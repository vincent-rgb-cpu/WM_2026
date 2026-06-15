# =============================================================================
# scorelines.R  --  Independent Poisson scoreline model.
#
# The XGBoost model outputs W/D/L probabilities. This module bridges that gap
# by producing exact scorelines (e.g. "2-1") via:
#
#   1. Fitting a Poisson GLM to historical goals data to estimate expected
#      goals (xG) for each team as a function of their Elo ratings.
#   2. Building the full (MAX_GOALS+1)^2 scoreline probability matrix for
#      any match via independent Poisson distributions.
#   3. Selecting the single most-probable scoreline that is CONSISTENT with
#      the W/D/L direction produced by the XGBoost model. This ensures the
#      submitted scoreline never contradicts the main model's outcome call.
#
# WHY ELO FEATURES INSTEAD OF TEAM DUMMIES?
# A standard Dixon-Coles model uses one attack + one defence dummy per team.
# With 48 WC teams — many of whom appear sparsely in recent results — those
# dummies would be poorly estimated and prediction on unseen name combinations
# would fail. Using continuous Elo as the predictor instead:
#   * Generalises to any team (Elo is always available via the main pipeline)
#   * Avoids factor-level mismatches between training and prediction data
#   * Loses some team-specific signal, but gains robustness
#
# MODEL (symmetric scorer view — one GLM for both sides):
#   log(E[goals]) = α  +  β_att · elo_attack
#                      +  β_def · elo_defense
#                      +  β_home · is_home
#
#   where (elo_attack, elo_defense) = (elo_home, elo_away) for the home-team
#   row and (elo_away, elo_home) for the away-team row. All WC 2026 matches
#   are on neutral ground so is_home = 0 at prediction time.
#
# All functions here are PURE (no file I/O). Side effects live in
# scripts/05_exact_scores.R.
# =============================================================================

suppressPackageStartupMessages(library(dplyr))


# --- 1. Fit the Poisson GLM --------------------------------------------------

#' Fit a Poisson goals model on historical match data.
#'
#' @param training_data  Data frame produced by build_features(). Must contain
#'   home_score, away_score, elo_home_pre, elo_away_pre, neutral, date.
#' @param min_date  Only include matches from this date onward. A tighter
#'   window focuses the model on current scoring patterns.
#' @return A fitted glm object (family = poisson).
fit_poisson_model <- function(training_data, min_date = POISSON_MIN_DATE) {
  m <- training_data %>%
    filter(
      date >= min_date,
      !is.na(home_score),   !is.na(away_score),
      !is.na(elo_home_pre), !is.na(elo_away_pre),
      # Drop extreme outliers that are likely data-quality issues.
      home_score <= 20, away_score <= 20
    )

  # Build the symmetric "scorer view": each match -> two rows.
  #   elo_attack  = Elo of the team that is trying to score
  #   elo_def     = Elo of the team that is trying to prevent goals
  #   is_home     = 1 only when the scoring team is at HOME (not for neutrals)
  home_view <- data.frame(
    goals      = m$home_score,
    elo_attack = m$elo_home_pre,
    elo_def    = m$elo_away_pre,
    is_home    = as.integer(!m$neutral),   # neutral venue -> no home bonus
    date       = m$date
  )
  away_view <- data.frame(
    goals      = m$away_score,
    elo_attack = m$elo_away_pre,
    elo_def    = m$elo_home_pre,
    is_home    = 0L,                        # away team never gets the home bonus
    date       = m$date
  )

  long     <- rbind(home_view, away_view)
  max_date <- max(long$date)
  long$sample_weight <- exp(-RECENCY_DECAY * as.numeric(max_date - long$date))

  fit <- glm(
    goals ~ elo_attack + elo_def + is_home,
    data    = long,
    family  = poisson(link = "log"),
    weights = sample_weight
  )

  log_msg(
    "Poisson model: ", nrow(long), " scorer-rows (", nrow(m), " matches)",
    "  |  deviance: ", round(fit$deviance),
    " / ", round(fit$null.deviance), " (null)"
  )
  fit
}


# --- 2. Predict expected goals -----------------------------------------------

#' Predict expected goals for a single match.
#'
#' @param poisson_model  Fitted glm from fit_poisson_model().
#' @param elo_home       Pre-match Elo of the home / first-named team.
#' @param elo_away       Pre-match Elo of the away / second-named team.
#' @param neutral        TRUE (default) for World Cup matches at neutral venues.
#' @return Named list: lambda_home, lambda_away (numeric scalars).
predict_xg <- function(poisson_model, elo_home, elo_away, neutral = TRUE) {
  # For neutral venues, assign 0.5 to both sides rather than 0: this recovers
  # the average scoring environment without giving either team a directional
  # edge. Setting both to 0 (two "away teams") suppresses goals ~13% below
  # the WC historical baseline because the GLM intercept was estimated on data
  # where one team almost always received the full home-advantage boost.
  is_h_home <- if (neutral) 0.5 else 1L
  is_h_away <- if (neutral) 0.5 else 0L

  nd_home <- data.frame(elo_attack = elo_home, elo_def = elo_away, is_home = is_h_home)
  nd_away <- data.frame(elo_attack = elo_away, elo_def = elo_home, is_home = is_h_away)

  list(
    lambda_home = unname(predict(poisson_model, nd_home, type = "response")),
    lambda_away = unname(predict(poisson_model, nd_away, type = "response"))
  )
}


# --- 3. Scoreline probability matrix -----------------------------------------

#' Apply the Dixon-Coles low-score dependency correction to a score matrix.
#'
#' The independent-Poisson model systematically under-predicts 0-0 and 1-1
#' and over-predicts 1-0 and 0-1. Dixon & Coles (1997) model this with a
#' single correlation parameter rho (negative empirically).
#'
#' The four modifiers are:
#'   P(0,0) × (1 − λμρ)   →  increased when ρ < 0
#'   P(1,0) × (1 + λρ)    →  decreased when ρ < 0
#'   P(0,1) × (1 + μρ)    →  decreased when ρ < 0
#'   P(1,1) × (1 − ρ)     →  increased when ρ < 0
#'
#' After modification the matrix is renormalised to sum to 1 and any negative
#' cells (which can arise for unusually high xG values) are floored at 0.
#'
#' @param mat     Numeric matrix from outer(h_probs, a_probs).
#' @param lambda  Expected home goals (scalar).
#' @param mu      Expected away goals (scalar).
#' @param rho     Dependency parameter. Default DC_RHO = -0.15.
#' @return Corrected and renormalised matrix with the same dimensions.
dc_correct_matrix <- function(mat, lambda, mu, rho = DC_RHO) {
  mat[1L, 1L] <- mat[1L, 1L] * (1 - lambda * mu * rho)   # P(0, 0)
  mat[2L, 1L] <- mat[2L, 1L] * (1 + lambda * rho)         # P(1, 0)
  mat[1L, 2L] <- mat[1L, 2L] * (1 + mu     * rho)         # P(0, 1)
  mat[2L, 2L] <- mat[2L, 2L] * (1 - rho)                  # P(1, 1)
  mat <- pmax(mat, 0)    # guard against negative cells at extreme xG
  mat / sum(mat)         # renormalise to unit sum
}

#' Build the full scoreline probability matrix with Dixon-Coles correction.
#'
#' Entry [i, j] = P(home scores i-1 goals, away scores j-1 goals) after
#' applying the DC dependency adjustment to the four low-scoring cells.
#' Rows index home goals (1 = 0 goals, ..., max_goals+1 = max_goals).
#' Cols index away goals in the same way.
#'
#' @param lambda_home  Expected home goals.
#' @param lambda_away  Expected away goals.
#' @param max_goals    Maximum goals per side (default MAX_GOALS = 5).
#' @param rho          Dixon-Coles correlation parameter (default DC_RHO).
#' @return Corrected numeric matrix of dimension (max_goals+1) × (max_goals+1).
score_matrix <- function(lambda_home, lambda_away,
                         max_goals = MAX_GOALS, rho = DC_RHO) {
  h_probs <- dpois(0:max_goals, lambda_home)
  a_probs <- dpois(0:max_goals, lambda_away)
  mat <- outer(h_probs, a_probs)
  dc_correct_matrix(mat, lambda_home, lambda_away, rho)
}


# --- 4. Pick the best consistent scoreline -----------------------------------

#' Select the most-probable scoreline that matches a W/D/L direction.
#'
#' Given the probability matrix from score_matrix() and the XGBoost model's
#' pred_result label, blank out all scorelines that CONTRADICT that result and
#' return the peak of the remaining region.
#'
#' Example: XGBoost says "home_win" -> only consider scorelines where
#'   home_goals > away_goals -> pick the (i,j) cell with max probability in
#'   that upper-left triangle.
#'
#' @param mat         Output of score_matrix().
#' @param pred_result One of "home_win", "draw", "away_win".
#' @return Named integer vector: c(goals_home = i, goals_away = j), 0-based.
best_scoreline <- function(mat, pred_result) {
  n <- nrow(mat) - 1L   # max goals value (0-indexed)
  g <- 0:n              # goal values: 0, 1, 2, ..., n

  # outer(g, g, FUN) -> matrix[i, j] = FUN(g[i], g[j])
  # i.e. matrix[i, j] is True when (i-1) goals satisfy the condition vs (j-1).
  mask <- switch(
    pred_result,
    home_win = outer(g, g, ">"),    # home goals > away goals
    draw     = outer(g, g, "=="),   # home goals == away goals
    away_win = outer(g, g, "<"),    # home goals < away goals
    stop("pred_result must be one of: 'home_win', 'draw', 'away_win'")
  )

  masked <- mat * mask   # zero out the irrelevant scorelines

  # Edge case: model assigns zero probability everywhere in the required region
  # (extremely unlikely with a calibrated Poisson, but defensive).
  if (max(masked) <= 0) {
    warning("No positive probability found in the '", pred_result,
            "' region — falling back to unconstrained most-probable scoreline.")
    masked <- mat
  }

  # Find the cell with the highest probability. [1, ] picks the first in case
  # of an exact tie (rare, but possible for e.g. symmetric 0-0 vs 1-1 in draw).
  idx <- which(masked == max(masked), arr.ind = TRUE)[1, ]

  # Convert 1-based matrix indices -> 0-based goal counts.
  c(goals_home = unname(idx[1] - 1L),
    goals_away = unname(idx[2] - 1L))
}


# --- 5. Generate scoreline predictions ----------------------------------------

#' Apply the Poisson model to every upcoming fixture and produce a tidy CSV-
#' ready data frame with exact scoreline predictions.
#'
#' @param fixture_preds  Output of predict_fixtures() — must contain columns:
#'   date, home_team, away_team, pred_result.
#' @param poisson_model  Fitted glm from fit_poisson_model().
#' @param ratings        Named numeric vector of current Elo ratings (from the
#'   main model bundle).
#' @param elo_params     ELO_PARAMS list from config.R (for the init_rating
#'   fallback when a team is absent from the Elo table).
#' @return Data frame with columns:
#'   Match_Date, Team_A, Team_B, Goals_A, Goals_B, xG_A, xG_B, WDL_pred.
generate_scoreline_predictions <- function(fixture_preds, poisson_model, ratings,
                                     elo_params = ELO_PARAMS) {
  rows <- fixture_preds %>%
    filter(!is.na(home_team), !is.na(away_team), !is.na(pred_result))

  out <- lapply(seq_len(nrow(rows)), function(i) {
    r <- rows[i, ]

    # Look up current Elo; fall back to the global init_rating for unknowns.
    elo_h <- ratings[[r$home_team]] %||% elo_params$init_rating
    elo_a <- ratings[[r$away_team]] %||% elo_params$init_rating

    xg    <- predict_xg(poisson_model, elo_h, elo_a, neutral = TRUE)
    mat   <- score_matrix(xg$lambda_home, xg$lambda_away)
    score <- best_scoreline(mat, r$pred_result)

    data.frame(
      Match_Date = as.character(r$date),
      Team_A     = r$home_team,
      Team_B     = r$away_team,
      Goals_A    = score[["goals_home"]],
      Goals_B    = score[["goals_away"]],
      xG_A       = round(xg$lambda_home, 3),
      xG_B       = round(xg$lambda_away, 3),
      WDL_pred   = r$pred_result,
      row.names  = NULL
    )
  })

  do.call(rbind, out) %>% arrange(Match_Date)
}

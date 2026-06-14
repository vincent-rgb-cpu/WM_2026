# =============================================================================
# features.R  --  Turn a chronological match table into model features.
#
# Two leakage-free, "as-of-match" feature families are produced:
#   1. Elo ratings (pre-match strength of each side)
#   2. Rolling form over the last FORM_WINDOW matches (points / goals / rest)
#
# Both are computed by walking matches in date order and recording each team's
# state BEFORE the match, then updating. Nothing about a match's own result
# leaks into its own features.
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(zoo)
})

# --- Elo ---------------------------------------------------------------------
# Walk matches chronologically, attaching each side's pre-match Elo, and
# return both the augmented matches and the final per-team rating vector.
# Matches with missing scores (e.g. not-yet-played) contribute no update.
compute_elo <- function(matches, params = ELO_PARAMS) {
  teams   <- unique(c(matches$home_team, matches$away_team))
  ratings <- setNames(rep(params$init_rating, length(teams)), teams)

  n  <- nrow(matches)
  eh <- numeric(n); ea <- numeric(n)
  ht <- matches$home_team; at <- matches$away_team
  hs <- matches$home_score; as_ <- matches$away_score
  neu <- matches$neutral

  for (i in seq_len(n)) {
    rh <- ratings[[ht[i]]]; ra <- ratings[[at[i]]]
    eh[i] <- rh; ea[i] <- ra

    adv   <- if (isTRUE(neu[i])) 0 else params$home_advantage
    exp_h <- 1 / (1 + 10 ^ ((ra - (rh + adv)) / 400))

    if (is.na(hs[i]) || is.na(as_[i])) next  # unplayed -> no rating change

    gd  <- abs(hs[i] - as_[i])
    g   <- if (gd <= 1) 1 else if (gd == 2) 1.5
           else if (gd == 3) 1.75 else 1.75 + (gd - 3) / 8   # goal-diff weight
    res <- if (hs[i] > as_[i]) 1 else if (hs[i] == as_[i]) 0.5 else 0
    d   <- params$k * g * (res - exp_h)

    ratings[[ht[i]]] <- rh + d
    ratings[[at[i]]] <- ra - d
  }

  matches$elo_home_pre <- eh
  matches$elo_away_pre <- ea
  list(matches = matches, ratings = ratings)
}

# --- Rolling form ------------------------------------------------------------
# Reshape matches into one row per (team, match) so per-team rolling stats are
# easy to compute. Used by both the training-feature builder and the
# current-form snapshot for prediction.
to_team_long <- function(matches) {
  pts <- function(gf, ga) case_when(gf > ga ~ 3, gf == ga ~ 1, TRUE ~ 0)
  bind_rows(
    matches %>% transmute(match_id_seq, date, team = home_team, side = "home",
                          gf = home_score, ga = away_score,
                          pts = pts(home_score, away_score)),
    matches %>% transmute(match_id_seq, date, team = away_team, side = "away",
                          gf = away_score, ga = home_score,
                          pts = pts(away_score, home_score))
  ) %>%
    arrange(team, date, match_id_seq)
}

# Mean of the previous `n` values (current row excluded) -> no leakage.
.roll_prev_mean <- function(x, n) {
  prev <- dplyr::lag(x)
  out  <- zoo::rollapplyr(prev, width = n, FUN = function(v) mean(v, na.rm = TRUE),
                          partial = TRUE, fill = NA_real_)
  out[is.nan(out)] <- NA_real_   # first match of a team has no history
  out
}

# Attach home_/away_ rolling-form columns to the match table.
add_form_features <- function(matches, window = FORM_WINDOW) {
  long <- to_team_long(matches) %>%
    group_by(team) %>%
    mutate(
      form_pts  = .roll_prev_mean(pts, window),
      form_gf   = .roll_prev_mean(gf,  window),
      form_ga   = .roll_prev_mean(ga,  window),
      days_rest = as.numeric(date - dplyr::lag(date))
    ) %>%
    ungroup()

  home_f <- long %>% filter(side == "home") %>%
    select(match_id_seq, home_form_pts = form_pts, home_form_gf = form_gf,
           home_form_ga = form_ga, home_days_rest = days_rest)
  away_f <- long %>% filter(side == "away") %>%
    select(match_id_seq, away_form_pts = form_pts, away_form_gf = form_gf,
           away_form_ga = form_ga, away_days_rest = days_rest)

  matches %>%
    left_join(home_f, by = "match_id_seq") %>%
    left_join(away_f, by = "match_id_seq")
}

# --- Assemble the model frame ------------------------------------------------
# Full pipeline: chronological matches -> features + target + recency weight.
build_features <- function(matches, params = ELO_PARAMS) {
  matches <- matches %>%
    arrange(date) %>%
    mutate(match_id_seq = row_number())   # stable join key

  elo     <- compute_elo(matches, params)
  matches <- add_form_features(elo$matches)

  latest_date <- max(matches$date, na.rm = TRUE)

  feats <- matches %>%
    mutate(
      result = factor(
        case_when(
          home_score >  away_score ~ "home_win",
          home_score == away_score ~ "draw",
          TRUE                     ~ "away_win"
        ),
        levels = RESULT_LEVELS
      ),
      elo_diff      = elo_home_pre - elo_away_pre,
      home_adv      = ifelse(neutral, 0L, 1L),
      form_pts_diff = home_form_pts - away_form_pts,
      form_gf_diff  = home_form_gf  - away_form_gf,
      form_ga_diff  = home_form_ga  - away_form_ga,
      rest_diff     = pmin(home_days_rest, 365) - pmin(away_days_rest, 365),
      sample_weight = exp(-RECENCY_DECAY * as.numeric(latest_date - date))
    )

  list(data = feats, ratings = elo$ratings)
}

# --- Current-state snapshot (for predicting upcoming fixtures) ----------------
# Each team's most recent form, used to build features for unplayed matches.
current_team_form <- function(matches, window = FORM_WINDOW) {
  matches <- matches %>% arrange(date) %>% mutate(match_id_seq = row_number())
  to_team_long(matches) %>%
    arrange(team, date) %>%
    group_by(team) %>%
    slice_tail(n = window) %>%
    summarise(
      cur_form_pts = mean(pts, na.rm = TRUE),
      cur_form_gf  = mean(gf,  na.rm = TRUE),
      cur_form_ga  = mean(ga,  na.rm = TRUE),
      last_date    = max(date, na.rm = TRUE),
      .groups = "drop"
    )
}

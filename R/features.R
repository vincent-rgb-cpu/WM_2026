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

# --- Match importance & knockout flag ----------------------------------------
# Derive an ordinal importance tier from the `stage` column.
# Historical rows carry the tournament name as `stage` (e.g. "FIFA World Cup",
# "Friendly"); WC-2026 rows carry the round code (group/r32/r16/qf/sf/final).
#   0 = friendly  |  1 = qualifier  |  2 = tournament / group  |  3 = knockout
match_importance_score <- function(stage) {
  dplyr::case_when(
    grepl("^Friendly$",                              stage, ignore.case = TRUE) ~ 0L,
    grepl("qualif",                                  stage, ignore.case = TRUE) ~ 1L,
    grepl("^(r32|r16|qf|sf|third|final|ko)$",       stage, ignore.case = TRUE) ~ 3L,
    TRUE                                                                        ~ 2L
  )
}

is_knockout_flag <- function(stage) {
  as.integer(grepl("^(r32|r16|qf|sf|third|final|ko)$", stage, ignore.case = TRUE))
}

# --- Elo ---------------------------------------------------------------------
# Walk matches chronologically, attaching each side's pre-match Elo, and
# return both the augmented matches and the final per-team rating vector.
# A *fast* Elo is computed in parallel using FAST_K_MULTIPLIER × the normal K.
# It reacts heavily to the last ~3 matches, capturing recent momentum
# independently of the long-run slow Elo. Matches with missing scores
# (e.g. not-yet-played) contribute no update to either rating system.
compute_elo <- function(matches, params = ELO_PARAMS) {
  teams        <- unique(c(matches$home_team, matches$away_team))
  ratings      <- setNames(rep(params$init_rating, length(teams)), teams)
  fast_ratings <- setNames(rep(params$init_rating, length(teams)), teams)
  fast_k       <- params$k * FAST_K_MULTIPLIER

  n   <- nrow(matches)
  eh  <- numeric(n); ea  <- numeric(n)
  feh <- numeric(n); fea <- numeric(n)   # fast-Elo pre-match snapshots
  ht  <- matches$home_team; at <- matches$away_team
  hs  <- matches$home_score; as_ <- matches$away_score
  neu <- matches$neutral

  for (i in seq_len(n)) {
    rh <- ratings[[ht[i]]];      ra <- ratings[[at[i]]]
    fh <- fast_ratings[[ht[i]]]; fa <- fast_ratings[[at[i]]]
    eh[i]  <- rh; ea[i]  <- ra
    feh[i] <- fh; fea[i] <- fa

    adv        <- if (isTRUE(neu[i])) 0 else params$home_advantage
    exp_h      <- 1 / (1 + 10 ^ ((ra - (rh + adv)) / 400))
    exp_h_fast <- 1 / (1 + 10 ^ ((fa - (fh + adv)) / 400))

    if (is.na(hs[i]) || is.na(as_[i])) next  # unplayed -> no rating change

    gd      <- abs(hs[i] - as_[i])
    home_w  <- hs[i] > as_[i]
    home_l  <- hs[i] < as_[i]
    res     <- if (home_w) 1 else if (home_l) 0 else 0.5

    # MoV multiplier (log-scale, continuous):
    #   gd 0→1 | gd 1→1 | gd 2→1.58 | gd 3→2 | gd 4→2.32 | gd 5→2.58
    # For draws (gd=0) g=1 and autocorr is skipped (no winner to reference).
    g <- if (gd == 0L) {
      1
    } else {
      g_base <- log2(gd + 1)   # log base-2 keeps gd=1 anchored at 1.0

      # Autocorrelation correction (FiveThirtyEight SPI):
      # dominant wins over weak opponents earn LESS extra credit;
      # upsets earn MORE. winner_delta > 0 means the winner was already favoured.
      winner_delta <- if (home_w) (rh + adv) - ra else ra - (rh + adv)
      g_base * (2.2 / (winner_delta * 0.001 + 2.2))
    }

    d      <- params$k * g * (res - exp_h)
    d_fast <- fast_k    * g * (res - exp_h_fast)

    ratings[[ht[i]]]      <- rh + d;      ratings[[at[i]]]      <- ra - d
    fast_ratings[[ht[i]]] <- fh + d_fast; fast_ratings[[at[i]]] <- fa - d_fast
  }

  matches$elo_home_pre      <- eh
  matches$elo_away_pre      <- ea
  matches$fast_elo_home_pre <- feh
  matches$fast_elo_away_pre <- fea
  list(matches = matches, ratings = ratings, fast_ratings = fast_ratings)
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
      days_rest = {
        raw <- as.numeric(date - dplyr::lag(date))
        # First match per team has no lag → NA.
        # Impute with that team's own median rest interval; fall back to 14 days
        # for teams whose entire history in this dataset is a single match.
        dplyr::coalesce(raw, median(raw, na.rm = TRUE), 14)
      }
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

  # Anchor recency weights to WC_START rather than the latest row in training
  # data. Before the WC this equals the latest training date; once the WC
  # begins, the anchor is fixed so adding new results doesn't silently
  # re-weight every historical match.
  latest_date <- max(matches$date, na.rm = TRUE)
  ref_date    <- max(latest_date, WC_START)
  mv          <- load_market_values()
  mv_log      <- function(team) {
    v <- mv[team]
    ifelse(is.na(v) | v <= 0, NA_real_, log(v))
  }

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
      sample_weight = exp(-RECENCY_DECAY * as.numeric(ref_date - date)),
      log_mv_home   = mv_log(home_team),
      log_mv_away   = mv_log(away_team),
      match_importance = match_importance_score(stage),
      is_knockout      = is_knockout_flag(stage),
      momentum_home    = fast_elo_home_pre - elo_home_pre,
      momentum_away    = fast_elo_away_pre - elo_away_pre
    )

  n_mv <- sum(!is.na(feats$log_mv_home) | !is.na(feats$log_mv_away))
  log_msg("Market value coverage: ", n_mv, " / ", nrow(feats),
          " rows have at least one team MV")

  list(data = feats, ratings = elo$ratings, fast_ratings = elo$fast_ratings)
}

# --- Squad market values (Transfermarkt) -------------------------------------
# Returns a named numeric vector: team_name -> mv_eur.
# Missing or unparseable entries are silently dropped; callers receive NA for
# those teams, which xgboost routes to the default (mean) split path.
load_market_values <- function(path = FILES$market_values) {
  if (!file.exists(path)) {
    log_msg("No market value cache at ", path,
            " — run scripts/01b_scrape_market_values.R to enable log_mv features.")
    return(setNames(numeric(0), character(0)))
  }
  df <- read.csv(path, stringsAsFactors = FALSE)
  df <- df[!is.na(df$mv_eur) & df$mv_eur > 0, ]
  setNames(df$mv_eur, df$team)
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

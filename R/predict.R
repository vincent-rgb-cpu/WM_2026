# =============================================================================
# predict.R  --  Apply the trained model to WC-2026 fixtures and simulate the
#                group stage.
#
# Two outputs:
#   1. predict_fixtures()      - per-match P(home/draw/away) for scheduled games
#   2. simulate_group_stage()  - Monte-Carlo advancement probabilities
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tibble)
})

# Build the feature row for each upcoming fixture from the *current* team state
# (latest Elo + latest rolling form), then predict probabilities.
# fast_ratings: end-of-training fast-Elo vector (from build_features return value).
#   momentum_home/away = fast_elo - slow_elo; positive = team on an upswing.
predict_fixtures <- function(model, fixtures, ratings, team_form,
                             fast_ratings = list(),
                             ref_date = Sys.Date(), params = ELO_PARAMS) {
  elo_of      <- function(t) ratings[[t]]      %||% params$init_rating
  fast_elo_of <- function(t) fast_ratings[[t]] %||% elo_of(t)
  form_of <- function(t, col, default) {
    v <- team_form[[col]][team_form$team == t]
    if (length(v)) v[1] else default
  }
  last_of <- function(t) {
    v <- team_form$last_date[team_form$team == t]
    if (length(v)) v[1] else NA
  }
  mv     <- load_market_values()
  mv_log <- function(t) { v <- mv[t]; ifelse(is.na(v) | v <= 0, NA_real_, log(v)) }

  if (!"neutral"  %in% names(fixtures)) fixtures$neutral  <- TRUE
  if (!"matchday" %in% names(fixtures)) fixtures$matchday <- NA_real_
  if (!"stage"    %in% names(fixtures)) fixtures$stage    <- NA_character_

  fx <- fixtures %>%
    rowwise() %>%
    mutate(
      elo_home_pre  = elo_of(home_team),
      elo_away_pre  = elo_of(away_team),
      elo_diff      = elo_home_pre - elo_away_pre,
      home_adv      = ifelse(neutral, 0L, 1L),  # 1 for WC 2026 host nations
      form_pts_diff = form_of(home_team, "cur_form_pts", 1) -
                      form_of(away_team, "cur_form_pts", 1),
      form_gf_diff  = form_of(home_team, "cur_form_gf", 1) -
                      form_of(away_team, "cur_form_gf", 1),
      form_ga_diff  = form_of(home_team, "cur_form_ga", 1) -
                      form_of(away_team, "cur_form_ga", 1),
      rest_diff     = pmin(as.numeric(ref_date - last_of(home_team)), 365) -
                      pmin(as.numeric(ref_date - last_of(away_team)), 365),
      log_mv_home   = mv_log(home_team),
      log_mv_away   = mv_log(away_team),
      match_importance = match_importance_score(stage),
      is_knockout      = is_knockout_flag(stage),
      momentum_home    = fast_elo_of(home_team) - elo_of(home_team),
      momentum_away    = fast_elo_of(away_team) - elo_of(away_team)
    ) %>%
    ungroup()

  proba <- predict_proba(model, fx)
  fx %>%
    mutate(
      p_home_win  = proba[, "home_win"],
      p_draw      = proba[, "draw"],
      p_away_win  = proba[, "away_win"],
      pred_result = RESULT_LEVELS[max.col(proba, ties.method = "first")]
    ) %>%
    select(match_id, date, group, stage, matchday, home_team, away_team,
           p_home_win, p_draw, p_away_win, pred_result)
}

# Monte-Carlo the group stage. For each simulation every group match is sampled
# from its predicted W/D/L probabilities, points are tallied, and qualification
# is decided by the WC-2026 rule (top 2 of each group + best N_THIRDS_ADV
# third-placed teams). Ties are broken with tiny random noise.
#
# Dead-rubber adjustment: if a team has already secured DEAD_RUBBER_PTS points
# by matchday 3, they are treated as likely rotating their squad. Their
# probabilities are shrunk by DEAD_RUBBER_SHRINK toward uniform (1/3 each).
# This requires group_probs to include a `matchday` column (added by
# predict_fixtures); if the column is absent the adjustment is silently skipped.
#
# Returns per-team probabilities of winning the group and of advancing.
simulate_group_stage <- function(group_probs, n_sim = SIM_N, seed = SIM_SEED,
                                 n_thirds        = N_THIRDS_ADV,
                                 dead_rubber_pts = DEAD_RUBBER_PTS,
                                 dead_rubber_shrink = DEAD_RUBBER_SHRINK) {
  set.seed(seed)
  has_matchday <- "matchday" %in% names(group_probs)
  groups <- sort(unique(group_probs$group))
  teams  <- sort(unique(c(group_probs$home_team, group_probs$away_team)))

  win_group <- setNames(numeric(length(teams)), teams)
  advance   <- setNames(numeric(length(teams)), teams)
  pts_total <- setNames(numeric(length(teams)), teams)

  for (s in seq_len(n_sim)) {
    third_team <- character(0)
    third_pts  <- numeric(0)

    for (g in groups) {
      m  <- group_probs[group_probs$group == g, ]
      # Process in matchday order so points accumulate before the MD3 check.
      if (has_matchday) m <- m[order(m$matchday, na.last = FALSE), ]
      gt <- sort(unique(c(m$home_team, m$away_team)))
      p  <- setNames(numeric(length(gt)), gt)

      for (i in seq_len(nrow(m))) {
        ph <- m$p_home_win[i]
        pd <- m$p_draw[i]
        pa <- m$p_away_win[i]

        # Dead-rubber: shrink probs toward uniform when a team already has
        # enough points to be through, signalling likely squad rotation.
        if (has_matchday && !is.na(m$matchday[i]) && m$matchday[i] == 3) {
          h <- m$home_team[i]; a <- m$away_team[i]
          if (p[h] >= dead_rubber_pts || p[a] >= dead_rubber_pts) {
            s_frac <- dead_rubber_shrink
            ph <- ph * (1 - s_frac) + s_frac / 3
            pd <- pd * (1 - s_frac) + s_frac / 3
            pa <- pa * (1 - s_frac) + s_frac / 3
            # Sum still equals 1: (ph+pd+pa)*(1-s) + s = 1
          }
        }

        r <- runif(1)
        if (r < ph) {
          p[m$home_team[i]] <- p[m$home_team[i]] + 3
        } else if (r < ph + pd) {
          p[m$home_team[i]] <- p[m$home_team[i]] + 1
          p[m$away_team[i]] <- p[m$away_team[i]] + 1
        } else {
          p[m$away_team[i]] <- p[m$away_team[i]] + 3
        }
      }

      ord <- order(p + runif(length(p), 0, 1e-3), decreasing = TRUE)
      win_group[gt[ord[1]]] <- win_group[gt[ord[1]]] + 1
      advance[gt[ord[1]]]   <- advance[gt[ord[1]]]   + 1   # group winner
      advance[gt[ord[2]]]   <- advance[gt[ord[2]]]   + 1   # runner-up
      pts_total[gt]         <- pts_total[gt] + p[gt]

      third_team <- c(third_team, gt[ord[3]])
      third_pts  <- c(third_pts,  p[gt[ord[3]]])
    }

    # Best third-placed teams across all groups also advance.
    if (length(third_team)) {
      best <- third_team[order(third_pts + runif(length(third_pts), 0, 1e-3),
                               decreasing = TRUE)][seq_len(min(n_thirds,
                                                              length(third_team)))]
      advance[best] <- advance[best] + 1
    }
  }

  tibble(
    team        = teams,
    p_win_group = win_group[teams] / n_sim,
    p_advance   = advance[teams]   / n_sim,
    exp_points  = pts_total[teams] / n_sim
  ) %>%
    arrange(desc(p_advance), desc(exp_points))
}

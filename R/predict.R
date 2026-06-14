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
predict_fixtures <- function(model, fixtures, ratings, team_form,
                             ref_date = Sys.Date(), params = ELO_PARAMS) {
  elo_of <- function(t) ratings[[t]] %||% params$init_rating
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

  fx <- fixtures %>%
    rowwise() %>%
    mutate(
      elo_home_pre  = elo_of(home_team),
      elo_away_pre  = elo_of(away_team),
      elo_diff      = elo_home_pre - elo_away_pre,
      home_adv      = 0L,                       # neutral-venue tournament
      form_pts_diff = form_of(home_team, "cur_form_pts", 1) -
                      form_of(away_team, "cur_form_pts", 1),
      form_gf_diff  = form_of(home_team, "cur_form_gf", 1) -
                      form_of(away_team, "cur_form_gf", 1),
      form_ga_diff  = form_of(home_team, "cur_form_ga", 1) -
                      form_of(away_team, "cur_form_ga", 1),
      rest_diff     = pmin(as.numeric(ref_date - last_of(home_team)), 365) -
                      pmin(as.numeric(ref_date - last_of(away_team)), 365),
      log_mv_home   = mv_log(home_team),
      log_mv_away   = mv_log(away_team)
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
    select(match_id, date, group, stage, home_team, away_team,
           p_home_win, p_draw, p_away_win, pred_result)
}

# Monte-Carlo the group stage. For each simulation every group match is sampled
# from its predicted W/D/L probabilities, points are tallied, and qualification
# is decided by the WC-2026 rule (top 2 of each group + best N_THIRDS_ADV
# third-placed teams). Ties are broken with tiny random noise.
# Returns per-team probabilities of winning the group and of advancing.
simulate_group_stage <- function(group_probs, n_sim = SIM_N, seed = SIM_SEED,
                                 n_thirds = N_THIRDS_ADV) {
  set.seed(seed)
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
      gt <- sort(unique(c(m$home_team, m$away_team)))
      p  <- setNames(numeric(length(gt)), gt)

      for (i in seq_len(nrow(m))) {
        r <- runif(1)
        if (r < m$p_home_win[i]) {
          p[m$home_team[i]] <- p[m$home_team[i]] + 3
        } else if (r < m$p_home_win[i] + m$p_draw[i]) {
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

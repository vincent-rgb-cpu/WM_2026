# =============================================================================
# 06_financial_benchmark.R  --  Live benchmarking against completed WC-2026 matches.
#
# For each finished WC-2026 match:
#   1. Re-generates our model's pre-match probability vector.
#   2. Records proper scoring metrics (log-loss, Brier, accuracy).
#   3. Simulates a value-betting strategy using Quarter-Kelly sizing.
#
# Bookmaker odds assumption: bookmaker's implied probability =
#   model_prob / OVERROUND_FACTOR (i.e. they charge a 5% margin on top of
#   whatever the true market price is). This is NOT a real backtest against
#   external odds; it demonstrates the value-betting framework and shows
#   calibration. A real backtest would replace the odds column with actual
#   quotes from a broker API.
#
# Outputs:
#   output/wc2026_match_log.csv     -- one row per finished match
#   output/financial_benchmark.csv  -- cumulative P&L over the tournament
#
# Usage:  Rscript scripts/06_financial_benchmark.R
# =============================================================================

source("R/utils.R")
load_pipeline("R")
ensure_dirs()

STARTING_BANKROLL  <- 1000      # arbitrary monetary units
OVERROUND_FACTOR   <- 1.05      # bookmaker's 5% margin (vig)
KELLY_FRACTION     <- 0.25      # quarter-Kelly is standard for model uncertainty
MIN_EDGE           <- 0.01      # only bet when edge > 1 pp (filters noise)
MAX_KELLY_STAKE    <- 0.10      # cap any single bet at 10 % of bankroll

# ── Load pipeline outputs ─────────────────────────────────────────────────────
bundle   <- readRDS(FILES$training_data)
model    <- load_model()
finished <- finished_fixtures(bundle$fixtures)

if (nrow(finished) == 0L) {
  log_msg("No finished WC-2026 matches yet — writing empty benchmark files.")
  empty_log <- tibble::tibble(
    match_id=character(), date=as.Date(character()),
    home_team=character(), away_team=character(),
    actual_result=character(), pred_result=character(),
    p_home_win=numeric(), p_draw=numeric(), p_away_win=numeric(),
    p_actual=numeric(), log_loss=numeric(), brier=numeric(),
    correct=logical(), bet_outcome=character(),
    kelly_stake=numeric(), bet_return=numeric(), bankroll=numeric()
  )
  readr::write_csv(empty_log, file.path(PATHS$output, "wc2026_match_log.csv"))
  readr::write_csv(empty_log[0, c("date","bankroll")],
                   file.path(PATHS$output, "financial_benchmark.csv"))
  quit(status = 0)
}

log_msg("Generating model predictions for ", nrow(finished),
        " finished WC-2026 matches ...")

# predict_fixtures() works on any fixtures tibble, finished or not.
preds <- predict_fixtures(model, finished, bundle$ratings, bundle$team_form)

# ── Join predictions with actual scores ───────────────────────────────────────
match_log <- finished %>%
  dplyr::select(match_id, date, home_team, away_team, home_score, away_score) %>%
  dplyr::inner_join(preds %>% dplyr::select(match_id, p_home_win, p_draw,
                                              p_away_win, pred_result),
                    by = "match_id") %>%
  dplyr::mutate(
    actual_result = dplyr::case_when(
      home_score >  away_score ~ "home_win",
      home_score == away_score ~ "draw",
      TRUE                     ~ "away_win"
    ),
    # Probability our model assigned to the outcome that actually happened
    p_actual = dplyr::case_when(
      actual_result == "home_win" ~ p_home_win,
      actual_result == "draw"     ~ p_draw,
      actual_result == "away_win" ~ p_away_win
    ),
    log_loss = -log(pmax(p_actual, 1e-7)),
    brier    = (1 - p_actual)^2 +
               dplyr::if_else(actual_result != "home_win", p_home_win^2, 0) +
               dplyr::if_else(actual_result != "draw",     p_draw^2,     0) +
               dplyr::if_else(actual_result != "away_win", p_away_win^2, 0),
    correct  = pred_result == actual_result
  )

# ── Value-betting simulation (Quarter-Kelly on predicted outcome) ─────────────
# We always bet on the outcome our model gives the highest probability to.
# Edge = model_prob - bookmaker_implied_prob
# Bookmaker implied = model_prob / OVERROUND_FACTOR  →  edge ≈ model_prob * 4.8%
# Note: because we derive odds from our own model, edge is always positive here.
# In practice you compare against an external odds feed.

match_log <- match_log %>%
  dplyr::mutate(
    bet_prob    = dplyr::case_when(
      pred_result == "home_win" ~ p_home_win,
      pred_result == "draw"     ~ p_draw,
      TRUE                      ~ p_away_win
    ),
    bet_odds    = OVERROUND_FACTOR / bet_prob,   # decimal bookmaker odds
    implied_prob = 1 / bet_odds,
    edge        = bet_prob - implied_prob,
    # Raw Kelly fraction: (p*b - 1)/(b - 1) where b = decimal odds
    kelly_full  = pmax((bet_prob * bet_odds - 1) / (bet_odds - 1), 0),
    kelly_frac  = pmin(kelly_full * KELLY_FRACTION, MAX_KELLY_STAKE),
    bet_won     = pred_result == actual_result
  )

# Sequential bankroll simulation (must loop — each stake depends on current bankroll)
bankroll  <- STARTING_BANKROLL
stakes    <- numeric(nrow(match_log))
returns_v <- numeric(nrow(match_log))
bankrolls <- numeric(nrow(match_log))

for (i in seq_len(nrow(match_log))) {
  row <- match_log[i, ]
  if (row$edge >= MIN_EDGE) {
    stake      <- row$kelly_frac * bankroll
    profit     <- if (row$bet_won) stake * (row$bet_odds - 1) else -stake
    bankroll   <- bankroll + profit
  } else {
    stake  <- 0
    profit <- 0
  }
  stakes[i]    <- stake
  returns_v[i] <- profit
  bankrolls[i] <- bankroll
}

match_log <- match_log %>%
  dplyr::mutate(
    kelly_stake = stakes,
    bet_return  = returns_v,
    bankroll    = bankrolls
  )

# ── Summary statistics ────────────────────────────────────────────────────────
n   <- nrow(match_log)
acc <- mean(match_log$correct)
ll  <- mean(match_log$log_loss)
br  <- mean(match_log$brier)
roi <- (tail(bankrolls, 1) - STARTING_BANKROLL) / STARTING_BANKROLL * 100

log_msg(sprintf(
  "WC-2026 live results  |  n=%d  acc=%.1f%%  log-loss=%.3f  Brier=%.3f  sim-ROI=%+.1f%%",
  n, acc * 100, ll, br, roi
))

# ── Write outputs ─────────────────────────────────────────────────────────────
out_log <- match_log %>%
  dplyr::select(match_id, date, home_team, away_team, home_score, away_score,
                actual_result, pred_result, p_home_win, p_draw, p_away_win,
                p_actual, log_loss, brier, correct, edge,
                kelly_stake, bet_return, bankroll)

readr::write_csv(out_log, file.path(PATHS$output, "wc2026_match_log.csv"))
log_msg("Saved wc2026_match_log.csv  (", nrow(out_log), " rows)")

# Cumulative P&L anchored at day-0 starting point
pnl <- dplyr::bind_rows(
  tibble::tibble(date = min(out_log$date) - 1L, bankroll = STARTING_BANKROLL,
                 n_bets = 0L, cumulative_correct = 0L),
  out_log %>%
    dplyr::arrange(date) %>%
    dplyr::mutate(n_bets = cumsum(kelly_stake > 0),
                  cumulative_correct = cumsum(correct))  %>%
    dplyr::select(date, bankroll, n_bets, cumulative_correct)
)
readr::write_csv(pnl, file.path(PATHS$output, "financial_benchmark.csv"))
log_msg("Saved financial_benchmark.csv")

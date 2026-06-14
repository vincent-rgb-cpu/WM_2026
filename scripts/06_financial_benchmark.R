# =============================================================================
# 06_financial_benchmark.R  --  Live benchmarking against completed WC-2026 matches.
#
# For each finished WC-2026 match:
#   1. Re-generates our model's pre-match probability vector.
#   2. Records proper scoring metrics (log-loss, Brier, accuracy).
#   3. Simulates a value-betting strategy using Quarter-Kelly sizing against
#      REAL pre-match market odds from The Odds API (via 01c_fetch_real_odds.R).
#
# A bet is only placed when:
#   (a) real odds are available for that match, AND
#   (b) edge = model_prob − 1/real_odds ≥ MIN_EDGE
#
# Matches without real odds are logged and skipped (no bet, no crash).
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

STARTING_BANKROLL <- 1000      # arbitrary monetary units
KELLY_FRACTION    <- 0.25      # quarter-Kelly is standard for model uncertainty
MIN_EDGE          <- 0.03      # minimum model edge to place a bet (3 pp)
MAX_KELLY_STAKE   <- 0.10      # cap any single bet at 10 % of current bankroll

# ── Load pipeline outputs ─────────────────────────────────────────────────────
bundle   <- readRDS(FILES$training_data)
model    <- load_model()
finished <- finished_fixtures(bundle$fixtures)

if (nrow(finished) == 0L) {
  log_msg("No finished WC-2026 matches yet — writing empty benchmark files.")
  empty_log <- tibble::tibble(
    match_id=character(), date=as.Date(character()),
    home_team=character(), away_team=character(),
    home_score=integer(), away_score=integer(),
    actual_result=character(), pred_result=character(),
    p_home_win=numeric(), p_draw=numeric(), p_away_win=numeric(),
    p_actual=numeric(), log_loss=numeric(), brier=numeric(),
    correct=logical(),
    bookmaker=character(), real_odds=numeric(), edge=numeric(),
    kelly_stake=numeric(), bet_return=numeric(), bankroll=numeric()
  )
  readr::write_csv(empty_log, file.path(PATHS$output, "wc2026_match_log.csv"))
  pnl_empty <- tibble::tibble(date=as.Date(character()), bankroll=numeric(),
                              n_bets=integer(), cumulative_correct=integer())
  readr::write_csv(pnl_empty, file.path(PATHS$output, "financial_benchmark.csv"))
  quit(status = 0)
}

log_msg("Generating model predictions for ", nrow(finished),
        " finished WC-2026 matches ...")

preds <- predict_fixtures(model, finished, bundle$ratings, bundle$team_form,
                         fast_ratings = bundle$fast_ratings %||% list())

# ── Join predictions with actual scores ───────────────────────────────────────
match_log <- finished %>%
  dplyr::select(match_id, date, home_team, away_team, home_score, away_score) %>%
  dplyr::inner_join(
    preds %>% dplyr::select(match_id, p_home_win, p_draw, p_away_win, pred_result),
    by = "match_id"
  ) %>%
  dplyr::mutate(
    actual_result = dplyr::case_when(
      home_score >  away_score ~ "home_win",
      home_score == away_score ~ "draw",
      TRUE                     ~ "away_win"
    ),
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
    correct  = pred_result == actual_result,
    # Probability our model assigns to the predicted (bet) outcome
    bet_prob = dplyr::case_when(
      pred_result == "home_win" ~ p_home_win,
      pred_result == "draw"     ~ p_draw,
      TRUE                      ~ p_away_win
    )
  )

# ── Load real market odds ─────────────────────────────────────────────────────
real_odds_df <- NULL
if (file.exists(FILES$real_odds)) {
  real_odds_df <- tryCatch(
    read.csv(FILES$real_odds, stringsAsFactors = FALSE),
    error = function(e) {
      log_msg("Could not read odds cache: ", conditionMessage(e))
      NULL
    }
  )
}

if (!is.null(real_odds_df) && nrow(real_odds_df) > 0) {
  log_msg(sprintf("Loaded real odds for %d match(es) from cache.", nrow(real_odds_df)))

  match_log <- match_log %>%
    dplyr::left_join(
      real_odds_df %>%
        dplyr::select(home_team, away_team, bookmaker,
                      home_odds, draw_odds, away_odds),
      by = c("home_team", "away_team")
    ) %>%
    dplyr::mutate(
      # Pick the real decimal odds for the outcome our model predicts
      real_odds = dplyr::case_when(
        pred_result == "home_win" ~ home_odds,
        pred_result == "draw"     ~ draw_odds,
        pred_result == "away_win" ~ away_odds
      ),
      edge = dplyr::if_else(
        !is.na(real_odds),
        bet_prob - (1 / real_odds),
        NA_real_
      )
    )

  n_with_odds    <- sum(!is.na(match_log$real_odds))
  n_without_odds <- sum( is.na(match_log$real_odds))
  log_msg(sprintf("  Odds matched: %d/%d matches (%d skipped — no odds available).",
                  n_with_odds, nrow(match_log), n_without_odds))

  if (n_without_odds > 0) {
    missing <- match_log %>%
      dplyr::filter(is.na(real_odds)) %>%
      dplyr::mutate(label = paste(home_team, "vs", away_team))
    log_msg("  Matches without odds (no bet will be placed):")
    for (lbl in missing$label) log_msg("    • ", lbl)
  }
} else {
  log_msg("No real odds cache found — Kelly simulation will be skipped for all matches.")
  log_msg("  Run:  make odds  (requires ODDS_API_KEY env variable)")
  match_log <- match_log %>%
    dplyr::mutate(bookmaker = NA_character_,
                  home_odds = NA_real_, draw_odds = NA_real_, away_odds = NA_real_,
                  real_odds = NA_real_, edge = NA_real_)
}

# ── Kelly sizing ──────────────────────────────────────────────────────────────
match_log <- match_log %>%
  dplyr::mutate(
    # Kelly formula: (p*b - 1)/(b - 1) where b = decimal odds
    kelly_full = dplyr::if_else(
      !is.na(real_odds) & edge >= MIN_EDGE,
      pmax((bet_prob * real_odds - 1) / (real_odds - 1), 0),
      0
    ),
    kelly_frac = pmin(kelly_full * KELLY_FRACTION, MAX_KELLY_STAKE),
    bet_won    = pred_result == actual_result
  )

# ── Sequential bankroll simulation ────────────────────────────────────────────
bankroll  <- STARTING_BANKROLL
stakes    <- numeric(nrow(match_log))
returns_v <- numeric(nrow(match_log))
bankrolls <- numeric(nrow(match_log))

for (i in seq_len(nrow(match_log))) {
  row <- match_log[i, ]

  if (!is.na(row$edge) && row$edge >= MIN_EDGE) {
    stake  <- row$kelly_frac * bankroll
    profit <- if (isTRUE(row$bet_won)) stake * (row$real_odds - 1) else -stake
    bankroll <- bankroll + profit
    log_msg(sprintf(
      "  Bet: %s vs %s → %s @ %.2f [%s, edge %+.1f%%] → %+.2f units (bankroll: %.2f)",
      row$home_team, row$away_team, row$pred_result, row$real_odds,
      row$bookmaker, row$edge * 100, profit, bankroll
    ))
  } else {
    stake <- 0; profit <- 0
  }

  stakes[i]    <- stake
  returns_v[i] <- profit
  bankrolls[i] <- bankroll
}

match_log <- match_log %>%
  dplyr::mutate(kelly_stake = stakes,
                bet_return  = returns_v,
                bankroll    = bankrolls)

# ── Summary ───────────────────────────────────────────────────────────────────
n     <- nrow(match_log)
acc   <- mean(match_log$correct)
ll    <- mean(match_log$log_loss)
br    <- mean(match_log$brier)
n_bet <- sum(stakes > 0)
roi   <- (tail(bankrolls, 1) - STARTING_BANKROLL) / STARTING_BANKROLL * 100

log_msg(sprintf(
  "WC-2026 live results | n=%d matches | acc=%.1f%% | log-loss=%.3f | Brier=%.3f",
  n, acc * 100, ll, br
))
log_msg(sprintf(
  "Kelly simulation     | %d bets placed | final bankroll=%.2f | sim-ROI=%+.1f%%",
  n_bet, tail(bankrolls, 1), roi
))

# ── Write outputs ─────────────────────────────────────────────────────────────
out_log <- match_log %>%
  dplyr::select(match_id, date, home_team, away_team, home_score, away_score,
                actual_result, pred_result, p_home_win, p_draw, p_away_win,
                p_actual, log_loss, brier, correct,
                bookmaker, real_odds, edge,
                kelly_stake, bet_return, bankroll)

readr::write_csv(out_log, file.path(PATHS$output, "wc2026_match_log.csv"))
log_msg("Saved wc2026_match_log.csv (", nrow(out_log), " rows)")

pnl <- dplyr::bind_rows(
  tibble::tibble(date = min(out_log$date) - 1L, bankroll = STARTING_BANKROLL,
                 n_bets = 0L, cumulative_correct = 0L),
  out_log %>%
    dplyr::arrange(date) %>%
    dplyr::mutate(n_bets             = cumsum(kelly_stake > 0),
                  cumulative_correct = cumsum(correct)) %>%
    dplyr::select(date, bankroll, n_bets, cumulative_correct)
)
readr::write_csv(pnl, file.path(PATHS$output, "financial_benchmark.csv"))
log_msg("Saved financial_benchmark.csv")

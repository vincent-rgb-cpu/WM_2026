# =============================================================================
# 09_live_notify.R  --  Per-game Discord/Slack notifications (pre + post match).
#
# Run every 30 min by .github/workflows/notify.yml during tournament hours.
# Stateless: tight time windows ensure each 30-min run fires at most once per
# game per event type — no state file or dedup database required.
#
# Pre-match  : sent when kick-off is 45 – 75 min away.
# Post-match : sent when the fixture API marks the game finished AND the game
#              clock (kickoff + 95 min) fell in the last 30-min window.
#
# Timezone note: local_date in the fixture JSON is venue local time.  The
# constant VENUE_UTC_OFFSET converts it to UTC (default = -5 = CDT, which
# covers most WC 2026 venues).  Adjust for Pacific venues (PDT = -7).
#
# Required env var:  WEBHOOK_URL
# Optional  env var: VENUE_UTC_OFFSET  (integer; default -5)
#
# Usage:
#   export WEBHOOK_URL=https://discord.com/api/webhooks/...
#   Rscript scripts/09_live_notify.R
# =============================================================================

suppressPackageStartupMessages({
  library(httr)
  library(dplyr)
  library(jsonlite)
  library(lubridate)
  library(readr)
})

# Minimal helpers (no full pipeline load needed)
`%||%` <- function(a, b) if (!is.null(a)) a else b
log_msg <- function(...) message(format(Sys.time(), "[%H:%M:%S]"), " ", ...)

source("R/config.R")        # FILES, PATHS
source("R/team_mapping.R")  # canonical_team()

WEBHOOK_URL <- Sys.getenv("WEBHOOK_URL")
if (nchar(trimws(WEBHOOK_URL)) == 0) {
  log_msg("WEBHOOK_URL is not set — skipping.")
  quit(status = 0)
}

# Timezone offset: local_date → UTC.  CDT = UTC−5 means we ADD 5 hours.
VENUE_UTC_OFFSET <- as.integer(Sys.getenv("VENUE_UTC_OFFSET", unset = "-5"))
PREMATCH_MIN     <- 45L    # }  send pre-match when kick-off is between
PREMATCH_MAX     <- 75L    # }  45 and 75 minutes away (30-min slot)
POSTMATCH_MIN    <- 95L    # }  send post-match when game clock (kickoff + 95)
POSTMATCH_MAX    <- 125L   # }  is 0 – 30 min in the past
MIN_EDGE         <- 0.03

now_utc <- as.POSIXct(Sys.time(), tz = "UTC")
log_msg("Live notify check at ", format(now_utc, "%Y-%m-%d %H:%M UTC"))

# ── Parse fixture JSON ────────────────────────────────────────────────────────
if (!file.exists(FILES$fixtures_raw)) {
  log_msg("No fixture JSON at ", FILES$fixtures_raw, " — skipping.")
  quit(status = 0)
}

raw   <- fromJSON(FILES$fixtures_raw, simplifyVector = FALSE)
games <- raw$games %||% raw

parse_game <- function(g) {
  ht <- trimws(as.character(g$home_team_name_en %||% ""))
  at <- trimws(as.character(g$away_team_name_en %||% ""))
  if (!nzchar(ht) || !nzchar(at)) return(NULL)

  local_dt <- mdy_hm(as.character(g$local_date %||% ""), quiet = TRUE)
  if (is.na(local_dt)) return(NULL)

  # local_date is venue local time; subtract offset (negative) to get UTC
  kickoff_utc <- local_dt - hours(VENUE_UTC_OFFSET)

  data.frame(
    match_id    = as.character(g$id %||% ""),
    home_team   = canonical_team(ht),
    away_team   = canonical_team(at),
    kickoff_utc = kickoff_utc,
    finished    = toupper(as.character(g$finished %||% "FALSE")) == "TRUE",
    home_score  = suppressWarnings(as.integer(g$home_score)),
    away_score  = suppressWarnings(as.integer(g$away_score)),
    stringsAsFactors = FALSE
  )
}

fixtures <- do.call(rbind, Filter(Negate(is.null), lapply(games, parse_game)))
if (is.null(fixtures) || nrow(fixtures) == 0) {
  log_msg("No parseable fixtures — skipping.")
  quit(status = 0)
}

# ── Load supporting data (best-effort; script works without them) ────────────
preds <- tryCatch(
  read_csv(FILES$fixture_preds, show_col_types = FALSE),
  error = function(e) NULL
)
scorelines <- tryCatch(
  read_csv(FILES$scoreline_predictions, show_col_types = FALSE),
  error = function(e) NULL
)
real_odds <- tryCatch(
  read_csv(FILES$real_odds, show_col_types = FALSE),
  error = function(e) NULL
)

# ── Helpers ───────────────────────────────────────────────────────────────────
send_msg <- function(msg) {
  resp <- tryCatch(
    httr::POST(
      url    = WEBHOOK_URL,
      body   = list(content = msg, username = "WM 2026 Bot"),
      encode = "json",
      httr::timeout(15)
    ),
    error = function(e) { log_msg("POST error: ", conditionMessage(e)); NULL }
  )
  if (!is.null(resp) && !httr::http_error(resp)) {
    log_msg("Sent notification (HTTP ", httr::status_code(resp), ")")
  } else if (!is.null(resp)) {
    log_msg("Webhook failed — HTTP ", httr::status_code(resp))
  }
}

pred_row <- function(ht, at) {
  if (is.null(preds)) return(NULL)
  r <- preds %>% filter(home_team == ht, away_team == at)
  if (nrow(r) == 0) NULL else r[1, ]
}

score_str <- function(ht, at) {
  if (is.null(scorelines)) return(NA_character_)
  r <- scorelines %>% filter(Team_A == ht, Team_B == at)
  if (nrow(r) == 0) NA_character_ else sprintf("%d–%d", r$Goals_A[1], r$Goals_B[1])
}

pred_label <- function(pred_result, ht, at) {
  switch(pred_result,
    home_win = paste0(ht, " win"),
    draw     = "Draw",
    away_win = paste0(at, " win"),
    pred_result
  )
}

# ── Check each fixture ────────────────────────────────────────────────────────
notified <- 0L

for (i in seq_len(nrow(fixtures))) {
  f       <- fixtures[i, ]
  mins_to <- as.numeric(difftime(f$kickoff_utc, now_utc, units = "mins"))

  # ── PRE-MATCH ──────────────────────────────────────────────────────────────
  if (!f$finished && mins_to >= PREMATCH_MIN && mins_to <= PREMATCH_MAX) {
    log_msg(sprintf("PRE-MATCH window: %s vs %s (kick-off in %.0f min)",
                    f$home_team, f$away_team, mins_to))

    p <- pred_row(f$home_team, f$away_team)
    sc <- score_str(f$home_team, f$away_team)

    if (!is.null(p)) {
      bet_prob  <- switch(p$pred_result,
        home_win = p$p_home_win, draw = p$p_draw, away_win = p$p_away_win)
      plabel <- pred_label(p$pred_result, f$home_team, f$away_team)

      # Check for value bet
      value_str <- ""
      if (!is.null(real_odds)) {
        or <- real_odds %>% filter(home_team == f$home_team, away_team == f$away_team)
        if (nrow(or) > 0) {
          bet_odds <- switch(p$pred_result,
            home_win = or$home_odds[1], draw = or$draw_odds[1],
            away_win = or$away_odds[1])
          edge <- bet_prob - 1 / bet_odds
          if (!is.na(edge) && edge >= MIN_EDGE)
            value_str <- sprintf(
              "\n\U0001F4B0 **Value Bet: %s @ %.2f (%s) — Edge +%.1f%%**",
              plabel, bet_odds, coalesce(or$bookmaker[1], "market"), edge * 100
            )
        }
      }

      score_part <- if (!is.na(sc)) sprintf(" • Score: **%s**", sc) else ""

      msg <- paste0(
        sprintf("⚽ **WM 2026 — Kick-off in ~%.0f min**\n\n", mins_to),
        sprintf("▶ **%s vs %s**\n", f$home_team, f$away_team),
        sprintf("   Pred: **%s** (%.0f%%)%s%s\n\n",
                plabel, bet_prob * 100, score_part, value_str),
        "_Dashboard: https://vincent-rgb-cpu.github.io/WM_2026/_"
      )
    } else {
      msg <- paste0(
        sprintf("⚽ **WM 2026 — Kick-off in ~%.0f min**\n\n", mins_to),
        sprintf("▶ **%s vs %s**\n\n", f$home_team, f$away_team),
        "_Dashboard: https://vincent-rgb-cpu.github.io/WM_2026/_"
      )
    }

    send_msg(msg)
    notified <- notified + 1L
  }

  # ── POST-MATCH ─────────────────────────────────────────────────────────────
  # Trigger when finished == TRUE and the simulated "game clock" (kickoff + 95)
  # landed in the POSTMATCH window. This catches the result within ~30 min of
  # full time without needing any state file.
  mins_since_end <- -(mins_to) - 95L  # minutes since kickoff+95 (game clock)

  if (f$finished &&
      !is.na(f$home_score) && !is.na(f$away_score) &&
      mins_since_end >= 0L && mins_since_end <= (POSTMATCH_MAX - POSTMATCH_MIN)) {

    log_msg(sprintf("POST-MATCH window: %s vs %s (%d–%d)",
                    f$home_team, f$away_team, f$home_score, f$away_score))

    actual <- if (f$home_score > f$away_score) "home_win" else
              if (f$home_score < f$away_score) "away_win" else "draw"
    p <- pred_row(f$home_team, f$away_team)

    if (!is.null(p)) {
      correct <- p$pred_result == actual
      plabel  <- pred_label(p$pred_result, f$home_team, f$away_team)
      tick    <- if (correct) "✅" else "❌"
      remark  <- if (correct) "← correct!" else "← wrong"

      msg <- paste0(
        sprintf("\U0001F3C1 **WM 2026 — Full time** %s\n\n", tick),
        sprintf("▶ **%s vs %s — %d–%d**\n",
                f$home_team, f$away_team, f$home_score, f$away_score),
        sprintf("   Predicted: **%s** (%.0f%%) %s\n\n",
                plabel,
                switch(p$pred_result,
                  home_win = p$p_home_win, draw = p$p_draw, away_win = p$p_away_win) * 100,
                remark),
        "_Dashboard: https://vincent-rgb-cpu.github.io/WM_2026/_"
      )
    } else {
      msg <- paste0(
        "\U0001F3C1 **WM 2026 — Full time**\n\n",
        sprintf("▶ **%s vs %s — %d–%d**\n\n",
                f$home_team, f$away_team, f$home_score, f$away_score),
        "_Dashboard: https://vincent-rgb-cpu.github.io/WM_2026/_"
      )
    }

    send_msg(msg)
    notified <- notified + 1L
  }
}

log_msg(sprintf("Done — %d notification(s) sent.", notified))

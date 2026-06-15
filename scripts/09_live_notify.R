# =============================================================================
# 09_live_notify.R  --  Per-game Discord/Slack notifications (pre + post match).
#
# Run every 30 min by .github/workflows/notify.yml during tournament hours.
# Uses a state file (output/notification_log.csv) to guarantee exactly one
# notification per game per event type regardless of timezone uncertainty.
#
# Pre-match  : sent once when kick-off is 45 – 75 min away (estimated UTC).
# Post-match : sent once when finished == TRUE, regardless of kick-off time.
#              A 3-hour grace window prevents re-firing stale finished games
#              from days ago if the log is ever reset.
#
# Timezone note: local_date in the fixture JSON is venue local time.  The
# constant VENUE_UTC_OFFSET converts it to UTC (default = -5 = CDT).  The
# pre-match timing depends on this; the post-match does NOT (uses finished flag).
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
VENUE_UTC_OFFSET  <- as.integer(Sys.getenv("VENUE_UTC_OFFSET", unset = "-5"))
PREMATCH_MIN      <- 45L   # send pre-match when kick-off is 45–75 min away
PREMATCH_MAX      <- 75L
POSTMATCH_MAX_AGE <- 180L  # ignore finished games whose kick-off was >3 h ago
MIN_EDGE          <- 0.03

# State file — tracks which notifications have been sent to avoid duplicates.
LOG_FILE <- file.path(PATHS$output, "notification_log.csv")

now_utc <- as.POSIXct(Sys.time(), tz = "UTC")
log_msg("Live notify check at ", format(now_utc, "%Y-%m-%d %H:%M UTC"))

# ── Load / initialise state file ─────────────────────────────────────────────
if (file.exists(LOG_FILE)) {
  notif_log <- tryCatch(
    read_csv(LOG_FILE, show_col_types = FALSE, col_types = "ccc"),
    error = function(e) tibble(match_id = character(), type = character(), sent_at = character())
  )
} else {
  notif_log <- tibble(match_id = character(), type = character(), sent_at = character())
}

already_sent <- function(mid, type) {
  any(notif_log$match_id == mid & notif_log$type == type)
}

record_sent <- function(mid, type) {
  new_row <- tibble(match_id = mid, type = type,
                    sent_at = format(now_utc, "%Y-%m-%d %H:%M:%S"))
  notif_log <<- bind_rows(notif_log, new_row)
}

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
  if (!f$finished && mins_to >= PREMATCH_MIN && mins_to <= PREMATCH_MAX &&
      !already_sent(f$match_id, "prematch")) {
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
    record_sent(f$match_id, "prematch")
    notified <- notified + 1L
  }

  # ── POST-MATCH ─────────────────────────────────────────────────────────────
  # Trigger as soon as finished == TRUE and we haven't notified yet.
  # The 3-hour age cap prevents re-firing very old finished games if the log
  # is ever wiped. Timezone uncertainty doesn't matter here — we rely only on
  # the finished flag, not on kick-off time arithmetic.
  mins_since_kickoff <- -mins_to   # positive = kick-off was in the past

  if (f$finished &&
      !is.na(f$home_score) && !is.na(f$away_score) &&
      mins_since_kickoff <= POSTMATCH_MAX_AGE &&
      !already_sent(f$match_id, "postmatch")) {

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
    record_sent(f$match_id, "postmatch")
    notified <- notified + 1L
  }
}

# ── Persist state file ────────────────────────────────────────────────────────
if (notified > 0L) {
  write_csv(notif_log, LOG_FILE)
  log_msg("State file updated: ", nrow(notif_log), " entries in ", LOG_FILE)
}

log_msg(sprintf("Done — %d notification(s) sent.", notified))

# =============================================================================
# 08_send_notification.R  --  Daily Discord/Slack fixture + value-bet alert.
#
# Sends ONE message per day containing:
#   1. All of today's scheduled fixtures with W/D/L prediction, probability,
#      and most-likely exact scoreline from the Poisson model.
#   2. Value-bet highlights for any match where edge >= MIN_EDGE.
#
# Webhook format: Discord by default (payload key = "content").
#   To use Slack incoming webhooks, change the payload key to "text".
#
# Required env var:  WEBHOOK_URL   (store as a GitHub Actions secret)
# Optional env var:  NOTIFY_SILENT=TRUE  (suppress the message when there are
#                    no fixtures today AND no value bets)
#
# Usage:
#   export WEBHOOK_URL=https://discord.com/api/webhooks/...
#   Rscript scripts/08_send_notification.R
# =============================================================================

source("R/utils.R")
source("R/config.R")     # FILES, PATHS

library(httr)
library(dplyr)
library(readr)
library(lubridate)

WEBHOOK_URL   <- Sys.getenv("WEBHOOK_URL")
NOTIFY_SILENT <- identical(toupper(Sys.getenv("NOTIFY_SILENT")), "TRUE")
MIN_EDGE      <- 0.03

# --- 0. Guard: no webhook configured ----------------------------------------
if (nchar(trimws(WEBHOOK_URL)) == 0) {
  log_msg("WEBHOOK_URL is not set -- skipping notification.")
  log_msg("  Set it with:  export WEBHOOK_URL=<your_webhook_url>")
  quit(status = 0)
}

# --- 1. Load today's fixtures and supporting tables -------------------------
# Use Zurich local date so "today" is correct even when the runner is UTC.
today <- as.Date(now(tz = "Europe/Zurich"))

fixture_preds <- tryCatch(
  read_csv(FILES$fixture_preds, show_col_types = FALSE),
  error = function(e) { log_msg("Could not read fixture predictions: ", conditionMessage(e)); NULL }
)

real_odds <- tryCatch(
  read_csv(FILES$real_odds, show_col_types = FALSE),
  error = function(e) { log_msg("Could not read real odds cache: ", conditionMessage(e)); NULL }
)

scorelines <- tryCatch(
  read_csv(FILES$scoreline_predictions, show_col_types = FALSE),
  error = function(e) NULL
)

if (is.null(fixture_preds)) {
  log_msg("Missing fixture predictions -- skipping notification.")
  quit(status = 0)
}

# --- 2. Filter to today's matches -------------------------------------------
todays_fixtures <- fixture_preds %>%
  filter(as.Date(date) == today)

if (nrow(todays_fixtures) == 0) {
  if (NOTIFY_SILENT) {
    log_msg("No matches scheduled for ", format(today), " -- silent mode, not sending.")
    quit(status = 0)
  }
  log_msg("No matches scheduled for ", format(today), " -- nothing to send.")
  quit(status = 0)
}

log_msg(nrow(todays_fixtures), " fixture(s) today (", format(today), ")")

# --- 3. Join odds and scorelines --------------------------------------------
overview <- todays_fixtures %>%
  # Join real market odds
  left_join(
    if (!is.null(real_odds))
      real_odds %>% select(home_team, away_team, bookmaker,
                           home_odds, draw_odds, away_odds)
    else
      tibble(home_team = character(), away_team = character(),
             bookmaker = character(), home_odds = numeric(),
             draw_odds = numeric(), away_odds = numeric()),
    by = c("home_team", "away_team")
  ) %>%
  # Join Poisson scoreline predictions
  left_join(
    if (!is.null(scorelines))
      scorelines %>%
        rename(home_team = Team_A, away_team = Team_B) %>%
        select(home_team, away_team, Goals_A, Goals_B)
    else
      tibble(home_team = character(), away_team = character(),
             Goals_A = integer(), Goals_B = integer()),
    by = c("home_team", "away_team")
  ) %>%
  mutate(
    bet_prob = case_when(
      pred_result == "home_win" ~ p_home_win,
      pred_result == "draw"     ~ p_draw,
      pred_result == "away_win" ~ p_away_win
    ),
    bet_odds = case_when(
      pred_result == "home_win" ~ home_odds,
      pred_result == "draw"     ~ draw_odds,
      pred_result == "away_win" ~ away_odds
    ),
    edge = bet_prob - 1 / bet_odds,
    pred_label = case_when(
      pred_result == "home_win" ~ paste0(home_team, " win"),
      pred_result == "draw"     ~ "Draw",
      pred_result == "away_win" ~ paste0(away_team, " win")
    )
  )

# --- 4. Format each fixture line --------------------------------------------
# Use R Unicode escapes (\uXXXX) so strings are correctly interpreted as
# Unicode codepoints regardless of the system locale when the file is parsed.
SOCCER  <- "\u26BD"        # \u26BD
ARROW   <- "\u25B6"        # \u25B6
BULLET  <- "\u2022"        # \u2022
MONEY   <- "\U0001F4B0"    # \U0001F4B0

game_lines <- overview %>%
  mutate(
    score_str = ifelse(
      !is.na(Goals_A) & !is.na(Goals_B),
      sprintf("%d-%d", Goals_A, Goals_B),
      "n/a"
    ),
    value_str = ifelse(
      !is.na(edge) & edge >= MIN_EDGE,
      sprintf(
        "\n   %s **Value Bet: %s @ %.2f (%s) - Edge +%.1f%%**",
        MONEY,
        pred_label,
        bet_odds,
        coalesce(bookmaker, "market"),
        edge * 100
      ),
      ""
    ),
    line = sprintf(
      "%s **%s vs %s**\n   Pred: **%s** (%.0f%%) %s Score: **%s**%s",
      ARROW,
      home_team, away_team,
      pred_label, bet_prob * 100,
      BULLET,
      score_str,
      value_str
    )
  ) %>%
  pull(line)

# --- 5. Count value bets ----------------------------------------------------
n_value <- sum(!is.na(overview$edge) & overview$edge >= MIN_EDGE, na.rm = TRUE)
log_msg(n_value, " value bet(s) identified for today.")

# --- 6. Compose message -----------------------------------------------------
header <- sprintf(
  "%s **WM 2026 -- %s** (%d fixture%s today)",
  "\u26BD",
  format(today, "%d %b %Y"),
  nrow(todays_fixtures),
  if (nrow(todays_fixtures) == 1) "" else "s"
)

footer <- sprintf(
  "_Strategy: Quarter-Kelly | Min edge: %g%% | Dashboard: https://vincent-rgb-cpu.github.io/WM_2026/_",
  MIN_EDGE * 100
)

msg <- enc2utf8(paste0(
  header, "\n\n",
  paste(game_lines, collapse = "\n\n"),
  "\n\n", footer
))

# --- 7. Send webhook POST ---------------------------------------------------
resp <- tryCatch(
  httr::POST(
    url  = WEBHOOK_URL,
    body = list(content = msg, username = "WM 2026 Bot"),
    encode = "json",
    httr::timeout(15)
  ),
  error = function(e) {
    log_msg("Webhook POST error: ", conditionMessage(e))
    NULL
  }
)

if (is.null(resp)) quit(status = 1)

status <- httr::status_code(resp)
if (httr::http_error(resp)) {
  log_msg("Webhook POST failed -- HTTP ", status)
  log_msg("  Response: ", httr::content(resp, "text", encoding = "UTF-8"))
  quit(status = 1)
}

log_msg("Notification sent successfully (HTTP ", status, ")")

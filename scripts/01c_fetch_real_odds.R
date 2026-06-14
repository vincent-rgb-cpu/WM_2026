# =============================================================================
# 01c_fetch_real_odds.R  --  Fetch pre-match h2h odds from The Odds API.
#
# Writes data/raw/real_market_odds.csv with columns:
#   home_team, away_team, bookmaker, home_odds, draw_odds, away_odds, fetched_at
#
# Cache strategy: upsert by (home_team, away_team).  Fresh API data overwrites
# known upcoming matches; previously cached rows are retained so we keep
# pre-match closing odds even after a match finishes and leaves the live feed.
# The API is only hit when the cache file is older than ODDS_CACHE_DAYS.
#
# Usage:  ODDS_API_KEY=<key> Rscript scripts/01c_fetch_real_odds.R
# Free key: https://the-odds-api.com  (500 requests / month on the free tier)
# =============================================================================

source("R/utils.R")
source("R/config.R")

suppressPackageStartupMessages({
  library(httr)
  library(jsonlite)
  library(dplyr)
})

ODDS_API_BASE   <- "https://api.the-odds-api.com/v4/sports"
SPORT_KEY       <- "soccer_fifa_world_cup"
ODDS_CACHE_DAYS <- 1L

# Preferred bookmakers in order (Pinnacle = sharpest closing lines).
PREFERRED_BOOKS <- c("pinnacle", "bet365", "williamhill", "unibet",
                     "betfair_ex_eu", "betsson", "nordicbet")

# Map Odds API team names → our canonical names (data_reader.R).
# Only teams where the names differ need an entry; everything else passes through.
ODDS_NAME_MAP <- c(
  "USA"                          = "United States",
  "Turkey"                       = "Turkiye",
  "South Korea"                  = "Korea Republic",
  "Ivory Coast"                  = "Cote d'Ivoire",
  "Czech Republic"               = "Czechia",
  "Bosnia & Herzegovina"         = "Bosnia and Herzegovina",
  "Bosnia-Herzegovina"           = "Bosnia and Herzegovina",
  "Democratic Republic of Congo" = "DR Congo",
  "Republic of Congo"            = "Congo"
)

canonicalize <- function(name) {
  if (!is.character(name) || length(name) != 1L || is.na(name) || !nzchar(name))
    return(as.character(name))
  mapped <- ODDS_NAME_MAP[name]     # [ ] returns named NA when key absent (no error)
  if (is.na(mapped)) name else unname(mapped)
}

# ── Validate API key ──────────────────────────────────────────────────────────
api_key <- Sys.getenv("ODDS_API_KEY")
if (nchar(trimws(api_key)) == 0L) {
  log_msg("ODDS_API_KEY is not set — skipping real odds fetch.")
  log_msg("  Set it with:  export ODDS_API_KEY=<your_key>")
  log_msg("  Free keys at: https://the-odds-api.com")
  log_msg("  The financial benchmark will log missing odds and skip Kelly bets.")
  quit(status = 0)
}

# ── Cache check ───────────────────────────────────────────────────────────────
cache_path <- FILES$real_odds
existing   <- NULL

if (file.exists(cache_path)) {
  age_h <- as.numeric(Sys.time() - file.mtime(cache_path), units = "hours")
  if (age_h < ODDS_CACHE_DAYS * 24) {
    log_msg(sprintf("Odds cache is %.1fh old (TTL = %dd) — skipping API call.",
                    age_h, ODDS_CACHE_DAYS))
    quit(status = 0)
  }
  existing <- tryCatch(
    read.csv(cache_path, stringsAsFactors = FALSE),
    error = function(e) NULL
  )
  log_msg(sprintf("Odds cache is %.1fh old — refreshing from API.", age_h))
} else {
  log_msg("No odds cache found — fetching from The Odds API.")
}

# ── API request ───────────────────────────────────────────────────────────────
url <- sprintf("%s/%s/odds/", ODDS_API_BASE, SPORT_KEY)
log_msg("GET ", url)

resp <- tryCatch(
  httr::GET(url, query = list(
    apiKey     = api_key,
    regions    = "eu",
    markets    = "h2h",
    oddsFormat = "decimal",
    dateFormat = "iso"
  )),
  error = function(e) {
    log_msg("HTTP request failed: ", conditionMessage(e))
    NULL
  }
)

if (is.null(resp)) {
  log_msg("Request failed — retaining existing cache.")
  quit(status = 0)
}

if (httr::status_code(resp) == 422L) {
  log_msg("HTTP 422: sport key '", SPORT_KEY, "' is not currently active.")
  log_msg("  The tournament may not have started yet or has ended.")
  log_msg("  Retaining existing cache (", if (!is.null(existing)) nrow(existing) else 0, " rows).")
  quit(status = 0)
}

if (httr::status_code(resp) != 200L) {
  log_msg(sprintf("API returned HTTP %d — retaining existing cache.", httr::status_code(resp)))
  body <- tryCatch(httr::content(resp, as = "text"), error = function(e) "")
  if (nchar(body) > 0) log_msg("  Response: ", substr(body, 1, 200))
  quit(status = 0)
}

# Log remaining quota so we can monitor free-tier usage.
remaining <- httr::headers(resp)[["x-requests-remaining"]]
used      <- httr::headers(resp)[["x-requests-used"]]
if (!is.null(remaining))
  log_msg(sprintf("API quota: %s used, %s remaining this month.", used, remaining))

raw_text <- httr::content(resp, as = "text", encoding = "UTF-8")
events   <- jsonlite::fromJSON(raw_text, simplifyVector = FALSE)

if (length(events) == 0L) {
  log_msg("API returned 0 events — nothing to cache.")
  quit(status = 0)
}
log_msg(sprintf("Received %d event(s).", length(events)))

# ── Parse events ──────────────────────────────────────────────────────────────
parse_event <- function(ev) {
  home_api <- ev$home_team
  away_api <- ev$away_team
  books    <- ev$bookmakers

  # Skip TBD knockout slots (empty or missing team name)
  if (is.null(home_api) || is.null(away_api) ||
      is.na(home_api)   || is.na(away_api)   ||
      !nzchar(home_api) || !nzchar(away_api)) return(NULL)

  if (length(books) == 0L) return(NULL)

  # Select best available bookmaker in preference order.
  book_keys <- vapply(books, `[[`, character(1), "key")
  preferred_match <- match(PREFERRED_BOOKS, book_keys)
  chosen_idx <- preferred_match[!is.na(preferred_match)][1]
  if (is.na(chosen_idx)) chosen_idx <- 1L
  chosen_book <- books[[chosen_idx]]

  h2h_markets <- Filter(function(m) m$key == "h2h", chosen_book$markets)
  if (length(h2h_markets) == 0L) return(NULL)
  outcomes <- h2h_markets[[1]]$outcomes

  home_odds <- draw_odds <- away_odds <- NA_real_
  for (o in outcomes) {
    if      (o$name == "Draw")    draw_odds <- as.numeric(o$price)
    else if (o$name == home_api)  home_odds <- as.numeric(o$price)
    else if (o$name == away_api)  away_odds <- as.numeric(o$price)
  }

  if (anyNA(c(home_odds, draw_odds, away_odds))) return(NULL)

  data.frame(
    home_team  = canonicalize(home_api),
    away_team  = canonicalize(away_api),
    bookmaker  = chosen_book$title,
    home_odds  = home_odds,
    draw_odds  = draw_odds,
    away_odds  = away_odds,
    fetched_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    stringsAsFactors = FALSE
  )
}

parsed_list <- Filter(Negate(is.null), lapply(events, parse_event))

if (length(parsed_list) == 0L) {
  log_msg("No parseable h2h events — retaining existing cache.")
  quit(status = 0)
}

fresh_df <- dplyr::bind_rows(parsed_list)
log_msg(sprintf("Parsed h2h odds for %d match(es).", nrow(fresh_df)))

# ── Upsert into existing cache ────────────────────────────────────────────────
# Retain old rows for matches no longer in the live feed (already finished).
if (!is.null(existing) && nrow(existing) > 0) {
  key_fresh    <- paste(fresh_df$home_team, fresh_df$away_team)
  key_existing <- paste(existing$home_team, existing$away_team)
  stale_kept   <- existing[!key_existing %in% key_fresh, , drop = FALSE]
  combined     <- dplyr::bind_rows(stale_kept, fresh_df)
  log_msg(sprintf("  Kept %d stale + %d fresh = %d total rows.",
                  nrow(stale_kept), nrow(fresh_df), nrow(combined)))
} else {
  combined <- fresh_df
}

# ── Write cache ───────────────────────────────────────────────────────────────
ensure_dirs()
write.csv(combined, cache_path, row.names = FALSE)
log_msg(sprintf("Saved %s (%d rows).", cache_path, nrow(combined)))

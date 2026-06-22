# =============================================================================
# data_reader.R  --  Read the WC-2026 fixtures / live results from the API.
#
# Responsibility: turn the messy upstream JSON into a clean, typed tibble of
# matches. Nothing here knows about Elo, features or models.
#
# Upstream quirks handled here:
#   * rows live under the top-level `games` key (not the root object)
#   * scores and the `finished` flag arrive as STRINGS ("2", "TRUE")
#   * dates look like "06/11/2026 13:00" (MM/DD/YYYY HH:MM)
#   * knockout fixtures can have empty team names (TBD slots)
#   * `home_scorers` is a malformed embedded string -> ignored entirely
# =============================================================================

suppressPackageStartupMessages({
  library(jsonlite)
  library(dplyr)
  library(lubridate)
})

# Fetch the raw fixtures JSON, caching it to disk. Falls back to the cached
# copy if the network is unavailable.
fetch_fixtures <- function(url = FIXTURES_URL, cache_file = FILES$fixtures_raw,
                           use_cache = TRUE) {
  if (use_cache && file.exists(cache_file)) {
    log_msg("Fixtures: using cached ", cache_file)
    return(fromJSON(cache_file, simplifyVector = FALSE))
  }
  log_msg("Fixtures: downloading from ", url)
  ensure_dirs()
  # Use curl -k to tolerate the server's self-signed / mismatched cert on macOS
  # (LibreSSL rejects it even though OpenSSL on Linux accepts it fine).
  ok <- system2("curl", c("-sf", "-k", "--max-time", "20", "-o", cache_file, url),
                stdout = FALSE, stderr = FALSE) == 0L
  if (ok && file.exists(cache_file)) {
    return(fromJSON(cache_file, simplifyVector = FALSE))
  }
  if (file.exists(cache_file)) {
    log_msg("  download failed, falling back to cache")
    return(fromJSON(cache_file, simplifyVector = FALSE))
  }
  stop("Fixture download failed and no cache file found at ", cache_file)
}

# Parse the raw JSON into a tidy tibble, one row per match.
parse_fixtures <- function(raw) {
  games <- raw$games %||% raw

  # Fail loudly if the API response changes shape rather than silently
  # returning a tibble full of NAs.
  if (length(games) == 0L)
    stop("parse_fixtures: API returned zero games")
  required_keys <- c("id", "local_date", "home_team_name_en",
                     "away_team_name_en", "finished")
  missing_keys <- required_keys[
    !vapply(required_keys, function(k) !is.null(games[[1L]][[k]]), logical(1))
  ]
  if (length(missing_keys) > 0L)
    stop("parse_fixtures: API response missing expected field(s): ",
         paste(missing_keys, collapse = ", "))

  pull <- function(key) vapply(games, function(g) {
    v <- g[[key]]
    if (is.null(v)) NA_character_ else as.character(v)
  }, character(1))

  tibble(
    match_id   = pull("id"),
    kickoff    = mdy_hm(pull("local_date"), quiet = TRUE),
    date       = as_date(kickoff),
    home_team  = canonical_team(pull("home_team_name_en")),
    away_team  = canonical_team(pull("away_team_name_en")),
    home_score = to_num(pull("home_score")),
    away_score = to_num(pull("away_score")),
    finished   = toupper(pull("finished")) == "TRUE",
    stage      = pull("type"),       # group / r32 / r16 / qf / sf / third / final
    group      = pull("group"),
    matchday   = to_num(pull("matchday")),
    # Bracket routing for knockout games (NA for group games), e.g.
    # "Winner Group E", "Runner-up Group A", "3rd Group A/B/C/D/F",
    # "Winner Match 74". These define the official FIFA 2026 bracket.
    home_label = pull("home_team_label"),
    away_label = pull("away_team_label"),
    # WC 2026 co-hosts (USA, Canada, Mexico) play in their own stadiums and
    # receive a home-venue advantage; all other matches are neutral.
    neutral    = !home_team %in% c("United States", "Mexico", "Canada")
  )
}

# Convenience: completed WC-2026 matches with valid scores (Elo/form input).
# Primary condition: API sets finished=TRUE (reliable for previous-day games).
# Fallback: scores exist and are non-zero — catches same-day games where the
# worldcup26.ir API has a flag lag but the scoreline is already populated.
# 0-0 finished games are still caught via the primary condition once the API
# updates; the fallback would only miss them if both conditions fail together.
finished_fixtures <- function(fixtures) {
  fixtures %>%
    filter(
      !is.na(home_score), !is.na(away_score),
      !is.na(home_team),  !is.na(away_team),
      finished | (home_score + away_score) > 0
    )
}

# Convenience: scheduled matches with two known teams (prediction targets).
upcoming_fixtures <- function(fixtures) {
  fixtures %>%
    filter(!finished,
           !is.na(home_team), home_team != "",
           !is.na(away_team), away_team != "")
}

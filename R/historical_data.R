# =============================================================================
# historical_data.R  --  Read the historical international-results dataset.
#
# This is the *training* data: ~45,000 international matches since 1872
# (date, home_team, away_team, scores, tournament, neutral). It shares the
# match schema produced by data_reader.R so the two can be row-bound.
# =============================================================================

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
})

# Download the CSV once and cache it. Re-used on subsequent runs.
download_historical <- function(url = HISTORICAL_URL,
                                cache_file = FILES$historical_raw,
                                use_cache = TRUE) {
  if (use_cache && file.exists(cache_file)) {
    log_msg("Historical: using cached ", cache_file)
    return(cache_file)
  }
  log_msg("Historical: downloading ", url)
  ensure_dirs()
  utils::download.file(url, cache_file, quiet = TRUE, mode = "wb")
  cache_file
}

# Load + clean into the canonical match schema. Result is sorted chronologically
# (required by the sequential Elo / rolling-form computation downstream).
load_historical <- function(cache_file = FILES$historical_raw) {
  raw <- read_csv(cache_file, show_col_types = FALSE, progress = FALSE)

  raw %>%
    transmute(
      match_id   = NA_character_,
      date       = as.Date(date),
      home_team  = canonical_team(home_team),
      away_team  = canonical_team(away_team),
      home_score = to_num(home_score),
      away_score = to_num(away_score),
      finished   = TRUE,
      stage      = tournament,
      group      = NA_character_,
      matchday   = NA_real_,
      neutral    = as.logical(neutral)
    ) %>%
    filter(!is.na(home_score), !is.na(away_score),
           !is.na(home_team), !is.na(away_team)) %>%
    arrange(date)
}

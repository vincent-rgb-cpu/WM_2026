# =============================================================================
# 01b_scrape_market_values.R  --  Fetch squad market values from Transfermarkt.
#
# Writes data/raw/squad_market_values.csv with columns:
#   team (canonical English name), mv_eur (total squad value in EUR)
#
# The cache is skipped when it is younger than MV_CACHE_DAYS days, so
# re-running is cheap. Refresh before each tournament phase.
#
# Usage:  Rscript scripts/01b_scrape_market_values.R
# =============================================================================

source("R/utils.R")
source("R/config.R")

suppressPackageStartupMessages({
  library(rvest)
  library(httr)
  library(dplyr)
})

MV_CACHE_DAYS <- 7L

# Transfermarkt verein IDs for national teams.
# Key  = canonical name used in this pipeline (historical + fixture data).
# Value = TM verein ID (integer as string for safe URL construction).
# Teams missing from this table receive NA in the model (xgboost handles NA).
TM_TEAM_IDS <- c(
  # Europe
  "Germany"               = "3262",
  "England"               = "3299",
  "Portugal"              = "3300",
  "Spain"                 = "3375",
  "Italy"                 = "3376",
  "France"                = "3377",
  "Netherlands"           = "3379",
  "Scotland"              = "3380",
  "Turkey"                = "3381",   # historical data uses "Turkey"
  "Turkiye"               = "3381",   # fixture API may use "Turkiye"
  "Belgium"               = "3382",
  "Austria"               = "3383",
  "Switzerland"           = "3384",
  "Bulgaria"              = "3394",
  "Japan"                 = "3435",
  "Denmark"               = "3436",
  "Argentina"             = "3437",
  "Serbia"                = "3438",
  "Brazil"                = "3439",
  "Norway"                = "3440",
  "Ghana"                 = "3441",
  "Poland"                = "3442",
  "Nigeria"               = "3444",
  "Czech Republic"        = "3445",
  "Czechia"               = "3445",
  "Bosnia and Herzegovina"= "3446",
  "Romania"               = "3447",
  "Uruguay"               = "3449",
  "Venezuela"             = "3504",
  "United States"         = "3505",
  "USA"                   = "3505",
  "Republic of Ireland"   = "3509",
  "Canada"                = "3510",
  "Croatia"               = "3556",
  "Sweden"                = "3557",
  "Iraq"                  = "3560",
  "Albania"               = "3561",
  "Uzbekistan"            = "3563",
  "Iceland"               = "3574",
  "Morocco"               = "3575",
  "Panama"                = "3577",
  "Paraguay"              = "3581",
  "Iran"                  = "3582",
  "South Korea"           = "3589",
  "Ivory Coast"           = "3591",
  "Algeria"               = "3614",
  "Tunisia"               = "3670",
  "Jamaica"               = "3671",
  "Egypt"                 = "3672",
  "Chile"                 = "3700",
  "Ukraine"               = "3699",
  "Hungary"               = "3468",
  "Australia"             = "3433",
  "Senegal"               = "3499",
  "Slovakia"              = "3503",
  "Cameroon"              = "3434",
  "Colombia"              = "3816",
  "Ecuador"               = "5750",
  "Mexico"                = "6303",
  "Wales"                 = "3864"
)

# ── helpers ──────────────────────────────────────────────────────────────────

parse_tm_mv <- function(txt) {
  if (is.na(txt) || !nchar(trimws(txt))) return(NA_real_)
  m <- regmatches(txt, regexpr("[0-9]+[.]?[0-9]*", txt))
  if (!length(m)) return(NA_real_)
  mult <- ifelse(grepl("bn", txt, ignore.case = TRUE), 1e9,
           ifelse(grepl("m",  txt, ignore.case = TRUE), 1e6, 1e3))
  as.numeric(m) * mult
}

fetch_one <- function(verein_id, team_name) {
  ua  <- paste0("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ",
                "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36")
  url <- paste0("https://www.transfermarkt.com/x/startseite/verein/", verein_id)

  r <- tryCatch(
    httr::GET(url,
      httr::add_headers("User-Agent"      = ua,
                        "Accept-Language" = "en-US,en;q=0.9"),
      httr::timeout(15)
    ),
    error = function(e) NULL
  )

  if (is.null(r) || httr::http_error(r)) {
    log_msg("  WARN: HTTP ", if (is.null(r)) "timeout" else httr::status_code(r),
            " for ", team_name)
    return(NA_real_)
  }

  txt <- httr::content(r, "text", encoding = "UTF-8") |>
    read_html() |>
    html_node(".data-header__market-value-wrapper") |>
    html_text(trim = TRUE)

  mv <- parse_tm_mv(txt)
  if (is.na(mv))
    log_msg("  WARN: could not parse MV for ", team_name, " — raw: '", txt, "'")
  mv
}

# ── main ──────────────────────────────────────────────────────────────────────

scrape_market_values <- function() {
  ensure_dirs()

  # De-duplicate the mapping (e.g. Turkey/Turkiye both -> 3381); fetch each
  # TM ID once, then expand back to all canonical names.
  unique_ids  <- unique(TM_TEAM_IDS)
  id_to_names <- lapply(unique_ids, function(id) names(TM_TEAM_IDS)[TM_TEAM_IDS == id])

  log_msg("Fetching squad market values for ", length(unique_ids),
          " TM entries (", length(TM_TEAM_IDS), " team name aliases) ...")

  rows <- vector("list", length(unique_ids))
  for (i in seq_along(unique_ids)) {
    id    <- unique_ids[i]
    nms   <- id_to_names[[i]]
    label <- nms[1]

    Sys.sleep(runif(1, 1.2, 2.2))   # polite rate limiting
    mv <- fetch_one(id, label)

    log_msg(sprintf("  %-28s  %s", label,
                    if (is.na(mv)) "NA" else paste0(round(mv / 1e6, 1), "m EUR")))

    rows[[i]] <- data.frame(team = nms, mv_eur = mv, stringsAsFactors = FALSE)
  }

  df <- do.call(rbind, rows)
  write.csv(df, FILES$market_values, row.names = FALSE)
  log_msg("Saved ", nrow(df), " rows -> ", FILES$market_values)
  invisible(df)
}

scrape_market_values()

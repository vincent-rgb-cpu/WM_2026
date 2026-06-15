# =============================================================================
# team_mapping.R  --  Reconcile team names across data sources.
#
# The fixtures API and the historical dataset mostly agree on English team
# names (47 of 48 WC-2026 teams match verbatim). This map normalises the
# remaining variants so both sources share a single namespace. Keys are the
# "variant" spelling, values the canonical (historical-dataset) spelling.
# The map is idempotent: canonical names pass through unchanged.
# =============================================================================

TEAM_NAME_MAP <- c(
  # The one real WC-2026 mismatch:
  "Democratic Republic of the Congo" = "DR Congo",
  # Common alternate spellings, included defensively in case either upstream
  # source changes its convention. All harmless no-ops today.
  "Korea Republic"                   = "South Korea",
  "Korea DPR"                        = "North Korea",
  "IR Iran"                          = "Iran",
  "China PR"                         = "China",
  "Czechia"                          = "Czech Republic",
  "Cabo Verde"                       = "Cape Verde",
  "Turkiye"                          = "Turkey",
  "Türkiye"                          = "Turkey",
  "USA"                              = "United States",
  "Republic of Ireland"             = "Ireland"
)

# Apply the canonical mapping to a character vector of team names.
canonical_team <- function(x) {
  x <- trimws(x)
  hit <- TEAM_NAME_MAP[x]
  unname(ifelse(is.na(hit), x, unname(hit)))
}

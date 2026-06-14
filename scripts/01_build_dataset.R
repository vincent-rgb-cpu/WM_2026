# =============================================================================
# 01_build_dataset.R  --  Stage 1 of the pipeline: assemble training data.
#
#   historical results  +  finished WC-2026 matches
#        -> Elo + rolling-form features
#        -> data/processed/training_data.rds
#
# Run from the project root:  Rscript scripts/01_build_dataset.R
# =============================================================================

source("R/utils.R")
load_pipeline("R")
ensure_dirs()

# --- 1. Historical training data --------------------------------------------
download_historical()
hist <- load_historical()
log_msg("Historical matches loaded: ", nrow(hist))

# --- 2. Finished WC-2026 matches (so ratings reflect the latest games) -------
fixtures     <- parse_fixtures(fetch_fixtures())
wc_finished  <- finished_fixtures(fixtures)
log_msg("Finished WC-2026 matches: ", nrow(wc_finished))

# --- 3. Combine + build features --------------------------------------------
all_matches <- bind_rows(hist, wc_finished) %>% arrange(date)
built       <- build_features(all_matches)

# Keep only recent matches as ML training rows (Elo/form already warmed up).
training <- built$data %>% filter(date >= TRAIN_START)
log_msg("Training rows (>= ", format(TRAIN_START), "): ", nrow(training))

# --- 4. Current team state, for predicting upcoming fixtures ------------------
team_form <- current_team_form(all_matches)

saveRDS(
  list(training = training, ratings = built$ratings, team_form = team_form,
       fixtures = fixtures),
  FILES$training_data
)
log_msg("Saved ", FILES$training_data)

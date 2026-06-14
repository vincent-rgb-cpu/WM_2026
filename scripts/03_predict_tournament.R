# =============================================================================
# 03_predict_tournament.R  --  Stage 3: predict WC-2026.
#
#   result_model.rds + current team state
#        -> per-fixture W/D/L probabilities      -> fixture_predictions.csv
#        -> Monte-Carlo group-stage advancement  -> group_stage_simulation.csv
#
# Run from the project root:  Rscript scripts/03_predict_tournament.R
# =============================================================================

source("R/utils.R")
load_pipeline("R")
ensure_dirs()
set.seed(GLOBAL_SEED)

bundle <- readRDS(FILES$training_data)
model  <- load_model()

# --- 1. Per-fixture predictions for every scheduled, known-team match --------
upcoming <- upcoming_fixtures(bundle$fixtures)
preds    <- predict_fixtures(model, upcoming, bundle$ratings, bundle$team_form,
                             fast_ratings = bundle$fast_ratings %||% list())
log_msg("Predicted ", nrow(preds), " upcoming fixtures")

readr::write_csv(preds, FILES$fixture_preds)
log_msg("Saved ", FILES$fixture_preds)

cat("\n--- Sample fixture predictions ---\n")
print(utils::head(as.data.frame(preds %>%
        dplyr::select(group, home_team, away_team,
                      p_home_win, p_draw, p_away_win, pred_result)), 10),
      digits = 3, row.names = FALSE)

# --- 2. Monte-Carlo group-stage simulation -----------------------------------
group_preds <- preds %>% dplyr::filter(stage == "group", !is.na(group))
if (nrow(group_preds) > 0) {
  sim <- simulate_group_stage(group_preds)
  readr::write_csv(sim, FILES$group_sim)
  log_msg("Saved ", FILES$group_sim)

  cat("\n--- Top 15 teams by simulated advancement probability ---\n")
  print(utils::head(as.data.frame(sim), 15), digits = 3, row.names = FALSE)
} else {
  log_msg("No group-stage fixtures with predictions yet; skipping simulation.")
}

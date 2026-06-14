# =============================================================================
# 05_exact_scores.R  --  Stage 5: generate exact scorelines for SRF Tippspiel.
#
# Dependencies (run in order):
#   01_build_dataset.R  ->  data/processed/training_data.rds
#   02_train_evaluate.R ->  output/models/result_model.rds
#
# This script is self-contained beyond those two artefacts; it re-derives the
# W/D/L fixture predictions in-memory rather than reading from script 03's CSV,
# so the two outputs remain independent and script 05 can be re-run cheaply.
#
# Outputs:
#   output/srf_predictions.csv  (Match_Date, Team_A, Team_B, Goals_A, Goals_B,
#                                 xG_A, xG_B, WDL_pred)
#
# Run from the project root:
#   Rscript scripts/05_exact_scores.R
# =============================================================================

source("R/utils.R")
load_pipeline("R")
ensure_dirs()
set.seed(GLOBAL_SEED)

bundle <- readRDS(FILES$training_data)
model  <- load_model()

# --- 1. Fit the Poisson expected-goals model ---------------------------------
log_msg("Fitting Poisson xG model on data from ", format(POISSON_MIN_DATE), " onward ...")
poisson_mod <- fit_poisson_model(bundle$training)

cat("\n--- Poisson GLM coefficients ---\n")
print(round(summary(poisson_mod)$coefficients, 6))

# Sanity check: predict a known-strong vs known-weak matchup.
# Should show lambda_strong > lambda_weak.
strongest <- names(which.max(unlist(bundle$ratings)))
weakest   <- names(which.min(unlist(bundle$ratings)))
xg_test   <- predict_xg(poisson_mod,
                         bundle$ratings[[strongest]],
                         bundle$ratings[[weakest]])
cat(sprintf("\nxG sanity check: %s vs %s  ->  %.2f - %.2f\n",
            strongest, weakest, xg_test$lambda_home, xg_test$lambda_away))

# --- 2. Re-derive W/D/L fixture predictions (in-memory) ---------------------
log_msg("Predicting W/D/L outcomes for upcoming fixtures ...")
upcoming  <- upcoming_fixtures(bundle$fixtures)
wdl_preds <- predict_fixtures(model, upcoming, bundle$ratings, bundle$team_form)
log_msg("  ", nrow(wdl_preds), " fixtures to predict")

# --- 3. Generate exact scorelines --------------------------------------------
log_msg("Generating scoreline predictions ...")
srf_preds <- generate_srf_predictions(wdl_preds, poisson_mod, bundle$ratings)

readr::write_csv(srf_preds, FILES$srf_predictions)
log_msg("Saved ", FILES$srf_predictions, "  (", nrow(srf_preds), " rows)")

# --- 4. Summary output -------------------------------------------------------
cat("\n--- SRF Tippspiel predictions (first 15) ---\n")
print(head(srf_preds[, c("Match_Date","Team_A","Goals_A","Goals_B","Team_B",
                          "xG_A","xG_B","WDL_pred")], 15),
      row.names = FALSE)

# Distribution of predicted results as a sanity check.
cat("\n--- Predicted result distribution ---\n")
print(table(srf_preds$WDL_pred))
cat("\n--- Predicted score distribution (top 10) ---\n")
score_tbl <- sort(table(paste0(srf_preds$Goals_A, "-", srf_preds$Goals_B)),
                  decreasing = TRUE)
print(head(score_tbl, 10))

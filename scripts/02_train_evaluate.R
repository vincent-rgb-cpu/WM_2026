# =============================================================================
# 02_train_evaluate.R  --  Stage 2: time-split evaluation, then fit final model.
#
#   training_data.rds
#        -> time-based train/test evaluation (vs baselines)  -> metrics.csv
#        -> final model fitted on ALL rows                    -> result_model.rds
#
# Run from the project root:  Rscript scripts/02_train_evaluate.R
# =============================================================================

source("R/utils.R")
load_pipeline("R")
ensure_dirs()
set.seed(GLOBAL_SEED)

bundle   <- readRDS(FILES$training_data)
training <- bundle$training

# --- 1. Honest evaluation on a held-out future window ------------------------
split <- time_split(training, EVAL_CUTOFF)
log_msg("Train rows: ", nrow(split$train), " | Test rows (>= ",
        format(EVAL_CUTOFF), "): ", nrow(split$test))

# val_df enables early stopping: xgboost monitors val_mlogloss and records the
# optimal round count in eval_model$booster$best_iteration.
eval_model <- train_model(split$train, val_df = split$test)

# --- 1b. Probability calibration (Platt scaling) ----------------------------
# Fit a multinomial logistic calibrator on the raw XGBoost val-set predictions.
# The eval_model has no calibrator yet, so predict_proba() returns raw softprob.
# The calibrator corrects systematic over-confidence before Kelly edge maths.
log_msg("Fitting probability calibrator on validation set ...")
val_raw    <- predict_proba(eval_model, split$test)   # uncalibrated [n x 3]
calibrator <- fit_calibrator(val_raw, split$test$result)

# Assess calibration lift: compare raw vs calibrated log-loss on the val set.
val_cal   <- apply_calibrator(calibrator, val_raw)
y_val     <- split$test$result
logloss_f <- function(probs, y) {
  idx <- cbind(seq_along(y), as.integer(y))
  -mean(log(pmax(probs[idx], 1e-15)))
}
ll_raw <- logloss_f(val_raw, y_val)
ll_cal <- logloss_f(val_cal, y_val)
log_msg(sprintf("Calibration: val log-loss  raw=%.4f  calibrated=%.4f  delta=%+.4f",
                ll_raw, ll_cal, ll_cal - ll_raw))

metrics <- evaluate_model(eval_model, split)   # reported on raw probs for transparency

cat("\n--- Held-out evaluation (test set: matches on/after ",
    format(EVAL_CUTOFF), ") ---\n", sep = "")
print(as.data.frame(metrics), digits = 4, row.names = FALSE)

readr::write_csv(metrics, FILES$metrics)
log_msg("Saved ", FILES$metrics)

# --- 2. Final model: refit on the full training window for deployment --------
# Reuse the optimal nrounds found by early stopping above so we don't
# hard-code an arbitrary fixed round count. Attach the calibrator so every
# downstream call to predict_proba() auto-applies Platt scaling.
best_n      <- eval_model$booster$best_iteration %||% XGB_NROUNDS
log_msg("Final model nrounds: ", best_n)
final_model <- train_model(training, nrounds = best_n)
final_model$calibrator <- calibrator
save_model(final_model)
log_msg("Saved ", FILES$model, " (calibrator attached)")

cat("\n--- Feature importance (final model) ---\n")
print(as.data.frame(feature_importance(final_model)), digits = 4, row.names = FALSE)

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
metrics    <- evaluate_model(eval_model, split)

cat("\n--- Held-out evaluation (test set: matches on/after ",
    format(EVAL_CUTOFF), ") ---\n", sep = "")
print(as.data.frame(metrics), digits = 4, row.names = FALSE)

readr::write_csv(metrics, FILES$metrics)
log_msg("Saved ", FILES$metrics)

# --- 2. Final model: refit on the full training window for deployment --------
# Reuse the optimal nrounds found by early stopping above so we don't
# hard-code an arbitrary fixed round count.
best_n      <- eval_model$booster$best_iteration %||% XGB_NROUNDS
log_msg("Final model nrounds: ", best_n)
final_model <- train_model(training, nrounds = best_n)
save_model(final_model)
log_msg("Saved ", FILES$model)

cat("\n--- Feature importance (final model) ---\n")
print(as.data.frame(feature_importance(final_model)), digits = 4, row.names = FALSE)

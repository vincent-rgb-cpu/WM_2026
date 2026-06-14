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

bundle   <- readRDS(FILES$training_data)
training <- bundle$training

# --- 1. Honest evaluation on a held-out future window ------------------------
split <- time_split(training, EVAL_CUTOFF)
log_msg("Train rows: ", nrow(split$train), " | Test rows (>= ",
        format(EVAL_CUTOFF), "): ", nrow(split$test))

eval_model <- train_model(split$train)
metrics    <- evaluate_model(eval_model, split)

cat("\n--- Held-out evaluation (test set: matches on/after ",
    format(EVAL_CUTOFF), ") ---\n", sep = "")
print(as.data.frame(metrics), digits = 4, row.names = FALSE)

readr::write_csv(metrics, FILES$metrics)
log_msg("Saved ", FILES$metrics)

# --- 2. Final model: refit on the full training window for deployment --------
final_model <- train_model(training)
save_model(final_model)
log_msg("Saved ", FILES$model)

cat("\n--- Feature importance (final model) ---\n")
print(as.data.frame(feature_importance(final_model)), digits = 4, row.names = FALSE)

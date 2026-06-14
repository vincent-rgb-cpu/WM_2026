# =============================================================================
# 07_tune_hyperparameters.R  --  Random search for XGBoost hyperparameters.
#
# Motivation: the fast-Elo momentum features (range ±470 Elo pts) can dominate
# splits and cause overfitting if the model is too deep or too permissive.
# This script finds the regularisation configuration with the lowest held-out
# mlogloss on the same time-split used for evaluation (EVAL_CUTOFF).
#
# Strategy: random search over N_TRIALS parameter combinations. Each trial
# trains for TUNE_ROUNDS rounds on the train split and evaluates val mlogloss
# via manual prediction (xgboost 3.x dropped the in-booster eval log slot).
#
# Outputs:
#   output/tuning_results.csv  -- all trials sorted by val_mlogloss
#
# Usage:
#   Rscript scripts/07_tune_hyperparameters.R          # default 60 trials
#   Rscript scripts/07_tune_hyperparameters.R 120      # more trials
#
# After running, copy the best row's parameters into XGB_PARAMS in R/config.R
# and set XGB_NROUNDS = best_rounds.
# =============================================================================

source("R/utils.R")
load_pipeline("R")
ensure_dirs()

args        <- commandArgs(trailingOnly = TRUE)
N_TRIALS    <- if (length(args) >= 1 && !is.na(as.integer(args[1]))) as.integer(args[1]) else 60L
TUNE_ROUNDS <- 300L   # fixed rounds per trial; enough to see model plateau

bundle   <- readRDS(FILES$training_data)
training <- bundle$training
split    <- time_split(training, EVAL_CUTOFF)

log_msg("Random hyperparameter search | N_TRIALS = ", N_TRIALS,
        " | TUNE_ROUNDS = ", TUNE_ROUNDS)
log_msg("Train: ", nrow(split$train), " rows | Val: ", nrow(split$test),
        " rows (>= ", format(EVAL_CUTOFF), ")")

dtrain  <- .make_dmatrix(split$train)
dval    <- .make_dmatrix(split$test)
y_val   <- xgboost::getinfo(dval, "label")   # 0-based class indices
n_val   <- length(y_val)
n_class <- length(RESULT_LEVELS)

# Multiclass log-loss: mean of -log(p_correct_class).
# xgboost >= 3.x returns a matrix directly; older versions return a flat vector.
mlogloss <- function(pred) {
  probs <- if (is.matrix(pred)) pred else matrix(pred, ncol = n_class, byrow = TRUE)
  p_correct <- probs[cbind(seq_len(n_val), y_val + 1L)]
  -mean(log(pmax(p_correct, 1e-7)))
}

# --- Search space ------------------------------------------------------------
# Focused on the parameters most likely to overfit with noisy momentum features.
SEARCH_SPACE <- list(
  eta              = c(0.02, 0.04, 0.06, 0.08, 0.10, 0.12),
  max_depth        = c(3L, 4L, 5L, 6L),
  min_child_weight = c(3L, 5L, 10L, 15L, 25L),
  subsample        = c(0.70, 0.80, 0.85, 0.90, 1.00),
  colsample_bytree = c(0.65, 0.75, 0.85, 0.90, 1.00),
  gamma            = c(0, 0.05, 0.10, 0.20, 0.30)
)

set.seed(GLOBAL_SEED)
trials <- as.data.frame(
  lapply(SEARCH_SPACE, function(vals) sample(vals, N_TRIALS, replace = TRUE))
)

# --- Run trials --------------------------------------------------------------
results <- vector("list", N_TRIALS)
best_so_far <- Inf

for (i in seq_len(N_TRIALS)) {
  p <- as.list(trials[i, ])
  p$objective   <- "multi:softprob"
  p$num_class   <- n_class
  p$eval_metric <- "mlogloss"

  booster <- xgboost::xgb.train(
    params  = p,
    data    = dtrain,
    nrounds = TUNE_ROUNDS,
    verbose = 0
  )

  score <- mlogloss(predict(booster, dval))
  if (score < best_so_far) best_so_far <- score

  results[[i]] <- data.frame(
    trial        = i,
    trials[i, ],
    rounds       = TUNE_ROUNDS,
    val_mlogloss = round(score, 6),
    stringsAsFactors = FALSE
  )

  if (i %% 10 == 0 || i == N_TRIALS)
    log_msg(sprintf("  [%d/%d] this=%.5f | best=%.5f", i, N_TRIALS, score, best_so_far))
}

# --- Report ------------------------------------------------------------------
res_df <- do.call(rbind, results)
res_df <- res_df[order(res_df$val_mlogloss), ]

cat("\n--- Top 10 configurations (sorted by val_mlogloss) ---\n")
print(head(res_df, 10), row.names = FALSE, digits = 5)

readr::write_csv(res_df, file.path(PATHS$output, "tuning_results.csv"))
log_msg("Saved output/tuning_results.csv")

# Current baseline for comparison
base_params <- as.list(XGB_PARAMS)
base_params$num_class <- n_class   # ensure present; XGB_PARAMS already has it
base_booster <- xgboost::xgb.train(
  params  = base_params,
  data    = dtrain,
  nrounds = XGB_NROUNDS,
  verbose = 0
)
baseline_score <- mlogloss(predict(base_booster, dval))

best <- res_df[1, ]
cat(sprintf("\n--- Baseline config (current R/config.R)  mlogloss = %.5f ---\n", baseline_score))
cat(sprintf("--- Best found config                      mlogloss = %.5f (+%.3f%%)\n\n",
            best$val_mlogloss,
            (baseline_score - best$val_mlogloss) / baseline_score * 100))
cat("Paste into R/config.R → XGB_PARAMS:\n\n")
cat(sprintf("XGB_PARAMS <- list(\n"))
cat(sprintf("  objective        = \"multi:softprob\",\n"))
cat(sprintf("  num_class        = length(RESULT_LEVELS),\n"))
cat(sprintf("  eval_metric      = \"mlogloss\",\n"))
cat(sprintf("  eta              = %.2f,\n",  best$eta))
cat(sprintf("  max_depth        = %d,\n",    best$max_depth))
cat(sprintf("  subsample        = %.2f,\n",  best$subsample))
cat(sprintf("  colsample_bytree = %.2f,\n",  best$colsample_bytree))
cat(sprintf("  min_child_weight = %d,\n",    best$min_child_weight))
cat(sprintf("  gamma            = %.2f\n",   best$gamma))
cat(")\n")
cat(sprintf("XGB_NROUNDS <- %dL\n", best$rounds))

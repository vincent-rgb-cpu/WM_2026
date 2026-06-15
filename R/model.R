# =============================================================================
# model.R  --  Train and apply the match-result model.
#
# The model is a gradient-boosted multiclass classifier (xgboost) over the
# features from features.R, predicting P(home_win), P(draw), P(away_win).
# Training rows are recency-weighted (see RECENCY_DECAY). xgboost handles the
# occasional missing form value natively, so no imputation is required.
# =============================================================================

suppressPackageStartupMessages({
  library(xgboost)
  library(dplyr)
  library(nnet)   # multinom — base R recommended package, always available
})

# Build the xgboost DMatrix from a feature frame. `label` is optional so the
# same helper serves both training and prediction.
.make_dmatrix <- function(df, with_label = TRUE) {
  X <- as.matrix(df[, FEATURE_COLS])
  if (!with_label) return(xgb.DMatrix(X, missing = NA))
  y <- as.integer(df$result) - 1L                      # 0-based for xgboost
  w <- df$sample_weight %||% rep(1, nrow(df))
  xgb.DMatrix(X, label = y, weight = w, missing = NA)
}

# Train the result model. Returns a small bundle carrying everything needed to
# predict later (booster + the feature order + class levels).
#
# When val_df is supplied, early stopping monitors val_mlogloss and halts after
# XGB_EARLY_STOPPING_ROUNDS rounds without improvement. booster$best_iteration
# records the optimal round count so the caller can reuse it for the final model.
train_model <- function(train_df, val_df = NULL,
                        params = XGB_PARAMS, nrounds = XGB_NROUNDS) {
  dtrain    <- .make_dmatrix(train_df, with_label = TRUE)
  watchlist <- list(train = dtrain)
  early     <- NULL

  if (!is.null(val_df)) {
    watchlist$val <- .make_dmatrix(val_df, with_label = TRUE)
    early         <- XGB_EARLY_STOPPING_ROUNDS
  }

  booster <- xgb.train(
    params                = params,
    data                  = dtrain,
    nrounds               = nrounds,
    evals                 = watchlist,
    early_stopping_rounds = early,
    verbose               = 0
  )

  if (!is.null(early)) {
    best_iter <- booster$best_iteration
    if (is.null(best_iter)) {
      log_msg("Early stopping: no plateau in ", nrounds, " rounds (model still improving)")
    } else {
      # best_score slot name varies by xgboost version; fall back to eval_log
      best_score <- tryCatch(
        round(as.numeric(booster$best_score), 4),
        error = function(e) {
          log <- booster$evaluation_log
          if (!is.null(log) && "val_mlogloss" %in% names(log))
            round(log$val_mlogloss[best_iter], 4)
          else NA_real_
        }
      )
      log_msg("Early stopping: best round = ", best_iter,
              " (val_mlogloss = ", best_score, ")")
    }
  }

  structure(
    list(booster = booster, features = FEATURE_COLS, levels = RESULT_LEVELS),
    class = "wm_model"
  )
}

# Predict a calibrated probability matrix (rows = matches, cols = RESULT_LEVELS).
# Pipeline:
#   1. XGBoost raw softprob  →  [n × 3] matrix
#   2. apply_calibrator()    →  Platt-scaled probabilities (pass-through if NULL)
# Modern xgboost returns a matrix directly; older versions return a flat vector.
predict_proba <- function(model, newdf) {
  d <- .make_dmatrix(newdf, with_label = FALSE)
  p <- predict(model$booster, d)
  m <- if (is.matrix(p)) p else matrix(p, ncol = length(model$levels), byrow = TRUE)
  colnames(m) <- model$levels
  apply_calibrator(model$calibrator, m)
}

# --- Probability calibration (Platt scaling, multiclass) ---------------------
# Fit a multinomial logistic regression on the raw XGBoost probability outputs
# to correct systematic over- or under-confidence before edge calculations.
#
# Design:
#   * Input: two of the three XGBoost probabilities (p_draw, p_away_win).
#     p_home_win is omitted — the three sum to 1, so including all three
#     creates perfect collinearity and makes multinom ill-conditioned.
#   * Reference level: "home_win" (the first level of RESULT_LEVELS).
#   * Fit on the VALIDATION set predictions so the calibrator never sees the
#     same rows that trained the booster.
#
# Usage:
#   calibrator <- fit_calibrator(val_raw_probs, val_true_labels)
#   final_model$calibrator <- calibrator   # attach; predict_proba auto-applies
fit_calibrator <- function(raw_probs, true_labels) {
  colnames(raw_probs) <- RESULT_LEVELS
  df   <- as.data.frame(raw_probs)
  df$y <- factor(true_labels, levels = RESULT_LEVELS)
  suppressWarnings(
    nnet::multinom(y ~ draw + away_win,   # column names come from RESULT_LEVELS
                   data = df, trace = FALSE, maxit = 500)
  )
}

# Apply a fitted calibrator to a raw probability matrix.
# Returns the calibrated [n × 3] matrix in RESULT_LEVELS column order.
# Pass-through (returns raw_probs unchanged) when calibrator is NULL so the
# function is safe to call on models that pre-date calibration support.
apply_calibrator <- function(calibrator, raw_probs) {
  if (is.null(calibrator)) return(raw_probs)
  colnames(raw_probs) <- RESULT_LEVELS
  df  <- as.data.frame(raw_probs)
  cal <- predict(calibrator, newdata = df, type = "probs")
  # nnet returns a named vector for n=1, a matrix/data.frame otherwise.
  if (is.vector(cal))
    cal <- matrix(cal, nrow = 1L, dimnames = list(NULL, names(cal)))
  cal <- as.matrix(cal)
  cal[, RESULT_LEVELS, drop = FALSE]
}

# Relative feature importance, handy for the README / sanity checks.
feature_importance <- function(model) {
  xgboost::xgb.importance(feature_names = model$features, model = model$booster)
}

save_model <- function(model, path = FILES$model) {
  ensure_dirs()
  saveRDS(model, path)
  invisible(path)
}

load_model <- function(path = FILES$model) readRDS(path)

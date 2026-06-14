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
    watchlist             = watchlist,
    early_stopping_rounds = early,
    verbose               = 0
  )

  if (!is.null(early)) {
    log_msg("Early stopping: best round = ", booster$best_iteration,
            " (val_mlogloss = ",
            round(booster$best_score, 4), ")")
  }

  structure(
    list(booster = booster, features = FEATURE_COLS, levels = RESULT_LEVELS),
    class = "wm_model"
  )
}

# Predict a probability matrix (rows = matches, cols = RESULT_LEVELS).
# Modern xgboost returns an [n x num_class] matrix for multi:softprob; older
# versions return a flat row-major vector. Handle both.
predict_proba <- function(model, newdf) {
  d <- .make_dmatrix(newdf, with_label = FALSE)
  p <- predict(model$booster, d)
  m <- if (is.matrix(p)) p else matrix(p, ncol = length(model$levels), byrow = TRUE)
  colnames(m) <- model$levels
  m
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

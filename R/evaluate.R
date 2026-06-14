# =============================================================================
# evaluate.R  --  Honest, time-aware model evaluation.
#
# Football results are a time series, so we never use random cross-validation.
# Instead we split on a calendar cut-off (train on the past, test on the
# future) and score the held-out set with proper scoring rules:
#   * accuracy        - fraction of correct argmax predictions
#   * log-loss        - multiclass cross-entropy (lower is better)
#   * Brier score     - mean squared error of the probability vector
# Two naive baselines (majority class, class priors) are reported alongside so
# the model's lift is obvious.
# =============================================================================

suppressPackageStartupMessages(library(dplyr))

# Chronological split: rows before `cutoff` train, rows on/after test.
time_split <- function(df, cutoff = EVAL_CUTOFF) {
  list(train = df %>% filter(date <  cutoff),
       test  = df %>% filter(date >= cutoff))
}

# --- Scoring rules (y is the result factor; proba columns match RESULT_LEVELS)
accuracy <- function(y, proba) {
  mean(max.col(proba, ties.method = "first") == as.integer(y))
}

logloss <- function(y, proba, eps = 1e-15) {
  idx <- cbind(seq_along(y), as.integer(y))
  p   <- pmax(pmin(proba[idx], 1 - eps), eps)
  -mean(log(p))
}

brier <- function(y, proba) {
  oh <- matrix(0, nrow = length(y), ncol = ncol(proba))
  oh[cbind(seq_along(y), as.integer(y))] <- 1
  mean(rowSums((proba - oh) ^ 2))
}

# One tidy row of metrics for a named predictor.
.metric_row <- function(name, y, proba) {
  tibble(model = name,
         accuracy = accuracy(y, proba),
         log_loss = logloss(y, proba),
         brier    = brier(y, proba))
}

# Evaluate the trained model plus two baselines on the test set.
#   * "majority class" -> always predicts the most common training outcome
#   * "class priors"   -> predicts the training class frequencies every match
evaluate_model <- function(model, split) {
  test  <- split$test
  proba <- predict_proba(model, test)
  y     <- test$result

  priors <- as.numeric(prop.table(table(factor(split$train$result,
                                               levels = RESULT_LEVELS))))
  prior_mat <- matrix(priors, nrow = nrow(test), ncol = length(priors),
                      byrow = TRUE)
  maj_mat <- matrix(0, nrow = nrow(test), ncol = length(RESULT_LEVELS))
  maj_mat[, which.max(priors)] <- 1

  bind_rows(
    .metric_row("xgboost", y, proba),
    .metric_row("baseline: class priors", y, prior_mat),
    .metric_row("baseline: majority class", y, maj_mat)
  )
}

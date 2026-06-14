# =============================================================================
# config.R  --  Central configuration for the WM 2026 prediction pipeline.
#
# All tunable constants, data-source URLs and on-disk paths live here so the
# rest of the code never hard-codes a magic number. Pure values only: this
# file must not call any helper that is defined in another module.
# =============================================================================

# --- On-disk layout (paths are relative to the project root) -----------------
PATHS <- list(
  data_raw       = "data/raw",
  data_processed = "data/processed",
  output         = "output",
  models         = "output/models"
)

# Cached / produced artefacts
FILES <- list(
  fixtures_raw    = file.path(PATHS$data_raw, "wc2026_fixtures.json"),
  historical_raw  = file.path(PATHS$data_raw, "international_results.csv"),
  training_data   = file.path(PATHS$data_processed, "training_data.rds"),
  model           = file.path(PATHS$models, "result_model.rds"),
  metrics         = file.path(PATHS$output, "evaluation_metrics.csv"),
  fixture_preds   = file.path(PATHS$output, "fixture_predictions.csv"),
  group_sim       = file.path(PATHS$output, "group_stage_simulation.csv"),
  tournament_prob = file.path(PATHS$output, "tournament_probabilities.csv"),
  srf_predictions = file.path(PATHS$output, "srf_predictions.csv"),
  market_values   = file.path(PATHS$data_raw, "squad_market_values.csv")
)

# --- Data sources ------------------------------------------------------------
# WC 2026 fixtures + live results (JSON).
FIXTURES_URL <- "https://worldcup26.ir/get/games"

# Historical international results, 1872-present (martj42 mirror of the
# well-known Kaggle dataset). Public, no authentication required.
HISTORICAL_URL <-
  "https://raw.githubusercontent.com/martj42/international_results/master/results.csv"

# --- Modelling constants -----------------------------------------------------
# Outcome classes, in a fixed order used everywhere (probability columns,
# label encoding, evaluation). Always from the HOME team's perspective.
RESULT_LEVELS <- c("home_win", "draw", "away_win")

# Elo rating parameters (World-Football-Elo style).
ELO_PARAMS <- list(
  init_rating    = 1500,  # rating every team starts with
  k              = 20,    # update step size
  home_advantage = 65     # rating points added to the home side (0 if neutral)
)

# Rolling-form window: number of most recent matches used for form features.
FORM_WINDOW <- 5L

# Only matches on/after this date are used as ML *training rows*. Elo and form
# are still warmed up on the full history before this cut-off.
TRAIN_START <- as.Date("2006-01-01")

# Time-based train/test split: matches before the cut-off train the model,
# matches on/after it are the held-out test set.
EVAL_CUTOFF <- as.Date("2021-01-01")

# Recency weighting for training rows: weight = exp(-decay * days_before_latest).
# ~0.00050/day => ~3.8-year half-life, so recent form counts more than 2008.
RECENCY_DECAY <- 0.00050

# xgboost hyper-parameters for the multiclass result model.
XGB_PARAMS <- list(
  objective        = "multi:softprob",
  num_class        = length(RESULT_LEVELS),
  eval_metric      = "mlogloss",
  eta              = 0.08,
  max_depth        = 4,
  subsample        = 0.85,
  colsample_bytree = 0.85,
  min_child_weight = 5
)
XGB_NROUNDS <- 250L

# Feature columns fed to the model (order matters; reused at predict time).
# elo_diff (= elo_home_pre - elo_away_pre) is deliberately excluded: it is a
# deterministic linear combination of the two raw ratings already present, so
# it wastes tree splits and pollutes feature-importance scores.
FEATURE_COLS <- c(
  "elo_home_pre", "elo_away_pre", "home_adv",
  "form_pts_diff", "form_gf_diff", "form_ga_diff", "rest_diff",
  "log_mv_home", "log_mv_away"
)

# Minimum match date used to train the Poisson goals model. A tighter window
# than the XGBoost TRAIN_START keeps the xG estimates focused on how teams
# currently score/concede rather than their historical averages.
POISSON_MIN_DATE <- as.Date("2010-01-01")

# Maximum scoreline modelled by the Poisson matrix (0..MAX_GOALS per side).
# A 6x6 grid (0-5) covers >99% of all international match scorelines.
MAX_GOALS <- 5L

# Global random seed used by all scripts for reproducibility.
GLOBAL_SEED <- 42L

# Monte-Carlo group-stage simulation (the quick group-only sim in script 03).
SIM_N        <- 2000L
SIM_SEED     <- GLOBAL_SEED
N_THIRDS_ADV <- 8L   # best 3rd-placed teams that advance (WC 2026 format)

# Full tournament Monte-Carlo (script 04: groups -> knockout -> final).
TOURNAMENT_SIM_N <- 10000L

# xgboost early stopping: halt training if val mlogloss doesn't improve for
# this many rounds. The eval model's best_iteration is then reused for the
# final model so we never train for an arbitrary fixed nrounds.
XGB_EARLY_STOPPING_ROUNDS <- 20L

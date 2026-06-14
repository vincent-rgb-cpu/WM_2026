# =============================================================================
# run_all.R  --  Run the full pipeline end to end.
#
#   Rscript run_all.R
#
# Equivalent to running scripts 01 -> 02 -> 03 in order.
# =============================================================================

source("scripts/01_build_dataset.R")
source("scripts/02_train_evaluate.R")
source("scripts/03_predict_tournament.R")
source("scripts/04_simulate.R")
source("scripts/05_exact_scores.R")
cat("\nPipeline complete. See the output/ directory for results.\n")

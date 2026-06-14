# =============================================================================
# 04_simulate.R  --  Stage 4: full-tournament Monte-Carlo simulation.
#
#   result_model.rds + current team state
#        -> simulate group stage -> knockout -> final, N times
#        -> output/tournament_probabilities.csv
#
# Run from the project root:
#   Rscript scripts/04_simulate.R          # N = TOURNAMENT_SIM_N (10,000)
#   Rscript scripts/04_simulate.R 100      # override N (e.g. quick test)
# =============================================================================

source("R/utils.R")
load_pipeline("R")
ensure_dirs()

# Optional command-line override for the number of simulations.
args <- commandArgs(trailingOnly = TRUE)
N <- TOURNAMENT_SIM_N
if (length(args) >= 1 && !is.na(suppressWarnings(as.integer(args[1])))) {
  N <- as.integer(args[1])
}

bundle <- readRDS(FILES$training_data)
model  <- load_model()

log_msg("Running full-tournament Monte-Carlo with N = ", N, " simulations")
t0 <- Sys.time()
probs <- run_tournament_simulation(model, bundle$fixtures, bundle$ratings,
                                   bundle$team_form, N = N)
log_msg("Simulation finished in ",
        round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1), "s")

readr::write_csv(probs, FILES$tournament_prob)
log_msg("Saved ", FILES$tournament_prob)

cat("\n--- Tournament probabilities (%), top 16 by title odds ---\n")
print(utils::head(probs, 16), row.names = FALSE)

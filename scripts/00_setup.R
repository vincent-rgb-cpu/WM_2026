# =============================================================================
# 00_setup.R  --  Install any missing R packages the pipeline needs.
#
# Run once after cloning:  Rscript scripts/00_setup.R
#
# Package reproducibility (renv):
#   If renv.lock exists, call `make lock` (or renv::restore()) to reproduce
#   the exact package versions used when the lock was created.
#   To update the lock after changing deps: run `renv::snapshot()` and commit
#   the updated renv.lock.
# =============================================================================

# If a lockfile is present, restore pinned versions; otherwise install fresh.
if (file.exists("renv.lock")) {
  if (!requireNamespace("renv", quietly = TRUE))
    install.packages("renv", repos = "https://cloud.r-project.org")
  message("renv.lock found — restoring pinned package versions ...")
  renv::restore(prompt = FALSE)
} else {
  required <- c("jsonlite", "dplyr", "lubridate", "tidyr", "readr",
                "purrr", "zoo", "xgboost", "tibble", "renv")

  missing <- required[!(required %in% rownames(installed.packages()))]
  if (length(missing)) {
    message("Installing: ", paste(missing, collapse = ", "))
    install.packages(missing, repos = "https://cloud.r-project.org")
  } else {
    message("All required packages are already installed.")
  }
  message("\nTip: run `make lock` to create renv.lock and pin current package versions.")
}

# =============================================================================
# 00_setup.R  --  Install any missing R packages the pipeline needs.
#
# Run once after cloning:  Rscript scripts/00_setup.R
# =============================================================================

required <- c("jsonlite", "dplyr", "lubridate", "tidyr", "readr",
              "purrr", "zoo", "xgboost", "tibble")

missing <- required[!(required %in% rownames(installed.packages()))]
if (length(missing)) {
  message("Installing: ", paste(missing, collapse = ", "))
  install.packages(missing, repos = "https://cloud.r-project.org")
} else {
  message("All required packages are already installed.")
}

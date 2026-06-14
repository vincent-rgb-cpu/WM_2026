# =============================================================================
# utils.R  --  Small, dependency-free helpers shared across the pipeline.
# =============================================================================

# Null-coalescing operator: `a %||% b` returns `a` unless it is NULL.
`%||%` <- function(a, b) if (is.null(a)) b else a

# Timestamped console logging so long-running scripts are easy to follow.
log_msg <- function(...) {
  cat(sprintf("[%s] %s\n", format(Sys.time(), "%H:%M:%S"), paste0(..., collapse = "")))
}

# Make sure every output/data directory exists (idempotent).
ensure_dirs <- function() {
  for (p in PATHS) dir.create(p, recursive = TRUE, showWarnings = FALSE)
  invisible(TRUE)
}

# Coerce a character/JSON value to numeric, turning "null", "" and friends into
# NA instead of throwing a warning.
to_num <- function(x) suppressWarnings(as.numeric(x))

# Source every module in R/ (config first, then the rest). Scripts call this so
# they don't each repeat a list of `source()` lines.
load_pipeline <- function(r_dir = "R") {
  source(file.path(r_dir, "config.R"))
  others <- setdiff(
    list.files(r_dir, pattern = "\\.R$", full.names = TRUE),
    file.path(r_dir, "config.R")
  )
  for (f in others) source(f)
  invisible(TRUE)
}

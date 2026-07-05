#!/usr/bin/env Rscript

# ============================================================
# 00_setup_env.R
# Purpose:
#   - Ensure required R version
#   - Install & check required CRAN packages for V0 pipeline
#
# Usage:
#   Rscript 00_setup_env.R
#
# Notes:
#   - This script is SAFE to re-run
#   - It only installs missing packages
# ============================================================

cat("=== GenePipeline V0 | Environment Setup ===\n")

# ----------------------------
# 1. Check R version
# ----------------------------
required_r_version <- "4.3.0"
current_r_version  <- getRversion()

cat("R version detected:", as.character(current_r_version), "\n")

if (current_r_version < required_r_version) {
  stop(
    "R version >= ", required_r_version, " is required.\n",
    "Please upgrade R before running the pipeline.",
    call. = FALSE
  )
}

# ----------------------------
# 2. Required packages (CRAN)
# ----------------------------
required_pkgs <- c(
  "optparse",
  "readr",
  "dplyr",
  "stringr",
  "tibble",
  "tidyr"
)

# ----------------------------
# 3. Detect missing packages
# ----------------------------
installed <- rownames(installed.packages())
missing_pkgs <- setdiff(required_pkgs, installed)

if (length(missing_pkgs) == 0) {
  cat("All required packages are already installed.\n")
} else {
  cat("Missing packages detected:\n")
  cat("  -", paste(missing_pkgs, collapse = ", "), "\n")
  cat("Installing missing packages from CRAN...\n")
  
  install.packages(
    missing_pkgs,
    repos = "https://cloud.r-project.org",
    dependencies = TRUE
  )
}

# ----------------------------
# 4. Final check
# ----------------------------
cat("Verifying package availability...\n")

failed <- character(0)
for (pkg in required_pkgs) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    failed <- c(failed, pkg)
  }
}

if (length(failed) > 0) {
  stop(
    "The following packages could not be loaded:\n",
    paste(failed, collapse = ", "),
    "\nPlease check installation manually.",
    call. = FALSE
  )
}

cat("All required packages are available.\n")
cat("Environment setup complete.\n")
cat("=========================================\n")

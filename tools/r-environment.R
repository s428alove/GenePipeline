#!/usr/bin/env Rscript
# Internal CLI: launched with --vanilla, so check mode can never auto-install.
args <- commandArgs(trailingOnly = TRUE)
mode <- if (length(args)) args[[1]] else "check"
project <- normalizePath(if (length(args) > 1L) args[[2]] else getwd(), winslash = "/", mustWork = TRUE)
source(file.path(project, "tools", "r-environment-lib.R"))
result <- tryCatch({
  if (mode == "check") gp_check(project)
  else if (mode == "setup") gp_setup(project, rebuild = length(args) > 2L && args[[3]] == "rebuild")
  else stop(gp_fail("PACKAGE_ENV_NOT_READY", "Unknown environment operation"))
}, error = function(e) list(ok = FALSE, state = "not_ready", error = list(
  code = if (inherits(e, "gp_environment_error")) e$code else "PACKAGE_VALIDATION_FAILED",
  message = conditionMessage(e))))
cat("GENEPIPELINE_ENV_RESULT=", gp_json(result), "\n", sep = "")
quit(status = if (isTRUE(result$ok)) 0L else 1L)

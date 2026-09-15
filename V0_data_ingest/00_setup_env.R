#!/usr/bin/env Rscript
# Retired per-layer installer. Environment setup belongs to Node startup.
stop(
  "V0 no longer manages R packages. Start GenePipeline for automatic setup, ",
  "or run npm run setup:environment from the repository root for repair.",
  call. = FALSE
)

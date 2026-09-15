#!/usr/bin/env Rscript
# Maintainer-only initial lock creation / intentional dependency updates.
# Never called by application startup or an analysis request.
# Run with the selected Rscript --vanilla from the repository root.
project <- normalizePath(getwd(), winslash = "/")
source("tools/r-environment-lib.R")
gp_bootstrap(project)
gp_activate(project)
definition <- gp_definition(project)
renv::settings$snapshot.type("explicit", project = project)
renv::settings$bioconductor.version(definition$bioconductor, project = project)
renv::install(paste0("renv@", definition$renv_version), project = project)
renv::install(c(setdiff(definition$direct, definition$bioc_packages),
                setdiff(definition$tooling, "renv")), project = project)
renv::install(paste0("bioc::", definition$bioc_packages), project = project)
renv::snapshot(project = project, type = "explicit", prompt = FALSE)
# The Node maintainer wrapper performs a fresh-project restore/snapshot roundtrip.

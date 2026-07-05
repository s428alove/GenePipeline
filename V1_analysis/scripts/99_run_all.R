#!/usr/bin/env Rscript
# 99_run_all.R
# V1 core orchestrator for GenePipeline.
#
# Purpose:
#   Run the sealed V1 core modules in order:
#     _tools/00_sanity_check_inputs.R
#     01_qc_dataset_overview.R
#     02_run_differential_expression.R
#     03_volcano_plot.R
#     04_ma_plot.R
#
# Canonical inputs expected by downstream modules:
#   data_processed/<GSE>/expression_gene_log.tsv
#   data_processed/<GSE>/sample_metadata_merged.tsv
#
# Usage:
#   Rscript V1_analysis/scripts/99_run_all.R --gse GSE13601
#   Rscript V1_analysis/scripts/99_run_all.R --gse GSE13601 --case_label Tumor --control_label Normal
#   Rscript V1_analysis/scripts/99_run_all.R --gse GSE13601 --padj_cutoff 0.05 --lfc_cutoff 1
#
# Notes:
#   - 10_targeted_gene_distribution.R is intentionally NOT included in the default V1 core.
#   - Survival / forestplot / decision-template helper scripts should remain outside this core runner.

if (!requireNamespace("optparse", quietly = TRUE)) {
  stop(
    "Missing bootstrap R package: optparse. Install it with ",
    "install.packages(\"optparse\") and rerun.",
    call. = FALSE
  )
}

suppressPackageStartupMessages({
  library(optparse)
})

stop2 <- function(...) stop(paste0(..., collapse = ""), call. = FALSE)

option_list <- list(
  make_option(c("--gse"), type = "character", help = "GSE accession, e.g. GSE13601"),

  make_option(c("--scripts_dir"), type = "character", default = "V1_analysis/scripts",
              help = "Directory containing V1 scripts (default: V1_analysis/scripts)"),
  make_option(
    c("--rscript"),
    type = "character",
    default = file.path(
      R.home("bin"),
      if (.Platform$OS.type == "windows") "Rscript.exe" else "Rscript"
    ),
    help = "Path to Rscript executable"
  ),

  make_option(c("--group_col"), type = "character", default = "group_label",
              help = "Group column passed to DEG module (default: group_label)"),
  make_option(c("--batch_col"), type = "character", default = "batch",
              help = "Batch column passed to DEG module if present (default: batch)"),
  make_option(c("--case_label"), type = "character", default = "",
              help = "Optional DEG direction override: case group label"),
  make_option(c("--control_label"), type = "character", default = "",
              help = "Optional DEG direction override: control group label"),

  make_option(c("--padj_cutoff"), type = "double", default = 0.05,
              help = "Adjusted P cutoff passed to DEG/plots (default: 0.05)"),
  make_option(c("--lfc_cutoff"), type = "double", default = 1,
              help = "Abs(logFC) cutoff passed to DEG/plots (default: 1)"),

  make_option(c("--figroot"), type = "character", default = "figures",
              help = "Figures root for plot modules (default: figures)"),
  make_option(c("--resroot"), type = "character", default = "results",
              help = "Results root for plot modules (default: results)"),
  make_option(c("--dpi"), type = "integer", default = 300,
              help = "Plot DPI passed to plotting modules (default: 300)"),
  make_option(c("--width"), type = "double", default = 7,
              help = "Plot width passed to plotting modules (default: 7)"),
  make_option(c("--height"), type = "double", default = 5,
              help = "Plot height passed to plotting modules where applicable (default: 5)"),

  make_option(c("--skip_qc"), action = "store_true", default = FALSE,
              help = "Skip 01_qc_dataset_overview.R"),
  make_option(c("--skip_deg"), action = "store_true", default = FALSE,
              help = "Skip 02_run_differential_expression.R"),
  make_option(c("--skip_volcano"), action = "store_true", default = FALSE,
              help = "Skip 03_volcano_plot.R"),
  make_option(c("--skip_ma"), action = "store_true", default = FALSE,
              help = "Skip 04_ma_plot.R"),

  make_option(c("--dry_run"), action = "store_true", default = FALSE,
              help = "Print commands without executing"),
  make_option(c("--quiet"), action = "store_true", default = FALSE,
              help = "Pass --quiet to modules that support it")
)

opt <- parse_args(OptionParser(option_list = option_list))

if (is.null(opt$gse) || opt$gse == "") stop2("Missing --gse")

if (
  length(opt$padj_cutoff) != 1L ||
  !is.finite(opt$padj_cutoff) ||
  opt$padj_cutoff <= 0 ||
  opt$padj_cutoff > 1
) {
  stop2("--padj_cutoff must be greater than 0 and less than or equal to 1.")
}

if (
  length(opt$lfc_cutoff) != 1L ||
  !is.finite(opt$lfc_cutoff) ||
  opt$lfc_cutoff < 0
) {
  stop2("--lfc_cutoff must be greater than or equal to 0.")
}

gse <- opt$gse
scripts_dir <- opt$scripts_dir
rscript <- opt$rscript

if (!file.exists(rscript)) {
  stop2("Rscript executable not found: ", rscript,
        "\nHint: pass --rscript \"C:/Program Files/R/R-4.5.2/bin/Rscript.exe\"")
}
if (!dir.exists(scripts_dir)) stop2("scripts_dir not found: ", scripts_dir)

script_path <- function(filename) file.path(scripts_dir, filename)

run_step <- function(step_name, script_file, args = character()) {
  if (!file.exists(script_file)) stop2("Script not found for ", step_name, ": ", script_file)

  cmd_args <- c(script_file, args)

  message("\n=== V1 STEP START: ", step_name, " ===")
  message("Rscript: ", rscript)
  message("Script : ", script_file)
  message("Args   : ", paste(args, collapse = " "))

  if (isTRUE(opt$dry_run)) {
    message("DRY RUN: command not executed.")
    message("=== V1 STEP SKIP: ", step_name, " ===")
    return(invisible(0L))
  }

  status <- system2(command = rscript, args = cmd_args)

  if (!identical(status, 0L)) {
    stop2("V1 step failed: ", step_name, " (exit status = ", status, ")")
  }

  message("=== V1 STEP DONE: ", step_name, " ===")
  invisible(status)
}

base_args <- c("--gse", gse)
quiet_arg <- if (isTRUE(opt$quiet)) "--quiet" else character(0)

message("=== V1 RUN START ===")
message("GSE        : ", gse)
message("scripts_dir: ", scripts_dir)
message("Rscript    : ", rscript)
message("Core steps : Sanity -> QC overview -> DEG -> Volcano -> MA")
message("Optional targeted gene module is not run by this core orchestrator.")

sanity_args <- c(
  base_args,
  "--scripts_dir", scripts_dir,
  "--group_col", opt$group_col,
  "--padj_cutoff", as.character(opt$padj_cutoff),
  "--lfc_cutoff", as.character(opt$lfc_cutoff),
  quiet_arg
)

if (!isTRUE(opt$skip_deg)) {
  sanity_args <- c(sanity_args, "--require_deg_ready")
}

run_step(
  step_name = "00_sanity_check_inputs",
  script_file = script_path(file.path("_tools", "00_sanity_check_inputs.R")),
  args = sanity_args
)

if (!isTRUE(opt$skip_qc)) {
  run_step(
    step_name = "01_qc_dataset_overview",
    script_file = script_path("01_qc_dataset_overview.R"),
    args = c(
      base_args,
      "--outroot", opt$figroot,
      "--dpi", as.character(opt$dpi),
      "--width", as.character(opt$width),
      "--height", as.character(opt$height)
    )
  )
}

if (!isTRUE(opt$skip_deg)) {
  deg_args <- c(
    base_args,
    "--group_col", opt$group_col,
    "--batch_col", opt$batch_col,
    "--padj_cutoff", as.character(opt$padj_cutoff),
    "--lfc_cutoff", as.character(opt$lfc_cutoff),
    quiet_arg
  )

  if (nzchar(opt$case_label)) {
    deg_args <- c(deg_args, "--case_label", opt$case_label)
  }
  if (nzchar(opt$control_label)) {
    deg_args <- c(deg_args, "--control_label", opt$control_label)
  }

  run_step(
    step_name = "02_run_differential_expression",
    script_file = script_path("02_run_differential_expression.R"),
    args = deg_args
  )
}

if (!isTRUE(opt$skip_volcano)) {
  run_step(
    step_name = "03_volcano_plot",
    script_file = script_path("03_volcano_plot.R"),
    args = c(
      base_args,
      "--figroot", opt$figroot,
      "--resroot", opt$resroot,
      "--padj_cutoff", as.character(opt$padj_cutoff),
      "--lfc_cutoff", as.character(opt$lfc_cutoff),
      "--width", as.character(opt$width),
      "--height", as.character(max(opt$height, 6)),
      "--dpi", as.character(opt$dpi),
      quiet_arg
    )
  )
}

if (!isTRUE(opt$skip_ma)) {
  run_step(
    step_name = "04_ma_plot",
    script_file = script_path("04_ma_plot.R"),
    args = c(
      base_args,
      "--outroot", opt$figroot,
      "--padj_cutoff", as.character(opt$padj_cutoff),
      "--lfc_cutoff", as.character(opt$lfc_cutoff),
      "--width", as.character(opt$width),
      "--height", as.character(max(opt$height, 6)),
      "--dpi", as.character(opt$dpi),
      quiet_arg
    )
  )
}

message("\n=== V1 RUN COMPLETE ===")
message("Expected core outputs:")
message("- results/", gse, "/qc_dataset_overview/")
message("- results/", gse, "/deg/")
message("- results/", gse, "/volcano/")
message("- results/", gse, "/ma_plot/")
message("- figures/", gse, "/")

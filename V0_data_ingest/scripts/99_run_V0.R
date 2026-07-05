#!/usr/bin/env Rscript

# ============================================================
# 99_run_V0.R  (FULL OVERWRITE)
# - V0 data ingest runner
# - Responsibilities:
#   * resolve paths / CLI
#   * read series matrix
#   * decide GPL
#   * obtain probe->gene mapping (via gpl_annotation.R, with cache)
#   * aggregate expression (via v0_io.R)
#   * write V0 outputs:
#       - expression_gene_log.tsv
#       - sample_metadata_raw.tsv
#       - sample_metadata_decision.tsv (template)
#       - dataset_decision.tsv (dataset-level gating)
#       - _engineering/{run_manifest.txt, sessionInfo.txt, V0_summary.txt}
# ============================================================

# ---- resolve project root relative to this script ----
args <- commandArgs(trailingOnly = FALSE)
script_path <- sub("^--file=", "", args[grep("^--file=", args)])
script_dir  <- dirname(normalizePath(script_path))

# script is: V0_data_ingest/scripts/99_run_V0.R
# project_root should be: V0_data_ingest
project_root <- normalizePath(file.path(script_dir, ".."))

suppressPackageStartupMessages({
  library(optparse)
  library(readr)
  library(dplyr)
  library(tibble)
  library(stringr)
})

# ----------------------------
# logging / stop
# ----------------------------
log_msg <- function(..., quiet = FALSE) {
  if (!quiet) {
    cat(sprintf("[%s] ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
        ..., "\n", sep = "")
  }
}
stop2 <- function(...) stop(paste0(..., collapse = ""), call. = FALSE)

# ----------------------------
# source libs
# ----------------------------
source(file.path(project_root, "_lib/geo_series_matrix.R"))
source(file.path(project_root, "_lib/gpl_annotation.R"))
source(file.path(project_root, "_lib/v0_io.R"))

# ----------------------------
# helpers: dataset decision
# ----------------------------
infer_feature_space <- function(mapping_df) {
  if (!("gene_id_type" %in% names(mapping_df))) return("unknown")
  df <- mapping_df
  if ("map_status" %in% names(df)) df <- df %>% filter(map_status == "OK")
  if (nrow(df) == 0) return("unknown")
  p_mirna <- mean(df$gene_id_type == "mirna", na.rm = TRUE)
  p_gene  <- mean(df$gene_id_type == "gene_symbol", na.rm = TRUE)
  if (isTRUE(p_mirna >= 0.5)) return("mirna")
  if (isTRUE(p_gene  >= 0.5)) return("gene")
  "unknown"
}

guess_annotation_path <- function(raw_gse_dir, gpl_id, mapping_df) {
  # 1) if mapping_df has an attribute
  ap <- attr(mapping_df, "annotation_path", exact = TRUE)
  if (!is.null(ap) && is.character(ap) && length(ap) == 1 && ap != "" && file.exists(ap)) return(ap)
  
  # 2) common filenames in raw folder
  candidates <- c(
    file.path(raw_gse_dir, paste0(gpl_id, ".annot")),
    file.path(raw_gse_dir, paste0(gpl_id, "_family.soft")),
    file.path(raw_gse_dir, paste0(gpl_id, ".soft")),
    file.path(raw_gse_dir, paste0(gpl_id, ".txt")),
    file.path(raw_gse_dir, paste0(gpl_id, "_annot.txt"))
  )
  hit <- candidates[file.exists(candidates)]
  if (length(hit) >= 1) return(hit[1])
  
  # 3) unknown/indirect
  "(resolved via gpl_annotation.R)"
}

count_mapped_features_ok <- function(mapping_df) {
  df <- mapping_df
  if ("map_status" %in% names(df)) df <- df %>% filter(map_status == "OK")
  
  feat <- NULL
  if ("feature_id" %in% names(df)) feat <- df$feature_id
  if (is.null(feat) && "probe" %in% names(df)) feat <- df$probe
  if (is.null(feat)) return(NA_integer_)
  
  feat <- as.character(feat)
  feat <- feat[!is.na(feat) & feat != ""]
  length(unique(feat))
}

# ----------------------------
# CLI
# ----------------------------
option_list <- list(
  make_option(c("--gse"), type = "character"),
  make_option(c("--raw_dir"), type = "character", default = "data_raw"),
  make_option(c("--out_dir"), type = "character", default = "data_processed"),
  make_option(c("--series_matrix"), type = "character", default = NA),
  make_option(c("--gpl"), type = "character", default = NA),
  make_option(c("--agg"), type = "character", default = "mean"),
  make_option(c("--force_log2"), type = "character", default = "auto"),
  make_option(c("--quiet"), action = "store_true", default = FALSE)
)

opt <- parse_args(OptionParser(option_list = option_list))
if (is.null(opt$gse) || opt$gse == "") stop2("Missing --gse.")

gse   <- opt$gse
quiet <- opt$quiet

raw_gse_dir <- file.path(opt$raw_dir, gse)
out_gse_dir <- file.path(opt$out_dir, gse)
eng_dir     <- file.path(out_gse_dir, "_engineering")

if (!dir.exists(raw_gse_dir)) stop2("Raw GSE folder not found: ", raw_gse_dir)
dir.create(out_gse_dir, recursive = TRUE, showWarnings = FALSE)
dir.create(eng_dir, recursive = TRUE, showWarnings = FALSE)

# ----------------------------
# resolve series matrix
# ----------------------------
series_path <- opt$series_matrix
if (is.na(series_path)) {
  files <- list.files(raw_gse_dir, full.names = TRUE, recursive = FALSE)
  hits <- files[grepl("series[_-]?matrix.*\\.(txt|tsv|gz)$",
                      basename(files), ignore.case = TRUE)]
  if (length(hits) == 0) stop2("Cannot find series matrix in: ", raw_gse_dir)
  series_path <- hits[1]
}

log_msg("GSE: ", gse, quiet = quiet)
log_msg("Series matrix: ", series_path, quiet = quiet)

# ----------------------------
# read series matrix
# ----------------------------
sm_lines <- read_text_lines(series_path)
sm <- read_series_matrix_to_probe_sample(sm_lines)

expr_mat     <- sm$mat
sample_names <- sm$sample_names

if (is.null(expr_mat) || nrow(expr_mat) == 0 || ncol(expr_mat) == 0) {
  stop2("Parsed expression matrix is empty.")
}

# metrics before any transform (dims same, but keep intention clear)
n_probe_raw <- nrow(expr_mat)
n_samples   <- ncol(expr_mat)

# ----------------------------
# decide GPL
# ----------------------------
gpl_id <- opt$gpl

if (is.na(gpl_id) || gpl_id == "") {
  gpl_info <- extract_gpl_from_series_matrix(sm_lines, sample_names)
  
  if (length(gpl_info$gpl_candidates) == 1) {
    gpl_id <- gpl_info$gpl_candidates[1]
  } else if (length(gpl_info$gpl_candidates) > 1) {
    stop2(
      "Multiple GPL candidates detected: ",
      paste(gpl_info$gpl_candidates, collapse = ", "),
      ". Please pass --gpl explicitly."
    )
  } else {
    stop2("Cannot determine GPL from series matrix; please pass --gpl.")
  }
}

# normalize GPL id
gpl_id <- as.character(gpl_id)
gpl_id <- str_trim(gpl_id)
gpl_id <- gsub('^"+|"+$', "", gpl_id)
gpl_id <- gsub("'", "", gpl_id)

log_msg("GPL: [", gpl_id, "]", quiet = quiet)

# ----------------------------
# log2 decision
# ----------------------------
log2_needed  <- detect_log2_needed(as.numeric(expr_mat), method = opt$force_log2)
log2_applied <- FALSE
if (isTRUE(log2_needed)) {
  expr_mat <- safe_log2(expr_mat)
  log2_applied <- TRUE
}

# ----------------------------
# probe -> gene mapping (with cache)
# ----------------------------
mapping <- get_probe_to_gene_mapping(
  gpl_id      = gpl_id,
  raw_gse_dir = raw_gse_dir,
  cache_dir   = file.path(out_gse_dir, "_cache"),
  quiet       = quiet
)

if (is.null(mapping) || nrow(mapping) == 0) stop2("Empty mapping returned from gpl_annotation.R")

annotation_path <- guess_annotation_path(raw_gse_dir, gpl_id, mapping)

# ----------------------------
# dataset_decision.tsv (dataset-level gating)
# - miRNA datasets are marked v1_eligible=FALSE (V1 will skip)
# ----------------------------
feature_space <- infer_feature_space(mapping)
v1_eligible <- ifelse(feature_space == "mirna", "FALSE", "TRUE")
annotation_strategy <- ifelse(feature_space == "mirna", "EXTERNAL_JOIN_LATER", "CURRENT_V1_OK")

dataset_decision_df <- tibble(
  gse = gse,
  gpl = gpl_id,
  feature_space = feature_space,
  v1_eligible = v1_eligible,
  annotation_strategy = annotation_strategy
)
dataset_decision_out <- file.path(out_gse_dir, "dataset_decision.tsv")
readr::write_tsv(dataset_decision_df, dataset_decision_out)

if (feature_space == "mirna") {
  log_msg("Detected feature_space=mirna; marked v1_eligible=FALSE (V1 will skip this dataset).", quiet = quiet)
}

# ----------------------------
# aggregate probes/features to gene_id (via v0_io.R)
# ----------------------------
gene_mat <- aggregate_probe_to_gene(
  expr_mat = expr_mat,
  mapping_df = mapping,
  agg = opt$agg
)

n_gene_out <- nrow(gene_mat)
n_probe_mapped <- count_mapped_features_ok(mapping)

# ----------------------------
# write outputs
# ----------------------------
expr_out <- file.path(out_gse_dir, "expression_gene_log.tsv")

# --- build gene_id -> feature_ids lookup (traceability) ---
map_trace <- mapping %>%
  mutate(
    feature_id = if ("feature_id" %in% names(.)) as.character(feature_id) else as.character(probe),
    gene_id    = if ("gene_id" %in% names(.)) as.character(gene_id) else as.character(gene),
    map_status = if ("map_status" %in% names(.)) as.character(map_status) else "OK"
  ) %>%
  filter(map_status == "OK", !is.na(gene_id), gene_id != "", !is.na(feature_id), feature_id != "") %>%
  group_by(gene_id) %>%
  summarise(
    feature_ids = paste(sort(unique(feature_id)), collapse = ";"),
    n_features  = dplyr::n_distinct(feature_id),
    .groups = "drop"
  )

# --- expression table ---
expr_tbl <- as.data.frame(gene_mat, stringsAsFactors = FALSE, check.names = FALSE)
expr_tbl$gene_id <- rownames(expr_tbl)
expr_tbl <- expr_tbl %>% relocate(gene_id)

# attach trace columns
expr_tbl <- expr_tbl %>%
  left_join(map_trace, by = "gene_id") %>%
  relocate(feature_ids, n_features, .after = gene_id)

readr::write_tsv(expr_tbl, expr_out)

# raw metadata from series header
raw_meta <- parse_sample_metadata_from_series_header(sm_lines, sample_names)
raw_meta_out <- file.path(out_gse_dir, "sample_metadata_raw.tsv")
readr::write_tsv(raw_meta, raw_meta_out)

# minimal decision template (V0)
decision_df <- tibble(
  sample_id    = sample_names,
  include      = "FALSE",
  group_label  = NA_character_,
  case_control = NA_character_,
  batch        = NA_character_,
  tissue       = NA_character_
)
decision_out <- file.path(out_gse_dir, "sample_metadata_decision.tsv")
readr::write_tsv(decision_df, decision_out)

# ----------------------------
# validation
# ----------------------------
validate_v0_minimal(
  gene_mat = gene_mat,
  raw_meta = raw_meta,
  decision_df = decision_df
)

# ----------------------------
# engineering outputs: V0_summary, run_manifest, sessionInfo
# ----------------------------
run_id <- paste0(gse, "_", format(Sys.time(), "%Y%m%d_%H%M%S"))
timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")

summary_out <- file.path(eng_dir, "V0_summary.txt")
manifest_out <- file.path(eng_dir, "run_manifest.txt")
session_out <- file.path(eng_dir, "sessionInfo.txt")

# summary (human-readable)
write_summary(summary_out, list(
  gse            = gse,
  gpl            = gpl_id,
  series_matrix  = series_path,
  annotation     = annotation_path,
  agg            = opt$agg,
  force_log2     = opt$force_log2,
  log2_applied   = ifelse(isTRUE(log2_applied), "TRUE", "FALSE"),
  feature_space  = feature_space,
  v1_eligible    = v1_eligible,
  n_probe_raw    = n_probe_raw,
  n_probe_mapped = ifelse(is.na(n_probe_mapped), "", as.character(n_probe_mapped)),
  n_gene_out     = n_gene_out,
  n_samples      = n_samples
))

# sessionInfo
write_session_info(session_out)

# run_manifest (machine-readable)
write_manifest(manifest_out, list(
  run_id = run_id,
  timestamp = timestamp,
  gse = gse,
  gpl = gpl_id,
  series_matrix = series_path,
  annotation = annotation_path,
  decision_path = decision_out,
  agg = opt$agg,
  force_log2 = opt$force_log2,
  log2_applied = ifelse(isTRUE(log2_applied), "TRUE", "FALSE"),
  feature_space = "gene",            # V0 output is gene-level table
  n_probe_raw = n_probe_raw,
  n_probe_mapped = n_probe_mapped,
  n_gene_out = n_gene_out,
  n_samples = n_samples,
  v1_eligible = v1_eligible,
  expr_out = expr_out,
  raw_meta_out = raw_meta_out,
  decision_meta_out = decision_out,
  summary_out = summary_out,
  session_info_out = session_out
))

log_msg("DONE. Wrote expression_gene_log.tsv + sample_metadata_raw/decision + dataset_decision.tsv + engineering files.", quiet = quiet)

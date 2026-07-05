# ============================================================
# V0_data_ingest/_lib/gpl_annotation.R
#
# Role:
#   GPL annotation parser and probe/feature -> gene_id mapping builder.
#
# Responsibility:
#   1. Select the best annotation file for a GPL inside data_raw/<GSE>/
#   2. Parse multiple annotation formats (.annot / .soft / .txt)
#   3. Convert raw parsed output into a unified mapping schema
#   4. Rebuild mapping from the current annotation on every V0 run
#
# Important:
#   - This file is intended to be sourced AFTER v0_io.R
#   - Shared helpers such as stop2() / log_msg() / read_text_lines()
#     live in v0_io.R
# ============================================================

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
  library(stringr)
  library(tidyr)
})

# ------------------------------------------------------------
# Dependency guard
# ------------------------------------------------------------
for (.fn in c("stop2", "log_msg", "read_text_lines", "ensure_dir")) {
  if (!exists(.fn, mode = "function")) {
    stop("gpl_annotation.R requires v0_io.R to be sourced first (missing ", .fn, "()).", call. = FALSE)
  }
}
rm(.fn)

# ------------------------------------------------------------
# .norm_key()
# Normalize column names to make matching more robust.
# ------------------------------------------------------------
.norm_key <- function(x) {
  x %>%
    trimws() %>%
    tolower() %>%
    gsub("[ _-]+", "", .)
}

# ------------------------------------------------------------
# .pick_col_idx()
# Return first matched column index from a candidate set.
# ------------------------------------------------------------
.pick_col_idx <- function(keys_norm, candidates) {
  cand_norm <- .norm_key(candidates)
  idx <- match(cand_norm, keys_norm)
  idx <- idx[!is.na(idx)]
  if (length(idx) == 0) return(NA_integer_)
  idx[1]
}

# ------------------------------------------------------------
# .infer_gene_id_type()
# Heuristic classifier for downstream traceability.
# ------------------------------------------------------------
.infer_gene_id_type <- function(x) {
  if (is.na(x) || x == "") return("unknown")

  lx <- tolower(x)

  if (str_detect(lx, "^(hsa|mmu|rno|dme|ath|cfa|gga|dre)-") && str_detect(lx, "(mir|let)")) {
    return("mirna")
  }
  if (str_detect(lx, "^(mir|let)[-_]")) return("mirna")
  if (str_detect(lx, "mir")) return("mirna")

  if (str_detect(x, "^[0-9]+$")) return("entrez")

  if (str_detect(x, "^[A-Za-z0-9][A-Za-z0-9\\-\\.]*$")) return("gene_symbol")

  "unknown"
}

# ------------------------------------------------------------
# pick_annotation_by_gpl()
#
# Priority:
#   .annot > .soft > .txt
#
# Fail-fast:
#   If multiple candidates exist in the same priority tier, stop and
#   let the user resolve ambiguity explicitly.
# ------------------------------------------------------------
pick_annotation_by_gpl <- function(gpl_id, raw_gse_dir, quiet = FALSE) {
  if (is.na(gpl_id) || gpl_id == "") {
    stop2("GPL id is empty; cannot select annotation automatically.")
  }
  if (!dir.exists(raw_gse_dir)) {
    stop2("Raw GSE directory not found: ", raw_gse_dir)
  }

  files <- list.files(raw_gse_dir, full.names = TRUE, recursive = FALSE)
  hits <- files[grepl(gpl_id, basename(files), fixed = TRUE)]

  if (length(hits) == 0) {
    stop2('Cannot find any annotation file that matches "', gpl_id, '" in: ', raw_gse_dir)
  }

  annot_hits <- hits[grepl("\\.annot(\\.gz)?$", hits, ignore.case = TRUE)]
  soft_hits  <- hits[grepl("\\.soft(\\.gz)?$",  hits, ignore.case = TRUE)]
  txt_hits   <- hits[grepl("\\.txt(\\.gz)?$",   hits, ignore.case = TRUE)]

  if (length(annot_hits) == 1) return(annot_hits)
  if (length(annot_hits) > 1) {
    stop2(
      "Multiple .annot files found for ", gpl_id, ":\n- ",
      paste(basename(annot_hits), collapse = "\n- "),
      "\nPlease resolve manually."
    )
  }

  if (length(soft_hits) == 1) return(soft_hits)
  if (length(soft_hits) > 1) {
    stop2(
      "Multiple .soft files found for ", gpl_id, ":\n- ",
      paste(basename(soft_hits), collapse = "\n- "),
      "\nPlease resolve manually."
    )
  }

  if (length(txt_hits) == 1) {
    log_msg("Using GPL full-table txt as annotation fallback: ", basename(txt_hits), quiet = quiet)
    return(txt_hits)
  }
  if (length(txt_hits) > 1) {
    stop2(
      "Multiple .txt files found for ", gpl_id, ":\n- ",
      paste(basename(txt_hits), collapse = "\n- "),
      "\nCannot disambiguate automatically."
    )
  }

  stop2("No usable annotation file found for ", gpl_id)
}

# ------------------------------------------------------------
# parse_gpl_annotation()
# Dispatcher by file suffix.
# ------------------------------------------------------------
parse_gpl_annotation <- function(path, quiet = FALSE) {
  log_msg("Parsing annotation: ", path, quiet = quiet)

  if (grepl("\\.annot(\\.gz)?$", path, ignore.case = TRUE)) {
    return(parse_annot_file(path))
  }
  if (grepl("\\.soft(\\.gz)?$", path, ignore.case = TRUE)) {
    return(parse_soft_file(path))
  }
  if (grepl("\\.txt(\\.gz)?$", path, ignore.case = TRUE)) {
    return(parse_full_table_txt(path))
  }

  stop2("Unsupported annotation format: ", path)
}

# ------------------------------------------------------------
# parse_annot_file()
# Parse GEO .annot / .annot.gz files.
# ------------------------------------------------------------
parse_annot_file <- function(path) {
  lines <- read_text_lines(path)

  b <- grep("^!platform_table_begin\\b", lines)
  e <- grep("^!platform_table_end\\b",   lines)

  if (length(b) == 0 || length(e) == 0 || b[1] >= e[1]) {
    stop2("Invalid .annot format: cannot locate platform table.")
  }

  header <- lines[b[1] + 1]
  data_lines <- lines[(b[1] + 2):(e[1] - 1)]

  cols <- strsplit(header, "\t", fixed = TRUE)[[1]]
  keys_norm <- .norm_key(cols)

  id_idx <- .pick_col_idx(keys_norm, c("ID", "ID_REF", "Probe", "PROBE_ID"))
  gene_idx <- .pick_col_idx(keys_norm, c("Gene Symbol", "gene_symbol", "symbol", "gene_assignment", "Gene Assignment"))

  if (is.na(id_idx) || is.na(gene_idx)) {
    stop2("Cannot locate probe / gene column in annot header.")
  }

  probe <- character()
  gene  <- character()

  for (ln in data_lines) {
    parts <- strsplit(ln, "\t", fixed = TRUE)[[1]]
    if (length(parts) < max(id_idx, gene_idx)) next

    p <- trimws(parts[id_idx])
    g <- trimws(parts[gene_idx])

    if (p == "" || g == "" || g == "---") next

    probe <- c(probe, p)
    gene  <- c(gene, g)
  }

  tibble(probe = probe, gene = gene) %>%
    mutate(gene = str_split(gene, "\\s*///\\s*|\\s*;\\s*|\\s*,\\s*")) %>%
    unnest(gene) %>%
    mutate(gene = str_trim(gene)) %>%
    filter(gene != "") %>%
    distinct()
}

# ------------------------------------------------------------
# parse_soft_file()
# Parse GPL .soft / .soft.gz files.
# ------------------------------------------------------------
parse_soft_file <- function(path) {
  lines <- read_text_lines(path)

  b <- grep("^!platform_table_begin\\b", lines)
  e <- grep("^!platform_table_end\\b",   lines)

  if (length(b) == 0 || length(e) == 0 || b[1] >= e[1]) {
    stop2("Invalid .soft format: cannot locate !platform_table_begin/end.")
  }

  header <- lines[b[1] + 1]
  data_lines <- lines[(b[1] + 2):(e[1] - 1)]

  cols <- strsplit(header, "\t", fixed = TRUE)[[1]]
  key  <- tolower(trimws(cols))

  id_idx <- match("id", key)
  if (is.na(id_idx)) {
    id_idx <- match(c("id_ref", "probe", "probe_id"), key)
    id_idx <- id_idx[!is.na(id_idx)][1]
  }
  if (is.na(id_idx)) {
    stop2(
      "Cannot locate probe ID column in .soft header.\n",
      "Detected columns: ", paste(cols, collapse = " | ")
    )
  }

  gene_candidates <- c(
    "probe gene symbol", "probe_gene_symbol",
    "gene symbol", "gene_symbol", "symbol",
    "gene assignment", "gene_assignment",
    "gene", "genesymbol", "gene_symbols",
    "gene title", "gene_title",
    "genename", "gene_name",
    "entrez_gene_id", "entrez id", "entrezid", "entrez gene"
  )

  cand_idx <- match(gene_candidates, key)
  cand_idx <- unique(cand_idx[!is.na(cand_idx)])

  if (length(cand_idx) == 0) {
    stop2(
      "Cannot locate any plausible gene column in .soft platform table header.\n",
      "Detected columns: ", paste(cols, collapse = " | ")
    )
  }

  N <- min(2000, length(data_lines))
  sample_lines <- data_lines[seq_len(N)]

  .col_from_lines <- function(idx) {
    v <- character(N)
    for (i in seq_len(N)) {
      parts <- strsplit(sample_lines[i], "\t", fixed = TRUE)[[1]]
      v[i] <- if (length(parts) >= idx) trimws(parts[idx]) else ""
    }
    v
  }

  probe_v <- .col_from_lines(id_idx)

  score_best <- -Inf
  gene_idx_best <- NA_integer_

  for (gi in cand_idx) {
    gv <- .col_from_lines(gi)
    gv0 <- gv[gv != "" & gv != "---" & !is.na(gv)]

    nonempty_rate <- length(gv0) / length(gv)
    same_as_probe_rate <- mean(gv == probe_v, na.rm = TRUE)

    score <- nonempty_rate - 0.5 * same_as_probe_rate

    if (is.finite(score) && score > score_best) {
      score_best <- score
      gene_idx_best <- gi
    }
  }

  if (is.na(gene_idx_best) || score_best <= 0) {
    stop2(
      "Failed to choose a usable gene column from candidates.\n",
      "Detected columns: ", paste(cols, collapse = " | ")
    )
  }

  probe <- character()
  gene  <- character()

  for (ln in data_lines) {
    parts <- strsplit(ln, "\t", fixed = TRUE)[[1]]
    if (length(parts) < max(id_idx, gene_idx_best)) next

    p <- trimws(parts[id_idx])
    g <- trimws(parts[gene_idx_best])

    if (p == "") next
    if (g == "" || g == "---") next

    probe <- c(probe, p)
    gene  <- c(gene, g)
  }

  tibble(probe = probe, gene = gene) %>%
    mutate(gene = str_split(gene, "\\s*///\\s*|\\s*;\\s*|\\s*,\\s*")) %>%
    unnest(gene) %>%
    mutate(gene = str_trim(gene)) %>%
    filter(gene != "") %>%
    distinct()
}

# ------------------------------------------------------------
# parse_full_table_txt()
# Parse GPL full-table txt as fallback.
# ------------------------------------------------------------
parse_full_table_txt <- function(path) {
  df <- suppressMessages(
    read_tsv(
      path,
      comment = "#",
      col_types = cols(.default = "c"),
      progress = FALSE
    )
  )

  if (!("ID" %in% names(df))) {
    stop2("Full-table txt missing 'ID' column.")
  }

  gene_col <- intersect(
    names(df),
    c("gene_assignment", "Gene Symbol", "Gene symbol", "symbol", "ILMN_Gene", "miRNA_ID", "TargetMatureName", "Search_Key")
  )[1]

  if (is.na(gene_col)) {
    return(df %>% transmute(probe = ID, gene = NA_character_) %>% distinct())
  }

  df %>%
    select(probe = ID, gene = all_of(gene_col)) %>%
    filter(!is.na(probe), probe != "") %>%
    mutate(gene = if_else(is.na(gene) | gene == "" | gene == "---", NA_character_, gene)) %>%
    distinct()
}

# ------------------------------------------------------------
# .postprocess_mapping()
# Convert parser outputs into unified mapping schema.
# ------------------------------------------------------------
.postprocess_mapping <- function(mapping, map_source_col = NA_character_) {
  out <- mapping %>%
    transmute(
      probe = as.character(probe),
      gene = as.character(gene),
      feature_id = as.character(probe),
      gene_id = as.character(gene),
      map_source_col = map_source_col
    ) %>%
    mutate(
      gene_id = na_if(gene_id, ""),
      gene_id_type = vapply(gene_id, .infer_gene_id_type, character(1)),
      map_status = case_when(
        is.na(gene_id) ~ "NO_GENE_ID",
        feature_id == gene_id ~ "SELF_ID",
        TRUE ~ "OK"
      )
    )

  ratio_self <- mean(out$map_status == "SELF_ID", na.rm = TRUE)
  if (isTRUE(ratio_self > 0.9)) {
    out <- out %>%
      mutate(
        gene_id = NA_character_,
        gene = NA_character_,
        gene_id_type = "unknown",
        map_status = "NO_GENE_COL"
      )
  }

  out
}

# ------------------------------------------------------------
# .infer_soft_source_col()
# Best-effort traceability for chosen .soft gene column.
# ------------------------------------------------------------
.infer_soft_source_col <- function(path) {
  lines <- read_text_lines(path)
  b <- grep("^!platform_table_begin\\b", lines)
  e <- grep("^!platform_table_end\\b",   lines)
  if (length(b) == 0 || length(e) == 0 || b[1] >= e[1]) return(NA_character_)

  header <- lines[b[1] + 1]
  cols <- strsplit(header, "\t", fixed = TRUE)[[1]]
  keys_norm <- .norm_key(cols)

  gene_candidates <- c(
    "ILMN_Gene", "miRNA_ID", "TargetMatureName", "Search_Key",
    "Gene Symbol", "gene_symbol", "symbol",
    "gene assignment", "gene_assignment",
    "entrez_gene_id", "entrez id", "entrezid"
  )
  idx <- .pick_col_idx(keys_norm, gene_candidates)
  if (is.na(idx)) return(NA_character_)
  cols[idx]
}

# ------------------------------------------------------------
# build_probe_to_gene_mapping_from_annotation()
#
# Public API:
#   Build unified mapping directly from a known annotation path.
#
# Returns:
#   list(
#     mapping = unified mapping data frame,
#     annotation_path = normalized input path,
#     map_source_col = source column used for traceability (best-effort)
#   )
# ------------------------------------------------------------
build_probe_to_gene_mapping_from_annotation <- function(path, quiet = FALSE) {
  if (missing(path) || is.null(path) || is.na(path) || !nzchar(path)) {
    stop2("build_probe_to_gene_mapping_from_annotation(): annotation path is empty.")
  }
  if (!file.exists(path)) {
    stop2("build_probe_to_gene_mapping_from_annotation(): annotation file not found: ", path)
  }

  mapping_raw <- parse_gpl_annotation(path, quiet = quiet)
  if (nrow(mapping_raw) == 0) {
    stop2("Parsed annotation mapping is empty: ", path)
  }

  source_col <- NA_character_
  if (grepl("\\.soft(\\.gz)?$", path, ignore.case = TRUE)) {
    source_col <- .infer_soft_source_col(path)
  }

  mapping <- .postprocess_mapping(mapping_raw, map_source_col = source_col)

  list(
    mapping = mapping,
    annotation_path = path,
    map_source_col = source_col
  )
}

# ------------------------------------------------------------
# get_probe_to_gene_mapping()
#
# Public API:
#   Main entry point for downstream V0 ingest when GPL id is known.
# ------------------------------------------------------------
get_probe_to_gene_mapping <- function(
  gpl_id,
  raw_gse_dir,
  cache_dir = NULL,
  quiet = FALSE
) {
  # Deliberately re-parse the current annotation on every V0 run.
  # `cache_dir` is kept only for backward compatibility with existing callers.
  if (!is.null(cache_dir) && nzchar(as.character(cache_dir))) {
    log_msg(
      "Annotation mapping cache is disabled; re-parsing annotation for ",
      gpl_id,
      ".",
      quiet = quiet
    )
  }

  ann_path <- pick_annotation_by_gpl(gpl_id, raw_gse_dir, quiet = quiet)
  built <- build_probe_to_gene_mapping_from_annotation(ann_path, quiet = quiet)
  mapping <- built$mapping

  log_msg(
    "Rebuilt probe→gene mapping from annotation: ",
    ann_path,
    quiet = quiet
  )

  mapping
}

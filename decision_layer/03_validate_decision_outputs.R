#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(readr)
  library(dplyr)
})

stop2 <- function(...) stop(paste0(..., collapse = ""), call. = FALSE)

parse_cli_args <- function(argv) {
  res <- list()
  i <- 1L
  while (i <= length(argv)) {
    key <- argv[[i]]
    if (!startsWith(key, "--")) stop2("Invalid argument: ", key)
    key <- sub("^--", "", key)
    if (i == length(argv) || startsWith(argv[[i + 1L]], "--")) {
      res[[key]] <- TRUE
      i <- i + 1L
    } else {
      res[[key]] <- argv[[i + 1L]]
      i <- i + 2L
    }
  }
  res
}

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0 || is.na(x) || !nzchar(x)) y else x

as_bool_chr <- function(x, field_name = "field", allow_na = FALSE) {
  y <- trimws(as.character(x))
  y[y %in% c("", "NA", "<NA>")] <- NA_character_
  y <- toupper(y)
  y[y %in% c("T", "TRUE", "1")] <- "TRUE"
  y[y %in% c("F", "FALSE", "0")] <- "FALSE"
  bad <- !(y %in% c("TRUE", "FALSE")) & !is.na(y)
  if (any(bad)) {
    stop2(
      field_name, " must be TRUE/FALSE (or coercible). Bad values: ",
      paste(unique(head(as.character(x[bad]), 10)), collapse = ", ")
    )
  }
  if (!allow_na && any(is.na(y))) {
    stop2(field_name, " contains NA/empty values.")
  }
  y
}

normalize_blank_to_na <- function(x) {
  y <- as.character(x)
  y[trimws(y) == ""] <- NA_character_
  y
}

normalize_case_control <- function(x, field_name = "case_control", allow_na = TRUE) {
  y <- tolower(trimws(as.character(x)))
  y[y %in% c("", "na", "<na>")] <- NA_character_
  bad <- !(y %in% c("case", "control")) & !is.na(y)
  if (any(bad)) {
    stop2(
      field_name, " must be case/control. Bad values: ",
      paste(unique(head(as.character(x[bad]), 10)), collapse = ", ")
    )
  }
  if (!allow_na && any(is.na(y))) stop2(field_name, " contains NA/empty values.")
  y
}

validate_case_control_mapping <- function(df, label, two_group_required = TRUE) {
  included <- df %>% filter(include == "TRUE")
  if (nrow(included) == 0) stop2(label, " has no included samples.")

  bad_role <- included$sample_id[is.na(included$case_control)]
  if (length(bad_role) > 0) {
    stop2(label, " included samples missing case_control: ", paste(head(bad_role, 10), collapse = ", "))
  }

  mapping <- included %>% distinct(group_label, case_control)
  inconsistent <- mapping %>% count(group_label, name = "n_roles") %>% filter(n_roles != 1L)
  if (nrow(inconsistent) > 0) {
    stop2(
      label, " requires each group_label to map to exactly one case_control role. Bad groups: ",
      paste(inconsistent$group_label, collapse = ", ")
    )
  }

  groups <- sort(unique(included$group_label))
  roles <- sort(unique(included$case_control))
  if (isTRUE(two_group_required) && length(groups) != 2L) {
    stop2(
      label, " two-group validation failed: expected exactly 2 included groups, found ",
      length(groups), " (", paste(groups, collapse = ", "), ")."
    )
  }
  if (isTRUE(two_group_required) && !identical(roles, c("case", "control"))) {
    stop2(
      label, " requires one case group and one control group. Found roles: ",
      paste(roles, collapse = ", ")
    )
  }

  mapping
}

read_tsv_required <- function(path, required_cols, label) {
  if (!file.exists(path)) stop2(label, " not found: ", path)
  df <- readr::read_tsv(path, show_col_types = FALSE)
  miss <- setdiff(required_cols, names(df))
  if (length(miss) > 0) stop2(label, " missing required columns: ", paste(miss, collapse = ", "), " | File: ", path)
  df
}


normalize_raw_metadata_schema <- function(df, label = "Raw metadata") {
  nms <- names(df)

  # sample_id aliases
  if (!("sample_id" %in% nms)) {
    sid_alias <- intersect(c("sample", "gsm", "GSM", "geo_accession", "accession"), nms)
    if (length(sid_alias) > 0) {
      names(df)[match(sid_alias[[1]], names(df))] <- "sample_id"
      nms <- names(df)
    }
  }
  if (!("sample_id" %in% names(df))) {
    stop2(label, " missing required column: sample_id")
  }

  # title aliases
  if (!("title" %in% nms)) {
    title_alias <- intersect(c("sample_title", "name", "sample_name"), nms)
    if (length(title_alias) > 0) {
      names(df)[match(title_alias[[1]], names(df))] <- "title"
      nms <- names(df)
    }
  }
  if (!("title" %in% names(df))) {
    stop2(label, " missing required column: title")
  }

  # source aliases: keep both source_name and source_name_ch1 when possible
  source_alias <- intersect(c("source_name_ch1", "source_name", "source"), names(df))
  if (length(source_alias) > 0) {
    src_col <- source_alias[[1]]
    if (!("source_name_ch1" %in% names(df))) df$source_name_ch1 <- df[[src_col]]
    if (!("source_name" %in% names(df))) df$source_name <- df[[src_col]]
  } else {
    df$source_name_ch1 <- NA_character_
    df$source_name <- NA_character_
  }

  # optional characteristics alias normalization
  if (!("characteristics" %in% names(df))) {
    char_alias <- intersect(c("characteristics_ch1", "characteristics_ch1.1", "characteristic", "characteristics_text"), names(df))
    if (length(char_alias) > 0) df$characteristics <- df[[char_alias[[1]]]]
  }

  df %>%
    mutate(
      sample_id = as.character(sample_id),
      title = as.character(title),
      source_name_ch1 = as.character(source_name_ch1),
      source_name = as.character(source_name)
    )
}

validate_unique_sample_id <- function(df, label) {
  sid <- as.character(df$sample_id)
  if (any(is.na(sid) | trimws(sid) == "")) stop2(label, " has NA/empty sample_id.")
  if (anyDuplicated(sid)) {
    dup <- unique(sid[duplicated(sid)])
    stop2(label, " has duplicated sample_id: ", paste(head(dup, 10), collapse = ", "))
  }
}

read_tsv_header_only <- function(path) {
  hdr <- readLines(path, n = 1, warn = FALSE)
  if (length(hdr) == 0) stop2("Cannot read header from: ", path)
  strsplit(hdr, "\t", fixed = TRUE)[[1]]
}

infer_expr_sample_cols <- function(header_vec) {
  if (length(header_vec) < 2) return(character(0))
  if (length(header_vec) >= 3 && header_vec[1] == "gene_id" && header_vec[2] == "feature_ids" && header_vec[3] == "n_features") {
    return(header_vec[-c(1, 2, 3)])
  }
  if (header_vec[1] == "gene_id") return(header_vec[-1])
  header_vec[-1]
}

infer_default_paths <- function(gse, out_dir, expr, raw_meta, decision, override, qc, merged) {
  if (!is.null(gse) && nzchar(gse) && is.null(out_dir)) {
    out_dir <- file.path("results", gse, "decision_validation")
  }
  data_dir <- if (!is.null(gse) && nzchar(gse)) file.path("data_processed", gse) else NULL
  if (is.null(expr) && !is.null(data_dir)) expr <- file.path(data_dir, "expression_gene_log.tsv")
  if (is.null(raw_meta) && !is.null(data_dir)) {
    p1 <- file.path(data_dir, "sample_metadata_raw.tsv")
    p2 <- file.path(data_dir, "sample_metadata.tsv")
    raw_meta <- if (file.exists(p1)) p1 else if (file.exists(p2)) p2 else p1
  }
  if (is.null(decision) && !is.null(data_dir)) decision <- file.path(data_dir, "sample_metadata_decision.tsv")
  if (is.null(override) && !is.null(data_dir)) override <- file.path(data_dir, "sample_metadata_override.tsv")
  if (is.null(qc) && !is.null(data_dir)) qc <- file.path(data_dir, "sample_qc_flags.tsv")
  if (is.null(merged) && !is.null(data_dir)) merged <- file.path(data_dir, "sample_metadata_merged.tsv")
  list(out_dir = out_dir, expr = expr, raw_meta = raw_meta, decision = decision, override = override, qc = qc, merged = merged)
}

validate_decision_outputs <- function(
    out_dir,
    expr_path = NULL,
    raw_meta_path = NULL,
    decision_path = NULL,
    override_path = NULL,
    qc_path = NULL,
    merged_meta_path = NULL,
    gse = NULL,
    two_group_required = TRUE) {

  if (is.null(out_dir) || !nzchar(out_dir)) stop2("out_dir is required.")
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  notes <- c()
  add_note <- function(...) notes <<- c(notes, paste0(..., collapse = ""))

  raw_meta <- NULL
  if (!is.null(raw_meta_path) && nzchar(raw_meta_path) && file.exists(raw_meta_path)) {
    raw_meta <- readr::read_tsv(raw_meta_path, show_col_types = FALSE) %>%
      normalize_raw_metadata_schema("Raw metadata")
    validate_unique_sample_id(raw_meta, "Raw metadata")
    add_note("[OK] Raw metadata validated: ", raw_meta_path)
  }

  decision <- NULL
  if (!is.null(decision_path) && nzchar(decision_path) && file.exists(decision_path)) {
    decision <- read_tsv_required(decision_path, c("sample_id", "include", "group_label", "case_control"), "Decision table") %>%
      mutate(
        sample_id = as.character(sample_id),
        include = as_bool_chr(include, "Decision include", allow_na = FALSE),
        group_label = normalize_blank_to_na(group_label),
        case_control = normalize_case_control(case_control, "Decision case_control", allow_na = TRUE)
      )
    validate_unique_sample_id(decision, "Decision table")
    if (!is.null(raw_meta)) {
      bad <- setdiff(decision$sample_id, raw_meta$sample_id)
      if (length(bad) > 0) stop2("Decision table contains sample_id not found in raw metadata: ", paste(head(bad, 10), collapse = ", "))
    }
    if (all(decision$include == "FALSE")) stop2("Decision invariant violated: include must not be all FALSE.")
    bad_grp <- decision$sample_id[decision$include == "TRUE" & is.na(decision$group_label)]
    if (length(bad_grp) > 0) stop2("Decision invariant violated: included samples missing group_label: ", paste(head(bad_grp, 10), collapse = ", "))
    decision_role_map <- validate_case_control_mapping(decision, "Decision table", two_group_required)
    add_note("[OK] Decision case/control mapping: ", paste(paste0(decision_role_map$group_label, "=", decision_role_map$case_control), collapse = ", "))
    add_note("[OK] Decision table validated: ", decision_path)
  }

  override_tbl <- NULL
  if (!is.null(override_path) && nzchar(override_path) && file.exists(override_path)) {
    override_tbl <- read_tsv_required(override_path, c("sample_id", "override_include", "override_group_label", "override_reason"), "Override table") %>%
      mutate(
        sample_id = as.character(sample_id),
        override_include = as_bool_chr(override_include, "Override include", allow_na = TRUE),
        override_group_label = normalize_blank_to_na(override_group_label),
        override_reason = normalize_blank_to_na(override_reason)
      )
    validate_unique_sample_id(override_tbl, "Override table")
    if (!is.null(raw_meta)) {
      bad <- setdiff(override_tbl$sample_id, raw_meta$sample_id)
      if (length(bad) > 0) stop2("Override table contains sample_id not found in raw metadata: ", paste(head(bad, 10), collapse = ", "))
    }
    missing_reason <- override_tbl$sample_id[is.na(override_tbl$override_reason)]
    if (length(missing_reason) > 0) stop2("Override rule violated: override_reason is required. Bad sample_id: ", paste(head(missing_reason, 10), collapse = ", "))
    no_effect <- override_tbl$sample_id[is.na(override_tbl$override_include) & is.na(override_tbl$override_group_label)]
    if (length(no_effect) > 0) stop2("Override table has rows with no effective override fields. Bad sample_id: ", paste(head(no_effect, 10), collapse = ", "))
    add_note("[OK] Override table validated: ", override_path)
  }

  qc_tbl <- NULL
  if (!is.null(qc_path) && nzchar(qc_path) && file.exists(qc_path)) {
    qc_tbl <- read_tsv_required(qc_path, c("sample_id", "qc_flag", "qc_reason"), "QC table") %>%
      mutate(sample_id = as.character(sample_id))
    validate_unique_sample_id(qc_tbl, "QC table")
    if (!is.null(raw_meta)) {
      bad <- setdiff(qc_tbl$sample_id, raw_meta$sample_id)
      if (length(bad) > 0) stop2("QC table contains sample_id not found in raw metadata: ", paste(head(bad, 10), collapse = ", "))
    }
    add_note("[OK] QC table validated: ", qc_path)
  }

  merged <- NULL
  if (!is.null(merged_meta_path) && nzchar(merged_meta_path) && file.exists(merged_meta_path)) {
    merged <- read_tsv_required(merged_meta_path, c("sample_id", "include", "group_label", "case_control"), "Merged metadata") %>%
      mutate(
        sample_id = as.character(sample_id),
        include = as_bool_chr(include, "Merged include", allow_na = FALSE),
        group_label = normalize_blank_to_na(group_label),
        case_control = normalize_case_control(case_control, "Merged case_control", allow_na = TRUE)
      )
    validate_unique_sample_id(merged, "Merged metadata")
    if (!is.null(raw_meta)) {
      missing_raw <- setdiff(raw_meta$sample_id, merged$sample_id)
      missing_merged <- setdiff(merged$sample_id, raw_meta$sample_id)
      if (length(missing_raw) > 0 || length(missing_merged) > 0) {
        stop2(
          "Merged metadata sample_id set does not match raw metadata. ",
          "Missing in merged (up to 10): ", paste(head(missing_raw, 10), collapse = ", "),
          " | Extra in merged (up to 10): ", paste(head(missing_merged, 10), collapse = ", ")
        )
      }
    }
    if (all(merged$include == "FALSE")) stop2("Merged invariant violated: include must not be all FALSE.")
    bad_grp <- merged$sample_id[merged$include == "TRUE" & is.na(merged$group_label)]
    if (length(bad_grp) > 0) stop2("Merged invariant violated: included samples missing group_label: ", paste(head(bad_grp, 10), collapse = ", "))
    group_levels <- sort(unique(merged$group_label[merged$include == "TRUE"]))
    merged_role_map <- validate_case_control_mapping(merged, "Merged metadata", two_group_required)
    add_note("[OK] Merged case/control mapping: ", paste(paste0(merged_role_map$group_label, "=", merged_role_map$case_control), collapse = ", "))
    add_note("[OK] Merged metadata validated: ", merged_meta_path)
  }

  if (!is.null(expr_path) && nzchar(expr_path) && file.exists(expr_path)) {
    hdr <- read_tsv_header_only(expr_path)
    expr_samples <- infer_expr_sample_cols(hdr)
    if (length(expr_samples) == 0) stop2("Cannot infer sample columns from expression file: ", expr_path)
    if (!is.null(merged)) {
      miss_meta <- setdiff(expr_samples, merged$sample_id)
      if (length(miss_meta) > 0) {
        stop2("Expression sample columns not found in merged metadata sample_id: ", paste(head(miss_meta, 10), collapse = ", "))
      }
      inc <- merged %>% filter(include == "TRUE")
      miss_expr_for_inc <- setdiff(inc$sample_id, expr_samples)
      if (length(miss_expr_for_inc) > 0) {
        stop2("Included samples in merged metadata not found in expression columns: ", paste(head(miss_expr_for_inc, 10), collapse = ", "))
      }
    } else if (!is.null(raw_meta)) {
      miss_meta <- setdiff(expr_samples, raw_meta$sample_id)
      if (length(miss_meta) > 0) {
        stop2("Expression sample columns not found in raw metadata sample_id: ", paste(head(miss_meta, 10), collapse = ", "))
      }
    }
    add_note("[OK] Expression alignment validated: ", expr_path)
  }

  summary_lines <- c(
    paste0("GSE\t", gse %||% NA_character_),
    paste0("expr_path\t", if (!is.null(expr_path) && file.exists(expr_path)) normalizePath(expr_path, winslash = "/", mustWork = FALSE) else "NA"),
    paste0("raw_meta_path\t", if (!is.null(raw_meta_path) && file.exists(raw_meta_path)) normalizePath(raw_meta_path, winslash = "/", mustWork = FALSE) else "NA"),
    paste0("decision_path\t", if (!is.null(decision_path) && file.exists(decision_path)) normalizePath(decision_path, winslash = "/", mustWork = FALSE) else "NA"),
    paste0("override_path\t", if (!is.null(override_path) && file.exists(override_path)) normalizePath(override_path, winslash = "/", mustWork = FALSE) else "NA"),
    paste0("qc_path\t", if (!is.null(qc_path) && file.exists(qc_path)) normalizePath(qc_path, winslash = "/", mustWork = FALSE) else "NA"),
    paste0("merged_meta_path\t", if (!is.null(merged_meta_path) && file.exists(merged_meta_path)) normalizePath(merged_meta_path, winslash = "/", mustWork = FALSE) else "NA"),
    paste0("n_raw\t", if (is.null(raw_meta)) NA_integer_ else nrow(raw_meta)),
    paste0("n_decision\t", if (is.null(decision)) NA_integer_ else nrow(decision)),
    paste0("n_override\t", if (is.null(override_tbl)) NA_integer_ else nrow(override_tbl)),
    paste0("n_qc\t", if (is.null(qc_tbl)) NA_integer_ else nrow(qc_tbl)),
    paste0("n_merged\t", if (is.null(merged)) NA_integer_ else nrow(merged)),
    paste0("n_included\t", if (is.null(merged)) NA_integer_ else sum(merged$include == "TRUE")),
    paste0("group_levels_included\t", if (is.null(merged)) "NA" else paste(sort(unique(merged$group_label[merged$include == "TRUE"])), collapse = ", ")),
    paste0("case_control_levels_included\t", if (is.null(merged)) "NA" else paste(sort(unique(merged$case_control[merged$include == "TRUE"])), collapse = ", ")),
    paste0(
      "group_case_control_mapping\t",
      if (is.null(merged)) "NA" else paste(
        paste0(merged_role_map$group_label, "=", merged_role_map$case_control),
        collapse = ", "
      )
    ),
    paste0("two_group_required\t", if (isTRUE(two_group_required)) "TRUE" else "FALSE"),
    paste0("validation_status\tOK")
  )

  summary_path <- file.path(out_dir, "decision_validation_summary.tsv")
  log_path <- file.path(out_dir, "decision_validation_log.txt")
  writeLines(summary_lines, con = summary_path)
  writeLines(notes, con = log_path)

  invisible(list(summary_path = summary_path, log_path = log_path, notes = notes))
}

main <- function() {
  args <- parse_cli_args(commandArgs(trailingOnly = TRUE))

  gse <- args$gse %||% NULL
  out_dir <- args$out %||% args$out_dir %||% NULL
  expr <- args$expr %||% NULL
  raw_meta <- args$meta_raw %||% args$raw_meta %||% NULL
  decision <- args$decision %||% NULL
  override <- args$override %||% NULL
  qc <- args$qc %||% NULL
  merged <- args$meta %||% args$merged %||% NULL
  two_group_required <- !identical(tolower(as.character(args$two_group_required %||% "true")), "false")

  inferred <- infer_default_paths(gse, out_dir, expr, raw_meta, decision, override, qc, merged)
  out_dir <- inferred$out_dir
  expr <- inferred$expr
  raw_meta <- inferred$raw_meta
  decision <- inferred$decision
  override <- inferred$override
  qc <- inferred$qc
  merged <- inferred$merged

  if (is.null(out_dir) || !nzchar(out_dir)) stop2("Provide --out (or --out_dir), or --gse so a default validation output directory can be inferred.")

  res <- validate_decision_outputs(
    out_dir = out_dir,
    expr_path = expr,
    raw_meta_path = raw_meta,
    decision_path = decision,
    override_path = override,
    qc_path = qc,
    merged_meta_path = merged,
    gse = gse,
    two_group_required = two_group_required
  )

  cat("[OK] Wrote validation summary:\n", res$summary_path, "\n", sep = "")
  cat("[OK] Wrote validation log:\n", res$log_path, "\n", sep = "")
}

if (sys.nframe() == 0) main()

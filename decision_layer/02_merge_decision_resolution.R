#!/usr/bin/env Rscript

suppressPackageStartupMessages({
  library(optparse)
  library(readr)
  library(dplyr)
  library(stringr)
  library(tibble)
})

stop2 <- function(...) stop(paste0(..., collapse = ""), call. = FALSE)

resolve_column <- function(df, candidates, new_name, default = NA_character_) {
  for (c in candidates) {
    if (c %in% names(df)) {
      if (c != new_name) {
        df <- dplyr::rename(df, !!new_name := all_of(c))
      }
      return(df)
    }
  }
  df[[new_name]] <- default
  df
}

normalize_include <- function(x) {
  if (is.logical(x)) return(ifelse(is.na(x), NA, x))
  x0 <- tolower(str_trim(as.character(x)))
  out <- rep(NA, length(x0))
  out[x0 %in% c("true","t","1","yes","y","include","included","ok","keep")] <- TRUE
  out[x0 %in% c("false","f","0","no","n","exclude","excluded","drop","remove")] <- FALSE
  out
}

normalize_case_control <- function(x) {
  x0 <- tolower(str_trim(as.character(x)))
  x0[x0 %in% c("", "na", "<na>")] <- NA_character_
  out <- rep(NA_character_, length(x0))
  out[x0 == "case"] <- "case"
  out[x0 == "control"] <- "control"
  out
}

main <- function() {
  option_list <- list(
    make_option("--gse", type="character"),
    make_option("--meta_raw", type="character"),
    make_option("--decision", type="character"),
    make_option("--override", type="character", default=NULL),
    make_option("--qc", type="character", default=NULL),
    make_option("--out", type="character")
  )
  opt <- parse_args(OptionParser(option_list = option_list))

  if (is.null(opt$meta_raw) || !file.exists(opt$meta_raw)) stop2("Not found: ", opt$meta_raw)
  if (is.null(opt$decision) || !file.exists(opt$decision)) stop2("Not found: ", opt$decision)
  if (is.null(opt$out) || opt$out == "") stop2("Missing --out")
  dir.create(opt$out, recursive = TRUE, showWarnings = FALSE)

  raw <- read_tsv(opt$meta_raw, show_col_types = FALSE)
  raw <- resolve_column(raw, c("sample_id","sample","gsm","geo_accession","accession"), "sample_id")
  raw <- resolve_column(raw, c("title","sample_title"), "title")
  raw <- resolve_column(raw, c("source_name_ch1","source_name","source"), "source_name_ch1")
  raw <- resolve_column(raw, c("characteristics","characteristics_ch1"), "characteristics")
  raw$sample_id <- as.character(raw$sample_id)

  if (any(is.na(raw$sample_id) | str_trim(raw$sample_id) == "")) {
    stop2("Raw metadata has NA/empty sample_id | File: ", opt$meta_raw)
  }
  if (any(duplicated(raw$sample_id))) {
    dup <- unique(raw$sample_id[duplicated(raw$sample_id)])
    stop2("Raw metadata has duplicated sample_id: ", paste(head(dup, 10), collapse = ", "))
  }

  dec <- read_tsv(opt$decision, show_col_types = FALSE)
  dec <- resolve_column(dec, c("sample_id","sample","gsm","geo_accession","accession"), "sample_id")
  dec <- resolve_column(dec, c("include"), "include")
  dec <- resolve_column(dec, c("group_label","group","group_id"), "group_label")
  dec <- resolve_column(dec, c("case_control","group_role"), "case_control")
  dec <- resolve_column(dec, c("reason_exclude","exclude_reason"), "reason_exclude")
  dec$sample_id <- as.character(dec$sample_id)
  dec$include <- normalize_include(dec$include)
  dec$case_control <- normalize_case_control(dec$case_control)

  if (any(is.na(dec$sample_id) | str_trim(dec$sample_id) == "")) {
    stop2("Decision table has NA/empty sample_id | File: ", opt$decision)
  }
  if (any(duplicated(dec$sample_id))) {
    dup <- unique(dec$sample_id[duplicated(dec$sample_id)])
    stop2("Decision table has duplicated sample_id: ", paste(head(dup, 10), collapse = ", "))
  }
  if (any(is.na(dec$include))) {
    bad <- dec$sample_id[is.na(dec$include)]
    stop2("Decision include contains unrecognized values | sample_id: ", paste(head(bad, 10), collapse = ", "))
  }

  missing_case_control <- dec$sample_id[dec$include & is.na(dec$case_control)]
  if (length(missing_case_control) > 0) {
    stop2(
      "Included decision rows require case_control=case/control | sample_id: ",
      paste(head(missing_case_control, 10), collapse = ", ")
    )
  }

  missing_in_raw <- setdiff(dec$sample_id, raw$sample_id)
  if (length(missing_in_raw) > 0) {
    stop2("Decision sample_id not found in raw metadata: ", paste(head(missing_in_raw, 10), collapse = ", "))
  }

  if (!is.null(opt$override) && !is.na(opt$override) && nzchar(opt$override) && file.exists(opt$override)) {
    ov <- read_tsv(opt$override, show_col_types = FALSE)
    ov <- resolve_column(ov, c("sample_id","sample","gsm","geo_accession","accession"), "sample_id")
    ov <- resolve_column(ov, c("override_include","include_override"), "override_include")
    ov <- resolve_column(ov, c("override_group_label","group_label_override"), "override_group_label")
    ov <- resolve_column(ov, c("override_reason","reason_override"), "override_reason")
    ov$sample_id <- as.character(ov$sample_id)
    ov$override_include <- normalize_include(ov$override_include)

    if (any(is.na(ov$sample_id) | str_trim(ov$sample_id) == "")) {
      stop2("Override table has NA/empty sample_id | File: ", opt$override)
    }
    if (any(duplicated(ov$sample_id))) {
      dup <- unique(ov$sample_id[duplicated(ov$sample_id)])
      stop2("Override table has duplicated sample_id: ", paste(head(dup, 10), collapse = ", "))
    }
    bad_reason <- ov$sample_id[
      (!is.na(ov$override_include) | (!is.na(ov$override_group_label) & str_trim(as.character(ov$override_group_label)) != "")) &
      (is.na(ov$override_reason) | str_trim(as.character(ov$override_reason)) == "")
    ]
    if (length(bad_reason) > 0) {
      stop2("Override rows require override_reason | sample_id: ", paste(head(bad_reason, 10), collapse = ", "))
    }
    missing_ov_in_raw <- setdiff(ov$sample_id, raw$sample_id)
    if (length(missing_ov_in_raw) > 0) {
      stop2("Override sample_id not found in raw metadata: ", paste(head(missing_ov_in_raw, 10), collapse = ", "))
    }
  } else {
    ov <- tibble(
      sample_id = raw$sample_id,
      override_include = as.logical(rep(NA, length(raw$sample_id))),
      override_group_label = rep(NA_character_, length(raw$sample_id)),
      override_reason = rep(NA_character_, length(raw$sample_id))
    )
  }

  if (!is.null(opt$qc) && !is.na(opt$qc) && nzchar(opt$qc) && file.exists(opt$qc)) {
    qc <- read_tsv(opt$qc, show_col_types = FALSE)
    qc <- resolve_column(qc, c("sample_id","sample","gsm","geo_accession","accession"), "sample_id")
    qc <- resolve_column(qc, c("qc_flag","flag"), "qc_flag")
    qc <- resolve_column(qc, c("qc_reason","reason"), "qc_reason")
    if (!"qc_metric" %in% names(qc)) qc$qc_metric <- NA_character_
    qc$sample_id <- as.character(qc$sample_id)
    if (any(duplicated(qc$sample_id))) {
      qc <- qc %>% group_by(sample_id) %>% slice(1) %>% ungroup()
    }
  } else {
    qc <- tibble(
      sample_id = raw$sample_id,
      qc_flag = rep(NA_character_, length(raw$sample_id)),
      qc_reason = rep(NA_character_, length(raw$sample_id)),
      qc_metric = rep(NA_character_, length(raw$sample_id))
    )
  }

  merged <- raw %>%
    left_join(dec, by = "sample_id") %>%
    left_join(ov, by = "sample_id") %>%
    left_join(qc, by = "sample_id") %>%
    mutate(
      include_from_decision = include,
      group_from_decision = group_label,
      case_control_from_decision = case_control,
      include = dplyr::coalesce(override_include, include),
      group_label = dplyr::coalesce(
        dplyr::na_if(str_trim(as.character(override_group_label)), ""),
        dplyr::na_if(str_trim(as.character(group_label)), "")
      ),
      case_control = normalize_case_control(case_control),
      resolved_from = dplyr::case_when(
        !is.na(override_include) | (!is.na(override_group_label) & str_trim(as.character(override_group_label)) != "") ~ "manual_override",
        TRUE ~ "decision"
      ),
      override_applied = resolved_from == "manual_override"
    )

  if (any(is.na(merged$include))) {
    miss <- merged$sample_id[is.na(merged$include)]
    stop2("Merged include is NA. Raw samples must all have a decision or override | sample_id: ",
          paste(head(miss, 10), collapse = ", "))
  }

  if (sum(merged$include, na.rm = TRUE) == 0) {
    stop2("Merged invalid: include is all FALSE")
  }

  bad_true_no_group <- merged$sample_id[
    merged$include & (is.na(merged$group_label) | str_trim(as.character(merged$group_label)) == "")
  ]
  if (length(bad_true_no_group) > 0) {
    stop2("Included samples require non-empty group_label | sample_id: ",
          paste(head(bad_true_no_group, 10), collapse = ", "))
  }

  bad_true_no_role <- merged$sample_id[merged$include & is.na(merged$case_control)]
  if (length(bad_true_no_role) > 0) {
    stop2("Included samples require case_control=case/control | sample_id: ",
          paste(head(bad_true_no_role, 10), collapse = ", "))
  }

  included_role_map <- merged %>%
    filter(include) %>%
    distinct(group_label, case_control)

  inconsistent_groups <- included_role_map %>%
    count(group_label, name = "n_roles") %>%
    filter(n_roles != 1)
  if (nrow(inconsistent_groups) > 0) {
    stop2(
      "Each included group_label must map to exactly one case_control role | group_label: ",
      paste(inconsistent_groups$group_label, collapse = ", ")
    )
  }

  role_levels <- sort(unique(included_role_map$case_control))
  if (!identical(role_levels, c("case", "control"))) {
    stop2(
      "Included groups must contain both case and control roles | found: ",
      paste(role_levels, collapse = ", ")
    )
  }

  # Excluded rows do not participate in the V1 contrast.
  merged$case_control[!merged$include] <- NA_character_
  merged$include <- ifelse(merged$include, "TRUE", "FALSE")

  out_file <- file.path(opt$out, "sample_metadata_merged.tsv")
  write_tsv(merged, out_file)

  summary_tbl <- tibble(
    gse = ifelse(is.null(opt$gse), NA_character_, opt$gse),
    n_raw = nrow(raw),
    n_included = sum(merged$include == "TRUE"),
    n_excluded = sum(merged$include == "FALSE"),
    n_override_applied = sum(merged$override_applied, na.rm = TRUE),
    group_levels_included = paste(sort(unique(merged$group_label[merged$include == "TRUE"])), collapse = ";"),
    case_control_levels_included = paste(sort(unique(merged$case_control[merged$include == "TRUE"])), collapse = ";"),
    group_case_control_mapping = paste(
      paste0(included_role_map$group_label, "=", included_role_map$case_control),
      collapse = ";"
    )
  )
  summary_file <- file.path(opt$out, "decision_resolution_summary.tsv")
  write_tsv(summary_tbl, summary_file)

  cat("Wrote: ", out_file, "\n", sep = "")
  cat("Wrote: ", summary_file, "\n", sep = "")
}

main()

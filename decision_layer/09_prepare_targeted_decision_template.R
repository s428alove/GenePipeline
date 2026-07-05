#!/usr/bin/env Rscript
# ============================================================
# 09_prepare_targeted_decision_template.R
#
# Purpose:
#   - Help you quickly label samples for targeted gene plots:
#       include (TRUE/FALSE)
#       group_label (e.g., Normal / PanIN / Cancer)
#   - Based on keyword rules applied to sample_metadata_raw.tsv fields.
#
# Inputs:
#   data_processed/<GSE>/sample_metadata_raw.tsv
#   data_processed/<GSE>/sample_metadata_decision.tsv
#
# Outputs:
#   data_processed/<GSE>/targeted_decision_suggestions.tsv   (always)
#   data_processed/<GSE>/sample_metadata_decision.tsv        (only if --apply TRUE)
#   data_processed/<GSE>/_engineering/backup/ ...            (if apply)
#
# Notes:
#   - Single source of truth is sample_metadata_decision.tsv
#   - This script can:
#       (A) Suggest-only (default): write suggestions TSV for review
#       (B) Apply: update decision TSV (with backup), respecting overwrite policy
# ============================================================

suppressPackageStartupMessages({
  library(optparse)
  library(readr)
  library(dplyr)
  library(stringr)
  library(tibble)
  library(jsonlite)
})

stop2 <- function(...) stop(paste0(..., collapse = ""), call. = FALSE)

# ----------------------------
# utils
# ----------------------------
normalize_include_to_tf <- function(x) {
  if (is.logical(x)) return(ifelse(is.na(x), NA_character_, ifelse(x, "TRUE", "FALSE")))
  x0 <- as.character(x)
  x1 <- str_trim(tolower(x0))
  out <- rep(NA_character_, length(x1))
  out[x1 %in% c("true","t","1","yes","y","include","included","ok","go","run")] <- "TRUE"
  out[x1 %in% c("false","f","0","no","n","exclude","excluded","stop","skip")] <- "FALSE"
  out
}

# safe concat text fields for matching
concat_fields <- function(df, fields) {
  present <- fields[fields %in% names(df)]
  if (length(present) == 0) return(rep("", nrow(df)))
  # join with delimiter to preserve some interpretability
  txt <- apply(df[, present, drop = FALSE], 1, function(row) {
    paste(na.omit(as.character(row)), collapse = " | ")
  })
  txt[is.na(txt)] <- ""
  txt
}

# keyword matching (case-insensitive)
# - include_any: if ANY keyword matches -> hit
# - exclude_any: if ANY exclude matches -> block hit
match_rule <- function(text_vec, include_any, exclude_any = character(0)) {
  x <- tolower(text_vec)
  
  inc <- tolower(include_any)
  inc <- inc[!is.na(inc) & str_trim(inc) != ""]
  exc <- tolower(exclude_any)
  exc <- exc[!is.na(exc) & str_trim(exc) != ""]
  
  hit_inc <- rep(FALSE, length(x))
  hit_exc <- rep(FALSE, length(x))
  
  if (length(inc) > 0) {
    for (k in inc) hit_inc <- hit_inc | str_detect(x, fixed(k))
  }
  if (length(exc) > 0) {
    for (k in exc) hit_exc <- hit_exc | str_detect(x, fixed(k))
  }
  
  hit_inc & (!hit_exc)
}

# parse comma-separated keywords from CLI
parse_kw <- function(x) {
  if (!nzchar(x)) return(character(0))
  parts <- str_trim(unlist(strsplit(x, ",", fixed = TRUE)))
  parts <- parts[parts != ""]
  unique(parts)
}

# load rules from JSON
# expected JSON schema:
# {
#   "fields": ["title","source_name","characteristics"],
#   "rules": [
#     {"label":"Normal","include":"TRUE","keywords":["normal","adjacent"],"exclude":["cancer"]},
#     {"label":"PanIN","include":"TRUE","keywords":["panin"]},
#     {"label":"Cancer","include":"TRUE","keywords":["cancer","carcinoma","tumor","adenocarcinoma"]}
#   ],
#   "priority": ["Normal","PanIN","Cancer"]
# }
load_rules <- function(rules_json,
                       fields_default,
                       normal_kw, panin_kw, cancer_kw,
                       include_default = "TRUE",
                       labels_default = c("Normal","PanIN","Cancer")) {
  
  if (nzchar(rules_json)) {
    if (!file.exists(rules_json)) stop2("rules_json not found: ", rules_json)
    obj <- jsonlite::fromJSON(rules_json)
    
    fields <- fields_default
    if (!is.null(obj$fields)) fields <- as.character(obj$fields)
    
    if (is.null(obj$rules) || length(obj$rules) == 0) {
      stop2("rules_json missing 'rules' array or it is empty.")
    }
    
    rules <- lapply(obj$rules, function(r) {
      if (is.null(r$label) || !nzchar(r$label)) stop2("rules_json: each rule must have non-empty label.")
      lab <- as.character(r$label)
      
      inc <- include_default
      if (!is.null(r$include)) inc <- as.character(r$include)
      inc2 <- normalize_include_to_tf(inc)
      if (is.na(inc2)) stop2("rules_json: invalid include value for label=", lab, " (must be TRUE/FALSE).")
      
      kw <- character(0)
      if (!is.null(r$keywords)) kw <- as.character(r$keywords)
      kw <- kw[!is.na(kw) & str_trim(kw) != ""]
      if (length(kw) == 0) stop2("rules_json: rule '", lab, "' has empty keywords.")
      
      exc <- character(0)
      if (!is.null(r$exclude)) exc <- as.character(r$exclude)
      exc <- exc[!is.na(exc) & str_trim(exc) != ""]
      
      list(label = lab, include = inc2, keywords = kw, exclude = exc)
    })
    
    priority <- NULL
    if (!is.null(obj$priority)) priority <- as.character(obj$priority)
    if (is.null(priority) || length(priority) == 0) {
      # default: rule order
      priority <- vapply(rules, function(r) r$label, character(1))
    }
    
    return(list(fields = fields, rules = rules, priority = priority, source = "json"))
  }
  
  # CLI/default rules
  rules <- list(
    list(label = "Normal", include = "TRUE",
         keywords = if (length(normal_kw) > 0) normal_kw else c("normal","healthy","benign","non-tumor","non tumor","adjacent","control"),
         exclude  = character(0)),
    list(label = "PanIN", include = "TRUE",
         keywords = if (length(panin_kw) > 0) panin_kw else c("panin"),
         exclude  = character(0)),
    list(label = "Cancer", include = "TRUE",
         keywords = if (length(cancer_kw) > 0) cancer_kw else c("cancer","carcinoma","tumor","tumour","adenocarcinoma","malignant"),
         exclude  = character(0))
  )
  list(fields = fields_default, rules = rules, priority = labels_default, source = "cli/default")
}

# determine winning label per sample given hits + priority
pick_label <- function(hit_labels, priority, allow_ambiguous = FALSE) {
  # hit_labels: character vector of matched labels for one sample
  hit_labels <- unique(hit_labels)
  hit_labels <- hit_labels[!is.na(hit_labels) & hit_labels != ""]
  if (length(hit_labels) == 0) return(list(label = NA_character_, status = "NO_MATCH"))
  if (length(hit_labels) == 1) return(list(label = hit_labels[1], status = "OK"))
  
  # multiple matches
  if (!allow_ambiguous) {
    return(list(label = NA_character_, status = paste0("AMBIGUOUS:", paste(hit_labels, collapse = "|"))))
  }
  
  # choose by priority
  for (p in priority) {
    if (p %in% hit_labels) return(list(label = p, status = paste0("RESOLVED_BY_PRIORITY:", paste(hit_labels, collapse="|"))))
  }
  # fallback first
  list(label = hit_labels[1], status = paste0("RESOLVED_FALLBACK:", paste(hit_labels, collapse="|")))
}

# ----------------------------
# CLI
# ----------------------------
option_list <- list(
  make_option(c("--gse"), type = "character", help = "GSE accession"),
  make_option(c("--out_dir"), type = "character", default = "data_processed", help = "Processed data root"),
  
  make_option(c("--apply"), type = "character", default = "FALSE",
              help = "TRUE/FALSE. If TRUE, write back to sample_metadata_decision.tsv (with backup)."),
  
  make_option(c("--overwrite_group_label"), type = "character", default = "FALSE",
              help = "TRUE/FALSE. If FALSE, only fill empty group_label. If TRUE, overwrite existing group_label."),
  make_option(c("--overwrite_include"), type = "character", default = "FALSE",
              help = "TRUE/FALSE. If FALSE, only fill empty include. If TRUE, overwrite existing include."),
  
  make_option(c("--allow_ambiguous"), type = "character", default = "FALSE",
              help = "TRUE/FALSE. If TRUE, resolve multi-match using priority; else leave as ambiguous (no apply)."),
  
  make_option(c("--fields"), type = "character", default = "title,source_name,characteristics",
              help = "Comma-separated raw fields to search (must exist in sample_metadata_raw.tsv)."),
  
  # rules control
  make_option(c("--rules_json"), type = "character", default = "",
              help = "Optional JSON file for rules. If provided, overrides CLI keyword options."),
  make_option(c("--normal_kw"), type = "character", default = "",
              help = "Override Normal keywords (comma-separated). Used only when rules_json not provided."),
  make_option(c("--panin_kw"), type = "character", default = "",
              help = "Override PanIN keywords (comma-separated). Used only when rules_json not provided."),
  make_option(c("--cancer_kw"), type = "character", default = "",
              help = "Override Cancer keywords (comma-separated). Used only when rules_json not provided."),
  
  # target columns in decision
  make_option(c("--group_col"), type = "character", default = "group_label",
              help = "Decision column to write labels into (default: group_label)."),
  make_option(c("--include_col"), type = "character", default = "include",
              help = "Decision column for include (default: include)."),
  
  # output suggestions path override
  make_option(c("--suggestions_out"), type = "character", default = "",
              help = "Optional override for suggestions TSV output path.")
)

opt <- parse_args(OptionParser(option_list = option_list))
if (is.null(opt$gse) || opt$gse == "") stop2("Missing --gse")

gse <- opt$gse
out_gse_dir <- file.path(opt$out_dir, gse)

raw_path <- file.path(out_gse_dir, "sample_metadata_raw.tsv")
dec_path <- file.path(out_gse_dir, "sample_metadata_decision.tsv")

if (!file.exists(raw_path)) stop2("Not found: ", raw_path)
if (!file.exists(dec_path)) stop2("Not found: ", dec_path)

apply_changes <- {
  x <- normalize_include_to_tf(opt$apply)
  if (is.na(x)) stop2("--apply must be TRUE/FALSE")
  x == "TRUE"
}
overwrite_group <- {
  x <- normalize_include_to_tf(opt$overwrite_group_label)
  if (is.na(x)) stop2("--overwrite_group_label must be TRUE/FALSE")
  x == "TRUE"
}
overwrite_inc <- {
  x <- normalize_include_to_tf(opt$overwrite_include)
  if (is.na(x)) stop2("--overwrite_include must be TRUE/FALSE")
  x == "TRUE"
}
allow_ambiguous <- {
  x <- normalize_include_to_tf(opt$allow_ambiguous)
  if (is.na(x)) stop2("--allow_ambiguous must be TRUE/FALSE")
  x == "TRUE"
}

fields <- str_trim(unlist(strsplit(opt$fields, ",", fixed = TRUE)))
fields <- fields[fields != ""]
if (length(fields) == 0) stop2("No valid --fields provided.")

normal_kw <- parse_kw(opt$normal_kw)
panin_kw  <- parse_kw(opt$panin_kw)
cancer_kw <- parse_kw(opt$cancer_kw)

rule_pack <- load_rules(
  rules_json = opt$rules_json,
  fields_default = fields,
  normal_kw = normal_kw,
  panin_kw = panin_kw,
  cancer_kw = cancer_kw
)
fields_use <- rule_pack$fields
rules <- rule_pack$rules
priority <- rule_pack$priority

# ----------------------------
# load data
# ----------------------------
raw <- readr::read_tsv(raw_path, show_col_types = FALSE)
dec <- readr::read_tsv(dec_path, show_col_types = FALSE)

# normalize schema
if (!("sample_id" %in% names(raw))) {
  cand <- intersect(names(raw), c("sample","GSM","gsm","geo_accession","accession"))
  if (length(cand) > 0) raw <- raw %>% rename(sample_id = all_of(cand[1]))
  else stop2("raw missing sample_id. File: ", raw_path)
}
raw <- raw %>% mutate(sample_id = as.character(sample_id))

if (!("sample_id" %in% names(dec))) {
  cand <- intersect(names(dec), c("sample","GSM","gsm","geo_accession","accession"))
  if (length(cand) > 0) dec <- dec %>% rename(sample_id = all_of(cand[1]))
  else stop2("decision missing sample_id. File: ", dec_path)
}
dec <- dec %>% mutate(sample_id = as.character(sample_id))

# ensure include/group cols exist
if (!(opt$include_col %in% names(dec))) dec[[opt$include_col]] <- NA_character_
if (!(opt$group_col %in% names(dec))) dec[[opt$group_col]] <- NA_character_

# normalize include to TRUE/FALSE/NA (do not force; allow NA for "not decided yet")
dec[[opt$include_col]] <- normalize_include_to_tf(dec[[opt$include_col]])

# align decision to raw sample_id universe (left join raw->dec keeps all raw rows)
base <- raw %>%
  select(sample_id, everything()) %>%
  left_join(dec %>% select(sample_id, all_of(opt$include_col), all_of(opt$group_col)), by = "sample_id")

txt <- concat_fields(base, fields_use)

# ----------------------------
# apply rules: collect hits
# ----------------------------
hit_mat <- matrix(FALSE, nrow = nrow(base), ncol = length(rules))
colnames(hit_mat) <- vapply(rules, function(r) r$label, character(1))

hit_keywords <- vector("list", nrow(base))

for (i in seq_along(rules)) {
  r <- rules[[i]]
  hit <- match_rule(txt, include_any = r$keywords, exclude_any = r$exclude)
  hit_mat[, i] <- hit
  
  # store which keywords matched (for reporting)
  matched <- rep("", nrow(base))
  if (any(hit)) {
    x <- tolower(txt[hit])
    kws <- tolower(r$keywords)
    mk <- lapply(x, function(xx) {
      k_hit <- kws[sapply(kws, function(k) str_detect(xx, fixed(k)))]
      paste(unique(k_hit), collapse = ",")
    })
    matched[hit] <- unlist(mk)
  }
  
  # accumulate per row
  for (rr in which(hit)) {
    hit_keywords[[rr]] <- c(hit_keywords[[rr]], paste0(r$label, "=>", matched[rr]))
  }
}

hit_labels_per_row <- apply(hit_mat, 1, function(row) colnames(hit_mat)[which(row)])

picked <- lapply(hit_labels_per_row, pick_label, priority = priority, allow_ambiguous = allow_ambiguous)
suggest_label <- vapply(picked, function(x) x$label, character(1))
match_status  <- vapply(picked, function(x) x$status, character(1))

# suggested include: by winning rule include (only when OK/resolved)
rule_include_map <- setNames(vapply(rules, function(r) r$include, character(1)),
                             vapply(rules, function(r) r$label, character(1)))
suggest_include <- rep(NA_character_, nrow(base))
ok_mask <- !is.na(suggest_label) & !str_starts(match_status, "AMBIGUOUS") & match_status != "NO_MATCH"
suggest_include[ok_mask] <- rule_include_map[suggest_label[ok_mask]]

# current values
cur_inc <- base[[opt$include_col]]
cur_grp <- as.character(base[[opt$group_col]])

# propose new values (respect overwrite policy)
new_inc <- cur_inc
new_grp <- cur_grp

# include apply rule
if (overwrite_inc) {
  new_inc[ok_mask] <- suggest_include[ok_mask]
} else {
  # fill only NA
  fill_mask <- ok_mask & is.na(new_inc)
  new_inc[fill_mask] <- suggest_include[fill_mask]
}

# group apply rule
if (overwrite_group) {
  new_grp[ok_mask] <- suggest_label[ok_mask]
} else {
  fill_mask <- ok_mask & (is.na(new_grp) | str_trim(new_grp) == "")
  new_grp[fill_mask] <- suggest_label[fill_mask]
}

# suggestions report
suggestions <- tibble(
  sample_id = base$sample_id,
  current_include = cur_inc,
  current_group_label = cur_grp,
  suggested_include = suggest_include,
  suggested_group_label = suggest_label,
  match_status = match_status,
  matched_detail = vapply(hit_keywords, function(v) paste(v, collapse=";"), character(1)),
  final_include_if_applied = new_inc,
  final_group_label_if_applied = new_grp
)

# write suggestions
sugg_out <- opt$suggestions_out
if (!nzchar(sugg_out)) sugg_out <- file.path(out_gse_dir, "targeted_decision_suggestions.tsv")
readr::write_tsv(suggestions, sugg_out)

cat("Wrote suggestions: ", sugg_out, "\n", sep = "")
cat("Rule source: ", rule_pack$source, "\n", sep = "")
cat("Fields searched: ", paste(fields_use, collapse=", "), "\n", sep = "")
cat("Rules (priority order): ", paste(priority, collapse=" > "), "\n", sep = "")
cat("Counts by suggested_group_label:\n")
print(suggestions %>% count(suggested_group_label, match_status, name="n") %>% arrange(desc(n)))

# ----------------------------
# apply to decision.tsv (optional)
# ----------------------------
if (apply_changes) {
  # Block apply if ambiguous exists (unless allow_ambiguous TRUE already resolved)
  amb <- which(str_starts(suggestions$match_status, "AMBIGUOUS"))
  if (length(amb) > 0) {
    cat("WARNING: ambiguous matches remain (not applied to those rows). n=", length(amb), "\n", sep = "")
  }
  
  # Prepare updated decision table: start from existing dec to preserve other columns
  dec2 <- dec
  
  # ensure cols exist
  if (!(opt$include_col %in% names(dec2))) dec2[[opt$include_col]] <- NA_character_
  if (!(opt$group_col %in% names(dec2))) dec2[[opt$group_col]] <- NA_character_
  
  dec2$sample_id <- as.character(dec2$sample_id)
  
  # Bring raw universe: for samples missing in decision, add rows
  missing_rows <- setdiff(raw$sample_id, dec2$sample_id)
  if (length(missing_rows) > 0) {
    add <- tibble(sample_id = missing_rows)
    for (nm in setdiff(names(dec2), "sample_id")) add[[nm]] <- NA
    dec2 <- bind_rows(dec2, add)
  }
  
  # align
  idx <- match(dec2$sample_id, suggestions$sample_id)
  has <- !is.na(idx)
  
  # backup
  bk_dir <- file.path(out_gse_dir, "_engineering", "backup")
  dir.create(bk_dir, recursive = TRUE, showWarnings = FALSE)
  ts <- format(Sys.time(), "%Y%m%d_%H%M%S")
  bk_path <- file.path(bk_dir, paste0("sample_metadata_decision.tsv.", ts, ".bak"))
  file.copy(dec_path, bk_path, overwrite = TRUE)
  cat("Backup decision: ", bk_path, "\n", sep = "")
  
  # apply include/group
  # normalize include output to TRUE/FALSE if set
  final_inc <- suggestions$final_include_if_applied[idx[has]]
  final_inc <- normalize_include_to_tf(final_inc)
  final_grp <- suggestions$final_group_label_if_applied[idx[has]]
  
  dec2[[opt$include_col]][has] <- final_inc
  dec2[[opt$group_col]][has] <- final_grp
  
  # write back
  readr::write_tsv(dec2, dec_path)
  cat("Applied updates to: ", dec_path, "\n", sep = "")
  cat("Next: re-run 00_make_sample_metadata_merged.R for this GSE.\n")
} else {
  cat("Apply=FALSE: decision.tsv NOT modified. Review suggestions then re-run with --apply TRUE.\n")
}

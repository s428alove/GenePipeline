# V1_analysis/scripts/_lib/targeted_gene_helpers.R
# ============================================================
# Helpers for targeted gene visualization modules.
# Upstream objects (from validate_v1_inputs):
#   expr_mat: numeric matrix [gene x sample] (included samples only)
#   meta_inc: data.frame with sample_id + group columns (aligned)
#
# Provides:
#   - resolve_gene_ids()
#   - make_gene_long_df()
#   - plot_gene_violin_box_jitter()
#   - plot_gene_box_jitter()
#   - compute_gene_stats()
#   - compute_gene_trend_stats()       (ordered trend)
#   - plot_gene_ordered_trend()
#   - write_gene_outputs()             (main per-gene writer)
# ============================================================

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(tibble)
  library(stringr)
  library(ggplot2)
  library(readr)
})

stop2 <- function(...) stop(paste0(..., collapse=""), call. = FALSE)

# ----------------------------
# gene id resolution
# ----------------------------
.norm_gene_query <- function(x) {
  x <- as.character(x)
  x <- str_trim(x)
  x[x == ""] <- NA_character_
  x
}

.suggest_gene_ids <- function(query, gene_ids, max_n = 20) {
  q <- .norm_gene_query(query)
  if (is.na(q)) return(character(0))
  
  gid <- as.character(gene_ids)
  gid <- gid[!is.na(gid) & gid != ""]
  
  q_lc <- tolower(q)
  gid_lc <- tolower(gid)
  
  hit1 <- gid[gid_lc == q_lc]
  if (length(hit1) > 0) return(head(unique(hit1), max_n))
  
  hit2 <- gid[str_starts(gid_lc, q_lc)]
  if (length(hit2) > 0) return(head(unique(hit2), max_n))
  
  hit3 <- gid[str_detect(gid_lc, fixed(q_lc))]
  head(unique(hit3), max_n)
}

resolve_gene_ids <- function(expr_mat, queries, mode = "exact", suggest_n = 20) {
  if (is.null(expr_mat) || nrow(expr_mat) == 0) stop2("resolve_gene_ids: expr_mat is empty.")
  gene_ids <- rownames(expr_mat)
  if (is.null(gene_ids) || length(gene_ids) == 0) stop2("resolve_gene_ids: expr_mat has no rownames (gene_id).")
  
  mode <- tolower(mode)
  if (!mode %in% c("exact", "ci")) stop2("resolve_gene_ids: mode must be 'exact' or 'ci'.")
  
  qs <- .norm_gene_query(queries)
  qs <- qs[!is.na(qs)]
  if (length(qs) == 0) stop2("No valid gene queries provided.")
  
  resolved <- character(0)
  missing <- character(0)
  suggestions <- list()
  gene_set <- gene_ids
  
  for (q in qs) {
    if (q %in% gene_set) {
      resolved <- c(resolved, q); next
    }
    q_lc <- tolower(q)
    gid_lc <- tolower(gene_set)
    ci_hits <- gene_set[gid_lc == q_lc]
    
    if (length(ci_hits) == 1) {
      resolved <- c(resolved, ci_hits[1]); next
    }
    
    missing <- c(missing, q)
    suggestions[[q]] <- .suggest_gene_ids(q, gene_set, max_n = suggest_n)
  }
  
  list(
    resolved = unique(resolved),
    missing = unique(missing),
    suggestions = suggestions
  )
}

# ----------------------------
# build long df for plotting/stats
# ----------------------------
make_gene_long_df <- function(expr_mat, meta_inc, gene_id, group_col = "group_label") {
  if (!(gene_id %in% rownames(expr_mat))) stop2("Gene not found in expr_mat: ", gene_id)
  if (!("sample_id" %in% names(meta_inc))) stop2("meta_inc missing sample_id.")
  if (!(group_col %in% names(meta_inc))) stop2("meta_inc missing group_col: ", group_col)
  
  meta2 <- meta_inc[match(colnames(expr_mat), meta_inc$sample_id), , drop = FALSE]
  if (any(is.na(meta2$sample_id))) stop2("make_gene_long_df: alignment error between expr_mat and meta_inc.")
  
  vals <- as.numeric(expr_mat[gene_id, , drop = TRUE])
  df <- tibble(
    gene_id = gene_id,
    sample_id = colnames(expr_mat),
    expression = vals
  ) %>%
    left_join(meta2 %>% select(sample_id, !!group_col), by = "sample_id") %>%
    rename(group = !!group_col)
  
  df$group <- as.character(df$group)
  df$group[is.na(df$group) | str_trim(df$group) == ""] <- "NA"
  df$group <- factor(df$group)
  
  df
}

# ----------------------------
# plotting
# ----------------------------
.plot_subtitle_n <- function(df_long) {
  n_by <- df_long %>% count(group, name = "n")
  paste0("n: ", paste0(n_by$group, "=", n_by$n, collapse = ", "))
}

plot_gene_violin_box_jitter <- function(df_long,
                                        title = NULL,
                                        subtitle = NULL,
                                        ylab = "Expression (log2)",
                                        point_size = 1.6,
                                        jitter_width = 0.12,
                                        violin_trim = TRUE) {
  if (!all(c("group","expression","sample_id","gene_id") %in% names(df_long))) {
    stop2("plot_gene_violin_box_jitter: df_long missing required columns.")
  }
  if (is.null(title)) title <- paste0(df_long$gene_id[1], " expression")
  if (is.null(subtitle)) subtitle <- .plot_subtitle_n(df_long)
  
  ggplot(df_long, aes(x = group, y = expression, fill = group)) +
    geom_violin(trim = violin_trim, alpha = 0.6, linewidth = 0.25) +
    geom_boxplot(width = 0.25, outlier.shape = NA, alpha = 0.55, linewidth = 0.25) +
    geom_jitter(aes(color = group),
                width = jitter_width, height = 0,
                size = point_size, alpha = 0.85, show.legend = FALSE) +
    theme_bw() +
    theme(legend.position = "none",
          axis.text.x = element_text(angle = 20, hjust = 1)) +
    labs(title = title, subtitle = subtitle, x = NULL, y = ylab)
}

# ✅ 你要的「箱型圖 + 點」（不含 violin）
plot_gene_box_jitter <- function(df_long,
                                 title = NULL,
                                 subtitle = NULL,
                                 ylab = "Expression (log2)",
                                 point_size = 1.7,
                                 jitter_width = 0.12) {
  if (!all(c("group","expression","sample_id","gene_id") %in% names(df_long))) {
    stop2("plot_gene_box_jitter: df_long missing required columns.")
  }
  if (is.null(title)) title <- paste0(df_long$gene_id[1], " expression")
  if (is.null(subtitle)) subtitle <- .plot_subtitle_n(df_long)
  
  ggplot(df_long, aes(x = group, y = expression)) +
    geom_boxplot(aes(fill = group), width = 0.35, outlier.shape = NA, alpha = 0.6, linewidth = 0.25) +
    geom_jitter(aes(color = group),
                width = jitter_width, height = 0,
                size = point_size, alpha = 0.85, show.legend = FALSE) +
    theme_bw() +
    theme(legend.position = "none",
          axis.text.x = element_text(angle = 20, hjust = 1)) +
    labs(title = title, subtitle = subtitle, x = NULL, y = ylab)
}

# ----------------------------
# stats
# ----------------------------
compute_gene_stats <- function(df_long) {
  df <- df_long %>%
    filter(!is.na(expression)) %>%
    mutate(group = droplevels(group))
  
  n_groups <- nlevels(df$group)
  if (n_groups < 2) {
    return(tibble(method="NA", p_value=NA_real_, n_groups=n_groups,
                  note="Less than 2 groups; no test."))
  }
  
  counts <- df %>% count(group, name = "n")
  min_n <- min(counts$n)
  
  if (n_groups == 2) {
    res <- tryCatch(wilcox.test(expression ~ group, data = df, exact = FALSE),
                    error=function(e) NULL)
    p <- if (!is.null(res)) res$p.value else NA_real_
    return(tibble(method="wilcox", p_value=p, n_groups=2,
                  min_n_per_group=min_n,
                  groups=paste(levels(df$group), collapse="|")))
  }
  
  res <- tryCatch(kruskal.test(expression ~ group, data = df),
                  error=function(e) NULL)
  p <- if (!is.null(res)) res$p.value else NA_real_
  
  tibble(method="kruskal", p_value=p, n_groups=n_groups,
         min_n_per_group=min_n,
         groups=paste(levels(df$group), collapse="|"))
}

# ✅ 有序趨勢檢定：給定 ordered_levels（例如 Normal,PanIN,Cancer）
# - 先把 group 轉成 order_score 1..K
# - Spearman correlation：order_score vs expression
# - Linear regression slope：expression ~ order_score（補一個 slope p-value）
compute_gene_trend_stats <- function(df_long, ordered_levels) {
  if (length(ordered_levels) < 2) {
    return(tibble(method="NA", p_value=NA_real_, note="ordered_levels < 2"))
  }
  
  lev <- str_trim(as.character(ordered_levels))
  lev <- lev[lev != ""]
  if (length(lev) < 2) {
    return(tibble(method="NA", p_value=NA_real_, note="ordered_levels < 2 after trim"))
  }
  
  df <- df_long %>%
    mutate(group_chr = as.character(group)) %>%
    filter(!is.na(expression)) %>%
    filter(group_chr %in% lev) %>%
    mutate(
      group_ord = factor(group_chr, levels = lev, ordered = TRUE),
      order_score = as.numeric(group_ord)
    )
  
  if (nrow(df) < 3) {
    return(tibble(method="NA", p_value=NA_real_, note="Too few samples after filtering to ordered_levels"))
  }
  
  # Spearman
  sp <- tryCatch(cor.test(df$order_score, df$expression, method = "spearman", exact = FALSE),
                 error = function(e) NULL)
  sp_rho <- if (!is.null(sp)) unname(sp$estimate) else NA_real_
  sp_p   <- if (!is.null(sp)) sp$p.value else NA_real_
  
  # Linear slope
  fit <- tryCatch(lm(expression ~ order_score, data = df),
                  error = function(e) NULL)
  slope <- NA_real_
  slope_p <- NA_real_
  if (!is.null(fit)) {
    co <- summary(fit)$coefficients
    if ("order_score" %in% rownames(co)) {
      slope <- co["order_score", "Estimate"]
      slope_p <- co["order_score", "Pr(>|t|)"]
    }
  }
  
  counts <- df %>% count(group_ord, name="n")
  tibble(
    method = "trend_spearman+lm",
    spearman_rho = sp_rho,
    spearman_p = sp_p,
    lm_slope = slope,
    lm_slope_p = slope_p,
    n_samples = nrow(df),
    groups_used = paste(lev, collapse="|"),
    group_counts = paste0(as.character(counts$group_ord), ":", counts$n, collapse=";")
  )
}

# ✅ 趨勢圖（有序 x 軸 + 點 + 盒鬚 + 趨勢線）
plot_gene_ordered_trend <- function(df_long, ordered_levels,
                                    title = NULL,
                                    subtitle = NULL,
                                    ylab = "Expression (log2)",
                                    point_size = 1.6,
                                    jitter_width = 0.10) {
  lev <- str_trim(as.character(ordered_levels))
  lev <- lev[lev != ""]
  
  df <- df_long %>%
    mutate(group_chr = as.character(group)) %>%
    filter(group_chr %in% lev) %>%
    mutate(group_ord = factor(group_chr, levels = lev, ordered = TRUE))
  
  if (nrow(df) == 0) stop2("plot_gene_ordered_trend: no samples after filtering to ordered_levels.")
  
  if (is.null(title)) title <- paste0(df$gene_id[1], " ordered trend")
  if (is.null(subtitle)) subtitle <- .plot_subtitle_n(df %>% mutate(group = group_ord))
  
  ggplot(df, aes(x = group_ord, y = expression)) +
    geom_boxplot(aes(fill = group_ord), width = 0.35, outlier.shape = NA, alpha = 0.6, linewidth = 0.25) +
    geom_jitter(aes(color = group_ord),
                width = jitter_width, height = 0,
                size = point_size, alpha = 0.85, show.legend = FALSE) +
    # add a trend line on numeric score
    geom_smooth(aes(x = as.numeric(group_ord), y = expression),
                method = "lm", se = TRUE, inherit.aes = FALSE) +
    scale_x_discrete(drop = FALSE) +
    theme_bw() +
    theme(legend.position = "none",
          axis.text.x = element_text(angle = 20, hjust = 1)) +
    labs(title = title, subtitle = subtitle, x = NULL, y = ylab)
}

# ----------------------------
# write outputs for one gene
# ----------------------------
# plot_style: "violin" or "box"
# ordered_levels: character vector (optional) for trend test + trend plot
write_gene_outputs <- function(out_dir,
                               gse,
                               gene_id,
                               df_long,
                               group_col_used,
                               plot_style = "violin",
                               ordered_levels = NULL,
                               dpi = 300,
                               width = 7,
                               height = 5) {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  
  plot_style <- tolower(plot_style)
  if (!plot_style %in% c("violin", "box")) stop2("plot_style must be 'violin' or 'box'.")
  
  # group stats
  stats <- compute_gene_stats(df_long)
  stats_path <- file.path(out_dir, "stats.tsv")
  readr::write_tsv(stats, stats_path)
  
  # main plot subtitle: n + p
  n_text <- .plot_subtitle_n(df_long)
  p_txt <- if (!is.na(stats$p_value[1])) sprintf("p=%.3g", stats$p_value[1]) else "p=NA"
  subtitle <- paste0("GSE: ", gse,
                     " | group_col: ", group_col_used,
                     " | ", n_text,
                     " | ", stats$method[1], " ", p_txt)
  
  p_main <- if (plot_style == "violin") {
    plot_gene_violin_box_jitter(
      df_long,
      title = paste0(gse, " | ", gene_id),
      subtitle = subtitle
    )
  } else {
    plot_gene_box_jitter(
      df_long,
      title = paste0(gse, " | ", gene_id),
      subtitle = subtitle
    )
  }
  
  main_png <- file.path(out_dir, ifelse(plot_style == "violin", "gene_violin.png", "gene_box.png"))
  ggsave(main_png, p_main, width = width, height = height, dpi = dpi)
  
  # ordered trend outputs (optional)
  trend_stats <- NULL
  trend_stats_path <- NULL
  trend_png <- NULL
  
  if (!is.null(ordered_levels) && length(ordered_levels) >= 2) {
    trend_stats <- compute_gene_trend_stats(df_long, ordered_levels)
    trend_stats_path <- file.path(out_dir, "trend_stats.tsv")
    readr::write_tsv(trend_stats, trend_stats_path)
    
    # subtitle add spearman p + slope p (if present)
    sp_p <- trend_stats$spearman_p[1]
    sl_p <- trend_stats$lm_slope_p[1]
    t_sub <- paste0(
      "Ordered: ", paste(ordered_levels, collapse="→"),
      " | spearman p=", ifelse(is.na(sp_p), "NA", sprintf("%.3g", sp_p)),
      " | slope p=", ifelse(is.na(sl_p), "NA", sprintf("%.3g", sl_p))
    )
    
    p_trend <- plot_gene_ordered_trend(
      df_long,
      ordered_levels = ordered_levels,
      title = paste0(gse, " | ", gene_id, " (ordered)"),
      subtitle = t_sub
    )
    trend_png <- file.path(out_dir, "gene_ordered_trend.png")
    ggsave(trend_png, p_trend, width = width, height = height, dpi = dpi)
  }
  
  list(
    paths = list(
      main_plot_png = main_png,
      stats_tsv = stats_path,
      trend_plot_png = trend_png,
      trend_stats_tsv = trend_stats_path
    ),
    stats = stats,
    trend_stats = trend_stats
  )
}

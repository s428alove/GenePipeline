forest_from_top_table <- function(
    file_path,
    out_png,
    gene_col = NULL,          # 可留 NULL 讓它自動猜
    effect_col = NULL,        # 可留 NULL 讓它自動猜（logFC / log2FC / log2FoldChange）
    p_col = NULL,             # 可留 NULL 讓它自動猜（adj.P.Val / padj / FDR）
    t_col = NULL,             # 可留 NULL 讓它自動猜（t）
    se_col = NULL,            # 若你的表本來就有 SE/lfcSE，可指定；否則用 t 反推
    ci_lower_col = NULL,      # 若你的表本來就有 CI lower/upper，可指定
    ci_upper_col = NULL,
    top_n = 20,
    target_genes = NULL,      # 指定基因清單（A 模式）；NULL 則用 top_n（padj 最小）
    gene_id_type = c("symbol", "id"),  # target_genes 用哪種對應（symbol 或原始 id）
    delimiter = "\t",         # tsv = "\t"；csv = ","
    has_header = TRUE
) {
  gene_id_type <- match.arg(gene_id_type)
  
  suppressPackageStartupMessages({
    library(dplyr)
    library(readr)
    library(tibble)
    library(ggplot2)
  })
  
  # ---------- 1) 讀檔 ----------
  df <- readr::read_delim(
    file = file_path,
    delim = delimiter,
    col_names = has_header,
    show_col_types = FALSE,
    progress = FALSE
  )
  
  # 有些 top.table 會把基因ID放在 rownames；這裡嘗試補一欄
  if (!(".rownames" %in% names(df)) && !any(grepl("^gene$|^gene_id$|^symbol$", names(df), ignore.case = TRUE))) {
    # 不強制；後面會用自動偵測處理
  }
  
  nms <- names(df)
  
  # ---------- 2) 自動偵測欄位 ----------
  pick_first <- function(cands) {
    hit <- cands[cands %in% nms]
    if (length(hit) > 0) hit[1] else NA_character_
  }
  
  if (is.null(effect_col)) {
    effect_col <- pick_first(c("logFC", "log2FC", "log2FoldChange", "LFC"))
  }
  if (is.null(p_col)) {
    p_col <- pick_first(c("adj.P.Val", "padj", "FDR", "qvalue", "q_value", "adj_p", "adjP"))
    if (is.na(p_col)) p_col <- pick_first(c("P.Value", "pvalue", "p_value"))
  }
  if (is.null(t_col)) {
    t_col <- pick_first(c("t", "tstat", "t_stat"))
  }
  
  if (is.null(gene_col)) {
    gene_col <- pick_first(c("gene", "gene_id", "Gene", "GeneID", "ENSEMBL", "symbol", "SYMBOL", "Gene.symbol"))
    # 如果還是找不到，嘗試用第一欄當 gene（很多 top.table 第一欄就是基因）
    if (is.na(gene_col)) gene_col <- nms[1]
  }
  
  # ---------- 3) 整理核心欄位 ----------
  if (is.na(effect_col) || !(effect_col %in% nms)) {
    stop("找不到效果量欄位（logFC/log2FC/log2FoldChange）。請手動指定 effect_col。")
  }
  if (is.na(gene_col) || !(gene_col %in% nms)) {
    stop("找不到基因欄位。請手動指定 gene_col。")
  }
  
  core <- df %>%
    dplyr::mutate(
      .gene = as.character(.data[[gene_col]]),
      .effect = suppressWarnings(as.numeric(.data[[effect_col]]))
    )
  
  if (!is.na(p_col) && (p_col %in% nms)) {
    core <- core %>% dplyr::mutate(.p = suppressWarnings(as.numeric(.data[[p_col]])))
  } else {
    core <- core %>% dplyr::mutate(.p = NA_real_)
  }
  
  # ---------- 4) 取得 / 計算 CI ----------
  # 4a) 若表本來就有 CI 欄
  if (!is.null(ci_lower_col) && !is.null(ci_upper_col) &&
      ci_lower_col %in% nms && ci_upper_col %in% nms) {
    
    core <- core %>%
      dplyr::mutate(
        .ci_l = suppressWarnings(as.numeric(.data[[ci_lower_col]])),
        .ci_u = suppressWarnings(as.numeric(.data[[ci_upper_col]]))
      )
    
  } else {
    # 4b) 若有 SE 欄
    if (!is.null(se_col) && (se_col %in% nms)) {
      core <- core %>%
        dplyr::mutate(.se = suppressWarnings(as.numeric(.data[[se_col]])))
    } else {
      # 4c) 用 t 反推 SE
      if (is.na(t_col) || !(t_col %in% nms)) {
        stop("你的檔案沒有 CI/SE，也沒有 t 欄位，因此無法計算 CI。你可以：\n- 改成提供 se_col 或 ci_lower/ci_upper\n- 或換成只畫點（我也可以給你那個版本）")
      }
      core <- core %>%
        dplyr::mutate(
          .t = suppressWarnings(as.numeric(.data[[t_col]])),
          .se = dplyr::if_else(!is.na(.t) & .t != 0, abs(.effect / .t), NA_real_)
        )
    }
    
    core <- core %>%
      dplyr::mutate(
        .ci_l = .effect - 1.96 * .se,
        .ci_u = .effect + 1.96 * .se
      )
  }
  
  # ---------- 5) 選基因（A：指定清單 or top_n） ----------
  if (!is.null(target_genes)) {
    core2 <- core %>% dplyr::filter(.gene %in% target_genes)
  } else {
    core2 <- core %>%
      dplyr::filter(!is.na(.p)) %>%
      dplyr::arrange(.p) %>%
      dplyr::slice(1:top_n)
  }
  
  if (nrow(core2) == 0) stop("選出來的基因為 0 列：請確認 gene 名稱是否對得上，或 target_genes 是否存在於檔案中。")
  
  # 排序讓圖比較好看：p 小的在上面
  core2 <- core2 %>%
    dplyr::mutate(.gene = factor(.gene, levels = rev(.gene[order(.p, decreasing = FALSE)])))
  
  # ---------- 6) 畫圖 + 存檔 ----------
  p <- ggplot(core2, aes(x = .effect, y = .gene)) +
    geom_errorbarh(aes(xmin = .ci_l, xmax = .ci_u), height = 0.2) +
    geom_point() +
    geom_vline(xintercept = 0, linetype = "dashed") +
    xlab(paste0(effect_col, " (case / control)")) +
    ylab("Gene") +
    ggtitle("Forest plot from top.table") +
    theme_minimal()
  
  ggsave(out_png, plot = p, width = 8, height = 6, dpi = 300)
  print(p)
  
  invisible(list(
    data_used = core2,
    plot = p,
    detected = list(
      gene_col = gene_col, effect_col = effect_col, p_col = p_col, t_col = t_col
    )
  ))
}

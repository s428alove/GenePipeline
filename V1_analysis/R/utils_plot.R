############################################################
# utils_plot.R
# 跟畫圖相關的共用設定
############################################################

# 統一 ggplot 主題（可以之後慢慢調）
set_default_ggplot_theme <- function() {
  theme_set(
    ggplot2::theme_bw(base_size = 12)
  )
}
# 
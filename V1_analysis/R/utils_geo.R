############################################################
# utils_geo.R
# 跟 GEO 檔案相關的小工具
############################################################

# 從 series matrix 檔案抓出 platform（GPL 編號）
detect_platform_from_series_matrix <- function(path, n = 300) {
  if (!file.exists(path)) {
    stop("File not found: ", path)
  }
  lines <- readLines(path, n = n)
  plat_line <- grep("!Series_platform_id", lines, value = TRUE)
  if (length(plat_line) == 0) {
    warning("No !Series_platform_id line found in first ", n, " lines.")
    return(NA_character_)
  }
  # 例如 "!Series_platform_id = GPL570"
  gsub(".*=\\s*", "", plat_line[1])
}

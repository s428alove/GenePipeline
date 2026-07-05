############################################################
# utils_io.R
# 讀寫檔案、路徑相關的共用小工具
############################################################

# 簡單包一層，確保路徑是相對於專案根目錄
read_csv_project <- function(path, ...) {
  full <- file.path(path)
  if (!file.exists(full)) {
    stop("File not found: ", full)
  }
  readr::read_csv(full, show_col_types = FALSE, ...)
}

write_csv_project <- function(df, path, ...) {
  full <- file.path(path)
  readr::write_csv(df, full, ...)
  message(">>> Wrote CSV: ", full)
}

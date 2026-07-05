# _lib/manifest.R
# Write per-module manifest.json to results/<GSE>/<module>/manifest.json

write_manifest_json <- function(
    manifest_path,
    module_id,
    gse,
    inputs,
    outputs,
    args = list(),
    extra = list(),
    hash_algo = "md5"
) {
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    stop("Package required: jsonlite. Install with install.packages('jsonlite')", call. = FALSE)
  }
  if (!requireNamespace("digest", quietly = TRUE)) {
    stop("Package required: digest. Install with install.packages('digest')", call. = FALSE)
  }
  
  file_hash <- function(p) {
    if (is.null(p) || is.na(p) || !nzchar(p) || !file.exists(p)) return(NA_character_)
    digest::digest(file = p, algo = hash_algo)
  }
  
  input_hashes <- lapply(inputs, file_hash)
  output_hashes <- lapply(outputs, file_hash)
  
  payload <- c(list(
    module_id = module_id,
    gse = gse,
    timestamp = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    inputs = inputs,
    input_hash = input_hashes,
    args = args,
    outputs = outputs,
    output_hash = output_hashes
  ), extra)
  
  dir.create(dirname(manifest_path), recursive = TRUE, showWarnings = FALSE)
  jsonlite::write_json(
    payload,
    path = manifest_path,
    pretty = TRUE,
    auto_unbox = TRUE,
    null = "null"
  )
  
  invisible(manifest_path)
}

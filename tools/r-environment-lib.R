# Shared package-environment implementation. No installation at source time.
gp_definition <- function(project) {
  d <- read.dcf(file.path(project, "DESCRIPTION"))[1, ]
  split_packages <- function(x) trimws(strsplit(x, ",", fixed = TRUE)[[1]])
  list(direct = split_packages(d[["Imports"]]), tooling = split_packages(d[["Suggests"]]),
       renv_version = unname(d[["Config/GenePipeline/RenvVersion"]]),
       bioconductor = unname(d[["Config/GenePipeline/BioconductorVersion"]]),
       bioc_packages = split_packages(d[["Config/GenePipeline/BioconductorPackages"]]),
       cran = unname(d[["Config/GenePipeline/CRAN"]]))
}

gp_tooling_library <- function(project) {
  file.path(project, "renv", "bootstrap", paste0("R-", R.version$major, ".",
    strsplit(R.version$minor, ".", fixed = TRUE)[[1]][1]), R.version$platform)
}

gp_library <- function(project) renv::paths$library(project = project)

gp_configure <- function(project) {
  project <- normalizePath(project, winslash = "/", mustWork = TRUE)
  Sys.setenv(RENV_PATHS_LIBRARY = file.path(project, "renv", "library"),
             RENV_PATHS_CACHE = file.path(project, "renv", "cache"),
             RENV_PATHS_ROOT = file.path(project, "renv", "state"),
             RENV_PATHS_SANDBOX = file.path(project, "renv", "state", "sandbox"),
             RENV_CONFIG_AUTO_SNAPSHOT = "FALSE",
             RENV_CONFIG_USER_PROFILE = "FALSE",
             RENV_CONFIG_STARTUP_QUIET = "TRUE",
             RENV_CONFIG_SYNCHRONIZED_CHECK = "FALSE",
             RENV_CONFIG_AUTOLOADER_ENABLED = "FALSE")
  options(repos = c(CRAN = gp_definition(project)$cran), timeout = 300)
  invisible(project)
}

gp_fail <- function(code, message, details = list()) {
  structure(list(message = message, call = NULL, code = code, details = details),
            class = c("gp_environment_error", "error", "condition"))
}

gp_activate <- function(project) {
  gp_configure(project)
  lib <- gp_tooling_library(project)
  wanted <- gp_definition(project)$renv_version
  desc <- file.path(lib, "renv", "DESCRIPTION")
  if (!file.exists(desc) || read.dcf(desc)[1, "Version"] != wanted) {
    stop(gp_fail("PACKAGE_ENV_NOT_READY", "GenePipeline renv tooling is not installed. Start GenePipeline to run environment setup."))
  }
  # lib.loc prevents silently loading renv from a global user library.
  if (!requireNamespace("renv", lib.loc = lib, quietly = TRUE)) {
    stop(gp_fail("PACKAGE_VALIDATION_FAILED", "The project renv installation cannot be loaded."))
  }
  if (as.character(getNamespaceVersion("renv")) != wanted)
    stop(gp_fail("PACKAGE_VALIDATION_FAILED", "The loaded renv namespace does not match the pinned tooling version."))
  renv::load(project = project)
  invisible(lib)
}

gp_check <- function(project) {
  tryCatch({
    gp_activate(project)
    lib <- gp_library(project)
    same_path <- function(a, b) identical(normalizePath(a, winslash = "/", mustWork = FALSE),
                                          normalizePath(b, winslash = "/", mustWork = FALSE))
    if (!same_path(renv::project(), project) || !same_path(.libPaths()[1], lib)) {
      stop(gp_fail("PACKAGE_ENV_NOT_READY", "The repository renv environment is not active."))
    }
    lock_path <- file.path(project, "renv.lock")
    if (!file.exists(lock_path)) stop(gp_fail("PACKAGE_ENV_NOT_READY", "renv.lock is missing; repair the GenePipeline distribution."))
    lock <- tryCatch(renv::lockfile_read(lock_path), error = function(e) {
      stop(gp_fail("PACKAGE_ENV_NOT_READY", "renv.lock is invalid.", list(reason = conditionMessage(e))))
    })
    definition <- gp_definition(project)
    if (!identical(renv::settings$snapshot.type(project = project), "explicit") ||
        !identical(renv::settings$bioconductor.version(project = project), definition$bioconductor))
      stop(gp_fail("PACKAGE_ENV_NOT_READY", "renv settings do not match the repository environment definition."))
    required <- c(definition$direct, definition$tooling)
    if (is.null(lock$R$Version) || !length(lock$Packages) ||
        !all(required %in% names(lock$Packages)) ||
        !identical(lock$Packages$renv$Version, definition$renv_version) ||
        !identical(lock$Bioconductor$Version, definition$bioconductor)) {
      stop(gp_fail("PACKAGE_ENV_NOT_READY", "renv.lock does not cover the central dependency definition or pinned renv tooling."))
    }
    # Check every lock record against THIS library, not fallback global packages.
    mismatch <- Filter(Negate(is.null), lapply(names(lock$Packages), function(pkg) {
      desc <- file.path(lib, pkg, "DESCRIPTION")
      installed <- if (file.exists(desc)) tryCatch(read.dcf(desc)[1, "Version"], error = function(e) NA_character_) else NA_character_
      if (is.na(installed) || installed != lock$Packages[[pkg]]$Version)
        list(package = pkg, expected = lock$Packages[[pkg]]$Version, installed = installed) else NULL
    }))
    installed_names <- list.files(lib)
    installed_names <- installed_names[file.exists(file.path(lib, installed_names, "DESCRIPTION"))]
    extras <- setdiff(installed_names, names(lock$Packages))
    packages <- lapply(definition$direct, function(pkg) {
      reason <- NULL
      usable <- tryCatch({
        if (!requireNamespace(pkg, lib.loc = lib, quietly = TRUE)) stop("Namespace could not be loaded")
        actual <- getNamespaceInfo(asNamespace(pkg), "path")
        if (!same_path(actual, file.path(lib, pkg))) stop("Namespace came from outside the project library")
        TRUE
      }, error = function(e) { reason <<- conditionMessage(e); FALSE })
      list(package = pkg, usable = usable, error = reason)
    })
    status_text <- utils::capture.output(status <- renv::status(project = project, library = lib, dev = TRUE))
    synchronized <- isTRUE(status$synchronized) && !length(mismatch) && !length(extras)
    loadable <- all(vapply(packages, function(p) p$usable, logical(1)))
    ready <- synchronized && loadable
    list(ok = ready, state = if (ready) "ready" else "not_ready", active = TRUE,
         synchronized = synchronized, library = lib, project = project,
         rVersion = as.character(getRversion()), renvVersion = definition$renv_version,
         packages = packages, mismatches = mismatch, extraPackages = extras, synchronizationDetails = status_text,
         error = if (ready) NULL else list(code = if (!loadable) "PACKAGE_VALIDATION_FAILED" else "PACKAGE_ENV_NOT_READY",
           message = "GenePipeline package environment is incomplete or out of sync. Restart GenePipeline or retry environment setup."))
  }, error = function(e) {
    list(ok = FALSE, state = "not_ready", error = list(
      code = if (inherits(e, "gp_environment_error")) e$code else "PACKAGE_VALIDATION_FAILED",
      message = conditionMessage(e), details = if (inherits(e, "gp_environment_error")) e$details else list()))
  })
}

gp_require_ready <- function(project) {
  result <- gp_check(project)
  if (!isTRUE(result$ok)) stop(paste0(result$error$code, ": ", result$error$message), call. = FALSE)
  invisible(result)
}

# Base-R JSON output works even when jsonlite / renv are missing or broken.
gp_json <- function(x) {
  if (is.null(x)) return("null")
  if (is.list(x)) {
    values <- vapply(x, gp_json, character(1))
    if (!is.null(names(x))) return(paste0("{", paste(paste0(vapply(names(x), gp_json, character(1)), ":", values), collapse = ","), "}"))
    return(paste0("[", paste(values, collapse = ","), "]"))
  }
  if (length(x) != 1L) return(gp_json(as.list(x)))
  if (is.na(x)) return("null")
  if (is.logical(x)) return(if (x) "true" else "false")
  if (is.numeric(x)) return(as.character(x))
  escaped <- encodeString(as.character(x), quote = '"')
  escaped <- gsub("\\a", "\\u0007", escaped, fixed = TRUE)
  escaped <- gsub("\\v", "\\u000b", escaped, fixed = TRUE)
  escaped
}

gp_event <- function(state, message) {
  cat("GENEPIPELINE_ENV_EVENT=", gp_json(list(state = state, message = message)), "\n", sep = "")
  flush.console()
}

gp_bootstrap <- function(project) {
  gp_configure(project)
  # R CMD INSTALL launches child R processes. They must not run the analysis
  # profile while this very environment is still being assembled.
  Sys.setenv(R_PROFILE_USER = file.path(project, "renv", ".setup-no-profile"))
  lib <- gp_tooling_library(project)
  definition <- gp_definition(project)
  desc <- file.path(lib, "renv", "DESCRIPTION")
  if (file.exists(desc) && read.dcf(desc)[1, "Version"] == definition$renv_version &&
      requireNamespace("renv", lib.loc = lib, quietly = TRUE)) return(invisible(FALSE))
  gp_event("bootstrapping", paste("Installing project renv", definition$renv_version))
  tryCatch({
    dir.create(lib, recursive = TRUE, showWarnings = FALSE)
    archive <- tempfile(fileext = ".tar.gz")
    on.exit(unlink(archive), add = TRUE)
    filename <- paste0("renv_", definition$renv_version, ".tar.gz")
    urls <- paste0(definition$cran, c("/src/contrib/", "/src/contrib/Archive/renv/"), filename)
    downloaded <- FALSE
    for (url in urls) {
      downloaded <- tryCatch({ utils::download.file(url, archive, mode = "wb", quiet = TRUE); TRUE }, error = function(e) FALSE)
      if (downloaded) break
    }
    if (!downloaded) stop("Unable to download the pinned renv archive. Check network access to CRAN.")
    utils::install.packages(archive, repos = NULL, type = "source", lib = lib)
    if (!requireNamespace("renv", lib.loc = lib, quietly = TRUE) ||
        as.character(utils::packageVersion("renv", lib.loc = lib)) != definition$renv_version)
      stop("The pinned renv package could not be installed or loaded.")
    invisible(TRUE)
  }, error = function(e) stop(gp_fail("RENV_BOOTSTRAP_FAILED", conditionMessage(e))))
}

gp_setup <- function(project, rebuild = FALSE) {
  if (!file.exists(file.path(project, "renv.lock")))
    stop(gp_fail("PACKAGE_ENV_NOT_READY", "renv.lock is missing; setup never invents a lockfile from the user's machine."))
  gp_bootstrap(project)
  tryCatch({
    gp_activate(project)
    gp_event("restoring", "Restoring the locked repository environment")
    if (!rebuild) {
      renv::restore(project = project, prompt = FALSE, clean = TRUE)
    } else {
      # In renv 1.1.5, a version-identical library can short-circuit restore even
      # with rebuild=TRUE. Restore to an empty library, then replace the broken
      # one only after successful installation. Keep original files on failure.
      lib <- gp_library(project)
      staging <- tempfile("repair-", tmpdir = dirname(lib))
      dir.create(staging, recursive = TRUE)
      on.exit(if (dir.exists(staging)) unlink(staging, recursive = TRUE), add = TRUE)
      # renv needs its Bioconductor tooling before restoring to a non-default
      # library. Seed the recorded tooling, then let restore verify its version.
      for (pkg in setdiff(gp_definition(project)$tooling, "renv")) {
        if (dir.exists(file.path(lib, pkg))) file.copy(file.path(lib, pkg), staging, recursive = TRUE)
      }
      renv::restore(project = project, library = staging, prompt = FALSE, rebuild = TRUE)
      backup <- tempfile("before-repair-", tmpdir = dirname(lib))
      if (!file.rename(lib, backup)) stop("Unable to preserve the current library before repair.")
      if (!file.rename(staging, lib)) {
        file.rename(backup, lib)
        stop("Unable to activate the repaired library; the original library was retained.")
      }
      unlink(backup, recursive = TRUE)
    }
  },
    error = function(e) stop(gp_fail("RENV_RESTORE_FAILED", conditionMessage(e))))
  # The Node supervisor validates in a fresh R process after restore: namespaces
  # loaded during restore must not mask a broken installation or old DLL version.
  list(ok = TRUE, state = "restored", error = NULL)
}

#!/usr/bin/env Rscript

r_version <- Sys.getenv("R_VERSION")
lock <- pak:::json$parse_file("/opt/rdh/pkg.lock")

stopifnot(
  identical(as.character(getRversion()), r_version),
  identical(
    unname(getOption("repos")[["CRAN"]]),
    Sys.getenv("RDH_PPM_REPO")
  )
)

direct <- vapply(lock$packages, function(package) isTRUE(package$direct), logical(1L))
required <- vapply(lock$packages[direct], `[[`, character(1L), "package")

stopifnot(
  all(vapply(required, requireNamespace, logical(1L), quietly = TRUE)),
  exists("rdh_connect", envir = globalenv(), mode = "function", inherits = FALSE),
  startsWith(
    normalizePath(.libPaths()[[1L]], mustWork = TRUE),
    normalizePath(
      file.path(
        Sys.getenv("RDH_DATA_DIR", unset = path.expand("~/.local/share/rdh")),
        "v1",
        paste0("R-", paste(strsplit(r_version, ".", fixed = TRUE)[[1L]][1:2], collapse = ".")),
        "library"
      ),
      mustWork = TRUE
    )
  )
)

drivers <- odbc::odbcListDrivers()
driver_names <- if (ncol(drivers) > 0L) as.character(drivers[[1L]]) else character()
stopifnot("FreeTDS" %in% driver_names)

message("rdh image smoke test passed")

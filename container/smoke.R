#!/usr/bin/env Rscript

image_config <- readRDS("/opt/datahub-r/image-config.rds")

stopifnot(
  identical(as.character(getRversion()), image_config$r_version),
  identical(
    unname(getOption("repos")[["CRAN"]]),
    image_config$ppm_repo
  )
)

required <- image_config$packages

stopifnot(
  all(vapply(required, requireNamespace, logical(1L), quietly = TRUE)),
  exists("datahub_connect", envir = globalenv(), mode = "function", inherits = FALSE),
  startsWith(
    normalizePath(.libPaths()[[1L]], mustWork = TRUE),
    normalizePath(
      file.path(
        Sys.getenv("DATAHUB_R_DATA_DIR", unset = path.expand("~/.local/share/datahub-r")),
        "v1",
        paste0("R-", paste(strsplit(image_config$r_version, ".", fixed = TRUE)[[1L]][1:2], collapse = ".")),
        "library"
      ),
      mustWork = TRUE
    )
  )
)

drivers <- odbc::odbcListDrivers()
driver_names <- if (ncol(drivers) > 0L) as.character(drivers[[1L]]) else character()
stopifnot("ODBC Driver 18 for SQL Server" %in% driver_names)

message("datahub-r image smoke test passed")

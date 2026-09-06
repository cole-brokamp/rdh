#!/usr/bin/env Rscript

source("/opt/rdh/database.R", local = TRUE)

rdh_check <- function(profile = Sys.getenv(
  "RDH_DB_PROFILE",
  unset = "MBHI"
)) {
  image_config <- readRDS("/opt/rdh/image-config.rds")
  required_packages <- image_config$packages

  unavailable <- required_packages[
    !vapply(required_packages, requireNamespace, logical(1L), quietly = TRUE)
  ]

  if (length(unavailable) > 0L) {
    stop("required package(s) unavailable: ", paste(unavailable, collapse = ", "))
  }

  expected_ppm <- image_config$ppm_repo
  active_cran <- unname(getOption("repos")[["CRAN"]])

  if (!identical(active_cran, expected_ppm)) {
    warning(
      "the active CRAN repository is not the supported Posit Package Manager repository",
      call. = FALSE
    )
  }

  drivers <- odbc::odbcListDrivers()
  driver_names <- if (ncol(drivers) > 0L) {
    as.character(drivers[[1L]])
  } else {
    character()
  }

  if (!"ODBC Driver 18 for SQL Server" %in% driver_names) {
    stop("ODBC Driver 18 for SQL Server is not registered")
  }

  con <- rdh_connect(profile)
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  profile <- toupper(profile)

  probe <- DBI::dbGetQuery(con, "SELECT 1 AS ok")

  if (
    nrow(probe) != 1L ||
      ncol(probe) != 1L ||
      is.na(probe[[1L]][1L]) ||
      as.integer(probe[[1L]][1L]) != 1L
  ) {
    stop(profile, " connection probe returned an unexpected result")
  }

  message("R ", as.character(getRversion()))
  message("user library: ", .libPaths()[[1L]])
  message("CRAN repository: ", active_cran)
  message("ODBC Driver 18 for SQL Server is registered")
  message(profile, " connection probe succeeded")

  invisible(TRUE)
}

if (sys.nframe() == 0L) {
  rdh_check()
}

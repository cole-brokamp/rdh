#!/usr/bin/env Rscript

metadata_path <- "/opt/datahub-r/build-metadata"
metadata <- if (file.exists(metadata_path)) {
  read.dcf(metadata_path)
} else {
  matrix(character(), nrow = 0L, ncol = 0L)
}

metadata_value <- function(name, fallback = "unknown") {
  if (nrow(metadata) == 1L && name %in% colnames(metadata)) {
    metadata[[1L, name]]
  } else {
    fallback
  }
}

driver_version <- tryCatch(
  system2(
    "dpkg-query",
    c("-W", "-f=${Version}", "msodbcsql18"),
    stdout = TRUE,
    stderr = FALSE
  ),
  error = function(...) "unknown"
)

cat("datahub-r image:", metadata_value("DATAHUB_R_VERSION"), "\n")
cat("R:", as.character(getRversion()), "\n")
cat("Microsoft ODBC Driver 18 package:", driver_version[[1L]], "\n")
cat("CRAN:", unname(getOption("repos")[["CRAN"]]), "\n")
cat("package lock sha256:", metadata_value("PACKAGE_LOCK_SHA256"), "\n")
cat("build date:", metadata_value("BUILD_DATE"), "\n")
cat("source revision:", metadata_value("VCS_REF"), "\n")
cat("user library:", .libPaths()[[1L]], "\n")

packages <- readRDS("/opt/datahub-r/image-config.rds")$packages

for (package in packages) {
  version <- if (requireNamespace(package, quietly = TRUE)) {
    as.character(packageVersion(package))
  } else {
    "unavailable"
  }
  cat(package, ": ", version, "\n", sep = "")
}

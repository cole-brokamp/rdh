#!/usr/bin/env Rscript

# Read-only acceptance test: all rows are synthetic SQL expressions.
rdh_test_connection <- function(expected_authentication = NULL) {
  con <- rdh_connect()
  on.exit(DBI::dbDisconnect(con), add = TRUE)
  stopifnot(inherits(con, "Microsoft SQL Server"))

  authentication <- DBI::dbGetQuery(
    con,
    "SELECT CAST(CONNECTIONPROPERTY('auth_scheme') AS varchar(20)) AS auth_scheme"
  )[[1L]]
  stopifnot(
    length(authentication) == 1L,
    authentication %in% c("SQL", "NTLM", "KERBEROS")
  )
  if (!is.null(expected_authentication)) {
    stopifnot(identical(authentication, expected_authentication))
  }

  rows <- dplyr::tbl(con, dbplyr::sql(paste(
    "SELECT 1 AS id, CAST('9007199254740993' AS bigint) AS big_id,",
    "CAST('2026-01-02' AS date) AS test_date,",
    "CAST('2026-01-02T03:04:05.123' AS datetime2(3)) AS test_time,",
    "NCHAR(233) + NCHAR(28450) AS test_text, CAST(NULL AS int) AS nullable",
    "UNION ALL SELECT 2, CAST('-9007199254740993' AS bigint),",
    "CAST(NULL AS date), CAST(NULL AS datetime2(3)), N'other', 7"
  )))
  result <- rows |> dplyr::arrange(id) |> dplyr::collect()
  stopifnot(
    nrow(result) == 2L,
    inherits(result$big_id, "integer64"),
    identical(as.character(result$big_id), c("9007199254740993", "-9007199254740993")),
    inherits(result$test_date, "Date"),
    identical(result$test_date[[1L]], as.Date("2026-01-02")),
    is.na(result$test_date[[2L]]),
    inherits(result$test_time, "POSIXct"),
    abs(as.numeric(result$test_time[[1L]]) -
      as.numeric(as.POSIXct("2026-01-02 03:04:05.123", tz = "UTC"))) < 0.001,
    is.na(result$test_time[[2L]]),
    identical(result$test_text, c("\u00e9\u6f22", "other")),
    is.na(result$nullable[[1L]]),
    result$nullable[[2L]] == 7L
  )

  lookup <- dplyr::tbl(con, dbplyr::sql("SELECT 1 AS id, 42 AS lookup_value"))
  joined <- rows |>
    dplyr::filter(id == 1L, !is.na(big_id)) |>
    dplyr::left_join(lookup, by = "id") |>
    head(1L) |>
    dplyr::collect()
  stopifnot(
    nrow(joined) == 1L,
    joined$lookup_value[[1L]] == 42L,
    identical(as.character(joined$big_id), "9007199254740993")
  )

  message("authentication: ", authentication)
  message("SQL Server class, dbplyr filters/joins, integer64, dates/timestamps, Unicode, and nulls passed")
  invisible(TRUE)
}

if (sys.nframe() == 0L) {
  rdh_test_connection()
}

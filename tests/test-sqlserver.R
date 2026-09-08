#!/usr/bin/env Rscript

# Run only against the disposable CI database. The bundled test stays read-only.
source("/opt/rdh/test-connection.R")
rdh_test_connection(expected_authentication = "SQL")

local({
  con <- rdh_connect()
  on.exit(DBI::dbDisconnect(con), add = TRUE)

  expected <- data.frame(
    id = c(1L, 2L),
    big_id = bit64::as.integer64(c("9007199254740993", NA_character_)),
    test_date = as.Date(c("2026-01-02", NA_character_)),
    test_time = as.POSIXct(c("2026-01-02 03:04:05.123", NA_character_), tz = "UTC"),
    test_text = c("\u00e9\u6f22", NA_character_),
    nullable = c(NA_integer_, 7L)
  )
  DBI::dbWriteTable(
    con, "#rdh_roundtrip", expected, temporary = TRUE,
    # odbc converts integer64 to decimal text before inferring write types.
    field.types = c(big_id = "bigint", test_text = "nvarchar(100)", test_time = "datetime2(3)")
  )
  actual <- dplyr::tbl(con, "#rdh_roundtrip") |>
    dplyr::arrange(id) |>
    dplyr::collect()
  # The fixture is entirely synthetic; retain useful type/precision diagnostics.
  print(as.data.frame(actual))
  message("timestamp difference in seconds: ",
    as.numeric(actual$test_time[[1L]]) - as.numeric(expected$test_time[[1L]]))
  stopifnot(
    identical(actual$id, expected$id),
    inherits(actual$big_id, "integer64"),
    identical(as.character(actual$big_id), as.character(expected$big_id)),
    identical(actual$test_date, expected$test_date),
    inherits(actual$test_time, "POSIXct"),
    abs(as.numeric(actual$test_time[[1L]]) - as.numeric(expected$test_time[[1L]])) < 0.001,
    is.na(actual$test_time[[2L]]),
    identical(actual$test_text, expected$test_text),
    identical(actual$nullable, expected$nullable)
  )
  DBI::dbRemoveTable(con, "#rdh_roundtrip")
})

message("SQL-password authentication and temporary-table write/read passed")

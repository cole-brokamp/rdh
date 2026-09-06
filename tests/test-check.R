# Sourcing the helper exposes only the public connection function.
helper_environment <- new.env(parent = baseenv())
sys.source("/opt/rdh/database.R", envir = helper_environment)
stopifnot(identical(ls(helper_environment, all.names = TRUE), "rdh_connect"))

check_environment <- new.env(parent = baseenv())
sys.source("/opt/rdh/check.R", envir = check_environment)

state <- new.env(parent = emptyenv())
state$connect_arguments <- NULL
state$disconnects <- 0L
state$query_error <- FALSE

originals <- list(
  dbConnect = get("dbConnect", envir = asNamespace("DBI")),
  dbDisconnect = get("dbDisconnect", envir = asNamespace("DBI")),
  dbGetQuery = get("dbGetQuery", envir = asNamespace("DBI")),
  odbc = get("odbc", envir = asNamespace("odbc")),
  odbcListDrivers = get("odbcListDrivers", envir = asNamespace("odbc"))
)

on.exit({
  for (name in names(originals)[1:3]) {
    assignInNamespace(name, originals[[name]], ns = "DBI")
  }
  for (name in names(originals)[4:5]) {
    assignInNamespace(name, originals[[name]], ns = "odbc")
  }
}, add = TRUE)

assignInNamespace(
  "odbcListDrivers",
  function(...) data.frame(name = "ODBC Driver 18 for SQL Server"),
  ns = "odbc"
)
assignInNamespace(
  "odbc",
  function(...) structure(list(), class = "rdh_test_driver"),
  ns = "odbc"
)
assignInNamespace(
  "dbConnect",
  function(drv, ...) {
    state$connect_arguments <- list(...)
    structure(list(), class = "rdh_test_connection")
  },
  ns = "DBI"
)
assignInNamespace(
  "dbDisconnect",
  function(conn, ...) {
    state$disconnects <- state$disconnects + 1L
    invisible(TRUE)
  },
  ns = "DBI"
)
assignInNamespace(
  "dbGetQuery",
  function(conn, statement, ...) {
    stopifnot(identical(statement, "SELECT 1 AS ok"))
    if (state$query_error) {
      stop("mock query failure", call. = FALSE)
    }
    data.frame(ok = 1L)
  },
  ns = "DBI"
)

mbhi_required_names <- c(
  "MBHI_DB_HOST",
  "MBHI_DB_USERNAME",
  "MBHI_DB_PASSWORD"
)
mbhi_names <- c(mbhi_required_names, "MBHI_DB_NAME")
omop_names <- c(
  "OMOP_DB_HOST",
  "OMOP_DB_NAME",
  "OMOP_DB_USERNAME",
  "OMOP_DB_PASSWORD"
)
environment_names <- c(mbhi_names, omop_names, "RDH_DB_PROFILE")
old_values <- Sys.getenv(environment_names, unset = NA_character_, names = TRUE)
on.exit({
  Sys.unsetenv(environment_names)
  present <- !is.na(old_values)
  if (any(present)) {
    do.call(Sys.setenv, as.list(old_values[present]))
  }
}, add = TRUE)

Sys.unsetenv(c(omop_names, "RDH_DB_PROFILE"))
Sys.unsetenv("MBHI_DB_NAME")

set_mbhi <- function(host = "host-secret", username = "user-secret", password = "password-secret") {
  Sys.setenv(
    MBHI_DB_HOST = host,
    MBHI_DB_USERNAME = username,
    MBHI_DB_PASSWORD = password
  )
}

set_mbhi()
messages <- capture.output(
  result <- check_environment$rdh_check(),
  type = "message"
)
stopifnot(
  identical(result, TRUE),
  identical(state$disconnects, 1L),
  identical(
    state$connect_arguments,
    list(
      Driver = "ODBC Driver 18 for SQL Server",
      Server = "host-secret",
      Database = "MBHI",
      UID = "user-secret",
      PWD = "password-secret",
      Encrypt = "yes",
      TrustServerCertificate = "yes"
    )
  ),
  !grepl("host-secret|user-secret|password-secret", paste(messages, collapse = "\n"))
)

state$query_error <- TRUE
error_messages <- capture.output(
  query_condition <- tryCatch(
    check_environment$rdh_check(),
    error = identity
  ),
  type = "message"
)
stopifnot(
  inherits(query_condition, "error"),
  identical(state$disconnects, 2L),
  !grepl(
    "host-secret|user-secret|password-secret",
    paste(c(error_messages, conditionMessage(query_condition)), collapse = "\n")
  )
)
state$query_error <- FALSE

Sys.unsetenv(mbhi_names)
missing_condition <- tryCatch(
  check_environment$rdh_check(),
  needenv_missing = identity
)
stopifnot(
  inherits(missing_condition, "needenv_missing"),
  identical(missing_condition$missing, mbhi_required_names),
  identical(state$disconnects, 2L)
)

set_mbhi(host = "", username = "", password = "")
empty_condition <- tryCatch(
  check_environment$rdh_check(),
  needenv_missing = identity
)
stopifnot(
  inherits(empty_condition, "needenv_missing"),
  identical(empty_condition$missing, mbhi_required_names),
  identical(state$disconnects, 2L)
)

set_mbhi()
old_repos <- getOption("repos")
on.exit(options(repos = old_repos), add = TRUE)
options(repos = c(CRAN = "https://example.invalid/cran"))
ppm_warning <- NULL
withCallingHandlers(
  check_environment$rdh_check(),
  warning = function(condition) {
    ppm_warning <<- condition
    invokeRestart("muffleWarning")
  },
  message = function(condition) invokeRestart("muffleMessage")
)
stopifnot(
  inherits(ppm_warning, "warning"),
  grepl("Posit Package Manager", conditionMessage(ppm_warning), fixed = TRUE),
  identical(state$disconnects, 3L)
)

Sys.setenv(
  OMOP_DB_HOST = "omop-host-secret",
  OMOP_DB_NAME = "omop_cdm",
  OMOP_DB_USERNAME = "omop-user-secret",
  OMOP_DB_PASSWORD = "omop-password-secret"
)
omop_messages <- capture.output(
  omop_result <- check_environment$rdh_check("omop"),
  type = "message"
)
stopifnot(
  identical(omop_result, TRUE),
  identical(state$disconnects, 4L),
  identical(
    state$connect_arguments,
    list(
      Driver = "ODBC Driver 18 for SQL Server",
      Server = "omop-host-secret",
      Database = "omop_cdm",
      UID = "omop-user-secret",
      PWD = "omop-password-secret",
      Encrypt = "yes",
      TrustServerCertificate = "yes"
    )
  ),
  !grepl(
    "omop-host-secret|omop-user-secret|omop-password-secret",
    paste(omop_messages, collapse = "\n")
  )
)

Sys.unsetenv("OMOP_DB_NAME")
omop_default <- check_environment$rdh_connect("OMOP")
stopifnot(identical(state$connect_arguments$Database, "OMOP"))
DBI::dbDisconnect(omop_default)

Sys.setenv(RDH_DB_PROFILE = "OMOP")
shortcut_connection <- check_environment$rdh_connect()
stopifnot(
  inherits(shortcut_connection, "rdh_test_connection"),
  identical(
    state$connect_arguments,
    list(
      Driver = "ODBC Driver 18 for SQL Server",
      Server = "omop-host-secret",
      Database = "OMOP",
      UID = "omop-user-secret",
      PWD = "omop-password-secret",
      Encrypt = "yes",
      TrustServerCertificate = "yes"
    )
  ),
  identical(state$disconnects, 5L)
)
DBI::dbDisconnect(shortcut_connection)
stopifnot(identical(state$disconnects, 6L))

message("connection checker tests passed")

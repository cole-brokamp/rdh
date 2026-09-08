local({
  # Sourcing the helper exposes only the public connection function.
  helper_environment <- new.env(parent = baseenv())
  sys.source("/opt/rdh/database.R", envir = helper_environment)
  stopifnot(identical(ls(helper_environment, all.names = TRUE), "rdh_connect"))

  check_environment <- new.env(parent = baseenv())
  sys.source("/opt/rdh/check.R", envir = check_environment)

  state <- new.env(parent = emptyenv())
  state$connect_arguments <- NULL
  state$connects <- 0L
  state$disconnects <- 0L
  state$connect_error <- FALSE
  state$query_error <- FALSE
  state$probe <- data.frame(ok = 1L)
  state$authentication <- data.frame(auth_scheme = "SQL")
  state$drivers <- data.frame(name = "FreeTDS")

  originals <- list(
    DBI = mget(c("dbConnect", "dbDisconnect", "dbGetQuery"), asNamespace("DBI")),
    odbc = mget(c("odbc", "odbcListDrivers"), asNamespace("odbc"))
  )
  on.exit({
    for (namespace in names(originals)) {
      for (name in names(originals[[namespace]])) {
        assignInNamespace(name, originals[[namespace]][[name]], ns = namespace)
      }
    }
  }, add = TRUE)

  assignInNamespace("odbcListDrivers", function(...) state$drivers, ns = "odbc")
  assignInNamespace("odbc", function(...) "mock driver", ns = "odbc")
  assignInNamespace("dbConnect", function(drv, ...) {
    state$connects <- state$connects + 1L
    state$connect_arguments <- list(...)
    if (state$connect_error) stop("mock connection failure", call. = FALSE)
    structure(list(), class = "rdh_test_connection")
  }, ns = "DBI")
  assignInNamespace("dbDisconnect", function(conn, ...) {
    state$disconnects <- state$disconnects + 1L
    invisible(TRUE)
  }, ns = "DBI")
  assignInNamespace("dbGetQuery", function(conn, statement, ...) {
    stopifnot(inherits(conn, "rdh_test_connection"))
    if (state$query_error) stop("mock query failure", call. = FALSE)
    if (identical(statement, "SELECT 1 AS ok")) return(state$probe)
    stopifnot(identical(
      statement,
      "SELECT CAST(CONNECTIONPROPERTY('auth_scheme') AS varchar(20)) AS auth_scheme"
    ))
    state$authentication
  }, ns = "DBI")

  required <- c("MBHI_DB_HOST", "MBHI_DB_USERNAME", "MBHI_DB_PASSWORD")
  environment_names <- c(
    required, "MBHI_DB_NAME", "RDH_DB_PROFILE",
    paste0("OMOP_DB_", c("HOST", "NAME", "USERNAME", "PASSWORD"))
  )
  old_values <- Sys.getenv(environment_names, unset = NA_character_, names = TRUE)
  on.exit({
    Sys.unsetenv(environment_names)
    present <- !is.na(old_values)
    if (any(present)) do.call(Sys.setenv, as.list(old_values[present]))
  }, add = TRUE)
  Sys.unsetenv(environment_names)
  Sys.setenv(
    MBHI_DB_HOST = "host-secret", MBHI_DB_USERNAME = "user-secret",
    MBHI_DB_PASSWORD = "password-secret"
  )

  messages <- capture.output(result <- check_environment$rdh_check(), type = "message")
  stopifnot(
    identical(result, TRUE), state$connects == 1L, state$disconnects == 1L,
    identical(state$connect_arguments, list(
      Driver = "FreeTDS", Server = "{host-secret}", Database = "{MBHI}",
      UID = "{user-secret}", PWD = "{password-secret}", TDS_Version = "7.4",
      UseNTLMv2 = "yes", Encryption = "require", ClientCharset = "UTF-8",
      bigint = "integer64"
    )),
    "authentication: SQL" %in% messages,
    !grepl("host-secret|user-secret|password-secret", paste(messages, collapse = "\n"))
  )

  expect_failure <- function(disconnects = 1L, connects = 1L) {
    before_disconnects <- state$disconnects
    before_connects <- state$connects
    condition <- tryCatch(check_environment$rdh_check(), error = identity)
    stopifnot(
      inherits(condition, "error"),
      state$disconnects == before_disconnects + disconnects,
      state$connects == before_connects + connects
    )
    condition
  }
  state$query_error <- TRUE
  expect_failure()
  state$query_error <- FALSE
  for (probe in list(data.frame(), data.frame(ok = NA_integer_), data.frame(ok = 2L))) {
    state$probe <- probe
    expect_failure()
  }
  state$probe <- data.frame(ok = 1L)
  for (auth in list(data.frame(), data.frame(auth = NA_character_), data.frame(auth = "user-secret"))) {
    state$authentication <- auth
    condition <- expect_failure()
    stopifnot(!grepl("user-secret", conditionMessage(condition), fixed = TRUE))
  }
  state$authentication <- data.frame(auth_scheme = "NTLM")
  state$connect_error <- TRUE
  expect_failure(disconnects = 0L)
  state$connect_error <- FALSE
  state$drivers <- data.frame()
  expect_failure(disconnects = 0L, connects = 0L)
  state$drivers <- data.frame(name = "FreeTDS")

  Sys.unsetenv(required)
  condition <- expect_failure(disconnects = 0L, connects = 0L)
  stopifnot(inherits(condition, "needenv_missing"), identical(condition$missing, required))
  Sys.setenv(MBHI_DB_HOST = "", MBHI_DB_USERNAME = "", MBHI_DB_PASSWORD = "")
  condition <- expect_failure(disconnects = 0L, connects = 0L)
  stopifnot(inherits(condition, "needenv_missing"), identical(condition$missing, required))

  Sys.setenv(
    MBHI_DB_HOST = "tcp:host-secret,1444", MBHI_DB_USERNAME = "chmcres\\user-secret",
    MBHI_DB_PASSWORD = " ;{pa}ss;'\"= word} ", MBHI_DB_NAME = "db;UID=other}"
  )
  messages <- capture.output(check_environment$rdh_check(), type = "message")
  stopifnot(
    identical(state$connect_arguments$Server, "{host-secret,1444}"),
    identical(state$connect_arguments$UID, "{chmcres\\user-secret}"),
    identical(state$connect_arguments$PWD, "{ ;{pa}ss;'\"= word} }"),
    identical(state$connect_arguments$Database, "{db;UID=other}}"),
    "authentication: NTLM" %in% messages,
    !grepl("user-secret|pa.*ss|UID=other", paste(messages, collapse = "\n"))
  )

  # This old driver cannot encode its own brace/semicolon terminator.
  # Reject it before connecting, without exposing the affected value.
  for (variable in c(required, "MBHI_DB_NAME")) {
    original <- Sys.getenv(variable)
    do.call(Sys.setenv, setNames(list("secret};UID=other"), variable))
    condition <- expect_failure(disconnects = 0L, connects = 0L)
    stopifnot(
      grepl("cannot represent the sequence };", conditionMessage(condition), fixed = TRUE),
      !grepl("secret|UID=other", conditionMessage(condition))
    )
    do.call(Sys.setenv, setNames(list(original), variable))
  }

  old_repos <- getOption("repos")
  on.exit(options(repos = old_repos), add = TRUE)
  options(repos = c(CRAN = "https://example.invalid/cran"))
  ppm_warning <- NULL
  withCallingHandlers(check_environment$rdh_check(), warning = function(condition) {
    ppm_warning <<- condition
    invokeRestart("muffleWarning")
  }, message = function(condition) invokeRestart("muffleMessage"))
  stopifnot(
    inherits(ppm_warning, "warning"),
    grepl("Posit Package Manager", conditionMessage(ppm_warning), fixed = TRUE)
  )
  options(repos = old_repos)

  Sys.setenv(
    OMOP_DB_HOST = "host-secret\\instance", OMOP_DB_NAME = "omop_cdm",
    OMOP_DB_USERNAME = "chmcres\\omop-user-secret", OMOP_DB_PASSWORD = "omop-password-secret"
  )
  con <- helper_environment$rdh_connect("omop")
  stopifnot(
    identical(state$connect_arguments$Server, "{host-secret\\instance}"),
    identical(state$connect_arguments$Database, "{omop_cdm}"),
    identical(state$connect_arguments$UID, "{chmcres\\omop-user-secret}")
  )
  DBI::dbDisconnect(con)
  Sys.setenv(RDH_DB_PROFILE = "OMOP")
  for (database in c(NA_character_, "")) {
    if (is.na(database)) Sys.unsetenv("OMOP_DB_NAME") else Sys.setenv(OMOP_DB_NAME = database)
    before <- state$disconnects
    con <- helper_environment$rdh_connect()
    stopifnot(
      inherits(con, "rdh_test_connection"),
      identical(state$connect_arguments$Database, "{OMOP}"),
      state$disconnects == before
    )
    DBI::dbDisconnect(con)
    stopifnot(state$disconnects == before + 1L)
  }
  for (profile in list("", NA_character_, c("MBHI", "OMOP"), "BAD-NAME", "1DB")) {
    before <- state$connects
    condition <- tryCatch(helper_environment$rdh_connect(profile), error = identity)
    stopifnot(inherits(condition, "error"), state$connects == before)
  }
})

message("connection checker tests passed")

ppm_repo <- Sys.getenv("RDH_PPM_REPO", unset = "")
site_library <- Sys.getenv("R_LIBS_SITE", unset = "")

if (!nzchar(ppm_repo) || !nzchar(site_library)) {
  stop("RDH_PPM_REPO and R_LIBS_SITE must be set", call. = FALSE)
}

options(repos = c(CRAN = ppm_repo))

# pak carries a dependency-free JSON reader, so the committed lock can be
# consumed before any of the lock's supporting packages are installed.
lock <- pak:::json$parse_file("/opt/rdh/pkg.lock")
locked <- lock$packages

`%||%` <- function(lhs, rhs) {
  if (is.null(lhs) || !length(lhs)) rhs else lhs
}

if (!length(locked)) {
  stop("pkg.lock contains no packages", call. = FALSE)
}

package_names <- vapply(locked, `[[`, character(1), "package")
package_versions <- vapply(locked, `[[`, character(1), "version")
package_repos <- vapply(
  locked,
  function(package) package$metadata$RemoteRepos %||% "",
  character(1)
)

if (anyDuplicated(package_names)) {
  stop("pkg.lock contains duplicate package names", call. = FALSE)
}

if (any(!startsWith(package_repos, "https://packagemanager.posit.co/cran/"))) {
  stop("pkg.lock contains a package resolved outside Posit Package Manager", call. = FALSE)
}

# Every direct and transitive package is passed as an exact version. Resolving
# those specs against the Noble PPM repository allows pak to use its Linux
# binaries while the committed lock remains the version authority.
specs <- paste0(package_names, "@", package_versions)
pak::pkg_install(
  specs,
  lib = site_library,
  upgrade = FALSE,
  ask = FALSE,
  dependencies = FALSE
)

installed <- installed.packages(lib.loc = site_library)
missing <- setdiff(package_names, rownames(installed))
if (length(missing)) {
  stop("locked packages were not installed: ", paste(missing, collapse = ", "), call. = FALSE)
}

installed_versions <- installed[package_names, "Version"]
mismatched <- package_names[installed_versions != package_versions]
if (length(mismatched)) {
  details <- paste0(
    mismatched,
    " (locked ", package_versions[match(mismatched, package_names)],
    ", installed ", installed_versions[match(mismatched, package_names)], ")"
  )
  stop("installed versions differ from pkg.lock: ", paste(details, collapse = ", "), call. = FALSE)
}

manifest <- data.frame(
  Package = package_names,
  Version = unname(installed_versions),
  Repository = rep(ppm_repo, length(package_names)),
  stringsAsFactors = FALSE
)
manifest <- manifest[order(manifest$Package), , drop = FALSE]
write.csv(manifest, "/opt/rdh/installed-packages.csv", row.names = FALSE)

# Runtime checks and startup consume the same settings used to build the image.
direct <- vapply(locked, function(package) isTRUE(package$direct), logical(1L))
saveRDS(
  list(
    r_version = Sys.getenv("R_VERSION"),
    ppm_repo = ppm_repo,
    packages = package_names[direct]
  ),
  "/opt/rdh/image-config.rds",
  version = 2
)

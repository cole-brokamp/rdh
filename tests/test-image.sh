#!/usr/bin/env bash

set -euo pipefail

image="${1:-rdh:local}"
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
case "$(uname -m)" in
  arm64|aarch64) native_platform="linux/arm64" ;;
  x86_64|amd64) native_platform="linux/amd64" ;;
  *) echo "unsupported host architecture: $(uname -m)" >&2; exit 1 ;;
esac
platform="${RDH_PLATFORM:-$native_platform}"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT HUP INT TERM

home_dir="$test_root/home"
project_dir="$test_root/project"
export_only_dir="$test_root/export only project"
profile_override_dir="$test_root/profile override"
mkdir -p \
  "$home_dir" \
  "$project_dir" \
  "$export_only_dir" \
  "$profile_override_dir/custom-library"

cat > "$project_dir/.Renviron" <<'EOF_RENVIRON'
RDH_TEST_RENVIRON=loaded
MBHI_DB_HOST=renviron-host
MBHI_DB_USERNAME='chmcres\renviron-user'
MBHI_DB_PASSWORD=renviron-password
EOF_RENVIRON

cat > "$project_dir/.Rprofile" <<'EOF_RPROFILE'
options(rdh.test.rprofile = "loaded")
EOF_RPROFILE

cat > "$profile_override_dir/.Rprofile" <<'EOF_OVERRIDE_RPROFILE'
.libPaths("/profile-override/custom-library")
EOF_OVERRIDE_RPROFILE

run_rscript() {
  container run --rm \
    --platform "$platform" \
    --env HOME=/home/rdh-test \
    --env RDH_DATA_DIR=/home/rdh-test/custom-data \
    --mount "type=bind,source=$home_dir,target=/home/rdh-test" \
    --mount "type=bind,source=$project_dir,target=/project" \
    --workdir /project \
    --entrypoint Rscript \
    "$image" \
    "$@"
}

run_export_only() {
  container run --rm \
    --platform "$platform" \
    --env HOME=/home/rdh-test \
    --env MBHI_DB_HOST=export-host \
    --env 'MBHI_DB_USERNAME=chmcres\export-user' \
    --env MBHI_DB_PASSWORD=export-password \
    --mount "type=bind,source=$home_dir,target=/home/rdh-test" \
    --mount "type=bind,source=$export_only_dir,target=/export-only" \
    --workdir /export-only \
    --entrypoint Rscript \
    "$image" \
    "$@"
}

container run --rm \
  --platform "$platform" \
  --env HOME=/home/rdh-test \
  --mount "type=bind,source=$home_dir,target=/home/rdh-test" \
  --entrypoint Rscript \
  "$image" \
  /opt/rdh/smoke.R

container run --rm \
  --platform "$platform" \
  --env HOME=/home/rdh-test \
  --env MBHI_DB_HOST=export-host \
  --env 'MBHI_DB_USERNAME=chmcres\export-user' \
  --env MBHI_DB_PASSWORD=export-password \
  --mount "type=bind,source=$home_dir,target=/home/rdh-test" \
  --mount "type=bind,source=$project_dir,target=/project" \
  --workdir /project \
  --entrypoint Rscript \
  "$image" \
  -e '
  stopifnot(
    identical(Sys.getenv("RDH_TEST_RENVIRON"), "loaded"),
    identical(Sys.getenv("MBHI_DB_HOST"), "renviron-host"),
    identical(Sys.getenv("MBHI_DB_USERNAME"), "chmcres\\renviron-user"),
    identical(Sys.getenv("MBHI_DB_PASSWORD"), "renviron-password"),
    identical(getOption("rdh.test.rprofile"), "loaded"),
    identical(
      unname(getOption("repos")[["CRAN"]]),
      readRDS("/opt/rdh/image-config.rds")$ppm_repo
    ),
    startsWith(.libPaths()[[1L]], path.expand("~/.local/share/rdh/"))
  )
'

run_export_only -e '
  stopifnot(
    identical(Sys.getenv("MBHI_DB_HOST"), "export-host"),
    identical(Sys.getenv("MBHI_DB_USERNAME"), "chmcres\\export-user"),
    identical(Sys.getenv("MBHI_DB_PASSWORD"), "export-password")
  )
'

run_rscript -e 'install.packages("fortunes", lib = .libPaths()[[1L]], dependencies = NA)'
run_rscript -e 'stopifnot(startsWith(.libPaths()[[1L]], "/home/rdh-test/custom-data/"))'
run_rscript -e '
  stopifnot(
    requireNamespace("fortunes", quietly = TRUE),
    startsWith(find.package("fortunes"), .libPaths()[[1L]])
  )
  remove.packages("fortunes", lib = .libPaths()[[1L]])
'

container run --rm \
  --platform "$platform" \
  --env HOME=/home/rdh-test \
  --mount "type=bind,source=$home_dir,target=/home/rdh-test" \
  --mount "type=bind,source=$profile_override_dir,target=/profile-override" \
  --workdir /profile-override \
  --entrypoint Rscript \
  "$image" \
  -e 'stopifnot(identical(.libPaths()[[1L]], "/profile-override/custom-library"))'

run_rscript -e 'install.packages("DBI", lib = .libPaths()[[1L]], dependencies = NA)'
run_rscript -e '
  stopifnot(startsWith(find.package("DBI"), .libPaths()[[1L]]))
  remove.packages("DBI", lib = .libPaths()[[1L]])
  stopifnot(!startsWith(find.package("DBI"), .libPaths()[[1L]]))
'

container run --rm \
  --platform "$platform" \
  --env HOME=/home/rdh-test \
  --mount "type=bind,source=$home_dir,target=/home/rdh-test" \
  --mount "type=bind,source=$repo_dir,target=/source" \
  --entrypoint Rscript \
  "$image" \
  /source/tests/test-check.R

if container run --rm \
  --platform "$platform" \
  --env HOME=/home/rdh-test \
  --mount "type=bind,source=$home_dir,target=/home/rdh-test" \
  --entrypoint /usr/bin/find \
  "$image" \
  /opt/rdh -name .Renviron -print | grep -q .; then
  echo "a .Renviron file was found in the image" >&2
  exit 1
fi

echo "image checks passed"

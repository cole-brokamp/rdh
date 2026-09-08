#!/usr/bin/env bash

set -euo pipefail

binary="$1"
runtime="$2"
export RDH_IMAGE="$3"
[[ "$binary" = /* ]] || binary="$(pwd -P)/$binary"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT HUP INT TERM
export RDH_DATA_DIR="$test_root/data"
export MBHI_DB_HOST=export-host
export MBHI_DB_USERNAME='chmcres\export-user'
export MBHI_DB_PASSWORD='password-secret;$literal\backslash{brace}'
mkdir -p "$test_root/project"
cd "$test_root/project"

cat > verify.R <<'EOF_R'
mode <- commandArgs(trailingOnly = TRUE)[[1L]]
stopifnot(
  identical(Sys.getenv("MBHI_DB_HOST"), paste0(mode, "-host")),
  identical(Sys.getenv("MBHI_DB_USERNAME"), paste0("chmcres\\", mode, "-user")),
  identical(Sys.getenv("MBHI_DB_PASSWORD"), "password-secret;$literal\\backslash{brace}")
)
EOF_R

"$binary" --runtime "$runtime" --db MBHI Rscript verify.R export
cat > .Renviron <<'EOF_RENVIRON'
MBHI_DB_HOST=renviron-host
MBHI_DB_USERNAME='chmcres\renviron-user'
MBHI_DB_PASSWORD='password-secret;$literal\backslash{brace}'
EOF_RENVIRON
"$binary" --runtime "$runtime" --db MBHI Rscript verify.R renviron

echo "$runtime credential forwarding and .Renviron checks passed"

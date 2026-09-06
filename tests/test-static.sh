#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_dir"

version="$(tr -d '\r\n' < VERSION)"
[[ "$version" =~ ^[0-9]{4}[.](0[1-9]|1[0-2])[.](0|[1-9][0-9]*)(-dev)?$ ]] || {
  echo "VERSION is not YYYY.MM.REVISION or YYYY.MM.REVISION-dev: $version" >&2
  exit 1
}

for file in image.conf install.sh scripts/*.sh tests/*.sh; do
  bash -n "$file"
done

for file in container/*.R tests/*.R; do
  Rscript -e 'parse(file = commandArgs(trailingOnly = TRUE)[[1L]])' "$file" >/dev/null
done

source image.conf
jq -e --arg r_version "$R_VERSION" '
  .lockfile_version == 1 and
  (.r_version | startswith("R version " + $r_version + " ")) and
  ([.packages[] | select(.direct == true)] | length > 0) and
  all(.packages[];
    (.sources | length) > 0 and
    all(.sources[]; startswith("https://packagemanager.posit.co/")) and
    (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
  )
' pkg.lock >/dev/null

if rg -n 'cloud[.]r-project[.]org|r-universe[.]dev' \
  Containerfile container pkg.lock; then
  echo "a non-PPM R repository is configured" >&2
  exit 1
fi

rg -q '^ARG BASE_IMAGE$' Containerfile
rg -q '^ARG RDH_VERSION$' Containerfile
rg -Fq 'amd64|arm64' Containerfile
rg -Fq -- '--build-arg "RDH_VERSION=$version"' Justfile
if [[ "$BASE_IMAGE" == *@sha256:* ]]; then
  echo "the R base image is unexpectedly pinned by digest" >&2
  exit 1
fi

rg -q 'needenv::needenv[(]' container/database.R
rg -q 'RDH_DB_PROFILE' container/database.R
rg -q '^rdh_connect <- local[(]' container/database.R
rg -Fq 'sys.source("/opt/rdh/database.R", envir = globalenv())' container/Rprofile.site
rg -Fq 'env!("RDH_VERSION")' src/main.rs
rg -Fq 'cargo:rustc-env=RDH_VERSION' build.rs
rg -Fq -- '--cleanenv' src/main.rs
rg -Fq -- '--db PROFILE' src/main.rs
rg -Fq 'APPTAINERENV_' src/main.rs
rg -q '^docker://ghcr[.]io/cole-brokamp/rdh@sha256:' RELEASE_IMAGE
rg -q 'linux/amd64' .github/workflows/release.yml
rg -q 'linux/arm64' .github/workflows/release.yml
rg -Fq 'pattern: rdh-*' .github/workflows/release.yml

if [[ -e bin/rdh ]]; then
  echo "the obsolete Bash launcher still exists" >&2
  exit 1
fi

sentence_violations="$(rg -n '[.!?] [A-Z]' README.md | rg -v '^[0-9]+:[0-9]+[.] ' || true)"
if [[ -n "$sentence_violations" ]]; then
  printf '%s\n' "$sentence_violations"
  echo "README paragraphs must keep each sentence on its own physical line" >&2
  exit 1
fi

echo "static checks passed"

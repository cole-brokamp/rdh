#!/usr/bin/env bash

set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
binary="${1:-$repo_dir/target/debug/datahub-r}"
[[ "$binary" = /* ]] || binary="$repo_dir/$binary"
[[ -x "$binary" ]] || {
  echo "Rust CLI is not executable: $binary" >&2
  exit 1
}

test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT HUP INT TERM

fake_bin="$test_root/fake-bin"
project_dir="$test_root/project with spaces"
runtime_args="$test_root/runtime-args.log"
runtime_env="$test_root/runtime-env.log"
pull_log="$test_root/pull.log"
cache_dir="$test_root/cache"
data_dir="$test_root/data"
mkdir -p "$fake_bin" "$project_dir"
project_real="$(cd "$project_dir" && pwd -P)"

cat > "$fake_bin/container" <<'FAKE_CONTAINER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$DATAHUB_TEST_ARGS_LOG"
{
  printf 'profile=%s\n' "${DATAHUB_R_DB_PROFILE:-}"
  printf 'custom=%s\n' "${CUSTOM_SETTING:-}"
} > "$DATAHUB_TEST_ENV_LOG"
if [[ "${1:-}" == "image" && "${2:-}" == "pull" ]]; then
  printf 'container-pull\n' >> "$DATAHUB_TEST_PULL_LOG"
fi
FAKE_CONTAINER

cat > "$fake_bin/apptainer" <<'FAKE_APPTAINER'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--silent" && "${2:-}" == "pull" ]]; then
  printf 'apptainer-pull\n' >> "$DATAHUB_TEST_PULL_LOG"
  : > "$3"
  exit 0
fi
printf '%s\n' "$@" > "$DATAHUB_TEST_ARGS_LOG"
{
  printf 'profile=%s\n' "${APPTAINERENV_DATAHUB_R_DB_PROFILE:-}"
  printf 'host=%s\n' "${APPTAINERENV_MBHI_DB_HOST:-}"
  printf 'custom=%s\n' "${APPTAINERENV_CUSTOM_SETTING:-}"
  printf 'inherited_rlibs=%s\n' "${APPTAINERENV_R_LIBS_USER:-}"
  printf 'inherited_unrelated=%s\n' "${SINGULARITYENV_UNRELATED:-}"
} > "$DATAHUB_TEST_ENV_LOG"
FAKE_APPTAINER
chmod +x "$fake_bin/container" "$fake_bin/apptainer"
ln -s container "$fake_bin/docker"
ln -s container "$fake_bin/podman"

export PATH="$fake_bin:$PATH"
export DATAHUB_TEST_ARGS_LOG="$runtime_args"
export DATAHUB_TEST_ENV_LOG="$runtime_env"
export DATAHUB_TEST_PULL_LOG="$pull_log"
export DATAHUB_R_IMAGE="docker://example.invalid/datahub-r@sha256:0123456789abcdef"
export DATAHUB_R_CACHE_DIR="$cache_dir"
export DATAHUB_R_DATA_DIR="$data_dir"
export MBHI_DB_HOST="host-secret"
export MBHI_DB_USERNAME="user-secret"
export MBHI_DB_PASSWORD="password-secret"
export OMOP_DB_HOST="omop-host-secret"
export OMOP_DB_NAME="omop_cdm"
export OMOP_DB_USERNAME="omop-user-secret"
export OMOP_DB_PASSWORD="omop-password-secret"
export CUSTOM_SETTING="custom-secret"

expected_version="$(tr -d '\r\n' < "$repo_dir/VERSION")"
version_output="$($binary version)"
rg -Fq "datahub-r $expected_version" <<<"$version_output"
rg -Fq 'image override: docker://example.invalid/datahub-r@sha256:0123456789abcdef' <<<"$version_output"
"$binary" help | rg -q '^Usage:'
"$binary" --runtime container doctor | rg -Fq 'selected runtime: container'

# Informational commands remain usable when execution defaults need repair.
for command in help version; do
  DATAHUB_R_RUNTIME=invalid-runtime DATAHUB_R_DB_PROFILE=invalid-profile \
    "$binary" "$command" >/dev/null
done
DATAHUB_R_RUNTIME=invalid-runtime DATAHUB_R_DB_PROFILE=invalid-profile \
  "$binary" --runtime auto doctor >/dev/null
DATAHUB_R_RUNTIME=podman "$binary" doctor | rg -Fq 'selected runtime: podman'
if DATAHUB_R_RUNTIME=invalid-runtime "$binary" doctor >/dev/null 2>&1; then
  echo "an invalid runtime default was unexpectedly accepted" >&2
  exit 1
fi

cd "$project_dir"
"$binary" --runtime container --env CUSTOM_SETTING Rscript analysis.R --example
rg -Fxq 'run' "$runtime_args"
rg -Fxq -- '--rm' "$runtime_args"
rg -Fxq -- '--volume' "$runtime_args"
rg -Fxq -- '--workdir' "$runtime_args"
rg -Fxq -- "$project_real:$project_real" "$runtime_args"
rg -Fxq 'example.invalid/datahub-r@sha256:0123456789abcdef' "$runtime_args"
rg -Fxq 'DATAHUB_R_DB_PROFILE' "$runtime_args"
rg -Fxq 'MBHI_DB_HOST' "$runtime_args"
rg -Fxq 'CUSTOM_SETTING' "$runtime_args"
rg -Fxq 'Rscript' "$runtime_args"
rg -Fxq 'analysis.R' "$runtime_args"
rg -Fxq -- '--example' "$runtime_args"
rg -Fxq -- '--uid' "$runtime_args"
rg -Fxq -- '--gid' "$runtime_args"
rg -Fxq 'profile=MBHI' "$runtime_env"
rg -Fxq 'custom=custom-secret' "$runtime_env"

if rg -q 'host-secret|user-secret|password-secret|custom-secret' "$runtime_args"; then
  echo "an environment value leaked into OCI runtime arguments" >&2
  exit 1
fi

"$binary" --runtime docker Rscript analysis.R
rg -Fxq -- '--user' "$runtime_args"
if rg -Fxq -- '--uid' "$runtime_args" || rg -Fxq -- '--gid' "$runtime_args"; then
  echo "Docker unexpectedly received Apple container identity flags" >&2
  exit 1
fi

"$binary" --runtime podman Rscript analysis.R
rg -Fxq -- '--userns=keep-id' "$runtime_args"
if rg -Fxq -- '--user' "$runtime_args"; then
  echo "Podman unexpectedly received Docker's user flag" >&2
  exit 1
fi

"$binary" --runtime container --db omop Rscript analysis.R
rg -Fxq 'OMOP_DB_HOST' "$runtime_args"
rg -Fxq 'OMOP_DB_NAME' "$runtime_args"
if rg -Fxq 'MBHI_DB_HOST' "$runtime_args"; then
  echo "the unselected database profile was forwarded" >&2
  exit 1
fi

DATAHUB_R_DB_PROFILE=omop "$binary" --runtime container Rscript analysis.R
rg -Fxq 'profile=OMOP' "$runtime_env"
DATAHUB_R_DB_PROFILE=invalid-profile \
  "$binary" --runtime container --db mbhi Rscript analysis.R
rg -Fxq 'profile=MBHI' "$runtime_env"
if DATAHUB_R_DB_PROFILE=invalid-profile \
  "$binary" --runtime container Rscript analysis.R >/dev/null 2>&1; then
  echo "an invalid database profile default was unexpectedly accepted" >&2
  exit 1
fi

"$binary" --runtime container pull >/dev/null
rg -Fxq 'image' "$runtime_args"
rg -Fxq 'pull' "$runtime_args"
rg -Fxq 'container-pull' "$pull_log"

: > "$pull_log"
first_sif="$($binary --runtime apptainer pull)"
second_sif="$($binary --runtime apptainer pull)"
[[ "$first_sif" == "$second_sif" ]]
[[ -f "$first_sif" ]]
[[ "$(wc -l < "$pull_log" | tr -d ' ')" == "1" ]]

export APPTAINERENV_R_LIBS_USER="/host/module/library"
export SINGULARITYENV_UNRELATED="old-forwarding"
"$binary" --runtime apptainer --env CUSTOM_SETTING Rscript analysis.R
rg -Fxq -- '--cleanenv' "$runtime_args"
rg -Fxq 'Rscript' "$runtime_args"
rg -Fxq 'analysis.R' "$runtime_args"
rg -Fxq 'profile=MBHI' "$runtime_env"
rg -Fxq 'host=host-secret' "$runtime_env"
rg -Fxq 'custom=custom-secret' "$runtime_env"
rg -Fxq 'inherited_rlibs=' "$runtime_env"
rg -Fxq 'inherited_unrelated=' "$runtime_env"

if "$binary" --runtime container --env CUSTOM_SETTING=value R >/dev/null 2>&1; then
  echo "NAME=value unexpectedly accepted" >&2
  exit 1
fi
if "$binary" --runtime container --db INVALID-NAME R >/dev/null 2>&1; then
  echo "a malformed database profile was unexpectedly accepted" >&2
  exit 1
fi
if "$binary" --runtime container unknown-command >/dev/null 2>&1; then
  echo "an unknown command unexpectedly succeeded" >&2
  exit 1
fi

local_sif="$test_root/local.sif"
: > "$local_sif"
if DATAHUB_R_IMAGE="$local_sif" "$binary" --runtime container pull >/dev/null 2>&1; then
  echo "an OCI runtime unexpectedly accepted a local SIF" >&2
  exit 1
fi

echo "Rust CLI integration checks passed"

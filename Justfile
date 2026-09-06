set shell := ["bash", "-euo", "pipefail", "-c"]

image := "datahub-r:local"

default:
  @just --list

build:
  #!/usr/bin/env bash
  set -euo pipefail
  source image.conf
  version="$(tr -d '\r\n' < VERSION)"
  image_repository="${DATAHUB_R_IMAGE_REPOSITORY:-datahub-r}"
  case "$(uname -m)" in
    arm64|aarch64) native_platform="linux/arm64" ;;
    x86_64|amd64) native_platform="linux/amd64" ;;
    *) echo "unsupported host architecture: $(uname -m)" >&2; exit 1 ;;
  esac
  platform="${DATAHUB_R_PLATFORM:-$native_platform}"
  lock_sha="$(shasum -a 256 pkg.lock | awk '{print $1}')"
  build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if vcs_ref="$(git rev-parse --verify HEAD 2>/dev/null)"; then
    :
  else
    vcs_ref="uncommitted"
  fi
  container build \
    --platform "$platform" \
    --file Containerfile \
    --build-arg "BASE_IMAGE=$BASE_IMAGE" \
    --build-arg "R_VERSION=$R_VERSION" \
    --build-arg "PPM_REPO=$PPM_REPO" \
    --tag "{{image}}" \
    --tag "$image_repository:$version" \
    --build-arg "DATAHUB_R_VERSION=$version" \
    --build-arg "BUILD_DATE=$build_date" \
    --build-arg "VCS_REF=$vcs_ref" \
    --build-arg "PACKAGE_LOCK_SHA256=$lock_sha" \
    .

test-static:
  cargo fmt -- --check
  cargo test
  cargo build
  bash tests/test-static.sh
  bash tests/test-cli.sh target/debug/datahub-r
  bash tests/test-installer.sh target/debug/datahub-r
  bash tests/test-release-packaging.sh target/debug/datahub-r

test-image: build
  bash tests/test-image.sh "{{image}}"
  bash tests/test-layers.sh "{{image}}"

test: test-static test-image

install:
  #!/usr/bin/env bash
  set -euo pipefail
  cargo build --release
  install -d "${HOME}/.local/bin"
  install -m 0755 target/release/datahub-r "${HOME}/.local/bin/datahub-r"

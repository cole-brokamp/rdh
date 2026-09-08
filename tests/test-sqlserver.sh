#!/usr/bin/env bash

set -euo pipefail

image="${1:-rdh:ci}"
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
name="rdh-sqlserver-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT HUP INT TERM

# Disposable credentials also exercise connection-string delimiters and quotes.
export MSSQL_SA_PASSWORD="Rdh9;{$(openssl rand -hex 16)}=\"quote'"
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
  printf '::add-mask::%s\n' "$MSSQL_SA_PASSWORD"
fi
docker run --detach --name "$name" \
  --env ACCEPT_EULA=Y --env MSSQL_PID=Developer --env MSSQL_SA_PASSWORD \
  mcr.microsoft.com/mssql/server:2022-latest >/dev/null

ready=false
for ((attempt = 0; attempt < 60; attempt++)); do
  if docker exec "$name" bash -c \
    'SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -l 2 -Q "SELECT 1"' \
    >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 2
done
if [[ "$ready" != true ]]; then
  docker logs "$name"
  echo "disposable SQL Server did not become ready" >&2
  exit 1
fi

export MBHI_DB_HOST=localhost,1433
export MBHI_DB_NAME=tempdb
export MBHI_DB_USERNAME=sa
export MBHI_DB_PASSWORD="$MSSQL_SA_PASSWORD"
for script in /source/tests/test-check.R /opt/rdh/check.R /source/tests/test-sqlserver.R; do
  docker run --rm --network "container:$name" \
    --env MBHI_DB_HOST --env MBHI_DB_NAME --env MBHI_DB_USERNAME --env MBHI_DB_PASSWORD \
    --volume "$repo_dir:/source:ro" \
    --entrypoint Rscript "$image" "$script"
done

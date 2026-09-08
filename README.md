# rdh

`rdh` (R Data Hub) gives you the same ready-to-use R environment on a laptop, workstation, or computing cluster.
It includes tools for querying SQL Server databases, saving extracts, and writing data when your account has permission.
It runs through an available container runtime.

## Install

First, make sure one supported container runtime is available:

- macOS: Apple container, Docker, or Podman
- Linux: Docker, Podman, or Apptainer
- CCHMC cluster: Apptainer is detected and its module is loaded automatically

Then install `rdh`:

```sh
curl -fsSL https://raw.githubusercontent.com/cole-brokamp/rdh/main/install.sh | sh
```

The installer selects the correct executable and asks whether you want to download the container image now.
The initial image download can take several minutes, but later starts use the cached copy.

If the command is not found after installation, add its default location to `PATH`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

For unattended installation, use `--pull` to download the image or `--no-pull` to skip it:

```sh
curl -fsSL https://raw.githubusercontent.com/cole-brokamp/rdh/main/install.sh \
  | sh -s -- --pull
```

You can also download an archive directly from [GitHub Releases](https://github.com/cole-brokamp/rdh/releases).

## Start using it

Start an interactive R session in the current directory:

```sh
rdh
```

Run an R script:

```sh
rdh Rscript analysis.R
```

Install an R package normally.
It will remain available the next time you use `rdh`:

```r
install.packages("ggplot2")
```

## Connect to a database

Create a `.Renviron` file in your project directory:

```text
MBHI_DB_HOST=...
MBHI_DB_NAME=MBHI
MBHI_DB_USERNAME=...
MBHI_DB_PASSWORD=...
```

Protect the file and confirm the connection:

```sh
chmod 600 .Renviron
rdh check
```

Inside R, connect with:

```r
con <- rdh_connect()

results <- DBI::dbGetQuery(con, "SELECT TOP 10 * FROM my_table")

DBI::dbDisconnect(con)
```

`rdh_connect()` returns a normal DBI connection and does not disconnect automatically.
FreeTDS supplies the SQL Server connection, so existing dplyr and dbplyr pipelines continue to use SQL Server SQL translation.
Host, username, and password are required; the database name defaults to the uppercase profile name when omitted or empty.
Hosts may include a port (`server,1433`) or named instance (`server\instance`).

For another database profile, use matching variable names such as `OMOP_DB_HOST`, `OMOP_DB_NAME`, `OMOP_DB_USERNAME`, and `OMOP_DB_PASSWORD`.
Select that profile when starting the script:

```sh
rdh --db OMOP Rscript analysis.R
```

You can also select it directly in R:

```r
con <- rdh_connect("OMOP")
```

For CCHMC domain credentials, use a domain-qualified username in `.Renviron`:

```text
OMOP_DB_HOST=ritepicprod02ms,1433
OMOP_DB_NAME=omop
OMOP_DB_USERNAME='chmcres\your_username'
OMOP_DB_PASSWORD='your_password'
```

Keep the single backslash inside the quotes exactly as shown.
Bare usernames use SQL Server authentication; domain-qualified usernames use NTLM.
The helper passes the username unchanged and does not add a domain or retry another authentication method.
Passwords and other connection values are escaped for FreeTDS, including semicolons and closing braces.
The pinned FreeTDS version cannot represent a closing brace immediately followed by a semicolon (`};`) inside a value; the helper rejects that sequence before connecting.
When entering a password in `.Renviron`, choose surrounding quotes that do not occur in the password and follow R's `.Renviron` quoting rules.
`rdh check` reports the server's authentication scheme without printing credentials.

## CCHMC cluster

Start a compute session with `bsi` before running the container.
The observed login node cannot run the cluster's Apptainer build because its glibc is too old.
`rdh` loads the Apptainer module automatically when needed.

Upgrade to this release, then run the connection checks from the directory containing `.Renviron`:

```sh
curl -fsSL https://raw.githubusercontent.com/cole-brokamp/rdh/v2026.09.3/install.sh \
  | sh -s -- --version 2026.09.3 --no-pull
bsi
cd /path/to/your/project
rdh version
rdh --db OMOP check
rdh --db OMOP Rscript /opt/rdh/test-connection.R
```

The bundled acceptance script uses synthetic, read-only queries to check SQL Server class detection, dbplyr filters and joins, exact large integers, dates and timestamps, Unicode, and nulls.
It closes its connection after the checks and does not read application tables or write to the database.
The [previous release](https://github.com/cole-brokamp/rdh/releases/tag/v2026.09.2) remains available for rollback; install it with `--version 2026.09.2`.

## Useful commands

| Command | What it does |
| --- | --- |
| `rdh` | Start interactive R |
| `rdh Rscript analysis.R` | Run an R script |
| `rdh check` | Check R, the database driver, and the selected connection |
| `rdh pull` | Download the container image without starting R |
| `rdh doctor` | Show the detected runtime and local paths |
| `rdh shell` | Start a shell inside the environment |
| `rdh version` | Show the installed version and linked image |

Use `--runtime` only when you need to override automatic runtime selection:

```sh
rdh --runtime apptainer Rscript analysis.R
```

Forward an additional exported environment variable by name with `--env`:

```sh
export MY_SETTING=value
rdh --env MY_SETTING Rscript analysis.R
```

## Technical notes

- The current release is `2026.09.3`.
- The environment uses R 4.6.1, Ubuntu's FreeTDS ODBC package `tdsodbc` version `1.3.17+ds-2build3`, and common data packages including DBI, odbc, dplyr, dbplyr, nanoparquet, bit64, pak, and renv.
- Connections use TDS 7.4, NTLMv2, required encryption, UTF-8, and `integer64` results for SQL Server `bigint` values.
- Certificate trust remains as before: the server certificate is accepted without CA validation.
- Released executables are available for macOS and Linux on both AMD64 and ARM64.
- Each executable is linked to an immutable multi-architecture image digest.
- Apptainer images are cached under `/scratch/$USER/rdh` when available, otherwise under the user cache directory; set `RDH_CACHE_DIR` to override it.
- User-installed R packages persist under the user data directory; set `RDH_DATA_DIR` to override it.
- Packages use Posit Public Package Manager by default.
- `image.conf` defines the R version, base image, and package repository for local and release builds; `pkg.lock` defines required packages and their versions.
- Database secrets are read from the selected profile's environment variables and are not placed in container command arguments.

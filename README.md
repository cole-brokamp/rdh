# rdh

`rdh` (R Data Hub) gives you a ready-to-use R environment for connecting to SQL Server with your domain credentials using NTLM.
It includes tools for querying SQL Server databases, saving extracts, and writing data when your account has permission.
It runs on macOS and Linux through an available container runtime.

## Install

First, make sure one supported container runtime is available:

- macOS: Apple container, Docker, or Podman
- Linux: Docker, Podman, or Apptainer

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

## Connect with NTLM

Use NTLM with your organization's username and password, including your domain in your username.
Create a `.Renviron` file in your project directory:

```text
MBHI_DB_HOST=sql.example.invalid
MBHI_DB_NAME=MBHI
MBHI_DB_USERNAME='YOUR_DOMAIN\your_username'
MBHI_DB_PASSWORD='your_password'
```

Replace the dummy host, `YOUR_DOMAIN`, and credentials with your own values.
Keep the single backslash inside the quotes exactly as shown.
The domain-qualified username selects NTLM authentication.
`rdh_connect()` passes it unchanged, so include the domain yourself.

Protect the file and confirm the connection:

```sh
chmod 600 .Renviron
rdh check
```

`rdh check` should report `authentication: NTLM` without printing your credentials.
Start R with `rdh`, then connect:

```r
con <- rdh_connect()

results <- DBI::dbGetQuery(con, "SELECT TOP 10 * FROM my_table")

DBI::dbDisconnect(con)
```

`rdh_connect()` returns a normal DBI connection and does not disconnect automatically.
FreeTDS supplies the SQL Server connection, so existing dplyr and dbplyr pipelines continue to use SQL Server SQL translation.
Host, username, and password are required; the database name defaults to the uppercase profile name when omitted or empty.

For a more complete connection check, run the bundled read-only test:

```sh
rdh Rscript /opt/rdh/test-connection.R
```

It uses synthetic queries to check SQL Server class detection, dbplyr filters and joins, exact large integers, dates and timestamps, Unicode, and nulls, then closes its connection.

## Use another database profile

Use matching variable names for another database, with the same NTLM credential format:

```text
OMOP_DB_HOST=sql.example.invalid
OMOP_DB_NAME=omop
OMOP_DB_USERNAME='YOUR_DOMAIN\your_username'
OMOP_DB_PASSWORD='your_password'
```

Select that profile when checking the connection or starting a script:

```sh
rdh --db OMOP check
rdh --db OMOP Rscript analysis.R
```

You can also select it directly in R:

```r
con <- rdh_connect("OMOP")

results <- DBI::dbGetQuery(con, "SELECT TOP 10 * FROM cdm.person")

DBI::dbDisconnect(con)
```

## Run scripts and install packages

Run an R script using your project's `.Renviron` credentials:

```sh
rdh Rscript analysis.R
```

Install an R package normally.
It will remain available the next time you use `rdh`:

```r
install.packages("ggplot2")
```

## Bundled R package versions

The container recipe in this checkout freezes all 48 packages below to the latest versions available from [Posit Public Package Manager](https://packagemanager.posit.co/cran/latest) on October 20, 2026.
This includes direct packages, their required dependencies, and all 15 recommended packages distributed with R.
The committed `pkg.lock` fixes each version, so rebuilding against the `latest` repository does not upgrade these packages.
The build checks every installed version against the lock and writes `/opt/rdh/installed-packages.csv` inside the image.

| Package | Version |
| --- | --- |
| bit | 4.6.0 |
| bit64 | 4.8.6 |
| blob | 1.3.0 |
| boot | 1.3-32 |
| class | 7.3-24 |
| cli | 3.6.6 |
| cluster | 2.1.8.3 |
| codetools | 0.2-20 |
| cpp11 | 0.5.5 |
| DBI | 1.3.0 |
| dbplyr | 2.6.0 |
| digest | 0.6.39 |
| dplyr | 1.2.1 |
| foreign | 0.8-92 |
| generics | 0.1.4 |
| glue | 1.8.1 |
| hms | 1.1.4 |
| KernSmooth | 2.23-27 |
| lattice | 0.23-1 |
| lifecycle | 1.0.5 |
| magrittr | 2.0.5 |
| MASS | 7.3-66 |
| Matrix | 1.7-6 |
| mgcv | 1.9-4 |
| nanoparquet | 0.5.2 |
| needenv | 0.1.0 |
| nlme | 3.1-171 |
| nnet | 7.3-21 |
| odbc | 1.7.2 |
| pak | 0.11.1 |
| pillar | 1.11.1 |
| pkgconfig | 2.0.3 |
| purrr | 1.2.2 |
| R6 | 2.6.1 |
| Rcpp | 1.1.2 |
| renv | 1.3.1 |
| rlang | 1.3.0 |
| rpart | 4.1.27 |
| spatial | 7.3-19 |
| stringi | 1.8.9 |
| stringr | 1.6.0 |
| survival | 3.8-12 |
| tibble | 3.3.1 |
| tidyr | 1.3.2 |
| tidyselect | 1.2.1 |
| utf8 | 1.2.6 |
| vctrs | 0.7.3 |
| withr | 3.0.3 |

R's base packages (`base`, `compiler`, `datasets`, `graphics`, `grDevices`, `grid`, `methods`, `parallel`, `splines`, `stats`, `stats4`, `tcltk`, `tools`, and `utils`) each use version 4.6.1, supplied by `posit/r-base:4.6.1-noble`.
To inspect the frozen package manifest in your container:

```sh
rdh Rscript -e 'print(read.csv("/opt/rdh/installed-packages.csv"), row.names = FALSE)'
```

## Access additional directories with Apptainer

`rdh` binds your current project directory and its persistent R package directory automatically.
To access another host directory, such as `/scratch` or `/data`, set `APPTAINER_BINDPATH` in your host shell before starting `rdh`:

```sh
export APPTAINER_BINDPATH="/scratch,/data"
rdh --runtime apptainer Rscript analysis.R
```

Use only directories that exist on your host, and separate multiple binds with commas.
These directories are available at the same paths inside R, with read/write access by default and your existing filesystem permissions.
For a different container path or read-only access, use `host_path:container_path[:ro]`:

```sh
APPTAINER_BINDPATH="/scratch:/work,/data:/data:ro" \
  rdh --runtime apptainer Rscript analysis.R
```

Apptainer also accepts `APPTAINER_BIND` with the same syntax.
Set these variables in your shell or job script, not in `.Renviron`; Apptainer reads them before R starts, so `rdh --env` is unnecessary for bind settings.
See the [Apptainer bind documentation](https://apptainer.org/docs/user/main/bind_paths_and_mounts.html) for more options.

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
rdh --runtime docker Rscript analysis.R
```

Forward an additional exported environment variable by name with `--env`:

```sh
export MY_SETTING=value
rdh --env MY_SETTING Rscript analysis.R
```

## Technical notes

- The current release is `2026.09.3`.
- The environment uses R 4.6.1, Ubuntu's FreeTDS ODBC package `tdsodbc` version `1.3.17+ds-2build3`, and common data packages including DBI, odbc, dplyr, dbplyr, nanoparquet, bit64, digest, pak, and renv.
- Connections use TDS 7.4, NTLMv2, required encryption, UTF-8, and `integer64` results for SQL Server `bigint` values.
- Certificate trust remains as before: the server certificate is accepted without CA validation.
- Released executables are available for macOS and Linux on both AMD64 and ARM64.
- Each executable is linked to an immutable multi-architecture image digest.
- Apptainer images are cached locally; set `RDH_CACHE_DIR` to choose the cache directory.
- User-installed R packages persist under the user data directory; set `RDH_DATA_DIR` to override it.
- Packages use Posit Public Package Manager by default.
- `image.conf` defines the R version, base image, and package repository for local and release builds; `pkg.lock` defines required packages and their versions.
- Database secrets are read from the selected profile's environment variables and are not placed in container command arguments.
- Passwords and other connection values are escaped for FreeTDS, including semicolons and closing braces; the pinned driver cannot represent the sequence `};` inside a value, so the helper rejects it before connecting.
- When entering a password in `.Renviron`, choose surrounding quotes that do not occur in the password and follow R's `.Renviron` quoting rules.
- For writes with `DBI::dbWriteTable()`, specify SQL column types when precision matters, such as `field.types = c(big_id = "bigint", test_time = "datetime2(3)")`.
- Native `POSIXct` writes through the pinned driver drop fractional seconds; to preserve milliseconds, first convert the timestamp column with `format(x, "%Y-%m-%dT%H:%M:%OS6", tz = "UTC")` and write those strings into an explicit `datetime2(3)` column.
- Timestamp reads preserve fractional seconds.

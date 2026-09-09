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

Use NTLM with your CCHMC username and password, including the `chmcres` domain in your username.
Create a `.Renviron` file in your project directory:

```text
MBHI_DB_HOST=your_sql_server,1433
MBHI_DB_NAME=MBHI
MBHI_DB_USERNAME='chmcres\your_username'
MBHI_DB_PASSWORD='your_password'
```

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
Hosts may include a port (`server,1433`) or named instance (`server\instance`).

For a more complete connection check, run the bundled read-only test:

```sh
rdh Rscript /opt/rdh/test-connection.R
```

It uses synthetic queries to check SQL Server class detection, dbplyr filters and joins, exact large integers, dates and timestamps, Unicode, and nulls, then closes its connection.

## Use another database profile

Use matching variable names for another database, with the same NTLM credential format:

```text
OMOP_DB_HOST=ritepicprod02ms,1433
OMOP_DB_NAME=omop
OMOP_DB_USERNAME='chmcres\your_username'
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
- The environment uses R 4.6.1, Ubuntu's FreeTDS ODBC package `tdsodbc` version `1.3.17+ds-2build3`, and common data packages including DBI, odbc, dplyr, dbplyr, nanoparquet, bit64, pak, and renv.
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

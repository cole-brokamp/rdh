# datahub-r

`datahub-r` gives you the same ready-to-use R environment on a laptop, workstation, or computing cluster.
It includes the tools needed to work with CCHMC SQL Server databases and runs through an available container runtime.

## Install

First, make sure one supported container runtime is available:

- macOS: Apple container, Docker, or Podman
- Linux: Docker, Podman, or Apptainer
- CCHMC cluster: Apptainer is detected and its module is loaded automatically

Then install `datahub-r`:

```sh
curl -fsSL https://raw.githubusercontent.com/cole-brokamp/datahub-r/main/install.sh | sh
```

The installer selects the correct executable and asks whether you want to download the container image now.
The initial image download can take several minutes, but later starts use the cached copy.

If the command is not found after installation, add its default location to `PATH`:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

For unattended installation, use `--pull` to download the image or `--no-pull` to skip it:

```sh
curl -fsSL https://raw.githubusercontent.com/cole-brokamp/datahub-r/main/install.sh \
  | sh -s -- --pull
```

You can also download an archive directly from [GitHub Releases](https://github.com/cole-brokamp/datahub-r/releases).

## Start using it

Start an interactive R session in the current directory:

```sh
datahub-r
```

Run an R script:

```sh
datahub-r Rscript analysis.R
```

Install an R package normally.
It will remain available the next time you use `datahub-r`:

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
datahub-r check
```

Inside R, connect with:

```r
con <- datahub_connect()

results <- DBI::dbGetQuery(con, "SELECT TOP 10 * FROM my_table")

DBI::dbDisconnect(con)
```

`datahub_connect()` returns a normal DBI connection and does not disconnect automatically.

For another database profile, use matching variable names such as `OMOP_DB_HOST`, `OMOP_DB_NAME`, `OMOP_DB_USERNAME`, and `OMOP_DB_PASSWORD`.
Select that profile when starting the script:

```sh
datahub-r --db OMOP Rscript analysis.R
```

You can also select it directly in R:

```r
con <- datahub_connect("OMOP")
```

## Useful commands

| Command | What it does |
| --- | --- |
| `datahub-r` | Start interactive R |
| `datahub-r Rscript analysis.R` | Run an R script |
| `datahub-r check` | Check R, the database driver, and the selected connection |
| `datahub-r pull` | Download the container image without starting R |
| `datahub-r doctor` | Show the detected runtime and local paths |
| `datahub-r shell` | Start a shell inside the environment |
| `datahub-r version` | Show the installed version and linked image |

Use `--runtime` only when you need to override automatic runtime selection:

```sh
datahub-r --runtime apptainer Rscript analysis.R
```

Forward an additional exported environment variable by name with `--env`:

```sh
export MY_SETTING=value
datahub-r --env MY_SETTING Rscript analysis.R
```

## Technical notes

- The current release is `2026.09.1`.
- The environment currently uses R 4.6.1, Microsoft ODBC Driver 18, and common data packages including DBI, odbc, dplyr, dbplyr, nanoparquet, bit64, pak, and renv.
- Released executables are available for macOS and Linux on both AMD64 and ARM64.
- Each executable is linked to an immutable multi-architecture image digest.
- Apptainer images are cached under `/scratch/$USER/datahub-r` when available, otherwise under the user cache directory; set `DATAHUB_R_CACHE_DIR` to override it.
- User-installed R packages persist under the user data directory; set `DATAHUB_R_DATA_DIR` to override it.
- Packages use Posit Public Package Manager by default.
- `image.conf` defines the R version, base image, and package repository for local and release builds; `pkg.lock` defines required packages and their versions.
- Database secrets are read from the selected profile's environment variables and are not placed in container command arguments.

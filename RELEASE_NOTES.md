rdh (R Data Hub) is the new name for the portable R environment for database work.

- The executable is now `rdh`, the connection helper is `rdh_connect()`, and launcher settings use `RDH_` instead of `DATAHUB_R_`.
- Explicit runtime choices override environment defaults; help and version output remain available when execution settings are invalid.
- The package-library directory override works with Apptainer as well as Apple container, Docker, and Podman.
- Image builds and R startup share settings, and required packages come from the lockfile.
- Only the public connection helper is loaded into the R workspace; callers still close their own DBI connections.
- The unused image-version script and duplicate metadata file have been removed; build metadata remains in OCI labels.

Install or upgrade with:

```sh
curl -fsSL https://raw.githubusercontent.com/cole-brokamp/rdh/main/install.sh | sh -s -- --version 2026.09.2 --pull
```

Update existing scripts to call `rdh` and `rdh_connect()`, and change launcher environment variable prefixes to `RDH_`.
Database credential names such as `MBHI_DB_HOST` are unchanged.
New package libraries and image caches use directories named `rdh`.
To reuse packages installed under the previous name, set `RDH_DATA_DIR` to the old package directory, for example `$HOME/.local/share/datahub-r`.

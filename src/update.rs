use std::env;
use std::ffi::{OsStr, OsString};
use std::fs::{self, OpenOptions};
use std::io::{self, IsTerminal, Read, Seek, Write};
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

const RELEASES: &str = "https://github.com/cole-brokamp/rdh/releases";
const INSTALL: &str =
    "curl -fsSL https://raw.githubusercontent.com/cole-brokamp/rdh/main/install.sh | sh";
const CHECK_INTERVAL: u64 = 24 * 60 * 60;

pub fn notify(payload: &[OsString]) {
    if env::var_os("RDH_NO_UPDATE_CHECK").as_deref() == Some(OsStr::new("1"))
        || !io::stdin().is_terminal()
        || !io::stdout().is_terminal()
        || !io::stderr().is_terminal()
        || !interactive_r(payload)
    {
        return;
    }
    let Ok(root) = super::cache_root() else {
        return;
    };
    let Ok(now) = SystemTime::now().duration_since(UNIX_EPOCH) else {
        return;
    };
    let _ = check(&root, now.as_secs(), latest_release, &mut io::stderr());
}

fn interactive_r(payload: &[OsString]) -> bool {
    if payload.first().and_then(|value| value.to_str()) != Some("R") {
        return false;
    }
    // Unknown arguments may execute a file or expression, so only check for
    // known interactive options. Arguments after --args are passed through to R.
    payload[1..]
        .iter()
        .take_while(|argument| *argument != "--args")
        .all(|argument| {
            matches!(
                argument.to_str(),
                Some(
                    "--vanilla"
                        | "--quiet"
                        | "-q"
                        | "--silent"
                        | "--save"
                        | "--no-save"
                        | "--no-restore"
                        | "--no-restore-data"
                        | "--no-restore-history"
                        | "--no-site-file"
                        | "--no-init-file"
                        | "--no-environ"
                        | "--interactive"
                )
            )
        })
}

fn check(
    root: &Path,
    now: u64,
    fetch: impl FnOnce() -> Option<String>,
    output: &mut impl Write,
) -> io::Result<()> {
    if !claim_check(root, now)? {
        return Ok(());
    }
    if let Some(version) = fetch()
        && let (Some(latest), Some(installed)) = (calver(&version), calver(super::VERSION))
        && latest > installed
    {
        writeln!(
            output,
            "rdh {version} is available (installed: {}).\nRelease notes: {RELEASES}/tag/v{version}\nUpdate: {INSTALL}\nUse your original install directory if you chose a custom location.",
            super::VERSION
        )?;
    }
    Ok(())
}

fn claim_check(root: &Path, now: u64) -> io::Result<bool> {
    fs::create_dir_all(root)?;
    let mut marker = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(root.join("update-check"))?;
    // A nonblocking lock also prevents simultaneous interactive starts from
    // checking twice. If locking or writing is unavailable, skip the check.
    if marker.try_lock().is_err() {
        return Ok(false);
    }
    let mut previous = String::new();
    marker.read_to_string(&mut previous)?;
    if let Ok(last) = previous.trim().parse::<u64>()
        && now.saturating_sub(last) < CHECK_INTERVAL
    {
        return Ok(false);
    }
    // Record attempts before requesting, including failures on offline hosts.
    marker.rewind()?;
    marker.set_len(0)?;
    write!(marker, "{now}")?;
    Ok(true)
}

fn latest_release() -> Option<String> {
    // Resolve GitHub's latest-release redirect without a JSON/HTTP dependency.
    // Disable curl's user config so it cannot override the quiet timeout.
    let output = Command::new("curl")
        .args([
            "--disable",
            "--fail",
            "--silent",
            "--head",
            "--location",
            "--max-redirs",
            "3",
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "--connect-timeout",
            "1",
            "--max-time",
            "2",
            "--output",
            "/dev/null",
            "--write-out",
            "%{url_effective}",
            &format!("{RELEASES}/latest"),
        ])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    release_version(std::str::from_utf8(&output.stdout).ok()?)
}

fn release_version(url: &str) -> Option<String> {
    let version = url.trim().strip_prefix(&format!("{RELEASES}/tag/v"))?;
    calver(version)?;
    Some(version.to_owned())
}

fn calver(version: &str) -> Option<(u32, u32, u32)> {
    let mut parts = version.split('.');
    let year = parts.next()?;
    let month = parts.next()?;
    let revision = parts.next()?;
    if parts.next().is_some()
        || year.len() != 4
        || month.len() != 2
        || revision.is_empty()
        || (revision.len() > 1 && revision.starts_with('0'))
        || ![year, month, revision]
            .iter()
            .all(|part| part.bytes().all(|byte| byte.is_ascii_digit()))
    {
        return None;
    }
    let month = month.parse().ok()?;
    if !(1..=12).contains(&month) {
        return None;
    }
    Some((year.parse().ok()?, month, revision.parse().ok()?))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Cache(std::path::PathBuf);

    impl Cache {
        fn new() -> Self {
            static NEXT: AtomicUsize = AtomicUsize::new(0);
            let root = env::temp_dir().join(format!(
                "rdh-update-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&root).unwrap();
            Self(root)
        }
    }

    impl Drop for Cache {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn only_interactive_r_commands_are_eligible() {
        for args in [vec!["R"], vec!["R", "--vanilla", "--quiet"]] {
            assert!(interactive_r(&super::super::os_strings(&args)));
        }
        for args in [
            vec!["Rscript", "analysis.R"],
            vec!["R", "-e", "1"],
            vec!["R", "-f", "analysis.R"],
            vec!["R", "--file=analysis.R"],
            vec!["R", "CMD", "BATCH", "analysis.R"],
            vec!["R", "--version"],
            vec!["/bin/bash"],
        ] {
            assert!(!interactive_r(&super::super::os_strings(&args)));
        }
    }

    #[test]
    fn versions_are_numeric_and_only_stable_release_urls_are_accepted() {
        assert!(calver("2026.10.10") > calver("2026.10.9"));
        assert!(calver("2027.01.0") > calver("2026.12.99"));
        assert_eq!(
            release_version(&format!("{RELEASES}/tag/v2026.10.1\n")),
            Some("2026.10.1".to_owned())
        );
        for version in [
            "2026.00.0",
            "2026.13.0",
            "2026.10.01",
            "2026.10.1-dev",
            "2026.10.1/",
            "2026.10.+1",
            "2026.1.0",
            "garbage",
        ] {
            assert!(calver(version).is_none(), "{version}");
        }
        assert!(release_version(&format!("{RELEASES}/latest")).is_none());
        assert!(release_version("https://example.invalid/tag/v2026.10.1").is_none());
    }

    #[test]
    fn attempts_are_throttled_including_network_failures() {
        let cache = Cache::new();
        let mut output = Vec::new();
        check(&cache.0, CHECK_INTERVAL, || None, &mut output).unwrap();
        check(
            &cache.0,
            2 * CHECK_INTERVAL - 1,
            || panic!("must not retry within 24 hours"),
            &mut output,
        )
        .unwrap();
        assert!(output.is_empty());
        check(
            &cache.0,
            2 * CHECK_INTERVAL,
            || Some("9999.12.1".to_owned()),
            &mut output,
        )
        .unwrap();
        let notice = String::from_utf8(output).unwrap();
        assert!(notice.contains("rdh 9999.12.1 is available"));
        assert!(notice.contains(INSTALL));
        assert!(notice.contains("/releases/tag/v9999.12.1"));
    }

    #[test]
    fn current_older_and_invalid_versions_do_not_notify() {
        for version in [super::super::VERSION, "2000.01.0", "invalid"] {
            let cache = Cache::new();
            let mut output = Vec::new();
            check(
                &cache.0,
                CHECK_INTERVAL,
                || Some(version.to_owned()),
                &mut output,
            )
            .unwrap();
            assert!(output.is_empty());
        }
    }

    #[test]
    fn locked_or_unwritable_cache_skips_the_request() {
        let cache = Cache::new();
        let marker = fs::File::create(cache.0.join("update-check")).unwrap();
        marker.try_lock().unwrap();
        check(
            &cache.0,
            CHECK_INTERVAL,
            || panic!("must not fetch while another process holds the lock"),
            &mut Vec::new(),
        )
        .unwrap();
        assert!(
            check(
                &cache.0.join("update-check"),
                CHECK_INTERVAL,
                || panic!("must not fetch without a writable cache"),
                &mut Vec::new(),
            )
            .is_err()
        );
    }
}

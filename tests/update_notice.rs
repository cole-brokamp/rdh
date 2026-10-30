#![cfg(unix)]

use std::fs::{self, File};
use std::io::{self, Read};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, ExitStatus, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const RELEASES: &str = "https://github.com/cole-brokamp/rdh/releases";

#[test]
fn notices_use_stderr_and_throttle_successful_and_failed_checks() {
    let fixture = Fixture::new();
    let output = fixture.run(&[], None, &[]);
    output.assert_runtime();
    assert!(output.stderr.contains("rdh 9999.12.1 is available"));
    assert!(
        output
            .stderr
            .contains(&format!("{RELEASES}/tag/v9999.12.1"))
    );
    assert!(output.stderr.contains("Update: curl -fsSL"));
    assert!(!output.stderr.contains("network error"));
    let requests = fs::read_to_string(fixture.requests()).unwrap();
    let arguments: Vec<_> = requests.lines().collect();
    assert_eq!(arguments[0], "--disable");
    for (option, value) in [("--max-time", "2"), ("--connect-timeout", "1")] {
        let index = arguments.iter().position(|arg| *arg == option).unwrap();
        assert_eq!(arguments[index + 1], value);
    }
    assert_eq!(*arguments.last().unwrap(), format!("{RELEASES}/latest"));
    assert!(!fixture.run(&[], None, &[]).stderr.contains("is available"));
    assert_eq!(fs::read_to_string(fixture.requests()).unwrap(), requests);

    // Expiration permits a new attempt. Offline failures also consume it.
    fs::write(fixture.marker(), "0").unwrap();
    let failed = fixture.run(&[], None, &[("UPDATE_STATUS", "28")]);
    failed.assert_runtime();
    assert_eq!(failed.stderr.trim(), "runtime stderr");
    let requests = fs::read(fixture.requests()).unwrap();
    fixture.run(&[], None, &[]).assert_runtime();
    assert_eq!(fs::read(fixture.requests()).unwrap(), requests);
}

#[test]
fn current_older_and_invalid_responses_stay_quiet() {
    let fixture = Fixture::new();
    for url in [
        format!("{RELEASES}/tag/v2000.01.0"),
        format!("{RELEASES}/tag/v{}", include_str!("../VERSION").trim()),
        format!("{RELEASES}/tag/v9999.12.1-dev"),
        "invalid response".to_owned(),
    ] {
        fixture.reset();
        let output = fixture.run(&[], None, &[("UPDATE_URL", &url)]);
        output.assert_runtime();
        assert_eq!(output.stderr.trim(), "runtime stderr", "{url}");
    }
}

#[test]
fn scripts_informational_commands_redirects_and_opt_out_skip_requests() {
    let fixture = Fixture::new();
    for arguments in [
        vec!["Rscript", "analysis.R"],
        vec!["R", "-e", "1"],
        vec!["R", "--file=analysis.R"],
        vec!["R", "CMD", "BATCH", "analysis.R"],
        vec!["check"],
        vec!["shell"],
        vec!["help"],
        vec!["version"],
        vec!["doctor"],
        vec!["pull"],
    ] {
        fixture.run(&arguments, None, &[]);
        fixture.assert_no_check();
    }
    for redirected in 0..3 {
        fixture.run(&[], Some(redirected), &[]).assert_runtime();
        fixture.assert_no_check();
    }
    fixture
        .run(&[], None, &[("RDH_NO_UPDATE_CHECK", "1")])
        .assert_runtime();
    fixture.assert_no_check();
}

#[test]
fn missing_curl_and_unusable_cache_preserve_runtime_output_and_status() {
    let fixture = Fixture::new();
    fs::remove_file(fixture.root.join("bin/curl")).unwrap();
    let missing = fixture.run(&[], None, &[]);
    missing.assert_runtime();
    assert_eq!(missing.stderr.trim(), "runtime stderr");
    let unusable = fixture.root.join("bin/container");
    let output = fixture.run(&[], None, &[("RDH_CACHE_DIR", unusable.to_str().unwrap())]);
    output.assert_runtime();
    assert_eq!(output.stderr.trim(), "runtime stderr");
}

struct Fixture {
    root: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("rdh-update-{}-{unique}", std::process::id()));
        fs::create_dir(&root).unwrap();
        fs::create_dir(root.join("bin")).unwrap();
        for (name, script) in [
            (
                "curl",
                "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"$UPDATE_REQUESTS\"\nprintf '%s' \"$UPDATE_URL\"\nprintf 'network error\\n' >&2\nexit \"$UPDATE_STATUS\"\n",
            ),
            (
                "container",
                "#!/bin/sh\nprintf 'runtime stdout\\n'\nprintf 'runtime stderr\\n' >&2\nexit 7\n",
            ),
        ] {
            let path = root.join("bin").join(name);
            fs::write(&path, script).unwrap();
            fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
        }
        Self { root }
    }

    fn requests(&self) -> PathBuf {
        self.root.join("requests")
    }

    fn marker(&self) -> PathBuf {
        self.root.join("cache/update-check")
    }

    fn reset(&self) {
        for path in [self.requests(), self.marker()] {
            if path.exists() {
                fs::remove_file(path).unwrap();
            }
        }
    }

    fn assert_no_check(&self) {
        assert!(!self.requests().exists());
        assert!(!self.marker().exists());
    }

    fn run(&self, args: &[&str], redirected: Option<usize>, vars: &[(&str, &str)]) -> Output {
        let input = Terminal::new();
        let mut stdout = Terminal::new();
        let mut stderr = Terminal::new();
        let mut command = Command::new(env!("CARGO_BIN_EXE_rdh"));
        command
            .args(args)
            .env_clear()
            .env("PATH", self.root.join("bin"))
            .env("HOME", &self.root)
            .env("RDH_RUNTIME", "container")
            .env("RDH_DB_PROFILE", "MBHI")
            .env("RDH_IMAGE", "docker://example.invalid/rdh:test")
            .env("RDH_DATA_DIR", self.root.join("data"))
            .env("RDH_CACHE_DIR", self.root.join("cache"))
            .env("UPDATE_REQUESTS", self.requests())
            .env("UPDATE_URL", format!("{RELEASES}/tag/v9999.12.1"))
            .env("UPDATE_STATUS", "0")
            .envs(vars.iter().copied())
            .current_dir(&self.root)
            .stdin(if redirected == Some(0) {
                Stdio::null()
            } else {
                input.stream()
            })
            .stdout(if redirected == Some(1) {
                Stdio::piped()
            } else {
                stdout.stream()
            })
            .stderr(if redirected == Some(2) {
                Stdio::piped()
            } else {
                stderr.stream()
            });
        let mut child = command.spawn().unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut out = Vec::new();
        let mut err = Vec::new();
        let status = loop {
            // Drain while running so terminal buffers cannot block the child.
            stdout.drain(&mut out);
            stderr.drain(&mut err);
            if let Some(status) = child.try_wait().unwrap() {
                break status;
            }
            if Instant::now() >= deadline {
                child.kill().unwrap();
                child.wait().unwrap();
                panic!("CLI timed out: {args:?}");
            }
            thread::sleep(Duration::from_millis(5));
        };
        // Keep the slaves open until drained: macOS discards unread terminal
        // data when the last slave closes. Redirected fixture output is tiny.
        stdout.drain(&mut out);
        stderr.drain(&mut err);
        if let Some(mut pipe) = child.stdout.take() {
            pipe.read_to_end(&mut out).unwrap();
        }
        if let Some(mut pipe) = child.stderr.take() {
            pipe.read_to_end(&mut err).unwrap();
        }
        Output {
            status,
            stdout: String::from_utf8(out).unwrap(),
            stderr: String::from_utf8(err).unwrap(),
        }
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

struct Output {
    status: ExitStatus,
    stdout: String,
    stderr: String,
}

impl Output {
    fn assert_runtime(&self) {
        assert_eq!(self.status.code(), Some(7), "{}", self.stderr);
        assert_eq!(self.stdout.trim(), "runtime stdout");
        assert!(self.stderr.contains("runtime stderr"));
    }
}

struct Terminal {
    master: File,
    slave: File,
}

impl Terminal {
    fn new() -> Self {
        let mut master = -1;
        let mut slave = -1;
        // SAFETY: openpty receives valid output pointers and null optional
        // settings. On success it returns two new, uniquely owned descriptors.
        let result = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert_eq!(result, 0, "openpty: {}", io::Error::last_os_error());
        // SAFETY: successful openpty transfers ownership of these descriptors.
        let terminal = unsafe {
            Self {
                master: File::from_raw_fd(master),
                slave: File::from_raw_fd(slave),
            }
        };
        for file in [&terminal.master, &terminal.slave] {
            // SAFETY: the File owns a live descriptor. Only descriptor flags
            // change; its ownership remains with File.
            let result = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) };
            assert_ne!(result, -1, "fcntl: {}", io::Error::last_os_error());
        }
        // SAFETY: these calls read/set flags on our live master descriptor.
        let flags = unsafe { libc::fcntl(terminal.master.as_raw_fd(), libc::F_GETFL) };
        assert_ne!(flags, -1);
        let result = unsafe {
            libc::fcntl(
                terminal.master.as_raw_fd(),
                libc::F_SETFL,
                flags | libc::O_NONBLOCK,
            )
        };
        assert_ne!(result, -1, "fcntl: {}", io::Error::last_os_error());
        terminal
    }

    fn stream(&self) -> Stdio {
        Stdio::from(self.slave.try_clone().unwrap())
    }

    fn drain(&mut self, output: &mut Vec<u8>) {
        let mut buffer = [0; 4096];
        loop {
            match self.master.read(&mut buffer) {
                Ok(0) => break,
                Ok(length) => output.extend_from_slice(&buffer[..length]),
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error)
                    if error.kind() == io::ErrorKind::WouldBlock
                        || error.raw_os_error() == Some(libc::EIO) =>
                {
                    break;
                }
                Err(error) => panic!("read terminal: {error}"),
            }
        }
    }
}

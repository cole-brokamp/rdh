use crate::cli::RuntimeRequest;
use std::env;
use std::fmt;
use std::io::{IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::thread;
use std::time::Duration;

pub const APPTAINER_MODULE: &str = "apptainer/1.4.2";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimeKind {
    Apptainer,
    Container,
    Docker,
    Podman,
}

impl RuntimeKind {
    pub const ALL: [Self; 4] = [Self::Apptainer, Self::Container, Self::Docker, Self::Podman];

    pub fn executable(self) -> &'static str {
        match self {
            Self::Apptainer => "apptainer",
            Self::Container => "container",
            Self::Docker => "docker",
            Self::Podman => "podman",
        }
    }

    pub fn available(self) -> bool {
        command_available(self.executable())
            || (self == Self::Apptainer && module_apptainer_available())
    }
}

impl fmt::Display for RuntimeKind {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.executable())
    }
}

pub fn select(request: RuntimeRequest) -> Result<RuntimeKind, String> {
    let explicit = match request {
        RuntimeRequest::Auto => None,
        RuntimeRequest::Apptainer => Some(RuntimeKind::Apptainer),
        RuntimeRequest::Container => Some(RuntimeKind::Container),
        RuntimeRequest::Docker => Some(RuntimeKind::Docker),
        RuntimeRequest::Podman => Some(RuntimeKind::Podman),
    };

    if let Some(runtime) = explicit {
        return runtime
            .available()
            .then_some(runtime)
            .ok_or_else(|| format!("requested runtime {runtime} is unavailable; run rdh doctor"));
    }

    let hpc = ["LSB_JOBID", "SLURM_JOB_ID", "PBS_JOBID"]
        .iter()
        .any(|name| env::var_os(name).is_some());
    select_with(cfg!(target_os = "macos"), hpc, |runtime| runtime.available()).ok_or_else(|| {
        "no supported container runtime found; install Apple container, Docker, Podman, or Apptainer"
            .to_owned()
    })
}

fn select_with(
    macos: bool,
    hpc: bool,
    available: impl Fn(RuntimeKind) -> bool,
) -> Option<RuntimeKind> {
    let order = if macos {
        [
            RuntimeKind::Container,
            RuntimeKind::Docker,
            RuntimeKind::Podman,
            RuntimeKind::Apptainer,
        ]
    } else if hpc {
        [
            RuntimeKind::Apptainer,
            RuntimeKind::Docker,
            RuntimeKind::Podman,
            RuntimeKind::Container,
        ]
    } else {
        [
            RuntimeKind::Docker,
            RuntimeKind::Podman,
            RuntimeKind::Apptainer,
            RuntimeKind::Container,
        ]
    };
    order.into_iter().find(|runtime| available(*runtime))
}

pub fn command_available(name: &str) -> bool {
    let candidate = Path::new(name);
    if candidate.components().count() > 1 {
        return is_executable(candidate);
    }
    env::var_os("PATH")
        .map(|path| env::split_paths(&path).any(|directory| is_executable(&directory.join(name))))
        .unwrap_or(false)
}

fn is_executable(path: &Path) -> bool {
    let Ok(metadata) = path.metadata() else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

fn module_apptainer_available() -> bool {
    command_available("bash")
        && Command::new("bash")
            .args([
                "-lc",
                "type module >/dev/null 2>&1 && module load apptainer/1.4.2 >/dev/null 2>&1 && command -v apptainer >/dev/null 2>&1",
            ])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success())
}

pub fn run(
    runtime: RuntimeKind,
    arguments: &[std::ffi::OsString],
    environment: &[(String, std::ffi::OsString)],
) -> Result<ExitStatus, String> {
    configured_command(runtime, arguments, environment)
        .status()
        .map_err(|error| format!("could not run {runtime}: {error}"))
}

pub fn run_with_spinner(
    runtime: RuntimeKind,
    arguments: &[std::ffi::OsString],
    environment: &[(String, std::ffi::OsString)],
    message: &str,
) -> Result<ExitStatus, String> {
    let mut child = configured_command(runtime, arguments, environment)
        .spawn()
        .map_err(|error| format!("could not run {runtime}: {error}"))?;

    if !std::io::stderr().is_terminal() {
        return wait_for_child(&mut child, runtime);
    }

    let frames = ['|', '/', '-', '\\'];
    let mut frame = 0;
    let mut stderr = std::io::stderr().lock();
    loop {
        if let Some(status) = child
            .try_wait()
            .map_err(|error| format!("could not wait for {runtime}: {error}"))?
        {
            let result = if status.success() { "done" } else { "failed" };
            let _ = writeln!(stderr, "\r{message} {result}");
            return Ok(status);
        }

        let _ = write!(stderr, "\r{message} {}", frames[frame]);
        let _ = stderr.flush();
        frame = (frame + 1) % frames.len();
        thread::sleep(Duration::from_millis(120));
    }
}

fn wait_for_child(child: &mut Child, runtime: RuntimeKind) -> Result<ExitStatus, String> {
    child
        .wait()
        .map_err(|error| format!("could not wait for {runtime}: {error}"))
}

fn configured_command(
    runtime: RuntimeKind,
    arguments: &[std::ffi::OsString],
    environment: &[(String, std::ffi::OsString)],
) -> Command {
    let mut command = if runtime == RuntimeKind::Apptainer
        && !command_available(RuntimeKind::Apptainer.executable())
    {
        let mut command = Command::new("bash");
        command.args([
            "-lc",
            "module load apptainer/1.4.2 >/dev/null && exec apptainer \"$@\"",
            "rdh",
        ]);
        command
    } else {
        Command::new(runtime.executable())
    };

    command.args(arguments);
    if runtime == RuntimeKind::Apptainer {
        for (name, _) in env::vars_os() {
            let name_text = name.to_string_lossy();
            if name_text.starts_with("APPTAINERENV_") || name_text.starts_with("SINGULARITYENV_") {
                command.env_remove(name);
            }
        }
    }
    for (name, value) in environment {
        command.env(name, value);
    }
    command
}

pub fn host_ids() -> Option<(String, String)> {
    #[cfg(unix)]
    {
        unsafe extern "C" {
            fn getuid() -> u32;
            fn getgid() -> u32;
        }

        // POSIX getuid and getgid have no failure return and are safe to call.
        let uid = unsafe { getuid() };
        let gid = unsafe { getgid() };
        Some((uid.to_string(), gid.to_string()))
    }
    #[cfg(not(unix))]
    {
        None
    }
}

pub fn executable_path(name: &str) -> Option<PathBuf> {
    let path = env::var_os("PATH")?;
    env::split_paths(&path)
        .map(|directory| directory.join(name))
        .find(|candidate| is_executable(candidate))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn macos_prefers_apple_container() {
        let selected = select_with(true, false, |runtime| {
            matches!(runtime, RuntimeKind::Container | RuntimeKind::Docker)
        });
        assert_eq!(selected, Some(RuntimeKind::Container));
    }

    #[test]
    fn hpc_prefers_apptainer() {
        let selected = select_with(false, true, |_| true);
        assert_eq!(selected, Some(RuntimeKind::Apptainer));
    }

    #[test]
    fn linux_workstation_prefers_docker_then_podman() {
        let selected = select_with(false, false, |runtime| runtime == RuntimeKind::Podman);
        assert_eq!(selected, Some(RuntimeKind::Podman));
    }
}

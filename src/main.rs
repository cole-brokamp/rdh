mod cli;
mod runtime;

use cli::{Action, Cli, RuntimeRequest};
use runtime::RuntimeKind;
use std::env;
use std::ffi::OsString;
use std::fs;
use std::io::IsTerminal;
use std::path::{Path, PathBuf};
use std::process::ExitStatus;
use std::thread;
use std::time::{Duration, Instant};

const VERSION: &str = env!("DATAHUB_R_VERSION");
const RELEASE_IMAGE: &str = env!("DATAHUB_R_RELEASE_IMAGE");
const CONTAINER_HOME: &str = "/home/datahub-r";
const CONTAINER_DATA_DIR: &str = "/home/datahub-r/.local/share/datahub-r";

const HELP: &str = r#"Usage:
  datahub-r [--runtime NAME] [--db PROFILE] [--env NAME ...] [COMMAND]

Commands:
  R [arguments]          Start R or pass R arguments (the default).
  Rscript SCRIPT [...]  Run an R script.
  check                  Validate the image and selected database connection.
  shell [arguments]     Start Bash inside the environment.
  pull                   Pull the configured image without running it.
  version                Print the CLI version and configured image.
  doctor                 Report runtime, image, cache, and host readiness.
  help                   Show this help.

Runtime selection:
  --runtime auto|apptainer|container|docker|podman
  DATAHUB_R_RUNTIME      Default runtime when --runtime is omitted.

Configuration:
  DATAHUB_R_IMAGE        Override the digest-pinned release image or use a local SIF.
  DATAHUB_R_PLATFORM     Override the OCI platform, for example linux/amd64.
  DATAHUB_R_CACHE_DIR    Override the Apptainer image and conversion cache.
  DATAHUB_R_DATA_DIR     Override the persistent host package-library directory.
  DATAHUB_R_DB_PROFILE   Database profile selected by --db (default: MBHI).

The selected <PROFILE>_DB_HOST, <PROFILE>_DB_NAME, <PROFILE>_DB_USERNAME,
and <PROFILE>_DB_PASSWORD variables are forwarded by name. Additional exported
variables can be forwarded with --env NAME. NAME=value is rejected so secrets
are not placed in command arguments or shell history.
"#;

fn main() {
    match run() {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            eprintln!("datahub-r: {error}");
            std::process::exit(1);
        }
    }
}

fn run() -> Result<i32, String> {
    let cli = cli::parse(env::args_os().skip(1))?;

    match &cli.action {
        Action::Help => {
            print!("{HELP}");
            return Ok(0);
        }
        Action::Version => {
            print_version();
            return Ok(0);
        }
        Action::Doctor => return Ok(i32::from(!doctor(cli.runtime_request()?)?)),
        Action::Pull => {}
        Action::Execute(_) => {}
    }

    let selected_runtime = runtime::select(cli.runtime_request()?)?;
    let image = required_image()?;

    match &cli.action {
        Action::Pull => {
            let resolved = pull_image(selected_runtime, &image)?;
            println!("{}", resolved.to_string_lossy());
            Ok(0)
        }
        Action::Execute(payload) => {
            let forwarded = forwarded_environment(&cli)?;
            let status = if selected_runtime == RuntimeKind::Apptainer {
                let image_path = prepare_apptainer_image(&image)?;
                run_apptainer(&image_path, payload, &forwarded)?
            } else {
                run_oci(selected_runtime, &image, payload, &forwarded)?
            };
            Ok(exit_code(status))
        }
        _ => unreachable!(),
    }
}

fn print_version() {
    println!("datahub-r {VERSION}");
    if RELEASE_IMAGE.contains("REPLACE_AT_RELEASE") {
        println!("release image: unpublished");
    } else {
        println!("release image: {RELEASE_IMAGE}");
    }
    if let Some(image) = env::var_os("DATAHUB_R_IMAGE") {
        println!("image override: {}", image.to_string_lossy());
    }
}

fn doctor(request: RuntimeRequest) -> Result<bool, String> {
    print_version();
    println!("host: {}/{}", env::consts::OS, env::consts::ARCH);
    println!(
        "platform override: {}",
        env::var("DATAHUB_R_PLATFORM").unwrap_or_else(|_| "automatic".to_owned())
    );
    println!("persistent data: {}", data_root()?.display());
    println!("Apptainer cache: {}", cache_root()?.display());

    for kind in RuntimeKind::ALL {
        let state = if kind.available() {
            let location = runtime::executable_path(kind.executable())
                .map(|path| path.display().to_string())
                .unwrap_or_else(|| format!("{} module", runtime::APPTAINER_MODULE));
            format!("available ({location})")
        } else {
            "unavailable".to_owned()
        };
        println!("runtime {kind}: {state}");
    }

    let selected = runtime::select(request);
    match &selected {
        Ok(runtime) => println!("selected runtime: {runtime}"),
        Err(error) => println!("selected runtime: unavailable ({error})"),
    }

    let image_ready = required_image();
    match &image_ready {
        Ok(image) => println!("configured image: {image}"),
        Err(error) => println!("configured image: unavailable ({error})"),
    }

    Ok(selected.is_ok() && image_ready.is_ok())
}

fn required_image() -> Result<String, String> {
    let image = env::var("DATAHUB_R_IMAGE").unwrap_or_else(|_| RELEASE_IMAGE.to_owned());
    if image.contains("REPLACE_AT_RELEASE") {
        return Err(
            "no release image is published; set DATAHUB_R_IMAGE to a local image or SIF".to_owned(),
        );
    }
    if image.trim().is_empty() {
        return Err("DATAHUB_R_IMAGE is empty".to_owned());
    }
    Ok(image)
}

fn forwarded_environment(cli: &Cli) -> Result<Vec<(String, OsString)>, String> {
    let database_profile = cli.database_profile()?;
    let mut names = vec!["DATAHUB_R_DB_PROFILE".to_owned()];
    for suffix in ["HOST", "NAME", "USERNAME", "PASSWORD"] {
        let name = format!("{database_profile}_DB_{suffix}");
        if env::var_os(&name).is_some() {
            names.push(name);
        }
    }
    for name in &cli.forward_names {
        if !names.contains(name) {
            names.push(name.clone());
        }
    }

    let mut forwarded = Vec::with_capacity(names.len());
    for name in names {
        let value = if name == "DATAHUB_R_DB_PROFILE" {
            OsString::from(&database_profile)
        } else {
            env::var_os(&name)
                .ok_or_else(|| format!("environment variable is not exported or set: {name}"))?
        };
        forwarded.push((name, value));
    }
    Ok(forwarded)
}

fn pull_image(runtime: RuntimeKind, image: &str) -> Result<PathBuf, String> {
    if runtime == RuntimeKind::Apptainer {
        prepare_apptainer_image(image)
    } else {
        let reference = oci_reference(image)?;
        let arguments = match runtime {
            RuntimeKind::Container => os_strings(&["image", "pull", &reference]),
            RuntimeKind::Docker | RuntimeKind::Podman => os_strings(&["pull", &reference]),
            RuntimeKind::Apptainer => unreachable!(),
        };
        let status = runtime::run(runtime, &arguments, &[])?;
        ensure_success(status, runtime, "pull")?;
        Ok(PathBuf::from(reference))
    }
}

fn oci_reference(image: &str) -> Result<String, String> {
    if Path::new(image).is_file() {
        return Err("a local SIF can be used only with the Apptainer runtime".to_owned());
    }
    if let Some(reference) = image.strip_prefix("docker://") {
        return Ok(reference.to_owned());
    }
    if image.contains("://") {
        return Err(format!(
            "the selected OCI runtime cannot use this image URI: {image}"
        ));
    }
    Ok(image.to_owned())
}

fn apptainer_reference(image: &str) -> Result<String, String> {
    if Path::new(image).is_file() {
        return fs::canonicalize(image)
            .map(|path| path.to_string_lossy().into_owned())
            .map_err(|error| format!("could not resolve local SIF {image}: {error}"));
    }
    if image.contains("://") {
        Ok(image.to_owned())
    } else {
        Ok(format!("docker://{image}"))
    }
}

fn prepare_apptainer_image(image: &str) -> Result<PathBuf, String> {
    if Path::new(image).is_file() {
        return fs::canonicalize(image)
            .map_err(|error| format!("could not resolve local SIF {image}: {error}"));
    }

    let reference = apptainer_reference(image)?;
    let root = cache_root()?;
    let image_dir = root.join("images");
    let partial_dir = root.join("partials");
    let lock_dir = root.join("locks");
    let apptainer_cache = root.join("apptainer-cache");
    let temporary_dir = root.join("tmp");
    for directory in [
        &root,
        &image_dir,
        &partial_dir,
        &lock_dir,
        &apptainer_cache,
        &temporary_dir,
    ] {
        create_private_directory(directory)?;
    }

    let key = cache_key(&reference);
    let architecture = env::consts::ARCH;
    let image_path = image_dir.join(format!("datahub-r-{VERSION}-{architecture}-{key}.sif"));
    if image_path.is_file() {
        return Ok(image_path);
    }

    let lock_path = lock_dir.join(format!("{architecture}-{key}.lock"));
    let timeout = env::var("DATAHUB_R_LOCK_TIMEOUT_SECONDS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(300);
    let start = Instant::now();
    let guard = loop {
        match fs::create_dir(&lock_path) {
            Ok(()) => break PullLock(lock_path.clone()),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                if image_path.is_file() {
                    return Ok(image_path);
                }
                if start.elapsed() >= Duration::from_secs(timeout) {
                    return Err(format!(
                        "timed out waiting for image pull lock: {}",
                        lock_path.display()
                    ));
                }
                thread::sleep(Duration::from_secs(1));
            }
            Err(error) => {
                return Err(format!(
                    "could not acquire image pull lock {}: {error}",
                    lock_path.display()
                ));
            }
        }
    };

    if image_path.is_file() {
        drop(guard);
        return Ok(image_path);
    }

    let partial = partial_dir.join(format!(
        "datahub-r-{VERSION}-{architecture}-{key}.partial.{}.sif",
        std::process::id()
    ));
    let arguments = vec![
        OsString::from("--silent"),
        OsString::from("pull"),
        partial.as_os_str().to_owned(),
        OsString::from(&reference),
    ];
    let environment = vec![
        (
            "APPTAINER_CACHEDIR".to_owned(),
            apptainer_cache.as_os_str().to_owned(),
        ),
        (
            "APPTAINER_TMPDIR".to_owned(),
            temporary_dir.as_os_str().to_owned(),
        ),
    ];
    let status = runtime::run_with_spinner(
        RuntimeKind::Apptainer,
        &arguments,
        &environment,
        "datahub-r: downloading and converting image",
    )?;
    if let Err(error) = ensure_success(status, RuntimeKind::Apptainer, "pull") {
        let _ = fs::remove_file(&partial);
        return Err(error);
    }
    if !partial.is_file() {
        return Err(format!(
            "Apptainer reported success but did not create {}",
            partial.display()
        ));
    }
    fs::rename(&partial, &image_path).map_err(|error| {
        format!(
            "could not atomically install {} as {}: {error}",
            partial.display(),
            image_path.display()
        )
    })?;
    drop(guard);
    Ok(image_path)
}

fn run_apptainer(
    image: &Path,
    payload: &[OsString],
    forwarded: &[(String, OsString)],
) -> Result<ExitStatus, String> {
    let working_directory = canonical_working_directory()?;
    let mut arguments = vec![
        OsString::from("exec"),
        OsString::from("--cleanenv"),
        OsString::from("--bind"),
        OsString::from(format!(
            "{}:{}",
            working_directory.display(),
            working_directory.display()
        )),
        OsString::from("--cwd"),
        working_directory.as_os_str().to_owned(),
        image.as_os_str().to_owned(),
    ];
    arguments.extend_from_slice(payload);

    let mut environment = Vec::new();
    for (name, value) in forwarded {
        environment.push((format!("APPTAINERENV_{name}"), value.clone()));
    }
    runtime::run(RuntimeKind::Apptainer, &arguments, &environment)
}

fn run_oci(
    runtime_kind: RuntimeKind,
    image: &str,
    payload: &[OsString],
    forwarded: &[(String, OsString)],
) -> Result<ExitStatus, String> {
    let reference = oci_reference(image)?;
    let working_directory = canonical_working_directory()?;
    let data_directory = data_root()?;
    create_private_directory(&data_directory)?;

    let mut arguments = vec![OsString::from("run"), OsString::from("--rm")];
    if std::io::stdin().is_terminal() {
        arguments.push(OsString::from("--interactive"));
    }
    if std::io::stdout().is_terminal() && std::io::stderr().is_terminal() {
        arguments.push(OsString::from("--tty"));
    }

    if let Ok(platform) = env::var("DATAHUB_R_PLATFORM")
        && !platform.is_empty()
    {
        arguments.extend(os_strings(&["--platform", &platform]));
        if runtime_kind == RuntimeKind::Container
            && env::consts::ARCH == "aarch64"
            && platform.ends_with("/amd64")
        {
            arguments.push(OsString::from("--rosetta"));
        }
    }

    match runtime_kind {
        RuntimeKind::Podman => arguments.push(OsString::from("--userns=keep-id")),
        RuntimeKind::Container | RuntimeKind::Docker => {
            if let Some((uid, gid)) = runtime::host_ids() {
                if runtime_kind == RuntimeKind::Container {
                    arguments.extend(os_strings(&["--uid", &uid, "--gid", &gid]));
                } else {
                    arguments.extend(os_strings(&["--user", &format!("{uid}:{gid}")]));
                }
            }
        }
        RuntimeKind::Apptainer => unreachable!(),
    }

    arguments.extend(os_strings(&["--env", &format!("HOME={CONTAINER_HOME}")]));
    for (name, _) in forwarded {
        arguments.extend(os_strings(&["--env", name]));
    }
    arguments.extend(os_strings(&[
        "--volume",
        &format!(
            "{}:{}",
            working_directory.display(),
            working_directory.display()
        ),
        "--volume",
        &format!("{}:{CONTAINER_DATA_DIR}", data_directory.display()),
        "--workdir",
        &working_directory.to_string_lossy(),
        &reference,
    ]));
    arguments.extend_from_slice(payload);

    runtime::run(runtime_kind, &arguments, forwarded)
}

fn canonical_working_directory() -> Result<PathBuf, String> {
    env::current_dir()
        .and_then(fs::canonicalize)
        .map_err(|error| format!("could not resolve the working directory: {error}"))
}

fn data_root() -> Result<PathBuf, String> {
    if let Some(path) = env::var_os("DATAHUB_R_DATA_DIR") {
        return Ok(PathBuf::from(path));
    }
    if let Some(path) = env::var_os("XDG_DATA_HOME") {
        return Ok(PathBuf::from(path).join("datahub-r"));
    }
    home_directory().map(|home| home.join(".local/share/datahub-r"))
}

fn cache_root() -> Result<PathBuf, String> {
    if let Some(path) = env::var_os("DATAHUB_R_CACHE_DIR") {
        return Ok(PathBuf::from(path));
    }

    if let Some(user) = env::var_os("USER") {
        let scratch = Path::new("/scratch").join(user);
        if scratch.is_dir()
            && !fs::metadata(&scratch).is_ok_and(|metadata| metadata.permissions().readonly())
        {
            return Ok(scratch.join("datahub-r"));
        }
    }

    if let Some(path) = env::var_os("XDG_CACHE_HOME") {
        return Ok(PathBuf::from(path).join("datahub-r"));
    }
    home_directory().map(|home| home.join(".cache/datahub-r"))
}

fn home_directory() -> Result<PathBuf, String> {
    env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| "HOME is not set".to_owned())
}

fn create_private_directory(path: &Path) -> Result<(), String> {
    fs::create_dir_all(path)
        .map_err(|error| format!("could not create {}: {error}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))
            .map_err(|error| format!("could not protect {}: {error}", path.display()))?;
    }
    Ok(())
}

fn cache_key(reference: &str) -> String {
    if let Some(digest) = reference.split("@sha256:").nth(1)
        && digest
            .chars()
            .all(|character| character.is_ascii_hexdigit())
    {
        return digest.chars().take(24).collect();
    }

    let mut hash = 0xcbf29ce484222325_u64;
    for byte in reference.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{hash:016x}")
}

fn os_strings(values: &[&str]) -> Vec<OsString> {
    values.iter().map(OsString::from).collect()
}

fn ensure_success(status: ExitStatus, runtime: RuntimeKind, operation: &str) -> Result<(), String> {
    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "{runtime} {operation} failed with status {}",
            status
                .code()
                .map(|code| code.to_string())
                .unwrap_or_else(|| "signal".to_owned())
        ))
    }
}

fn exit_code(status: ExitStatus) -> i32 {
    status.code().unwrap_or(1)
}

struct PullLock(PathBuf);

impl Drop for PullLock {
    fn drop(&mut self) {
        let _ = fs::remove_dir(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_docker_transport_for_oci_runtimes() {
        assert_eq!(
            oci_reference("docker://ghcr.io/cole-brokamp/datahub-r@sha256:abc").unwrap(),
            "ghcr.io/cole-brokamp/datahub-r@sha256:abc"
        );
    }

    #[test]
    fn leaves_plain_oci_references_unchanged() {
        assert_eq!(oci_reference("datahub-r:local").unwrap(), "datahub-r:local");
    }

    #[test]
    fn digest_cache_keys_are_readable_and_stable() {
        assert_eq!(
            cache_key("docker://example/image@sha256:0123456789abcdef0123456789abcdef"),
            "0123456789abcdef01234567"
        );
        assert_eq!(cache_key("datahub-r:local"), cache_key("datahub-r:local"));
    }

    #[test]
    fn release_version_is_zero_padded_calver() {
        let core = VERSION.strip_suffix("-dev").unwrap_or(VERSION);
        let fields: Vec<_> = core.split('.').collect();
        assert_eq!(fields.len(), 3);
        assert_eq!(fields[0].len(), 4);
        assert_eq!(fields[1].len(), 2);
        assert!((1_u8..=12).contains(&fields[1].parse::<u8>().unwrap()));
    }

    #[test]
    fn os_string_conversion_preserves_order() {
        assert_eq!(
            os_strings(&["a", "b"]),
            vec![OsString::from("a"), OsString::from("b")]
        );
    }
}

use std::collections::VecDeque;
use std::ffi::OsString;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimeRequest {
    Auto,
    Apptainer,
    Container,
    Docker,
    Podman,
}

impl RuntimeRequest {
    pub fn parse(value: &str) -> Result<Self, String> {
        match value.to_ascii_lowercase().as_str() {
            "auto" => Ok(Self::Auto),
            "apptainer" => Ok(Self::Apptainer),
            "container" => Ok(Self::Container),
            "docker" => Ok(Self::Docker),
            "podman" => Ok(Self::Podman),
            _ => Err(format!(
                "unknown runtime {value:?}; expected auto, apptainer, container, docker, or podman"
            )),
        }
    }
}

#[derive(Debug, Eq, PartialEq)]
pub enum Action {
    Doctor,
    Execute(Vec<OsString>),
    Help,
    Pull,
    Version,
}

#[derive(Debug, Eq, PartialEq)]
pub struct Cli {
    pub action: Action,
    pub database_profile: Option<String>,
    pub forward_names: Vec<String>,
    pub runtime: Option<RuntimeRequest>,
}

impl Cli {
    pub fn runtime_request(&self) -> Result<RuntimeRequest, String> {
        match self.runtime {
            Some(runtime) => Ok(runtime),
            None => std::env::var("DATAHUB_R_RUNTIME").map_or(Ok(RuntimeRequest::Auto), |value| {
                RuntimeRequest::parse(&value)
            }),
        }
    }

    pub fn database_profile(&self) -> Result<String, String> {
        let profile = self.database_profile.clone().unwrap_or_else(|| {
            std::env::var("DATAHUB_R_DB_PROFILE").unwrap_or_else(|_| "MBHI".to_owned())
        });
        normalize_profile(&profile)
    }
}

pub fn parse(arguments: impl IntoIterator<Item = OsString>) -> Result<Cli, String> {
    let mut arguments: VecDeque<OsString> = arguments.into_iter().collect();
    let mut runtime = None;
    let mut database_profile = None;
    let mut forward_names = Vec::new();

    while let Some(argument) = arguments.front().and_then(|argument| argument.to_str()) {
        match argument {
            "--runtime" => {
                arguments.pop_front();
                if runtime.is_some() {
                    return Err("--runtime may be supplied only once".to_owned());
                }
                let value = next_utf8(&mut arguments, "--runtime")?;
                runtime = Some(RuntimeRequest::parse(&value)?);
            }
            "--db" => {
                arguments.pop_front();
                if database_profile.is_some() {
                    return Err("--db may be supplied only once".to_owned());
                }
                database_profile = Some(normalize_profile(&next_utf8(&mut arguments, "--db")?)?);
            }
            "--env" => {
                arguments.pop_front();
                let name = next_utf8(&mut arguments, "--env")?;
                validate_environment_name(&name)?;
                if !forward_names.contains(&name) {
                    forward_names.push(name);
                }
            }
            "--" => {
                arguments.pop_front();
                break;
            }
            value if value.starts_with("--runtime=") => {
                return Err("use --runtime NAME, not --runtime=NAME".to_owned());
            }
            value if value.starts_with("--db=") => {
                return Err("use --db PROFILE, not --db=PROFILE".to_owned());
            }
            value if value.starts_with("--env=") => {
                return Err("use --env NAME, not --env=NAME or --env NAME=value".to_owned());
            }
            _ => break,
        }
    }

    let command = arguments.pop_front();
    let remaining: Vec<OsString> = arguments.into_iter().collect();
    let action = match command.as_ref().and_then(|command| command.to_str()) {
        None => Action::Execute(vec![OsString::from("R")]),
        Some("help" | "-h" | "--help") => no_arguments(Action::Help, remaining, "help")?,
        Some("version" | "--version") => no_arguments(Action::Version, remaining, "version")?,
        Some("doctor") => no_arguments(Action::Doctor, remaining, "doctor")?,
        Some("pull") => no_arguments(Action::Pull, remaining, "pull")?,
        Some("check") => no_arguments(
            Action::Execute(vec![
                OsString::from("Rscript"),
                OsString::from("/opt/datahub-r/check.R"),
            ]),
            remaining,
            "check",
        )?,
        Some("shell") => {
            let mut payload = vec![OsString::from("/bin/bash")];
            payload.extend(remaining);
            Action::Execute(payload)
        }
        Some("R" | "Rscript") => {
            let mut payload = vec![command.unwrap()];
            payload.extend(remaining);
            Action::Execute(payload)
        }
        Some(value) if value.starts_with('-') => {
            let mut payload = vec![OsString::from("R"), command.unwrap()];
            payload.extend(remaining);
            Action::Execute(payload)
        }
        Some(value) => {
            return Err(format!(
                "unknown command {value:?}; run datahub-r help for usage"
            ));
        }
    };

    Ok(Cli {
        action,
        database_profile,
        forward_names,
        runtime,
    })
}

fn next_utf8(arguments: &mut VecDeque<OsString>, option: &str) -> Result<String, String> {
    let value = arguments
        .pop_front()
        .ok_or_else(|| format!("{option} requires an argument"))?;
    value
        .into_string()
        .map_err(|_| format!("{option} requires a UTF-8 argument"))
}

fn no_arguments(action: Action, arguments: Vec<OsString>, name: &str) -> Result<Action, String> {
    if arguments.is_empty() {
        Ok(action)
    } else {
        Err(format!("{name} does not accept arguments"))
    }
}

pub fn normalize_profile(profile: &str) -> Result<String, String> {
    let valid = profile.chars().enumerate().all(|(index, character)| {
        if index == 0 {
            character.is_ascii_alphabetic()
        } else {
            character.is_ascii_alphanumeric() || character == '_'
        }
    });
    if profile.is_empty() || !valid {
        return Err(format!("invalid database profile: {profile}"));
    }
    Ok(profile.to_ascii_uppercase())
}

pub fn validate_environment_name(name: &str) -> Result<(), String> {
    let valid = name.chars().enumerate().all(|(index, character)| {
        if index == 0 {
            character.is_ascii_alphabetic() || character == '_'
        } else {
            character.is_ascii_alphanumeric() || character == '_'
        }
    });
    if name.is_empty() || !valid || name.contains('=') {
        return Err(format!("invalid environment variable name: {name}"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(values: &[&str]) -> Vec<OsString> {
        values.iter().map(OsString::from).collect()
    }

    #[test]
    fn parses_runtime_profile_environment_and_script() {
        let cli = parse(strings(&[
            "--runtime",
            "podman",
            "--db",
            "omop",
            "--env",
            "CUSTOM_SETTING",
            "Rscript",
            "analysis.R",
        ]))
        .unwrap();
        assert_eq!(cli.runtime, Some(RuntimeRequest::Podman));
        assert_eq!(cli.database_profile.as_deref(), Some("OMOP"));
        assert_eq!(cli.forward_names, vec!["CUSTOM_SETTING"]);
        assert_eq!(
            cli.action,
            Action::Execute(strings(&["Rscript", "analysis.R"]))
        );
    }

    #[test]
    fn treats_r_flags_as_default_r_arguments() {
        let cli = parse(strings(&["--quiet"])).unwrap();
        assert_eq!(cli.action, Action::Execute(strings(&["R", "--quiet"])));
    }

    #[test]
    fn rejects_values_in_environment_option() {
        let error = parse(strings(&["--env", "TOKEN=secret", "R"])).unwrap_err();
        assert!(error.contains("invalid environment variable name"));
    }

    #[test]
    fn validates_database_profiles() {
        assert_eq!(normalize_profile("omop_2").unwrap(), "OMOP_2");
        assert!(normalize_profile("2omop").is_err());
        assert!(normalize_profile("OMOP-NOT").is_err());
    }
}

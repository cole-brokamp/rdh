use std::{env, fs, path::Path};

fn main() {
    println!("cargo:rerun-if-changed=VERSION");
    println!("cargo:rerun-if-changed=RELEASE_IMAGE");
    println!("cargo:rerun-if-env-changed=RDH_RELEASE_IMAGE");

    let root = env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is set by Cargo");
    let version = read_trimmed(Path::new(&root).join("VERSION"));
    assert_valid_version(&version);

    let release_image = env::var("RDH_RELEASE_IMAGE")
        .unwrap_or_else(|_| read_trimmed(Path::new(&root).join("RELEASE_IMAGE")));
    assert!(!release_image.is_empty(), "RELEASE_IMAGE must not be empty");

    println!("cargo:rustc-env=RDH_VERSION={version}");
    println!("cargo:rustc-env=RDH_RELEASE_IMAGE={release_image}");
}

fn read_trimmed(path: impl AsRef<Path>) -> String {
    let path = path.as_ref();
    fs::read_to_string(path)
        .unwrap_or_else(|error| panic!("could not read {}: {error}", path.display()))
        .trim()
        .to_owned()
}

fn assert_valid_version(version: &str) {
    let core = version.strip_suffix("-dev").unwrap_or(version);
    let fields: Vec<_> = core.split('.').collect();
    assert!(
        fields.len() == 3 && fields.iter().all(|field| field.parse::<u32>().is_ok()),
        "VERSION must be YYYY.MM.REVISION or YYYY.MM.REVISION-dev"
    );

    let year = fields[0].parse::<u32>().unwrap();
    let month = fields[1].parse::<u32>().unwrap();
    let revision = fields[2].parse::<u32>().unwrap();
    assert!(
        fields[0].len() == 4 && year >= 2000,
        "VERSION year must be four digits and at least 2000"
    );
    assert!(
        (1..=12).contains(&month),
        "VERSION month must be 1 through 12"
    );
    assert!(
        fields[1].len() == 2,
        "VERSION month must be zero-padded to two digits"
    );
    assert!(
        fields[2] == revision.to_string(),
        "VERSION revision must not have a leading zero"
    );
}

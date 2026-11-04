mod build;
mod common;
mod package;
mod r2;
#[allow(dead_code)]
#[path = "../update/package.rs"]
mod update_package;

use anyhow::{Context, Result, bail, ensure};
use std::{collections::BTreeMap, path::PathBuf};

pub struct Args {
    pub command: String,
    pub values: BTreeMap<String, String>,
}

impl Args {
    pub fn get(&self, name: &str) -> Result<&str> {
        self.values
            .get(name)
            .map(String::as_str)
            .with_context(|| format!("Missing --{name}."))
    }
    pub fn path(&self, name: &str) -> Result<PathBuf> {
        common::absolute(self.get(name)?)
    }
    pub fn identity(&self) -> Result<()> {
        ensure!(
            self.get("commit")?.len() == 40
                && self
                    .get("commit")?
                    .bytes()
                    .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)),
            "Commit must be 40 lowercase hexadecimal characters."
        );
        let branch = self.get("branch")?;
        ensure!(
            !branch.is_empty()
                && !branch.starts_with('/')
                && !branch.ends_with('/')
                && !branch.contains("..")
                && branch
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"._/-".contains(&b)),
            "Unsupported default branch."
        );
        ensure!(
            matches!(self.get("runtime")?, "win-x64" | "win-arm64"),
            "Unsupported runtime."
        );
        let repo = self.get("repository")?;
        let parts: Vec<_> = repo.split('/').collect();
        ensure!(
            parts.len() == 2
                && parts.iter().all(|p| !p.is_empty()
                    && p.bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))),
            "Repository must be owner/name."
        );
        common::Pins::new().directory(&self.path("source")?)?;
        Ok(())
    }
}

pub fn run() -> Result<()> {
    let mut argv = std::env::args().skip(1);
    let command = argv.next().unwrap_or_else(|| "--help".into());
    if matches!(command.as_str(), "--help" | "-h" | "help") {
        println!(
            "prunlet-release <build|package|verify|publish-r2> --source ABS --commit SHA --branch BRANCH --runtime <win-x64|win-arm64> --repository OWNER/REPO\n  build: --output ABS [--target-directory ABS] [--release-source true]\n  package|verify|publish-r2: --publish ABS --package ABS\nRelease builds and all package commands require unchanged tracked Git HEAD inputs.\nBuild provenance is required at the publish directory's parent/build-provenance.json.\nR2 uses PRUNLET_R2_ACCOUNT_ID, PRUNLET_R2_BUCKET, PRUNLET_R2_ACCESS_KEY_ID, PRUNLET_R2_SECRET_ACCESS_KEY."
        );
        return Ok(());
    }
    ensure!(
        matches!(
            command.as_str(),
            "build" | "package" | "verify" | "publish-r2"
        ),
        "Unknown release command."
    );
    let mut values = BTreeMap::new();
    while let Some(key) = argv.next() {
        let name = key
            .strip_prefix("--")
            .context("Expected a named argument.")?;
        let allowed = matches!(
            name,
            "source" | "commit" | "branch" | "runtime" | "repository"
        ) || if command == "build" {
            matches!(
                name,
                "output" | "target-directory" | "include-verification-probe" | "release-source"
            )
        } else {
            matches!(name, "publish" | "package")
        };
        ensure!(allowed, "Unsupported argument: {key}");
        let value = argv
            .next()
            .with_context(|| format!("Missing value: {key}"))?;
        ensure!(
            values.insert(name.to_owned(), value).is_none(),
            "Duplicate argument: {key}"
        );
    }
    let args = Args { command, values };
    args.identity()?;
    match args.command.as_str() {
        "build" => build::run(&args),
        "package" => package::create(&args),
        "verify" => {
            println!("{}", package::verify(&args)?.sha256);
            Ok(())
        }
        "publish-r2" => r2::run(&args),
        _ => bail!("Unsupported command."),
    }
}

//! 配布元は明示選択する。R2の内容認証もGitHub assetの独立したdigestを使う。
use anyhow::{Result, bail, ensure};

pub const OFFICIAL_REPOSITORY: &str = "1llum1n4t1s/Prunlet";
pub const R2_BASE: &str = "https://prunlet.kagayoi.com";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    Github,
    R2,
}

impl Source {
    pub fn parse(value: Option<&str>) -> Result<Self> {
        match value {
            None | Some("github") => Ok(Self::Github),
            Some("r2") => Ok(Self::R2),
            _ => bail!("Unknown published distribution source"),
        }
    }

    pub fn url(
        self,
        repository: &str,
        commit: &str,
        runtime: Option<&str>,
        hash: &str,
        asset: u64,
    ) -> Result<String> {
        ensure!(
            asset > 0 && super::package::is_hex(commit, 40) && super::package::is_hex(hash, 64),
            "Invalid authenticated distribution identity"
        );
        ensure!(
            regex::Regex::new(r"\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z")?.is_match(repository),
            "Invalid distribution repository"
        );
        match self {
            Self::Github => Ok(format!(
                "https://api.github.com/repos/{repository}/releases/assets/{asset}"
            )),
            Self::R2 => {
                ensure!(
                    repository.eq_ignore_ascii_case(OFFICIAL_REPOSITORY),
                    "R2 distribution is only available for the official repository"
                );
                let runtime = runtime
                    .filter(|v| matches!(*v, "win-x64" | "win-arm64"))
                    .ok_or_else(|| {
                        anyhow::anyhow!("R2 distribution requires a supported Windows runtime")
                    })?;
                Ok(format!(
                    "{R2_BASE}/releases/{}/{}/{runtime}/{}.zip",
                    repository.to_ascii_lowercase(),
                    commit.to_ascii_lowercase(),
                    hash.to_ascii_lowercase()
                ))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fixed_r2_address_requires_authenticated_identity() {
        let commit = "A".repeat(40);
        let hash = "B".repeat(64);
        assert_eq!(
            Source::R2
                .url(OFFICIAL_REPOSITORY, &commit, Some("win-x64"), &hash, 1)
                .unwrap(),
            format!(
                "{R2_BASE}/releases/1llum1n4t1s/prunlet/{}/win-x64/{}.zip",
                commit.to_lowercase(),
                hash.to_lowercase()
            )
        );
        for repository in [
            "fork/Prunlet",
            "1llum1n4t1s/Prunlet?x=1",
            "https://evil/Prunlet",
        ] {
            assert!(
                Source::R2
                    .url(repository, &commit, Some("win-x64"), &hash, 1)
                    .is_err()
            );
        }
        for runtime in [
            None,
            Some("osx-arm64"),
            Some("win-x64?x=1"),
            Some("../win-x64"),
        ] {
            assert!(
                Source::R2
                    .url(OFFICIAL_REPOSITORY, &commit, runtime, &hash, 1)
                    .is_err()
            );
        }
        assert!(
            Source::R2
                .url(OFFICIAL_REPOSITORY, "bad", Some("win-x64"), &hash, 1)
                .is_err()
        );
        assert!(
            Source::R2
                .url(OFFICIAL_REPOSITORY, &commit, Some("win-x64"), "bad", 1)
                .is_err()
        );
        assert!(Source::parse(Some("other")).is_err());
        assert_eq!(Source::parse(None).unwrap(), Source::Github);
    }
}

use anyhow::{Context, Result, ensure};
use std::path::Path;

pub fn ensure_ready(config: &Path) -> Result<()> {
    let executable = std::env::current_exe()
        .context("Cannot determine the executable path for update state inspection.")?;
    let mut roots = Vec::new();
    let name = executable
        .file_name()
        .and_then(|x| x.to_str())
        .unwrap_or("");
    if matches!(
        name.to_ascii_lowercase().as_str(),
        "prunlet.exe" | "prunlet-maintenance.exe"
    ) && executable
        .parent()
        .and_then(|x| x.file_name())
        .is_some_and(|x| x.eq_ignore_ascii_case("bin"))
    {
        roots.push(
            executable
                .parent()
                .and_then(Path::parent)
                .context("Missing executable installation root")?
                .to_path_buf(),
        );
    }
    if config
        .file_name()
        .is_some_and(|x| x.eq_ignore_ascii_case("config.json"))
    {
        let root = config
            .parent()
            .context("Missing configuration installation root")?;
        if !roots.iter().any(|x| {
            x.to_string_lossy()
                .eq_ignore_ascii_case(&root.to_string_lossy())
        }) {
            roots.push(root.to_path_buf());
        }
    }
    for root in roots {
        #[cfg(windows)]
        let state = super::coordinator::read_state(&root);
        #[cfg(not(windows))]
        let state: Result<Option<super::state::UpdateState>> =
            match std::fs::read(root.join(super::state::STATE_NAME)) {
                Ok(bytes) => super::state::UpdateState::parse(&bytes).map(Some),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
                Err(e) => Err(e.into()),
            };
        let state = state
            .context("Prunlet cannot start while its update state is incomplete or unreadable")?;
        ensure!(
            state.is_none_or(|s| s.phase == "idle"),
            "Prunlet cannot start while its update state is incomplete or unreadable."
        );
    }
    Ok(())
}

//! 切替中の補助製品を固定した来歴で更新する。未知の差分・不明な置換を再送しない。
use std::path::Path;

use anyhow::{Context, Result, ensure};
use windows_sys::Win32::{
    Foundation::GENERIC_READ,
    Storage::FileSystem::{FILE_READ_ATTRIBUTES, FILE_SHARE_READ},
};

use super::{
    budget,
    coordinator::{self as coordinator, InstallationMutexes, Provenance},
    state::AUXILIARY_NAMES,
};
use crate::{
    config::Config,
    platform::windows::{self as native, PinnedFile, path},
};

pub fn products_match(root: &Path, candidate: &Provenance) -> Result<bool> {
    let stage = coordinator::stage_path(root);
    let _integration = path::pin_directories(&stage.join("integration"))?;
    let _scripts = path::pin_directories(&stage.join("scripts"))?;
    let _bin = path::pin_directories(&root.join("bin"))?;
    let mut matches = true;
    for name in AUXILIARY_NAMES {
        let expected = candidate
            .auxiliary_hashes
            .get(&format!("bin\\{name}"))
            .context("Auxiliary provenance is incomplete.")?;
        coordinator::verify_hash(&stage.join(coordinator::auxiliary_path(name)), expected)?;
        match coordinator::hash_file(&root.join("bin").join(name)) {
            Ok(actual) => {
                if !actual.eq_ignore_ascii_case(expected) {
                    matches = false;
                }
            }
            Err(error)
                if error
                    .chain()
                    .filter_map(|e| e.downcast_ref::<std::io::Error>())
                    .any(|e| e.raw_os_error() == Some(2)) =>
            {
                matches = false;
            }
            Err(error) => return Err(error),
        }
    }
    Ok(matches)
}

pub fn apply(config: &Config) -> Result<()> {
    let root = coordinator::installation_root(&config.path)?;
    let stage = coordinator::stage_path(&root);
    coordinator::verify_candidate_process(&stage)?;
    let _stage_parents = path::pin_directories(&stage)?;
    let _mutex = InstallationMutexes::acquire(&root)?;
    let mut state = coordinator::read_state(&root)?.context("Update state is missing.")?;
    ensure!(
        state.phase == "switching" && state.stage_cleanup == "pending",
        "Auxiliary products can only be updated during switching."
    );
    ensure!(
        state.auxiliary_rotation_status.is_empty(),
        "An uncertain auxiliary replacement was preserved; it will not be retried."
    );
    coordinator::verify_stage_owner(&stage, &root, &state.candidate_commit)?;
    let candidate_info = stage.join("source-info.json");
    coordinator::verify_hash(&candidate_info, &state.candidate_source_info_sha256)?;
    let candidate = coordinator::read_provenance(&candidate_info)?;
    let old = coordinator::read_provenance(&stage.join("previous-source-info.json"))?;
    ensure!(
        candidate
            .commit
            .eq_ignore_ascii_case(&state.candidate_commit)
            && old.commit.eq_ignore_ascii_case(&state.old_commit),
        "Auxiliary provenance differs from the active update state."
    );
    ensure!(
        !state.rotation_cli_backup.is_empty()
            && !state.rotation_maintenance_backup.is_empty()
            && !state.rotation_hook_backup.is_empty(),
        "Product rotation has not completed for all products."
    );
    let bin = root.join("bin");
    let cli = coordinator::old_guard(&bin.join(&state.rotation_cli_backup), &old.cli_hash, false)?;
    let maintenance = coordinator::old_guard(
        &bin.join(&state.rotation_maintenance_backup),
        &old.maintenance_hash,
        false,
    )?;
    coordinator::verify_hash(&bin.join("prunlet.exe"), &candidate.cli_hash)?;
    coordinator::verify_hash(
        &bin.join("prunlet-maintenance.exe"),
        &candidate.maintenance_hash,
    )?;
    coordinator::verify_hash(&bin.join("prunlet-hook.exe"), &candidate.hook_hash)?;
    let hook =
        coordinator::old_guard(&bin.join(&state.rotation_hook_backup), &old.hook_hash, true)?;
    let _budget_guards = budget::with_guards(&[&cli, &maintenance, &hook])?;
    let previous_root = stage.join("previous-auxiliary");
    if !coordinator::exists(&previous_root)? {
        std::fs::create_dir(&previous_root)?;
    }
    let _previous_parents = path::pin_directories(&previous_root)?;
    let _bin_parents = path::pin_directories(&bin)?;
    for name in AUXILIARY_NAMES {
        let key = format!("bin\\{name}");
        let current = bin.join(name);
        let previous = previous_root.join(name);
        let source = stage.join(coordinator::auxiliary_path(name));
        let temporary = bin.join(format!(".prunlet-candidate-{name}"));
        let old_hash = old
            .auxiliary_hashes
            .get(&key)
            .context("Old auxiliary provenance is incomplete.")?;
        let new_hash = candidate
            .auxiliary_hashes
            .get(&key)
            .context("Candidate auxiliary provenance is incomplete.")?;
        coordinator::verify_hash(&source, new_hash)?;
        let previous_exists = coordinator::exists(&previous)?;
        if old_hash.eq_ignore_ascii_case(new_hash) {
            coordinator::verify_hash(&current, old_hash)?;
            continue;
        }
        if previous_exists {
            let current_hash = coordinator::hash_file(&current)?;
            let previous_hash = coordinator::hash_file(&previous)?;
            if current_hash.eq_ignore_ascii_case(new_hash)
                && previous_hash.eq_ignore_ascii_case(old_hash)
            {
                let _guard = coordinator::old_guard(&previous, old_hash, false)?;
                if !state
                    .auxiliary_backup_sha256
                    .get(&key)
                    .is_some_and(|s| s.eq_ignore_ascii_case(old_hash))
                {
                    state
                        .auxiliary_backup_sha256
                        .insert(key.clone(), old_hash.clone());
                    coordinator::write_state(&root, &state)?;
                }
                continue;
            }
            let prior_hash = state
                .prior_auxiliary_sha256
                .as_ref()
                .and_then(|m| m.get(&key))
                .context("An unexpected auxiliary backup was preserved.")?
                .clone();
            ensure!(
                current_hash.eq_ignore_ascii_case(old_hash)
                    && (previous_hash.eq_ignore_ascii_case(&prior_hash)
                        || previous_hash.eq_ignore_ascii_case(new_hash)),
                "An unexpected auxiliary backup was preserved: {}",
                previous.display()
            );
            {
                let source_handle = coordinator::plain(&source, GENERIC_READ, FILE_SHARE_READ)?;
                let mut input = coordinator::stream(&source_handle)?;
                let bytes = input.metadata()?.len();
                budget::ensure(&root, bytes)?;
                coordinator::stage_product(
                    &root,
                    &mut state,
                    &format!("previous-auxiliary/{name}"),
                    &previous,
                    &mut input,
                    bytes,
                    new_hash,
                    Some(&prior_hash),
                )?;
            }
            native::reject_named_streams(&previous)?;
            coordinator::rename_no_replace(&previous, &temporary)?;
        }
        let guard = coordinator::old_guard(&current, old_hash, false)?;
        match coordinator::verify_hash(&temporary, new_hash) {
            Ok(()) => {}
            Err(error)
                if error
                    .chain()
                    .filter_map(|e| e.downcast_ref::<std::io::Error>())
                    .any(|e| e.raw_os_error() == Some(2)) =>
            {
                let source_handle = coordinator::plain(&source, GENERIC_READ, FILE_SHARE_READ)?;
                let mut input = coordinator::stream(&source_handle)?;
                let bytes = input.metadata()?.len();
                budget::ensure(&root, bytes)?;
                {
                    let (output_handle, mut output) = coordinator::create_plain(&temporary)?;
                    coordinator::copy_verified(&mut input, &mut output, bytes, new_hash)?;
                    output_handle.verify_named()?;
                }
                coordinator::verify_hash(&temporary, new_hash)?;
            }
            Err(error) => return Err(error),
        }
        guard.verify_named()?;
        state.auxiliary_rotation_name = name.into();
        state.auxiliary_rotation_status = "replacing".into();
        state.auxiliary_rotation_old_sha256 = old_hash.clone();
        state.auxiliary_rotation_new_sha256 = new_hash.clone();
        coordinator::write_state(&root, &state)?;
        let replacement = (|| -> Result<()> {
            coordinator::replace(&temporary, &current, Some(&previous))?;
            let moved = PinnedFile::open(&previous, FILE_READ_ATTRIBUTES, 7)?;
            ensure!(
                guard.identity()?.same_object(&moved.identity()?) && guard.identity()?.links == 1,
                "The auxiliary backup does not identify the held original product."
            );
            ensure!(
                guard.final_path()? == previous,
                "The held auxiliary original has an unexpected final name."
            );
            coordinator::verify_hash(&current, new_hash)?;
            drop(moved);
            drop(guard);
            budget::ensure(&root, 0)?;
            state
                .auxiliary_backup_sha256
                .insert(key.clone(), old_hash.clone());
            state.auxiliary_rotation_name.clear();
            state.auxiliary_rotation_status.clear();
            state.auxiliary_rotation_old_sha256.clear();
            state.auxiliary_rotation_new_sha256.clear();
            coordinator::write_state(&root, &state)?;
            Ok(())
        })();
        if let Err(error) = replacement {
            state.auxiliary_rotation_name = name.into();
            state.auxiliary_rotation_status = "ambiguous".into();
            state.auxiliary_rotation_old_sha256 = old_hash.clone();
            state.auxiliary_rotation_new_sha256 = new_hash.clone();
            coordinator::write_state(&root, &state).with_context(|| format!("Auxiliary replacement and its ambiguous state could not be recorded; files were retained. Replacement error: {error}"))?;
            return Err(error
                .context("Auxiliary replacement could not be verified; all files were retained."));
        }
    }
    ensure!(
        products_match(&root, &candidate)?,
        "Auxiliary product verification did not complete."
    );
    Ok(())
}

pub fn confirm(config: &Config) -> Result<()> {
    let root = coordinator::installation_root(&config.path)?;
    let stage = coordinator::stage_path(&root);
    coordinator::verify_candidate_process(&stage)?;
    let _stage_parents = path::pin_directories(&stage)?;
    let _mutex = InstallationMutexes::acquire(&root)?;
    let mut state = coordinator::read_state(&root)?.context("Update state is missing.")?;
    ensure!(
        state.phase == "switching" && state.stage_cleanup == "pending",
        "Integration confirmation requires an active product switch."
    );
    ensure!(
        state.auxiliary_rotation_status.is_empty(),
        "An uncertain auxiliary replacement was preserved; it cannot be confirmed."
    );
    coordinator::verify_stage_owner(&stage, &root, &state.candidate_commit)?;
    let candidate_info = stage.join("source-info.json");
    coordinator::verify_hash(&candidate_info, &state.candidate_source_info_sha256)?;
    let candidate = coordinator::read_provenance(&candidate_info)?;
    ensure!(
        candidate
            .commit
            .eq_ignore_ascii_case(&state.candidate_commit)
            && products_match(&root, &candidate)?,
        "Auxiliary products do not match the candidate."
    );
    state.integration_ready = true;
    coordinator::write_state(&root, &state)
}

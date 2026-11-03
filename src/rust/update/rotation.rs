use super::{budget, coordinator::*, state::UpdateState};
use crate::platform::windows::{self as native, PinnedFile, path};
use anyhow::{Result, bail, ensure};
use std::path::Path;
use windows_sys::Win32::Foundation::{GENERIC_READ, GENERIC_WRITE};
use windows_sys::Win32::Storage::FileSystem::*;

pub fn rotate(
    root: &Path,
    leaf: &str,
    current_hash: &str,
    candidate_hash: &str,
    prior: Option<&str>,
    guard: &PinnedFile,
    state: &mut UpdateState,
) -> Result<()> {
    ensure!(
        PRODUCTS.contains(&leaf)
            && super::package::is_hex(current_hash, 64)
            && super::package::is_hex(candidate_hash, 64)
            && prior.is_none_or(|h| super::package::is_hex(h, 64)),
        "Invalid update rotation inputs"
    );
    let bin = root.join("bin");
    let stage = stage_path(root);
    let _bin = path::pin_directories(&bin)?;
    let _stage = path::pin_directories(&stage)?;
    let current = bin.join(leaf);
    let stem = leaf.strip_suffix(".exe").unwrap();
    let previous_leaf = format!("{stem}.previous.exe");
    let candidate_leaf = format!("{stem}.candidate.exe");
    let previous = bin.join(&previous_leaf);
    let staged = stage.join(leaf);
    if state.rotation_name != leaf {
        ensure!(
            state.rotation_status.is_empty(),
            "Another product rotation is still recorded"
        );
        state.rotation_name = leaf.into();
        state.rotation_prior_sha256 = prior.unwrap_or("").into();
        state.rotation_candidate_sha256 = candidate_hash.into();
        state.rotation_backup_name.clear();
    }
    ensure!(
        state.rotation_candidate_sha256 == candidate_hash
            && state.rotation_prior_sha256 == prior.unwrap_or(""),
        "Rotation state does not match confirmed product"
    );
    ensure!(
        !matches!(state.rotation_status.as_str(), "replacing" | "ambiguous"),
        "Interrupted or ambiguous product replacement requires inspection; all files were retained."
    );
    let mut backup = if state.rotation_backup_name.is_empty() {
        previous_leaf.clone()
    } else {
        state.rotation_backup_name.clone()
    };
    ensure!(
        super::state::rotation_backup(leaf, &backup),
        "Invalid rotation backup name"
    );
    let candidate_for = |backup: &str| {
        if backup == previous_leaf {
            candidate_leaf.clone()
        } else {
            backup.replacen(".previous-", ".candidate-", 1)
        }
    };
    let guarded = guard.final_path()?;
    if guarded == bin.join(&backup) {
        verify_guard(guard, current_hash)?;
        verify_hash(&current, candidate_hash)?;
        state.rotation_status = "switched".into();
        write_state(root, state)?;
        return Ok(());
    }
    ensure!(guarded == current, "Old guard has an unexpected name");
    verify_guard(guard, current_hash)?;
    native::reject_named_streams(&current)?;
    verify_hash(&staged, candidate_hash)?;
    native::reject_named_streams(&staged)?;
    let mut candidate = candidate_for(&backup);
    let mut fresh = state.rotation_status == "writing";
    if state.rotation_status.is_empty() {
        let fixed_absent = !exists(&bin.join(&candidate_leaf))?;
        budget::ensure(
            root,
            std::fs::metadata(&staged)?
                .len()
                .max(std::fs::metadata(&current)?.len()),
        )?;
        let mut reused = false;
        if fixed_absent {
            if let Some(old_hash) = prior {
                if let Ok(pin) = plain(
                    &previous,
                    GENERIC_READ | GENERIC_WRITE | DELETE,
                    FILE_SHARE_READ | FILE_SHARE_DELETE,
                ) {
                    let mut output = stream(&pin)?;
                    if native::reject_named_streams(&previous).is_ok()
                        && hash_stream(&mut output)?.eq_ignore_ascii_case(old_hash)
                    {
                        backup = previous_leaf.clone();
                        candidate = candidate_leaf.clone();
                        state.rotation_backup_name = backup.clone();
                        state.rotation_status = "writing".into();
                        let _guards = budget::with_guards(&[guard, &pin])?;
                        write_state(root, state)?;
                        let source = plain(&staged, GENERIC_READ, FILE_SHARE_READ)?;
                        copy_verified(
                            &mut stream(&source)?,
                            &mut output,
                            std::fs::metadata(&staged)?.len(),
                            candidate_hash,
                        )?;
                        pin.verify_named()?;
                        native::reject_named_streams(&previous)?;
                        state.rotation_status = "candidate_ready".into();
                        write_state(root, state)?;
                        rename_pinned(&pin, &bin, &candidate)?;
                        state.rotation_status = "candidate_named".into();
                        write_state(root, state)?;
                        reused = true;
                    }
                }
            }
        }
        if !reused {
            fresh = true;
            if !exists(&previous)? && fixed_absent {
                backup = previous_leaf.clone();
            } else {
                backup = format!("{stem}.previous-{}.exe", uuid::Uuid::new_v4().simple());
            }
        }
    } else if fresh {
        backup = format!("{stem}.previous-{}.exe", uuid::Uuid::new_v4().simple());
    }
    if fresh {
        budget::ensure(
            root,
            std::fs::metadata(&staged)?
                .len()
                .max(std::fs::metadata(&current)?.len()),
        )?;
        candidate = candidate_for(&backup);
        state.rotation_backup_name = backup.clone();
        state.rotation_status = "writing".into();
        write_state(root, state)?;
        let (pin, mut output) = create_plain(&bin.join(&candidate))?;
        let source = plain(&staged, GENERIC_READ, FILE_SHARE_READ)?;
        copy_verified(
            &mut stream(&source)?,
            &mut output,
            std::fs::metadata(&staged)?.len(),
            candidate_hash,
        )?;
        pin.verify_named()?;
        drop(output);
        drop(pin);
        state.rotation_status = "candidate_named".into();
        write_state(root, state)?;
    }
    if state.rotation_status == "candidate_ready" {
        if !exists(&bin.join(&candidate))? {
            let pin = plain(
                &previous,
                GENERIC_READ | DELETE,
                FILE_SHARE_READ | FILE_SHARE_DELETE,
            )?;
            verify_guard(&pin, candidate_hash)?;
            native::reject_named_streams(&previous)?;
            rename_pinned(&pin, &bin, &candidate)?;
        }
        verify_hash(&bin.join(&candidate), candidate_hash)?;
        state.rotation_status = "candidate_named".into();
        write_state(root, state)?;
    }
    ensure!(
        state.rotation_status == "candidate_named",
        "Update rotation requires inspection"
    );
    let candidate_path = bin.join(&candidate);
    let backup_path = bin.join(&backup);
    budget::ensure(
        root,
        std::fs::metadata(&current)?
            .len()
            .saturating_sub(std::fs::metadata(&candidate_path)?.len()),
    )?;
    let inspection = plain(&candidate_path, FILE_READ_ATTRIBUTES, 7)?;
    let candidate_pin = plain(
        &candidate_path,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_DELETE,
    )?;
    verify_guard(&candidate_pin, candidate_hash)?;
    native::reject_named_streams(&candidate_path)?;
    let identity = candidate_pin.identity()?;
    ensure!(
        inspection.identity()?.same_object(&identity),
        "Candidate inspection does not refer to verified file"
    );
    drop(candidate_pin);
    verify_guard(guard, current_hash)?;
    ensure!(
        guard.final_path()? == current,
        "Old product moved before replacement"
    );
    native::reject_named_streams(&current)?;
    ensure!(
        !exists(&backup_path)?,
        "Rotation backup name is occupied; existing file retained"
    );
    state.rotation_status = "replacing".into();
    write_state(root, state)?;
    let result = (|| -> Result<()> {
        replace(&candidate_path, &current, Some(&backup_path))?;
        ensure!(
            inspection.final_path()? == current && inspection.identity()?.same_object(&identity),
            "Installed candidate identity differs from verified file"
        );
        let installed = plain(&current, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE)?;
        ensure!(
            installed.identity()?.same_object(&identity),
            "Installed candidate is not the verified file"
        );
        verify_guard(&installed, candidate_hash)?;
        ensure!(
            guard.final_path()? == backup_path,
            "Old product guard did not move to backup"
        );
        verify_guard(guard, current_hash)?;
        Ok(())
    })();
    match result {
        Ok(()) => {
            state.rotation_status = "switched".into();
            write_state(root, state)
        }
        Err(error) => {
            state.rotation_status = "ambiguous".into();
            write_state(root,state).map_err(|record|anyhow::anyhow!("Product replacement failed ({error}); ambiguous state could not be recorded ({record}); all files retained"))?;
            bail!("Product replacement could not be verified; all files retained: {error}")
        }
    }
}
pub fn verify_guard(pin: &PinnedFile, hash: &str) -> Result<()> {
    let id = pin.identity()?;
    ensure!(
        !id.is_directory() && !id.is_reparse() && id.links == 1,
        "Product guard is no longer a plain single-link file"
    );
    ensure!(
        hash_stream(&mut stream(pin)?)?.eq_ignore_ascii_case(hash),
        "Guarded product hash differs from recorded identity"
    );
    Ok(())
}
fn rename_pinned(pin: &PinnedFile, parent: &Path, leaf: &str) -> Result<()> {
    let directory = PinnedFile::open(parent, FILE_READ_ATTRIBUTES | FILE_ADD_FILE, 7)?;
    native::security::rename_fixed(pin.raw(), directory.raw(), leaf)?;
    ensure!(
        pin.final_path()? == parent.join(leaf),
        "Renamed product has unexpected name"
    );
    Ok(())
}

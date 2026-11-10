//! 検証fixture専用のsparse証拠と、所有済み内容だけの縮小。
use anyhow::{Context, Result, bail, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{
    ffi::OsStr,
    os::windows::ffi::OsStrExt,
    path::{Path, PathBuf},
    ptr::{null, null_mut},
};
use windows_sys::Win32::{
    Foundation::*,
    Security::GetKernelObjectSecurity,
    Storage::FileSystem::*,
    System::IO::DeviceIoControl,
    UI::Shell::{SHQUERYRBINFO, SHQueryRecycleBinW},
};
#[link(name = "kernel32")]
unsafe extern "system" {
    fn CompareStringOrdinal(
        a: *const u16,
        alen: i32,
        b: *const u16,
        blen: i32,
        ignore_case: i32,
    ) -> i32;
}
fn same_name(a: &str, b: &str) -> bool {
    let a: Vec<u16> = a.encode_utf16().collect();
    let b: Vec<u16> = b.encode_utf16().collect();
    if a.len() > i32::MAX as usize || b.len() > i32::MAX as usize {
        return false;
    }
    unsafe { CompareStringOrdinal(a.as_ptr(), a.len() as i32, b.as_ptr(), b.len() as i32, 1) == 2 }
}
struct Handle(HANDLE);
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}
fn field<'a>(v: &'a Value, n: &str) -> Result<&'a str> {
    v.get(n)
        .and_then(Value::as_str)
        .with_context(|| format!("Missing {n}"))
}
fn num(v: &Value, n: &str) -> Result<i64> {
    v.get(n)
        .and_then(Value::as_i64)
        .with_context(|| format!("Missing or invalid {n}"))
}
fn wide(s: &OsStr) -> Result<Vec<u16>> {
    let mut b: Vec<_> = s.encode_wide().collect();
    ensure!(!b.contains(&0), "NUL in path");
    b.push(0);
    Ok(b)
}
fn absolute(s: &str) -> Result<PathBuf> {
    let p = PathBuf::from(s);
    ensure!(p.is_absolute(), "Absolute fixture path required");
    let s = s.strip_prefix(r"\\?\").unwrap_or(s);
    ensure!(
        !s.chars().any(|c| matches!(c, '\0' | '*' | '?'))
            && !s.split(['\\', '/']).any(|x| x == "." || x == ".."),
        "Invalid fixture path"
    );
    Ok(p)
}
fn owned(path: &Path, scope: &Path) -> Result<()> {
    // Windowsのordinal比較は文字数が増える大文字変換を行わない。
    let p: Vec<u16> = path
        .as_os_str()
        .encode_wide()
        .map(|c| if c == b'/' as u16 { b'\\' as u16 } else { c })
        .collect();
    let mut s: Vec<u16> = scope
        .as_os_str()
        .encode_wide()
        .map(|c| if c == b'/' as u16 { b'\\' as u16 } else { c })
        .collect();
    while s.last() == Some(&(b'\\' as u16)) {
        s.pop();
    }
    ensure!(
        !s.is_empty()
            && s.len() <= i32::MAX as usize
            && p.len() > s.len()
            && p[s.len()] == b'\\' as u16
            && unsafe {
                CompareStringOrdinal(p.as_ptr(), s.len() as i32, s.as_ptr(), s.len() as i32, 1)
            } == 2,
        "Sparse fixture escaped owned scope"
    );
    Ok(())
}
fn open(path: &Path, access: u32, share: u32, flags: u32) -> Result<Handle> {
    let p = wide(path.as_os_str())?;
    let h = unsafe {
        CreateFileW(
            p.as_ptr(),
            access,
            share,
            null(),
            OPEN_EXISTING,
            flags,
            null_mut(),
        )
    };
    if h == INVALID_HANDLE_VALUE {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(Handle(h))
}
fn info(h: HANDLE, class: FILE_INFO_BY_HANDLE_CLASS, size: usize) -> Result<Vec<u8>> {
    let mut b = vec![0u8; size];
    if unsafe { GetFileInformationByHandleEx(h, class, b.as_mut_ptr().cast(), size as u32) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(b)
}
fn i64at(b: &[u8], offset: usize) -> i64 {
    i64::from_le_bytes(b[offset..offset + 8].try_into().unwrap())
}
fn u32at(b: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(b[offset..offset + 4].try_into().unwrap())
}
fn pin_parents(path: &Path) -> Result<Vec<Handle>> {
    let parent = path.parent().context("Missing fixture parent")?;
    let mut paths: Vec<_> = parent.ancestors().collect();
    paths.reverse();
    let mut held = Vec::new();
    for p in paths {
        let h = open(
            p,
            0x80,
            3,
            FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS,
        )?;
        let basic = info(h.0, FileBasicInfo, 40)?;
        let attrs = u32at(&basic, 32);
        ensure!(
            attrs & 0x10 != 0 && attrs & 0x400 == 0,
            "Sparse fixture parent is not an ordinary pinned directory"
        );
        held.push(h);
    }
    Ok(held)
}
fn exclusive(path: &Path, writable: bool) -> Result<Handle> {
    open(
        path,
        if writable { 0xc0020000 } else { 0x80020000 },
        0,
        FILE_FLAG_OPEN_REPARSE_POINT,
    )
}
fn final_path(h: HANDLE) -> Result<String> {
    let mut b = vec![0u16; 32768];
    let n = unsafe { GetFinalPathNameByHandleW(h, b.as_mut_ptr(), b.len() as u32, 0) } as usize;
    ensure!(
        n > 0 && n < b.len(),
        "Cannot bind sparse handle to complete DOS path"
    );
    let s = String::from_utf16(&b[..n])?;
    Ok(s.strip_prefix(r"\\?\").unwrap_or(&s).to_owned())
}
fn security(h: HANDLE) -> Result<String> {
    let mut n = 0;
    unsafe { GetKernelObjectSecurity(h, 7, null_mut(), 0, &mut n) };
    ensure!(
        n > 0 && n <= 1048576,
        "Sparse security descriptor length unknown"
    );
    let mut b = vec![0u8; n as usize];
    let mut used = 0;
    if unsafe { GetKernelObjectSecurity(h, 7, b.as_mut_ptr().cast(), n, &mut used) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    ensure!(used == n, "Sparse security descriptor changed length");
    Ok(STANDARD.encode(b))
}
fn proof(h: HANDLE, path: &Path) -> Result<Value> {
    let basic = info(h, FileBasicInfo, 40)?;
    let standard = info(h, FileStandardInfo, 24)?;
    let compression = info(h, FileCompressionInfo, 16)?;
    let alloc = i64at(&standard, 0);
    let length = i64at(&standard, 8);
    let compressed = i64at(&compression, 0);
    ensure!(
        standard[20] == 0
            && standard[21] == 0
            && alloc >= 0
            && length >= 0
            && compressed >= 0
            && u16::from_le_bytes(compression[8..10].try_into()?) == 0,
        "Sparse fixture has unknown directory/delete/compression state"
    );
    let stream = info(h, FileStreamInfo, 65536)?;
    let mut names = Vec::new();
    let mut offset = 0usize;
    loop {
        ensure!(
            offset <= stream.len() - 24,
            "Sparse stream inventory incomplete"
        );
        let next = u32at(&stream, offset) as usize;
        let size = u32at(&stream, offset + 4) as usize;
        ensure!(
            size > 0 && size % 2 == 0 && size <= stream.len() - offset - 24,
            "Sparse stream inventory malformed"
        );
        let units: Vec<u16> = stream[offset + 24..offset + 24 + size]
            .chunks_exact(2)
            .map(|x| u16::from_le_bytes([x[0], x[1]]))
            .collect();
        let name = String::from_utf16(&units)?;
        ensure!(
            name == "::$DATA" && i64at(&stream, offset + 8) == length,
            "Sparse fixture has unknown stream or length"
        );
        names.push(name);
        if next == 0 {
            break;
        }
        ensure!(
            next >= 24 && next <= stream.len() - offset && names.len() < 64,
            "Sparse stream inventory did not advance"
        );
        offset += next;
    }
    ensure!(
        names.len() == 1,
        "Sparse fixture is not a single unnamed stream"
    );
    let final_name = final_path(h)?;
    let requested = path.to_string_lossy();
    let requested = requested.strip_prefix(r"\\?\").unwrap_or(&requested);
    ensure!(
        same_name(&final_name, requested),
        "Sparse handle no longer names recorded path"
    );
    Ok(
        json!({"Id":hex::encode_upper(info(h,FileIdInfo,24)?),"SecurityBase64":security(h)?,"Attributes":u32at(&basic,32),"Length":length,"AllocationSize":alloc,"CompressedSize":compressed,"NumberOfLinks":u32at(&standard,16),"FinalPath":final_name,"Streams":names}),
    )
}
fn match_proof(p: &Value, id: &str, sec: &str, attrs: u32, length: i64, max: u64) -> Result<()> {
    ensure!(
        p["Id"] == id
            && p["SecurityBase64"] == sec
            && p["Attributes"] == attrs
            && p["Length"] == length
            && p["NumberOfLinks"] == 1,
        "Sparse identity, security, attributes, length or link count differs"
    );
    const FORBIDDEN: u32 = 0x10 | 0x40 | 0x400 | 0x800 | 0x1000 | 0x4000 | 0x40000 | 0x400000;
    ensure!(
        attrs & 0x200 != 0
            && attrs & FORBIDDEN == 0
            && p["AllocationSize"].as_u64().is_some_and(|x| x <= max)
            && p["CompressedSize"].as_u64().is_some_and(|x| x <= max),
        "Sparse allocation or file state not understood; retained"
    );
    Ok(())
}
fn ranges(h: HANDLE, length: i64, max: u64) -> Result<Vec<Value>> {
    ensure!(length > 0, "Sparse range query length invalid");
    let mut result = Vec::new();
    let mut cursor = 0i64;
    let mut total = 0u64;
    let mut output = vec![0i64; 8192];
    while cursor < length {
        let input = [cursor, length - cursor];
        let mut returned = 0u32;
        let success = unsafe {
            DeviceIoControl(
                h,
                0x000940cf,
                input.as_ptr().cast(),
                16,
                output.as_mut_ptr().cast(),
                65536,
                &mut returned,
                null_mut(),
            )
        };
        let error = if success == 0 {
            unsafe { GetLastError() }
        } else {
            0
        };
        ensure!(
            (success != 0 || error == 234) && returned <= 65536 && returned % 16 == 0,
            "Sparse allocated range query failed or incomplete (Win32 {error})"
        );
        let mut previous = cursor;
        for chunk in output[..returned as usize / 8].chunks_exact(2) {
            let start = chunk[0];
            let count = chunk[1];
            ensure!(
                start >= previous
                    && count > 0
                    && start <= length
                    && count <= length - start
                    && result.len() < 4096,
                "Sparse allocated ranges overlap or are malformed"
            );
            total = total
                .checked_add(count as u64)
                .context("Sparse allocated size overflow")?;
            ensure!(
                total <= max,
                "Sparse allocated ranges exceed verification budget"
            );
            result.push(json!({"Offset":start,"Length":count}));
            previous = start.checked_add(count).context("Sparse range overflow")?;
        }
        if success != 0 {
            return Ok(result);
        }
        ensure!(
            returned > 0 && previous > cursor && previous < length,
            "Sparse range pagination did not advance"
        );
        cursor = previous;
    }
    bail!("Sparse range query did not certify completion")
}
fn seek(h: HANDLE, position: i64) -> Result<()> {
    if unsafe { SetFilePointerEx(h, position, null_mut(), FILE_BEGIN) } == 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(())
}
fn read_exact(h: HANDLE, b: &mut [u8]) -> Result<()> {
    let mut offset = 0;
    while offset < b.len() {
        let mut read = 0;
        let count = (b.len() - offset).min(u32::MAX as usize) as u32;
        if unsafe { ReadFile(h, b[offset..].as_mut_ptr(), count, &mut read, null_mut()) } == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        ensure!(read > 0, "Unexpected EOF in sparse fixture");
        offset += read as usize;
    }
    Ok(())
}
fn check_prefix(h: HANDLE, prefix: &[u8]) -> Result<()> {
    seek(h, 0)?;
    let mut actual = vec![0u8; prefix.len()];
    read_exact(h, &mut actual)?;
    ensure!(
        actual == prefix,
        "Sparse prefix differs from recorded bytes"
    );
    Ok(())
}
fn restore(args: &Value) -> Result<Value> {
    let raw_path = field(args, "path")?;
    let logical = num(args, "expectedLogicalLength")?;
    let encoded = field(args, "prefixBase64")?;
    let mut result = json!({"Success":false,"Error":null,"Path":raw_path,"ExpectedLogicalLength":logical,"PrefixBase64":encoded,"MutationStarted":false,"AlreadyTiny":false,"TailWasZero":false,"BytesChecked":0,"Before":null,"After":null,"PostClose":null,"AllocatedRangesBefore":null,"AllocatedRangesAfter":null});
    let run = (|| -> Result<()> {
        let path = absolute(raw_path)?;
        let scope = absolute(field(args, "scope")?)?;
        owned(&path, &scope)?;
        let id = field(args, "expectedId")?;
        let sec = field(args, "expectedSecurityBase64")?;
        let attrs: u32 = num(args, "expectedAttributes")?.try_into()?;
        let max = args
            .get("maximumAllocation")
            .and_then(Value::as_u64)
            .context("Missing allocation budget")?;
        let prefix = STANDARD.decode(encoded)?;
        ensure!(
            !id.is_empty()
                && !sec.is_empty()
                && !prefix.is_empty()
                && logical >= prefix.len() as i64
                && max > 0
                && max <= 1048576,
            "Sparse finalization requires complete evidence and bounded allocation"
        );
        let _parents = pin_parents(&path)?;
        result["Path"] = json!(path);
        {
            let handle = exclusive(&path, true)?;
            let before = proof(handle.0, &path)?;
            result["Before"] = before.clone();
            let tiny = before["Length"] == prefix.len() as i64;
            result["AlreadyTiny"] = json!(tiny);
            let before_len = before["Length"].as_i64().context("Invalid sparse length")?;
            match_proof(
                &before,
                id,
                sec,
                attrs,
                if tiny { prefix.len() as i64 } else { logical },
                max,
            )?;
            check_prefix(handle.0, &prefix)?;
            let allocated = ranges(handle.0, logical, max)?;
            result["AllocatedRangesBefore"] = json!(allocated);
            let mut checked = 0u64;
            let mut buffer = vec![0u8; 65536];
            for range in &allocated {
                let start = num(range, "Offset")?;
                let count = num(range, "Length")?;
                let mut position = start.max(prefix.len() as i64);
                let end = start
                    .checked_add(count)
                    .context("Sparse range overflow")?
                    .min(before_len);
                seek(handle.0, position)?;
                while position < end {
                    let length = (end - position).min(buffer.len() as i64) as usize;
                    read_exact(handle.0, &mut buffer[..length])?;
                    checked = checked
                        .checked_add(length as u64)
                        .context("Checked byte overflow")?;
                    result["BytesChecked"] = json!(checked);
                    ensure!(checked <= max, "Sparse tail exceeded allocation budget");
                    for (index, byte) in buffer[..length].iter().enumerate() {
                        ensure!(
                            *byte == 0,
                            "Unknown nonzero sparse tail at offset {}; file retained",
                            position + index as i64
                        );
                    }
                    position += length as i64;
                }
            }
            result["TailWasZero"] = json!(true);
            match_proof(&proof(handle.0, &path)?, id, sec, attrs, before_len, max)?;
            check_prefix(handle.0, &prefix)?;
            if !tiny {
                result["MutationStarted"] = json!(true);
                seek(handle.0, prefix.len() as i64)?;
                if unsafe { SetEndOfFile(handle.0) } == 0 {
                    return Err(std::io::Error::last_os_error().into());
                }
                if unsafe { FlushFileBuffers(handle.0) } == 0 {
                    return Err(std::io::Error::last_os_error().into());
                }
            }
            let after = proof(handle.0, &path)?;
            result["After"] = after.clone();
            match_proof(&after, id, sec, attrs, prefix.len() as i64, max)?;
            check_prefix(handle.0, &prefix)?;
            result["AllocatedRangesAfter"] = json!(ranges(handle.0, logical, max)?);
        }
        // close後も別のexclusive handleで同じ名前・実体と本文を再確認する。
        let reopened = exclusive(&path, false)?;
        let post = proof(reopened.0, &path)?;
        result["PostClose"] = post.clone();
        match_proof(&post, id, sec, attrs, prefix.len() as i64, max)?;
        check_prefix(reopened.0, &prefix)?;
        result["Success"] = json!(true);
        Ok(())
    })();
    if let Err(e) = run {
        result["Error"] = json!(format!("{e:#}"));
    }
    Ok(result)
}
fn allocation(path: &Path) -> Result<Value> {
    let name = wide(path.as_os_str())?;
    let mut high = 0;
    unsafe { SetLastError(0) };
    let low = unsafe { GetCompressedFileSizeW(name.as_ptr(), &mut high) };
    let err = unsafe { GetLastError() };
    ensure!(
        low != u32::MAX || err == 0,
        "Cannot query compressed size (Win32 {err})"
    );
    Ok(json!(((high as u64) << 32) | low as u64))
}
fn bin_totals(root: &Path) -> Result<Value> {
    let name = wide(root.as_os_str())?;
    let mut data = SHQUERYRBINFO {
        cbSize: std::mem::size_of::<SHQUERYRBINFO>() as u32,
        ..Default::default()
    };
    ensure!(
        (std::mem::size_of::<usize>() == 8 && data.cbSize == 24)
            || (std::mem::size_of::<usize>() == 4 && data.cbSize == 20),
        "Unexpected SHQUERYRBINFO layout"
    );
    let hr = unsafe { SHQueryRecycleBinW(name.as_ptr(), &mut data) };
    ensure!(
        hr >= 0,
        "Cannot query Recycle Bin totals (HRESULT 0x{:08X})",
        hr as u32
    );
    let count = data.i64NumItems;
    let bytes = data.i64Size;
    ensure!(count >= 0 && bytes >= 0, "Negative Recycle Bin totals");
    Ok(json!([count, bytes]))
}
/// 検証DLLと同一processで実行し、借用handleの寿命は呼出し元が固定する。
fn borrowed_handle(args: &Value) -> Result<HANDLE> {
    let n = args
        .get("handle")
        .and_then(Value::as_u64)
        .context("Missing borrowed handle")?;
    ensure!(
        n > 0 && n != usize::MAX as u64 && n <= usize::MAX as u64,
        "Invalid borrowed handle"
    );
    Ok(n as usize as HANDLE)
}
pub fn dispatch(op: &str, args: &Value) -> Result<Value> {
    match op {
        "file.sparse.make" => {
            let h = borrowed_handle(args)?;
            let mut returned = 0;
            if unsafe {
                DeviceIoControl(
                    h,
                    0x000900c4,
                    null(),
                    0,
                    null_mut(),
                    0,
                    &mut returned,
                    null_mut(),
                )
            } == 0
            {
                return Err(std::io::Error::last_os_error().into());
            }
            Ok(Value::Null)
        }
        "file.sparse.ranges" => {
            let handle = borrowed_handle(args)?;
            let length = num(args, "length")?;
            let maximum = args
                .get("maximumAllocation")
                .and_then(Value::as_u64)
                .context("Missing allocation budget")?;
            Ok(json!(ranges(handle, length, maximum)?))
        }
        "file.sparse.proof" => {
            let path = absolute(field(args, "path")?)?;
            let scope = absolute(field(args, "scope")?)?;
            owned(&path, &scope)?;
            let _parents = pin_parents(&path)?;
            let h = exclusive(&path, false)?;
            proof(h.0, &path)
        }
        "file.sparse.restore_tiny" => restore(args),
        "file.sparse.allocation" => allocation(&absolute(field(args, "path")?)?),
        "file.sparse.bin_totals" => bin_totals(&absolute(field(args, "rootPath")?)?),
        _ => bail!("Unknown sparse fixture operation: {op}"),
    }
}

#[cfg(test)]
mod scope_tests {
    use super::*;

    #[test]
    fn windows_ordinal_scope_boundaries() {
        assert!(
            owned(
                Path::new(r"D:\Fixture\Straße\item"),
                Path::new(r"d:\fixture\Straße")
            )
            .is_ok()
        );
        assert!(
            owned(
                Path::new(r"D:\Fixture\Straße\item"),
                Path::new(r"D:\Fixture\STRASSE")
            )
            .is_err()
        );
        assert!(
            owned(
                Path::new(r"D:\Fixture\STRASSE\item"),
                Path::new(r"D:\Fixture\Straße")
            )
            .is_err()
        );
        assert!(
            owned(
                Path::new(r"D:\FixtureSuffix\item"),
                Path::new(r"D:\Fixture")
            )
            .is_err()
        );
        assert!(owned(Path::new(r"D:\Fixture"), Path::new(r"D:\Fixture")).is_err());
        assert!(owned(Path::new(r"D:\item"), Path::new("d:\\")).is_ok());
    }
}

use super::{Args, common::*, package};
use anyhow::{Result, bail, ensure};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    ffi::c_void,
    io::{Read, Seek, SeekFrom},
    ptr,
};
use windows_sys::Win32::Networking::WinHttp::*;

struct Internet(*mut c_void);
impl Drop for Internet {
    fn drop(&mut self) {
        unsafe {
            WinHttpCloseHandle(self.0);
        }
    }
}
fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}
fn stop<T>(phase: &str, code: &str, status: Option<u32>) -> Result<T> {
    match status {
        Some(s) => bail!("R2 publisher stopped: phase={phase} code={code} httpStatus={s}"),
        None => bail!("R2 publisher stopped: phase={phase} code={code}"),
    }
}
fn hmac(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut block = [0u8; 64];
    if key.len() > 64 {
        block[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        block[..key.len()].copy_from_slice(key);
    }
    let mut inner = Sha256::new();
    let mut outer = Sha256::new();
    for byte in &mut block {
        *byte ^= 0x36;
    }
    inner.update(block);
    inner.update(data);
    for byte in &mut block {
        *byte ^= 0x36 ^ 0x5c;
    }
    outer.update(block);
    outer.update(inner.finalize());
    block.fill(0);
    outer.finalize().into()
}
fn signed(
    method: &str,
    host: &str,
    path: &str,
    payload: &str,
    access: &str,
    secret: &str,
    create: bool,
) -> String {
    let timestamp = chrono::Utc::now().format("%Y%m%dT%H%M%SZ").to_string();
    let mut headers = BTreeMap::from([
        ("host", host.to_owned()),
        ("x-amz-content-sha256", payload.to_owned()),
        ("x-amz-date", timestamp.clone()),
    ]);
    if create {
        headers.insert("if-none-match", "*".into());
    }
    let canonical_headers = headers
        .iter()
        .map(|(k, v)| format!("{k}:{v}\n"))
        .collect::<String>();
    let names = headers.keys().copied().collect::<Vec<_>>().join(";");
    let canonical = format!("{method}\n{path}\n\n{canonical_headers}\n{names}\n{payload}");
    let scope = format!("{}/auto/s3/aws4_request", &timestamp[..8]);
    let to_sign = format!(
        "AWS4-HMAC-SHA256\n{timestamp}\n{scope}\n{}",
        digest(canonical.as_bytes()).to_lowercase()
    );
    let mut date_key = hmac(
        format!("AWS4{secret}").as_bytes(),
        timestamp[..8].as_bytes(),
    );
    let mut region_key = hmac(&date_key, b"auto");
    let mut service_key = hmac(&region_key, b"s3");
    let mut signing_key = hmac(&service_key, b"aws4_request");
    let signature = hex::encode(hmac(&signing_key, to_sign.as_bytes()));
    for key in [
        &mut date_key,
        &mut region_key,
        &mut service_key,
        &mut signing_key,
    ] {
        key.fill(0);
    }
    headers.insert("Authorization", format!("AWS4-HMAC-SHA256 Credential={access}/{scope}, SignedHeaders={names}, Signature={signature}"));
    headers
        .into_iter()
        .map(|(k, v)| format!("{k}: {v}\r\n"))
        .collect()
}
struct Response {
    request: Internet,
    _connection: Internet,
    _session: Internet,
    status: u32,
}
fn request(
    host: &str,
    path: &str,
    method: &str,
    headers: &str,
    mut body: Option<&mut std::fs::File>,
    phase: &str,
) -> Result<Response> {
    let transport = || {
        if phase == "s3-put" {
            stop(phase, "unknown-no-resend", None)
        } else {
            stop(phase, "transport-unknown", None)
        }
    };
    unsafe {
        let session = Internet(WinHttpOpen(
            wide("Prunlet-release/1").as_ptr(),
            WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
            ptr::null(),
            ptr::null(),
            0,
        ));
        if session.0.is_null() {
            return transport();
        }
        if WinHttpSetTimeouts(session.0, 120000, 120000, 600000, 600000) == 0 {
            return transport();
        }
        let connection = Internet(WinHttpConnect(session.0, wide(host).as_ptr(), 443, 0));
        if connection.0.is_null() {
            return transport();
        }
        let request = Internet(WinHttpOpenRequest(
            connection.0,
            wide(method).as_ptr(),
            wide(path).as_ptr(),
            ptr::null(),
            ptr::null(),
            ptr::null(),
            WINHTTP_FLAG_SECURE,
        ));
        if request.0.is_null() {
            return transport();
        }
        let mut disable = WINHTTP_DISABLE_REDIRECTS | WINHTTP_DISABLE_COOKIES;
        if WinHttpSetOption(
            request.0,
            WINHTTP_OPTION_DISABLE_FEATURE,
            (&mut disable as *mut u32).cast(),
            4,
        ) == 0
        {
            return transport();
        }
        // 応答前の内部再接続は許すが、HTTP 307/401等に伴うbody再送要求には応じない。
        let size = if let Some(file) = body.as_mut() {
            match file.metadata() {
                Ok(m) if m.len() <= MAX_ZIP => m.len() as u32,
                _ => return stop("package-pin", "changed", None),
            }
        } else {
            0
        };
        let all_headers = if body.is_some() {
            format!("{headers}Content-Type: application/zip\r\nContent-Length: {size}\r\n")
        } else {
            headers.to_owned()
        };
        let headers = wide(&all_headers);
        if WinHttpSendRequest(
            request.0,
            headers.as_ptr(),
            (headers.len() - 1) as u32,
            ptr::null(),
            0,
            size,
            0,
        ) == 0
        {
            return transport();
        }
        if let Some(file) = body.as_mut() {
            if file.seek(SeekFrom::Start(0)).is_err() {
                return stop("package-pin", "changed", None);
            }
            let mut buffer = [0u8; 65536];
            let mut sent = 0u64;
            loop {
                let n = match file.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(n) => n,
                    Err(_) => return transport(),
                };
                sent += n as u64;
                if sent > size as u64 {
                    return stop("package-pin", "changed", None);
                }
                let mut written = 0;
                if WinHttpWriteData(request.0, buffer.as_ptr().cast(), n as u32, &mut written) == 0
                    || written != n as u32
                {
                    return transport();
                }
            }
            if sent != size as u64 {
                return stop("package-pin", "changed", None);
            }
        }
        if WinHttpReceiveResponse(request.0, ptr::null_mut()) == 0 {
            return transport();
        }
        let mut status = 0u32;
        let mut length = 4;
        if WinHttpQueryHeaders(
            request.0,
            WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
            ptr::null(),
            (&mut status as *mut u32).cast(),
            &mut length,
            ptr::null_mut(),
        ) == 0
        {
            return transport();
        }
        Ok(Response {
            _session: session,
            _connection: connection,
            request,
            status,
        })
    }
}
fn body(response: &Response, bytes: u64, hash: &str, phase: &str) -> Result<()> {
    if response.status != 200 {
        return stop(phase, "http-rejected", Some(response.status));
    }
    unsafe {
        // WinHTTPによる自動展開は有効化せず、Content-Encoding自体も拒否する。
        let mut encoding = [0u16; 256];
        let mut length = (encoding.len() * 2) as u32;
        let encoding_result = WinHttpQueryHeaders(
            response.request.0,
            WINHTTP_QUERY_CONTENT_ENCODING,
            ptr::null(),
            encoding.as_mut_ptr().cast(),
            &mut length,
            ptr::null_mut(),
        );
        if encoding_result != 0 {
            if length > 0 {
                return stop(phase, "body-mismatch", Some(response.status));
            }
        } else if windows_sys::Win32::Foundation::GetLastError() != ERROR_WINHTTP_HEADER_NOT_FOUND {
            return stop(phase, "operation-failed", None);
        }
        let mut content_length = [0u16; 64];
        let mut length = (content_length.len() * 2) as u32;
        if WinHttpQueryHeaders(
            response.request.0,
            WINHTTP_QUERY_CONTENT_LENGTH,
            ptr::null(),
            content_length.as_mut_ptr().cast(),
            &mut length,
            ptr::null_mut(),
        ) != 0
        {
            let value = String::from_utf16(&content_length[..(length as usize / 2)])
                .ok()
                .and_then(|v| v.trim_end_matches('\0').parse::<u64>().ok());
            if value != Some(bytes) {
                return stop(phase, "body-mismatch", Some(response.status));
            }
        } else if windows_sys::Win32::Foundation::GetLastError() != ERROR_WINHTTP_HEADER_NOT_FOUND {
            return stop(phase, "operation-failed", None);
        }
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(600);
        let mut digest = Sha256::new();
        let mut total = 0u64;
        let mut buffer = [0u8; 65536];
        loop {
            if std::time::Instant::now() >= deadline {
                return stop(phase, "transport-unknown", None);
            }
            let remaining = deadline
                .saturating_duration_since(std::time::Instant::now())
                .as_millis()
                .min(600000)
                .max(1) as u32;
            if WinHttpSetOption(
                response.request.0,
                WINHTTP_OPTION_RECEIVE_TIMEOUT,
                (&remaining as *const u32).cast(),
                4,
            ) == 0
            {
                return stop(phase, "operation-failed", None);
            }
            let mut read = 0;
            if WinHttpReadData(
                response.request.0,
                buffer.as_mut_ptr().cast(),
                buffer.len() as u32,
                &mut read,
            ) == 0
            {
                return stop(phase, "transport-unknown", None);
            }
            if read == 0 {
                break;
            }
            total += read as u64;
            if total > bytes {
                return stop(phase, "body-mismatch", Some(response.status));
            }
            digest.update(&buffer[..read as usize]);
        }
        if total != bytes || hex::encode(digest.finalize()) != hash {
            return stop(phase, "body-mismatch", Some(response.status));
        }
    }
    Ok(())
}
pub fn run(args: &Args) -> Result<()> {
    if args.get("repository")? != "1llum1n4t1s/Prunlet" {
        return stop("identity", "invalid-input", None);
    }
    let mut package = package::verify(args).map_err(|_| {
        anyhow::anyhow!("R2 publisher stopped: phase=package-verification code=verification-failed")
    })?;
    let account = std::env::var("PRUNLET_R2_ACCOUNT_ID").unwrap_or_default();
    let bucket = std::env::var("PRUNLET_R2_BUCKET")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| "prunlet-updates".into());
    if account.len() != 32
        || !account
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        || !regex::Regex::new(r"^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$")?.is_match(&bucket)
    {
        return stop("identity", "invalid-input", None);
    }
    let access = std::env::var("PRUNLET_R2_ACCESS_KEY_ID").unwrap_or_default();
    let secret = std::env::var("PRUNLET_R2_SECRET_ACCESS_KEY").unwrap_or_default();
    if access.is_empty()
        || !access.bytes().all(|b| b.is_ascii_alphanumeric())
        || secret.trim().is_empty()
        || secret.contains(['\r', '\n'])
    {
        return stop("credentials", "unavailable-before-http", None);
    }
    let hash = package.sha256.to_lowercase();
    super::build::verify_git_source(args, &mut package._pins).map_err(|_| {
        anyhow::anyhow!("R2 publisher stopped: phase=package-verification code=verification-failed")
    })?;
    let key = format!(
        "releases/{}/{}/{}/{hash}.zip",
        args.get("repository")?.to_lowercase(),
        args.get("commit")?,
        args.get("runtime")?
    );
    let host = format!("{account}.r2.cloudflarestorage.com");
    let path = format!("/{bucket}/{key}");
    let empty = digest(b"").to_lowercase();
    let head = request(
        &host,
        &path,
        "HEAD",
        &signed("HEAD", &host, &path, &empty, &access, &secret, false),
        None,
        "s3-head",
    )?;
    let mut reused = false;
    match head.status {
        404 => {
            drop(head);
            // PUTは一度だけ。失敗・不明応答を他経路で再送しない。
            let put = request(
                &host,
                &path,
                "PUT",
                &signed("PUT", &host, &path, &hash, &access, &secret, true),
                Some(&mut package.file),
                "s3-put",
            )?;
            match put.status {
                200 => {}
                412 => reused = true,
                400..=499 => return stop("s3-put", "http-rejected", Some(put.status)),
                _ => return stop("s3-put", "unknown-no-resend", Some(put.status)),
            }
        }
        200 => {
            reused = true;
            drop(head);
        }
        _ => return stop("s3-head", "http-rejected", Some(head.status)),
    }
    let existing = request(
        &host,
        &path,
        "GET",
        &signed("GET", &host, &path, &empty, &access, &secret, false),
        None,
        "s3-existing",
    )?;
    body(&existing, package.bytes, &hash, "s3-existing")?;
    drop(existing);
    let public = request(
        "prunlet.kagayoi.com",
        &format!("/{key}"),
        "GET",
        "",
        None,
        "public-get",
    )?;
    body(&public, package.bytes, &hash, "public-get")?;
    ensure!(
        package.file.metadata()?.len() == package.bytes
            && super::common::hash(&mut package.file)?.eq_ignore_ascii_case(&hash),
        "R2 publisher stopped: phase=package-pin code=changed"
    );
    println!(
        "{}",
        serde_json::json!({"schema":1,"repository":args.get("repository")?,"commitSha":args.get("commit")?,"runtime":args.get("runtime")?,"objectKey":key,"publicUrl":format!("https://prunlet.kagayoi.com/{key}"),"sha256":hash,"bytes":package.bytes,"reused":reused,"verified":true})
    );
    Ok(())
}

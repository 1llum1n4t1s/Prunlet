//! 検証専用のWindows API境界。製品Coreへ依存せず、呼出し元のプロセスで実行する。
//!
//! JSON応答はRust側のallocatorで確保し、必ず同じDLLのfreeへ返す。
//! 応答の読取りに失敗しても、callを自動再送してはならない。

#[cfg(windows)]
mod files;
#[cfg(windows)]
mod path_scope;
#[cfg(windows)]
mod protected;
#[cfg(windows)]
mod registry;
#[cfg(windows)]
mod session;
#[cfg(windows)]
mod sparse;

use serde_json::{Value, json};
use std::panic::{AssertUnwindSafe, catch_unwind};

const MAX_MESSAGE_BYTES: usize = 64 * 1024 * 1024;

fn execute(input: &[u8]) -> anyhow::Result<Value> {
    let request: Value = serde_json::from_slice(input)?;
    let object = request
        .as_object()
        .ok_or_else(|| anyhow::anyhow!("Fixture request must be an object"))?;
    anyhow::ensure!(
        object.len() == 2 && object.contains_key("operation") && object.contains_key("arguments"),
        "Fixture request fields differ"
    );
    let operation = request["operation"]
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("Fixture operation must be a string"))?;
    let arguments = &request["arguments"];
    anyhow::ensure!(arguments.is_object(), "Fixture arguments must be an object");
    if operation == "bridge.identity" {
        return Ok(json!({
            "product": "PrunletVerificationFixtures",
            "schema": 1,
            "processId": std::process::id(),
            "pointerBytes": std::mem::size_of::<usize>(),
            "version": env!("CARGO_PKG_VERSION")
        }));
    }
    #[cfg(windows)]
    {
        if operation.starts_with("file.sparse.") {
            return sparse::dispatch(operation, arguments);
        }
        if operation.starts_with("file.") {
            return files::dispatch(operation, arguments);
        }
        if operation.starts_with("registry.protected.") {
            return protected::dispatch(operation, arguments);
        }
        if operation.starts_with("registry.") {
            return registry::dispatch(operation, arguments);
        }
        if operation.starts_with("session.") {
            return session::dispatch(operation, arguments);
        }
    }
    anyhow::bail!("Unknown fixture operation: {operation}")
}

fn response(input: &[u8]) -> Vec<u8> {
    // panicをFFIの外へ伝播させない。エラー時も呼出しの成否を一度だけ応答する。
    let value = match catch_unwind(AssertUnwindSafe(|| execute(input))) {
        Ok(Ok(value)) => json!({"ok": true, "value": value}),
        Ok(Err(error)) => {
            let win32 = error.chain().find_map(|cause| {
                cause
                    .downcast_ref::<std::io::Error>()
                    .and_then(std::io::Error::raw_os_error)
            });
            json!({"ok": false, "error": format!("{error:#}"), "win32": win32})
        }
        Err(_) => {
            json!({"ok": false, "error": "Fixture operation panicked; inspect its state before continuing", "win32": null})
        }
    };
    let bytes = serde_json::to_vec(&value).unwrap_or_else(|_| {
        br#"{"ok":false,"error":"Fixture response serialization failed; do not resend"}"#.to_vec()
    });
    if bytes.len() > MAX_MESSAGE_BYTES {
        return br#"{"ok":false,"error":"Fixture response exceeded its bound; do not resend"}"#
            .to_vec();
    }
    bytes
}

/// 一度だけ要求を実行する。戻り値は`prunlet_fixture_free`で解放する。
///
/// # Safety
/// inputはlength bytes、output_lengthはusizeを書込める領域であること。
#[unsafe(no_mangle)]
pub unsafe extern "system" fn prunlet_fixture_call(
    input: *const u8,
    length: usize,
    output_length: *mut usize,
) -> *mut u8 {
    if output_length.is_null() {
        return std::ptr::null_mut();
    }
    unsafe { output_length.write(0) };
    if input.is_null() || length == 0 || length > MAX_MESSAGE_BYTES {
        return std::ptr::null_mut();
    }
    let bytes = response(unsafe { std::slice::from_raw_parts(input, length) }).into_boxed_slice();
    let size = bytes.len();
    let pointer = Box::into_raw(bytes).cast::<u8>();
    unsafe { output_length.write(size) };
    pointer
}

/// `call`から得た応答だけを、元の長さで一度解放する。
///
/// # Safety
/// pointerとlengthはこのDLLのcallが返した未解放の組であること。
#[unsafe(no_mangle)]
pub unsafe extern "system" fn prunlet_fixture_free(pointer: *mut u8, length: usize) {
    if !pointer.is_null() && length != 0 {
        let slice = std::ptr::slice_from_raw_parts_mut(pointer, length);
        unsafe { drop(Box::from_raw(slice)) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_reports_the_actual_process_and_strict_request_shape() {
        let value = execute(br#"{"operation":"bridge.identity","arguments":{}}"#).unwrap();
        assert_eq!(value["processId"], std::process::id());
        assert!(execute(br#"{"operation":"bridge.identity","arguments":{},"extra":1}"#).is_err());
        assert!(execute(br#"{"operation":"bridge.identity","arguments":[]}"#).is_err());
    }

    #[test]
    fn ffi_response_has_explicit_rust_owned_lifetime() {
        let input = br#"{"operation":"bridge.identity","arguments":{}}"#;
        let mut length = 0;
        let pointer = unsafe { prunlet_fixture_call(input.as_ptr(), input.len(), &mut length) };
        assert!(!pointer.is_null());
        let parsed: Value =
            serde_json::from_slice(unsafe { std::slice::from_raw_parts(pointer, length) }).unwrap();
        assert_eq!(parsed["ok"], true);
        unsafe { prunlet_fixture_free(pointer, length) };
        let failed: Value = serde_json::from_slice(&response(b"invalid json")).unwrap();
        assert_eq!(failed["ok"], false);
    }
}

//! 実行ファイルの事実の読み取り（Authenticode 署名・版リソース・PE の machine）。
//!
//! ここは「事実を取り出す」だけで、合否の判断は [`super::trust`] の純関数が行う。判断を分けることで、
//! 未署名・別 CN・製品名違い・版不一致・machine 違いなどの拒否を、署名済みの実物が無くても単体テストで網羅できる。
//!
//! # 署名の検査
//! - `WinVerifyTrust`（`WINTRUST_ACTION_GENERIC_VERIFY_V2`、UI なし、失効確認なし）で Valid かを確かめる。
//!   失効確認（OCSP/CRL）をしないのは、ログオン時にネットワークが無くても適用判断を終えられるようにするため。
//! - 署名者の CN は、埋め込み署名の最初の署名者の証明書から読む（`CryptQueryObject`）。
//! - **タイムスタンプの有無**は、署名者情報の非認証属性に、RFC 3161 のタイムスタンプ
//!   （`1.3.6.1.4.1.311.3.3.1`）か従来形式の副署名（`1.2.840.113549.1.9.6`）があるかで判定する。
//!   タイムスタンプが無い署名は、証明書の期限が切れた時点で検証できなくなるため、受け入れない。
use std::{
    ffi::{CStr, c_void},
    os::windows::ffi::OsStrExt,
    path::Path,
    ptr::{null, null_mut},
};

use windows_sys::{
    Win32::{
        Foundation::INVALID_HANDLE_VALUE,
        Security::{
            Cryptography::{
                CERT_CONTEXT, CERT_FIND_SUBJECT_CERT, CERT_INFO, CERT_NAME_ATTR_TYPE,
                CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED, CERT_QUERY_FORMAT_FLAG_BINARY,
                CERT_QUERY_OBJECT_FILE, CMSG_SIGNER_CERT_INFO_PARAM, CMSG_SIGNER_UNAUTH_ATTR_PARAM,
                CRYPT_ATTRIBUTES, CertCloseStore, CertFindCertificateInStore,
                CertFreeCertificateContext, CertGetNameStringW, CryptMsgClose, CryptMsgGetParam,
                CryptQueryObject, PKCS_7_ASN_ENCODING, X509_ASN_ENCODING, szOID_COMMON_NAME,
            },
            WinTrust::{
                WINTRUST_DATA, WINTRUST_FILE_INFO, WTD_CHOICE_FILE, WTD_REVOKE_NONE,
                WTD_STATEACTION_CLOSE, WTD_STATEACTION_VERIFY, WTD_UI_NONE, WinVerifyTrust,
            },
        },
        Storage::FileSystem::{
            GetFileVersionInfoSizeW, GetFileVersionInfoW, VS_FIXEDFILEINFO, VerQueryValueW,
        },
    },
    core::GUID,
};

/// RFC 3161 のタイムスタンプトークン（Authenticode の非認証属性）。
const OID_RFC3161_TIMESTAMP: &str = "1.3.6.1.4.1.311.3.3.1";
/// 従来形式の副署名（タイムスタンプ）。
const OID_COUNTER_SIGNATURE: &str = "1.2.840.113549.1.9.6";

/// WINTRUST_ACTION_GENERIC_VERIFY_V2 {00AAC56B-CD44-11d0-8CC2-00C04FC295EE}。
const GENERIC_VERIFY_V2: GUID = GUID {
    data1: 0x00AA_C56B,
    data2: 0xCD44,
    data3: 0x11D0,
    data4: [0x8C, 0xC2, 0x00, 0xC0, 0x4F, 0xC2, 0x95, 0xEE],
};

/// 署名について得た事実。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SignatureFacts {
    /// `WinVerifyTrust` が成功した（Authenticode が Valid）。
    pub valid: bool,
    /// 署名者の証明書の CN。読めなければ None。
    pub common_name: Option<String>,
    /// タイムスタンプ（副署名）が付いている。
    pub timestamped: bool,
}

/// PE 1つについて取り出した事実（署名・版リソース・machine）。
#[derive(Debug, Clone, Default)]
pub struct PeFactsSource {
    pub signature: SignatureFacts,
    pub version: VersionFacts,
    pub machine: Option<u16>,
}

/// 版リソースについて得た事実。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct VersionFacts {
    /// `StringFileInfo` の `ProductName`。
    pub product_name: Option<String>,
    /// 固定情報の FILEVERSION（major, minor, patch, revision）。
    pub file_version: Option<[u16; 4]>,
    /// `StringFileInfo` の `ProductVersion`（`<版>+<コミット>` の形がある）。
    pub product_version: Option<String>,
}

fn wide(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain(Some(0)).collect()
}

fn wide_str(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}

/// ファイルの署名の事実を取り出す。
pub fn signature_facts(path: &Path) -> SignatureFacts {
    let valid = signature_is_valid(path);
    let (common_name, timestamped) = embedded_signer(path);
    SignatureFacts {
        valid,
        common_name,
        timestamped,
    }
}

fn signature_is_valid(path: &Path) -> bool {
    let path = wide(path);
    let mut file = WINTRUST_FILE_INFO {
        cbStruct: std::mem::size_of::<WINTRUST_FILE_INFO>() as u32,
        pcwszFilePath: path.as_ptr(),
        hFile: null_mut(),
        pgKnownSubject: null_mut(),
    };
    // SAFETY: ゼロ初期化した構造体に必要な項目を設定してから渡す。state は VERIFY の後に CLOSE で解放する。
    unsafe {
        let mut data: WINTRUST_DATA = std::mem::zeroed();
        data.cbStruct = std::mem::size_of::<WINTRUST_DATA>() as u32;
        data.dwUIChoice = WTD_UI_NONE;
        data.fdwRevocationChecks = WTD_REVOKE_NONE;
        data.dwUnionChoice = WTD_CHOICE_FILE;
        data.Anonymous.pFile = &mut file;
        data.dwStateAction = WTD_STATEACTION_VERIFY;
        let mut action = GENERIC_VERIFY_V2;
        let status = WinVerifyTrust(
            INVALID_HANDLE_VALUE,
            &mut action,
            &mut data as *mut WINTRUST_DATA as *mut c_void,
        );
        data.dwStateAction = WTD_STATEACTION_CLOSE;
        WinVerifyTrust(
            INVALID_HANDLE_VALUE,
            &mut action,
            &mut data as *mut WINTRUST_DATA as *mut c_void,
        );
        status == 0
    }
}

/// 埋め込み署名の最初の署名者の CN と、タイムスタンプの有無を読む。署名が無ければ (None, false)。
fn embedded_signer(path: &Path) -> (Option<String>, bool) {
    let path = wide(path);
    let mut store = null_mut();
    let mut message: *mut c_void = null_mut();
    // SAFETY: 出力はいずれも自分の変数。得たハンドル・コンテキストは末尾で必ず解放する。
    unsafe {
        if CryptQueryObject(
            CERT_QUERY_OBJECT_FILE,
            path.as_ptr() as *const c_void,
            CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED,
            CERT_QUERY_FORMAT_FLAG_BINARY,
            0,
            null_mut(),
            null_mut(),
            null_mut(),
            &mut store,
            &mut message,
            null_mut(),
        ) == 0
        {
            return (None, false);
        }
        let name = common_name_of_signer(store, message);
        let timestamped = has_timestamp(message);
        CertCloseStore(store, 0);
        CryptMsgClose(message);
        (name, timestamped)
    }
}

/// 署名者の証明書をストアから探して CN を得る（CryptQueryObject の定番の手順）。
///
/// # Safety
/// `store` と `message` は `CryptQueryObject` が返した有効なハンドルであること。
unsafe fn common_name_of_signer(store: *mut c_void, message: *mut c_void) -> Option<String> {
    unsafe {
        let mut size = 0u32;
        if CryptMsgGetParam(
            message,
            CMSG_SIGNER_CERT_INFO_PARAM,
            0,
            null_mut(),
            &mut size,
        ) == 0
        {
            return None;
        }
        // CERT_INFO を指すポインタを含むため、8 バイト境界の領域に取る。
        let mut buffer = vec![0u64; (size as usize).div_ceil(8)];
        if CryptMsgGetParam(
            message,
            CMSG_SIGNER_CERT_INFO_PARAM,
            0,
            buffer.as_mut_ptr() as *mut c_void,
            &mut size,
        ) == 0
        {
            return None;
        }
        let info = buffer.as_ptr() as *const CERT_INFO;
        let certificate: *mut CERT_CONTEXT = CertFindCertificateInStore(
            store,
            X509_ASN_ENCODING | PKCS_7_ASN_ENCODING,
            0,
            CERT_FIND_SUBJECT_CERT,
            info as *const c_void,
            null(),
        );
        if certificate.is_null() {
            return None;
        }
        let length = CertGetNameStringW(
            certificate,
            CERT_NAME_ATTR_TYPE,
            0,
            szOID_COMMON_NAME as *const c_void,
            null_mut(),
            0,
        );
        let mut text = vec![0u16; length as usize];
        let written = CertGetNameStringW(
            certificate,
            CERT_NAME_ATTR_TYPE,
            0,
            szOID_COMMON_NAME as *const c_void,
            text.as_mut_ptr(),
            length,
        );
        CertFreeCertificateContext(certificate);
        if written <= 1 {
            return None;
        }
        Some(String::from_utf16_lossy(&text[..written as usize - 1]))
    }
}

/// 署名者情報の非認証属性に、タイムスタンプ（RFC 3161 または従来形式の副署名）があるか。
///
/// # Safety
/// `message` は `CryptQueryObject` が返した有効なメッセージハンドルであること。
unsafe fn has_timestamp(message: *mut c_void) -> bool {
    unsafe {
        let mut size = 0u32;
        if CryptMsgGetParam(
            message,
            CMSG_SIGNER_UNAUTH_ATTR_PARAM,
            0,
            null_mut(),
            &mut size,
        ) == 0
        {
            // 非認証属性が無い（CRYPT_E_ATTRIBUTES_MISSING）＝タイムスタンプ無し。
            return false;
        }
        // CRYPT_ATTRIBUTES は内部にポインタを持つため、8 バイト境界の領域に取る。
        let mut buffer = vec![0u64; (size as usize).div_ceil(8)];
        if CryptMsgGetParam(
            message,
            CMSG_SIGNER_UNAUTH_ATTR_PARAM,
            0,
            buffer.as_mut_ptr() as *mut c_void,
            &mut size,
        ) == 0
        {
            return false;
        }
        let attributes = &*(buffer.as_ptr() as *const CRYPT_ATTRIBUTES);
        (0..attributes.cAttr as usize).any(|index| {
            let attribute = &*attributes.rgAttr.add(index);
            if attribute.pszObjId.is_null() {
                return false;
            }
            let oid = CStr::from_ptr(attribute.pszObjId as *const std::ffi::c_char);
            matches!(
                oid.to_str(),
                Ok(OID_RFC3161_TIMESTAMP) | Ok(OID_COUNTER_SIGNATURE)
            )
        })
    }
}

/// 版リソースの事実を取り出す。リソースが無い・読めない場合は空の事実を返す。
pub fn version_facts(path: &Path) -> VersionFacts {
    let wide_path = wide(path);
    // SAFETY: 標準の版情報 API の手順（サイズ照会 → 取得 → 値の参照）。参照した値はバッファの寿命内だけ使う。
    unsafe {
        let mut handle = 0u32;
        let size = GetFileVersionInfoSizeW(wide_path.as_ptr(), &mut handle);
        if size == 0 {
            return VersionFacts::default();
        }
        let mut buffer = vec![0u8; size as usize];
        if GetFileVersionInfoW(
            wide_path.as_ptr(),
            0,
            size,
            buffer.as_mut_ptr() as *mut c_void,
        ) == 0
        {
            return VersionFacts::default();
        }
        let file_version = query_fixed(&buffer);
        // build.rs の版リソースは英語（040904B0）の1ブロックだけを持つ。
        let product_name = query_string(&buffer, "ProductName");
        let product_version = query_string(&buffer, "ProductVersion");
        VersionFacts {
            product_name,
            file_version,
            product_version,
        }
    }
}

/// VS_FIXEDFILEINFO の FILEVERSION を読む。
///
/// # Safety
/// `buffer` は `GetFileVersionInfoW` が満たした版情報ブロックであること。
unsafe fn query_fixed(buffer: &[u8]) -> Option<[u16; 4]> {
    unsafe {
        let mut value: *mut c_void = null_mut();
        let mut length = 0u32;
        let sub_block = wide_str("\\");
        if VerQueryValueW(
            buffer.as_ptr() as *const c_void,
            sub_block.as_ptr(),
            &mut value,
            &mut length,
        ) == 0
            || value.is_null()
            || (length as usize) < std::mem::size_of::<VS_FIXEDFILEINFO>()
        {
            return None;
        }
        let info = &*(value as *const VS_FIXEDFILEINFO);
        Some([
            (info.dwFileVersionMS >> 16) as u16,
            (info.dwFileVersionMS & 0xffff) as u16,
            (info.dwFileVersionLS >> 16) as u16,
            (info.dwFileVersionLS & 0xffff) as u16,
        ])
    }
}

/// `\StringFileInfo\040904B0\<name>` の文字列を読む。
///
/// # Safety
/// `buffer` は `GetFileVersionInfoW` が満たした版情報ブロックであること。
unsafe fn query_string(buffer: &[u8], name: &str) -> Option<String> {
    unsafe {
        let mut value: *mut c_void = null_mut();
        let mut length = 0u32;
        let sub_block = wide_str(&format!("\\StringFileInfo\\040904B0\\{name}"));
        if VerQueryValueW(
            buffer.as_ptr() as *const c_void,
            sub_block.as_ptr(),
            &mut value,
            &mut length,
        ) == 0
            || value.is_null()
            || length == 0
        {
            return None;
        }
        let units = std::slice::from_raw_parts(value as *const u16, length as usize);
        let end = units
            .iter()
            .position(|unit| *unit == 0)
            .unwrap_or(units.len());
        Some(String::from_utf16_lossy(&units[..end]))
    }
}

/// PE ヘッダーから machine（`IMAGE_FILE_HEADER.Machine`）を読む。PE として読めなければ None。
pub fn pe_machine(header: &[u8]) -> Option<u16> {
    // DOS ヘッダーの e_lfanew（0x3C）から PE シグネチャ `PE\0\0`、その直後の2バイトが Machine。
    if header.get(..2)? != b"MZ" {
        return None;
    }
    let offset = u32::from_le_bytes(header.get(0x3c..0x40)?.try_into().ok()?) as usize;
    if header.get(offset..offset + 4)? != b"PE\0\0" {
        return None;
    }
    Some(u16::from_le_bytes(
        header.get(offset + 4..offset + 6)?.try_into().ok()?,
    ))
}

/// `IMAGE_FILE_MACHINE_AMD64`。
pub const MACHINE_AMD64: u16 = 0x8664;
/// `IMAGE_FILE_MACHINE_ARM64`。
pub const MACHINE_ARM64: u16 = 0xAA64;

/// 実行中のビルドの machine（候補の exe がこれと一致しなければ、別の CPU 向けの差し替えとして拒否する）。
pub fn running_machine() -> u16 {
    if cfg!(target_arch = "aarch64") {
        MACHINE_ARM64
    } else {
        MACHINE_AMD64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn machine_is_read_from_the_running_executable() {
        let bytes = std::fs::read(std::env::current_exe().unwrap()).unwrap();
        assert_eq!(
            pe_machine(&bytes[..4096.min(bytes.len())]),
            Some(running_machine())
        );
        assert_eq!(pe_machine(b"not a pe"), None);
        assert_eq!(pe_machine(b"MZ"), None);
    }

    #[test]
    fn unsigned_executable_has_no_valid_signature() {
        // このテストの実行ファイル自身は未署名。
        let facts = signature_facts(&std::env::current_exe().unwrap());
        assert!(!facts.valid);
        assert!(!facts.timestamped);
        assert_eq!(facts.common_name, None);
    }

    /// 署名済みの prunlet.exe がある環境でだけ、実物の署名・版・タイムスタンプの読み取りを確かめる。
    /// `PRUNLET_TEST_SIGNED_FILE`（読み取り専用の複製を指す）を指定して `--include-ignored` で実行する。
    #[test]
    #[ignore = "PRUNLET_TEST_SIGNED_FILE に署名済みファイルを指定して --include-ignored で実行"]
    fn signed_file_probe() {
        let file = std::path::PathBuf::from(
            std::env::var_os("PRUNLET_TEST_SIGNED_FILE")
                .expect("PRUNLET_TEST_SIGNED_FILE に署名済みファイルを指定してください"),
        );
        let signature = signature_facts(&file);
        assert!(signature.valid, "{signature:?}");
        assert!(signature.timestamped, "{signature:?}");
        assert_eq!(
            signature.common_name.as_deref(),
            Some("Open Source Developer Yuichiro Shinozaki")
        );
        let version = version_facts(&file);
        assert_eq!(version.product_name.as_deref(), Some("Prunlet"));
        assert!(version.file_version.is_some());
        let header = std::fs::read(&file).unwrap();
        assert_eq!(pe_machine(&header[..4096]), Some(MACHINE_AMD64));
    }
}

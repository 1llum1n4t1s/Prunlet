use anyhow::{Context, Result, bail, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use chrono::{DateTime, FixedOffset};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    cmp::Ordering,
    collections::{BTreeMap, BTreeSet},
};

struct OrdinalKey(Vec<u16>);
impl PartialEq for OrdinalKey {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}
impl Eq for OrdinalKey {}
impl OrdinalKey {
    fn new(value: &str) -> Self {
        Self(value.encode_utf16().collect())
    }
}
impl Ord for OrdinalKey {
    fn cmp(&self, other: &Self) -> Ordering {
        #[cfg(windows)]
        {
            let result = unsafe {
                CompareStringOrdinal(
                    self.0.as_ptr(),
                    self.0.len() as i32,
                    other.0.as_ptr(),
                    other.0.len() as i32,
                    1,
                )
            };
            match result {
                1 => Ordering::Less,
                2 => Ordering::Equal,
                3 => Ordering::Greater,
                _ => self.0.cmp(&other.0),
            }
        }
        #[cfg(not(windows))]
        {
            fn fold(s: &[u16]) -> String {
                String::from_utf16_lossy(s)
                    .chars()
                    .map(|c| {
                        let mut upper = c.to_uppercase();
                        let first = upper.next().unwrap();
                        if upper.next().is_some() { c } else { first }
                    })
                    .collect()
            }
            fold(&self.0).cmp(&fold(&other.0))
        }
    }
}
impl PartialOrd for OrdinalKey {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
pub fn ordinal_eq(left: &str, right: &str) -> bool {
    OrdinalKey::new(left).cmp(&OrdinalKey::new(right)) == Ordering::Equal
}
#[cfg(windows)]
#[link(name = "kernel32")]
unsafe extern "system" {
    fn CompareStringOrdinal(
        left: *const u16,
        left_length: i32,
        right: *const u16,
        right_length: i32,
        ignore_case: i32,
    ) -> i32;
}

pub const MAX_BYTES: usize = 128 * 1024 * 1024;
pub const MAX_KEYS: usize = 4096;
pub const MAX_VALUES: usize = 65536;
pub const MAX_DEPTH: usize = 128;

// System.Text.Jsonのbyte[]は配列ではなくBase64文字列。旧記録と同じwire形式を保つ。
pub(crate) mod bytes {
    use super::*;
    pub fn serialize<S: serde::Serializer>(value: &[u8], serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&STANDARD.encode(value))
    }
    pub fn deserialize<'de, D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> Result<Vec<u8>, D::Error> {
        let text = String::deserialize(deserializer)?;
        STANDARD.decode(text).map_err(serde::de::Error::custom)
    }
}
mod optional_bytes {
    use super::*;
    pub fn serialize<S: serde::Serializer>(
        value: &Option<Vec<u8>>,
        serializer: S,
    ) -> Result<S::Ok, S::Error> {
        match value {
            Some(bytes) => serializer.serialize_some(&STANDARD.encode(bytes)),
            None => serializer.serialize_none(),
        }
    }
    pub fn deserialize<'de, D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> Result<Option<Vec<u8>>, D::Error> {
        Option::<String>::deserialize(deserializer)?
            .map(|s| STANDARD.decode(s).map_err(serde::de::Error::custom))
            .transpose()
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Scope {
    pub kind: String,
    pub machine_id: String,
    pub owner_sid: String,
}
impl Scope {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.kind == "nativeWindows" && digest(&self.machine_id) && valid_sid(&self.owner_sid),
            "Registry scope identity is invalid."
        );
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Snapshot {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scope: Option<Scope>,
    pub schema: u32,
    pub path: String,
    pub view: String,
    pub value_name: Option<String>,
    pub keys: Vec<KeySnapshot>,
    pub value: Option<ValueSnapshot>,
    #[serde(with = "optional_bytes")]
    pub context_security: Option<Vec<u8>>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct KeySnapshot {
    pub relative_path: String,
    pub class: String,
    #[serde(with = "bytes")]
    pub security: Vec<u8>,
    pub last_write_file_time: i64,
    pub values: Vec<ValueSnapshot>,
}
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ValueSnapshot {
    pub name: String,
    pub r#type: u32,
    #[serde(with = "bytes")]
    pub data: Vec<u8>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Manifest {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scope: Option<Scope>,
    pub schema: u32,
    pub operation_id: String,
    pub created_utc: DateTime<FixedOffset>,
    pub metadata_root: String,
    pub owner_sid: String,
    pub path: String,
    pub view: String,
    pub value_name: Option<String>,
    pub kind: String,
    pub size: u64,
    pub sha256: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Receipt {
    pub schema: u32,
    pub operation_id: String,
    pub manifest_sha256: String,
    pub action: String,
    pub phase: String,
    pub created_utc: DateTime<FixedOffset>,
}

#[derive(Clone, Debug)]
pub struct Target {
    pub path: String,
    pub hive: String,
    pub segments: Vec<String>,
    pub view: String,
    pub value_name: Option<String>,
    pub access_mode: String,
}
impl Target {
    pub fn new(
        path: &str,
        view: &str,
        value_name: Option<String>,
        access_mode: &str,
    ) -> Result<Self> {
        ensure!(
            matches!(view, "32" | "64"),
            "Registry view must be explicitly 32 or 64."
        );
        ensure!(
            matches!(access_mode, "normal" | "backupRestore"),
            "Registry accessMode must be normal or backupRestore."
        );
        if access_mode == "backupRestore" {
            ensure!(
                view == "64" && cfg!(all(windows, target_pointer_width = "64")),
                "backupRestore requires view 64 in a 64-bit Windows process."
            );
        }
        validate_text(path, 32760, false)?;
        let mut path = path;
        for prefix in ["Microsoft.PowerShell.Core\\Registry::", "Registry::"] {
            if path
                .get(..prefix.len())
                .is_some_and(|s| s.eq_ignore_ascii_case(prefix))
            {
                path = &path[prefix.len()..];
                break;
            }
        }
        let (hive, tail) = path
            .split_once('\\')
            .context("Specify an absolute registry key below a supported hive.")?;
        let hive = match hive.to_ascii_uppercase().as_str() {
            "HKCU:" | "HKEY_CURRENT_USER" => "HKEY_CURRENT_USER",
            "HKLM:" | "HKEY_LOCAL_MACHINE" => "HKEY_LOCAL_MACHINE",
            "HKU:" | "HKEY_USERS" => "HKEY_USERS",
            _ => bail!("Only HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE and HKEY_USERS are supported."),
        }
        .to_string();
        let segments: Vec<String> = tail.split('\\').map(str::to_string).collect();
        ensure!(
            segments.len() <= MAX_DEPTH
                && segments.iter().all(|s| !s.is_empty()
                    && s.encode_utf16().count() <= 255
                    && !matches!(s.as_str(), "." | "..")
                    && !s.contains(['*', '?', '[', ']', '/'])),
            "Registry path contains an unsupported segment."
        );
        if let Some(name) = &value_name {
            validate_text(name, 16383, true)?;
        }
        Ok(Self {
            path: format!("{}\\{}", hive, segments.join("\\")),
            hive,
            segments,
            view: view.into(),
            value_name,
            access_mode: access_mode.into(),
        })
    }
    pub fn kind(&self) -> &'static str {
        if self.value_name.is_some() {
            "registry-value"
        } else {
            "registry-key"
        }
    }
}

pub fn validate_text(text: &str, maximum: usize, allow_empty: bool) -> Result<()> {
    ensure!(
        (allow_empty || !text.is_empty())
            && text.encode_utf16().count() <= maximum
            && !text.contains('\0'),
        "Registry text is empty, oversized or contains NUL."
    );
    Ok(())
}
pub fn digest(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
pub fn hash(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
pub fn operation_id(id: &str) -> Result<()> {
    ensure!(
        id.len() == 32
            && id
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            && uuid::Uuid::parse_str(id).is_ok(),
        "Invalid operation ID."
    );
    Ok(())
}
pub fn valid_sid(s: &str) -> bool {
    let pieces: Vec<_> = s.split('-').collect();
    pieces.len() >= 4
        && pieces.len() <= 18
        && pieces[0] == "S"
        && pieces[1] == "1"
        && pieces[2]
            .parse::<u64>()
            .is_ok_and(|n| n < 1u64 << 48 && n.to_string() == pieces[2])
        && pieces[3..]
            .iter()
            .all(|p| p.parse::<u32>().is_ok_and(|n| n.to_string() == *p))
}

// セキュリティ記述子をネイティブAPIへ渡す前に、可変offset/ACL/SIDの境界も検査する。
pub fn validate_security(bytes: &[u8]) -> Result<()> {
    ensure!(
        bytes.len() >= 20 && bytes.len() <= 1024 * 1024 && bytes[0] == 1,
        "Invalid registry security descriptor."
    );
    let control = u16::from_le_bytes([bytes[2], bytes[3]]);
    ensure!(
        control & 0x8000 != 0,
        "Registry security descriptor is not self-relative."
    );
    for index in [4, 8, 12, 16] {
        let offset = u32::from_le_bytes(bytes[index..index + 4].try_into().unwrap()) as usize;
        if offset == 0 {
            ensure!(
                index >= 12,
                "Registry security descriptor has no owner/group."
            );
            continue;
        }
        ensure!(
            offset >= 20 && offset % 4 == 0 && offset + 8 <= bytes.len(),
            "Invalid security descriptor offset."
        );
        if index < 12 {
            ensure!(
                bytes[offset] == 1
                    && bytes[offset + 1] <= 15
                    && offset + 8 + 4 * bytes[offset + 1] as usize <= bytes.len(),
                "Invalid security descriptor SID."
            );
        } else {
            let size = u16::from_le_bytes([bytes[offset + 2], bytes[offset + 3]]) as usize;
            let count = u16::from_le_bytes([bytes[offset + 4], bytes[offset + 5]]) as usize;
            ensure!(
                matches!(bytes[offset], 2 | 4) && size >= 8 && offset + size <= bytes.len(),
                "Invalid registry ACL."
            );
            let mut position = offset + 8;
            for _ in 0..count {
                ensure!(position + 4 <= offset + size, "Truncated registry ACE.");
                let length =
                    u16::from_le_bytes([bytes[position + 2], bytes[position + 3]]) as usize;
                ensure!(
                    length >= 4 && length % 4 == 0 && position + length <= offset + size,
                    "Invalid registry ACE."
                );
                position += length;
            }
        }
    }
    #[cfg(windows)]
    ensure!(
        unsafe { IsValidSecurityDescriptor(bytes.as_ptr()) } != 0,
        "Native security descriptor validation failed."
    );
    Ok(())
}
#[cfg(windows)]
#[link(name = "advapi32")]
unsafe extern "system" {
    fn IsValidSecurityDescriptor(bytes: *const u8) -> i32;
}

pub fn decode<T: DeserializeOwned + Serialize>(bytes: &[u8]) -> Result<T> {
    ensure!(
        !bytes.is_empty() && bytes.len() <= MAX_BYTES,
        "Registry metadata size is invalid."
    );
    let raw = crate::json::parse_unique(bytes)?;
    fn limits(value: &Value, depth: usize) -> Result<()> {
        match value {
            Value::Array(a) => {
                ensure!(depth < 16, "Registry metadata depth limit exceeded.");
                ensure!(
                    a.len() <= MAX_VALUES,
                    "Registry metadata has too many entries."
                );
                for x in a {
                    limits(x, depth + 1)?
                }
            }
            Value::Object(o) => {
                ensure!(depth < 16, "Registry metadata depth limit exceeded.");
                for x in o.values() {
                    limits(x, depth + 1)?
                }
            }
            _ => {}
        }
        Ok(())
    }
    limits(&raw, 0)?;
    // `raw`は後段のshape照合でも使うため、所有権を渡さず`&Value`をDeserializerとして読む。
    // 以前の`from_value(raw.clone())`は最大128 MiBのsnapshotでもValue木全体を毎回複製していた。
    let parsed: T = T::deserialize(&raw).context("Invalid registry metadata JSON")?;
    // Optionだけでは必須null項目の欠落を受理するため、C#同様に再構成したfield集合を再帰照合する。
    fn shape(actual: &Value, canonical: &Value) -> Result<()> {
        match canonical {
            Value::Object(o) => {
                let a = actual.as_object().context("Invalid registry object")?;
                ensure!(
                    a.len() == o.len(),
                    "Registry metadata is missing required fields."
                );
                for (k, v) in o {
                    shape(a.get(k).context("Missing registry field")?, v)?;
                }
            }
            Value::Array(o) => {
                let a = actual.as_array().context("Invalid registry array")?;
                ensure!(a.len() == o.len(), "Invalid registry array.");
                for (a, c) in a.iter().zip(o) {
                    shape(a, c)?;
                }
            }
            Value::Null => ensure!(actual.is_null(), "Invalid registry null field."),
            Value::Bool(_) => ensure!(actual.is_boolean(), "Invalid registry boolean field."),
            Value::Number(_) => ensure!(actual.is_number(), "Invalid registry numeric field."),
            Value::String(_) => ensure!(actual.is_string(), "Invalid registry string field."),
        }
        Ok(())
    }
    shape(&raw, &serde_json::to_value(&parsed)?)?;
    Ok(parsed)
}
pub fn decode_lifecycle<T: DeserializeOwned + Serialize>(bytes: &[u8]) -> Result<T> {
    ensure!(
        !bytes.is_empty() && bytes.len() <= 16 * 1024 * 1024,
        "Lifecycle metadata size is invalid."
    );
    let raw = crate::json::parse_unique(bytes)?;
    fn limits(value: &Value) -> Result<()> {
        match value {
            Value::Null => bail!("Lifecycle metadata contains null."),
            Value::String(s) => ensure!(
                s.encode_utf16().count() <= 32767,
                "Lifecycle metadata string is oversized."
            ),
            Value::Array(a) => {
                ensure!(a.len() <= 8192, "Lifecycle inventory is too large.");
                for x in a {
                    limits(x)?;
                }
            }
            Value::Object(o) => {
                for x in o.values() {
                    limits(x)?;
                }
            }
            _ => {}
        }
        Ok(())
    }
    limits(&raw)?;
    decode(bytes)
}

impl Manifest {
    pub fn validate(&self, id: &str, root: &str, sid: &str) -> Result<()> {
        operation_id(id)?;
        if let Some(scope) = &self.scope {
            scope.validate()?;
        }
        let target = Target::new(&self.path, &self.view, self.value_name.clone(), "normal")?;
        ensure!(
            self.schema == 5
                && self.operation_id == id
                && self.created_utc.timestamp() != -62135596800
                && self.metadata_root == root
                && self.owner_sid == sid
                && self.path == target.path
                && self.kind == target.kind()
                && self.size > 0
                && self.size <= MAX_BYTES as u64
                && digest(&self.sha256),
            "Registry manifest identity, target, owner, size or digest is invalid."
        );
        Ok(())
    }
}
impl Snapshot {
    pub fn validate(&self, manifest: &Manifest) -> Result<()> {
        if let Some(scope) = &self.scope {
            scope.validate()?;
        }
        ensure!(
            self.scope == manifest.scope
                && self.schema == 5
                && self.path == manifest.path
                && self.view == manifest.view
                && self.value_name == manifest.value_name
                && self.keys.len() <= MAX_KEYS,
            "Registry snapshot differs from its manifest."
        );
        if let Some(name) = &manifest.value_name {
            let value = self
                .value
                .as_ref()
                .context("Registry value snapshot is missing")?;
            ensure!(
                self.keys.is_empty() && value.name == *name,
                "Invalid registry value snapshot shape."
            );
            validate_security(
                self.context_security
                    .as_ref()
                    .context("Registry value security is missing")?,
            )?;
            return value.validate();
        }
        ensure!(
            !self.keys.is_empty()
                && self.keys[0].relative_path.is_empty()
                && self.value.is_none()
                && self.context_security.is_none(),
            "Invalid registry key snapshot shape."
        );
        let mut paths = BTreeSet::new();
        let mut count = 0;
        for key in &self.keys {
            validate_text(&key.relative_path, 32760, true)?;
            validate_text(&key.class, 32767, true)?;
            validate_security(&key.security)?;
            if !key.relative_path.is_empty() {
                let segments: Vec<_> = key.relative_path.split('\\').collect();
                ensure!(
                    segments.len() <= MAX_DEPTH
                        && segments.iter().all(|s| !s.is_empty()
                            && s.encode_utf16().count() <= 255
                            && !matches!(*s, "." | "..")),
                    "Invalid registry relative path."
                );
                let parent = key.relative_path.rsplit_once('\\').map_or("", |(p, _)| p);
                ensure!(
                    paths.contains(&OrdinalKey::new(parent)),
                    "Registry snapshot child has no preceding parent."
                );
            }
            ensure!(
                paths.insert(OrdinalKey::new(&key.relative_path)),
                "Duplicate registry snapshot key."
            );
            let mut names = BTreeSet::new();
            for value in &key.values {
                value.validate()?;
                count += 1;
                ensure!(
                    count <= MAX_VALUES && names.insert(OrdinalKey::new(&value.name)),
                    "Duplicate or excessive registry values."
                );
                ensure!(
                    !(value.name.eq_ignore_ascii_case("SymbolicLinkValue") && value.r#type == 6),
                    "Registry snapshot contains a registry link."
                );
            }
        }
        Ok(())
    }
    pub fn difference(&self, other: &Self) -> Option<String> {
        if self.keys.len() != other.keys.len() {
            return Some("key count".into());
        }
        if self.value != other.value {
            return Some("raw value bytes/type/name".into());
        }
        let nodes: BTreeMap<_, _> = other
            .keys
            .iter()
            .map(|k| (OrdinalKey::new(&k.relative_path), k))
            .collect();
        for key in &self.keys {
            let Some(found) = nodes.get(&OrdinalKey::new(&key.relative_path)) else {
                return Some("key name".into());
            };
            if key.relative_path != found.relative_path || key.class != found.class {
                return Some("key name/class".into());
            }
            if key.security != found.security {
                return Some("complete security bytes".into());
            }
            if key.values.len() != found.values.len() {
                return Some("value count".into());
            }
            let values: BTreeMap<_, _> = found
                .values
                .iter()
                .map(|v| (OrdinalKey::new(&v.name), v))
                .collect();
            if key.values.iter().any(|x| {
                values
                    .get(&OrdinalKey::new(&x.name))
                    .is_none_or(|found| *found != x)
            }) {
                return Some("raw values".into());
            }
        }
        None
    }
}
impl ValueSnapshot {
    pub fn validate(&self) -> Result<()> {
        validate_text(&self.name, 16383, true)?;
        ensure!(
            self.data.len() <= MAX_BYTES / 2,
            "Registry value data limit exceeded."
        );
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn value_snapshot() -> Vec<u8> {
        br#"{"schema":5,"path":"HKEY_CURRENT_USER\\Software\\Prunlet","view":"64","valueName":"","keys":[],"value":{"name":"","type":3,"data":"+/8="},"contextSecurity":"AQAA"}"#.to_vec()
    }
    #[test]
    fn schema5_byte_arrays_and_required_nulls() {
        let bytes = value_snapshot();
        let snapshot: Snapshot = decode(&bytes).unwrap();
        assert_eq!(snapshot.value.unwrap().data, [251, 255]);
        let mut value = crate::json::parse_unique(&bytes).unwrap();
        value.as_object_mut().unwrap().remove("valueName");
        assert!(decode::<Snapshot>(&serde_json::to_vec(&value).unwrap()).is_err());
        value["valueName"] = Value::Null;
        value["contextSecurity"] = Value::Null;
        value["value"] = Value::Null;
        let snapshot: Snapshot = decode(&serde_json::to_vec(&value).unwrap()).unwrap();
        assert!(snapshot.value_name.is_none() && snapshot.context_security.is_none());
    }
    #[test]
    fn duplicate_unknown_and_array_encoded_bytes_are_refused() {
        let duplicate = String::from_utf8(value_snapshot()).unwrap().replacen(
            "\"schema\":5",
            "\"schema\":5,\"schema\":5",
            1,
        );
        assert!(decode::<Snapshot>(duplicate.as_bytes()).is_err());
        let mut value = crate::json::parse_unique(&value_snapshot()).unwrap();
        value["extra"] = Value::Null;
        assert!(decode::<Snapshot>(&serde_json::to_vec(&value).unwrap()).is_err());
        value.as_object_mut().unwrap().remove("extra");
        value["value"]["data"] = serde_json::json!([251, 255]);
        assert!(decode::<Snapshot>(&serde_json::to_vec(&value).unwrap()).is_err());
    }
    #[test]
    fn hash_is_original_bytes_not_reencoded_json() {
        let bytes = value_snapshot();
        let canonical =
            serde_json::to_vec_pretty(&crate::json::parse_unique(&bytes).unwrap()).unwrap();
        assert_ne!(hash(&bytes), hash(&canonical));
    }
    #[test]
    fn target_requires_explicit_view_and_refuses_roots_or_ambiguous_names() {
        assert_eq!(
            Target::new(
                "Registry::HKCU:\\Software\\Prunlet",
                "64",
                Some(String::new()),
                "normal"
            )
            .unwrap()
            .path,
            "HKEY_CURRENT_USER\\Software\\Prunlet"
        );
        for path in [
            "HKEY_CURRENT_USER",
            "HKEY_CURRENT_USER\\",
            "HKEY_CURRENT_USER\\Software\\..",
            "HKEY_CURRENT_USER\\Software\\*",
            "HKEY_CLASSES_ROOT\\Prunlet",
        ] {
            assert!(Target::new(path, "64", None, "normal").is_err(), "{path}");
        }
        assert!(Target::new("HKEY_CURRENT_USER\\Software", "", None, "normal").is_err());
        assert!(Target::new("HKEY_CURRENT_USER\\Software", "32", None, "backupRestore").is_err());
    }
    #[test]
    fn relative_security_offsets_are_bounded_before_native_validation() {
        assert!(validate_security(&[0; 20]).is_err());
        let mut bytes = vec![0; 20];
        bytes[0] = 1;
        bytes[3] = 0x80;
        bytes[4..8].copy_from_slice(&u32::MAX.to_le_bytes());
        assert!(validate_security(&bytes).is_err());
    }
    #[test]
    fn ordinal_names_do_not_expand_sharp_s_into_two_letters() {
        assert!(!ordinal_eq("ß", "ss"));
        assert!(ordinal_eq("Prunlet", "PRUNLET"));
    }
}

use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

use anyhow::{Result, bail};
use serde::{
    Deserialize, Deserializer, Serialize,
    de::{self, MapAccess, Visitor},
};

#[derive(Clone, Debug)]
pub struct Config {
    pub path: PathBuf,
    pub data: ConfigData,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase", deny_unknown_fields)]
pub struct ConfigData {
    #[serde(deserialize_with = "web_u32")]
    pub schema: u32,
    #[serde(deserialize_with = "nullable_roots")]
    pub allowed_roots: Vec<String>,
    pub backup_directory: String,
    #[serde(deserialize_with = "web_u32")]
    pub retention_days: u32,
    #[serde(deserialize_with = "web_u64")]
    pub max_recovery_bytes: u64,
    #[serde(skip_serializing_if = "is_zero", deserialize_with = "web_u32")]
    pub capacity_default_migration_version: u32,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub volume_recovery_directories: BTreeMap<String, String>,
    #[serde(skip_serializing_if = "is_current")]
    pub registry_scope: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub registry_session_file: Option<String>,
}

fn is_zero(value: &u32) -> bool {
    *value == 0
}
fn is_current(value: &String) -> bool {
    value == "current"
}
fn nullable_roots<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<Vec<String>, D::Error> {
    Ok(Option::<Vec<String>>::deserialize(d)?.unwrap_or_default())
}

// JsonSerializerDefaults.Webの整数文字列入力も既存設定として受理する。
fn web_integer<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<u64, D::Error> {
    match serde_json::Value::deserialize(d)? {
        serde_json::Value::Number(n) => n
            .as_i64()
            .and_then(|v| u64::try_from(v).ok())
            .ok_or_else(|| de::Error::custom("Expected a nonnegative signed 64-bit integer.")),
        serde_json::Value::String(s)
            if !s.is_empty() && {
                let digits = s
                    .strip_prefix('+')
                    .or_else(|| s.strip_prefix('-'))
                    .unwrap_or(&s);
                !digits.is_empty() && digits.bytes().all(|c| c.is_ascii_digit())
            } =>
        {
            u64::try_from(s.parse::<i64>().map_err(de::Error::custom)?).map_err(de::Error::custom)
        }
        _ => Err(de::Error::custom("Expected an integer or integer string.")),
    }
}
fn web_u32<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<u32, D::Error> {
    u32::try_from(web_integer(d)?).map_err(de::Error::custom)
}
fn web_u64<'de, D: Deserializer<'de>>(d: D) -> std::result::Result<u64, D::Error> {
    web_integer(d)
}

impl Config {
    pub fn load(path: &Path) -> Result<Self> {
        let path = crate::platform::path::resolve(path, false, false)?;
        let bytes = crate::platform::read_plain_file(&path, usize::MAX, false)?;
        let text = configuration_text(&bytes)?;
        let mut decoder = serde_json::Deserializer::from_str(&text);
        let mut data = ConfigInput::deserialize(&mut decoder)?.0;
        decoder.end()?;
        data.validate_fields()?;
        data.backup_directory =
            crate::platform::path::resolve(Path::new(&data.backup_directory), false, false)?
                .into_os_string()
                .into_string()
                .map_err(|_| {
                    anyhow::anyhow!("Backup directory must be representable as a JSON string.")
                })?;
        let config = Self { path, data };
        crate::files::validate_config(&config)?;
        Ok(config)
    }
}

fn configuration_text(bytes: &[u8]) -> Result<String> {
    // File.ReadAllTextと同じBOM付きUTF-16/UTF-32設定を読み込む。
    if bytes.starts_with(b"\xff\xfe\0\0") || bytes.starts_with(b"\0\0\xfe\xff") {
        let little = bytes[0] == 0xff;
        let bytes = &bytes[4..];
        if bytes.len() % 4 != 0 {
            bail!("Invalid UTF-32 configuration.");
        }
        return bytes
            .chunks_exact(4)
            .map(|c| {
                let raw = <[u8; 4]>::try_from(c).unwrap();
                let n = if little {
                    u32::from_le_bytes(raw)
                } else {
                    u32::from_be_bytes(raw)
                };
                char::from_u32(n)
                    .ok_or_else(|| anyhow::anyhow!("Invalid UTF-32 configuration character."))
            })
            .collect();
    }
    if bytes.starts_with(b"\xff\xfe") || bytes.starts_with(b"\xfe\xff") {
        let little = bytes[0] == 0xff;
        let bytes = &bytes[2..];
        if bytes.len() % 2 != 0 {
            bail!("Invalid UTF-16 configuration.");
        }
        let words: Vec<_> = bytes
            .chunks_exact(2)
            .map(|c| {
                if little {
                    u16::from_le_bytes([c[0], c[1]])
                } else {
                    u16::from_be_bytes([c[0], c[1]])
                }
            })
            .collect();
        return Ok(String::from_utf16(&words)?);
    }
    Ok(std::str::from_utf8(bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(bytes))?.to_owned())
}

/// .NET Web既定のproperty名の大文字小文字非依存と、未知property拒否を維持する。
struct ConfigInput(ConfigData);
impl<'de> Deserialize<'de> for ConfigInput {
    fn deserialize<D: Deserializer<'de>>(d: D) -> std::result::Result<Self, D::Error> {
        struct ConfigVisitor;
        impl<'de> Visitor<'de> for ConfigVisitor {
            type Value = ConfigInput;
            fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("Prunlet configuration object")
            }
            fn visit_map<A: MapAccess<'de>>(
                self,
                mut a: A,
            ) -> std::result::Result<Self::Value, A::Error> {
                let mut map = serde_json::Map::new();
                while let Some((key, value)) = a.next_entry::<String, serde_json::Value>()? {
                    let canonical = match key.to_ascii_lowercase().as_str() {
                        "schema" => "schema",
                        "allowedroots" => "allowedRoots",
                        "backupdirectory" => "backupDirectory",
                        "retentiondays" => "retentionDays",
                        "maxrecoverybytes" => "maxRecoveryBytes",
                        "capacitydefaultmigrationversion" => "capacityDefaultMigrationVersion",
                        "volumerecoverydirectories" => "volumeRecoveryDirectories",
                        "registryscope" => "registryScope",
                        "registrysessionfile" => "registrySessionFile",
                        _ => {
                            return Err(de::Error::custom(format!(
                                "Unknown configuration property: {key}"
                            )));
                        }
                    };
                    map.insert(canonical.into(), value);
                }
                serde_json::from_value(serde_json::Value::Object(map))
                    .map(ConfigInput)
                    .map_err(de::Error::custom)
            }
        }
        d.deserialize_map(ConfigVisitor)
    }
}

impl Default for ConfigData {
    fn default() -> Self {
        Self {
            schema: 1,
            allowed_roots: Vec::new(),
            backup_directory: String::new(),
            retention_days: 7,
            max_recovery_bytes: 1 << 30,
            capacity_default_migration_version: 0,
            volume_recovery_directories: BTreeMap::new(),
            registry_scope: "current".into(),
            registry_session_file: None,
        }
    }
}

impl ConfigData {
    /// OS固有のパス・実体・ACL検証はplatform層で別に行う。
    pub fn validate_fields(&self) -> Result<()> {
        if self.schema != 1 {
            bail!("Unsupported configuration schema.");
        }
        if !(1..=36500).contains(&self.retention_days) {
            bail!("retentionDays must be between 1 and 36500.");
        }
        if self.max_recovery_bytes == 0 {
            bail!("maxRecoveryBytes must be positive.");
        }
        if self.max_recovery_bytes > i64::MAX as u64 {
            bail!("maxRecoveryBytes exceeds the supported signed 64-bit range.");
        }
        if self.capacity_default_migration_version > i32::MAX as u32 {
            bail!("capacityDefaultMigrationVersion exceeds the supported signed 32-bit range.");
        }
        if !matches!(self.registry_scope.as_str(), "current" | "nativeWindows") {
            bail!("registryScope must be current or nativeWindows.");
        }
        if self.registry_scope == "nativeWindows" && self.registry_session_file.is_none() {
            bail!("nativeWindows requires an absolute registrySessionFile.");
        }
        if let Some(path) = &self.registry_session_file {
            if crate::platform::path::absolute(Path::new(path))? != Path::new(path) {
                bail!("registrySessionFile must be a canonical absolute path.");
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decode(input: &str) -> Result<ConfigData> {
        let mut reader = serde_json::Deserializer::from_str(input);
        let data = ConfigInput::deserialize(&mut reader)?.0;
        reader.end()?;
        data.validate_fields()?;
        Ok(data)
    }

    #[test]
    fn existing_web_configuration_numbers_and_names() {
        let data = decode(r#"{"SCHEMA":"1","allowedRoots":null,"RetentionDays":"+7","maxRecoveryBytes":"1073741824","capacityDefaultMigrationVersion":"1"}"#).unwrap();
        assert!(data.allowed_roots.is_empty());
        assert_eq!(data.max_recovery_bytes, 1 << 30);
        assert_eq!(data.capacity_default_migration_version, 1);
        assert_eq!(
            decode(r#"{"retentionDays":1,"RETENTIONDAYS":2}"#)
                .unwrap()
                .retention_days,
            2
        );
    }

    #[test]
    fn invalid_existing_config_contract_is_rejected() {
        for input in [
            r#"{"unknown":true}"#,
            r#"{"schema":2}"#,
            r#"{"maxRecoveryBytes":"9223372036854775808"}"#,
            r#"{"capacityDefaultMigrationVersion":"2147483648"}"#,
            r#"{"retentionDays":"7.0"}"#,
            r#"{"maxRecoveryBytes":null}"#,
            r#"{"registryScope":"nativeWindows"}"#,
            r#"{"volumeRecoveryDirectories":null}"#,
        ] {
            assert!(decode(input).is_err(), "Unexpectedly accepted {input}");
        }
    }

    #[test]
    fn bom_encoded_existing_configuration_is_preserved() {
        let text = r#"{"backupDirectory":"日本語💕"}"#;
        for little in [false, true] {
            let mut utf16 = if little {
                vec![0xff, 0xfe]
            } else {
                vec![0xfe, 0xff]
            };
            for c in text.encode_utf16() {
                utf16.extend(if little {
                    c.to_le_bytes()
                } else {
                    c.to_be_bytes()
                });
            }
            assert_eq!(configuration_text(&utf16).unwrap(), text);
            let mut utf32 = if little {
                vec![0xff, 0xfe, 0, 0]
            } else {
                vec![0, 0, 0xfe, 0xff]
            };
            for c in text.chars() {
                utf32.extend(if little {
                    (c as u32).to_le_bytes()
                } else {
                    (c as u32).to_be_bytes()
                });
            }
            assert_eq!(configuration_text(&utf32).unwrap(), text);
        }
        assert!(configuration_text(&[0xff, 0xfe, 0x01]).is_err());
    }
}

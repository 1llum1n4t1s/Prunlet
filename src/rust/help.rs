// CLI のヘルプ（`prunlet`・`prunlet --help`・`prunlet help`）の英語原文と、その多言語表示。
//
// 英語の原文はここに固定し、辞書（`locales/<タグ>.json`）のキーにもそのまま使う。
// 翻訳は行単位で行い、`prunlet ` で始まる用法の行（コマンド・オプション・パス）は訳さず原文のまま出す。
// 英語では各行を en.json（原文→原文）で引くため、出力は従来の HELP 定数と完全に同じ文字列になる。
// 3OS 分の原文を常にコンパイルし、整合テストが全 OS の訳すべき行と辞書のキー集合を一度に照合できるようにする。
use crate::locale::{self, Language};

pub const LINUX: &str = r#"Prunlet — Linux freedesktop Trash.
prunlet --config <absolute-json-path> init --backup-directory <directory>
prunlet --config <absolute-json-path> validate-config
prunlet --config <absolute-json-path> delete [--dry-run] [--recursive] -- <absolute-path> [...]
prunlet --config <absolute-json-path> delete [--dry-run] [--recursive] --paths-file <absolute-json-file>
prunlet --config <absolute-json-path> mcp
prunlet --config <absolute-json-path> hook
"#;

pub const MACOS: &str = r#"Prunlet — Apple Silicon macOS Trash.
prunlet --install-macos <new absolute installation path>
prunlet --config <absolute-json-path> init --backup-directory <directory>
prunlet --config <absolute-json-path> validate-config
prunlet --config <absolute-json-path> delete [--dry-run] [--recursive] -- <absolute-path> [...]
prunlet --config <absolute-json-path> delete [--dry-run] [--recursive] --paths-file <absolute-json-file>
prunlet --config <absolute-json-path> delete-queue [--recursive] -- <absolute-path> [...]
prunlet --config <absolute-json-path> delete-queue-status <job-id>
prunlet --config <absolute-json-path> delete-queue-cancel <job-id>
prunlet --config <absolute-json-path> mcp
prunlet --config <absolute-json-path> hook
"#;

pub const WINDOWS: &str = r#"Prunlet — Windows Recycle Bin deletion and registry recovery.
prunlet --config <absolute-json-path> init --backup-directory <directory>
prunlet --config <absolute-json-path> validate-config
prunlet --config <absolute-json-path> delete [--dry-run] [--recursive] -- <absolute-path> [...]
prunlet --config <absolute-json-path> delete [--dry-run] [--recursive] --paths-file <absolute-json-file>
prunlet --config <absolute-json-path> delete-queue [--recursive] -- <absolute-path> [...]
prunlet --config <absolute-json-path> delete-queue [--recursive] --paths-file <absolute-json-file>
prunlet --config <absolute-json-path> delete-queue-status <job-id>
prunlet --config <absolute-json-path> delete-queue-cancel <job-id>
prunlet --config <absolute-json-path> registry-delete --view <32|64> [--access-mode <normal|backupRestore>] [--value-name <literal-name> | --value-name=] [--recursive] [--dry-run] -- <registry-key-path>
prunlet --config <absolute-json-path> registry-session --minutes <1..60> --assert-native-windows
prunlet --config <absolute-json-path> registry-reconcile <operation-id>
prunlet --config <absolute-json-path> registry-restore <operation-id> [--access-mode <normal|backupRestore>]
prunlet --config <absolute-json-path> restore <registry-operation-id> [--access-mode <normal|backupRestore>]
prunlet --config <absolute-json-path> purge <operation-id> [--dry-run | --apply]
prunlet --config <absolute-json-path> maintain [--dry-run | --apply] [--audit-records]
prunlet --config <absolute-json-path> operations
prunlet --config <absolute-json-path> migrate [--dry-run | --apply [--if-needed | --retry-legacy-discard]]
prunlet --config <absolute-json-path> mcp
prunlet --config <absolute-json-path> hook [--hook-script <legacy-path>]
prunlet update-apply [--no-maintenance]
prunlet update-check
prunlet setup status
prunlet setup repair
Setup (Velopack) installs only: update-apply applies a downloaded update at logon only when no Prunlet process is running and never stops a running process; setup repair redoes the installation steps.
Legacy --allowed-root <directory> options are accepted but do not restrict target directories.
Metadata and volume recovery directories are protected.
Files and folders normally move into the Windows Recycle Bin without Prunlet operation records.
An ordinary file with a Windows reserved final name is permanently deleted after identity checks, without using the bin.
Dry-run reports that case as would_permanently_delete. Reserved-name directories and links are rejected.
When Windows reports a file or folder too large for the bin, Prunlet attempts to permanently delete its confirmed original.
Only a confirmed removal returns permanently_deleted; an uncertain attempt returns ambiguous.
On a volume whose confirmed immediate-delete setting means the bin is unavailable, an item may also be permanently deleted after the same identity checks; its status is permanently_deleted, never recycled.
Other recycling failures do not trigger permanent deletion. Dry-run cannot predict an ordinary item's bin-size outcome.
Restore recycled items using Windows Recycle Bin; permanently deleted items cannot be restored there.
Registry snapshots retain the configured 7-day / 1 GiB defaults.
Maintain and purge manage registry recovery only; inspection is the default.
Migrate discards owned legacy file recovery data through Windows Recycle Bin; registry recovery stays protected.
After checking an interrupted discard, use migrate --apply --retry-legacy-discard to explicitly acknowledge retry.
Restore and registry-restore accept registry operation IDs and never overwrite existing keys or values.
Recycled hard links share content with surviving aliases.
For ambiguous file results, inspect the source and Windows Recycle Bin; do not resend deletion.
Empty directories are supported; deleting directory contents requires --recursive.
Wildcard expansion is unsupported. Links are deleted without following their targets.
Registry view is required. Omit value-name for a key; an empty value-name selects the default value.
Registry access defaults to normal. backupRestore is explicit per deletion/restoration, requires effective-token privileges, and supports only view 64 in a 64-bit Windows process.
Registry key snapshots require full Owner/Group/DACL/SACL access and SeSecurityPrivilege; no automatic elevation or fallback."#;

/// この OS 向けのヘルプ原文（英語）。
#[cfg(target_os = "linux")]
pub const CURRENT: &str = LINUX;
#[cfg(target_os = "macos")]
pub const CURRENT: &str = MACOS;
#[cfg(windows)]
pub const CURRENT: &str = WINDOWS;

/// 訳さない用法の行か。コマンド名・オプション・パスの表記は全言語で同じにする。
pub fn is_usage_line(line: &str) -> bool {
    line.starts_with("prunlet ")
}

/// 辞書で訳す行（用法の行と空行を除く）。整合テストが辞書のキー集合と照合する。
pub fn translatable_lines(text: &'static str) -> impl Iterator<Item = &'static str> {
    text.lines()
        .filter(|line| !line.is_empty() && !is_usage_line(line))
}

/// ヘルプを指定した言語で組み立てる。改行の位置と末尾の改行の有無は原文のまま保つ。
pub fn render(text: &'static str, language: Language) -> String {
    let mut output = String::with_capacity(text.len() * 2);
    for segment in text.split_inclusive('\n') {
        let (line, newline) = match segment.strip_suffix('\n') {
            Some(line) => (line, "\n"),
            None => (segment, ""),
        };
        if line.is_empty() || is_usage_line(line) {
            output.push_str(line);
        } else {
            output.push_str(locale::tr_in(language, line));
        }
        output.push_str(newline);
    }
    output
}

/// 現在の言語で、この OS 向けのヘルプを返す。言語判定はこの呼出しで初めて行う。
pub fn current() -> String {
    render(CURRENT, locale::current())
}

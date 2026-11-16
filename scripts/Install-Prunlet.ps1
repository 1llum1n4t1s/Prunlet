#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Repository = '1llum1n4t1s/Prunlet',
    [string]$InstallDirectory = (Join-Path $env:USERPROFILE '.local\Prunlet'),
    # 出荷済み呼出しの互換引数。対象フォルダーの制限には使わない。
    [string[]]$AllowedRoot,
    [string]$BackupDirectory,
    [string]$WorkDirectory,
    [string]$UpdateBackupRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Prunlet\Backups'),
    [ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64',
    [switch]$RegisterCodex,
    [switch]$RegisterAgentInstructions,
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
    [string]$SettingsBackupDirectory,
    [switch]$PrepareStartupUpdate,
    [switch]$UpdateManagedInstallation,
    [ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedCommitSha
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# 人が読む案内・エラー・警告を利用者の言語で出す（D:\Dev\APP-DISTRIBUTION.md「8. ローカライズ」と同じ規則）。
# 言語は PRUNLET_LANGUAGE → LC_ALL → LC_MESSAGES → LANG（空・C・POSIX は飛ばす）→ OS の表示言語 → 英語の順で決め、
# タグは zh-Hans/zh-CN/zh-SG → zh-CN、zh-Hant/zh-TW/zh-HK/zh-MO → zh-TW、pt-* → pt-BR、それ以外は主言語で照合する。
# キーは英語の原文で、英語・未対応の言語・辞書に無いキーでは原文をそのまま返す（従来の文言と完全に同じ）。
# 最終結果の JSON・バックアップの説明 JSON・CLI へ渡す値は機械可読なので、この関数を通さず英語のまま固定する。
# 検証スクリプトはこの関数だけを単独で読み込むことがあるため、辞書が無い・判定に失敗した場合も例外を出さず英語へ落とす
# （ErrorActionPreference=Stop の下で案内の表示が導入そのものを失敗させないため）。
function Format-PrunletMessage([string]$Text, [hashtable]$Values) {
    $message = $Text
    try {
        $tag = $null
        foreach ($source in @('PRUNLET_LANGUAGE', 'LC_ALL', 'LC_MESSAGES', 'LANG', '')) {
            # 最後の空の名前は OS の表示言語（Windows では利用者の UI 言語）を表す。
            $value = if ($source) { [Environment]::GetEnvironmentVariable($source) } else { [Globalization.CultureInfo]::CurrentUICulture.Name }
            $base = ([string]$value).Trim().Split([char[]]@('.', '@'))[0].ToLowerInvariant()
            if (!$base -or $base -ceq 'c' -or $base -ceq 'posix') { continue }
            $parts = @($base.Split([char[]]@('_', '-')))
            $primary = $parts[0]
            $tag = if ($primary -ceq 'ja' -or $primary -ceq 'japanese') { 'ja' }
                elseif ($primary -ceq 'zh') {
                    if ($parts -ccontains 'hant') { 'zh-TW' } elseif ($parts -ccontains 'hans') { 'zh-CN' }
                    elseif ($parts -ccontains 'tw' -or $parts -ccontains 'hk' -or $parts -ccontains 'mo') { 'zh-TW' } else { 'zh-CN' }
                }
                elseif ($primary.StartsWith('chinese', [StringComparison]::Ordinal)) { if ($base -match 'traditional|taiwan|hong kong|macao|macau') { 'zh-TW' } else { 'zh-CN' } }
                elseif ($primary -ceq 'ko' -or $primary -ceq 'korean') { 'ko' }
                elseif ($primary -ceq 'es' -or $primary -ceq 'spanish') { 'es' }
                elseif ($primary -ceq 'fr' -or $primary -ceq 'french') { 'fr' }
                elseif ($primary -ceq 'de' -or $primary -ceq 'german') { 'de' }
                elseif ($primary -ceq 'pt' -or $primary -ceq 'portuguese') { 'pt-BR' }
                else { 'en' }
            break
        }
        if ($tag -and $tag -cne 'en') {
            $table = $script:PrunletMessages
            if ($table -and $table.Contains($tag) -and $table[$tag].Contains($Text)) { $message = [string]$table[$tag][$Text] }
        }
    } catch { $message = $Text }
    if ($Values) {
        # {name} を一度だけ置き換える（値の中の波括弧は再展開しない）。
        $message = [regex]::Replace($message, '\{([a-z]+)\}', { param($match) if ($Values.ContainsKey($match.Groups[1].Value)) { [string]$Values[$match.Groups[1].Value] } else { $match.Value } })
    }
    return $message
}

# 英語以外の8言語の辞書（キーは英語の原文、値は訳文。プレースホルダーは全言語で同じ集合）。
# この区間は tests/localization.rs が抽出し、キー集合・プレースホルダー・コードが参照するキーを照合する。
# BEGIN PRUNLET INSTALLER MESSAGES
try {
    $script:PrunletMessages = ConvertFrom-Json -AsHashtable -InputObject @'
{
 "ja": {
  "{name} must be an absolute path.": "{name} は絶対パスで指定してください。",
  "{name} cannot be a filesystem root.": "{name} にファイルシステムのルートは使えません。",
  "{name} cannot traverse links: {path}": "{name} はリンクを経由できません: {path}",
  "{name} must be outside repositories and Codex home: {path}": "{name} はリポジトリと Codex ホームの外に置いてください: {path}",
  "{name} cannot be inside a repository: {path}": "{name} はリポジトリの中に置けません: {path}",
  "Directory ancestor is a file: {path}": "ディレクトリの祖先がファイルです: {path}",
  "Managed installation cannot use a source or Codex directory.": "管理された導入先には、ソースや Codex のディレクトリを使えません。",
  "Managed installation directories must already exist.": "管理された導入先のディレクトリは、あらかじめ存在している必要があります。",
  "Managed installation cannot be inside a source tree.": "管理された導入先はソースツリーの中に置けません。",
  "Managed update mode requires an existing installation inside Git.": "管理された更新モードには、Git の中にある既存の導入先が必要です。",
  "Nested Git repositories are unsupported for managed installation.": "管理された導入では、入れ子の Git リポジトリに対応していません。",
  "Managed installation requires the physical Git repository and index.": "管理された導入には、物理的な Git リポジトリとインデックスが必要です。",
  "Managed installation Git repository could not be verified.": "管理された導入先の Git リポジトリを確認できませんでした。",
  "Managed installation path must be Git-ignored or match its existing CLI registration.": "管理された導入先のパスは、Git の無視対象にするか、既存の CLI 登録と一致させてください。",
  "Managed installation path contains tracked files or an unverifiable index.": "管理された導入先のパスに、追跡されたファイルか確認できないインデックスがあります。",
  "Managed update requires an existing installation and configuration.": "管理された更新には、既存の導入先と設定が必要です。",
  "Managed installation metadata does not match the requested product.": "管理された導入先のメタデータが、要求した製品と一致しません。",
  "Managed recovery overlaps installed products.": "管理された復元データが導入済みの製品と重なっています。",
  "Managed installation product hash mismatch.": "管理された導入先の製品の hash が一致しません。",
  "Managed installation auxiliary hash mismatch.": "管理された導入先の補助ファイルの hash が一致しません。",
  "Unowned retired backend was preserved; managed update cannot replace it.": "所有していない廃止済みのバックエンドを保全しました。管理された更新ではこれを置き換えられません。",
  "Managed installation or recovery configuration changed; nothing was replaced.": "管理された導入先または復元データの設定が変わりました。何も置き換えていません。",
  "Managed recovery configuration changed; migration was not started.": "管理された復元データの設定が変わりました。移行は開始していません。",
  "Unexpected or duplicate package entry: {entry}": "配布物に想定外または重複したエントリがあります: {entry}",
  "Package links, directories, or special files are forbidden: {entry}": "配布物にリンク・ディレクトリ・特殊ファイルは含められません: {entry}",
  "Package entry size is invalid: {entry}": "配布物のエントリのサイズが不正です: {entry}",
  "Release package is missing required entries.": "release の配布物に必要なエントリが不足しています。",
  "Package metadata does not match the published release.": "配布物のメタデータが公開された release と一致しません。",
  "Package metadata is missing: {entry}": "配布物のメタデータがありません: {entry}",
  "Package metadata is invalid: {entry}": "配布物のメタデータが不正です: {entry}",
  "Package content differs from its metadata: {entry}": "配布物の内容がメタデータと異なります: {entry}",
  "The hook host must match the CLI binary.": "hook のホストは CLI と同じバイナリである必要があります。",
  "Package executable is not a PE file: {entry}": "配布物の実行ファイルが PE ファイルではありません: {entry}",
  "Package executable does not match {runtime}: {entry}": "配布物の実行ファイルが {runtime} と一致しません: {entry}",
  "Package executable is not signed by the Prunlet publisher (status {status}): {entry}": "配布物の実行ファイルが Prunlet の発行者によって署名されていません（状態 {status}）: {entry}",
  "Prunlet installation requires Windows and PowerShell 7.": "Prunlet の導入には Windows と PowerShell 7 が必要です。",
  "Startup preparation is not part of manual installation. Use the registered MCP startup entry to verify and prepare a published release package.": "起動時更新の準備は手動導入の一部ではありません。登録済みの MCP 起動エントリを使って、公開された release の配布物を検証・準備してください。",
  "RegisterAgentInstructions requires explicit -RegisterCodex.": "RegisterAgentInstructions には明示的な -RegisterCodex が必要です。",
  "Repository must be a GitHub owner/repository name.": "Repository には GitHub の owner/repository 名を指定してください。",
  "On Windows ARM64 explicitly choose -Runtime win-arm64 (or win-x64 for emulation).": "Windows ARM64 では -Runtime win-arm64（エミュレーションなら win-x64）を明示的に選んでください。",
  "Unsupported Windows architecture: {architecture}": "対応していない Windows のアーキテクチャです: {architecture}",
  "WorkDirectory and InstallDirectory must be separate trees.": "WorkDirectory と InstallDirectory は別々のツリーにしてください。",
  "WorkDirectory must be a new directory owned by this installation.": "WorkDirectory には、この導入が所有する新しいディレクトリを指定してください。",
  "InstallDirectory is a file.": "InstallDirectory がファイルです。",
  "WorkDirectory and recovery backup must be separate trees.": "WorkDirectory と復元データの保存先は別々のツリーにしてください。",
  "Update backup must be separate from install and work directories.": "更新のバックアップは導入先・作業用ディレクトリと別にしてください。",
  "Update backup must be separate from recovery data.": "更新のバックアップは復元データと別にしてください。",
  "Installed product path is a directory: {path}": "導入する製品のパスがディレクトリです: {path}",
  "Product files and recovery backup must be separate.": "製品ファイルと復元データの保存先は別にしてください。",
  "Another Prunlet installation is already running for this directory.": "このディレクトリには別の Prunlet の導入がすでに実行中です。",
  "A Prunlet update is in progress (phase: {phase}); nothing was installed. Let the update finish, then install again.": "Prunlet の更新が進行中です（phase: {phase}）。何も導入していません。更新が終わってから、もう一度導入してください。",
  "The latest release commit differs from ExpectedCommitSha; nothing was installed.": "最新の release の commit が ExpectedCommitSha と異なります。何も導入していません。",
  "Downloaded package differs from the published release asset; nothing was installed.": "ダウンロードした配布物が公開された release の asset と異なります。何も導入していません。",
  "Prunlet rejected the initial configuration.": "Prunlet が初期設定を拒否しました。",
  "Prunlet rejected the existing configuration; it was preserved.": "Prunlet が既存の設定を拒否しました。設定はそのまま保全しています。",
  "Update backup verification failed: {file}": "更新のバックアップの検証に失敗しました: {file}",
  "Installed file verification failed: {file}": "導入したファイルの検証に失敗しました: {file}",
  "Configuration must be a JSON object.": "設定は JSON のオブジェクトである必要があります。",
  "Prunlet rejected the migrated configuration; the original was preserved.": "Prunlet が移行後の設定を拒否しました。元の設定を保全しています。",
  "Configuration changed during capacity migration; it was preserved.": "容量上限の移行中に設定が変わりました。設定はそのまま保全しています。",
  "Codex configuration path is a directory: {path}": "Codex の設定パスがディレクトリです: {path}",
  "Prunlet could not retire the obsolete hook backend; recovery data was preserved.": "Prunlet は廃止済みの hook バックエンドを退役できませんでした。復元データは保全しています。",
  "Retired product recycling was not confirmed.": "退役した製品をごみ箱へ移したことを確認できませんでした。",
  "Recovery storage migration is incomplete. Installed products were retained; resume with the installed CLI migrate --apply.": "復元データの保存先の移行が完了していません。導入した製品は残しています。導入済みの CLI の migrate --apply で再開してください。",
  "Some legacy file recovery data was retained. Review the migration result before retrying migrate --apply; normal maintenance does not scan it.": "旧ファイル復元データの一部を保持しました。migrate --apply を再試行する前に移行結果を確認してください。通常の保守ではこれを走査しません。",
  "Installation reached recovery migration: {error}. The updated executables, configuration, and registrations were preserved; retry the installed CLI migrate --apply. Migration result: {result}": "導入は復元データの移行まで進みました: {error}。更新した実行ファイル・設定・登録は保全しています。導入済みの CLI で migrate --apply を再試行してください。移行結果: {result}",
  "Migrated configuration changed; it was preserved.": "移行後の設定が変わりました。設定はそのまま保全しています。",
  "Restored content hash differs from the preimage.": "復元した内容の hash が元の内容と異なります。",
  "Configuration path became a directory.": "設定のパスがディレクトリになりました。",
  "Installation failed: {error}. Installed products were retained because registration rollback failed. Recover registrations from {backup}: {details}": "導入に失敗しました: {error}。登録の巻き戻しに失敗したため、導入した製品は残しています。{backup} から登録を復旧してください: {details}",
  "New configuration was changed or replaced; it was preserved.": "新しい設定が変更または置き換えられていました。設定はそのまま保全しています。",
  "Installation failed: {error}. Rollback requires recovery from {backup}: {details}": "導入に失敗しました: {error}。巻き戻しには {backup} からの復旧が必要です: {details}",
  "Work directory contains links; automatic cleanup stopped.": "作業用ディレクトリにリンクがあるため、自動清掃を止めました。",
  "Temporary files retained at {path}: {error}": "一時ファイルを {path} に残しました: {error}",
  "The release manifest was rejected ({reason}); nothing was installed.": "リリースのマニフェストを拒否しました（{reason}）。何も導入していません。",
  "The release manifest could not be retrieved from {url}; nothing was installed.": "{url} からリリースのマニフェストを取得できませんでした。何も導入していません。",
  "The package could not be downloaded from {url}; nothing was installed.": "{url} から配布物をダウンロードできませんでした。何も導入していません。"
 },
 "zh-CN": {
  "{name} must be an absolute path.": "{name} 必须是绝对路径。",
  "{name} cannot be a filesystem root.": "{name} 不能是文件系统根目录。",
  "{name} cannot traverse links: {path}": "{name} 不能经过链接：{path}",
  "{name} must be outside repositories and Codex home: {path}": "{name} 必须位于仓库和 Codex 主目录之外：{path}",
  "{name} cannot be inside a repository: {path}": "{name} 不能位于仓库内：{path}",
  "Directory ancestor is a file: {path}": "目录的上级是一个文件：{path}",
  "Managed installation cannot use a source or Codex directory.": "托管安装不能使用源代码或 Codex 目录。",
  "Managed installation directories must already exist.": "托管安装的目录必须已经存在。",
  "Managed installation cannot be inside a source tree.": "托管安装不能位于源代码树内。",
  "Managed update mode requires an existing installation inside Git.": "托管更新模式需要位于 Git 内的现有安装。",
  "Nested Git repositories are unsupported for managed installation.": "托管安装不支持嵌套的 Git 仓库。",
  "Managed installation requires the physical Git repository and index.": "托管安装需要实际的 Git 仓库和索引。",
  "Managed installation Git repository could not be verified.": "无法验证托管安装的 Git 仓库。",
  "Managed installation path must be Git-ignored or match its existing CLI registration.": "托管安装路径必须被 Git 忽略，或与现有的 CLI 注册一致。",
  "Managed installation path contains tracked files or an unverifiable index.": "托管安装路径包含被跟踪的文件或无法验证的索引。",
  "Managed update requires an existing installation and configuration.": "托管更新需要现有的安装和配置。",
  "Managed installation metadata does not match the requested product.": "托管安装的元数据与请求的产品不匹配。",
  "Managed recovery overlaps installed products.": "托管的恢复数据与已安装的产品重叠。",
  "Managed installation product hash mismatch.": "托管安装的产品 hash 不匹配。",
  "Managed installation auxiliary hash mismatch.": "托管安装的辅助文件 hash 不匹配。",
  "Unowned retired backend was preserved; managed update cannot replace it.": "已保留不属于本安装的已停用后端；托管更新无法替换它。",
  "Managed installation or recovery configuration changed; nothing was replaced.": "托管安装或恢复配置已更改；未替换任何内容。",
  "Managed recovery configuration changed; migration was not started.": "托管的恢复配置已更改；未开始迁移。",
  "Unexpected or duplicate package entry: {entry}": "软件包中有意外或重复的条目：{entry}",
  "Package links, directories, or special files are forbidden: {entry}": "软件包中不允许链接、目录或特殊文件：{entry}",
  "Package entry size is invalid: {entry}": "软件包条目的大小无效：{entry}",
  "Release package is missing required entries.": "release 软件包缺少必需的条目。",
  "Package metadata does not match the published release.": "软件包元数据与已发布的 release 不匹配。",
  "Package metadata is missing: {entry}": "缺少软件包元数据：{entry}",
  "Package metadata is invalid: {entry}": "软件包元数据无效：{entry}",
  "Package content differs from its metadata: {entry}": "软件包内容与其元数据不一致：{entry}",
  "The hook host must match the CLI binary.": "hook 宿主必须与 CLI 二进制文件相同。",
  "Package executable is not a PE file: {entry}": "软件包中的可执行文件不是 PE 文件：{entry}",
  "Package executable does not match {runtime}: {entry}": "软件包中的可执行文件与 {runtime} 不匹配：{entry}",
  "Package executable is not signed by the Prunlet publisher (status {status}): {entry}": "软件包中的可执行文件未由 Prunlet 发布者签名（状态 {status}）：{entry}",
  "Prunlet installation requires Windows and PowerShell 7.": "安装 Prunlet 需要 Windows 和 PowerShell 7。",
  "Startup preparation is not part of manual installation. Use the registered MCP startup entry to verify and prepare a published release package.": "启动时更新的准备不属于手动安装。请使用已注册的 MCP 启动项来验证并准备已发布的 release 软件包。",
  "RegisterAgentInstructions requires explicit -RegisterCodex.": "RegisterAgentInstructions 需要显式指定 -RegisterCodex。",
  "Repository must be a GitHub owner/repository name.": "Repository 必须是 GitHub 的 owner/repository 名称。",
  "On Windows ARM64 explicitly choose -Runtime win-arm64 (or win-x64 for emulation).": "在 Windows ARM64 上请显式选择 -Runtime win-arm64（模拟运行则选 win-x64）。",
  "Unsupported Windows architecture: {architecture}": "不支持的 Windows 架构：{architecture}",
  "WorkDirectory and InstallDirectory must be separate trees.": "WorkDirectory 和 InstallDirectory 必须是互不包含的目录树。",
  "WorkDirectory must be a new directory owned by this installation.": "WorkDirectory 必须是由本次安装创建的新目录。",
  "InstallDirectory is a file.": "InstallDirectory 是一个文件。",
  "WorkDirectory and recovery backup must be separate trees.": "WorkDirectory 和恢复数据的备份位置必须是互不包含的目录树。",
  "Update backup must be separate from install and work directories.": "更新备份必须与安装目录和工作目录分开。",
  "Update backup must be separate from recovery data.": "更新备份必须与恢复数据分开。",
  "Installed product path is a directory: {path}": "要安装的产品路径是一个目录：{path}",
  "Product files and recovery backup must be separate.": "产品文件和恢复数据的备份位置必须分开。",
  "Another Prunlet installation is already running for this directory.": "此目录已有另一个 Prunlet 安装正在运行。",
  "A Prunlet update is in progress (phase: {phase}); nothing was installed. Let the update finish, then install again.": "Prunlet 更新正在进行中（phase：{phase}）；未安装任何内容。请等待更新完成后再安装。",
  "The latest release commit differs from ExpectedCommitSha; nothing was installed.": "最新 release 的 commit 与 ExpectedCommitSha 不同；未安装任何内容。",
  "Downloaded package differs from the published release asset; nothing was installed.": "下载的软件包与已发布的 release asset 不一致；未安装任何内容。",
  "Prunlet rejected the initial configuration.": "Prunlet 拒绝了初始配置。",
  "Prunlet rejected the existing configuration; it was preserved.": "Prunlet 拒绝了现有配置；配置已保留。",
  "Update backup verification failed: {file}": "更新备份验证失败：{file}",
  "Installed file verification failed: {file}": "已安装文件验证失败：{file}",
  "Configuration must be a JSON object.": "配置必须是 JSON 对象。",
  "Prunlet rejected the migrated configuration; the original was preserved.": "Prunlet 拒绝了迁移后的配置；已保留原始配置。",
  "Configuration changed during capacity migration; it was preserved.": "容量上限迁移期间配置已更改；配置已保留。",
  "Codex configuration path is a directory: {path}": "Codex 配置路径是一个目录：{path}",
  "Prunlet could not retire the obsolete hook backend; recovery data was preserved.": "Prunlet 无法停用过时的 hook 后端；恢复数据已保留。",
  "Retired product recycling was not confirmed.": "无法确认已停用的产品已移入回收站。",
  "Recovery storage migration is incomplete. Installed products were retained; resume with the installed CLI migrate --apply.": "恢复数据存储的迁移未完成。已保留安装的产品；请使用已安装 CLI 的 migrate --apply 继续。",
  "Some legacy file recovery data was retained. Review the migration result before retrying migrate --apply; normal maintenance does not scan it.": "部分旧版文件恢复数据已被保留。重试 migrate --apply 前请检查迁移结果；常规维护不会扫描这些数据。",
  "Installation reached recovery migration: {error}. The updated executables, configuration, and registrations were preserved; retry the installed CLI migrate --apply. Migration result: {result}": "安装已进行到恢复数据迁移：{error}。已保留更新后的可执行文件、配置和注册；请使用已安装的 CLI 重试 migrate --apply。迁移结果：{result}",
  "Migrated configuration changed; it was preserved.": "迁移后的配置已更改；配置已保留。",
  "Restored content hash differs from the preimage.": "恢复内容的 hash 与原始内容不一致。",
  "Configuration path became a directory.": "配置路径变成了目录。",
  "Installation failed: {error}. Installed products were retained because registration rollback failed. Recover registrations from {backup}: {details}": "安装失败：{error}。由于注册回滚失败，已保留安装的产品。请从 {backup} 恢复注册：{details}",
  "New configuration was changed or replaced; it was preserved.": "新配置已被更改或替换；配置已保留。",
  "Installation failed: {error}. Rollback requires recovery from {backup}: {details}": "安装失败：{error}。回滚需要从 {backup} 恢复：{details}",
  "Work directory contains links; automatic cleanup stopped.": "工作目录包含链接；已停止自动清理。",
  "Temporary files retained at {path}: {error}": "临时文件保留在 {path}：{error}",
  "The release manifest was rejected ({reason}); nothing was installed.": "已拒绝发布清单（{reason}）。未安装任何内容。",
  "The release manifest could not be retrieved from {url}; nothing was installed.": "无法从 {url} 获取发布清单。未安装任何内容。",
  "The package could not be downloaded from {url}; nothing was installed.": "无法从 {url} 下载软件包。未安装任何内容。"
 },
 "zh-TW": {
  "{name} must be an absolute path.": "{name} 必須是絕對路徑。",
  "{name} cannot be a filesystem root.": "{name} 不能是檔案系統根目錄。",
  "{name} cannot traverse links: {path}": "{name} 不能經過連結：{path}",
  "{name} must be outside repositories and Codex home: {path}": "{name} 必須位於存放庫和 Codex 主目錄之外：{path}",
  "{name} cannot be inside a repository: {path}": "{name} 不能位於存放庫內：{path}",
  "Directory ancestor is a file: {path}": "目錄的上層是一個檔案：{path}",
  "Managed installation cannot use a source or Codex directory.": "受管理的安裝不能使用原始碼或 Codex 目錄。",
  "Managed installation directories must already exist.": "受管理的安裝目錄必須已經存在。",
  "Managed installation cannot be inside a source tree.": "受管理的安裝不能位於原始碼樹內。",
  "Managed update mode requires an existing installation inside Git.": "受管理的更新模式需要位於 Git 內的現有安裝。",
  "Nested Git repositories are unsupported for managed installation.": "受管理的安裝不支援巢狀的 Git 存放庫。",
  "Managed installation requires the physical Git repository and index.": "受管理的安裝需要實際的 Git 存放庫和索引。",
  "Managed installation Git repository could not be verified.": "無法驗證受管理安裝的 Git 存放庫。",
  "Managed installation path must be Git-ignored or match its existing CLI registration.": "受管理的安裝路徑必須被 Git 忽略，或與現有的 CLI 註冊一致。",
  "Managed installation path contains tracked files or an unverifiable index.": "受管理的安裝路徑包含受追蹤的檔案或無法驗證的索引。",
  "Managed update requires an existing installation and configuration.": "受管理的更新需要現有的安裝和設定。",
  "Managed installation metadata does not match the requested product.": "受管理安裝的中繼資料與要求的產品不符。",
  "Managed recovery overlaps installed products.": "受管理的復原資料與已安裝的產品重疊。",
  "Managed installation product hash mismatch.": "受管理安裝的產品 hash 不符。",
  "Managed installation auxiliary hash mismatch.": "受管理安裝的輔助檔案 hash 不符。",
  "Unowned retired backend was preserved; managed update cannot replace it.": "已保留不屬於本安裝的已停用後端；受管理的更新無法取代它。",
  "Managed installation or recovery configuration changed; nothing was replaced.": "受管理的安裝或復原設定已變更；未取代任何內容。",
  "Managed recovery configuration changed; migration was not started.": "受管理的復原設定已變更；未開始移轉。",
  "Unexpected or duplicate package entry: {entry}": "套件中有非預期或重複的項目：{entry}",
  "Package links, directories, or special files are forbidden: {entry}": "套件中不允許連結、目錄或特殊檔案：{entry}",
  "Package entry size is invalid: {entry}": "套件項目的大小無效：{entry}",
  "Release package is missing required entries.": "release 套件缺少必要的項目。",
  "Package metadata does not match the published release.": "套件中繼資料與已發布的 release 不符。",
  "Package metadata is missing: {entry}": "缺少套件中繼資料：{entry}",
  "Package metadata is invalid: {entry}": "套件中繼資料無效：{entry}",
  "Package content differs from its metadata: {entry}": "套件內容與其中繼資料不一致：{entry}",
  "The hook host must match the CLI binary.": "hook 主機必須與 CLI 二進位檔相同。",
  "Package executable is not a PE file: {entry}": "套件中的執行檔不是 PE 檔案：{entry}",
  "Package executable does not match {runtime}: {entry}": "套件中的執行檔與 {runtime} 不符：{entry}",
  "Package executable is not signed by the Prunlet publisher (status {status}): {entry}": "套件中的執行檔未由 Prunlet 發行者簽署（狀態 {status}）：{entry}",
  "Prunlet installation requires Windows and PowerShell 7.": "安裝 Prunlet 需要 Windows 和 PowerShell 7。",
  "Startup preparation is not part of manual installation. Use the registered MCP startup entry to verify and prepare a published release package.": "啟動時更新的準備不屬於手動安裝。請使用已註冊的 MCP 啟動項目來驗證並準備已發布的 release 套件。",
  "RegisterAgentInstructions requires explicit -RegisterCodex.": "RegisterAgentInstructions 需要明確指定 -RegisterCodex。",
  "Repository must be a GitHub owner/repository name.": "Repository 必須是 GitHub 的 owner/repository 名稱。",
  "On Windows ARM64 explicitly choose -Runtime win-arm64 (or win-x64 for emulation).": "在 Windows ARM64 上請明確選擇 -Runtime win-arm64（模擬執行則選 win-x64）。",
  "Unsupported Windows architecture: {architecture}": "不支援的 Windows 架構：{architecture}",
  "WorkDirectory and InstallDirectory must be separate trees.": "WorkDirectory 和 InstallDirectory 必須是互不包含的目錄樹。",
  "WorkDirectory must be a new directory owned by this installation.": "WorkDirectory 必須是由本次安裝建立的新目錄。",
  "InstallDirectory is a file.": "InstallDirectory 是一個檔案。",
  "WorkDirectory and recovery backup must be separate trees.": "WorkDirectory 和復原資料的備份位置必須是互不包含的目錄樹。",
  "Update backup must be separate from install and work directories.": "更新備份必須與安裝目錄和工作目錄分開。",
  "Update backup must be separate from recovery data.": "更新備份必須與復原資料分開。",
  "Installed product path is a directory: {path}": "要安裝的產品路徑是一個目錄：{path}",
  "Product files and recovery backup must be separate.": "產品檔案和復原資料的備份位置必須分開。",
  "Another Prunlet installation is already running for this directory.": "此目錄已有另一個 Prunlet 安裝正在執行。",
  "A Prunlet update is in progress (phase: {phase}); nothing was installed. Let the update finish, then install again.": "Prunlet 更新正在進行中（phase：{phase}）；未安裝任何內容。請等待更新完成後再安裝。",
  "The latest release commit differs from ExpectedCommitSha; nothing was installed.": "最新 release 的 commit 與 ExpectedCommitSha 不同；未安裝任何內容。",
  "Downloaded package differs from the published release asset; nothing was installed.": "下載的套件與已發布的 release asset 不一致；未安裝任何內容。",
  "Prunlet rejected the initial configuration.": "Prunlet 拒絕了初始設定。",
  "Prunlet rejected the existing configuration; it was preserved.": "Prunlet 拒絕了現有設定；設定已保留。",
  "Update backup verification failed: {file}": "更新備份驗證失敗：{file}",
  "Installed file verification failed: {file}": "已安裝檔案驗證失敗：{file}",
  "Configuration must be a JSON object.": "設定必須是 JSON 物件。",
  "Prunlet rejected the migrated configuration; the original was preserved.": "Prunlet 拒絕了移轉後的設定；已保留原始設定。",
  "Configuration changed during capacity migration; it was preserved.": "容量上限移轉期間設定已變更；設定已保留。",
  "Codex configuration path is a directory: {path}": "Codex 設定路徑是一個目錄：{path}",
  "Prunlet could not retire the obsolete hook backend; recovery data was preserved.": "Prunlet 無法停用過時的 hook 後端；復原資料已保留。",
  "Retired product recycling was not confirmed.": "無法確認已停用的產品已移至資源回收筒。",
  "Recovery storage migration is incomplete. Installed products were retained; resume with the installed CLI migrate --apply.": "復原資料儲存區的移轉未完成。已保留安裝的產品；請使用已安裝 CLI 的 migrate --apply 繼續。",
  "Some legacy file recovery data was retained. Review the migration result before retrying migrate --apply; normal maintenance does not scan it.": "部分舊版檔案復原資料已被保留。重試 migrate --apply 前請檢查移轉結果；一般維護不會掃描這些資料。",
  "Installation reached recovery migration: {error}. The updated executables, configuration, and registrations were preserved; retry the installed CLI migrate --apply. Migration result: {result}": "安裝已進行到復原資料移轉：{error}。已保留更新後的執行檔、設定和註冊；請使用已安裝的 CLI 重試 migrate --apply。移轉結果：{result}",
  "Migrated configuration changed; it was preserved.": "移轉後的設定已變更；設定已保留。",
  "Restored content hash differs from the preimage.": "還原內容的 hash 與原始內容不一致。",
  "Configuration path became a directory.": "設定路徑變成了目錄。",
  "Installation failed: {error}. Installed products were retained because registration rollback failed. Recover registrations from {backup}: {details}": "安裝失敗：{error}。由於註冊回復失敗，已保留安裝的產品。請從 {backup} 復原註冊：{details}",
  "New configuration was changed or replaced; it was preserved.": "新設定已被變更或取代；設定已保留。",
  "Installation failed: {error}. Rollback requires recovery from {backup}: {details}": "安裝失敗：{error}。回復需要從 {backup} 復原：{details}",
  "Work directory contains links; automatic cleanup stopped.": "工作目錄包含連結；已停止自動清理。",
  "Temporary files retained at {path}: {error}": "暫存檔案保留在 {path}：{error}",
  "The release manifest was rejected ({reason}); nothing was installed.": "已拒絕發行資訊清單（{reason}）。未安裝任何內容。",
  "The release manifest could not be retrieved from {url}; nothing was installed.": "無法從 {url} 取得發行資訊清單。未安裝任何內容。",
  "The package could not be downloaded from {url}; nothing was installed.": "無法從 {url} 下載套件。未安裝任何內容。"
 },
 "ko": {
  "{name} must be an absolute path.": "{name}은(는) 절대 경로여야 합니다.",
  "{name} cannot be a filesystem root.": "{name}은(는) 파일 시스템 루트일 수 없습니다.",
  "{name} cannot traverse links: {path}": "{name}은(는) 링크를 거칠 수 없습니다: {path}",
  "{name} must be outside repositories and Codex home: {path}": "{name}은(는) 리포지토리와 Codex 홈 밖에 있어야 합니다: {path}",
  "{name} cannot be inside a repository: {path}": "{name}은(는) 리포지토리 안에 있을 수 없습니다: {path}",
  "Directory ancestor is a file: {path}": "디렉터리의 상위 항목이 파일입니다: {path}",
  "Managed installation cannot use a source or Codex directory.": "관리형 설치에는 소스 또는 Codex 디렉터리를 사용할 수 없습니다.",
  "Managed installation directories must already exist.": "관리형 설치 디렉터리는 이미 존재해야 합니다.",
  "Managed installation cannot be inside a source tree.": "관리형 설치는 소스 트리 안에 있을 수 없습니다.",
  "Managed update mode requires an existing installation inside Git.": "관리형 업데이트 모드에는 Git 안의 기존 설치가 필요합니다.",
  "Nested Git repositories are unsupported for managed installation.": "관리형 설치는 중첩된 Git 리포지토리를 지원하지 않습니다.",
  "Managed installation requires the physical Git repository and index.": "관리형 설치에는 실제 Git 리포지토리와 인덱스가 필요합니다.",
  "Managed installation Git repository could not be verified.": "관리형 설치의 Git 리포지토리를 확인할 수 없습니다.",
  "Managed installation path must be Git-ignored or match its existing CLI registration.": "관리형 설치 경로는 Git에서 무시되거나 기존 CLI 등록과 일치해야 합니다.",
  "Managed installation path contains tracked files or an unverifiable index.": "관리형 설치 경로에 추적되는 파일 또는 확인할 수 없는 인덱스가 있습니다.",
  "Managed update requires an existing installation and configuration.": "관리형 업데이트에는 기존 설치와 구성이 필요합니다.",
  "Managed installation metadata does not match the requested product.": "관리형 설치의 메타데이터가 요청한 제품과 일치하지 않습니다.",
  "Managed recovery overlaps installed products.": "관리형 복구 데이터가 설치된 제품과 겹칩니다.",
  "Managed installation product hash mismatch.": "관리형 설치의 제품 hash가 일치하지 않습니다.",
  "Managed installation auxiliary hash mismatch.": "관리형 설치의 보조 파일 hash가 일치하지 않습니다.",
  "Unowned retired backend was preserved; managed update cannot replace it.": "소유하지 않은 폐기된 백엔드를 보존했습니다. 관리형 업데이트로는 이를 교체할 수 없습니다.",
  "Managed installation or recovery configuration changed; nothing was replaced.": "관리형 설치 또는 복구 구성이 변경되었습니다. 아무것도 교체하지 않았습니다.",
  "Managed recovery configuration changed; migration was not started.": "관리형 복구 구성이 변경되었습니다. 마이그레이션을 시작하지 않았습니다.",
  "Unexpected or duplicate package entry: {entry}": "패키지에 예상치 못했거나 중복된 항목이 있습니다: {entry}",
  "Package links, directories, or special files are forbidden: {entry}": "패키지에는 링크, 디렉터리 또는 특수 파일을 포함할 수 없습니다: {entry}",
  "Package entry size is invalid: {entry}": "패키지 항목의 크기가 올바르지 않습니다: {entry}",
  "Release package is missing required entries.": "release 패키지에 필수 항목이 없습니다.",
  "Package metadata does not match the published release.": "패키지 메타데이터가 게시된 release와 일치하지 않습니다.",
  "Package metadata is missing: {entry}": "패키지 메타데이터가 없습니다: {entry}",
  "Package metadata is invalid: {entry}": "패키지 메타데이터가 올바르지 않습니다: {entry}",
  "Package content differs from its metadata: {entry}": "패키지 내용이 메타데이터와 다릅니다: {entry}",
  "The hook host must match the CLI binary.": "hook 호스트는 CLI 바이너리와 같아야 합니다.",
  "Package executable is not a PE file: {entry}": "패키지 실행 파일이 PE 파일이 아닙니다: {entry}",
  "Package executable does not match {runtime}: {entry}": "패키지 실행 파일이 {runtime}과(와) 일치하지 않습니다: {entry}",
  "Package executable is not signed by the Prunlet publisher (status {status}): {entry}": "패키지 실행 파일이 Prunlet 게시자의 서명을 받지 않았습니다(상태 {status}): {entry}",
  "Prunlet installation requires Windows and PowerShell 7.": "Prunlet을 설치하려면 Windows와 PowerShell 7이 필요합니다.",
  "Startup preparation is not part of manual installation. Use the registered MCP startup entry to verify and prepare a published release package.": "시작 시 업데이트 준비는 수동 설치에 포함되지 않습니다. 등록된 MCP 시작 항목을 사용하여 게시된 release 패키지를 확인하고 준비하십시오.",
  "RegisterAgentInstructions requires explicit -RegisterCodex.": "RegisterAgentInstructions에는 명시적인 -RegisterCodex가 필요합니다.",
  "Repository must be a GitHub owner/repository name.": "Repository는 GitHub owner/repository 이름이어야 합니다.",
  "On Windows ARM64 explicitly choose -Runtime win-arm64 (or win-x64 for emulation).": "Windows ARM64에서는 -Runtime win-arm64(에뮬레이션은 win-x64)를 명시적으로 선택하십시오.",
  "Unsupported Windows architecture: {architecture}": "지원되지 않는 Windows 아키텍처입니다: {architecture}",
  "WorkDirectory and InstallDirectory must be separate trees.": "WorkDirectory와 InstallDirectory는 서로 다른 트리여야 합니다.",
  "WorkDirectory must be a new directory owned by this installation.": "WorkDirectory는 이 설치가 소유하는 새 디렉터리여야 합니다.",
  "InstallDirectory is a file.": "InstallDirectory가 파일입니다.",
  "WorkDirectory and recovery backup must be separate trees.": "WorkDirectory와 복구 데이터 백업 위치는 서로 다른 트리여야 합니다.",
  "Update backup must be separate from install and work directories.": "업데이트 백업은 설치 디렉터리 및 작업 디렉터리와 분리되어야 합니다.",
  "Update backup must be separate from recovery data.": "업데이트 백업은 복구 데이터와 분리되어야 합니다.",
  "Installed product path is a directory: {path}": "설치할 제품 경로가 디렉터리입니다: {path}",
  "Product files and recovery backup must be separate.": "제품 파일과 복구 데이터 백업 위치는 분리되어야 합니다.",
  "Another Prunlet installation is already running for this directory.": "이 디렉터리에 대해 다른 Prunlet 설치가 이미 실행 중입니다.",
  "A Prunlet update is in progress (phase: {phase}); nothing was installed. Let the update finish, then install again.": "Prunlet 업데이트가 진행 중입니다(phase: {phase}). 아무것도 설치하지 않았습니다. 업데이트가 끝난 후 다시 설치하십시오.",
  "The latest release commit differs from ExpectedCommitSha; nothing was installed.": "최신 release commit이 ExpectedCommitSha와 다릅니다. 아무것도 설치하지 않았습니다.",
  "Downloaded package differs from the published release asset; nothing was installed.": "다운로드한 패키지가 게시된 release asset과 다릅니다. 아무것도 설치하지 않았습니다.",
  "Prunlet rejected the initial configuration.": "Prunlet이 초기 구성을 거부했습니다.",
  "Prunlet rejected the existing configuration; it was preserved.": "Prunlet이 기존 구성을 거부했습니다. 구성은 그대로 보존했습니다.",
  "Update backup verification failed: {file}": "업데이트 백업 확인에 실패했습니다: {file}",
  "Installed file verification failed: {file}": "설치된 파일 확인에 실패했습니다: {file}",
  "Configuration must be a JSON object.": "구성은 JSON 개체여야 합니다.",
  "Prunlet rejected the migrated configuration; the original was preserved.": "Prunlet이 마이그레이션된 구성을 거부했습니다. 원래 구성을 보존했습니다.",
  "Configuration changed during capacity migration; it was preserved.": "용량 한도 마이그레이션 중에 구성이 변경되었습니다. 구성은 그대로 보존했습니다.",
  "Codex configuration path is a directory: {path}": "Codex 구성 경로가 디렉터리입니다: {path}",
  "Prunlet could not retire the obsolete hook backend; recovery data was preserved.": "Prunlet이 폐기된 hook 백엔드를 정리하지 못했습니다. 복구 데이터는 보존했습니다.",
  "Retired product recycling was not confirmed.": "폐기된 제품이 휴지통으로 이동했는지 확인할 수 없습니다.",
  "Recovery storage migration is incomplete. Installed products were retained; resume with the installed CLI migrate --apply.": "복구 데이터 저장소 마이그레이션이 완료되지 않았습니다. 설치된 제품은 유지했습니다. 설치된 CLI의 migrate --apply로 다시 시작하십시오.",
  "Some legacy file recovery data was retained. Review the migration result before retrying migrate --apply; normal maintenance does not scan it.": "이전 파일 복구 데이터의 일부를 보존했습니다. migrate --apply를 다시 시도하기 전에 마이그레이션 결과를 확인하십시오. 일반 유지 관리는 이를 검사하지 않습니다.",
  "Installation reached recovery migration: {error}. The updated executables, configuration, and registrations were preserved; retry the installed CLI migrate --apply. Migration result: {result}": "설치가 복구 데이터 마이그레이션까지 진행되었습니다: {error}. 업데이트된 실행 파일, 구성, 등록은 보존했습니다. 설치된 CLI로 migrate --apply를 다시 시도하십시오. 마이그레이션 결과: {result}",
  "Migrated configuration changed; it was preserved.": "마이그레이션된 구성이 변경되었습니다. 구성은 그대로 보존했습니다.",
  "Restored content hash differs from the preimage.": "복원된 내용의 hash가 원래 내용과 다릅니다.",
  "Configuration path became a directory.": "구성 경로가 디렉터리가 되었습니다.",
  "Installation failed: {error}. Installed products were retained because registration rollback failed. Recover registrations from {backup}: {details}": "설치에 실패했습니다: {error}. 등록 롤백에 실패하여 설치된 제품은 유지했습니다. {backup}에서 등록을 복구하십시오: {details}",
  "New configuration was changed or replaced; it was preserved.": "새 구성이 변경되었거나 교체되었습니다. 구성은 그대로 보존했습니다.",
  "Installation failed: {error}. Rollback requires recovery from {backup}: {details}": "설치에 실패했습니다: {error}. 롤백하려면 {backup}에서 복구해야 합니다: {details}",
  "Work directory contains links; automatic cleanup stopped.": "작업 디렉터리에 링크가 있어 자동 정리를 중지했습니다.",
  "Temporary files retained at {path}: {error}": "임시 파일을 {path}에 남겼습니다: {error}",
  "The release manifest was rejected ({reason}); nothing was installed.": "릴리스 매니페스트를 거부했습니다({reason}). 아무것도 설치하지 않았습니다.",
  "The release manifest could not be retrieved from {url}; nothing was installed.": "{url}에서 릴리스 매니페스트를 가져올 수 없습니다. 아무것도 설치하지 않았습니다.",
  "The package could not be downloaded from {url}; nothing was installed.": "{url}에서 패키지를 다운로드할 수 없습니다. 아무것도 설치하지 않았습니다."
 },
 "es": {
  "{name} must be an absolute path.": "{name} debe ser una ruta absoluta.",
  "{name} cannot be a filesystem root.": "{name} no puede ser la raíz de un sistema de archivos.",
  "{name} cannot traverse links: {path}": "{name} no puede atravesar enlaces: {path}",
  "{name} must be outside repositories and Codex home: {path}": "{name} debe estar fuera de los repositorios y del directorio de Codex: {path}",
  "{name} cannot be inside a repository: {path}": "{name} no puede estar dentro de un repositorio: {path}",
  "Directory ancestor is a file: {path}": "Un antecesor del directorio es un archivo: {path}",
  "Managed installation cannot use a source or Codex directory.": "La instalación administrada no puede usar un directorio de código fuente ni de Codex.",
  "Managed installation directories must already exist.": "Los directorios de la instalación administrada ya deben existir.",
  "Managed installation cannot be inside a source tree.": "La instalación administrada no puede estar dentro de un árbol de código fuente.",
  "Managed update mode requires an existing installation inside Git.": "El modo de actualización administrada requiere una instalación existente dentro de Git.",
  "Nested Git repositories are unsupported for managed installation.": "La instalación administrada no admite repositorios Git anidados.",
  "Managed installation requires the physical Git repository and index.": "La instalación administrada requiere el repositorio Git y el índice físicos.",
  "Managed installation Git repository could not be verified.": "No se pudo verificar el repositorio Git de la instalación administrada.",
  "Managed installation path must be Git-ignored or match its existing CLI registration.": "La ruta de la instalación administrada debe estar ignorada por Git o coincidir con su registro de CLI existente.",
  "Managed installation path contains tracked files or an unverifiable index.": "La ruta de la instalación administrada contiene archivos con seguimiento o un índice no verificable.",
  "Managed update requires an existing installation and configuration.": "La actualización administrada requiere una instalación y una configuración existentes.",
  "Managed installation metadata does not match the requested product.": "Los metadatos de la instalación administrada no coinciden con el producto solicitado.",
  "Managed recovery overlaps installed products.": "La recuperación administrada se superpone con los productos instalados.",
  "Managed installation product hash mismatch.": "El hash de un producto de la instalación administrada no coincide.",
  "Managed installation auxiliary hash mismatch.": "El hash de un archivo auxiliar de la instalación administrada no coincide.",
  "Unowned retired backend was preserved; managed update cannot replace it.": "Se conservó un backend retirado que no es propio; la actualización administrada no puede reemplazarlo.",
  "Managed installation or recovery configuration changed; nothing was replaced.": "La configuración de la instalación administrada o de la recuperación cambió; no se reemplazó nada.",
  "Managed recovery configuration changed; migration was not started.": "La configuración de la recuperación administrada cambió; no se inició la migración.",
  "Unexpected or duplicate package entry: {entry}": "Entrada del paquete inesperada o duplicada: {entry}",
  "Package links, directories, or special files are forbidden: {entry}": "No se permiten enlaces, directorios ni archivos especiales en el paquete: {entry}",
  "Package entry size is invalid: {entry}": "El tamaño de la entrada del paquete no es válido: {entry}",
  "Release package is missing required entries.": "Al paquete de la release le faltan entradas obligatorias.",
  "Package metadata does not match the published release.": "Los metadatos del paquete no coinciden con la release publicada.",
  "Package metadata is missing: {entry}": "Faltan los metadatos del paquete: {entry}",
  "Package metadata is invalid: {entry}": "Los metadatos del paquete no son válidos: {entry}",
  "Package content differs from its metadata: {entry}": "El contenido del paquete difiere de sus metadatos: {entry}",
  "The hook host must match the CLI binary.": "El host del hook debe coincidir con el binario de la CLI.",
  "Package executable is not a PE file: {entry}": "El ejecutable del paquete no es un archivo PE: {entry}",
  "Package executable does not match {runtime}: {entry}": "El ejecutable del paquete no coincide con {runtime}: {entry}",
  "Package executable is not signed by the Prunlet publisher (status {status}): {entry}": "El ejecutable del paquete no está firmado por el editor de Prunlet (estado {status}): {entry}",
  "Prunlet installation requires Windows and PowerShell 7.": "La instalación de Prunlet requiere Windows y PowerShell 7.",
  "Startup preparation is not part of manual installation. Use the registered MCP startup entry to verify and prepare a published release package.": "La preparación de la actualización de inicio no forma parte de la instalación manual. Use la entrada de inicio MCP registrada para verificar y preparar un paquete de release publicado.",
  "RegisterAgentInstructions requires explicit -RegisterCodex.": "RegisterAgentInstructions requiere -RegisterCodex explícito.",
  "Repository must be a GitHub owner/repository name.": "Repository debe ser un nombre owner/repository de GitHub.",
  "On Windows ARM64 explicitly choose -Runtime win-arm64 (or win-x64 for emulation).": "En Windows ARM64 elija explícitamente -Runtime win-arm64 (o win-x64 para emulación).",
  "Unsupported Windows architecture: {architecture}": "Arquitectura de Windows no compatible: {architecture}",
  "WorkDirectory and InstallDirectory must be separate trees.": "WorkDirectory e InstallDirectory deben ser árboles separados.",
  "WorkDirectory must be a new directory owned by this installation.": "WorkDirectory debe ser un directorio nuevo propiedad de esta instalación.",
  "InstallDirectory is a file.": "InstallDirectory es un archivo.",
  "WorkDirectory and recovery backup must be separate trees.": "WorkDirectory y la copia de seguridad de recuperación deben ser árboles separados.",
  "Update backup must be separate from install and work directories.": "La copia de seguridad de actualización debe estar separada de los directorios de instalación y de trabajo.",
  "Update backup must be separate from recovery data.": "La copia de seguridad de actualización debe estar separada de los datos de recuperación.",
  "Installed product path is a directory: {path}": "La ruta del producto instalado es un directorio: {path}",
  "Product files and recovery backup must be separate.": "Los archivos del producto y la copia de seguridad de recuperación deben estar separados.",
  "Another Prunlet installation is already running for this directory.": "Ya hay otra instalación de Prunlet en ejecución para este directorio.",
  "A Prunlet update is in progress (phase: {phase}); nothing was installed. Let the update finish, then install again.": "Hay una actualización de Prunlet en curso (phase: {phase}); no se instaló nada. Deje que termine la actualización y vuelva a instalar.",
  "The latest release commit differs from ExpectedCommitSha; nothing was installed.": "El commit de la release más reciente difiere de ExpectedCommitSha; no se instaló nada.",
  "Downloaded package differs from the published release asset; nothing was installed.": "El paquete descargado difiere del asset de la release publicada; no se instaló nada.",
  "Prunlet rejected the initial configuration.": "Prunlet rechazó la configuración inicial.",
  "Prunlet rejected the existing configuration; it was preserved.": "Prunlet rechazó la configuración existente; se conservó.",
  "Update backup verification failed: {file}": "Falló la verificación de la copia de seguridad de actualización: {file}",
  "Installed file verification failed: {file}": "Falló la verificación del archivo instalado: {file}",
  "Configuration must be a JSON object.": "La configuración debe ser un objeto JSON.",
  "Prunlet rejected the migrated configuration; the original was preserved.": "Prunlet rechazó la configuración migrada; se conservó la original.",
  "Configuration changed during capacity migration; it was preserved.": "La configuración cambió durante la migración del límite de capacidad; se conservó.",
  "Codex configuration path is a directory: {path}": "La ruta de configuración de Codex es un directorio: {path}",
  "Prunlet could not retire the obsolete hook backend; recovery data was preserved.": "Prunlet no pudo retirar el backend de hook obsoleto; se conservaron los datos de recuperación.",
  "Retired product recycling was not confirmed.": "No se confirmó que el producto retirado se moviera a la papelera.",
  "Recovery storage migration is incomplete. Installed products were retained; resume with the installed CLI migrate --apply.": "La migración del almacenamiento de recuperación está incompleta. Se conservaron los productos instalados; reanude con migrate --apply de la CLI instalada.",
  "Some legacy file recovery data was retained. Review the migration result before retrying migrate --apply; normal maintenance does not scan it.": "Se conservaron algunos datos heredados de recuperación de archivos. Revise el resultado de la migración antes de reintentar migrate --apply; el mantenimiento normal no los examina.",
  "Installation reached recovery migration: {error}. The updated executables, configuration, and registrations were preserved; retry the installed CLI migrate --apply. Migration result: {result}": "La instalación llegó a la migración de recuperación: {error}. Se conservaron los ejecutables, la configuración y los registros actualizados; reintente migrate --apply con la CLI instalada. Resultado de la migración: {result}",
  "Migrated configuration changed; it was preserved.": "La configuración migrada cambió; se conservó.",
  "Restored content hash differs from the preimage.": "El hash del contenido restaurado difiere del original.",
  "Configuration path became a directory.": "La ruta de configuración se convirtió en un directorio.",
  "Installation failed: {error}. Installed products were retained because registration rollback failed. Recover registrations from {backup}: {details}": "La instalación falló: {error}. Se conservaron los productos instalados porque falló la reversión del registro. Recupere los registros desde {backup}: {details}",
  "New configuration was changed or replaced; it was preserved.": "La nueva configuración se cambió o reemplazó; se conservó.",
  "Installation failed: {error}. Rollback requires recovery from {backup}: {details}": "La instalación falló: {error}. La reversión requiere recuperar desde {backup}: {details}",
  "Work directory contains links; automatic cleanup stopped.": "El directorio de trabajo contiene enlaces; se detuvo la limpieza automática.",
  "Temporary files retained at {path}: {error}": "Se conservaron archivos temporales en {path}: {error}",
  "The release manifest was rejected ({reason}); nothing was installed.": "Se rechazó el manifiesto de la versión ({reason}); no se instaló nada.",
  "The release manifest could not be retrieved from {url}; nothing was installed.": "No se pudo obtener el manifiesto de la versión desde {url}; no se instaló nada.",
  "The package could not be downloaded from {url}; nothing was installed.": "No se pudo descargar el paquete desde {url}; no se instaló nada."
 },
 "fr": {
  "{name} must be an absolute path.": "{name} doit être un chemin absolu.",
  "{name} cannot be a filesystem root.": "{name} ne peut pas être la racine d'un système de fichiers.",
  "{name} cannot traverse links: {path}": "{name} ne peut pas traverser de liens : {path}",
  "{name} must be outside repositories and Codex home: {path}": "{name} doit se trouver hors des dépôts et du répertoire Codex : {path}",
  "{name} cannot be inside a repository: {path}": "{name} ne peut pas se trouver dans un dépôt : {path}",
  "Directory ancestor is a file: {path}": "Un ancêtre du répertoire est un fichier : {path}",
  "Managed installation cannot use a source or Codex directory.": "L'installation gérée ne peut pas utiliser un répertoire source ou Codex.",
  "Managed installation directories must already exist.": "Les répertoires de l'installation gérée doivent déjà exister.",
  "Managed installation cannot be inside a source tree.": "L'installation gérée ne peut pas se trouver dans une arborescence source.",
  "Managed update mode requires an existing installation inside Git.": "Le mode de mise à jour gérée nécessite une installation existante dans Git.",
  "Nested Git repositories are unsupported for managed installation.": "Les dépôts Git imbriqués ne sont pas pris en charge pour l'installation gérée.",
  "Managed installation requires the physical Git repository and index.": "L'installation gérée nécessite le dépôt Git et l'index physiques.",
  "Managed installation Git repository could not be verified.": "Impossible de vérifier le dépôt Git de l'installation gérée.",
  "Managed installation path must be Git-ignored or match its existing CLI registration.": "Le chemin de l'installation gérée doit être ignoré par Git ou correspondre à son enregistrement CLI existant.",
  "Managed installation path contains tracked files or an unverifiable index.": "Le chemin de l'installation gérée contient des fichiers suivis ou un index invérifiable.",
  "Managed update requires an existing installation and configuration.": "La mise à jour gérée nécessite une installation et une configuration existantes.",
  "Managed installation metadata does not match the requested product.": "Les métadonnées de l'installation gérée ne correspondent pas au produit demandé.",
  "Managed recovery overlaps installed products.": "La récupération gérée chevauche les produits installés.",
  "Managed installation product hash mismatch.": "Le hash d'un produit de l'installation gérée ne correspond pas.",
  "Managed installation auxiliary hash mismatch.": "Le hash d'un fichier auxiliaire de l'installation gérée ne correspond pas.",
  "Unowned retired backend was preserved; managed update cannot replace it.": "Un backend retiré non possédé a été conservé ; la mise à jour gérée ne peut pas le remplacer.",
  "Managed installation or recovery configuration changed; nothing was replaced.": "La configuration de l'installation gérée ou de la récupération a changé ; rien n'a été remplacé.",
  "Managed recovery configuration changed; migration was not started.": "La configuration de la récupération gérée a changé ; la migration n'a pas été lancée.",
  "Unexpected or duplicate package entry: {entry}": "Entrée de paquet inattendue ou en double : {entry}",
  "Package links, directories, or special files are forbidden: {entry}": "Les liens, répertoires et fichiers spéciaux sont interdits dans le paquet : {entry}",
  "Package entry size is invalid: {entry}": "La taille de l'entrée du paquet n'est pas valide : {entry}",
  "Release package is missing required entries.": "Il manque des entrées obligatoires dans le paquet de la release.",
  "Package metadata does not match the published release.": "Les métadonnées du paquet ne correspondent pas à la release publiée.",
  "Package metadata is missing: {entry}": "Métadonnées du paquet manquantes : {entry}",
  "Package metadata is invalid: {entry}": "Métadonnées du paquet non valides : {entry}",
  "Package content differs from its metadata: {entry}": "Le contenu du paquet diffère de ses métadonnées : {entry}",
  "The hook host must match the CLI binary.": "L'hôte du hook doit correspondre au binaire de la CLI.",
  "Package executable is not a PE file: {entry}": "L'exécutable du paquet n'est pas un fichier PE : {entry}",
  "Package executable does not match {runtime}: {entry}": "L'exécutable du paquet ne correspond pas à {runtime} : {entry}",
  "Package executable is not signed by the Prunlet publisher (status {status}): {entry}": "L'exécutable du paquet n'est pas signé par l'éditeur de Prunlet (état {status}) : {entry}",
  "Prunlet installation requires Windows and PowerShell 7.": "L'installation de Prunlet nécessite Windows et PowerShell 7.",
  "Startup preparation is not part of manual installation. Use the registered MCP startup entry to verify and prepare a published release package.": "La préparation de la mise à jour au démarrage ne fait pas partie de l'installation manuelle. Utilisez l'entrée de démarrage MCP enregistrée pour vérifier et préparer un paquet de release publié.",
  "RegisterAgentInstructions requires explicit -RegisterCodex.": "RegisterAgentInstructions nécessite -RegisterCodex explicite.",
  "Repository must be a GitHub owner/repository name.": "Repository doit être un nom owner/repository GitHub.",
  "On Windows ARM64 explicitly choose -Runtime win-arm64 (or win-x64 for emulation).": "Sous Windows ARM64, choisissez explicitement -Runtime win-arm64 (ou win-x64 pour l'émulation).",
  "Unsupported Windows architecture: {architecture}": "Architecture Windows non prise en charge : {architecture}",
  "WorkDirectory and InstallDirectory must be separate trees.": "WorkDirectory et InstallDirectory doivent être des arborescences séparées.",
  "WorkDirectory must be a new directory owned by this installation.": "WorkDirectory doit être un nouveau répertoire appartenant à cette installation.",
  "InstallDirectory is a file.": "InstallDirectory est un fichier.",
  "WorkDirectory and recovery backup must be separate trees.": "WorkDirectory et la sauvegarde de récupération doivent être des arborescences séparées.",
  "Update backup must be separate from install and work directories.": "La sauvegarde de mise à jour doit être séparée des répertoires d'installation et de travail.",
  "Update backup must be separate from recovery data.": "La sauvegarde de mise à jour doit être séparée des données de récupération.",
  "Installed product path is a directory: {path}": "Le chemin du produit installé est un répertoire : {path}",
  "Product files and recovery backup must be separate.": "Les fichiers du produit et la sauvegarde de récupération doivent être séparés.",
  "Another Prunlet installation is already running for this directory.": "Une autre installation de Prunlet est déjà en cours pour ce répertoire.",
  "A Prunlet update is in progress (phase: {phase}); nothing was installed. Let the update finish, then install again.": "Une mise à jour de Prunlet est en cours (phase : {phase}) ; rien n'a été installé. Laissez la mise à jour se terminer, puis réinstallez.",
  "The latest release commit differs from ExpectedCommitSha; nothing was installed.": "Le commit de la dernière release diffère d'ExpectedCommitSha ; rien n'a été installé.",
  "Downloaded package differs from the published release asset; nothing was installed.": "Le paquet téléchargé diffère de l'asset de la release publiée ; rien n'a été installé.",
  "Prunlet rejected the initial configuration.": "Prunlet a refusé la configuration initiale.",
  "Prunlet rejected the existing configuration; it was preserved.": "Prunlet a refusé la configuration existante ; elle a été conservée.",
  "Update backup verification failed: {file}": "Échec de la vérification de la sauvegarde de mise à jour : {file}",
  "Installed file verification failed: {file}": "Échec de la vérification du fichier installé : {file}",
  "Configuration must be a JSON object.": "La configuration doit être un objet JSON.",
  "Prunlet rejected the migrated configuration; the original was preserved.": "Prunlet a refusé la configuration migrée ; l'original a été conservé.",
  "Configuration changed during capacity migration; it was preserved.": "La configuration a changé pendant la migration de la limite de capacité ; elle a été conservée.",
  "Codex configuration path is a directory: {path}": "Le chemin de configuration de Codex est un répertoire : {path}",
  "Prunlet could not retire the obsolete hook backend; recovery data was preserved.": "Prunlet n'a pas pu retirer l'ancien backend de hook ; les données de récupération ont été conservées.",
  "Retired product recycling was not confirmed.": "La mise à la corbeille du produit retiré n'a pas été confirmée.",
  "Recovery storage migration is incomplete. Installed products were retained; resume with the installed CLI migrate --apply.": "La migration du stockage de récupération est incomplète. Les produits installés ont été conservés ; reprenez avec migrate --apply de la CLI installée.",
  "Some legacy file recovery data was retained. Review the migration result before retrying migrate --apply; normal maintenance does not scan it.": "Certaines anciennes données de récupération de fichiers ont été conservées. Examinez le résultat de la migration avant de réessayer migrate --apply ; la maintenance normale ne les analyse pas.",
  "Installation reached recovery migration: {error}. The updated executables, configuration, and registrations were preserved; retry the installed CLI migrate --apply. Migration result: {result}": "L'installation a atteint la migration de récupération : {error}. Les exécutables, la configuration et les enregistrements mis à jour ont été conservés ; réessayez migrate --apply avec la CLI installée. Résultat de la migration : {result}",
  "Migrated configuration changed; it was preserved.": "La configuration migrée a changé ; elle a été conservée.",
  "Restored content hash differs from the preimage.": "Le hash du contenu restauré diffère de l'original.",
  "Configuration path became a directory.": "Le chemin de configuration est devenu un répertoire.",
  "Installation failed: {error}. Installed products were retained because registration rollback failed. Recover registrations from {backup}: {details}": "Échec de l'installation : {error}. Les produits installés ont été conservés car l'annulation des enregistrements a échoué. Récupérez les enregistrements depuis {backup} : {details}",
  "New configuration was changed or replaced; it was preserved.": "La nouvelle configuration a été modifiée ou remplacée ; elle a été conservée.",
  "Installation failed: {error}. Rollback requires recovery from {backup}: {details}": "Échec de l'installation : {error}. L'annulation nécessite une récupération depuis {backup} : {details}",
  "Work directory contains links; automatic cleanup stopped.": "Le répertoire de travail contient des liens ; le nettoyage automatique a été arrêté.",
  "Temporary files retained at {path}: {error}": "Fichiers temporaires conservés dans {path} : {error}",
  "The release manifest was rejected ({reason}); nothing was installed.": "Le manifeste de la version a été refusé ({reason}) ; rien n'a été installé.",
  "The release manifest could not be retrieved from {url}; nothing was installed.": "Impossible de récupérer le manifeste de la version depuis {url} ; rien n'a été installé.",
  "The package could not be downloaded from {url}; nothing was installed.": "Impossible de télécharger le paquet depuis {url} ; rien n'a été installé."
 },
 "de": {
  "{name} must be an absolute path.": "{name} muss ein absoluter Pfad sein.",
  "{name} cannot be a filesystem root.": "{name} darf kein Dateisystemstamm sein.",
  "{name} cannot traverse links: {path}": "{name} darf keine Links durchlaufen: {path}",
  "{name} must be outside repositories and Codex home: {path}": "{name} muss außerhalb von Repositorys und des Codex-Verzeichnisses liegen: {path}",
  "{name} cannot be inside a repository: {path}": "{name} darf nicht in einem Repository liegen: {path}",
  "Directory ancestor is a file: {path}": "Ein übergeordnetes Element des Verzeichnisses ist eine Datei: {path}",
  "Managed installation cannot use a source or Codex directory.": "Die verwaltete Installation darf kein Quell- oder Codex-Verzeichnis verwenden.",
  "Managed installation directories must already exist.": "Die Verzeichnisse der verwalteten Installation müssen bereits vorhanden sein.",
  "Managed installation cannot be inside a source tree.": "Die verwaltete Installation darf nicht in einem Quellbaum liegen.",
  "Managed update mode requires an existing installation inside Git.": "Der verwaltete Aktualisierungsmodus erfordert eine vorhandene Installation innerhalb von Git.",
  "Nested Git repositories are unsupported for managed installation.": "Verschachtelte Git-Repositorys werden für die verwaltete Installation nicht unterstützt.",
  "Managed installation requires the physical Git repository and index.": "Die verwaltete Installation erfordert das physische Git-Repository und den Index.",
  "Managed installation Git repository could not be verified.": "Das Git-Repository der verwalteten Installation konnte nicht überprüft werden.",
  "Managed installation path must be Git-ignored or match its existing CLI registration.": "Der Pfad der verwalteten Installation muss von Git ignoriert werden oder mit ihrer vorhandenen CLI-Registrierung übereinstimmen.",
  "Managed installation path contains tracked files or an unverifiable index.": "Der Pfad der verwalteten Installation enthält nachverfolgte Dateien oder einen nicht überprüfbaren Index.",
  "Managed update requires an existing installation and configuration.": "Die verwaltete Aktualisierung erfordert eine vorhandene Installation und Konfiguration.",
  "Managed installation metadata does not match the requested product.": "Die Metadaten der verwalteten Installation stimmen nicht mit dem angeforderten Produkt überein.",
  "Managed recovery overlaps installed products.": "Die verwaltete Wiederherstellung überschneidet sich mit installierten Produkten.",
  "Managed installation product hash mismatch.": "Produkt-Hash der verwalteten Installation stimmt nicht überein.",
  "Managed installation auxiliary hash mismatch.": "Hash einer Hilfsdatei der verwalteten Installation stimmt nicht überein.",
  "Unowned retired backend was preserved; managed update cannot replace it.": "Ein nicht eigenes, eingestelltes Backend wurde beibehalten; die verwaltete Aktualisierung kann es nicht ersetzen.",
  "Managed installation or recovery configuration changed; nothing was replaced.": "Die Konfiguration der verwalteten Installation oder Wiederherstellung hat sich geändert; nichts wurde ersetzt.",
  "Managed recovery configuration changed; migration was not started.": "Die Konfiguration der verwalteten Wiederherstellung hat sich geändert; die Migration wurde nicht gestartet.",
  "Unexpected or duplicate package entry: {entry}": "Unerwarteter oder doppelter Paketeintrag: {entry}",
  "Package links, directories, or special files are forbidden: {entry}": "Links, Verzeichnisse oder Sonderdateien sind im Paket nicht zulässig: {entry}",
  "Package entry size is invalid: {entry}": "Die Größe des Paketeintrags ist ungültig: {entry}",
  "Release package is missing required entries.": "Im Release-Paket fehlen erforderliche Einträge.",
  "Package metadata does not match the published release.": "Die Paketmetadaten stimmen nicht mit dem veröffentlichten Release überein.",
  "Package metadata is missing: {entry}": "Paketmetadaten fehlen: {entry}",
  "Package metadata is invalid: {entry}": "Paketmetadaten sind ungültig: {entry}",
  "Package content differs from its metadata: {entry}": "Der Paketinhalt weicht von seinen Metadaten ab: {entry}",
  "The hook host must match the CLI binary.": "Der Hook-Host muss mit der CLI-Binärdatei übereinstimmen.",
  "Package executable is not a PE file: {entry}": "Die Programmdatei des Pakets ist keine PE-Datei: {entry}",
  "Package executable does not match {runtime}: {entry}": "Die Programmdatei des Pakets passt nicht zu {runtime}: {entry}",
  "Package executable is not signed by the Prunlet publisher (status {status}): {entry}": "Die Programmdatei des Pakets ist nicht vom Prunlet-Herausgeber signiert (Status {status}): {entry}",
  "Prunlet installation requires Windows and PowerShell 7.": "Für die Installation von Prunlet sind Windows und PowerShell 7 erforderlich.",
  "Startup preparation is not part of manual installation. Use the registered MCP startup entry to verify and prepare a published release package.": "Die Vorbereitung der Startaktualisierung ist nicht Teil der manuellen Installation. Verwenden Sie den registrierten MCP-Starteintrag, um ein veröffentlichtes Release-Paket zu überprüfen und vorzubereiten.",
  "RegisterAgentInstructions requires explicit -RegisterCodex.": "RegisterAgentInstructions erfordert ein explizites -RegisterCodex.",
  "Repository must be a GitHub owner/repository name.": "Repository muss ein GitHub-Name im Format owner/repository sein.",
  "On Windows ARM64 explicitly choose -Runtime win-arm64 (or win-x64 for emulation).": "Wählen Sie unter Windows ARM64 explizit -Runtime win-arm64 (oder win-x64 für die Emulation).",
  "Unsupported Windows architecture: {architecture}": "Nicht unterstützte Windows-Architektur: {architecture}",
  "WorkDirectory and InstallDirectory must be separate trees.": "WorkDirectory und InstallDirectory müssen getrennte Verzeichnisbäume sein.",
  "WorkDirectory must be a new directory owned by this installation.": "WorkDirectory muss ein neues Verzeichnis sein, das dieser Installation gehört.",
  "InstallDirectory is a file.": "InstallDirectory ist eine Datei.",
  "WorkDirectory and recovery backup must be separate trees.": "WorkDirectory und die Wiederherstellungssicherung müssen getrennte Verzeichnisbäume sein.",
  "Update backup must be separate from install and work directories.": "Die Aktualisierungssicherung muss von Installations- und Arbeitsverzeichnis getrennt sein.",
  "Update backup must be separate from recovery data.": "Die Aktualisierungssicherung muss von den Wiederherstellungsdaten getrennt sein.",
  "Installed product path is a directory: {path}": "Der Pfad des installierten Produkts ist ein Verzeichnis: {path}",
  "Product files and recovery backup must be separate.": "Produktdateien und Wiederherstellungssicherung müssen getrennt sein.",
  "Another Prunlet installation is already running for this directory.": "Für dieses Verzeichnis läuft bereits eine andere Prunlet-Installation.",
  "A Prunlet update is in progress (phase: {phase}); nothing was installed. Let the update finish, then install again.": "Eine Prunlet-Aktualisierung läuft (phase: {phase}); es wurde nichts installiert. Lassen Sie die Aktualisierung abschließen und installieren Sie dann erneut.",
  "The latest release commit differs from ExpectedCommitSha; nothing was installed.": "Der Commit des neuesten Release weicht von ExpectedCommitSha ab; es wurde nichts installiert.",
  "Downloaded package differs from the published release asset; nothing was installed.": "Das heruntergeladene Paket weicht vom Asset des veröffentlichten Release ab; es wurde nichts installiert.",
  "Prunlet rejected the initial configuration.": "Prunlet hat die Erstkonfiguration abgelehnt.",
  "Prunlet rejected the existing configuration; it was preserved.": "Prunlet hat die vorhandene Konfiguration abgelehnt; sie wurde beibehalten.",
  "Update backup verification failed: {file}": "Überprüfung der Aktualisierungssicherung fehlgeschlagen: {file}",
  "Installed file verification failed: {file}": "Überprüfung der installierten Datei fehlgeschlagen: {file}",
  "Configuration must be a JSON object.": "Die Konfiguration muss ein JSON-Objekt sein.",
  "Prunlet rejected the migrated configuration; the original was preserved.": "Prunlet hat die migrierte Konfiguration abgelehnt; das Original wurde beibehalten.",
  "Configuration changed during capacity migration; it was preserved.": "Die Konfiguration hat sich während der Migration der Kapazitätsgrenze geändert; sie wurde beibehalten.",
  "Codex configuration path is a directory: {path}": "Der Codex-Konfigurationspfad ist ein Verzeichnis: {path}",
  "Prunlet could not retire the obsolete hook backend; recovery data was preserved.": "Prunlet konnte das veraltete Hook-Backend nicht stilllegen; die Wiederherstellungsdaten wurden beibehalten.",
  "Retired product recycling was not confirmed.": "Das Verschieben des stillgelegten Produkts in den Papierkorb wurde nicht bestätigt.",
  "Recovery storage migration is incomplete. Installed products were retained; resume with the installed CLI migrate --apply.": "Die Migration des Wiederherstellungsspeichers ist unvollständig. Die installierten Produkte wurden beibehalten; setzen Sie mit migrate --apply der installierten CLI fort.",
  "Some legacy file recovery data was retained. Review the migration result before retrying migrate --apply; normal maintenance does not scan it.": "Einige veraltete Dateiwiederherstellungsdaten wurden beibehalten. Prüfen Sie das Migrationsergebnis, bevor Sie migrate --apply erneut ausführen; die normale Wartung durchsucht sie nicht.",
  "Installation reached recovery migration: {error}. The updated executables, configuration, and registrations were preserved; retry the installed CLI migrate --apply. Migration result: {result}": "Die Installation hat die Wiederherstellungsmigration erreicht: {error}. Die aktualisierten Programmdateien, Konfiguration und Registrierungen wurden beibehalten; führen Sie migrate --apply mit der installierten CLI erneut aus. Migrationsergebnis: {result}",
  "Migrated configuration changed; it was preserved.": "Die migrierte Konfiguration hat sich geändert; sie wurde beibehalten.",
  "Restored content hash differs from the preimage.": "Der Hash des wiederhergestellten Inhalts weicht vom Original ab.",
  "Configuration path became a directory.": "Der Konfigurationspfad ist zu einem Verzeichnis geworden.",
  "Installation failed: {error}. Installed products were retained because registration rollback failed. Recover registrations from {backup}: {details}": "Installation fehlgeschlagen: {error}. Die installierten Produkte wurden beibehalten, weil das Zurücksetzen der Registrierungen fehlgeschlagen ist. Stellen Sie die Registrierungen aus {backup} wieder her: {details}",
  "New configuration was changed or replaced; it was preserved.": "Die neue Konfiguration wurde geändert oder ersetzt; sie wurde beibehalten.",
  "Installation failed: {error}. Rollback requires recovery from {backup}: {details}": "Installation fehlgeschlagen: {error}. Das Zurücksetzen erfordert eine Wiederherstellung aus {backup}: {details}",
  "Work directory contains links; automatic cleanup stopped.": "Das Arbeitsverzeichnis enthält Links; die automatische Bereinigung wurde angehalten.",
  "Temporary files retained at {path}: {error}": "Temporäre Dateien wurden in {path} beibehalten: {error}",
  "The release manifest was rejected ({reason}); nothing was installed.": "Das Release-Manifest wurde abgelehnt ({reason}); es wurde nichts installiert.",
  "The release manifest could not be retrieved from {url}; nothing was installed.": "Das Release-Manifest konnte nicht von {url} abgerufen werden; es wurde nichts installiert.",
  "The package could not be downloaded from {url}; nothing was installed.": "Das Paket konnte nicht von {url} heruntergeladen werden; es wurde nichts installiert."
 },
 "pt-BR": {
  "{name} must be an absolute path.": "{name} deve ser um caminho absoluto.",
  "{name} cannot be a filesystem root.": "{name} não pode ser a raiz de um sistema de arquivos.",
  "{name} cannot traverse links: {path}": "{name} não pode atravessar links: {path}",
  "{name} must be outside repositories and Codex home: {path}": "{name} deve ficar fora de repositórios e do diretório do Codex: {path}",
  "{name} cannot be inside a repository: {path}": "{name} não pode ficar dentro de um repositório: {path}",
  "Directory ancestor is a file: {path}": "Um ancestral do diretório é um arquivo: {path}",
  "Managed installation cannot use a source or Codex directory.": "A instalação gerenciada não pode usar um diretório de código-fonte ou do Codex.",
  "Managed installation directories must already exist.": "Os diretórios da instalação gerenciada já devem existir.",
  "Managed installation cannot be inside a source tree.": "A instalação gerenciada não pode ficar dentro de uma árvore de código-fonte.",
  "Managed update mode requires an existing installation inside Git.": "O modo de atualização gerenciada requer uma instalação existente dentro do Git.",
  "Nested Git repositories are unsupported for managed installation.": "Repositórios Git aninhados não são suportados na instalação gerenciada.",
  "Managed installation requires the physical Git repository and index.": "A instalação gerenciada requer o repositório Git e o índice físicos.",
  "Managed installation Git repository could not be verified.": "Não foi possível verificar o repositório Git da instalação gerenciada.",
  "Managed installation path must be Git-ignored or match its existing CLI registration.": "O caminho da instalação gerenciada deve ser ignorado pelo Git ou corresponder ao seu registro de CLI existente.",
  "Managed installation path contains tracked files or an unverifiable index.": "O caminho da instalação gerenciada contém arquivos rastreados ou um índice não verificável.",
  "Managed update requires an existing installation and configuration.": "A atualização gerenciada requer uma instalação e uma configuração existentes.",
  "Managed installation metadata does not match the requested product.": "Os metadados da instalação gerenciada não correspondem ao produto solicitado.",
  "Managed recovery overlaps installed products.": "A recuperação gerenciada se sobrepõe aos produtos instalados.",
  "Managed installation product hash mismatch.": "O hash de um produto da instalação gerenciada não corresponde.",
  "Managed installation auxiliary hash mismatch.": "O hash de um arquivo auxiliar da instalação gerenciada não corresponde.",
  "Unowned retired backend was preserved; managed update cannot replace it.": "Um backend desativado que não é próprio foi preservado; a atualização gerenciada não pode substituí-lo.",
  "Managed installation or recovery configuration changed; nothing was replaced.": "A configuração da instalação gerenciada ou da recuperação mudou; nada foi substituído.",
  "Managed recovery configuration changed; migration was not started.": "A configuração da recuperação gerenciada mudou; a migração não foi iniciada.",
  "Unexpected or duplicate package entry: {entry}": "Entrada de pacote inesperada ou duplicada: {entry}",
  "Package links, directories, or special files are forbidden: {entry}": "Links, diretórios ou arquivos especiais não são permitidos no pacote: {entry}",
  "Package entry size is invalid: {entry}": "O tamanho da entrada do pacote é inválido: {entry}",
  "Release package is missing required entries.": "Faltam entradas obrigatórias no pacote da release.",
  "Package metadata does not match the published release.": "Os metadados do pacote não correspondem à release publicada.",
  "Package metadata is missing: {entry}": "Metadados do pacote ausentes: {entry}",
  "Package metadata is invalid: {entry}": "Metadados do pacote inválidos: {entry}",
  "Package content differs from its metadata: {entry}": "O conteúdo do pacote difere dos seus metadados: {entry}",
  "The hook host must match the CLI binary.": "O host do hook deve corresponder ao binário da CLI.",
  "Package executable is not a PE file: {entry}": "O executável do pacote não é um arquivo PE: {entry}",
  "Package executable does not match {runtime}: {entry}": "O executável do pacote não corresponde a {runtime}: {entry}",
  "Package executable is not signed by the Prunlet publisher (status {status}): {entry}": "O executável do pacote não está assinado pelo editor do Prunlet (status {status}): {entry}",
  "Prunlet installation requires Windows and PowerShell 7.": "A instalação do Prunlet requer Windows e PowerShell 7.",
  "Startup preparation is not part of manual installation. Use the registered MCP startup entry to verify and prepare a published release package.": "A preparação da atualização na inicialização não faz parte da instalação manual. Use a entrada de inicialização MCP registrada para verificar e preparar um pacote de release publicado.",
  "RegisterAgentInstructions requires explicit -RegisterCodex.": "RegisterAgentInstructions requer -RegisterCodex explícito.",
  "Repository must be a GitHub owner/repository name.": "Repository deve ser um nome owner/repository do GitHub.",
  "On Windows ARM64 explicitly choose -Runtime win-arm64 (or win-x64 for emulation).": "No Windows ARM64, escolha explicitamente -Runtime win-arm64 (ou win-x64 para emulação).",
  "Unsupported Windows architecture: {architecture}": "Arquitetura do Windows não suportada: {architecture}",
  "WorkDirectory and InstallDirectory must be separate trees.": "WorkDirectory e InstallDirectory devem ser árvores separadas.",
  "WorkDirectory must be a new directory owned by this installation.": "WorkDirectory deve ser um diretório novo pertencente a esta instalação.",
  "InstallDirectory is a file.": "InstallDirectory é um arquivo.",
  "WorkDirectory and recovery backup must be separate trees.": "WorkDirectory e o backup de recuperação devem ser árvores separadas.",
  "Update backup must be separate from install and work directories.": "O backup de atualização deve ficar separado dos diretórios de instalação e de trabalho.",
  "Update backup must be separate from recovery data.": "O backup de atualização deve ficar separado dos dados de recuperação.",
  "Installed product path is a directory: {path}": "O caminho do produto instalado é um diretório: {path}",
  "Product files and recovery backup must be separate.": "Os arquivos do produto e o backup de recuperação devem ficar separados.",
  "Another Prunlet installation is already running for this directory.": "Outra instalação do Prunlet já está em execução para este diretório.",
  "A Prunlet update is in progress (phase: {phase}); nothing was installed. Let the update finish, then install again.": "Uma atualização do Prunlet está em andamento (phase: {phase}); nada foi instalado. Deixe a atualização terminar e instale novamente.",
  "The latest release commit differs from ExpectedCommitSha; nothing was installed.": "O commit da release mais recente difere de ExpectedCommitSha; nada foi instalado.",
  "Downloaded package differs from the published release asset; nothing was installed.": "O pacote baixado difere do asset da release publicada; nada foi instalado.",
  "Prunlet rejected the initial configuration.": "O Prunlet rejeitou a configuração inicial.",
  "Prunlet rejected the existing configuration; it was preserved.": "O Prunlet rejeitou a configuração existente; ela foi preservada.",
  "Update backup verification failed: {file}": "Falha na verificação do backup de atualização: {file}",
  "Installed file verification failed: {file}": "Falha na verificação do arquivo instalado: {file}",
  "Configuration must be a JSON object.": "A configuração deve ser um objeto JSON.",
  "Prunlet rejected the migrated configuration; the original was preserved.": "O Prunlet rejeitou a configuração migrada; a original foi preservada.",
  "Configuration changed during capacity migration; it was preserved.": "A configuração mudou durante a migração do limite de capacidade; ela foi preservada.",
  "Codex configuration path is a directory: {path}": "O caminho de configuração do Codex é um diretório: {path}",
  "Prunlet could not retire the obsolete hook backend; recovery data was preserved.": "O Prunlet não conseguiu desativar o backend de hook obsoleto; os dados de recuperação foram preservados.",
  "Retired product recycling was not confirmed.": "Não foi confirmado que o produto desativado foi movido para a lixeira.",
  "Recovery storage migration is incomplete. Installed products were retained; resume with the installed CLI migrate --apply.": "A migração do armazenamento de recuperação está incompleta. Os produtos instalados foram mantidos; retome com migrate --apply da CLI instalada.",
  "Some legacy file recovery data was retained. Review the migration result before retrying migrate --apply; normal maintenance does not scan it.": "Alguns dados legados de recuperação de arquivos foram mantidos. Revise o resultado da migração antes de tentar migrate --apply novamente; a manutenção normal não os verifica.",
  "Installation reached recovery migration: {error}. The updated executables, configuration, and registrations were preserved; retry the installed CLI migrate --apply. Migration result: {result}": "A instalação chegou à migração de recuperação: {error}. Os executáveis, a configuração e os registros atualizados foram preservados; tente migrate --apply novamente com a CLI instalada. Resultado da migração: {result}",
  "Migrated configuration changed; it was preserved.": "A configuração migrada mudou; ela foi preservada.",
  "Restored content hash differs from the preimage.": "O hash do conteúdo restaurado difere do original.",
  "Configuration path became a directory.": "O caminho de configuração virou um diretório.",
  "Installation failed: {error}. Installed products were retained because registration rollback failed. Recover registrations from {backup}: {details}": "A instalação falhou: {error}. Os produtos instalados foram mantidos porque a reversão do registro falhou. Recupere os registros de {backup}: {details}",
  "New configuration was changed or replaced; it was preserved.": "A nova configuração foi alterada ou substituída; ela foi preservada.",
  "Installation failed: {error}. Rollback requires recovery from {backup}: {details}": "A instalação falhou: {error}. A reversão requer recuperação a partir de {backup}: {details}",
  "Work directory contains links; automatic cleanup stopped.": "O diretório de trabalho contém links; a limpeza automática foi interrompida.",
  "Temporary files retained at {path}: {error}": "Arquivos temporários mantidos em {path}: {error}",
  "The release manifest was rejected ({reason}); nothing was installed.": "O manifesto da versão foi rejeitado ({reason}); nada foi instalado.",
  "The release manifest could not be retrieved from {url}; nothing was installed.": "Não foi possível obter o manifesto da versão em {url}; nada foi instalado.",
  "The package could not be downloaded from {url}; nothing was installed.": "Não foi possível baixar o pacote de {url}; nada foi instalado."
 }
}
'@
} catch { $script:PrunletMessages = $null }
# END PRUNLET INSTALLER MESSAGES

# ---- 署名付きマニフェスト（更新・導入の信頼の基点） ----
# 目的: GitHub Release・タグ・compare APIを使わず、R2（https://prunlet.kagayoi.com）の署名付きマニフェストだけを
# 信頼の基点にする。固定の公開鍵で署名を検証し、payloadが指す配布物の名前・キー・長さ・SHA-256・版を確かめてから使う。
# 1つでも外れたら例外にして、呼出し元は何も適用しない（fail-closed）。
# 導入時の検証はこのインストーラー内で完結させる（配布物の12ファイル構成を変えないため共通ファイルにしない）。
# 起動時更新の launcher（integration/start-prunlet-mcp.ps1）は、検証を Rust の内部コマンド（__check-release-manifest 等）
# に任せるので、この区間を持たない。配信側の正本は scripts/PrunletRelease.Common.ps1 の
# Read-PrunletReleaseEnvelope で、ここはそれより厳しく、封筒・payloadとも正規形（キー順固定・compact・末尾改行なし）
# へ再直列化したバイト列と完全一致することを求める。
# 鍵整合の関門（scripts/Test-PrunletReleaseKeyGate.ps1）は、次の定数の行（識別子とbase64の文字列リテラルが同じ行）を
# 抽出して配信側の正本と照合する。このファイル内の定義はこの1か所だけにする（検証は写しのこの1行だけをテスト鍵へ置換する）。
$script:PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64 = 'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEMIbQQg1ZUrL1G3V5sKqnQm74bz087XUrB5+wnCXOfBnP8kREgm960J5b9S/fT0rUgopgPODpO9/PINkkCFhJbA=='
$script:PrunletReleaseKeyId = 'prunlet-release-1'
$script:PrunletReleaseOrigin = 'https://prunlet.kagayoi.com/'
$script:PrunletReleaseRepository = '1llum1n4t1s/Prunlet'
$script:PrunletReleaseEnvelopeMaxBytes = 16384

# マニフェストの拒否。理由は固定語彙だけにして、取得した本文・鍵の値を例外へ混ぜない。
function Stop-PrunletReleaseManifest([string]$Reason) {
    $failure = [InvalidOperationException]::new("Release manifest rejected: $Reason.")
    $failure.Data['PrunletReleaseManifestReason'] = $Reason
    throw $failure
}

# 署名対象と比べるための正規形。配信側（New-PrunletReleaseEnvelopeBytes / New-PrunletReleasePayloadBytes）と同じ
# Utf8JsonWriter・UnsafeRelaxedJsonEscaping・compactで書く（base64の + / を + 等へ逃がさない）。
function ConvertTo-PrunletReleaseCanonicalJson([scriptblock]$Write) {
    $stream = [IO.MemoryStream]::new()
    $options = [Text.Json.JsonWriterOptions]::new()
    $options.Encoder = [Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
    $options.Indented = $false
    $writer = [Text.Json.Utf8JsonWriter]::new($stream, $options)
    try {
        & $Write $writer
        $writer.Flush()
        return , $stream.ToArray()
    } finally { $writer.Dispose(); $stream.Dispose() }
}

# 厳密なUTF-8（BOMなし）のJSONオブジェクトを読み、プロパティを出現順のまま返す。
# 重複キー・順序違いは呼出し側が名前の並びの完全一致で拒否する。
function Read-PrunletReleaseJsonObject([byte[]]$Bytes, [string]$Reason) {
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { Stop-PrunletReleaseManifest $Reason }
    try {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($Bytes)
        $options = [Text.Json.JsonDocumentOptions]::new()
        $options.MaxDepth = 4; $options.AllowTrailingCommas = $false; $options.CommentHandling = [Text.Json.JsonCommentHandling]::Disallow
        $document = [Text.Json.JsonDocument]::Parse($text, $options)
    } catch { Stop-PrunletReleaseManifest $Reason }
    try {
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) { Stop-PrunletReleaseManifest $Reason }
        $names = [Collections.Generic.List[string]]::new()
        $values = @{}
        foreach ($property in $document.RootElement.EnumerateObject()) {
            $names.Add($property.Name)
            # 値は文書の破棄後も使えるよう複製する（JsonElement.Clone）。
            $values[$property.Name] = $property.Value.Clone()
        }
        return @{ names = $names.ToArray(); values = $values }
    } finally { $document.Dispose() }
}

function Get-PrunletReleaseJsonString($Values, [string]$Name, [string]$Reason) {
    $value = $Values[$Name]
    if ($value.ValueKind -ne [Text.Json.JsonValueKind]::String) { Stop-PrunletReleaseManifest $Reason }
    return $value.GetString()
}

# 封筒の取得結果（生バイト）を検証し、payloadの値を返す。
#   $Runtime: 自分のruntime（win-x64 / win-arm64）。payloadのruntime・固定asset名・キーの組立てに使う。
#   $Repository: 導入元として指定・記録されたrepository。公式（$script:PrunletReleaseRepository）以外は不一致で止める。
#   $Version: 版を指定した取得（manifests/<版>/<runtime>.json）では、その版と一致することも求める。
function Read-PrunletReleaseManifest([byte[]]$Bytes, [string]$Runtime, [string]$Repository, [string]$Version = '') {
    switch -CaseSensitive ($Runtime) {
        'win-x64' { $assetName = 'prunlet-update-win-x64.zip'; $maxBytes = [long]536870912 }
        'win-arm64' { $assetName = 'prunlet-update-win-arm64.zip'; $maxBytes = [long]536870912 }
        default { Stop-PrunletReleaseManifest 'unsupported-runtime' }
    }
    if ($null -eq $Bytes -or $Bytes.Length -lt 2 -or $Bytes.Length -gt $script:PrunletReleaseEnvelopeMaxBytes) { Stop-PrunletReleaseManifest 'envelope-size' }
    # 封筒: キーは schema, keyId, payload, signature の4つだけをこの順で（重複・追加・順序違いは名前の並びで拒否）。
    $envelope = Read-PrunletReleaseJsonObject $Bytes 'envelope-malformed'
    if (($envelope.names -join ',') -cne 'schema,keyId,payload,signature') { Stop-PrunletReleaseManifest 'envelope-keys' }
    $schema = $envelope.values['schema']
    if ($schema.ValueKind -ne [Text.Json.JsonValueKind]::Number -or $schema.GetRawText() -cne '1') { Stop-PrunletReleaseManifest 'envelope-schema' }
    $keyId = Get-PrunletReleaseJsonString $envelope.values 'keyId' 'envelope-malformed'
    $payloadText = Get-PrunletReleaseJsonString $envelope.values 'payload' 'envelope-malformed'
    $signatureText = Get-PrunletReleaseJsonString $envelope.values 'signature' 'envelope-malformed'
    if ($keyId -cne $script:PrunletReleaseKeyId) { Stop-PrunletReleaseManifest 'unknown-key-id' }
    # base64は標準・パディング付きで、再エンコードが元の文字列と一致する正規形だけを受け付ける（空白・改行も拒否）。
    try {
        $payload = [Convert]::FromBase64String($payloadText)
        $signature = [Convert]::FromBase64String($signatureText)
    } catch { Stop-PrunletReleaseManifest 'invalid-base64' }
    if ([Convert]::ToBase64String($payload) -cne $payloadText -or [Convert]::ToBase64String($signature) -cne $signatureText) { Stop-PrunletReleaseManifest 'invalid-base64' }
    # 封筒全体が正規形（compact・キー順固定・末尾改行なし）と完全一致すること。
    $canonicalEnvelope = ConvertTo-PrunletReleaseCanonicalJson {
        param($writer)
        $writer.WriteStartObject()
        $writer.WriteNumber('schema', [long]1)
        $writer.WriteString('keyId', $keyId)
        $writer.WriteString('payload', $payloadText)
        $writer.WriteString('signature', $signatureText)
        $writer.WriteEndObject()
    }
    if (![Linq.Enumerable]::SequenceEqual([byte[]]$canonicalEnvelope, [byte[]]$Bytes)) { Stop-PrunletReleaseManifest 'envelope-not-canonical' }
    # 署名はRFC 3279のDER（SEQUENCE{INTEGER r, INTEGER s}）だけ。r||sの64バイト形式はDERとして読めないので検証で落ちるが、
    # 形の段階でも明示的に拒否する（P-256のDER署名は8〜72バイト。SEQUENCEの長さが全体と一致し、2つのINTEGERが
    # 1〜33バイトで隙間なく並ぶこと。乱数の64バイトが偶然この形になることは実質ない）。
    $derValid = $signature.Length -ge 8 -and $signature.Length -le 72 -and $signature[0] -eq 0x30 -and $signature[1] -eq ($signature.Length - 2)
    $offset = 2
    for ($part = 0; $derValid -and $part -lt 2; $part++) {
        if ($offset + 2 -gt $signature.Length -or $signature[$offset] -ne 0x02) { $derValid = $false; break }
        $partLength = [int]$signature[$offset + 1]
        if ($partLength -lt 1 -or $partLength -gt 33) { $derValid = $false; break }
        $offset += 2 + $partLength
    }
    if (!$derValid -or $offset -ne $signature.Length) { Stop-PrunletReleaseManifest 'signature-format' }
    $ecdsa = [Security.Cryptography.ECDsa]::Create()
    try {
        try {
            $spki = [Convert]::FromBase64String($script:PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64)
            $read = 0
            $ecdsa.ImportSubjectPublicKeyInfo($spki, [ref]$read)
            if ($read -ne $spki.Length -or $ecdsa.KeySize -ne 256 -or $ecdsa.ExportParameters($false).Curve.Oid.Value -cne '1.2.840.10045.3.1.7') { throw 'not P-256' }
        } catch { Stop-PrunletReleaseManifest 'invalid-public-key' }
        $valid = $false
        try { $valid = $ecdsa.VerifyData($payload, $signature, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.DSASignatureFormat]::Rfc3279DerSequence) } catch { $valid = $false }
    } finally { $ecdsa.Dispose() }
    if (!$valid) { Stop-PrunletReleaseManifest 'signature-verification-failed' }

    # payload: 署名済みのバイト列を、キー集合・順序・型・形式まで厳密に読む。
    $document = Read-PrunletReleaseJsonObject $payload 'payload-malformed'
    if (($document.names -join ',') -cne 'schema,product,repository,runtime,version,commit,defaultBranch,asset') { Stop-PrunletReleaseManifest 'payload-keys' }
    $values = $document.values
    if ($values['schema'].ValueKind -ne [Text.Json.JsonValueKind]::Number -or $values['schema'].GetRawText() -cne '1') { Stop-PrunletReleaseManifest 'payload-schema' }
    $product = Get-PrunletReleaseJsonString $values 'product' 'payload-malformed'
    $payloadRepository = Get-PrunletReleaseJsonString $values 'repository' 'payload-malformed'
    $payloadRuntime = Get-PrunletReleaseJsonString $values 'runtime' 'payload-malformed'
    $payloadVersion = Get-PrunletReleaseJsonString $values 'version' 'payload-malformed'
    $commit = Get-PrunletReleaseJsonString $values 'commit' 'payload-malformed'
    $branch = Get-PrunletReleaseJsonString $values 'defaultBranch' 'payload-malformed'
    $asset = $values['asset']
    if ($asset.ValueKind -ne [Text.Json.JsonValueKind]::Object) { Stop-PrunletReleaseManifest 'payload-malformed' }
    $assetNames = [Collections.Generic.List[string]]::new()
    $assetValues = @{}
    foreach ($property in $asset.EnumerateObject()) { $assetNames.Add($property.Name); $assetValues[$property.Name] = $property.Value }
    if (($assetNames -join ',') -cne 'name,key,bytes,sha256') { Stop-PrunletReleaseManifest 'payload-keys' }
    $name = Get-PrunletReleaseJsonString $assetValues 'name' 'payload-malformed'
    $key = Get-PrunletReleaseJsonString $assetValues 'key' 'payload-malformed'
    $sha256 = Get-PrunletReleaseJsonString $assetValues 'sha256' 'payload-malformed'
    $length = [long]0
    if ($assetValues['bytes'].ValueKind -ne [Text.Json.JsonValueKind]::Number -or !$assetValues['bytes'].TryGetInt64([ref]$length)) { Stop-PrunletReleaseManifest 'payload-malformed' }
    # payloadも正規形と完全一致すること（数値の表記ゆれ・空白・キー順をここで止める）。
    $canonicalPayload = ConvertTo-PrunletReleaseCanonicalJson {
        param($writer)
        $writer.WriteStartObject()
        $writer.WriteNumber('schema', [long]1)
        $writer.WriteString('product', $product)
        $writer.WriteString('repository', $payloadRepository)
        $writer.WriteString('runtime', $payloadRuntime)
        $writer.WriteString('version', $payloadVersion)
        $writer.WriteString('commit', $commit)
        $writer.WriteString('defaultBranch', $branch)
        $writer.WriteStartObject('asset')
        $writer.WriteString('name', $name)
        $writer.WriteString('key', $key)
        $writer.WriteNumber('bytes', $length)
        $writer.WriteString('sha256', $sha256)
        $writer.WriteEndObject()
        $writer.WriteEndObject()
    }
    if (![Linq.Enumerable]::SequenceEqual([byte[]]$canonicalPayload, [byte[]]$payload)) { Stop-PrunletReleaseManifest 'payload-not-canonical' }
    # 値の照合。製品・公式repository・自分のruntime・固定asset名・自分で組み立てたキーとの完全一致・上限。
    if ($product -cne 'Prunlet') { Stop-PrunletReleaseManifest 'product-mismatch' }
    if ($payloadRepository -cne $script:PrunletReleaseRepository -or ![string]::Equals($Repository, $script:PrunletReleaseRepository, [StringComparison]::OrdinalIgnoreCase)) { Stop-PrunletReleaseManifest 'repository-mismatch' }
    if ($payloadRuntime -cne $Runtime) { Stop-PrunletReleaseManifest 'runtime-mismatch' }
    if ($payloadVersion -cnotmatch '\A(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\z') { Stop-PrunletReleaseManifest 'invalid-version' }
    if ($Version -and $payloadVersion -cne $Version) { Stop-PrunletReleaseManifest 'version-mismatch' }
    if ($commit -cnotmatch '\A[0-9a-f]{40}\z') { Stop-PrunletReleaseManifest 'invalid-commit' }
    if ($branch -cnotmatch '\A[A-Za-z0-9._/-]+\z' -or $branch.Contains('..') -or $branch.StartsWith('/') -or $branch.EndsWith('/')) { Stop-PrunletReleaseManifest 'invalid-branch' }
    if ($name -cne $assetName) { Stop-PrunletReleaseManifest 'asset-name-mismatch' }
    if ($sha256 -cnotmatch '\A[0-9a-f]{64}\z') { Stop-PrunletReleaseManifest 'invalid-sha256' }
    if ($length -le 0 -or $length -gt $maxBytes) { Stop-PrunletReleaseManifest 'asset-length' }
    $expectedKey = 'releases/' + $script:PrunletReleaseRepository.ToLowerInvariant() + '/' + $commit + '/' + $Runtime + '/' + $sha256 + '.zip'
    if ($key -cne $expectedKey) { Stop-PrunletReleaseManifest 'asset-key-mismatch' }
    return [ordered]@{
        version = $payloadVersion; versionValue = [version]$payloadVersion; commit = $commit; branch = $branch
        assetName = $name; assetKey = $key; assetBytes = $length; assetSha256 = $sha256; downloadUrl = ($script:PrunletReleaseOrigin + $key)
    }
}

# R2の公開オブジェクトを生バイトで取得する。リダイレクトは追わず（-MaximumRedirection 0）、200以外・上限超えは拒否する。
# 取得はInvoke-WebRequestだけで行う（検証スクリプトが同名の関数でfixtureの応答へ置き換えるため。HttpClientを直接使わない）。
function Get-PrunletReleaseObject([string]$Key, [long]$MaxBytes, [int]$TimeoutSec) {
    if ($Key -cnotmatch '\A(latest/[a-z0-9-]+\.json|manifests/[0-9]+\.[0-9]+\.[0-9]+/[a-z0-9-]+\.json)\z') { Stop-PrunletReleaseManifest 'invalid-object-key' }
    $response = Invoke-WebRequest -Uri ($script:PrunletReleaseOrigin + $Key) -Headers @{ 'User-Agent' = 'Prunlet-Latest-Installer' } -MaximumRedirection 0 -TimeoutSec $TimeoutSec
    if ($null -eq $response -or [int]$response.StatusCode -ne 200 -or $null -eq $response.RawContentStream) { Stop-PrunletReleaseManifest 'unexpected-response' }
    $bytes = $response.RawContentStream.ToArray()
    if ($bytes.Length -gt $MaxBytes) { Stop-PrunletReleaseManifest 'envelope-size' }
    return , $bytes
}
# ---- 署名付きマニフェストここまで ----
function Test-InTree([string]$Path, [string]$Root) {
    $Path.Equals($Root, [StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($Root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}
function Assert-PlainPath([string]$Path, [string]$Name) {
    if (![IO.Path]::IsPathFullyQualified($Path)) { throw (Format-PrunletMessage '{name} must be an absolute path.' @{ name = $Name }) }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if (!$full -or $full -eq [IO.Path]::GetPathRoot($Path).TrimEnd('\', '/')) { throw (Format-PrunletMessage '{name} cannot be a filesystem root.' @{ name = $Name }) }
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw (Format-PrunletMessage '{name} cannot traverse links: {path}' @{ name = $Name; path = $cursor }) }
        }
        $cursor = Split-Path -Parent $cursor
    }
    return $full
}
function Assert-ExternalPath([string]$Path, [string]$Name) {
    $full = Assert-PlainPath $Path $Name
    foreach ($forbidden in $script:ForbiddenRoots) {
        if (Test-InTree $full $forbidden) { throw (Format-PrunletMessage '{name} must be outside repositories and Codex home: {path}' @{ name = $Name; path = $full }) }
    }
    $cursor = $full
    while ($cursor) {
        if ((Test-Path -LiteralPath (Join-Path $cursor '.git')) -or (Test-Path -LiteralPath (Join-Path $cursor 'Cargo.toml')) -or (Test-Path -LiteralPath (Join-Path $cursor 'src\Prunlet\Prunlet.csproj'))) { throw (Format-PrunletMessage '{name} cannot be inside a repository: {path}' @{ name = $Name; path = $full }) }
        $cursor = Split-Path -Parent $cursor
    }
    return $full
}
function New-TrackedDirectory([string]$Path) {
    $full = Assert-ExternalPath $Path 'Installation directory'
    $missing = [Collections.Generic.List[string]]::new()
    $cursor = $full
    while (!(Test-Path -LiteralPath $cursor)) {
        $missing.Add($cursor)
        $cursor = Split-Path -Parent $cursor
    }
    if (!(Test-Path -LiteralPath $cursor -PathType Container)) { throw (Format-PrunletMessage 'Directory ancestor is a file: {path}' @{ path = $cursor }) }
    for ($index = $missing.Count - 1; $index -ge 0; $index--) {
        $directory = $missing[$index]
        if (Test-Path -LiteralPath $directory -PathType Container) { continue }
        New-Item -ItemType Directory -Path $directory | Out-Null
        $createdDirectories.Add(@{ path = $directory; createdUtcTicks = (Get-Item -LiteralPath $directory).CreationTimeUtc.Ticks })
    }
}
# CodexHomeにPrunletの登録（所有block・hook handler・共通指示）が残っているか。起動スクリプトの
# Test-CodexRegistrationPresentと同じ目印で判定する。通常ファイルでない登録先は判定できないため登録ありとする。
function Test-CodexHomeHasPrunlet([string]$Codex) {
    if (!$Codex -or !(Test-Path -LiteralPath $Codex -PathType Container)) { return $false }
    $markers = @{
        'config.toml' = @('# BEGIN PRUNLET MCP', '# BEGIN PRUNLET HOOK-FEATURE')
        'hooks.json' = @('prunlet-hook.exe', 'Prunlet')
        'AGENTS.md' = @('BEGIN PRUNLET AGENT-INSTRUCTIONS')
    }
    if (Test-Path -LiteralPath (Join-Path $Codex 'PRUNLET.md')) { return $true }
    foreach ($name in $markers.Keys) {
        $path = Join-Path $Codex $name
        if (!(Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $true }
        $text = [IO.File]::ReadAllText($path)
        foreach ($marker in $markers[$name]) { if ($text.Contains($marker, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    }
    return $false
}
function Test-RegisteredManagedInstallation([string]$Root) {
    $effectiveHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    if (!(Assert-PlainPath $CodexHome 'CodexHome').Equals((Assert-PlainPath $effectiveHome 'Effective CodexHome'),[StringComparison]::OrdinalIgnoreCase)) { return $false }
    $document = Assert-PlainPath (Join-Path $CodexHome 'AGENTS.md') 'Existing CLI registration'
    if (!(Test-Path -LiteralPath $document -PathType Leaf)) { return $false }
    $text = [IO.File]::ReadAllText($document)
    if ([regex]::Matches($text,'BEGIN PRUNLET AGENT-INSTRUCTIONS').Count -ne 1 -or [regex]::Matches($text,'END PRUNLET AGENT-INSTRUCTIONS').Count -ne 1) { return $false }
    $block = [regex]::Matches($text,'(?ms)^<!-- BEGIN PRUNLET AGENT-INSTRUCTIONS -->\r?\n(.*?)^<!-- END PRUNLET AGENT-INSTRUCTIONS -->\r?$')
    if ($block.Count -ne 1 -or $block[0].Index -ne 0) { return $false }
    $line = [regex]::Matches($block[0].Groups[1].Value,'(?m)^Prunlet CLI: (\{[^\r\n]*\})\r?$')
    if ($line.Count -ne 1) { return $false }
    try {
        $binding = $line[0].Groups[1].Value | ConvertFrom-Json -ErrorAction Stop
        $instruction = 'Windowsのファイル・フォルダー・レジストリ削除では、[PRUNLET.md](PRUNLET.md)を読み、Prunlet CLIを最初からCMD（shell=cmd.exe、login=false）で直接実行する。'
        $canonical = $instruction + "`nPrunlet CLI: " + ([ordered]@{executablePath=$binding.executablePath;configPath=$binding.configPath} | ConvertTo-Json -Compress) + "`n"
        if (![string]::Equals($block[0].Groups[1].Value.Replace("`r`n","`n"),$canonical,[StringComparison]::Ordinal)) { return $false }
        $executable = Assert-PlainPath ([string]$binding.executablePath) 'Registered CLI'
        $configuration = Assert-PlainPath ([string]$binding.configPath) 'Registered configuration'
        return $executable.Equals((Join-Path $Root 'bin\prunlet.exe'),[StringComparison]::OrdinalIgnoreCase) -and $configuration.Equals((Join-Path $Root 'config.json'),[StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}
function Assert-ManagedExistingPath([string]$Path,[switch]$RegisteredInstallation,[switch]$RequireGit) {
    $full = Assert-PlainPath $Path 'Managed installation path'
    foreach ($forbidden in $script:ForbiddenRoots) {
        if (Test-InTree $full $forbidden) { throw (Format-PrunletMessage 'Managed installation cannot use a source or Codex directory.') }
    }
    if (!(Test-Path -LiteralPath $full -PathType Container)) { throw (Format-PrunletMessage 'Managed installation directories must already exist.') }
    $repositories = [Collections.Generic.List[string]]::new()
    $cursor = $full
    while ($cursor) {
        if ((Test-Path -LiteralPath (Join-Path $cursor 'Cargo.toml')) -or (Test-Path -LiteralPath (Join-Path $cursor 'src\Prunlet\Prunlet.csproj'))) { throw (Format-PrunletMessage 'Managed installation cannot be inside a source tree.') }
        if (Test-Path -LiteralPath (Join-Path $cursor '.git')) { $repositories.Add($cursor) }
        $cursor = Split-Path -Parent $cursor
    }
    if ($RequireGit -and !$repositories.Count) { throw (Format-PrunletMessage 'Managed update mode requires an existing installation inside Git.') }
    if ($repositories.Count -gt 1) { throw (Format-PrunletMessage 'Nested Git repositories are unsupported for managed installation.') }
    if ($repositories.Count) {
        foreach ($variable in @('GIT_DIR','GIT_WORK_TREE','GIT_INDEX_FILE','GIT_COMMON_DIR','GIT_LITERAL_PATHSPECS')) {
            if ([Environment]::GetEnvironmentVariable($variable)) { throw (Format-PrunletMessage 'Managed installation requires the physical Git repository and index.') }
        }
        $git = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
        $gitRoot = $repositories[0]
        $actual = & $git.Source --no-optional-locks --literal-pathspecs -c core.fsmonitor=false -C $gitRoot rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -ne 0 -or !$actual -or !(Assert-PlainPath ([string]$actual) 'Git root').Equals($gitRoot,[StringComparison]::OrdinalIgnoreCase)) { throw (Format-PrunletMessage 'Managed installation Git repository could not be verified.') }
        & $git.Source --no-optional-locks -c core.fsmonitor=false -C $gitRoot check-ignore --no-index -q -- $full 2>$null
        if ($LASTEXITCODE -ne 0 -and !($LASTEXITCODE -eq 1 -and $RegisteredInstallation)) { throw (Format-PrunletMessage 'Managed installation path must be Git-ignored or match its existing CLI registration.') }
        $indexStart = [Diagnostics.ProcessStartInfo]::new($git.Source)
        $indexStart.UseShellExecute = $false; $indexStart.CreateNoWindow = $true
        $indexStart.RedirectStandardOutput = $true; $indexStart.RedirectStandardError = $true
        $indexStart.StandardOutputEncoding = [Text.UTF8Encoding]::new($false,$true)
        foreach ($argument in @('--no-optional-locks','-c','core.fsmonitor=false','-C',$gitRoot,'ls-files','-z')) { $indexStart.ArgumentList.Add($argument) }
        $indexProcess = [Diagnostics.Process]::Start($indexStart)
        try {
            $indexError = $indexProcess.StandardError.ReadToEndAsync()
            $indexText = $indexProcess.StandardOutput.ReadToEnd()
            $indexProcess.WaitForExit(); [void]$indexError.GetAwaiter().GetResult()
            if ($indexProcess.ExitCode -ne 0) { throw (Format-PrunletMessage 'Managed installation path contains tracked files or an unverifiable index.') }
            foreach ($entry in $indexText.Split([char]0,[StringSplitOptions]::RemoveEmptyEntries)) {
                $trackedPath = [IO.Path]::GetFullPath((Join-Path $gitRoot $entry))
                if (Test-InTree $trackedPath $full) { throw (Format-PrunletMessage 'Managed installation path contains tracked files or an unverifiable index.') }
            }
        } finally { $indexProcess.Dispose() }
    }
    return $full
}
function Read-ManagedInstallationJson([string]$Path) {
    [void](Assert-PlainPath $Path 'Managed installation file')
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw (Format-PrunletMessage 'Managed update requires an existing installation and configuration.') }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $reader = [IO.StreamReader]::new([IO.MemoryStream]::new($bytes,$false),[Text.Encoding]::UTF8,$true)
    try { $value = $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop } finally { $reader.Dispose() }
    return @{ value=$value; hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)) }
}
function Get-ManagedInstallationSnapshot([string]$Root) {
    $rootPath = Assert-PlainPath $Root 'Managed installation root'
    $registered = Test-RegisteredManagedInstallation $rootPath
    $full = Assert-ManagedExistingPath $rootPath -RegisteredInstallation:$registered -RequireGit
    [void](Assert-ManagedExistingPath (Join-Path $full 'bin') -RegisteredInstallation:$registered)
    $configuration = Read-ManagedInstallationJson (Join-Path $full 'config.json')
    $provenance = Read-ManagedInstallationJson (Join-Path $full 'source-info.json')
    $info = $provenance.value
    if (![string]::Equals($info.repository,$Repository,[StringComparison]::OrdinalIgnoreCase) -or ![string]::Equals($info.runtime,$Runtime,[StringComparison]::Ordinal) -or $info.commitSha -notmatch '^[0-9a-fA-F]{40}$' -or $configuration.value.schema -ne 1) { throw (Format-PrunletMessage 'Managed installation metadata does not match the requested product.') }
    $recoveryPath = Assert-PlainPath ([string]$configuration.value.backupDirectory) 'Managed recovery'
    $recovery = if (Test-InTree $recoveryPath $full) { Assert-ManagedExistingPath $recoveryPath -RegisteredInstallation:$registered } else { Assert-ExternalPath $recoveryPath 'Configured backupDirectory' }
    if ((Test-InTree $full $recovery) -or (Test-InTree $recovery (Join-Path $full 'bin'))) { throw (Format-PrunletMessage 'Managed recovery overlaps installed products.') }
    $hashes = [ordered]@{}
    foreach ($entry in @(@('prunlet.exe','executableSha256'),@('prunlet-maintenance.exe','maintenanceExecutableSha256'),@('prunlet-hook.exe','hookExecutableSha256'))) {
        $path = Assert-PlainPath (Join-Path $full ('bin\'+$entry[0])) 'Managed product'
        $expected = [string]$info.($entry[1])
        if ($expected -notmatch '^[0-9a-fA-F]{64}$' -or !(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $expected) { throw (Format-PrunletMessage 'Managed installation product hash mismatch.') }
        $hashes[$entry[0]] = $expected.ToUpperInvariant()
    }
    # この関数は検証スクリプトがASTから単体で読み込んで呼ぶため、スクリプト変数に依存せず表を直接持つ。
    foreach ($name in @('Install-Prunlet.ps1','start-prunlet-mcp.ps1','configuration-common.ps1','maintenance-task.ps1','uninstall-maintenance.ps1','install-codex.ps1','uninstall-codex.ps1','install-agent-instructions.ps1','PRUNLET.md')) {
        $relative = 'bin\'+$name
        $path = Assert-PlainPath (Join-Path $full $relative) 'Managed auxiliary product'
        $expected = [string]$info.auxiliarySha256.($relative)
        if ($expected -notmatch '^[0-9a-fA-F]{64}$' -or !(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $expected) { throw (Format-PrunletMessage 'Managed installation auxiliary hash mismatch.') }
        $hashes[$relative] = $expected.ToUpperInvariant()
    }
    if (Test-Path -LiteralPath (Join-Path $full 'bin\codex-pretooluse.ps1')) { throw (Format-PrunletMessage 'Unowned retired backend was preserved; managed update cannot replace it.') }
    return [ordered]@{ root=$full; recovery=$recovery; registered=$registered; configHash=$configuration.hash; sourceInfoHash=$provenance.hash; products=$hashes }
}
function Assert-ManagedInstallationSnapshot($Snapshot) {
    $current = Get-ManagedInstallationSnapshot $Snapshot.root
    if (![string]::Equals(($current | ConvertTo-Json -Depth 5 -Compress),($Snapshot | ConvertTo-Json -Depth 5 -Compress),[StringComparison]::Ordinal)) { throw (Format-PrunletMessage 'Managed installation or recovery configuration changed; nothing was replaced.') }
}
# 登録helperへ渡すPreviousGuideSha256を決める。管理モード・非管理モードで共通に使う。
# 前回のbin\PRUNLET.mdと登録済みガイドが改行形式（CRLF/LF）の差だけなら登録実物のhashを、
# それ以外（未登録・本文差・厳密UTF-8として読めない）は前回binのhashを返す。
# 本文が一致する改行差だけを認識し、編集済み本文の拒否は登録helperに委ねる。
function Get-GuideRegistrationPreviousHash([byte[]]$PreviousBytes) {
    $expected = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($PreviousBytes))
    $current = Assert-PlainPath (Join-Path $CodexHome 'PRUNLET.md') 'Registered guide'
    if (!(Test-Path -LiteralPath $current -PathType Leaf)) { return $expected }
    $currentBytes = [IO.File]::ReadAllBytes($current)
    $utf8 = [Text.UTF8Encoding]::new($false,$true)
    try {
        $previousText = $utf8.GetString($PreviousBytes).Replace("`r`n","`n")
        $currentText = $utf8.GetString($currentBytes).Replace("`r`n","`n")
    } catch { return $expected }
    if ([string]::Equals($previousText,$currentText,[StringComparison]::Ordinal)) {
        return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($currentBytes))
    }
    return $expected
}
function Get-ManagedGuideRegistrationHash($Snapshot) {
    $previous = Assert-PlainPath (Join-Path $Snapshot.root 'bin\PRUNLET.md') 'Managed guide'
    $expected = $Snapshot.products['bin\PRUNLET.md']
    $previousBytes = [IO.File]::ReadAllBytes($previous)
    if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($previousBytes)) -ine $expected) { throw (Format-PrunletMessage 'Managed installation auxiliary hash mismatch.') }
    return Get-GuideRegistrationPreviousHash $previousBytes
}
function Assert-ManagedRecoveryBinding($Snapshot,[string]$ExpectedConfigHash = $Snapshot.configHash) {
    $registered = Test-RegisteredManagedInstallation $Snapshot.root
    [void](Assert-ManagedExistingPath $Snapshot.root -RegisteredInstallation:$registered -RequireGit)
    $configuration = Read-ManagedInstallationJson (Join-Path $Snapshot.root 'config.json')
    if ($configuration.hash -ine $ExpectedConfigHash) { throw (Format-PrunletMessage 'Managed recovery configuration changed; migration was not started.') }
    $recoveryPath = Assert-PlainPath ([string]$configuration.value.backupDirectory) 'Managed recovery'
    $recovery = if (Test-InTree $recoveryPath $Snapshot.root) { Assert-ManagedExistingPath $recoveryPath -RegisteredInstallation:$registered } else { Assert-ExternalPath $recoveryPath 'Configured backupDirectory' }
    if (!$recovery.Equals($Snapshot.recovery,[StringComparison]::OrdinalIgnoreCase)) { throw (Format-PrunletMessage 'Managed recovery configuration changed; migration was not started.') }
}
# 公開済み最新版を解決する。R2の最新ポインタ（latest/<runtime>.json、署名付きマニフェストの封筒）を取得し、
# 起動時更新（start-prunlet-mcp.ps1）と同じ Read-PrunletReleaseManifest で、固定公開鍵の署名・製品・公式repository・
# runtime・固定asset名・自分で組み立てたキーとの完全一致・上限を確認する。GitHubのAPI・Release・タグは使わない。
# 失敗の理由は固定語彙だけを利用者の言語で示し、取得した本文は表示しない。
function Get-LatestPrunletRelease {
    $key = 'latest/' + $Runtime + '.json'
    try { $bytes = Get-PrunletReleaseObject $key $script:PrunletReleaseEnvelopeMaxBytes 60 }
    catch {
        if ($_.Exception.Data.Contains('PrunletReleaseManifestReason')) { throw (Format-PrunletMessage 'The release manifest was rejected ({reason}); nothing was installed.' @{ reason = $_.Exception.Data['PrunletReleaseManifestReason'] }) }
        throw (Format-PrunletMessage 'The release manifest could not be retrieved from {url}; nothing was installed.' @{ url = ($script:PrunletReleaseOrigin + $key) })
    }
    try { return Read-PrunletReleaseManifest $bytes $Runtime $Repository }
    catch {
        $reason = if ($_.Exception.Data.Contains('PrunletReleaseManifestReason')) { $_.Exception.Data['PrunletReleaseManifestReason'] } else { 'invalid' }
        throw (Format-PrunletMessage 'The release manifest was rejected ({reason}); nothing was installed.' @{ reason = $reason })
    }
}
# 配布ZIPに含まれる12製品。配置先（bin\…）とZIP内の名前（bin/…）は1対1で対応する。
$script:PackageExecutables = @('prunlet.exe', 'prunlet-maintenance.exe', 'prunlet-hook.exe')
$script:PackageAuxiliary = @('Install-Prunlet.ps1', 'start-prunlet-mcp.ps1', 'configuration-common.ps1', 'maintenance-task.ps1', 'uninstall-maintenance.ps1', 'install-codex.ps1', 'uninstall-codex.ps1', 'install-agent-instructions.ps1', 'PRUNLET.md')
# 配布物の署名者。Signing.Common.ps1と同じ値で、インストーラー単体でも照合できるよう直接持つ。
$script:PackageSignerCommonName = 'Open Source Developer Yuichiro Shinozaki'

# 取得したZIPを、何も実行する前に検証してから展開する。
# 検証範囲: 固定のentry集合・リンクなし・サイズ上限、package.json（製品・schema・取得元・既定ブランチ・
# releaseのcommit・runtime・12製品のhash/長さ）、展開後の実体hash、CLIとhookの同一性、PEのmachine、
# 実行ファイルのAuthenticode（Valid・署名者・タイムスタンプ）。
function Expand-VerifiedPackage([string]$Archive, [string]$Destination, $Release) {
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        [void]$expected.Add('package.json')
        foreach ($name in @($script:PackageExecutables + $script:PackageAuxiliary)) { [void]$expected.Add('bin/' + $name) }
        $entries = [Collections.Generic.Dictionary[string, IO.Compression.ZipArchiveEntry]]::new([StringComparer]::Ordinal)
        $caseFolded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            if (!$expected.Contains($name) -or !$caseFolded.Add($name)) { throw (Format-PrunletMessage 'Unexpected or duplicate package entry: {entry}' @{ entry = $name }) }
            $mode = ($entry.ExternalAttributes -shr 16) -band 0xf000
            if ($mode -notin @(0, 0x8000) -or ($entry.ExternalAttributes -band 0x410)) { throw (Format-PrunletMessage 'Package links, directories, or special files are forbidden: {entry}' @{ entry = $name }) }
            $limit = if ($name.EndsWith('.exe', [StringComparison]::Ordinal)) { 256MB } elseif ($name -ceq 'package.json') { 64KB } else { 4MB }
            if ($entry.Length -lt 1 -or $entry.Length -gt $limit) { throw (Format-PrunletMessage 'Package entry size is invalid: {entry}' @{ entry = $name }) }
            $entries.Add($name, $entry)
        }
        if ($entries.Count -ne $expected.Count) { throw (Format-PrunletMessage 'Release package is missing required entries.') }
        $reader = [IO.StreamReader]::new($entries['package.json'].Open(), [Text.UTF8Encoding]::new($false, $true))
        try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable -ErrorAction Stop } finally { $reader.Dispose() }
        if ($manifest -isnot [Collections.IDictionary] -or $manifest['product'] -cne 'Prunlet' -or $manifest['schema'] -ne 1 -or
            $manifest['repository'] -cne $Repository -or $manifest['defaultBranch'] -cne $Release.branch -or
            [string]$manifest['commitSha'] -cne $Release.commit -or $manifest['runtime'] -cne $Runtime -or
            $manifest['files'] -isnot [Collections.IDictionary] -or $manifest['files'].Count -ne ($expected.Count - 1)) {
            throw (Format-PrunletMessage 'Package metadata does not match the published release.')
        }
        New-Item -ItemType Directory -Path (Join-Path $Destination 'bin') | Out-Null
        $hashes = [ordered]@{}
        foreach ($name in @($script:PackageExecutables + $script:PackageAuxiliary)) {
            $key = 'bin/' + $name
            if (@($manifest['files'].Keys) -cnotcontains $key) { throw (Format-PrunletMessage 'Package metadata is missing: {entry}' @{ entry = $key }) }
            $item = $manifest['files'][$key]
            if ($item -isnot [Collections.IDictionary] -or [string]$item['sha256'] -cnotmatch '^[0-9A-F]{64}$' -or [long]$item['bytes'] -ne $entries[$key].Length) { throw (Format-PrunletMessage 'Package metadata is invalid: {entry}' @{ entry = $key }) }
            $path = Join-Path $Destination ('bin\' + $name)
            $source = $entries[$key].Open()
            try {
                $file = [IO.FileStream]::new($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $source.CopyTo($file) } finally { $file.Dispose() }
            } finally { $source.Dispose() }
            $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            if ($hash -cne [string]$item['sha256'] -or (Get-Item -LiteralPath $path).Length -ne [long]$item['bytes']) { throw (Format-PrunletMessage 'Package content differs from its metadata: {entry}' @{ entry = $key }) }
            $hashes[$name] = $hash
        }
        if ($hashes['prunlet.exe'] -cne $hashes['prunlet-hook.exe']) { throw (Format-PrunletMessage 'The hook host must match the CLI binary.') }
        $machine = if ($Runtime -eq 'win-x64') { 0x8664 } else { 0xaa64 }
        foreach ($name in $script:PackageExecutables) {
            $path = Join-Path $Destination ('bin\' + $name)
            $bytes = [IO.File]::ReadAllBytes($path)
            if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) { throw (Format-PrunletMessage 'Package executable is not a PE file: {entry}' @{ entry = $name }) }
            $offset = [BitConverter]::ToUInt32($bytes, 0x3c)
            if ($offset -lt 64 -or $offset -gt $bytes.Length - 6 -or [BitConverter]::ToUInt32($bytes, [int]$offset) -ne 0x00004550 -or [BitConverter]::ToUInt16($bytes, [int]$offset + 4) -ne $machine) { throw (Format-PrunletMessage 'Package executable does not match {runtime}: {entry}' @{ runtime = $Runtime; entry = $name }) }
            # 未署名・署名者違い・タイムスタンプなしの実行ファイルは配置も実行もしない。
            $signature = Get-AuthenticodeSignature -LiteralPath $path
            $signer = if ($signature.SignerCertificate) { $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) } else { '' }
            if ($signature.Status -ne 'Valid' -or $signer -cne $script:PackageSignerCommonName -or !$signature.TimeStamperCertificate) { throw (Format-PrunletMessage 'Package executable is not signed by the Prunlet publisher (status {status}): {entry}' @{ status = $signature.Status; entry = $name }) }
        }
        return $hashes
    } finally { $zip.Dispose() }
}



# 配布物の補助ファイルが更新タスクに対応しているかを、実物の構文木で判定する。
# maintenance-task.ps1が登録・復元の関数を定義し、start-prunlet-mcp.ps1が-UpdateOnlyを受け付ける場合だけ真。
function Test-PackageSupportsUpdateTask([string]$PackageBin) {
    $definitions = @{}
    foreach ($name in @('maintenance-task.ps1', 'start-prunlet-mcp.ps1')) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PackageBin $name), [ref]$tokens, [ref]$errors)
        if ($errors.Count) { return $false }
        $definitions[$name] = $ast
    }
    $functions = @($definitions['maintenance-task.ps1'].FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object Name)
    foreach ($required in @('Get-PrunletUpdateTaskState', 'Register-PrunletUpdateTask', 'Restore-PrunletUpdateTask')) {
        if ($functions -cnotcontains $required) { return $false }
    }
    $launcherParameters = $definitions['start-prunlet-mcp.ps1'].ParamBlock
    return [bool]($launcherParameters -and @($launcherParameters.Parameters | Where-Object { $_.Name.VariablePath.UserPath -ceq 'UpdateOnly' }).Count)
}

if (!$IsWindows) { throw (Format-PrunletMessage 'Prunlet installation requires Windows and PowerShell 7.') }
if ($PrepareStartupUpdate) { throw (Format-PrunletMessage 'Startup preparation is not part of manual installation. Use the registered MCP startup entry to verify and prepare a published release package.') }
if ($RegisterAgentInstructions -and !$RegisterCodex) { throw (Format-PrunletMessage 'RegisterAgentInstructions requires explicit -RegisterCodex.') }
if ($Repository -cnotmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}$') { throw (Format-PrunletMessage 'Repository must be a GitHub owner/repository name.') }
$nativeArchitecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
if ($nativeArchitecture -eq 'Arm64' -and !$PSBoundParameters.ContainsKey('Runtime')) { throw (Format-PrunletMessage 'On Windows ARM64 explicitly choose -Runtime win-arm64 (or win-x64 for emulation).') }
if ($nativeArchitecture -notin @('X64', 'Arm64')) { throw (Format-PrunletMessage 'Unsupported Windows architecture: {architecture}' @{ architecture = $nativeArchitecture }) }
$runId = 'install-' + [Guid]::NewGuid().ToString('N')
$ForbiddenRoots = @((Assert-PlainPath $CodexHome 'CodexHome'), (Join-Path $env:USERPROFILE '.codex'))
if ($env:CODEX_HOME) { $ForbiddenRoots += Assert-PlainPath $env:CODEX_HOME 'CODEX_HOME' }
$scriptParent = Split-Path -Parent $PSScriptRoot
if ((Test-Path -LiteralPath (Join-Path $scriptParent 'Cargo.toml')) -or (Test-Path -LiteralPath (Join-Path $scriptParent 'src\Prunlet\Prunlet.csproj'))) { $ForbiddenRoots += $scriptParent }
$managedInstallation = if ($UpdateManagedInstallation) { Get-ManagedInstallationSnapshot $InstallDirectory } else { $null }
$InstallDirectory = if ($managedInstallation) { $managedInstallation.root } else { Assert-ExternalPath $InstallDirectory 'InstallDirectory' }

if (!$WorkDirectory) {
    $WorkDirectory = Join-Path ([IO.Path]::GetTempPath()) "Prunlet\$runId"
}
$WorkDirectory = Assert-ExternalPath $WorkDirectory 'WorkDirectory'
if ((Test-InTree $WorkDirectory $InstallDirectory) -or (Test-InTree $InstallDirectory $WorkDirectory)) {
    throw (Format-PrunletMessage 'WorkDirectory and InstallDirectory must be separate trees.')
}
if (Test-Path -LiteralPath $WorkDirectory) { throw (Format-PrunletMessage 'WorkDirectory must be a new directory owned by this installation.') }
if (Test-Path -LiteralPath $InstallDirectory -PathType Leaf) { throw (Format-PrunletMessage 'InstallDirectory is a file.') }
$configPath = Join-Path $InstallDirectory 'config.json'
$existingConfig = Test-Path -LiteralPath $configPath -PathType Leaf

if (!$BackupDirectory) { $BackupDirectory = if ($managedInstallation) { $managedInstallation.recovery } else { Join-Path $InstallDirectory 'recovery' } }
$BackupDirectory = Assert-PlainPath $BackupDirectory 'BackupDirectory'
$BackupDirectory = if ($managedInstallation -and ([IO.Path]::GetFullPath($BackupDirectory).TrimEnd('\','/')).Equals($managedInstallation.recovery,[StringComparison]::OrdinalIgnoreCase)) { $managedInstallation.recovery } else { Assert-ExternalPath $BackupDirectory 'BackupDirectory' }
if ($existingConfig) {
    [void](Assert-PlainPath $configPath 'ConfigPath')
    $existing = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
    $effectiveBackup = if ($managedInstallation) { $managedInstallation.recovery } else { Assert-ExternalPath $existing.backupDirectory 'Configured backupDirectory' }
} else { $effectiveBackup = $BackupDirectory }
if ((Test-InTree $effectiveBackup $WorkDirectory) -or (Test-InTree $WorkDirectory $effectiveBackup)) { throw (Format-PrunletMessage 'WorkDirectory and recovery backup must be separate trees.') }
$UpdateBackupRoot = Assert-ExternalPath $UpdateBackupRoot 'UpdateBackupRoot'
$updateBackup = Assert-ExternalPath (Join-Path $UpdateBackupRoot $runId) 'UpdateBackupDirectory'
if ((Test-InTree $updateBackup $InstallDirectory) -or (Test-InTree $InstallDirectory $updateBackup) -or (Test-InTree $updateBackup $WorkDirectory) -or (Test-InTree $WorkDirectory $updateBackup)) { throw (Format-PrunletMessage 'Update backup must be separate from install and work directories.') }
if ((Test-InTree $updateBackup $effectiveBackup) -or (Test-InTree $effectiveBackup $updateBackup)) { throw (Format-PrunletMessage 'Update backup must be separate from recovery data.') }
if ($RegisterCodex -and $SettingsBackupDirectory) { $SettingsBackupDirectory = Assert-ExternalPath $SettingsBackupDirectory 'SettingsBackupDirectory' }
# 12製品は$script:PackageExecutables・$script:PackageAuxiliaryから組み立て、表の重複を持たない。
$products = @(@($script:PackageExecutables + $script:PackageAuxiliary | ForEach-Object { 'bin\' + $_ }) + 'source-info.json')
$retiredProducts = @('bin\codex-pretooluse.ps1')
$previousGuidePath = Join-Path $InstallDirectory 'bin\PRUNLET.md'
# 非管理モードでも、前回binと登録済みガイドが改行差だけなら登録実物のhashをPreviousに使う（管理モードと同じ判定）。
$previousGuideSha256 = if ($managedInstallation -and $RegisterAgentInstructions) { Get-ManagedGuideRegistrationHash $managedInstallation } elseif (Test-Path -LiteralPath $previousGuidePath -PathType Leaf) { if ($RegisterAgentInstructions) { Get-GuideRegistrationPreviousHash ([IO.File]::ReadAllBytes($previousGuidePath)) } else { (Get-FileHash -LiteralPath $previousGuidePath -Algorithm SHA256).Hash } } else { $null }
foreach ($relative in @($products + $retiredProducts)) {
    $target = Assert-PlainPath (Join-Path $InstallDirectory $relative) 'Installed product path'
    if (Test-Path -LiteralPath $target -PathType Container) { throw (Format-PrunletMessage 'Installed product path is a directory: {path}' @{ path = $target }) }
    if ((Test-InTree $effectiveBackup $target) -or (Test-InTree $target $effectiveBackup)) { throw (Format-PrunletMessage 'Product files and recovery backup must be separate.') }
}
$mutexKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($InstallDirectory.ToLowerInvariant())))
$globalInstallationMutex = [Threading.Mutex]::new($false, ('Global\Prunlet-Install-' + $mutexKey))
$installationMutex = [Threading.Mutex]::new($false, ('Local\Prunlet-Install-' + $mutexKey))
$globalMutexAcquired = $false
$mutexAcquired = $false
$createdWork = $false
$changed = [Collections.Generic.List[string]]::new()
$saved = @{}
$createdDirectories = [Collections.Generic.List[object]]::new()
$createdConfig = $null
$migratedConfig = $null
$profileSnapshot = [Collections.Generic.List[object]]::new()
$registrationStarted = $false
$maintenanceState = $null
$maintenanceStarted = $false
$updateTaskState = $null
$updateTaskStarted = $false
$retiredProductPaths = [Collections.Generic.List[string]]::new()
$storageMigrationStarted = $false
$storageMigration = $null
$migrationJson = $null
try {
    try { $globalMutexAcquired = $globalInstallationMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $globalMutexAcquired = $true }
    if (!$globalMutexAcquired) { throw (Format-PrunletMessage 'Another Prunlet installation is already running for this directory.') }
    try { $mutexAcquired = $installationMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $mutexAcquired = $true }
    if (!$mutexAcquired) { throw (Format-PrunletMessage 'Another Prunlet installation is already running for this directory.') }
    if ($managedInstallation) { Assert-ManagedInstallationSnapshot $managedInstallation }
    # 更新状態がidleでない（切替・移行・後片付けの途中）間は導入しない。製品を上書きすると、途中の更新を
    # 再開できなくなり、更新状態がidleへ戻らないままCLIの起動gateが止まり続ける。
    $updateStatePath = Join-Path $InstallDirectory '.prunlet-update-state.json'
    if (Test-Path -LiteralPath $updateStatePath -PathType Leaf) {
        $updateStatePhase = $null
        try { $updateStatePhase = ([IO.File]::ReadAllText($updateStatePath) | ConvertFrom-Json).phase } catch { }
        if ($null -ne $updateStatePhase -and $updateStatePhase -cne 'idle') { throw (Format-PrunletMessage 'A Prunlet update is in progress (phase: {phase}); nothing was installed. Let the update finish, then install again.' @{ phase = $updateStatePhase }) }
    }
    # 既定ブランチのHEADではなく、署名済みの更新ZIPを持つ公開済み最新releaseを導入する。
    # ソースのビルドをしないため、Rust・MSVC・Windows SDKは不要。
    $release = Get-LatestPrunletRelease
    $branch = $release.branch
    $sha = $release.commit
    if ($ExpectedCommitSha -and $sha -ine $ExpectedCommitSha) { throw (Format-PrunletMessage 'The latest release commit differs from ExpectedCommitSha; nothing was installed.') }

    New-Item -ItemType Directory -Path $WorkDirectory | Out-Null
    $createdWork = $true
    # ZIP本体は、署名済みマニフェストが指すR2の不変キー（commit・runtime・SHA-256を含むcreate-onlyのURL）から取得し、
    # マニフェストのbytes・sha256で照合する。リダイレクトは追わず、200以外は取得失敗として何も導入しない。
    $archive = Join-Path $WorkDirectory $release.assetName
    try {
        $downloaded = Invoke-WebRequest -Uri $release.downloadUrl -Headers @{ 'User-Agent' = 'Prunlet-Latest-Installer' } -OutFile $archive -PassThru -MaximumRedirection 0 -TimeoutSec 300
        if ($null -eq $downloaded -or [int]$downloaded.StatusCode -ne 200) { throw 'unexpected response' }
    } catch { throw (Format-PrunletMessage 'The package could not be downloaded from {url}; nothing was installed.' @{ url = $release.downloadUrl }) }
    $archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    if ((Get-Item -LiteralPath $archive).Length -ne $release.assetBytes -or $archiveHash.ToLowerInvariant() -cne $release.assetSha256) { throw (Format-PrunletMessage 'Downloaded package differs from the published release asset; nothing was installed.') }
    $packageRoot = Join-Path $WorkDirectory 'package'
    $packageHashes = Expand-VerifiedPackage $archive $packageRoot $release
    $packageBin = Join-Path $packageRoot 'bin'
    # 取得元情報のdownloadUrlは、R2の不変URL（https://prunlet.kagayoi.com/releases/<repo>/<commit>/<runtime>/<sha256>.zip）。
    # archiveSha256はZIP全体（起動時更新と同じ形）。旧版が書いたGitHubのasset API形式も、読取り側（-UpdateManagedInstallation
    # の照合）は形式を問わず受け付ける。
    $downloadUrl = $release.downloadUrl
    if ($RegisterAgentInstructions) {
        $instructionParameters = @{ SourceGuidePath = (Join-Path $packageBin 'PRUNLET.md'); CodexHome = $CodexHome; BackupDirectory = $(if ($SettingsBackupDirectory) { $SettingsBackupDirectory } else { $updateBackup }); PreviousGuideSha256 = $previousGuideSha256; ExecutablePath = (Join-Path $InstallDirectory 'bin\prunlet.exe'); ConfigPath = $configPath }
        & (Join-Path $packageBin 'install-agent-instructions.ps1') @instructionParameters -ValidateOnly | Out-Null
    }
    # 所有していない既存タスクは製品ファイルを書き換える前に拒否する。
    . (Join-Path $packageBin 'maintenance-task.ps1')
    $maintenanceState = Get-PrunletMaintenanceState (Join-Path $InstallDirectory 'bin\prunlet.exe') $configPath
    # 更新タスクは、導入する配布物の補助ファイルが対応している場合だけ登録する。このインストーラーは
    # mainから取得されるため、最新releaseより新しいことがある。呼び出し元の関数ではなく配布物の実物で判定する。
    # 更新タスクへCodexHomeを渡すのは、今回Codexへ登録する場合と、CodexHomeにPrunletの登録が残っている場合だけ。
    # Codexを使わない導入ではタスク引数から外し、更新のたびに~/.codexを参照・保護しないようにする。
    # mainのインストーラーは最新releaseより新しいことがある。配布物のmaintenance-task.ps1が
    # CodexHome省略に対応していない（PreserveCodexHomeを持たない）旧版なら、従来どおりCodexHomeを渡す。
    $taskFunction = Get-Command Get-PrunletUpdateTaskState -CommandType Function -ErrorAction SilentlyContinue
    $optionalCodexHome = $taskFunction -and $taskFunction.Parameters.ContainsKey('PreserveCodexHome')
    $taskCodexHome = if (!$optionalCodexHome -or $RegisterCodex -or $RegisterAgentInstructions -or (Test-CodexHomeHasPrunlet $CodexHome)) { $CodexHome } else { '' }
    $updateTaskState = if (Test-PackageSupportsUpdateTask $packageBin) { Get-PrunletUpdateTaskState (Join-Path $InstallDirectory 'bin\prunlet.exe') $configPath $taskCodexHome } else { $null }
    $exe = Join-Path $packageBin 'prunlet.exe'
    $maintenanceExe = Join-Path $packageBin 'prunlet-maintenance.exe'
    $hookExe = Join-Path $packageBin 'prunlet-hook.exe'
    # 初期設定も外部作業場所で検証する。既存設定の移行は配置後に行う。
    $newConfig = Join-Path $WorkDirectory 'config.json'
    if (!$existingConfig) {
        # 最終的な復元先の安全性をCoreに検査させる。
        # 今回作ったディレクトリだけを追跡し、失敗時に空のものを戻す。
        New-TrackedDirectory $effectiveBackup
        $probeArgs = @('--config', $newConfig, 'init', '--backup-directory', $effectiveBackup)
        & $exe @probeArgs | Out-Null
        if ($LASTEXITCODE -ne 0) { throw (Format-PrunletMessage 'Prunlet rejected the initial configuration.') }
    } else {
        & $exe --config $configPath validate-config | Out-Null
        if ($LASTEXITCODE -ne 0) { throw (Format-PrunletMessage 'Prunlet rejected the existing configuration; it was preserved.') }
    }
    $auxiliaryHashes = [ordered]@{}
    foreach ($name in $script:PackageAuxiliary) { $auxiliaryHashes['bin\' + $name] = $packageHashes[$name] }
    # 起動時更新（coordinator.rsのsource_info）が書く10項目と同じ構成にし、次回以降の自動更新が引き継げるようにする。
    $provenance = [ordered]@{ repository = $Repository; defaultBranch = $branch; commitSha = $sha.ToLowerInvariant(); downloadUrl = $downloadUrl; archiveSha256 = $archiveHash.ToUpperInvariant(); executableSha256 = $packageHashes['prunlet.exe']; maintenanceExecutableSha256 = $packageHashes['prunlet-maintenance.exe']; hookExecutableSha256 = $packageHashes['prunlet-hook.exe']; auxiliarySha256 = $auxiliaryHashes; runtime = $Runtime }
    $provenance | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $WorkDirectory 'source-info.json') -Encoding utf8NoBOM

    if ($managedInstallation) { Assert-ManagedInstallationSnapshot $managedInstallation }
    # 製品ファイルと設定原本を保全する。復元領域の移行は更新の最後にCoreへ委ねる。
    foreach ($relative in @($products + $retiredProducts)) {
        $target = Join-Path $InstallDirectory $relative
        [void](Assert-PlainPath $target 'Installed product path')
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            $copy = Join-Path $updateBackup $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $copy) -Force | Out-Null
            Copy-Item -LiteralPath $target -Destination $copy
            if ((Get-FileHash -LiteralPath $copy).Hash -ne (Get-FileHash -LiteralPath $target).Hash) { throw (Format-PrunletMessage 'Update backup verification failed: {file}' @{ file = $relative }) }
            $saved[$relative] = $copy
        }
    }
    if ($saved.Count) {
        [ordered]@{ purpose = 'Restore product files after this update; config and recovery are excluded.'; installDirectory = $InstallDirectory; savedFiles = @($saved.Keys); cleanup = 'Delete after confirming this installation works.' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $updateBackup 'backup-info.json') -Encoding utf8NoBOM
    }
    if ($managedInstallation) { Assert-ManagedInstallationSnapshot $managedInstallation } else { New-TrackedDirectory (Join-Path $InstallDirectory 'bin') }
    foreach ($relative in $products) {
        $inputPath = if ($relative -eq 'source-info.json') { Join-Path $WorkDirectory $relative } else { Join-Path $packageBin ([IO.Path]::GetFileName($relative)) }
        $target = Join-Path $InstallDirectory $relative
        [void]$changed.Add($relative)
        Copy-Item -LiteralPath $inputPath -Destination $target -Force
        if ((Get-FileHash -LiteralPath $inputPath).Hash -ne (Get-FileHash -LiteralPath $target).Hash) { throw (Format-PrunletMessage 'Installed file verification failed: {file}' @{ file = $relative }) }
    }
    if (!$existingConfig) {
        # CreateNewで並行作成された設定も上書きしない。
        $stream = [IO.File]::Open($configPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $createdConfig = @{ createdUtcTicks = (Get-Item -LiteralPath $configPath).CreationTimeUtc.Ticks; sha256 = $null }
        try { $bytes = [IO.File]::ReadAllBytes($newConfig); $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
        $createdConfig.sha256 = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
    }
    if ($existingConfig) {
        [void](Assert-PlainPath $configPath 'Capacity migration configuration')
        # 読込経路は変更せず、正式更新時だけ一度移行する。未知の設定もJSON木で保持する。
        $originalBytes = [IO.File]::ReadAllBytes($configPath)
        $originalHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($originalBytes))
        if ($managedInstallation -and $originalHash -ine $managedInstallation.configHash) { throw (Format-PrunletMessage 'Managed recovery configuration changed; migration was not started.') }
        $nodeOptions = [Text.Json.Nodes.JsonNodeOptions]::new()
        $nodeOptions.PropertyNameCaseInsensitive = $true
        $settings = [Text.Json.Nodes.JsonNode]::Parse([Text.Encoding]::UTF8.GetString($originalBytes).TrimStart([char]0xfeff), $nodeOptions, [Text.Json.JsonDocumentOptions]::new())
        if ($settings -isnot [Text.Json.Nodes.JsonObject]) { throw (Format-PrunletMessage 'Configuration must be a JSON object.') }
        $migrationVersion = $settings['capacityDefaultMigrationVersion']
        if ($null -eq $migrationVersion -or $migrationVersion.GetValue[int]() -lt 1) {
            $settings['maxRecoveryBytes'] = [Text.Json.Nodes.JsonValue]::Create([long]1073741824)
            $settings['capacityDefaultMigrationVersion'] = [Text.Json.Nodes.JsonValue]::Create([int]1)
            $candidate = Join-Path $WorkDirectory 'migrated-config.json'
            [IO.File]::WriteAllText($candidate, $settings.ToJsonString(), [Text.UTF8Encoding]::new($false))
            & $exe --config $candidate validate-config | Out-Null
            if ($LASTEXITCODE -ne 0) { throw (Format-PrunletMessage 'Prunlet rejected the migrated configuration; the original was preserved.') }
            $originalHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($originalBytes))
            $migrationBackup = Join-Path $updateBackup 'config-before-capacity-migration.json'
            New-Item -ItemType Directory -Path $updateBackup -Force | Out-Null
            [IO.File]::WriteAllBytes($migrationBackup, $originalBytes)
            $temporaryConfig = Join-Path $InstallDirectory ('config-migration-' + [guid]::NewGuid().ToString('N') + '.json')
            try {
                [IO.File]::Copy($candidate, $temporaryConfig, $false)
                # 通常の書込みを排除し、検証した原本だけを原子的に置換する。
                $guard = [IO.File]::Open($configPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
                try {
                    if ((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ne $originalHash) { throw (Format-PrunletMessage 'Configuration changed during capacity migration; it was preserved.') }
                    $migratedHash = (Get-FileHash -LiteralPath $temporaryConfig -Algorithm SHA256).Hash
                    [IO.File]::Replace($temporaryConfig, $configPath, [Management.Automation.Language.NullString]::Value)
                    $migratedConfig = @{ backup = $migrationBackup; sha256 = $migratedHash }
                } finally { $guard.Dispose() }
            } finally {
                if (Test-Path -LiteralPath $temporaryConfig -PathType Leaf) { Remove-Item -LiteralPath $temporaryConfig }
            }
        }
    }
    if ($RegisterCodex) {
        # 連携側の2ファイル書込みを一つの操作として戻せるよう、呼出し前のバイト列を保全する。
        $profileFiles = @('hooks.json', 'config.toml')
        if ($RegisterAgentInstructions) { $profileFiles += @('AGENTS.md', 'PRUNLET.md') }
        foreach ($fileName in $profileFiles) {
            $target = Assert-PlainPath (Join-Path $CodexHome $fileName) 'Codex configuration path'
            if (Test-Path -LiteralPath $target -PathType Container) { throw (Format-PrunletMessage 'Codex configuration path is a directory: {path}' @{ path = $target }) }
            $existed = Test-Path -LiteralPath $target -PathType Leaf
            $backup = $null
            $originalHash = $null
            if ($existed) {
                $backup = Join-Path $updateBackup ('codex-profile\' + $fileName)
                New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
                [IO.File]::WriteAllBytes($backup, [IO.File]::ReadAllBytes($target))
                $originalHash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
            }
            $profileSnapshot.Add([ordered]@{ target = $target; existed = $existed; backup = $backup; sha256 = $originalHash })
        }
        New-Item -ItemType Directory -Path $updateBackup -Force | Out-Null
        [ordered]@{ purpose = 'Restore Codex profile files if registration fails.'; installDirectory = $InstallDirectory; files = @($profileSnapshot.ToArray()); restore = 'For an originally existing file copy its backup to target; for an originally absent file remove the newly created target after reviewing it.'; retention = 'Keep until installation and Codex registration are verified; delete this installation backup when no recovery is required.' } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $updateBackup 'profile-backup-info.json') -Encoding utf8NoBOM
        $registration = @{ ExecutablePath = (Join-Path $InstallDirectory 'bin\prunlet.exe'); ConfigPath = $configPath; CodexHome = $CodexHome }
        if ($SettingsBackupDirectory) { $registration.BackupDirectory = $SettingsBackupDirectory }
        # 既存連携スクリプトの任意キー処理には呼出し元のStrictModeを伝播させない。
        $registrationStarted = $true
        & { Set-StrictMode -Off; & (Join-Path $InstallDirectory 'bin\install-codex.ps1') @registration } | Out-Null
        if ($RegisterAgentInstructions) {
            $instructionParameters.SourceGuidePath = Join-Path $InstallDirectory 'bin\PRUNLET.md'
            & (Join-Path $InstallDirectory 'bin\install-agent-instructions.ps1') @instructionParameters | Out-Null
        }
    }
    # Codex連携とは独立した製品機能として、無操作時もログイン中に日次保守する。
    New-Item -ItemType Directory -Path $updateBackup -Force | Out-Null
    if ($maintenanceState.previousXml) { [IO.File]::WriteAllText((Join-Path $updateBackup 'maintenance-task.xml'), $maintenanceState.previousXml, [Text.Encoding]::Unicode) }
    [ordered]@{ purpose = 'Restore the owned maintenance task if this installation fails.'; installDirectory = $InstallDirectory; taskName = $maintenanceState.name; taskPath = '\'; existed = [bool]$maintenanceState.previousXml; previousXml = $(if ($maintenanceState.previousXml) { 'maintenance-task.xml' } else { $null }); restore = 'First verify current task ownership using maintenance-task.ps1; restore previous XML if existed, otherwise unregister only the owned task.' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $updateBackup 'maintenance-task-backup-info.json') -Encoding utf8NoBOM
    $maintenanceStarted = $true
    Register-PrunletMaintenanceTask $maintenanceState
    if ($updateTaskState) {
        # CodexがMCPを起動しないPCでも最新releaseへ追従させる更新タスク（start-prunlet-mcp.ps1 -UpdateOnly）。
        if ($updateTaskState.previousXml) { [IO.File]::WriteAllText((Join-Path $updateBackup 'update-task.xml'), $updateTaskState.previousXml, [Text.Encoding]::Unicode) }
        [ordered]@{ purpose = 'Restore the owned update task if this installation fails.'; installDirectory = $InstallDirectory; taskName = $updateTaskState.name; taskPath = '\'; existed = [bool]$updateTaskState.previousXml; previousXml = $(if ($updateTaskState.previousXml) { 'update-task.xml' } else { $null }); restore = 'First verify current task ownership using maintenance-task.ps1; restore previous XML if existed, otherwise unregister only the owned task.' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $updateBackup 'update-task-backup-info.json') -Encoding utf8NoBOM
        $updateTaskStarted = $true
        Register-PrunletUpdateTask $updateTaskState
    }
    # 廃止したバックエンドも記録なしのCore経路でWindowsのゴミ箱へ渡す。
    foreach ($relative in $retiredProducts) {
        $target = Assert-PlainPath (Join-Path $InstallDirectory $relative) 'Retired product path'
        if (!(Test-Path -LiteralPath $target -PathType Leaf)) { continue }
        $installedExe = Join-Path $InstallDirectory 'bin\prunlet.exe'
        [void]$changed.Add($relative)
        $retirementJson = & $installedExe --config $configPath delete -- $target
        if ($LASTEXITCODE -ne 0) { throw (Format-PrunletMessage 'Prunlet could not retire the obsolete hook backend; recovery data was preserved.') }
        $retirement = $retirementJson | ConvertFrom-Json -AsHashtable
        if (@($retirement.items).Count -ne 1 -or @($retirement.items | Where-Object status -ne 'recycled').Count -or (Test-Path -LiteralPath $target)) { throw (Format-PrunletMessage 'Retired product recycling was not confirmed.') }
        $retiredProductPaths.Add($target)
        $retirementJson | Set-Content -LiteralPath (Join-Path $updateBackup 'retired-products.json') -Encoding utf8NoBOM
    }
    # 移行開始後は旧exeへ戻さない。移行済み領域も同じ新版で再開できる状態を残す。
    if ($managedInstallation) {
        $expectedConfiguration = if ($migratedConfig) { $migratedConfig.sha256 } else { $managedInstallation.configHash }
        Assert-ManagedRecoveryBinding $managedInstallation $expectedConfiguration
    }
    $storageMigrationStarted = $true
    $migrationJson = & (Join-Path $InstallDirectory 'bin\prunlet.exe') --config $configPath migrate --apply --if-needed
    $migrationExitCode = $LASTEXITCODE
    $storageMigration = $migrationJson | ConvertFrom-Json -AsHashtable
    if ($migrationExitCode -ne 0 -or !$storageMigration.registryReady -or @($storageMigration.operations | Where-Object status -eq 'failed').Count) {
        throw (Format-PrunletMessage 'Recovery storage migration is incomplete. Installed products were retained; resume with the installed CLI migrate --apply.')
    }
    if (!$storageMigration.complete) { Write-Warning (Format-PrunletMessage 'Some legacy file recovery data was retained. Review the migration result before retrying migrate --apply; normal maintenance does not scan it.') }
    [ordered]@{ status = 'installed'; installDirectory = $InstallDirectory; configPath = $configPath; repository = $Repository; defaultBranch = $branch; releaseTag = ('v' + $release.version); commitSha = $sha; sourceInfoPath = (Join-Path $InstallDirectory 'source-info.json'); updateBackupDirectory = $updateBackup; maintenanceTaskName = $maintenanceState.name; updateTaskName = $(if ($updateTaskState) { $updateTaskState.name } else { $null }); updateTaskRegistered = [bool]$updateTaskState; retiredProductPaths = @($retiredProductPaths.ToArray()); recoveryMigration = $storageMigration; codexRegistered = [bool]$RegisterCodex; agentInstructionsRegistered = [bool]$RegisterAgentInstructions; requiresHookTrust = [bool]$RegisterCodex } | ConvertTo-Json -Depth 12
} catch {
    $originalError = $_
    if ($storageMigrationStarted) {
        throw (Format-PrunletMessage 'Installation reached recovery migration: {error}. The updated executables, configuration, and registrations were preserved; retry the installed CLI migrate --apply. Migration result: {result}' @{ error = $originalError; result = $migrationJson })
    }
    $rollbackErrors = [Collections.Generic.List[string]]::new()
    if ($migratedConfig) {
        try {
            [void](Assert-PlainPath $configPath 'Capacity migration rollback path')
            $rollbackConfig = Join-Path $InstallDirectory ('config-rollback-' + [guid]::NewGuid().ToString('N') + '.json')
            try {
                [IO.File]::Copy($migratedConfig.backup, $rollbackConfig, $false)
                $guard = [IO.File]::Open($configPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
                try {
                    if ((Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ne $migratedConfig.sha256) { throw (Format-PrunletMessage 'Migrated configuration changed; it was preserved.') }
                    [IO.File]::Replace($rollbackConfig, $configPath, [Management.Automation.Language.NullString]::Value)
                } finally { $guard.Dispose() }
            } finally { if (Test-Path -LiteralPath $rollbackConfig -PathType Leaf) { Remove-Item -LiteralPath $rollbackConfig } }
        } catch { $rollbackErrors.Add("Capacity configuration: $_") }
    }
    if ($updateTaskStarted) {
        try { Restore-PrunletUpdateTask $updateTaskState } catch { $rollbackErrors.Add("Update task: $_") }
    }
    if ($maintenanceStarted) {
        try { Restore-PrunletMaintenanceTask $maintenanceState } catch { $rollbackErrors.Add("Maintenance task: $_") }
    }
    if ($registrationStarted) {
        foreach ($profile in $profileSnapshot) {
            try {
                $target = Assert-PlainPath $profile.target 'Codex rollback path'
                if ($profile.existed) {
                    # 未変更のロック中ファイルには書き込まない。
                    if ((Test-Path -LiteralPath $target -PathType Leaf) -and (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $profile.sha256) { continue }
                    [IO.File]::WriteAllBytes($target, [IO.File]::ReadAllBytes($profile.backup))
                    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $profile.sha256) { throw (Format-PrunletMessage 'Restored content hash differs from the preimage.') }
                } elseif (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target }
                elseif (Test-Path -LiteralPath $target) { throw (Format-PrunletMessage 'Configuration path became a directory.') }
            } catch { $rollbackErrors.Add("Codex profile ${target}: $_") }
        }
    }
    # 連携やタスクを戻せない場合は、残った登録が指す実行ファイルを消さず保全する。
    if ($rollbackErrors.Count) { throw (Format-PrunletMessage 'Installation failed: {error}. Installed products were retained because registration rollback failed. Recover registrations from {backup}: {details}' @{ error = $originalError; backup = $updateBackup; details = ($rollbackErrors -join '; ') }) }
    foreach ($relative in $changed) {
        try {
            $target = Assert-PlainPath (Join-Path $InstallDirectory $relative) 'Rollback path'
            if ($saved.ContainsKey($relative)) { Copy-Item -LiteralPath $saved[$relative] -Destination $target -Force } elseif (Test-Path -LiteralPath $target -PathType Leaf) { Remove-Item -LiteralPath $target }
        } catch { [void]$rollbackErrors.Add("${relative}: $_") }
    }
    if ($createdConfig) {
        try {
            [void](Assert-PlainPath $configPath 'New configuration rollback path')
            if (Test-Path -LiteralPath $configPath -PathType Leaf) {
                $configItem = Get-Item -LiteralPath $configPath
                if ($configItem.CreationTimeUtc.Ticks -ne $createdConfig.createdUtcTicks -or !$createdConfig.sha256 -or (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash -ne $createdConfig.sha256) { throw (Format-PrunletMessage 'New configuration was changed or replaced; it was preserved.') }
                Remove-Item -LiteralPath $configPath
            }
        } catch { $rollbackErrors.Add("New configuration ${configPath}: $_") }
    }
    for ($index = $createdDirectories.Count - 1; $index -ge 0; $index--) {
        try {
            $directory = $createdDirectories[$index]
            $target = Assert-ExternalPath $directory.path 'Created directory rollback path'
            if ((Test-Path -LiteralPath $target -PathType Container) -and (Get-Item -LiteralPath $target).CreationTimeUtc.Ticks -eq $directory.createdUtcTicks -and !(Get-ChildItem -LiteralPath $target -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $target }
        } catch { $rollbackErrors.Add("Created directory ${target}: $_") }
    }
    if ($rollbackErrors.Count) { throw (Format-PrunletMessage 'Installation failed: {error}. Rollback requires recovery from {backup}: {details}' @{ error = $originalError; backup = $updateBackup; details = ($rollbackErrors -join '; ') }) }
    throw $originalError
} finally {
    if ($createdWork) {
        try {
            [void](Assert-ExternalPath $WorkDirectory 'WorkDirectory cleanup')
            # 展開元にリンクがないことを再検査して今回の専用作業場所だけ清掃する。
            if (@(Get-ChildItem -LiteralPath $WorkDirectory -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw (Format-PrunletMessage 'Work directory contains links; automatic cleanup stopped.') }
            Remove-Item -LiteralPath $WorkDirectory -Recurse -Force
        } catch { Write-Warning (Format-PrunletMessage 'Temporary files retained at {path}: {error}' @{ path = $WorkDirectory; error = $_ }) }
    }
    if ($mutexAcquired) { $installationMutex.ReleaseMutex() }
    $installationMutex.Dispose()
    if ($globalMutexAcquired) { $globalInstallationMutex.ReleaseMutex() }
    $globalInstallationMutex.Dispose()
}

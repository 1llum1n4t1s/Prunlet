[English](README.md) | [日本語](README.ja.md) | **简体中文** | [繁體中文](README.zh-TW.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português (Brasil)](README.pt-BR.md)

# Prunlet — Anti “blocked by policy”

Prunlet 是一款适用于 Windows、Apple Silicon Mac 和 Linux 的工具，它把 AI 代理的文件和文件夹删除集中到专用的 CLI 和 MCP 服务器，以减少清理因 `blocked by policy` 而中断。它统一采用从一开始就把获准的删除交给 Prunlet 的用法。

文件和文件夹通常移入操作系统的回收站。Prunlet 不保存文件的操作记录、操作 ID 或用于恢复的 snapshot，从回收站恢复和保留交由操作系统处理。它不附属于任何特定的 AI 工具，而是作为独立应用安装。可以按需向各 AI 工具注册 MCP 服务器、CLI 和 hook；hook 会检查并拒绝直接删除，并引导使用 CLI 的步骤。发布者为 Kagayoi。

它处理文件和空文件夹，明确指定 `--recursive` 时可删除整个文件夹。不会追踪链接目标。移入回收站后的硬链接仍与留存的别名共享内容。有条件的永久删除和[注册表的删除与恢复](#注册表的删除与恢复)仅适用于 Windows。

## 作为 `blocked by policy` 对策的用法

在 AI 生成的 `Remove-Item`、`rm` 等删除命令容易导致清理中断的环境中，从一开始就把获准的删除交给 Prunlet CLI。Apple Silicon Mac 和 Linux 上的 Codex 使用安装时放置的 CLI 和配置。[macOS 安装步骤](docs/macos.md) · [Linux 安装步骤](docs/linux.md)

在 Windows 上按以下顺序使用：

1. 使用下文[安装与更新](#安装与更新)中的命令，把 Prunlet 作为独立应用安装。它不会改动 AI 工具的配置文件。
2. 向所用的 AI 工具（MCP 主机）注册[注册到 MCP 主机](#注册到-mcp-主机)中的启动命令。若直接调用 CLI，请把已安装 CLI 和配置的绝对路径写入 AI 工具的指令。若要一次性注册到 Codex，请使用[注册到 Codex（可选）](#注册到-codex可选)。
3. 照常委托工作和清理。CLI 使用已安装 CLI 和配置的绝对路径，从 CMD（`shell: cmd.exe`、`login: false`）直接调用。无需在每个仓库中添加相同的指令。

若要明确委托清理，可以这样说：

> 请从一开始就用 Prunlet CLI 清理这次创建的不需要的临时文件和工作文件夹。

含空格、Unicode、长路径或多个目标时，请用 `--paths-file` 传入 UTF-8 的 JSON 列表；对非空文件夹请明确指定 `--recursive`。实际命令和恢复方法请参阅[删除与恢复](#删除与恢复)。

hook 是检测并拒绝直接删除、引导使用 CLI 步骤的辅助手段，不会自动转换命令。为避免反复失败和重试，基本做法是通过共同指令从第一次起就使用 CLI。主机和操作系统的权限、审批和管理策略仍然适用。如果对 Prunlet 本身的调用被拒绝，请停止，不要改用其他途径重试。注册和检查范围的详情请参阅[集成步骤](docs/integration.md)。

Codex 发送到 Mac 等处的 PowerShell 脚本，请按[hook 集成步骤](docs/integration.md#hookの検査範囲)中明确的子 PowerShell 形式传递。Codex 的 hook 输入不包含执行用的 shell，因此仅指定 `shell: "pwsh"` 无法区分 here-string 中的删除。

## 安装与更新

在发布源迁移到 `https://prunlet.kagayoi.com` 的签名清单之前发布的版本（通过 GitHub Releases 分发的版本）无法检测到新版本。它们会继续以当前版本运行而不会损坏，但不会自动迁移，因此请重新安装一次：Windows 请再次运行 [Windows](#windows) 中的安装程序命令；Apple Silicon Mac 和 Linux 请按照 [macOS 重新安装步骤](docs/macos.md#旧版からの再導入)或 [Linux 重新安装步骤](docs/linux.md#旧版からの再導入)操作。

### Apple Silicon Mac

`scripts/Install-Prunlet.sh` 从 `https://prunlet.kagayoi.com` 获取签名清单，用脚本内置的公钥验证，然后从清单记录的位置获取 `prunlet-update-osx-arm64.zip`。它一次完成下载、大小和 SHA-256 校验、签名与公证验证，以及到专用文件夹的全新安装（步骤见 [macOS 安装步骤](docs/macos.md)）。请使用它显示的配置行，自行向 Codex 等注册 MCP。已注册的 MCP 在启动时检查更新，正在使用时推迟到以后的启动。

### Linux

从 `https://prunlet.kagayoi.com` 获取与 CPU 对应的 `prunlet-linux-x64.tar.gz` 或 `prunlet-linux-arm64.tar.gz`。其获取位置和 SHA-256 记录在签名清单中。如需简便获取，`https://prunlet.kagayoi.com/download/latest/` 下也有固定名称的软件包和同名的 `.sha256` 文件。

签名清单和校验和的核对、放置到专用目录以及注册到 Codex，请参阅 [Linux 安装步骤](docs/linux.md#初回インストール)。按步骤放置后，官方发行版会在 MCP 启动时检查更新，正在使用时推迟到以后的启动。

### Windows

支持 Windows x64 和 ARM64。下面的安装程序会从 `https://prunlet.kagayoi.com` 获取最新版本的已签名预构建软件包（`prunlet-update-<runtime>.zip`）并放置。只需要 PowerShell 7，不需要 Rust、MSVC 构建工具和 Windows SDK。

| 安装目标 | 安装程序选项 |
| --- | --- |
| Windows x64 | `-Runtime win-x64`（默认） |
| Windows ARM64 | `-Runtime win-arm64` |

在 Windows ARM64 上，请在下面的命令中明确指定 `-Runtime`。若选择 x64 模拟，请指定 `-Runtime win-x64`。

```powershell
$installerDirectory = Join-Path ([IO.Path]::GetTempPath()) ('Prunlet\bootstrap-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $installerDirectory | Out-Null
$installer = Join-Path $installerDirectory 'Install-Prunlet.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/1llum1n4t1s/Prunlet/main/scripts/Install-Prunlet.ps1' -OutFile $installer
pwsh -NoProfile -File $installer
```

安装和更新不需要 GitHub 帐户、登录或令牌。

安装程序从 `https://prunlet.kagayoi.com` 获取最新版本的签名清单（`latest/<runtime>.json`），用安装程序内置的公钥验证签名，并确认产品、仓库、runtime、软件包名称和获取位置一致。它从该固定位置获取 ZIP，不跟随重定向；放置前会核对清单记录的长度和 SHA-256、所含文件列表及各自的 hash、commit 和 runtime，以及可执行文件的 Authenticode 签名（签名者正确且带时间戳的 Valid）。这些核对与启动时自动更新的条件相同。如果无法获取清单或核对失败，它将不写入任何内容并停止。它不会从源代码构建，也不会切换到本地克隆。

默认安装位置为 `%USERPROFILE%\.local\Prunlet`。它放置 `bin\prunlet.exe`、注册用脚本和共同指令，并以与启动时自动更新相同的格式，在 `source-info.json` 中记录来源、分支、commit 和软件包的 hash。默认不会写入 Codex 等 AI 工具的配置文件或文件夹，只注册维护任务和更新任务。

自动更新会在 MCP 主机启动 Prunlet MCP 时，以及由安装程序注册的更新任务（每天 12:30 和登录 10 分钟后，无窗口）中，检查 `https://prunlet.kagayoi.com` 上的签名清单，并在旧 MCP 和维护进程退出后切换。只会应用比已安装版本更新的版本。由于有更新任务，未注册 MCP 的电脑也会跟进最新版本。自动更新不需要重新从源代码构建。运行产品可执行文件不需要另外安装 .NET 运行时或 VC 运行时。正在使用时不会强制结束，而是在下次 MCP 启动时再次检查。如果通信、下载或验证失败，则不应用任何内容；只要更新前的状态安全保留，就使用当前版本。

自动更新只信任发布专用密钥所做的签名。发布 workflow 会先确认 commit 包含在 `main` 中，并构建、签名和验证软件包，然后才为清单签名。验证机制和信任范围请参阅[启动时自动更新的设计](DESIGN.md#起動時自動更新)。

更新数据在专用的 2 GiB 配额内管理。已确认的区域会被复用，未知数据和中断的输出会被保留。空间不足时推迟更新，注册表的恢复数据不会因此被清理。

#### 注册到 MCP 主机

对于 Toolport、Claude Code 等 MCP 主机，请把已安装的启动脚本注册为 stdio 服务器。PowerShell 7 请指定为 `pwsh`（Microsoft Store 版为 `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`），不要使用 AI 工具自带的 PowerShell 的绝对路径。

```text
command: pwsh
args:    -NoProfile -NonInteractive -File %USERPROFILE%\.local\Prunlet\bin\start-prunlet-mcp.ps1 -ExecutablePath %USERPROFILE%\.local\Prunlet\bin\prunlet.exe -ConfigPath %USERPROFILE%\.local\Prunlet\config.json
```

请把 `%USERPROFILE%` 替换为实际的绝对路径。不需要 `-CodexHome`。仅当 Codex 中残留以前的注册时，启动脚本才会以只读方式检查并保护该注册。

#### 注册到 Codex（可选）

只有在要一次性注册到 Codex 时，才在上面的安装程序中添加 `-RegisterCodex -RegisterAgentInstructions`。它会把 Codex 的 MCP、原生可执行文件的 hook，以及从一开始就使用 Prunlet CLI 的共同指令注册到 CodexHome（`CODEX_HOME`，未指定时为 `%USERPROFILE%\.codex`）。

使用 `-RegisterCodex` 安装或更新后，请在 Codex 中打开 `/hooks`，确认 Prunlet hook 的定义并信任它。安装程序不会更改信任设置，会通过结果中的 `requiresHookTrust` 告知需要此操作。请重启 Codex，确认 MCP、共同指令和 hook 已加载。注册和解除的详情请参阅[集成步骤](docs/integration.md#登録)。

上面的 `-RegisterAgentInstructions` 是一个显式选项，它注册 Codex home 中的 `PRUNLET.md`，以及共同 `AGENTS.md` 中的专用引用和已安装可执行文件与配置的绝对路径。它不会在各仓库中追加内容，而是指示 Codex 从一开始就在 CMD 上用 Prunlet CLI 删除。如果可执行文件或配置的路径本身无法在 CMD 中安全表示，请在执行前选择使用同一核心的 MCP。若不想更改共同指令，请去掉此选项。

自动更新只会切换到包括共同指令在内的注册内容都无需更改的候选版本。如果已注册的 `PRUNLET.md` 与候选版本的差异仅在于 CRLF 与 LF 的换行格式，会直接使用现有文件。如果需要覆盖注册，或检测到用户更改了注册，则暂缓更新。使用安装程序手动更新时，若已注册共同指令，请指定相同的 `-RegisterAgentInstructions`。详情请参阅[代理共同指令](docs/integration.md#エージェント共通指示)。

从没有自动更新机制的旧版本首次更新或手动更新时，请重新获取并运行最新的安装程序。现有的 `config.json` 会被保留，只有保留容量的一次性迁移除外。旧的恢复数据由[显式迁移](#旧版文件恢复数据的迁移)处理。无需预先注册要删除的文件夹。旧的 `-AllowedRoot` 作为兼容参数被接受，但不会限制删除范围。可以用 `-InstallDirectory` 更改安装位置。不会把用户的克隆路径注册到 AI 工具的配置中。

如果现有的托管安装位于 Git 仓库中，且更新在常规的保存位置检查时停止，可以在重新获取的安装程序中添加 `-UpdateManagedInstallation -InstallDirectory <现有安装的绝对路径>`。它会确认现有配置、安装信息和产品 hash 一致，并更新没有被 Git 跟踪的文件、且被 Git 排除或与当前共同 CLI 注册一致的安装。无法确认的安装会被保留并停止。条件详情请参阅[集成步骤](docs/integration.md#手動の設定準備)。

若要求与事先确认的 release 一致，可以添加 `-ExpectedCommitSha <40 位 SHA>`。如果最新 release 的 commit 不同，会在安装前停止。

下载的 bootstrap 文件是临时文件。确认安装结果后，请只清理该 bootstrap 专用目录。不要把应用的安装位置和恢复数据纳入清理。

如果存在更新前产品或注册前 Codex 配置的备份，安装结果的 `updateBackupDirectory` 会显示保存位置。默认为 `%LOCALAPPDATA%\Prunlet\Backups\install-<ID>`。确认运行和注册内容、且不再需要恢复后，请只清理该次安装的备份。集成脚本的配置备份请参阅[集成步骤](docs/integration.md)。

在 AppData 被转向到其他实际位置的 MSIX 环境中，可以用 `-UpdateBackupRoot <实际位置的绝对路径>` 明确指定更新备份的上级目录。每次安装会在其下创建 `install-<ID>`。如果每次安装的保存位置与仓库、Codex home、安装位置、工作位置或恢复数据重叠，则会被拒绝。如果残留旧的 PowerShell hook，安装程序会用 Prunlet 把它移入 Windows 回收站，并把结果保存到同一更新备份的 `retired-products.json` 中。

## 初始配置

在 macOS 和 Linux 上，配置由各操作系统的安装步骤创建。以下是 Windows 的初始配置步骤。使用 Windows 安装程序时已完成初始化。手动配置时请指定注册表恢复数据的保存位置。`init` 不会覆盖现有配置。

```powershell
$config = Join-Path $env:USERPROFILE '.local\Prunlet\config.json'
$backup = Join-Path $env:USERPROFILE '.local\Prunlet\recovery'
New-Item -ItemType Directory -Path (Split-Path $config), $backup -Force | Out-Null
$exe = Join-Path $env:USERPROFILE '.local\Prunlet\bin\prunlet.exe'
& $exe --config $config init --backup-directory $backup
& $exe --config $config migrate --dry-run
& $exe --config $config migrate --apply
```

`backupDirectory` 是存放注册表 snapshot 和迁移前旧数据的受保护区域。它不保存新的文件删除的记录或内容。注册表记录保存在专用的 `.registry-records-v1` 下。配置中的 `allowedRoots` 和旧的 `--allowed-root` 是兼容输入，不用作删除范围的允许列表。

手动 `init` 只创建配置。使用注册表前，请用 `migrate --dry-run` 确认对象并运行 `migrate --apply`。如果尚未迁移，注册表的常规操作会以 `migration_required` 停止，且不会自动搜索旧的文件区域。文件删除不依赖注册表的迁移状态。

```json
{
  "schema": 1,
  "backupDirectory": "C:\\Users\\you\\.local\\Prunlet\\recovery",
  "retentionDays": 7,
  "maxRecoveryBytes": 1073741824
}
```

## 删除与恢复

### 在 Apple Silicon Mac 上删除与恢复

使用 [macOS 的 CLI 示例](docs/macos.md)中的可执行文件和配置的绝对路径。用 `delete --dry-run -- <绝对路径>` 确认对象，实际执行时去掉 `--dry-run`。`recycled` 的项目可以从 Finder 的废纸篓恢复。若为 `ambiguous`，请检查原路径和废纸篓，不要自动重新发送相同的删除。

若要等待协作式 `flock` 释放，请用 `delete-queue -- <绝对路径>` 登记，并用 `delete-queue-status <job-id>` 确认最终结果。在 `pending` 期间可用 `delete-queue-cancel <job-id>` 取消。

### 在 Linux 上删除与恢复

使用 [Linux 的 CLI 示例](docs/linux.md#初回インストール)中的可执行文件和配置的绝对路径。用 `delete --dry-run -- <绝对路径>` 确认对象，实际执行时去掉 `--dry-run`。可以移动与主目录 Trash 位于同一挂载点的项目。`recycled` 的项目可以用支持 freedesktop Trash 的文件管理器恢复。若为 `ambiguous`，请检查原路径和回收站，不要自动重新发送相同的删除。

### 在 Windows 上删除与恢复

在支持正式 sandbox 权限申请、且有效配置要求并允许该申请的 Codex 主机上，实际删除从第一次起就附带申请执行。dry-run 不保证拥有访问回收站的权限。需要 Windows 管理员权限时，代理会在允许范围内启动管理员 CMD，并用同一已安装的 CLI 和配置执行并确认结果。需要本人的 UAC 同意时会给出操作指引。Prunlet 本身不会自动提权，也不会改用其他途径重试被拒绝或结果不明的操作。详情请参阅[集成步骤](docs/integration.md#sandboxとゴミ箱へのアクセス)。

```cmd
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete --dry-run --paths-file C:\work\delete-paths.json
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete --paths-file C:\work\delete-paths.json
```

请把可执行文件和配置替换为已安装的绝对路径。在 Codex 中请指定 `cmd.exe` 和 `login: false`。含空格、Unicode、数量多或路径长的目标，不要在 shell 中展开，请以 UTF-8 JSON 数组中的绝对路径传递。`--paths-file` 接受 1 到 256 项，最大 1 MiB。

```json
["C:\\work\\project\\unused.txt", "C:\\work\\project\\other.txt"]
```

空文件夹用普通的 `delete`，有内容的文件夹用 `delete --recursive --paths-file <绝对 JSON 路径>` 处理。简单路径也可以用 `delete [--dry-run] [--recursive] -- <绝对路径> [...]` 传递。不处理通配符、网络路径和未知的 reparse 标记。对于链接，删除链接本身，不遍历链接目标。与 `NUL`、`NUL.txt` 等 Windows 保留名称同名的普通文件，会在确认实体后不经额外确认地永久删除，不会进入回收站。保留名称的上级、目录和链接不在此例外范围内。对于普通名称，只有当 Windows 返回对象对回收站来说过大，或回收站不可用且已确认目标驱动器的立即删除设置时，才会在核对原始实体和名称后尝试永久删除。

结果包含 `dryRun`、`items` 和 `warnings`。请检查各项目的 `path`、`kind`、`status` 和可选的 `error`。状态为 `recycled`、`permanently_deleted`、`would_recycle`、`would_permanently_delete`、`already_absent`、`failed` 和 `ambiguous`，不返回文件的操作 ID、backupPath、hash 或 size。`permanently_deleted` 表示所指定的原始名称未移入回收站就被删除，并不意味着其他硬链接或备份被清除。`failed` 和 `ambiguous` 不视为成功。

`recycled` 项目请从 Windows 回收站恢复。`permanently_deleted` 的原始名称无法从回收站恢复。Prunlet 没有文件恢复命令或 MCP 工具。如果回收站的恢复位置已有项目，请在 Windows 界面中确认冲突，不要覆盖。

如果因正在使用、权限不足或路径限制等无法移动，请检查结果。失败时的 `error` 包含对象和错误代码，正在使用时还会返回观测到的占用者的 PID、名称和文件路径。在递归的永久删除中，结果的 `path` 和 `error` 中的 `Target` 指所指定的文件夹。存在 `Failure entry` 时，它给出失败位置的绝对路径，占用者的诊断也以该位置为对象。诊断的范围和限制请参阅[集成步骤](docs/integration.md#使用中のファイルと同時実行)。如果在 Shell 处理期间对象名称被替换，可能会有别的实体被移入回收站。Prunlet 会核对移动后的实体，不一致时以 `ambiguous` 停止。若为 `ambiguous`，请检查原对象和 Windows 回收站，不会自动重新发送相同的删除。对于保留名称的普通文件，dry-run 返回 `would_permanently_delete`，不会实际删除。除此之外的 `would_recycle` 是对输入的预先检查结果，无法预测执行时是否会变为 `permanently_deleted`，也无法预测实际移动是否成功。

位于 Windows 回收站期间的访问权限，以及从恢复位置上级继承的权限，同样遵循 Windows 的行为。硬链接不仅共享内容，也共享 ACL，因此移入回收站时的权限变化也会反映到留存的别名上。

### 等待使用中的文件后再删除

在 Windows 上要等待正在使用的对象时，请在删除开始前登记到显式的 `delete-queue`。普通的 `delete` 仍同步返回结果。

```cmd
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue --paths-file C:\work\delete-paths.json
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue-status <job-id>
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue-cancel <job-id>
```

非空文件夹用 `delete-queue --recursive --paths-file <绝对 JSON 路径>` 指定，简单路径用 `delete-queue [--recursive] -- <绝对路径> [...]` 指定。登记的响应并不表示删除完成。请用返回的作业 ID 确认状态和最终结果。在 MCP 中，向现有的 `delete_files` 指定 `action: "enqueue"`、`"status"` 或 `"cancel"`。详情请参阅[集成步骤](docs/integration.md#明示的な削除待機キュー)。

队列在删除前固定对象、上级以及递归对象的子项的实体，只对共享冲突和锁定冲突无限期等待。等待期间若实体发生变化则中止，删除开始后的失败或结果不明不会重新发送。同一用户和 Windows 会话最多 8 个（包括完成后仍保留的）。只能在等待期间取消，最终结果保留 1 小时。作业只存在于专用临时 worker 的内存中，既不是文件操作记录也不是恢复用 ID。如果因过期或操作系统、worker 结束而无法确认结果，请检查原对象和 Windows 回收站，不要自动重新发送相同的删除。

## 注册表的删除与恢复

可以在明确指定的 32/64 位 view 中，备份并删除获准的本地 HKCU、HKLM、HKU 的键或值。键的路径请用绝对路径，在 `--` 之后只传一个。省略 `--value-name` 时对象为键，指定时对象为字面意义上的值名称。默认值的名称为空，因此可以使用 PowerShell 不会丢掉空参数的 `--value-name=`。删除值不能与 `--recursive` 同时使用。删除含子键的键需要 `--recursive`。

键名中的冒号也可以原样指定。例如 `HKCU:\Software\Example\C:#Program Files#Fixture.exe` 的末尾是一个键名。含 `%5C` 等的名称也按字面处理，不进行 URL 解码。

```text
prunlet --config <绝对路径> registry-delete --view 64 --dry-run -- HKCU:\Software\Example
prunlet --config <绝对路径> registry-delete --view 64 --recursive -- HKCU:\Software\Example
prunlet --config <绝对路径> registry-delete --view 32 --value-name= -- HKCU:\Software\Example
prunlet --config <绝对路径> registry-restore <operation-id>
```

备份数据和记录以仅当前用户和 SYSTEM 可访问的权限保护，检测到权限被篡改的记录不会被恢复或清理，而是保留。保存键的数据和完整的访问权限需要 `SeSecurityPrivilege`。在权限不足或无法使用事务的环境中，会在删除前停止，不会自动提权。恢复值时不会更改上级键的访问权限。对于 64 位 Windows、64 位进程和 view 64 中受保护的对象，可以在删除、dry-run 和恢复中分别明确指定 `--access-mode backupRestore`。这需要当前有效令牌具有 `SeBackupPrivilege` 和 `SeRestorePrivilege`，并不是通过更改 ACL 或所有权来获得访问。默认为 `normal`，不会自动切换。也请确认[选择条件和限制](docs/integration.md#保護されたレジストリへの明示アクセス)。保存格式和事务的设计请参阅 [DESIGN.md](DESIGN.md#レジストリの削除と復元)。

恢复会写回原来的 view，不会覆盖或合并现有的键和值（包括空的默认值）。即使恢复 Owner/SACL 的权限不足，也会回滚并保留备份。根本身、HKCR/HKCC、远程、相对指定、任意注册表链接、未知的 schema、metadata 以及无法验证的恢复记录都会被拒绝。键的 class 也会保存，但不恢复最后写入时间，volatile 键也会作为非 volatile 键恢复。commit 之后、记录确定之前中断的操作会作为状态不明而保留，并拒绝自动清理和恢复。

有效用户的 `Software\Classes` 别名下的项目，会在验证目标后处理。删除和恢复需要对别名额外的写入权限，别名的最后写入时间可能会改变。dry-run 不会写入。Classes 本身和其他链接不在对象范围内。支持的路径和安全条件请参阅[设计](DESIGN.md#レジストリの削除と復元)。

在源自 MSIX 的虚拟 view 中出现 6801 时，可以使用[常规 Windows 的显式会话](docs/integration.md#通常windowsのレジストリを明示して操作する)。用户在常规桌面上启动有期限的会话，并从选择了专用配置的 CLI 或 MCP 连接。不会从虚拟 view 自动切换或自动提权，也不会把虚拟 view 中的键当作常规 Windows 上同名的键。

如果会话的响应丢失，请保留通知的 `operationId`，并用 `prunlet --config <同一配置的绝对路径> registry-reconcile <operation-id>` 确认已保存的结果。不要重新发送相同的删除，也不要根据键当前是否存在来推测不明的 commit 结果。恢复成功后会消耗 snapshot，因此不能用同一操作 ID 重复恢复。

注册表的 `--dry-run` 也会以与实际删除相同的对象、权限和递归范围确认与事务的连接，无法连接时失败。它不写入或删除数据，也不保证后续实际删除一定成功。

## 恢复数据的保留与自动整理

`retentionDays`（默认 7 天）和 `maxRecoveryBytes`（默认 1 GiB）只适用于注册表 snapshot。Windows 回收站由 Windows 保留和清理，Prunlet 不把它纳入容量、期限或 purge 的对象。

旧配置中未设置容量上限的迁移标记或其值小于 1 时，latest 安装会一次性把 `maxRecoveryBytes` 更新为 1 GiB。迁移后用户更改的容量在再次更新时也会保留。

`operations` 列出注册表的操作 ID，`purge <registry-operation-id> [--dry-run | --apply]` 和 `maintain [--dry-run | --apply] [--audit-records]` 也只用于注册表。省略选项时只做检查。在删除前以及显式和定期维护中，会检查受保护的记录并应用保留条件。状态不明的记录和无法验证的 snapshot 会被保留。

## 旧版文件恢复数据的迁移

`migrate [--dry-run | --apply [--if-needed | --retry-legacy-discard]]` 会整理旧版文件的备份数据和操作记录，并把旧的注册表记录移到专用 namespace。**旧版文件的恢复兼容性就此结束。** 能确认归属的旧文件区域不会展开格式、检查内容 hash、复制或打包，而是原样送入 Windows 回收站。已经在回收站中的文件仍由 Windows 管理。不会把旧数据转换为可恢复的形式，也不会创建原始权限的参考文件。

安装程序在注册和停用旧 backend 之后运行 `migrate --apply --if-needed`。已评估的中央旧区域不会重新扫描，更新时还会检查后来连接的驱动器上已确认归属的旧数据。常规的文件删除、列表和维护不会扫描旧的操作目录。归属确认和重新扫描的设计请参阅 [DESIGN.md](DESIGN.md#旧ファイル復元データの明示移行)。

注册表的保留、完整 ACL 和非覆盖恢复保持不变。有注册表痕迹的区域、无法确认归属的区域，以及离线或权限不足的区域会附带警告保留下来，仅因文件整理未完成不会停止注册表的常规操作。

中断或结果不明的文件整理不会自动重新发送，而是在固定的空 gate 处停止。只有在检查原文件夹和 Windows 回收站之后，才用 `migrate --apply --retry-legacy-discard` 明确地重新评估。安装程序不会自动指定此确认。迁移开始后即使安装失败，也会保留新的可执行文件、配置和注册，不会回退到旧的 binary。

## MCP

`prunlet --config <绝对路径> mcp` 启动本地 stdio 服务器。标准输出专用于 JSON-RPC。支持 MCP 协议的 2025-11-25、2025-06-18 和 2024-11-05。`delete_files` 的同步删除可在 Windows、macOS 和 Linux 上使用，等待登记、查询和取消可在 Windows 和 macOS 上使用。表中的其他工具仅适用于 Windows。

| 工具 | 参数 | 用途 |
| --- | --- | --- |
| `delete_files` | 同步：`paths`，可选 `dryRun`、`recursive`。等待登记：`action: "enqueue"`、`paths`，可选 `recursive`。查询和取消：仅 `action: "status"` / `"cancel"` 和 `jobId` | 文件和文件夹的同步删除，以及等待登记、查询和取消。等待登记不支持 `dryRun` |
| `delete_registry` | `path`、`view`（`"32"`/`"64"`），可选 `valueName`、`recursive`、`dryRun`、`accessMode` | 保留后删除键或值。空的 `valueName` 表示默认值。`accessMode` 为 `normal` 或 `backupRestore` |
| `restore_registry` | `operationId`，可选 `accessMode` | 以非覆盖方式恢复注册表操作。受保护的访问在恢复时也要明确选择 |
| `reconcile_registry` | `operationId` | 断开后读取并确认已保存的结果。不会重新发送删除或恢复 |
| `list_operations` | 无 | 列出注册表的操作 ID（能否恢复在恢复时验证） |

服务器通过 `instructions` 告知删除工具的用途。在 Windows 上通常使用 CLI，在已安装的可执行文件或配置无法在 CMD 中安全表示等情况下可以使用 MCP。注册表的 `purge` 是显式的 CLI 操作。

## 与 Codex 的集成

Windows 的共同 MCP 注册、删除输入的检查和解除步骤，请参阅[集成步骤](docs/integration.md)。macOS 和 Linux 的 MCP 注册示例和 hook 的启动参数，请参阅各自的安装步骤。[macOS 安装步骤](docs/macos.md) · [Linux 安装步骤](docs/linux.md)

hook 会拒绝识别出的直接删除，并把检测到的命令和 shell 的解释作为理由返回。shell 不明时，判定只是候选，并不是已确认的本地删除。如果搜索字符串或远程脚本被拒绝，请确认[hook 的检查范围](docs/integration.md#hookの検査範囲)。hook 引导的 CLI 用于删除获准的主机操作系统上的对象。它不会自动替换删除或输入。Codex 端的审批和管理策略保持有效。

## 因保存位置的实体验证而停止时

在 MSIX 版应用中，AppData 中的新文件夹可能被转向到包专用的 LocalCache。常规目录的转向会解析为实际位置处理，但如果无法验证上级链接或实际位置与属性，则会停止。请确认错误中显示的路径和属性，不要禁用验证，必要时把可执行文件、配置和恢复数据放到 `%USERPROFILE%\.local\Prunlet` 等专用目录。不建议把 Codex 包的 LocalCache 用作恢复数据的永久保存位置。

## 无法使用注册表事务时

因 `ERROR_RM_NOT_ACTIVE`（6801）等导致目标 hive 的事务无法使用时，不会 commit 删除，会保留原始数据并停止。即使在同一台电脑上，各 hive 的可用性也可能不同。不要切换到非事务删除，也不要在未确认原因的情况下修复操作系统，请确认错误以及目标 hive 和 view。

## 开发资料

开发时的构建和工作规范请参阅 [AGENTS.md](AGENTS.md)，结构和设计决策请参阅 [DESIGN.md](DESIGN.md)，E2E 的运行方法和验证范围请参阅[验证步骤](docs/verification.md)。

[English](README.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md) | **繁體中文** | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português (Brasil)](README.pt-BR.md)

# Prunlet — Anti “blocked by policy”

Prunlet 是一款適用於 Windows、Apple Silicon Mac 與 Linux 的工具，它將 AI 代理的檔案與資料夾刪除集中到專用的 CLI 與 MCP 伺服器，以減少清理因 `blocked by policy` 而中斷。它統一採用從一開始就把獲准的刪除交給 Prunlet 的用法。

檔案與資料夾通常會移至作業系統的資源回收筒。Prunlet 不儲存檔案的操作紀錄、操作 ID 或用於還原的 snapshot，從資源回收筒還原與保留交由作業系統處理。它不隨附於任何特定的 AI 工具，而是以獨立應用程式安裝。可以視需要向各 AI 工具註冊 MCP 伺服器、CLI 與 hook；hook 會檢查並拒絕直接刪除，並引導使用 CLI 的步驟。發行者為 Kagayoi。

它處理檔案與空資料夾，明確指定 `--recursive` 時可刪除整個資料夾。不會追蹤連結目標。移至資源回收筒後的硬式連結仍與留存的別名共用內容。有條件的永久刪除與[登錄的刪除與還原](#登錄的刪除與還原)僅適用於 Windows。

## 作為 `blocked by policy` 對策的用法

在 AI 產生的 `Remove-Item`、`rm` 等刪除命令容易讓清理中斷的環境中，從一開始就把獲准的刪除交給 Prunlet CLI。Apple Silicon Mac 與 Linux 上的 Codex 使用安裝時放置的 CLI 與設定。[macOS 安裝步驟](docs/macos.md) · [Linux 安裝步驟](docs/linux.md)

在 Windows 上依下列順序使用：

1. 使用下方[安裝與更新](#安裝與更新)中的命令，將 Prunlet 以獨立應用程式安裝。它不會變更 AI 工具的設定檔。
2. 向所使用的 AI 工具（MCP 主機）註冊[註冊到 MCP 主機](#註冊到-mcp-主機)中的啟動命令。若直接呼叫 CLI，請將已安裝 CLI 與設定的絕對路徑寫入 AI 工具的指示。若要一次註冊到 Codex，請使用[註冊到 Codex（選用）](#註冊到-codex選用)。
3. 照常委託工作與清理。CLI 使用已安裝 CLI 與設定的絕對路徑，從 CMD（`shell: cmd.exe`、`login: false`）直接呼叫。不需要在每個存放庫加入相同的指示。

若要明確委託清理，可以這樣說：

> 請從一開始就用 Prunlet CLI 清理這次建立的不需要的暫存檔案與工作資料夾。

含空格、Unicode、長路徑或多個目標時，請用 `--paths-file` 傳入 UTF-8 的 JSON 清單；對非空資料夾請明確指定 `--recursive`。實際命令與還原方法請參閱[刪除與還原](#刪除與還原)。

hook 是偵測並拒絕直接刪除、引導使用 CLI 步驟的輔助手段，不會自動轉換命令。為避免反覆失敗與重試，基本做法是透過共同指示從第一次起就使用 CLI。主機與作業系統的權限、核准與管理原則仍然適用。如果對 Prunlet 本身的呼叫被拒絕，請停止，不要改用其他途徑重試。註冊與檢查範圍的詳細資訊請參閱[整合步驟](docs/integration.md)。

Codex 傳送到 Mac 等處的 PowerShell 指令碼，請依[hook 整合步驟](docs/integration.md#hookの検査範囲)中明確的子 PowerShell 形式傳遞。Codex 的 hook 輸入不包含執行用的 shell，因此僅指定 `shell: "pwsh"` 無法區分 here-string 中的刪除。

## 安裝與更新

在發佈來源移轉到 `https://prunlet.kagayoi.com` 的簽署資訊清單之前發佈的版本（透過 GitHub Releases 散佈的版本）無法偵測到新版本。它們會繼續以目前版本執行而不會損壞，但不會自動移轉，因此請重新安裝一次：Windows 請再次執行 [Windows](#windows) 中的安裝程式命令；Apple Silicon Mac 與 Linux 請依照 [macOS 重新安裝步驟](docs/macos.md#旧版からの再導入)或 [Linux 重新安裝步驟](docs/linux.md#旧版からの再導入)操作。

### Apple Silicon Mac

`scripts/Install-Prunlet.sh` 從 `https://prunlet.kagayoi.com` 取得簽署資訊清單，以指令碼內建的公開金鑰驗證，再從清單記錄的位置取得 `prunlet-update-osx-arm64.zip`。它一次完成下載、大小與 SHA-256 核對、簽署與公證驗證，以及到專用資料夾的全新安裝（步驟見 [macOS 安裝步驟](docs/macos.md)）。請使用它顯示的設定行，自行向 Codex 等註冊 MCP。已註冊的 MCP 會在啟動時檢查更新，使用中時延後到之後的啟動。

### Linux

從 `https://prunlet.kagayoi.com` 取得與 CPU 對應的 `prunlet-linux-x64.tar.gz` 或 `prunlet-linux-arm64.tar.gz`。其取得位置與 SHA-256 記錄在簽署資訊清單中。如需簡便取得，`https://prunlet.kagayoi.com/download/latest/` 下也有固定名稱的套件與同名的 `.sha256` 檔案。

簽署資訊清單與總和檢查碼的核對、放置到專用目錄以及註冊到 Codex，請參閱 [Linux 安裝步驟](docs/linux.md#初回インストール)。依步驟放置後，官方發行版會在 MCP 啟動時檢查更新，使用中時延後到之後的啟動。

### Windows

支援 Windows x64 與 ARM64。下方的安裝程式會從 `https://prunlet.kagayoi.com` 取得最新版本的已簽署預先建置套件（`prunlet-update-<runtime>.zip`）並放置。只需要 PowerShell 7，不需要 Rust、MSVC 建置工具與 Windows SDK。

| 安裝目標 | 安裝程式選項 |
| --- | --- |
| Windows x64 | `-Runtime win-x64`（預設） |
| Windows ARM64 | `-Runtime win-arm64` |

在 Windows ARM64 上，請在下方的命令中明確指定 `-Runtime`。若選擇 x64 模擬，請指定 `-Runtime win-x64`。

```powershell
$installerDirectory = Join-Path ([IO.Path]::GetTempPath()) ('Prunlet\bootstrap-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $installerDirectory | Out-Null
$installer = Join-Path $installerDirectory 'Install-Prunlet.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/1llum1n4t1s/Prunlet/main/scripts/Install-Prunlet.ps1' -OutFile $installer
pwsh -NoProfile -File $installer
```

安裝與更新不需要 GitHub 帳戶、登入或權杖。

安裝程式從 `https://prunlet.kagayoi.com` 取得最新版本的簽署資訊清單（`latest/<runtime>.json`），以安裝程式內建的公開金鑰驗證簽章，並確認產品、存放庫、runtime、套件名稱與取得位置一致。它從該固定位置取得 ZIP，不跟隨重新導向；放置前會核對清單記錄的長度與 SHA-256、所含檔案清單及各自的 hash、commit 與 runtime，以及執行檔的 Authenticode 簽章（簽署者正確且附時間戳記的 Valid）。這些核對與啟動時自動更新的條件相同。如果無法取得清單或核對失敗，它不會寫入任何內容並停止。它不會從原始碼建置，也不會切換到本機複製。

預設安裝位置為 `%USERPROFILE%\.local\Prunlet`。它放置 `bin\prunlet.exe`、註冊用指令碼與共同指示，並以與啟動時自動更新相同的格式，在 `source-info.json` 中記錄來源、分支、commit 與套件的 hash。預設不會寫入 Codex 等 AI 工具的設定檔或資料夾，只註冊維護工作與更新工作。

自動更新會在 MCP 主機啟動 Prunlet MCP 時，以及由安裝程式註冊的更新工作（每天 12:30 與登入 10 分鐘後，無視窗）中，檢查 `https://prunlet.kagayoi.com` 上的簽署資訊清單，並在舊 MCP 與維護處理程序結束後切換。只會套用比已安裝版本更新的版本。由於有更新工作，未註冊 MCP 的電腦也會跟上最新版本。自動更新不需要重新從原始碼建置。執行產品執行檔不需要另外安裝 .NET 執行階段或 VC 執行階段。使用中時不會強制結束，而是在下次 MCP 啟動時再次檢查。如果通訊、下載或驗證失敗，則不套用任何內容；只要更新前的狀態安全保留，就使用目前的版本。

自動更新只信任發佈專用金鑰所做的簽章。發佈 workflow 會先確認 commit 包含在 `main` 中，並建置、簽署與驗證套件，之後才為資訊清單簽署。驗證機制與信任範圍請參閱[啟動時自動更新的設計](DESIGN.md#起動時自動更新)。

更新資料在專用的 2 GiB 配額內管理。已確認的區域會被重複使用，未知資料與中斷的輸出會被保留。空間不足時延後更新，登錄的復原資料不會因此被清理。

#### 註冊到 MCP 主機

對於 Toolport、Claude Code 等 MCP 主機，請將已安裝的啟動指令碼註冊為 stdio 伺服器。PowerShell 7 請指定為 `pwsh`（Microsoft Store 版為 `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`），不要使用 AI 工具隨附的 PowerShell 的絕對路徑。

```text
command: pwsh
args:    -NoProfile -NonInteractive -File %USERPROFILE%\.local\Prunlet\bin\start-prunlet-mcp.ps1 -ExecutablePath %USERPROFILE%\.local\Prunlet\bin\prunlet.exe -ConfigPath %USERPROFILE%\.local\Prunlet\config.json
```

請將 `%USERPROFILE%` 替換為實際的絕對路徑。不需要 `-CodexHome`。僅當 Codex 中殘留先前的註冊時，啟動指令碼才會以唯讀方式檢查並保護該註冊。

#### 註冊到 Codex（選用）

只有在要一次註冊到 Codex 時，才在上方的安裝程式中加入 `-RegisterCodex -RegisterAgentInstructions`。它會將 Codex 的 MCP、原生執行檔的 hook，以及從一開始就使用 Prunlet CLI 的共同指示註冊到 CodexHome（`CODEX_HOME`，未指定時為 `%USERPROFILE%\.codex`）。

使用 `-RegisterCodex` 安裝或更新後，請在 Codex 中開啟 `/hooks`，確認 Prunlet hook 的定義並信任它。安裝程式不會變更信任設定，會透過結果中的 `requiresHookTrust` 告知需要此操作。請重新啟動 Codex，確認 MCP、共同指示與 hook 已載入。註冊與解除的詳細資訊請參閱[整合步驟](docs/integration.md#登録)。

上方的 `-RegisterAgentInstructions` 是一個明確選項，它註冊 Codex home 中的 `PRUNLET.md`，以及共同 `AGENTS.md` 中的專用參照與已安裝執行檔和設定的絕對路徑。它不會在各存放庫中追加內容，而是指示 Codex 從一開始就在 CMD 上用 Prunlet CLI 刪除。如果執行檔或設定的路徑本身無法在 CMD 中安全表示，請在執行前選擇使用同一核心的 MCP。若不想變更共同指示，請拿掉此選項。

自動更新只會切換到包含共同指示在內的註冊內容都不需變更的候選版本。如果已註冊的 `PRUNLET.md` 與候選版本的差異僅在於 CRLF 與 LF 的換行格式，會直接使用現有檔案。如果需要覆寫註冊，或偵測到使用者變更了註冊，則暫緩更新。使用安裝程式手動更新時，若已註冊共同指示，請指定相同的 `-RegisterAgentInstructions`。詳細資訊請參閱[代理共同指示](docs/integration.md#エージェント共通指示)。

從沒有自動更新機制的舊版本首次更新或手動更新時，請重新取得並執行最新的安裝程式。現有的 `config.json` 會被保留，只有保留容量的一次性移轉除外。舊的復原資料由[明確移轉](#舊版檔案復原資料的移轉)處理。不需要預先註冊要刪除的資料夾。舊的 `-AllowedRoot` 作為相容引數被接受，但不會限制刪除範圍。可以用 `-InstallDirectory` 變更安裝位置。不會將使用者的複製路徑註冊到 AI 工具的設定中。

如果現有的受管理安裝位於 Git 存放庫中，且更新在一般的儲存位置檢查時停止，可以在重新取得的安裝程式中加入 `-UpdateManagedInstallation -InstallDirectory <現有安裝的絕對路徑>`。它會確認現有設定、安裝資訊與產品 hash 一致，並更新沒有被 Git 追蹤的檔案、且被 Git 排除或與目前共同 CLI 註冊一致的安裝。無法確認的安裝會被保留並停止。條件的詳細資訊請參閱[整合步驟](docs/integration.md#手動の設定準備)。

若要求與事先確認的 release 一致，可以加入 `-ExpectedCommitSha <40 位 SHA>`。如果最新 release 的 commit 不同，會在安裝前停止。

下載的 bootstrap 檔案是暫存檔。確認安裝結果後，請只清理該 bootstrap 專用目錄。不要將應用程式的安裝位置與復原資料納入清理。

如果存在更新前產品或註冊前 Codex 設定的備份，安裝結果的 `updateBackupDirectory` 會顯示儲存位置。預設為 `%LOCALAPPDATA%\Prunlet\Backups\install-<ID>`。確認運作與註冊內容、且不再需要復原後，請只清理該次安裝的備份。整合指令碼的設定備份請參閱[整合步驟](docs/integration.md)。

在 AppData 被重新導向到其他實際位置的 MSIX 環境中，可以用 `-UpdateBackupRoot <實際位置的絕對路徑>` 明確指定更新備份的上層目錄。每次安裝會在其下建立 `install-<ID>`。如果每次安裝的儲存位置與存放庫、Codex home、安裝位置、工作位置或復原資料重疊，則會被拒絕。如果殘留舊的 PowerShell hook，安裝程式會用 Prunlet 將它移至 Windows 資源回收筒，並將結果儲存到同一更新備份的 `retired-products.json` 中。

## 初始設定

在 macOS 與 Linux 上，設定由各作業系統的安裝步驟建立。以下是 Windows 的初始設定步驟。使用 Windows 安裝程式時已完成初始化。手動設定時請指定登錄復原資料的儲存位置。`init` 不會覆寫現有設定。

```powershell
$config = Join-Path $env:USERPROFILE '.local\Prunlet\config.json'
$backup = Join-Path $env:USERPROFILE '.local\Prunlet\recovery'
New-Item -ItemType Directory -Path (Split-Path $config), $backup -Force | Out-Null
$exe = Join-Path $env:USERPROFILE '.local\Prunlet\bin\prunlet.exe'
& $exe --config $config init --backup-directory $backup
& $exe --config $config migrate --dry-run
& $exe --config $config migrate --apply
```

`backupDirectory` 是存放登錄 snapshot 與移轉前舊資料的受保護區域。它不儲存新的檔案刪除的紀錄或內容。登錄紀錄儲存在專用的 `.registry-records-v1` 下。設定中的 `allowedRoots` 與舊的 `--allowed-root` 是相容輸入，不作為刪除範圍的允許清單。

手動 `init` 只建立設定。使用登錄前，請用 `migrate --dry-run` 確認對象並執行 `migrate --apply`。如果尚未移轉，登錄的一般操作會以 `migration_required` 停止，且不會自動搜尋舊的檔案區域。檔案刪除不依賴登錄的移轉狀態。

```json
{
  "schema": 1,
  "backupDirectory": "C:\\Users\\you\\.local\\Prunlet\\recovery",
  "retentionDays": 7,
  "maxRecoveryBytes": 1073741824
}
```

## 刪除與還原

### 在 Apple Silicon Mac 上刪除與還原

使用 [macOS 的 CLI 範例](docs/macos.md)中的執行檔與設定的絕對路徑。用 `delete --dry-run -- <絕對路徑>` 確認對象，實際執行時拿掉 `--dry-run`。`recycled` 的項目可以從 Finder 的垃圾桶還原。若為 `ambiguous`，請檢查原路徑與垃圾桶，不要自動重新傳送相同的刪除。

若要等待協作式 `flock` 釋放，請用 `delete-queue -- <絕對路徑>` 登記，並用 `delete-queue-status <job-id>` 確認最終結果。在 `pending` 期間可用 `delete-queue-cancel <job-id>` 取消。

### 在 Linux 上刪除與還原

使用 [Linux 的 CLI 範例](docs/linux.md#初回インストール)中的執行檔與設定的絕對路徑。用 `delete --dry-run -- <絕對路徑>` 確認對象，實際執行時拿掉 `--dry-run`。可以移動與家目錄 Trash 位於同一掛載點的項目。`recycled` 的項目可以用支援 freedesktop Trash 的檔案管理員還原。若為 `ambiguous`，請檢查原路徑與垃圾桶，不要自動重新傳送相同的刪除。

### 在 Windows 上刪除與還原

在支援正式 sandbox 權限申請、且有效設定要求並允許該申請的 Codex 主機上，實際刪除從第一次起就附帶申請執行。dry-run 不保證擁有存取資源回收筒的權限。需要 Windows 系統管理員權限時，代理會在允許範圍內啟動系統管理員 CMD，並用同一已安裝的 CLI 與設定執行並確認結果。需要本人的 UAC 同意時會給予操作引導。Prunlet 本身不會自動提升權限，也不會改用其他途徑重試被拒絕或結果不明的操作。詳細資訊請參閱[整合步驟](docs/integration.md#sandboxとゴミ箱へのアクセス)。

```cmd
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete --dry-run --paths-file C:\work\delete-paths.json
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete --paths-file C:\work\delete-paths.json
```

請將執行檔與設定替換為已安裝的絕對路徑。在 Codex 中請指定 `cmd.exe` 與 `login: false`。含空格、Unicode、數量多或路徑長的目標，不要在 shell 中展開，請以 UTF-8 JSON 陣列中的絕對路徑傳遞。`--paths-file` 接受 1 到 256 項，最大 1 MiB。

```json
["C:\\work\\project\\unused.txt", "C:\\work\\project\\other.txt"]
```

空資料夾用一般的 `delete`，有內容的資料夾用 `delete --recursive --paths-file <絕對 JSON 路徑>` 處理。簡單路徑也可以用 `delete [--dry-run] [--recursive] -- <絕對路徑> [...]` 傳遞。不處理萬用字元、網路路徑與未知的 reparse 標記。對於連結，刪除連結本身，不走訪連結目標。與 `NUL`、`NUL.txt` 等 Windows 保留名稱同名的一般檔案，會在確認實體後不經額外確認地永久刪除，不會進入資源回收筒。保留名稱的上層、目錄與連結不在此例外範圍內。對於一般名稱，只有當 Windows 傳回對象對資源回收筒而言過大，或資源回收筒無法使用且已確認目標磁碟機的立即刪除設定時，才會在核對原始實體與名稱後嘗試永久刪除。

結果包含 `dryRun`、`items` 與 `warnings`。請檢查各項目的 `path`、`kind`、`status` 與選用的 `error`。狀態為 `recycled`、`permanently_deleted`、`would_recycle`、`would_permanently_delete`、`already_absent`、`failed` 與 `ambiguous`，不傳回檔案的操作 ID、backupPath、hash 或 size。`permanently_deleted` 表示所指定的原始名稱未移至資源回收筒就被刪除，並不代表其他硬式連結或備份被清除。`failed` 與 `ambiguous` 不視為成功。

`recycled` 項目請從 Windows 資源回收筒還原。`permanently_deleted` 的原始名稱無法從資源回收筒還原。Prunlet 沒有檔案還原命令或 MCP 工具。如果資源回收筒的還原位置已有項目，請在 Windows 畫面中確認衝突，不要覆寫。

如果因使用中、權限不足或路徑限制等無法移動，請檢查結果。失敗時的 `error` 包含對象與錯誤代碼，使用中時還會傳回觀測到的占用者的 PID、名稱與檔案路徑。在遞迴的永久刪除中，結果的 `path` 與 `error` 中的 `Target` 指所指定的資料夾。存在 `Failure entry` 時，它提供失敗位置的絕對路徑，占用者的診斷也以該位置為對象。診斷的範圍與限制請參閱[整合步驟](docs/integration.md#使用中のファイルと同時実行)。如果在 Shell 處理期間對象名稱被替換，可能會有別的實體被移至資源回收筒。Prunlet 會核對移動後的實體，不一致時以 `ambiguous` 停止。若為 `ambiguous`，請檢查原對象與 Windows 資源回收筒，不會自動重新傳送相同的刪除。對於保留名稱的一般檔案，dry-run 傳回 `would_permanently_delete`，不會實際刪除。除此之外的 `would_recycle` 是對輸入的事前檢查結果，無法預測執行時是否會變為 `permanently_deleted`，也無法預測實際移動是否成功。

位於 Windows 資源回收筒期間的存取權限，以及從還原位置上層繼承的權限，同樣遵循 Windows 的行為。硬式連結不僅共用內容，也共用 ACL，因此移至資源回收筒時的權限變更也會反映到留存的別名上。

### 等待使用中的檔案後再刪除

在 Windows 上要等待使用中的對象時，請在刪除開始前登記到明確的 `delete-queue`。一般的 `delete` 仍同步傳回結果。

```cmd
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue --paths-file C:\work\delete-paths.json
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue-status <job-id>
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue-cancel <job-id>
```

非空資料夾用 `delete-queue --recursive --paths-file <絕對 JSON 路徑>` 指定，簡單路徑用 `delete-queue [--recursive] -- <絕對路徑> [...]` 指定。登記的回應並不表示刪除完成。請用傳回的工作 ID 確認狀態與最終結果。在 MCP 中，向現有的 `delete_files` 指定 `action: "enqueue"`、`"status"` 或 `"cancel"`。詳細資訊請參閱[整合步驟](docs/integration.md#明示的な削除待機キュー)。

佇列在刪除前固定對象、上層以及遞迴對象的子項目的實體，只對共用違規與鎖定違規無限期等待。等待期間若實體發生變化則中止，刪除開始後的失敗或結果不明不會重新傳送。同一使用者與 Windows 工作階段最多 8 個（包括完成後仍保留的）。只能在等待期間取消，最終結果保留 1 小時。工作只存在於專用暫時 worker 的記憶體中，既不是檔案操作紀錄也不是還原用 ID。如果因過期或作業系統、worker 結束而無法確認結果，請檢查原對象與 Windows 資源回收筒，不要自動重新傳送相同的刪除。

## 登錄的刪除與還原

可以在明確指定的 32/64 位元 view 中，備份並刪除獲准的本機 HKCU、HKLM、HKU 的機碼或值。機碼的路徑請用絕對路徑，在 `--` 之後只傳一個。省略 `--value-name` 時對象為機碼，指定時對象為字面上的值名稱。預設值的名稱為空，因此可以使用 PowerShell 不會丟掉空引數的 `--value-name=`。刪除值不能與 `--recursive` 同時使用。刪除含子機碼的機碼需要 `--recursive`。

機碼名稱中的冒號也可以原樣指定。例如 `HKCU:\Software\Example\C:#Program Files#Fixture.exe` 的末尾是一個機碼名稱。含 `%5C` 等的名稱也依字面處理，不進行 URL 解碼。

```text
prunlet --config <絕對路徑> registry-delete --view 64 --dry-run -- HKCU:\Software\Example
prunlet --config <絕對路徑> registry-delete --view 64 --recursive -- HKCU:\Software\Example
prunlet --config <絕對路徑> registry-delete --view 32 --value-name= -- HKCU:\Software\Example
prunlet --config <絕對路徑> registry-restore <operation-id>
```

備份資料與紀錄以僅目前使用者與 SYSTEM 可存取的權限保護，偵測到權限遭竄改的紀錄不會被還原或清理，而是保留。儲存機碼的資料與完整的存取權需要 `SeSecurityPrivilege`。在權限不足或無法使用交易的環境中，會在刪除前停止，不會自動提升權限。還原值時不會變更上層機碼的存取權。對於 64 位元 Windows、64 位元處理程序與 view 64 中受保護的對象，可以在刪除、dry-run 與還原中分別明確指定 `--access-mode backupRestore`。這需要目前有效權杖具有 `SeBackupPrivilege` 與 `SeRestorePrivilege`，並不是透過變更 ACL 或擁有權來取得存取。預設為 `normal`，不會自動切換。也請確認[選擇條件與限制](docs/integration.md#保護されたレジストリへの明示アクセス)。儲存格式與交易的設計請參閱 [DESIGN.md](DESIGN.md#レジストリの削除と復元)。

還原會寫回原本的 view，不會覆寫或合併現有的機碼與值（包括空的預設值）。即使還原 Owner/SACL 的權限不足，也會復原並保留備份。根本身、HKCR/HKCC、遠端、相對指定、任意登錄連結、未知的 schema、metadata 以及無法驗證的還原紀錄都會被拒絕。機碼的 class 也會儲存，但不還原最後寫入時間，volatile 機碼也會作為非 volatile 機碼還原。commit 之後、紀錄確定之前中斷的操作會作為狀態不明而保留，並拒絕自動清理與還原。

有效使用者的 `Software\Classes` 別名下的項目，會在驗證目的地後處理。刪除與還原需要對別名額外的寫入權限，別名的最後寫入時間可能會改變。dry-run 不會寫入。Classes 本身與其他連結不在對象範圍內。支援的路徑與安全條件請參閱[設計](DESIGN.md#レジストリの削除と復元)。

在源自 MSIX 的虛擬 view 中出現 6801 時，可以使用[一般 Windows 的明確工作階段](docs/integration.md#通常windowsのレジストリを明示して操作する)。使用者在一般桌面上啟動有期限的工作階段，並從選擇了專用設定的 CLI 或 MCP 連線。不會從虛擬 view 自動切換或自動提升權限，也不會將虛擬 view 中的機碼當作一般 Windows 上同名的機碼。

如果工作階段的回應遺失，請保留通知的 `operationId`，並用 `prunlet --config <同一設定的絕對路徑> registry-reconcile <operation-id>` 確認已儲存的結果。不要重新傳送相同的刪除，也不要根據機碼目前是否存在來推測不明的 commit 結果。還原成功後會消耗 snapshot，因此不能用同一操作 ID 重複還原。

登錄的 `--dry-run` 也會以與實際刪除相同的對象、權限與遞迴範圍確認與交易的連線，無法連線時失敗。它不寫入或刪除資料，也不保證後續實際刪除一定成功。

## 復原資料的保留與自動整理

`retentionDays`（預設 7 天）與 `maxRecoveryBytes`（預設 1 GiB）只適用於登錄 snapshot。Windows 資源回收筒由 Windows 保留與清理，Prunlet 不將它納入容量、期限或 purge 的對象。

舊設定中未設定容量上限的移轉標記或其值小於 1 時，latest 安裝會一次性將 `maxRecoveryBytes` 更新為 1 GiB。移轉後使用者變更的容量在再次更新時也會保留。

`operations` 列出登錄的操作 ID，`purge <registry-operation-id> [--dry-run | --apply]` 與 `maintain [--dry-run | --apply] [--audit-records]` 也只用於登錄。省略選項時只做檢查。在刪除前以及明確與定期維護中，會檢查受保護的紀錄並套用保留條件。狀態不明的紀錄與無法驗證的 snapshot 會被保留。

## 舊版檔案復原資料的移轉

`migrate [--dry-run | --apply [--if-needed | --retry-legacy-discard]]` 會整理舊版檔案的備份資料與操作紀錄，並將舊的登錄紀錄移到專用 namespace。**舊版檔案的還原相容性就此結束。** 能確認歸屬的舊檔案區域不會展開格式、檢查內容 hash、複製或打包，而是原樣送至 Windows 資源回收筒。已經在資源回收筒中的檔案仍由 Windows 管理。不會將舊資料轉換為可還原的形式，也不會建立原始權限的參考檔案。

安裝程式在註冊與停用舊 backend 之後執行 `migrate --apply --if-needed`。已評估的中央舊區域不會重新掃描，更新時還會檢查之後連接的磁碟機上已確認歸屬的舊資料。一般的檔案刪除、清單與維護不會掃描舊的操作目錄。歸屬確認與重新掃描的設計請參閱 [DESIGN.md](DESIGN.md#旧ファイル復元データの明示移行)。

登錄的保留、完整 ACL 與非覆寫還原維持不變。有登錄痕跡的區域、無法確認歸屬的區域，以及離線或權限不足的區域會附帶警告保留下來，僅因檔案整理未完成不會停止登錄的一般操作。

中斷或結果不明的檔案整理不會自動重新傳送，而是在固定的空 gate 處停止。只有在檢查原資料夾與 Windows 資源回收筒之後，才用 `migrate --apply --retry-legacy-discard` 明確地重新評估。安裝程式不會自動指定此確認。移轉開始後即使安裝失敗，也會保留新的執行檔、設定與註冊，不會退回到舊的 binary。

## MCP

`prunlet --config <絕對路徑> mcp` 啟動本機 stdio 伺服器。標準輸出專用於 JSON-RPC。支援 MCP 協定的 2025-11-25、2025-06-18 與 2024-11-05。`delete_files` 的同步刪除可在 Windows、macOS 與 Linux 上使用，等待登記、查詢與取消可在 Windows 與 macOS 上使用。表中的其他工具僅適用於 Windows。

| 工具 | 引數 | 用途 |
| --- | --- | --- |
| `delete_files` | 同步：`paths`，選用 `dryRun`、`recursive`。等待登記：`action: "enqueue"`、`paths`，選用 `recursive`。查詢與取消：僅 `action: "status"` / `"cancel"` 與 `jobId` | 檔案與資料夾的同步刪除，以及等待登記、查詢與取消。等待登記不支援 `dryRun` |
| `delete_registry` | `path`、`view`（`"32"`/`"64"`），選用 `valueName`、`recursive`、`dryRun`、`accessMode` | 保留後刪除機碼或值。空的 `valueName` 代表預設值。`accessMode` 為 `normal` 或 `backupRestore` |
| `restore_registry` | `operationId`，選用 `accessMode` | 以非覆寫方式還原登錄操作。受保護的存取在還原時也要明確選擇 |
| `reconcile_registry` | `operationId` | 中斷連線後讀取並確認已儲存的結果。不會重新傳送刪除或還原 |
| `list_operations` | 無 | 列出登錄的操作 ID（能否還原在還原時驗證） |

伺服器透過 `instructions` 告知刪除工具的用途。在 Windows 上通常使用 CLI，在已安裝的執行檔或設定無法在 CMD 中安全表示等情況下可以使用 MCP。登錄的 `purge` 是明確的 CLI 操作。

## 與 Codex 的整合

Windows 的共同 MCP 註冊、刪除輸入的檢查與解除步驟，請參閱[整合步驟](docs/integration.md)。macOS 與 Linux 的 MCP 註冊範例與 hook 的啟動引數，請參閱各自的安裝步驟。[macOS 安裝步驟](docs/macos.md) · [Linux 安裝步驟](docs/linux.md)

hook 會拒絕識別出的直接刪除，並將偵測到的命令與 shell 的解讀作為理由傳回。shell 不明時，判定只是候選，並不是已確認的本機刪除。如果搜尋字串或遠端指令碼被拒絕，請確認[hook 的檢查範圍](docs/integration.md#hookの検査範囲)。hook 引導的 CLI 用於刪除獲准的主機作業系統上的對象。它不會自動替換刪除或輸入。Codex 端的核准與管理原則維持有效。

## 因儲存位置的實體驗證而停止時

在 MSIX 版應用程式中，AppData 中的新資料夾可能被重新導向到套件專用的 LocalCache。一般目錄的重新導向會解析為實際位置處理，但如果無法驗證上層連結或實際位置與屬性，則會停止。請確認錯誤中顯示的路徑與屬性，不要停用驗證，必要時將執行檔、設定與復原資料放到 `%USERPROFILE%\.local\Prunlet` 等專用目錄。不建議將 Codex 套件的 LocalCache 用作復原資料的永久儲存位置。

## 無法使用登錄交易時

因 `ERROR_RM_NOT_ACTIVE`（6801）等導致目標 hive 的交易無法使用時，不會 commit 刪除，會保留原始資料並停止。即使在同一台電腦上，各 hive 的可用性也可能不同。不要切換到非交易刪除，也不要在未確認原因的情況下修復作業系統，請確認錯誤以及目標 hive 與 view。

## 開發資料

開發時的建置與工作規範請參閱 [AGENTS.md](AGENTS.md)，結構與設計決策請參閱 [DESIGN.md](DESIGN.md)，E2E 的執行方法與驗證範圍請參閱[驗證步驟](docs/verification.md)。

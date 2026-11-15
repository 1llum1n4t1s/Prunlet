[English](README.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | **한국어** | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português (Brasil)](README.pt-BR.md)

# Prunlet — Anti “blocked by policy”

Prunlet은 AI 에이전트의 파일·폴더 삭제를 전용 CLI와 MCP 서버로 모아 `blocked by policy`로 인해 정리가 멈추는 일을 줄이는 Windows, Apple Silicon Mac, Linux용 도구입니다. 허용된 삭제를 처음부터 Prunlet에 맡기는 사용 방식으로 통일합니다.

파일과 폴더는 보통 OS의 휴지통으로 이동합니다. Prunlet은 파일의 작업 기록, 작업 ID, 복원용 snapshot을 저장하지 않으며, 휴지통에서의 복원과 보관은 OS에 맡깁니다. 특정 AI 도구에 포함되지 않고 독립된 앱으로 설치합니다. 각 AI 도구에 MCP 서버, CLI, hook을 선택적으로 등록할 수 있으며, hook은 직접 삭제를 검사·거부하고 CLI 절차를 안내합니다. 제공자는 Kagayoi입니다.

파일과 빈 폴더를 다루며, `--recursive`를 명시하면 폴더 전체를 삭제할 수 있습니다. 링크 대상은 따라가지 않습니다. 하드 링크는 휴지통으로 이동한 뒤에도 남아 있는 별칭과 내용을 공유합니다. 조건부 영구 삭제와 [레지스트리 삭제·복원](#레지스트리-삭제복원)은 Windows 전용입니다.

## `blocked by policy` 대책으로서의 사용법

AI가 생성한 `Remove-Item`이나 `rm` 같은 삭제 명령으로 정리가 멈추기 쉬운 환경에서는 허용된 삭제를 처음부터 Prunlet CLI에 맡깁니다. Apple Silicon Mac과 Linux의 Codex는 설치할 때 배치한 CLI와 구성을 사용합니다. [macOS 설치 절차](docs/macos.md) · [Linux 설치 절차](docs/linux.md)

Windows에서는 다음 순서로 사용합니다.

1. 아래 [설치 및 업데이트](#설치-및-업데이트)의 명령으로 Prunlet을 독립된 앱으로 설치합니다. AI 도구의 구성 파일은 건드리지 않습니다.
2. 사용하는 AI 도구(MCP 호스트)에 [MCP 호스트에 등록](#mcp-호스트에-등록)의 시작 명령을 등록합니다. CLI를 직접 호출하려면 설치된 CLI와 구성의 절대 경로를 AI 도구의 지시에 적습니다. Codex에 한꺼번에 등록하려면 [Codex에 등록(선택 사항)](#codex에-등록선택-사항)을 사용합니다.
3. 평소처럼 작업과 정리를 요청합니다. CLI는 설치된 CLI와 구성의 절대 경로를 사용해 CMD(`shell: cmd.exe`, `login: false`)에서 직접 호출합니다. 각 리포지토리에 같은 지시를 추가할 필요는 없습니다.

정리를 명시적으로 요청하려면 예를 들어 다음과 같이 말합니다.

> 이번에 만든 불필요한 임시 파일과 작업 폴더를 처음부터 Prunlet CLI로 정리해 주세요.

공백, Unicode, 긴 경로, 여러 대상은 UTF-8 JSON 목록을 `--paths-file`로 전달하고, 비어 있지 않은 폴더에는 `--recursive`를 명시합니다. 실제 명령과 복원 방법은 [삭제·복원](#삭제복원)을 참조하십시오.

hook은 직접 삭제를 감지·거부하고 CLI 절차를 안내하는 보조 수단이며, 명령을 자동으로 변환하지 않습니다. 실패와 재시도를 반복하지 않도록 공통 지시를 통해 첫 시도부터 CLI를 사용하는 것을 기본으로 합니다. 호스트와 OS의 권한, 승인, 관리 정책은 계속 적용됩니다. Prunlet 호출 자체가 거부되면 중지하고 다른 경로로 재시도하지 않습니다. 등록과 검사 범위의 자세한 내용은 [연동 절차](docs/integration.md)를 참조하십시오.

Codex가 Mac 등으로 보내는 PowerShell 스크립트는 [hook 연동 절차](docs/integration.md#hookの検査範囲)에 있는 명시적인 자식 PowerShell 형식으로 전달합니다. Codex의 hook 입력에는 실행 shell이 전달되지 않으므로 `shell: "pwsh"`만 지정해서는 here-string 안의 삭제를 구별할 수 없습니다.

## 설치 및 업데이트

배포 원본을 `https://prunlet.kagayoi.com`의 서명된 매니페스트로 옮기기 전에 배포된 버전(GitHub Releases로 배포하던 버전)은 새 버전을 감지할 수 없습니다. 현재 버전으로 계속 동작하며 망가지지는 않지만 자동으로 이전되지 않으므로 한 번만 다시 설치하십시오. Windows는 [Windows](#windows)의 설치 프로그램 명령을 다시 실행합니다. Apple Silicon Mac과 Linux는 [macOS 재설치 절차](docs/macos.md#旧版からの再導入) 또는 [Linux 재설치 절차](docs/linux.md#旧版からの再導入)를 따릅니다.

### Apple Silicon Mac

`scripts/Install-Prunlet.sh`가 `https://prunlet.kagayoi.com`에서 서명된 매니페스트를 받아 스크립트에 내장된 공개 키로 검증하고, 거기에 기록된 위치에서 `prunlet-update-osx-arm64.zip`을 받습니다. 다운로드, 크기와 SHA-256 확인, 서명과 공증 검증, 전용 폴더로의 새 설치까지 한 번에 수행합니다(절차는 [macOS 설치 절차](docs/macos.md)). Codex 등의 MCP 등록은 표시되는 구성 줄을 사용해 직접 합니다. 등록된 MCP는 시작할 때 업데이트를 확인하고, 사용 중이면 다음 시작 이후로 미룹니다.

### Linux

CPU에 맞는 `prunlet-linux-x64.tar.gz` 또는 `prunlet-linux-arm64.tar.gz`를 `https://prunlet.kagayoi.com`에서 받습니다. 받을 위치와 SHA-256은 서명된 매니페스트에 기록되어 있습니다. 간편하게 받으려면 `https://prunlet.kagayoi.com/download/latest/`에 고정 이름의 패키지와 같은 이름의 `.sha256` 파일도 있습니다.

서명된 매니페스트와 체크섬 확인, 전용 디렉터리로의 배치, Codex 등록은 [Linux 설치 절차](docs/linux.md#初回インストール)를 참조하십시오. 절차대로 배치하면 공식 배포판은 MCP 시작 시 업데이트를 확인하고, 사용 중이면 다음 시작 이후로 미룹니다.

### Windows

Windows x64와 ARM64를 지원합니다. 아래 설치 프로그램은 `https://prunlet.kagayoi.com`에서 최신 버전의 서명된 사전 빌드 패키지(`prunlet-update-<runtime>.zip`)를 받아 배치합니다. 필요한 것은 PowerShell 7뿐이며 Rust, MSVC 빌드 도구, Windows SDK는 필요하지 않습니다.

| 설치 대상 | 설치 프로그램 옵션 |
| --- | --- |
| Windows x64 | `-Runtime win-x64`(기본값) |
| Windows ARM64 | `-Runtime win-arm64` |

Windows ARM64에서는 아래 실행 명령에 `-Runtime`을 명시하십시오. x64 에뮬레이션을 선택하려면 `-Runtime win-x64`를 지정합니다.

```powershell
$installerDirectory = Join-Path ([IO.Path]::GetTempPath()) ('Prunlet\bootstrap-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $installerDirectory | Out-Null
$installer = Join-Path $installerDirectory 'Install-Prunlet.ps1'
Invoke-WebRequest 'https://raw.githubusercontent.com/1llum1n4t1s/Prunlet/main/scripts/Install-Prunlet.ps1' -OutFile $installer
pwsh -NoProfile -File $installer
```

설치와 업데이트에는 GitHub 계정, 로그인, 토큰이 필요하지 않습니다.

설치 프로그램은 `https://prunlet.kagayoi.com`에서 최신 버전의 서명된 매니페스트(`latest/<runtime>.json`)를 받아 설치 프로그램에 내장된 공개 키로 서명을 검증하고, 제품, 리포지토리, runtime, 패키지 이름, 받을 위치가 일치하는지 확인합니다. ZIP은 그 고정된 위치에서 리디렉션을 따르지 않고 받으며, 배치하기 전에 매니페스트에 기록된 길이와 SHA-256, 포함된 파일 목록과 각 hash, commit과 runtime, 실행 파일의 Authenticode 서명(서명자와 타임스탬프가 있는 Valid)을 확인합니다. 확인 조건은 시작 시 자동 업데이트와 같습니다. 매니페스트를 받을 수 없거나 확인에 실패하면 아무것도 쓰지 않고 중지합니다. 소스에서 빌드하거나 로컬 클론으로 전환하지 않습니다.

기본 설치 위치는 `%USERPROFILE%\.local\Prunlet`입니다. `bin\prunlet.exe`와 등록용 스크립트, 공통 지시를 배치하고, `source-info.json`에 출처, 브랜치, commit, 패키지 hash를 시작 시 자동 업데이트와 같은 형식으로 기록합니다. 기본적으로 Codex 등 AI 도구의 구성 파일·폴더에는 쓰지 않으며, 유지 관리 작업과 업데이트 작업만 등록합니다.

자동 업데이트는 MCP 호스트가 Prunlet MCP를 시작할 때와 설치 프로그램이 등록하는 업데이트 작업(매일 12:30과 로그온 10분 후, 창 없음)에서 `https://prunlet.kagayoi.com`의 서명된 매니페스트를 확인하고, 이전 MCP와 유지 관리 프로세스가 종료되었을 때 전환합니다. 설치된 버전보다 새로운 버전만 적용합니다. 업데이트 작업이 있으므로 MCP를 등록하지 않은 PC도 최신 버전을 따라갑니다. 자동 업데이트에는 소스 재빌드가 필요하지 않습니다. 제품 실행 파일을 실행하는 데 .NET 런타임이나 VC 런타임을 추가로 설치할 필요가 없습니다. 사용 중이면 강제로 종료하지 않고 다음 MCP 시작 시 다시 확인합니다. 통신, 다운로드, 검증에 실패하면 아무것도 적용하지 않으며, 업데이트 전 상태가 안전하게 유지되는 한 현재 버전을 사용합니다.

자동 업데이트는 배포 전용 키로 만든 서명만 신뢰합니다. 배포 workflow는 commit이 `main`에 포함되어 있는지 확인하고 패키지를 빌드, 서명, 검증한 뒤에만 매니페스트에 서명합니다. 검증 방식과 신뢰 범위는 [시작 시 자동 업데이트 설계](DESIGN.md#起動時自動更新)를 참조하십시오.

업데이트 데이터는 전용 2 GiB 한도 안에서 관리합니다. 확인된 영역은 재사용하고, 알 수 없는 데이터와 중단된 출력은 보존합니다. 공간이 부족하면 업데이트를 미루며, 레지스트리 복구 데이터는 이를 위해 정리하지 않습니다.

#### MCP 호스트에 등록

Toolport나 Claude Code 같은 MCP 호스트에는 설치된 시작 스크립트를 stdio 서버로 등록합니다. PowerShell 7은 `pwsh`(Microsoft Store 버전은 `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`)로 지정하고, AI 도구에 포함된 PowerShell의 절대 경로는 사용하지 않습니다.

```text
command: pwsh
args:    -NoProfile -NonInteractive -File %USERPROFILE%\.local\Prunlet\bin\start-prunlet-mcp.ps1 -ExecutablePath %USERPROFILE%\.local\Prunlet\bin\prunlet.exe -ConfigPath %USERPROFILE%\.local\Prunlet\config.json
```

`%USERPROFILE%`는 실제 절대 경로로 바꿉니다. `-CodexHome`은 필요하지 않습니다. 시작 스크립트는 Codex에 이전 등록이 남아 있는 경우에만 그 등록을 읽기 전용으로 확인하고 보호합니다.

#### Codex에 등록(선택 사항)

Codex에 한꺼번에 등록하는 경우에만 위 설치 프로그램에 `-RegisterCodex -RegisterAgentInstructions`를 추가합니다. Codex의 MCP, 네이티브 실행 파일의 hook, 처음부터 Prunlet CLI를 사용하는 공통 지시를 CodexHome(`CODEX_HOME`, 지정하지 않으면 `%USERPROFILE%\.codex`)에 등록합니다.

`-RegisterCodex`를 지정해 설치·업데이트한 뒤에는 Codex에서 `/hooks`를 열어 Prunlet hook의 정의를 확인하고 신뢰하십시오. 설치 프로그램은 신뢰 설정을 변경하지 않으며, 결과의 `requiresHookTrust`로 이 작업이 필요함을 알립니다. Codex를 다시 시작하고 MCP, 공통 지시, hook이 로드되었는지 확인하십시오. 등록과 해제의 자세한 내용은 [연동 절차](docs/integration.md#登録)를 참조하십시오.

위 `-RegisterAgentInstructions`는 Codex home의 `PRUNLET.md`와, 공통 `AGENTS.md`의 전용 참조 및 설치된 실행 파일과 구성의 절대 경로를 등록하는 명시적 옵션입니다. 각 리포지토리에 내용을 추가하지 않고, 처음부터 CMD의 Prunlet CLI로 삭제하도록 Codex에 지시합니다. 실행 파일이나 구성의 경로 자체를 CMD에서 안전하게 표현할 수 없으면 실행 전에 같은 코어를 사용하는 MCP를 선택합니다. 공통 지시를 변경하고 싶지 않으면 이 옵션을 빼십시오.

자동 업데이트는 공통 지시를 포함한 등록 내용을 변경할 필요가 없는 후보로만 전환합니다. 등록된 `PRUNLET.md`와 후보의 차이가 CRLF와 LF의 줄 바꿈 형식뿐이면 기존 파일을 그대로 사용합니다. 등록을 덮어써야 하거나 사용자가 등록을 변경한 것이 감지되면 업데이트를 보류합니다. 설치 프로그램으로 수동 업데이트할 때 공통 지시를 등록해 두었다면 같은 `-RegisterAgentInstructions`를 지정하십시오. 자세한 내용은 [에이전트 공통 지시](docs/integration.md#エージェント共通指示)를 참조하십시오.

자동 업데이트 기능이 없는 이전 버전에서 처음 업데이트하거나 수동으로 업데이트할 때는 최신 설치 프로그램을 다시 받아 실행합니다. 기존 `config.json`은 보관 용량의 일회성 마이그레이션을 제외하고 유지합니다. 이전 복구 데이터는 [명시적 마이그레이션](#이전-파일-복구-데이터-마이그레이션)으로 다룹니다. 삭제할 폴더를 미리 등록할 필요는 없습니다. 이전 `-AllowedRoot`는 호환 인수로 받아들이지만 삭제 범위를 제한하지 않습니다. 설치 위치는 `-InstallDirectory`로 변경할 수 있습니다. 사용자의 클론 경로를 AI 도구의 구성에 등록하는 일은 없습니다.

기존 관리형 설치가 Git 리포지토리 아래에 있어 일반 저장 위치 검사에서 업데이트가 멈추는 경우, 다시 받은 설치 프로그램에 `-UpdateManagedInstallation -InstallDirectory <기존 설치의 절대 경로>`를 추가할 수 있습니다. 기존 구성, 설치 정보, 제품 hash가 일치하는지 확인하고, Git 추적 대상이 없으며 Git에서 제외되었거나 현재 공통 CLI 등록과 일치하는 설치를 업데이트합니다. 확인할 수 없는 설치는 보존하고 중지합니다. 조건의 자세한 내용은 [연동 절차](docs/integration.md#手動の設定準備)를 참조하십시오.

미리 확인한 release와의 일치를 요구하려면 `-ExpectedCommitSha <40자리 SHA>`를 추가할 수 있습니다. 최신 release의 commit이 다르면 설치 전에 중지합니다.

받은 bootstrap 파일은 임시 파일입니다. 설치 결과를 확인한 뒤 그 bootstrap 전용 디렉터리만 정리하십시오. 앱의 설치 위치와 복구 데이터는 정리 대상에 포함하지 않습니다.

업데이트 전 제품이나 등록 전 Codex 구성의 백업이 있으면 설치 결과의 `updateBackupDirectory`에 저장 위치가 표시됩니다. 기본값은 `%LOCALAPPDATA%\Prunlet\Backups\install-<ID>`입니다. 동작과 등록 내용을 확인하고 복구가 더 이상 필요하지 않게 된 뒤에 그 설치분의 백업만 정리하십시오. 연동 스크립트의 구성 백업은 [연동 절차](docs/integration.md)를 참조하십시오.

AppData가 다른 실제 위치로 리디렉션되는 MSIX 환경에서는 `-UpdateBackupRoot <실제 위치의 절대 경로>`로 업데이트 백업의 상위 폴더를 명시할 수 있습니다. 그 아래에 설치마다 `install-<ID>`를 만듭니다. 설치마다의 저장 위치가 리포지토리, Codex home, 설치 위치, 작업 위치, 복구 데이터와 겹치면 거부합니다. 이전 PowerShell hook이 남아 있으면 설치 프로그램은 Prunlet으로 이를 Windows 휴지통으로 옮기고, 결과를 같은 업데이트 백업의 `retired-products.json`에 저장합니다.

## 초기 구성

macOS와 Linux에서는 각 OS의 설치 절차에서 구성을 만듭니다. 다음은 Windows의 초기 구성 절차입니다. Windows 설치 프로그램을 사용했다면 이미 초기화되어 있습니다. 수동으로는 레지스트리 복구 데이터의 저장 위치를 지정합니다. `init`은 기존 구성을 덮어쓰지 않습니다.

```powershell
$config = Join-Path $env:USERPROFILE '.local\Prunlet\config.json'
$backup = Join-Path $env:USERPROFILE '.local\Prunlet\recovery'
New-Item -ItemType Directory -Path (Split-Path $config), $backup -Force | Out-Null
$exe = Join-Path $env:USERPROFILE '.local\Prunlet\bin\prunlet.exe'
& $exe --config $config init --backup-directory $backup
& $exe --config $config migrate --dry-run
& $exe --config $config migrate --apply
```

`backupDirectory`는 레지스트리 snapshot과 마이그레이션 전의 이전 데이터를 두는 보호 영역입니다. 새로운 파일 삭제의 기록이나 내용은 저장하지 않습니다. 레지스트리 기록은 전용 `.registry-records-v1` 아래에 저장합니다. 구성의 `allowedRoots`와 이전 `--allowed-root`는 호환 입력이며 삭제 범위의 허용 목록으로 사용하지 않습니다.

수동 `init`은 구성 생성만 수행합니다. 레지스트리를 사용하기 전에 `migrate --dry-run`으로 대상을 확인하고 `migrate --apply`를 실행하십시오. 마이그레이션하지 않았다면 레지스트리 일반 작업은 `migration_required`로 중지하며, 이전 파일 영역을 자동으로 탐색하지 않습니다. 파일 삭제는 레지스트리의 마이그레이션 상태에 의존하지 않습니다.

```json
{
  "schema": 1,
  "backupDirectory": "C:\\Users\\you\\.local\\Prunlet\\recovery",
  "retentionDays": 7,
  "maxRecoveryBytes": 1073741824
}
```

## 삭제·복원

### Apple Silicon Mac에서 삭제·복원

[macOS CLI 예시](docs/macos.md)에 있는 실행 파일과 구성의 절대 경로를 사용합니다. `delete --dry-run -- <절대 경로>`로 대상을 확인하고, 실행할 때는 `--dry-run`을 뺍니다. `recycled` 항목은 Finder의 휴지통에서 복원할 수 있습니다. `ambiguous`인 경우 원래 경로와 휴지통을 확인하고, 같은 삭제를 자동으로 다시 보내지 마십시오.

협조적인 `flock`의 해제를 기다리려면 `delete-queue -- <절대 경로>`로 등록하고 `delete-queue-status <job-id>`로 최종 결과를 확인합니다. 취소는 `pending`인 동안 `delete-queue-cancel <job-id>`로 합니다.

### Linux에서 삭제·복원

[Linux CLI 예시](docs/linux.md#初回インストール)의 실행 파일과 구성의 절대 경로를 사용합니다. `delete --dry-run -- <절대 경로>`로 대상을 확인하고, 실행할 때는 `--dry-run`을 뺍니다. 홈 Trash와 같은 마운트에 있는 항목을 옮길 수 있습니다. `recycled` 항목은 freedesktop Trash를 지원하는 파일 관리자로 복원할 수 있습니다. `ambiguous`인 경우 원래 경로와 휴지통을 확인하고, 같은 삭제를 자동으로 다시 보내지 마십시오.

### Windows에서 삭제·복원

정식 sandbox 권한 요청을 지원하고, 유효 구성에서 요청이 필요하며 허용되는 Codex 호스트에서는 실제 삭제를 첫 시도부터 요청과 함께 실행합니다. dry-run은 휴지통 액세스 권한을 보장하지 않습니다. Windows 관리자 권한이 필요하면 에이전트가 허용 범위 안에서 관리자 CMD를 시작하고, 같은 설치된 CLI와 구성으로 실행·결과 확인을 합니다. 본인의 UAC 동의가 필요하면 조작을 안내합니다. Prunlet 자체는 자동으로 권한을 상승하지 않으며, 거부나 결과 불명을 다른 경로로 재시도하지 않습니다. 자세한 내용은 [연동 절차](docs/integration.md#sandboxとゴミ箱へのアクセス)를 참조하십시오.

```cmd
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete --dry-run --paths-file C:\work\delete-paths.json
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete --paths-file C:\work\delete-paths.json
```

실행 파일과 구성은 설치된 절대 경로로 바꾸십시오. Codex에서는 `cmd.exe`와 `login: false`를 지정합니다. 공백, Unicode, 많은 수, 긴 대상 경로는 shell에서 확장하지 말고 UTF-8 JSON 배열의 절대 경로로 전달합니다. `--paths-file`은 1~256개, 최대 1 MiB입니다.

```json
["C:\\work\\project\\unused.txt", "C:\\work\\project\\other.txt"]
```

빈 폴더는 일반 `delete`로, 내용이 있는 폴더는 `delete --recursive --paths-file <절대 JSON 경로>`로 다룹니다. 단순한 경로는 `delete [--dry-run] [--recursive] -- <절대 경로> [...]`로도 전달할 수 있습니다. 와일드카드, 네트워크 경로, 알 수 없는 reparse 태그는 다루지 않습니다. 링크는 링크 자체를 삭제하고 링크 대상을 탐색하지 않습니다. `NUL`이나 `NUL.txt` 등 Windows 예약 이름과 같은 이름의 일반 파일은 실체를 확인한 뒤 추가 확인 없이 영구 삭제합니다. 휴지통에는 들어가지 않습니다. 예약 이름의 상위 항목, 디렉터리, 링크는 이 예외의 대상이 아닙니다. 일반 이름의 경우, Windows가 대상이 휴지통에 넣기에 너무 크다고 반환했거나, 휴지통을 사용할 수 없고 대상 드라이브의 즉시 삭제 설정을 확인한 경우에만 원래 실체와 이름을 대조해 영구 삭제를 시도합니다.

결과는 `dryRun`, `items`, `warnings`입니다. 각 항목의 `path`, `kind`, `status`와 선택적인 `error`를 확인합니다. 상태는 `recycled`, `permanently_deleted`, `would_recycle`, `would_permanently_delete`, `already_absent`, `failed`, `ambiguous`이며, 파일의 작업 ID, backupPath, hash, size는 반환하지 않습니다. `permanently_deleted`는 지정한 원래 이름을 휴지통으로 옮기지 않고 삭제했음을 나타내며, 다른 하드 링크나 백업이 지워졌다는 뜻이 아닙니다. `failed`와 `ambiguous`는 성공으로 취급하지 않습니다.

`recycled` 항목은 Windows 휴지통에서 복원합니다. `permanently_deleted`의 원래 이름은 휴지통에서 복원할 수 없습니다. Prunlet에는 파일 복원 명령이나 MCP 도구가 없습니다. 휴지통의 복원 위치에 기존 항목이 있으면 Windows 화면에서 충돌을 확인하고 덮어쓰지 마십시오.

사용 중, 권한 부족, 경로 제한 등으로 이동할 수 없으면 결과를 확인하십시오. 실패 시 `error`에는 대상과 오류 코드가 포함되며, 사용 중인 경우 관찰된 점유자의 PID, 이름, 파일 경로도 반환합니다. 재귀적 영구 삭제에서는 결과의 `path`와 `error` 안의 `Target`이 지정한 폴더를 가리킵니다. `Failure entry`가 있으면 실패한 위치의 절대 경로를 나타내며, 점유자 진단도 그 위치를 대상으로 합니다. 진단의 범위와 제약은 [연동 절차](docs/integration.md#使用中のファイルと同時実行)를 참조하십시오. Shell 처리 중에 대상 이름이 바뀌면 다른 실체가 휴지통으로 이동할 수 있습니다. Prunlet은 이동 후의 실체를 대조하고, 일치하지 않으면 `ambiguous`로 중지합니다. `ambiguous`인 경우 원래 대상과 Windows 휴지통을 확인하며, 같은 삭제를 자동으로 다시 보내지 않습니다. 예약 이름의 일반 파일은 dry-run에서 `would_permanently_delete`를 반환하며 실제로는 삭제하지 않습니다. 그 밖의 `would_recycle`은 입력의 사전 검사 결과이며, 실행 시 `permanently_deleted`가 될지나 실제 이동의 성공은 예측할 수 없습니다.

Windows 휴지통에 있는 동안의 액세스 권한과 복원 위치의 상위 폴더로부터의 권한 상속도 Windows의 동작을 따릅니다. 하드 링크는 내용뿐 아니라 ACL도 공유하므로, 휴지통으로 이동할 때의 권한 변경이 남아 있는 별칭에도 반영됩니다.

### 사용 중인 파일을 기다렸다가 삭제

Windows에서 사용 중인 대상을 기다리려면 삭제를 시작하기 전에 명시적인 `delete-queue`에 등록합니다. 일반 `delete`는 기존처럼 동기적으로 결과를 반환합니다.

```cmd
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue --paths-file C:\work\delete-paths.json
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue-status <job-id>
C:\Users\you\.local\Prunlet\bin\prunlet.exe --config C:\Users\you\.local\Prunlet\config.json delete-queue-cancel <job-id>
```

비어 있지 않은 폴더는 `delete-queue --recursive --paths-file <절대 JSON 경로>`로, 단순한 경로는 `delete-queue [--recursive] -- <절대 경로> [...]`로 지정할 수 있습니다. 등록 응답은 삭제 완료가 아닙니다. 반환된 작업 ID로 상태와 최종 결과를 확인하십시오. MCP에서는 기존 `delete_files`에 `action: "enqueue"`, `"status"`, `"cancel"`을 지정합니다. 자세한 내용은 [연동 절차](docs/integration.md#明示的な削除待機キュー)를 참조하십시오.

큐는 삭제 전에 대상, 상위 폴더, 재귀 대상의 하위 항목의 실체를 고정하고, 공유·잠금 위반만 기한 없이 기다립니다. 대기 중에 실체가 바뀌면 중단하며, 삭제 시작 후의 실패나 결과 불명은 다시 보내지 않습니다. 같은 사용자와 Windows 세션에서 최대 8개(완료 후 보관 중인 것 포함)입니다. 대기 중에만 취소할 수 있으며 최종 결과는 1시간 동안 보관합니다. 작업은 전용 임시 worker의 메모리에만 있으며, 파일 작업 기록이나 복원용 ID가 아닙니다. 만료되었거나 OS 또는 worker가 종료되어 결과를 확인할 수 없으면 원래 대상과 Windows 휴지통을 확인하고, 같은 삭제를 자동으로 다시 보내지 마십시오.

## 레지스트리 삭제·복원

허용된 로컬 HKCU, HKLM, HKU의 키 또는 값을 명시한 32/64비트 view에서 백업하고 삭제할 수 있습니다. 키 경로는 절대 경로로 지정하고 `--` 뒤에 하나만 전달합니다. `--value-name`을 생략하면 키를, 지정하면 문자 그대로의 값 이름을 대상으로 합니다. 기본값은 이름이 비어 있으므로 PowerShell에서 빈 인수가 사라지지 않는 `--value-name=`을 사용할 수 있습니다. 값 삭제와 `--recursive`는 함께 사용할 수 없습니다. 하위 키를 포함한 삭제에는 `--recursive`가 필요합니다.

키 이름에 포함된 콜론도 그대로 지정할 수 있습니다. 예를 들어 `HKCU:\Software\Example\C:#Program Files#Fixture.exe`의 끝부분은 하나의 키 이름입니다. `%5C` 등을 포함한 이름도 문자 그대로 다루며 URL 디코딩을 하지 않습니다.

```text
prunlet --config <절대 경로> registry-delete --view 64 --dry-run -- HKCU:\Software\Example
prunlet --config <절대 경로> registry-delete --view 64 --recursive -- HKCU:\Software\Example
prunlet --config <절대 경로> registry-delete --view 32 --value-name= -- HKCU:\Software\Example
prunlet --config <절대 경로> registry-restore <operation-id>
```

백업 데이터와 기록은 현재 사용자와 SYSTEM만 액세스할 수 있는 권한으로 보호하며, 권한 변조가 감지된 기록은 복원·정리하지 않고 보존합니다. 키의 데이터와 완전한 액세스 권한을 저장하려면 `SeSecurityPrivilege`가 필요합니다. 권한이 부족하거나 트랜잭션을 사용할 수 없는 환경에서는 삭제 전에 중지하며 자동으로 권한을 상승하지 않습니다. 값을 복원할 때 상위 키의 액세스 권한은 변경하지 않습니다. 64비트 Windows, 64비트 프로세스, view 64의 보호된 대상에는 삭제, dry-run, 복원마다 `--access-mode backupRestore`를 명시할 수 있습니다. 현재 유효 토큰에 `SeBackupPrivilege`와 `SeRestorePrivilege`가 필요하며, ACL이나 소유권을 변경해 액세스를 얻는 방식이 아닙니다. 기본값은 `normal`이며 자동 전환하지 않습니다. [선택 조건과 한계](docs/integration.md#保護されたレジストリへの明示アクセス)도 확인하십시오. 저장 형식과 트랜잭션 설계는 [DESIGN.md](DESIGN.md#レジストリの削除と復元)를 참조하십시오.

복원은 원래 view로 하며, 기존 키·값(빈 기본값 포함)을 덮어쓰거나 병합하지 않습니다. Owner/SACL 복원 권한이 부족한 경우에도 롤백하고 백업을 보존합니다. 루트 자체, HKCR/HKCC, 원격, 상대 지정, 임의의 레지스트리 링크, 알 수 없는 schema, metadata, 검증할 수 없는 복원 기록은 거부합니다. 키의 class도 저장하지만 마지막 쓰기 시간은 복원하지 않으며, volatile 키도 비 volatile 키로 복원합니다. commit 후 기록이 확정되기 전에 중단된 작업은 불명 상태로 보존하며, 자동 정리·복원을 거부합니다.

유효 사용자의 `Software\Classes` 별칭 아래는 대상 위치를 검증한 뒤 다룹니다. 삭제·복원에는 별칭에 대한 추가 쓰기 권한이 필요하며, 별칭의 마지막 쓰기 시간이 바뀔 수 있습니다. dry-run은 쓰기를 하지 않습니다. Classes 자체와 그 밖의 링크는 대상이 아닙니다. 지원하는 경로와 안전 조건은 [설계](DESIGN.md#レジストリの削除と復元)를 참조하십시오.

MSIX에서 비롯된 가상 view에서 6801이 발생하면 [일반 Windows의 명시적 세션](docs/integration.md#通常windowsのレジストリを明示して操作する)을 사용할 수 있습니다. 사용자가 일반 데스크톱에서 기한이 있는 세션을 시작하고, 전용 구성을 선택한 CLI·MCP에서 연결합니다. 가상 view에서 자동 전환하거나 자동으로 권한을 상승하지 않으며, 가상 view 안의 키를 일반 Windows의 같은 이름 키로 취급하지 않습니다.

세션 응답이 유실되면 통지된 `operationId`를 보관하고, `prunlet --config <같은 구성의 절대 경로> registry-reconcile <operation-id>`로 저장된 결과를 확인하십시오. 같은 삭제를 다시 보내지 말고, 알 수 없는 commit 결과를 현재 키의 존재 여부로 추측하지 마십시오. 복원에 성공하면 snapshot을 소비하므로 같은 작업 ID로 반복해서 복원할 수 없습니다.

레지스트리의 `--dry-run`은 실제 삭제와 같은 대상, 권한, 재귀 범위로 트랜잭션 연결도 확인하며, 연결할 수 없으면 실패합니다. 데이터를 쓰거나 삭제하지 않으며, 이후 실제 삭제의 성공까지 보장하지는 않습니다.

## 복구 데이터의 보관과 자동 정리

`retentionDays`(기본값 7일)와 `maxRecoveryBytes`(기본값 1 GiB)는 레지스트리 snapshot에만 적용합니다. Windows 휴지통은 Windows가 보관·정리하며, Prunlet은 이를 용량, 기한, purge의 대상에 포함하지 않습니다.

이전 구성에 용량 한도 마이그레이션 표시가 없거나 1 미만이면 latest 설치 시 한 번만 `maxRecoveryBytes`를 1 GiB로 업데이트합니다. 마이그레이션 후 사용자가 변경한 용량은 다시 업데이트해도 유지합니다.

`operations`는 레지스트리 작업 ID를 나열하며, `purge <registry-operation-id> [--dry-run | --apply]`와 `maintain [--dry-run | --apply] [--audit-records]`도 레지스트리 전용입니다. 옵션을 생략하면 검사만 합니다. 삭제 전과 명시적·정기 유지 관리에서는 보호된 기록을 검사하고 보관 조건을 적용합니다. 불명확한 기록이나 검증할 수 없는 snapshot은 보존합니다.

## 이전 파일 복구 데이터 마이그레이션

`migrate [--dry-run | --apply [--if-needed | --retry-legacy-discard]]`는 이전 파일의 백업 데이터와 작업 기록을 정리하고, 이전 레지스트리 기록을 전용 namespace로 옮깁니다. **이전 파일의 복원 호환성은 종료됩니다.** 소유를 확인할 수 있는 이전 파일 영역은 형식 전개, 내용 hash 검사, 복사, bundle화 없이 그대로 Windows 휴지통으로 보냅니다. 이미 휴지통에 있는 파일은 Windows 관리로 남습니다. 이전 데이터를 복원용으로 변환하는 처리나 원래 권한의 참조 파일은 만들지 않습니다.

설치 프로그램은 등록과 이전 backend 정리 후에 `migrate --apply --if-needed`를 실행합니다. 이미 평가한 중앙 이전 영역은 다시 검사하지 않으며, 업데이트 시에는 나중에 연결된 드라이브의 소유 확인된 이전 데이터도 확인합니다. 일반 파일 삭제, 목록, 유지 관리는 이전 작업 디렉터리를 검사하지 않습니다. 소유 확인과 재검사 설계는 [DESIGN.md](DESIGN.md#旧ファイル復元データの明示移行)를 참조하십시오.

레지스트리 보존, 완전한 ACL, 덮어쓰지 않는 복원은 유지합니다. 레지스트리 흔적이 있는 영역, 소유를 확인할 수 없는 영역, 오프라인이거나 권한이 부족한 영역은 경고와 함께 남기며, 파일 정리가 끝나지 않았다는 이유만으로 레지스트리 일반 작업을 멈추지 않습니다.

중단되었거나 결과가 불명인 파일 정리는 자동으로 다시 보내지 않고 고정된 빈 gate에서 중지합니다. 원래 폴더와 Windows 휴지통을 확인한 뒤에만 `migrate --apply --retry-legacy-discard`로 명시적으로 다시 평가하십시오. 설치 프로그램은 이 확인을 자동으로 지정하지 않습니다. 마이그레이션 시작 후 설치가 실패해도 새 실행 파일, 구성, 등록을 유지하며 이전 binary로 되돌리지 않습니다.

## MCP

`prunlet --config <절대 경로> mcp`로 로컬 stdio 서버를 시작합니다. 표준 출력은 JSON-RPC 전용입니다. MCP 프로토콜 2025-11-25, 2025-06-18, 2024-11-05를 지원합니다. `delete_files`의 동기 삭제는 Windows, macOS, Linux에서, 대기 등록·조회·취소는 Windows와 macOS에서 사용할 수 있습니다. 표의 나머지 도구는 Windows 전용입니다.

| 도구 | 인수 | 용도 |
| --- | --- | --- |
| `delete_files` | 동기: `paths`, 선택적 `dryRun`·`recursive`. 대기 등록: `action: "enqueue"`·`paths`, 선택적 `recursive`. 조회·취소: `action: "status"` / `"cancel"`·`jobId`만 | 파일·폴더의 동기 삭제, 대기 등록·조회·취소. 대기 등록은 `dryRun` 미지원 |
| `delete_registry` | `path`·`view`(`"32"`/`"64"`), 선택적 `valueName`·`recursive`·`dryRun`·`accessMode` | 키 또는 값을 보존한 뒤 삭제. 빈 `valueName`은 기본값. `accessMode`는 `normal` 또는 `backupRestore` |
| `restore_registry` | `operationId`, 선택적 `accessMode` | 레지스트리 작업을 덮어쓰지 않고 복원. 보호된 액세스는 복원 시에도 명시적으로 선택 |
| `reconcile_registry` | `operationId` | 연결이 끊긴 뒤 저장된 결과를 읽어 확인. 삭제·복원을 다시 보내지 않음 |
| `list_operations` | 없음 | 레지스트리 작업 ID 목록(복원 가능 여부는 복원 시 검증) |

서버는 삭제 도구의 용도를 `instructions`로 알립니다. Windows에서는 보통 CLI를 사용하며, 설치된 실행 파일이나 구성을 CMD에서 안전하게 표현할 수 없는 경우 등에 MCP를 사용할 수 있습니다. 레지스트리 `purge`는 명시적인 CLI 작업입니다.

## Codex와의 연동

Windows의 공통 MCP 등록, 삭제 입력 검사, 해제 절차는 [연동 절차](docs/integration.md)를 참조하십시오. macOS와 Linux의 MCP 등록 예시와 hook 시작 인수는 각 설치 절차를 참조하십시오. [macOS 설치 절차](docs/macos.md) · [Linux 설치 절차](docs/linux.md)

hook은 인식한 직접 삭제를 거부하고, 감지한 명령과 shell의 해석을 이유로 반환합니다. shell을 알 수 없는 경우는 후보로서의 판정이며 로컬 삭제로 확정된 것이 아닙니다. 검색 문자열이나 원격 스크립트가 거부되면 [hook 검사 범위](docs/integration.md#hookの検査範囲)를 확인하십시오. hook이 안내하는 CLI는 허용된 호스트 OS의 대상을 삭제하는 데 사용합니다. 삭제나 입력을 자동으로 바꾸지 않습니다. Codex 측의 승인과 관리 정책은 유지됩니다.

## 저장 위치의 실체 검증으로 중지하는 경우

MSIX 버전 앱에서는 AppData의 새 폴더가 패키지 전용 LocalCache로 리디렉션될 수 있습니다. 일반 디렉터리의 리디렉션은 실제 위치로 해석해 다루지만, 상위 링크나 실제 위치·속성을 검증할 수 없으면 중지합니다. 오류에 표시된 경로와 속성을 확인하고, 검증을 비활성화하지 말고, 필요하면 실행 파일, 구성, 복구 데이터를 `%USERPROFILE%\.local\Prunlet` 같은 전용 디렉터리에 배치하십시오. Codex 패키지의 LocalCache를 복구 데이터의 영구 저장 위치로 사용하는 것은 권장하지 않습니다.

## 레지스트리 트랜잭션을 사용할 수 없는 경우

`ERROR_RM_NOT_ACTIVE`(6801) 등으로 대상 hive의 트랜잭션을 사용할 수 없으면 삭제를 commit하지 않고 원래 데이터를 보존한 채 중지합니다. 같은 PC에서도 hive마다 사용 가능 여부가 다를 수 있습니다. 비 트랜잭션 삭제로 전환하거나 원인을 확인하지 않은 채 OS를 복구하지 말고, 오류와 대상 hive·view를 확인하십시오.

## 개발 자료

개발 시 빌드와 작업 규약은 [AGENTS.md](AGENTS.md), 구조와 설계 판단은 [DESIGN.md](DESIGN.md), E2E 실행 방법과 검증 범위는 [검증 절차](docs/verification.md)를 참조하십시오.

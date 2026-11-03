[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
# 使い捨てGitHub runner専用。既存ディスク・設定には触れず、失敗時はCIを停止する。
if ($env:GITHUB_ACTIONS -cne 'true' -or !$IsWindows) { throw 'This helper requires an ephemeral Windows GitHub Actions runner.' }
if (![IO.Path]::IsPathFullyQualified($env:RUNNER_TEMP)) { throw 'RUNNER_TEMP must be absolute.' }
$temporary = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
if ($temporary -match '["\r\n]') { throw 'RUNNER_TEMP cannot be represented safely in diskpart input.' }
for ($ancestor = Get-Item -LiteralPath $temporary -Force; $null -ne $ancestor; $ancestor = $ancestor.Parent) {
    if (!($ancestor.Attributes -band [IO.FileAttributes]::Directory) -or ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'RUNNER_TEMP ancestors must be plain directories.' }
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (!( [Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Creating the isolated CI volume requires the runner administrator token.' }
$root = Join-Path $temporary ('prunlet-immediate-' + [guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $root) { throw 'Fresh CI root unexpectedly exists.' }
$null = New-Item -ItemType Directory -Path $root
$image = Join-Path $root 'fixture.vhdx'
$letter = @('R','S','T','U','V','W','X','Y','Z') | Where-Object {
    !(Get-Volume -DriveLetter $_ -ErrorAction SilentlyContinue) -and !(Get-PSDrive -Name $_ -ErrorAction SilentlyContinue) -and !(Get-Partition -DriveLetter $_ -ErrorAction SilentlyContinue)
} | Select-Object -First 1
if (!$letter -or (Test-Path -LiteralPath $image)) { throw 'No unused CI drive or fresh image is available.' }
$diskpart = Join-Path $root 'create-volume.txt'
$commands = @("create vdisk file=`"$image`" maximum=512 type=expandable", "select vdisk file=`"$image`"", 'attach vdisk', 'create partition primary', 'format fs=ntfs quick label=PrunletCI', "assign letter=$letter", 'exit')
[IO.File]::WriteAllLines($diskpart, $commands, [Text.ASCIIEncoding]::new())
$output = & "$env:SystemRoot\System32\diskpart.exe" /s $diskpart 2>&1
$exitCode = $LASTEXITCODE
$output | Set-Content -LiteralPath (Join-Path $root 'diskpart.log')
if ($exitCode -ne 0) { throw "CI diskpart failed: $exitCode" }
$mounted = Get-DiskImage -ImagePath $image -ErrorAction Stop
if (!$mounted.Attached -or [IO.Path]::GetFullPath($mounted.ImagePath) -ine $image) { throw 'New image was not mounted as requested.' }
$disk = $mounted | Get-Disk -ErrorAction Stop
if ($disk.IsBoot -or $disk.IsSystem) { throw 'Refusing a system disk.' }
$partition = Get-Partition -DriveLetter $letter -ErrorAction Stop
$volume = $partition | Get-Volume -ErrorAction Stop
if ($partition.DiskNumber -ne $disk.Number -or $volume.FileSystem -cne 'NTFS' -or $volume.DriveLetter -ne $letter) { throw 'Mounted image, partition and NTFS drive differ.' }
$volumeId = [string]$volume.UniqueId
if ($volumeId -notmatch '^\\\\\?\\Volume(\{[0-9A-Fa-f-]{36}\})\\$') { throw 'The fresh volume has no canonical volume GUID.' }
$guid = $Matches[1]
$setting = 'Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\' + $guid
$registry = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Registry64)
try {
    $existing = $registry.OpenSubKey($setting)
    if ($existing) { $existing.Dispose(); throw 'The new volume unexpectedly has an existing Recycle Bin setting; it was preserved.' }
    $key = $registry.CreateSubKey($setting, $true)
    try {
        $key.SetValue('NukeOnDelete', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.SetValue('MaxCapacity', 5120, [Microsoft.Win32.RegistryValueKind]::DWord)
        if ($key.GetValueKind('NukeOnDelete') -ne [Microsoft.Win32.RegistryValueKind]::DWord -or $key.GetValue('NukeOnDelete') -ne 1) { throw 'New-volume immediate-delete setting was not established.' }
    } finally { $key.Dispose() }
} finally { $registry.Dispose() }
$fixture = $letter + ':\PrunletImmediateFixture'
$null = New-Item -ItemType Directory -Path $fixture
# 再確認後の固定先だけをE2Eへ渡す。CI VMの破棄で終了し、既存ディスクを清掃しない。
if ((Get-Partition -DriveLetter $letter).DiskNumber -ne $disk.Number -or (Get-Volume -DriveLetter $letter).UniqueId -cne $volumeId) { throw 'CI volume identity changed.' }
[pscustomobject]@{ fixtureRoot = $fixture; imagePath = $image; volumeId = $volumeId; diskNumber = $disk.Number; userSid = $identity.User.Value; setting = $setting } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'volume.json')
[pscustomobject]@{ FixtureRoot = $fixture; EvidencePath = (Join-Path $root 'volume.json') }

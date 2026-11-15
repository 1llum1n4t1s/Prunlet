#requires -Version 7.2
# 鍵整合の関門。署名した封筒を、Rust・Install-Prunlet.ps1・Install-Prunlet.sh の 3 か所の公開鍵定数
# すべてで検証できなければ失敗する。release workflow は、これが成功するまで R2 へ何も書かない。
# launcher（integration/start-prunlet-mcp.ps1）は封筒の検証を Rust の内部コマンドへ任せるため定数を持たない。
# 持たないことは失敗にしないが、もし持っているなら同じ規則で検査し、本番鍵と違えば失敗する（任意の場所）。
#
# 仕組み（本体は PrunletReleaseGate.Common.ps1 の Invoke-PrunletReleaseKeyGate）:
#   1. 本番の署名鍵（環境変数 PRUNLET_RELEASE_SIGNING_KEY）で試験用の封筒に署名し、配信側の正本
#      （scripts/PrunletRelease.Common.ps1 の PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64 / keyId）で検証できることを確認する。
#   2. 必須の 3 か所（と、定数があれば launcher）のファイルから定数を抽出し、(a) 正本と同じ値であること、
#      (b) 同じ封筒を検証できることを確認する。
#   必須の場所に定数が無ければ「未導入」（not-installed）として失敗する（黙って成功にしない）。
#   launcher に定数が無い場合は not-present として報告するだけで、失敗に数えない。
#
# 抽出規則（クライアント側の実装はこれに従う）:
#   各場所のファイル群で、識別子 PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64 を含む同じ行に、SPKI DER の base64（100 文字以上、
#   標準 base64、パディング付き）の文字列リテラル（シングルまたはダブルクォート）が 1 つだけあること。
#   場所ごとに、定数の定義はちょうど 1 個（複数ファイルに分けない・複数回定義しない）。
#   例: Rust `const PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64: &str = "MFkw...";`
#       PowerShell `$PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64 = 'MFkw...'`
#       sh `PRUNLET_RELEASE_PUBLIC_KEY_SPKI_B64='MFkw...'`
#   必須の場所: rust = src/rust/**/*.rs、installer-ps1 = scripts/Install-Prunlet.ps1、
#               installer-sh = scripts/Install-Prunlet.sh。
#   任意の場所: launcher = integration/start-prunlet-mcp.ps1（定数があれば、ちょうど 1 個・本番鍵と一致が必要）。
# 引数は持たない。照合先は本番の信頼、ツリーはこのリポジトリのルート、署名鍵は環境変数だけ
# （必須の関門を、コマンドラインから別の鍵・別のツリーへ向けさせない）。テストは関数を直接呼ぶ。
# 秘密鍵の値は出力しない。成功時は結果の JSON を 1 つ出力し、失敗時は例外（終了コード 1）で止まる。
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'PrunletReleaseGate.Common.ps1')
Invoke-PrunletReleaseKeyGate -SourceRoot (Split-Path -Parent $PSScriptRoot) -Trust (Get-PrunletReleaseTrust) -PrivateKeyPem $env:PRUNLET_RELEASE_SIGNING_KEY

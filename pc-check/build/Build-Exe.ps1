# 관리자 권한 요청이 내장된 단일 실행 파일(.exe) 빌드 — Windows PowerShell 5.1 에서 실행
param([Parameter(Mandatory)][string]$OutDir)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not (Get-Module -ListAvailable ps2exe)) { Install-Module ps2exe -Force -Scope CurrentUser }
Import-Module ps2exe
$ver = (Select-String -Path (Join-Path $root 'PCCheck.ps1') -Pattern "AppVersion\s*=\s*'([\d\.]+)'").Matches[0].Groups[1].Value
New-Item -ItemType Directory -Force $OutDir | Out-Null
$exe = Join-Path $OutDir 'PC원클릭진단.exe'
Invoke-ps2exe -inputFile (Join-Path $root 'PCCheck.ps1') -outputFile $exe -noConsole -STA -requireAdmin `
    -title 'PC 원클릭 진단' -product 'PC 원클릭 진단' -description '갑작스런 종료·그래픽카드·RAM 진단' -version "$ver.0"
if (-not (Test-Path $exe)) { throw 'EXE 생성 실패' }
Write-Host "EXE: $exe ($([int]((Get-Item $exe).Length / 1KB)) KB)"

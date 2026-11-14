# CI 전용: 실제 Windows 에서 무인 검사 → 결과 검증 → JSON 재분석 → 외부 도구 다운로드 검증
param([string]$Temp = $env:RUNNER_TEMP, [switch]$ToolCheck)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'PCCheck.ps1'

if ($ToolCheck) {
    . $script -LoadOnly
    $script:WorkDir = Join-Path $Temp 'tools'
    $a = Get-MemtestAsset; Write-Host "asset($($a.Source)): $($a.Name) · sha256: $($a.Sha256)"
    $p = Install-MemtestVulkan; Write-Host "memtest_vulkan: $p"
    # API 를 못 쓰는 경우의 고정 버전 경로도 실제로 받아 SHA-256 검증
    $script:WorkDir = Join-Path $Temp 'tools-pinned'
    $p2 = Install-MemtestVulkan -UsePinned; Write-Host "memtest_vulkan (pinned): $p2"


    try { $b = Install-BlueScreenView; Write-Host "BlueScreenView: $b" }
    catch { Write-Host "::warning::BlueScreenView 다운로드 실패: $($_.Exception.Message)" }
    return
}

$out = Join-Path $Temp ("report-" + $PSVersionTable.PSVersion.Major)
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = & $script -Mode Silent -Days 30 -Lang ko -OutDir $out | Select-Object -Last 1
Write-Host "PowerShell $($PSVersionTable.PSVersion) · 소요 $([int]$sw.Elapsed.TotalSeconds)초"
if (-not $r -or -not (Test-Path $r.Html)) { throw 'HTML 보고서 없음' }
$j = Get-Content -Raw -Encoding UTF8 $r.Json | ConvertFrom-Json
Write-Host "GPU $(@($j.Gpus).Count) · 디스크 $(@($j.Disks).Count) · RAM $(@($j.Dimms).Count) · 종료기록 $(@($j.Shutdowns).Count) · 그래픽오류 $(@($j.GpuEvents).Count) · WHEA $(@($j.Whea).Count)"
if (-not $j.System.OS) { throw '시스템 정보 수집 실패' }
. $script -LoadOnly
Write-Host "GPU 센서(D3DKMT): $(@(Get-GpuSensors).Count) 개 (가상 머신에서는 0 이 정상)"

if (@($j.Errors).Count -gt 0) { $j.Errors | Format-Table | Out-String | Write-Host; throw '수집 단계 오류 발생' }
$h = [IO.File]::ReadAllText($r.Html)
if ($h -notmatch '상태:' -or $h -notmatch '</html>') { throw '보고서 내용 이상' }
$r2 = & $script -Mode Silent -FromJson $r.Json -OutDir (Join-Path $out 'rerender') -NoOpen | Select-Object -Last 1
if (-not (Test-Path $r2.Html)) { throw 'JSON 재분석 실패' }
# 영어 보고서 (영문 Windows 이므로 이벤트 내용도 영어 → 한글이 없어야 함)
$r3 = & $script -Mode Silent -Days 30 -Lang en -OutDir (Join-Path $out 'en') | Select-Object -Last 1
$h3 = [IO.File]::ReadAllText($r3.Html)
$ko = @([regex]::Matches($h3, '[^<>"]{0,20}[가-힣]+[^<>"]{0,20}') | ForEach-Object { $_.Value })
if ($ko.Count) { throw "영어 보고서에 한글이 남음: $(($ko | Select-Object -First 10) -join ' | ')" }
if ($h3 -notmatch 'lang="en"' -or $h3 -notmatch 'PC Diagnostic Report') { throw '영어 보고서 아님' }
Write-Host 'OK'



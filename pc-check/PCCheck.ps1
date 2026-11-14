# =====================================================================
#  PC 원클릭 진단 (갑작스런 종료 · 블루스크린 · 그래픽카드/VRAM · RAM)
#  - Windows 10/11, PowerShell 5.1 이상
#  - "원클릭검사.bat" 을 더블클릭하면 관리자 권한으로 실행됩니다.
# =====================================================================
param(
    [int]$Days = 30,          # 최근 며칠간의 기록을 볼지
    [switch]$NoMenu           # 보고서만 만들고 추가 검사 메뉴는 생략
)

$ErrorActionPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Since    = (Get-Date).AddDays(-$Days)
$Stamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
$Desktop  = [Environment]::GetFolderPath('Desktop')
$WorkDir  = Join-Path $env:LOCALAPPDATA 'PCCheck'
$Report   = Join-Path $Desktop "PC진단보고서_$Stamp.html"
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }
function H($s) { if ($null -eq $s) { return '' }; return [System.Net.WebUtility]::HtmlEncode([string]$s) }

function Get-Events([string]$Log, $Ids, [string]$Provider) {
    $f = @{ LogName = $Log; StartTime = $Since }
    if ($Ids)      { $f.Id = $Ids }
    if ($Provider) { $f.ProviderName = $Provider }
    try { return @(Get-WinEvent -FilterHashtable $f -ErrorAction Stop) } catch { return @() }
}

# 자주 나오는 블루스크린 코드 해설
$BugMap = @{
    '0x116' = 'VIDEO_TDR_FAILURE - 그래픽 드라이버/그래픽카드 응답 없음 (드라이버, VRAM, 오버클럭, 전원 의심)'
    '0x117' = 'VIDEO_TDR_TIMEOUT_DETECTED - 그래픽카드 응답 시간 초과'
    '0x119' = 'VIDEO_SCHEDULER_INTERNAL_ERROR - 그래픽 드라이버/카드 문제'
    '0x124' = 'WHEA_UNCORRECTABLE_ERROR - 하드웨어 오류 (CPU·RAM·전원·과열·오버클럭)'
    '0x1a'  = 'MEMORY_MANAGEMENT - RAM 불량 또는 메모리 설정(XMP) 의심'
    '0x50'  = 'PAGE_FAULT_IN_NONPAGED_AREA - RAM 또는 드라이버 문제'
    '0x3b'  = 'SYSTEM_SERVICE_EXCEPTION - 드라이버(특히 그래픽) 문제'
    '0xa'   = 'IRQL_NOT_LESS_OR_EQUAL - 드라이버 또는 RAM 문제'
    '0xd1'  = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL - 드라이버 문제'
    '0x9f'  = 'DRIVER_POWER_STATE_FAILURE - 절전/전원 관련 드라이버 문제'
    '0x133' = 'DPC_WATCHDOG_VIOLATION - 드라이버나 SSD 펌웨어 문제'
    '0x7e'  = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED - 드라이버 문제'
    '0xef'  = 'CRITICAL_PROCESS_DIED - 시스템 파일/디스크 문제'
    '0x7a'  = 'KERNEL_DATA_INPAGE_ERROR - 디스크(SSD/HDD) 또는 RAM 문제'
    '0x101' = 'CLOCK_WATCHDOG_TIMEOUT - CPU 문제 (오버클럭/전압)'
    '0x139' = 'KERNEL_SECURITY_CHECK_FAILURE - 드라이버 또는 RAM 문제'
}
function Explain-Bug([string]$hex) {
    $k = ('0x' + ($hex -replace '^0x0*', '')).ToLower()
    if ($BugMap.ContainsKey($k)) { return $BugMap[$k] }
    return '기타 코드 - BlueScreenView 로 상세 확인 권장'
}

Clear-Host
Say '=================================================' Cyan
Say '   PC 원클릭 진단 - 갑작스런 종료 / 그래픽카드 / RAM' Cyan
Say '=================================================' Cyan
if (-not $isAdmin) { Say '[주의] 관리자 권한이 아닙니다. 일부 항목이 빠질 수 있습니다.' Yellow }
Say "최근 $Days 일간의 기록을 분석합니다...`n"

# ---------------------------------------------------------------------
# 1. 시스템 정보
# ---------------------------------------------------------------------
Say '[1/7] 시스템 정보 수집'
$os   = Get-CimInstance Win32_OperatingSystem
$cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
$cs   = Get-CimInstance Win32_ComputerSystem
$mb   = Get-CimInstance Win32_BaseBoard
$bios = Get-CimInstance Win32_BIOS
$dimms = @(Get-CimInstance Win32_PhysicalMemory)
$ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
$lastBoot = $os.LastBootUpTime

# GPU (AdapterRAM 은 4GB 에서 잘리므로 레지스트리 값 우선)
$gpus = @()
$classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
$regGpu = @{}
Get-ChildItem $classKey | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath
    if ($p.DriverDesc) {
        $mem = $p.'HardwareInformation.qwMemorySize'
        if (-not $mem) { $mem = $p.'HardwareInformation.MemorySize'; if ($mem -is [byte[]]) { $mem = [BitConverter]::ToUInt32($mem, 0) } }
        if ($mem) { $regGpu[$p.DriverDesc] = [double]$mem }
    }
}
foreach ($v in Get-CimInstance Win32_VideoController) {
    $vram = $null
    if ($regGpu.ContainsKey($v.Name)) { $vram = $regGpu[$v.Name] } elseif ($v.AdapterRAM) { $vram = [double]$v.AdapterRAM }
    $gpus += [pscustomobject]@{
        Name    = $v.Name
        VRAM    = $(if ($vram) { '{0:N1} GB' -f ($vram / 1GB) } else { '알 수 없음' })
        Driver  = $v.DriverVersion
        DrvDate = $(if ($v.DriverDate) { ([datetime]$v.DriverDate).ToString('yyyy-MM-dd') } else { '' })
        Status  = $v.Status
    }
}

# NVIDIA 라면 nvidia-smi 로 실시간 상태
$nvsmi = $null
foreach ($c in @("$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe")) { if (Test-Path $c) { $nvsmi = $c; break } }
$nvInfo = @()
if ($nvsmi) {
    $q = 'name,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw,power.limit,clocks.gr,driver_version'
    $out = & $nvsmi "--query-gpu=$q" '--format=csv,noheader' 2>$null
    foreach ($line in $out) {
        $c = $line -split ',\s*'
        if ($c.Count -ge 9) {
            $nvInfo += [pscustomobject]@{ Name=$c[0]; Temp="$($c[1]) °C"; Util=$c[2]; MemUsed=$c[3]; MemTotal=$c[4]; Power=$c[5]; PowerLimit=$c[6]; Clock=$c[7]; Driver=$c[8]; TempNum=[int]($c[1] -replace '\D','') }
        }
    }
}

# ---------------------------------------------------------------------
# 2. 갑작스런 종료 / 블루스크린
# ---------------------------------------------------------------------
Say '[2/7] 갑작스런 종료 / 블루스크린 기록 분석'
$kp41 = Get-Events 'System' 41 'Microsoft-Windows-Kernel-Power'
$ev6008 = Get-Events 'System' 6008 'EventLog'
$bug1001 = @(Get-Events 'System' 1001 $null | Where-Object { $_.ProviderName -match 'WER-SystemErrorReporting|BugCheck' })

$shutdownRows = @()
$powerLoss = 0; $bsodFrom41 = 0
foreach ($e in $kp41) {
    $code = 0
    try { $code = [int64]$e.Properties[0].Value } catch {}
    if ($code -ne 0) {
        $bsodFrom41++
        $hex = '0x{0:X}' -f $code
        $kind = "블루스크린 ($hex)"; $why = Explain-Bug $hex
    } else {
        $powerLoss++
        $kind = '전원 끊김/멈춤 (코드 0)'
        $why = '블루스크린 없이 꺼짐 → 파워(PSU) 부족·불량, 과열, 멀티탭/전원 케이블, 강제 전원 버튼, 하드웨어 완전 멈춤 의심'
    }
    $shutdownRows += [pscustomobject]@{ Time = $e.TimeCreated; Kind = $kind; Why = $why }
}
$bsodRows = @()
$bugCodes = @{}
foreach ($e in $bug1001) {
    $msg = $e.Message
    $hex = ''
    if ($msg -match '0x[0-9a-fA-F]{8}') { $hex = '0x' + ($Matches[0].Substring(2).TrimStart('0')) }
    if ($hex) { $bugCodes[$hex] = 1 + [int]$bugCodes[$hex] }
    $bsodRows += [pscustomobject]@{ Time = $e.TimeCreated; Code = $hex; Why = $(if ($hex) { Explain-Bug $hex } else { '' }) }
}

# ---------------------------------------------------------------------
# 3. 그래픽카드 드라이버 오류 (TDR 등)
# ---------------------------------------------------------------------
Say '[3/7] 그래픽카드 드라이버 오류(TDR) 분석'
$gpuEv = @()
$gpuEv += Get-Events 'System' 4101 'Display'                         # 드라이버가 응답을 멈췄다가 복구됨
$gpuEv += Get-Events 'System' @(13,14,153) 'nvlddmkm'                 # NVIDIA 드라이버 오류 (Xid)
$gpuEv += Get-Events 'System' $null 'amdkmdag' | Where-Object { $_.Level -le 2 }   # AMD
$gpuEv += Get-Events 'System' $null 'amdwddmg' | Where-Object { $_.Level -le 2 }
$gpuEv += Get-Events 'System' $null 'igfx'     | Where-Object { $_.Level -le 2 }   # Intel
$gpuEv += Get-Events 'Application' 1 'Microsoft-Windows-Kernel-LiveDump' # 그래픽 라이브덤프 생성
$gpuEv = @($gpuEv | Sort-Object TimeCreated -Descending)
$xidList = @()
foreach ($e in $gpuEv | Where-Object { $_.ProviderName -eq 'nvlddmkm' }) {
    if ($e.Message -match 'Xid[^0-9]*(\d+)') { $xidList += [int]$Matches[1] }
}

# ---------------------------------------------------------------------
# 4. 하드웨어 오류 (WHEA)
# ---------------------------------------------------------------------
Say '[4/7] 하드웨어 오류(WHEA) 분석'
$whea = Get-Events 'System' $null 'Microsoft-Windows-WHEA-Logger'
$wheaRows = @()
foreach ($e in $whea) {
    $comp = ''
    if ($e.Message -match '(?m)(Component|구성 요소)\s*:\s*(.+)$') { $comp = $Matches[2].Trim() }
    $hint = switch ($e.Id) {
        17 { 'PCI Express 수정된 오류 - 그래픽카드/NVMe 슬롯 접촉, PCIe 세대 설정 의심' }
        18 { '치명적 하드웨어 오류 - CPU/전원/오버클럭 의심 (반복 시 심각)' }
        19 { '수정된 CPU/캐시 오류 - CPU 전압·오버클럭 의심' }
        47 { '수정된 메모리 오류 - RAM 불량/XMP 설정 의심' }
        1  { '하드웨어 오류 발생 기록' }
        default { '하드웨어 오류' }
    }
    $wheaRows += [pscustomobject]@{ Time = $e.TimeCreated; Id = $e.Id; Level = $e.LevelDisplayName; Comp = $comp; Hint = $hint }
}

# ---------------------------------------------------------------------
# 5. 디스크 / 메모리 진단 결과
# ---------------------------------------------------------------------
Say '[5/7] 디스크 상태 / 이전 메모리 진단 결과 확인'
$diskEv = @()
$diskEv += Get-Events 'System' @(7,11,51,153) 'disk'
$diskEv += Get-Events 'System' 55 'Ntfs'
$diskEv += Get-Events 'System' @(129,153) 'stornvme'
$disks = @()
foreach ($d in Get-PhysicalDisk) {
    $rel = $d | Get-StorageReliabilityCounter
    $disks += [pscustomobject]@{
        Name = $d.FriendlyName; Type = $d.MediaType; Size = ('{0:N0} GB' -f ($d.Size / 1GB))
        Health = $d.HealthStatus; Temp = $(if ($rel.Temperature) { "$($rel.Temperature) °C" } else { '-' })
        Wear = $(if ($null -ne $rel.Wear) { "$($rel.Wear) %" } else { '-' })
        ReadErr = $(if ($null -ne $rel.ReadErrorsUncorrected) { $rel.ReadErrorsUncorrected } else { '-' })
    }
}
$memDiag = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results' } -MaxEvents 3 -ErrorAction SilentlyContinue)

# ---------------------------------------------------------------------
# 6. 덤프 파일 / 온도
# ---------------------------------------------------------------------
Say '[6/7] 덤프 파일 / 온도 확인'
$dumps = @(Get-ChildItem "$env:SystemRoot\Minidump\*.dmp" | Sort-Object LastWriteTime -Descending)
$memDmp = Get-Item "$env:SystemRoot\MEMORY.DMP"
$thermal = @()
foreach ($t in Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature) {
    if ($t.CurrentTemperature) { $thermal += [math]::Round($t.CurrentTemperature / 10 - 273.15, 1) }
}

# ---------------------------------------------------------------------
# 7. 종합 판정
# ---------------------------------------------------------------------
Say '[7/7] 종합 판정'
$findings = @()   # 각 항목: Level(bad/warn/ok), Title, Detail
function Add-F($lv, $t, $d) { $script:findings += [pscustomobject]@{ Level = $lv; Title = $t; Detail = $d } }

$gpuBugs = @($bugCodes.Keys | Where-Object { $_ -match '^0x11[679]$' })
$memBugs = @($bugCodes.Keys | Where-Object { $_ -in @('0x1A','0x1a','0x50','0x139') })
$whea47 = @($whea | Where-Object { $_.Id -eq 47 }).Count
$whea17 = @($whea | Where-Object { $_.Id -eq 17 }).Count
$wheaFatal = @($whea | Where-Object { $_.Id -eq 18 -or $_.Level -le 2 }).Count

if ($powerLoss -gt 0) {
    Add-F $(if ($powerLoss -ge 3) { 'bad' } else { 'warn' }) "블루스크린 없이 갑자기 꺼짐 $powerLoss 회" `
        '파워서플라이(PSU) 용량 부족·노후, 과열(CPU/GPU), 멀티탭·전원 케이블 접촉, 그래픽카드 보조전원 케이블을 먼저 점검하세요. 게임/고부하 중에만 꺼진다면 PSU 또는 그래픽카드 가능성이 큽니다.'
}
if ($bsodFrom41 + $bsodRows.Count -gt 0) {
    $codes = ($bugCodes.Keys | ForEach-Object { "$_ ($($bugCodes[$_])회)" }) -join ', '
    Add-F 'bad' "블루스크린 발생 $([math]::Max($bsodFrom41, $bsodRows.Count)) 회" "코드: $codes  → 아래 표의 해설과 BlueScreenView 분석(메뉴 2)을 확인하세요."
}
if ($gpuEv.Count -gt 0 -or $gpuBugs.Count -gt 0) {
    $d = "그래픽 드라이버 오류/응답없음 $($gpuEv.Count) 건."
    if ($xidList.Count) { $d += " NVIDIA Xid: $((($xidList | Sort-Object -Unique) -join ', '))." }
    if ($xidList -contains 48 -or $xidList -contains 63 -or $xidList -contains 64 -or $xidList -contains 94 -or $xidList -contains 95) { $d += ' (Xid 48/63/64/94/95 는 VRAM 메모리 오류 신호입니다!)' }
    if ($xidList -contains 79) { $d += ' (Xid 79: 그래픽카드가 버스에서 떨어짐 → 전원/슬롯/과열 의심)' }
    $d += ' → DDU로 드라이버 완전 삭제 후 재설치, 오버클럭 해제, VRAM 검사(메뉴 1) 권장.'
    Add-F $(if ($gpuEv.Count -ge 3 -or $gpuBugs.Count) { 'bad' } else { 'warn' }) '그래픽카드 관련 오류 감지' $d
}
if ($whea.Count -gt 0) {
    $d = "WHEA 하드웨어 오류 $($whea.Count) 건 (치명적 $wheaFatal, 메모리 $whea47, PCIe $whea17)."
    if ($whea17) { $d += ' PCIe 오류가 많으면 그래픽카드를 다시 장착하고 BIOS에서 PCIe 세대를 Gen3 등으로 고정해 보세요.' }
    if ($whea47) { $d += ' 메모리 오류가 있으니 XMP/EXPO 를 끄고 RAM 검사(메뉴 3)를 해 보세요.' }
    Add-F $(if ($wheaFatal) { 'bad' } else { 'warn' }) '하드웨어 오류(WHEA) 기록' $d
}
if ($memBugs.Count -gt 0) { Add-F 'warn' 'RAM 관련 블루스크린 코드' "코드 $($memBugs -join ', ') → Windows 메모리 진단(메뉴 3) 또는 MemTest86 권장." }
foreach ($m in $memDiag) {
    if ($m.Id -eq 1202 -or $m.Message -match '오류가 검색|errors were detected|하드웨어 문제가 검색') { Add-F 'bad' 'Windows 메모리 진단에서 RAM 오류 발견' "$($m.TimeCreated) - RAM 교체 또는 슬롯별 단독 테스트를 권장합니다." }
}
if ($diskEv.Count -gt 0) { Add-F 'warn' "디스크 오류 기록 $($diskEv.Count) 건" '디스크 오류는 멈춤/블루스크린의 원인이 될 수 있습니다. CrystalDiskInfo 로 SMART 를 확인하세요.' }
foreach ($d in $disks) { if ($d.Health -and $d.Health -ne 'Healthy') { Add-F 'bad' "디스크 상태 이상: $($d.Name)" "상태: $($d.Health) → 즉시 백업하세요." } }
foreach ($n in $nvInfo) { if ($n.TempNum -ge 85) { Add-F 'warn' "그래픽카드 온도 높음: $($n.TempNum) °C" '쿨링(팬, 먼지, 써멀) 점검 필요. 부하 중이 아니라면 더 심각합니다.' } }
foreach ($t in $thermal) { if ($t -ge 90) { Add-F 'warn' "메인보드 온도센서 $t °C" '과열 가능성. HWiNFO 로 CPU/GPU 온도를 확인하세요.' } }
if ($findings.Count -eq 0) { Add-F 'ok' "최근 $Days 일간 특별한 문제 기록 없음" '증상이 계속되면 VRAM 검사(메뉴 1)와 RAM 검사(메뉴 3)로 직접 부하 테스트를 해 보세요.' }

# ---------------------------------------------------------------------
# HTML 보고서
# ---------------------------------------------------------------------
function Table($rows, $cols, $heads) {
    if (-not $rows -or @($rows).Count -eq 0) { return '<p class="none">기록 없음 ✓</p>' }
    $s = '<table><tr>' + (($heads | ForEach-Object { "<th>$(H $_)</th>" }) -join '') + '</tr>'
    foreach ($r in $rows) {
        $s += '<tr>' + (($cols | ForEach-Object { $v = $r.$_; if ($v -is [datetime]) { $v = $v.ToString('yyyy-MM-dd HH:mm') }; "<td>$(H $v)</td>" }) -join '') + '</tr>'
    }
    return $s + '</table>'
}
$gpuEvRows = $gpuEv | Select-Object -First 50 | ForEach-Object { [pscustomobject]@{ Time = $_.TimeCreated; Src = $_.ProviderName; Id = $_.Id; Msg = (($_.Message -split "`n")[0]) } }
$diskEvRows = $diskEv | Sort-Object TimeCreated -Descending | Select-Object -First 30 | ForEach-Object { [pscustomobject]@{ Time = $_.TimeCreated; Src = $_.ProviderName; Id = $_.Id; Msg = (($_.Message -split "`n")[0]) } }
$dumpRows = $dumps | Select-Object -First 30 | ForEach-Object { [pscustomobject]@{ Time = $_.LastWriteTime; Name = $_.Name; Size = ('{0:N0} KB' -f ($_.Length / 1KB)) } }
$dimmRows = $dimms | ForEach-Object { [pscustomobject]@{ Slot = $_.DeviceLocator; Size = ('{0:N0} GB' -f ($_.Capacity / 1GB)); Speed = "$($_.ConfiguredClockSpeed) / $($_.Speed) MHz"; Maker = $_.Manufacturer; Part = ($_.PartNumber -as [string]).Trim() } }

$cards = ($findings | ForEach-Object { "<div class='card $($_.Level)'><b>$(H $_.Title)</b><p>$(H $_.Detail)</p></div>" }) -join "`n"
$badCount = @($findings | Where-Object Level -eq 'bad').Count
$verdict = if ($badCount) { "점검이 필요한 문제 $badCount 건" } elseif (@($findings | Where-Object Level -eq 'warn').Count) { '주의 항목이 있습니다' } else { '양호' }

$html = @"
<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>PC 진단 보고서</title>
<style>
:root{--bg:#f6f7f9;--fg:#15191e;--muted:#5d6670;--line:#dde1e6;--card:#fff;--bad:#c62828;--warn:#b26a00;--ok:#2e7d32}
@media (prefers-color-scheme:dark){:root{--bg:#111316;--fg:#eceff3;--muted:#9aa3ad;--line:#2a2f36;--card:#1a1d22;--bad:#ff6b6b;--warn:#ffb74d;--ok:#66bb6a}}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.6 "Malgun Gothic","Segoe UI",sans-serif}
main{max-width:1000px;margin:0 auto;padding:24px 16px 60px}
h1{margin:0 0 4px;font-size:24px} h2{margin:32px 0 10px;font-size:18px;border-bottom:1px solid var(--line);padding-bottom:6px}
.sub{color:var(--muted);margin:0 0 18px}
.verdict{font-size:20px;font-weight:700;margin:12px 0}
.card{background:var(--card);border:1px solid var(--line);border-left:5px solid var(--ok);border-radius:8px;padding:12px 14px;margin:10px 0}
.card.bad{border-left-color:var(--bad)} .card.warn{border-left-color:var(--warn)} .card p{margin:4px 0 0;color:var(--muted)}
table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);font-size:13px;display:block;overflow-x:auto}
th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top} th{white-space:nowrap}
.none{color:var(--ok)} .kv td:first-child{color:var(--muted);white-space:nowrap}
ul{padding-left:20px} a{color:inherit}
</style></head><body><main>
<h1>PC 진단 보고서</h1>
<p class="sub">$(H $env:COMPUTERNAME) · 생성 $(Get-Date -Format 'yyyy-MM-dd HH:mm') · 분석 기간 최근 $Days 일 $(if (-not $isAdmin) { '· ⚠ 관리자 권한 아님' })</p>
<div class="verdict">종합: $(H $verdict)</div>
$cards

<h2>시스템</h2>
<table class="kv">
<tr><td>Windows</td><td>$(H $os.Caption) ($(H $os.Version))</td></tr>
<tr><td>CPU</td><td>$(H $cpu.Name)</td></tr>
<tr><td>메인보드</td><td>$(H $mb.Manufacturer) $(H $mb.Product) · BIOS $(H $bios.SMBIOSBIOSVersion)</td></tr>
<tr><td>RAM</td><td>$ramGB GB</td></tr>
<tr><td>마지막 부팅</td><td>$(H $lastBoot)</td></tr>
</table>

<h2>그래픽카드</h2>
$(Table $gpus @('Name','VRAM','Driver','DrvDate','Status') @('이름','VRAM','드라이버','드라이버 날짜','상태'))
$(if ($nvInfo.Count) { '<p class="sub" style="margin-top:10px">NVIDIA 실시간 상태</p>' + (Table $nvInfo @('Name','Temp','Util','MemUsed','MemTotal','Power','PowerLimit','Clock') @('이름','온도','사용률','VRAM 사용','VRAM 전체','전력','전력 제한','클럭')) })

<h2>갑작스런 종료 (Kernel-Power 41)</h2>
$(Table ($shutdownRows | Sort-Object Time -Descending) @('Time','Kind','Why') @('시간','종류','추정 원인'))
<p class="sub">예기치 않은 종료 기록(이벤트 6008): $($ev6008.Count) 건</p>

<h2>블루스크린 (BugCheck)</h2>
$(Table ($bsodRows | Sort-Object Time -Descending) @('Time','Code','Why') @('시간','코드','해설'))

<h2>그래픽 드라이버 오류 (TDR / Xid)</h2>
$(Table $gpuEvRows @('Time','Src','Id','Msg') @('시간','출처','ID','내용'))

<h2>하드웨어 오류 (WHEA)</h2>
$(Table ($wheaRows | Sort-Object Time -Descending | Select-Object -First 50) @('Time','Id','Level','Comp','Hint') @('시간','ID','수준','구성요소','해설'))

<h2>RAM</h2>
$(Table $dimmRows @('Slot','Size','Speed','Maker','Part') @('슬롯','용량','속도(현재/정격)','제조사','모델'))
<p class="sub">Windows 메모리 진단 최근 결과: $(if ($memDiag.Count) { H (($memDiag | Select-Object -First 1).TimeCreated.ToString() + ' - ' + (($memDiag | Select-Object -First 1).Message -split "`n")[0]) } else { '실행 기록 없음' })</p>

<h2>디스크</h2>
$(Table $disks @('Name','Type','Size','Health','Temp','Wear','ReadErr') @('이름','종류','용량','상태','온도','마모도','읽기오류'))
<div style="height:8px"></div>
$(Table $diskEvRows @('Time','Src','Id','Msg') @('시간','출처','ID','내용'))

<h2>덤프 파일</h2>
$(Table $dumpRows @('Time','Name','Size') @('시간','파일','크기'))
$(if ($memDmp) { "<p class='sub'>전체 덤프: $(H $memDmp.FullName) ($('{0:N0} MB' -f ($memDmp.Length / 1MB)), $(H $memDmp.LastWriteTime))</p>" })

<h2>다음 단계 (권장 순서)</h2>
<ul>
<li><b>VRAM 검사</b>: memtest_vulkan (GitHub GpuZelenograd/memtest_vulkan, 오픈소스) — 이 프로그램 메뉴 1</li>
<li><b>블루스크린 원인 드라이버 확인</b>: NirSoft BlueScreenView — 메뉴 2</li>
<li><b>RAM 검사</b>: Windows 메모리 진단(재부팅) — 메뉴 3 / 더 정밀하게는 MemTest86 (USB 부팅)</li>
<li><b>온도·전압 실시간 감시</b>: HWiNFO — 메뉴 4 / <b>종합 부하 테스트(PSU·VRAM)</b>: OCCT — 메뉴 5</li>
<li><b>그래픽 드라이버 완전 재설치</b>: DDU(Display Driver Uninstaller, 안전모드에서 실행) 후 최신 드라이버 설치</li>
<li>오버클럭·XMP/EXPO 를 끄고 증상이 사라지는지 확인, 그래픽카드 보조전원 케이블을 각각 별도 케이블로 연결</li>
</ul>
</main></body></html>
"@
$html | Out-File -FilePath $Report -Encoding utf8
Say "`n보고서 저장: $Report" Green
Start-Process $Report

Say "`n================ 종합 결과 ================" Cyan
foreach ($f in $findings) {
    $c = switch ($f.Level) { 'bad' { 'Red' } 'warn' { 'Yellow' } default { 'Green' } }
    Say ("● " + $f.Title) $c
}

# ---------------------------------------------------------------------
# 추가 검사 메뉴 (평판 좋은 외부 도구 자동 다운로드·실행)
# ---------------------------------------------------------------------
function Download($url, $dest) {
    Say "다운로드: $url"
    try { Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -UserAgent 'PCCheck' -ErrorAction Stop; return $true }
    catch { Say "다운로드 실패: $($_.Exception.Message)" Red; return $false }
}

function Run-MemtestVulkan {
    $dir = Join-Path $WorkDir 'memtest_vulkan'
    $exe = Get-ChildItem $dir -Recurse -Filter 'memtest_vulkan*.exe' | Select-Object -First 1
    if (-not $exe) {
        $rel = $null
        try { $rel = Invoke-RestMethod 'https://api.github.com/repos/GpuZelenograd/memtest_vulkan/releases/latest' -UserAgent 'PCCheck' -ErrorAction Stop } catch {}
        $asset = $null
        if ($rel) { $asset = $rel.assets | Where-Object { $_.name -match '\.zip$' -and $_.name -notmatch 'linux|arm|aarch' } | Select-Object -First 1 }
        if (-not $asset) { Say 'GitHub 에서 자동 다운로드에 실패해 릴리스 페이지를 엽니다. Windows용 zip 을 받아 실행하세요.' Yellow; Start-Process 'https://github.com/GpuZelenograd/memtest_vulkan/releases'; return }
        $zip = Join-Path $WorkDir $asset.name
        if (-not (Download $asset.browser_download_url $zip)) { return }
        Expand-Archive $zip -DestinationPath $dir -Force
        $exe = Get-ChildItem $dir -Recurse -Filter 'memtest_vulkan*.exe' | Select-Object -First 1
    }
    if (-not $exe) { Say '실행 파일을 찾지 못했습니다.' Red; return }
    Say "`nmemtest_vulkan 을 새 창에서 실행합니다." Green
    Say ' - 시작 후 엔터를 누르면 기본 GPU 로 테스트가 진행됩니다 (여러 개면 번호 선택).'
    Say ' - 최소 5~10분 실행: "Standard 5-minute test PASSed" 가 나오면 정상, "error" 가 보이면 VRAM 불량 의심.'
    Say ' - 끝내려면 그 창에서 Ctrl+C. 이 테스트 중에 PC 가 꺼지면 PSU/그래픽카드 전원 문제일 가능성이 큽니다.'
    Start-Process -FilePath $exe.FullName -WorkingDirectory $exe.DirectoryName
}

function Run-BlueScreenView {
    $dir = Join-Path $WorkDir 'BlueScreenView'
    $exe = Join-Path $dir 'BlueScreenView.exe'
    if (-not (Test-Path $exe)) {
        $zip = Join-Path $WorkDir 'bluescreenview.zip'
        $url = if ([Environment]::Is64BitOperatingSystem) { 'https://www.nirsoft.net/utils/bluescreenview-x64.zip' } else { 'https://www.nirsoft.net/utils/bluescreenview.zip' }
        if (-not (Download $url $zip)) { Start-Process 'https://www.nirsoft.net/utils/blue_screen_of_death_viewer.html'; return }
        Expand-Archive $zip -DestinationPath $dir -Force
    }
    if ($dumps.Count -eq 0) { Say '참고: Minidump 파일이 없어 표시할 내용이 없을 수 있습니다.' Yellow }
    Say 'BlueScreenView 실행 - 아래쪽 빨간색으로 표시된 드라이버가 원인 후보입니다 (nvlddmkm.sys=NVIDIA, amdkmdag.sys=AMD, ntoskrnl.exe=하드웨어/RAM 가능).' Green
    Start-Process $exe
}

if (-not $NoMenu) {
    while ($true) {
        Say "`n============ 추가 정밀 검사 ============" Cyan
        Say ' 1. 그래픽카드 VRAM 검사  (memtest_vulkan · GitHub 오픈소스, 자동 다운로드)'
        Say ' 2. 블루스크린 원인 분석   (NirSoft BlueScreenView, 자동 다운로드)'
        Say ' 3. RAM 검사              (Windows 메모리 진단 · 재부팅 후 진행)'
        Say ' 4. 온도/전압 모니터링     (HWiNFO 공식 사이트 열기)'
        Say ' 5. 전원·GPU 부하 테스트   (OCCT 공식 사이트 열기)'
        Say ' 6. 보고서 다시 열기'
        Say ' 0. 종료'
        $sel = Read-Host '번호 선택'
        switch ($sel) {
            '1' { Run-MemtestVulkan }
            '2' { Run-BlueScreenView }
            '3' {
                $ok = Read-Host '작업을 저장하세요. 지금 재부팅하여 RAM 검사를 할까요? (y/n)'
                if ($ok -eq 'y') { Start-Process "$env:SystemRoot\System32\MdSched.exe" }
            }
            '4' { Start-Process 'https://www.hwinfo.com/download/' }
            '5' { Start-Process 'https://www.ocbase.com/download' }
            '6' { Start-Process $Report }
            '0' { break }
            default { }
        }
        if ($sel -eq '0') { break }
    }
}

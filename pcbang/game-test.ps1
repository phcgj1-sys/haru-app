# PC방 게임 점검 - 실전 게임 테스트 (Windows PowerShell 5.1 이상)
# 실제 게임을 하는 동안 FPS·프레임 시간(PresentMon), CPU·그래픽 사용률, 그래픽 온도·클럭,
# 메모리, 게이트웨이·외부·게임 서버 핑을 1초마다 기록하고 결과 코드(PCBANGG1:...)를 만듭니다.
# 사용법:
#   game-test.bat                      (측정 시간을 물어봄)
#   game-test.bat -Seconds 120 -Delay 20 -Seat 23 -Share \\SERVER\pcbang
# FPS 측정(PresentMon)은 관리자 권한이 필요합니다. bat이 관리자 권한을 요청해요.
# 정보는 어디로도 전송하지 않습니다(핑 신호만 나감).

param(
  [int]$Seconds = 0,
  [int]$Delay = -1,
  [string]$Seat = '',
  [string]$Share = ''
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
Remove-TypeData System.Array -ErrorAction SilentlyContinue

function Say($t, $c) { if ($c) { Write-Host $t -ForegroundColor $c } else { Write-Host $t } }
function R1($v) { if ($null -eq $v) { return $null } return [math]::Round([double]$v, 1) }
function Avg($a) { $l = @($a | Where-Object { $null -ne $_ }); if (-not $l.Count) { return $null }; return R1 (($l | Measure-Object -Average).Average) }
function Mx($a) { $l = @($a | Where-Object { $null -ne $_ }); if (-not $l.Count) { return $null }; return R1 (($l | Measure-Object -Maximum).Maximum) }

$base = $PSScriptRoot; if (-not $base) { $base = [Environment]::GetFolderPath('Desktop') }
$isAdmin = $false
try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch {}

Say ''
Say '==============================================' Cyan
Say '  PC방 게임 점검 - 실전 게임 테스트' Cyan
Say '==============================================' Cyan
Say '실제 게임을 하는 동안 FPS, 끊김, CPU·그래픽 사용률, 온도, 핑을 기록해요.'
if (-not $isAdmin) { Say '※ 관리자 권한이 아니어서 FPS는 잴 수 없어요(사용률·온도·핑은 기록돼요).' Yellow }
Say ''

# ---------- 좌석·공유 폴더 ----------
$computer = $env:COMPUTERNAME
$seatVal = $null
if ($Seat -and $Seat.Trim()) { $s = $Seat.Trim(); if ($s -match '^\d{1,9}$') { $seatVal = [int]$s } else { $seatVal = $s } }
elseif ($computer -match '^(?:PC|SEAT|S)?[-_]?0*(\d{1,4})$' -or $computer -match '^[A-Za-z]{1,10}[-_]0*(\d{1,4})$') { $seatVal = [int]$matches[1] }
if (-not $Share) {
  try {
    $cfgPath = Join-Path $base 'pc-check.config'
    if (Test-Path $cfgPath) { foreach ($ln in (Get-Content -Path $cfgPath -Encoding UTF8)) { if ($ln -match '^\s*share\s*=\s*(.+?)\s*$') { $Share = $matches[1] } } }
  } catch {}
}

# ---------- 측정 시간 ----------
if ($Seconds -le 0) {
  Say '측정 시간을 고르세요:  1) 1분   2) 2분 (권장)   3) 5분'
  $ans = Read-Host '번호'
  if ($ans -eq '1') { $Seconds = 60 } elseif ($ans -eq '3') { $Seconds = 300 } else { $Seconds = 120 }
}
if ($Seconds -lt 20) { $Seconds = 20 }
if ($Seconds -gt 900) { $Seconds = 900 }
if ($Delay -lt 0) { $Delay = 20 }

# ---------- PresentMon 준비 ----------
$pm = $null; $pmMajor = 2
function FindPM {
  $c = @(Get-ChildItem -Path $base -Filter 'PresentMon*.exe' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'arm' } | Sort-Object Name -Descending)
  if ($c.Count) { return $c[0].FullName }
  $c = @(Get-ChildItem -Path $env:TEMP -Filter 'PresentMon*-x64.exe' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
  if ($c.Count) { return $c[0].FullName }
  return $null
}
if ($isAdmin) {
  $pm = FindPM
  if (-not $pm) {
    Say 'FPS 측정 도구(PresentMon, 인텔 공개 프로그램)를 내려받는 중...' Yellow
    try {
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
      $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/GameTechDev/PresentMon/releases/latest' -TimeoutSec 15 -Headers @{ 'User-Agent' = 'pcbang-check' }
      $asset = @($rel.assets | Where-Object { $_.name -match '^PresentMon-[\d\.]+-x64\.exe$' })[0]
      if ($asset) {
        $dest = Join-Path $base $asset.name
        try { Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dest -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop } catch {
          $dest = Join-Path $env:TEMP $asset.name
          Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $dest -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        }
        if (Test-Path $dest) { $pm = $dest }
      }
    } catch {}
    if (-not $pm) {
      Say '  내려받지 못했어요. https://github.com/GameTechDev/PresentMon/releases 에서' Red
      Say '  PresentMon-버전-x64.exe 를 받아 이 폴더에 넣으면 FPS도 잴 수 있어요. (이번에는 FPS 없이 진행)' Red
    }
  }
  if ($pm -and ((Split-Path $pm -Leaf) -match 'PresentMon-?(\d+)\.')) { $pmMajor = [int]$matches[1] }
}

# ---------- nvidia-smi ----------
$smi = $null
foreach ($cand in @((Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue).Source, "$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe")) {
  if ($cand -and (Test-Path $cand)) { $smi = $cand; break }
}

# ---------- 게이트웨이 ----------
$gateway = $null
try {
  $rt = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object { $_.RouteMetric + [int](Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric } | Select-Object -First 1
  if ($rt -and $rt.NextHop -match '^\d+\.\d+\.\d+\.\d+$' -and $rt.NextHop -ne '0.0.0.0') { $gateway = $rt.NextHop }
} catch {}
if (-not $gateway) {
  $cfg = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE' | Where-Object { $_.DefaultIPGateway } | Select-Object -First 1
  if ($cfg) { $gateway = @($cfg.DefaultIPGateway | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })[0] }
}
$extHost = '168.126.63.1'

# ---------- 대기 ----------
Say ''
Say ("게임을 켜고 실제로 플레이하세요. {0}초 뒤에 측정을 시작해서 {1}초 동안 기록해요." -f $Delay, $Seconds) Green
Say '시작·끝날 때 "삑" 소리가 나요. 측정 중에는 게임만 하세요(이 창은 그대로 두세요).'
for ($i = $Delay; $i -gt 0; $i--) { Write-Host -NoNewline ("`r  시작까지 {0,3}초  " -f $i); Start-Sleep -Seconds 1 }
Write-Host ''
try { [Console]::Beep(880, 250) } catch {}

# ---------- 측정 시작 ----------
$stamp = Get-Date
$pmCsv = Join-Path $env:TEMP ("pcbang_pm_{0}.csv" -f $PID)
$nvCsv = Join-Path $env:TEMP ("pcbang_nv_{0}.csv" -f $PID)
Remove-Item $pmCsv, $nvCsv -ErrorAction SilentlyContinue
$pmProc = $null
if ($pm) {
  if ($pmMajor -ge 2) { $pmArgs = @('--output_file', ('"{0}"' -f $pmCsv), '--timed', ($Seconds + 1), '--terminate_after_timed', '--stop_existing_session') }
  else { $pmArgs = @('-output_file', ('"{0}"' -f $pmCsv), '-timed', ($Seconds + 1), '-terminate_after_timed', '-stop_existing_session') }
  try { $pmProc = Start-Process -FilePath $pm -ArgumentList $pmArgs -WindowStyle Hidden -PassThru -ErrorAction Stop } catch { $pmProc = $null }
}
$nvProc = $null
if ($smi) {
  try { $nvProc = Start-Process -FilePath $smi -ArgumentList @('--query-gpu=temperature.gpu,utilization.gpu,clocks.sm,power.draw,fan.speed', '--format=csv,noheader,nounits', '-l', '1', '-f', ('"{0}"' -f $nvCsv)) -WindowStyle Hidden -PassThru -ErrorAction Stop } catch { $nvProc = $null }
}

$tl = New-Object System.Collections.ArrayList
$gpuByPid = @{}
$gameSrv = $null
$swAll = [System.Diagnostics.Stopwatch]::StartNew()
for ($sec = 0; $sec -lt $Seconds; $sec++) {
  $tick = [System.Diagnostics.Stopwatch]::StartNew()
  $pgGw = $null; $pgEx = $null; $pgGs = $null
  try { if ($gateway) { $pgGw = (New-Object System.Net.NetworkInformation.Ping).SendPingAsync($gateway, 900) } } catch {}
  try { $pgEx = (New-Object System.Net.NetworkInformation.Ping).SendPingAsync($extHost, 900) } catch {}
  try { if ($gameSrv) { $pgGs = (New-Object System.Net.NetworkInformation.Ping).SendPingAsync($gameSrv, 900) } } catch {}
  $smp = [ordered]@{ t = $sec; cpu = $null; core = $null; gpu = $null; mem = $null; gw = $null; ext = $null; gs = $null }
  try {
    $cp = @(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -OperationTimeoutSec 2)
    $tot = $cp | Where-Object { $_.Name -eq '_Total' } | Select-Object -First 1
    if ($tot) { $smp.cpu = [int]$tot.PercentProcessorTime }
    $cores = @($cp | Where-Object { $_.Name -ne '_Total' } | ForEach-Object { [int]$_.PercentProcessorTime })
    if ($cores.Count) { $smp.core = ($cores | Measure-Object -Maximum).Maximum }
  } catch {}
  try {
    $eng = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -Filter "Name LIKE '%engtype_3D%'" -OperationTimeoutSec 2)
    $sum = 0
    foreach ($e in $eng) {
      $u = [double]$e.UtilizationPercentage; $sum += $u
      if ($u -gt 0 -and $e.Name -match '^pid_(\d+)_') { $k = [int]$matches[1]; if ($gpuByPid.ContainsKey($k)) { $gpuByPid[$k] += $u } else { $gpuByPid[$k] = $u } }
    }
    if ($eng.Count) { $smp.gpu = [int][math]::Min(100, $sum) }
  } catch {}
  try { $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 2; $smp.mem = [int](100 - [double]$os.FreePhysicalMemory / [double]$os.TotalVisibleMemorySize * 100) } catch {}
  # 게임 서버(TCP) 찾기: 10초마다, 그래픽을 가장 많이 쓰는 프로세스의 연결 중 웹(80/443)이 아닌 공인 IP
  if (-not $gameSrv -and ($sec % 10) -eq 5 -and $gpuByPid.Count) {
    try {
      $gpid = ($gpuByPid.GetEnumerator() | Sort-Object Value -Descending | Where-Object { (Get-Process -Id $_.Key -ErrorAction SilentlyContinue).ProcessName -notmatch '^(dwm|explorer|chrome|msedge|firefox|whale|discord)$' } | Select-Object -First 1).Key
      if ($gpid) {
        $cn = @(Get-NetTCPConnection -OwningProcess $gpid -State Established -ErrorAction Stop | Where-Object { $_.RemotePort -ne 443 -and $_.RemotePort -ne 80 -and $_.RemoteAddress -match '^\d+\.\d+\.\d+\.\d+$' -and $_.RemoteAddress -notmatch '^(10\.|127\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.)' })
        if ($cn.Count) { $gameSrv = $cn[0].RemoteAddress }
      }
    } catch {}
  }
  foreach ($pair in @(@('gw', $pgGw), @('ext', $pgEx), @('gs', $pgGs))) {
    $tk = $pair[1]
    if ($tk) { try { if ($tk.Wait(1000)) { $r = $tk.Result; if ($r.Status -eq 'Success') { $smp[$pair[0]] = [int]$r.RoundtripTime } else { $smp[$pair[0]] = -1 } } else { $smp[$pair[0]] = -1 } } catch { $smp[$pair[0]] = -1 } }
  }
  [void]$tl.Add($smp)
  $left = $Seconds - $sec - 1
  $pingTxt = '-'; if ($null -ne $smp.gw -and $smp.gw -ge 0) { $pingTxt = ('{0}ms' -f $smp.gw) } elseif ($smp.gw -eq -1) { $pingTxt = '손실' }
  Write-Host -NoNewline ("`r  남은 {0,3}초 | CPU {1,3}% | 그래픽 {2,3}% | 메모리 {3,3}% | 게이트웨이 {4}      " -f $left, $smp.cpu, $smp.gpu, $smp.mem, $pingTxt)
  $rest = 1000 - [int]$tick.ElapsedMilliseconds
  if ($rest -gt 0) { Start-Sleep -Milliseconds $rest }
}
Write-Host ''
try { [Console]::Beep(660, 200); [Console]::Beep(990, 300) } catch {}
Say '측정 끝. 결과를 정리하는 중...' Yellow

if ($pmProc) { try { Wait-Process -Id $pmProc.Id -Timeout 15 -ErrorAction Stop } catch { try { Stop-Process -Id $pmProc.Id -Force } catch {} } }
if ($nvProc) { try { Stop-Process -Id $nvProc.Id -Force } catch {} }

# 그래픽을 가장 많이 쓴 프로세스 = 게임
$gamePid = $null; $gameExe = $null
try {
  foreach ($kv in ($gpuByPid.GetEnumerator() | Sort-Object Value -Descending)) {
    $pn = (Get-Process -Id $kv.Key -ErrorAction SilentlyContinue).ProcessName
    if ($pn -and $pn -notmatch '^(dwm|explorer|chrome|msedge|firefox|whale|discord|powershell|conhost)$') { $gamePid = [int]$kv.Key; $gameExe = $pn + '.exe'; break }
  }
} catch {}

# ---------- PresentMon 결과 해석 ----------
$fps = $null; $fpsTl = @(); $ftMaxTl = @(); $gpuBusyRatio = $null; $pmApp = $null; $pmNote = $null
if ($pm) {
  if (-not (Test-Path $pmCsv)) { $pmNote = 'PresentMon 결과 파일이 없음(보안 프로그램 차단 또는 실행 실패)' }
  else {
    try {
      $sr = New-Object System.IO.StreamReader($pmCsv)
      $hdr = $sr.ReadLine().Split(',')
      $ix = @{}; for ($k = 0; $k -lt $hdr.Length; $k++) { $ix[$hdr[$k].Trim().ToLower()] = $k }
      $iApp = $ix['application']; $iPid = $ix['processid']
      $iFt = $null; foreach ($cn in @('msbetweenpresents', 'frametime', 'msbetweenappstart', 'msbetweendisplaychange')) { if ($ix.ContainsKey($cn)) { $iFt = $ix[$cn]; break } }
      $iGb = $null; if ($ix.ContainsKey('msgpubusy')) { $iGb = $ix['msgpubusy'] }
      $byApp = @{}
      while ($null -ne ($ln = $sr.ReadLine())) {
        $f = $ln.Split(',')
        if ($null -eq $iFt -or $f.Length -le $iFt) { continue }
        $ft = 0.0; if (-not [double]::TryParse($f[$iFt], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$ft)) { continue }
        if ($ft -le 0 -or $ft -gt 5000) { continue }
        $key = $f[$iApp] + '|' + $f[$iPid]
        if (-not $byApp.ContainsKey($key)) { $byApp[$key] = @{ ft = (New-Object System.Collections.Generic.List[double]); gb = 0.0; gbn = 0 } }
        $byApp[$key].ft.Add($ft)
        if ($null -ne $iGb -and $f.Length -gt $iGb) { $g = 0.0; if ([double]::TryParse($f[$iGb], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$g)) { $byApp[$key].gb += $g; $byApp[$key].gbn++ } }
      }
      $sr.Close()
      $pick = $null
      if ($gamePid) { $pick = @($byApp.Keys | Where-Object { $_ -match ('\|' + $gamePid + '$') })[0] }
      if (-not $pick) { $pick = @($byApp.Keys | Where-Object { $_ -notmatch '^(dwm|explorer|chrome|msedge|firefox|whale|discord)' } | Sort-Object { $byApp[$_].ft.Count } -Descending)[0] }
      if ($pick -and $byApp[$pick].ft.Count -ge 30) {
        $pmApp = ($pick -split '\|')[0]
        $arr = $byApp[$pick].ft.ToArray()
        $tot = 0.0; foreach ($x in $arr) { $tot += $x }
        $srt = $arr.Clone(); [Array]::Sort($srt)
        $n = $srt.Length
        $p = { param($q) $srt[[math]::Min($n - 1, [int][math]::Floor($q * ($n - 1)))] }
        $med = & $p 0.5
        $w1 = [math]::Max(1, [int][math]::Floor($n * 0.01)); $w01 = [math]::Max(1, [int][math]::Floor($n * 0.001))
        $s1 = 0.0; for ($k = $n - $w1; $k -lt $n; $k++) { $s1 += $srt[$k] }
        $s01 = 0.0; for ($k = $n - $w01; $k -lt $n; $k++) { $s01 += $srt[$k] }
        $stut = 0; foreach ($x in $arr) { if ($x -gt [math]::Max(2.5 * $med, 25)) { $stut++ } }
        $fps = [ordered]@{ frames = $n; avg = R1 ($n * 1000.0 / $tot); low1 = R1 (1000.0 / ($s1 / $w1)); low01 = R1 (1000.0 / ($s01 / $w01)); p50ms = R1 $med; p99ms = R1 (& $p 0.99); maxms = R1 $srt[$n - 1]; stutters = $stut; stutterPerMin = R1 ($stut / ($tot / 60000.0)) }
        # 1초 단위 타임라인
        $acc = 0.0; $bucket = 0; $cnt = 0; $mxf = 0.0
        foreach ($x in $arr) {
          $acc += $x
          if ($acc -ge 1000.0 * ($bucket + 1)) { $fpsTl += $cnt; $ftMaxTl += (R1 $mxf); $bucket++; $cnt = 0; $mxf = 0.0 }
          $cnt++; if ($x -gt $mxf) { $mxf = $x }
        }
        if ($byApp[$pick].gbn -gt 0) { $gpuBusyRatio = R1 (($byApp[$pick].gb / $byApp[$pick].gbn) / ($tot / $n) * 100) }
      } else { $pmNote = '게임 프레임을 찾지 못함(게임이 실행 중이었는지 확인)' }
    } catch { $pmNote = 'PresentMon 결과를 읽지 못함' }
  }
  Remove-Item $pmCsv -ErrorAction SilentlyContinue
}

# ---------- nvidia-smi 결과 ----------
$nvT = @(); $nvU = @(); $nvC = @(); $nvP = @(); $nvF = @()
if (Test-Path $nvCsv) {
  foreach ($ln in (Get-Content $nvCsv)) {
    $f = $ln.Split(',') | ForEach-Object { $_.Trim() }
    if ($f.Count -ge 5) {
      $v = 0.0
      if ([double]::TryParse($f[0], [ref]$v)) { $nvT += $v }
      if ([double]::TryParse($f[1], [ref]$v)) { $nvU += $v }
      if ([double]::TryParse($f[2], [ref]$v)) { $nvC += $v }
      if ([double]::TryParse($f[3], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { $nvP += $v }
      if ([double]::TryParse($f[4], [ref]$v)) { $nvF += $v }
    }
  }
  Remove-Item $nvCsv -ErrorAction SilentlyContinue
}

# ---------- 요약 ----------
$cpuA = @($tl | ForEach-Object { $_.cpu }); $coreA = @($tl | ForEach-Object { $_.core }); $gpuA = @($tl | ForEach-Object { $_.gpu }); $memA = @($tl | ForEach-Object { $_.mem })
if ($nvU.Count) { $gpuUse = $nvU } else { $gpuUse = $gpuA }
function PingSum($vals) {
  $all = @($vals | Where-Object { $null -ne $_ })
  if (-not $all.Count) { return $null }
  $ok = @($all | Where-Object { $_ -ge 0 }); $lost = $all.Count - $ok.Count
  $o = [ordered]@{ n = $all.Count; loss = R1 ($lost * 100.0 / $all.Count) }
  if ($ok.Count) {
    $o.avg = Avg $ok; $o.max = Mx $ok
    $j = 0.0; for ($k = 1; $k -lt $ok.Count; $k++) { $j += [math]::Abs($ok[$k] - $ok[$k - 1]) }
    if ($ok.Count -gt 1) { $o.jitter = R1 ($j / ($ok.Count - 1)) } else { $o.jitter = 0 }
    $o.spikes = @($ok | Where-Object { $_ -gt ($o.avg + 50) }).Count
  }
  return $o
}
$ping = [ordered]@{ gwHost = $gateway; extHost = $extHost; gsHost = $gameSrv; gw = (PingSum @($tl | ForEach-Object { $_.gw })); ext = (PingSum @($tl | ForEach-Object { $_.ext })); gs = (PingSum @($tl | ForEach-Object { $_.gs })) }

$gpuName = $null; $hz = $null
try { $vc = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Microsoft Basic|Remote|Virtual|Parsec' }); if ($vc.Count) { $gpuName = ($vc | Select-Object -First 1).Name; $hz = [int]($vc | Select-Object -First 1).CurrentRefreshRate } } catch {}
$cpuName = $null; try { $cpuName = ((Get-CimInstance Win32_Processor | Select-Object -First 1).Name -replace '\s+', ' ').Trim() } catch {}
$ramGB = $null; try { $ramGB = [math]::Round(((Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum) / 1GB) } catch {}

$gpu = [ordered]@{ utilAvg = (Avg $gpuUse); utilMax = (Mx $gpuUse) }
if ($nvT.Count) {
  $gpu.tempAvg = Avg $nvT; $gpu.tempMax = Mx $nvT; $gpu.powerAvg = Avg $nvP; $gpu.fanMax = Mx $nvF
  $third = [math]::Max(1, [int][math]::Floor($nvC.Count / 3))
  if ($nvC.Count -ge 6) { $gpu.clockStart = Avg ($nvC[0..($third - 1)]); $gpu.clockEnd = Avg ($nvC[($nvC.Count - $third)..($nvC.Count - 1)]) }
}

$verd = New-Object System.Collections.ArrayList
$bottle = '판단 어려움'
$gu = $gpu.utilAvg; $ca = Avg $coreA
if ($null -ne $gu) {
  if ($gu -ge 90) { $bottle = '그래픽' }
  elseif ($null -ne $ca -and $ca -ge 85) { $bottle = 'CPU' }
  elseif ($gu -lt 75 -and $fps -and $fps.avg -and ($null -ne $hz) -and [math]::Abs($fps.avg - $hz) -lt 3) { $bottle = '프레임 제한(수직 동기화·FPS 제한)' }
  elseif ($gu -lt 75) { $bottle = 'CPU 또는 게임 엔진' }
  else { $bottle = '여유 있음' }
}
if ($null -ne $gpuBusyRatio) { if ($gpuBusyRatio -ge 90) { $bottle = '그래픽' } elseif ($gpuBusyRatio -lt 70 -and $bottle -eq '그래픽') { $bottle = 'CPU 또는 게임 엔진' } }
if ($fps) {
  if ($hz -and $fps.avg -lt $hz * 0.9) { [void]$verd.Add(('평균 {0}fps로 모니터 {1}Hz보다 낮음 (병목: {2})' -f $fps.avg, $hz, $bottle)) }
  if ($fps.stutterPerMin -ge 6) { [void]$verd.Add(('끊김(스터터) 분당 {0}회 - 저장 장치·백그라운드 프로그램·램 확인' -f $fps.stutterPerMin)) }
  if ($fps.low1 -lt $fps.avg * 0.5) { [void]$verd.Add(('1% 최저 {0}fps가 평균의 절반 미만 - 순간 프레임 급락' -f $fps.low1)) }
}
if ($gpu.tempMax -ge 85) { [void]$verd.Add(('그래픽카드 최고 {0}°C - 먼지 청소·팬 확인' -f $gpu.tempMax)) }
if ($gpu.clockStart -and $gpu.clockEnd -and $gpu.clockEnd -lt $gpu.clockStart * 0.9 -and $gpu.tempMax -ge 80) { [void]$verd.Add(('그래픽 클럭이 {0}→{1}MHz로 떨어짐 - 발열로 성능 저하(스로틀링) 의심' -f $gpu.clockStart, $gpu.clockEnd)) }
if ((Mx $memA) -ge 90) { [void]$verd.Add(('메모리 사용 최고 {0}% - 램 부족으로 끊김 가능' -f (Mx $memA))) }
if ($ping.gw -and ($ping.gw.loss -gt 0 -or ($ping.gw.avg -gt 3))) { [void]$verd.Add(('게임 중 게이트웨이 핑 이상(평균 {0}ms, 손실 {1}%) - 매장 안 네트워크 문제' -f $ping.gw.avg, $ping.gw.loss)) }
if ($ping.ext -and ($ping.ext.loss -ge 2 -or $ping.ext.spikes -ge 3)) { [void]$verd.Add(('게임 중 외부 핑 불안정(손실 {0}%, 튐 {1}회)' -f $ping.ext.loss, $ping.ext.spikes)) }
if (-not $verd.Count) { [void]$verd.Add('측정 중 눈에 띄는 문제가 없어요') }

$result = [ordered]@{
  v = 1; kind = 'game'; seat = $seatVal; computer = $computer; time = $stamp.ToString('yyyy-MM-dd HH:mm'); durationS = $Seconds
  app = $(if ($pmApp) { $pmApp } else { $gameExe }); admin = $isAdmin; pmUsed = [bool]$pm; pmNote = $pmNote
  cpuName = $cpuName; gpuName = $gpuName; ramGB = $ramGB; hz = $hz
  fps = $fps; gpuBusyPct = $gpuBusyRatio; bottleneck = $bottle
  cpu = [ordered]@{ avg = (Avg $cpuA); max = (Mx $cpuA); coreAvg = (Avg $coreA); coreMax = (Mx $coreA) }
  gpu = $gpu; mem = [ordered]@{ avg = (Avg $memA); max = (Mx $memA) }; ping = $ping
  tl = [ordered]@{ fps = [object[]]$fpsTl; ftMax = [object[]]$ftMaxTl; cpu = [object[]]$cpuA; core = [object[]]$coreA; gpu = [object[]]$gpuUse; temp = [object[]]$nvT; mem = [object[]]$memA; gw = [object[]]@($tl | ForEach-Object { $_.gw }); ext = [object[]]@($tl | ForEach-Object { $_.ext }) }
  verdicts = [object[]]$verd
}

Say ''
Say '==============================================' Cyan
Say ('  게임: {0}' -f $result.app)
if ($fps) {
  Say ('  평균 {0}fps · 1% 최저 {1}fps · 0.1% 최저 {2}fps' -f $fps.avg, $fps.low1, $fps.low01) Green
  Say ('  프레임 시간 중간 {0}ms · 상위 1% {1}ms · 최대 {2}ms · 끊김 {3}회' -f $fps.p50ms, $fps.p99ms, $fps.maxms, $fps.stutters)
} else { Say ('  FPS: 측정 안 됨 {0}' -f $pmNote) Yellow }
Say ('  CPU 평균 {0}% (가장 바쁜 코어 평균 {1}%) · 그래픽 평균 {2}% · 메모리 최고 {3}%' -f $result.cpu.avg, $result.cpu.coreAvg, $gpu.utilAvg, $result.mem.max)
if ($gpu.tempMax) { Say ('  그래픽 온도 평균 {0}°C · 최고 {1}°C' -f $gpu.tempAvg, $gpu.tempMax) }
if ($ping.gw) { Say ('  게이트웨이 핑 평균 {0}ms · 최대 {1}ms · 손실 {2}%' -f $ping.gw.avg, $ping.gw.max, $ping.gw.loss) }
if ($ping.ext) { Say ('  외부(KT DNS) 핑 평균 {0}ms · 최대 {1}ms · 손실 {2}%' -f $ping.ext.avg, $ping.ext.max, $ping.ext.loss) }
if ($ping.gs) { Say ('  게임 서버({0}) 핑 평균 {1}ms · 손실 {2}%' -f $gameSrv, $ping.gs.avg, $ping.gs.loss) }
Say ('  병목: {0}' -f $bottle)
foreach ($v in $verd) { Say ('  - ' + $v) Yellow }

$json = $result | ConvertTo-Json -Depth 6 -Compress
$code = 'PCBANGG1:' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
$copied = $false
try { Set-Clipboard -Value $code -ErrorAction Stop; $copied = $true } catch { $code | clip.exe; $copied = ($LASTEXITCODE -eq 0) }
$tag = $(if ($null -ne $seatVal) { 'seat-' + $seatVal } else { $computer })
$fname = ('game-{0}-{1}.txt' -f $tag, $stamp.ToString('yyyyMMdd-HHmm'))
$desk = Join-Path ([Environment]::GetFolderPath('Desktop')) $fname
try { $code | Out-File -FilePath $desk -Encoding ascii -ErrorAction Stop; Say ('  결과 파일: {0}' -f $desk) } catch {}
if ($Share) {
  try {
    if (-not (Test-Path $Share)) { New-Item -ItemType Directory -Path $Share -Force | Out-Null }
    $code | Out-File -FilePath (Join-Path $Share $fname) -Encoding ascii -ErrorAction Stop
    Say ('  공유 폴더에도 저장: {0}' -f (Join-Path $Share $fname)) Green
  } catch { Say '  공유 폴더 저장 실패(권한·경로 확인)' Red }
}
if ($copied) { Say '  결과 코드를 클립보드에 복사했어요. 웹 앱 [실전 테스트] 탭에 붙여넣으세요.' Green }
Say '==============================================' Cyan
Say ''

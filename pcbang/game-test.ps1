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
# 게임이 아닌 프로그램(브라우저·런처·메신저·녹화 등)
$skipRx = '^(dwm|explorer|chrome|msedge|msedgewebview2|firefox|whale|discord|powershell|pwsh|conhost|steamwebhelper|steam|EpicGamesLauncher|Battle\.net|LeagueClientUx|LeagueClientUxRender|RiotClientUx|RiotClientUxRender|obs64|KakaoTalk|nvcontainer|NVIDIA Share|GameBar|ApplicationFrameHost|TextInputHost|SearchHost|SearchApp|ShellExperienceHost|StartMenuExperienceHost|Overwolf|PresentMon.*|nvidia-smi)$'
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
    if (Test-Path -LiteralPath $cfgPath) {
      # 점검 프로그램과 같은 방식: UTF-8이 아니면(메모장 ANSI 저장) 한국어 코드 페이지(949)로 읽음
      $bytes = [System.IO.File]::ReadAllBytes($cfgPath); $txt = $null
      try { $txt = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes) } catch { $txt = [System.Text.Encoding]::GetEncoding(949).GetString($bytes) }
      foreach ($ln in ($txt.TrimStart([char]0xFEFF) -split "`r?`n")) { if ($ln -match '^\s*share\s*=\s*(.+?)\s*$') { $Share = $matches[1] } }
    }
  } catch {}
}
# 경로 정리: 따옴표, 끝의 \ (bat 에서 "\\SERVER\pc bang\" 처럼 넘기면 \" 가 따옴표를 먹어 " 가 붙어 들어옴)
if ($Share) { $Share = $Share.Trim().Trim('"').TrimEnd('\', '"').Trim() }

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
$pm = $null
function FindPM {
  $ver = { if ($_.Name -match '(\d+(\.\d+)+)') { try { [version]$matches[1] } catch { [version]'0.0' } } else { [version]'0.0' } }
  $c = @(Get-ChildItem -Path $base -Filter 'PresentMon*.exe' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'arm' } | Sort-Object $ver -Descending)
  if ($c.Count) { return $c[0].FullName }
  $c = @(Get-ChildItem -Path $env:TEMP -Filter 'PresentMon*-x64.exe' -ErrorAction SilentlyContinue | Sort-Object $ver -Descending)
  if ($c.Count) { return $c[0].FullName }
  return $null
}
if ($isAdmin) {
  $pm = FindPM
  if (-not $pm) {
    Say 'FPS 측정 도구(PresentMon, 인텔 공개 프로그램)를 내려받는 중...' Yellow
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $url = $null; $name = $null; $size = 0
    try {
      $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/GameTechDev/PresentMon/releases/latest' -TimeoutSec 15 -Headers @{ 'User-Agent' = 'pcbang-check' } -ErrorAction Stop
      $asset = @($rel.assets | Where-Object { $_.name -match '^PresentMon-[\d\.]+-x64\.exe$' })[0]
      if ($asset) { $url = $asset.browser_download_url; $name = $asset.name; $size = [long]$asset.size }
    } catch {}
    # GitHub API는 매장 IP 하나당 시간당 60회 제한 → 실패하면 고정 버전 주소
    if (-not $url) { $name = 'PresentMon-2.3.1-x64.exe'; $url = 'https://github.com/GameTechDev/PresentMon/releases/download/v2.3.1/' + $name }
    foreach ($dir in @($base, $env:TEMP)) {
      $dest = Join-Path $dir $name; $tmp = $dest + '.tmp'
      try {
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        if ($size -and (Get-Item $tmp).Length -ne $size) { throw 'size' }
        if ((Get-Item $tmp).Length -lt 100000) { throw 'small' }
        Move-Item $tmp $dest -Force -ErrorAction Stop; $pm = $dest; break
      } catch { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }
    if (-not $pm) {
      Say '  내려받지 못했어요. https://github.com/GameTechDev/PresentMon/releases 에서' Red
      Say '  PresentMon-버전-x64.exe 를 받아 이 폴더에 넣으면 FPS도 잴 수 있어요. (이번에는 FPS 없이 진행)' Red
    }
  }
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
try { $null = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor; $null = Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -Filter "Name LIKE '%engtype_3D%'" } catch {}
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
  # PresentMon 1.x~2.x 모두 -옵션 형식을 받음. 다른 프로그램 세션을 건드리지 않게 전용 세션 이름 사용
  $pmArgs = @('-output_file', ('"{0}"' -f $pmCsv), '-timed', ($Seconds + 1), '-terminate_after_timed', '-session_name', 'pcbang_game', '-stop_existing_session')
  try { $pmProc = Start-Process -FilePath $pm -ArgumentList $pmArgs -WindowStyle Hidden -PassThru -ErrorAction Stop } catch { $pmProc = $null }
}
$nvProc = $null
if ($smi) {
  try { $nvProc = Start-Process -FilePath $smi -ArgumentList @('--query-gpu=temperature.gpu,utilization.gpu,clocks.sm,power.draw,fan.speed', '--format=csv,noheader,nounits', '-l', '1', '-f', ('"{0}"' -f $nvCsv)) -WindowStyle Hidden -PassThru -ErrorAction Stop } catch { $nvProc = $null }
}

$tl = New-Object System.Collections.ArrayList
$gpuByPid = @{}
$gameSrv = $null
$pingGw = New-Object System.Net.NetworkInformation.Ping; $pingEx = New-Object System.Net.NetworkInformation.Ping; $pingGs = New-Object System.Net.NetworkInformation.Ping
$swAll = [System.Diagnostics.Stopwatch]::StartNew()
for ($sec = 0; $sec -lt $Seconds; $sec++) {
    $pgGw = $null; $pgEx = $null; $pgGs = $null
  try { if ($gateway) { $pgGw = $pingGw.SendPingAsync($gateway, 900) } } catch {}
  try { $pgEx = $pingEx.SendPingAsync($extHost, 900) } catch {}
  try { if ($gameSrv) { $pgGs = $pingGs.SendPingAsync($gameSrv, 900) } } catch {}
  $smp = [ordered]@{ t = [math]::Round($swAll.Elapsed.TotalSeconds, 1); cpu = $null; core = $null; gpu = $null; mem = $null; gw = $null; ext = $null; gs = $null; clk = $null }
  try {
    $cp = @(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -OperationTimeoutSec 2)
    $tot = $cp | Where-Object { $_.Name -eq '_Total' } | Select-Object -First 1
    if ($tot) { $smp.cpu = [int]$tot.PercentProcessorTime }
    $cores = @($cp | Where-Object { $_.Name -ne '_Total' } | ForEach-Object { [int]$_.PercentProcessorTime })
    if ($cores.Count) { $smp.core = ($cores | Measure-Object -Maximum).Maximum }
  } catch {}
  try {
    $eng = @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -Filter "Name LIKE '%engtype_3D%'" -OperationTimeoutSec 2)
    $byEng = @{}
    foreach ($e in $eng) {
      $u = [double]$e.UtilizationPercentage
      $ek = ($e.Name -replace '^pid_\d+_', ''); if ($byEng.ContainsKey($ek)) { $byEng[$ek] += $u } else { $byEng[$ek] = $u }
      if ($u -gt 0 -and $e.Name -match '^pid_(\d+)_') { $k = [int]$matches[1]; if ($gpuByPid.ContainsKey($k)) { $gpuByPid[$k] += $u } else { $gpuByPid[$k] = $u } }
    }
    if ($byEng.Count) { $smp.gpu = [int][math]::Min(100, ($byEng.Values | Measure-Object -Maximum).Maximum) }
  } catch {}
  # CPU 실제 클럭(MHz) = 기본 클럭 × 성능% (관리자 권한 없이 읽는 성능 카운터)
  try { $pi = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -OperationTimeoutSec 2; if ($pi -and $pi.ProcessorFrequency) { $smp.clk = [int]([double]$pi.ProcessorFrequency * [double]$pi.PercentProcessorPerformance / 100) } } catch {}
  try { $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 2; $smp.mem = [int](100 - [double]$os.FreePhysicalMemory / [double]$os.TotalVisibleMemorySize * 100) } catch {}
  # 게임 서버(TCP) 찾기: 10초마다, 그래픽을 가장 많이 쓰는 프로세스의 연결 중 웹(80/443)이 아닌 공인 IP
  if (-not $gameSrv -and ($sec % 10) -eq 5 -and $gpuByPid.Count) {
    try {
      $gpid = ($gpuByPid.GetEnumerator() | Sort-Object Value -Descending | Where-Object { $pn = (Get-Process -Id $_.Key -ErrorAction SilentlyContinue).ProcessName; $pn -and $pn -notmatch $skipRx } | Select-Object -First 1).Key
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
  $rest = ($sec + 1) * 1000 - [int]$swAll.ElapsedMilliseconds
  if ($rest -gt 0) { Start-Sleep -Milliseconds $rest }
  elseif ($rest -lt -1500) {
    # 측정이 1.5초 넘게 밀리면(성능 카운터 응답 지연 등) 건너뛴 초를 빈 칸으로 채워 그래프 시간축을 FPS 그래프와 맞춤
    $nsec = [int][math]::Floor($swAll.ElapsedMilliseconds / 1000) - 1
    for ($m = $sec + 1; $m -le $nsec -and $m -lt $Seconds; $m++) { [void]$tl.Add([ordered]@{ t = $m; cpu = $null; core = $null; gpu = $null; mem = $null; gw = $null; ext = $null; gs = $null; clk = $null }) }
    $sec = $nsec
  }
}
Write-Host ''
try { [Console]::Beep(660, 200); [Console]::Beep(990, 300) } catch {}
Say '측정 끝. 결과를 정리하는 중...' Yellow

if ($pmProc) { try { Wait-Process -Id $pmProc.Id -Timeout 15 -ErrorAction Stop } catch { try { Stop-Process -Id $pmProc.Id -Force } catch {} } }
if ($nvProc) { try { Stop-Process -Id $nvProc.Id -Force } catch {}; try { Wait-Process -Id $nvProc.Id -Timeout 3 } catch {} }
try { $pingGw.Dispose(); $pingEx.Dispose(); $pingGs.Dispose() } catch {}

# 그래픽을 가장 많이 쓴 프로세스 = 게임
$gamePid = $null; $gameExe = $null
try {
  foreach ($kv in ($gpuByPid.GetEnumerator() | Sort-Object Value -Descending)) {
    $pn = (Get-Process -Id $kv.Key -ErrorAction SilentlyContinue).ProcessName
    if ($pn -and $pn -notmatch $skipRx) { $gamePid = [int]$kv.Key; $gameExe = $pn + '.exe'; break }
  }
} catch {}

# ---------- PresentMon 결과 해석 ----------
$fps = $null; $fpsTl = @(); $ftMaxTl = @(); $gpuBusyRatio = $null; $pmApp = $null; $pmNote = $null
if ($pm) {
  if (-not (Test-Path $pmCsv)) { $pmNote = 'PresentMon 결과 파일이 없음(보안 프로그램 차단 또는 실행 실패)' }
  else {
    try {
      $sr = $null
      $sr = New-Object System.IO.StreamReader($pmCsv)
      $hdr = $sr.ReadLine().Split(',')
      $ix = @{}; for ($k = 0; $k -lt $hdr.Length; $k++) { $ix[$hdr[$k].Trim().ToLower()] = $k }
      $iApp = $ix['application']; $iPid = $ix['processid']
      # 한 프로세스가 창(스왑체인)을 여러 개 쓰면 프레임이 섞여 FPS가 부풀려짐 → 스왑체인별로 나눔(1.x·2.x 모두 SwapChainAddress 열)
      $iSc = $ix['swapchainaddress']
      # 버전마다 열 이름이 다름: main/2.4+ MsBetweenPresents·MsGPUBusy, 2.1~2.3 FrameTime·GPUBusy, 2.0 CPUBusy+CPUWait, 1.x msBetweenPresents·msGPUActive
      $iFt = $null; foreach ($cn in @('msbetweenpresents', 'frametime', 'msbetweenappstart', 'msbetweendisplaychange')) { if ($ix.ContainsKey($cn)) { $iFt = $ix[$cn]; break } }
      $iCb = $ix['cpubusy']; $iCw = $ix['cpuwait']
      $iGb = $null; foreach ($cn in @('msgpubusy', 'gpubusy', 'msgpuactive')) { if ($ix.ContainsKey($cn)) { $iGb = $ix[$cn]; break } }
      $inv = [Globalization.CultureInfo]::InvariantCulture; $flt = [Globalization.NumberStyles]::Float
      $byApp = @{}
      while ($null -ne ($ln = $sr.ReadLine())) {
        $f = $ln.Split(',')
        $ft = 0.0
        if ($null -ne $iFt) { if ($f.Length -le $iFt -or -not [double]::TryParse($f[$iFt], $flt, $inv, [ref]$ft)) { continue } }
        elseif ($null -ne $iCb -and $null -ne $iCw -and $f.Length -gt [math]::Max($iCb, $iCw)) { $a1 = 0.0; $b1 = 0.0; if (-not ([double]::TryParse($f[$iCb], $flt, $inv, [ref]$a1) -and [double]::TryParse($f[$iCw], $flt, $inv, [ref]$b1))) { continue }; $ft = $a1 + $b1 }
        else { continue }
        if ($ft -le 0 -or $ft -gt 5000) { continue }
        $key = $f[$iApp] + '|' + $f[$iPid]; if ($null -ne $iSc -and $f.Length -gt $iSc) { $key += '|' + $f[$iSc] }
        if (-not $byApp.ContainsKey($key)) { $byApp[$key] = @{ ft = (New-Object System.Collections.Generic.List[double]); gb = 0.0; gbn = 0 } }
        $byApp[$key].ft.Add($ft)
        if ($null -ne $iGb -and $f.Length -gt $iGb) { $g = 0.0; if ([double]::TryParse($f[$iGb], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$g)) { $byApp[$key].gb += $g; $byApp[$key].gbn++ } }
      }
      $sr.Close(); $sr = $null
      $pick = $null
      if ($gamePid) { $pick = @($byApp.Keys | Where-Object { $_ -match ('^[^|]*\|' + $gamePid + '(\||$)') } | Sort-Object { $byApp[$_].ft.Count } -Descending)[0] }
      if (-not $pick) { $pick = @($byApp.Keys | Where-Object { (($_ -split '\|')[0] -replace '\.exe$', '') -notmatch $skipRx } | Sort-Object { $byApp[$_].ft.Count } -Descending)[0] }
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
          while ($acc -ge 1000.0 * ($bucket + 1)) { $fpsTl += $cnt; $ftMaxTl += (R1 $mxf); $bucket++; $cnt = 0; $mxf = 0.0 }
          $cnt++; if ($x -gt $mxf) { $mxf = $x }
        }
        if ($byApp[$pick].gbn -gt 0) { $gpuBusyRatio = R1 (($byApp[$pick].gb / $byApp[$pick].gbn) / ($tot / $n) * 100) }
      } else { $pmNote = '게임 프레임을 찾지 못함(게임이 실행 중이었는지 확인)' }
    } catch { $pmNote = 'PresentMon 결과를 읽지 못함' } finally { if ($sr) { $sr.Close() } }
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
      $inv = [Globalization.CultureInfo]::InvariantCulture; $flt = [Globalization.NumberStyles]::Float
      if ([double]::TryParse($f[0], $flt, $inv, [ref]$v)) { $nvT += $v }
      if ([double]::TryParse($f[1], $flt, $inv, [ref]$v)) { $nvU += $v }
      if ([double]::TryParse($f[2], $flt, $inv, [ref]$v)) { $nvC += $v }
      if ([double]::TryParse($f[3], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { $nvP += $v }
      if ([double]::TryParse($f[4], $flt, $inv, [ref]$v)) { $nvF += $v }
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

$gpuName = $null; $hz = $null; $resW = $null; $resH = $null
try { $vc = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Microsoft Basic|Remote|Virtual|Parsec' } | Sort-Object { [int]([int]$_.CurrentRefreshRate -gt 1) }, { [int]($_.Name -match 'NVIDIA|AMD|Radeon|Arc') } -Descending); if ($vc.Count) { $v0 = $vc | Select-Object -First 1; $gpuName = $v0.Name; $hz = [int]$v0.CurrentRefreshRate; $resW = [int]$v0.CurrentHorizontalResolution; $resH = [int]$v0.CurrentVerticalResolution } } catch {}
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
# 게임 자체·드라이버 FPS 제한(서든 200 등)에 붙어 있는지: 흔한 상한값 ±2.5fps, 그래픽이 꽉 차지 않았을 때 (웹 앱 판정과 같은 기준)
$capAt = $null
if ($fps -and $fps.avg -and -not ($null -ne $gu -and $gu -ge 90)) { foreach ($c in @(60, 75, 100, 120, 144, 165, 200, 240, 300, $hz)) { if ($c -and [math]::Abs($fps.avg - $c) -lt 2.5) { $capAt = $c; break } } }
if ($null -ne $gu) {
  if ($gu -ge 90) { $bottle = '그래픽' }
  elseif ($null -ne $ca -and $ca -ge 85) { $bottle = 'CPU' }
  elseif ($capAt) { $bottle = ('프레임 제한 {0}fps(게임·드라이버 FPS 제한 또는 수직 동기화)' -f $capAt) }
  elseif ($gu -lt 75) { $bottle = 'CPU 또는 게임 엔진' }
  else { $bottle = '여유 있음' }
}
if ($null -ne $gpuBusyRatio) { if ($gpuBusyRatio -ge 90) { $bottle = '그래픽' } elseif ($gpuBusyRatio -lt 70 -and $bottle -eq '그래픽') { $bottle = 'CPU 또는 게임 엔진' } }
if ($fps) {
  if ($hz -and $fps.avg -lt $hz * 0.9 -and -not $capAt) { [void]$verd.Add(('평균 {0}fps로 모니터 {1}Hz보다 낮음 (병목: {2})' -f $fps.avg, $hz, $bottle)) }
  # 60~165 에 묶이고 모니터가 더 빠르면 보통 게임 옵션의 FPS 제한·수직 동기화 설정 (200·240·300 은 게임 엔진 상한인 경우가 많아 알리지 않음)
  if ($capAt -and $hz -and $capAt -lt $hz * 0.9 -and $capAt -le 165) { [void]$verd.Add(('FPS가 {0}에 묶여 있음(모니터 {1}Hz) - 게임 옵션의 FPS 제한·수직 동기화, 그래픽 드라이버의 최대 프레임 속도 설정 확인' -f $capAt, $hz)) }
  if ($fps.stutterPerMin -ge 6) { [void]$verd.Add(('끊김(스터터) 분당 {0}회 - 저장 장치·백그라운드 프로그램·램 확인' -f $fps.stutterPerMin)) }
  if ($fps.low1 -lt $fps.avg * 0.5) { [void]$verd.Add(('1% 최저 {0}fps가 평균의 절반 미만 - 순간 프레임 급락' -f $fps.low1)) }
}
if ($gpu.tempMax -ge 85) { [void]$verd.Add(('그래픽카드 최고 {0}°C - 먼지 청소·팬 확인' -f $gpu.tempMax)) }
if ($gpu.clockStart -and $gpu.clockEnd -and $gpu.clockEnd -lt $gpu.clockStart * 0.9 -and $gpu.tempMax -ge 80) { [void]$verd.Add(('그래픽 클럭이 {0}→{1}MHz로 떨어짐 - 발열로 성능 저하(스로틀링) 의심' -f $gpu.clockStart, $gpu.clockEnd)) }
# CPU 클럭: 처음(4~18초)과 마지막 1/3 비교. 28초쯤부터 크게 떨어지면 PL1(장기 전력) 제한이나 발열 의심
$clkA = @($tl | ForEach-Object { $_.clk }); $clkStart = $null; $clkEnd = $null
$clkOk = @($clkA | Where-Object { $_ -gt 0 })
if ($clkOk.Count -ge 30) {
  $clkStart = Avg ($clkA[4..17] | Where-Object { $_ -gt 0 })
  $clkEnd = Avg ($clkA[([int]($clkA.Count * 2 / 3))..($clkA.Count - 1)] | Where-Object { $_ -gt 0 })
  if ($clkStart -and $clkEnd -and $clkEnd -lt $clkStart * 0.85 -and (Avg $coreA) -ge 50) { [void]$verd.Add(('게임 중 CPU 클럭이 {0}→{1}MHz로 떨어짐 - 전원 제한(PL1: K 없는 인텔은 65W로 묶이는 경우 많음)이나 CPU 발열 확인' -f $clkStart, $clkEnd)) }
}
if ((Mx $memA) -ge 90) { [void]$verd.Add(('메모리 사용 최고 {0}% - 램 부족으로 끊김 가능' -f (Mx $memA))) }
# 응답이 하나도 없으면(100% 손실) 핑 차단이거나 연결 끊김 → 불안정과 구분
if ($ping.gw -and $ping.gw.loss -ge 100) { [void]$verd.Add('게임 중 게이트웨이 핑 응답 없음 - 공유기·스위치가 핑을 막았거나 연결 문제(게임이 정상이면 핑 차단)') }
elseif ($ping.gw -and ($ping.gw.loss -gt 0 -or ($ping.gw.avg -gt 5))) { [void]$verd.Add(('게임 중 게이트웨이 핑 이상(평균 {0}ms, 손실 {1}%) - 매장 안 네트워크 문제' -f $ping.gw.avg, $ping.gw.loss)) }
if ($ping.ext -and $ping.ext.loss -ge 100) { [void]$verd.Add('게임 중 외부(KT DNS) 핑 응답 없음 - 방화벽의 핑 차단 또는 인터넷 끊김(게임이 정상이면 핑 차단)') }
elseif ($ping.ext -and ($ping.ext.loss -ge 2 -or $ping.ext.spikes -ge 3)) { $sp = ''; if ($null -ne $ping.ext.spikes) { $sp = (', 튐 {0}회' -f $ping.ext.spikes) }; [void]$verd.Add(('게임 중 외부 핑 불안정(손실 {0}%{1})' -f $ping.ext.loss, $sp)) }
if (-not $verd.Count) { [void]$verd.Add('측정 중 눈에 띄는 문제가 없어요') }

$result = [ordered]@{
  v = 1; kind = 'game'; seat = $seatVal; computer = $computer; time = $stamp.ToString('yyyy-MM-dd HH:mm'); durationS = $Seconds
  app = $(if ($pmApp) { $pmApp } else { $gameExe }); admin = $isAdmin; pmUsed = [bool]$pm; pmNote = $pmNote
  cpuName = $cpuName; gpuName = $gpuName; ramGB = $ramGB; hz = $hz; resW = $resW; resH = $resH
  fps = $fps; gpuBusyPct = $gpuBusyRatio; bottleneck = $bottle
  cpu = [ordered]@{ avg = (Avg $cpuA); max = (Mx $cpuA); coreAvg = (Avg $coreA); coreMax = (Mx $coreA); clockStart = $clkStart; clockEnd = $clkEnd }
  gpu = $gpu; mem = [ordered]@{ avg = (Avg $memA); max = (Mx $memA) }; ping = $ping
  tl = [ordered]@{ clk = [object[]]$clkA; fps = [object[]]$fpsTl; ftMax = [object[]]$ftMaxTl; cpu = [object[]]$cpuA; core = [object[]]$coreA; gpu = [object[]]$gpuUse; temp = [object[]]$nvT; mem = [object[]]$memA; gw = [object[]]@($tl | ForEach-Object { $_.gw }); ext = [object[]]@($tl | ForEach-Object { $_.ext }) }
  verdicts = [object[]]$verd
}

Say ''
Say '==============================================' Cyan
Say ('  게임: {0}' -f $result.app)
if ($fps) {
  Say ('  평균 {0}fps · 1% 최저 {1}fps · 0.1% 최저 {2}fps' -f $fps.avg, $fps.low1, $fps.low01) Green
  Say ('  프레임 시간 중간 {0}ms · 상위 1% {1}ms · 최대 {2}ms · 끊김 {3}회' -f $fps.p50ms, $fps.p99ms, $fps.maxms, $fps.stutters)
} else { Say ('  FPS: 측정 안 됨 {0}' -f $pmNote) Yellow }
if ($clkStart) { Say ('  CPU 실제 클럭: 처음 {0}MHz → 끝 {1}MHz' -f $clkStart, $clkEnd) }
Say ('  CPU 평균 {0}% (가장 바쁜 코어 평균 {1}%) · 그래픽 평균 {2}% · 메모리 최고 {3}%' -f $result.cpu.avg, $result.cpu.coreAvg, $gpu.utilAvg, $result.mem.max)
if ($gpu.tempMax) { Say ('  그래픽 온도 평균 {0}°C · 최고 {1}°C' -f $gpu.tempAvg, $gpu.tempMax) }
function PingLine($label, $o) {
  if (-not $o) { return }
  if ($null -eq $o.avg) { Say ('  {0} 핑: 응답 없음 (손실 {1}%)' -f $label, $o.loss) Yellow }
  else { Say ('  {0} 핑 평균 {1}ms · 최대 {2}ms · 손실 {3}%' -f $label, $o.avg, $o.max, $o.loss) }
}
PingLine '게이트웨이' $ping.gw
PingLine '외부(KT DNS)' $ping.ext
if ($gameSrv) { PingLine ('게임 서버({0})' -f $gameSrv) $ping.gs }
Say ('  병목: {0}' -f $bottle)
foreach ($v in $verd) { Say ('  - ' + $v) Yellow }

$json = $result | ConvertTo-Json -Depth 6 -Compress
$code = 'PCBANGG1:' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
$copied = $false
try { Set-Clipboard -Value $code -ErrorAction Stop; $copied = $true } catch { $code | clip.exe; $copied = ($LASTEXITCODE -eq 0) }
$tag = $(if ($null -ne $seatVal) { 'seat-' + $seatVal } else { $computer })
$tag = ([string]$tag) -replace '[\\/:*?"<>|\s]', '_'  # 파일 이름에 못 쓰는 글자(-Seat "A/3" 등) 정리
$fname = ('game-{0}-{1}.txt' -f $tag, $stamp.ToString('yyyyMMdd-HHmm'))
$desk = Join-Path ([Environment]::GetFolderPath('Desktop')) $fname
try { $code | Out-File -FilePath $desk -Encoding ascii -ErrorAction Stop; Say ('  결과 파일: {0}' -f $desk) } catch {}
if ($Share) {
  # 연결 안 되는 공유 폴더에서 오래 멈추지 않도록 별도 작업으로 10초까지만 기다림
  $job = Start-Job -ScriptBlock { param($sh, $fn, $cd) try { if (-not (Test-Path $sh)) { New-Item -ItemType Directory -Path $sh -Force | Out-Null }; $cd | Out-File -FilePath (Join-Path $sh $fn) -Encoding ascii -ErrorAction Stop; 'OK' } catch { 'ERR' } } -ArgumentList $Share, $fname, $code
  $done = Wait-Job $job -Timeout 10
  $res = $null; if ($done) { $res = Receive-Job $job }
  Remove-Job $job -Force -ErrorAction SilentlyContinue
  if ($res -eq 'OK') { Say ('  공유 폴더에도 저장: {0}' -f (Join-Path $Share $fname)) Green } else { Say '  공유 폴더 저장 실패(권한·경로·연결 확인)' Red }
}
if ($copied) { Say '  결과 코드를 클립보드에 복사했어요. 웹 앱 [실전 테스트] 탭에 붙여넣으세요.' Green }
Say '==============================================' Cyan
Say ''

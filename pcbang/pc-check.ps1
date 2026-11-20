# PC방 게임 점검 - 윈도우 점검 프로그램 (Windows PowerShell 5.1 이상)
# 이 PC의 부품 정보와 네트워크(게이트웨이/외부 핑, 게임사 서버 접속 시간)를 측정해
# 결과 코드(PCBANG1:...)를 클립보드에 복사합니다. 정보를 어디로도 전송하지 않습니다.
# 핑 대상에게 보내는 짧은 신호(ICMP, TCP 접속)만 나갑니다.
#
# 옵션 (pc-check.bat 뒤에 붙여도 됩니다):
#   -Seat 23                  좌석 번호 (없으면 컴퓨터 이름 끝의 숫자: PC-023 -> 23)
#   -Share \\SERVER\pcbang    결과를 이 폴더에도 seat-23.txt 로 저장 (사장님이 모든 좌석 결과를 모을 때)
#   이 파일 옆 pc-check.config 에 share=\\SERVER\pcbang 한 줄을 써 두어도 됩니다.

param(
  [string]$Seat = '',
  [string]$Share = ''
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
try { if ([Console]::OutputEncoding.CodePage -ne 949 -and [Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage -eq 949) { [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(949) } } catch {}
Remove-TypeData System.Array -ErrorAction SilentlyContinue

function Say($t, $c) { if ($c) { Write-Host $t -ForegroundColor $c } else { Write-Host $t } }
function Round1($v) { if ($null -eq $v) { return $null } return [math]::Round([double]$v, 1) }
# 레지스트리 값(바이트 배열 / 부호 있는 DWORD)을 바이트 수로
function RegBytes($v) {
  if ($null -eq $v) { return $null }
  if ($v -is [byte[]]) {
    if ($v.Length -ge 8) { return [double][BitConverter]::ToUInt64($v, 0) }
    if ($v.Length -ge 4) { return [double][BitConverter]::ToUInt32($v, 0) }
    return $null
  }
  $d = [double]$v; if ($d -lt 0) { $d += 4294967296 }
  return $d
}
# 문자열 -> 숫자 (실패하면 null). nvidia-smi 의 [N/A] 같은 값 처리
function NumOrNull($s) {
  $d = 0.0
  if ([double]::TryParse(([string]$s).Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
  return $null
}
# 레지스트리 값 하나 읽기 (없으면 null)
function RegVal($path, $name) {
  try { $p = Get-ItemProperty -LiteralPath $path -ErrorAction Stop; return $p.$name } catch { return $null }
}
# 외부 프로그램을 시간 제한을 두고 실행 (넘으면 강제 종료)
function RunExe($file, $argLine, $ms) {
  $p = $null
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $file
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    if ($p.WaitForExit($ms)) {
      if ($so.Wait(1000)) { return $so.Result }
      return $null
    }
    try { $p.Kill() } catch {}
    return $null
  } catch {
    if ($p) { try { $p.Kill() } catch {} }
    return $null
  }
}
# 이름 목록: 중복 제거, 이름 있는 장치가 있으면 일반(HID 규격 등) 이름은 뺌
function CleanList($names, $genericRx) {
  $seen = @{}
  $all = @()
  foreach ($n in $names) {
    if (-not $n) { continue }
    $n = ([string]$n -replace '\s+', ' ').Trim()
    if (-not $n) { continue }
    $k = $n.ToLower()
    if ($seen.ContainsKey($k)) { continue }
    $seen[$k] = 1
    $all += $n
  }
  if ($genericRx) {
    $named = @($all | Where-Object { $_ -notmatch $genericRx })
    if ($named.Count) { return ,([object[]]$named) }
  }
  return ,([object[]]$all)
}

$timedOutJobs = $false
# 스크립트 블록을 별도 실행 공간에서 시간 제한을 두고 실행 (네트워크 폴더가 응답 없을 때 멈추지 않게)
function InvokeTimed($code, $argList, $ms) {
  $ps = [powershell]::Create()
  [void]$ps.AddScript($code)
  foreach ($a in $argList) { [void]$ps.AddArgument($a) }
  $h = $ps.BeginInvoke()
  if ($h.AsyncWaitHandle.WaitOne($ms)) {
    $r = $null
    try { $r = @($ps.EndInvoke($h)) } catch {}
    try { $ps.Dispose() } catch {}
    if ($r -and $r.Count) { return $r[0] }
    return $null
  }
  try { [void]$ps.BeginStop($null, $null) } catch {}
  $script:timedOutJobs = $true
  return 'ERR:시간 초과(폴더가 응답하지 않음)'
}

$base = $PSScriptRoot; if (-not $base) { $base = [Environment]::GetFolderPath('Desktop') }

# ---------- 좌석 번호 / 공유 폴더 설정 ----------
$computer = $env:COMPUTERNAME
$seatVal = $null
try {
  if ($Seat -and $Seat.Trim()) {
    $s = $Seat.Trim()
    if ($s -match '^\d{1,9}$') { $seatVal = [int]$s } else { $seatVal = $s }
  } elseif ($computer -match '^(?:PC|SEAT|S|좌석)?[-_]?0*(\d{1,4})$' -or $computer -match '^[A-Za-z]{1,10}[-_]0*(\d{1,4})$') { $seatVal = [int]$matches[1] }
} catch {}
try {
  if (-not $Share -and $PSScriptRoot) {
    $cfgPath = Join-Path $PSScriptRoot 'pc-check.config'
    if (Test-Path -LiteralPath $cfgPath) {
      $bytes = [System.IO.File]::ReadAllBytes($cfgPath)
      $txt = $null
      try { $txt = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes) } catch { $txt = [System.Text.Encoding]::GetEncoding(949).GetString($bytes) }
      $txt = $txt.TrimStart([char]0xFEFF)
      foreach ($line in ($txt -split "`r?`n")) {
        if ($line -match '^\s*share\s*=\s*(.+?)\s*$') { $Share = $matches[1].Trim().Trim('"') }
      }
    }
  }
} catch {}

Say ''
Say '==============================================' Cyan
Say '  PC방 게임 점검 - 윈도우 점검 프로그램' Cyan
Say '==============================================' Cyan
Say '약 45초 걸립니다. 창을 닫지 마세요.'
if ($null -ne $seatVal) { Say ("좌석: {0}  (컴퓨터 이름: {1})" -f $seatVal, $computer) } else { Say ("컴퓨터 이름: {0}" -f $computer) }
Say ''

$result = [ordered]@{ v = 2; time = (Get-Date).ToString('yyyy-MM-dd HH:mm'); seat = $seatVal; computer = $computer }

# ---------- CPU ----------
Say '[1/9] CPU 확인' Yellow
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
if ($cpu) {
  $result.cpu = ($cpu.Name -replace '\s+', ' ').Trim()
  $result.cores = [int]$cpu.NumberOfCores
  $result.threads = [int]$cpu.NumberOfLogicalProcessors
  $result.cpuMHz = [int]$cpu.MaxClockSpeed
  $result.cpuLoad = [int]$cpu.LoadPercentage
  Say ("      {0} ({1}코어 {2}스레드)" -f $result.cpu, $result.cores, $result.threads)
}
# CPU를 많이 쓰는 프로그램 (2초 동안 측정, 이름만)
try {
  $snapA = @{}
  foreach ($p in @(Get-Process)) {
    try { if ($p.Id -ne $PID -and $p.Id -ne 0 -and $null -ne $p.CPU) { $snapA[$p.Id] = @([double]$p.CPU, $p.ProcessName) } } catch {}
  }
  $swP = [System.Diagnostics.Stopwatch]::StartNew()
  Start-Sleep -Milliseconds 2000
  $secs = $swP.Elapsed.TotalSeconds
  $byName = @{}
  foreach ($p in @(Get-Process)) {
    try {
      if ($snapA.ContainsKey($p.Id) -and $null -ne $p.CPU -and $snapA[$p.Id][1] -eq $p.ProcessName) {
        $d = [double]$p.CPU - $snapA[$p.Id][0]
        if ($d -gt 0) { if ($byName.ContainsKey($p.ProcessName)) { $byName[$p.ProcessName] += $d } else { $byName[$p.ProcessName] = $d } }
      }
    } catch {}
  }
  $lp = [Environment]::ProcessorCount; if (-not $lp) { $lp = 1 }
  $top = @($byName.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5 | ForEach-Object { [ordered]@{ name = [string]$_.Key; pct = (Round1 ($_.Value / $secs / $lp * 100)) } })
  $result.topProcs = [object[]]$top
  if ($top.Count) { Say ("      CPU 사용 상위: {0}" -f (($top | ForEach-Object { "{0} {1}%" -f $_.name, $_.pct }) -join ', ')) }
} catch {}

# 메인보드 모델(전원 제한 기본값이 보드 칩셋에 따라 다름)
try { $bb = Get-CimInstance Win32_BaseBoard -OperationTimeoutSec 5 | Select-Object -First 1; if ($bb) { $result.board = (('{0} {1}' -f $bb.Manufacturer, $bb.Product) -replace '\s+', ' ').Trim(); Say ('      메인보드: {0}' -f $result.board) } } catch {}

# ---------- 그래픽 ----------
Say '[2/9] 그래픽카드 확인' Yellow
$gpus = @()
$regBase = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
$regVram = @{}
Get-ChildItem $regBase | ForEach-Object {
  $p = Get-ItemProperty $_.PSPath
  $mem = RegBytes $p.'HardwareInformation.qwMemorySize'
  if (-not $mem) { $mem = RegBytes $p.'HardwareInformation.MemorySize' }
  if ($p.DriverDesc -and $mem) { $regVram[$p.DriverDesc] = [double]$mem }
}
$hz = $null
Get-CimInstance Win32_VideoController | ForEach-Object {
  $name = ($_.Name -replace '\s+', ' ').Trim()
  if ($name -match 'Microsoft Basic|Remote Display|Virtual|Parsec|Meta Virtual|Citrix') { $virtual = $true } else { $virtual = $false }
  $bytes = $null
  if ($regVram.ContainsKey($_.Name)) { $bytes = $regVram[$_.Name] } elseif ($_.AdapterRAM -and [double]$_.AdapterRAM -lt 4293918720) { $bytes = [double]$_.AdapterRAM }
  $vram = $null; if ($bytes) { $vram = [math]::Round($bytes / 1GB, 1) }
  $rr = [double]$_.CurrentRefreshRate
  if ($rr -gt 1 -and $rr -lt 1000 -and -not $hz -and -not $virtual) { $hz = [int]$rr }
  $dd = $null
  try { if ($_.DriverDate) { $dd = ([datetime]$_.DriverDate).ToString('yyyy-MM-dd') } } catch {}
  $gpus += [ordered]@{ name = $name; vram = $vram; driver = $_.DriverVersion; driverDate = $dd; virtual = $virtual; res = ("{0}x{1}" -f $_.CurrentHorizontalResolution, $_.CurrentVerticalResolution) }
  $vtxt = ''; if ($vram) { $vtxt = " {0}GB" -f $vram }
  $dtxt = ''; if ($dd) { $dtxt = ", {0}" -f $dd }
  Say ("      {0}{1} (드라이버 {2}{3})" -f $name, $vtxt, $_.DriverVersion, $dtxt)
}
$result.gpus = [object[]]$gpus

# NVIDIA 실시간 상태 (nvidia-smi, 5초 제한)
$gpuLive = $null
try {
  $cands = @()
  $gc = Get-Command 'nvidia-smi.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($gc -and $gc.Path) { $cands += $gc.Path }
  $cands += (Join-Path $env:windir 'System32\nvidia-smi.exe')
  $cands += (Join-Path $env:windir 'Sysnative\nvidia-smi.exe')
  if ($env:ProgramW6432) { $cands += (Join-Path $env:ProgramW6432 'NVIDIA Corporation\NVSMI\nvidia-smi.exe') }
  $cands += (Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe')
  $smi = $null
  foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { $smi = $c; break } }
  if ($smi) {
    $out = RunExe $smi '--query-gpu=name,temperature.gpu,utilization.gpu,clocks.sm,clocks.max.sm,power.draw,power.limit,pcie.link.gen.current,pcie.link.width.current,pcie.link.width.max,driver_version,fan.speed --format=csv,noheader,nounits' 5000
    if ($out) {
      $line = @(($out -split "`r?`n") | Where-Object { $_.Trim() })[0]
      $f = @(([string]$line -split ',') | ForEach-Object { $_.Trim() })
      if ($f.Count -ge 12) {
        $gpuLive = [ordered]@{
          name = $f[0]
          tempC = (NumOrNull $f[1])
          util = (NumOrNull $f[2])
          clockMHz = (NumOrNull $f[3])
          clockMaxMHz = (NumOrNull $f[4])
          powerW = (Round1 (NumOrNull $f[5]))
          powerLimitW = (Round1 (NumOrNull $f[6]))
          pcieGen = (NumOrNull $f[7])
          pcieWidth = (NumOrNull $f[8])
          pcieWidthMax = (NumOrNull $f[9])
          driver = $f[10]
          fanPct = (NumOrNull $f[11])
        }
        $result.gpuLive = $gpuLive
        $pcie = ''
        if ($gpuLive.pcieWidth) { $pcie = (", PCIe {0}.0 x{1} (최대 x{2}, 쉬는 중엔 낮아질 수 있음)" -f $gpuLive.pcieGen, $gpuLive.pcieWidth, $gpuLive.pcieWidthMax) }
        Say ("      NVIDIA 실시간: 온도 {0}도, 사용률 {1}%, 클럭 {2}/{3}MHz, 전력 {4}/{5}W{6}" -f $gpuLive.tempC, $gpuLive.util, $gpuLive.clockMHz, $gpuLive.clockMaxMHz, $gpuLive.powerW, $gpuLive.powerLimitW, $pcie)
      }
    }
  }
} catch {}

# ---------- 모니터 ----------
Say '[3/9] 모니터 확인' Yellow
$makerMap = @{ 'SAM' = 'Samsung'; 'SEC' = 'Samsung'; 'GSM' = 'LG'; 'LGD' = 'LG Display'; 'DEL' = 'Dell'; 'AUS' = 'ASUS'; 'ACI' = 'ASUS'; 'BNQ' = 'BenQ'; 'AOC' = 'AOC'; 'ACR' = 'Acer'; 'MSI' = 'MSI'; 'HWP' = 'HP'; 'HPN' = 'HP'; 'LEN' = 'Lenovo'; 'PHL' = 'Philips'; 'VSC' = 'ViewSonic'; 'GBT' = 'GIGABYTE'; 'XMI' = 'Xiaomi'; 'IVM' = 'iiyama'; 'EIZ' = 'EIZO'; 'ENC' = 'EIZO'; 'SNY' = 'Sony'; 'AUO' = 'AUO'; 'BOE' = 'BOE'; 'CMN' = 'Innolux'; 'SHP' = 'Sharp'; 'HKC' = 'HKC'; 'KOS' = 'KOS' }
function U16($a) {
  if (-not $a) { return '' }
  $s = -join (@($a) | Where-Object { $_ -ne 0 } | ForEach-Object { [char][int]$_ })
  return $s.Trim()
}
$mons = @()
try {
  foreach ($m in @(Get-CimInstance -Namespace 'root/wmi' -ClassName WmiMonitorID -OperationTimeoutSec 5 -ErrorAction Stop)) {
    $mk = U16 $m.ManufacturerName
    $fn = U16 $m.UserFriendlyName
    $pc = U16 $m.ProductCodeID
    $maker = $makerMap[$mk.ToUpper()]; if (-not $maker) { $maker = $mk }
    if ($fn) {
      $nm = $fn
      if ($maker -and $fn -notmatch [regex]::Escape(($maker -split ' ')[0])) { $nm = "$maker $fn" }
    } else { $nm = ("{0} {1}" -f $maker, $pc).Trim() }
    $key = (([string]$m.InstanceName) -replace '_\d+$', '') -replace '\\', '#'
    $mons += [pscustomobject]@{ key = $key.ToUpper() + '#'; name = $nm }
  }
} catch {}
$result.monitors = [object[]](CleanList @($mons | ForEach-Object { $_.name }) $null)

$dispSrc = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class PcbDisp {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
  }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra; public int dmFields;
    public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
    public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
    public int dmDisplayFlags; public int dmDisplayFrequency;
    public int dmICMMethod; public int dmICMIntent; public int dmMediaType; public int dmDitherType;
    public int dmReserved1; public int dmReserved2; public int dmPanningWidth; public int dmPanningHeight;
  }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
  public static string[] List() {
    List<string> res = new List<string>();
    for (uint i = 0; i < 16; i++) {
      DISPLAY_DEVICE a = new DISPLAY_DEVICE(); a.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
      if (!EnumDisplayDevices(null, i, ref a, 0)) break;
      if ((a.StateFlags & 1) == 0 || (a.StateFlags & 8) != 0) continue;
      DEVMODE cur = new DEVMODE(); cur.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
      if (!EnumDisplaySettings(a.DeviceName, -1, ref cur)) continue;
      int maxRes = 0, maxAny = 0;
      for (int m = 0; m < 5000; m++) {
        DEVMODE d = new DEVMODE(); d.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        if (!EnumDisplaySettings(a.DeviceName, m, ref d)) break;
        int f = d.dmDisplayFrequency;
        if (f <= 1 || f > 1000) continue;
        if (f > maxAny) maxAny = f;
        if (d.dmPelsWidth == cur.dmPelsWidth && d.dmPelsHeight == cur.dmPelsHeight && f > maxRes) maxRes = f;
      }
      string monId = "", monName = "";
      DISPLAY_DEVICE mo = new DISPLAY_DEVICE(); mo.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
      if (EnumDisplayDevices(a.DeviceName, 0, ref mo, 1)) { monId = mo.DeviceID ?? ""; monName = mo.DeviceString ?? ""; }
      res.Add(string.Join("|", new string[] { a.DeviceName ?? "", (a.DeviceString ?? "").Replace("|", " "),
        cur.dmPelsWidth.ToString(), cur.dmPelsHeight.ToString(), cur.dmDisplayFrequency.ToString(),
        maxRes.ToString(), maxAny.ToString(), ((a.StateFlags & 4) != 0) ? "1" : "0", monId.Replace("|", " "), monName.Replace("|", " ") }));
    }
    return res.ToArray();
  }
}
'@
$displays = @()
try {
  if (-not ('PcbDisp' -as [type])) { Add-Type -TypeDefinition $dispSrc -ErrorAction Stop }
  foreach ($ln in [PcbDisp]::List()) {
    $f = ([string]$ln) -split '\|'
    if ($f.Count -lt 10) { continue }
    $cur = [int]$f[4]; $mx = [int]$f[5]; if ($mx -le 0) { $mx = [int]$f[6] }
    $nm = $null
    $mid = $f[8].ToUpper()
    foreach ($mo in $mons) { if ($mo.key -and $mid.Contains($mo.key)) { $nm = $mo.name; break } }
    if (-not $nm -and $f[9] -and $f[9] -notmatch 'Generic|PnP|일반') { $nm = $f[9] }
    $o = [ordered]@{ name = $nm; res = ("{0}x{1}" -f $f[2], $f[3]); hz = $cur; maxHz = $null; primary = ($f[7] -eq '1') }
    if ($mx -gt 0) { $o.maxHz = $mx }
    $displays += $o
  }
} catch {}
$result.displays = [object[]]$displays
$prim = $null
foreach ($d in $displays) { if ($d.primary) { $prim = $d; break } }
if (-not $prim -and $displays.Count) { $prim = $displays[0] }
if ($prim -and $prim.hz -gt 1) { $hz = [int]$prim.hz }
if ($prim -and $prim.maxHz) { $result.monitorMaxHz = [int]$prim.maxHz }
if (-not $result.Contains('monitorMaxHz') -and $displays.Count -le 1) {
  # 대체 방법 (관리자 권한이 필요할 수 있음: 안 되면 건너뜀)
  try {
    $best = 0
    foreach ($sm in @(Get-CimInstance -Namespace 'root/wmi' -ClassName WmiMonitorListedSupportedSourceModes -OperationTimeoutSec 5 -ErrorAction Stop)) {
      foreach ($md in @($sm.MonitorSourceModes)) {
        $den = [double]$md.VerticalRefreshRateDenominator
        if ($den -gt 0) { $r = [math]::Round([double]$md.VerticalRefreshRateNumerator / $den); if ($r -gt $best -and $r -lt 1000) { $best = $r } }
      }
    }
    if ($best -gt 0) { $result.monitorMaxHz = [int]$best }
  } catch {}
}
if ($hz) { $result.hz = $hz }
foreach ($d in $displays) {
  $nmTxt = $d.name; if (-not $nmTxt) { $nmTxt = '모니터' }
  $mxTxt = ''; if ($d.maxHz) { $mxTxt = (" (최대 {0}Hz)" -f $d.maxHz) }
  Say ("      {0}: {1} {2}Hz{3}" -f $nmTxt, $d.res, $d.hz, $mxTxt)
}
if (-not $displays.Count) {
  if ($result.monitors.Count) { Say ("      {0}" -f ($result.monitors -join ', ')) }
  if ($hz) { Say ("      모니터 주사율: {0}Hz" -f $hz) }
}

# ---------- 메모리·운영체제·디스크 ----------
Say '[4/9] 메모리·운영체제·저장 장치 확인' Yellow
$sticks = @(Get-CimInstance Win32_PhysicalMemory)
$total = ($sticks | Measure-Object -Property Capacity -Sum).Sum
if (-not $total) { $total = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory }
$result.ramGB = [math]::Round($total / 1GB)
$result.ramSticks = $sticks.Count
$spd = ($sticks | ForEach-Object { if ($_.ConfiguredClockSpeed) { $_.ConfiguredClockSpeed } else { $_.Speed } } | Measure-Object -Minimum).Minimum
if ($spd) { $result.ramSpeed = [int]$spd }
# XMP(메모리 오버클럭 설정) 꺼짐 추정: 실제 동작 속도 < 메모리 정격 속도(Speed / 제품 번호)
try {
  $rated = 0
  foreach ($st in $sticks) {
    $sp = [int]$st.Speed; if ($sp -gt $rated) { $rated = $sp }
    $pn = ([string]$st.PartNumber).Trim()
    $pr = 0
    if ($pn -match '^F[345]-(\d{4})') { $pr = [int]$matches[1] }
    elseif ($pn -match 'M\d[A-Z](\d{4})C\d') { $pr = [int]$matches[1] }
    elseif ($pn -match '^KF[345](\d{2})C') { $pr = [int]$matches[1] * 100 }
    elseif ($pn -match '^KHX(\d{4})C') { $pr = [int]$matches[1] }
    if ($pr -ge 1600 -and $pr -le 10000 -and $pr -gt $rated) { $rated = $pr }
  }
  if ($rated -gt 0) { $result.ramRated = $rated }
  if ($result.ramSpeed -and $rated -gt 0) {
    $cfgSp = [int]$result.ramSpeed
    # 일부 PC는 동작 속도를 절반(MHz)으로 보고함
    if ($cfgSp -lt 1400 -and ($cfgSp * 2) -ge ($rated * 0.97)) { $cfgSp = $cfgSp * 2 }
    $result.ramXmpOff = ($cfgSp -lt ($rated * 0.97))
  }
} catch {}
$spdTxt = ''; if ($result.ramSpeed) { $spdTxt = (", {0}MT/s" -f $result.ramSpeed) }
if ($result.ramRated -and $result.ramRated -ne $result.ramSpeed) { $spdTxt += (" / 정격 {0}" -f $result.ramRated) }
Say ("      RAM {0}GB ({1}개{2})" -f $result.ramGB, $result.ramSticks, $spdTxt)

$os = Get-CimInstance Win32_OperatingSystem
$build = [int]$os.BuildNumber
$result.osBuild = $build
$result.osName = ("{0} ({1}, 빌드 {2})" -f $os.Caption, $os.OSArchitecture, $build)
if ($os.OSArchitecture -notmatch '64') { $result.os = 'win10-32' }
elseif ($build -ge 22000) { $result.os = 'win11' }
elseif ($build -ge 10240) { $result.os = 'win10' }
else { $result.os = 'win7' }
try { $up = (Get-Date) - $os.LastBootUpTime; $result.uptimeH = [math]::Round($up.TotalHours, 1) } catch {}
try {
  $tv = [double]$os.TotalVisibleMemorySize; $fv = [double]$os.FreePhysicalMemory
  if ($tv -gt 0) { $result.memUsedPct = [int][math]::Round(($tv - $fv) / $tv * 100) }
} catch {}
$upTxt = ''; if ($null -ne $result.uptimeH) { $upTxt = (", 켜진 지 {0}시간" -f $result.uptimeH) }
$memTxt = ''; if ($null -ne $result.memUsedPct) { $memTxt = (", 메모리 사용 {0}%" -f $result.memUsedPct) }
Say ("      {0}{1}{2}" -f $result.osName, $upTxt, $memTxt)

$disks = @()
Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
  $disks += [ordered]@{ name = $_.DeviceID; size = [math]::Round($_.Size / 1GB); free = [math]::Round($_.FreeSpace / 1GB) }
}
$result.disks = [object[]]$disks
try {
  $sysDrv = $env:SystemDrive; if (-not $sysDrv) { $sysDrv = 'C:' }
  $sysLd = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $sysDrv) | Select-Object -First 1
  if ($sysLd -and [double]$sysLd.Size -gt 0) {
    $result.sysFreePct = [int][math]::Round([double]$sysLd.FreeSpace / [double]$sysLd.Size * 100)
    $result.lowDisk = ($result.sysFreePct -lt 15)
  }
} catch {}

# 물리 디스크 (SSD/HDD, 상태, 연결 방식)
$physDisks = @()
$pdOk = $false
$mediaMap = @{ 0 = 'Unspecified'; 3 = 'HDD'; 4 = 'SSD'; 5 = 'SCM' }
$busMap = @{ 1 = 'SCSI'; 2 = 'ATAPI'; 3 = 'ATA'; 4 = '1394'; 5 = 'SSA'; 6 = 'Fibre Channel'; 7 = 'USB'; 8 = 'RAID'; 9 = 'iSCSI'; 10 = 'SAS'; 11 = 'SATA'; 12 = 'SD'; 13 = 'MMC'; 15 = 'File Backed Virtual'; 16 = 'Storage Spaces'; 17 = 'NVMe'; 18 = 'SCM'; 19 = 'UFS' }
$healthMap = @{ 0 = 'Healthy'; 1 = 'Warning'; 2 = 'Unhealthy'; 5 = 'Unknown' }
$opMap = @{ 0 = 'Unknown'; 1 = 'Other'; 2 = 'OK'; 3 = 'Degraded'; 4 = 'Stressed'; 5 = 'Predictive Failure'; 6 = 'Error'; 7 = 'Non-Recoverable Error'; 8 = 'Starting'; 9 = 'Stopping'; 10 = 'Stopped'; 11 = 'In Service'; 12 = 'No Contact'; 13 = 'Lost Communication'; 14 = 'Aborted'; 15 = 'Dormant'; 16 = 'Supporting Entity in Error'; 17 = 'Completed'; 18 = 'Power Mode' }
function MapOr($map, $v) { if ($null -eq $v) { return $null }; $k = [int]$v; if ($map.ContainsKey($k)) { return $map[$k] }; return [string]$k }
try {
  foreach ($pd in @(Get-CimInstance -Namespace 'root/Microsoft/Windows/Storage' -ClassName MSFT_PhysicalDisk -OperationTimeoutSec 5 -ErrorAction Stop)) {
    $ops = @(@($pd.OperationalStatus) | ForEach-Object { MapOr $opMap $_ }) -join ', '
    $physDisks += [ordered]@{ name = ([string]$pd.FriendlyName).Trim(); media = (MapOr $mediaMap $pd.MediaType); bus = (MapOr $busMap $pd.BusType); health = (MapOr $healthMap $pd.HealthStatus); status = $ops; sizeGB = [math]::Round([double]$pd.Size / 1GB) }
  }
  if ($physDisks.Count) { $pdOk = $true } else { throw 'no MSFT_PhysicalDisk rows' }
} catch {
  try {
    foreach ($dd in @(Get-CimInstance Win32_DiskDrive -OperationTimeoutSec 5 -ErrorAction Stop)) {
      $physDisks += [ordered]@{ name = ([string]$dd.Model).Trim(); media = $null; bus = [string]$dd.InterfaceType; health = [string]$dd.Status; status = [string]$dd.Status; sizeGB = [math]::Round([double]$dd.Size / 1GB) }
    }
    $pdOk = $true
  } catch {}
}
$result.physDisks = [object[]]$physDisks
$mt = @($physDisks | ForEach-Object { $_.media } | Where-Object { $_ } | Sort-Object -Unique)
if ($mt.Count) { $result.diskTypes = ($mt -join ', ') }
foreach ($pd in $physDisks) {
  $col = $null; if ($pd.health -and $pd.health -notmatch '^(Healthy|OK)$') { $col = 'Red' }
  Say ("      {0} ({1}, {2}, {3}GB) 상태: {4}" -f $pd.name, $pd.media, $pd.bus, $pd.sizeGB, $pd.health) $col
}
foreach ($dk in $disks) { Say ("      드라이브 {0} {1}GB 중 {2}GB 남음" -f $dk.name, $dk.size, $dk.free) }
# 디스크리스(네트워크 부팅) 추정
try {
  $why = @()
  if (@($physDisks | Where-Object { $_.bus -eq 'iSCSI' }).Count) { $why += 'iSCSI 디스크' }
  if (@($physDisks | Where-Object { $_.name -match 'CCBoot|iCafe|Diskless|NxD|iSCSI' }).Count) { $why += '원격 디스크 이름' }
  $sysAny = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $sysDrv) | Select-Object -First 1
  if ($sysAny -and [int]$sysAny.DriveType -eq 4) { $why += '시스템 드라이브가 네트워크 드라이브' }
  if ($pdOk -and $physDisks.Count -eq 0 -and $why.Count) { $why += '로컬 디스크 없음' }
  $result.diskless = ($why.Count -gt 0)
  if ($why.Count) { $result.disklessWhy = ($why -join ', '); Say ("      디스크리스(네트워크 부팅) 추정: {0}" -f $result.disklessWhy) }
} catch {}

# ---------- 설정·보안 ----------
Say '[5/9] 윈도우 설정·보안 확인' Yellow
# 전원 관리 옵션 (GUID로 판별: 언어와 무관)
$scheme = (powercfg /getactivescheme) | Out-String
$plans = @{ '381b4222-f694-41f0-9685-ff5bb260df2e' = '균형 조정'; '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' = '고성능'; 'a1841308-3540-4fe4-a8b5-15b6ce5e2b1c' = '절전'; 'e9a42b02-d5df-448d-aa00-03f14749eb61' = '최고의 성능' }
if ($scheme -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
  $g = $matches[1].ToLower()
  if ($plans.ContainsKey($g)) { $result.power = $plans[$g] } elseif ($scheme -match '\((.+)\)') { $result.power = $matches[1].Trim() } else { $result.power = '사용자 지정' }
  Say ("      전원 관리: {0}" -f $result.power)
}

# 보안 부팅·TPM (발로란트·롤 뱅가드 관련, 관리자 권한이 없으면 확인 불가)
$sbv = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction SilentlyContinue).UEFISecureBootEnabled
if ($sbv -eq 1) { $result.secureBoot = '켜짐' } elseif ($sbv -eq 0) { $result.secureBoot = '꺼짐' } else {
  try { if (Confirm-SecureBootUEFI -ErrorAction Stop) { $result.secureBoot = '켜짐' } else { $result.secureBoot = '꺼짐' } }
  catch [System.PlatformNotSupportedException] { $result.secureBoot = '꺼짐(레거시 BIOS/CSM)' }
  catch { $result.secureBoot = '확인 불가' }
}
try {
  $tpm = Get-CimInstance -Namespace 'root/cimv2/Security/MicrosoftTpm' -ClassName Win32_Tpm -OperationTimeoutSec 5 -ErrorAction Stop
  if ($tpm) { $result.tpm = ("있음 ({0})" -f ($tpm.SpecVersion -split ',')[0]) } else { $result.tpm = '없음' }
} catch {
  $pe = Get-CimInstance Win32_PnPEntity -Filter "Service='TPM'" | Select-Object -First 1
  if ($pe) { $tv = '?'; if ($pe.Name -match '(\d\.\d)') { $tv = $matches[1] }; $result.tpm = "있음 ($tv)" } else { $result.tpm = '없음(또는 BIOS에서 꺼짐)' }
}
Say ("      보안 부팅: {0} / TPM: {1}" -f $result.secureBoot, $result.tpm)

# 메모리 무결성(HVCI)
try {
  $hv = $null
  try {
    $dg = Get-CimInstance -Namespace 'root/Microsoft/Windows/DeviceGuard' -ClassName Win32_DeviceGuard -OperationTimeoutSec 3 -ErrorAction Stop | Select-Object -First 1
    if ($dg -and (@($dg.SecurityServicesRunning) -contains 2)) { $hv = '켜짐' }
  } catch {}
  if (-not $hv) {
    $hve = RegVal 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled'
    if ($hve -eq 1) { $hv = '켜짐(설정됨)' } else { $hv = '꺼짐' }
  }
  $result.hvci = $hv
} catch {}
# 뱅가드(라이엇 안티치트)
try {
  $svcKo = @{ 'Running' = '실행 중'; 'Stopped' = '중지됨'; 'Paused' = '일시 중지'; 'StartPending' = '시작 중'; 'StopPending' = '중지 중' }
  $stKo = @{ 'Automatic' = '자동'; 'Manual' = '수동'; 'Disabled' = '사용 안 함'; 'Boot' = '부팅'; 'System' = '시스템' }
  $vs = Get-Service -Name 'vgc' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($vs) {
    $a1 = $svcKo[[string]$vs.Status]; if (-not $a1) { $a1 = [string]$vs.Status }
    $a2 = $stKo[[string]$vs.StartType]; if (-not $a2) { $a2 = [string]$vs.StartType }
    $result.vgc = ("{0} ({1})" -f $a1, $a2)
  } else { $result.vgc = '설치 안 됨' }
  if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\vgk') { $result.vgk = '설치됨' } else { $result.vgk = '설치 안 됨' }
  # 윈도우 업데이트 서비스
  $wu = Get-Service -Name 'wuauserv' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($wu) {
    $b1 = $svcKo[[string]$wu.Status]; if (-not $b1) { $b1 = [string]$wu.Status }
    $b2 = $stKo[[string]$wu.StartType]; if (-not $b2) { $b2 = [string]$wu.StartType }
    $result.wuService = ("{0} ({1})" -f $b1, $b2)
  }
} catch {}
Say ("      메모리 무결성: {0} / 뱅가드: {1} / 윈도우 업데이트: {2}" -f $result.hvci, $result.vgc, $result.wuService)
# 재부팅 대기
try {
  $result.rebootPending = ((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'))
} catch {}
# 게임 모드 / 하드웨어 가속 GPU 예약(HAGS)
try {
  $gm = RegVal 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
  if ($null -eq $gm) { $gm = RegVal 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' }
  if ($null -eq $gm) { $result.gameMode = '켜짐(기본값)' } elseif ([int]$gm -eq 0) { $result.gameMode = '꺼짐' } else { $result.gameMode = '켜짐' }
  $hs = RegVal 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
  if ($null -eq $hs) { $result.hags = '설정 없음(기본값)' } elseif ([int]$hs -eq 2) { $result.hags = '켜짐' } else { $result.hags = '꺼짐' }
} catch {}
# 마우스 가속(향상된 포인터 정밀도)
try {
  $ms = RegVal 'HKCU:\Control Panel\Mouse' 'MouseSpeed'
  if ($null -ne $ms) { $result.mouseAccel = ([string]$ms).Trim() -ne '0' }
  $sens = RegVal 'HKCU:\Control Panel\Mouse' 'MouseSensitivity'
  if ($null -ne $sens) { $result.mouseSens = [int]([string]$sens).Trim() }
} catch {}
$maTxt = '꺼짐'; if ($result.mouseAccel) { $maTxt = '향상된 포인터 정밀도 켜짐' }
Say ("      게임 모드: {0} / HAGS: {1} / 마우스 가속: {2} / 재부팅 대기: {3}" -f $result.gameMode, $result.hags, $maTxt, $(if ($result.rebootPending) { '있음' } else { '없음' }))

# ---------- 입력 장치·오디오 ----------
Say '[6/9] 마우스·키보드·오디오 확인' Yellow
$vidMap = @{ '046D' = 'Logitech'; '1532' = 'Razer'; '1038' = 'SteelSeries'; '1B1C' = 'Corsair'; '0951' = 'HyperX'; '03F0' = 'HP'; '0B05' = 'ASUS'; '045E' = 'Microsoft'; '05AC' = 'Apple'; '3434' = 'Keychron'; '1E7D' = 'ROCCAT'; '2516' = 'Cooler Master'; '1AF3' = 'ZOWIE' }
$pnpOk = [bool](Get-Command Get-PnpDeviceProperty -ErrorAction SilentlyContinue)
if ($pnpOk) { Import-Module PnpDevice -ErrorAction SilentlyContinue }
$pnpSw = [System.Diagnostics.Stopwatch]::StartNew()
function DevLabel($pnpId, $fallback) {
  $label = ''
  if ($pnpId -and $pnpOk -and $pnpSw.ElapsedMilliseconds -lt 5000) {
    try {
      $v = (Get-PnpDeviceProperty -InstanceId $pnpId -KeyName 'DEVPKEY_Device_BusReportedDeviceDesc' -ErrorAction Stop).Data
      if ($v) { $label = [string]$v }
      if (-not $label) {
        $par = (Get-PnpDeviceProperty -InstanceId $pnpId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop).Data
        if ($par) { $v2 = (Get-PnpDeviceProperty -InstanceId $par -KeyName 'DEVPKEY_Device_BusReportedDeviceDesc' -ErrorAction Stop).Data; if ($v2) { $label = [string]$v2 } }
      }
    } catch {}
  }
  if (-not $label) { $label = [string]$fallback }
  $label = ($label -replace '\s+', ' ').Trim()
  if ($label -and $pnpId -match 'VID_([0-9A-Fa-f]{4})') {
    $vn = $vidMap[$matches[1].ToUpper()]
    if ($vn -and $label -notmatch [regex]::Escape($vn)) { $label = "$vn $label" }
  }
  return $label
}
$genRx = 'HID|PS/2|표준|규격|USB 입력|USB Input|Terminal Server|터미널 서버|Remote Desktop|원격 데스크톱|Keyboard Device|Mouse Device|키보드 장치|마우스 장치'
try {
  $mn = @(Get-CimInstance Win32_PointingDevice -OperationTimeoutSec 5 | ForEach-Object { DevLabel $_.PNPDeviceID $_.Name })
  $result.mice = [object[]](CleanList $mn $genRx)
} catch {}
try {
  $kn = @(Get-CimInstance Win32_Keyboard -OperationTimeoutSec 5 | ForEach-Object { DevLabel $_.PNPDeviceID $_.Name })
  $result.keyboards = [object[]](CleanList $kn $genRx)
} catch {}
try {
  $an = @(Get-CimInstance Win32_SoundDevice -OperationTimeoutSec 5 | ForEach-Object { $_.Name })
  $result.audio = [object[]](CleanList $an $null)
} catch {}
if ($result.mice) { Say ("      마우스: {0}" -f ($result.mice -join ', ')) }
if ($result.keyboards) { Say ("      키보드: {0}" -f ($result.keyboards -join ', ')) }
if ($result.audio) { Say ("      오디오: {0}" -f ($result.audio -join ', ')) }

# ---------- 네트워크 어댑터·게이트웨이 ----------
Say '[7/9] 네트워크 연결 확인' Yellow
# 기본 경로(메트릭이 가장 낮은 것) = 실제 인터넷으로 나가는 어댑터. VPN·가상 어댑터를 피함
$rt = $null
try { $rt = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object { $_.RouteMetric + [int](Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric } | Select-Object -First 1 } catch {}
$cfg = $null
if ($rt) { $cfg = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter ("InterfaceIndex={0}" -f $rt.ifIndex) }
if (-not $cfg) { $cfg = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=TRUE' | Where-Object { $_.DefaultIPGateway } | Select-Object -First 1 }
$gateway = $null
if ($rt -and $rt.NextHop -match '^\d+\.\d+\.\d+\.\d+$' -and $rt.NextHop -ne '0.0.0.0') { $gateway = $rt.NextHop }
if ($cfg) {
  if (-not $gateway) { $gateway = @($cfg.DefaultIPGateway | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })[0] }
  $ad = Get-CimInstance Win32_NetworkAdapter -Filter ("Index={0}" -f $cfg.Index)
  $speed = ''
  if ($ad.Speed) { $speed = (" {0}Mbps" -f [math]::Round([double]$ad.Speed / 1e6)) }
  $kind = '유선'
  if ($ad.Name -match 'Wi-?Fi|Wireless|WLAN|802\.11') { $kind = '무선(와이파이)' }
  $result.adapter = ("{0} · {1}{2}" -f $kind, $ad.Name, $speed)
  Say ("      {0}" -f $result.adapter)
  Say ("      게이트웨이: {0}" -f $gateway)
}

# ---------- 핑 (ICMP) ----------
Say '[8/9] 핑 측정 (대상마다 20회)' Yellow
$targets = @()
if ($gateway) { $targets += ,@('게이트웨이(공유기/스위치)', $gateway, $true) }
$targets += ,@('KT DNS', '168.126.63.1', $false)
$targets += ,@('SK브로드밴드 DNS', '210.220.163.82', $false)
$targets += ,@('LG U+ DNS', '164.124.101.2', $false)
$targets += ,@('구글 DNS', '8.8.8.8', $false)
$targets += ,@('클라우드플레어 DNS', '1.1.1.1', $false)

$pinger = New-Object System.Net.NetworkInformation.Ping
$pings = @()
foreach ($t in $targets) {
  $rtts = New-Object System.Collections.ArrayList
  # 처음 5번 모두 응답이 없으면 그만(막힌 대상 때문에 오래 멈추지 않게)
  for ($i = 0; $i -lt 20; $i++) {
    try { $r = $pinger.Send($t[1], 1000); if ($r.Status -eq 'Success') { [void]$rtts.Add([double]$r.RoundtripTime) } } catch {}
    if ($i -eq 4 -and $rtts.Count -eq 0) { $i++; break }
    Start-Sleep -Milliseconds 50
  }
  $sent = $i
  $recv = $rtts.Count
  $o = [ordered]@{ name = $t[0]; host = $t[1]; isGateway = $t[2]; sent = $sent; recv = $recv; loss = [math]::Round((($sent - $recv) / $sent) * 100) }
  if ($recv -gt 0) {
    $o.avg = Round1 (($rtts | Measure-Object -Average).Average)
    $o.min = [double]($rtts | Measure-Object -Minimum).Minimum
    $o.max = [double]($rtts | Measure-Object -Maximum).Maximum
    $j = 0; for ($k = 1; $k -lt $recv; $k++) { $j += [math]::Abs($rtts[$k] - $rtts[$k - 1]) }
    if ($recv -gt 1) { $o.jitter = Round1 ($j / ($recv - 1)) } else { $o.jitter = 0 }
    $col = 'Green'; if ($o.loss -gt 0 -or ($t[2] -and $o.avg -gt 3) -or $o.avg -gt 60) { $col = 'Red' }
    Say ("      {0,-22} 평균 {1,5}ms  최소 {2,4}  최대 {3,4}  지터 {4,4}ms  손실 {5}%" -f $t[0], $o.avg, $o.min, $o.max, $o.jitter, $o.loss) $col
  } else {
    Say ("      {0,-22} 응답 없음 (손실 100%)" -f $t[0]) Red
  }
  $pings += $o
}
$result.pings = [object[]]$pings

# ---------- 게임사 서버 접속 시간 (TCP 443) ----------
Say '[9/9] 게임사 웹 서버 접속 시간 (TCP, 게임 매치 서버가 아니라 가까운 웹/CDN 서버)' Yellow
$hosts = @(
  @('라이엇 (롤·발로란트)', 'www.leagueoflegends.com'),
  @('크래프톤 (배그)', 'pubg.com'),
  @('넥슨 (FC·서든·메이플)', 'www.nexon.com'),
  @('블리자드 (오버워치)', 'kr.battle.net'),
  @('스토브 (로스트아크)', 'lostark.game.onstove.com'),
  @('로블록스', 'www.roblox.com'),
  @('엔씨소프트 (리니지)', 'www.plaync.com')
)
$tcp = @()
foreach ($h in $hosts) {
  $o = [ordered]@{ name = $h[0]; host = $h[1]; port = 443; n = 5; fail = 0; ok = $false }
  $ip = $null
  try { $dt = [System.Net.Dns]::GetHostAddressesAsync($h[1]); if ($dt.Wait(3000)) { $ip = $dt.Result | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1 } } catch {}
  $times = New-Object System.Collections.ArrayList
  if ($ip) {
    # 첫 번째 시도는 준비 시간(소켓 초기화)이 섞여 버림
    for ($i = 0; $i -lt 6; $i++) {
      $c = New-Object System.Net.Sockets.TcpClient
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      try {
        $task = $c.ConnectAsync($ip, 443)
        $okc = $task.Wait(1500) -and $c.Connected; $sw.Stop()
        if ($i -gt 0) { if ($okc) { [void]$times.Add($sw.Elapsed.TotalMilliseconds) } else { $o.fail++ } }
      } catch { if ($i -gt 0) { $o.fail++ } } finally { $c.Close() }
      # 처음 3번 모두 실패하면 그 서버는 막힌 것으로 보고 넘어감(오래 멈추지 않게)
      if ($i -ge 2 -and $times.Count -eq 0) { $o.fail = 5; break }
      Start-Sleep -Milliseconds 80
    }
  } else { $o.fail = 5 }
  if ($times.Count) {
    $o.ok = $true
    $o.avg = Round1 (($times | Measure-Object -Average).Average)
    $o.min = Round1 (($times | Measure-Object -Minimum).Minimum)
    Say ("      {0,-24} 평균 {1,5}ms  최소 {2,5}ms" -f $h[0], $o.avg, $o.min)
  } else { Say ("      {0,-24} 접속 실패" -f $h[0]) Red }
  $tcp += $o
}
$result.tcp = [object[]]$tcp

# ---------- 요약 ----------
$warns = New-Object System.Collections.ArrayList
$oks = New-Object System.Collections.ArrayList
try {
  # 모니터 주사율
  $hzChecked = $false
  foreach ($d in $displays) {
    $nmTxt = $d.name; if (-not $nmTxt) { $nmTxt = '모니터' }
    if ($d.maxHz -and $d.maxHz -ge 100 -and $d.hz -gt 1 -and $d.hz -lt ($d.maxHz - 5)) {
      [void]$warns.Add(("{0}: {1}Hz로 설정됨 (최대 {2}Hz 가능) - 디스플레이 설정 > 고급 디스플레이에서 변경" -f $nmTxt, $d.hz, $d.maxHz)); $hzChecked = $true
    } elseif ($d.hz -gt 1) {
      [void]$oks.Add(("{0}: {1}Hz" -f $nmTxt, $d.hz)); $hzChecked = $true
    }
  }
  if (-not $hzChecked -and $result.hz) {
    if ($result.monitorMaxHz -and $result.monitorMaxHz -ge 100 -and $result.hz -lt ($result.monitorMaxHz - 5)) { [void]$warns.Add(("모니터 {0}Hz로 설정됨 (최대 {1}Hz 가능)" -f $result.hz, $result.monitorMaxHz)) }
    else { [void]$oks.Add(("모니터 {0}Hz" -f $result.hz)) }
  }
  # 전원 관리
  if ($result.power) {
    if ($result.power -eq '고성능' -or $result.power -eq '최고의 성능') { [void]$oks.Add(("전원 관리: {0}" -f $result.power)) }
    else { [void]$warns.Add(("전원 관리가 [{0}] - 고성능으로 바꾸면 좋아요" -f $result.power)) }
  }
  # XMP
  if ($result.ramXmpOff -eq $true) { [void]$warns.Add(("메모리가 정격보다 느리게 동작 ({0} / 정격 {1}MT/s) - BIOS에서 XMP/EXPO 켜기 확인" -f $result.ramSpeed, $result.ramRated)) }
  elseif ($result.ramXmpOff -eq $false) { [void]$oks.Add(("메모리 속도 정상 ({0}MT/s)" -f $result.ramSpeed)) }
  # 재부팅 대기
  if ($result.rebootPending) { [void]$warns.Add('윈도우 업데이트 후 재부팅 대기 중') }
  # 디스크 여유 공간
  if ($result.lowDisk) { [void]$warns.Add(("{0} 드라이브 여유 공간 {1}% (15% 미만)" -f $sysDrv, $result.sysFreePct)) }
  elseif ($null -ne $result.sysFreePct) { [void]$oks.Add(("{0} 드라이브 여유 공간 {1}%" -f $sysDrv, $result.sysFreePct)) }
  foreach ($pd in $physDisks) { if ($pd.health -and $pd.health -notmatch '^(Healthy|OK|Unknown)$') { [void]$warns.Add(("디스크 상태 이상: {0} ({1})" -f $pd.name, $pd.health)) } }
  # 그래픽 드라이버 날짜 (주 그래픽카드)
  $mainGpu = $null
  foreach ($gp in $gpus) { if (-not $gp.virtual -and $gp.name -match 'NVIDIA|GeForce|Radeon|AMD|Arc') { $mainGpu = $gp; break } }
  if (-not $mainGpu) { foreach ($gp in $gpus) { if (-not $gp.virtual) { $mainGpu = $gp; break } } }
  if ($mainGpu -and $mainGpu.driverDate) {
    $ddt = [datetime]::ParseExact($mainGpu.driverDate, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    if ($ddt -lt (Get-Date).AddDays(-365)) { [void]$warns.Add(("그래픽 드라이버가 오래됨 ({0}) - 최신 드라이버 설치 권장" -f $mainGpu.driverDate)) }
    else { [void]$oks.Add(("그래픽 드라이버 날짜 {0}" -f $mainGpu.driverDate)) }
  }
  # GPU 온도
  if ($gpuLive -and $null -ne $gpuLive.tempC) {
    if ($gpuLive.tempC -gt 85) { [void]$warns.Add(("그래픽카드 온도 {0}도 (85도 초과) - 먼지·팬 점검" -f $gpuLive.tempC)) }
    else { [void]$oks.Add(("그래픽카드 온도 {0}도" -f $gpuLive.tempC)) }
  }
  # 마우스 가속
  # K 없는 인텔 12~14세대 + B·H 칩셋 보드: 장기 전력(PL1)이 65W로 묶이는 경우가 많음(사용자 PC에서 확인된 원인)
  if ($result.cpu -match 'i[579]-1[234]\d{3}F?\b' -and $result.cpu -notmatch 'i[579]-1[234]\d{3}KF?\b' -and $result.board -match '\b[BH][67]\d0') { [void]$warns.Add('K 없는 인텔 CPU + B/H 보드: 장기 전력 제한(PL1)이 65W로 묶였을 수 있어요 - HWiNFO로 PL1 확인, 65W면 BIOS에서 95~150W로') }
  if ($result.mouseAccel -eq $true) { [void]$warns.Add('마우스: 향상된 포인터 정밀도 켜짐 (FPS 게임은 끄는 게 좋아요)') }
  elseif ($result.mouseAccel -eq $false) { [void]$oks.Add('마우스 가속 꺼짐') }
  # 메모리 사용량
  if ($result.memUsedPct -gt 85) { [void]$warns.Add(("메모리 사용 {0}% - 백그라운드 프로그램 확인" -f $result.memUsedPct)) }
  # 게이트웨이
  $gwp = $null
  foreach ($pp in $pings) { if ($pp.isGateway) { $gwp = $pp; break } }
  if (-not $gateway) { [void]$warns.Add('게이트웨이(공유기/스위치)를 찾지 못함 - 랜선·네트워크 설정 확인') }
  elseif ($gwp) {
    if ($gwp.recv -eq 0) { [void]$warns.Add('게이트웨이 핑 응답 없음 (장비가 핑을 막았거나 연결 문제)') }
    elseif ($gwp.loss -gt 0 -or $gwp.avg -gt 3) { [void]$warns.Add(("게이트웨이 핑 불안정 (평균 {0}ms, 손실 {1}%) - 랜선·스위치 점검" -f $gwp.avg, $gwp.loss)) }
    else { [void]$oks.Add(("게이트웨이 핑 정상 ({0}ms)" -f $gwp.avg)) }
  }
} catch {}
$result.warns = [object[]]@($warns)

# ---------- 결과 코드 ----------
$json = $result | ConvertTo-Json -Depth 6 -Compress
$code = 'PCBANG1:' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
$copied = $false
try { Set-Clipboard -Value $code -ErrorAction Stop; $copied = $true } catch { $code | clip.exe; $copied = ($LASTEXITCODE -eq 0) }
# 공유 폴더에서 실행하면 모든 좌석이 같은 파일을 덮어쓰므로 바탕화면에 저장
$base2 = $base; if ($base2 -like '\\*') { $base2 = [Environment]::GetFolderPath('Desktop') }
$outFile = Join-Path $base2 'pc-check-result.txt'; $saved = $false
try { $code | Out-File -FilePath $outFile -Encoding ascii -ErrorAction Stop; $saved = $true } catch {
  $outFile = Join-Path ([Environment]::GetFolderPath('Desktop')) 'pc-check-result.txt'
  try { $code | Out-File -FilePath $outFile -Encoding ascii -ErrorAction Stop; $saved = $true } catch {}
}
# 공유 폴더에도 저장 (응답 없으면 8초 뒤 포기)
$shareMsg = $null
if ($Share) {
  try {
    $tag = $computer; if ($null -ne $seatVal) { $tag = [string]$seatVal }
    $tag = ([string]$tag) -replace '[\\/:*?"<>|\s]', '_'
    if (-not $tag) { $tag = 'unknown' }
    $fname = 'seat-' + $tag + '.txt'
    $writer = 'param($dir, $name, $text) try { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }; $p = Join-Path $dir $name; [System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding($false))); $p } catch { ''ERR:'' + $_.Exception.Message }'
    $shareMsg = InvokeTimed $writer @($Share, $fname, ($code + "`r`n")) 8000
  } catch { $shareMsg = 'ERR:' + $_.Exception.Message }
}

Say ''
Say '==============================================' Cyan
Say '  점검 요약' Cyan
Say '==============================================' Cyan
$okMark = [string][char]0x25CB; $warnMark = [string][char]0x25B2
if ($env:WT_SESSION) { $okMark = [string][char]0x2714; $warnMark = [string][char]0x26A0 }
foreach ($w in $warns) { Say ("  {0} {1}" -f $warnMark, $w) Yellow }
foreach ($k in $oks) { Say ("  {0} {1}" -f $okMark, $k) Green }
if (-not $warns.Count) { Say '  특별히 손볼 곳이 없어요.' Green }

Say ''
Say '==============================================' Cyan
if ($copied) { Say '  결과 코드를 클립보드에 복사했어요.' Green } else { Say '  클립보드 복사 실패: 아래 파일을 열어 복사하세요.' Red }
if ($saved) { Say ("  파일로도 저장: {0}" -f $outFile) }
if ($Share) {
  if ($shareMsg -and -not ([string]$shareMsg).StartsWith('ERR:')) { Say ("  공유 폴더에도 저장: {0}" -f $shareMsg) Green }
  else { Say ("  공유 폴더 저장 실패 ({0}): {1}" -f $Share, ([string]$shareMsg -replace '^ERR:', '')) Red }
}
Say '  웹 앱 [내 사양] 탭 -> 결과 붙여넣기 칸에 Ctrl+V 하세요.'
Say '==============================================' Cyan
Say ''
# 응답 없는 공유 폴더 작업이 남아 있으면 창이 닫히지 않을 수 있어 바로 종료
if ($timedOutJobs) { [Environment]::Exit(0) }

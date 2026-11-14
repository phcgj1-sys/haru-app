# PC방 게임 점검 - 윈도우 점검 프로그램 (Windows PowerShell 5.1 이상)
# 이 PC의 부품 정보와 네트워크(게이트웨이/외부 핑, 게임사 서버 접속 시간)를 측정해
# 결과 코드(PCBANG1:...)를 클립보드에 복사합니다. 정보를 어디로도 전송하지 않습니다.
# 핑 대상에게 보내는 짧은 신호(ICMP, TCP 접속)만 나갑니다.

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding(949) } catch {}

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

Say ''
Say '==============================================' Cyan
Say '  PC방 게임 점검 - 윈도우 점검 프로그램' Cyan
Say '==============================================' Cyan
Say '약 40초 걸립니다. 창을 닫지 마세요.'
Say ''

$result = [ordered]@{ v = 1; time = (Get-Date).ToString('yyyy-MM-dd HH:mm') }

# ---------- CPU ----------
Say '[1/6] CPU 확인' Yellow
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
if ($cpu) {
  $result.cpu = ($cpu.Name -replace '\s+', ' ').Trim()
  $result.cores = [int]$cpu.NumberOfCores
  $result.threads = [int]$cpu.NumberOfLogicalProcessors
  $result.cpuMHz = [int]$cpu.MaxClockSpeed
  $result.cpuLoad = [int]$cpu.LoadPercentage
  Say ("      {0} ({1}코어 {2}스레드)" -f $result.cpu, $result.cores, $result.threads)
}

# ---------- 그래픽 ----------
Say '[2/6] 그래픽카드 확인' Yellow
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
  $gpus += [ordered]@{ name = $name; vram = $vram; driver = $_.DriverVersion; virtual = $virtual; res = ("{0}x{1}" -f $_.CurrentHorizontalResolution, $_.CurrentVerticalResolution) }
  $vtxt = ''; if ($vram) { $vtxt = " {0}GB" -f $vram }
  Say ("      {0}{1} (드라이버 {2})" -f $name, $vtxt, $_.DriverVersion)
}
$result.gpus = [object[]]$gpus
if ($hz) { $result.hz = $hz; Say ("      모니터 주사율: {0}Hz" -f $hz) }

# ---------- 메모리·운영체제·전원·디스크 ----------
Say '[3/6] 메모리·운영체제·저장 장치 확인' Yellow
$sticks = @(Get-CimInstance Win32_PhysicalMemory)
$total = ($sticks | Measure-Object -Property Capacity -Sum).Sum
if (-not $total) { $total = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory }
$result.ramGB = [math]::Round($total / 1GB)
$result.ramSticks = $sticks.Count
$spd = ($sticks | ForEach-Object { if ($_.ConfiguredClockSpeed) { $_.ConfiguredClockSpeed } else { $_.Speed } } | Measure-Object -Minimum).Minimum
if ($spd) { $result.ramSpeed = [int]$spd }
$spdTxt = ''; if ($result.ramSpeed) { $spdTxt = (", {0}MT/s" -f $result.ramSpeed) }
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
Say ("      {0}" -f $result.osName)

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
  $tpm = Get-CimInstance -Namespace 'root/cimv2/Security/MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop
  if ($tpm) { $result.tpm = ("있음 ({0})" -f ($tpm.SpecVersion -split ',')[0]) } else { $result.tpm = '없음' }
} catch {
  $pe = Get-CimInstance Win32_PnPEntity -Filter "Service='TPM'" | Select-Object -First 1
  if ($pe) { $tv = '?'; if ($pe.Name -match '(\d\.\d)') { $tv = $matches[1] }; $result.tpm = "있음 ($tv)" } else { $result.tpm = '없음(또는 BIOS에서 꺼짐)' }
}
Say ("      보안 부팅: {0} / TPM: {1}" -f $result.secureBoot, $result.tpm)

$disks = @()
$ssdMap = @{}
try { Get-PhysicalDisk | ForEach-Object { $ssdMap[[string]$_.DeviceId] = [string]$_.MediaType } } catch {}
Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
  $disks += [ordered]@{ name = $_.DeviceID; size = [math]::Round($_.Size / 1GB); free = [math]::Round($_.FreeSpace / 1GB) }
}
$result.disks = [object[]]$disks
if ($ssdMap.Count) { $result.diskTypes = (($ssdMap.Values | Sort-Object -Unique) -join ', ') }

# ---------- 네트워크 어댑터·게이트웨이 ----------
Say '[4/6] 네트워크 연결 확인' Yellow
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
Say '[5/6] 핑 측정 (대상마다 20회)' Yellow
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
Say '[6/6] 게임사 웹 서버 접속 시간 (TCP, 게임 매치 서버가 아니라 가까운 웹/CDN 서버)' Yellow
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
        $okc = $task.Wait(2000) -and $c.Connected; $sw.Stop()
        if ($i -gt 0) { if ($okc) { [void]$times.Add($sw.Elapsed.TotalMilliseconds) } else { $o.fail++ } }
      } catch { if ($i -gt 0) { $o.fail++ } } finally { $c.Close() }
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

# ---------- 결과 코드 ----------
$json = $result | ConvertTo-Json -Depth 6 -Compress
$code = 'PCBANG1:' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
$copied = $false
try { Set-Clipboard -Value $code -ErrorAction Stop; $copied = $true } catch { $code | clip.exe; $copied = ($LASTEXITCODE -eq 0) }
$base = $PSScriptRoot; if (-not $base) { $base = [Environment]::GetFolderPath('Desktop') }
$outFile = Join-Path $base 'pc-check-result.txt'; $saved = $false
try { $code | Out-File -FilePath $outFile -Encoding ascii -ErrorAction Stop; $saved = $true } catch {
  $outFile = Join-Path ([Environment]::GetFolderPath('Desktop')) 'pc-check-result.txt'
  try { $code | Out-File -FilePath $outFile -Encoding ascii -ErrorAction Stop; $saved = $true } catch {}
}

Say ''
Say '==============================================' Cyan
if ($copied) { Say '  결과 코드를 클립보드에 복사했어요.' Green } else { Say '  클립보드 복사 실패: 아래 파일을 열어 복사하세요.' Red }
if ($saved) { Say ("  파일로도 저장: {0}" -f $outFile) }
Say '  웹 앱 [내 사양] 탭 -> 결과 붙여넣기 칸에 Ctrl+V 하세요.'
Say '==============================================' Cyan
Say ''

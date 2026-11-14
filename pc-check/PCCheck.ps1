<#
.SYNOPSIS
  PC 원클릭 진단 — 갑작스런 종료 · 블루스크린 · 그래픽카드(VRAM) · RAM · 디스크
.DESCRIPTION
  Windows 이벤트 로그, 덤프 파일, 하드웨어 상태를 수집해 원인 후보를 점수로 순위화하고
  HTML 보고서와 진단 데이터(JSON)를 만듭니다. 모든 처리는 PC 안에서만 이루어지며
  외부로 아무 정보도 보내지 않습니다.
.PARAMETER Mode     Gui(기본) · Console · Silent(무인 실행, CI용)
.PARAMETER Days     분석 기간(일), 1~365
.PARAMETER OutDir   보고서 저장 폴더 (기본: 바탕화면\PC진단)
.PARAMETER FromJson 저장된 진단 데이터(JSON)로 보고서를 다시 생성 (원격 상담용)
.PARAMETER LoadOnly 함수만 불러오고 실행하지 않음 (테스트용)
#>
[CmdletBinding()]
param(
    [ValidateSet('Gui', 'Console', 'Silent')][string]$Mode = 'Gui',
    [ValidateRange(1, 365)][int]$Days = 30,
    [string]$OutDir,
    [string]$FromJson,
    [switch]$NoOpen,
    [switch]$GuiSmokeTest,
    [switch]$LoadOnly
)

$script:AppName    = 'PC 원클릭 진단'
$script:AppVersion = '2.0.0'
$script:IsWin      = ($env:OS -eq 'Windows_NT')

# =====================================================================
#  공통 유틸
# =====================================================================
function HtmlEnc($s) { if ($null -eq $s) { return '' }; return [System.Net.WebUtility]::HtmlEncode([string]$s) }

function Format-T($dt) { if ($null -eq $dt) { return '' }; return ([datetime]$dt).ToString('yyyy-MM-ddTHH:mm:ss') }
function ConvertTo-Date($s) {
    if ($null -eq $s -or $s -eq '') { return $null }
    if ($s -is [datetime]) { return $s }
    try { return [datetime]::Parse([string]$s, [Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}
function Get-FirstLine($s, [int]$Max = 220) {
    if ($null -eq $s) { return '' }
    $l = (([string]$s) -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
    if ($null -eq $l) { return '' }
    $l = $l.Trim()
    if ($l.Length -gt $Max) { $l = $l.Substring(0, $Max) + '…' }
    return $l
}
function Format-BugCode($n) {
    # 정수/문자열 어떤 형태든 '0x116' 같은 표준 형태로
    if ($null -eq $n -or $n -eq '') { return '' }
    if ($n -is [string]) {
        $s = $n.Trim()
        if ($s -match '^0x([0-9a-fA-F]+)$') { $v = [Convert]::ToUInt64($Matches[1], 16) }
        elseif ($s -match '^\d+$') { $v = [uint64]$s }
        else { return '' }
    } else { $v = [uint64]([int64]$n -band 0xFFFFFFFFL) }
    if ($v -eq 0) { return '' }
    return ('0x{0:X}' -f $v)
}

$script:LogFile = $null
function Write-PCLog([string]$msg) {
    if (-not $script:LogFile) { return }
    try { Add-Content -Path $script:LogFile -Value ("{0:HH:mm:ss} {1}" -f (Get-Date), $msg) -Encoding UTF8 } catch {}
}

# =====================================================================
#  지식 베이스
# =====================================================================
# 원인 카테고리
$script:Causes = [ordered]@{
    PSU        = @{ Name = '파워(전원 공급)';        Icon = '⚡' }
    GPU_HW     = @{ Name = '그래픽카드 하드웨어/VRAM'; Icon = '🎮' }
    GPU_DRIVER = @{ Name = '그래픽 드라이버';          Icon = '🧩' }
    RAM        = @{ Name = 'RAM(메모리)';             Icon = '🧠' }
    CPU_OC     = @{ Name = 'CPU·오버클럭·전압';        Icon = '🔧' }
    THERMAL    = @{ Name = '과열(쿨링)';              Icon = '🌡' }
    DISK       = @{ Name = '저장장치(SSD/HDD)';        Icon = '💾' }
    DRIVER     = @{ Name = '기타 드라이버/소프트웨어';   Icon = '🛠' }
}

# 블루스크린 코드: 이름, 쉬운 설명, 원인 가중치
$script:BugDb = @{
    '0x116' = @{ N = 'VIDEO_TDR_FAILURE';               D = '그래픽카드가 응답하지 않아 복구에 실패';          W = @{ GPU_DRIVER = 15; GPU_HW = 12; PSU = 4 } }
    '0x117' = @{ N = 'VIDEO_TDR_TIMEOUT_DETECTED';      D = '그래픽카드 응답 시간 초과';                       W = @{ GPU_DRIVER = 12; GPU_HW = 10 } }
    '0x119' = @{ N = 'VIDEO_SCHEDULER_INTERNAL_ERROR';  D = '그래픽 스케줄러 오류';                             W = @{ GPU_DRIVER = 14; GPU_HW = 6 } }
    '0x10E' = @{ N = 'VIDEO_MEMORY_MANAGEMENT_INTERNAL'; D = '그래픽 메모리 관리 오류';                        W = @{ GPU_DRIVER = 10; GPU_HW = 12 } }
    '0x141' = @{ N = 'VIDEO_ENGINE_TIMEOUT_DETECTED';   D = '그래픽 엔진 응답 없음';                            W = @{ GPU_DRIVER = 10; GPU_HW = 8 } }
    '0x124' = @{ N = 'WHEA_UNCORRECTABLE_ERROR';        D = '복구 불가능한 하드웨어 오류';                       W = @{ CPU_OC = 14; PSU = 8; THERMAL = 6; RAM = 4; GPU_HW = 3 } }
    '0x101' = @{ N = 'CLOCK_WATCHDOG_TIMEOUT';          D = 'CPU 코어가 응답하지 않음';                          W = @{ CPU_OC = 16; PSU = 4 } }
    '0x1A'  = @{ N = 'MEMORY_MANAGEMENT';               D = '메모리 관리 오류';                                  W = @{ RAM = 15; DRIVER = 4 } }
    '0x50'  = @{ N = 'PAGE_FAULT_IN_NONPAGED_AREA';     D = '잘못된 메모리 접근';                                W = @{ RAM = 10; DRIVER = 7 } }
    '0x4E'  = @{ N = 'PFN_LIST_CORRUPT';                D = '메모리 페이지 목록 손상';                           W = @{ RAM = 15 } }
    '0x19'  = @{ N = 'BAD_POOL_HEADER';                 D = '메모리 풀 손상';                                    W = @{ RAM = 9; DRIVER = 8 } }
    '0xC2'  = @{ N = 'BAD_POOL_CALLER';                 D = '드라이버의 잘못된 메모리 요청';                      W = @{ DRIVER = 10; RAM = 5 } }
    '0x139' = @{ N = 'KERNEL_SECURITY_CHECK_FAILURE';   D = '커널 데이터 손상 감지';                             W = @{ DRIVER = 9; RAM = 8 } }
    '0xA'   = @{ N = 'IRQL_NOT_LESS_OR_EQUAL';          D = '드라이버/메모리 접근 오류';                          W = @{ DRIVER = 10; RAM = 7 } }
    '0xD1'  = @{ N = 'DRIVER_IRQL_NOT_LESS_OR_EQUAL';   D = '드라이버 메모리 접근 오류';                          W = @{ DRIVER = 13; RAM = 4 } }
    '0x3B'  = @{ N = 'SYSTEM_SERVICE_EXCEPTION';        D = '시스템 서비스 예외 (그래픽 드라이버에서 흔함)';        W = @{ DRIVER = 9; GPU_DRIVER = 6; RAM = 4 } }
    '0x7E'  = @{ N = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED'; D = '드라이버 예외 처리 실패';                       W = @{ DRIVER = 12; GPU_DRIVER = 3 } }
    '0x1E'  = @{ N = 'KMODE_EXCEPTION_NOT_HANDLED';     D = '커널 모드 예외';                                    W = @{ DRIVER = 10; RAM = 5 } }
    '0x9F'  = @{ N = 'DRIVER_POWER_STATE_FAILURE';      D = '절전/전원 전환 중 드라이버 문제';                    W = @{ DRIVER = 13 } }
    '0x133' = @{ N = 'DPC_WATCHDOG_VIOLATION';          D = '드라이버 또는 SSD 펌웨어 응답 지연';                 W = @{ DRIVER = 9; DISK = 7 } }
    '0x7A'  = @{ N = 'KERNEL_DATA_INPAGE_ERROR';        D = '디스크에서 데이터를 읽지 못함';                      W = @{ DISK = 15; RAM = 4 } }
    '0x77'  = @{ N = 'KERNEL_STACK_INPAGE_ERROR';       D = '디스크 읽기 오류';                                  W = @{ DISK = 15 } }
    '0xF4'  = @{ N = 'CRITICAL_OBJECT_TERMINATION';     D = '핵심 프로세스 종료 (디스크 문제에서 흔함)';           W = @{ DISK = 12; DRIVER = 4 } }
    '0xEF'  = @{ N = 'CRITICAL_PROCESS_DIED';           D = '핵심 시스템 프로세스 종료';                          W = @{ DISK = 8; DRIVER = 8 } }
    '0x7B'  = @{ N = 'INACCESSIBLE_BOOT_DEVICE';        D = '부팅 디스크 접근 불가';                              W = @{ DISK = 15 } }
    '0x154' = @{ N = 'UNEXPECTED_STORE_EXCEPTION';      D = '저장소 관리 예외';                                  W = @{ DISK = 10; RAM = 5 } }
    '0x1000007E' = @{ N = 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED_M'; D = '드라이버 예외 처리 실패';              W = @{ DRIVER = 12 } }
    '0x1000008E' = @{ N = 'KERNEL_MODE_EXCEPTION_NOT_HANDLED_M';   D = '커널 모드 예외';                      W = @{ DRIVER = 10; RAM = 5 } }
}
function Get-BugInfo([string]$code) {
    $k = Format-BugCode $code
    if ($k -and $script:BugDb.ContainsKey($k)) { return $script:BugDb[$k] }
    return @{ N = '기타'; D = 'BlueScreenView 로 원인 드라이버 확인 권장'; W = @{ DRIVER = 6 } }
}

# NVIDIA Xid (드라이버 오류 번호)
$script:XidDb = @{
    13 = @{ D = '그래픽 엔진 예외 (주로 앱/드라이버)';  W = @{ GPU_DRIVER = 3 } }
    31 = @{ D = 'GPU 메모리 페이지 오류 (주로 앱/드라이버)'; W = @{ GPU_DRIVER = 3 } }
    43 = @{ D = 'GPU 작업 중단 (앱 오류)';            W = @{ GPU_DRIVER = 2 } }
    45 = @{ D = '작업 강제 종료';                      W = @{ GPU_DRIVER = 1 } }
    48 = @{ D = 'VRAM 더블비트 ECC 오류';              W = @{ GPU_HW = 30 } }
    61 = @{ D = '내부 마이크로컨트롤러 정지';            W = @{ GPU_HW = 10; GPU_DRIVER = 8 } }
    62 = @{ D = '내부 마이크로컨트롤러 정지';            W = @{ GPU_HW = 10; GPU_DRIVER = 8 } }
    63 = @{ D = 'VRAM 페이지 퇴출(ECC)';                W = @{ GPU_HW = 25 } }
    64 = @{ D = 'VRAM 페이지 퇴출 실패';                W = @{ GPU_HW = 30 } }
    74 = @{ D = 'NVLink 오류';                          W = @{ GPU_HW = 10 } }
    79 = @{ D = '그래픽카드가 PCIe 버스에서 떨어짐';      W = @{ GPU_HW = 20; PSU = 18; THERMAL = 6 } }
    92 = @{ D = '높은 단일비트 ECC 오류율';              W = @{ GPU_HW = 20 } }
    94 = @{ D = 'VRAM 오류 격리됨';                     W = @{ GPU_HW = 25 } }
    95 = @{ D = 'VRAM 오류 격리 실패';                  W = @{ GPU_HW = 30 } }
    119 = @{ D = 'GSP 응답 시간 초과';                  W = @{ GPU_DRIVER = 10; GPU_HW = 4 } }
}
$script:VramXids = @(48, 63, 64, 92, 94, 95)

# 원인별 해결 단계 (쉬운 것 → 어려운 것)
$script:Playbook = @{
    PSU = @(
        '멀티탭을 빼고 벽 콘센트에 직접 연결해 보기',
        '그래픽카드 보조전원(8핀)을 한 줄 케이블이 아니라 각각 별도 케이블로 연결',
        '파워 정격 용량 확인: 그래픽카드 권장 파워 이상인지 (예: RTX 4070 → 650W 이상)',
        '메뉴의 "부하 테스트(OCCT Power)" 중 꺼지면 파워 교체 1순위 (5년 이상 사용 파워는 특히 의심)'
    )
    GPU_HW = @(
        '그래픽카드 오버클럭/언더볼트 설정 해제 (MSI Afterburner 기본값)',
        'VRAM 검사(memtest_vulkan) 10분 이상 실행 → error 가 나오면 VRAM 불량',
        '그래픽카드를 뽑았다 다시 장착, 슬롯/보조전원 단자 확인',
        '그래도 반복되면 그래픽카드 A/S (진단 보고서 첨부)'
    )
    GPU_DRIVER = @(
        '그래픽 드라이버를 최신 "안정" 버전으로 (최근 업데이트 후 문제라면 이전 버전으로)',
        'DDU(Display Driver Uninstaller)로 안전모드에서 완전 삭제 후 재설치',
        '그래픽 설정의 오버레이/녹화 기능(GeForce Experience, Adrenalin) 끄기',
        '계속되면 그래픽카드 하드웨어 점검(VRAM 검사)으로 진행'
    )
    RAM = @(
        'BIOS 에서 XMP/EXPO(메모리 오버클럭) 끄고 사용해 보기',
        'Windows 메모리 진단 실행 (메뉴) → 더 정밀하게는 MemTest86 USB 부팅 4회 이상',
        'RAM 을 한 개씩만 꽂아 테스트해 불량 모듈 찾기',
        '메인보드 BIOS 업데이트'
    )
    CPU_OC = @(
        'BIOS 기본값(Load Optimized Defaults)으로 초기화 → 오버클럭/언더볼트 해제',
        '메인보드 BIOS 최신 버전으로 업데이트 (Intel 13·14세대는 마이크로코드 업데이트 필수)',
        'CPU 온도와 전압을 HWiNFO 로 확인',
        '계속되면 CPU/메인보드 점검'
    )
    THERMAL = @(
        '케이스 내부 먼지 청소, 팬이 모두 도는지 확인',
        'HWiNFO 로 부하 중 CPU/GPU 온도 확인 (GPU 85°C·CPU 95°C 이상이면 위험)',
        '써멀 페이스트 재도포, 케이스 공기 흐름 개선'
    )
    DISK = @(
        '중요한 자료를 즉시 백업',
        'CrystalDiskInfo 로 SMART 상태 확인 (주의/나쁨이면 교체)',
        'SSD 펌웨어 업데이트, SATA 케이블 교체',
        '관리자 명령 프롬프트에서 chkdsk C: /scan 실행'
    )
    DRIVER = @(
        'BlueScreenView 로 블루스크린 원인 드라이버(.sys) 확인 (메뉴)',
        '해당 드라이버(칩셋·랜·사운드·보안프로그램) 업데이트 또는 제거',
        '관리자 명령 프롬프트: sfc /scannow 후 DISM /Online /Cleanup-Image /RestoreHealth',
        '최근 설치한 프로그램/드라이버가 있다면 제거 또는 시스템 복원'
    )
}

# =====================================================================
#  수집 (Windows 전용)
# =====================================================================
function New-EmptyData {
    return [ordered]@{
        Meta = [ordered]@{ App = $script:AppName; Version = $script:AppVersion; Created = (Format-T (Get-Date)); Computer = $env:COMPUTERNAME; Days = 30; IsAdmin = $false; PS = "$($PSVersionTable.PSVersion)" }
        System = [ordered]@{}
        Gpus = @(); NvSmi = @(); Dimms = @()
        Shutdowns = @(); Unexpected = @(); BugChecks = @(); Dumps = @()
        GpuEvents = @(); Whea = @(); DiskEvents = @(); Disks = @(); MemDiag = @()
        DriverInstalls = @(); AppCrashes = @(); OcTools = @(); Thermal = @()
        Errors = @()
    }
}

function Get-EventsSafe([string]$Log, $Ids, [string]$Provider, [datetime]$Since, [int]$Max = 500) {
    $f = @{ LogName = $Log; StartTime = $Since }
    if ($Ids) { $f.Id = $Ids }
    if ($Provider) { $f.ProviderName = $Provider }
    try { return @(Get-WinEvent -FilterHashtable $f -MaxEvents $Max -ErrorAction Stop) }
    catch { return @() }   # 기록이 없으면 예외가 나므로 빈 배열
}
function Get-EventData($e) {
    # 이벤트의 EventData 를 이름 → 값 사전으로 (속성 순서는 Windows 버전마다 다를 수 있음)
    $h = @{}
    try {
        $x = [xml]$e.ToXml()
        foreach ($d in $x.Event.EventData.Data) { if ($d.Name) { $h[[string]$d.Name] = [string]$d.'#text' } }
    } catch {}
    return $h
}
function Get-EventText($e) {
    $t = $e.Message
    if (-not $t) { $t = (($e.Properties | ForEach-Object { [string]$_.Value }) -join ' ') }
    return [string]$t
}

function Read-MinidumpBugCode([string]$Path) {
    # 커널 미니덤프 헤더에서 BugCheck 코드 직접 읽기 (PAGEDU64: 0x38, PAGEDUMP: 0x20)
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $buf = New-Object byte[] 0x60
            [void]$fs.Read($buf, 0, $buf.Length)
        } finally { $fs.Dispose() }
        $sig = [Text.Encoding]::ASCII.GetString($buf, 0, 8)
        if ($sig -eq 'PAGEDU64') { return (Format-BugCode ([BitConverter]::ToUInt32($buf, 0x38))) }
        if ($sig -eq 'PAGEDUMP') { return (Format-BugCode ([BitConverter]::ToUInt32($buf, 0x20))) }
    } catch {}
    return ''
}

function Invoke-Collect {
    param([int]$Days = 30, [scriptblock]$Progress)
    $D = New-EmptyData
    $D.Meta.Days = $Days
    $D.Meta.IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $since = (Get-Date).AddDays(-$Days)

    $steps = @(
        @{ Name = '시스템 정보';            Run = {
            $os = Get-CimInstance Win32_OperatingSystem
            $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
            $cs = Get-CimInstance Win32_ComputerSystem
            $mb = Get-CimInstance Win32_BaseBoard
            $bios = Get-CimInstance Win32_BIOS
            $plan = ''
            try { $plan = ((powercfg /getactivescheme) -replace '^.*\(|\)\s*$', '') } catch {}
            $fast = $null
            try { $fast = [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction Stop).HiberbootEnabled } catch {}
            $D.System = [ordered]@{
                OS = $os.Caption; Build = $os.BuildNumber; Version = $os.Version
                CPU = ($cpu.Name -replace '\s+', ' ').Trim(); Cores = $cpu.NumberOfCores; Threads = $cpu.NumberOfLogicalProcessors
                Board = ("$($mb.Manufacturer) $($mb.Product)").Trim(); BIOS = $bios.SMBIOSBIOSVersion; BIOSDate = (Format-T $bios.ReleaseDate)
                RamGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
                LastBoot = (Format-T $os.LastBootUpTime); PowerPlan = $plan; FastStartup = $fast
                Model = ("$($cs.Manufacturer) $($cs.Model)").Trim()
                IsVM = [bool]($cs.HypervisorPresent -and ("$($cs.Manufacturer) $($cs.Model)" -match 'Virtual|VMware|QEMU|KVM|Xen|Parallels|VirtualBox|Hyper-V|Amazon EC2|Google Compute'))
            }
        } }
        @{ Name = '그래픽카드';             Run = {
            $reg = @{}
            $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
            Get-ChildItem $classKey -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
                $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                if ($p.DriverDesc) {
                    $m = $p.'HardwareInformation.qwMemorySize'
                    if (-not $m) { $m = $p.'HardwareInformation.MemorySize'; if ($m -is [byte[]]) { $m = [BitConverter]::ToUInt32($m, 0) } }
                    if ($m) { $reg[$p.DriverDesc] = [double]$m }
                }
            }
            $list = @()
            foreach ($v in Get-CimInstance Win32_VideoController) {
                if ($v.Name -match 'Microsoft Basic|Remote Display|Virtual|Parsec|Meta Virtual') { continue }
                $vram = $null
                if ($reg.ContainsKey($v.Name)) { $vram = $reg[$v.Name] } elseif ($v.AdapterRAM) { $vram = [double]$v.AdapterRAM }
                $vendor = if ($v.Name -match 'NVIDIA|GeForce|RTX|GTX|Quadro') { 'NVIDIA' } elseif ($v.Name -match 'AMD|Radeon') { 'AMD' } elseif ($v.Name -match 'Intel') { 'Intel' } else { '' }
                $list += [ordered]@{ Name = $v.Name; Vendor = $vendor; VramGB = $(if ($vram) { [math]::Round($vram / 1GB, 1) } else { $null }); Driver = $v.DriverVersion; DriverDate = (Format-T $v.DriverDate); Status = $v.Status }
            }
            $D.Gpus = $list
            $nv = $null
            foreach ($c in @("$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe")) { if (Test-Path $c) { $nv = $c; break } }
            if ($nv) {
                $out = & $nv '--query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total,power.draw,power.limit,clocks.gr,driver_version' '--format=csv,noheader,nounits' 2>$null
                $rows = @()
                foreach ($line in @($out)) {
                    $c = ([string]$line) -split ',\s*'
                    if ($c.Count -ge 9) {
                        $num = { param($x) $r = 0.0; if ([double]::TryParse(($x -replace '[^\d\.]', ''), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$r)) { $r } else { $null } }
                        $rows += [ordered]@{ Name = $c[0]; Temp = (& $num $c[1]); Util = (& $num $c[2]); MemUsedMB = (& $num $c[3]); MemTotalMB = (& $num $c[4]); PowerW = (& $num $c[5]); PowerLimitW = (& $num $c[6]); ClockMHz = (& $num $c[7]); Driver = $c[8] }
                    }
                }
                $D.NvSmi = $rows
            }
        } }
        @{ Name = 'RAM';                    Run = {
            $D.Dimms = @(Get-CimInstance Win32_PhysicalMemory | ForEach-Object {
                $ddr = switch ([int]$_.SMBIOSMemoryType) { 26 { 'DDR4' } 34 { 'DDR5' } 24 { 'DDR3' } default { '' } }
                [ordered]@{ Slot = $_.DeviceLocator; SizeGB = [math]::Round($_.Capacity / 1GB, 0); ConfiguredMHz = $_.ConfiguredClockSpeed; RatedMHz = $_.Speed; Maker = ([string]$_.Manufacturer).Trim(); Part = ([string]$_.PartNumber).Trim(); DDR = $ddr }
            })
        } }
        @{ Name = '갑작스런 종료 기록';      Run = {
            $D.Shutdowns = @(Get-EventsSafe 'System' 41 'Microsoft-Windows-Kernel-Power' $since | ForEach-Object {
                $ed = Get-EventData $_
                $code = 0; try { $code = [int64]$ed['BugcheckCode'] } catch {}
                $pb = 0; try { $pb = [int64]$ed['PowerButtonTimestamp'] } catch {}
                $sl = 0; try { $sl = [int64]$ed['SleepInProgress'] } catch {}
                [ordered]@{ T = (Format-T $_.TimeCreated); Code = (Format-BugCode $code); PowerButton = [bool]($pb -ne 0); Sleep = [bool]($sl -ne 0) }
            })
            $D.Unexpected = @(Get-EventsSafe 'System' 6008 'EventLog' $since | ForEach-Object { [ordered]@{ T = (Format-T $_.TimeCreated) } })
        } }
        @{ Name = '블루스크린 기록';         Run = {
            $D.BugChecks = @(Get-EventsSafe 'System' 1001 $null $since | Where-Object { $_.ProviderName -match 'WER-SystemErrorReporting|BugCheck' } | ForEach-Object {
                $txt = Get-EventText $_; $code = ''
                if ($txt -match '0x[0-9a-fA-F]{8}\b') { $code = Format-BugCode $Matches[0] }
                [ordered]@{ T = (Format-T $_.TimeCreated); Code = $code }
            })
            $files = @(Get-ChildItem "$env:SystemRoot\Minidump\*.dmp" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 50)
            $D.Dumps = @($files | ForEach-Object { [ordered]@{ T = (Format-T $_.LastWriteTime); Name = $_.Name; SizeKB = [math]::Round($_.Length / 1KB); Code = (Read-MinidumpBugCode $_.FullName) } })
            $live = @(Get-ChildItem "$env:SystemRoot\LiveKernelReports\WATCHDOG\*.dmp", "$env:SystemRoot\LiveKernelReports\*.dmp" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $since })
            $D.System.LiveDumps = $live.Count
        } }
        @{ Name = '그래픽 드라이버 오류';    Run = {
            $ev = @()
            $ev += Get-EventsSafe 'System' 4101 'Display' $since
            $ev += Get-EventsSafe 'System' @(13, 14, 153) 'nvlddmkm' $since
            foreach ($p in 'amdkmdag', 'amdwddmg', 'igfx', 'igfxn') { $ev += @(Get-EventsSafe 'System' $null $p $since | Where-Object { $_.Level -le 2 }) }
            $wer = @(Get-EventsSafe 'Application' 1001 'Windows Error Reporting' $since 300 | Where-Object { (Get-EventText $_) -match 'LiveKernelEvent' -and (Get-EventText $_) -match '\b(141|117|1a1|1a8)\b' })
            $ev += $wer
            $D.GpuEvents = @($ev | Sort-Object TimeCreated -Descending | Select-Object -First 300 | ForEach-Object {
                $txt = Get-EventText $_; $xid = $null
                if ($txt -match 'Xid[^:\d]*(?:\([^)]*\))?\s*:?\s*(\d{1,3})\b') { $xid = [int]$Matches[1] }
                $src = $_.ProviderName; if ($src -eq 'Windows Error Reporting') { $src = 'LiveKernelEvent' }
                [ordered]@{ T = (Format-T $_.TimeCreated); Source = $src; Id = $_.Id; Xid = $xid; Msg = (Get-FirstLine $txt) }
            })
        } }
        @{ Name = '하드웨어 오류(WHEA)';     Run = {
            $D.Whea = @(Get-EventsSafe 'System' $null 'Microsoft-Windows-WHEA-Logger' $since | ForEach-Object {
                $txt = Get-EventText $_; $comp = ''
                if ($txt -match '(?m)(Component|구성 요소)\s*:\s*(.+)$') { $comp = $Matches[2].Trim() }
                [ordered]@{ T = (Format-T $_.TimeCreated); Id = $_.Id; Level = [int]$_.Level; Comp = $comp; Msg = (Get-FirstLine $txt) }
            })
        } }
        @{ Name = '저장장치';                Run = {
            $ev = @()
            $ev += Get-EventsSafe 'System' @(7, 11, 51, 153) 'disk' $since
            $ev += Get-EventsSafe 'System' 55 'Ntfs' $since
            $ev += Get-EventsSafe 'System' @(129, 153) 'stornvme' $since
            $ev += Get-EventsSafe 'System' @(129) 'storahci' $since
            $D.DiskEvents = @($ev | Sort-Object TimeCreated -Descending | Select-Object -First 200 | ForEach-Object { [ordered]@{ T = (Format-T $_.TimeCreated); Source = $_.ProviderName; Id = $_.Id; Msg = (Get-FirstLine (Get-EventText $_)) } })
            $D.Disks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
                $r = $_ | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
                [ordered]@{ Name = $_.FriendlyName; Media = [string]$_.MediaType; Bus = [string]$_.BusType; SizeGB = [math]::Round($_.Size / 1GB); Health = [string]$_.HealthStatus; TempC = $r.Temperature; WearPct = $r.Wear; ReadErr = $r.ReadErrorsUncorrected; PowerOnHours = $r.PowerOnHours }
            })
        } }
        @{ Name = '메모리 진단 결과';        Run = {
            $D.MemDiag = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results' } -MaxEvents 5 -ErrorAction SilentlyContinue | ForEach-Object {
                $txt = Get-EventText $_
                $failed = ($_.Id -in 1102, 1202) -or ($txt -match 'detected hardware errors|하드웨어 오류가|오류가 검색되었')
                [ordered]@{ T = (Format-T $_.TimeCreated); Id = $_.Id; Failed = [bool]$failed; Msg = (Get-FirstLine $txt) }
            })
        } }
        @{ Name = '드라이버 설치·앱 충돌·온도'; Run = {
            $D.DriverInstalls = @(Get-EventsSafe 'System' 20001 'Microsoft-Windows-UserPnp' $since 200 | ForEach-Object {
                $txt = Get-EventText $_
                if ($txt -match 'Display|디스플레이|NVIDIA|GeForce|Radeon|AMD|Intel\(R\).*Graphics|Arc') { [ordered]@{ T = (Format-T $_.TimeCreated); Msg = (Get-FirstLine $txt) } }
            } | Where-Object { $_ })
            $crash = @(Get-EventsSafe 'Application' 1000 'Application Error' $since 400 | ForEach-Object { try { [string]$_.Properties[0].Value } catch { '' } } | Where-Object { $_ })
            $D.AppCrashes = @($crash | Group-Object | Sort-Object Count -Descending | Select-Object -First 8 | ForEach-Object { [ordered]@{ App = $_.Name; Count = $_.Count } })
            $oc = 'MSIAfterburner', 'EVGAPrecisionX1', 'ThrottleStop', 'XTU', 'RyzenMaster', 'AsusGpuTweakII', 'GPUTweakIII', 'AISuite3', 'ArmouryCrate.Service'
            $D.OcTools = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $oc -contains $_.ProcessName } | Select-Object -ExpandProperty ProcessName -Unique)
            $D.Thermal = @(Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue | Where-Object { $_.CurrentTemperature } | ForEach-Object { [math]::Round($_.CurrentTemperature / 10 - 273.15, 1) } | Where-Object { $_ -gt 0 -and $_ -lt 130 })
        } }
    )

    $i = 0
    foreach ($s in $steps) {
        $i++
        if ($Progress) { & $Progress $i $steps.Count $s.Name }
        Write-PCLog "collect: $($s.Name)"
        try { & $s.Run } catch {
            $D.Errors += [ordered]@{ Step = $s.Name; Msg = $_.Exception.Message }
            Write-PCLog "  error: $($_.Exception.Message)"
        }
    }
    return $D
}

# =====================================================================
#  분석 (순수 함수 · 어느 OS 에서나 테스트 가능)
# =====================================================================
function Get-Arr($x) { if ($null -eq $x) { return @() }; return @($x) }
function Get-Prop($o, [string]$n) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Collections.IDictionary]) { if ($o.Contains($n)) { return $o[$n] }; return $null }
    $p = $o.PSObject.Properties[$n]; if ($p) { return $p.Value }; return $null
}

function Get-Diagnosis {
    param([Parameter(Mandatory)]$Data)
    $score = [ordered]@{}; foreach ($k in $script:Causes.Keys) { $score[$k] = 0.0 }
    $why = @{}; foreach ($k in $script:Causes.Keys) { $why[$k] = New-Object System.Collections.ArrayList }
    $findings = New-Object System.Collections.ArrayList
    $add = {
        param($cause, [double]$pts, [string]$reason)
        $score[$cause] = [double]$score[$cause] + $pts
        if ($reason -and -not $why[$cause].Contains($reason)) { [void]$why[$cause].Add($reason) }
    }
    $find = {
        param([string]$level, [string]$cat, [string]$title, [string]$detail, [int]$penalty)
        [void]$findings.Add([ordered]@{ Level = $level; Category = $cat; Title = $title; Detail = $detail; Penalty = $penalty })
    }

    $meta = Get-Prop $Data 'Meta'
    $days = [int](Get-Prop $meta 'Days'); if ($days -le 0) { $days = 30 }
    $shut = @(Get-Arr (Get-Prop $Data 'Shutdowns'))
    $bugEv = @(Get-Arr (Get-Prop $Data 'BugChecks'))
    $dumps = @(Get-Arr (Get-Prop $Data 'Dumps'))
    $gpuEv = @(Get-Arr (Get-Prop $Data 'GpuEvents'))
    $whea = @(Get-Arr (Get-Prop $Data 'Whea'))
    $diskEv = @(Get-Arr (Get-Prop $Data 'DiskEvents'))
    $disks = @(Get-Arr (Get-Prop $Data 'Disks'))
    $memDiag = @(Get-Arr (Get-Prop $Data 'MemDiag'))
    $nv = @(Get-Arr (Get-Prop $Data 'NvSmi'))
    $therm = @(Get-Arr (Get-Prop $Data 'Thermal'))
    $dimms = @(Get-Arr (Get-Prop $Data 'Dimms'))
    $gpus = @(Get-Arr (Get-Prop $Data 'Gpus'))
    $drvInst = @(Get-Arr (Get-Prop $Data 'DriverInstalls'))
    $oc = @(Get-Arr (Get-Prop $Data 'OcTools'))
    $sys = Get-Prop $Data 'System'

    # ---- 1) 블루스크린 코드 모으기 (이벤트 + 덤프, 같은 사건은 중복 제거)
    $crashes = New-Object System.Collections.ArrayList
    foreach ($b in $bugEv) { $c = Format-BugCode (Get-Prop $b 'Code'); [void]$crashes.Add(@{ T = (ConvertTo-Date (Get-Prop $b 'T')); Code = $c }) }
    foreach ($d in $dumps) {
        $t = ConvertTo-Date (Get-Prop $d 'T'); $c = Format-BugCode (Get-Prop $d 'Code')
        $dup = $false
        foreach ($x in $crashes) { if ($x.T -and $t -and [math]::Abs(($x.T - $t).TotalMinutes) -lt 30) { $dup = $true; if (-not $x.Code) { $x.Code = $c }; break } }
        if (-not $dup) { [void]$crashes.Add(@{ T = $t; Code = $c }) }
    }
    $powerLoss = @(); $bsod41 = @()
    foreach ($s in $shut) {
        $c = Format-BugCode (Get-Prop $s 'Code'); $t = ConvertTo-Date (Get-Prop $s 'T')
        if ($c) {
            $bsod41 += $s
            $dup = $false
            foreach ($x in $crashes) { if ($x.T -and $t -and [math]::Abs(($x.T - $t).TotalMinutes) -lt 30) { $dup = $true; break } }
            if (-not $dup) { [void]$crashes.Add(@{ T = $t; Code = $c }) }
        } else { $powerLoss += $s }
    }
    $codeCount = @{}
    foreach ($x in $crashes) { $k = $x.Code; if (-not $k) { $k = '(미상)' }; $codeCount[$k] = 1 + [int]$codeCount[$k] }

    # ---- 2) 블루스크린 없이 꺼짐 (코드 0)
    $plCount = $powerLoss.Count
    $plButton = @($powerLoss | Where-Object { Get-Prop $_ 'PowerButton' }).Count
    $plSleep = @($powerLoss | Where-Object { Get-Prop $_ 'Sleep' }).Count
    if ($plCount -gt 0) {
        $eff = [math]::Max(0, $plCount - $plButton * 0.7)
        & $add 'PSU' ([math]::Min(45, 14 * $eff)) "블루스크린 없이 꺼짐 $plCount 회"
        & $add 'THERMAL' ([math]::Min(18, 5 * $eff)) '블루스크린 없이 꺼짐 (과열 보호 차단 가능)'
        & $add 'GPU_HW' ([math]::Min(12, 3 * $eff)) ''
        $lv = if ($plCount -ge 3) { 'bad' } else { 'warn' }
        $d = "블루스크린 기록 없이 전원이 끊긴 것처럼 꺼진 기록입니다. 파워 부족·노후, 과열 보호, 전원 케이블/멀티탭 접촉 불량에서 전형적으로 나타납니다."
        if ($plButton) { $d += " (이 중 $plButton 회는 전원 버튼을 길게 눌러 끈 흔적이 있습니다 — 멈춤 후 강제 종료였을 수 있습니다.)" }
        if ($plSleep) {
            $d += " $plSleep 회는 절전 진입/복귀 중에 발생했습니다 (드라이버·BIOS 절전 설정 문제가 흔함)."
            & $add 'DRIVER' ([math]::Min(20, 8 * $plSleep)) "절전 진입/복귀 중 꺼짐 $plSleep 회"
        }

        & $find $lv 'PSU' "갑자기 꺼짐 $plCount 회 (블루스크린 없음)" $d ([math]::Min(35, 10 * $plCount))
    }

    # ---- 3) 블루스크린
    if ($crashes.Count -gt 0) {
        $parts = @()
        foreach ($k in ($codeCount.Keys | Sort-Object { -$codeCount[$_] })) {
            if ($k -eq '(미상)') { $parts += "코드 미상 $($codeCount[$k])회"; continue }
            $bi = Get-BugInfo $k
            $parts += "$k $($bi.N) $($codeCount[$k])회"
            $mult = [math]::Min(3, $codeCount[$k])
            foreach ($wk in $bi.W.Keys) { & $add $wk ($bi.W[$wk] * $mult) "블루스크린 $k ($($bi.N))" }
        }
        if ($codeCount.Count -ge 3 -and $crashes.Count -ge 3) {
            & $add 'RAM' 12 '블루스크린 코드가 매번 다름 (RAM 불량의 전형적 특징)'
            & $add 'PSU' 5 ''
        }
        & $find $(if ($crashes.Count -ge 2) { 'bad' } else { 'warn' }) 'BSOD' "블루스크린 $($crashes.Count) 회" ($parts -join ' · ') ([math]::Min(35, 10 * $crashes.Count))
    }

    # ---- 4) 그래픽카드
    $gpuCount = $gpuEv.Count
    if ($gpuCount -gt 0) {
        $tdr = @($gpuEv | Where-Object { (Get-Prop $_ 'Id') -eq 4101 -or (Get-Prop $_ 'Source') -eq 'LiveKernelEvent' }).Count
        & $add 'GPU_DRIVER' ([math]::Min(32, 4 * $gpuCount)) "그래픽 드라이버 응답 없음/오류 $gpuCount 건"
        & $add 'GPU_HW' ([math]::Min(18, 2 * $gpuCount)) "그래픽 드라이버 오류 $gpuCount 건"
        $xids = @($gpuEv | ForEach-Object { Get-Prop $_ 'Xid' } | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ } | Sort-Object -Unique)
        $detail = "그래픽 드라이버가 멈추거나 오류를 낸 기록입니다 (TDR $tdr 건)."
        foreach ($x in $xids) {
            if ($script:XidDb.ContainsKey($x)) {
                $xi = $script:XidDb[$x]
                foreach ($wk in $xi.W.Keys) { & $add $wk $xi.W[$wk] "NVIDIA Xid $x ($($xi.D))" }
                $detail += " Xid $x = $($xi.D)."
            }
        }
        $vramX = @($xids | Where-Object { $script:VramXids -contains $_ })
        if ($vramX.Count) {
            & $find 'bad' 'GPU_HW' 'VRAM(그래픽 메모리) 오류 신호' "NVIDIA 드라이버가 VRAM 오류(Xid $($vramX -join ', '))를 보고했습니다. VRAM 검사로 확인하세요." 30
        }
        if ($xids -contains 79) {
            & $find 'bad' 'GPU_HW' '그래픽카드가 연결에서 떨어짐 (Xid 79)' '전원 공급 불안정, 슬롯 접촉, 과열에서 주로 발생합니다. 보조전원 케이블과 파워를 먼저 점검하세요.' 25
        }
        & $find $(if ($gpuCount -ge 3) { 'bad' } else { 'warn' }) 'GPU_DRIVER' "그래픽 드라이버 오류 $gpuCount 건" $detail ([math]::Min(25, 4 * $gpuCount))
    }

    # ---- 5) 상관관계: 그래픽 오류 직후 꺼짐/블루스크린
    $gpuTimes = @($gpuEv | ForEach-Object { ConvertTo-Date (Get-Prop $_ 'T') } | Where-Object { $_ })
    $corr = 0
    foreach ($s in $powerLoss) {
        $t = ConvertTo-Date (Get-Prop $s 'T'); if (-not $t) { continue }
        foreach ($g in $gpuTimes) { $dm = ($t - $g).TotalMinutes; if ($dm -ge 0 -and $dm -le 15) { $corr++; break } }
    }
    if ($corr -gt 0) {
        & $add 'PSU' ([math]::Min(25, 10 * $corr)) "그래픽 오류 직후 15분 안에 꺼짐 $corr 회 (고부하 중 전력 부족 패턴)"
        & $add 'GPU_HW' ([math]::Min(25, 10 * $corr)) "그래픽 오류 직후 꺼짐 $corr 회"
        & $find 'bad' 'PSU' "그래픽 오류 직후 꺼짐 $corr 회" '그래픽카드가 오류를 낸 뒤 바로 전원이 꺼졌습니다. 게임 등 고부하에서 파워가 버티지 못하거나 그래픽카드 자체 문제일 가능성이 큽니다.' 10
    }

    # ---- 6) 드라이버 업데이트 직후 문제 시작
    $probT = New-Object 'System.Collections.Generic.List[datetime]'
    foreach ($g in $gpuTimes) { $probT.Add([datetime]$g) }
    foreach ($x in $crashes) { if ($x.T) { $probT.Add([datetime]$x.T) } }
    $inst = New-Object 'System.Collections.Generic.List[datetime]'
    if ($probT.Count -and $drvInst.Count) {
        $probT.Sort(); $firstProblem = $probT[0]
        foreach ($di in $drvInst) {
            $it = ConvertTo-Date (Get-Prop $di 'T')
            if ($null -ne $it -and $it -le $firstProblem -and ($firstProblem - $it).TotalDays -le 3) { $inst.Add($it) }
        }
        if ($inst.Count) {

            & $add 'GPU_DRIVER' 18 '그래픽 드라이버 설치 직후(3일 이내)부터 문제 시작'
            & $find 'warn' 'GPU_DRIVER' '그래픽 드라이버 설치 직후부터 문제 시작' "$((($inst | Sort-Object -Descending | Select-Object -First 1)).ToString('yyyy-MM-dd')) 드라이버 설치 후 문제가 시작됐습니다. 이전 버전으로 되돌려 보세요 (DDU 사용)." 5
        }
    }

    # ---- 7) WHEA 하드웨어 오류
    if ($whea.Count) {
        $w47 = @($whea | Where-Object { (Get-Prop $_ 'Id') -eq 47 }).Count
        $w17 = @($whea | Where-Object { (Get-Prop $_ 'Id') -eq 17 }).Count
        $w19 = @($whea | Where-Object { (Get-Prop $_ 'Id') -eq 19 }).Count
        $wF  = @($whea | Where-Object { (Get-Prop $_ 'Id') -eq 18 -or ((Get-Prop $_ 'Level') -le 2 -and (Get-Prop $_ 'Level') -ge 1) }).Count
        if ($w47) { & $add 'RAM' ([math]::Min(40, 10 * $w47)) "수정된 메모리 오류(WHEA 47) $w47 건" }
        if ($w17) {
            $gpuSlot = @($whea | Where-Object { (Get-Prop $_ 'Id') -eq 17 -and (Get-Prop $_ 'Comp') -match 'PCI' }).Count
            & $add 'GPU_HW' ([math]::Min(20, 2 * $w17)) "PCIe 오류(WHEA 17) $w17 건 — 그래픽카드/NVMe 슬롯"
            & $add 'DRIVER' ([math]::Min(6, $w17)) ''
        }
        if ($w19) { & $add 'CPU_OC' ([math]::Min(30, 8 * $w19)) "수정된 CPU 오류(WHEA 19) $w19 건" }
        if ($wF) { & $add 'CPU_OC' ([math]::Min(36, 12 * $wF)) "치명적 하드웨어 오류(WHEA 18) $wF 건"; & $add 'PSU' ([math]::Min(15, 5 * $wF)) "치명적 하드웨어 오류 $wF 건" }
        $d = "하드웨어가 스스로 보고한 오류입니다. 치명적 $wF · 메모리 $w47 · PCIe $w17 · CPU $w19 건."
        if ($w17 -and -not $wF -and -not $w47) { $d += ' PCIe 수정 오류만 있다면 대개 가벼운 문제입니다 (BIOS 에서 PCIe 세대를 Gen4/Gen3 로 고정하면 사라지는 경우가 많음).' }
        $lv = if ($wF -or $w47) { 'bad' } else { 'warn' }
        & $find $lv 'CPU_OC' "하드웨어 오류(WHEA) $($whea.Count) 건" $d ([math]::Min(25, 8 * $wF + 4 * $w47 + [math]::Min(5, $w17) + 3 * $w19))
    }

    # ---- 8) RAM
    $failMem = @($memDiag | Where-Object { Get-Prop $_ 'Failed' })
    if ($failMem.Count) {
        & $add 'RAM' 70 'Windows 메모리 진단에서 오류 발견'
        & $find 'bad' 'RAM' 'Windows 메모리 진단에서 RAM 오류 발견' 'RAM 불량이 거의 확실합니다. 한 개씩 꽂아 불량 모듈을 찾고 교체하세요.' 35
    }
    $xmp = $false
    foreach ($m in $dimms) {
        $cfg = [int](Get-Prop $m 'ConfiguredMHz'); $ddr = [string](Get-Prop $m 'DDR')
        if (($ddr -eq 'DDR4' -and $cfg -gt 3200) -or ($ddr -eq 'DDR5' -and $cfg -gt 5600) -or ($ddr -eq '' -and $cfg -gt 3200 -and $cfg -lt 4400)) { $xmp = $true }
    }
    if ($xmp) {
        $memish = $score['RAM'] -gt 0
        if ($memish) { & $add 'RAM' 10 'XMP/EXPO(메모리 오버클럭) 사용 중 + 메모리 관련 오류' }
        & $find 'info' 'RAM' 'XMP/EXPO(메모리 오버클럭) 사용 중으로 보임' '대부분 문제없지만, 불안정하면 BIOS 에서 XMP/EXPO 를 끄고 테스트해 보세요.' 0
    }
    $sizes = @($dimms | ForEach-Object { [int](Get-Prop $_ 'SizeGB') } | Sort-Object -Unique)
    $parts = @($dimms | ForEach-Object { [string](Get-Prop $_ 'Part') } | Where-Object { $_ } | Sort-Object -Unique)
    $isVM = [bool](Get-Prop $sys 'IsVM')
    if ($isVM) { & $find 'info' 'META' '가상 머신에서 실행됨' '가상 머신은 실제 하드웨어 정보를 보여 주지 않아 RAM/온도/그래픽카드 진단이 제한됩니다.' 0 }
    if (-not $isVM -and $dimms.Count -ge 2 -and ($sizes.Count -gt 1 -or $parts.Count -gt 1)) {

        & $add 'RAM' 4 '서로 다른 RAM 모듈 혼용'
        & $find 'info' 'RAM' '서로 다른 RAM 모듈을 섞어 사용 중' '용량/제품이 다른 RAM 혼용은 불안정의 원인이 될 수 있습니다.' 0
    }

    # ---- 9) 디스크
    foreach ($dk in $disks) {
        $h = [string](Get-Prop $dk 'Health')
        if ($h -and $h -ne 'Healthy' -and $h -ne '0') {
            & $add 'DISK' 50 "디스크 상태 이상: $(Get-Prop $dk 'Name')"
            & $find 'bad' 'DISK' "디스크 상태 이상: $(Get-Prop $dk 'Name')" "상태: $h — 즉시 백업하세요." 30
        }
        $we = Get-Prop $dk 'WearPct'
        if ($null -ne $we -and [int]$we -ge 90) { & $add 'DISK' 15 'SSD 수명 거의 소진'; & $find 'warn' 'DISK' "SSD 수명 소진 ($(Get-Prop $dk 'Name') $we%)" '교체를 준비하세요.' 10 }
        $re = Get-Prop $dk 'ReadErr'
        if ($null -ne $re -and [int64]$re -gt 0) { & $add 'DISK' 15 "복구 불가 읽기 오류 $re"; & $find 'warn' 'DISK' "디스크 읽기 오류 ($(Get-Prop $dk 'Name'))" "복구되지 않은 읽기 오류 $re 회." 8 }
        $tc = Get-Prop $dk 'TempC'
        if ($null -ne $tc -and [int]$tc -ge 70) { & $add 'THERMAL' 6 'SSD 고온'; & $find 'warn' 'DISK' "SSD 온도 높음 ($tc °C)" 'NVMe 방열판/공기 흐름을 확인하세요.' 3 }
    }
    if ($diskEv.Count) {
        & $add 'DISK' ([math]::Min(30, 3 * $diskEv.Count)) "디스크 오류 기록 $($diskEv.Count) 건"
        & $find $(if ($diskEv.Count -ge 5) { 'bad' } else { 'warn' }) 'DISK' "디스크 오류 기록 $($diskEv.Count) 건" '디스크/컨트롤러 오류는 멈춤·블루스크린의 원인이 됩니다. 케이블·펌웨어·SMART 를 확인하세요.' ([math]::Min(20, 3 * $diskEv.Count))
    }

    # ---- 10) 온도
    foreach ($g in $nv) {
        $t = Get-Prop $g 'Temp'; $u = Get-Prop $g 'Util'
        if ($null -ne $t -and [double]$t -ge 83) {
            $idle = ($null -ne $u -and [double]$u -lt 30)
            & $add 'THERMAL' $(if ($idle) { 30 } else { 12 }) "그래픽카드 $t °C$(if ($idle) { ' (저부하인데 높음)' })"
            & $find $(if ($idle) { 'bad' } else { 'warn' }) 'THERMAL' "그래픽카드 온도 높음: $t °C" $(if ($idle) { '거의 쉬는 상태인데 온도가 높습니다. 팬 고장이나 먼지 막힘을 확인하세요.' } else { '부하 중 온도입니다. 85°C 이상이 계속되면 쿨링을 개선하세요.' }) $(if ($idle) { 15 } else { 5 })
        }
    }
    foreach ($t in $therm) { if ([double]$t -ge 90) { & $add 'THERMAL' 15 "메인보드 온도 센서 $t °C"; & $find 'warn' 'THERMAL' "메인보드 온도 센서 $t °C" 'HWiNFO 로 CPU 온도를 확인하세요.' 8; break } }

    # ---- 11) 오버클럭 도구, 오래된 드라이버
    if ($oc.Count -and ($crashes.Count + $plCount + $gpuCount) -gt 0) {
        & $add 'CPU_OC' 6 "오버클럭 도구 실행 중: $($oc -join ', ')"; & $add 'GPU_HW' 6 "오버클럭 도구 실행 중: $($oc -join ', ')"
        & $find 'info' 'CPU_OC' "오버클럭/튜닝 도구 실행 중: $($oc -join ', ')" '오버클럭·언더볼트 설정을 기본값으로 돌려 테스트해 보세요.' 0
    }
    $now = ConvertTo-Date (Get-Prop $meta 'Created'); if (-not $now) { $now = Get-Date }
    foreach ($g in $gpus) {
        $dd = ConvertTo-Date (Get-Prop $g 'DriverDate')
        if ($dd -and ($now - $dd).TotalDays -gt 365 -and (Get-Prop $g 'Vendor') -in 'NVIDIA', 'AMD') {
            if ($gpuCount -gt 0) { & $add 'GPU_DRIVER' 8 '그래픽 드라이버가 1년 이상 오래됨' }
            & $find 'info' 'GPU_DRIVER' "그래픽 드라이버가 오래됨 ($($dd.ToString('yyyy-MM-dd')))" "$(Get-Prop $g 'Name') 드라이버를 최신 안정 버전으로 업데이트하세요." 2
        }
    }
    $biosD = ConvertTo-Date (Get-Prop $sys 'BIOSDate')
    $cpuName = [string](Get-Prop $sys 'CPU')
    if ($cpuName -match 'i[579]-1[34]\d{3}K?F?' ) {
        & $find 'info' 'CPU_OC' 'Intel 13·14세대 CPU' 'BIOS 를 최신(마이크로코드 0x12B 이상 포함)으로 업데이트하세요. 구버전 BIOS 는 CPU 불안정/열화 문제가 알려져 있습니다.' 0
        if ($crashes.Count -or $whea.Count) { & $add 'CPU_OC' 10 'Intel 13·14세대 CPU + 크래시 (알려진 불안정 이슈)' }
    }
    if ($biosD -and ($now - $biosD).TotalDays -gt 365 * 3 -and ($crashes.Count + $whea.Count) -gt 0) {
        & $find 'info' 'CPU_OC' "메인보드 BIOS 가 오래됨 ($($biosD.ToString('yyyy-MM-dd')))" '안정성 개선이 포함된 최신 BIOS 를 확인하세요.' 0
    }
    if ((Get-Prop $sys 'FastStartup') -eq 1 -and ($plCount + $crashes.Count) -gt 0) {
        & $find 'info' 'DRIVER' '빠른 시작(Fast Startup) 켜짐' '종료/부팅 관련 문제가 있으면 제어판 > 전원 옵션에서 "빠른 시작 켜기"를 꺼 보세요.' 0
    }
    $errs = @(Get-Arr (Get-Prop $Data 'Errors'))
    if (-not (Get-Prop $meta 'IsAdmin')) { & $find 'info' 'META' '관리자 권한 없이 실행됨' '일부 기록(덤프 파일 등)을 읽지 못했을 수 있습니다. 원클릭검사.bat 으로 실행하세요.' 0 }
    if ($errs.Count) { & $find 'info' 'META' "일부 항목 수집 실패 $($errs.Count) 건" (($errs | ForEach-Object { "$(Get-Prop $_ 'Step'): $(Get-Prop $_ 'Msg')" }) -join ' / ') 0 }

    # ---- 결과 정리
    $ranked = @()
    foreach ($k in $script:Causes.Keys) {
        $v = [math]::Round([math]::Min(100, $score[$k]))
        if ($v -ge 10) {
            $conf = if ($v -ge 60) { '높음' } elseif ($v -ge 30) { '중간' } else { '낮음' }
            $ranked += [ordered]@{ Key = $k; Name = $script:Causes[$k].Name; Icon = $script:Causes[$k].Icon; Score = $v; Confidence = $conf; Reasons = @($why[$k]); Steps = $script:Playbook[$k] }
        }
    }
    $ranked = @($ranked | Sort-Object { - $_.Score })

    $penalty = 0; foreach ($f in $findings) { $penalty += [int]$f.Penalty }
    # 감점이 쌓일수록 완만하게 줄어드는 곡선 (문제 하나로 0점이 되지 않도록)
    $health = [int][math]::Round(100 * [math]::Exp(-$penalty / 90.0))
    $grade = if ($health -ge 90) { '양호' } elseif ($health -ge 70) { '주의' } elseif ($health -ge 40) { '점검 필요' } else { '위험' }
    $order = @{ bad = 0; warn = 1; info = 2; ok = 3 }
    $sorted = @($findings | Sort-Object @{ e = { $order[$_.Level] } }, @{ e = { - $_.Penalty } })
    if (@($sorted | Where-Object { $_.Level -in 'bad', 'warn' }).Count -eq 0) {
        $sorted = @([ordered]@{ Level = 'ok'; Category = 'OK'; Title = "최근 $days 일간 심각한 문제 기록 없음"; Detail = '증상이 계속된다면 VRAM 검사와 RAM 검사로 직접 부하 테스트를 해 보세요. 기록이 남지 않는 순간 정전(파워 문제)일 수도 있습니다.'; Penalty = 0 }) + $sorted
    }

    return [ordered]@{
        Health = $health; Grade = $grade; Causes = $ranked; Findings = $sorted
        Counts = [ordered]@{ PowerLoss = $plCount; Bsod = $crashes.Count; Gpu = $gpuCount; Whea = $whea.Count; Disk = $diskEv.Count; Correlated = $corr }
        CrashCodes = $codeCount
    }
}

# =====================================================================
#  보고서
# =====================================================================
function Get-TimelineSvg($Data) {
    $days = [int](Get-Prop (Get-Prop $Data 'Meta') 'Days'); if ($days -le 0) { $days = 30 }
    $end = (ConvertTo-Date (Get-Prop (Get-Prop $Data 'Meta') 'Created')); if (-not $end) { $end = Get-Date }
    $end = $end.Date
    $series = [ordered]@{
        '꺼짐' = @{ C = 'var(--c-psu)'; T = @(Get-Arr (Get-Prop $Data 'Shutdowns') | ForEach-Object { Get-Prop $_ 'T' }) }
        '블루스크린' = @{ C = 'var(--c-bsod)'; T = @(Get-Arr (Get-Prop $Data 'BugChecks') | ForEach-Object { Get-Prop $_ 'T' }) }
        '그래픽' = @{ C = 'var(--c-gpu)'; T = @(Get-Arr (Get-Prop $Data 'GpuEvents') | ForEach-Object { Get-Prop $_ 'T' }) }
        'WHEA' = @{ C = 'var(--c-whea)'; T = @(Get-Arr (Get-Prop $Data 'Whea') | ForEach-Object { Get-Prop $_ 'T' }) }
        '디스크' = @{ C = 'var(--c-disk)'; T = @(Get-Arr (Get-Prop $Data 'DiskEvents') | ForEach-Object { Get-Prop $_ 'T' }) }
    }
    $bins = @{}
    $max = 1
    foreach ($name in $series.Keys) {
        $arr = New-Object int[] $days
        foreach ($t in $series[$name].T) {
            $dt = ConvertTo-Date $t; if (-not $dt) { continue }
            $idx = $days - 1 - [int]($end - $dt.Date).TotalDays
            if ($idx -ge 0 -and $idx -lt $days) { $arr[$idx]++ }
        }
        $bins[$name] = $arr
    }
    for ($i = 0; $i -lt $days; $i++) { $sum = 0; foreach ($n in $series.Keys) { $sum += $bins[$n][$i] }; if ($sum -gt $max) { $max = $sum } }
    $W = 720; $Hh = 150; $pad = 26; $bw = ($W - $pad - 4) / $days
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg viewBox='0 0 $W $($Hh + 24)' class='tl' role='img' aria-label='날짜별 문제 기록'>")
    [void]$sb.Append("<line x1='$pad' y1='$Hh' x2='$W' y2='$Hh' class='axis'/>")
    [void]$sb.Append("<text x='$($pad - 6)' y='12' class='lbl' text-anchor='end'>$max</text><text x='$($pad - 6)' y='$Hh' class='lbl' text-anchor='end'>0</text>")
    $inv = [Globalization.CultureInfo]::InvariantCulture
    for ($i = 0; $i -lt $days; $i++) {
        $y = $Hh; $x = $pad + $i * $bw
        $day = $end.AddDays($i - $days + 1)
        $tip = @()
        foreach ($n in $series.Keys) {
            $v = $bins[$n][$i]; if ($v -le 0) { continue }
            $h = ($Hh - 14) * $v / $max; $y -= $h
            $tip += "$n $v"
            [void]$sb.Append(("<rect x='{0}' y='{1}' width='{2}' height='{3}' rx='1.5' fill='{4}'/>" -f $x.ToString('0.#', $inv), $y.ToString('0.#', $inv), ([math]::Max(1, $bw - 2)).ToString('0.#', $inv), $h.ToString('0.#', $inv), $series[$n].C))
        }
        if ($tip.Count) { [void]$sb.Append(("<rect x='{0}' y='0' width='{1}' height='{2}' fill='transparent'><title>{3}: {4}</title></rect>" -f $x.ToString('0.#', $inv), $bw.ToString('0.#', $inv), $Hh, $day.ToString('MM-dd'), ($tip -join ', '))) }
        if ($i % [math]::Max(1, [int]($days / 6)) -eq 0 -or $i -eq $days - 1) { [void]$sb.Append(("<text x='{0}' y='{1}' class='lbl'>{2}</text>" -f $x.ToString('0.#', $inv), ($Hh + 16), $day.ToString('MM-dd'))) }
    }
    [void]$sb.Append('</svg><div class="legend">')
    foreach ($n in $series.Keys) { [void]$sb.Append("<span><i style='background:$($series[$n].C)'></i>$n</span>") }
    [void]$sb.Append('</div>')
    return $sb.ToString()
}

function ConvertTo-HtmlTable($rows, [string[]]$cols, [string[]]$heads, [string]$empty = '기록 없음 ✓') {
    $rows = @(Get-Arr $rows)
    if ($rows.Count -eq 0) { return "<p class='none'>$(HtmlEnc $empty)</p>" }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<div class="tw"><table><thead><tr>')
    foreach ($h in $heads) { [void]$sb.Append("<th>$(HtmlEnc $h)</th>") }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($r in $rows) {
        [void]$sb.Append('<tr>')
        foreach ($c in $cols) {
            $v = Get-Prop $r $c
            if ($v -is [bool]) { $v = $(if ($v) { '예' } else { '' }) }
            if ($c -eq 'T' -and $v) { $v = ([string]$v).Replace('T', ' ').Substring(0, [math]::Min(16, ([string]$v).Length)) }
            [void]$sb.Append("<td>$(HtmlEnc $v)</td>")
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table></div>')
    return $sb.ToString()
}

function Get-SummaryText($Data, $Dx) {
    $s = Get-Prop $Data 'System'; $m = Get-Prop $Data 'Meta'
    $L = New-Object System.Collections.ArrayList
    [void]$L.Add("[$($script:AppName) v$($script:AppVersion)] $(([string](Get-Prop $m 'Created')).Replace('T',' ')) · 최근 $(Get-Prop $m 'Days')일")
    [void]$L.Add("상태 점수: $($Dx.Health)/100 ($($Dx.Grade))")
    [void]$L.Add("PC: $(Get-Prop $s 'CPU') / RAM $(Get-Prop $s 'RamGB')GB / $((@(Get-Arr (Get-Prop $Data 'Gpus')) | ForEach-Object { Get-Prop $_ 'Name' }) -join ', ')")
    [void]$L.Add("OS: $(Get-Prop $s 'OS') (빌드 $(Get-Prop $s 'Build')) · 보드: $(Get-Prop $s 'Board') BIOS $(Get-Prop $s 'BIOS')")
    $c = $Dx.Counts
    [void]$L.Add("기록: 갑자기꺼짐 $($c.PowerLoss) · 블루스크린 $($c.Bsod) · 그래픽오류 $($c.Gpu) · WHEA $($c.Whea) · 디스크 $($c.Disk)")
    if ($Dx.CrashCodes.Count) { [void]$L.Add("블루스크린 코드: $((($Dx.CrashCodes.Keys | ForEach-Object { "$_ x$($Dx.CrashCodes[$_])" }) -join ', '))") }
    if (@($Dx.Causes).Count) {
        [void]$L.Add('의심 원인:')
        $i = 0; foreach ($x in $Dx.Causes | Select-Object -First 3) { $i++; [void]$L.Add("  $i. $($x.Name) — $($x.Score)점(가능성 $($x.Confidence)): $(@($x.Reasons | Select-Object -First 2) -join '; ')") }
    }
    return ($L -join "`r`n")
}

function New-HtmlReport {
    param([Parameter(Mandatory)]$Data, [Parameter(Mandatory)]$Dx)
    $m = Get-Prop $Data 'Meta'; $s = Get-Prop $Data 'System'
    $gradeCls = if ($Dx.Health -ge 90) { 'ok' } elseif ($Dx.Health -ge 70) { 'warn' } else { 'bad' }
    $circ = 2 * [math]::PI * 52
    $dash = ($circ * $Dx.Health / 100).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
    $circS = $circ.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)

    # 원인 Top
    $causeHtml = ''
    if (@($Dx.Causes).Count -eq 0) {
        $causeHtml = "<p class='none'>뚜렷한 원인 후보가 없습니다.</p>"
    } else {
        $rank = 0
        foreach ($c in $Dx.Causes | Select-Object -First 4) {
            $rank++
            $reasons = (@($c.Reasons) | Select-Object -First 4 | ForEach-Object { "<li>$(HtmlEnc $_)</li>" }) -join ''
            $steps = (@($c.Steps) | ForEach-Object { "<li>$(HtmlEnc $_)</li>" }) -join ''
            $open = if ($rank -eq 1) { ' open' } else { '' }
            $causeHtml += @"
<details class="cause"$open><summary><span class="rk">$rank</span><span class="cn">$(HtmlEnc $c.Icon) $(HtmlEnc $c.Name)</span><span class="bar"><i style="width:$($c.Score)%"></i></span><span class="sc">$($c.Score)</span><span class="cf cf-$(HtmlEnc $c.Confidence)">가능성 $(HtmlEnc $c.Confidence)</span></summary>
<div class="cb"><div><h4>근거</h4><ul>$reasons</ul></div><div><h4>해결 순서</h4><ol>$steps</ol></div></div></details>
"@
        }
    }
    $findHtml = (@($Dx.Findings) | ForEach-Object {
        $tag = switch ($_.Level) { 'bad' { '위험' } 'warn' { '주의' } 'info' { '참고' } default { '정상' } }
        "<div class='f $($_.Level)'><span class='tag'>$tag</span><div><b>$(HtmlEnc $_.Title)</b><p>$(HtmlEnc $_.Detail)</p></div></div>"
    }) -join "`n"

    $gpuRows = @(Get-Arr (Get-Prop $Data 'Gpus') | ForEach-Object { [ordered]@{ Name = (Get-Prop $_ 'Name'); Vram = $(if (Get-Prop $_ 'VramGB') { "$(Get-Prop $_ 'VramGB') GB" } else { '' }); Driver = (Get-Prop $_ 'Driver'); DD = ([string](Get-Prop $_ 'DriverDate')).Split('T')[0]; St = (Get-Prop $_ 'Status') } })
    $nvRows = @(Get-Arr (Get-Prop $Data 'NvSmi') | ForEach-Object { [ordered]@{ Name = (Get-Prop $_ 'Name'); Temp = "$(Get-Prop $_ 'Temp') °C"; Util = "$(Get-Prop $_ 'Util') %"; Mem = "$(Get-Prop $_ 'MemUsedMB') / $(Get-Prop $_ 'MemTotalMB') MB"; Pw = "$(Get-Prop $_ 'PowerW') / $(Get-Prop $_ 'PowerLimitW') W"; Clk = "$(Get-Prop $_ 'ClockMHz') MHz" } })
    $shutRows = @(Get-Arr (Get-Prop $Data 'Shutdowns') | ForEach-Object {
        $c = Format-BugCode (Get-Prop $_ 'Code')
        [ordered]@{ T = (Get-Prop $_ 'T'); K = $(if ($c) { "블루스크린 $c" } else { '전원 끊김/멈춤' }); W = $(if ($c) { (Get-BugInfo $c).D } else { '파워·과열·전원 접촉 의심' }); B = (Get-Prop $_ 'PowerButton') }
    })
    $bugRows = @(Get-Arr (Get-Prop $Data 'BugChecks') | ForEach-Object { $bi = Get-BugInfo (Get-Prop $_ 'Code'); [ordered]@{ T = (Get-Prop $_ 'T'); C = (Get-Prop $_ 'Code'); N = $bi.N; D = $bi.D } })
    $dumpRows = @(Get-Arr (Get-Prop $Data 'Dumps') | ForEach-Object { $bi = Get-BugInfo (Get-Prop $_ 'Code'); [ordered]@{ T = (Get-Prop $_ 'T'); Name = (Get-Prop $_ 'Name'); C = (Get-Prop $_ 'Code'); N = $(if (Get-Prop $_ 'Code') { $bi.N } else { '' }); KB = "$(Get-Prop $_ 'SizeKB') KB" } })
    $dimmRows = @(Get-Arr (Get-Prop $Data 'Dimms') | ForEach-Object { [ordered]@{ Slot = (Get-Prop $_ 'Slot'); Sz = "$(Get-Prop $_ 'SizeGB') GB"; Ddr = (Get-Prop $_ 'DDR'); Sp = "$(Get-Prop $_ 'ConfiguredMHz') / $(Get-Prop $_ 'RatedMHz')"; Mk = (Get-Prop $_ 'Maker'); Pt = (Get-Prop $_ 'Part') } })
    $diskRows = @(Get-Arr (Get-Prop $Data 'Disks') | ForEach-Object { [ordered]@{ Name = (Get-Prop $_ 'Name'); Ty = "$(Get-Prop $_ 'Media') $(Get-Prop $_ 'Bus')"; Sz = "$(Get-Prop $_ 'SizeGB') GB"; He = (Get-Prop $_ 'Health'); Tc = $(if ($null -ne (Get-Prop $_ 'TempC')) { "$(Get-Prop $_ 'TempC') °C" }); We = $(if ($null -ne (Get-Prop $_ 'WearPct')) { "$(Get-Prop $_ 'WearPct') %" }); Re = (Get-Prop $_ 'ReadErr'); Ph = (Get-Prop $_ 'PowerOnHours') } })
    $memD = @(Get-Arr (Get-Prop $Data 'MemDiag'))
    $summary = Get-SummaryText $Data $Dx
    $c = $Dx.Counts

    $css = @'
:root{--bg:#f5f6f8;--fg:#14181d;--muted:#5b6570;--line:#dfe3e8;--card:#fff;--soft:#eef1f4;--bad:#c62828;--warn:#a85d00;--ok:#2e7d32;--info:#3b6fd4;--accent:#2457c5;
--c-psu:#e0533d;--c-bsod:#2457c5;--c-gpu:#8e44ad;--c-whea:#d49a00;--c-disk:#16857a}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){--bg:#0f1114;--fg:#e9edf1;--muted:#9aa4ae;--line:#2a2f36;--card:#171a1f;--soft:#1f242a;--bad:#ff6b6b;--warn:#ffb74d;--ok:#66bb6a;--info:#7aa7ff;--accent:#7aa7ff}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.6 "Malgun Gothic","맑은 고딕","Segoe UI",system-ui,sans-serif}
main{max-width:980px;margin:0 auto;padding:28px 16px 80px}
header{display:flex;gap:24px;align-items:center;flex-wrap:wrap;background:var(--card);border:1px solid var(--line);border-radius:14px;padding:20px}
.ring{position:relative;width:128px;height:128px;flex:none}.ring svg{transform:rotate(-90deg)}.ring circle{fill:none;stroke-width:12}
.ring .bg{stroke:var(--soft)}.ring .fg{stroke-linecap:round}.ring.ok .fg{stroke:var(--ok)}.ring.warn .fg{stroke:var(--warn)}.ring.bad .fg{stroke:var(--bad)}
.ring b{position:absolute;inset:0;display:grid;place-items:center;font-size:34px;line-height:1}.ring small{position:absolute;left:0;bottom:26px;width:100%;text-align:center;color:var(--muted);font-size:12px}
.hd h1{margin:0;font-size:22px}.hd .grade{font-size:18px;font-weight:700;margin:4px 0}.sub{color:var(--muted);font-size:13px;margin:0}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:10px;margin:16px 0}
.stat{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px}.stat b{display:block;font-size:24px;line-height:1.2}.stat span{color:var(--muted);font-size:12px}
.stat.hot b{color:var(--bad)}
h2{font-size:17px;margin:30px 0 10px;display:flex;align-items:center;gap:8px}
.cause{background:var(--card);border:1px solid var(--line);border-radius:12px;margin:8px 0;overflow:hidden}
.cause summary{display:grid;grid-template-columns:28px minmax(120px,1.2fr) 2fr 40px auto;gap:10px;align-items:center;padding:12px 14px;cursor:pointer;list-style:none}
.cause summary::-webkit-details-marker{display:none}.rk{width:24px;height:24px;border-radius:50%;background:var(--soft);display:grid;place-items:center;font-weight:700;font-size:13px}
.cause:first-of-type .rk{background:var(--accent);color:#fff}.cn{font-weight:700}.bar{height:8px;background:var(--soft);border-radius:4px;overflow:hidden}.bar i{display:block;height:100%;background:var(--accent);border-radius:4px}
.sc{font-weight:700;text-align:right}.cf{font-size:12px;padding:2px 8px;border-radius:999px;background:var(--soft);white-space:nowrap}.cf-높음{color:var(--bad)}.cf-중간{color:var(--warn)}
.cb{display:grid;grid-template-columns:1fr 1fr;gap:16px;padding:0 16px 14px;border-top:1px solid var(--line)}.cb h4{margin:12px 0 4px;font-size:13px;color:var(--muted)}.cb ul,.cb ol{margin:0;padding-left:20px}
.f{display:flex;gap:12px;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 14px;margin:8px 0}.f p{margin:2px 0 0;color:var(--muted)}
.tag{flex:none;font-size:12px;font-weight:700;padding:2px 8px;border-radius:6px;height:fit-content;background:var(--soft)}
.f.bad .tag{background:var(--bad);color:#fff}.f.warn .tag{background:var(--warn);color:#fff}.f.ok .tag{background:var(--ok);color:#fff}.f.info .tag{color:var(--info)}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px}
.tl{width:100%;height:auto}.tl .axis{stroke:var(--line)}.tl .lbl{fill:var(--muted);font-size:10px}
.legend{display:flex;gap:14px;flex-wrap:wrap;font-size:12px;color:var(--muted);margin-top:4px}.legend i{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:4px;vertical-align:-1px}
details.sec{background:var(--card);border:1px solid var(--line);border-radius:12px;margin:8px 0}details.sec>summary{padding:12px 14px;cursor:pointer;font-weight:700}details.sec>div{padding:0 14px 14px}
.cnt{font-weight:400;color:var(--muted);font-size:13px;margin-left:6px}
.tw{overflow-x:auto}table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted);font-weight:600;white-space:nowrap}
.none{color:var(--ok);margin:6px 0}.kv td:first-child{color:var(--muted);white-space:nowrap;width:120px}
pre{white-space:pre-wrap;background:var(--soft);border-radius:8px;padding:12px;font:12px/1.6 Consolas,monospace;margin:0}
.btns{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}button{font:inherit;border:1px solid var(--line);background:var(--card);color:var(--fg);border-radius:8px;padding:8px 14px;cursor:pointer}button.pri{background:var(--accent);color:#fff;border-color:var(--accent)}
footer{margin-top:40px;color:var(--muted);font-size:12px}
.cmp{border-radius:12px;padding:12px 16px;margin:16px 0;border:1px solid var(--line);background:var(--card)}.cmp p{margin:2px 0 0;color:var(--muted)}
.cmp.ok{border-left:5px solid var(--ok)}.cmp.bad{border-left:5px solid var(--bad)}

@media (max-width:640px){.cause summary{grid-template-columns:24px 1fr 36px;}.cause .bar,.cause .cf{display:none}.cb{grid-template-columns:1fr}header{padding:16px}}
@media print{button,.btns{display:none}details{break-inside:avoid}details:not([open])>*:not(summary){display:block}body{background:#fff}}
'@
    $js = @'
function copySummary(){var t=document.getElementById('sumtext').innerText;
 if(navigator.clipboard){navigator.clipboard.writeText(t).then(function(){flash('복사했습니다')},fallback)}else{fallback()}
 function fallback(){var r=document.createRange();r.selectNodeContents(document.getElementById('sumtext'));var s=getSelection();s.removeAllRanges();s.addRange(r);try{document.execCommand('copy');flash('복사했습니다')}catch(e){flash('Ctrl+C 로 복사하세요')}}}
function flash(m){var b=document.getElementById('cpbtn');var o=b.textContent;b.textContent=m;setTimeout(function(){b.textContent=o},1600)}
function openAll(v){document.querySelectorAll('details').forEach(function(d){d.open=v})}
'@
    $cmpHtml = ''
    $pv = $Dx['Previous']
    if ($pv) {
        $pvT = ([string]$pv.Created).Replace('T', ' ').Substring(0, 16)
        $lbl = [ordered]@{ PowerLoss = '갑자기 꺼짐'; Bsod = '블루스크린'; Gpu = '그래픽 오류'; Whea = 'WHEA'; Disk = '디스크 오류' }
        if ($pv.NewTotal -eq 0) {
            $cmpHtml = "<div class='cmp ok'><b>지난 검사($pvT · $($pv.Health)점) 이후 새로 생긴 문제 없음 ✓</b><p>조치가 효과를 보고 있는 것으로 보입니다. 며칠 더 사용한 뒤 다시 검사해 확인하세요.</p></div>"
        } else {
            $parts = @(); foreach ($k in $lbl.Keys) { if ($pv.New[$k]) { $parts += "$($lbl[$k]) $($pv.New[$k])" } }
            $cmpHtml = "<div class='cmp bad'><b>지난 검사($pvT · $($pv.Health)점) 이후 새 문제 $($pv.NewTotal) 건</b><p>$(HtmlEnc ($parts -join ' · ')) — 문제가 아직 해결되지 않았습니다. 아래 1순위 원인의 다음 단계를 진행하세요.</p></div>"
        }
    }
    $memDiagText = if ($memD.Count) { $x = $memD[0]; "$(([string](Get-Prop $x 'T')).Replace('T',' ')) — $(if (Get-Prop $x 'Failed') { '❌ 오류 발견' } else { '✅ 오류 없음' })" } else { '실행 기록 없음 (메뉴에서 실행 가능)' }

    $html = @"
<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>PC 진단 보고서</title><style>$css</style></head><body><main>
<header>
 <div class="ring $gradeCls"><svg width="128" height="128" viewBox="0 0 128 128"><circle class="bg" cx="64" cy="64" r="52"/><circle class="fg" cx="64" cy="64" r="52" stroke-dasharray="$dash $circS"/></svg><b>$($Dx.Health)</b><small>/ 100</small></div>
 <div class="hd"><h1>PC 진단 보고서</h1><div class="grade">상태: $(HtmlEnc $Dx.Grade)</div>
 <p class="sub">$(HtmlEnc (Get-Prop $m 'Computer')) · $(HtmlEnc ([string](Get-Prop $m 'Created')).Replace('T',' ')) · 최근 $(Get-Prop $m 'Days')일 분석 · v$(HtmlEnc (Get-Prop $m 'Version'))</p>
 <p class="sub">$(HtmlEnc (Get-Prop $s 'CPU')) · RAM $(HtmlEnc (Get-Prop $s 'RamGB'))GB · $(HtmlEnc ((@(Get-Arr (Get-Prop $Data 'Gpus')) | ForEach-Object { Get-Prop $_ 'Name' }) -join ', '))</p></div>
</header>
<div class="stats">
 <div class="stat$(if ($c.PowerLoss) { ' hot' })"><b>$($c.PowerLoss)</b><span>갑자기 꺼짐</span></div>
 <div class="stat$(if ($c.Bsod) { ' hot' })"><b>$($c.Bsod)</b><span>블루스크린</span></div>
 <div class="stat$(if ($c.Gpu) { ' hot' })"><b>$($c.Gpu)</b><span>그래픽 드라이버 오류</span></div>
 <div class="stat$(if ($c.Whea) { ' hot' })"><b>$($c.Whea)</b><span>하드웨어 오류(WHEA)</span></div>
 <div class="stat$(if ($c.Disk) { ' hot' })"><b>$($c.Disk)</b><span>디스크 오류</span></div>
</div>

$cmpHtml
<h2>가장 의심되는 원인</h2>
$causeHtml
<p class="sub">점수는 기록된 증거의 강도입니다 (100 = 매우 강함). 해결 순서대로 하나씩 시도하고 다시 검사해 보세요.</p>

<h2>발견 사항</h2>
$findHtml

<h2>날짜별 기록</h2>
<div class="card">$(Get-TimelineSvg $Data)</div>

<h2>A/S · 상담용 요약</h2>
<div class="card"><pre id="sumtext">$(HtmlEnc $summary)</pre>
<div class="btns"><button class="pri" id="cpbtn" onclick="copySummary()">요약 복사</button><button onclick="openAll(true);window.print()">인쇄 / PDF 저장</button><button onclick="openAll(true)">모두 펼치기</button></div></div>

<h2>상세 기록</h2>
<details class="sec"><summary>시스템 정보</summary><div><table class="kv">
<tr><td>Windows</td><td>$(HtmlEnc (Get-Prop $s 'OS')) (빌드 $(HtmlEnc (Get-Prop $s 'Build')))</td></tr>
<tr><td>모델</td><td>$(HtmlEnc (Get-Prop $s 'Model'))</td></tr>
<tr><td>CPU</td><td>$(HtmlEnc (Get-Prop $s 'CPU')) ($(HtmlEnc (Get-Prop $s 'Cores'))코어 / $(HtmlEnc (Get-Prop $s 'Threads'))스레드)</td></tr>
<tr><td>메인보드</td><td>$(HtmlEnc (Get-Prop $s 'Board')) · BIOS $(HtmlEnc (Get-Prop $s 'BIOS')) ($(HtmlEnc ([string](Get-Prop $s 'BIOSDate')).Split('T')[0]))</td></tr>
<tr><td>마지막 부팅</td><td>$(HtmlEnc ([string](Get-Prop $s 'LastBoot')).Replace('T',' '))</td></tr>
<tr><td>전원 관리</td><td>$(HtmlEnc (Get-Prop $s 'PowerPlan')) · 빠른 시작 $(if ((Get-Prop $s 'FastStartup') -eq 1) { '켜짐' } elseif ((Get-Prop $s 'FastStartup') -eq 0) { '꺼짐' } else { '-' })</td></tr>
</table></div></details>
<details class="sec"><summary>그래픽카드<span class="cnt">$($gpuRows.Count)</span></summary><div>
$(ConvertTo-HtmlTable $gpuRows @('Name','Vram','Driver','DD','St') @('이름','VRAM','드라이버','드라이버 날짜','상태'))
$(if ($nvRows.Count) { '<h4>NVIDIA 실시간 상태</h4>' + (ConvertTo-HtmlTable $nvRows @('Name','Temp','Util','Mem','Pw','Clk') @('이름','온도','사용률','VRAM','전력','클럭')) })
</div></details>
<details class="sec"$(if ($c.PowerLoss -or $shutRows.Count) { ' open' })><summary>갑작스런 종료 (Kernel-Power 41)<span class="cnt">$($shutRows.Count)</span></summary><div>
$(ConvertTo-HtmlTable $shutRows @('T','K','W','B') @('시간','종류','추정','전원버튼'))
<p class="sub">예기치 않은 종료(이벤트 6008): $(@(Get-Arr (Get-Prop $Data 'Unexpected')).Count) 건</p></div></details>
<details class="sec"$(if ($bugRows.Count) { ' open' })><summary>블루스크린<span class="cnt">$($bugRows.Count)</span></summary><div>
$(ConvertTo-HtmlTable $bugRows @('T','C','N','D') @('시간','코드','이름','설명'))
<h4>덤프 파일</h4>$(ConvertTo-HtmlTable $dumpRows @('T','Name','C','N','KB') @('시간','파일','코드','이름','크기') '덤프 파일 없음')
</div></details>
<details class="sec"$(if ($c.Gpu) { ' open' })><summary>그래픽 드라이버 오류 (TDR · Xid)<span class="cnt">$($c.Gpu)</span></summary><div>
$(ConvertTo-HtmlTable (@(Get-Arr (Get-Prop $Data 'GpuEvents')) | Select-Object -First 80) @('T','Source','Id','Xid','Msg') @('시간','출처','ID','Xid','내용'))</div></details>
<details class="sec"><summary>하드웨어 오류 (WHEA)<span class="cnt">$($c.Whea)</span></summary><div>
$(ConvertTo-HtmlTable (@(Get-Arr (Get-Prop $Data 'Whea')) | Select-Object -First 80) @('T','Id','Comp','Msg') @('시간','ID','구성요소','내용'))</div></details>
<details class="sec"><summary>RAM<span class="cnt">$($dimmRows.Count)</span></summary><div>
$(ConvertTo-HtmlTable $dimmRows @('Slot','Sz','Ddr','Sp','Mk','Pt') @('슬롯','용량','종류','속도 MHz (현재/정격)','제조사','모델'))
<p class="sub">Windows 메모리 진단: $(HtmlEnc $memDiagText)</p></div></details>
<details class="sec"><summary>저장장치<span class="cnt">$($diskRows.Count)</span></summary><div>
$(ConvertTo-HtmlTable $diskRows @('Name','Ty','Sz','He','Tc','We','Re','Ph') @('이름','종류','용량','상태','온도','마모','읽기오류','사용시간(h)'))
<h4>디스크 오류 기록</h4>$(ConvertTo-HtmlTable (@(Get-Arr (Get-Prop $Data 'DiskEvents')) | Select-Object -First 50) @('T','Source','Id','Msg') @('시간','출처','ID','내용'))</div></details>
<details class="sec"><summary>그래픽 드라이버 설치 이력 · 자주 충돌한 프로그램</summary><div>
$(ConvertTo-HtmlTable (Get-Prop $Data 'DriverInstalls') @('T','Msg') @('시간','내용') '기간 내 설치 기록 없음')
<h4>자주 충돌한 프로그램</h4>$(ConvertTo-HtmlTable (Get-Prop $Data 'AppCrashes') @('App','Count') @('프로그램','횟수'))</div></details>

<footer>$(HtmlEnc $script:AppName) v$(HtmlEnc $script:AppVersion) · 이 보고서는 PC 안에서만 생성되었으며 어떤 정보도 외부로 전송되지 않았습니다.<br>
진단은 Windows 기록에 기반한 추정입니다. 하드웨어 교체 전에 정밀 검사(VRAM·RAM·부하 테스트)로 확인하세요.</footer>
</main><script>$js</script></body></html>
"@
    return $html
}

function Get-NewSince($Data, [datetime]$Since) {
    # 지정 시각 이후에 새로 생긴 문제 기록 수
    $n = [ordered]@{ PowerLoss = 0; Bsod = 0; Gpu = 0; Whea = 0; Disk = 0 }
    $after = { param($o) $t = ConvertTo-Date (Get-Prop $o 'T'); return ($null -ne $t -and $t -gt $Since) }
    foreach ($s in @(Get-Arr (Get-Prop $Data 'Shutdowns'))) { if (& $after $s) { if (Format-BugCode (Get-Prop $s 'Code')) { $n.Bsod++ } else { $n.PowerLoss++ } } }
    $bsodEv = @(@(Get-Arr (Get-Prop $Data 'BugChecks')) | Where-Object { & $after $_ }).Count
    if ($bsodEv -gt $n.Bsod) { $n.Bsod = $bsodEv }
    $n.Gpu = @(@(Get-Arr (Get-Prop $Data 'GpuEvents')) | Where-Object { & $after $_ }).Count
    $n.Whea = @(@(Get-Arr (Get-Prop $Data 'Whea')) | Where-Object { & $after $_ }).Count
    $n.Disk = @(@(Get-Arr (Get-Prop $Data 'DiskEvents')) | Where-Object { & $after $_ }).Count
    return $n
}

function Get-HistoryPath { return (Join-Path $script:WorkDir 'history.json') }
function Read-History {
    $p = Get-HistoryPath
    if (-not (Test-Path $p)) { return @() }
    try { return @(Get-Content -Raw -Encoding UTF8 $p | ConvertFrom-Json) } catch { return @() }
}
function Add-Comparison($Data, $Dx, $History) {
    $me = [string](Get-Prop (Get-Prop $Data 'Meta') 'Computer')
    $prev = @($History | Where-Object { [string](Get-Prop $_ 'Computer') -eq $me }) | Select-Object -Last 1
    if (-not $prev) { return }
    $pt = ConvertTo-Date (Get-Prop $prev 'Created'); if (-not $pt) { return }
    $new = Get-NewSince $Data $pt
    $total = 0; foreach ($k in $new.Keys) { $total += $new[$k] }
    $Dx.Previous = [ordered]@{ Created = (Format-T $pt); Health = [int](Get-Prop $prev 'Health'); New = $new; NewTotal = $total }
}
function Add-History($Data, $Dx) {
    $h = @(Read-History) + @([ordered]@{ Created = (Get-Prop (Get-Prop $Data 'Meta') 'Created'); Computer = (Get-Prop (Get-Prop $Data 'Meta') 'Computer'); Health = $Dx.Health; Counts = $Dx.Counts })
    if ($h.Count -gt 50) { $h = $h[($h.Count - 50)..($h.Count - 1)] }
    try {
        New-Item -ItemType Directory -Force -Path $script:WorkDir | Out-Null
        [IO.File]::WriteAllText((Get-HistoryPath), (ConvertTo-Json -InputObject @($h) -Depth 5), (New-Object System.Text.UTF8Encoding($true)))
    } catch { Write-PCLog "history save failed: $($_.Exception.Message)" }
}

function Save-Results {
    param($Data, $Dx, [string]$Dir, [switch]$Track)
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }
    if ($Track) { Add-Comparison $Data $Dx (Read-History) }
    $stamp = (ConvertTo-Date (Get-Prop (Get-Prop $Data 'Meta') 'Created')); if (-not $stamp) { $stamp = Get-Date }
    $base = Join-Path $Dir ("PC진단_{0:yyyyMMdd_HHmmss}" -f $stamp)
    $html = New-HtmlReport -Data $Data -Dx $Dx
    $utf8 = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText("$base.html", $html, $utf8)
    [IO.File]::WriteAllText("$base.json", (ConvertTo-Json -InputObject $Data -Depth 6), $utf8)
    if ($Track) { Add-History $Data $Dx }
    return [pscustomobject]@{ Html = "$base.html"; Json = "$base.json" }
}

# =====================================================================
#  외부 도구 (평판 좋은 도구를 공식 출처에서 받아 실행)
# =====================================================================
$script:WorkDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'PCCheck' } else { Join-Path ([IO.Path]::GetTempPath()) 'PCCheck' }

function Save-Download([string]$Url, [string]$Dest, [string]$Sha256) {
    Write-PCLog "download $Url"
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $tmp = "$Dest.part"
    $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'   # PS5.1 진행 표시가 다운로드를 크게 느리게 함
    try { Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -UserAgent "PCCheck/$($script:AppVersion)" -ErrorAction Stop }
    finally { $ProgressPreference = $pp }
    if ($Sha256) {
        $h = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash
        if ($h -ne $Sha256.ToUpper()) { Remove-Item $tmp -Force; throw "파일 무결성 검증 실패 (SHA256 불일치)" }
        Write-PCLog "  sha256 ok"
    }
    Move-Item $tmp $Dest -Force
}

function Select-WindowsAsset($assets) {
    # 릴리스 파일 중 Windows x64 용을 고름 (.exe 또는 .zip, 리눅스/ARM/맥 제외)
    $c = @($assets | Where-Object { $_.name -match '\.(exe|zip)$' -and $_.name -notmatch '(?i)linux|aarch|arm64|armv|raspberry|android|mac|darwin|src|source' })
    $win = @($c | Where-Object { $_.name -match '(?i)win' })
    if ($win.Count) { $c = $win }
    $x64 = @($c | Where-Object { $_.name -match '(?i)x64|x86_64|amd64|64' })
    if ($x64.Count) { $c = $x64 }
    return ($c | Sort-Object @{ e = { if ($_.name -match '\.exe$') { 0 } else { 1 } } } | Select-Object -First 1)
}
function Install-MemtestVulkan {

    $dir = Join-Path $script:WorkDir 'memtest_vulkan'
    $exe = Get-ChildItem $dir -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'memtest' } | Select-Object -First 1
    if (-not $exe) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $rel = Invoke-RestMethod 'https://api.github.com/repos/GpuZelenograd/memtest_vulkan/releases/latest' -UserAgent "PCCheck/$($script:AppVersion)" -ErrorAction Stop
        $asset = Select-WindowsAsset @($rel.assets)
        if (-not $asset) { throw "Windows 용 파일을 찾지 못했습니다. (릴리스 파일: $((@($rel.assets) | ForEach-Object { $_.name }) -join ', '))" }
        $sha = $null; if ($asset.digest -match '^sha256:([0-9a-fA-F]{64})$') { $sha = $Matches[1] }
        $file = Join-Path $script:WorkDir $asset.name
        Save-Download $asset.browser_download_url $file $sha
        if ($asset.name -match '\.exe$') { Move-Item $file (Join-Path $dir $asset.name) -Force }
        else { Expand-Archive $file -DestinationPath $dir -Force; Remove-Item $file -Force -ErrorAction SilentlyContinue }
        $exe = Get-ChildItem $dir -Recurse -Filter '*.exe' | Where-Object { $_.Name -match 'memtest' } | Select-Object -First 1
    }
    if (-not $exe) { throw '실행 파일을 찾지 못했습니다.' }
    return $exe.FullName
}
function Start-MemtestVulkan { $p = Install-MemtestVulkan; Start-Process -FilePath $p -WorkingDirectory (Split-Path $p) }

function Install-BlueScreenView {
    $dir = Join-Path $script:WorkDir 'BlueScreenView'
    $exe = Join-Path $dir 'BlueScreenView.exe'
    if (-not (Test-Path $exe)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $zip = Join-Path $script:WorkDir 'bluescreenview.zip'
        $url = if ([Environment]::Is64BitOperatingSystem) { 'https://www.nirsoft.net/utils/bluescreenview-x64.zip' } else { 'https://www.nirsoft.net/utils/bluescreenview.zip' }
        Save-Download $url $zip $null
        Expand-Archive $zip -DestinationPath $dir -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path $exe)) { throw '실행 파일을 찾지 못했습니다.' }
    return $exe
}
function Start-BlueScreenView { Start-Process (Install-BlueScreenView) }

$script:ExternalTools = @(
    @{ Key = 'vram';  Label = '그래픽카드 VRAM 검사';  Desc = 'memtest_vulkan (GitHub 오픈소스) · NVIDIA/AMD/Intel'; Help = "새 창에서 엔터를 누르면 시작합니다.`n최소 5~10분 실행 후 'PASSed' 가 나오면 정상, 'error' 가 보이면 VRAM 불량 의심입니다.`n끝내려면 그 창에서 Ctrl+C.`n테스트 중 PC 가 꺼지면 파워/그래픽카드 전원 문제일 가능성이 큽니다."; Run = { Start-MemtestVulkan } ; Fallback = 'https://github.com/GpuZelenograd/memtest_vulkan/releases' }
    @{ Key = 'bsv';   Label = '블루스크린 원인 드라이버'; Desc = 'NirSoft BlueScreenView'; Help = "아래쪽 목록에서 빨간색으로 표시된 파일이 원인 후보입니다.`nnvlddmkm.sys=NVIDIA, amdkmdag.sys=AMD, ntoskrnl.exe=하드웨어/RAM 가능성."; Run = { Start-BlueScreenView }; Fallback = 'https://www.nirsoft.net/utils/blue_screen_of_death_viewer.html' }
    @{ Key = 'ram';   Label = 'RAM 검사 (재부팅)';     Desc = 'Windows 메모리 진단 (기본 내장)'; Help = "작업을 저장한 뒤 '지금 다시 시작하여 문제 확인'을 선택하세요.`n결과는 재부팅 후 이 프로그램을 다시 실행하면 보고서에 표시됩니다."; Run = { Start-Process "$env:SystemRoot\System32\MdSched.exe" }; Fallback = $null }
    @{ Key = 'hwinfo'; Label = '온도·전압 모니터링';     Desc = 'HWiNFO 공식 사이트'; Help = '공식 사이트에서 받아 "Sensors-only" 로 실행하세요.'; Run = { Start-Process 'https://www.hwinfo.com/download/' }; Fallback = $null }
    @{ Key = 'occt';  Label = '파워·GPU 부하 테스트';    Desc = 'OCCT 공식 사이트'; Help = "'Power' 테스트 10~20분 중 꺼지면 파워 문제, 'VRAM' 테스트에서 오류면 그래픽카드 문제입니다."; Run = { Start-Process 'https://www.ocbase.com/download' }; Fallback = $null }
)

function Invoke-Tool([string]$Key) {
    $t = $script:ExternalTools | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
    try { & $t.Run; return [pscustomobject]@{ Ok = $true; Help = $t.Help; Error = $null } }
    catch {
        Write-PCLog "tool $Key failed: $($_.Exception.Message)"
        if ($t.Fallback) { Start-Process $t.Fallback }
        return [pscustomobject]@{ Ok = $false; Help = $t.Help; Error = "$($_.Exception.Message)$(if ($t.Fallback) { "`n공식 다운로드 페이지를 열었습니다." })" }
    }
}

# =====================================================================
#  화면 (WinForms)
# =====================================================================
function Test-GuiLayout($root) {
    # 글자 잘림 · 컨트롤 겹침 · 부모 영역 밖으로 나감을 화면 없이 자동 검사
    $issues = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push($root)
    while ($stack.Count) {
        $parent = $stack.Pop()
        $kids = @($parent.Controls)
        foreach ($c in $kids) {
            $name = "$($c.GetType().Name) '$($c.Text)'"
            if ($c.Right -gt $parent.ClientSize.Width -or $c.Bottom -gt $parent.ClientSize.Height) { [void]$issues.Add("$name 이(가) 부모 영역 밖 ($($c.Bounds) / $($parent.ClientSize))") }
            if ($c.Text -and ($c -is [Windows.Forms.Button] -or ($c -is [Windows.Forms.Label] -and -not $c.AutoSize))) {
                $sz = [Windows.Forms.TextRenderer]::MeasureText([string]$c.Text, $c.Font)
                $avail = $c.ClientSize.Width - $(if ($c -is [Windows.Forms.Button]) { 10 } else { 0 })
                $multi = ($c -is [Windows.Forms.Label] -and $c.Height -ge $sz.Height * 2)
                if ($sz.Width -gt $avail -and -not $multi) { [void]$issues.Add("$name 글자 잘림 (필요 $($sz.Width)px > $avail px)") }
                if ($sz.Height -gt $c.ClientSize.Height + 2) { [void]$issues.Add("$name 높이 부족 (필요 $($sz.Height)px > $($c.ClientSize.Height)px)") }
            }
        }
        for ($i = 0; $i -lt $kids.Count; $i++) {
            for ($j = $i + 1; $j -lt $kids.Count; $j++) {
                $a = $kids[$i]; $b = $kids[$j]
                if ($a.Visible -and $b.Visible -and $a.Bounds.IntersectsWith($b.Bounds)) { [void]$issues.Add("겹침: $($a.GetType().Name) '$($a.Text)' ↔ $($b.GetType().Name) '$($b.Text)'") }
            }
        }
        foreach ($c in $kids) { if ($c -is [Windows.Forms.GroupBox] -or $c -is [Windows.Forms.Panel]) { $stack.Push($c) } }
    }
    return @($issues)
}

function Show-Gui {

    param([int]$Days, [string]$OutDir, [switch]$SmokeTest)
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $font = New-Object Drawing.Font('Malgun Gothic', 10)
    $bold = New-Object Drawing.Font('Malgun Gothic', 11, [Drawing.FontStyle]::Bold)
    $big  = New-Object Drawing.Font('Malgun Gothic', 26, [Drawing.FontStyle]::Bold)

    $f = New-Object Windows.Forms.Form
    $f.Text = "$($script:AppName) v$($script:AppVersion)"
    $f.ClientSize = New-Object Drawing.Size(760, 600)
    $f.MinimumSize = New-Object Drawing.Size(700, 560)
    $f.StartPosition = 'CenterScreen'; $f.Font = $font; $f.BackColor = [Drawing.Color]::FromArgb(246, 247, 249)
    $f.AutoScaleMode = 'Dpi'

    $title = New-Object Windows.Forms.Label
    $title.Text = 'PC 원클릭 진단'; $title.Font = New-Object Drawing.Font('Malgun Gothic', 16, [Drawing.FontStyle]::Bold)
    $title.Location = '20,16'; $title.AutoSize = $true
    $desc = New-Object Windows.Forms.Label
    $desc.Text = '갑자기 꺼짐 · 블루스크린 · 그래픽카드(VRAM) · RAM · 디스크 문제를 Windows 기록으로 분석합니다.'
    $desc.Location = '22,52'; $desc.AutoSize = $true; $desc.ForeColor = [Drawing.Color]::DimGray

    $daysLbl = New-Object Windows.Forms.Label; $daysLbl.Text = '분석 기간'; $daysLbl.Location = '22,90'; $daysLbl.AutoSize = $true
    $daysBox = New-Object Windows.Forms.ComboBox; $daysBox.DropDownStyle = 'DropDownList'; $daysBox.Location = '92,86'; $daysBox.Width = 110
    foreach ($o in '7일', '30일', '90일', '180일') { [void]$daysBox.Items.Add($o) }
    $daysBox.SelectedItem = $(if ($Days -le 7) { '7일' } elseif ($Days -le 30) { '30일' } elseif ($Days -le 90) { '90일' } else { '180일' })

    $start = New-Object Windows.Forms.Button
    $start.Text = '▶  검사 시작'; $start.Font = $bold; $start.Size = '200,44'; $start.Location = '538,78'; $start.Anchor = 'Top,Right'
    $start.BackColor = [Drawing.Color]::FromArgb(36, 87, 197); $start.ForeColor = [Drawing.Color]::White; $start.FlatStyle = 'Flat'; $start.FlatAppearance.BorderSize = 0

    $bar = New-Object Windows.Forms.ProgressBar; $bar.Location = '22,134'; $bar.Size = '716,10'; $bar.Anchor = 'Top,Left,Right'
    $status = New-Object Windows.Forms.Label; $status.Location = '22,150'; $status.Size = '716,22'; $status.Anchor = 'Top,Left,Right'; $status.ForeColor = [Drawing.Color]::DimGray
    $status.Text = $(if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { '준비됨 (관리자 권한)' } else { '준비됨 — ⚠ 관리자 권한이 아니어서 일부 항목이 빠질 수 있습니다' })

    $score = New-Object Windows.Forms.Label; $score.Font = $big; $score.Location = '22,180'; $score.Size = '150,60'; $score.Text = '—'; $score.TextAlign = 'MiddleLeft'
    $grade = New-Object Windows.Forms.Label; $grade.Font = $bold; $grade.Location = '24,240'; $grade.AutoSize = $true; $grade.Text = '상태 점수'

    $list = New-Object Windows.Forms.ListView
    $list.View = 'Details'; $list.FullRowSelect = $true; $list.HeaderStyle = 'Nonclickable'; $list.Location = '180,182'; $list.Size = '558,230'; $list.Anchor = 'Top,Left,Right,Bottom'
    [void]$list.Columns.Add('의심 원인 / 발견 사항', 380); [void]$list.Columns.Add('점수', 60); [void]$list.Columns.Add('가능성', 90)
    $tip = New-Object Windows.Forms.ToolTip

    $report = New-Object Windows.Forms.Button; $report.Text = '📄 보고서 열기'; $report.Location = '22,280'; $report.Size = '146,36'; $report.Enabled = $false
    $folder = New-Object Windows.Forms.Button; $folder.Text = '📁 저장 폴더'; $folder.Location = '22,322'; $folder.Size = '146,36'; $folder.Enabled = $false

    $grp = New-Object Windows.Forms.GroupBox; $grp.Text = '정밀 검사 (공식 출처에서 받아 실행)'; $grp.Location = '22,424'; $grp.Size = '716,160'; $grp.Anchor = 'Left,Right,Bottom'
    $x = 14; $y = 26; $i = 0
    foreach ($t in $script:ExternalTools) {
        $b = New-Object Windows.Forms.Button
        $b.Text = $t.Label; $b.Tag = $t.Key; $b.Size = '220,56'; $b.Location = New-Object Drawing.Point($x, $y)
        $tip.SetToolTip($b, "$($t.Desc)`n`n$($t.Help)")
        $b.Add_Click({
            param($sender, $e)
            $sender.Enabled = $false; $f.Cursor = 'WaitCursor'
            $r = Invoke-Tool $sender.Tag
            $f.Cursor = 'Default'; $sender.Enabled = $true
            if ($r.Ok) { [void][Windows.Forms.MessageBox]::Show($f, $r.Help, $sender.Text, 'OK', 'Information') }
            else { [void][Windows.Forms.MessageBox]::Show($f, "실행하지 못했습니다.`n$($r.Error)", $sender.Text, 'OK', 'Warning') }
        })
        $grp.Controls.Add($b)
        $i++; $x += 230; if ($i % 3 -eq 0) { $x = 14; $y += 64 }
    }

    $state = @{ Result = $null }
    $report.Add_Click({ if ($state.Result) { Start-Process $state.Result.Html } })
    $folder.Add_Click({ if ($state.Result) { Start-Process 'explorer.exe' "/select,`"$($state.Result.Html)`"" } })
    $start.Add_Click({
        $start.Enabled = $false; $daysBox.Enabled = $false; $list.Items.Clear(); $f.Cursor = 'WaitCursor'
        $d = [int](([string]$daysBox.SelectedItem) -replace '\D', '')
        try {
            $data = Invoke-Collect -Days $d -Progress { param($i, $n, $name) $bar.Maximum = $n + 2; $bar.Value = $i; $status.Text = "수집 중 ($i/$n): $name"; [Windows.Forms.Application]::DoEvents() }
            $status.Text = '분석 중...'; [Windows.Forms.Application]::DoEvents()
            $dx = Get-Diagnosis -Data $data
            $bar.Value = $bar.Maximum - 1
            $state.Result = Save-Results -Data $data -Dx $dx -Dir $OutDir -Track
            $bar.Value = $bar.Maximum
            $score.Text = "$($dx.Health)"
            $score.ForeColor = $(if ($dx.Health -ge 90) { [Drawing.Color]::SeaGreen } elseif ($dx.Health -ge 70) { [Drawing.Color]::DarkOrange } else { [Drawing.Color]::Firebrick })
            $grade.Text = "상태: $($dx.Grade)"
            foreach ($c in $dx.Causes | Select-Object -First 4) {
                $it = New-Object Windows.Forms.ListViewItem("$($c.Icon) $($c.Name)")
                [void]$it.SubItems.Add("$($c.Score)"); [void]$it.SubItems.Add($c.Confidence)
                $it.Font = $bold; $it.ToolTipText = (@($c.Reasons) -join "`n"); [void]$list.Items.Add($it)
            }
            foreach ($x in $dx.Findings | Where-Object { $_.Level -ne 'info' }) {
                $tag = switch ($x.Level) { 'bad' { '[위험]' } 'warn' { '[주의]' } default { '[정상]' } }
                $it = New-Object Windows.Forms.ListViewItem("$tag $($x.Title)")
                [void]$it.SubItems.Add(''); [void]$it.SubItems.Add('')
                $it.ForeColor = $(switch ($x.Level) { 'bad' { [Drawing.Color]::Firebrick } 'warn' { [Drawing.Color]::DarkOrange } default { [Drawing.Color]::SeaGreen } })
                $it.ToolTipText = $x.Detail; [void]$list.Items.Add($it)
            }
            $list.ShowItemToolTips = $true
            $report.Enabled = $true; $folder.Enabled = $true
            $status.Text = "완료 — 보고서: $($state.Result.Html)"
            Start-Process $state.Result.Html
        } catch {
            Write-PCLog "gui error: $($_.Exception.Message)"
            $status.Text = '오류가 발생했습니다.'
            [void][Windows.Forms.MessageBox]::Show($f, "검사 중 오류가 발생했습니다.`n$($_.Exception.Message)`n`n로그: $($script:LogFile)", $script:AppName, 'OK', 'Error')
        } finally { $start.Enabled = $true; $daysBox.Enabled = $true; $f.Cursor = 'Default' }
    })

    $f.Controls.AddRange(@($title, $desc, $daysLbl, $daysBox, $start, $bar, $status, $score, $grade, $list, $report, $folder, $grp))
    if ($SmokeTest) {
        # CI 등 화면 없는 환경: 컨트롤 생성까지만 검증
        $f.CreateControl(); $n = $f.Controls.Count
        $issues = @(Test-GuiLayout $f)
        foreach ($i in $issues) { Write-Output "GUI LAYOUT ISSUE: $i" }
        if ($env:PCCHECK_SHOT) {
            # 화면 캡처 (CI 산출물로 디자인 확인)
            $bmp = New-Object Drawing.Bitmap($f.Width, $f.Height)
            $f.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $f.Width, $f.Height)))
            $bmp.Save($env:PCCHECK_SHOT, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        }
        $f.Dispose()
        if ($issues.Count) { throw "GUI 레이아웃 문제 $($issues.Count) 건" }
        Write-Output "GUI OK: $n controls"; return
    }
    [void]$f.ShowDialog()
    $f.Dispose()
}

# =====================================================================
#  콘솔 모드
# =====================================================================
function Write-ConsoleResult($Dx, $Res) {
    Write-Host ''
    Write-Host ("상태 점수: {0}/100 ({1})" -f $Dx.Health, $Dx.Grade) -ForegroundColor $(if ($Dx.Health -ge 90) { 'Green' } elseif ($Dx.Health -ge 70) { 'Yellow' } else { 'Red' })
    if (@($Dx.Causes).Count) {
        Write-Host "`n가장 의심되는 원인" -ForegroundColor Cyan
        $i = 0; foreach ($c in $Dx.Causes | Select-Object -First 3) { $i++; Write-Host ("  {0}. {1}  {2}점 (가능성 {3})" -f $i, $c.Name, $c.Score, $c.Confidence); foreach ($r in @($c.Reasons) | Select-Object -First 2) { Write-Host "     - $r" -ForegroundColor DarkGray } }
    }
    Write-Host "`n발견 사항" -ForegroundColor Cyan
    foreach ($x in $Dx.Findings) { Write-Host ("  ● " + $x.Title) -ForegroundColor $(switch ($x.Level) { 'bad' { 'Red' } 'warn' { 'Yellow' } 'info' { 'Gray' } default { 'Green' } }) }
    Write-Host "`n보고서: $($Res.Html)" -ForegroundColor Green
}

function Start-ConsoleMenu($Res) {
    while ($true) {
        Write-Host "`n============ 정밀 검사 ============" -ForegroundColor Cyan
        $i = 0; foreach ($t in $script:ExternalTools) { $i++; Write-Host (" {0}. {1}  ({2})" -f $i, $t.Label, $t.Desc) }
        Write-Host ' 9. 보고서 다시 열기'; Write-Host ' 0. 종료'
        $sel = Read-Host '번호 선택'
        if ($sel -eq '0' -or $sel -eq '') { return }
        if ($sel -eq '9') { Start-Process $Res.Html; continue }
        $n = 0; if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $script:ExternalTools.Count) {
            $r = Invoke-Tool $script:ExternalTools[$n - 1].Key
            if ($r.Ok) { Write-Host $r.Help -ForegroundColor Green } else { Write-Host "실패: $($r.Error)" -ForegroundColor Red }
        }
    }
}

# =====================================================================
#  진입점
# =====================================================================
if ($LoadOnly) { return }

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
if (-not $OutDir) {
    $desk = [Environment]::GetFolderPath('Desktop'); if (-not $desk) { $desk = $HOME }
    $OutDir = Join-Path $desk 'PC진단'
}
New-Item -ItemType Directory -Force -Path $script:WorkDir, (Join-Path $script:WorkDir 'logs') -ErrorAction SilentlyContinue | Out-Null
$script:LogFile = Join-Path $script:WorkDir ("logs\{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
Write-PCLog "$($script:AppName) v$($script:AppVersion) mode=$Mode days=$Days ps=$($PSVersionTable.PSVersion)"

if ($FromJson) {
    $data = Get-Content -Raw -Encoding UTF8 -Path $FromJson | ConvertFrom-Json
    $dx = Get-Diagnosis -Data $data
    $res = Save-Results -Data $data -Dx $dx -Dir $OutDir
    Write-ConsoleResult $dx $res
    if ($Mode -eq 'Silent') { Write-Output $res; return }
    if (-not $NoOpen) { Start-Process $res.Html }
    return

}

if (-not $script:IsWin) { Write-Error 'Windows 에서만 검사할 수 있습니다. (-FromJson 으로 보고서 재생성은 가능)'; exit 2 }

if ($Mode -eq 'Gui') {
    try { Show-Gui -Days $Days -OutDir $OutDir -SmokeTest:$GuiSmokeTest; return }
    catch {
        # 화면을 띄우지 못하면 보이는 콘솔 창으로 다시 실행 (숨김 창에서 멈추지 않도록)
        Write-PCLog "gui failed, relaunch console: $($_.Exception.Message)"
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PSCommandPath`"", '-Mode', 'Console', '-Days', $Days)
        return
    }
}

Write-Host "$($script:AppName) v$($script:AppVersion) — 최근 $Days 일 분석" -ForegroundColor Cyan
$data = Invoke-Collect -Days $Days -Progress { param($i, $n, $name) Write-Host ("[{0}/{1}] {2}" -f $i, $n, $name) }
$dx = Get-Diagnosis -Data $data
$res = Save-Results -Data $data -Dx $dx -Dir $OutDir -Track
Write-ConsoleResult $dx $res
if ($Mode -eq 'Silent') { Write-Output $res; return }
if (-not $NoOpen) { Start-Process $res.Html }
Start-ConsoleMenu $res

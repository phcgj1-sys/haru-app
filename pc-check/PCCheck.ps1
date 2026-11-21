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
.PARAMETER Note     보고서에 넣을 증상·고객 메모 (PC 안에만 저장)
.PARAMETER Lang     보고서·화면 언어: auto(기본, Windows 언어) · ko · en
.PARAMETER LoadOnly 함수만 불러오고 실행하지 않음 (테스트용)
#>
[CmdletBinding()]
param(
    [ValidateSet('Gui', 'Console', 'Silent')][string]$Mode = 'Gui',
    [ValidateRange(1, 365)][int]$Days = 30,
    [string]$OutDir,
    [string]$FromJson,
    [string]$Note,
    [string]$Shop,
    [switch]$NoOpen,
    [switch]$GuiSmokeTest,
    [ValidateSet('auto', 'ko', 'en')][string]$Lang = 'auto',
    [switch]$LoadOnly
)

$script:AppName    = 'PC 원클릭 진단'
$script:AppVersion = '2.3.0'
$script:IsWin      = ($env:OS -eq 'Windows_NT')

# =====================================================================
#  공통 유틸
# =====================================================================
function HtmlEnc($s) { if ($null -eq $s) { return '' }; return [System.Net.WebUtility]::HtmlEncode((Tr ([string]$s))) }

function Format-T($dt) { if ($null -eq $dt) { return '' }; return ([datetime]$dt).ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) }
function ConvertTo-CsvField($v) {
    # 지역 설정과 무관하게 소수점은 항상 '.' (독일어 등 ',' 소수점 Windows 에서 CSV 가 깨지지 않도록)
    if ($null -eq $v) { return '' }
    if ($v -is [IFormattable] -and -not ($v -is [string])) { $s = $v.ToString($null, [Globalization.CultureInfo]::InvariantCulture) } else { $s = [string]$v }
    return ($s -replace ',', ';')
}
function ConvertFrom-PCJson([string]$Text) {
    # PowerShell 7 의 ConvertFrom-Json 은 날짜 문자열을 DateTime 으로 바꿔 지역 형식(11/19/2026)으로 표시되므로 원래 형식으로 되돌림
    $o = $Text | ConvertFrom-Json
    $fix = {
        param($x)
        if ($null -eq $x) { return }
        if ($x -is [System.Management.Automation.PSCustomObject]) {
            foreach ($p in @($x.PSObject.Properties)) {
                if ($p.Value -is [datetime]) { $p.Value = Format-T $p.Value } else { & $fix $p.Value }
            }
        } elseif ($x -is [System.Collections.IList]) {
            for ($i = 0; $i -lt $x.Count; $i++) { if ($x[$i] -is [datetime]) { $x[$i] = Format-T $x[$i] } else { & $fix $x[$i] } }
        }
    }
    foreach ($item in @($o)) { & $fix $item }
    return , $o
}
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
    try { Add-Content -Path $script:LogFile -Value ((Get-Date).ToString('HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + " $msg") -Encoding UTF8 } catch {}
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
        DriverInstalls = @(); AppCrashes = @(); OcTools = @(); Thermal = @(); GpuSensors = @(); Blackbox = @()

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

$script:GpuPerfSource = @'
using System;
using System.Runtime.InteropServices;
public static class PCCheckGpuPerf {
    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] struct ADAPTERINFO { public uint hAdapter; public LUID Luid; public uint NumOfSources; public int Precise; }
    [StructLayout(LayoutKind.Sequential)] struct ENUM2 { public uint NumAdapters; public IntPtr pAdapters; }
    [StructLayout(LayoutKind.Sequential)] struct QUERY { public uint hAdapter; public int Type; public IntPtr pData; public uint Size; }
    [StructLayout(LayoutKind.Sequential)] struct CLOSE { public uint hAdapter; }
    [StructLayout(LayoutKind.Sequential)] public struct PERF {
        public uint PhysicalAdapterIndex; public ulong MemoryFrequency; public ulong MaxMemoryFrequency; public ulong MaxMemoryFrequencyOC;
        public ulong MemoryBandwidth; public ulong PCIEBandwidth; public uint FanRPM; public uint Power; public uint Temperature; public byte PowerStateOverride; }
    [DllImport("gdi32.dll")] static extern int D3DKMTEnumAdapters2(ref ENUM2 e);
    [DllImport("gdi32.dll")] static extern int D3DKMTQueryAdapterInfo(ref QUERY q);
    [DllImport("gdi32.dll")] static extern int D3DKMTCloseAdapter(ref CLOSE c);
    // 반환: 어댑터마다 { 온도(0.1도), 팬 RPM, 전력(0.1%) } — 실패한 항목은 -1
    public static long[][] Read() {
        ENUM2 e = new ENUM2();
        if (D3DKMTEnumAdapters2(ref e) != 0 || e.NumAdapters == 0) return new long[0][];
        int sz = Marshal.SizeOf(typeof(ADAPTERINFO));
        IntPtr buf = Marshal.AllocHGlobal(sz * (int)e.NumAdapters);
        try {
            e.pAdapters = buf;
            if (D3DKMTEnumAdapters2(ref e) != 0) return new long[0][];
            long[][] res = new long[e.NumAdapters][];
            for (int i = 0; i < e.NumAdapters; i++) {
                ADAPTERINFO ai = (ADAPTERINFO)Marshal.PtrToStructure(new IntPtr(buf.ToInt64() + i * sz), typeof(ADAPTERINFO));
                res[i] = new long[] { -1, -1, -1 };
                PERF perf = new PERF();
                int psz = Marshal.SizeOf(typeof(PERF));
                IntPtr p = Marshal.AllocHGlobal(psz);
                try {
                    Marshal.StructureToPtr(perf, p, false);
                    QUERY q = new QUERY(); q.hAdapter = ai.hAdapter; q.Type = 62; q.pData = p; q.Size = (uint)psz;  // KMTQAITYPE_ADAPTERPERFDATA
                    if (D3DKMTQueryAdapterInfo(ref q) == 0) {
                        perf = (PERF)Marshal.PtrToStructure(p, typeof(PERF));
                        res[i][0] = perf.Temperature; res[i][1] = perf.FanRPM; res[i][2] = perf.Power;
                    }
                } catch { } finally { Marshal.FreeHGlobal(p); }
                CLOSE c = new CLOSE(); c.hAdapter = ai.hAdapter; try { D3DKMTCloseAdapter(ref c); } catch { }
            }
            return res;
        } finally { Marshal.FreeHGlobal(buf); }
    }
}
'@
function Get-GpuSensors {
    # 제조사와 무관한 GPU 온도/팬 (Windows 10 2004+ 의 작업 관리자와 같은 출처). 지원 안 되면 빈 결과
    $out = @()
    try {
        if (-not ('PCCheckGpuPerf' -as [type])) { Add-Type -TypeDefinition $script:GpuPerfSource -ErrorAction Stop }
        $rows = [PCCheckGpuPerf]::Read()
        for ($i = 0; $i -lt $rows.Length; $i++) {
            $t = $rows[$i][0] / 10.0
            if ($t -ge 5 -and $t -le 125) { $out += [ordered]@{ Index = $i; TempC = [math]::Round($t, 1); FanRPM = $(if ($rows[$i][1] -gt 0 -and $rows[$i][1] -lt 10000) { $rows[$i][1] } else { $null }) } }
        }
    } catch { Write-PCLog "gpu sensors: $($_.Exception.Message)" }
    return $out
}
function Test-DisplayDriverMessage([string]$Text) {
    # 드라이버 설치 기록(UserPnp 20001)이 '그래픽(디스플레이) 드라이버'인지 판별
    # 제조사 이름만으로는 칩셋·SATA·HDMI 오디오 드라이버까지 섞이므로, 디스플레이 INF 이름·장치명 기준으로 판단
    if (-not $Text) { return $false }
    if ($Text -match '(?i)audio|오디오|\bHDMI\b.*sound|SATA|AHCI|GPIO|SMBus|chipset|칩셋|USB|PSP|PCI Express Root|Bluetooth|Ethernet|Wi-?Fi|Network') { return $false }
    if ($Text -match '(?i)\bnv_disp\w*\.inf|\bnvlt\w*\.inf|\bnvdm\w*\.inf|\bnvami\w*\.inf|\bu\d{6,7}\.inf|\biigd\w*\.inf|\bigdlh\w*\.inf|\bcui_dch\.inf|\bamdkmdag') { return $true }
    return ($Text -match '(?i)Display adapter|디스플레이 어댑터|\bGeForce\b|\bRadeon\b|\bQuadro\b|\bRTX\b|\bGTX\b|Intel\(R\).*(Graphics|Arc)|\bArc\(TM\)|Intel Arc')
}
function Test-IsAdmin {
    try { return [bool](([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) }
    catch { return $false }
}
function Invoke-Collect {

    param([int]$Days = 30, [scriptblock]$Progress)
    $D = New-EmptyData
    $D.Meta.Days = $Days
    $D.Meta.IsAdmin = Test-IsAdmin
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
            $dumpCfg = $null
            try { $dumpCfg = [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction Stop).CrashDumpEnabled } catch {}
            $pageFiles = $null
            try { $pageFiles = @(Get-CimInstance Win32_PageFileUsage -ErrorAction Stop).Count } catch {}
            $fast = $null
            try { $fast = [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction Stop).HiberbootEnabled } catch {}
            $D.System = [ordered]@{
                OS = $os.Caption; Build = $os.BuildNumber; Version = $os.Version
                CPU = ($cpu.Name -replace '\s+', ' ').Trim(); Cores = $cpu.NumberOfCores; Threads = $cpu.NumberOfLogicalProcessors
                Board = ("$($mb.Manufacturer) $($mb.Product)").Trim(); BIOS = $bios.SMBIOSBIOSVersion; BIOSDate = (Format-T $bios.ReleaseDate)
                RamGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
                LastBoot = (Format-T $os.LastBootUpTime); PowerPlan = $plan; FastStartup = $fast
                Model = ("$($cs.Manufacturer) $($cs.Model)").Trim()
                CrashDump = $dumpCfg; PageFiles = $pageFiles
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
            $D.GpuSensors = @(Get-GpuSensors)
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
            $wer = @(Get-EventsSafe 'Application' 1001 'Windows Error Reporting' $since 300 | Where-Object { (Get-EventText $_) -match 'LiveKernelEvent' -and (Get-EventText $_) -match 'P1:\s*(141|117)\b' })
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
        @{ Name = '블랙박스 기록';            Run = { $D.Blackbox = @(Find-BlackboxFiles $Days) } }
        @{ Name = 'Windows 안정성 지수';      Run = {
            # 신뢰성 모니터의 시스템 안정성 지수 (1~10, 읽기 전용). 수집 작업이 꺼진 PC 에서는 비어 있음
            $since = [Management.ManagementDateTimeConverter]::ToDmtfDateTime((Get-Date).AddDays(-$Days))
            $vals = @(Get-CimInstance Win32_ReliabilityStabilityMetrics -Filter "TimeGenerated >= '$since'" -ErrorAction SilentlyContinue |
                ForEach-Object { [ordered]@{ T = (Format-T $_.TimeGenerated); V = [math]::Round([double]$_.SystemStabilityIndex, 2) } })
            $D.Stability = Get-StabilitySummary $vals
        } }
        @{ Name = '드라이버 설치·앱 충돌·온도'; Run = {
            $D.DriverInstalls = @(Get-EventsSafe 'System' 20001 'Microsoft-Windows-UserPnp' $since 200 | ForEach-Object {
                $txt = Get-EventText $_
                if (Test-DisplayDriverMessage $txt) { [ordered]@{ T = (Format-T $_.TimeCreated); Msg = (Get-FirstLine $txt) } }
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

function Start-CollectAsync {
    # 수집을 별도 런스페이스에서 실행 (화면 멈춤 방지). 진행 상황은 동기화 해시테이블로 전달
    param([int]$Days = 30)
    $sync = [hashtable]::Synchronized(@{ I = 0; N = 0; Name = ''; Done = $false; Data = $null; Error = $null })
    $rs = New-PCRunspace   # 함수와 설정값(GPU 센서 코드·단계 계획 등)을 모두 가진 실행 공간
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $rs.SessionStateProxy.SetVariable('days', $Days)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        try { $sync.Data = Invoke-Collect -Days $days -Progress { param($i, $n, $name) $sync.I = $i; $sync.N = $n; $sync.Name = $name } }
        catch { $sync.Error = $_.Exception.Message }
        finally { $sync.Done = $true }
    })
    $h = $ps.BeginInvoke()
    return [pscustomobject]@{ Sync = $sync; PS = $ps; Handle = $h; Runspace = $rs }
}
function Complete-CollectAsync($Job) {
    try { [void]$Job.PS.EndInvoke($Job.Handle) } catch { if (-not $Job.Sync.Error) { $Job.Sync.Error = $_.Exception.Message } }
    try { $Job.PS.Dispose(); $Job.Runspace.Dispose() } catch {}
    return $Job.Sync.Data
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

function Test-Diskless($Data) {
    # 노하드(네트워크 부팅): 디스크가 iSCSI·가상(파일) 디스크뿐 (가상 머신 제외)
    if ([bool](Get-Prop (Get-Prop $Data 'System') 'IsVM')) { return $false }
    $busList = @(@(Get-Arr (Get-Prop $Data 'Disks')) | ForEach-Object { [string](Get-Prop $_ 'Bus') })
    return ($busList.Count -gt 0 -and @($busList | Where-Object { $_ -notmatch '(?i)iSCSI|File Backed Virtual|Virtual' }).Count -eq 0)
}
function Get-ReportDir($Data, [string]$OutDir, [bool]$IsDefault, [string]$UsbRoot) {
    # 노하드는 재부팅하면 바탕화면이 지워지므로, 저장 위치를 따로 정하지 않았고 USB 가 있으면 USB 에 저장
    if ($IsDefault -and $UsbRoot -and (Test-Diskless $Data)) { return ($UsbRoot.TrimEnd('\', '/') + '\' + "$(Get-OutputPrefix)_reports") }
    return $OutDir
}
function Get-UsbRoot {
    if (-not $script:IsWin) { return '' }
    try { $u = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction Stop | Where-Object { $_.FreeSpace -gt 50MB }) | Select-Object -First 1; if ($u) { return ($u.DeviceID + '\') } } catch {}
    return ''
}
function Get-PsuEstimate($Data) {
    # 최대 소비전력 추정과 권장 파워 용량 (측정값 우선, 없으면 모델별 대표값). 순간 전력 급증 대비 30% 여유
    $gpuW = 0.0; $gpuSrc = ''
    foreach ($n in @(Get-Arr (Get-Prop $Data 'NvSmi'))) { $pl = Get-Prop $n 'PowerLimitW'; if ($null -ne $pl -and [double]$pl -gt $gpuW) { $gpuW = [double]$pl; $gpuSrc = '전력 제한값' } }
    foreach ($b in @(Get-Arr (Get-Prop $Data 'Blackbox'))) { $m = Get-Prop $b 'MaxGpuPowerW'; if ($null -ne $m -and [double]$m -gt $gpuW) { $gpuW = [double]$m; $gpuSrc = '블랙박스 측정' } }
    if ($gpuW -le 0) {
        # 제조사 기준 보드 전력(TBP/TGP). 'Ti'·'SUPER'·'XT' 변형이 기본 모델에 먼저 잡히지 않도록 긴 이름부터 비교
        $tbl = @(@('RTX 5090', 575), @('RTX 4090', 450), @('RTX 5080', 360), @('RTX 4080', 320), @('RTX 3090 Ti', 450), @('RTX 3090', 350), @('RTX 3080 Ti', 350), @('RTX 3080', 320),
                 @('RTX 5070 Ti', 300), @('RTX 4070 Ti', 285), @('RTX 5070', 250), @('RTX 4070 SUPER', 220), @('RTX 4070', 200), @('RTX 3070 Ti', 290), @('RTX 3070', 220),
                 @('RTX 5060 Ti', 180), @('RTX 5060', 145), @('RTX 4060 Ti', 160), @('RTX 4060', 115), @('RTX 3060 Ti', 200), @('RTX 3060', 170), @('RTX 3050', 130),
                 @('RTX 2080 Ti', 250), @('RTX 2080', 215), @('RTX 2070', 175), @('RTX 2060', 160), @('GTX 16', 125), @('GTX 10', 150),
                 @('RX 9070 XT', 304), @('RX 9070', 220), @('RX 9060 XT', 160), @('RX 7900 XTX', 355), @('RX 7900', 315), @('RX 6950', 335), @('RX 6900', 300), @('RX 6800 XT', 300), @('RX 6800', 250),
                 @('RX 7800', 263), @('RX 7700', 245), @('RX 6750', 250), @('RX 6700', 230), @('RX 7600', 165), @('RX 6650', 180), @('RX 6600', 132), @('Arc B580', 190), @('Arc A7', 225), @('Arc A5', 175))
        $tbl = @($tbl | Sort-Object { - $_[0].Length })
        foreach ($g in @(Get-Arr (Get-Prop $Data 'Gpus'))) {
            $nm = [string](Get-Prop $g 'Name')
            $nmN = ($nm -replace '\((R|TM)\)', ' ' -replace '\s+', ' ')   # 'Intel(R) Arc(TM) A770' → 'Intel Arc A770'
            foreach ($t in $tbl) { if ($nmN -match [regex]::Escape($t[0])) { if ($t[1] -gt $gpuW) { $gpuW = [double]$t[1]; $gpuSrc = '모델 대표값' }; break } }
            if ($gpuW -le 0 -and (Get-Prop $g 'Vendor') -in 'NVIDIA', 'AMD' -and $nm -notmatch 'Graphics$|Vega \d+ Graphics|Radeon\(TM\) Graphics') { $gpuW = 200.0; $gpuSrc = '일반 그래픽카드 가정' }
        }
    }
    $cpu = [string](Get-Prop (Get-Prop $Data 'System') 'CPU')
    $cpuW = 95.0
    if ($cpu -match 'i9-1[2-4]\d{3}K|i7-1[3-4]\d{3}K|Ultra [79] 2\d{2}K') { $cpuW = 253 }   # Core Ultra 200S K: 최대 250W
    elseif ($cpu -match 'Ultra 5 2\d{2}K') { $cpuW = 160 }
    elseif ($cpu -match 'Ultra [79] ') { $cpuW = 125 }
    elseif ($cpu -match 'Ultra 5 ') { $cpuW = 95 }
    elseif ($cpu -match 'i[579]-1[2-4]\d{3}K|Ryzen 9 [579]9\d{2}X') { $cpuW = 180 }
    elseif ($cpu -match 'Ryzen 9') { $cpuW = 142 }
    elseif ($cpu -match 'Ryzen 7 \d{4}X3D') { $cpuW = 120 }
    elseif ($cpu -match 'Ryzen 7|i7-') { $cpuW = 125 }
    elseif ($cpu -match 'Ryzen 5|i5-') { $cpuW = 95 }
    elseif ($cpu -match 'i3-|Ryzen 3|Pentium|Celeron|Athlon') { $cpuW = 65 }
    $other = 75.0
    $peak = $gpuW + $cpuW + $other
    $rec = [int]([math]::Ceiling($peak * 1.3 / 50.0) * 50)
    return [pscustomobject]@{ GpuW = [int]$gpuW; GpuSource = $gpuSrc; CpuW = [int]$cpuW; OtherW = [int]$other; PeakW = [int]$peak; RecommendW = $rec }
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
        $eff = [math]::Max(0.0, $plCount - $plButton * 0.7)
        & $add 'PSU' ([math]::Min(45.0, 14 * $eff)) "블루스크린 없이 꺼짐 $plCount 회"
        & $add 'THERMAL' ([math]::Min(18.0, 5 * $eff)) '블루스크린 없이 꺼짐 (과열 보호 차단 가능)'
        & $add 'GPU_HW' ([math]::Min(12.0, 3 * $eff)) ''
        # 전원 버튼 강제 종료(멈춤 후)는 '전원이 끊긴' 꺼짐보다 가볍게 반영 — 버튼 종료만 여러 번이면 '심각'으로 올리지 않음
        $plReal = $plCount - $plButton
        $lv = if ($plReal -ge 3) { 'bad' } else { 'warn' }
        $d = "블루스크린 기록 없이 전원이 끊긴 것처럼 꺼진 기록입니다. 파워 부족·노후, 과열 보호, 전원 케이블/멀티탭 접촉 불량에서 전형적으로 나타납니다."
        if ($plButton) { $d += " (이 중 $plButton 회는 전원 버튼을 길게 눌러 끈 흔적이 있습니다 — 멈춤 후 강제 종료였을 수 있습니다.)" }
        if ($plSleep) {
            $d += " $plSleep 회는 절전 진입/복귀 중에 발생했습니다 (드라이버·BIOS 절전 설정 문제가 흔함)."
            & $add 'DRIVER' ([math]::Min(20, 8 * $plSleep)) "절전 진입/복귀 중 꺼짐 $plSleep 회"
        }

        & $find $lv 'PSU' "갑자기 꺼짐 $plCount 회 (블루스크린 없음)" $d ([math]::Min(35, 10 * $plReal + 4 * $plButton))
    }

    # ---- 3) 블루스크린
    if ($crashes.Count -gt 0) {
        $parts = @()
        foreach ($k in ($codeCount.Keys | Sort-Object { -$codeCount[$_] })) {
            if ($k -eq '(미상)') { $parts += "코드 미상 $($codeCount[$k])회"; continue }
            $bi = Get-BugInfo $k
            $parts += "$k $($bi.N) $($codeCount[$k])회"
            $mult = [math]::Min(3, $codeCount[$k])
            foreach ($wk in $bi.W.Keys) { & $add $wk ($bi.W[$wk] * $mult) $(if ($bi.W[$wk] -ge 8) { "블루스크린 $k ($($bi.N))" } else { '' }) }
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
                foreach ($wk in $xi.W.Keys) { & $add $wk $xi.W[$wk] $(if ($xi.W[$wk] -ge 8) { "NVIDIA Xid $x ($($xi.D))" } else { '' }) }

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

    # ---- 안정성 지수 (Windows 신뢰성 모니터) — 보조 지표
    $stab = Get-Prop $Data 'Stability'
    if ($stab -and $null -ne (Get-Prop $stab 'Latest') -and [double](Get-Prop $stab 'Latest') -lt 3) {
        & $find 'info' 'DRIVER' "Windows 안정성 지수 낮음 ($(Get-Prop $stab 'Latest')/10)" '신뢰성 모니터가 최근 충돌·오류를 많이 기록했습니다. 시작 메뉴에서 "안정성 기록 보기"로 날짜별 오류를 확인할 수 있습니다.' 0
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
    # 가장 최근 '오류 없음' 결과보다 오래된 실패는 RAM 교체 등으로 해결된 것으로 봄
    $memPassT = $null
    foreach ($x in $memDiag) { if (-not (Get-Prop $x 'Failed')) { $t = ConvertTo-Date (Get-Prop $x 'T'); if ($t -and ($null -eq $memPassT -or $t -gt $memPassT)) { $memPassT = $t } } }
    $failAll = @($memDiag | Where-Object { Get-Prop $_ 'Failed' })
    $failMem = @($failAll | Where-Object { $t = ConvertTo-Date (Get-Prop $_ 'T'); -not $memPassT -or -not $t -or $t -gt $memPassT })
    if ($failMem.Count) {
        & $add 'RAM' 70 'Windows 메모리 진단에서 오류 발견'
        & $find 'bad' 'RAM' 'Windows 메모리 진단에서 RAM 오류 발견' 'RAM 불량이 거의 확실합니다. 한 개씩 꽂아 불량 모듈을 찾고 교체하세요.' 35
    } elseif ($failAll.Count) {
        & $find 'info' 'RAM' 'Windows 메모리 진단 오류 (이후 검사 통과)' "예전 검사에서 오류가 있었지만 $($memPassT.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)) 검사는 오류 없이 통과했습니다." 0
    }
    $xmp = $false
    # DDR5 기본(JEDEC) 최고 속도: Core Ultra 200S 는 6400, 그 외 5600 — 기본 속도를 XMP 로 오판하지 않도록
    $ddr5Std = $(if ([string](Get-Prop $sys 'CPU') -match 'Ultra [579] 2\d{2}') { 6400 } else { 5600 })
    foreach ($m in $dimms) {
        $cfg = [int](Get-Prop $m 'ConfiguredMHz'); $ddr = [string](Get-Prop $m 'DDR')
        if (($ddr -eq 'DDR4' -and $cfg -gt 3200) -or ($ddr -eq 'DDR5' -and $cfg -gt $ddr5Std) -or ($ddr -eq '' -and $cfg -gt 3200 -and $cfg -lt 4400)) { $xmp = $true }
    }
    if ($xmp) {
        $memish = $score['RAM'] -gt 0
        if ($memish) { & $add 'RAM' 10 'XMP/EXPO(메모리 오버클럭) 사용 중 + 메모리 관련 오류' }
        & $find 'info' 'RAM' 'XMP/EXPO(메모리 오버클럭) 사용 중으로 보임' '대부분 문제없지만, 불안정하면 BIOS 에서 XMP/EXPO 를 끄고 테스트해 보세요.' 0
    }
    $sizes = @($dimms | ForEach-Object { [int](Get-Prop $_ 'SizeGB') } | Sort-Object -Unique)
    $parts = @($dimms | ForEach-Object { [string](Get-Prop $_ 'Part') } | Where-Object { $_ } | Sort-Object -Unique)
    # 블루스크린 기록이 남을 수 있는 설정인지 (꺼져 있으면 '문제 없음'으로 오판 가능)
    $cd = Get-Prop $sys 'CrashDump'
    if ($null -ne $cd -and [int]$cd -eq 0) {
        & $find 'warn' 'META' '블루스크린 덤프 저장이 꺼져 있음' '블루스크린이 나도 원인 기록이 남지 않습니다. 시스템 속성 > 고급 > 시작 및 복구 > "디버깅 정보 쓰기"를 "작은 메모리 덤프" 또는 "자동 메모리 덤프"로 바꾸세요.' 3
    }
    $pf = Get-Prop $sys 'PageFiles'
    if ($null -ne $pf -and [int]$pf -eq 0) {
        & $find 'warn' 'META' '페이지 파일(가상 메모리)이 꺼져 있음' '페이지 파일이 없으면 블루스크린 덤프를 저장하지 못하고, 메모리 부족 시 프로그램이 갑자기 종료될 수 있습니다. "시스템이 관리하는 크기"로 켜 두세요.' 3
    }
    $isVM = [bool](Get-Prop $sys 'IsVM')
    # 노하드(네트워크 부팅): 디스크가 iSCSI·가상(파일) 디스크뿐이면 재부팅 시 기록이 사라지므로 블랙박스 안내
    $diskless = Test-Diskless $Data
    if ($diskless) {
        $hasBb = @(Get-Arr (Get-Prop $Data 'Blackbox')).Count -gt 0
        & $find $(if ($hasBb) { 'info' } else { 'warn' }) 'META' '노하드(네트워크 부팅) PC 로 보임' $(if ($hasBb) { '재부팅하면 Windows 기록이 사라지는 환경입니다. 아래 블랙박스 기록을 기준으로 판단하세요.' } else { '재부팅하면 Windows 기록이 사라져, 기록이 깨끗해도 문제가 없다는 뜻이 아닙니다. USB 를 꽂고 정밀 검사 → 블랙박스 기록(단계별 자동 테스트)을 실행하세요.' }) 0
    }

    if ($isVM) { & $find 'info' 'META' '가상 머신에서 실행됨' '가상 머신은 실제 하드웨어 정보를 보여 주지 않아 RAM/온도/그래픽카드 진단이 제한됩니다.' 0 }
    if (-not $isVM -and $dimms.Count -ge 2 -and ($sizes.Count -gt 1 -or $parts.Count -gt 1)) {

        & $add 'RAM' 4 '서로 다른 RAM 모듈 혼용'
        & $find 'info' 'RAM' '서로 다른 RAM 모듈을 섞어 사용 중' '용량/제품이 다른 RAM 혼용은 불안정의 원인이 될 수 있습니다.' 0
    }

    # ---- 9) 디스크
    foreach ($dk in $disks) {
        $h = [string](Get-Prop $dk 'Health')
        # 'Unknown'(5)은 고장이 아니라 상태를 알려 주지 않는 디스크(iSCSI·가상·일부 USB) — 경고하지 않음
        if ($h -match '^(Warning|1)$') {
            & $add 'DISK' 25 "디스크 상태 경고: $(Get-Prop $dk 'Name')"
            & $find 'warn' 'DISK' "디스크 상태 경고: $(Get-Prop $dk 'Name')" "상태: $h — 백업해 두고 SMART 를 확인하세요." 15
        } elseif ($h -and $h -notmatch '^(Healthy|0|Unknown|5)$') {
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
    if ($nv.Count -eq 0) {
        # NVIDIA 외 (AMD/Intel): Windows 공통 센서 — 부하 정보가 없으므로 높은 기준만 적용
        $gs = @(Get-Arr (Get-Prop $Data 'GpuSensors'))
        $hot = @($gs | Where-Object { [double](Get-Prop $_ 'TempC') -ge 88 } | Sort-Object { - [double](Get-Prop $_ 'TempC') }) | Select-Object -First 1
        if ($hot) {
            $tc = Get-Prop $hot 'TempC'
            & $add 'THERMAL' 14 "그래픽카드 $tc °C (Windows 센서)"
            & $find 'warn' 'THERMAL' "그래픽카드 온도 높음: $tc °C" '검사 시점의 온도입니다. 부하가 거의 없는데도 이 정도라면 팬·먼지·써멀을 점검하세요.' 5
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
    # 불안정 이슈 대상: 데스크톱 13·14세대 i9·i7 과 i5-13600/14600 이상 (i5-13400 등 하위 모델·노트북 H/U/P 제외)
    if ($cpuName -match '(i9-1[34]\d{3}|i7-1[34]\d{3}|i5-1[34][6-9]\d{2})(?![\dHUP])' ) {
        & $find 'info' 'CPU_OC' 'Intel 13·14세대 CPU' 'BIOS 를 최신(마이크로코드 0x12B 이상 포함)으로 업데이트하세요. 구버전 BIOS 는 CPU 불안정/열화 문제가 알려져 있습니다.' 0
        if ($crashes.Count -or $whea.Count) { & $add 'CPU_OC' 10 'Intel 13·14세대 CPU + 크래시 (알려진 불안정 이슈)' }
    }
    if ($biosD -and ($now - $biosD).TotalDays -gt 365 * 3 -and ($crashes.Count + $whea.Count) -gt 0) {
        & $find 'info' 'CPU_OC' "메인보드 BIOS 가 오래됨 ($($biosD.ToString('yyyy-MM-dd')))" '안정성 개선이 포함된 최신 BIOS 를 확인하세요.' 0
    }
    if ((Get-Prop $sys 'FastStartup') -eq 1 -and ($plCount + $crashes.Count) -gt 0) {
        & $find 'info' 'DRIVER' '빠른 시작(Fast Startup) 켜짐' '종료/부팅 관련 문제가 있으면 제어판 > 전원 옵션에서 "빠른 시작 켜기"를 꺼 보세요.' 0
    }
    # ---- 블랙박스(실시간 기록) — 노하드 등 이벤트 기록이 남지 않는 PC
    # 수리 후 더 새로운 '전 단계 통과' 기록이 있으면, 그 이전 실패 기록은 해결된 것으로 보고 참고로만 표시
    $bbAll = @(Get-Arr (Get-Prop $Data 'Blackbox'))
    $passT = $null
    foreach ($bb in $bbAll) {
        if ([string](Get-Prop $bb 'Level') -eq 'ok' -and [string](Get-Prop $bb 'Title') -match '전 단계 통과') {
            $e = ConvertTo-Date (Get-Prop $bb 'End'); if ($e -and ($null -eq $passT -or $e -gt $passT)) { $passT = $e }
        }
    }
    foreach ($bb in $bbAll) {
        $lvl = [string](Get-Prop $bb 'Level'); $cz = [string](Get-Prop $bb 'Cause'); $tt = [string](Get-Prop $bb 'Title')
        $be = ConvertTo-Date (Get-Prop $bb 'End')
        if ($passT -and $be -and $be -lt $passT -and $lvl -in 'bad', 'warn') {
            & $find 'info' 'META' "$tt (이후 테스트 통과)" ("$(Get-Prop $bb 'Detail') — $($passT.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)) 에 단계별 정밀 테스트를 모두 통과해 해결된 것으로 봅니다.") 0
            continue
        }
        if ($lvl -eq 'bad') {
            if ($cz) { & $add $cz 45 $tt }
            & $find 'bad' $(if ($cz) { $cz } else { 'META' }) $tt ([string](Get-Prop $bb 'Detail')) 20
        } elseif ($lvl -eq 'warn') {
            if ($cz) { & $add $cz 20 $tt }
            & $find 'warn' $(if ($cz) { $cz } else { 'META' }) $tt ([string](Get-Prop $bb 'Detail')) 8
        } elseif ($tt) { & $find 'info' 'META' $tt ([string](Get-Prop $bb 'Detail')) 0 }
    }
    $errs = @(Get-Arr (Get-Prop $Data 'Errors'))
    if (-not (Get-Prop $meta 'IsAdmin')) { & $find 'info' 'META' '관리자 권한 없이 실행됨' '일부 기록(덤프 파일 등)을 읽지 못했을 수 있습니다. 원클릭검사.bat 으로 실행하세요.' 0 }
    if ($errs.Count) { & $find 'info' 'META' "일부 항목 수집 실패 $($errs.Count) 건" (($errs | ForEach-Object { "$(Get-Prop $_ 'Step'): $(Get-Prop $_ 'Msg')" }) -join ' / ') 0 }

    # ---- 권장 파워 용량 (그래픽카드가 있을 때) — 파워가 의심되면 경고로, 아니면 참고로
    $psuE = Get-PsuEstimate $Data
    if ($psuE.GpuW -gt 0) {
        $txt = "최대 소비전력 약 $($psuE.PeakW)W (그래픽카드 $($psuE.GpuW)W·$($psuE.GpuSource) + CPU $($psuE.CpuW)W + 기타 $($psuE.OtherW)W). 순간 전력 급증을 고려해 정격 $($psuE.RecommendW)W 이상, 80 PLUS 인증 제품을 권장합니다. 파워 라벨의 정격 출력과 비교해 보세요."
        $psuSuspect = [double]$score['PSU'] -ge 30
        & $find $(if ($psuSuspect) { 'warn' } else { 'info' }) 'PSU' "권장 파워 용량: $($psuE.RecommendW)W 이상" $txt 0
    }

    # ---- 결과 정리
    $ranked = @()
    foreach ($k in $script:Causes.Keys) {
        $v = [math]::Round([math]::Min(100.0, $score[$k]))
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
        '갑자기 꺼짐' = @{ C = 'var(--c-psu)'; T = @(Get-Arr (Get-Prop $Data 'Shutdowns') | ForEach-Object { Get-Prop $_ 'T' }) }
        '블루스크린' = @{ C = 'var(--c-bsod)'; T = @(Get-Arr (Get-Prop $Data 'BugChecks') | ForEach-Object { Get-Prop $_ 'T' }) }
        '그래픽' = @{ C = 'var(--c-gpu)'; T = @(Get-Arr (Get-Prop $Data 'GpuEvents') | ForEach-Object { Get-Prop $_ 'T' }) }
        'WHEA' = @{ C = 'var(--c-whea)'; T = @(Get-Arr (Get-Prop $Data 'Whea') | ForEach-Object { Get-Prop $_ 'T' }) }
        '디스크 오류' = @{ C = 'var(--c-disk)'; T = @(Get-Arr (Get-Prop $Data 'DiskEvents') | ForEach-Object { Get-Prop $_ 'T' }) }
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
            [void]$sb.Append(("<rect x='{0}' y='{1}' width='{2}' height='{3}' rx='1.5' fill='{4}'/>" -f $x.ToString('0.#', $inv), $y.ToString('0.#', $inv), ([math]::Max(1.0, $bw - 2)).ToString('0.#', $inv), $h.ToString('0.#', $inv), $series[$n].C))
        }
        if ($tip.Count) { [void]$sb.Append(("<rect x='{0}' y='0' width='{1}' height='{2}' fill='transparent'><title>{3}: {4}</title></rect>" -f $x.ToString('0.#', $inv), $bw.ToString('0.#', $inv), $Hh, $day.ToString('MM-dd'), ($tip -join ', '))) }
        if ($i % [math]::Max(1, [int]($days / 6)) -eq 0 -or $i -eq $days - 1) { [void]$sb.Append(("<text x='{0}' y='{1}' class='lbl'>{2}</text>" -f $x.ToString('0.#', $inv), ($Hh + 16), $day.ToString('MM-dd'))) }   # int-ok: 정수 결과가 의도됨
    }
    [void]$sb.Append('</svg><div class="legend">')
    foreach ($n in $series.Keys) { [void]$sb.Append("<span><i style='background:$($series[$n].C)'></i>$n</span>") }
    [void]$sb.Append('</div>')
    return $sb.ToString()
}

function Get-BlackboxChartSvg($A) {
    # 블랙박스 기록 그래프: GPU 온도(°C)·CPU 사용률(%)은 0~100 축, GPU 전력(W)은 최대값 기준. 단계 구간 배경, 끊긴 지점 표시
    $ser = Get-Prop $A 'Series'; if (-not $ser) { return '' }
    $sec = @(Get-Arr (Get-Prop $ser 'Sec')); if ($sec.Count -lt 2) { return '' }
    $temp = @(Get-Arr (Get-Prop $ser 'Temp')); $pow = @(Get-Arr (Get-Prop $ser 'Pow')); $cpu = @(Get-Arr (Get-Prop $ser 'Cpu')); $stg = @(Get-Arr (Get-Prop $ser 'Stage'))
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $W = 720; $H = 170; $L = 34; $R = 44; $T = 10; $B = 22
    $tMax = [double]$sec[-1]; if ($tMax -le 0) { $tMax = 1 }
    $pMax = 0.0; foreach ($p in $pow) { if ($null -ne $p -and [double]$p -gt $pMax) { $pMax = [double]$p } }; if ($pMax -le 0) { $pMax = 1 }
    $xOf = { param($t) ($L + ($W - $L - $R) * [double]$t / $tMax).ToString('0.#', $inv) }
    $yOf = { param($v, $max) ($T + ($H - $T - $B) * (1 - [math]::Min(1.0, [double]$v / $max))).ToString('0.#', $inv) }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg viewBox='0 0 $W $H' class='tl bbc' role='img' aria-label='블랙박스 기록 그래프'>")
    # 단계 구간 (이름은 선 위에 보이도록 나중에 그림)
    $labels = New-Object System.Text.StringBuilder
    $names = @{}; foreach ($p in $script:StagePlan) { $names[$p.Key] = $p.Name }; $names['manual'] = '직접 설정'
    $i = 0
    while ($i -lt $sec.Count) {
        $k = [string]$stg[$i]; $j = $i
        while ($j + 1 -lt $sec.Count -and [string]$stg[$j + 1] -eq $k) { $j++ }
        if ($k) {
            $x1 = & $xOf $sec[$i]; $x2 = & $xOf $sec[[math]::Min($j + 1, $sec.Count - 1)]
            $fill = $(if ($i % 2 -eq 0) { 'var(--soft)' } else { 'transparent' })
            [void]$sb.Append("<rect x='$x1' y='$T' width='$(([double]$x2 - [double]$x1).ToString('0.#', $inv))' height='$($H - $T - $B)' fill='$fill'/>")
            $lbl = Tr $(if ($names.ContainsKey($k)) { $names[$k] } else { $k })
            # 구간 너비에 맞춰 이름을 줄이고, 너무 좁으면 생략 (글자가 옆 구간·선과 겹치지 않게)
            $bandW = [double]$x2 - [double]$x1
            # 글자 폭 추정: 한글 10px, 그 외 6px (글꼴 10px 기준)
            $room = $bandW - 6; $acc = 0.0; $cut = $lbl.Length
            for ($ci = 0; $ci -lt $lbl.Length; $ci++) { $acc += $(if ($lbl[$ci] -match '[가-힣]') { 10.0 } else { 6.0 }); if ($acc -gt $room) { $cut = $ci; break } }
            if ($cut -ge 2) {
                if ($cut -lt $lbl.Length) { $lbl = $lbl.Substring(0, $cut - 1) + '…' }
                [void]$labels.Append("<text x='$(([double]$x1 + 3).ToString('0.#', $inv))' y='$($T + 11)' class='lbl bbl'>$(HtmlEnc $lbl)</text>")
            }
        }
        $i = $j + 1
    }
    $line = {
        param($vals, $max, $color)
        $pts = @(); for ($q = 0; $q -lt $sec.Count; $q++) { if ($null -ne $vals[$q] -and "$($vals[$q])" -ne '') { $pts += ((& $xOf $sec[$q]) + ',' + (& $yOf $vals[$q] $max)) } }
        if ($pts.Count -ge 2) { [void]$sb.Append("<polyline points='$($pts -join ' ')' fill='none' stroke='$color' stroke-width='1.6'/>") }
    }
    & $line $cpu 100 'var(--c-bsod)'
    & $line $pow $pMax 'var(--c-whea)'
    & $line $temp 100 'var(--c-psu)'
    [void]$sb.Append($labels.ToString())
    [void]$sb.Append("<line x1='$L' y1='$($H - $B)' x2='$($W - $R)' y2='$($H - $B)' class='axis'/>")
    [void]$sb.Append("<text x='$($L - 4)' y='$($T + 4)' class='lbl' text-anchor='end'>100</text><text x='$($L - 4)' y='$($H - $B)' class='lbl' text-anchor='end'>0</text>")
    [void]$sb.Append("<text x='$($W - $R + 4)' y='$($T + 4)' class='lbl'>$([int]$pMax)W</text>")
    [void]$sb.Append("<text x='$L' y='$($H - 6)' class='lbl'>0</text><text x='$($W - $R)' y='$($H - 6)' class='lbl' text-anchor='end'>$([math]::Round($tMax / 60, 1)) 분</text>")
    if (Get-Prop $A 'Abrupt') {
        $xe = & $xOf $tMax
        [void]$sb.Append("<line x1='$xe' y1='$T' x2='$xe' y2='$($H - $B)' stroke='var(--bad)' stroke-width='2' stroke-dasharray='4 3'/><text x='$xe' y='$($H - $B - 4)' class='lbl' text-anchor='end' fill='var(--bad)'>기록 끊김</text>")
    }
    [void]$sb.Append('</svg><div class="legend"><span><i style="background:var(--c-psu)"></i>GPU 온도 (°C)</span><span><i style="background:var(--c-whea)"></i>GPU 전력 (W)</span><span><i style="background:var(--c-bsod)"></i>CPU 사용률 (%)</span></div>')
    return $sb.ToString()
}

function Get-BlackboxStageTable($A) {
    # 단계별 최고값 표 (단계별 정밀 테스트 기록일 때)
    $st = @(Get-Arr (Get-Prop $A 'Stages')); if ($st.Count -eq 0) { return '' }
    $last = [string](Get-Prop $A 'LastStage'); $abrupt = [bool](Get-Prop $A 'Abrupt')
    $rows = @($st | ForEach-Object {
        $k = [string](Get-Prop $_ 'Key')
        [ordered]@{
            N = (Get-Prop $_ 'Name')
            T = $(if ($null -ne (Get-Prop $_ 'MaxGpuTempC')) { "$(Get-Prop $_ 'MaxGpuTempC') °C" } else { '-' })
            P = $(if ($null -ne (Get-Prop $_ 'MaxGpuPowerW')) { "$(Get-Prop $_ 'MaxGpuPowerW') W" } else { '-' })
            C = $(if ($null -ne (Get-Prop $_ 'MaxCpuPct')) { "$(Get-Prop $_ 'MaxCpuPct')%" } else { '-' })
            R = $(if ($abrupt -and $k -eq $last) { '여기서 꺼짐' } else { '통과' })
        }
    })
    return '<h4>단계별 최고값</h4>' + (ConvertTo-HtmlTable $rows @('N', 'T', 'P', 'C', 'R') @('단계', 'GPU 온도', 'GPU 전력', 'CPU 사용률', '결과'))
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
            if ($c -eq 'T' -and $v) { $v = ([string]$v).Replace('T', ' ').Substring(0, [math]::Min(16, ([string]$v).Length)) }   # int-ok: 정수 결과가 의도됨
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
    if (Get-Prop $m 'Shop') { [void]$L.Add('점검: %%PCSHOP%%') }
    if (Get-Prop $m 'Note') { [void]$L.Add('메모: %%PCNOTE%%') }
    [void]$L.Add("상태 점수: $($Dx.Health)/100 ($($Dx.Grade))")
    [void]$L.Add("PC: $(Get-Prop $s 'CPU') / RAM $(Get-Prop $s 'RamGB')GB / $((@(Get-Arr (Get-Prop $Data 'Gpus')) | ForEach-Object { Get-Prop $_ 'Name' }) -join ', ')")
    [void]$L.Add("OS: $(Get-Prop $s 'OS') (빌드 $(Get-Prop $s 'Build')) · 보드: $(Get-Prop $s 'Board') BIOS $(Get-Prop $s 'BIOS')")
    $c = $Dx.Counts
    [void]$L.Add("기록: 갑자기꺼짐 $($c.PowerLoss) · 블루스크린 $($c.Bsod) · 그래픽오류 $($c.Gpu) · WHEA $($c.Whea) · 디스크 $($c.Disk)")
    $top = @($Dx.Causes) | Select-Object -First 1
    if ($top -and $top.Score -ge 30) { [void]$L.Add("지금 할 일: $(@($top.Steps)[0])") }
    # 노하드는 Windows 기록이 비어 있으므로 블랙박스 판정과 지난 검사 대비 결과를 함께 적음
    $bb = @(Get-Arr (Get-Prop $Data 'Blackbox')) | Select-Object -First 1
    if ($bb -and (Get-Prop $bb 'Title')) { [void]$L.Add("블랙박스(최근): $(Get-Prop $bb 'Title')") }
    $pv = $Dx.Previous
    if ($pv) { [void]$L.Add($(if ([int]$pv.NewTotal) { "지난 검사($($pv.Created.Replace('T', ' '))) 이후 새 문제 $($pv.NewTotal) 건" } else { "지난 검사($($pv.Created.Replace('T', ' '))) 이후 새 문제 없음" })) }
    if ($rl = Get-RecommendedToolLabel $Dx) { [void]$L.Add("다음 정밀 검사 추천: $rl") }
    if ($Dx.CrashCodes.Count) { [void]$L.Add("블루스크린 코드: $((($Dx.CrashCodes.Keys | ForEach-Object { "$_ x$($Dx.CrashCodes[$_])" }) -join ', '))") }
    if (@($Dx.Causes).Count) {
        [void]$L.Add('의심 원인:')
        $i = 0; foreach ($x in $Dx.Causes | Select-Object -First 3) { $i++; [void]$L.Add("  $i. $($x.Name) — $($x.Score)점(가능성 $($x.Confidence)): $(@($x.Reasons | Select-Object -First 2) -join '; ')") }
    }
    return (Tr ($L -join "`r`n")).Replace('%%PCNOTE%%', [string](Get-Prop $m 'Note')).Replace('%%PCSHOP%%', [string](Get-Prop $m 'Shop'))
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
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.6 "Malgun Gothic","Segoe UI",system-ui,sans-serif}
main{max-width:980px;margin:0 auto;padding:28px 16px 80px}
header{display:flex;gap:24px;align-items:center;flex-wrap:wrap;background:var(--card);border:1px solid var(--line);border-radius:14px;padding:20px}
.ring{position:relative;width:128px;height:128px;flex:none}.ring svg{transform:rotate(-90deg)}.ring circle{fill:none;stroke-width:12}
.ring .bg{stroke:var(--soft)}.ring .fg{stroke-linecap:round}.ring.ok .fg{stroke:var(--ok)}.ring.warn .fg{stroke:var(--warn)}.ring.bad .fg{stroke:var(--bad)}
.ring b{position:absolute;inset:0;display:grid;place-items:center;font-size:34px;line-height:1}.ring small{position:absolute;left:0;bottom:26px;width:100%;text-align:center;color:var(--muted);font-size:12px}
.hd{flex:1;min-width:260px}.hd h1{margin:0;font-size:22px}.hd .grade{font-size:18px;font-weight:700;margin:4px 0}.sub{color:var(--muted);font-size:13px;margin:0}
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
.tl{width:100%;height:auto}.bbl{paint-order:stroke;stroke:var(--card);stroke-width:3px}.tl .axis{stroke:var(--line)}.tl .lbl{fill:var(--muted);font-size:10px}
.legend{display:flex;gap:14px;flex-wrap:wrap;font-size:12px;color:var(--muted);margin-top:4px}.legend i{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:4px;vertical-align:-1px}
details.sec{background:var(--card);border:1px solid var(--line);border-radius:12px;margin:8px 0}details.sec>summary{padding:12px 14px;cursor:pointer;font-weight:700}details.sec>div{padding:0 14px 14px}
.cnt{font-weight:400;color:var(--muted);font-size:13px;margin-left:6px}
.tw{overflow-x:auto}table{width:100%;border-collapse:collapse;font-size:13px}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--line);vertical-align:top}th{color:var(--muted);font-weight:600;white-space:nowrap}
.none{color:var(--ok);margin:6px 0}.kv td:first-child{color:var(--muted);white-space:nowrap;width:120px}
pre{white-space:pre-wrap;background:var(--soft);border-radius:8px;padding:12px;font:12px/1.6 Consolas,monospace;margin:0}
.btns{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}button{font:inherit;border:1px solid var(--line);background:var(--card);color:var(--fg);border-radius:8px;padding:8px 14px;cursor:pointer}button.pri{background:var(--accent);color:#fff;border-color:var(--accent)}
footer{margin-top:40px;color:var(--muted);font-size:12px}
.sign{display:none;gap:24px;margin-top:36px}.sign div{flex:1}.sign span{font-size:12px;color:var(--muted)}.sign i{display:block;border-bottom:1px solid #000;height:36px}
.note{margin:4px 0;font-weight:600}
.next{margin:6px 0 4px;padding:8px 12px;background:var(--soft);border-radius:8px}.next span{color:var(--muted);font-size:13px}

.cmp{border-radius:12px;padding:12px 16px;margin:16px 0;border:1px solid var(--line);background:var(--card)}.cmp p{margin:2px 0 0;color:var(--muted)}
.cmp.ok{border-left:5px solid var(--ok)}.cmp.bad{border-left:5px solid var(--bad)}

@media (max-width:640px){.cause summary{grid-template-columns:24px 1fr 36px;}.cause .bar,.cause .cf{display:none}.cb{grid-template-columns:1fr}header{padding:16px}}
@media print{.sign{display:flex}button,.btns{display:none}details{break-inside:avoid}details:not([open])>*:not(summary){display:block}body{background:#fff}}
'@
    $js = @'
function copySummary(){var t=document.getElementById('sumtext').innerText;
 if(navigator.clipboard){navigator.clipboard.writeText(t).then(function(){flash('복사했습니다')},fallback)}else{fallback()}
 function fallback(){var r=document.createRange();r.selectNodeContents(document.getElementById('sumtext'));var s=getSelection();s.removeAllRanges();s.addRange(r);try{document.execCommand('copy');flash('복사했습니다')}catch(e){flash('Ctrl+C 로 복사하세요')}}}
function flash(m){var b=document.getElementById('cpbtn');var o=b.textContent;b.textContent=m;setTimeout(function(){b.textContent=o},1600)}
function openAll(v){document.querySelectorAll('details').forEach(function(d){d.open=v})}
'@
    $nextHtml = ''
    $topC = @($Dx.Causes) | Select-Object -First 1
    if ($topC -and $topC.Score -ge 30) { $nextHtml = "<p class='next'>👉 지금 할 일: <b>$(HtmlEnc @($topC.Steps)[0])</b> <span>($(HtmlEnc $topC.Name) 의심)</span></p>" }
    $cmpHtml = ''
    $pv = $Dx['Previous']
    if ($pv) {
        $pvT = ([string]$pv.Created).Replace('T', ' ').Substring(0, 16)
        $lbl = [ordered]@{ PowerLoss = '갑자기 꺼짐'; Bsod = '블루스크린'; Gpu = '그래픽 오류'; Whea = 'WHEA'; Disk = '디스크 오류'; Blackbox = '블랙박스 이상' }
        if ($pv.NewTotal -eq 0) {
            $cmpHtml = "<div class='cmp ok'><b>지난 검사($pvT · $($pv.Health)점) 이후 새로 생긴 문제 없음 ✓</b><p>조치가 효과를 보고 있는 것으로 보입니다. 며칠 더 사용한 뒤 다시 검사해 확인하세요.</p></div>"
        } else {
            $parts = @(); foreach ($k in $lbl.Keys) { if ($pv.New[$k]) { $parts += "$($lbl[$k]) $($pv.New[$k])" } }
            $cmpHtml = "<div class='cmp bad'><b>지난 검사($pvT · $($pv.Health)점) 이후 새 문제 $($pv.NewTotal) 건</b><p>$(HtmlEnc ($parts -join ' · ')) — 문제가 아직 해결되지 않았습니다. 아래 1순위 원인의 다음 단계를 진행하세요.</p></div>"
        }
        $tr = @(Get-Arr $Dx['Trend'])
        if ($tr.Count) {
            $steps = @($tr | ForEach-Object { $d = ([string]$_.Created); "$(HtmlEnc $(if ($d.Length -ge 10) { $d.Substring(5, 5) } else { $d })) $([int]$_.Health)" }) + @("지금 $($Dx.Health)")
            $cmpHtml += "<p class='sub'>점수 변화: $($steps -join ' → ')</p>"
        }
    }
    $memDiagText = if ($memD.Count) { $x = $memD[0]; "$(([string](Get-Prop $x 'T')).Replace('T',' ')) — $(if (Get-Prop $x 'Failed') { '❌ 오류 발견' } else { '✅ 오류 없음' })" } else { '실행 기록 없음 (메뉴에서 실행 가능)' }

    $html = @"
<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>PC 진단 보고서</title><style>$css</style></head><body><main>
<header>
 <div class="ring $gradeCls"><svg width="128" height="128" viewBox="0 0 128 128"><circle class="bg" cx="64" cy="64" r="52"/><circle class="fg" cx="64" cy="64" r="52" stroke-dasharray="$dash $circS"/></svg><b>$($Dx.Health)</b><small>/ 100</small></div>
 <div class="hd"><h1>PC 진단 보고서</h1><div class="grade">상태: $(HtmlEnc $Dx.Grade)</div>
 $nextHtml
 $(if (Get-Prop $m 'Shop') { "<p class='note'>점검: %%PCSHOP%%</p>" })
 $(if (Get-Prop $m 'Note') { "<p class='note'>메모: %%PCNOTE%%</p>" })
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
$(if ($rl = Get-RecommendedToolLabel $Dx) { "<div class='cmp ok'><b>다음 정밀 검사 추천: $(HtmlEnc $rl)</b><p>프로그램의 '정밀 검사'에서 실행해 원인을 확인하세요.</p></div>" })

<h2>발견 사항</h2>
$findHtml

<h2>날짜별 기록</h2>
<div class="card">$(Get-TimelineSvg $Data)</div>

<h2>A/S · 상담용 요약</h2>
<div class="card"><pre id="sumtext">$(HtmlEnc $summary)</pre>
<p class="sub" style="margin-top:8px">원격 상담을 받을 때는 이 요약과 함께, 보고서와 같은 폴더에 있는 같은 이름의 <b>.json</b> 파일을 보내 주세요 (상담사가 같은 보고서를 열어 볼 수 있습니다).</p>
<div class="btns"><button class="pri" id="cpbtn" onclick="copySummary()">요약 복사</button>
<button onclick="openAll(true);window.print()">인쇄 / PDF 저장</button><button onclick="openAll(true)">모두 펼치기</button></div></div>

<h2>상세 기록</h2>
<details class="sec"><summary>시스템 정보</summary><div><table class="kv">
<tr><td>Windows</td><td>$(HtmlEnc (Get-Prop $s 'OS')) (빌드 $(HtmlEnc (Get-Prop $s 'Build')))</td></tr>
<tr><td>모델</td><td>$(HtmlEnc (Get-Prop $s 'Model'))</td></tr>
<tr><td>CPU</td><td>$(HtmlEnc (Get-Prop $s 'CPU')) ($(HtmlEnc (Get-Prop $s 'Cores'))코어 / $(HtmlEnc (Get-Prop $s 'Threads'))스레드)</td></tr>
<tr><td>메인보드</td><td>$(HtmlEnc (Get-Prop $s 'Board')) · BIOS $(HtmlEnc (Get-Prop $s 'BIOS')) ($(HtmlEnc ([string](Get-Prop $s 'BIOSDate')).Split('T')[0]))</td></tr>
$(if ($stb = Get-Prop $Data 'Stability') { "<tr><td>Windows 안정성 지수</td><td>최근 $(HtmlEnc (Get-Prop $stb 'Latest')) / 10 · 최저 $(HtmlEnc (Get-Prop $stb 'Min')) · 평균 $(HtmlEnc (Get-Prop $stb 'Avg'))</td></tr>" })
<tr><td>마지막 부팅</td><td>$(HtmlEnc ([string](Get-Prop $s 'LastBoot')).Replace('T',' '))</td></tr>
<tr><td>전원 관리</td><td>$(HtmlEnc (Get-Prop $s 'PowerPlan')) · 빠른 시작 $(if ((Get-Prop $s 'FastStartup') -eq 1) { '켜짐' } elseif ((Get-Prop $s 'FastStartup') -eq 0) { '꺼짐' } else { '-' })</td></tr>
</table></div></details>
<details class="sec"><summary>그래픽카드<span class="cnt">$($gpuRows.Count)</span></summary><div>
$(ConvertTo-HtmlTable $gpuRows @('Name','Vram','Driver','DD','St') @('이름','VRAM','드라이버','드라이버 날짜','상태'))
$(if ($nvRows.Count) { '<h4>NVIDIA 실시간 상태</h4>' + (ConvertTo-HtmlTable $nvRows @('Name','Temp','Util','Mem','Pw','Clk') @('이름','온도','사용률','VRAM','전력','클럭')) })
$(if (@(Get-Arr (Get-Prop $Data 'GpuSensors')).Count) { '<h4>그래픽 센서 (Windows 제공)</h4>' + (ConvertTo-HtmlTable (@(Get-Arr (Get-Prop $Data 'GpuSensors')) | ForEach-Object { [ordered]@{ I = "어댑터 $(Get-Prop $_ 'Index')"; T = "$(Get-Prop $_ 'TempC') °C"; F = $(if (Get-Prop $_ 'FanRPM') { "$(Get-Prop $_ 'FanRPM') RPM" } else { '-' }) } }) @('I','T','F') @('장치','온도','팬')) })

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
$(if (@(Get-Arr (Get-Prop $Data 'Blackbox')).Count) { '<details class="sec" open><summary>블랙박스 기록 (실시간 테스트)</summary><div>' + (ConvertTo-HtmlTable (@(Get-Arr (Get-Prop $Data 'Blackbox')) | ForEach-Object { [ordered]@{ F = (Get-Prop $_ 'File'); S = ([string](Get-Prop $_ 'Start')).Replace('T', ' '); M = "$(Get-Prop $_ 'Minutes') 분"; R = $(if (Get-Prop $_ 'Abrupt') { '갑자기 끊김' } else { '정상 종료' }); G = $(if ($null -ne (Get-Prop $_ 'MaxGpuTempC')) { "$(Get-Prop $_ 'MaxGpuTempC') °C" } else { '-' }); V = (Get-Prop $_ 'Title') } }) @('F','S','M','R','G','V') @('파일','시작','길이','끝','GPU 최고','판정')) + '<h4>가장 최근 기록 그래프</h4>' + (Get-BlackboxChartSvg (@(Get-Arr (Get-Prop $Data 'Blackbox')) | Select-Object -First 1)) + (Get-BlackboxStageTable (@(Get-Arr (Get-Prop $Data 'Blackbox')) | Select-Object -First 1)) + '</div></details>' })
<details class="sec"><summary>그래픽 드라이버 설치 이력 · 자주 충돌한 프로그램</summary><div>
$(ConvertTo-HtmlTable (Get-Prop $Data 'DriverInstalls') @('T','Msg') @('시간','내용') '기간 내 설치 기록 없음')
<h4>자주 충돌한 프로그램</h4>$(ConvertTo-HtmlTable (Get-Prop $Data 'AppCrashes') @('App','Count') @('프로그램','횟수'))</div></details>

<div class="sign"><div><span>점검일</span><i></i></div><div><span>점검자 서명</span><i></i></div><div><span>고객 확인 서명</span><i></i></div></div>
<footer>$(if (Get-Prop $m 'Shop') { "점검: %%PCSHOP%%<br>" })$(HtmlEnc $script:AppName) v$(HtmlEnc $script:AppVersion) · 이 보고서는 PC 안에서만 생성되었으며 어떤 정보도 외부로 전송되지 않았습니다.<br>
진단은 Windows 기록에 기반한 추정입니다. 하드웨어 교체 전에 정밀 검사(VRAM·RAM·부하 테스트)로 확인하세요.</footer>
</main><script>$js</script></body></html>
"@
    if ($script:UiLang -eq 'en') { $html = (Tr $html).Replace('<html lang="ko">', '<html lang="en">') }
    # 사용자가 쓴 메모는 번역하지 않고 그대로 (번역 후에 끼워 넣음)
    $html = $html.Replace('%%PCNOTE%%', [System.Net.WebUtility]::HtmlEncode([string](Get-Prop $m 'Note'))).Replace('%%PCSHOP%%', [System.Net.WebUtility]::HtmlEncode([string](Get-Prop $m 'Shop')))
    return $html
}

function Get-NewSince($Data, [datetime]$Since) {
    # 지정 시각 이후에 새로 생긴 문제 기록 수
    $n = [ordered]@{ PowerLoss = 0; Bsod = 0; Gpu = 0; Whea = 0; Disk = 0; Blackbox = 0 }
    $after = { param($o) $t = ConvertTo-Date (Get-Prop $o 'T'); return ($null -ne $t -and $t -gt $Since) }
    foreach ($s in @(Get-Arr (Get-Prop $Data 'Shutdowns'))) { if (& $after $s) { if (Format-BugCode (Get-Prop $s 'Code')) { $n.Bsod++ } else { $n.PowerLoss++ } } }
    $bsodEv = @(@(Get-Arr (Get-Prop $Data 'BugChecks')) | Where-Object { & $after $_ }).Count
    if ($bsodEv -gt $n.Bsod) { $n.Bsod = $bsodEv }
    $n.Gpu = @(@(Get-Arr (Get-Prop $Data 'GpuEvents')) | Where-Object { & $after $_ }).Count
    $n.Whea = @(@(Get-Arr (Get-Prop $Data 'Whea')) | Where-Object { & $after $_ }).Count
    $n.Disk = @(@(Get-Arr (Get-Prop $Data 'DiskEvents')) | Where-Object { & $after $_ }).Count
    # 노하드는 Windows 기록이 없으므로 지난 검사 이후 끝난 블랙박스 기록 중 이상(bad·warn) 판정도 셈
    $n.Blackbox = @(@(Get-Arr (Get-Prop $Data 'Blackbox')) | Where-Object { $e = ConvertTo-Date (Get-Prop $_ 'End'); $null -ne $e -and $e -gt $Since -and [string](Get-Prop $_ 'Level') -in 'bad', 'warn' }).Count
    return $n
}

# 영어 사용자에게 한글 파일·폴더 이름이 보이지 않도록 언어별 이름 사용
function Get-OutputPrefix { if ($script:UiLang -eq 'en') { return 'PCCheck' } else { return 'PC진단' } }
function Get-HistoryPath { return (Join-Path $script:WorkDir 'history.json') }
function Get-HistoryPaths {
    # 기본 위치 + USB 의 블랙박스 폴더(있을 때만). 노하드는 재부팅하면 기본 위치가 지워지므로 USB 사본으로 이어 감
    $l = @(Get-HistoryPath)
    $dirs = @()
    if ($null -ne $script:ExtraHistoryDirs) { $dirs = @($script:ExtraHistoryDirs) }
    elseif ($script:IsWin) { try { $dirs = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction Stop | ForEach-Object { Join-Path ($_.DeviceID + '\') 'PCCheck_blackbox' }) } catch {} }
    foreach ($d in $dirs) { if ($d -and (Test-Path $d)) { $l += (Join-Path $d 'history.json') } }
    return $l
}
function Read-History {
    # 여러 위치의 기록을 합쳐 시간순으로 (같은 검사는 한 번만)
    $all = @{}
    foreach ($p in (Get-HistoryPaths)) {
        if (-not (Test-Path $p)) { continue }
        # 5.1 의 ConvertFrom-Json 은 JSON 배열을 통째로 하나의 개체로 내보내므로 직접 풀어서 사용
        try { $j = ConvertFrom-PCJson (Get-Content -Raw -Encoding UTF8 $p); foreach ($x in $j) { if ($x) { $all["$(Get-Prop $x 'Computer')|$(Get-Prop $x 'Created')"] = $x } } } catch { }
    }
    foreach ($k in ($all.Keys | Sort-Object { [string]($_ -split '\|', 2)[1] })) { $all[$k] }
}
function Add-Comparison($Data, $Dx, $History) {
    $me = [string](Get-Prop (Get-Prop $Data 'Meta') 'Computer')
    $mine = @($History | Where-Object { [string](Get-Prop $_ 'Computer') -eq $me })
    $prev = $mine | Select-Object -Last 1
    if (-not $prev) { return }
    # 최근 검사 점수 변화 (최대 5회) — 수리 전후 비교용
    $Dx.Trend = @($mine | Select-Object -Last 5 | ForEach-Object { [ordered]@{ Created = (Format-T (ConvertTo-Date (Get-Prop $_ 'Created'))); Health = [int](Get-Prop $_ 'Health') } })   # PS7 은 JSON 날짜를 DateTime 으로 읽으므로 형식 통일
    $pt = ConvertTo-Date (Get-Prop $prev 'Created'); if (-not $pt) { return }
    $new = Get-NewSince $Data $pt
    $total = 0; foreach ($k in $new.Keys) { $total += $new[$k] }
    $Dx.Previous = [ordered]@{ Created = (Format-T $pt); Health = [int](Get-Prop $prev 'Health'); New = $new; NewTotal = $total }
}
function Add-History($Data, $Dx) {
    $h = @(Read-History) + @([ordered]@{ Created = (Get-Prop (Get-Prop $Data 'Meta') 'Created'); Computer = (Get-Prop (Get-Prop $Data 'Meta') 'Computer'); Health = $Dx.Health; Counts = $Dx.Counts })
    if ($h.Count -gt 50) { $h = $h[($h.Count - 50)..($h.Count - 1)] }
    $json = ConvertTo-Json -InputObject @($h) -Depth 5
    foreach ($p in (Get-HistoryPaths)) {
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path $p) | Out-Null
            [IO.File]::WriteAllText($p, $json, (New-Object System.Text.UTF8Encoding($true)))
        } catch { Write-PCLog "history save failed ($p): $($_.Exception.Message)" }
    }
}

function Save-Results {
    param($Data, $Dx, [string]$Dir, [switch]$Track)
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }
    if ($Track) { Add-Comparison $Data $Dx (Read-History) }
    $stamp = (ConvertTo-Date (Get-Prop (Get-Prop $Data 'Meta') 'Created')); if (-not $stamp) { $stamp = Get-Date }
    $base = Join-Path $Dir ("{0}_{1:yyyyMMdd_HHmmss}" -f (Get-OutputPrefix), $stamp)
    $html = New-HtmlReport -Data $Data -Dx $Dx
    $utf8 = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText("$base.html", $html, $utf8)
    [IO.File]::WriteAllText("$base.json", (ConvertTo-Json -InputObject $Data -Depth 6), $utf8)
    # 메신저로 바로 보낼 수 있는 짧은 요약 (원인 Top 3 · 지금 할 일)
    [IO.File]::WriteAllText("$base.txt", (Get-SummaryText $Data $Dx), $utf8)
    if ($Track) { Add-History $Data $Dx }
    return [pscustomobject]@{ Html = "$base.html"; Json = "$base.json"; Txt = "$base.txt" }
}

# =====================================================================
#  블랙박스 (실시간 기록) — 노하드처럼 재부팅하면 기록이 사라지는 PC 용
#   부하 테스트 중 상태를 USB 등에 '바로바로' 기록하고,
#   PC 가 꺼진 뒤 그 파일로 직전 상황(어느 단계·어떤 상태였는지)을 분석합니다.
# =====================================================================
$script:BlackboxColsV1 = 'Time,CpuPct,MemPct,GpuTempC,GpuUtilPct,GpuPowerW,GpuClockMHz,GpuMemMB,CpuStress,GpuStress,Event'
$script:BlackboxCols = 'Time,Stage,CpuPct,CpuPerfPct,MemPct,BoardTempC,GpuTempC,GpuUtilPct,GpuPowerW,GpuClockMHz,GpuMemMB,GpuThrottle,CpuStress,GpuStress,RamTest,RamErrors,GpuTestErr,Event'

# 단계별 자동 정밀 테스트 (꺼진 단계로 원인을 좁힘)
$script:StagePlan = @(
    @{ Key = 'idle';  Name = '대기 (기준값)';        Sec = 120; Cpu = $false; Gpu = $false; Ram = $false; Pulse = $false }
    @{ Key = 'cpu';   Name = 'CPU 단독 부하';        Sec = 360; Cpu = $true;  Gpu = $false; Ram = $false; Pulse = $false }
    @{ Key = 'ram';   Name = 'RAM 검사';             Sec = 360; Cpu = $false; Gpu = $false; Ram = $true;  Pulse = $false }
    @{ Key = 'gpu';   Name = 'GPU·VRAM 단독 부하';    Sec = 360; Cpu = $false; Gpu = $true;  Ram = $false; Pulse = $false }
    @{ Key = 'full';  Name = '전체 부하 (CPU+GPU)';   Sec = 480; Cpu = $true;  Gpu = $true;  Ram = $false; Pulse = $false }
    @{ Key = 'pulse'; Name = '전력 출렁임 (10초 간격)'; Sec = 240; Cpu = $true;  Gpu = $true;  Ram = $false; Pulse = $true }
)
function Get-StageAt($Plan, [double]$Elapsed) {
    # 경과 시간(초)에 해당하는 단계와 그 순간 켜야 할 부하
    $t = 0.0; $i = 0
    foreach ($st in $Plan) {
        if ($Elapsed -lt $t + $st.Sec) {
            $cpuOn = $st.Cpu
            if ($st.Pulse) { $cpuOn = ([math]::Floor(($Elapsed - $t) / 10) % 2) -eq 0 }
            $total = 0; foreach ($q in $Plan) { $total += $q.Sec }
            return [pscustomobject]@{ Index = $i; Count = $Plan.Count; Key = $st.Key; Name = $st.Name; Remaining = [int]($t + $st.Sec - $Elapsed); Cpu = $cpuOn; Gpu = $st.Gpu; Ram = $st.Ram; Done = $false; TotalSec = $total }
        }
        $t += $st.Sec; $i++
    }
    return [pscustomobject]@{ Index = $Plan.Count; Count = $Plan.Count; Key = 'done'; Name = '완료'; Remaining = 0; Cpu = $false; Gpu = $false; Ram = $false; Done = $true; TotalSec = $t }
}

# 별도 실행 공간(백그라운드 수집·블랙박스)에 넘겨야 하는 설정값 — 새 전역 설정을 만들면 여기에 추가
$script:SharedVars = @('AppName', 'AppVersion', 'LogFile', 'IsWin', 'WorkDir', 'GpuPerfSource', 'RamTestSource', 'BlackboxCols', 'BlackboxColsV1', 'StagePlan', 'MemtestPinned', 'UiLang', 'EnPairs')
function New-PCRunspace {
    # 이 스크립트의 함수·설정을 그대로 가진 별도 실행 공간
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($fn in @(Get-ChildItem function:)) {
        if ($fn.ScriptBlock) { $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fn.Name, $fn.Definition))) }
    }
    foreach ($v in $script:SharedVars) {
        $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry($v, (Get-Variable -Name $v -Scope Script -ValueOnly -ErrorAction SilentlyContinue), '')))
    }
    $rs = [runspacefactory]::CreateRunspace($iss); $rs.Open()
    return $rs
}

function Write-DurableLine([string]$Path, [string]$Line) {
    # 전원이 갑자기 끊겨도 남도록 한 줄씩 디스크에 직접 기록 (WriteThrough + Flush)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Line + "`r`n")
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite, 4096, [IO.FileOptions]::WriteThrough)
    try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
}

# ---- Windows 안에서 하는 RAM 검사 (재부팅 불필요 — 노하드에서도 결과가 USB 에 남음)
$script:RamTestSource = @'
using System;
using System.Collections.Generic;
using System.Threading;
public static class PCCheckRamTest {
    public static volatile bool StopFlag;
    public static volatile bool Running;
    public static long Errors, TestedMB, Passes;
    public static string LastError = "";
    static Thread worker;
    public static void Start(int megabytes) {
        if (Running) return;
        StopFlag = false; Errors = 0; TestedMB = 0; Passes = 0; LastError = "";
        worker = new Thread(() => Run(megabytes)); worker.IsBackground = true; worker.Priority = ThreadPriority.BelowNormal;
        Running = true; worker.Start();
    }
    public static void Stop() {
        StopFlag = true; if (worker != null) worker.Join(15000); Running = false;
        // 다음 단계(GPU·전체 부하)가 메모리 부족 상태로 돌지 않도록 즉시 반환
        GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
    }
    static void Run(int megabytes) {
        var blocks = new List<long[]>();
        try {
            const int blockLongs = 64 * 1024 * 1024 / 8;   // 64MB 블록
            int count = Math.Max(1, megabytes / 64);
            for (int b = 0; b < count && !StopFlag; b++) {
                try { blocks.Add(new long[blockLongs]); } catch (OutOfMemoryException) { break; }
            }
            ulong seed = 0x9E3779B97F4A7C15UL;
            while (!StopFlag) {
                for (int p = 0; p < 4 && !StopFlag; p++) {
                    for (int b = 0; b < blocks.Count && !StopFlag; b++) {
                        long[] a = blocks[b]; long baseIx = (long)b * a.Length;
                        ulong x = seed ^ (ulong)(b + 1) * 0xBF58476D1CE4E5B9UL ^ (ulong)p;
                        for (int i = 0; i < a.Length; i++) a[i] = Pat(p, baseIx + i, ref x);
                        x = seed ^ (ulong)(b + 1) * 0xBF58476D1CE4E5B9UL ^ (ulong)p;
                        for (int i = 0; i < a.Length; i++) {
                            long want = Pat(p, baseIx + i, ref x);
                            if (a[i] != want) { Interlocked.Increment(ref Errors); LastError = string.Format("block {0} index {1} pattern {2}", b, i, p); }
                        }
                        Interlocked.Add(ref TestedMB, 64);
                    }
                }
                Interlocked.Increment(ref Passes);
                seed = seed * 6364136223846793005UL + 1442695040888963407UL;
            }
        } catch (Exception e) { LastError = e.Message; }
        finally { blocks.Clear(); Running = false; }
    }
    static long Pat(int p, long addr, ref ulong x) {
        switch (p) {
            case 0: return addr;                                  // 주소 패턴
            case 1: return ~addr;                                 // 반전 주소
            case 2: return (addr & 1) == 0 ? 0x5555555555555555L : unchecked((long)0xAAAAAAAAAAAAAAAAUL);  // 교차 비트
            default: x ^= x << 13; x ^= x >> 7; x ^= x << 17; return unchecked((long)x);  // 난수
        }
    }
}
'@
function Initialize-RamTest { if (-not ('PCCheckRamTest' -as [type])) { Add-Type -TypeDefinition $script:RamTestSource -ErrorAction Stop } }
function Get-RamTestSizeMB {
    # 여유 메모리의 70% (최소 256MB, Windows 와 다른 작업용으로 1.5GB 는 남김)
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $freeMB = [int]($os.FreePhysicalMemory / 1024)
        return [int][math]::Max(256, [math]::Min($freeMB * 0.7, $freeMB - 1536))   # int-ok: 정수 결과가 의도됨
    } catch { return 512 }
}
function Start-RamTest([int]$MB = 0) { Initialize-RamTest; if ($MB -le 0) { $MB = Get-RamTestSizeMB }; [PCCheckRamTest]::Start($MB) }
function Stop-RamTest { if ('PCCheckRamTest' -as [type]) { [PCCheckRamTest]::Stop() } }
function Get-RamTestState {
    if (-not ('PCCheckRamTest' -as [type])) { return [pscustomobject]@{ Running = $false; Errors = 0; TestedMB = 0; Passes = 0 } }
    return [pscustomobject]@{ Running = [PCCheckRamTest]::Running; Errors = [PCCheckRamTest]::Errors; TestedMB = [PCCheckRamTest]::TestedMB; Passes = [PCCheckRamTest]::Passes }
}

function ConvertFrom-NvThrottle([string]$Hex) {
    # NVIDIA 클럭 제한 원인 비트 → 짧은 코드 (HWSLOW·PBRAKE 는 전원 공급 문제 신호)
    $v = 0L
    if (-not $Hex -or -not [long]::TryParse(($Hex -replace '^0x', ''), [Globalization.NumberStyles]::HexNumber, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return '' }
    $o = @()
    if ($v -band 0x4) { $o += 'PWRCAP' }
    if ($v -band 0x8) { $o += 'HWSLOW' }
    if ($v -band 0x20) { $o += 'SWTHERM' }
    if ($v -band 0x40) { $o += 'HWTHERM' }
    if ($v -band 0x80) { $o += 'PBRAKE' }
    return ($o -join '+')
}

function Get-LiveSample {
    $s = [ordered]@{ Time = (Format-T (Get-Date)); CpuPct = $null; CpuPerfPct = $null; MemPct = $null; BoardTempC = $null; GpuTempC = $null; GpuUtilPct = $null; GpuPowerW = $null; GpuClockMHz = $null; GpuMemMB = $null; GpuThrottle = '' }
    try { $s.CpuPct = [int](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorTime } catch {}
    try { $s.CpuPerfPct = [int](Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorPerformance } catch {}
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop; $s.MemPct = [int](100 - 100 * $os.FreePhysicalMemory / $os.TotalVisibleMemorySize) } catch {}
    try { $tz = @(Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop | ForEach-Object { [math]::Round($_.CurrentTemperature / 10 - 273.15, 1) } | Where-Object { $_ -gt 0 -and $_ -lt 130 }); if ($tz.Count) { $s.BoardTempC = ($tz | Measure-Object -Maximum).Maximum } } catch {}
    $nv = $null
    foreach ($c in @("$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe")) { if ($c -and (Test-Path $c)) { $nv = $c; break } }
    if ($nv) {
        $num = { param($x) $r = 0.0; if ([double]::TryParse(($x -replace '[^\d\.]', ''), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$r)) { $r } else { $null } }
        try {
            $c = ([string](@(& $nv '--query-gpu=temperature.gpu,utilization.gpu,power.draw,clocks.gr,memory.used' '--format=csv,noheader,nounits' 2>$null)[0])) -split ',\s*'
            if ($c.Count -ge 5) { $s.GpuTempC = & $num $c[0]; $s.GpuUtilPct = & $num $c[1]; $s.GpuPowerW = & $num $c[2]; $s.GpuClockMHz = & $num $c[3]; $s.GpuMemMB = & $num $c[4] }
        } catch {}
        try {
            $th = [string](@(& $nv '--query-gpu=clocks_event_reasons.active' '--format=csv,noheader' 2>$null)[0])
            if ($th -notmatch '^0x') { $th = [string](@(& $nv '--query-gpu=clocks_throttle_reasons.active' '--format=csv,noheader' 2>$null)[0]) }
            $s.GpuThrottle = ConvertFrom-NvThrottle $th.Trim()
        } catch {}
    }
    if ($null -eq $s.GpuTempC) { $g = @(Get-GpuSensors) | Select-Object -First 1; if ($g) { $s.GpuTempC = $g.TempC } }
    return $s
}

function Get-RecentHwEvents([datetime]$Since) {
    # 기록 중 새로 생긴 하드웨어/그래픽 오류 (짧은 코드로)
    $out = @()
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $Since; ProviderName = @('Microsoft-Windows-WHEA-Logger', 'Display', 'nvlddmkm', 'amdkmdag', 'disk', 'Ntfs') } -MaxEvents 20 -ErrorAction Stop)
        foreach ($e in $ev) {
            $code = switch ($e.ProviderName) {
                'Microsoft-Windows-WHEA-Logger' { "WHEA $($e.Id)" }
                'Display' { 'TDR' }
                'nvlddmkm' { $t = Get-EventText $e; if ($t -match 'Xid[^:\d]*(?:\([^)]*\))?\s*:?\s*(\d{1,3})\b') { "Xid $($Matches[1])" } else { "NVIDIA $($e.Id)" } }
                'amdkmdag' { "AMD $($e.Id)" }
                default { "DISK $($e.Id)" }
            }
            $out += $code
        }
    } catch {}
    return $out
}

function Get-BlackboxDefaultDir {
    # 이동식 디스크(USB)가 있으면 그곳, 없으면 바탕화면 (노하드에서는 재부팅 시 사라짐)
    try {
        $usb = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction Stop | Where-Object { $_.FreeSpace -gt 10MB }) | Select-Object -First 1
        if ($usb) { return [pscustomobject]@{ Dir = (Join-Path ($usb.DeviceID + '\') 'PCCheck_blackbox'); Removable = $true } }
    } catch {}
    $desk = [Environment]::GetFolderPath('Desktop'); if (-not $desk) { $desk = [IO.Path]::GetTempPath() }
    return [pscustomobject]@{ Dir = (Join-Path $desk 'PCCheck_blackbox'); Removable = $false }
}

function Start-Blackbox {
    param([string]$Dir, [double]$IntervalSec = 1, [switch]$NoEvents)
    if (-not $Dir) { $Dir = (Get-BlackboxDefaultDir).Dir }
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    Add-BlackboxDirMemory $Dir
    $path = Join-Path $Dir ("PCCheck_blackbox_{0}_{1:yyyyMMdd_HHmmss}.csv" -f $env:COMPUTERNAME, (Get-Date))
    $sync = [hashtable]::Synchronized(@{ Stop = $false; Path = $path; Rows = 0; Last = $null; Stage = ''; CpuStress = $false; GpuStress = $false; Error = $null; Done = $false; Events = 0; GpuLog = ''; GpuSeen = ''; Pending = ''; Warn = '' })
    Write-DurableLine $path ("# PCCheck blackbox,v2,{0},{1},{2}" -f $env:COMPUTERNAME, (Format-T (Get-Date)), $script:AppVersion)
    Write-DurableLine $path $script:BlackboxCols
    $rs = New-PCRunspace
    $rs.SessionStateProxy.SetVariable('sync', $sync)
    $rs.SessionStateProxy.SetVariable('interval', $IntervalSec)
    $rs.SessionStateProxy.SetVariable('noEvents', [bool]$NoEvents)
    $rs.SessionStateProxy.SetVariable('origPath', $path)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
        $endLine = { param($ev) (@((Format-T (Get-Date))) + @('') * ($script:BlackboxCols.Split(',').Count - 2) + @($ev)) -join ',' }
        try {
            $lastPoll = Get-Date; $n = 0; $fails = 0
            while (-not $sync.Stop) {
              # 한 번의 센서·쓰기 오류(USB 순간 끊김 등)로 기록 전체가 멈추면 '갑자기 꺼짐'으로 오판되므로 잠시 후 다시 시도
              $ev = ''
              try {
                $s = Get-LiveSample
                $ram = Get-RamTestState
                $ev = Get-BlackboxPending $sync   # 화면 쪽에서 알려 온 사건 (예: GPU 도구 실패)
                $gpuErr = $null
                if ($sync.GpuLog -and ($n % 3) -eq 0) {
                    # memtest_vulkan 출력에서 VRAM 오류·장치 끊김·시작 실패를 읽어 기록
                    $g = Get-GpuLoadStatus $sync.GpuLog
                    $gpuErr = $g.Errors; $sync.GpuErrors = $g.Errors
                    foreach ($k in 'GPUFAIL', 'GPULOST') {
                        if ((($k -eq 'GPUFAIL' -and $g.InitFailed) -or ($k -eq 'GPULOST' -and $g.DeviceLost)) -and $sync.GpuSeen -notmatch $k) { $sync.GpuSeen += " $k"; $ev = ($ev + ' ; ' + $k).Trim(' ;') }
                    }
                } elseif ($null -ne $sync.GpuErrors) { $gpuErr = $sync.GpuErrors }
                if (-not $noEvents -and ($n % 5) -eq 4) {
                    $now = Get-Date; $codes = @(Get-RecentHwEvents $lastPoll); $lastPoll = $now
                    if ($codes.Count) { $ev = (@($ev) + $codes | Where-Object { $_ }) -join ' ; '; $sync.Events += $codes.Count }
                }
                $vals = @($s.Time, $sync.Stage, $s.CpuPct, $s.CpuPerfPct, $s.MemPct, $s.BoardTempC, $s.GpuTempC, $s.GpuUtilPct, $s.GpuPowerW, $s.GpuClockMHz, $s.GpuMemMB, $s.GpuThrottle,
                    [int][bool]$sync.CpuStress, [int][bool]$sync.GpuStress, [int][bool]$ram.Running, $ram.Errors, $gpuErr, ($ev -replace ',', ';'))
                Write-DurableLine $sync.Path (($vals | ForEach-Object { ConvertTo-CsvField $_ }) -join ',')
                $sync.Rows++; $sync.Last = $s; $n++; $fails = 0; $sync.Warn = ''
              } catch {
                $fails++; $sync.Warn = $_.Exception.Message
                if ($ev) { Add-BlackboxEvent $sync $ev -Front }   # 기록하지 못한 사건은 다음 줄에 다시 기록
                if ($fails -ge 10) { throw }
              }
                $until = (Get-Date).AddSeconds($interval)
                while (-not $sync.Stop -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 100 }
            }
            Write-DurableLine $sync.Path (& $endLine 'STOP')
        } catch {
            $sync.Error = $_.Exception.Message
            # 기록 오류로 멈춘 것을 남겨 두어 분석에서 전원 차단으로 오판하지 않게 함 (처음 파일에 기록)
            try { Write-DurableLine $origPath (& $endLine 'LOGERR'); Write-DurableLine $origPath (& $endLine 'STOP') } catch {}
        } finally { $sync.Done = $true }
    })
    $h = $ps.BeginInvoke()
    return [pscustomobject]@{ Sync = $sync; PS = $ps; Handle = $h; Runspace = $rs; Path = $path }
}

function Stop-Blackbox($Job, [int]$TimeoutSec = 10) {
    if (-not $Job) { return }
    $Job.Sync.Stop = $true
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $Job.Sync.Done -and $sw.Elapsed.TotalSeconds -lt $TimeoutSec) { Start-Sleep -Milliseconds 100 }
    try { [void]$Job.PS.EndInvoke($Job.Handle) } catch {}
    try { $Job.PS.Dispose(); $Job.Runspace.Dispose() } catch {}
}

function Start-CpuStress {
    # 모든 CPU 스레드에 계산 부하. Pause 로 순간적으로 껐다 켤 수 있음 (전력 출렁임 시험)
    param([int]$Threads = 0)
    if ($Threads -le 0) { $Threads = [Environment]::ProcessorCount }
    $sync = [hashtable]::Synchronized(@{ Stop = $false; Pause = $false })
    $pool = [runspacefactory]::CreateRunspacePool(1, $Threads); $pool.Open()
    $jobs = @()
    for ($i = 0; $i -lt $Threads; $i++) {
        $ps = [powershell]::Create(); $ps.RunspacePool = $pool
        [void]$ps.AddScript({ param($sync) while (-not $sync.Stop) { if ($sync.Pause) { Start-Sleep -Milliseconds 50; continue }; $x = 0.0; for ($k = 1; $k -lt 100000; $k++) { $x += [math]::Sqrt($k) * [math]::Sin($k) } } }).AddArgument($sync)
        $jobs += [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke() }
    }
    return [pscustomobject]@{ Sync = $sync; Pool = $pool; Jobs = $jobs; Threads = $Threads }
}
function Stop-CpuStress($Job) {
    if (-not $Job) { return }
    $Job.Sync.Stop = $true
    foreach ($j in $Job.Jobs) { try { [void]$j.PS.EndInvoke($j.Handle) } catch {}; try { $j.PS.Dispose() } catch {} }
    try { $Job.Pool.Dispose() } catch {}
}

function Add-BlackboxEvent($Sync, [string]$Code, [switch]$Front) {
    # 화면 쪽 사건을 기록기에 전달 (덮어쓰지 않고 이어 붙임 — 연달아 생긴 사건도 모두 기록)
    [Threading.Monitor]::Enter($Sync.SyncRoot)
    try {
        $cur = [string]$Sync.Pending
        if (-not $cur) { $Sync.Pending = $Code } elseif ($Front) { $Sync.Pending = "$Code ; $cur" } else { $Sync.Pending = "$cur ; $Code" }
    } finally { [Threading.Monitor]::Exit($Sync.SyncRoot) }
}
function Get-BlackboxPending($Sync) {
    [Threading.Monitor]::Enter($Sync.SyncRoot)
    try { $v = [string]$Sync.Pending; $Sync.Pending = ''; return $v } finally { [Threading.Monitor]::Exit($Sync.SyncRoot) }
}
function Get-StabilitySummary($Values) {
    # 안정성 지수 기록 → 최근값·최저값·평균 (기록 없으면 $null)
    $v = @(@(Get-Arr $Values) | Where-Object { $null -ne (Get-Prop $_ 'V') } | Sort-Object { [string](Get-Prop $_ 'T') })
    if (-not $v.Count) { return $null }
    $nums = @($v | ForEach-Object { [double](Get-Prop $_ 'V') })
    $mo = $nums | Measure-Object -Minimum -Average
    return [ordered]@{ Latest = $nums[-1]; LatestT = [string](Get-Prop $v[-1] 'T'); Min = $mo.Minimum; Avg = [math]::Round($mo.Average, 1); Count = $nums.Count }
}
function Get-DayChoices([int]$Days) {
    # 화면의 분석 기간 목록: 기본 7·30·90·180일 + 명령줄로 받은 값 (오름차순)
    return @(@(7, 30, 90, 180) + @($Days) | Where-Object { $_ -ge 1 -and $_ -le 365 } | Sort-Object -Unique)
}
function Get-ShopText([string]$Shop, [string]$Dir) {
    # 매장(점검자) 이름·연락처: -Shop 값, 없으면 프로그램 옆 shop.txt 첫 줄 (보고서·요약에 표시, 최대 100자)
    $t = $Shop
    if (-not $t) {
        if (-not $Dir) { $Dir = $(if ($PSScriptRoot) { $PSScriptRoot } else { [AppDomain]::CurrentDomain.BaseDirectory }) }
        $f = Join-Path $Dir 'shop.txt'
        if (Test-Path $f) { try { $t = @(Get-Content -Encoding UTF8 $f | Where-Object { $_.Trim() })[0] } catch {} }
    }
    $t = ([string]$t).Trim()
    if ($t.Length -gt 100) { $t = $t.Substring(0, 100) }
    return $t
}
function Get-BlackboxCloseQuestion($State) {
    # 기록 중 창을 닫으려 할 때 물어볼 문구 (기록 중이 아니면 빈 값)
    if (-not $State -or -not $State.Box) { return '' }
    return "블랙박스 기록 중입니다 ($($State.Box.Sync.Rows) 줄).`n기록을 멈추고 창을 닫을까요?"
}
function Get-BlackboxWarnText($Sync) {
    # 기록기가 쓰기를 다시 시도하는 중이면 화면에 알림 (USB 가 빠지면 기록이 남지 않으므로)
    if ($Sync -and [string]$Sync.Warn) { return "`n기록 쓰기 실패 — 다시 시도 중 (USB 연결·여유 공간 확인)" }
    return ''
}
function Test-OverheatGuard([hashtable]$State, $GpuTempC, [double]$LimitC = 95, [int]$Count = 3) {
    # 과열 보호: GPU 온도가 한계 이상으로 연속 Count 회(약 Count 초) 이어지면 $true (부하를 멈춰야 함)
    if ($null -ne $GpuTempC -and "$GpuTempC" -ne '' -and [double]$GpuTempC -ge $LimitC) { $State.Hot = 1 + [int]$State.Hot } else { $State.Hot = 0 }
    return ([int]$State.Hot -ge $Count)
}
function Start-GpuLoad([string]$LogPath) {
    # memtest_vulkan (Windows 에서는 입력 없이 바로 시작). 출력은 파일로 받아 오류를 기록에 반영
    $p = Install-MemtestVulkan
    if ($LogPath) { return (Start-Process -FilePath $p -WorkingDirectory (Split-Path $p) -RedirectStandardOutput $LogPath -RedirectStandardError ($LogPath + '.err') -WindowStyle Minimized -PassThru) }
    return (Start-Process -FilePath $p -WorkingDirectory (Split-Path $p) -PassThru)
}
function Get-GpuLoadStatus([string]$LogPath) {
    # memtest_vulkan 출력 해석: 'Error found' 줄 수, ERROR_DEVICE_LOST, 'early exit during init'
    $r = [pscustomobject]@{ Errors = 0; DeviceLost = $false; InitFailed = $false; Passed = $false; Testing = $false }
    $txt = ''
    foreach ($f in @($LogPath, ($LogPath + '.err'))) {
        if ($f -and (Test-Path $f)) { try { $fs = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite'); try { $txt += (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() } } catch {} }
    }
    if (-not $txt) { return $r }
    $r.Errors = ([regex]::Matches($txt, '(?im)^\s*Error found')).Count
    $r.DeviceLost = $txt -match 'ERROR_DEVICE_LOST'
    $r.InitFailed = $txt -match 'early exit during init'
    $r.Passed = $txt -match 'PASSed'
    $r.Testing = $txt -match '(?m)^\s*Testing\s+\d'
    return $r
}
function Stop-GpuLoad($Proc) { if ($Proc) { try { if (-not $Proc.HasExited) { $Proc.Kill() } } catch {} } }

function Read-BlackboxAnalysis([string]$Path) {
    # 블랙박스 기록 분석 (순수 함수) — 마지막 상태와 '어느 단계'에서 끊겼는지로 원인 추정
    $lines = @(Get-Content -Path $Path -Encoding UTF8 -ErrorAction Stop)
    $cols = $script:BlackboxColsV1 -split ','
    foreach ($l in $lines) { if ($l -and $l.StartsWith('Time,')) { $cols = $l.Trim() -split ','; break } }
    # 긴 기록(수 시간 = 수만 줄)에서 배열 += 는 줄 수의 제곱으로 느려지므로 List 에 모은 뒤 배열로 변환
    $rowList = New-Object System.Collections.Generic.List[object]; $stopped = $false; $events = @{}
    foreach ($l in $lines) {
        if (-not $l -or $l.StartsWith('#') -or $l.StartsWith('Time,')) { continue }
        $v = $l -split ','
        if ($v.Count -lt $cols.Count) { continue }   # 전원 차단으로 잘린 마지막 줄
        $r = @{}
        for ($i = 0; $i -lt $cols.Count; $i++) { $r[$cols[$i]] = $v[$i] }
        if ($r['Event'] -eq 'STOP') { $stopped = $true; continue }
        if ($r['Event']) { foreach ($e in ($r['Event'] -split '\s*;\s*')) { if ($e) { $events[$e] = 1 + [int]$events[$e] } } }
        $rowList.Add($r)
    }
    $rows = $rowList.ToArray()
    $num = { param($x) $d = 0.0; if ($null -ne $x -and [double]::TryParse([string]$x, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { $d } else { $null } }
    # 긴 기록에서도 빠르도록 스크립트 블록 호출 없이 바로 변환
    $maxOf = { param($set, $col) $m = $null; $d = 0.0; $inv = [Globalization.CultureInfo]::InvariantCulture; $fl = [Globalization.NumberStyles]::Float
        foreach ($r in $set) { if ([double]::TryParse([string]$r[$col], $fl, $inv, [ref]$d) -and ($null -eq $m -or $d -gt $m)) { $m = $d } }; $m }
    $res = [ordered]@{
        File = [IO.Path]::GetFileName($Path); Rows = $rows.Count; Stopped = $stopped; Abrupt = $false
        Start = $null; End = $null; Minutes = 0
        MaxGpuTempC = (& $maxOf $rows 'GpuTempC'); MaxGpuPowerW = (& $maxOf $rows 'GpuPowerW'); MaxCpuPct = (& $maxOf $rows 'CpuPct'); MaxBoardTempC = (& $maxOf $rows 'BoardTempC')
        RamErrors = [int](& $maxOf $rows 'RamErrors'); GpuTestErrors = [int](& $maxOf $rows 'GpuTestErr'); LastStage = ''; Stages = @(); Throttle = @(); Notes = @()
        Last = $null; Events = $events; Level = 'ok'; Cause = ''; Title = ''; Detail = ''
    }
    if ($rows.Count -eq 0) { $res.Title = '블랙박스 기록이 비어 있음'; $res.Level = 'info'; return $res }
    $res.Start = $rows[0]['Time']; $res.End = $rows[-1]['Time']
    $t0 = ConvertTo-Date $res.Start; $t1 = ConvertTo-Date $res.End
    if ($t0 -and $t1) { $res.Minutes = [math]::Round(($t1 - $t0).TotalMinutes, 1) }
    $res.LastStage = [string]$rows[-1]['Stage']
    # 그래프용 요약 계열 (최대 300점으로 줄여 보관)
    $step = [math]::Max(1, [math]::Ceiling($rows.Count / 300.0))   # int-ok: 정수 결과가 의도됨
    $ser = [ordered]@{ Sec = @(); Temp = @(); Pow = @(); Cpu = @(); Stage = @() }
    for ($i = 0; $i -lt $rows.Count; $i += $step) {
        $r = $rows[$i]; $tt = ConvertTo-Date $r['Time']
        $ser.Sec += $(if ($t0 -and $tt) { [int]($tt - $t0).TotalSeconds } else { $i })
        $ser.Temp += (& $num $r['GpuTempC']); $ser.Pow += (& $num $r['GpuPowerW']); $ser.Cpu += (& $num $r['CpuPct']); $ser.Stage += [string]$r['Stage']
    }
    $res.Series = $ser

    # 단계별 요약
    $stageNames = @{}; foreach ($p in $script:StagePlan) { $stageNames[$p.Key] = $p.Name }
    $stageNames['manual'] = '직접 설정'   # 직접 설정 모드 기록
    $order = New-Object System.Collections.Generic.List[string]; $byStage = @{}
    foreach ($r in $rows) { $k = [string]$r['Stage']; if (-not $k) { continue }; if (-not $byStage.ContainsKey($k)) { $order.Add($k); $byStage[$k] = New-Object System.Collections.Generic.List[object] }; $byStage[$k].Add($r) }
    foreach ($k in $order) {
        $set = $byStage[$k].ToArray()
        $res.Stages += [ordered]@{ Key = $k; Name = $(if ($stageNames.ContainsKey($k)) { $stageNames[$k] } else { $k }); Rows = $set.Count; MaxGpuTempC = (& $maxOf $set 'GpuTempC'); MaxGpuPowerW = (& $maxOf $set 'GpuPowerW'); MaxCpuPct = (& $maxOf $set 'CpuPct') }
    }
    $thr = @{}; foreach ($r in $rows) { foreach ($x in ([string]$r['GpuThrottle'] -split '\+')) { if ($x -and $x -ne 'PWRCAP') { $thr[$x] = 1 + [int]$thr[$x] } } }
    $res.Throttle = @($thr.Keys | Sort-Object)

    # 직전 상태 (마지막 5줄)
    $tail = @($rows | Select-Object -Last 5)
    $lastLoad = 0.0; $lastTemp = $null; $lastPow = $null; $stress = $false
    foreach ($r in $tail) {
        $c = & $num $r['CpuPct']; $g = & $num $r['GpuUtilPct']; $t = & $num $r['GpuTempC']; $p = & $num $r['GpuPowerW']
        if ($null -ne $c -and $c -gt $lastLoad) { $lastLoad = $c }; if ($null -ne $g -and $g -gt $lastLoad) { $lastLoad = $g }
        if ($null -ne $t -and ($null -eq $lastTemp -or $t -gt $lastTemp)) { $lastTemp = $t }
        if ($null -ne $p -and ($null -eq $lastPow -or $p -gt $lastPow)) { $lastPow = $p }
        if ($r['CpuStress'] -eq '1' -or $r['GpuStress'] -eq '1') { $stress = $true }
    }
    $res.Last = [ordered]@{ Time = $res.End; LoadPct = $lastLoad; GpuTempC = $lastTemp; GpuPowerW = $lastPow; Stress = $stress; Stage = $res.LastStage }
    $evText = (($events.Keys | Sort-Object | ForEach-Object { "$_ ×$($events[$_])" }) -join ', ')

    # 부가 신호
    if ($res.RamErrors -gt 0) { $res.Notes += "RAM 검사 오류 $($res.RamErrors) 건 (RAM 불량이 거의 확실)" }
    if ($res.GpuTestErrors -gt 0) { $res.Notes += "VRAM 검사 오류 $($res.GpuTestErrors) 건 (그래픽카드 메모리 불량 의심)" }
    if ($events.ContainsKey('LOGERR')) { $res.Notes += '기록 오류로 기록이 중간에 멈춤 (USB 연결·여유 공간 확인)' }
    if ($events.ContainsKey('GPULOST')) { $res.Notes += '그래픽카드 연결 끊김 (ERROR_DEVICE_LOST)' }
    $gpuFail = $events.ContainsKey('GPUFAIL')
    if ($gpuFail) { $res.Notes += 'GPU 부하 도구가 시작되지 못해 GPU 단계는 시험되지 않음 (Vulkan 드라이버 확인)' }
    if ($thr.ContainsKey('HWSLOW') -or $thr.ContainsKey('PBRAKE')) { $res.Notes += '그래픽카드 하드웨어 감속 신호 (전원 공급 불안정 또는 과열)' }
    if ($thr.ContainsKey('HWTHERM') -or $thr.ContainsKey('SWTHERM')) { $res.Notes += '그래픽카드 온도 제한 동작' }
    $cpuSet = @($(if ($byStage.ContainsKey('cpu')) { $byStage['cpu'].ToArray() }) | Where-Object { $null -ne $_ -and (& $num $_['CpuPct']) -ge 80 })
    $perf = @($cpuSet | ForEach-Object { & $num $_['CpuPerfPct'] } | Where-Object { $null -ne $_ -and $_ -gt 0 })
    if ($perf.Count -ge 5 -and ($perf | Measure-Object -Minimum).Minimum -lt 60) { $res.Notes += "CPU 부하 중 클럭이 $([int]($perf | Measure-Object -Minimum).Minimum)% 까지 떨어짐 (과열·전력 제한)" }
    $noteText = $(if ($res.Notes.Count) { ' ' + (($res.Notes | ForEach-Object { "[$_]" }) -join ' ') } else { '' })

    # GPU 도구가 돌지 않았다면 GPU 가 들어간 단계는 실제 부하 기준으로 다시 해석 (GPU 단독 → 대기, 전체·출렁임 → CPU 단독)
    $effStage = $res.LastStage
    if ($events.ContainsKey('GPUFAIL')) { if ($effStage -eq 'gpu') { $effStage = 'idle' } elseif ($effStage -in 'full', 'pulse') { $effStage = 'cpu' } }
    if (-not $stopped) {
        $res.Abrupt = $true; $res.Level = 'bad'
        $stName = $(if ($res.LastStage -and $stageNames.ContainsKey($res.LastStage)) { $stageNames[$res.LastStage] } else { '' })
        $state = "마지막 기록 $(([string]$res.End).Replace('T', ' ')) · 부하 $([int]$lastLoad)% · GPU $(if ($null -ne $lastTemp) { "$lastTemp °C" } else { '온도 미상' })$(if ($null -ne $lastPow) { " · $lastPow W" })"
        if ($stName) { $state = "[$stName 단계] " + $state }
        if ($null -ne $lastTemp -and $lastTemp -ge 88) {
            $res.Cause = 'THERMAL'; $res.Title = '블랙박스: 고온 상태에서 기록이 끊김 (과열 의심)'
            $res.Detail = "$state. 꺼지기 직전 그래픽카드 온도가 매우 높았습니다. 쿨링(팬·먼지·써멀)을 먼저 점검하세요."
        } elseif ($effStage -eq 'pulse') {
            $res.Cause = 'PSU'; $res.Title = '블랙박스: 전력 출렁임 단계에서 꺼짐 (파워 품질·노후 의심)'
            $res.Detail = "$state. 부하가 급하게 바뀌는 순간을 파워가 버티지 못했습니다. 용량이 충분해도 노후·저품질 파워에서 흔한 패턴입니다. 파워 교체 1순위."
        } elseif ($effStage -eq 'full') {
            $res.Cause = 'PSU'; $res.Title = '블랙박스: 전체 부하 단계에서 꺼짐 (파워 용량 부족 의심)'
            $res.Detail = "$state. CPU·GPU 를 각각 돌릴 때는 버텼지만 함께 돌리자 꺼졌습니다. 파워 용량 부족·노후가 가장 유력합니다."
        } elseif ($effStage -eq 'gpu') {
            $res.Cause = 'GPU_HW'; $res.Title = '블랙박스: GPU 단독 부하에서 꺼짐 (그래픽카드·보조전원 의심)'
            $res.Detail = "$state. 그래픽카드만 부하를 받았을 때 꺼졌습니다. 그래픽카드 자체 또는 보조전원 케이블·파워의 PCIe 출력이 의심됩니다."
        } elseif ($effStage -eq 'cpu') {
            $res.Cause = 'CPU_OC'; $res.Title = '블랙박스: CPU 단독 부하에서 꺼짐 (CPU·메인보드 전원부 의심)'
            $res.Detail = "$state. CPU 만 부하를 받았을 때 꺼졌습니다. CPU 보조전원(4+4핀), 메인보드 전원부, CPU 쿨러 장착, 오버클럭 설정을 확인하세요."
        } elseif ($effStage -eq 'ram') {
            $res.Cause = 'RAM'; $res.Title = '블랙박스: RAM 검사 중 꺼짐 (RAM·메인보드 의심)'
            $res.Detail = "$state. 메모리를 집중적으로 쓰는 중에 꺼졌습니다. XMP/EXPO 를 끄고, RAM 을 한 개씩 꽂아 다시 시험하세요."
        } elseif ($effStage -eq 'idle') {
            $res.Cause = 'PSU'; $res.Title = '블랙박스: 대기 중에 꺼짐 (전원 연결·메인보드 의심)'
            $res.Detail = "$state. 부하가 없는데 꺼졌습니다. 전원 케이블·멀티탭, 파워, 메인보드 순서로 의심됩니다."
        } elseif ($lastLoad -ge 70 -or $stress) {
            $res.Cause = 'PSU'; $res.Title = '블랙박스: 고부하 중 기록이 끊김 (파워 의심)'
            $res.Detail = "$state. 온도는 정상인데 부하가 걸린 상태에서 갑자기 꺼졌습니다. 전형적인 파워(PSU) 용량 부족·노후 패턴입니다."
        } else {
            $res.Cause = 'PSU'; $res.Title = '블랙박스: 낮은 부하에서 기록이 끊김'
            $res.Detail = "$state. 부하와 무관하게 꺼졌습니다. 전원 케이블·멀티탭·파워, 메인보드, RAM 순서로 의심됩니다."
        }
        if ($evText) { $res.Detail += " 직전 오류: $evText." }
        $res.Detail += $noteText
        # 꺼지기 전에 메모리 검사 오류가 나왔다면 그것이 더 직접적인 근거 — 원인과 제목을 함께 바꿈 (제목·원인 불일치 방지)
        if ($res.RamErrors -gt 0) {
            $res.Cause = 'RAM'; $res.Title = "블랙박스: RAM 검사 오류 $($res.RamErrors) 건 뒤 꺼짐 (RAM 불량 의심)"
        } elseif ($res.GpuTestErrors -gt 0) {
            $res.Cause = 'GPU_HW'; $res.Title = "블랙박스: VRAM 검사 오류 $($res.GpuTestErrors) 건 뒤 꺼짐 (그래픽카드 불량 의심)"
        }
    } elseif ($events.ContainsKey('OVERHEAT_STOP')) {
        $res.Level = 'bad'; $res.Cause = 'THERMAL'; $res.Title = '블랙박스: 과열 보호로 테스트 중지 (과열 의심)'
        $res.Detail = "테스트 중 그래픽카드 온도가 95°C 이상으로 이어져 하드웨어 보호를 위해 부하를 멈췄습니다 (최고 $(if ($null -ne $res.MaxGpuTempC) { "$($res.MaxGpuTempC) °C" } else { '-' })). 팬·먼지·써멀을 점검한 뒤 다시 시험하세요.$noteText"
    } elseif ($res.GpuTestErrors -gt 0 -or $events.ContainsKey('GPULOST')) {
        $res.Level = 'bad'; $res.Cause = 'GPU_HW'; $res.Title = "블랙박스: VRAM 검사에서 오류 $($res.GpuTestErrors) 건"
        $res.Detail = "그래픽카드 메모리 검사(memtest_vulkan)에서 오류가 나왔습니다. 오버클럭을 끄고 다시 시험해도 나오면 그래픽카드 A/S 대상입니다.$noteText"
    } elseif ($res.RamErrors -gt 0) {
        $res.Level = 'bad'; $res.Cause = 'RAM'; $res.Title = "블랙박스: RAM 검사에서 오류 $($res.RamErrors) 건"
        $res.Detail = "Windows 안에서 메모리에 쓴 값과 다시 읽은 값이 달랐습니다. RAM 불량 가능성이 매우 높습니다. XMP/EXPO 를 끄고 한 개씩 꽂아 불량 모듈을 찾으세요.$noteText"
    } elseif ($events.Count -or $thr.ContainsKey('HWSLOW') -or $thr.ContainsKey('PBRAKE')) {
        $res.Level = 'warn'; $res.Title = "블랙박스: 테스트 중 오류 기록 ($([math]::Round($res.Minutes)) 분)"
        $res.Detail = "꺼지지는 않았지만 테스트 중 이상 신호가 기록되었습니다$(if ($evText) { ": $evText" })."
        if ($evText -match 'Xid|TDR|NVIDIA|AMD') { $res.Cause = 'GPU_HW' } elseif ($evText -match 'WHEA') { $res.Cause = 'CPU_OC' } elseif ($evText) { $res.Cause = 'DISK' } else { $res.Cause = 'PSU' }
        $res.Detail += $noteText
    } else {
        $res.Level = 'ok'
        $done = @($order | Where-Object { $_ -in 'idle', 'cpu', 'ram', 'gpu', 'full', 'pulse' }).Count
        if ($gpuFail) { $done = 0 }
        $res.Title = $(if ($done -ge 6) { "블랙박스: 단계별 정밀 테스트 전 단계 통과 ($([math]::Round($res.Minutes)) 분)" } else { "블랙박스: 테스트 $([math]::Round($res.Minutes)) 분 동안 이상 없음" })
        $res.Detail = "최고 GPU $(if ($null -ne $res.MaxGpuTempC) { "$($res.MaxGpuTempC) °C" } else { '-' }) · CPU 최고 $(if ($null -ne $res.MaxCpuPct) { "$($res.MaxCpuPct)%" } else { '-' }).$noteText"
        if ($res.Notes.Count) { $res.Level = 'warn'; $res.Cause = $(if ($gpuFail) { '' } elseif ($thr.ContainsKey('HWTHERM') -or $thr.ContainsKey('SWTHERM') -or ($res.Notes -match '클럭')) { 'THERMAL' } else { 'PSU' }) }
    }
    return $res
}

function Get-BlackboxDirMemoryPath { return (Join-Path $script:WorkDir 'blackbox-dirs.txt') }
function Get-BlackboxDirMemory {
    $p = Get-BlackboxDirMemoryPath
    if (-not (Test-Path $p)) { return @() }
    try { return @(Get-Content -Encoding UTF8 $p | Where-Object { $_.Trim() }) } catch { return @() }
}
function Add-BlackboxDirMemory([string]$Dir) {
    # 기록한 폴더를 기억해 두었다가 검사할 때 찾아 봄 (최근 10개)
    try {
        $l = @(@($Dir) + @(Get-BlackboxDirMemory | Where-Object { $_ -ne $Dir }) | Select-Object -First 10)
        New-Item -ItemType Directory -Force -Path $script:WorkDir | Out-Null
        [IO.File]::WriteAllLines((Get-BlackboxDirMemoryPath), [string[]]$l, (New-Object System.Text.UTF8Encoding($true)))
    } catch { Write-PCLog "blackbox dir memory: $($_.Exception.Message)" }
}
function Find-BlackboxFiles([int]$Days = 30) {
    # USB·바탕화면에서 최근 블랙박스 기록 찾기
    $dirs = @()
    $roots = @()
    if ($null -ne $script:BlackboxSearchRoots) { $roots = @($script:BlackboxSearchRoots) }
    else { try { $roots = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=2' -ErrorAction Stop | ForEach-Object { $_.DeviceID + '\' }) } catch {} }
    foreach ($r in $roots) {
        $dirs += (Join-Path $r 'PCCheck_blackbox')
        # '찾아보기'로 USB 안의 폴더를 고른 경우 (E:\폴더\PCCheck_blackbox) — 재부팅으로 기억이 지워져도 찾도록 한 단계 아래까지
        try { $dirs += @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction Stop | ForEach-Object { Join-Path $_.FullName 'PCCheck_blackbox' }) } catch {}
    }
    $desk = [Environment]::GetFolderPath('Desktop'); if ($desk) { $dirs += (Join-Path $desk 'PCCheck_blackbox') }
    $dirs += @(Get-BlackboxDirMemory)   # '찾아보기'로 직접 고른 폴더
    $dirs = @($dirs | Where-Object { $_ } | Sort-Object -Unique)
    $since = (Get-Date).AddDays(-$Days)
    $files = @($dirs | Where-Object { $_ -and (Test-Path $_) } | ForEach-Object { Get-ChildItem $_ -Filter 'PCCheck_blackbox_*.csv' -ErrorAction SilentlyContinue } | Where-Object { $_.LastWriteTime -ge $since } | Sort-Object LastWriteTime -Descending | Select-Object -First 5)
    return @($files | ForEach-Object { try { Read-BlackboxAnalysis $_.FullName } catch {} })
}

function Show-BlackboxDialog {
    param([switch]$SmokeTest, [double]$SimScale = 1.0)
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $s = $SimScale
    $font = New-Object Drawing.Font('Malgun Gothic', (10 * $s)); $bold = New-Object Drawing.Font('Malgun Gothic', (10.5 * $s), [Drawing.FontStyle]::Bold)
    $f = New-Object Windows.Forms.Form
    $f.Text = '블랙박스 기록 (재현 테스트)'; $f.Font = $font; $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.AutoScaleMode = 'None'; $f.ClientSize = New-Object Drawing.Size([int](560 * $s), [int](478 * $s))
    $u = { param([double]$v) [int][math]::Round($v * $s) }
    $mk = { param($type, $text, $x, $y, $w, $h) $c = New-Object $type; $c.Text = $text; $c.SetBounds((& $u $x), (& $u $y), (& $u $w), (& $u $h)); $f.Controls.Add($c); $c }
    $def = Get-BlackboxDefaultDir
    $note = & $mk Windows.Forms.Label '노하드 PC 는 재부팅하면 기록이 사라지므로 USB 에 저장하세요. PC 가 꺼지면 다시 켠 뒤 이 프로그램으로 검사하면 기록을 자동으로 분석합니다.' 16 12 528 42
    $note.ForeColor = [Drawing.Color]::DimGray
    $dirLbl = & $mk Windows.Forms.Label '저장 위치' 16 66 90 22
    $dirBox = & $mk Windows.Forms.TextBox $def.Dir 108 63 330 26
    $browse = & $mk Windows.Forms.Button '찾아보기' 446 61 98 30
    $warn = & $mk Windows.Forms.Label $(if ($def.Removable) { 'USB 가 선택되었습니다.' } else { '(주의) USB 가 없습니다. 노하드라면 USB 를 꽂고 다시 여세요.' }) 108 94 436 22
    $warn.ForeColor = $(if ($def.Removable) { [Drawing.Color]::SeaGreen } else { [Drawing.Color]::DarkOrange })
    $autoR = & $mk Windows.Forms.RadioButton '단계별 자동 정밀 테스트 (약 32분, 권장)' 16 124 528 26
    $autoTip = & $mk Windows.Forms.Label '대기 → CPU → RAM 검사 → GPU·VRAM → 전체 부하 → 전력 출렁임 순서로 자동 진행. 꺼진 단계로 원인을 좁힙니다.' 34 150 510 42
    $autoTip.ForeColor = [Drawing.Color]::DimGray
    $manR = & $mk Windows.Forms.RadioButton '직접 설정' 16 196 528 26
    $cpuChk = & $mk Windows.Forms.CheckBox 'CPU 부하 걸기 (모든 코어 100%)' 34 222 510 26
    $gpuChk = & $mk Windows.Forms.CheckBox 'GPU·VRAM 부하 걸기 (memtest_vulkan 창이 열림)' 34 248 510 26
    $ramChk = & $mk Windows.Forms.CheckBox 'RAM 검사 (Windows 안에서, 재부팅 없음)' 34 274 510 26
    $autoR.Checked = $true; $cpuChk.Checked = $true; $gpuChk.Checked = $true
    foreach ($c in $cpuChk, $gpuChk, $ramChk) { $c.Enabled = $false }
    $live = & $mk Windows.Forms.Label '대기 중' 16 310 528 92
    $live.Font = $bold
    $startB = & $mk Windows.Forms.Button '기록 시작' 16 416 170 44
    $stopB = & $mk Windows.Forms.Button '중지' 196 416 170 44
    $anaB = & $mk Windows.Forms.Button '기록 파일 분석' 376 416 168 44
    $stopB.Enabled = $false
    $st = @{ Box = $null; Cpu = $null; Gpu = $null; Ram = $false; Start = $null; Auto = $false; GpuFailed = $false; Hot = 0 }
    $t = New-Object Windows.Forms.Timer; $t.Interval = 1000
    $setLoad = {
        param([bool]$cpu, [bool]$gpu, [bool]$ram)
        if ($cpu) { if (-not $st.Cpu) { $st.Cpu = Start-CpuStress }; $st.Cpu.Sync.Pause = $false } elseif ($st.Cpu) { $st.Cpu.Sync.Pause = $true }
        if ($gpu -and -not $st.Gpu -and -not $st.GpuFailed) {
            try { $gl = $null; if ($st.Box) { $gl = [IO.Path]::ChangeExtension($st.Box.Path, '.gpu.log'); $st.Box.Sync.GpuLog = $gl }; $st.Gpu = Start-GpuLoad -LogPath $gl }
            catch {
                # 다운로드·실행 실패: 기록에 남겨 'GPU 단계 미시험'으로 판정되게 함 (조용히 통과 처리 방지)
                Write-PCLog "gpu load: $($_.Exception.Message)"; $st.Gpu = $null; $st.GpuFailed = $true
                if ($st.Box -and $st.Box.Sync.GpuSeen -notmatch 'GPUFAIL') { Add-BlackboxEvent $st.Box.Sync 'GPUFAIL'; $st.Box.Sync.GpuSeen += ' GPUFAIL' }
            }
        }
        if (-not $gpu -and $st.Gpu) { Stop-GpuLoad $st.Gpu; $st.Gpu = $null }
        if ($ram -and -not $st.Ram) { try { Start-RamTest; $st.Ram = $true } catch { Write-PCLog "ram test: $($_.Exception.Message)" } }
        if (-not $ram -and $st.Ram) { Stop-RamTest; $st.Ram = $false }
        if ($st.Box) { $st.Box.Sync.CpuStress = $cpu; $st.Box.Sync.GpuStress = [bool]$st.Gpu }
    }
    $stopAll = {
        $t.Stop()
        if ($st.Cpu) { Stop-CpuStress $st.Cpu; $st.Cpu = $null }
        if ($st.Gpu) { Stop-GpuLoad $st.Gpu; $st.Gpu = $null }
        if ($st.Ram) { Stop-RamTest; $st.Ram = $false }
        if ($st.Box) { Stop-Blackbox $st.Box; $st.Box = $null }
        $startB.Enabled = $true; $stopB.Enabled = $false; $autoR.Enabled = $true; $manR.Enabled = $true
        foreach ($c in $cpuChk, $gpuChk, $ramChk) { $c.Enabled = $manR.Checked }
    }
    $manR.Add_CheckedChanged({ foreach ($c in $cpuChk, $gpuChk, $ramChk) { $c.Enabled = $manR.Checked } })
    $t.Add_Tick({
        try {
            if (-not $st.Box) { return }
            $sy = $st.Box.Sync; $l = $sy.Last
            $el = ((Get-Date) - $st.Start).TotalSeconds
            if ($l -and (Test-OverheatGuard $st $l.GpuTempC)) {
                # 하드웨어 보호: 부하를 즉시 멈추고 기록에 남김
                Add-BlackboxEvent $sy 'OVERHEAT_STOP'; Start-Sleep -Milliseconds 1500
                $p = $sy.Path; & $stopAll
                $live.Text = (Tr "과열 보호: 그래픽카드 $($l.GpuTempC) °C 가 이어져 테스트를 멈췄습니다. 쿨링을 점검하세요.") + "`n" + $p
                [void][Windows.Forms.MessageBox]::Show($f, (Tr "과열 보호: 그래픽카드 $($l.GpuTempC) °C 가 이어져 테스트를 멈췄습니다. 쿨링을 점검하세요."), (Tr $script:AppName), 'OK', 'Warning')
                return
            }
            $head = ''
            if ($st.Auto) {
                $g = Get-StageAt $script:StagePlan $el
                if ($g.Done) { $p = $sy.Path; & $stopAll; $live.Text = (Tr '단계별 정밀 테스트를 모두 마쳤습니다. 다시 검사하면 결과가 보고서에 나옵니다.') + "`n" + $p; return }
                $sy.Stage = $g.Key
                & $setLoad $g.Cpu $g.Gpu $g.Ram
                $head = "단계 $($g.Index + 1)/$($g.Count) · $($g.Name) · 남은 $([math]::Ceiling($g.Remaining / 60)) 분 (전체 $([int]($el / 60))/$([int]($g.TotalSec / 60)) 분)"
            } else { $head = "기록 중 · $([int]($el / 60)) 분 · $($sy.Rows) 줄" }
            $txt = $head
            if ($l) { $txt += "`nCPU $($l.CpuPct)%$(if ($null -ne $l.CpuPerfPct) { " (클럭 $($l.CpuPerfPct)%)" }) · GPU $(if ($null -ne $l.GpuTempC) { "$($l.GpuTempC) °C" } else { '-' })$(if ($null -ne $l.GpuPowerW) { " $($l.GpuPowerW) W" })$(if ($l.GpuThrottle) { " [$($l.GpuThrottle)]" })" }
            $rt = Get-RamTestState
            if ($rt.TestedMB -gt 0) { $txt += " · RAM 검사 $([math]::Round($rt.TestedMB / 1024, 1)) GB, 오류 $($rt.Errors) 건" }
            if ($sy.Events) { $txt += " · 오류 $($sy.Events) 건" }
            $txt += Get-BlackboxWarnText $sy
            $live.Text = (Tr $txt) + "`n" + $sy.Path
            if ($sy.Error) { $live.Text = Tr "기록 오류: $($sy.Error)"; & $stopAll }
        } catch { Write-PCLog "blackbox tick: $($_.Exception.Message)" }
    })
    $browse.Add_Click({ $d = New-Object Windows.Forms.FolderBrowserDialog; if ($d.ShowDialog($f) -eq 'OK') { $dirBox.Text = Join-Path $d.SelectedPath 'PCCheck_blackbox' } })
    $startB.Add_Click({
        try {
            $st.Auto = $autoR.Checked; $st.GpuFailed = $false; $st.Hot = 0
            if ($st.Auto -or $gpuChk.Checked) {
                # GPU 부하 도구를 미리 준비 (노하드는 재부팅마다 지워지므로 매번 받음). 실패하면 바로 알림
                $live.Text = Tr 'GPU 부하 도구 준비 중...'; [Windows.Forms.Application]::DoEvents()
                try { [void](Install-MemtestVulkan) }
                catch {
                    $st.GpuFailed = $true
                    [void][Windows.Forms.MessageBox]::Show($f, (Tr "GPU 부하 도구를 준비하지 못해 GPU 단계는 시험되지 않습니다 (인터넷 연결 확인).`n$($_.Exception.Message)"), (Tr $script:AppName), 'OK', 'Warning')
                }
            }
            $st.Box = Start-Blackbox -Dir $dirBox.Text
            if ($st.GpuFailed) { Add-BlackboxEvent $st.Box.Sync 'GPUFAIL'; $st.Box.Sync.GpuSeen = ' GPUFAIL' }
            if (-not $st.Auto) { & $setLoad $cpuChk.Checked $gpuChk.Checked $ramChk.Checked; $st.Box.Sync.Stage = 'manual' }
            $st.Start = Get-Date; $t.Start()
            $startB.Enabled = $false; $stopB.Enabled = $true; $autoR.Enabled = $false; $manR.Enabled = $false
            foreach ($c in $cpuChk, $gpuChk, $ramChk) { $c.Enabled = $false }
        } catch { & $stopAll; [void][Windows.Forms.MessageBox]::Show($f, (Tr "기록을 시작하지 못했습니다.`n$($_.Exception.Message)"), (Tr $script:AppName), 'OK', 'Error') }
    })
    $stopB.Add_Click({ $p = $st.Box.Path; & $stopAll; $live.Text = (Tr '기록을 마쳤습니다.') + "`n" + $p })
    $anaB.Add_Click({
        $o = New-Object Windows.Forms.OpenFileDialog; $o.Filter = 'PCCheck blackbox (*.csv)|PCCheck_blackbox_*.csv|CSV (*.csv)|*.csv'
        if (Test-Path $dirBox.Text) { $o.InitialDirectory = $dirBox.Text }
        if ($o.ShowDialog($f) -eq 'OK') {
            try {
                $a = Read-BlackboxAnalysis $o.FileName
                $stg = (@($a.Stages) | ForEach-Object { "· $($_.Name): GPU 최고 $(if ($null -ne $_.MaxGpuTempC) { "$($_.MaxGpuTempC) °C" } else { '-' })$(if ($null -ne $_.MaxGpuPowerW) { " / $($_.MaxGpuPowerW) W" })" }) -join "`n"
                [void][Windows.Forms.MessageBox]::Show($f, (Tr "$($a.Title)`n`n$($a.Detail)$(if ($stg) { "`n`n$stg" })"), $a.File)
            } catch { [void][Windows.Forms.MessageBox]::Show($f, (Tr "분석하지 못했습니다.`n$($_.Exception.Message)"), (Tr $script:AppName)) }
        }
    })
    $f.Add_FormClosing({
        param($src, $e)
        # 32분 테스트 중 실수로 X 를 눌러 기록이 끝나 버리지 않도록 확인
        $msg = Get-BlackboxCloseQuestion $st
        if ($msg -and -not $SmokeTest -and [Windows.Forms.MessageBox]::Show($f, (Tr $msg), (Tr $script:AppName), 'YesNo', 'Question') -ne 'Yes') { $e.Cancel = $true; return }
        & $stopAll
    })
    if ($script:UiLang -eq 'en') { $f.Text = Tr $f.Text; foreach ($c in $f.Controls) { if ($c.Text) { $c.Text = Tr $c.Text } } }
    if ($SmokeTest) {
        $f.CreateControl()
        $issues = @(Test-GuiLayout $f)
        $f.Dispose()
        return $issues
    }
    [void]$f.ShowDialog()
    $f.Dispose()
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
# API 한도 초과(공유 IP 등) 시 쓰는 검증된 고정 버전 — SHA-256 은 GitHub 릴리스가 제공한 값
$script:MemtestPinned = @{ Tag = 'v0.5.0'; Name = 'memtest_vulkan-v0.5.0.exe'; Sha256 = '09e67704210762ae8d8ad70fe6d71275eefbe815cc2c0658cd5afc8e231d0df6' }
function Get-MemtestAsset([switch]$UsePinned) {
    if (-not $UsePinned) {
        try {
            $h = @{}; if ($env:GITHUB_TOKEN) { $h.Authorization = "Bearer $($env:GITHUB_TOKEN)" }
            $rel = Invoke-RestMethod 'https://api.github.com/repos/GpuZelenograd/memtest_vulkan/releases/latest' -Headers $h -UserAgent "PCCheck/$($script:AppVersion)" -ErrorAction Stop
            $a = Select-WindowsAsset @($rel.assets)
            if ($a) {
                $sha = $null; if ($a.digest -match '^sha256:([0-9a-fA-F]{64})$') { $sha = $Matches[1] }
                return [pscustomobject]@{ Name = $a.name; Url = $a.browser_download_url; Sha256 = $sha; Source = 'api' }
            }
        } catch { Write-PCLog "github api failed, using pinned: $($_.Exception.Message)" }
    }
    $p = $script:MemtestPinned
    return [pscustomobject]@{ Name = $p.Name; Url = "https://github.com/GpuZelenograd/memtest_vulkan/releases/download/$($p.Tag)/$($p.Name)"; Sha256 = $p.Sha256; Source = 'pinned' }
}
function Install-MemtestVulkan {
    param([switch]$UsePinned)

    $dir = Join-Path $script:WorkDir 'memtest_vulkan'
    $exe = Get-ChildItem $dir -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'memtest' } | Select-Object -First 1
    if (-not $exe) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $asset = Get-MemtestAsset -UsePinned:$UsePinned
        $file = Join-Path $script:WorkDir $asset.Name
        Save-Download $asset.Url $file $asset.Sha256
        if ($asset.Name -match '\.exe$') { Move-Item $file (Join-Path $dir $asset.Name) -Force }
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
    @{ Key = 'blackbox'; Label = '블랙박스 기록 (노하드용)'; Desc = '부하 테스트 중 상태를 USB 에 실시간 기록'; Help = ''; Run = { Show-BlackboxDialog }; Fallback = $null }
    @{ Key = 'occt';  Label = '파워·GPU 부하 테스트';    Desc = 'OCCT 공식 사이트'; Help = "'Power' 테스트 10~20분 중 꺼지면 파워 문제, 'VRAM' 테스트에서 오류면 그래픽카드 문제입니다."; Run = { Start-Process 'https://www.ocbase.com/download' }; Fallback = $null }
)

function Get-RecommendedTool($Dx) {
    # 1순위 원인(점수 30 이상)에 맞는 다음 정밀 검사. 원인이 없지만 노하드면 블랙박스
    $top = @($Dx.Causes) | Select-Object -First 1
    if ($top -and $top.Score -ge 30) {
        switch ($top.Key) {
            'GPU_HW' { return 'vram' } 'GPU_DRIVER' { return 'bsv' } 'RAM' { return 'ram' }
            'PSU' { return 'blackbox' } 'THERMAL' { return 'blackbox' } 'CPU_OC' { return 'blackbox' } 'DRIVER' { return 'bsv' } 'DISK' { return '' }
        }
    }
    if (@($Dx.Findings) | Where-Object { $_.Title -match '노하드' }) { return 'blackbox' }
    return ''
}
function Get-RecommendedToolLabel($Dx) {
    $k = Get-RecommendedTool $Dx; if (-not $k) { return '' }
    $t = $script:ExternalTools | Where-Object { $_.Key -eq $k } | Select-Object -First 1
    if ($t) { return [string]$t.Label } else { return '' }
}
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
function Test-GuiLayout($root, [int]$RootW = 0, [int]$RootH = 0) {
    # 글자 잘림 · 컨트롤 겹침 · 부모 영역 밖으로 나감을 화면 없이 자동 검사
    $issues = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push($root)
    while ($stack.Count) {
        $parent = $stack.Pop()
        $kids = @($parent.Controls)
        $pw = $parent.ClientSize.Width; $ph = $parent.ClientSize.Height
        if ($parent -eq $root -and $RootW -gt 0) { $pw = $RootW; $ph = $RootH }
        foreach ($c in $kids) {
            $name = "$($c.GetType().Name) '$($c.Text)'"
            if ($c.Right -gt $pw -or $c.Bottom -gt $ph -or $c.Left -lt 0 -or $c.Top -lt 0) { [void]$issues.Add("$name 이(가) 부모 영역 밖 ($($c.Bounds) / ${pw}x${ph})") }
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

    # SimScale: 고배율(125~200%) 화면을 흉내 내 레이아웃을 검사할 때만 사용
    param([int]$Days, [string]$OutDir, [switch]$SmokeTest, [double]$SimScale = 1.0, [string]$Note)
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    if (-not $SmokeTest) {
        # 고해상도 모니터에서 흐릿하지 않게 (DPI 인식) — 실패해도 동작에는 지장 없음
        try {
            if (-not ('PCCheckDpi' -as [type])) { Add-Type -Name PCCheckDpi -Namespace '' -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -ErrorAction Stop }
            [void][PCCheckDpi]::SetProcessDPIAware()
        } catch { Write-PCLog "dpi aware failed: $($_.Exception.Message)" }
    }
    [Windows.Forms.Application]::EnableVisualStyles()
    if (-not $SmokeTest -and -not $script:GuiGuard) {
        # 처리되지 않은 오류가 .NET 오류 창으로 뜨지 않도록 (로그 + 안내 후 계속 사용)
        try {
            [Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException)
            [Windows.Forms.Application]::add_ThreadException({
                param($sender, $e)
                Write-PCLog "unhandled: $($e.Exception)"
                [void][Windows.Forms.MessageBox]::Show((Tr "예상하지 못한 오류가 발생했습니다.`n$($e.Exception.Message)`n`n로그: $($script:LogFile)"), (Tr $script:AppName), 'OK', 'Error')
            })
            $script:GuiGuard = $true
        } catch { Write-PCLog "guard failed: $($_.Exception.Message)" }
    }
    $font = New-Object Drawing.Font('Malgun Gothic', (10 * $SimScale))
    $bold = New-Object Drawing.Font('Malgun Gothic', (11 * $SimScale), [Drawing.FontStyle]::Bold)
    $big  = New-Object Drawing.Font('Malgun Gothic', (26 * $SimScale), [Drawing.FontStyle]::Bold)

    $f = New-Object Windows.Forms.Form
    $f.Text = "$($script:AppName) v$($script:AppVersion)"
    $f.StartPosition = 'CenterScreen'; $f.Font = $font; $f.BackColor = [Drawing.Color]::FromArgb(246, 247, 249)
    $f.AutoScaleMode = 'None'   # 배치는 아래 $doLayout 이 화면 배율($s)과 창 크기로 직접 계산
    $s = $SimScale
    if ($SimScale -eq 1.0) { try { $g = $f.CreateGraphics(); $s = [math]::Max(1.0, $g.DpiX / 96.0); $g.Dispose() } catch { $s = 1.0 } }

    $title = New-Object Windows.Forms.Label
    $title.Text = 'PC 원클릭 진단'; $title.Font = New-Object Drawing.Font('Malgun Gothic', (16 * $SimScale), [Drawing.FontStyle]::Bold)
    $title.AutoSize = $true
    $desc = New-Object Windows.Forms.Label
    $desc.Text = '갑자기 꺼짐 · 블루스크린 · 그래픽카드(VRAM) · RAM · 디스크 문제를 Windows 기록으로 분석합니다.'
    $desc.AutoEllipsis = $true; $desc.ForeColor = [Drawing.Color]::DimGray

    $daysLbl = New-Object Windows.Forms.Label; $daysLbl.Text = '분석 기간'; $daysLbl.AutoSize = $true
    $noteLbl = New-Object Windows.Forms.Label; $noteLbl.Text = '메모'; $noteLbl.AutoSize = $true
    $noteBox = New-Object Windows.Forms.TextBox; $noteBox.MaxLength = 200; $noteBox.Text = $Note
    $daysBox = New-Object Windows.Forms.ComboBox; $daysBox.DropDownStyle = 'DropDownList'
    foreach ($o in (Get-DayChoices $Days)) { [void]$daysBox.Items.Add("$($o)일") }
    $daysBox.SelectedItem = "$($Days)일"   # 명령줄 -Days 60 같은 값도 그대로 (90일로 바뀌지 않게)

    $start = New-Object Windows.Forms.Button
    $start.Text = '검사 시작'; $start.Font = $bold
    $start.BackColor = [Drawing.Color]::FromArgb(36, 87, 197); $start.ForeColor = [Drawing.Color]::White; $start.FlatStyle = 'Flat'; $start.FlatAppearance.BorderSize = 0

    $bar = New-Object Windows.Forms.ProgressBar
    $status = New-Object Windows.Forms.Label; $status.AutoEllipsis = $true; $status.ForeColor = [Drawing.Color]::DimGray
    $status.Text = $(if (Test-IsAdmin) { '준비됨 (관리자 권한)' } else { '준비됨 — (주의) 관리자 권한이 아니어서 일부 항목이 빠질 수 있습니다' })

    $score = New-Object Windows.Forms.Label; $score.Font = $big; $score.Text = '—'; $score.TextAlign = 'MiddleLeft'
    $grade = New-Object Windows.Forms.Label; $grade.Font = $bold; $grade.AutoEllipsis = $true; $grade.Text = '상태 점수'

    $list = New-Object Windows.Forms.ListView
    $list.View = 'Details'; $list.FullRowSelect = $true; $list.HeaderStyle = 'Nonclickable'
    [void]$list.Columns.Add('의심 원인 / 발견 사항', 300); [void]$list.Columns.Add('점수', [int](60 * $s)); [void]$list.Columns.Add('가능성', [int](90 * $s))
    $tip = New-Object Windows.Forms.ToolTip

    $report = New-Object Windows.Forms.Button; $report.Text = '보고서 열기'; $report.Enabled = $false
    $folder = New-Object Windows.Forms.Button; $folder.Text = '저장 폴더 열기'; $folder.Enabled = $false
    $copyB = New-Object Windows.Forms.Button; $copyB.Text = '요약 복사'; $copyB.Enabled = $false

    $grp = New-Object Windows.Forms.GroupBox; $grp.Text = '정밀 검사 (공식 출처에서 받아 실행)'
    $toolBtns = New-Object System.Collections.ArrayList
    foreach ($t in $script:ExternalTools) {
        $b = New-Object Windows.Forms.Button
        $b.Text = $t.Label; $b.Tag = $t.Key
        $tip.SetToolTip($b, (Tr "$($t.Desc)`n`n$($t.Help)"))
        $b.Add_Click({
            param($sender, $e)
            $sender.Enabled = $false; $f.Cursor = 'WaitCursor'
            $r = Invoke-Tool $sender.Tag
            $f.Cursor = 'Default'; $sender.Enabled = $true
            if ($r.Ok) { if ($r.Help) { & $notify $r.Help 'Information' $sender.Text } }
            else { & $notify "실행하지 못했습니다.`n$($r.Error)" 'Warning' $sender.Text }
        })
        $grp.Controls.Add($b); [void]$toolBtns.Add($b)
    }

    $state = @{ Result = $null; Job = $null; Tick = 0; Headless = [bool]$SmokeTest; Failed = $null }
    # 안내 창 (자동 테스트 중에는 창 대신 기록만)
    $notify = {
        param([string]$text, [string]$icon = 'Information', [string]$caption = $script:AppName)
        if ($state.Headless) { if ($icon -eq 'Error') { $state.Failed = $text }; Write-PCLog "notify: $text"; return }
        [void][Windows.Forms.MessageBox]::Show($f, (Tr $text), (Tr $caption), 'OK', $icon)
    }
    $report.Add_Click({ if ($state.Result) { Start-Process $state.Result.Html } })
    $folder.Add_Click({ if ($state.Result) { Start-Process 'explorer.exe' "/select,`"$($state.Result.Html)`"" } })
    # 메신저 상담용 요약을 클립보드로 (이 PC 안에서만 — 외부 전송 없음)
    $copyB.Add_Click({ try { if ($state.Summary) { [Windows.Forms.Clipboard]::SetText($state.Summary); $status.Text = Tr '요약을 복사했습니다 — 메신저 대화창에 붙여 넣으세요 (Ctrl+V)' } } catch { $status.Text = Tr "복사하지 못했습니다: $($_.Exception.Message)" } })
    # 수집이 끝난 뒤(화면 스레드) 분석·저장·표시
    $finish = {
        param($data)
        try {
            $status.Text = Tr '분석 중...'
            if ($noteBox.Text.Trim()) { $data.Meta.Note = $noteBox.Text.Trim() }
            if ($script:ShopText) { $data.Meta.Shop = $script:ShopText }
            $dx = Get-Diagnosis -Data $data
            $bar.Value = $bar.Maximum - 1
            $state.Result = Save-Results -Data $data -Dx $dx -Dir (Get-ReportDir $data $OutDir $script:OutDirDefault (Get-UsbRoot)) -Track
            $state.Summary = Get-SummaryText $data $dx
            $bar.Value = $bar.Maximum
            $score.Text = "$($dx.Health)"
            $score.ForeColor = $(if ($dx.Health -ge 90) { [Drawing.Color]::SeaGreen } elseif ($dx.Health -ge 70) { [Drawing.Color]::DarkOrange } else { [Drawing.Color]::Firebrick })
            $grade.Text = Tr "상태: $($dx.Grade)"
            foreach ($c in $dx.Causes | Select-Object -First 4) {
                $it = New-Object Windows.Forms.ListViewItem((Tr "[원인] $($c.Name)"))
                [void]$it.SubItems.Add("$($c.Score)"); [void]$it.SubItems.Add((Tr $c.Confidence))
                $it.Font = $bold; $it.ToolTipText = (Tr (@($c.Reasons) -join "`n")); [void]$list.Items.Add($it)
            }
            foreach ($x in $dx.Findings | Where-Object { $_.Level -ne 'info' }) {
                $tag = switch ($x.Level) { 'bad' { '[위험]' } 'warn' { '[주의]' } default { '[정상]' } }
                $it = New-Object Windows.Forms.ListViewItem((Tr "$tag $($x.Title)"))
                [void]$it.SubItems.Add(''); [void]$it.SubItems.Add('')
                $it.ForeColor = $(switch ($x.Level) { 'bad' { [Drawing.Color]::Firebrick } 'warn' { [Drawing.Color]::DarkOrange } default { [Drawing.Color]::SeaGreen } })
                $it.ToolTipText = (Tr $x.Detail); [void]$list.Items.Add($it)
            }
            $list.ShowItemToolTips = $true
            $report.Enabled = $true; $folder.Enabled = $true; $copyB.Enabled = $true
            $status.Text = (Tr '완료 — 보고서: ') + $state.Result.Html
            # 다음에 할 정밀 검사 버튼 강조
            $recKey = Get-RecommendedTool $dx
            foreach ($tb in $toolBtns) {
                if ($recKey -and $tb.Tag -eq $recKey) { $tb.BackColor = [Drawing.Color]::FromArgb(255, 236, 179); $tb.Font = $bold; $tip.SetToolTip($tb, (Tr '추천: 이 검사로 원인을 확인하세요')) }
                else { $tb.UseVisualStyleBackColor = $true; $tb.Font = $font }
            }
            if (-not $state.Headless) { Start-Process $state.Result.Html }
        } catch {
            Write-PCLog "gui error: $($_.Exception.Message)"
            $status.Text = Tr '오류가 발생했습니다.'
            & $notify "검사 중 오류가 발생했습니다.`n$($_.Exception.Message)`n`n로그: $($script:LogFile)" 'Error'
        } finally { $start.Enabled = $true; $daysBox.Enabled = $true; $f.Cursor = 'Default' }
    }
    # 진행 상황 갱신 타이머 (수집은 백그라운드에서, 화면은 계속 반응)
    $timer = New-Object Windows.Forms.Timer; $timer.Interval = 150
    $timer.Add_Tick({
        try {
            $j = $state.Job; if (-not $j) { $timer.Stop(); return }
            $sy = $j.Sync
            if ($sy.N -gt 0) { $bar.Maximum = $sy.N + 2; $bar.Value = [math]::Max(0, [math]::Min($bar.Maximum, [int]$sy.I)) }
            $state.Tick = ($state.Tick + 1) % 3
            if ($sy.Name) { $status.Text = (Tr "수집 중 ($($sy.I)/$($sy.N)): $($sy.Name)") + ' ' + ('.' * (1 + $state.Tick)) }
            if ($sy.Done) {
                $timer.Stop(); $state.Job = $null
                $data = Complete-CollectAsync $j
                if ($sy.Error) {
                    $status.Text = Tr '오류가 발생했습니다.'; $start.Enabled = $true; $daysBox.Enabled = $true; $f.Cursor = 'Default'
                    & $notify "검사 중 오류가 발생했습니다.`n$($sy.Error)`n`n로그: $($script:LogFile)" 'Error'
                } else { & $finish $data }
            }
        } catch {
            # 화면 갱신 중 예상 못 한 오류: 프로그램이 죽지 않게 정리하고 안내
            $timer.Stop(); $state.Job = $null
            Write-PCLog "tick error: $($_.Exception.Message)"
            $start.Enabled = $true; $daysBox.Enabled = $true; $f.Cursor = 'Default'; $status.Text = Tr '오류가 발생했습니다.'
            & $notify "검사 중 오류가 발생했습니다.`n$($_.Exception.Message)`n`n로그: $($script:LogFile)" 'Error'
        }
    })
    $onStart = {
        $start.Enabled = $false; $daysBox.Enabled = $false; $list.Items.Clear(); $f.Cursor = 'AppStarting'
        $score.Text = '—'; $score.ForeColor = [Drawing.Color]::Black; $grade.Text = Tr '검사 중'
        $d = [int](([string]$daysBox.SelectedItem) -replace '\D', '')
        $bar.Value = 0; $status.Text = Tr '검사 준비 중...'
        try { $state.Job = Start-CollectAsync -Days $d; $timer.Start() }
        catch {
            # 백그라운드 실행이 안 되는 환경이면 기존 방식(화면 스레드)으로
            Write-PCLog "async failed, sync fallback: $($_.Exception.Message)"
            $data = Invoke-Collect -Days $d -Progress { param($i, $n, $name) $bar.Maximum = $n + 2; $bar.Value = $i; $status.Text = Tr "수집 중 ($i/$n): $name"; [Windows.Forms.Application]::DoEvents() }
            & $finish $data
        }
    }
    $start.Add_Click({
        try { & $onStart }
        catch {
            Write-PCLog "start error: $($_.Exception.Message)"
            $start.Enabled = $true; $daysBox.Enabled = $true; $f.Cursor = 'Default'
            & $notify "검사 중 오류가 발생했습니다.`n$($_.Exception.Message)`n`n로그: $($script:LogFile)" 'Error'
        }
    })
    $f.Add_FormClosing({ if ($state.Job) { try { $state.Job.PS.Stop() } catch {} } })

    $f.Controls.AddRange(@($title, $desc, $daysLbl, $daysBox, $noteLbl, $noteBox, $start, $bar, $status, $score, $grade, $list, $report, $folder, $copyB, $grp))
    if ($script:UiLang -eq 'en') {
        # 화면 글자 번역 (컨트롤 · 목록 머리글 · 기간 선택)
        $f.Text = Tr $f.Text
        $stack = New-Object System.Collections.Stack; $stack.Push($f)
        while ($stack.Count) { $c = $stack.Pop(); foreach ($k in $c.Controls) { if ($k.Text) { $k.Text = Tr $k.Text }; $stack.Push($k) } }
        foreach ($col in $list.Columns) { $col.Text = Tr $col.Text }
        $sel = $daysBox.SelectedIndex; $items = @($daysBox.Items | ForEach-Object { Tr $_ }); $daysBox.Items.Clear(); foreach ($o in $items) { [void]$daysBox.Items.Add($o) }; $daysBox.SelectedIndex = $sel
    }

    # ---- 배치: 창 크기(W,H)와 배율($s)로 모든 위치를 계산 (작은 화면·고배율에서도 겹치지 않게)
    $doLayout = {
        param([int]$W, [int]$H)
        $u = { param([double]$v) [int][math]::Round($v * $s) }
        $m = & $u 20
        $title.Left = $m; $title.Top = & $u 14
        $desc.SetBounds($m + (& $u 2), (& $u 48), $W - 2 * $m, (& $u 24))
        $daysLbl.Left = $m + (& $u 2); $daysLbl.Top = & $u 90

        $daysBox.SetBounds($m + (& $u 74), (& $u 86), (& $u 110), $daysBox.Height)
        $start.SetBounds($W - $m - (& $u 200), (& $u 78), (& $u 200), (& $u 44))
        $nx = $m + (& $u 196)
        $noteLbl.Left = $nx; $noteLbl.Top = & $u 90
        $noteBox.SetBounds($nx + (& $u 44), (& $u 86), [math]::Max((& $u 80), $start.Left - (& $u 12) - ($nx + (& $u 44))), $noteBox.Height)
        $bar.SetBounds($m, (& $u 134), $W - 2 * $m, (& $u 10))
        $status.SetBounds($m, (& $u 150), $W - 2 * $m, (& $u 24))
        $grpH = & $u 150; $grpTop = $H - $grpH - (& $u 14)
        $grp.SetBounds($m, $grpTop, $W - 2 * $m, $grpH)
        $top = & $u 184; $leftW = & $u 150
        $score.SetBounds($m, $top, $leftW, (& $u 56))
        $grade.SetBounds($m + (& $u 2), $top + (& $u 58), $leftW, (& $u 26))
        $report.SetBounds($m, $top + (& $u 90), $leftW, (& $u 32))
        $folder.SetBounds($m, $top + (& $u 128), $leftW, (& $u 32))
        $copyB.SetBounds($m, $top + (& $u 166), $leftW, (& $u 32))
        $lx = $m + $leftW + (& $u 10)
        $list.SetBounds($lx, $top, $W - $m - $lx, [math]::Max((& $u 80), $grpTop - (& $u 10) - $top))
        $list.Columns[0].Width = [math]::Max((& $u 120), $list.ClientSize.Width - $list.Columns[1].Width - $list.Columns[2].Width - 4)
        $pad = & $u 12; $gap = & $u 10; $bh = & $u 52
        $bw = [int][math]::Floor(($grp.ClientSize.Width - 2 * $pad - 2 * $gap) / 3)
        for ($k = 0; $k -lt $toolBtns.Count; $k++) {
            $col = $k % 3; $row = [math]::Floor($k / 3)
            $toolBtns[$k].SetBounds($pad + $col * ($bw + $gap), (& $u 26) + $row * ($bh + $gap), $bw, $bh)
        }
    }
    # 화면 작업 영역에 맞춘 창 크기 (1366x768 + 125% 같은 작은 화면 대응)
    $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $cw = [math]::Min([int](760 * $s), $wa.Width - 40); $ch = [math]::Min([int](600 * $s), $wa.Height - 60)
    $f.ClientSize = New-Object Drawing.Size($cw, $ch)
    $f.MinimumSize = New-Object Drawing.Size([math]::Min([int](700 * $s), $wa.Width), [math]::Min([int](560 * $s), $wa.Height))
    & $doLayout $f.ClientSize.Width $f.ClientSize.Height
    $f.Add_Resize({ & $doLayout $f.ClientSize.Width $f.ClientSize.Height })

    if ($SmokeTest) {
        # CI 등 화면 없는 환경: 여러 창 크기에서 배치를 계산해 글자 잘림·겹침 검사
        $f.CreateControl(); $n = $f.Controls.Count
        $issues = @()
        foreach ($sz in @(@(760, 600), @(700, 540), @(760, 534))) {
            $W = [int]($sz[0] * $s); $H = [int]($sz[1] * $s)
            & $doLayout $W $H
            foreach ($i in @(Test-GuiLayout $f $W $H)) { $issues += "[$W x $H] $i" }
        }
        foreach ($i in $issues) { Write-Output "GUI LAYOUT ISSUE: $i" }
        & $doLayout 760 600
        if ($env:PCCHECK_GUI_E2E -and $SimScale -eq 1.0) {
            # 실제로 '검사 시작'을 누른 것과 같은 흐름을 끝까지 실행 (타이머·백그라운드 수집·분석·저장)
            & $onStart
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while (-not $state.Result -and -not $state.Failed -and $sw.Elapsed.TotalSeconds -lt 180) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30 }
            $timer.Stop()
            if ($state.Failed) { $issues += "검사 흐름 오류: $($state.Failed)" }
            elseif (-not $state.Result -or -not (Test-Path $state.Result.Html)) { $issues += '검사 흐름: 180초 안에 보고서가 만들어지지 않음' }
            elseif ($list.Items.Count -lt 1) { $issues += '검사 흐름: 결과 목록이 비어 있음' }
            elseif (-not $copyB.Enabled -or -not $state.Summary) { $issues += '검사 흐름: 요약 복사 준비 안 됨' }
            else { Write-Output "GUI E2E OK: $([int]$sw.Elapsed.TotalSeconds)s, 점수 $($score.Text), 목록 $($list.Items.Count)개, 상태줄 '$($status.Text)'" }
            foreach ($i in $issues) { Write-Output "GUI ISSUE: $i" }
        }
        if ($env:PCCHECK_SHOT -and $SimScale -eq 1.0) {
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
function Write-TrHost {
    param([Parameter(Position = 0)]$Object = '', $ForegroundColor)
    if ($ForegroundColor) { Write-Host (Tr ([string]$Object)) -ForegroundColor $ForegroundColor } else { Write-Host (Tr ([string]$Object)) }
}
function Write-ConsoleResult($Dx, $Res) {
    Write-TrHost ''
    Write-TrHost ("상태 점수: {0}/100 ({1})" -f $Dx.Health, $Dx.Grade) -ForegroundColor $(if ($Dx.Health -ge 90) { 'Green' } elseif ($Dx.Health -ge 70) { 'Yellow' } else { 'Red' })
    if (@($Dx.Causes).Count) {
        Write-TrHost "`n가장 의심되는 원인" -ForegroundColor Cyan
        $i = 0; foreach ($c in $Dx.Causes | Select-Object -First 3) { $i++; Write-TrHost ("  {0}. {1}  {2}점 (가능성 {3})" -f $i, $c.Name, $c.Score, $c.Confidence); foreach ($r in @($c.Reasons) | Select-Object -First 2) { Write-TrHost "     - $r" -ForegroundColor DarkGray } }
    }
    Write-TrHost "`n발견 사항" -ForegroundColor Cyan
    foreach ($x in $Dx.Findings) { Write-TrHost ("  ● " + $x.Title) -ForegroundColor $(switch ($x.Level) { 'bad' { 'Red' } 'warn' { 'Yellow' } 'info' { 'Gray' } default { 'Green' } }) }
    Write-TrHost "`n보고서: $($Res.Html)" -ForegroundColor Green
}

function Get-ConsoleRelaunchArgs([string]$Path, [int]$Days, [string]$OutDir, [string]$Lang, [string]$Note, [string]$Shop) {
    # 화면을 못 띄워 콘솔로 다시 실행할 때 사용자가 고른 저장 위치·언어·메모를 그대로 넘김
    $q = { param([string]$v) '"' + ($v -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', (& $q $Path), '-Mode', 'Console', '-Days', "$Days")
    if ($OutDir) { $a += @('-OutDir', (& $q $OutDir)) }
    if ($Lang) { $a += @('-Lang', $Lang) }
    if ($Note) { $a += @('-Note', (& $q $Note)) }
    if ($Shop) { $a += @('-Shop', (& $q $Shop)) }
    return $a
}
function Start-ConsoleMenu($Res) {
    while ($true) {
        Write-TrHost "`n============ 정밀 검사 ============" -ForegroundColor Cyan
        $i = 0; foreach ($t in $script:ExternalTools) { $i++; Write-TrHost (" {0}. {1}  ({2})" -f $i, $t.Label, $t.Desc) }
        Write-TrHost ' 9. 보고서 다시 열기'; Write-TrHost ' 0. 종료'
        $sel = Read-Host (Tr '번호 선택')
        if ($sel -eq '0' -or $sel -eq '') { return }
        if ($sel -eq '9') { Start-Process $Res.Html; continue }
        $n = 0; if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $script:ExternalTools.Count) {
            $r = Invoke-Tool $script:ExternalTools[$n - 1].Key
            if ($r.Ok) { if ($r.Help) { Write-TrHost $r.Help -ForegroundColor Green } } else { Write-TrHost "실패: $($r.Error)" -ForegroundColor Red }
        }
    }
}

# =====================================================================
#  영어 번역 (출력 단계에서 적용: -Lang en)
#   'RE:' 로 시작하면 정규식, 그 외는 고정 문구. 긴 문구부터 치환됩니다.
# =====================================================================
$script:UiLang = 'ko'
$script:EnPairs = @(
    # ---- 숫자가 들어가는 문장 (정규식)
    @('RE:블루스크린 없이 꺼짐 (\d+) 회', 'Power-off without blue screen: $1'),
    @('RE:갑자기 꺼짐 (\d+) 회 \(블루스크린 없음\)', 'Sudden power-off: $1 (no blue screen)'),
    @('RE: \(이 중 (\d+) 회는 전원 버튼을 길게 눌러 끈 흔적이 있습니다 — 멈춤 후 강제 종료였을 수 있습니다\.\)', ' ($1 of these show a long power-button press — likely a forced shutdown after a freeze.)'),
    @('RE: (\d+) 회는 절전 진입/복귀 중에 발생했습니다 \(드라이버·BIOS 절전 설정 문제가 흔함\)\.', ' $1 happened while entering/resuming from sleep (often a driver or BIOS power-setting issue).'),
    @('RE:절전 진입/복귀 중 꺼짐 (\d+) 회', 'Power-off during sleep/resume: $1'),
    @('RE:코드 미상 (\d+)회', 'unknown code ×$1'),
    @('RE:(0x[0-9A-F]+ [A-Z_0-9]+) (\d+)회', '$1 ×$2'),
    @('RE:블루스크린 (0x[0-9A-F]+) \(([A-Z_0-9]+)\)', 'Blue screen $1 ($2)'),
    @('RE:블루스크린 (\d+) 회', 'Blue screens: $1'),
    @('RE:그래픽 드라이버 응답 없음/오류 (\d+) 건', 'Graphics driver hangs/errors: $1'),
    @('RE:그래픽 드라이버 오류 (\d+) 건', 'Graphics driver errors: $1'),
    @('RE:그래픽 드라이버가 멈추거나 오류를 낸 기록입니다 \(TDR (\d+) 건\)\.', 'The graphics driver stopped responding or reported errors (TDR: $1).'),
    @('RE:NVIDIA 드라이버가 VRAM 오류\(Xid ([\d, ]+)\)를 보고했습니다\. VRAM 검사로 확인하세요\.', 'The NVIDIA driver reported VRAM errors (Xid $1). Confirm with the VRAM test.'),
    @('RE:그래픽 오류 직후 15분 안에 꺼짐 (\d+) 회 \(고부하 중 전력 부족 패턴\)', 'Power-off within 15 min of a graphics error: $1 (power shortage under load)'),
    @('RE:그래픽 오류 직후 꺼짐 (\d+) 회', 'Power-off right after a graphics error: $1'),
    @('RE:(\d{4}-\d{2}-\d{2}) 드라이버 설치 후 문제가 시작됐습니다\. 이전 버전으로 되돌려 보세요 \(DDU 사용\)\.', 'Problems started after the driver install on $1. Roll back to the previous version (use DDU).'),
    @('RE:수정된 메모리 오류\(WHEA 47\) (\d+) 건', 'Corrected memory errors (WHEA 47): $1'),
    @('RE:PCIe 오류\(WHEA 17\) (\d+) 건 — 그래픽카드/NVMe 슬롯', 'PCIe errors (WHEA 17): $1 — graphics card/NVMe slot'),
    @('RE:수정된 CPU 오류\(WHEA 19\) (\d+) 건', 'Corrected CPU errors (WHEA 19): $1'),
    @('RE:치명적 하드웨어 오류\(WHEA 18\) (\d+) 건', 'Fatal hardware errors (WHEA 18): $1'),
    @('RE:치명적 하드웨어 오류 (\d+) 건', 'Fatal hardware errors: $1'),
    @('RE:하드웨어가 스스로 보고한 오류입니다\. 치명적 (\d+) · 메모리 (\d+) · PCIe (\d+) · CPU (\d+) 건\.', 'Errors reported by the hardware itself. Fatal $1 · memory $2 · PCIe $3 · CPU $4.'),
    @('RE:하드웨어 오류\(WHEA\) (\d+) 건', 'Hardware errors (WHEA): $1'),
    @('RE:디스크 상태 이상: ', 'Disk health problem: '),
    @('RE:상태: (\S+) — 즉시 백업하세요\.', 'Status: $1 — back up now.'),
    @('RE:디스크 상태 경고: ', 'Disk health warning: '),
    @('RE:상태: (\S+) — 백업해 두고 SMART 를 확인하세요\.', 'Status: $1 — back up your data and check SMART.'),
    @('RE:SSD 수명 소진 \((.+?) (\d+)%\)', 'SSD worn out ($1 $2%)'),
    @('RE:복구 불가 읽기 오류 (\d+)', 'Uncorrectable read errors: $1'),
    @('RE:디스크 읽기 오류 \((.+?)\)', 'Disk read errors ($1)'),
    @('RE:복구되지 않은 읽기 오류 (\d+) 회\.', 'Uncorrected read errors: $1.'),
    @('RE:SSD 온도 높음 \(([\d\.]+) °C\)', 'SSD temperature high ($1 °C)'),
    @('RE:디스크 오류 기록 (\d+) 건', 'Disk error records: $1'),
    @('RE:그래픽카드 ([\d\.]+) °C \(저부하인데 높음\)', 'Graphics card $1 °C (high at low load)'),
    @('RE:그래픽카드 ([\d\.]+) °C \(Windows 센서\)', 'Graphics card $1 °C (Windows sensor)'),
    @('RE:그래픽카드 ([\d\.]+) °C', 'Graphics card $1 °C'),
    @('RE:그래픽카드 온도 높음: ([\d\.]+) °C', 'Graphics card temperature high: $1 °C'),
    @('RE:메인보드 온도 센서 ([\d\.]+) °C', 'Motherboard sensor $1 °C'),
    @('RE:오버클럭/튜닝 도구 실행 중: ', 'Overclocking/tuning tool running: '),
    @('RE:오버클럭 도구 실행 중: ', 'Overclocking tool running: '),
    @('RE:그래픽 드라이버가 오래됨 \((\d{4}-\d{2}-\d{2})\)', 'Graphics driver is old ($1)'),
    @('RE: 드라이버를 최신 안정 버전으로 업데이트하세요\.', ': update the driver to the latest stable version.'),
    @('RE:메인보드 BIOS 가 오래됨 \((\d{4}-\d{2}-\d{2})\)', 'Motherboard BIOS is old ($1)'),
    @('RE:일부 항목 수집 실패 (\d+) 건', 'Some items could not be collected: $1'),
    @('RE:최근 (\d+) ?일간 심각한 문제 기록 없음', 'No serious problems recorded in the last $1 days'),
    @('RE:지난 검사\(([\d\- :]+) · (\d+)점\) 이후 새로 생긴 문제 없음 ✓', 'No new problems since the last scan ($1 · score $2) ✓'),
    @('RE:지난 검사\(([\d\- :]+) · (\d+)점\) 이후 새 문제 (\d+) 건', '$3 new problem(s) since the last scan ($1 · score $2)'),
    @('RE:지난 검사\(([\d\- :]+)\) 이후 새 문제 (\d+) 건', '$2 new problem(s) since the last scan ($1)'),
    @('RE:지난 검사\(([\d\- :]+)\) 이후 새 문제 없음', 'No new problems since the last scan ($1)'),
    @('RE:상태 점수: (\d+)/100 \((.+?)\)', 'Health score: $1/100 ($2)'),
    @('RE:최근 (\d+) ?일 분석', 'last $1 days analyzed'),
    @('RE: · 최근 (\d+)일', ' · last $1 days'),
    @('RE:\(빌드 ([\w.]*)\)', '(build $1)'),
    @('RE:(\d+)코어 / (\d+)스레드', '$1 cores / $2 threads'),
    @('RE:(\d+)점\(가능성 ', '$1 pts (likelihood '),
    @('RE:지금 할 일: ', 'Do this now: '),
    @('RE:\(([^가-힣()]+(?:\([^가-힣()]*\))?[^가-힣()]*) 의심\)', '($1 suspected)'),
    @('RE:수집 중 \((\d+)/(\d+)\): ', 'Collecting ($1/$2): '),
    @('RX:(\d+)일$', '$1 days'), @('RX:(\d+) ?건', '$1'), @('RX:(\d+) ?회', '×$1'),
    @('RE:어댑터 (\d+)', 'Adapter $1'),
    @('RE:배율 (\d+)%', 'Scale $1%'),
    @('RE:(\d+) 개 \(가상 머신에서는 0 이 정상\)', '$1 (0 is normal on a virtual machine)'),
    @('RE: — 최근 (\d+) 일 분석', ' — analyzing the last $1 days'),

    # ---- 원인·등급
    @('파워(전원 공급)', 'Power supply (PSU)'), @('그래픽카드 하드웨어/VRAM', 'Graphics card hardware/VRAM'), @('기타 드라이버/소프트웨어', 'Other drivers/software'),
    @('RAM(메모리)', 'RAM (memory)'), @('CPU·오버클럭·전압', 'CPU · overclock · voltage'), @('과열(쿨링)', 'Overheating (cooling)'), @('저장장치(SSD/HDD)', 'Storage (SSD/HDD)'),
    @('가능성 높음', 'likelihood high'), @('가능성 중간', 'likelihood medium'), @('가능성 낮음', 'likelihood low'),
    @('점검 필요', 'Needs attention'),

    # ---- 블루스크린·Xid 설명
    @('그래픽카드가 응답하지 않아 복구에 실패', 'Graphics card stopped responding and recovery failed'), @('그래픽카드 응답 시간 초과', 'Graphics card response timeout'),
    @('그래픽 스케줄러 오류', 'Graphics scheduler error'), @('그래픽 메모리 관리 오류', 'Graphics memory management error'), @('그래픽 엔진 응답 없음', 'Graphics engine not responding'),
    @('복구 불가능한 하드웨어 오류', 'Uncorrectable hardware error'), @('CPU 코어가 응답하지 않음', 'A CPU core stopped responding'), @('메모리 관리 오류', 'Memory management error'),
    @('잘못된 메모리 접근', 'Invalid memory access'), @('메모리 페이지 목록 손상', 'Memory page list corrupted'), @('메모리 풀 손상', 'Memory pool corrupted'),
    @('드라이버의 잘못된 메모리 요청', 'Invalid memory request by a driver'), @('커널 데이터 손상 감지', 'Kernel data corruption detected'), @('드라이버/메모리 접근 오류', 'Driver/memory access error'),
    @('드라이버 메모리 접근 오류', 'Driver memory access error'), @('시스템 서비스 예외 (그래픽 드라이버에서 흔함)', 'System service exception (common with graphics drivers)'),
    @('드라이버 예외 처리 실패', 'Unhandled driver exception'), @('커널 모드 예외', 'Kernel-mode exception'), @('절전/전원 전환 중 드라이버 문제', 'Driver problem during a sleep/power transition'),
    @('드라이버 또는 SSD 펌웨어 응답 지연', 'Driver or SSD firmware not responding in time'), @('디스크에서 데이터를 읽지 못함', 'Could not read data from disk'), @('디스크 읽기 오류', 'Disk read error'),
    @('핵심 프로세스 종료 (디스크 문제에서 흔함)', 'Critical process terminated (common with disk problems)'), @('핵심 시스템 프로세스 종료', 'Critical system process died'),
    @('부팅 디스크 접근 불가', 'Boot disk inaccessible'), @('저장소 관리 예외', 'Storage management exception'), @('BlueScreenView 로 원인 드라이버 확인 권장', 'Check the faulting driver with BlueScreenView'),
    @('그래픽 엔진 예외 (주로 앱/드라이버)', 'Graphics engine exception (usually app/driver)'), @('GPU 메모리 페이지 오류 (주로 앱/드라이버)', 'GPU memory page fault (usually app/driver)'),
    @('GPU 작업 중단 (앱 오류)', 'GPU stopped processing (app error)'), @('작업 강제 종료', 'Work forcibly terminated'), @('VRAM 더블비트 ECC 오류', 'VRAM double-bit ECC error'),
    @('내부 마이크로컨트롤러 정지', 'Internal microcontroller halt'), @('VRAM 페이지 퇴출(ECC)', 'VRAM page retirement (ECC)'), @('VRAM 페이지 퇴출 실패', 'VRAM page retirement failure'),
    @('NVLink 오류', 'NVLink error'), @('그래픽카드가 PCIe 버스에서 떨어짐', 'Graphics card fell off the PCIe bus'), @('높은 단일비트 ECC 오류율', 'High single-bit ECC error rate'),
    @('VRAM 오류 격리됨', 'VRAM error contained'), @('VRAM 오류 격리 실패', 'VRAM error not contained'), @('GSP 응답 시간 초과', 'GSP response timeout'),

    # ---- 해결 순서
    @('멀티탭을 빼고 벽 콘센트에 직접 연결해 보기', 'Plug the PC directly into the wall instead of a power strip'),
    @('그래픽카드 보조전원(8핀)을 한 줄 케이블이 아니라 각각 별도 케이블로 연결', 'Use separate cables for each graphics card power connector (8-pin), not one daisy-chained cable'),
    @('파워 정격 용량 확인: 그래픽카드 권장 파워 이상인지 (예: RTX 4070 → 650W 이상)', 'Check PSU wattage meets the graphics card recommendation (e.g. RTX 4070 → 650 W or more)'),
    @('메뉴의 "부하 테스트(OCCT Power)" 중 꺼지면 파워 교체 1순위 (5년 이상 사용 파워는 특히 의심)', 'If the PC shuts off during the "OCCT Power" load test, replace the PSU first (especially if older than 5 years)'),
    @('그래픽카드 오버클럭/언더볼트 설정 해제 (MSI Afterburner 기본값)', 'Remove graphics card overclock/undervolt (reset MSI Afterburner to defaults)'),
    @('VRAM 검사(memtest_vulkan) 10분 이상 실행 → error 가 나오면 VRAM 불량', 'Run the VRAM test (memtest_vulkan) for 10+ minutes → any "error" means faulty VRAM'),
    @('그래픽카드를 뽑았다 다시 장착, 슬롯/보조전원 단자 확인', 'Reseat the graphics card and check the slot and power connectors'),
    @('그래도 반복되면 그래픽카드 A/S (진단 보고서 첨부)', 'If it keeps happening, send the card for warranty repair (attach this report)'),
    @('그래픽 드라이버를 최신 "안정" 버전으로 (최근 업데이트 후 문제라면 이전 버전으로)', 'Install the latest stable graphics driver (or roll back if problems started after an update)'),
    @('DDU(Display Driver Uninstaller)로 안전모드에서 완전 삭제 후 재설치', 'Fully remove the driver with DDU (Display Driver Uninstaller) in Safe Mode, then reinstall'),
    @('그래픽 설정의 오버레이/녹화 기능(GeForce Experience, Adrenalin) 끄기', 'Turn off overlay/recording features (GeForce Experience, Adrenalin)'),
    @('계속되면 그래픽카드 하드웨어 점검(VRAM 검사)으로 진행', 'If it continues, move on to hardware checks (VRAM test)'),
    @('BIOS 에서 XMP/EXPO(메모리 오버클럭) 끄고 사용해 보기', 'Disable XMP/EXPO (memory overclock) in the BIOS and try again'),
    @('Windows 메모리 진단 실행 (메뉴) → 더 정밀하게는 MemTest86 USB 부팅 4회 이상', 'Run Windows Memory Diagnostic (menu) → for more depth, MemTest86 from USB, 4+ passes'),
    @('RAM 을 한 개씩만 꽂아 테스트해 불량 모듈 찾기', 'Test one RAM stick at a time to find the faulty module'),
    @('메인보드 BIOS 업데이트', 'Update the motherboard BIOS'),
    @('BIOS 기본값(Load Optimized Defaults)으로 초기화 → 오버클럭/언더볼트 해제', 'Reset BIOS to defaults (Load Optimized Defaults) → removes overclock/undervolt'),
    @('메인보드 BIOS 최신 버전으로 업데이트 (Intel 13·14세대는 마이크로코드 업데이트 필수)', 'Update the motherboard BIOS (mandatory microcode update for Intel 13th/14th gen)'),
    @('CPU 온도와 전압을 HWiNFO 로 확인', 'Check CPU temperature and voltage with HWiNFO'), @('계속되면 CPU/메인보드 점검', 'If it continues, have the CPU/motherboard checked'),
    @('케이스 내부 먼지 청소, 팬이 모두 도는지 확인', 'Clean dust inside the case and make sure every fan spins'),
    @('HWiNFO 로 부하 중 CPU/GPU 온도 확인 (GPU 85°C·CPU 95°C 이상이면 위험)', 'Check CPU/GPU temperatures under load with HWiNFO (GPU 85 °C / CPU 95 °C or more is dangerous)'),
    @('써멀 페이스트 재도포, 케이스 공기 흐름 개선', 'Re-apply thermal paste and improve case airflow'),
    @('중요한 자료를 즉시 백업', 'Back up important data now'), @('CrystalDiskInfo 로 SMART 상태 확인 (주의/나쁨이면 교체)', 'Check SMART with CrystalDiskInfo (replace if Caution/Bad)'),
    @('SSD 펌웨어 업데이트, SATA 케이블 교체', 'Update SSD firmware, replace the SATA cable'), @('관리자 명령 프롬프트에서 chkdsk C: /scan 실행', 'Run chkdsk C: /scan in an administrator command prompt'),
    @('BlueScreenView 로 블루스크린 원인 드라이버(.sys) 확인 (메뉴)', 'Find the faulting driver (.sys) with BlueScreenView (menu)'),
    @('해당 드라이버(칩셋·랜·사운드·보안프로그램) 업데이트 또는 제거', 'Update or remove that driver (chipset, network, audio, security software)'),
    @('관리자 명령 프롬프트: sfc /scannow 후 DISM /Online /Cleanup-Image /RestoreHealth', 'Administrator command prompt: sfc /scannow, then DISM /Online /Cleanup-Image /RestoreHealth'),
    @('최근 설치한 프로그램/드라이버가 있다면 제거 또는 시스템 복원', 'Uninstall recently installed programs/drivers or use System Restore'),

    # ---- 발견 사항 (고정 문구)
    @('블루스크린 없이 꺼짐 (과열 보호 차단 가능)', 'Power-off without blue screen (possible thermal shutdown)'),
    @('블루스크린 기록 없이 전원이 끊긴 것처럼 꺼진 기록입니다. 파워 부족·노후, 과열 보호, 전원 케이블/멀티탭 접촉 불량에서 전형적으로 나타납니다.', 'The PC turned off as if power was cut, with no blue screen. Typical of a weak or aging PSU, thermal protection, or a loose power cable/power strip.'),
    @('블루스크린 코드가 매번 다름 (RAM 불량의 전형적 특징)', 'Blue screen codes differ every time (typical of faulty RAM)'),
    @('VRAM(그래픽 메모리) 오류 신호', 'VRAM (graphics memory) error signals'),
    @('그래픽카드가 연결에서 떨어짐 (Xid 79)', 'Graphics card dropped off the bus (Xid 79)'),
    @('전원 공급 불안정, 슬롯 접촉, 과열에서 주로 발생합니다. 보조전원 케이블과 파워를 먼저 점검하세요.', 'Usually caused by unstable power, a poor slot contact, or overheating. Check the power cables and PSU first.'),
    @('그래픽카드가 오류를 낸 뒤 바로 전원이 꺼졌습니다. 게임 등 고부하에서 파워가 버티지 못하거나 그래픽카드 자체 문제일 가능성이 큽니다.', 'The PC lost power right after a graphics error. Most likely the PSU cannot handle high load (e.g. games) or the graphics card itself is faulty.'),
    @('그래픽 드라이버 설치 직후(3일 이내)부터 문제 시작', 'Problems began within 3 days of a graphics driver install'),
    @('그래픽 드라이버 설치 직후부터 문제 시작', 'Problems began right after a graphics driver install'),
    @(' PCIe 수정 오류만 있다면 대개 가벼운 문제입니다 (BIOS 에서 PCIe 세대를 Gen4/Gen3 로 고정하면 사라지는 경우가 많음).', ' Corrected PCIe errors alone are usually minor (often fixed by forcing PCIe Gen4/Gen3 in the BIOS).'),
    @('Windows 메모리 진단에서 RAM 오류 발견', 'Windows Memory Diagnostic found RAM errors'), @('Windows 메모리 진단에서 오류 발견', 'Windows Memory Diagnostic found errors'),
    @('RAM 불량이 거의 확실합니다. 한 개씩 꽂아 불량 모듈을 찾고 교체하세요.', 'Faulty RAM is almost certain. Test one stick at a time and replace the bad module.'),
    @('XMP/EXPO(메모리 오버클럭) 사용 중 + 메모리 관련 오류', 'XMP/EXPO (memory overclock) enabled + memory-related errors'),
    @('XMP/EXPO(메모리 오버클럭) 사용 중으로 보임', 'XMP/EXPO (memory overclock) appears to be enabled'),
    @('대부분 문제없지만, 불안정하면 BIOS 에서 XMP/EXPO 를 끄고 테스트해 보세요.', 'Usually fine, but if the PC is unstable, disable XMP/EXPO in the BIOS and test.'),
    @('블루스크린 덤프 저장이 꺼져 있음', 'Blue screen dump saving is turned off'),
    @('블루스크린이 나도 원인 기록이 남지 않습니다. 시스템 속성 > 고급 > 시작 및 복구 > "디버깅 정보 쓰기"를 "작은 메모리 덤프" 또는 "자동 메모리 덤프"로 바꾸세요.', 'Blue screens leave no cause record. Go to System Properties > Advanced > Startup and Recovery and set "Write debugging information" to "Small memory dump" or "Automatic memory dump".'),
    @('페이지 파일(가상 메모리)이 꺼져 있음', 'Page file (virtual memory) is turned off'),
    @('페이지 파일이 없으면 블루스크린 덤프를 저장하지 못하고, 메모리 부족 시 프로그램이 갑자기 종료될 수 있습니다. "시스템이 관리하는 크기"로 켜 두세요.', 'Without a page file, blue screen dumps cannot be saved and programs may close suddenly when memory runs low. Set it to "System managed size".'),
    @('가상 머신에서 실행됨', 'Running in a virtual machine'),
    @('가상 머신은 실제 하드웨어 정보를 보여 주지 않아 RAM/온도/그래픽카드 진단이 제한됩니다.', 'Virtual machines hide real hardware details, so RAM/temperature/graphics checks are limited.'),
    @('서로 다른 RAM 모듈 혼용', 'Mixed RAM modules'), @('서로 다른 RAM 모듈을 섞어 사용 중', 'Different RAM modules are mixed'),
    @('용량/제품이 다른 RAM 혼용은 불안정의 원인이 될 수 있습니다.', 'Mixing RAM of different sizes/models can cause instability.'),
    @('SSD 수명 거의 소진', 'SSD nearly worn out'), @('교체를 준비하세요.', 'Plan a replacement.'), @('SSD 고온', 'SSD hot'),
    @('NVMe 방열판/공기 흐름을 확인하세요.', 'Check the NVMe heatsink/airflow.'),
    @('디스크/컨트롤러 오류는 멈춤·블루스크린의 원인이 됩니다. 케이블·펌웨어·SMART 를 확인하세요.', 'Disk/controller errors cause freezes and blue screens. Check cables, firmware and SMART.'),
    @('거의 쉬는 상태인데 온도가 높습니다. 팬 고장이나 먼지 막힘을 확인하세요.', 'Hot while nearly idle. Check for a failed fan or dust buildup.'),
    @('부하 중 온도입니다. 85°C 이상이 계속되면 쿨링을 개선하세요.', 'This is under load. If it stays above 85 °C, improve cooling.'),
    @('검사 시점의 온도입니다. 부하가 거의 없는데도 이 정도라면 팬·먼지·써멀을 점검하세요.', 'Temperature at scan time. If this hot with little load, check fans, dust and thermal paste.'),
    @('HWiNFO 로 CPU 온도를 확인하세요.', 'Check the CPU temperature with HWiNFO.'),
    @('오버클럭·언더볼트 설정을 기본값으로 돌려 테스트해 보세요.', 'Reset overclock/undervolt settings to default and test.'),
    @('그래픽 드라이버가 1년 이상 오래됨', 'Graphics driver is over a year old'),
    @('Intel 13·14세대 CPU + 크래시 (알려진 불안정 이슈)', 'Intel 13th/14th gen CPU + crashes (known instability issue)'),
    @('Intel 13·14세대 CPU', 'Intel 13th/14th gen CPU'),
    @('BIOS 를 최신(마이크로코드 0x12B 이상 포함)으로 업데이트하세요. 구버전 BIOS 는 CPU 불안정/열화 문제가 알려져 있습니다.', 'Update the BIOS to the latest version (microcode 0x12B or newer). Older BIOS versions have known CPU instability/degradation issues.'),
    @('안정성 개선이 포함된 최신 BIOS 를 확인하세요.', 'Check for a newer BIOS with stability fixes.'),
    @('빠른 시작(Fast Startup) 켜짐', 'Fast Startup is on'),
    @('종료/부팅 관련 문제가 있으면 제어판 > 전원 옵션에서 "빠른 시작 켜기"를 꺼 보세요.', 'If you have shutdown/boot problems, turn off "Fast startup" in Control Panel > Power Options.'),
    @('관리자 권한 없이 실행됨', 'Ran without administrator rights'),
    @('일부 기록(덤프 파일 등)을 읽지 못했을 수 있습니다. 원클릭검사.bat 으로 실행하세요.', 'Some records (dump files, etc.) may not have been read. Run it with the launcher .bat file.'),
    @('증상이 계속된다면 VRAM 검사와 RAM 검사로 직접 부하 테스트를 해 보세요. 기록이 남지 않는 순간 정전(파워 문제)일 수도 있습니다.', 'If symptoms continue, run the VRAM and RAM tests yourself. Instant power loss (a PSU problem) can leave no record.'),

    # ---- 보고서 화면
    @('PC 진단 보고서', 'PC Diagnostic Report'), @('가장 의심되는 원인', 'Most likely causes'), @('뚜렷한 원인 후보가 없습니다.', 'No clear cause candidates.'),
    @('점수는 기록된 증거의 강도입니다 (100 = 매우 강함). 해결 순서대로 하나씩 시도하고 다시 검사해 보세요.', 'Scores show the strength of recorded evidence (100 = very strong). Try the fixes in order and scan again.'),
    @('발견 사항', 'Findings'), @('날짜별 기록', 'Timeline'), @('A/S · 상담용 요약', 'Summary for support'),
    @('원격 상담을 받을 때는 이 요약과 함께, 보고서와 같은 폴더에 있는 같은 이름의 <b>.json</b> 파일을 보내 주세요 (상담사가 같은 보고서를 열어 볼 수 있습니다).', 'For remote support, send this summary together with the <b>.json</b> file of the same name in the report folder (the technician can open the same report).'),
    @('요약 복사', 'Copy summary'), @('복사했습니다', 'Copied'), @('Ctrl+C 로 복사하세요', 'Press Ctrl+C to copy'), @('인쇄 / PDF 저장', 'Print / Save PDF'), @('모두 펼치기', 'Expand all'),
    @('상세 기록', 'Details'), @('시스템 정보', 'System information'), @('메인보드', 'Motherboard'), @('마지막 부팅', 'Last boot'), @('전원 관리', 'Power plan'),
    @('빠른 시작', 'Fast startup'), @('켜짐', 'on'), @('꺼짐', 'off'), @('NVIDIA 실시간 상태', 'NVIDIA live status'), @('그래픽 센서 (Windows 제공)', 'Graphics sensors (from Windows)'),
    @('갑작스런 종료 (Kernel-Power 41)', 'Unexpected shutdowns (Kernel-Power 41)'), @('예기치 않은 종료(이벤트 6008):', 'Unexpected shutdowns (event 6008):'),
    @('그래픽 드라이버 오류 (TDR · Xid)', 'Graphics driver errors (TDR · Xid)'), @('하드웨어 오류 (WHEA)', 'Hardware errors (WHEA)'), @('디스크 오류 기록', 'Disk error records'),
    @('그래픽 드라이버 설치 이력 · 자주 충돌한 프로그램', 'Graphics driver installs · frequently crashing programs'), @('자주 충돌한 프로그램', 'Frequently crashing programs'),
    @('기간 내 설치 기록 없음', 'No installs in this period'), @('덤프 파일 없음', 'No dump files'), @('덤프 파일', 'Dump files'), @('기록 없음 ✓', 'No records ✓'),
    @('실행 기록 없음 (메뉴에서 실행 가능)', 'Never run (available from the menu)'), @('❌ 오류 발견', '❌ errors found'), @('✅ 오류 없음', '✅ no errors'),
    @('Windows 메모리 진단:', 'Windows Memory Diagnostic:'), @('날짜별 문제 기록', 'Problems by date'),
    @('조치가 효과를 보고 있는 것으로 보입니다. 며칠 더 사용한 뒤 다시 검사해 확인하세요.', 'The fix appears to be working. Use the PC for a few more days and scan again to confirm.'),
    @('문제가 아직 해결되지 않았습니다. 아래 1순위 원인의 다음 단계를 진행하세요.', 'The problem is not solved yet. Continue with the next step for the top cause below.'),
    @('이 보고서는 PC 안에서만 생성되었으며 어떤 정보도 외부로 전송되지 않았습니다.', 'This report was created entirely on this PC; nothing was sent anywhere.'),
    @('진단은 Windows 기록에 기반한 추정입니다. 하드웨어 교체 전에 정밀 검사(VRAM·RAM·부하 테스트)로 확인하세요.', 'This diagnosis is an estimate based on Windows records. Confirm with the detailed tests (VRAM, RAM, load) before replacing hardware.'),
    @('전원 끊김/멈춤', 'Power loss/freeze'), @('파워·과열·전원 접촉 의심', 'PSU, overheating or power contact suspected'),
    @('블루스크린 기록 없이', 'without a blue screen'), @('상담용', 'support'),
    @('의심 원인:', 'Likely causes:'), @('블루스크린 코드:', 'Blue screen codes:'), @('보드:', 'board:'),
    @('기록: 갑자기꺼짐', 'Records: power-offs'), @('그래픽오류', 'graphics errors'), @('디스크', 'disk'),
    # 표 머리글
    @('드라이버 날짜', 'Driver date'), @('속도 MHz (현재/정격)', 'Speed MHz (current/rated)'), @('사용시간(h)', 'Power-on (h)'), @('읽기오류', 'Read errors'), @('구성요소', 'Component'),
    @('전원버튼', 'Power button'), @('VRAM 사용', 'VRAM used'), @('전력 제한', 'Power limit'),
    @('사용률', 'Usage'), @('제조사', 'Maker'), @('프로그램', 'Program'), @('어댑터', 'Adapter'), @('그래픽카드', 'Graphics card'), @('그래픽 오류', 'Graphics errors'),
    @('갑자기 꺼짐', 'Sudden power-offs'), @('블루스크린', 'Blue screens'), @('그래픽 드라이버 오류', 'Graphics driver errors'), @('하드웨어 오류(WHEA)', 'Hardware errors (WHEA)'), @('디스크 오류', 'Disk errors'),
    @('저장장치', 'Storage'), @('드라이버', 'Driver'), @('그래픽 드라이버', 'Graphics driver'), @('그래픽', 'Graphics'),
    @('상태:', 'Status:'), @('근거', 'Evidence'), @('해결 순서', 'How to fix'), @('위험', 'Critical'), @('주의', 'Warning'), @('참고', 'Info'), @('정상', 'OK'), @('양호', 'Good'),
    @('시간', 'Time'), @('종류', 'Type'), @('추정', 'Likely'), @('코드', 'Code'), @('이름', 'Name'), @('설명', 'Description'), @('출처', 'Source'), @('내용', 'Message'),
    @('파일', 'File'), @('크기', 'Size'), @('슬롯', 'Slot'), @('용량', 'Size'), @('모델', 'Model'), @('상태', 'Status'), @('온도', 'Temp'), @('마모', 'Wear'),
    @('장치', 'Device'), @('팬', 'Fan'), @('횟수', 'Count'), @('클럭', 'Clock'), @('전력', 'Power'), @('예', 'yes'), @('높음', 'high'), @('중간', 'medium'), @('낮음', 'low'),
    @('(미상)', '(unknown)'), @('기타', 'Other'), @('코어 / ', ' cores / '), @('스레드', ' threads'),

    # ---- 화면(GUI)·콘솔·도구
    @('PC 원클릭 진단', 'PC One-Click Check'),
    @('갑자기 꺼짐 · 블루스크린 · 그래픽카드(VRAM) · RAM · 디스크 문제를 Windows 기록으로 분석합니다.', 'Finds causes of power-offs, blue screens, GPU/VRAM, RAM and disk issues.'),
    @('분석 기간', 'Period'), @('검사 시작', 'Start scan'), @('준비됨 (관리자 권한)', 'Ready (administrator)'),
    @('준비됨 — (주의) 관리자 권한이 아니어서 일부 항목이 빠질 수 있습니다', 'Ready — (note) not administrator, some items may be missing'),
    @('상태 점수', 'Health score'), @('의심 원인 / 발견 사항', 'Likely causes / findings'), @('점수', 'Score'), @('가능성', 'Likelihood'),
    @('보고서 열기', 'Open report'), @('저장 폴더 열기', 'Open folder'), @('정밀 검사 (공식 출처에서 받아 실행)', 'Detailed tests (downloaded from official sources)'),
    @('그래픽카드 VRAM 검사', 'Graphics VRAM test'), @('블루스크린 원인 드라이버', 'Blue screen driver check'), @('RAM 검사 (재부팅)', 'RAM test (reboot)'),
    @('온도·전압 모니터링', 'Temperature monitor'), @('파워·GPU 부하 테스트', 'PSU/GPU load test'),
    @('memtest_vulkan (GitHub 오픈소스) · NVIDIA/AMD/Intel', 'memtest_vulkan (GitHub open source) · NVIDIA/AMD/Intel'), @('Windows 메모리 진단 (기본 내장)', 'Windows Memory Diagnostic (built in)'),
    @('HWiNFO 공식 사이트', 'HWiNFO official site'), @('OCCT 공식 사이트', 'OCCT official site'),
    @("새 창에서 엔터를 누르면 시작합니다.`n최소 5~10분 실행 후 'PASSed' 가 나오면 정상, 'error' 가 보이면 VRAM 불량 의심입니다.`n끝내려면 그 창에서 Ctrl+C.`n테스트 중 PC 가 꺼지면 파워/그래픽카드 전원 문제일 가능성이 큽니다.", "Press Enter in the new window to start.`nRun at least 5–10 minutes: 'PASSed' means OK, any 'error' suggests faulty VRAM.`nPress Ctrl+C in that window to stop.`nIf the PC turns off during the test, the PSU/graphics power is the likely cause."),
    @("아래쪽 목록에서 빨간색으로 표시된 파일이 원인 후보입니다.`nnvlddmkm.sys=NVIDIA, amdkmdag.sys=AMD, ntoskrnl.exe=하드웨어/RAM 가능성.", "Files highlighted in red in the lower list are the suspects.`nnvlddmkm.sys=NVIDIA, amdkmdag.sys=AMD, ntoskrnl.exe=possibly hardware/RAM."),
    @("작업을 저장한 뒤 '지금 다시 시작하여 문제 확인'을 선택하세요.`n결과는 재부팅 후 이 프로그램을 다시 실행하면 보고서에 표시됩니다.", "Save your work, then choose 'Restart now and check for problems'.`nAfter rebooting, run this program again to see the result in the report."),
    @('공식 사이트에서 받아 "Sensors-only" 로 실행하세요.', 'Download it from the official site and run it in "Sensors-only" mode.'),
    @("'Power' 테스트 10~20분 중 꺼지면 파워 문제, 'VRAM' 테스트에서 오류면 그래픽카드 문제입니다.", "If the PC turns off during a 10–20 min 'Power' test, it's the PSU; errors in the 'VRAM' test point to the graphics card."),
    @('공식 다운로드 페이지를 열었습니다.', 'Opened the official download page.'), @('실행하지 못했습니다.', 'Could not start.'),
    @('분석 중...', 'Analyzing...'), @('검사 준비 중...', 'Preparing...'), @('검사 중', 'Scanning'), @('완료 — 보고서: ', 'Done — report: '),
    @('오류가 발생했습니다.', 'An error occurred.'), @('검사 중 오류가 발생했습니다.', 'An error occurred during the scan.'), @('화면을 여는 중 오류가 발생했습니다.', 'Could not open the window.'),
    @('로그:', 'Log:'), @('[원인]', '[cause]'), @('[위험]', '[critical]'), @('[주의]', '[warning]'), @('[정상]', '[ok]'),
    @('번호 선택', 'Choose a number'), @('보고서 다시 열기', 'Open report again'), @('종료', 'Exit'), @('정밀 검사', 'Detailed tests'), @('보고서:', 'Report:'), @('실패:', 'Failed:'),
    @('파일 무결성 검증 실패 (SHA256 불일치)', 'File integrity check failed (SHA-256 mismatch)'), @('실행 파일을 찾지 못했습니다.', 'Executable not found.'),
    @('Windows 용 파일을 찾지 못했습니다.', 'No Windows file found.'), @('릴리스 파일:', 'release files:'),
    @('Windows 에서만 검사할 수 있습니다. (-FromJson 으로 보고서 재생성은 가능)', 'Scanning works only on Windows. (-FromJson can still rebuild a report.)'),
    @('시스템 정보', 'System info'), @('갑작스런 종료 기록', 'Shutdown records'), @('블루스크린 기록', 'Blue screen records'), @('메모리 진단 결과', 'Memory diagnostic results'),
    @('드라이버 설치·앱 충돌·온도', 'Driver installs · app crashes · temperature'),
    @('RE:\[(.+?) 단계\] ', '[$1 stage] '),
    @('RE:블랙박스: RAM 검사에서 오류 (\d+) 건', 'Black box: RAM test found $1 errors'),
    @('RE:RAM 검사 오류 (\d+) 건 \(RAM 불량이 거의 확실\)', 'RAM test errors: $1 (faulty RAM almost certain)'),
    @('RE:CPU 부하 중 클럭이 (\d+)% 까지 떨어짐 \(과열·전력 제한\)', 'CPU clock fell to $1% under load (overheating/power limit)'),
    @('RE:블랙박스: 단계별 정밀 테스트 전 단계 통과 \((\d+) 분\)', 'Black box: passed every stage of the detailed test ($1 min)'),
    @('RE:단계 (\d+)/(\d+) · ', 'Stage $1/$2 · '),
    @('RE: · 남은 (\d+) 분 \(전체 (\d+)/(\d+) 분\)', ' · $1 min left (total $2/$3 min)'),
    @('RE: \(클럭 (\d+)%\)', ' (clock $1%)'),
    @('RE: · RAM 검사 ([\d\.]+) GB, 오류 (\d+) 건', ' · RAM test $1 GB, errors $2'),
    @('블랙박스: 전력 출렁임 단계에서 꺼짐 (파워 품질·노후 의심)', 'Black box: shut off during the power-swing stage (PSU quality/aging suspected)'),
    @('블랙박스: 전체 부하 단계에서 꺼짐 (파워 용량 부족 의심)', 'Black box: shut off at full load (insufficient PSU capacity suspected)'),
    @('블랙박스: GPU 단독 부하에서 꺼짐 (그래픽카드·보조전원 의심)', 'Black box: shut off with GPU-only load (graphics card or its power cables suspected)'),
    @('블랙박스: CPU 단독 부하에서 꺼짐 (CPU·메인보드 전원부 의심)', 'Black box: shut off with CPU-only load (CPU or motherboard power delivery suspected)'),
    @('블랙박스: RAM 검사 중 꺼짐 (RAM·메인보드 의심)', 'Black box: shut off during the RAM test (RAM or motherboard suspected)'),
    @('블랙박스: 대기 중에 꺼짐 (전원 연결·메인보드 의심)', 'Black box: shut off while idle (power connection or motherboard suspected)'),
    @('부하가 급하게 바뀌는 순간을 파워가 버티지 못했습니다. 용량이 충분해도 노후·저품질 파워에서 흔한 패턴입니다. 파워 교체 1순위.', 'The PSU could not cope with sudden load changes. Common with aging or low-quality PSUs even when wattage is enough. Replace the PSU first.'),
    @('CPU·GPU 를 각각 돌릴 때는 버텼지만 함께 돌리자 꺼졌습니다. 파워 용량 부족·노후가 가장 유력합니다.', 'It survived CPU and GPU load separately but shut off with both. An undersized or aging PSU is the most likely cause.'),
    @('그래픽카드만 부하를 받았을 때 꺼졌습니다. 그래픽카드 자체 또는 보조전원 케이블·파워의 PCIe 출력이 의심됩니다.', 'It shut off with only the graphics card under load. Suspect the card itself, its power cables, or the PSU''s PCIe output.'),
    @('CPU 만 부하를 받았을 때 꺼졌습니다. CPU 보조전원(4+4핀), 메인보드 전원부, CPU 쿨러 장착, 오버클럭 설정을 확인하세요.', 'It shut off with only the CPU under load. Check the CPU power cable (4+4 pin), motherboard power delivery, CPU cooler mounting and overclock settings.'),
    @('메모리를 집중적으로 쓰는 중에 꺼졌습니다. XMP/EXPO 를 끄고, RAM 을 한 개씩 꽂아 다시 시험하세요.', 'It shut off during heavy memory use. Disable XMP/EXPO and retest with one RAM stick at a time.'),
    @('부하가 없는데 꺼졌습니다. 전원 케이블·멀티탭, 파워, 메인보드 순서로 의심됩니다.', 'It shut off with no load. Suspect the power cable/power strip, then the PSU, then the motherboard.'),
    @('Windows 안에서 메모리에 쓴 값과 다시 읽은 값이 달랐습니다. RAM 불량 가능성이 매우 높습니다. XMP/EXPO 를 끄고 한 개씩 꽂아 불량 모듈을 찾으세요.', 'Values written to memory read back differently. Faulty RAM is very likely. Disable XMP/EXPO and test one stick at a time to find the bad module.'),
    @('그래픽카드 하드웨어 감속 신호 (전원 공급 불안정 또는 과열)', 'Graphics card hardware slowdown signal (unstable power or overheating)'),
    @('그래픽카드 온도 제한 동작', 'Graphics card thermal limiting'),
    @('RE:VRAM 검사 오류 (\d+) 건 \(그래픽카드 메모리 불량 의심\)', 'VRAM test errors: $1 (faulty graphics memory suspected)'),
    @('RE:블랙박스: VRAM 검사에서 오류 (\d+) 건', 'Black box: VRAM test found $1 errors'),
    @(' (이후 테스트 통과)', ' (later test passed)'),
    @('GPU 부하 도구 준비 중...', 'Preparing the GPU load tool...'),
    @('가장 최근 기록 그래프', 'Latest record chart'), @('점검: ', 'Checked by: '), @('블랙박스 이상', 'Blackbox failure'), @('다음 정밀 검사 추천: ', 'Recommended next test: '), @("프로그램의 '정밀 검사'에서 실행해 원인을 확인하세요.", "Run it from 'Detailed tests' in the program to confirm the cause."), @('RE:블랙박스: RAM 검사 오류 (\d+) 건 뒤 꺼짐 \(RAM 불량 의심\)', 'Blackbox: shut down after $1 RAM test error(s) (faulty RAM suspected)'), @('RE:블랙박스: VRAM 검사 오류 (\d+) 건 뒤 꺼짐 \(그래픽카드 불량 의심\)', 'Blackbox: shut down after $1 VRAM test error(s) (faulty graphics card suspected)'), @('점수 변화: ', 'Score history: '), @('RE: → 지금 (\d+)', ' → now $1'), @('Windows 메모리 진단 오류 (이후 검사 통과)', 'Windows Memory Diagnostic errors (passed a later test)'), @('RE:예전 검사에서 오류가 있었지만 ([\d\- :]+) 검사는 오류 없이 통과했습니다\.', 'An earlier test found errors, but the test on $1 passed with no errors.'), @('블랙박스(최근): ', 'Blackbox (latest): '), @('요약 복사', 'Copy summary'), @('요약을 복사했습니다 — 메신저 대화창에 붙여 넣으세요 (Ctrl+V)', 'Summary copied - paste it into your chat (Ctrl+V)'), @('복사하지 못했습니다: ', 'Could not copy: '), @('RE:Windows 안정성 지수 낮음 \(([\d.]+)/10\)', 'Low Windows stability index ($1/10)'), @('신뢰성 모니터가 최근 충돌·오류를 많이 기록했습니다. 시작 메뉴에서 "안정성 기록 보기"로 날짜별 오류를 확인할 수 있습니다.', 'Reliability Monitor recorded many recent crashes and errors. Open "View reliability history" from the Start menu to see errors by date.'), @('Windows 안정성 지수', 'Windows stability index'), @('RE:최근 ([\d.]+) / 10 · 최저 ([\d.]+) · 평균 ([\d.]+)', 'latest $1 / 10 · min $2 · avg $3'), @('RE:블랙박스 기록 중입니다 \((\d+) 줄\)\.', 'Blackbox recording in progress ($1 rows).'), @('기록을 멈추고 창을 닫을까요?', 'Stop recording and close the window?'), @('기록 쓰기 실패 — 다시 시도 중 (USB 연결·여유 공간 확인)', 'Write failed - retrying (check the USB connection and free space)'), @('기록 오류로 기록이 중간에 멈춤 (USB 연결·여유 공간 확인)', 'Recording stopped midway due to a write error (check the USB connection and free space)'), @('점검자 서명', 'Technician signature'), @('고객 확인 서명', 'Customer signature'), @('점검일', 'Date'), @('추천: 이 검사로 원인을 확인하세요', 'Recommended: confirm the cause with this test'),
    @('RE:과열 보호: 그래픽카드 ([\d\.]+) °C 가 이어져 테스트를 멈췄습니다\. 쿨링을 점검하세요\.', 'Overheat protection: the graphics card stayed at $1 °C, so the test was stopped. Check the cooling.'),
    @('블랙박스: 과열 보호로 테스트 중지 (과열 의심)', 'Black box: test stopped by overheat protection (overheating suspected)'),
    @('RE:테스트 중 그래픽카드 온도가 95°C 이상으로 이어져 하드웨어 보호를 위해 부하를 멈췄습니다 \(최고 (.+?)\)\. 팬·먼지·써멀을 점검한 뒤 다시 시험하세요\.', 'The graphics card stayed at 95 °C or more during the test, so the load was stopped to protect the hardware (max $1). Check fans, dust and thermal paste, then test again.'),
    @('노하드(네트워크 부팅) PC 로 보임', 'Looks like a diskless (network-boot) PC'),
    @('재부팅하면 Windows 기록이 사라지는 환경입니다. 아래 블랙박스 기록을 기준으로 판단하세요.', 'Windows records are lost on reboot here. Judge by the black box records below.'),
    @('재부팅하면 Windows 기록이 사라져, 기록이 깨끗해도 문제가 없다는 뜻이 아닙니다. USB 를 꽂고 정밀 검사 → 블랙박스 기록(단계별 자동 테스트)을 실행하세요.', 'Windows records are lost on reboot, so clean records do not mean there is no problem. Plug in a USB drive and run Detailed tests → Black box recorder (automatic staged test).'), @('메모:', 'Note:'), @('메모', 'Note'), @('단계별 최고값', 'Peak values by stage'), @('여기서 꺼짐', 'shut off here'), @('통과', 'passed'), @('GPU 온도', 'GPU temp'), @('GPU 전력', 'GPU power'), @('CPU 사용률', 'CPU usage'), @('결과', 'Result'), @('단계', 'Stage'),
    @('RE:권장 파워 용량: (\d+)W 이상', 'Recommended PSU: $1 W or more'),
    @('RE:최대 소비전력 약 (\d+)W \(그래픽카드 (\d+)W·(.+?) \+ CPU (\d+)W \+ 기타 (\d+)W\)\. 순간 전력 급증을 고려해 정격 (\d+)W 이상, 80 PLUS 인증 제품을 권장합니다\. 파워 라벨의 정격 출력과 비교해 보세요\.', 'Estimated peak draw about $1 W (graphics card $2 W · $3 + CPU $4 W + other $5 W). Allowing for power spikes, a rated $6 W or higher 80 PLUS certified PSU is recommended. Compare with the rated output on your PSU label.'),
    @('전력 제한값', 'power limit'), @('블랙박스 측정', 'black box measurement'), @('모델 대표값', 'typical for model'), @('일반 그래픽카드 가정', 'assumed typical card'), @('블랙박스 기록 그래프', 'Black box record chart'), @('기록 끊김', 'recording cut off'),
    @('GPU 온도 (°C)', 'GPU temperature (°C)'), @('GPU 전력 (W)', 'GPU power (W)'), @('CPU 사용률 (%)', 'CPU usage (%)'),
    @('GPU 부하 도구를 준비하지 못해 GPU 단계는 시험되지 않습니다 (인터넷 연결 확인).', 'Could not prepare the GPU load tool, so the GPU stages will not be tested (check the internet connection).'),
    @('RE: — ([\d\- :]+) 에 단계별 정밀 테스트를 모두 통과해 해결된 것으로 봅니다\.', ' — passed every stage of the detailed test at $1, so treated as resolved.'),
    @('그래픽카드 메모리 검사(memtest_vulkan)에서 오류가 나왔습니다. 오버클럭을 끄고 다시 시험해도 나오면 그래픽카드 A/S 대상입니다.', 'The graphics memory test (memtest_vulkan) found errors. If they persist with overclocking disabled, the card needs warranty service.'),
    @('그래픽카드 연결 끊김 (ERROR_DEVICE_LOST)', 'Graphics card connection lost (ERROR_DEVICE_LOST)'),
    @('GPU 부하 도구가 시작되지 못해 GPU 단계는 시험되지 않음 (Vulkan 드라이버 확인)', 'The GPU load tool failed to start, so the GPU stages were not tested (check the Vulkan driver)'),
    @('단계별 자동 정밀 테스트 (약 32분, 권장)', 'Automatic staged test (about 32 min, recommended)'),
    @('대기 → CPU → RAM 검사 → GPU·VRAM → 전체 부하 → 전력 출렁임 순서로 자동 진행. 꺼진 단계로 원인을 좁힙니다.', 'Runs idle → CPU → RAM test → GPU/VRAM → full load → power swings automatically. The stage where it dies narrows the cause.'),
    @('직접 설정', 'Manual'), @('RAM 검사 (Windows 안에서, 재부팅 없음)', 'RAM test (inside Windows, no reboot)'),
    @('단계별 정밀 테스트를 모두 마쳤습니다. 다시 검사하면 결과가 보고서에 나옵니다.', 'The staged test is complete. Run a scan to see the result in the report.'),
    @('기록을 마쳤습니다.', 'Recording finished.'),
    @('대기 (기준값)', 'Idle (baseline)'), @('CPU 단독 부하', 'CPU only'), @('GPU·VRAM 단독 부하', 'GPU/VRAM only'), @('전체 부하 (CPU+GPU)', 'Full load (CPU+GPU)'), @('전력 출렁임 (10초 간격)', 'Power swings (10 s)'),
    @('RAM 검사', 'RAM test'), @('완료', 'Done'),
    @('RE:마지막 기록 ([\d\- :]+) · 부하 (\d+)% · GPU ', 'Last record $1 · load $2% · GPU '),
    @('RE:블랙박스: 테스트 중 오류 기록 \((\d+) 분\)', 'Black box: errors recorded during test ($1 min)'),
    @('RE:블랙박스: 테스트 (\d+) 분 동안 이상 없음', 'Black box: no problems during a $1-minute test'),
    @('RE:기록 중 · (\d+) 분 · (\d+) 줄', 'Recording · $1 min · $2 rows'),
    @('RE:오류 (\d+) 건', 'errors $1'),
    @('RE:(\d+(?:\.\d+)?) 분', '$1 min'),
    @('블랙박스: 고온 상태에서 기록이 끊김 (과열 의심)', 'Black box: recording stopped while very hot (overheating suspected)'),
    @('블랙박스: 고부하 중 기록이 끊김 (파워 의심)', 'Black box: recording stopped under heavy load (PSU suspected)'),
    @('블랙박스: 낮은 부하에서 기록이 끊김', 'Black box: recording stopped at low load'),
    @('블랙박스 기록이 비어 있음', 'Black box file is empty'),
    @('꺼지기 직전 그래픽카드 온도가 매우 높았습니다. 쿨링(팬·먼지·써멀)을 먼저 점검하세요.', 'The graphics card was very hot right before shutdown. Check cooling (fans, dust, thermal paste) first.'),
    @('온도는 정상인데 부하가 걸린 상태에서 갑자기 꺼졌습니다. 전형적인 파워(PSU) 용량 부족·노후 패턴입니다.', 'Temperatures were normal but the PC died under load. This is the classic weak/aging PSU pattern.'),
    @('부하와 무관하게 꺼졌습니다. 전원 케이블·멀티탭·파워, 메인보드, RAM 순서로 의심됩니다.', 'It shut off regardless of load. Suspect the power cable/power strip/PSU, then motherboard, then RAM.'),
    @('직전 오류:', 'Errors just before:'), @('온도 미상', 'temp unknown'),
    @('꺼지지는 않았지만 테스트 중 오류가 기록되었습니다:', 'The PC did not shut off, but errors were recorded during the test:'),
    @('꺼지지는 않았지만 테스트 중 이상 신호가 기록되었습니다', 'The PC did not shut off, but warning signs were recorded during the test'),
    @('최고 GPU', 'Max GPU'), @('CPU 최고', 'max CPU'),
    @('블랙박스 기록 (실시간 테스트)', 'Black box records (live test)'), @('갑자기 끊김', 'cut off'), @('정상 종료', 'stopped normally'),
    @('GPU 최고', 'Max GPU'), @('판정', 'Verdict'), @('시작', 'Start'), @('길이', 'Length'), @('끝', 'End'),
    @('블랙박스 기록 (노하드용)', 'Black box recorder'), @('부하 테스트 중 상태를 USB 에 실시간 기록', 'Logs live status to USB during a load test'),
    @('블랙박스 기록 (재현 테스트)', 'Black box recorder (reproduce test)'), @('블랙박스 기록', 'Black box records'),
    @('노하드 PC 는 재부팅하면 기록이 사라지므로 USB 에 저장하세요. PC 가 꺼지면 다시 켠 뒤 이 프로그램으로 검사하면 기록을 자동으로 분석합니다.', 'Diskless PCs lose records on reboot, so save to USB. If the PC shuts off, turn it back on and run a scan: the record is analyzed automatically.'),
    @('저장 위치', 'Save to'), @('찾아보기', 'Browse'), @('USB 가 선택되었습니다.', 'USB drive selected.'),
    @('(주의) USB 가 없습니다. 노하드라면 USB 를 꽂고 다시 여세요.', '(note) No USB drive. On a diskless PC, plug one in and reopen.'),
    @('CPU 부하 걸기 (모든 코어 100%)', 'CPU load (all cores 100%)'), @('GPU·VRAM 부하 걸기 (memtest_vulkan 창이 열림)', 'GPU/VRAM load (opens memtest_vulkan)'),
    @('둘 다 켜면 전력 소모가 가장 커서 파워 문제 재현에 좋습니다. 20~30분 이상 권장.', 'Both together draw the most power — best for reproducing PSU problems. Run 20–30+ min.'),
    @('대기 중', 'Idle'), @('기록 시작', 'Start'), @('중지', 'Stop'), @('기록 파일 분석', 'Analyze file'),
    @('기록을 마쳤습니다. memtest_vulkan 창은 Ctrl+C 로 닫으세요.', 'Recording finished. Close the memtest_vulkan window with Ctrl+C.'),
    @('기록 오류:', 'Recording error:'), @('GPU 부하 도구를 시작하지 못했습니다.', 'Could not start the GPU load tool.'),
    @('기록을 시작하지 못했습니다.', 'Could not start recording.'), @('분석하지 못했습니다.', 'Could not analyze.')
)

function Get-EnTable {
    if ($script:EnRe) { return }
    $re = New-Object System.Collections.ArrayList; $lit = New-Object System.Collections.ArrayList; $rx = New-Object System.Collections.ArrayList
    foreach ($p in $script:EnPairs) {
        if ($p[0].StartsWith('RE:')) { [void]$re.Add(@((New-Object Text.RegularExpressions.Regex($p[0].Substring(3))), $p[1])) }
        elseif ($p[0].StartsWith('RX:')) { [void]$rx.Add(@((New-Object Text.RegularExpressions.Regex($p[0].Substring(3))), $p[1])) }
        else { [void]$lit.Add($p) }
    }
    $script:EnRe = $re; $script:EnRx = $rx
    $script:EnLit = @($lit | Sort-Object { - $_[0].Length })
}
function Tr([string]$s) {
    # 한국어 출력 문자열을 현재 언어로 (ko 이면 그대로)
    if ($script:UiLang -ne 'en' -or -not $s -or $s -notmatch '[가-힣]') { return $s }
    Get-EnTable
    foreach ($r in $script:EnRe) { $s = $r[0].Replace($s, $r[1]) }
    foreach ($p in $script:EnLit) { if ($s.Contains($p[0])) { $s = $s.Replace($p[0], $p[1]) } }
    foreach ($r in $script:EnRx) { $s = $r[0].Replace($s, $r[1]) }
    return $s
}
function Get-DefaultLang {
    try { if ((Get-Culture).TwoLetterISOLanguageName -eq 'ko') { return 'ko' } } catch {}
    return 'en'
}

# =====================================================================
#  진입점
# =====================================================================
if ($LoadOnly) { return }
if ($Lang -eq 'auto') { $script:UiLang = Get-DefaultLang } else { $script:UiLang = $Lang }

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$script:ShopText = Get-ShopText $Shop
$script:OutDirDefault = -not $OutDir
if (-not $OutDir) {
    $desk = [Environment]::GetFolderPath('Desktop'); if (-not $desk) { $desk = $HOME }
    $OutDir = Join-Path $desk (Get-OutputPrefix)
}
New-Item -ItemType Directory -Force -Path $script:WorkDir, (Join-Path $script:WorkDir 'logs') -ErrorAction SilentlyContinue | Out-Null
$script:LogFile = Join-Path $script:WorkDir ("logs\{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
Write-PCLog "$($script:AppName) v$($script:AppVersion) mode=$Mode days=$Days ps=$($PSVersionTable.PSVersion)"

if ($FromJson) {
    $data = ConvertFrom-PCJson (Get-Content -Raw -Encoding UTF8 -Path $FromJson)
    $dx = Get-Diagnosis -Data $data
    $res = Save-Results -Data $data -Dx $dx -Dir $OutDir
    Write-ConsoleResult $dx $res
    if ($Mode -eq 'Silent') { Write-Output $res; return }
    if (-not $NoOpen) { Start-Process $res.Html }
    return

}

if (-not $script:IsWin) { Write-Error 'Windows 에서만 검사할 수 있습니다. (-FromJson 으로 보고서 재생성은 가능)'; exit 2 }

if ($Mode -eq 'Gui') {
    try {
        if ($GuiSmokeTest) { foreach ($lg in 'ko', 'en') { $script:UiLang = $lg; foreach ($s in 1.0, 1.25, 1.5, 2.0) { Write-Output "[$lg] 배율 $([int]($s * 100))%"; Show-Gui -Days $Days -OutDir $OutDir -SmokeTest -SimScale $s; $bi = @(Show-BlackboxDialog -SmokeTest -SimScale $s); foreach ($i in $bi) { Write-Output "BLACKBOX LAYOUT ISSUE: $i" }; if ($bi.Count) { throw "블랙박스 창 레이아웃 문제 $($bi.Count) 건" } } } }
        else { Show-Gui -Days $Days -OutDir $OutDir -Note $Note }
        return
    }

    catch {
        if ($GuiSmokeTest) { throw }
        # 화면을 띄우지 못하면 보이는 콘솔 창으로 다시 실행 (숨김 창에서 멈추지 않도록)

        Write-PCLog "gui failed, relaunch console: $($_.Exception.Message)"
        if (-not $PSCommandPath) {
            # EXE(ps2exe)로 실행된 경우: 스크립트 경로가 없으므로 오류만 안내
            try { [void][Windows.Forms.MessageBox]::Show((Tr "화면을 여는 중 오류가 발생했습니다.`n$($_.Exception.Message)`n`n로그: $($script:LogFile)"), (Tr $script:AppName)) } catch {}
            return
        }

        Start-Process -FilePath 'powershell.exe' -ArgumentList (Get-ConsoleRelaunchArgs -Path $PSCommandPath -Days $Days -OutDir $OutDir -Lang $script:UiLang -Note $Note -Shop $Shop)
        return
    }
}

Write-TrHost "$($script:AppName) v$($script:AppVersion) — 최근 $Days 일 분석" -ForegroundColor Cyan
$data = Invoke-Collect -Days $Days -Progress { param($i, $n, $name) Write-Host ("[{0}/{1}] {2}" -f $i, $n, (Tr $name)) }
if ($Note) { $data.Meta.Note = $Note.Trim() }
if ($script:ShopText) { $data.Meta.Shop = $script:ShopText }
$dx = Get-Diagnosis -Data $data
$res = Save-Results -Data $data -Dx $dx -Dir (Get-ReportDir $data $OutDir $script:OutDirDefault (Get-UsbRoot)) -Track
Write-ConsoleResult $dx $res
if ($Mode -eq 'Silent') { Write-Output $res; return }
if (-not $NoOpen) { Start-Process $res.Html }
Start-ConsoleMenu $res

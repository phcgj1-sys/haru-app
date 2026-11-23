#Requires -Version 5.1
<#
  PC방 윈도우11 초기 세팅 스크립트 (1. 설치 후 개인정보/점검, 2. 드라이버·런타임, 5. 최적화)
  - 실행: 같은 폴더의 run_setup.bat 을 더블클릭 (관리자 권한 자동 요청)
  - 반드시 "손님이 실제로 사용할 계정"으로 로그인한 상태에서 실행하세요.
    (마우스 가속/알림 등 사용자별 설정은 실행한 계정에 적용됩니다)
  - 실행 후 재부팅 필요. 로그는 스크립트 폴더에 저장됩니다.
#>

# ============================== 설정 구역 (필요에 맞게 수정) ==============================
$InstallRuntimes   = $true    # VC++ / DirectX / .NET 설치 (winget, 인터넷 필요)
$OpenDriverPages   = $true    # 그래픽/칩셋 드라이버 다운로드 페이지 자동 열기
$ExtraWingetIds    = @()      # 추가 설치할 프로그램 winget ID 예: @('Logitech.GHUB','Discord.Discord')

$DisableVBS        = $true    # 메모리 무결성/VBS 끄기 (성능↑). 특정 안티치트가 요구하면 $false
$BlockWinUpdate    = $true    # 윈도우 자동 업데이트 차단 (점검 때 수동 업데이트)
$RemoveOneDrive    = $true
$RemoveCopilot     = $true

$EnableAutoLogon   = $true    # 자동 로그인 (현재 계정)
$AutoLogonPassword = ''       # 계정 비밀번호 (없으면 빈칸). 레지스트리에 평문 저장됨에 주의

$GamePaths         = @('C:\Games', 'D:\Games')   # Defender 검사 예외 폴더

# 고정 IP (비워두면 건너뜀). 이미지 배포 후 PC마다 바꿔서 실행하거나 수동 설정
$ComputerName      = ''       # 예: 'PC-001'
$IPAddress         = ''       # 예: '192.168.0.101'
$PrefixLength      = 24       # 255.255.255.0 = 24
$Gateway           = ''       # 예: '192.168.0.1'
$DnsServers        = @('168.126.63.1', '8.8.8.8')
# ==========================================================================================

$ErrorActionPreference = 'Continue'

# ---------- 관리자 확인 ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host '관리자 권한으로 실행해야 합니다. run_setup.bat 으로 실행하세요.' -ForegroundColor Red
    exit 1
}

$logFile = Join-Path $PSScriptRoot ("setup_log_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
Start-Transcript -Path $logFile | Out-Null

$script:Manual = New-Object System.Collections.Generic.List[string]

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function OK($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [!] $msg" -ForegroundColor Yellow; $script:Manual.Add($msg) }

function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "  [X] 레지스트리 실패: $Path\$Name ($($_.Exception.Message))" -ForegroundColor Red
    }
}

# ======================================================================
# 1. 설치 후 점검 + 개인정보 옵션 끄기
# ======================================================================
Step '1. 바이오스 상태 점검 (TPM / 보안 부팅)'
try {
    $tpm = Get-Tpm -ErrorAction Stop
    if ($tpm.TpmPresent -and $tpm.TpmReady) { OK 'TPM 2.0 사용 중' } else { Warn 'TPM 비활성 -> 바이오스에서 fTPM/PTT 켜기 (발로란트 등 필수)' }
} catch { Warn 'TPM 상태 확인 불가 -> 바이오스에서 직접 확인' }
try {
    if (Confirm-SecureBootUEFI -ErrorAction Stop) { OK '보안 부팅(Secure Boot) 켜짐' } else { Warn '보안 부팅 꺼짐 -> 바이오스에서 Secure Boot 켜기' }
} catch { Warn '보안 부팅 미지원/레거시 모드 -> 바이오스에서 UEFI + Secure Boot 설정' }

$memSpeed = (Get-CimInstance Win32_PhysicalMemory | Select-Object -First 1).ConfiguredClockSpeed
if ($memSpeed) { Write-Host "  램 동작 속도: $memSpeed MT/s (정격보다 낮으면 바이오스에서 XMP/EXPO 켜기)" }

Step '1. 개인정보 옵션 끄기 (위치/진단/광고 ID/맞춤 환경)'
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 1   # Pro 최소값
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location' 'Value' 'Deny' 'String'
Set-Reg 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
Set-Reg 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
OK '개인정보 옵션 적용'

# ======================================================================
# 2. 드라이버 / 런타임
# ======================================================================
Step '2. 그래픽 / 칩셋 드라이버 확인'
$gpus = Get-CimInstance Win32_VideoController
foreach ($g in $gpus) { Write-Host ("  GPU: {0}  (드라이버 {1})" -f $g.Name, $g.DriverVersion) }
$cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
Write-Host "  CPU: $cpu"

if ($OpenDriverPages) {
    if ($gpus.Name -match 'NVIDIA')        { Start-Process 'https://www.nvidia.com/ko-kr/drivers/' }
    if ($gpus.Name -match 'AMD|Radeon')    { Start-Process 'https://www.amd.com/ko/support/download/drivers.html' }
    if ($cpu -match 'AMD')                 { Start-Process 'https://www.amd.com/ko/support/download/drivers.html' }
    if ($cpu -match 'Intel' -or $gpus.Name -match 'Intel') { Start-Process 'https://www.intel.co.kr/content/www/kr/ko/support/detect.html' }
}
Warn '그래픽 드라이버(최신) / 칩셋 / 랜 / 사운드 드라이버는 열린 페이지 또는 메인보드 제조사 사이트에서 설치'

if ($InstallRuntimes) {
    Step '2. .NET Framework 3.5 활성화'
    try {
        Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All -NoRestart -ErrorAction Stop | Out-Null
        OK '.NET 3.5 활성화'
    } catch { Warn ".NET 3.5 활성화 실패 (인터넷/윈도우 업데이트 연결 확인): $($_.Exception.Message)" }

    Step '2. winget 준비'
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        try { Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop } catch {}
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Warn 'winget 없음 -> Microsoft Store에서 "앱 설치 관리자" 업데이트 후 다시 실행'
    } else {
        OK 'winget 사용 가능'
        $pkgs = @(
            'Microsoft.VCRedist.2005.x86', 'Microsoft.VCRedist.2005.x64',
            'Microsoft.VCRedist.2008.x86', 'Microsoft.VCRedist.2008.x64',
            'Microsoft.VCRedist.2010.x86', 'Microsoft.VCRedist.2010.x64',
            'Microsoft.VCRedist.2012.x86', 'Microsoft.VCRedist.2012.x64',
            'Microsoft.VCRedist.2013.x86', 'Microsoft.VCRedist.2013.x64',
            'Microsoft.VCRedist.2015+.x86', 'Microsoft.VCRedist.2015+.x64',
            'Microsoft.DirectX',
            'Microsoft.DotNet.DesktopRuntime.6',
            'Microsoft.DotNet.DesktopRuntime.8',
            'Microsoft.DotNet.DesktopRuntime.10'
        ) + $ExtraWingetIds

        Step '2. 런타임 설치 (VC++ / DirectX / .NET)'
        foreach ($id in $pkgs) {
            Write-Host "  설치 중: $id"
            winget install --id $id -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
            # 0 = 성공, -1978335189 = 이미 설치됨, 3010/1641 = 재부팅 필요
            if (@(0, -1978335189, 3010, 1641) -contains $LASTEXITCODE) { OK $id }
            else { Warn "$id 설치 실패 (코드 $LASTEXITCODE) -> 수동 설치 필요" }
        }
    }
}

# ======================================================================
# 5. 윈도우 최적화
# ======================================================================
Step '5. 전원 옵션 (최고의 성능 / 절전 끄기 / 빠른 시작 끄기)'
$ultimate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$out = powercfg -duplicatescheme $ultimate 2>$null
$guid = [regex]::Match(($out -join ' '), '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}').Value
if ($guid) { powercfg -setactive $guid; OK '전원 관리: 최고의 성능' }
else { powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c; OK '전원 관리: 고성능' }
powercfg /change monitor-timeout-ac 0
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change disk-timeout-ac 0
powercfg /hibernate off
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0
OK '절전/디스플레이 끄기 사용 안 함, 빠른 시작 꺼짐'

Step '5. 게임 모드 / GPU 스케줄링 / 게임 바 녹화 끄기'
Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
Set-Reg 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
OK '게임 모드 켜기, 하드웨어 가속 GPU 스케줄링 켜기, 백그라운드 녹화 끄기'

if ($DisableVBS) {
    Step '5. 메모리 무결성 / VBS 끄기'
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0
    OK '메모리 무결성/VBS 꺼짐 (재부팅 후 적용)'
}

if ($BlockWinUpdate) {
    Step '5. 윈도우 업데이트 / 드라이버 자동 업데이트 차단'
    $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    Set-Reg "$wu\AU" 'NoAutoUpdate' 1
    Set-Reg "$wu\AU" 'AUOptions' 2
    Set-Reg $wu 'ExcludeWUDriversInQualityUpdate' 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' 'SearchOrderConfig' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Settings' 'DisableSendGenericDriverNotFoundToWER' 1
    OK '자동 업데이트 차단 (점검 시 설정 > Windows 업데이트 에서 수동 업데이트)'
}

Step '5. 마우스 가속 끄기 / Num Lock 켜기'
Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'
Set-Reg 'HKCU:\Control Panel\Mouse' 'MouseSensitivity' '10' 'String'
Set-Reg 'HKCU:\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' 'String'
Set-Reg 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' 'String'
OK '포인터 정확도 향상 꺼짐, 부팅 시 Num Lock 켜짐'

Step '5. 모니터 주사율 확인'
foreach ($g in $gpus) {
    if ($g.CurrentRefreshRate) {
        Write-Host ("  {0}: {1}Hz" -f $g.Name, $g.CurrentRefreshRate)
        if ($g.CurrentRefreshRate -le 75) { Warn "$($g.Name) 주사율 $($g.CurrentRefreshRate)Hz -> 설정 > 디스플레이 > 고급 디스플레이에서 최대(144/165/240Hz)로 변경" }
    }
}

Step '5. 알림 / 추천 / 광고 / 위젯 / 검색 하이라이트 끄기'
$cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
foreach ($n in 'SubscribedContent-338388Enabled','SubscribedContent-338389Enabled','SubscribedContent-338393Enabled',
               'SubscribedContent-353694Enabled','SubscribedContent-353696Enabled','SubscribedContent-310093Enabled',
               'SystemPaneSuggestionsEnabled','SilentInstalledAppsEnabled','SoftLandingEnabled','RotatingLockScreenOverlayEnabled') {
    Set-Reg $cdm $n 0
}
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\CloudContent' 'DisableTailoredExperiencesWithDiagnosticData' 1

$adv = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Set-Reg $adv 'Start_IrisRecommendations' 0      # 시작 메뉴 추천
Set-Reg $adv 'Start_TrackDocs' 0                # 최근 파일 표시
Set-Reg $adv 'Start_AccountNotifications' 0
Set-Reg $adv 'ShowTaskViewButton' 0             # 작업 보기 버튼
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0        # 위젯
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 1   # 검색창 -> 아이콘
Set-Reg 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDynamicSearchBoxEnabled' 0  # 검색 하이라이트
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch' 1
Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
OK '알림/추천/광고/위젯/검색 하이라이트 꺼짐'

if ($RemoveCopilot) {
    Step '5. Copilot 앱 제거'
    Get-AppxPackage -AllUsers -Name '*Microsoft.Copilot*' -ErrorAction SilentlyContinue |
        ForEach-Object { try { Remove-AppxPackage -Package $_.PackageFullName -AllUsers -ErrorAction Stop; OK "제거: $($_.Name)" } catch {} }
}

if ($RemoveOneDrive) {
    Step '5. OneDrive 제거'
    Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
    $done = $false
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget uninstall --id Microsoft.OneDrive -e --silent --accept-source-agreements --disable-interactivity | Out-Null
        if ($LASTEXITCODE -eq 0) { $done = $true }
    }
    if (-not $done) {
        foreach ($p in "$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") {
            if (Test-Path $p) { Start-Process $p '/uninstall' -Wait; $done = $true; break }
        }
    }
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1
    Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDrive' -ErrorAction SilentlyContinue
    OK 'OneDrive 제거 및 재설치 차단'
}

Step '5. Defender 게임 폴더 예외'
foreach ($p in $GamePaths) {
    try { Add-MpPreference -ExclusionPath $p -ErrorAction Stop; OK "예외 추가: $p" }
    catch { Warn "예외 추가 실패: $p (타사 백신 사용 중이면 해당 백신에서 설정)" }
}

if ($EnableAutoLogon) {
    Step '5. 자동 로그인'
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-Reg $wl 'AutoAdminLogon' '1' 'String'
    Set-Reg $wl 'DefaultUserName' $env:USERNAME 'String'
    Set-Reg $wl 'DefaultDomainName' $env:COMPUTERNAME 'String'
    Set-Reg $wl 'DefaultPassword' $AutoLogonPassword 'String'
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device' 'DevicePasswordLessBuildVersion' 0
    OK "자동 로그인: $env:USERNAME"
}

if ($IPAddress -and $Gateway) {
    Step '5. 고정 IP 설정'
    $nic = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
    if ($nic) {
        Set-NetIPInterface -InterfaceIndex $nic.ifIndex -Dhcp Disabled -ErrorAction SilentlyContinue
        Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceIndex $nic.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress -InterfaceIndex $nic.ifIndex -IPAddress $IPAddress -PrefixLength $PrefixLength -DefaultGateway $Gateway | Out-Null
        Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $DnsServers
        OK "$($nic.Name): $IPAddress/$PrefixLength, GW $Gateway, DNS $($DnsServers -join ', ')"
    } else { Warn '연결된 유선 랜카드를 찾지 못함 -> 고정 IP 수동 설정' }
}

if ($ComputerName -and $ComputerName -ne $env:COMPUTERNAME) {
    Step '5. 컴퓨터 이름 변경'
    Rename-Computer -NewName $ComputerName -Force
    OK "컴퓨터 이름 -> $ComputerName (재부팅 후 적용)"
}

# ---------- 탐색기 재시작 (UI 설정 즉시 반영) ----------
Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue

# ---------- 결과 요약 ----------
Step '완료 - 수동으로 확인할 항목'
$script:Manual.Add('NVIDIA 제어판: 전원 관리 모드 "최대 성능 선호", 저지연 모드 "켜기"')
$script:Manual.Add('사운드: 기본 출력/입력 장치를 헤드셋으로 지정, 마이크 레벨 확인')
$script:Manual.Add('주변기기 SW(G HUB, 시냅스 등), 게임 런처, PC방 관리/복원 프로그램 설치')
$i = 1
foreach ($m in $script:Manual) { Write-Host ("  {0}. {1}" -f $i, $m) -ForegroundColor Yellow; $i++ }
Write-Host "`n로그 파일: $logFile"

Stop-Transcript | Out-Null

$ans = Read-Host "`n지금 재부팅할까요? (Y/N)"
if ($ans -match '^[Yy]') { Restart-Computer -Force }

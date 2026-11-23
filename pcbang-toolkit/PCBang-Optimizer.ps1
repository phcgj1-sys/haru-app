<#
  PC방 윈도우11 최적화 도구
  - 더블클릭 실행: Start-GUI.bat  (체크박스 화면에서 골라서 적용 / 되돌리기 / 상태 점검)
  - 자동 적용  : Apply-Recommended.bat  (권장 프리셋을 화면 없이 적용, 여러 PC 일괄 작업용)
  - 명령줄     : PCBang-Optimizer.ps1 -Preset Safe|Recommended|Max [-Exclude id1,id2] [-NoReboot]
                 PCBang-Optimizer.ps1 -UndoAll      (이 도구로 바꾼 것 전부 원래대로)
                 PCBang-Optimizer.ps1 -Report       (PC 진단 + 항목별 적용 상태만 출력)
                 -Preset 은 같은 단계의 작업 스케줄러 정리도 함께 적용 (-NoTasks 로 제외)
  다른 프로그램에 탭으로 넣기 : EMBED-GUIDE.txt 참고 (Add-PCBangTabs -TabControl $tabs)
  주의
  - 복원 프로그램(디스크 보호)을 "해제"한 상태에서 적용해야 재부팅 후에도 유지됩니다.
  - 손님이 쓰는 계정으로 로그인해서 실행하세요 (사용자별 설정은 실행한 계정에 적용).
  - 바꾸기 전 원래 값은 backup\backup.json 에 저장되며, 되돌리기로 복구됩니다.
#>
param(
    [string]$Preset,
    [string[]]$Exclude = @(),
    [switch]$UndoAll,
    [switch]$Report,
    [switch]$NoReboot,
    [switch]$NoTasks
)

$Version = '1.1'
$Embedded = ($env:PCBANG_EMBED -eq '1') -and -not $MyInvocation.MyCommand.Path
# [ValidateSet]을 param에 두면 PS 5.1에서 스크립트 블록 모듈(탭 넣기)로 불러올 때 오류가 나서 여기서 검사
if ($Preset -and $Preset -notin 'Safe', 'Recommended', 'Max') {
    Write-Host "-Preset 은 Safe, Recommended, Max 중 하나여야 합니다. (입력: $Preset)" -ForegroundColor Red
    exit 1
}

# ============================== 사용자 설정 ==============================
# Defender 검사 예외로 넣을 게임 폴더 (존재하는 폴더만 추가됨)
$GamePaths = @(
    'C:\Games', 'D:\Games', 'E:\Games',
    'C:\Riot Games', 'D:\Riot Games',
    'C:\Program Files (x86)\Steam', 'D:\SteamLibrary',
    'C:\Nexon', 'D:\Nexon',
    'C:\Program Files (x86)\Battle.net', 'C:\Program Files\Epic Games'
)
# 지울 기본 앱 (Xbox/스토어/사진/계산기/메모장/빠른 지원은 일부러 남김)
$BloatApps = @(
    'Clipchamp.Clipchamp', 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch',
    'Microsoft.GetHelp', 'Microsoft.Getstarted', 'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.People', 'Microsoft.PowerAutomateDesktop',
    'Microsoft.Todos', 'Microsoft.WindowsFeedbackHub', 'Microsoft.WindowsMaps', 'Microsoft.YourPhone',
    'MicrosoftCorporationII.MicrosoftFamily', 'MSTeams', 'Microsoft.OutlookForWindows',
    'Microsoft.Windows.DevHome', 'Microsoft.549981C3F5F10', 'Microsoft.Copilot', 'Microsoft.MicrosoftJournal'
)
# =========================================================================

$ErrorActionPreference = 'Continue'
if ($MyInvocation.MyCommand.Path) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
elseif ($env:PCBANG_DIR) { $ScriptDir = $env:PCBANG_DIR }
else { $ScriptDir = (Get-Location).Path }

# ---------- 관리자 권한으로 다시 실행 ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $Embedded -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($MyInvocation.MyCommand.Path)`"")
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { $argList += "-$k" } }
        elseif ($v -is [array]) { if (@($v).Count -gt 0) { $argList += "-$k"; $argList += ($v -join ',') } }
        else { $argList += "-$k"; $argList += "`"$v`"" }
    }
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -ErrorAction Stop }
    catch { Write-Host '관리자 권한이 필요합니다. (UAC 창에서 "예"를 눌러야 실행됩니다)' -ForegroundColor Red; Start-Sleep 5 }
    exit
}

$BackupDir  = Join-Path $ScriptDir 'backup'
$LogDir     = Join-Path $ScriptDir 'logs'
$BackupFile = Join-Path $BackupDir 'backup.json'
$MySid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
foreach ($d in $BackupDir, $LogDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null } }
$LogFile = Join-Path $LogDir ("{0}_{1}.log" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd'))

$script:LogBoxes = $null
function Log([string]$msg, [string]$lvl = 'INFO') {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $msg
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {}
    if ($script:LogBoxes -and $script:LogBoxes.Count -gt 0) {
        foreach ($lb in $script:LogBoxes) {
            if ($lb.IsDisposed) { continue }
            try { $lb.AppendText($line + "`r`n"); $lb.ScrollToCaret() } catch {}
        }
        [System.Windows.Forms.Application]::DoEvents()
    } else {
        $color = 'Gray'
        if ($lvl -eq 'OK') { $color = 'Green' } elseif ($lvl -eq 'WARN') { $color = 'Yellow' } elseif ($lvl -eq 'ERR') { $color = 'Red' }
        Write-Host $line -ForegroundColor $color
    }
}

# ============================== 레지스트리 / 백업 엔진 ==============================
function RegOp {
    param([string]$P, [string]$N, $V, [string]$T = 'DWord', [switch]$IfExists)
    [pscustomobject]@{ P = $P; N = $N; V = $V; T = $T; IfExists = [bool]$IfExists }
}
function Svc([string]$Name) { RegOp "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" 'Start' 4 -IfExists }
function Tk([string]$P, [string]$N) { [pscustomobject]@{ P = $P; N = $N } }

function Resolve-V($v) { if ($v -is [scriptblock]) { return (& $v) } return $v }

function Get-RegVal([string]$p, [string]$n) {
    try {
        $key = Get-Item -LiteralPath $p -ErrorAction Stop
        if ($key.GetValueNames() -contains $n) {
            return [pscustomobject]@{
                Exists = $true
                Value  = $key.GetValue($n, $null, 'DoNotExpandEnvironmentNames')
                Kind   = $key.GetValueKind($n).ToString()
            }
        }
    } catch {}
    return [pscustomobject]@{ Exists = $false; Value = $null; Kind = $null }
}

function Set-RegVal([string]$p, [string]$n, $v, [string]$t) {
    try {
        if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force -ErrorAction Stop | Out-Null }
        New-ItemProperty -LiteralPath $p -Name $n -Value $v -PropertyType $t -Force -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Log "  레지스트리 실패: $p\$n ($($_.Exception.Message))" 'ERR'
        return $false
    }
}

function Test-RegEq($cur, $want) {
    if (-not $cur.Exists) { return $false }
    if ($want -is [string]) { return ([string]$cur.Value -eq $want) }
    try { return ([int64]$cur.Value -eq [int64]$want) } catch { return $false }
}

function Convert-BkVal($v, [string]$kind) {
    switch ($kind) {
        'Binary'      { return [byte[]]@($v) }
        'MultiString' { return [string[]]@($v) }
        'DWord'       { return [int64]$v }
        'QWord'       { return [int64]$v }
        'String'      { return [string]$v }
        'ExpandString'{ return [string]$v }
        default       { return $null }
    }
}

$script:Backup = @{}
function Load-Backup {
    $script:Backup = @{}
    if (Test-Path $BackupFile) {
        try {
            $o = Get-Content -Path $BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($prop in $o.PSObject.Properties) { $script:Backup[$prop.Name] = $prop.Value }
            # v1.0 의 '원격 분석 예약 작업 끄기' 기록 -> 작업 스케줄러 탭 기록으로 옮김
            if ($script:Backup.ContainsKey('tasks_telemetry')) {
                foreach ($k in @($script:Backup['tasks_telemetry'].Tasks)) {
                    if (-not $k) { continue }
                    $key = "task|$($k.P)$($k.N)"
                    if (-not $script:Backup.ContainsKey($key)) {
                        $script:Backup[$key] = [pscustomobject]@{ P = $k.P; N = $k.N; Enabled = [bool]$k.Enabled; Xml = $null; Time = $script:Backup['tasks_telemetry'].Time }
                    }
                }
                $script:Backup.Remove('tasks_telemetry')
                Save-Backup
            }
        } catch { Log "백업 파일을 읽지 못했습니다: $($_.Exception.Message)" 'ERR' }
    }
}
function Save-Backup {
    $script:Backup | ConvertTo-Json -Depth 8 | Set-Content -Path $BackupFile -Encoding UTF8
}

# ============================== 최적화 항목 정의 ==============================
# Level: 1=안전  2=권장  3=최대(효과 작거나 트레이드오프 있음)  0=선택(문제 있을 때만)
$script:Tweaks = New-Object System.Collections.Generic.List[object]
function Add-Tweak {
    param(
        [string]$Id, [string]$Cat, [int]$Level, [string]$Name, [string]$Desc, [string]$Risk = '낮음',
        [object[]]$Reg = @(), [object[]]$Tasks = @(), [string[]]$Stop = @(),
        [scriptblock]$Apply, [scriptblock]$Undo, [scriptblock]$Check, [scriptblock]$Skip, [switch]$NoUndo
    )
    $script:Tweaks.Add([pscustomobject]@{
        Id = $Id; Cat = $Cat; Level = $Level; Name = $Name; Desc = $Desc; Risk = $Risk
        Reg = @($Reg | Where-Object { $_ }); Tasks = @($Tasks | Where-Object { $_ }); Stop = $Stop
        Apply = $Apply; Undo = $Undo; Check = $Check; Skip = $Skip; NoUndo = [bool]$NoUndo
    })
}

$guidRx = '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'

# 전원 설정 (현재 전원 관리 옵션의 AC 값) 읽기/쓰기 - 원래 값을 저장해 정확히 되돌림
function Get-ActiveScheme { return [regex]::Match((powercfg /getactivescheme | Out-String), $guidRx).Value }
function Get-PowerAc([string]$sub, [string]$set, [string]$scheme = 'SCHEME_CURRENT') {
    $txt = powercfg /qh $scheme $sub $set 2>$null | Out-String     # /qh = 숨겨진 설정도 표시
    $m = [regex]::Matches($txt, '0x([0-9a-fA-F]{8})')
    if ($m.Count -lt 2) {
        $txt = powercfg /q $scheme $sub $set 2>$null | Out-String
        $m = [regex]::Matches($txt, '0x([0-9a-fA-F]{8})')
    }
    if ($m.Count -lt 2) { return $null }
    return [Convert]::ToInt64($m[$m.Count - 2].Groups[1].Value, 16)   # 마지막 두 값 = AC, DC
}
function Set-PowerAcList($pairs, [int64]$value) {
    $state = @()
    $scheme = Get-ActiveScheme
    foreach ($pr in $pairs) {
        $old = Get-PowerAc $pr[0] $pr[1]
        if ($null -eq $old) { Log "  원래 값 읽기 실패(그래도 적용): $($pr[1])" 'WARN' }
        $state += [pscustomobject]@{ Scheme = $scheme; Sub = $pr[0]; Set = $pr[1]; Old = $old }
        powercfg /setacvalueindex SCHEME_CURRENT $pr[0] $pr[1] $value | Out-Null
    }
    powercfg /setactive SCHEME_CURRENT | Out-Null
    return , $state
}
function Restore-PowerAcList($state) {
    foreach ($x in @($state)) {
        if ($x -and $null -ne $x.Old) {
            $sc = 'SCHEME_CURRENT'; if ($x.Scheme) { $sc = [string]$x.Scheme }   # 적용했던 그 전원 관리 옵션에 복구
            powercfg /setacvalueindex $sc $x.Sub $x.Set ([int64]$x.Old) | Out-Null
        }
    }
    powercfg /setactive SCHEME_CURRENT | Out-Null
}
function Test-PowerAcList($pairs, [int64]$value) {
    $any = $false
    foreach ($pr in $pairs) {
        $cur = Get-PowerAc $pr[0] $pr[1]
        if ($null -eq $cur) { continue }
        $any = $true
        if ($cur -ne $value) { return $false }
    }
    if (-not $any) { return $null }
    return $true
}
$PwrSleep = @(
    @('7516b95f-f776-4464-8c53-06167f40cc99', '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'),  # 화면 끄기
    @('238c9fa8-0aad-41ed-83f4-97be242c8f20', '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'),  # 절전
    @('238c9fa8-0aad-41ed-83f4-97be242c8f20', '9d7815a6-7ee4-497e-8888-515a05f02364'),  # 최대 절전
    @('0012ee47-9041-4b5d-9b77-535fba8b1442', '6738e2c4-e8a5-4a42-b16a-e040e769756e')   # 디스크 끄기
)
$PwrUsbPcie = @(
    @('2a737441-1930-4402-8d77-b2bebba308a3', '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'),  # USB 선택적 절전
    @('501a4d13-42af-4429-9fd1-a8218c268e20', 'ee12f906-d277-404b-b6da-e5fa1a576df5')   # PCIe 링크 상태 전원 관리
)
$PwrCpu = @(
    @('54533251-82be-4824-96c1-47b60b740d00', '893dee8e-2bef-41e0-89c6-b55d0929964c'),  # 최소 프로세서 상태
    @('54533251-82be-4824-96c1-47b60b740d00', '0cc5b647-c1df-4637-891a-dec35c318583')   # 코어 파킹 최소 코어
)

# ---------------- 전원 / 성능 ----------------
$C = '전원 / 성능'
Add-Tweak -Id 'power_plan' -Cat $C -Level 1 -Name '전원 관리: 최고의 성능' `
    -Desc '최고의 성능(없으면 고성능) 전원 관리 옵션 사용. CPU가 절전 상태로 내려가며 생기는 순간 끊김 감소' `
    -Apply {
        $prev = [regex]::Match((powercfg /getactivescheme | Out-String), $guidRx).Value
        $list = powercfg /list | Out-String
        $g = ''
        foreach ($line in ($list -split "`n")) {
            if ($line -match '최고의 성능|Ultimate Performance') { $g = [regex]::Match($line, $guidRx).Value; break }
        }
        if (-not $g) { $g = [regex]::Match((powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Out-String), $guidRx).Value }
        if (-not $g) { $g = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'; Log '  최고의 성능 없음 -> 고성능 사용' 'WARN' }
        powercfg -setactive $g | Out-Null
        $script:CustomState = [pscustomobject]@{ Prev = $prev }
    } `
    -Undo {
        param($s)
        $g = '381b4222-f694-41f0-9685-ff5bb260df2e'   # 균형 조정
        if ($s -and $s.Prev) { $g = $s.Prev }
        powercfg -setactive $g | Out-Null
    } `
    -Check { (powercfg /getactivescheme | Out-String) -match '최고의 성능|Ultimate Performance|고성능|High performance' }

Add-Tweak -Id 'power_sleep' -Cat $C -Level 1 -Name '절전/화면 끄기/최대 절전/빠른 시작 끄기' `
    -Desc '자리 비움 중 절전으로 빠져 관리 프로그램이 끊기는 문제 방지. 빠른 시작은 복원 프로그램과 충돌하므로 끔' `
    -Reg @(
        RegOp 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0
    ) `
    -Apply {
        $hib = [int](Get-RegVal 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled').Value -eq 1
        $st = Set-PowerAcList $PwrSleep 0
        powercfg /hibernate off | Out-Null
        $script:CustomState = [pscustomobject]@{ Power = $st; Hibernate = $hib }
    } `
    -Undo {
        param($s)
        if ($s) {
            Restore-PowerAcList $s.Power
            if ($s.Hibernate) { powercfg /hibernate on | Out-Null }
        }
    } `
    -Check { Test-PowerAcList $PwrSleep 0 }

Add-Tweak -Id 'power_usb_pcie' -Cat $C -Level 2 -Name 'USB 선택적 절전 / PCIe 링크 절전 끄기' `
    -Desc '마우스/헤드셋이 순간 끊기거나 그래픽카드 응답이 늦어지는 현상 예방 (현재 전원 관리 옵션에 적용)' `
    -Apply { $script:CustomState = Set-PowerAcList $PwrUsbPcie 0 } `
    -Undo { param($s) Restore-PowerAcList $s } `
    -Check { Test-PowerAcList $PwrUsbPcie 0 }

Add-Tweak -Id 'power_cpu' -Cat $C -Level 3 -Name 'CPU 최소 상태 100% / 코어 파킹 끄기' -Risk '중간' `
    -Desc 'CPU 클럭을 항상 최대로 유지. 반응성은 약간 좋아지지만 발열/전기요금 증가. 쿨링이 약하면 비추천' `
    -Apply { $script:CustomState = Set-PowerAcList $PwrCpu 100 } `
    -Undo { param($s) Restore-PowerAcList $s } `
    -Check { Test-PowerAcList $PwrCpu 100 }

Add-Tweak -Id 'game_mode' -Cat $C -Level 1 -Name '게임 모드 켜기' `
    -Desc '게임 실행 중 윈도우 업데이트/백그라운드 작업 우선순위를 낮춤' `
    -Reg @(
        RegOp 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
        RegOp 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
    )

Add-Tweak -Id 'hags' -Cat $C -Level 1 -Name '하드웨어 가속 GPU 스케줄링 켜기' `
    -Desc 'GTX 10 / RX 5000 이상에서 지연 감소, DLSS 프레임 생성에 필요. 재부팅 후 적용' `
    -Reg @( RegOp 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2 )

Add-Tweak -Id 'windowed_opt' -Cat $C -Level 2 -Name '창 모드 게임 최적화 켜기' `
    -Desc '창 모드/전체 창 모드 게임의 지연 감소 (설정 > 디스플레이 > 그래픽의 같은 옵션)' `
    -Apply {
        $p = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'; $n = 'DirectXUserGlobalSettings'
        $cur = Get-RegVal $p $n
        $script:CustomState = [pscustomobject]@{ Exists = $cur.Exists; Value = [string]$cur.Value }
        $v = [string]$cur.Value
        if ($v -match 'SwapEffectUpgradeEnable=\d') { $v = $v -replace 'SwapEffectUpgradeEnable=\d', 'SwapEffectUpgradeEnable=1' }
        else { if ($v -and -not $v.EndsWith(';')) { $v += ';' }; $v += 'SwapEffectUpgradeEnable=1;' }
        Set-RegVal $p $n $v 'String' | Out-Null     # 자동 HDR/VRR 등 다른 설정은 유지
    } `
    -Undo {
        param($s)
        $p = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'; $n = 'DirectXUserGlobalSettings'
        if ($s -and $s.Exists) { Set-RegVal $p $n ([string]$s.Value) 'String' | Out-Null }
        else { Remove-ItemProperty -LiteralPath $p -Name $n -ErrorAction SilentlyContinue }
    } `
    -Check { [string](Get-RegVal 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings').Value -match 'SwapEffectUpgradeEnable=1' }

Add-Tweak -Id 'gamedvr_off' -Cat $C -Level 1 -Name '게임 바 백그라운드 녹화 끄기' `
    -Desc '게임 중 계속 화면을 녹화하는 기능 끄기 (프레임 드랍 원인)' `
    -Reg @(
        RegOp 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0
    )

Add-Tweak -Id 'visual_fx' -Cat $C -Level 2 -Name '투명 효과 / 창 애니메이션 끄기' `
    -Desc '창 열고 닫을 때 애니메이션과 반투명 효과 제거 (글꼴 부드럽게는 유지). 저사양 PC일수록 효과' `
    -Reg @(
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0
        RegOp 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0
        RegOp 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0
    )

Add-Tweak -Id 'maint_off' -Cat $C -Level 2 -Name '자동 유지 관리 끄기' `
    -Desc '손님 이용 중 디스크 최적화/검사 같은 예약 작업이 돌며 끊기는 것 방지 (복원 환경에선 의미 없음)' `
    -Reg @( RegOp 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' 'MaintenanceDisabled' 1 )

Add-Tweak -Id 'search_index_off' -Cat $C -Level 2 -Name '검색 색인(Windows Search) 끄기' `
    -Desc '파일 색인으로 생기는 디스크 사용 제거. 시작 메뉴 앱 검색은 계속 됨(파일 내용 검색만 느려짐)' `
    -Reg @( Svc 'WSearch' ) -Stop @('WSearch')

Add-Tweak -Id 'bg_apps_off' -Cat $C -Level 3 -Name '스토어 앱 백그라운드 실행 막기' -Risk '중간' `
    -Desc '스토어 앱이 몰래 돌지 않게 함. 일반 게임 런처는 영향 없음. Xbox 앱(게임패스) 백그라운드 다운로드/게임 바 위젯도 막히므로 게임패스 매장은 비추천' `
    -Reg @( RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' 2 )

Add-Tweak -Id 'ntfs_lastaccess' -Cat $C -Level 2 -Name 'NTFS 마지막 접근 시간 기록 끄기' `
    -Desc '파일을 읽을 때마다 접근 시간을 쓰는 작업 제거 (게임 로딩 시 디스크 쓰기 감소)' `
    -Reg @( RegOp 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'NtfsDisableLastAccessUpdate' -2147483647 )

Add-Tweak -Id 'vbs_off' -Cat $C -Level 3 -Name '메모리 무결성 / VBS 끄기' -Risk '중간' `
    -Desc '게임 성능 약 3~10% 향상. 대신 커널 보호 기능이 꺼짐. 매장 게임 중 안티치트가 요구하는 게 있으면 쓰지 말 것' `
    -Reg @(
        RegOp 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0
        RegOp 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0
    )

Add-Tweak -Id 'mmcss_games' -Cat $C -Level 3 -Name '멀티미디어 스케줄러 게임 우선순위' `
    -Desc '게임/오디오 스레드 우선순위 상향, 네트워크 제한 해제. 효과는 작지만 부작용도 거의 없음' `
    -Reg @(
        RegOp 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' -1
        RegOp 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 10
        RegOp 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'GPU Priority' 8
        RegOp 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Priority' 6
        RegOp 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'Scheduling Category' 'High' 'String'
        RegOp 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games' 'SFIO Priority' 'High' 'String'
    )

Add-Tweak -Id 'timer_res' -Cat $C -Level 3 -Name '타이머 해상도 전역 요청 허용' `
    -Desc '윈도우11에서 바뀐 타이머 동작을 예전 방식으로. 일부 구형 게임의 프레임 간격(프레임타임) 안정' `
    -Reg @( RegOp 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1 )

Add-Tweak -Id 'memcomp_off' -Cat $C -Level 3 -Name '메모리 압축 끄기 (램 16GB 이상만)' `
    -Desc '램이 충분할 때 압축/해제에 쓰는 CPU 사용 제거. 16GB 미만 PC에서는 자동으로 건너뜀' `
    -Skip {
        $gb = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
        if ($gb -lt 15) { "램 ${gb}GB (16GB 미만)" }
    } `
    -Apply {
        $script:CustomState = [pscustomobject]@{ WasOn = [bool](Get-MMAgent).MemoryCompression }
        Disable-MMAgent -MemoryCompression -ErrorAction Stop
    } `
    -Undo { param($s) if (-not $s -or $s.WasOn) { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue } } `
    -Check { -not (Get-MMAgent).MemoryCompression }

# ---------------- 입력 / 화면 / 소리 ----------------
$C = '입력 / 화면 / 소리'
Add-Tweak -Id 'mouse_accel' -Cat $C -Level 1 -Name '마우스 가속(포인터 정확도 향상) 끄기' `
    -Desc 'FPS 게임 에임 일관성. 게이머 체감 1순위 항목' `
    -Reg @(
        RegOp 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'
        RegOp 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'
        RegOp 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String'
        RegOp 'HKCU:\Control Panel\Mouse' 'MouseSensitivity' '10' 'String'
    )

Add-Tweak -Id 'sticky_keys' -Cat $C -Level 1 -Name '고정 키 / 필터 키 / 토글 키 팝업 끄기' `
    -Desc '게임 중 Shift 5번 눌러서 고정 키 창이 뜨며 게임이 내려가는 문제 방지' `
    -Reg @(
        RegOp 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'
        RegOp 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' 'String'
        RegOp 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' '58' 'String'
    )

Add-Tweak -Id 'lang_hotkey' -Cat $C -Level 2 -Name '입력 언어 전환 단축키(Alt+Shift, Ctrl+Shift) 끄기' `
    -Desc '게임 중 Alt+Shift로 키보드 언어가 바뀌는 문제 방지. 한/영 키는 그대로 동작' `
    -Reg @(
        RegOp 'HKCU:\Keyboard Layout\Toggle' 'Hotkey' '3' 'String'
        RegOp 'HKCU:\Keyboard Layout\Toggle' 'Language Hotkey' '3' 'String'
        RegOp 'HKCU:\Keyboard Layout\Toggle' 'Layout Hotkey' '3' 'String'
    )

Add-Tweak -Id 'kb_repeat' -Cat $C -Level 2 -Name '키보드 반복 지연 최소 / 반복 속도 최대' `
    -Desc '키를 누르고 있을 때 반응을 빠르게' `
    -Reg @(
        RegOp 'HKCU:\Control Panel\Keyboard' 'KeyboardDelay' '0' 'String'
        RegOp 'HKCU:\Control Panel\Keyboard' 'KeyboardSpeed' '31' 'String'
    )

Add-Tweak -Id 'numlock' -Cat $C -Level 1 -Name '부팅 시 Num Lock 켜기' `
    -Desc '로그인/게임 비밀번호 입력 시 숫자패드 바로 사용' `
    -Reg @(
        RegOp 'HKCU:\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' 'String'
        RegOp 'Registry::HKEY_USERS\.DEFAULT\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' 'String'
    )

Add-Tweak -Id 'audio_ducking' -Cat $C -Level 1 -Name '통화 시 다른 소리 줄이기 끄기' `
    -Desc '디스코드 음성채팅 중 게임 소리가 80% 줄어드는 기본 동작 끄기' `
    -Reg @( RegOp 'HKCU:\Software\Microsoft\Multimedia\Audio' 'UserDuckingPreference' 3 )

Add-Tweak -Id 'mpo_off' -Cat $C -Level 0 -Name '[문제 해결용] MPO(멀티플레인 오버레이) 끄기' `
    -Desc '게임/크롬에서 화면 깜빡임, 검은 화면, 멀티모니터 끊김이 있을 때만 사용. 문제 없으면 켜두는 게 좋음' `
    -Reg @( RegOp 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' 5 )

# ---------------- 업데이트 / 네트워크 ----------------
$C = '업데이트 / 네트워크'
Add-Tweak -Id 'driver_update_off' -Cat $C -Level 1 -Name '윈도우 업데이트로 드라이버 자동 설치 막기' `
    -Desc '직접 설치한 그래픽 드라이버를 윈도우가 구버전으로 덮어쓰는 문제 방지' `
    -Reg @(
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1
        RegOp 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' 'SearchOrderConfig' 0
    )

Add-Tweak -Id 'wu_manual' -Cat $C -Level 2 -Name '윈도우 자동 업데이트 끄기 (수동 업데이트)' `
    -Desc '영업 중 업데이트 다운로드/재부팅 방지. 점검일에 설정 > Windows 업데이트에서 직접 업데이트할 것' `
    -Reg @(
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 1
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions' 2
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 1
    )

Add-Tweak -Id 'feature_lock' -Cat $C -Level 2 -Name '현재 윈도우 버전 고정 (큰 업데이트 막기)' `
    -Desc '기능 업데이트(예: 25H2 -> 26H2)가 저절로 설치되지 않게 현재 버전으로 고정. 보안 업데이트는 해당 버전 지원 기간 동안 계속 받음. Home 에디션/지원 끝난 버전은 자동으로 건너뜀' `
    -Skip {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        if ($cv.EditionID -match '^Core') { 'Home 에디션은 이 정책을 지원하지 않음' }
        elseif ([string]$cv.DisplayVersion -lt '25H2') { "현재 $($cv.DisplayVersion) 은 지원이 끝났거나 곧 끝남 -> 먼저 최신 버전으로 업데이트 후 적용" }
    } `
    -Reg @(
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'TargetReleaseVersion' 1
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ProductVersion' 'Windows 11' 'String'
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'TargetReleaseVersionInfo' { [string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion } 'String'
    )

Add-Tweak -Id 'store_autoupdate_off' -Cat $C -Level 3 -Name '스토어 앱 자동 업데이트 끄기' -Risk '중간' `
    -Desc '영업 중 스토어 앱이 대역폭을 쓰지 않게 함. Gaming Services/Xbox 앱 업데이트도 멈춰 게임패스 게임이 안 될 수 있음 -> 게임패스 매장은 점검일에 스토어에서 수동 업데이트' `
    -Reg @( RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload' 2 )

Add-Tweak -Id 'delivery_opt' -Cat $C -Level 1 -Name '업데이트 공유를 매장 내부(LAN)로만 제한' `
    -Desc '인터넷의 다른 PC와 업데이트 파일을 주고받지 않고, 매장 PC끼리만 공유 -> 업데이트 때 외부 회선 사용량 감소' `
    -Reg @( RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 1 )

Add-Tweak -Id 'nic_power' -Cat $C -Level 2 -Name '유선 랜카드 절전 / 그린 이더넷(EEE) 끄기' `
    -Desc '랜카드 절전으로 생기는 핑 튐/순간 끊김 방지. Wake-on-LAN(원격 켜기)은 그대로 유지. 재부팅 후 적용' `
    -Apply {
        $state = @()
        foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.MediaType -eq '802.3' })) {
            $eee = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword '*EEE' -ErrorAction SilentlyContinue
            $pm  = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction SilentlyContinue
            $eeeVal = $null; if ($eee) { $eeeVal = [string](@($eee.RegistryValue)[0]) }
            $pmVal  = $null; if ($pm)  { $pmVal  = [string]$pm.AllowComputerToTurnOffDevice }
            $state += [pscustomobject]@{ Name = $a.Name; EEE = $eeeVal; PM = $pmVal }
            if ($eee) { Set-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword '*EEE' -RegistryValue 0 -NoRestart -ErrorAction SilentlyContinue }
            if ($pm -and $pmVal -eq 'Enabled') {
                # 절전 허용만 끔 (Disable-NetAdapterPowerManagement 는 WoL까지 꺼버려서 사용 안 함)
                $pm.AllowComputerToTurnOffDevice = 'Disabled'
                $pm | Set-NetAdapterPowerManagement -NoRestart -ErrorAction SilentlyContinue
            }
            Log "  랜카드: $($a.InterfaceDescription)"
        }
        $script:CustomState = $state
    } `
    -Undo {
        param($s)
        foreach ($x in @($s)) {
            if (-not $x) { continue }
            if ($x.EEE) { Set-NetAdapterAdvancedProperty -Name $x.Name -RegistryKeyword '*EEE' -RegistryValue $x.EEE -NoRestart -ErrorAction SilentlyContinue }
            if ($x.PM -eq 'Enabled') {
                $pm = Get-NetAdapterPowerManagement -Name $x.Name -ErrorAction SilentlyContinue
                if ($pm) { $pm.AllowComputerToTurnOffDevice = 'Enabled'; $pm | Set-NetAdapterPowerManagement -NoRestart -ErrorAction SilentlyContinue }
            }
        }
    } `
    -Check {
        $nics = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.MediaType -eq '802.3' })
        $known = 0; $bad = 0
        foreach ($a in $nics) {
            $e = Get-NetAdapterAdvancedProperty -Name $a.Name -RegistryKeyword '*EEE' -ErrorAction SilentlyContinue
            if ($e) { $known++; if ([string](@($e.RegistryValue)[0]) -ne '0') { $bad++ } }
            $pm = Get-NetAdapterPowerManagement -Name $a.Name -ErrorAction SilentlyContinue
            if ($pm -and [string]$pm.AllowComputerToTurnOffDevice -ne 'Unsupported') { $known++; if ([string]$pm.AllowComputerToTurnOffDevice -eq 'Enabled') { $bad++ } }
        }
        if ($known -eq 0) { return $null }
        return ($bad -eq 0)
    }

# ---------------- 백그라운드 / 서비스 / 앱 ----------------
$C = '백그라운드 / 서비스 / 앱'
Add-Tweak -Id 'svc_telemetry' -Cat $C -Level 2 -Name '진단 데이터 수집 서비스 끄기' `
    -Desc 'DiagTrack(사용자 경험 및 원격 분석), dmwappushservice 중지' `
    -Reg @( Svc 'DiagTrack'; Svc 'dmwappushservice' ) -Stop @('DiagTrack', 'dmwappushservice')

Add-Tweak -Id 'svc_misc' -Cat $C -Level 2 -Name '불필요 서비스 끄기 (지도/팩스/데모/오류 보고/위치)' `
    -Desc 'MapsBroker, Fax, RetailDemo, WerSvc, lfsvc 중지. Xbox/오디오/네트워크 관련 서비스는 건드리지 않음' `
    -Reg @( Svc 'MapsBroker'; Svc 'Fax'; Svc 'RetailDemo'; Svc 'WerSvc'; Svc 'lfsvc' ) `
    -Stop @('MapsBroker', 'Fax', 'RetailDemo', 'WerSvc', 'lfsvc')

Add-Tweak -Id 'svc_print' -Cat $C -Level 0 -Name '[선택] 프린터 서비스 끄기 (프린터 안 쓸 때만)' `
    -Desc '출력 서비스를 하지 않는 매장만. 끄면 인쇄 불가' `
    -Reg @( Svc 'Spooler' ) -Stop @('Spooler')

Add-Tweak -Id 'wer_off' -Cat $C -Level 1 -Name '오류 보고 창 끄기' `
    -Desc '게임이 튕겼을 때 뜨는 "문제 보고" 창과 덤프 업로드 끄기' `
    -Reg @(
        RegOp 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' 'DontShowUI' 1
    )

Add-Tweak -Id 'browser_bg' -Cat $C -Level 1 -Name 'Edge/크롬 백그라운드 실행 & 시작 부스트 끄기' `
    -Desc '브라우저를 닫아도 백그라운드에 남아 램을 쓰는 동작 끄기. Edge 첫 실행 안내 화면 생략' `
    -Reg @(
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 0
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 0
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'HideFirstRunExperience' 1
        RegOp 'HKLM:\SOFTWARE\Policies\Google\Chrome' 'BackgroundModeEnabled' 0
    )

Add-Tweak -Id 'ai_off' -Cat $C -Level 1 -Name 'Copilot / Recall / Click to Do 끄기' `
    -Desc 'AI 기능의 백그라운드 동작과 화면 스냅샷 저장 끄기 (공용 PC 개인정보 보호)' `
    -Reg @(
        RegOp 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
        RegOp 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableClickToDo' 1
        RegOp 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableClickToDo' 1
    )

Add-Tweak -Id 'onedrive_remove' -Cat $C -Level 2 -Name 'OneDrive 제거 및 재설치 차단' -NoUndo `
    -Desc '시작 시 자동 실행/동기화 제거. 되돌리기는 차단 정책만 해제(재설치는 직접)' `
    -Reg @( RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1 ) `
    -Apply {
        Stop-Process -Name OneDrive -Force -ErrorAction SilentlyContinue
        $done = $false
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            winget uninstall --id Microsoft.OneDrive -e --silent --accept-source-agreements --disable-interactivity | Out-Null
            if ($LASTEXITCODE -eq 0) { $done = $true }
        }
        if (-not $done) {
            foreach ($p in "$env:SystemRoot\System32\OneDriveSetup.exe", "$env:SystemRoot\SysWOW64\OneDriveSetup.exe") {
                if (Test-Path $p) { Start-Process $p '/uninstall' -Wait; break }
            }
        }
        Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'OneDrive' -ErrorAction SilentlyContinue
    } `
    -Check { -not (Get-Process OneDrive -ErrorAction SilentlyContinue) -and -not (Test-Path "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe") }

Add-Tweak -Id 'bloat_remove' -Cat $C -Level 2 -Name '불필요 기본 앱 삭제 (뉴스/날씨/팀즈/클립챔프 등)' -NoUndo `
    -Desc '모든 사용자에서 삭제 + 새 계정에도 설치 안 되게 함. Xbox/스토어/계산기/사진/빠른 지원은 유지. 되돌리기 불가(스토어에서 재설치)' `
    -Apply {
        $prov = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
        foreach ($n in $BloatApps) {
            $pk = @(Get-AppxPackage -AllUsers -Name $n -ErrorAction SilentlyContinue)
            foreach ($x in $pk) {
                try { Remove-AppxPackage -Package $x.PackageFullName -AllUsers -ErrorAction Stop; Log "  삭제: $n" }
                catch { try { Remove-AppxPackage -Package $x.PackageFullName -ErrorAction Stop; Log "  삭제(현재 사용자): $n" } catch { Log "  삭제 실패: $n" 'WARN' } }
            }
            foreach ($pp in @($prov | Where-Object { $_.DisplayName -eq $n })) {
                Remove-AppxProvisionedPackage -Online -PackageName $pp.PackageName -ErrorAction SilentlyContinue | Out-Null
            }
        }
    } `
    -Check {
        foreach ($n in $BloatApps) { if (Get-AppxPackage -Name $n -ErrorAction SilentlyContinue) { return $false } }
        return $true
    }

Add-Tweak -Id 'defender_excl' -Cat $C -Level 1 -Name 'Defender 게임 폴더 검사 예외' `
    -Desc '게임 패치/로딩 중 실시간 검사로 느려지는 것 방지 (설정 구역의 게임 폴더 중 있는 것만)' `
    -Apply {
        $added = @()
        $before = @((Get-MpPreference -ErrorAction SilentlyContinue).ExclusionPath)
        foreach ($p in $GamePaths) {
            if ((Test-Path $p) -and ($before -notcontains $p)) {
                try { Add-MpPreference -ExclusionPath $p -ErrorAction Stop; $added += $p; Log "  예외 추가: $p" }
                catch { Log "  예외 추가 실패(타사 백신이면 그 백신에서 설정): $p" 'WARN' }
            }
        }
        if ($added.Count -eq 0) { Log '  게임 폴더를 찾지 못함 -> 스크립트 위쪽 $GamePaths 수정' 'WARN' }
        $script:CustomState = $added
    } `
    -Undo { param($s) foreach ($p in @($s)) { if ($p) { Remove-MpPreference -ExclusionPath $p -ErrorAction SilentlyContinue } } } `
    -Check {
        $ex = @((Get-MpPreference -ErrorAction SilentlyContinue).ExclusionPath)
        $need = @($GamePaths | Where-Object { Test-Path $_ })
        if ($need.Count -eq 0) { return $null }
        return (@($need | Where-Object { $ex -notcontains $_ }).Count -eq 0)
    }

# ---------------- 화면 정리 / 개인정보 / 보안 ----------------
$C = '화면 정리 / 개인정보 / 보안'
Add-Tweak -Id 'notify_off' -Cat $C -Level 1 -Name '알림 / 팁 / 광고 / 추천 앱 자동 설치 끄기' `
    -Desc '게임 중 뜨는 알림 토스트, "윈도우 설정 마무리" 화면, 시작 메뉴 광고, 앱 자동 설치 끄기' `
    -Reg @(
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 0
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 0
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 0
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 0
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 0
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 0
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 0
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'RotatingLockScreenOverlayEnabled' 0
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
    )

Add-Tweak -Id 'start_clean' -Cat $C -Level 1 -Name '시작 메뉴 / 작업 표시줄 / 검색 정리' `
    -Desc '추천 항목, 최근 파일, 작업 보기 버튼, 위젯, 검색창의 웹(Bing) 결과와 하이라이트 끄기' `
    -Reg @(
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_TrackDocs' 0
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_AccountNotifications' 0
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowTaskViewButton' 0
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 1
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDynamicSearchBoxEnabled' 0
        RegOp 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'DisableWebSearch' 1
    )

Add-Tweak -Id 'end_task' -Cat $C -Level 1 -Name '작업 표시줄 우클릭 "작업 끝내기" 켜기' `
    -Desc '멈춘 게임을 손님이 작업 관리자 없이 작업 표시줄에서 바로 종료 가능' `
    -Reg @( RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings' 'TaskbarEndTask' 1 )

Add-Tweak -Id 'lockscreen_off' -Cat $C -Level 1 -Name '잠금 화면 끄기' `
    -Desc '부팅/절전 해제 시 잠금 화면 그림 없이 바로 로그인 (Pro 이상)' `
    -Reg @( RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' 'NoLockScreen' 1 )

Add-Tweak -Id 'privacy_basic' -Cat $C -Level 1 -Name '광고 ID / 맞춤 환경 / 진단 데이터 최소 / 입력 정보 수집 끄기' `
    -Desc '설치 화면의 개인정보 옵션을 모두 끈 것과 동일' `
    -Reg @(
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 1
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
        RegOp 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
        RegOp 'HKCU:\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
    )

Add-Tweak -Id 'clipboard_hist_off' -Cat $C -Level 1 -Name '클립보드 기록 끄기' `
    -Desc '이전 손님이 복사한 비밀번호/계정이 Win+V 기록에 남는 것 방지' `
    -Reg @(
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'AllowClipboardHistory' 0
        RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'AllowCrossDeviceClipboard' 0
    )

Add-Tweak -Id 'explorer_privacy' -Cat $C -Level 1 -Name '탐색기 최근 파일/자주 쓰는 폴더 숨기기' `
    -Desc '이전 손님이 연 파일 목록이 보이지 않게 하고, 탐색기를 "내 PC"로 열기' `
    -Reg @(
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer' 'ShowRecent' 0
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer' 'ShowFrequent' 0
        RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 1
    )

Add-Tweak -Id 'autorun_off' -Cat $C -Level 1 -Name 'USB 자동 실행 끄기' `
    -Desc '손님 USB의 자동 실행(악성코드 전파 경로) 차단' `
    -Reg @(
        RegOp 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun' 255
        RegOp 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoAutorun' 1
    )

$script:TweakMap = @{}
foreach ($t in $script:Tweaks) { $script:TweakMap[$t.Id] = $t }
$LevelName = @{ 0 = '선택'; 1 = '안전'; 2 = '권장'; 3 = '최대' }

# ============================== 적용 / 되돌리기 / 상태 ==============================
function Get-SkipReason($t) {
    if (-not $t.Skip) { return $null }
    try { $r = @(& $t.Skip) | Where-Object { $_ } | Select-Object -Last 1; if ($r) { return [string]$r } } catch {}
    return $null
}

function Invoke-Tweak($t) {
    Log "적용: $($t.Name)"
    $why = Get-SkipReason $t
    if ($why) { Log "  건너뜀: $why" 'WARN'; return }
    $entry = $null
    if ($script:Backup.ContainsKey($t.Id)) { $entry = $script:Backup[$t.Id] }
    $regBk = @(); $taskBk = @()
    if ($entry) {
        $regBk = @(@($entry.Reg) | Where-Object { $_ }); $taskBk = @(@($entry.Tasks) | Where-Object { $_ })
        if ($entry.MachineDone) {
            $regBk = @($regBk | Where-Object { $_.U }); $taskBk = @()
            $entry = [pscustomobject]@{ Time = $entry.Time; Reg = $regBk; Tasks = @(); Custom = $null; MachineDone = $false }
        }
    }
    foreach ($r in $t.Reg) {
        if ($r.IfExists -and -not (Test-Path -LiteralPath $r.P)) { continue }
        $u = ''; if ($r.P -like 'HKCU:*') { $u = $MySid }     # 사용자별 설정은 계정(SID)별로 따로 백업
        $known = @($regBk | Where-Object { $_.P -eq $r.P -and $_.N -eq $r.N -and [string]$_.U -eq $u }).Count -gt 0
        if (-not $known) {
            $cur = Get-RegVal $r.P $r.N
            $regBk += [pscustomobject]@{ P = $r.P; N = $r.N; U = $u; Exists = $cur.Exists; Value = $cur.Value; Kind = $cur.Kind }
        }
        Set-RegVal $r.P $r.N (Resolve-V $r.V) $r.T | Out-Null
    }
    foreach ($k in $t.Tasks) {
        $st = Get-ScheduledTask -TaskPath $k.P -TaskName $k.N -ErrorAction SilentlyContinue
        if ($st) {
            $known = @($taskBk | Where-Object { $_.P -eq $k.P -and $_.N -eq $k.N }).Count -gt 0
            if (-not $known) { $taskBk += [pscustomobject]@{ P = $k.P; N = $k.N; Enabled = ($st.State -ne 'Disabled') } }
            Disable-ScheduledTask -TaskPath $k.P -TaskName $k.N -ErrorAction SilentlyContinue | Out-Null
        }
    }
    foreach ($s in $t.Stop) { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue }
    $script:CustomState = $null
    if ($t.Apply) {
        try { & $t.Apply | Out-Null } catch { Log "  오류: $($_.Exception.Message)" 'ERR' }
    }
    # 사용자 지정 상태: 처음 적용할 때의 원래 값을 유지. 문자열 목록(예: 예외 폴더)은 합침
    $custom = $script:CustomState
    if ($entry -and $null -ne $entry.Custom) {
        $old = $entry.Custom
        $oldArr = @($old); $newArr = @($custom | Where-Object { $_ })
        if ($newArr.Count -gt 0 -and @($oldArr + $newArr | Where-Object { $_ -isnot [string] }).Count -eq 0) {
            $custom = @($oldArr + $newArr | Select-Object -Unique)
        } else { $custom = $old }
    }
    $time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    if ($entry -and $entry.Time) { $time = $entry.Time }
    $script:Backup[$t.Id] = [pscustomobject]@{ Time = $time; Reg = $regBk; Tasks = $taskBk; Custom = $custom; MachineDone = $false }
    Save-Backup
}

function Undo-Tweak($t) {
    if (-not $script:Backup.ContainsKey($t.Id)) { Log "되돌릴 기록 없음: $($t.Name)" 'WARN'; return }
    Log "되돌리기: $($t.Name)"
    $b = $script:Backup[$t.Id]
    $ok = $true
    $doMachine = -not $b.MachineDone
    $left = @()
    foreach ($r in @($b.Reg)) {
        if (-not $r) { continue }
        $u = [string]$r.U
        if ($u -and $u -ne $MySid) { $left += $r; continue }          # 다른 계정의 사용자 설정은 그 계정에서 되돌림
        if (-not $u -and -not $doMachine) { continue }
        if ($r.Exists) {
            $val = Convert-BkVal $r.Value $r.Kind
            if ($null -eq $val) { Log "  복구 불가 형식 건너뜀: $($r.P)\$($r.N)" 'WARN'; continue }
            if (-not (Set-RegVal $r.P $r.N $val $r.Kind)) { $ok = $false; $left += $r }
        }
        else { Remove-ItemProperty -LiteralPath $r.P -Name $r.N -ErrorAction SilentlyContinue }
    }
    if ($doMachine) {
        foreach ($k in @($b.Tasks)) {
            if ($k -and $k.Enabled) { Enable-ScheduledTask -TaskPath $k.P -TaskName $k.N -ErrorAction SilentlyContinue | Out-Null }
        }
        if ($t.Undo) {
            try { & $t.Undo $b.Custom | Out-Null } catch { $ok = $false; Log "  오류: $($_.Exception.Message)" 'ERR' }
        }
        if ($t.NoUndo) { Log '  (삭제된 앱/프로그램은 다시 설치해야 합니다)' 'WARN' }
    }
    if (-not $ok) {
        Log '  일부 실패 -> 백업 기록을 남겨둠 (다시 되돌리기 가능)' 'WARN'
    } elseif ($left.Count -gt 0) {
        $script:Backup[$t.Id] = [pscustomobject]@{ Time = $b.Time; Reg = $left; Tasks = @(); Custom = $null; MachineDone = $true }
        Log '  다른 계정의 사용자 설정 백업은 남겨둠 (그 계정으로 로그인해서 되돌리면 복구)' 'WARN'
    } else {
        $script:Backup.Remove($t.Id)
    }
    Save-Backup
}

function Get-TweakStatus($t) {
    if (Get-SkipReason $t) { return '해당없음' }
    $res = New-Object System.Collections.Generic.List[bool]
    foreach ($r in $t.Reg) {
        if ($r.IfExists -and -not (Test-Path -LiteralPath $r.P)) { continue }
        $res.Add([bool](Test-RegEq (Get-RegVal $r.P $r.N) (Resolve-V $r.V)))
    }
    foreach ($k in $t.Tasks) {
        $st = Get-ScheduledTask -TaskPath $k.P -TaskName $k.N -ErrorAction SilentlyContinue
        if ($st) { $res.Add([bool]($st.State -eq 'Disabled')) }
    }
    if ($t.Check) {
        try {
            $c = @(& $t.Check)
            if ($c.Count -gt 0 -and $null -ne $c[-1]) { $res.Add([bool]$c[-1]) }
        } catch {}
    }
    if ($res.Count -eq 0) {
        if ($script:Backup.ContainsKey($t.Id) -and -not $script:Backup[$t.Id].MachineDone) { return '적용됨' }
        return '-'
    }
    $n = @($res | Where-Object { $_ }).Count
    if ($n -eq $res.Count) { return '적용됨' }
    if ($n -eq 0) { return '미적용' }
    return '일부'
}

function New-RestorePoint {
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        Set-RegVal 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0 'DWord' | Out-Null
        Checkpoint-Computer -Description "PCBang-Optimizer $(Get-Date -Format 'yyyyMMdd HHmm')" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Log '시스템 복원 지점 생성 완료' 'OK'
    } catch { Log "복원 지점 생성 실패(계속 진행): $($_.Exception.Message)" 'WARN' }
}

function Restart-Explorer {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        if ($script:LogBoxes) { [System.Windows.Forms.Application]::DoEvents() }
        if (Get-Process explorer -ErrorAction SilentlyContinue) { return }   # 윈도우가 자동으로 다시 띄움
    }
    if ($script:UserWarning) { Log '작업 표시줄이 안 보이면 로그아웃 후 다시 로그인하세요.' 'WARN'; return }
    # 자동으로 안 뜨면 관리자 권한이 아닌 일반 권한으로 실행
    Start-Process -FilePath "$env:SystemRoot\System32\runas.exe" -ArgumentList '/trustlevel:0x20000', "$env:SystemRoot\explorer.exe" -WindowStyle Hidden
}

function Invoke-Many($list, [switch]$UndoMode, [switch]$NoRestorePoint) {
    $list = @($list)
    if ($list.Count -eq 0) { Log '선택된 항목이 없습니다.' 'WARN'; return }
    if (-not $UndoMode -and -not $NoRestorePoint) { New-RestorePoint }
    $i = 0
    foreach ($t in $list) {
        $i++
        Log ("({0}/{1})" -f $i, $list.Count)
        if ($UndoMode) { Undo-Tweak $t } else { Invoke-Tweak $t }
    }
    Restart-Explorer
    Log "완료: $($list.Count)개 항목. 재부팅해야 모두 적용됩니다." 'OK'
}

# ============================== PC 진단 ==============================
function Get-PcReport {
    $out = New-Object System.Collections.Generic.List[string]
    function Add-Line([string]$tag, [string]$msg) { $out.Add(('[{0}] {1}' -f $tag, $msg)) }

    $os = Get-CimInstance Win32_OperatingSystem
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    Add-Line '정보' ("{0} {1} (빌드 {2}.{3}) / PC 이름 {4} / 사용자 {5}" -f $os.Caption, $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR, $env:COMPUTERNAME, $env:USERNAME)

    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    Add-Line '정보' ("CPU: {0} ({1}코어/{2}스레드)" -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors)

    $mem = @(Get-CimInstance Win32_PhysicalMemory)
    $totalGb = [math]::Round(($mem | Measure-Object Capacity -Sum).Sum / 1GB)
    $speed = ($mem | Select-Object -First 1).ConfiguredClockSpeed
    $type = ($mem | Select-Object -First 1).SMBIOSMemoryType
    $typeName = '알수없음'; if ($type -eq 26) { $typeName = 'DDR4' } elseif ($type -eq 34) { $typeName = 'DDR5' }
    $tag = '정상'
    if (($type -eq 26 -and $speed -lt 3000) -or ($type -eq 34 -and $speed -le 4800)) { $tag = '주의' }
    Add-Line $tag ("램: {0}GB {1} {2}MT/s, {3}개 장착" -f $totalGb, $typeName, $speed, $mem.Count)
    if ($tag -eq '주의') { Add-Line '주의' '  -> 램 속도가 기본값(JEDEC)으로 보임. 바이오스에서 XMP/EXPO 켜기' }
    if ($mem.Count -eq 1) { Add-Line '주의' '  -> 램 1개(싱글 채널). 2개(듀얼 채널)면 게임 프레임이 크게 오름' }

    foreach ($g in @(Get-CimInstance Win32_VideoController)) {
        $age = $null
        if ($g.DriverDate) { $age = [int]((Get-Date) - $g.DriverDate).TotalDays }
        $tag = '정상'; if ($age -gt 180) { $tag = '주의' }
        Add-Line $tag ("GPU: {0} / 드라이버 {1} ({2}일 전)" -f $g.Name, $g.DriverVersion, $age)
        if ($tag -eq '주의') { Add-Line '주의' '  -> 그래픽 드라이버가 6개월 이상 됨. 최신 드라이버 설치 권장' }
        if ($g.CurrentRefreshRate) {
            $tag = '정상'
            if ($g.MaxRefreshRate -and $g.CurrentRefreshRate -lt ($g.MaxRefreshRate - 1) -and $g.MaxRefreshRate -gt 60) { $tag = '주의' }
            elseif ($g.CurrentRefreshRate -le 60) { $tag = '확인' }
            Add-Line $tag ("  화면: {0}x{1} {2}Hz (최대 {3}Hz)" -f $g.CurrentHorizontalResolution, $g.CurrentVerticalResolution, $g.CurrentRefreshRate, $g.MaxRefreshRate)
            if ($tag -ne '정상') { Add-Line $tag '  -> 설정 > 디스플레이 > 고급 디스플레이에서 최대 주사율 선택 (DP/HDMI 2.0 이상 케이블 확인)' }
        }
    }

    try {
        $tpm = Get-Tpm -ErrorAction Stop
        if ($tpm.TpmPresent -and $tpm.TpmReady) { Add-Line '정상' 'TPM 켜짐' } else { Add-Line '주의' 'TPM 꺼짐 -> 바이오스에서 fTPM/PTT 켜기 (발로란트 등 필수)' }
    } catch { Add-Line '확인' 'TPM 상태 확인 불가' }
    try {
        if (Confirm-SecureBootUEFI -ErrorAction Stop) { Add-Line '정상' '보안 부팅 켜짐' } else { Add-Line '주의' '보안 부팅 꺼짐 -> 바이오스에서 Secure Boot 켜기' }
    } catch { Add-Line '주의' '보안 부팅 미지원(레거시/CSM 모드) -> 바이오스에서 UEFI + Secure Boot' }

    try {
        $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
        $hvci = @($dg.SecurityServicesRunning) -contains 2
        $state = '꺼짐'; if ($hvci) { $state = '켜짐' }
        Add-Line '정보' "메모리 무결성(HVCI): $state"
    } catch {}

    $hags = (Get-RegVal 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode').Value
    if ($hags -eq 2) { Add-Line '정상' 'GPU 스케줄링 켜짐' } else { Add-Line '확인' 'GPU 스케줄링 꺼짐' }

    $plan = (powercfg /getactivescheme | Out-String).Trim()
    Add-Line '정보' "전원: $plan"

    foreach ($d in @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')) {
        $free = [math]::Round($d.FreeSpace / 1GB); $size = [math]::Round($d.Size / 1GB)
        $tag = '정상'; if ($size -gt 0 -and ($free / $size) -lt 0.1) { $tag = '주의' }
        Add-Line $tag ("디스크 {0} 남은 공간 {1}GB / {2}GB" -f $d.DeviceID, $free, $size)
    }
    try {
        foreach ($pd in @(Get-PhysicalDisk -ErrorAction Stop)) {
            $tag = '정상'; if ($pd.MediaType -eq 'HDD') { $tag = '주의' }
            Add-Line $tag ("저장장치: {0} ({1}, {2})" -f $pd.FriendlyName, $pd.MediaType, $pd.BusType)
        }
    } catch {}
    $trim = (fsutil behavior query DisableDeleteNotify | Out-String)
    if ($trim -match 'NTFS DisableDeleteNotify = 1') { Add-Line '주의' 'SSD TRIM 꺼짐 -> fsutil behavior set DisableDeleteNotify 0' }

    foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up')) {
        $tag = '정상'; if ($a.MediaType -eq '802.3' -and $a.LinkSpeed -match 'Mbps') { $tag = '주의' }
        Add-Line $tag ("랜: {0} / {1}" -f $a.InterfaceDescription, $a.LinkSpeed)
        if ($tag -eq '주의') { Add-Line '주의' '  -> 1Gbps 미만으로 연결됨. 랜선(CAT5e 이상)/허브 포트 확인' }
    }

    $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
               (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    if ($pending) { Add-Line '주의' '재부팅 대기 중인 업데이트가 있음' }

    $startup = @(Get-CimInstance Win32_StartupCommand -ErrorAction SilentlyContinue)
    Add-Line '정보' ("시작 프로그램 {0}개: {1}" -f $startup.Count, (($startup | Select-Object -ExpandProperty Name) -join ', '))
    return $out
}

function Write-ReportFile($lines) {
    $f = Join-Path $LogDir ("진단_{0}_{1}.txt" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmm'))
    $all = @($lines) + '' + '--- 최적화 항목 상태 ---'
    foreach ($t in $script:Tweaks) { $all += ('{0,-6} [{1}] {2}' -f (Get-TweakStatus $t), $LevelName[$t.Level], $t.Name) }
    $all | Set-Content -Path $f -Encoding UTF8
    return $f
}

function Get-PresetList([string]$p) {
    $max = @{ 'Safe' = 1; 'Recommended' = 2; 'Max' = 3 }[$p]
    $ex = @($Exclude | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return @($script:Tweaks | Where-Object { $_.Level -ge 1 -and $_.Level -le $max -and $ex -notcontains $_.Id })
}

# ============================== 작업 스케줄러 정리 ==============================
# Level: 1=안전  2=권장  3=최대(트레이드오프 있음).  Name 에 * 사용 가능 (예: 업데이트 작업 이름 뒤 GUID)
$script:TaskCatalog = New-Object System.Collections.Generic.List[object]
function Add-TaskDef([string]$Cat, [int]$Level, [string]$Path, [string]$Name, [string]$Desc) {
    $script:TaskCatalog.Add([pscustomobject]@{ Cat = $Cat; Level = $Level; P = $Path; N = $Name; Desc = $Desc })
}
$W = '\Microsoft\Windows\'

$C = '디스크 / 유지 관리'
Add-TaskDef $C 2 "${W}Defrag\" 'ScheduledDefrag' '드라이브 최적화(조각 모음/TRIM). 노하드·복원 환경은 재부팅마다 초기화돼 의미 없고 영업 중 디스크를 씀. 로컬 SSD는 점검일에 수동 최적화'
Add-TaskDef $C 1 "${W}Maintenance\" 'WinSAT' '윈도우 성능 평가(WinSAT). 유휴 시 CPU/디스크/GPU 벤치마크를 돌림'
Add-TaskDef $C 1 "${W}DiskDiagnostic\" 'Microsoft-Windows-DiskDiagnosticDataCollector' '디스크 진단 데이터 수집/전송'
Add-TaskDef $C 1 "${W}DiskDiagnostic\" 'Microsoft-Windows-DiskDiagnosticResolver' '디스크 문제 감지 알림'
Add-TaskDef $C 2 "${W}DiskCleanup\" 'SilentCleanup' '디스크 정리 자동 실행 (복원 환경에선 불필요, 실행 중 디스크 사용)'
Add-TaskDef $C 1 "${W}DiskFootprint\" 'Diagnostics' '디스크 사용량 진단 수집'
Add-TaskDef $C 1 "${W}DiskFootprint\" 'StorageSense' '저장소 센스 자동 정리 (게임 임시 파일 삭제 가능성)'
Add-TaskDef $C 2 "${W}Chkdsk\" 'ProactiveScan' '디스크 오류 사전 검사. 노하드/복원 환경에서는 의미 없음'
Add-TaskDef $C 3 "${W}Chkdsk\" 'SyspartRepair' '시스템 파티션 복구 검사 (로컬 디스크 PC는 켜두는 걸 권장)'
Add-TaskDef $C 2 "${W}Data Integrity Scan\" 'Data Integrity Scan' 'ReFS/저장소 공간 무결성 검사 (일반 NTFS PC는 불필요)'
Add-TaskDef $C 2 "${W}Data Integrity Scan\" 'Data Integrity Scan for Crash Recovery' '비정상 종료 후 무결성 검사 (일반 NTFS PC는 불필요)'
Add-TaskDef $C 1 "${W}MemoryDiagnostic\" 'ProcessMemoryDiagnosticEvents' '메모리 진단 결과 처리'
Add-TaskDef $C 1 "${W}MemoryDiagnostic\" 'RunFullMemoryDiagnostic' '메모리 진단 예약 실행'
Add-TaskDef $C 1 "${W}Power Efficiency Diagnostics\" 'AnalyzeSystem' '전원 효율 분석 (유휴 시 실행)'
Add-TaskDef $C 1 "${W}Autochk\" 'Proxy' '자동 검사 데이터 수집 (원격 분석)'
Add-TaskDef $C 2 "${W}Registry\" 'RegIdleBackup' '레지스트리 자동 백업 (복원/노하드 환경에선 불필요)'
Add-TaskDef $C 2 "${W}Servicing\" 'StartComponentCleanup' '업데이트 구성 요소 정리. 수십 분 동안 디스크/CPU 사용 -> 점검일에 수동'
Add-TaskDef $C 3 "${W}SystemRestore\" 'SR' '시스템 복원 지점 자동 생성. 노하드는 불필요, 로컬 디스크 PC는 유지 권장'

$C = '진단 / 원격 분석'
Add-TaskDef $C 1 "${W}Application Experience\" 'Microsoft Compatibility Appraiser' '호환성 검사(CompatTelRunner) - 게임 중 갑자기 CPU/디스크를 크게 씀'
Add-TaskDef $C 1 "${W}Application Experience\" 'Microsoft Compatibility Appraiser Exp' '호환성 검사 (확장)'
Add-TaskDef $C 1 "${W}Application Experience\" 'ProgramDataUpdater' '프로그램 사용 데이터 수집'
Add-TaskDef $C 1 "${W}Application Experience\" 'StartupAppTask' '시작 프로그램 영향 분석'
Add-TaskDef $C 1 "${W}Application Experience\" 'MareBackup' '호환성 데이터 백업'
Add-TaskDef $C 2 "${W}Application Experience\" 'PcaPatchDbTask' '프로그램 호환성 관리자 DB 갱신'
Add-TaskDef $C 2 "${W}Application Experience\" 'SdbinstMergeDbTask' '호환성 DB 병합'
Add-TaskDef $C 1 "${W}Customer Experience Improvement Program\" 'Consolidator' '사용자 경험 개선 프로그램 데이터 전송'
Add-TaskDef $C 1 "${W}Customer Experience Improvement Program\" 'UsbCeip' 'USB 사용 데이터 수집'
Add-TaskDef $C 1 "${W}Customer Experience Improvement Program\" 'KernelCeipTask' '커널 사용 데이터 수집'
Add-TaskDef $C 1 "${W}Feedback\Siuf\" 'DmClient' '피드백 허브 데이터 전송'
Add-TaskDef $C 1 "${W}Feedback\Siuf\" 'DmClientOnScenarioDownload' '피드백 시나리오 다운로드'
Add-TaskDef $C 1 "${W}Windows Error Reporting\" 'QueueReporting' '오류 보고서 전송'
Add-TaskDef $C 1 "${W}Diagnosis\" 'RecommendedTroubleshootingScanner' '권장 문제 해결 검사'
Add-TaskDef $C 2 "${W}Diagnosis\" 'Scheduled' '예약 진단 (유지 관리 중 실행)'
Add-TaskDef $C 2 "${W}WDI\" 'ResolutionHost' '진단 결과 처리'
Add-TaskDef $C 1 "${W}Flighting\FeatureConfig\" 'UsageDataReporting' '기능 사용 데이터 전송'
Add-TaskDef $C 1 "${W}Flighting\FeatureConfig\" 'UsageDataFlushing' '기능 사용 데이터 정리/전송'
Add-TaskDef $C 2 "${W}Flighting\OneSettings\" 'RefreshCache' '원격 설정 캐시 갱신'
Add-TaskDef $C 1 "${W}Device Information\" 'Device' '장치 정보 수집/전송'
Add-TaskDef $C 1 "${W}Device Information\" 'Device User' '장치 사용자 정보 수집'
Add-TaskDef $C 1 "${W}NetTrace\" 'GatherNetworkInfo' '네트워크 정보 수집'
Add-TaskDef $C 1 "${W}PI\" 'Sqm-Tasks' '사용 데이터 수집'
Add-TaskDef $C 1 "${W}Maps\" 'MapsToastTask' '지도 알림'
Add-TaskDef $C 1 "${W}Maps\" 'MapsUpdateTask' '오프라인 지도 업데이트'
Add-TaskDef $C 1 "${W}Location\" 'Notifications' '위치 알림'
Add-TaskDef $C 1 "${W}Location\" 'WindowsActionDialog' '위치 알림 창'
Add-TaskDef $C 1 "${W}Shell\" 'FamilySafetyMonitor' '자녀 보호 모니터'
Add-TaskDef $C 1 "${W}Shell\" 'FamilySafetyRefreshTask' '자녀 보호 설정 갱신'
Add-TaskDef $C 1 "${W}RetailDemo\" 'CleanupOfflineContent' '매장 데모 콘텐츠 정리'
Add-TaskDef $C 2 "${W}CloudExperienceHost\" 'CreateObjectTask' '클라우드 계정 환경 작업'
Add-TaskDef $C 1 "${W}Speech\" 'SpeechModelDownloadTask' '음성 인식 모델 다운로드'
Add-TaskDef $C 1 "${W}Offline Files\" 'Background Synchronization' '오프라인 파일 동기화 (사용 안 함)'
Add-TaskDef $C 1 "${W}Offline Files\" 'Logon Synchronization' '오프라인 파일 로그온 동기화'
Add-TaskDef $C 1 "${W}Work Folders\" 'Work Folders Logon Synchronization' '회사 폴더 동기화'
Add-TaskDef $C 1 "${W}Work Folders\" 'Work Folders Maintenance Work' '회사 폴더 유지 관리'
Add-TaskDef $C 1 "${W}Mobile Broadband Accounts\" 'MNO Metadata Parser' '모바일 통신사 정보 처리'
Add-TaskDef $C 1 "${W}Printing\" 'EduPrintProv' '교육용 프린터 설정'

$C = '윈도우 업데이트 / 백신 예약 작업'
Add-TaskDef $C 2 "${W}WindowsUpdate\" 'Scheduled Start' '윈도우 업데이트 예약 시작 (자동 업데이트 끄기와 함께 사용)'
Add-TaskDef $C 3 "${W}InstallService\" 'ScanForUpdates' '스토어 앱 업데이트 검사 - Gaming Services/Xbox 앱 업데이트도 멈춤(게임패스 매장 비추천)'
Add-TaskDef $C 3 "${W}InstallService\" 'ScanForUpdatesAsUser' '스토어 앱 업데이트 검사 (사용자) - Gaming Services/Xbox 앱 업데이트도 멈춤(게임패스 매장 비추천)'
Add-TaskDef $C 3 "${W}InstallService\" 'SmartRetry' '스토어 앱 설치 재시도 - Gaming Services/Xbox 앱 업데이트도 멈춤(게임패스 매장 비추천)'
Add-TaskDef $C 2 "${W}Windows Defender\" 'Windows Defender Scheduled Scan' 'Defender 예약 전체 검사 - 영업 중 검사로 끊김. 실시간 보호는 그대로 유지'
Add-TaskDef $C 3 "${W}Windows Defender\" 'Windows Defender Cache Maintenance' 'Defender 캐시 정리'
Add-TaskDef $C 3 "${W}Windows Defender\" 'Windows Defender Cleanup' 'Defender 정리'
Add-TaskDef $C 3 "${W}Windows Defender\" 'Windows Defender Verification' 'Defender 정의 파일 검증'

$C = '프로그램 자동 업데이트 / 원격 분석'
Add-TaskDef $C 2 '\' 'MicrosoftEdgeUpdateTaskMachine*' 'Edge 자동 업데이트 (WebView2 런타임 포함). 노하드/복원 PC는 재부팅마다 다시 받아 회선만 씀 -> 이미지 작업 때 수동 업데이트'
Add-TaskDef $C 2 '\' 'GoogleUpdateTaskMachine*' '크롬 자동 업데이트 (구버전 업데이터)'
Add-TaskDef $C 2 '\GoogleSystem\GoogleUpdater\' 'GoogleUpdaterTaskSystem*' '크롬 자동 업데이트'
Add-TaskDef $C 2 '\' 'GoogleUpdaterTaskSystem*' '크롬 자동 업데이트 (일부 버전)'
Add-TaskDef $C 2 '\' 'OneDrive*' 'OneDrive 업데이트/보고'
Add-TaskDef $C 1 '\' 'NvTmRep*' 'NVIDIA 원격 분석 보고 (구버전 드라이버)'
Add-TaskDef $C 1 '\' 'NvDriverUpdateCheckDaily*' 'NVIDIA 드라이버 업데이트 확인'
Add-TaskDef $C 1 '\' 'NVIDIA GeForce Experience SelfUpdate*' 'GeForce Experience 자동 업데이트'
Add-TaskDef $C 2 '\' 'NvProfileUpdater*' 'NVIDIA 게임 프로필 업데이트'
Add-TaskDef $C 2 '\' 'Adobe Acrobat Update Task' 'Adobe Reader 자동 업데이트'
Add-TaskDef $C 1 '\Microsoft\Office\' 'OfficeTelemetryAgent*' '오피스 원격 분석'
Add-TaskDef $C 2 '\Microsoft\Office\' 'Office Automatic Updates 2.0' '오피스 자동 업데이트'
Add-TaskDef $C 2 '\Microsoft\Office\' 'Office Feature Updates*' '오피스 기능 업데이트'
Add-TaskDef $C 1 '\Mozilla\' 'Firefox Default Browser Agent*' '파이어폭스 기본 브라우저 정보 전송'
Add-TaskDef $C 2 '\Mozilla\' 'Firefox Background Update*' '파이어폭스 자동 업데이트'

$TaskBackupDir = Join-Path $BackupDir 'tasks'
function Get-TaskKey([string]$p, [string]$n) { return "task|$p$n" }
function Get-TaskXmlFile([string]$p, [string]$n) {
    if (-not (Test-Path $TaskBackupDir)) { New-Item -ItemType Directory -Path $TaskBackupDir | Out-Null }
    $safe = (($p + $n) -replace '[\\/:*?"<>|\s]', '_').Trim('_')
    return (Join-Path $TaskBackupDir "$safe.xml")
}

# 카탈로그(+ 선택 시 전체 작업)를 실제 이 PC의 작업 목록으로 풀어서 행 목록을 만듦
function Get-TaskRows([switch]$All) {
    $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
    $rows = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($d in $script:TaskCatalog) {
        foreach ($t in @($tasks | Where-Object { $_.TaskPath -eq $d.P -and $_.TaskName -like $d.N })) {
            $k = Get-TaskKey $t.TaskPath $t.TaskName
            if ($seen.ContainsKey($k)) { continue }
            $seen[$k] = $true
            $rows.Add([pscustomobject]@{ P = $t.TaskPath; N = $t.TaskName; Cat = $d.Cat; Level = $d.Level; Desc = $d.Desc; Task = $t })
        }
    }
    # 이 도구로 삭제해서 지금은 없는 작업도 표시 (복구할 수 있게)
    foreach ($k in @($script:Backup.Keys | Where-Object { $_ -like 'task|*' })) {
        if ($seen.ContainsKey($k)) { continue }
        $b = $script:Backup[$k]
        $d = $script:TaskCatalog | Where-Object { $_.P -eq $b.P -and $b.N -like $_.N } | Select-Object -First 1
        $cat = '기타 (목록 밖)'; $lvl = 0; $desc = ''
        if ($d) { $cat = $d.Cat; $lvl = $d.Level; $desc = $d.Desc }
        $t = $tasks | Where-Object { $_.TaskPath -eq $b.P -and $_.TaskName -eq $b.N } | Select-Object -First 1
        $seen[$k] = $true
        $rows.Add([pscustomobject]@{ P = $b.P; N = $b.N; Cat = $cat; Level = $lvl; Desc = $desc; Task = $t })
    }
    if ($All) {
        foreach ($t in $tasks) {
            $k = Get-TaskKey $t.TaskPath $t.TaskName
            if ($seen.ContainsKey($k)) { continue }
            $seen[$k] = $true
            $rows.Add([pscustomobject]@{ P = $t.TaskPath; N = $t.TaskName; Cat = '기타 (목록 밖)'; Level = 0; Desc = [string]$t.Description; Task = $t })
        }
    }
    return , $rows
}

function Get-TaskRowState($row) {
    $t = $row.Task
    if (-not $t) {
        if ($script:Backup.ContainsKey((Get-TaskKey $row.P $row.N))) { return '삭제됨' }
        return '없음'
    }
    if ($t.State -eq 'Disabled') { return '사용 안 함' }
    return '사용'
}

function Get-TaskTriggerText($row) {
    $t = $row.Task
    if (-not $t) { return '' }
    $parts = @()
    foreach ($tr in @($t.Triggers)) {
        if (-not $tr) { continue }
        $cls = $tr.CimClass.CimClassName -replace '^MSFT_Task', '' -replace 'Trigger$', ''
        $name = switch ($cls) { 'Daily' { '매일' } 'Weekly' { '매주' } 'Logon' { '로그온' } 'Boot' { '부팅' } 'Idle' { '유휴' } 'Time' { '1회/반복' } 'Event' { '이벤트' } 'SessionStateChange' { '세션' } default { $cls } }
        $at = ''
        if ($tr.StartBoundary) { try { $at = ([datetime]$tr.StartBoundary).ToString('HH:mm') } catch {} }
        $parts += ("$name $at").Trim()
    }
    if ($parts.Count -eq 0) { return '(트리거 없음/유지 관리)' }
    return ($parts -join ', ')
}

function Save-TaskBackup($row, [bool]$withXml) {
    $k = Get-TaskKey $row.P $row.N
    $t = Get-ScheduledTask -TaskPath $row.P -TaskName $row.N -ErrorAction SilentlyContinue
    if (-not $t) { return $false }
    $entry = $null
    if ($script:Backup.ContainsKey($k)) { $entry = $script:Backup[$k] }
    if (-not $entry) {
        $entry = [pscustomobject]@{ P = $row.P; N = $row.N; Enabled = ($t.State -ne 'Disabled'); Xml = $null; Time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
    }
    if ($withXml -and -not $entry.Xml) {
        try {
            $f = Get-TaskXmlFile $row.P $row.N
            Export-ScheduledTask -TaskPath $row.P -TaskName $row.N -ErrorAction Stop | Set-Content -Path $f -Encoding Unicode
            $entry.Xml = $f
        } catch { Log "  XML 백업 실패: $($_.Exception.Message)" 'ERR'; return $false }
    }
    $script:Backup[$k] = $entry
    Save-Backup
    return $true
}

function Disable-TaskRow($row) {
    if (-not (Save-TaskBackup $row $false)) { Log "  없음: $($row.P)$($row.N)" 'WARN'; return }
    try {
        Disable-ScheduledTask -TaskPath $row.P -TaskName $row.N -ErrorAction Stop | Out-Null
        Log "  사용 안 함: $($row.P)$($row.N)" 'OK'
    } catch { Log "  실패(보호된 작업일 수 있음): $($row.P)$($row.N) - $($_.Exception.Message)" 'ERR' }
}

function Remove-TaskRow($row) {
    if (-not (Save-TaskBackup $row $true)) { Log "  없음 또는 백업 실패 -> 삭제 안 함: $($row.P)$($row.N)" 'WARN'; return }
    try {
        Unregister-ScheduledTask -TaskPath $row.P -TaskName $row.N -Confirm:$false -ErrorAction Stop
        Log "  삭제(XML 백업 보관): $($row.P)$($row.N)" 'OK'
    } catch { Log "  삭제 실패(보호된 작업일 수 있음): $($row.P)$($row.N) - $($_.Exception.Message)" 'ERR' }
}

function Set-TaskRowTime($row, [int]$hour) {
    if (-not (Save-TaskBackup $row $true)) { Log "  없음 또는 백업 실패 -> 변경 안 함: $($row.P)$($row.N)" 'WARN'; return }
    try {
        $at = (Get-Date).Date.AddHours($hour)
        $trig = New-ScheduledTaskTrigger -Daily -At $at
        $tk = Get-ScheduledTask -TaskPath $row.P -TaskName $row.N -ErrorAction Stop
        $tk.Triggers = @($trig)
        $tk.Settings.StartWhenAvailable = $false     # 꺼져 있다가 켜질 때(영업 중) 바로 실행되지 않게
        Set-ScheduledTask -InputObject $tk -ErrorAction Stop | Out-Null
        Log ("  실행 시간 변경 -> 매일 {0:00}:00 : {1}{2}" -f $hour, $row.P, $row.N) 'OK'
    } catch { Log "  시간 변경 실패(보호된 작업일 수 있음): $($row.P)$($row.N) - $($_.Exception.Message)" 'ERR' }
}

function Restore-TaskRow($row) {
    $k = Get-TaskKey $row.P $row.N
    if (-not $script:Backup.ContainsKey($k)) { Log "  되돌릴 기록 없음: $($row.P)$($row.N)" 'WARN'; return }
    $b = $script:Backup[$k]
    if (-not (Get-ScheduledTask -TaskPath $b.P -TaskName $b.N -ErrorAction SilentlyContinue) -and -not ($b.Xml -and (Test-Path $b.Xml))) {
        Log "  작업이 없고 백업 XML도 없음 -> 기록만 정리: $($b.P)$($b.N)" 'WARN'
        $script:Backup.Remove($k); Save-Backup; return
    }
    try {
        if ($b.Xml -and (Test-Path $b.Xml)) {
            $xml = Get-Content -Path $b.Xml -Raw -Encoding Unicode
            Register-ScheduledTask -Xml $xml -TaskPath $b.P -TaskName $b.N -Force -ErrorAction Stop | Out-Null
        }
        if ($b.Enabled) { Enable-ScheduledTask -TaskPath $b.P -TaskName $b.N -ErrorAction Stop | Out-Null }
        else { Disable-ScheduledTask -TaskPath $b.P -TaskName $b.N -ErrorAction Stop | Out-Null }
        $script:Backup.Remove($k); Save-Backup
        if ($b.Xml -and (Test-Path $b.Xml)) { Remove-Item $b.Xml -ErrorAction SilentlyContinue }
        Log "  원래대로: $($b.P)$($b.N)" 'OK'
    } catch { Log "  복구 실패(기록은 남겨둠): $($b.P)$($b.N) - $($_.Exception.Message)" 'ERR' }
}

function Get-TaskPresetRows([int]$max) {
    $rows = Get-TaskRows
    return @($rows | Where-Object { $_.Level -ge 1 -and $_.Level -le $max -and $_.Task })
}

# ============================== 화면 (탭) ==============================
$script:LogBoxes = New-Object System.Collections.Generic.List[object]
$script:Busy = $false
$script:Inited = $false

function Initialize-PCBang {
    if ($script:Inited) { return }
    $script:Inited = $true
    # 관리자 권한 창이 다른 계정(관리자 암호 입력)으로 열렸는지 확인 -> HKCU 설정이 손님 계정에 안 들어감
    $script:UserWarning = $null
    try {
        $ex = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Select-Object -First 1
        if ($ex) {
            $owner = (Invoke-CimMethod -InputObject $ex -MethodName GetOwner -ErrorAction Stop).User
            if ($owner -and $owner -ne $env:USERNAME) {
                $script:UserWarning = "현재 화면에 로그인된 계정은 '$owner' 인데, 이 도구는 '$env:USERNAME' 계정 권한으로 실행됐습니다.`n`n마우스/알림/시작 메뉴 같은 사용자 설정은 '$env:USERNAME' 계정에 적용됩니다.`n손님 계정에 적용하려면: 손님 계정을 관리자로 만들거나, 손님 계정 대신 '$env:USERNAME' 계정으로 로그인해 운영하세요."
            }
        }
    } catch {}
    Load-Backup
    Log "==== 시작 v$Version / $env:COMPUTERNAME / $env:USERNAME ===="
    if ($script:UserWarning) { Log ($script:UserWarning -replace "`n", ' ') 'WARN' }
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Log '관리자 권한이 아닙니다. 대부분의 항목이 실패합니다. 프로그램을 관리자 권한으로 실행하세요.' 'ERR' }
}

# 화면 색. 밝은 기본값 / Add-PCBangTabs -Dark 일 때 다크
$script:Dark = $false
function Col([string]$n) {
    $c = if ($script:Dark) {
        @{ Back = '#272727'; Fore = '#DDDDDD'; List = '#2B2B2B'; Box = '#1C1C1C'; BoxFore = '#BBBBBB'; Btn = '#4A4A4A'; Head = '#333333'; Line = '#555555'
           Ok = '#7CD992'; Part = '#FFB454'; Off = '#8A8A8A'; Warn = '#FF8A80'; Item = '#DDDDDD' }[$n]
    } else {
        @{ Back = 'Control'; Fore = 'ControlText'; List = 'Window'; Box = 'White'; BoxFore = 'WindowText'; Btn = 'Control'; Head = 'Control'; Line = 'ControlDark'
           Ok = 'DarkGreen'; Part = 'DarkOrange'; Off = 'Gray'; Warn = 'DarkRed'; Item = 'Black' }[$n]
    }
    if ($c.StartsWith('#')) { return [System.Drawing.ColorTranslator]::FromHtml($c) }
    return [System.Drawing.Color]::FromName($c)
}
# 다크일 때 밝은 버튼 색 -> 같은 계열의 어두운 색
$script:DarkBtn = @{ Honeydew = '#2F5D3A'; LightGreen = '#2E7D32'; Khaki = '#7A6A1E'; LightSkyBlue = '#1F6FA8'; MistyRose = '#8B3A3A'; LightSalmon = '#A0442F' }
function Set-DarkScroll($ctl) {
    # 스크롤바를 Windows 다크 테마로 (Win10 1809+, 실패해도 무시)
    if (-not $script:Dark) { return }
    try {
        if (-not ('PCBangUx' -as [type])) { Add-Type -Name PCBangUx -Namespace '' -MemberDefinition '[DllImport("uxtheme.dll", CharSet=CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr h, string app, string id);' }
        [void][PCBangUx]::SetWindowTheme($ctl.Handle, 'DarkMode_Explorer', $null)
    } catch {}
}
function Set-ListLook($lv) {
    $lv.BackColor = Col List; $lv.ForeColor = Col Item
    if (-not $script:Dark) { return }
    # 머리글은 직접 그림(기본은 밝은 회색), 행은 기본 그리기
    $lv.OwnerDraw = $true
    $lv.Add_DrawItem({ param($s, $e) $e.DrawDefault = $true })
    $lv.Add_DrawSubItem({ param($s, $e) $e.DrawDefault = $true })
    $lv.Add_DrawColumnHeader({
        param($s, $e)
        $bg = New-Object System.Drawing.SolidBrush (Col Head)
        $e.Graphics.FillRectangle($bg, $e.Bounds); $bg.Dispose()
        $pen = New-Object System.Drawing.Pen (Col Line)
        $e.Graphics.DrawLine($pen, $e.Bounds.Right - 1, $e.Bounds.Top, $e.Bounds.Right - 1, $e.Bounds.Bottom); $pen.Dispose()
        $r = New-Object System.Drawing.Rectangle(($e.Bounds.X + 4), $e.Bounds.Y, ($e.Bounds.Width - 4), $e.Bounds.Height)
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $s.Font, $r, (Col Fore), [System.Windows.Forms.TextFormatFlags]'VerticalCenter, Left, EndEllipsis')
    })
    $lv.Add_HandleCreated({ param($s, $e) Set-DarkScroll $s })
}
function Set-PageLook($page, $top) {
    $page.BackColor = Col Back; $page.ForeColor = Col Fore
    $top.BackColor = Col Back; $top.ForeColor = Col Fore
    foreach ($c in $top.Controls) {
        if ($c -is [System.Windows.Forms.TextBox] -or $c -is [System.Windows.Forms.NumericUpDown]) { $c.BackColor = Col Box; $c.ForeColor = Col Fore; if ($script:Dark) { $c.BorderStyle = 'FixedSingle' } }
    }
}
function Set-TabLook($TabControl) {
    $tc = $TabControl
    # 탭 머리글: 다크일 때만 직접 그림. 선택된 탭은 굵은 글자 + 빨간 밑줄 (색만으로 구분하지 않게)
    if (-not $script:Dark) { return }
    # 탭 줄의 빈 곳과 테두리는 DrawItem으로 못 칠해서, 그리기(WM_PAINT)가 끝난 뒤 덧칠
    if (-not ('PCBangTabSkin' -as [type])) {
        Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System.Drawing; using System.Windows.Forms;
public class PCBangTabSkin : NativeWindow {
    TabControl tc; Color back, line;
    public PCBangTabSkin(TabControl t, Color b, Color l) {
        tc = t; back = b; line = l;
        if (t.IsHandleCreated) AssignHandle(t.Handle);
        t.HandleCreated += (s, e) => AssignHandle(tc.Handle);
        t.HandleDestroyed += (s, e) => ReleaseHandle();
    }
    protected override void WndProc(ref Message m) {
        base.WndProc(ref m);
        if (m.Msg != 0x000F || tc.TabCount == 0) return;
        using (var g = Graphics.FromHwnd(tc.Handle))
        using (var br = new SolidBrush(back))
        using (var pen = new Pen(line)) {
            var d = tc.DisplayRectangle;
            var all = new Region(tc.ClientRectangle);
            all.Exclude(d);
            for (int i = 0; i < tc.TabCount; i++) { var r = tc.GetTabRect(i); r.Inflate(-2, -2); all.Exclude(r); }
            g.FillRegion(br, all);
            for (int i = 0; i < tc.TabCount; i++) { var r = tc.GetTabRect(i); r.Inflate(-2, -2); g.DrawRectangle(pen, r.X, r.Y, r.Width - 1, r.Height - 1); }
            g.DrawRectangle(pen, d.X - 1, d.Y - 1, d.Width + 1, d.Height + 1);
            all.Dispose();
            if (tc.SelectedIndex >= 0) {
                var r = tc.GetTabRect(tc.SelectedIndex); r.Inflate(-2, -2);
                using (var red = new SolidBrush(Color.FromArgb(0xE5, 0x39, 0x2D))) g.FillRectangle(red, r.X, r.Bottom - 3, r.Width, 3);
            }
        }
    }
}
'@
    }
    $script:TabSkin = New-Object PCBangTabSkin($TabControl, (Col Back), (Col Line))
    $tc.DrawMode = 'OwnerDrawFixed'
    $tc.Padding = New-Object System.Drawing.Point(14, 7)
    $tc.Add_SelectedIndexChanged({ param($s, $e) $s.Invalidate() })
    $tc.Add_DrawItem({
        param($s, $e)
        $sel = ($e.Index -eq $s.SelectedIndex)
        $bg = New-Object System.Drawing.SolidBrush ($(if ($sel) { Col Head } else { Col Box }))
        $e.Graphics.FillRectangle($bg, $e.Bounds); $bg.Dispose()
        $font = if ($sel) { New-Object System.Drawing.Font($s.Font, [System.Drawing.FontStyle]::Bold) } else { $s.Font }
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $s.TabPages[$e.Index].Text, $font, $e.Bounds, $(if ($sel) { Col Fore } else { Col BoxFore }), [System.Windows.Forms.TextFormatFlags]'HorizontalCenter, VerticalCenter')
        if ($sel) { $font.Dispose() }
    })
}

function New-Btn($parent, [string]$text, [int]$w, $color) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Width = $w; $b.Height = 34
    if ($script:Dark) {
        $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderColor = Col Line; $b.ForeColor = [System.Drawing.Color]::White
        $b.BackColor = if ($color -and $script:DarkBtn.ContainsKey($color.Name)) { [System.Drawing.ColorTranslator]::FromHtml($script:DarkBtn[$color.Name]) } else { Col Btn }
    } elseif ($color) { $b.BackColor = $color }
    $parent.Controls.Add($b)
    return $b
}
function New-LogBox {
    $lb = New-Object System.Windows.Forms.TextBox
    $lb.Multiline = $true; $lb.ReadOnly = $true; $lb.ScrollBars = 'Vertical'
    $lb.Dock = 'Bottom'; $lb.Height = 180; $lb.BackColor = Col Box; $lb.ForeColor = Col BoxFore
    if ($script:Dark) { $lb.BorderStyle = 'FixedSingle'; $lb.Add_HandleCreated({ param($s, $e) Set-DarkScroll $s }) }
    $script:LogBoxes.Add($lb)
    return $lb
}
function Set-Busy([bool]$busy) {
    $script:Busy = $busy
    foreach ($pg in @($script:PageOpt, $script:PageTask)) {
        if (-not $pg) { continue }
        foreach ($c in $pg.Controls) { if ($c -isnot [System.Windows.Forms.TextBox]) { $c.Enabled = -not $busy } }
    }
    $f = $null; if ($script:PageOpt) { $f = $script:PageOpt.FindForm() }
    if ($f) { if ($busy) { $f.Cursor = [System.Windows.Forms.Cursors]::WaitCursor } else { $f.Cursor = [System.Windows.Forms.Cursors]::Default } }
}

# ---------------- 최적화 탭 ----------------
function New-OptimizerPage {
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = 'PC방 최적화'
    $script:PageOpt = $page

    $top = New-Object System.Windows.Forms.FlowLayoutPanel
    $top.Dock = 'Top'; $top.Height = 92; $top.Padding = New-Object System.Windows.Forms.Padding(6)
    $bSafe = New-Btn $top '① 안전 선택' 105 ([System.Drawing.Color]::Honeydew)
    $bRec  = New-Btn $top '② 권장 선택' 105 ([System.Drawing.Color]::LightGreen)
    $bMax  = New-Btn $top '③ 최대 선택' 105 ([System.Drawing.Color]::Khaki)
    $bNone = New-Btn $top '선택 해제' 85 $null
    $bApplied = New-Btn $top '적용된 것 선택' 110 $null
    $bApply = New-Btn $top '▶ 선택 항목 적용' 140 ([System.Drawing.Color]::LightSkyBlue)
    $bUndo  = New-Btn $top '↺ 선택 항목 되돌리기' 150 ([System.Drawing.Color]::MistyRose)
    $bCheck = New-Btn $top '상태 새로고침' 105 $null
    $bDiag  = New-Btn $top 'PC 진단' 85 $null
    $bLogs  = New-Btn $top '폴더 열기' 85 $null

    $chkRp = New-Object System.Windows.Forms.CheckBox
    $chkRp.Text = '적용 전 복원 지점 만들기'; $chkRp.Checked = $true; $chkRp.AutoSize = $true
    $chkRp.Margin = New-Object System.Windows.Forms.Padding(8, 10, 8, 0)
    $top.Controls.Add($chkRp)
    $warn = New-Object System.Windows.Forms.Label
    $warn.AutoSize = $true; $warn.ForeColor = Col Warn
    $warn.Margin = New-Object System.Windows.Forms.Padding(4, 10, 4, 0)
    $warn.Text = '※ 복원 프로그램(디스크 보호)/노하드 이미지 쓰기 모드에서 실행하세요.  ※ 손님이 쓰는 계정으로 로그인해서 실행.  ※ 항목에 마우스를 올리면 설명이 나옵니다.'
    $top.Controls.Add($warn)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true; $lv.GridLines = $true
    $lv.ShowItemToolTips = $true; $lv.Dock = 'Fill'; $lv.HideSelection = $false
    [void]$lv.Columns.Add('항목', 380)
    [void]$lv.Columns.Add('단계', 55)
    [void]$lv.Columns.Add('위험', 50)
    [void]$lv.Columns.Add('상태', 70)
    [void]$lv.Columns.Add('설명', 600)
    $groups = @{}
    foreach ($t in $script:Tweaks) {
        if (-not $groups.ContainsKey($t.Cat)) {
            $g = New-Object System.Windows.Forms.ListViewGroup($t.Cat, $t.Cat)
            [void]$lv.Groups.Add($g); $groups[$t.Cat] = $g
        }
        $it = New-Object System.Windows.Forms.ListViewItem($t.Name)
        $it.Tag = $t.Id
        $it.Group = $groups[$t.Cat]
        [void]$it.SubItems.Add($LevelName[$t.Level])
        [void]$it.SubItems.Add($t.Risk)
        [void]$it.SubItems.Add('')
        [void]$it.SubItems.Add($t.Desc)
        $tip = $t.Desc
        if ($t.NoUndo) { $tip += "`n(되돌리기 시 삭제된 프로그램은 복구되지 않음)" }
        $it.ToolTipText = $tip
        [void]$lv.Items.Add($it)
    }
    $logBox = New-LogBox
    $page.Controls.Add($lv); $page.Controls.Add($logBox); $page.Controls.Add($top)
    $lv.BringToFront()
    Set-PageLook $page $top; Set-ListLook $lv
    $script:Lv = $lv
    $script:ChkRp = $chkRp

    $script:RefreshStatus = {
        foreach ($it in $script:Lv.Items) {
            $t = $script:TweakMap[$it.Tag]
            $s = Get-TweakStatus $t
            $it.SubItems[3].Text = $s
            if ($s -eq '적용됨') { $it.ForeColor = Col Ok }
            elseif ($s -eq '일부') { $it.ForeColor = Col Part }
            else { $it.ForeColor = Col Item }
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
    $script:SelectLevel = {
        param([int]$max)
        foreach ($it in $script:Lv.Items) {
            $lvl = $script:TweakMap[$it.Tag].Level
            $it.Checked = ($lvl -ge 1 -and $lvl -le $max)
        }
    }
    $script:Checked = {
        $sel = @()
        foreach ($it in $script:Lv.Items) { if ($it.Checked) { $sel += $script:TweakMap[$it.Tag] } }
        return , $sel
    }

    $bSafe.Add_Click({ & $script:SelectLevel 1 })
    $bRec.Add_Click({ & $script:SelectLevel 2 })
    $bMax.Add_Click({ & $script:SelectLevel 3 })
    $bNone.Add_Click({ foreach ($it in $script:Lv.Items) { $it.Checked = $false } })
    $bApplied.Add_Click({ foreach ($it in $script:Lv.Items) { $it.Checked = $script:Backup.ContainsKey([string]$it.Tag) } })
    $bCheck.Add_Click({ try { Set-Busy $true; & $script:RefreshStatus } catch {} finally { Set-Busy $false }; Log '상태 새로고침 완료' })
    $bLogs.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$ScriptDir`"" })
    $bApply.Add_Click({
        $sel = & $script:Checked
        if ($sel.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('적용할 항목을 체크하세요.', '알림'); return }
        $risky = @($sel | Where-Object { $_.Level -eq 3 -or $_.Level -eq 0 -or $_.NoUndo })
        $msg = "$($sel.Count)개 항목을 적용합니다."
        if ($risky.Count -gt 0) { $msg += "`n`n주의 항목:`n - " + (($risky | ForEach-Object { $_.Name }) -join "`n - ") }
        $msg += "`n`n화면이 잠깐 깜빡일 수 있습니다(탐색기 재시작). 계속할까요?"
        if ([System.Windows.Forms.MessageBox]::Show($msg, '적용 확인', 'YesNo', 'Question') -ne 'Yes') { return }
        try {
            Set-Busy $true
            Invoke-Many $sel -NoRestorePoint:(-not $script:ChkRp.Checked)
            & $script:RefreshStatus
        } catch { Log "오류: $($_.Exception.Message)" 'ERR' }
        finally { Set-Busy $false }
        if ([System.Windows.Forms.MessageBox]::Show("적용 완료. 지금 재부팅할까요?`n(재부팅 후 모든 설정이 반영됩니다)", '완료', 'YesNo', 'Information') -eq 'Yes') {
            Restart-Computer -Force
        }
    })
    $bUndo.Add_Click({
        $all = & $script:Checked
        $sel = @($all | Where-Object { $script:Backup.ContainsKey($_.Id) })
        if ($sel.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('체크한 항목 중 이 도구로 적용한 기록이 있는 항목이 없습니다.', '알림'); return }
        if ([System.Windows.Forms.MessageBox]::Show("$($sel.Count)개 항목을 적용 전 상태로 되돌립니다. 계속할까요?", '되돌리기 확인', 'YesNo', 'Question') -ne 'Yes') { return }
        try {
            Set-Busy $true
            [array]::Reverse($sel)
            Invoke-Many $sel -UndoMode
            & $script:RefreshStatus
        } catch { Log "오류: $($_.Exception.Message)" 'ERR' }
        finally { Set-Busy $false }
        [void][System.Windows.Forms.MessageBox]::Show('되돌리기 완료. 재부팅하면 모두 반영됩니다.', '완료')
    })
    $bDiag.Add_Click({
        try {
            Set-Busy $true
            Log '===== PC 진단 ====='
            $lines = Get-PcReport
            foreach ($l in $lines) { Log $l }
            $f = Write-ReportFile $lines
            Log "진단 결과 저장: $f" 'OK'
        } catch { Log "오류: $($_.Exception.Message)" 'ERR' }
        finally { Set-Busy $false }
    })
    return $page
}

# ---------------- 작업 스케줄러 탭 ----------------
function New-TaskPage {
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = '작업 스케줄러 정리'
    $script:PageTask = $page

    $top = New-Object System.Windows.Forms.FlowLayoutPanel
    $top.Dock = 'Top'; $top.Height = 92; $top.Padding = New-Object System.Windows.Forms.Padding(6)
    $bSafe = New-Btn $top '① 안전 선택' 105 ([System.Drawing.Color]::Honeydew)
    $bRec  = New-Btn $top '② 권장 선택' 105 ([System.Drawing.Color]::LightGreen)
    $bMax  = New-Btn $top '③ 최대 선택' 105 ([System.Drawing.Color]::Khaki)
    $bNone = New-Btn $top '선택 해제' 85 $null
    $bChanged = New-Btn $top '바꾼 것 선택' 100 $null
    $bOff  = New-Btn $top '■ 사용 안 함' 110 ([System.Drawing.Color]::LightSkyBlue)
    $bDel  = New-Btn $top '✕ 삭제(백업)' 105 ([System.Drawing.Color]::LightSalmon)
    $bRestore = New-Btn $top '↺ 원래대로' 100 ([System.Drawing.Color]::MistyRose)
    $bRefresh = New-Btn $top '새로고침' 80 $null
    $bTs = New-Btn $top '작업 스케줄러 열기' 135 $null

    $lblHour = New-Object System.Windows.Forms.Label
    $lblHour.Text = '실행 시간 변경:'; $lblHour.AutoSize = $true; $lblHour.Margin = New-Object System.Windows.Forms.Padding(8, 10, 0, 0)
    $top.Controls.Add($lblHour)
    $numHour = New-Object System.Windows.Forms.NumericUpDown
    $numHour.Minimum = 0; $numHour.Maximum = 23; $numHour.Value = 6; $numHour.Width = 50
    $numHour.Margin = New-Object System.Windows.Forms.Padding(2, 7, 0, 0)
    $top.Controls.Add($numHour)
    $bTime = New-Btn $top '시에 매일 실행' 115 $null

    $chkAll = New-Object System.Windows.Forms.CheckBox
    $chkAll.Text = '전체 작업 보기'; $chkAll.AutoSize = $true; $chkAll.Margin = New-Object System.Windows.Forms.Padding(12, 10, 0, 0)
    $top.Controls.Add($chkAll)
    $lblF = New-Object System.Windows.Forms.Label
    $lblF.Text = '검색:'; $lblF.AutoSize = $true; $lblF.Margin = New-Object System.Windows.Forms.Padding(8, 10, 0, 0)
    $top.Controls.Add($lblF)
    $txtF = New-Object System.Windows.Forms.TextBox
    $txtF.Width = 160; $txtF.Margin = New-Object System.Windows.Forms.Padding(2, 7, 0, 0)
    $top.Controls.Add($txtF)
    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize = $true; $hint.ForeColor = Col Warn
    $hint.Margin = New-Object System.Windows.Forms.Padding(8, 10, 0, 0)
    $hint.Text = '※ 보통 "사용 안 함"을 쓰세요. 삭제/시간 변경도 XML로 백업되어 "원래대로"로 복구됩니다. 시간 변경 작업 중 유지 관리용 작업은 "자동 유지 관리 끄기"도 함께 적용하세요.'
    $top.Controls.Add($hint)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true; $lv.GridLines = $true
    $lv.ShowItemToolTips = $true; $lv.Dock = 'Fill'; $lv.HideSelection = $false
    [void]$lv.Columns.Add('작업 이름', 300)
    [void]$lv.Columns.Add('경로', 250)
    [void]$lv.Columns.Add('단계', 50)
    [void]$lv.Columns.Add('상태', 75)
    [void]$lv.Columns.Add('실행 조건', 130)
    [void]$lv.Columns.Add('설명', 520)
    $logBox = New-LogBox
    $page.Controls.Add($lv); $page.Controls.Add($logBox); $page.Controls.Add($top)
    $lv.BringToFront()
    Set-PageLook $page $top; Set-ListLook $lv
    $script:TLv = $lv; $script:TChkAll = $chkAll; $script:TFilter = $txtF; $script:THour = $numHour

    $script:TaskReload = {
        $script:TLv.BeginUpdate()
        try {
        $script:TLv.Items.Clear(); $script:TLv.Groups.Clear()
        $rows = Get-TaskRows -All:($script:TChkAll.Checked)
        $f = $script:TFilter.Text.Trim()
        $groups = @{}
        foreach ($r in $rows) {
            if ($f -and ("$($r.P)$($r.N) $($r.Desc)").IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            if (-not $groups.ContainsKey($r.Cat)) {
                $g = New-Object System.Windows.Forms.ListViewGroup($r.Cat, $r.Cat)
                [void]$script:TLv.Groups.Add($g); $groups[$r.Cat] = $g
            }
            $it = New-Object System.Windows.Forms.ListViewItem($r.N)
            $it.Tag = $r
            $it.Group = $groups[$r.Cat]
            [void]$it.SubItems.Add($r.P)
            $ln = '-'; if ($r.Level -gt 0) { $ln = $LevelName[$r.Level] }
            [void]$it.SubItems.Add($ln)
            $st = Get-TaskRowState $r
            [void]$it.SubItems.Add($st)
            [void]$it.SubItems.Add((Get-TaskTriggerText $r))
            [void]$it.SubItems.Add($r.Desc)
            $it.ToolTipText = "$($r.P)$($r.N)`n$($r.Desc)"
            if ($script:Backup.ContainsKey((Get-TaskKey $r.P $r.N))) { $it.ForeColor = Col Ok }
            if ($st -eq '삭제됨') { $it.ForeColor = Col Off }
            [void]$script:TLv.Items.Add($it)
        }
        } finally { $script:TLv.EndUpdate() }
        Log ("작업 {0}개 표시 (바꾼 작업 {1}개)" -f $script:TLv.Items.Count, @($script:Backup.Keys | Where-Object { $_ -like 'task|*' }).Count)
    }
    $script:TaskChecked = {
        $sel = @()
        foreach ($it in $script:TLv.Items) { if ($it.Checked) { $sel += $it.Tag } }
        return , $sel
    }
    $script:TaskRun = {
        param([string]$title, [scriptblock]$action, [string]$confirm)
        $sel = & $script:TaskChecked
        if ($sel.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('작업을 체크하세요.', '알림'); return }
        if ([System.Windows.Forms.MessageBox]::Show("$($sel.Count)개 작업: $confirm`n계속할까요?", $title, 'YesNo', 'Question') -ne 'Yes') { return }
        try {
            Set-Busy $true
            Log "===== $title ($($sel.Count)개) ====="
            foreach ($r in $sel) { & $action $r; [System.Windows.Forms.Application]::DoEvents() }
            & $script:TaskReload
        } catch { Log "오류: $($_.Exception.Message)" 'ERR' }
        finally { Set-Busy $false }
    }
    $script:TaskSelectLevel = {
        param([int]$max)
        foreach ($it in $script:TLv.Items) { $l = $it.Tag.Level; $it.Checked = ($l -ge 1 -and $l -le $max -and $it.SubItems[3].Text -eq '사용') }
    }

    $bSafe.Add_Click({ & $script:TaskSelectLevel 1 })
    $bRec.Add_Click({ & $script:TaskSelectLevel 2 })
    $bMax.Add_Click({ & $script:TaskSelectLevel 3 })
    $bNone.Add_Click({ foreach ($it in $script:TLv.Items) { $it.Checked = $false } })
    $bChanged.Add_Click({ foreach ($it in $script:TLv.Items) { $it.Checked = $script:Backup.ContainsKey((Get-TaskKey $it.Tag.P $it.Tag.N)) } })
    $bRefresh.Add_Click({ try { Set-Busy $true; & $script:TaskReload } catch {} finally { Set-Busy $false } })
    $chkAll.Add_CheckedChanged({ try { Set-Busy $true; & $script:TaskReload } catch {} finally { Set-Busy $false } })
    $txtF.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; try { Set-Busy $true; & $script:TaskReload } catch {} finally { Set-Busy $false } } })
    $bTs.Add_Click({ Start-Process taskschd.msc })
    $bOff.Add_Click({ & $script:TaskRun '사용 안 함' { param($r) Disable-TaskRow $r } '사용 안 함으로 바꿉니다 (원래대로 가능)' })
    $bDel.Add_Click({ & $script:TaskRun '삭제' { param($r) Remove-TaskRow $r } "작업 스케줄러에서 삭제합니다.`n(XML로 백업되며 '원래대로'로 다시 만들 수 있음)" })
    $bRestore.Add_Click({ & $script:TaskRun '원래대로' { param($r) Restore-TaskRow $r } '이 도구로 바꾸기 전 상태로 되돌립니다' })
    $bTime.Add_Click({
        $h = [int]$script:THour.Value
        & $script:TaskRun '실행 시간 변경' { param($r) Set-TaskRowTime $r ([int]$script:THour.Value) } ("실행 조건을 '매일 {0:00}:00' 하나로 바꿉니다 (영업 안 하는 시간 추천)" -f $h)
    })
    return $page
}

# 다른 프로그램(예: 노하드 이미지 도구)의 TabControl 에 탭 2개를 추가
function Add-PCBangTabs {
    param([Parameter(Mandatory = $true)][System.Windows.Forms.TabControl]$TabControl, [switch]$Dark)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $script:Dark = $Dark.IsPresent
    Set-TabLook $TabControl
    Initialize-PCBang
    $p1 = New-OptimizerPage
    $p2 = New-TaskPage
    [void]$TabControl.TabPages.Add($p1)
    [void]$TabControl.TabPages.Add($p2)
    $script:LoadedOpt = $false; $script:LoadedTask = $false
    $script:OnTab = {
        param($tc)
        if ($script:Busy) { return }
        $sel = $tc.SelectedTab
        if (-not $script:ClosingHooked) {
            $f = $tc.FindForm()
            if ($f) {
                $script:ClosingHooked = $true
                $f.Add_FormClosing({ param($s, $e) if ($script:Busy) { $e.Cancel = $true } })
            }
        }
        if ($sel -eq $script:PageOpt -and -not $script:LoadedOpt) {
            $script:LoadedOpt = $true
            Log "PC방 최적화 도구 v$Version (백업: $BackupFile)"
            if ($script:UserWarning) { [void][System.Windows.Forms.MessageBox]::Show($script:UserWarning, '계정 확인', 'OK', 'Warning') }
            Log '상태 확인 중...'
            try { Set-Busy $true; & $script:RefreshStatus } catch {} finally { Set-Busy $false }
            Log '준비 완료. "② 권장 선택" -> "▶ 선택 항목 적용" 순서로 누르면 됩니다.' 'OK'
        }
        if ($sel -eq $script:PageTask -and -not $script:LoadedTask) {
            $script:LoadedTask = $true
            Log '작업 목록 읽는 중...'
            try { Set-Busy $true; & $script:TaskReload } catch {} finally { Set-Busy $false }
        }
    }
    $TabControl.Add_SelectedIndexChanged({ param($s, $e) & $script:OnTab $s })
    $script:HostTab = $TabControl
    if ($TabControl.SelectedTab -eq $p1 -or $TabControl.SelectedTab -eq $p2) {
        # 우리 탭이 처음부터 선택돼 있으면 창이 뜬 뒤 로드
        $f = $TabControl.FindForm()
        if ($f) { $f.Add_Shown({ & $script:OnTab $script:HostTab }) }
    }
}

function Show-Gui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "PC방 윈도우11 최적화 도구 v$Version  -  $env:COMPUTERNAME / $env:USERNAME"
    $form.Size = New-Object System.Drawing.Size(1250, 840)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('Malgun Gothic', 9)
    $tc = New-Object System.Windows.Forms.TabControl
    $tc.Dock = 'Fill'
    $form.Controls.Add($tc)
    Add-PCBangTabs -TabControl $tc
    $form.Add_Shown({ & $script:OnTab $script:HostTab })
    [void]$form.ShowDialog()
}

# ============================== 실행 ==============================
if ($Embedded) {
    # 다른 프로그램 안에 탭으로 들어갈 때: 화면 함수만 내보냄
    try { Export-ModuleMember -Function Add-PCBangTabs } catch {}
    return
}

Initialize-PCBang

if ($Report) {
    $lines = Get-PcReport
    foreach ($l in $lines) { Write-Host $l }
    Write-Host ''
    foreach ($t in $script:Tweaks) { Write-Host ('{0,-6} [{1}] {2}' -f (Get-TweakStatus $t), $LevelName[$t.Level], $t.Name) }
    $f = Write-ReportFile $lines
    Write-Host "`n저장: $f"
    [void](Read-Host "`n엔터를 누르면 닫힙니다")
    exit
}

if ($UndoAll) {
    $list = @($script:Tweaks | Where-Object { $script:Backup.ContainsKey($_.Id) })
    [array]::Reverse($list)
    Invoke-Many $list -UndoMode
    $tk = @($script:Backup.Keys | Where-Object { $_ -like 'task|*' })
    if ($tk.Count -gt 0) {
        Log "작업 스케줄러 $($tk.Count)개 원래대로"
        foreach ($k in $tk) { $b = $script:Backup[$k]; Restore-TaskRow ([pscustomobject]@{ P = $b.P; N = $b.N }) }
    }
    if (-not $NoReboot) { if ((Read-Host '지금 재부팅할까요? (Y/N)') -match '^[Yy]') { Restart-Computer -Force } }
    exit
}

if ($Preset) {
    $list = Get-PresetList $Preset
    Log "프리셋 $Preset : $($list.Count)개 항목 적용"
    Invoke-Many $list
    if (-not $NoTasks) {
        $max = @{ 'Safe' = 1; 'Recommended' = 2; 'Max' = 3 }[$Preset]
        $rows = Get-TaskPresetRows $max
        Log "작업 스케줄러: $($rows.Count)개 사용 안 함"
        foreach ($r in $rows) { if ($r.Task.State -ne 'Disabled') { Disable-TaskRow $r } }
    }
    if ($NoReboot) { exit }
    Write-Host ''
    if ((Read-Host '지금 재부팅할까요? (Y/N)') -match '^[Yy]') { Restart-Computer -Force }
    exit
}

Show-Gui

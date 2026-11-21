# PC 원클릭 진단 — 단위/시나리오 테스트 (외부 모듈 없이 PowerShell 5.1 / 7 모두 실행)
#   pwsh -File tests/Run-Tests.ps1
param([string]$OutDir)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'PCCheck.ps1') -LoadOnly
if (-not $OutDir) { $OutDir = Join-Path ([IO.Path]::GetTempPath()) ('pccheck-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8)) }

$script:pass = 0; $script:fail = 0; $script:failed = @()
function It([string]$name, [scriptblock]$body) {
    try { & $body; $script:pass++; Write-Host "  ✓ $name" -ForegroundColor Green }
    catch { $script:fail++; $script:failed += $name; Write-Host "  ✗ $name`n      $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert($cond, [string]$msg) { if (-not $cond) { throw "Assert 실패: $msg" } }
function Assert-Eq($a, $b, [string]$msg) { if ($a -ne $b) { throw "기대값 '$b' 인데 '$a' — $msg" } }

$now = Get-Date '2026-11-14T12:00:00'
function T([double]$daysAgo, [double]$minutes = 0) { return (Format-T ($now.AddDays(-$daysAgo).AddMinutes($minutes))) }
function New-Scenario([hashtable]$over) {
    $d = New-EmptyData
    $d.Meta.Created = Format-T $now; $d.Meta.Days = 30; $d.Meta.IsAdmin = $true
    $d.System = [ordered]@{ OS = 'Windows 11 Pro'; Build = '26100'; CPU = 'AMD Ryzen 7 7800X3D 8-Core Processor'; RamGB = 32; Board = 'ASUS TUF B650'; BIOS = '2613'; BIOSDate = (T 200); FastStartup = 0; LastBoot = (T 1) }
    $d.Gpus = @([ordered]@{ Name = 'NVIDIA GeForce RTX 4070'; Vendor = 'NVIDIA'; VramGB = 12; Driver = '32.0.15.6614'; DriverDate = (T 40); Status = 'OK' })
    $d.Dimms = @(
        [ordered]@{ Slot = 'DIMM_A2'; SizeGB = 16; ConfiguredMHz = 4800; RatedMHz = 4800; Maker = 'Samsung'; Part = 'M323R2GA3BB0'; DDR = 'DDR5' },
        [ordered]@{ Slot = 'DIMM_B2'; SizeGB = 16; ConfiguredMHz = 4800; RatedMHz = 4800; Maker = 'Samsung'; Part = 'M323R2GA3BB0'; DDR = 'DDR5' })
    $d.Disks = @([ordered]@{ Name = 'Samsung SSD 980 PRO'; Media = 'SSD'; Bus = 'NVMe'; SizeGB = 1000; Health = 'Healthy'; TempC = 45; WearPct = 3; ReadErr = 0 })
    foreach ($k in $over.Keys) { $d[$k] = $over[$k] }
    return $d
}
function Top($dx) { return @($dx.Causes)[0].Key }
function RoundTrip($d) { return (ConvertTo-Json -InputObject $d -Depth 6 | ConvertFrom-Json) }

$scenarios = [ordered]@{
    '파워 부족: 블루스크린 없이 반복 꺼짐 + 그래픽 오류 직후' = @{
        Expect = 'PSU'
        Data = @{
            Shutdowns = @(1..5 | ForEach-Object { [ordered]@{ T = (T ($_ * 3)); Code = ''; PowerButton = $false } })
            GpuEvents = @(1..3 | ForEach-Object { [ordered]@{ T = (T ($_ * 3) -5); Source = 'Display'; Id = 4101; Xid = $null; Msg = 'TDR' } })
        }
    }
    'VRAM 불량: Xid 48/63 + TDR 블루스크린' = @{
        Expect = 'GPU_HW'
        Data = @{
            GpuEvents = @(
                [ordered]@{ T = (T 2); Source = 'nvlddmkm'; Id = 13; Xid = 48; Msg = 'Xid 48' },
                [ordered]@{ T = (T 4); Source = 'nvlddmkm'; Id = 13; Xid = 63; Msg = 'Xid 63' },
                [ordered]@{ T = (T 6); Source = 'Display'; Id = 4101; Xid = $null; Msg = 'TDR' })
            BugChecks = @([ordered]@{ T = (T 6 10); Code = '0x116' })
        }
    }
    '그래픽 드라이버: 드라이버 설치 직후 TDR 반복' = @{
        Expect = 'GPU_DRIVER'
        Data = @{
            DriverInstalls = @([ordered]@{ T = (T 10); Msg = 'NVIDIA GeForce RTX 4070 driver installed' })
            GpuEvents = @(1..6 | ForEach-Object { [ordered]@{ T = (T (9.5 - $_)); Source = 'Display'; Id = 4101; Xid = $null; Msg = 'TDR' } })
        }
    }
    'RAM 불량: 메모리 진단 실패 + 다양한 블루스크린' = @{
        Expect = 'RAM'
        Data = @{
            BugChecks = @(
                [ordered]@{ T = (T 1); Code = '0x1A' }, [ordered]@{ T = (T 3); Code = '0x50' },
                [ordered]@{ T = (T 5); Code = '0x139' }, [ordered]@{ T = (T 8); Code = '0xA' })
            MemDiag = @([ordered]@{ T = (T 0.5); Id = 1202; Failed = $true; Msg = 'errors detected' })
        }
    }
    'RAM 의심: WHEA 47 + XMP' = @{
        Expect = 'RAM'
        Data = @{
            Whea = @(1..4 | ForEach-Object { [ordered]@{ T = (T $_); Id = 47; Level = 3; Comp = 'Memory'; Msg = 'corrected memory error' } })
            Dimms = @([ordered]@{ Slot = 'A2'; SizeGB = 16; ConfiguredMHz = 6000; RatedMHz = 4800; Maker = 'G.Skill'; Part = 'F5-6000'; DDR = 'DDR5' })
        }
    }
    'CPU 불안정: WHEA 18 + 0x124 + 0x101' = @{
        Expect = 'CPU_OC'
        Data = @{
            Whea = @([ordered]@{ T = (T 2); Id = 18; Level = 2; Comp = 'Processor Core'; Msg = 'fatal' }, [ordered]@{ T = (T 5); Id = 18; Level = 2; Comp = 'Processor Core'; Msg = 'fatal' })
            BugChecks = @([ordered]@{ T = (T 2 3); Code = '0x124' }, [ordered]@{ T = (T 7); Code = '0x101' })
        }
    }
    '디스크 불량: 상태 이상 + 0x7A' = @{
        Expect = 'DISK'
        Data = @{
            Disks = @([ordered]@{ Name = 'WDC HDD'; Media = 'HDD'; Bus = 'SATA'; SizeGB = 2000; Health = 'Warning'; TempC = 40; WearPct = $null; ReadErr = 12 })
            DiskEvents = @(1..6 | ForEach-Object { [ordered]@{ T = (T $_); Source = 'disk'; Id = 153; Msg = 'IO retried' } })
            BugChecks = @([ordered]@{ T = (T 3); Code = '0x7A' })
        }
    }
    '과열: 저부하 GPU 90도 + 꺼짐' = @{
        Expect = 'THERMAL'
        Data = @{
            NvSmi = @([ordered]@{ Name = 'RTX 4070'; Temp = 91; Util = 5; MemUsedMB = 900; MemTotalMB = 12282; PowerW = 40; PowerLimitW = 200; ClockMHz = 2500; Driver = '566.14' })
            Thermal = @(95.0)
        }
    }
    '기타 드라이버: 0x9F, 0xD1' = @{
        Expect = 'DRIVER'
        Data = @{ BugChecks = @([ordered]@{ T = (T 2); Code = '0x9F' }, [ordered]@{ T = (T 9); Code = '0xD1' }) }
    }
}

Write-Host "`n[시나리오: 원인 1순위]" -ForegroundColor Cyan
foreach ($name in $scenarios.Keys) {
    $sc = $scenarios[$name]
    It "$name → $($sc.Expect)" {
        $data = New-Scenario $sc.Data
        $dx = Get-Diagnosis -Data $data
        Assert-Eq (Top $dx) $sc.Expect "원인 순위: $((@($dx.Causes) | ForEach-Object { "$($_.Key)=$($_.Score)" }) -join ', ')"
        $dx2 = Get-Diagnosis -Data (RoundTrip $data)
        Assert-Eq (Top $dx2) $sc.Expect 'JSON 왕복 후에도 같은 결과'
        if ($dx2.Health -ne $dx.Health) {
            $rt = RoundTrip $data
            Write-Host ("      원본: " + ((@($dx.Findings) | ForEach-Object { $_.Title }) -join ' | '))
            Write-Host ("      왕복: " + ((@($dx2.Findings) | ForEach-Object { $_.Title }) -join ' | '))
            Write-Host ("      DriverInstalls 왕복: " + (ConvertTo-Json -InputObject $rt.DriverInstalls -Compress) + ' type=' + $rt.DriverInstalls.GetType().FullName)
            Write-Host ("      GpuEvents[0].T: " + $rt.GpuEvents[0].T + ' type=' + $rt.GpuEvents[0].T.GetType().FullName)
        }
        Assert-Eq $dx2.Health $dx.Health 'JSON 왕복 후 점수 동일'
        Assert ($dx.Health -lt 90) "문제가 있으면 90 미만이어야 함 (현재 $($dx.Health))"
    }
}

Write-Host "`n[정상 PC]" -ForegroundColor Cyan
It '기록 없음 → 점수 100, 원인 없음, 정상 카드' {
    $dx = Get-Diagnosis -Data (New-Scenario @{})
    Assert-Eq $dx.Health 100 '점수'
    Assert-Eq @($dx.Causes).Count 0 '원인 후보'
    Assert-Eq $dx.Findings[0].Level 'ok' '첫 카드'
}
It '빈 데이터(필드 없음)도 오류 없이 분석' {
    $dx = Get-Diagnosis -Data ([pscustomobject]@{ Meta = [pscustomobject]@{ Days = 7 } })
    Assert-Eq $dx.Health 100 '점수'
}
It '전원 버튼 할인은 소수까지 반영 (3회 중 1회 버튼 → 2.3회분)' {
    $d = New-Scenario @{ Shutdowns = @([ordered]@{ T = (T 1); Code = ''; PowerButton = $true }, [ordered]@{ T = (T 2); Code = ''; PowerButton = $false }, [ordered]@{ T = (T 3); Code = ''; PowerButton = $false }) }
    $psu = (@((Get-Diagnosis -Data $d).Causes) | Where-Object Key -eq 'PSU').Score
    Assert-Eq $psu 32 '14 × 2.3 = 32.2 → 32'
}
It '전원 버튼 강제 종료는 파워 점수를 낮춤' {
    $a = Get-Diagnosis -Data (New-Scenario @{ Shutdowns = @(1..3 | ForEach-Object { [ordered]@{ T = (T $_); Code = ''; PowerButton = $false } }) })
    $b = Get-Diagnosis -Data (New-Scenario @{ Shutdowns = @(1..3 | ForEach-Object { [ordered]@{ T = (T $_); Code = ''; PowerButton = $true } }) })
    $pa = (@($a.Causes) | Where-Object Key -eq 'PSU').Score; $pb = (@($b.Causes) | Where-Object Key -eq 'PSU').Score
    Assert ($pa -gt [int]$pb) "버튼 없음 $pa > 버튼 $pb"
}
It '전원 버튼 강제 종료만 여러 번이면 심각(bad)으로 올리지 않고 감점도 작게' {
    $a = Get-Diagnosis -Data (New-Scenario @{ Shutdowns = @(1..3 | ForEach-Object { [ordered]@{ T = (T $_); Code = ''; PowerButton = $false } }) })
    $b = Get-Diagnosis -Data (New-Scenario @{ Shutdowns = @(1..3 | ForEach-Object { [ordered]@{ T = (T $_); Code = ''; PowerButton = $true } }) })
    $fa = @($a.Findings) | Where-Object { $_.Title -match '갑자기 꺼짐' } | Select-Object -First 1
    $fb = @($b.Findings) | Where-Object { $_.Title -match '갑자기 꺼짐' } | Select-Object -First 1
    Assert-Eq $fa.Level 'bad' '진짜 전원 차단 3회는 심각'; Assert-Eq $fb.Level 'warn' '버튼 종료 3회는 주의'
    Assert ([int]$fb.Penalty -lt [int]$fa.Penalty) "감점 $($fb.Penalty) < $($fa.Penalty)"; Assert ($b.Health -gt $a.Health) '점수 덜 깎임'
}
It 'Windows 안정성 지수: 요약·낮으면 안내·보고서 표시 (영어 번역)' {
    Assert ($null -eq (Get-StabilitySummary @())) '기록 없으면 null'
    $sm = Get-StabilitySummary @([ordered]@{ T = '2026-11-12T10:00:00'; V = 8.5 }, [ordered]@{ T = '2026-11-14T10:00:00'; V = 2.1 }, [ordered]@{ T = '2026-11-13T10:00:00'; V = 5.0 })
    Assert-Eq $sm.Latest 2.1 '가장 최근 값(시간순)'; Assert-Eq $sm.Min 2.1 '최저'; Assert-Eq $sm.Count 3 '개수'
    $d = New-Scenario @{ Stability = $sm }; $dx = Get-Diagnosis -Data $d
    Assert (@($dx.Findings | Where-Object { $_.Title -match '안정성 지수 낮음' }).Count -eq 1) '낮으면 안내'
    $ok = Get-Diagnosis -Data (New-Scenario @{ Stability = (Get-StabilitySummary @([ordered]@{ T = '2026-11-14T10:00:00'; V = 9.0 })) })
    Assert (@($ok.Findings | Where-Object { $_.Title -match '안정성 지수' }).Count -eq 0) '높으면 안내 없음'
    $h = New-HtmlReport -Data $d -Dx $dx; Assert ($h -match '안정성 지수</td><td>최근 2.1 / 10') '보고서 표시'
    $old = $script:UiLang; $script:UiLang = 'en'
    try { $he = New-HtmlReport -Data $d -Dx $dx; Assert ($he -match 'Low Windows stability index \(2.1/10\)') '영어 제목'; Assert ($he -match 'latest 2.1 / 10') '영어 표'
        $m = [regex]::Matches($he, '[^<>"]{0,20}[가-힣]+[^<>"]{0,20}'); Assert ($m.Count -eq 0) "한글 남음: $(($m | Select-Object -First 3 | ForEach-Object Value) -join ' | ')" } finally { $script:UiLang = $old }
}
It '요약 복사 버튼: 화면 문구 영어 번역, 요약은 비어 있지 않음' {
    $old = $script:UiLang; $script:UiLang = 'en'
    try {
        Assert-Eq (Tr '요약 복사') 'Copy summary' '버튼'
        Assert ((Tr '요약을 복사했습니다 — 메신저 대화창에 붙여 넣으세요 (Ctrl+V)') -notmatch '[가-힣]') '상태 문구'
        Assert ((Tr '복사하지 못했습니다: Access denied') -notmatch '[가-힣]') '실패 문구'
    } finally { $script:UiLang = $old }
    $d = New-Scenario @{}; Assert ((Get-SummaryText $d (Get-Diagnosis -Data $d)).Length -gt 20) '요약 내용'
    $src = Get-Content -Raw (Join-Path $PSScriptRoot '..\PCCheck.ps1')
    Assert ($src -match '\$copyB\.SetBounds') '배치 계산에 포함 (레이아웃 검사 대상)'
}
It '화면 실패 → 콘솔 재실행: 저장 위치·언어·메모를 그대로 전달 (따옴표·역슬래시 처리)' {
    $a = Get-ConsoleRelaunchArgs -Path 'C:\My Tools\PCCheck.ps1' -Days 60 -OutDir 'D:\보고서 폴더\' -Lang 'en' -Note '홍길동 "게임 중" 꺼짐'
    $j = $a -join ' '
    Assert ($j -match '-File "C:\\My Tools\\PCCheck\.ps1"') "경로 $j"
    Assert ($j -match '-Days 60') '기간'; Assert ($j -match '-Lang en') '언어'
    Assert ($j -match [regex]::Escape('-OutDir "D:\보고서 폴더\\"')) "끝 역슬래시 두 번 (따옴표가 풀리지 않게): $j"
    Assert ($j -match [regex]::Escape('-Note "홍길동 \"게임 중\" 꺼짐"')) "메모 따옴표 이스케이프: $j"
    $b = Get-ConsoleRelaunchArgs -Path 'C:\x.ps1' -Days 30 -OutDir '' -Lang 'ko' -Note ''
    Assert (($b -join ' ') -notmatch '-Note|-OutDir') '빈 값은 넘기지 않음'
}
It '디스크 상태: Unknown 은 고장으로 보지 않음, Warning 은 주의, Unhealthy 는 심각' {
    $mk = { param($h) Get-Diagnosis -Data (New-Scenario @{ Disks = @([ordered]@{ Name = 'D1'; Media = 'SSD'; Bus = 'NVMe'; SizeGB = 500; Health = $h }) }) }
    foreach ($h in 'Unknown', '5', 'Healthy') { Assert (@((& $mk $h).Findings | Where-Object { $_.Category -eq 'DISK' }).Count -eq 0) "$h 는 문제 아님" }
    $w = @((& $mk 'Warning').Findings | Where-Object { $_.Category -eq 'DISK' }); Assert-Eq $w[0].Level 'warn' 'Warning → 주의'
    $b = @((& $mk 'Unhealthy').Findings | Where-Object { $_.Category -eq 'DISK' }); Assert-Eq $b[0].Level 'bad' 'Unhealthy → 심각'
    $old = $script:UiLang; $script:UiLang = 'en'
    try { $e = Tr ("$($w[0].Title) $($w[0].Detail)"); Assert ($e -notmatch '[가-힣]') "영어: $e" } finally { $script:UiLang = $old }
}
It '덤프와 이벤트의 같은 블루스크린은 한 번만 셈' {
    $dx = Get-Diagnosis -Data (New-Scenario @{
        BugChecks = @([ordered]@{ T = (T 1); Code = '0x116' })
        Dumps = @([ordered]@{ T = (T 1 2); Name = 'a.dmp'; SizeKB = 900; Code = '0x116' })
        Shutdowns = @([ordered]@{ T = (T 1 1); Code = '0x116'; PowerButton = $false }) })
    Assert-Eq $dx.Counts.Bsod 1 '블루스크린 수'
    Assert-Eq $dx.Counts.PowerLoss 0 '전원 끊김 수'
}

It '가상 머신에서는 RAM 혼용 경고 생략, 안내 표시' {
    $over = @{ Dimms = @([ordered]@{ Slot = 'A'; SizeGB = 8; Part = 'X' }, [ordered]@{ Slot = 'B'; SizeGB = 16; Part = 'Y' }) }
    $d = New-Scenario $over; $d.System.IsVM = $true
    $dx = Get-Diagnosis -Data $d
    Assert (-not (@($dx.Findings) | Where-Object { $_.Title -match '섞어' })) '혼용 경고 없어야 함'
    Assert (@($dx.Findings) | Where-Object { $_.Title -match '가상 머신' }) '가상 머신 안내'
    $d2 = New-Scenario $over
    Assert (@((Get-Diagnosis -Data $d2).Findings) | Where-Object { $_.Title -match '섞어' }) '실제 PC 에서는 혼용 경고'
}
It 'AMD/Intel: Windows GPU 센서 고온 판정 (NVIDIA 정보 없을 때만)' {
    $d = New-Scenario @{ GpuSensors = @([ordered]@{ Index = 0; TempC = 94; FanRPM = 3000 }) }
    Assert (@((Get-Diagnosis -Data $d).Findings) | Where-Object { $_.Title -match '94' }) '고온 경고'
    $d2 = New-Scenario @{ GpuSensors = @([ordered]@{ Index = 0; TempC = 60; FanRPM = 1000 }) }
    Assert (-not (@((Get-Diagnosis -Data $d2).Findings) | Where-Object { $_.Title -match '그래픽카드 온도' })) '정상 온도'
}
It 'GPU 센서 읽기는 지원 안 되는 환경에서도 오류 없이 빈 결과' {
    $r = @(Get-GpuSensors); Assert ($r.Count -ge 0) 'ok'
}
It '노하드(iSCSI·가상 디스크만) 감지 → 블랙박스 안내, 기록 있으면 참고로' {
    $d = New-Scenario @{ Disks = @([ordered]@{ Name = 'CCBoot iSCSI Disk'; Media = 'Unspecified'; Bus = 'iSCSI'; SizeGB = 120; Health = 'Healthy' }) }
    $f = @((Get-Diagnosis -Data $d).Findings | Where-Object { $_.Title -match '노하드' })
    Assert-Eq $f.Count 1 '감지'; Assert-Eq $f[0].Level 'warn' '블랙박스 없으면 경고'
    $d.Blackbox = @([ordered]@{ Level = 'ok'; Title = 'x'; Detail = 'y' })
    Assert-Eq @((Get-Diagnosis -Data $d).Findings | Where-Object { $_.Title -match '노하드' })[0].Level 'info' '블랙박스 있으면 참고'
    Assert (-not (@((Get-Diagnosis -Data (New-Scenario @{})).Findings) | Where-Object { $_.Title -match '노하드' })) '일반 NVMe PC 는 아님'
    $vm = New-Scenario @{ Disks = @([ordered]@{ Name = 'Msft Virtual Disk'; Bus = 'Virtual'; Health = 'Healthy' }) }; $vm.System.IsVM = $true
    Assert (-not (@((Get-Diagnosis -Data $vm).Findings) | Where-Object { $_.Title -match '노하드' })) '가상 머신은 제외'
    $script:UiLang = 'en'; try { Assert ((Tr "$($f[0].Title) $($f[0].Detail)") -notmatch '[가-힣]') '영어' } finally { $script:UiLang = 'ko' }
}
It '덤프 저장 꺼짐·페이지 파일 없음 안내' {

    $d = New-Scenario @{}; $d.System.CrashDump = 0; $d.System.PageFiles = 0
    $t = @((Get-Diagnosis -Data $d).Findings | ForEach-Object { $_.Title })
    Assert ($t -match '덤프 저장이 꺼져') '덤프'; Assert ($t -match '페이지 파일') '페이지 파일'
    $d2 = New-Scenario @{}; $d2.System.CrashDump = 7; $d2.System.PageFiles = 1
    Assert (-not (@((Get-Diagnosis -Data $d2).Findings | ForEach-Object { $_.Title }) -match '덤프 저장|페이지 파일')) '정상 설정은 안내 없음'
}
It '단일 항목 목록 (5.1 배열 풀림 회귀 방지)' {

    $d = RoundTrip (New-Scenario @{ Whea = @([ordered]@{ T = (T 1); Id = 47; Level = 3; Comp = 'Memory'; Msg = 'x' }); DriverInstalls = @([ordered]@{ T = (T 3); Msg = 'NVIDIA' }); GpuEvents = @([ordered]@{ T = (T 2); Source = 'Display'; Id = 4101; Xid = $null; Msg = 'TDR' }) })
    $dx = Get-Diagnosis -Data $d
    Assert-Eq $dx.Counts.Whea 1 'WHEA 1건'; Assert-Eq $dx.Counts.Gpu 1 'GPU 1건'
    Assert (@($dx.Findings) | Where-Object { $_.Title -match '설치 직후' }) '드라이버 설치 직후 판정'
}

It '권장 파워 용량: Ti·SUPER·XT 변형은 기본 모델보다 먼저, 최신 모델 포함' {
    $cases = @(@('NVIDIA GeForce RTX 3080 Ti', 350), @('NVIDIA GeForce RTX 3080', 320), @('NVIDIA GeForce RTX 3070 Ti', 290), @('NVIDIA GeForce RTX 3060 Ti', 200),
               @('NVIDIA GeForce RTX 4070 SUPER', 220), @('NVIDIA GeForce RTX 5070 Ti', 300), @('NVIDIA GeForce RTX 5060', 145), @('AMD Radeon RX 9070 XT', 304),
               @('AMD Radeon RX 6800 XT', 300), @('AMD Radeon RX 6800', 250), @('AMD Radeon RX 7900 XTX', 355), @('Intel(R) Arc(TM) B580 Graphics', 190), @('Intel(R) Arc(TM) A770 Graphics', 225))
    foreach ($c in $cases) {
        $d = New-Scenario @{}; $d.Gpus = @([ordered]@{ Name = $c[0]; Vendor = $(if ($c[0] -match 'NVIDIA') { 'NVIDIA' } elseif ($c[0] -match 'AMD') { 'AMD' } else { 'Intel' }) })
        Assert-Eq (Get-PsuEstimate $d).GpuW $c[1] $c[0]
    }
}
It '권장 파워 용량: Intel Core Ultra CPU 전력 반영' {
    foreach ($c in @(@('Intel(R) Core(TM) Ultra 9 285K', 253), @('Intel(R) Core(TM) Ultra 7 265KF', 253), @('Intel(R) Core(TM) Ultra 5 245K', 160), @('Intel(R) Core(TM) Ultra 7 155H', 125), @('Intel(R) Core(TM) Ultra 5 125U', 95), @('AMD Ryzen 7 9800X3D 8-Core Processor', 120))) {
        $d = New-Scenario @{}; $d.System.CPU = $c[0]; Assert-Eq (Get-PsuEstimate $d).CpuW $c[1] $c[0]
    }
}
It '권장 파워 용량: 측정값 우선, 모델 대표값, 파워 의심 시 경고' {
    $d = New-Scenario @{}; $d.System.CPU = 'Intel(R) Core(TM) i9-14900K'; $d.Gpus = @([ordered]@{ Name = 'NVIDIA GeForce RTX 4090'; Vendor = 'NVIDIA' })
    $e = Get-PsuEstimate $d; Assert-Eq $e.GpuW 450 'RTX 4090 대표값'; Assert-Eq $e.CpuW 253 'i9 K'; Assert-Eq $e.RecommendW 1050 '(450+253+75)×1.3=1011 → 1050'
    $d.NvSmi = @([ordered]@{ PowerLimitW = 600 }); Assert-Eq (Get-PsuEstimate $d).GpuW 600 '측정값 우선'
    $d2 = New-Scenario @{}; $d2.Gpus = @([ordered]@{ Name = 'Intel(R) UHD Graphics 770'; Vendor = 'Intel' })
    Assert-Eq (Get-PsuEstimate $d2).GpuW 0 '내장 그래픽은 계산 안 함'
    Assert (-not (@((Get-Diagnosis -Data $d2).Findings) | Where-Object { $_.Title -match '권장 파워' })) '내장 그래픽이면 표시 없음'
    $f = @((Get-Diagnosis -Data (New-Scenario @{})).Findings | Where-Object { $_.Title -match '권장 파워' })[0]
    Assert-Eq $f.Level 'info' '평소엔 참고'
    $f2 = @((Get-Diagnosis -Data (New-Scenario $scenarios['파워 부족: 블루스크린 없이 반복 꺼짐 + 그래픽 오류 직후'].Data)).Findings | Where-Object { $_.Title -match '권장 파워' })[0]
    Assert-Eq $f2.Level 'warn' '파워 의심이면 경고'
    $script:UiLang = 'en'; try { Assert ((Tr "$($f.Title) $($f.Detail)") -notmatch '[가-힣]') "영어: $(Tr $f.Detail)" } finally { $script:UiLang = 'ko' }
}

It '다음 정밀 검사 추천 (원인별 도구, 노하드면 블랙박스)' {
    Assert-Eq (Get-RecommendedTool (Get-Diagnosis -Data (New-Scenario $scenarios['VRAM 불량: Xid 48/63 + TDR 블루스크린'].Data))) 'vram' 'VRAM'
    Assert-Eq (Get-RecommendedTool (Get-Diagnosis -Data (New-Scenario $scenarios['RAM 불량: 메모리 진단 실패 + 다양한 블루스크린'].Data))) 'ram' 'RAM'
    Assert-Eq (Get-RecommendedTool (Get-Diagnosis -Data (New-Scenario $scenarios['파워 부족: 블루스크린 없이 반복 꺼짐 + 그래픽 오류 직후'].Data))) 'blackbox' '파워'
    Assert-Eq (Get-RecommendedTool (Get-Diagnosis -Data (New-Scenario @{}))) '' '정상 PC 는 추천 없음'
    $dl = New-Scenario @{ Disks = @([ordered]@{ Name = 'iSCSI'; Bus = 'iSCSI'; Health = 'Healthy' }) }
    Assert-Eq (Get-RecommendedTool (Get-Diagnosis -Data $dl)) 'blackbox' '노하드'
    foreach ($k in 'vram', 'ram', 'blackbox', 'bsv') { Assert (@($script:ExternalTools | Where-Object { $_.Key -eq $k }).Count -eq 1) "도구 존재: $k" }
}

Write-Host "`n[유틸]" -ForegroundColor Cyan
It '그래픽 드라이버 설치 기록 판별 (칩셋·오디오·SATA 제외)' {
    foreach ($y in @(
        'Driver Management concluded the process to install driver nv_dispi.inf_amd64_1f2e3d for Device Instance ID PCI\VEN_10DE&DEV_2786 with the following status: 0x0.',
        'Driver Management concluded the process to install driver u0401234.inf_amd64_aa for Device Instance ID PCI\VEN_1002&DEV_744C with the following status: 0x0.',
        'Driver Management concluded the process to install driver iigd_dch.inf_amd64_bb for Device Instance ID PCI\VEN_8086&DEV_A780',
        'NVIDIA GeForce RTX 4070 driver installed', 'Intel(R) Arc(TM) A770 Graphics')) { Assert (Test-DisplayDriverMessage $y) "그래픽: $y" }
    foreach ($n in @(
        'Driver Management concluded the process to install driver hdaudio.inf for NVIDIA High Definition Audio',
        'Driver Management concluded the process to install driver amd_sata.inf for AMD SATA Controller',
        'Driver Management concluded the process to install driver amdgpio2.inf for AMD GPIO Controller',
        'Driver Management concluded the process to install driver nvhda.inf for Device Instance ID HDAUDIO\FUNC_01&VEN_10DE (NVIDIA Audio)',
        'Driver Management concluded the process to install driver netrtwlane.inf for Realtek Wi-Fi Architecture', '', $null)) { Assert (-not (Test-DisplayDriverMessage $n)) "그래픽 아님: $n" }
}
It 'GitHub 릴리스에서 Windows 파일 고르기' {
    $mk = { param($n) [pscustomobject]@{ name = $n } }
    Assert-Eq (Select-WindowsAsset @((& $mk 'memtest_vulkan-v0.5.0_DesktopLinux_X86_64.tar.xz'), (& $mk 'memtest_vulkan-v0.5.0.zip'))).name 'memtest_vulkan-v0.5.0.zip' 'zip'
    Assert-Eq (Select-WindowsAsset @((& $mk 'memtest_vulkan-v0.6.0-linux-x86_64.zip'), (& $mk 'memtest_vulkan-v0.6.0-windows-x86_64.zip'), (& $mk 'memtest_vulkan-v0.6.0-linux-aarch64.zip'))).name 'memtest_vulkan-v0.6.0-windows-x86_64.zip' 'windows 표시'
    Assert-Eq (Select-WindowsAsset @((& $mk 'memtest_vulkan.exe'), (& $mk 'memtest_vulkan-linux.zip'))).name 'memtest_vulkan.exe' 'exe 우선'
    Assert ($null -eq (Select-WindowsAsset @((& $mk 'a-linux.tar.xz')))) '없으면 null'
}


It 'Format-BugCode 정규화' {
    Assert-Eq (Format-BugCode '0x00000116') '0x116' 'hex 문자열'
    Assert-Eq (Format-BugCode 278) '0x116' '정수'
    Assert-Eq (Format-BugCode '278') '0x116' '10진 문자열'
    Assert-Eq (Format-BugCode 0) '' '0'
    Assert-Eq (Format-BugCode $null) '' 'null'
    Assert-Eq (Format-BugCode '0x1a') '0x1A' '대소문자'
}
It '미니덤프 헤더에서 코드 읽기 (64/32비트)' {
    $p = Join-Path ([IO.Path]::GetTempPath()) ('t' + [guid]::NewGuid().ToString('N') + '.dmp')
    $b = New-Object byte[] 0x80; [Text.Encoding]::ASCII.GetBytes('PAGEDU64').CopyTo($b, 0); [BitConverter]::GetBytes([uint32]0x124).CopyTo($b, 0x38)
    [IO.File]::WriteAllBytes($p, $b); Assert-Eq (Read-MinidumpBugCode $p) '0x124' '64bit'
    $b = New-Object byte[] 0x80; [Text.Encoding]::ASCII.GetBytes('PAGEDUMP').CopyTo($b, 0); [BitConverter]::GetBytes([uint32]0x50).CopyTo($b, 0x20)
    [IO.File]::WriteAllBytes($p, $b); Assert-Eq (Read-MinidumpBugCode $p) '0x50' '32bit'
    [IO.File]::WriteAllBytes($p, [byte[]](1, 2, 3)); Assert-Eq (Read-MinidumpBugCode $p) '' '손상 파일'
    Remove-Item $p
}
It 'Get-FirstLine 자르기/빈 줄 건너뛰기' {
    Assert-Eq (Get-FirstLine "`r`n  hello`r`nworld") 'hello' '첫 줄'
    Assert ((Get-FirstLine ('x' * 500)).Length -le 221) '길이 제한'
}
It '모든 블루스크린 가중치 키가 원인 목록에 있음' {
    foreach ($k in $script:BugDb.Keys) { foreach ($w in $script:BugDb[$k].W.Keys) { Assert ($script:Causes.Contains($w)) "$k → $w" } }
    foreach ($k in $script:XidDb.Keys) { foreach ($w in $script:XidDb[$k].W.Keys) { Assert ($script:Causes.Contains($w)) "Xid $k → $w" } }
    foreach ($k in $script:Causes.Keys) { Assert ($script:Playbook.ContainsKey($k)) "해결 순서 누락: $k" }
}

Write-Host "`n[보고서]" -ForegroundColor Cyan
It 'HTML/JSON 저장, 특수문자 이스케이프, 타임라인' {
    $data = New-Scenario $scenarios['VRAM 불량: Xid 48/63 + TDR 블루스크린'].Data
    $data.System.CPU = '<script>alert(1)</script> & CPU'
    $dx = Get-Diagnosis -Data $data
    $r = Save-Results -Data $data -Dx $dx -Dir $OutDir
    Assert (Test-Path $r.Html) 'html 존재'; Assert (Test-Path $r.Json) 'json 존재'; Assert (Test-Path $r.Txt) 'txt 요약 존재'
    $tx = [IO.File]::ReadAllText($r.Txt); Assert ($tx -match '상태 점수') 'txt 내용'; Assert ($tx -match '지금 할 일') '다음 행동'
    $h = [IO.File]::ReadAllText($r.Html)
    Assert ($h -notmatch '<script>alert') '스크립트 주입 차단'
    Assert ($h -match '&lt;script&gt;') '이스케이프됨'
    Assert ($h -match '<svg viewBox') '타임라인 SVG'
    Assert ($h -match '그래픽카드 하드웨어/VRAM') '원인 표시'
    Assert ($h -match 'copySummary') '요약 복사 버튼'
    Assert ($h -match '지금 할 일') '다음 행동 안내'

    $bytes = [IO.File]::ReadAllBytes($r.Html); Assert ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) 'UTF-8 BOM'
    $j = Get-Content -Raw -Encoding UTF8 $r.Json | ConvertFrom-Json
    Assert-Eq (Top (Get-Diagnosis -Data $j)) 'GPU_HW' '저장된 JSON 재분석'
}
It '증상·고객 메모: 보고서 상단·요약에 표시, HTML 이스케이프' {
    $d = New-Scenario @{}; $d.Meta.Note = '홍길동 / 게임 중 꺼짐 <b>x</b>'
    $dx = Get-Diagnosis -Data $d
    $h = New-HtmlReport -Data $d -Dx $dx
    Assert ($h -match "class='note'") '메모 표시'; Assert ($h -match '&lt;b&gt;x&lt;/b&gt;') '이스케이프'; Assert ($h -notmatch '<b>x</b>') '태그 주입 없음'
    Assert ((Get-SummaryText $d $dx) -match '메모: 홍길동') '요약 포함'
    Assert ((New-HtmlReport -Data (New-Scenario @{}) -Dx $dx) -notmatch "class='note'") '메모 없으면 표시 안 함'
    $script:UiLang = 'en'
    try { $he = New-HtmlReport -Data $d -Dx $dx; Assert ($he -match 'Note: 홍길동 / 게임 중 꺼짐') "영어에서도 메모 원문 유지"; Assert ((Get-SummaryText $d $dx) -match 'Note: 홍길동 / 게임 중 꺼짐') '요약도 원문' }
    finally { $script:UiLang = 'ko' }
}
It '영어 모드: 저장 파일 이름에 한글 없음 (PCCheck_...)' {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ("pcc_en_" + [guid]::NewGuid().ToString('N'))
    $old = $script:UiLang; $script:UiLang = 'en'
    try {
        $d = New-Scenario @{}; $r = Save-Results -Data $d -Dx (Get-Diagnosis -Data $d) -Dir $dir
        foreach ($f in $r.Html, $r.Json, $r.Txt) { Assert ((Split-Path $f -Leaf) -match '^PCCheck_\d{8}_\d{6}\.') "영문 이름 $f"; Assert (Test-Path $f) '파일 존재' }
    } finally { $script:UiLang = $old }
    Assert ((Get-OutputPrefix) -eq 'PC진단') '한국어는 기존 이름 유지'
}
It '인쇄용 점검 확인란: 화면에서는 숨기고 인쇄 시에만 표시' {
    $h = New-HtmlReport -Data (New-Scenario @{}) -Dx (Get-Diagnosis -Data (New-Scenario @{}))
    Assert ($h -match 'class="sign"') '확인란'; Assert ($h -match '\.sign\{display:none') '화면 숨김'; Assert ($h -match '@media print\{\.sign\{display:flex\}') '인쇄 표시'
    Assert ($h -match '점검자 서명') '서명 칸'
}
It '요약 텍스트에 핵심 정보 포함' {
    $data = New-Scenario $scenarios['파워 부족: 블루스크린 없이 반복 꺼짐 + 그래픽 오류 직후'].Data
    $t = Get-SummaryText $data (Get-Diagnosis -Data $data)
    Assert ($t -match '상태 점수') '점수'; Assert ($t -match '파워') '원인'; Assert ($t -match 'RTX 4070') 'GPU'
}
It '기간 365일 · 대량 이벤트에서도 빠르게 동작' {
    $many = @(1..2000 | ForEach-Object { [ordered]@{ T = (T ($_ % 360)); Source = 'Display'; Id = 4101; Xid = $null; Msg = 'TDR' } })
    $data = New-Scenario @{ GpuEvents = $many }; $data.Meta.Days = 365
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $dx = Get-Diagnosis -Data $data; [void](New-HtmlReport -Data $data -Dx $dx)
    Assert ($sw.Elapsed.TotalSeconds -lt 30) "소요 $($sw.Elapsed.TotalSeconds)s"
}

It '지난 검사 대비: 이후 새 문제 집계와 보고서 표시, 이력 저장' {
    $old = $script:WorkDir
    $script:WorkDir = Join-Path $OutDir 'wd'
    try {
        $d1 = New-Scenario @{ Shutdowns = @([ordered]@{ T = (T 10); Code = ''; PowerButton = $false }) }
        $d1.Meta.Created = Format-T $now.AddDays(-5)
        $dx1 = Get-Diagnosis -Data $d1
        [void](Save-Results -Data $d1 -Dx $dx1 -Dir $OutDir -Track)
        Assert-Eq @(Read-History).Count 1 '이력 1건'
        # 5일 전 검사 이후 2건 새로 발생
        $d2 = New-Scenario @{ Shutdowns = @([ordered]@{ T = (T 10); Code = ''; PowerButton = $false }, [ordered]@{ T = (T 2); Code = ''; PowerButton = $false }); GpuEvents = @([ordered]@{ T = (T 1); Source = 'Display'; Id = 4101; Xid = $null; Msg = 'x' }) }
        $dx2 = Get-Diagnosis -Data $d2
        $r = Save-Results -Data $d2 -Dx $dx2 -Dir $OutDir -Track
        Assert-Eq $dx2.Previous.NewTotal 2 '새 문제 2건'
        Assert-Eq $dx2.Previous.New.PowerLoss 1 '꺼짐 1'
        Assert ([IO.File]::ReadAllText($r.Html) -match '이후 새 문제 2 건') '보고서 표시'
        # 새 문제 없음
        $d3 = New-Scenario @{}; $d3.Meta.Created = Format-T $now.AddMinutes(5)
        $dx3 = Get-Diagnosis -Data $d3
        $r3 = Save-Results -Data $d3 -Dx $dx3 -Dir $OutDir -Track
        Assert ([IO.File]::ReadAllText($r3.Html) -match '새로 생긴 문제 없음') '없음 표시'
        Assert-Eq @(Read-History).Count 3 '이력 3건'
    } finally { $script:WorkDir = $old }
}

It '백그라운드 실행 공간에 필요한 설정값이 모두 전달됨 (GPU 센서 코드·단계 계획 등)' {
    # 스크립트 수준 설정 중 함수 안에서 $script: 로 쓰는 것은 모두 SharedVars 에 있어야 함 (분석·보고서 전용 제외)
    $src = [IO.File]::ReadAllText((Join-Path $root 'PCCheck.ps1'))
    $rs = New-PCRunspace
    try {
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript('[pscustomobject]@{ Gpu = [bool]$script:GpuPerfSource; Stages = @($script:StagePlan).Count; Ram = [bool]$script:RamTestSource; Pin = [bool]$script:MemtestPinned; Cols = [bool]$script:BlackboxColsV1 }')
        $r = @($ps.Invoke())[0]; $ps.Dispose()
        Assert $r.Gpu 'GPU 센서 코드'; Assert-Eq $r.Stages 6 '단계 계획'; Assert $r.Ram 'RAM 검사 코드'; Assert $r.Pin '고정 버전'; Assert $r.Cols 'v1 열'
    } finally { $rs.Dispose() }
    Assert ($src -notmatch "foreach \(\`$v in 'AppName'") '설정 목록이 한 곳(SharedVars)에만 있음'
}
It '백그라운드 수집: 진행 상황 전달 후 데이터 반환' {
    $job = Start-CollectAsync -Days 3
    $sw = [Diagnostics.Stopwatch]::StartNew(); $seen = 0
    while (-not $job.Sync.Done -and $sw.Elapsed.TotalSeconds -lt 120) { if ($job.Sync.I -gt $seen) { $seen = $job.Sync.I }; Start-Sleep -Milliseconds 100 }
    Assert $job.Sync.Done '120초 안에 완료'
    $data = Complete-CollectAsync $job
    Assert ($null -eq $job.Sync.Error) "오류: $($job.Sync.Error)"
    Assert ($null -ne $data) '데이터 반환'
    Assert-Eq $job.Sync.N 12 '단계 수 전달'
    Assert-Eq $data.Meta.Days 3 '기간 전달'
    [void](Get-Diagnosis -Data $data)
}

Write-Host "`n[블랙박스]" -ForegroundColor Cyan
function New-BbFile([string]$name, [object[]]$rows, [switch]$Stop, [string]$Tail) {
    $p = Join-Path $OutDir $name
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $l = @('# PCCheck blackbox,v1,TEST,2026-11-14T10:00:00,2.1.0', $script:BlackboxColsV1)
    $t = Get-Date '2026-11-14T10:00:00'
    foreach ($r in $rows) { $t = $t.AddSeconds(2); $l += ('{0},{1},40,{2},{3},{4},2500,3000,{5},{6},{7}' -f (Format-T $t), $r[0], $r[1], $r[2], $r[3], $r[4], $r[5], $r[6]) }
    if ($Stop) { $l += ('{0},,,,,,,,,,STOP' -f (Format-T $t.AddSeconds(2))) }
    if ($Tail) { $l += $Tail }
    [IO.File]::WriteAllLines($p, [string[]]$l); return $p
}
It '갑자기 끊김 + 고부하 + 정상 온도 → 파워' {
    $p = New-BbFile 'a.csv' (@(1..20 | ForEach-Object { ,@(100, 72, 99, 280, 1, 1, '') }))
    $a = Read-BlackboxAnalysis $p
    Assert $a.Abrupt '끊김'; Assert-Eq $a.Cause 'PSU' '원인'; Assert-Eq $a.Level 'bad' '수준'
}
It '갑자기 끊김 + 고온 → 과열' {
    $p = New-BbFile 'b.csv' (@(1..10 | ForEach-Object { ,@(30, (80 + $_), 95, 250, 0, 1, '') }))
    Assert-Eq (Read-BlackboxAnalysis $p).Cause 'THERMAL' '원인'
}
It '정상 종료 + 오류 기록 → 경고, 정상 종료 무오류 → 이상 없음' {
    $p = New-BbFile 'c.csv' (@(@(90, 70, 99, 250, 1, 1, ''), @(90, 70, 99, 250, 1, 1, 'Xid 79 ; WHEA 18'))) -Stop
    $a = Read-BlackboxAnalysis $p; Assert-Eq $a.Level 'warn' '경고'; Assert-Eq $a.Cause 'GPU_HW' 'GPU'; Assert-Eq $a.Events['Xid 79'] 1 '이벤트'
    $p2 = New-BbFile 'd.csv' (@(1..30 | ForEach-Object { ,@(100, 70, 99, 250, 1, 1, '') })) -Stop
    Assert-Eq (Read-BlackboxAnalysis $p2).Level 'ok' '정상'
}
It '전원 차단으로 잘린 마지막 줄은 무시' {
    $p = New-BbFile 'e.csv' (@(1..5 | ForEach-Object { ,@(100, 70, 99, 250, 1, 1, '') })) -Tail '2026-11-14T10:01:00,10'
    $a = Read-BlackboxAnalysis $p; Assert-Eq $a.Rows 5 '행 수'; Assert $a.Abrupt '끊김'
}
It '블랙박스 결과가 진단·보고서에 반영' {
    $a = Read-BlackboxAnalysis (New-BbFile 'f.csv' (@(1..20 | ForEach-Object { ,@(100, 72, 99, 280, 1, 1, '') })))
    $d = New-Scenario @{ Blackbox = @($a) }
    $dx = Get-Diagnosis -Data $d
    Assert-Eq (Top $dx) 'PSU' '파워 1순위'
    Assert ((New-HtmlReport -Data $d -Dx $dx) -match '블랙박스 기록') '보고서 표시'
    Assert-Eq (Top (Get-Diagnosis -Data (RoundTrip $d))) 'PSU' 'JSON 왕복'
}
function New-Bb2File([string]$name, [object[]]$rows, [switch]$Stop) {
    # v2 형식: 단계·CPU 성능·감속 원인·RAM 오류 포함. 행: @(Stage, CpuPct, CpuPerf, GpuT, GpuUtil, GpuW, Throttle, RamErr, Event)
    $p = Join-Path $OutDir $name
    $l = @('# PCCheck blackbox,v2,TEST,2026-11-14T10:00:00,2.1.0', $script:BlackboxCols)
    $t = Get-Date '2026-11-14T10:00:00'
    foreach ($r in $rows) { $t = $t.AddSeconds(1); $ge = $(if ($r.Count -gt 9) { $r[9] } else { '' }); $l += ('{0},{1},{2},{3},40,45,{4},{5},{6},2500,3000,{7},1,1,0,{8},{10},{9}' -f (Format-T $t), $r[0], $r[1], $r[2], $r[3], $r[4], $r[5], $r[6], $r[7], $r[8], $ge) }
    if ($Stop) { $l += ((@((Format-T $t.AddSeconds(1))) + @('') * ($script:BlackboxCols.Split(',').Count - 2) + @('STOP')) -join ',') }
    [IO.File]::WriteAllLines($p, [string[]]$l); return $p
}
function Rep($n, $row) { return @(1..$n | ForEach-Object { , $row }) }
It '블랙박스: 긴 기록(2만 줄)도 빠르게 분석, 한 줄 기록도 정상' {
    $p = Join-Path $OutDir 'bb_long.csv'
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# PCCheck blackbox,v2,TEST,2026-11-14T10:00:00,2.2.0'); [void]$sb.AppendLine($script:BlackboxCols)
    $t = Get-Date '2026-11-14T10:00:00'
    for ($i = 0; $i -lt 20000; $i++) { [void]$sb.AppendLine(('{0},manual,50,99,40,45,70,90,250,2500,3000,,1,1,0,0,0,' -f (Format-T $t.AddSeconds($i)))) }
    [IO.File]::WriteAllText($p, $sb.ToString())
    $sw = [Diagnostics.Stopwatch]::StartNew(); $a = Read-BlackboxAnalysis $p; $sw.Stop()
    Assert-Eq $a.Rows 20000 '줄 수'; Assert-Eq $a.LastStage 'manual' '마지막 단계'
    Assert ($sw.Elapsed.TotalSeconds -lt 30) "분석 시간 $([int]$sw.Elapsed.TotalSeconds)초"
    $one = New-Bb2File 'bb_one.csv' @(, @('cpu', 90, 99, 60, 10, 100, '', 0, ''))
    $b = Read-BlackboxAnalysis $one; Assert-Eq $b.Rows 1 '한 줄'; Assert-Eq $b.LastStage 'cpu' '한 줄 단계'
}
It '상담용 요약: 블랙박스 판정·지난 검사 대비 포함 (영어 번역)' {
    $bbp = New-Bb2File 'bb_sum.csv' (Rep 10 @('full', 95, 99, 80, 99, 300, '', 0, ''))
    $d = New-Scenario @{ Blackbox = @(Read-BlackboxAnalysis $bbp) }; $dx = Get-Diagnosis -Data $d
    $dx.Previous = [ordered]@{ Created = '2026-11-10T09:00:00'; Health = 60; New = @{}; NewTotal = 2 }
    $t = Get-SummaryText $d $dx
    Assert ($t -match '블랙박스\(최근\): ') "블랙박스 줄: $t"; Assert ($t -match '지난 검사\(2026-11-10 09:00:00\) 이후 새 문제 2 건') '대비 줄'
    $dx.Previous.NewTotal = 0; Assert ((Get-SummaryText $d $dx) -match '이후 새 문제 없음') '없음'
    $old = $script:UiLang; $script:UiLang = 'en'
    try { $e = Get-SummaryText $d $dx; Assert ($e -notmatch '[가-힣]') "영어 한글 남음: $(([regex]::Matches($e, '.{0,15}[가-힣]+.{0,15}') | Select-Object -First 3 | ForEach-Object Value) -join ' | ')"; Assert ($e -match 'No new problems since the last scan') '영문' } finally { $script:UiLang = $old }
}
It '단계 계획: 경과 시간별 단계와 출렁임 부하' {
    $g = Get-StageAt $script:StagePlan 0; Assert-Eq $g.Key 'idle' '시작'; Assert (-not $g.Cpu) '대기는 부하 없음'
    $g = Get-StageAt $script:StagePlan 130; Assert-Eq $g.Key 'cpu' 'CPU'; Assert $g.Cpu 'CPU 켬'
    $g = Get-StageAt $script:StagePlan (120 + 360 + 10); Assert-Eq $g.Key 'ram' 'RAM'; Assert $g.Ram 'RAM 켬'
    $pulse0 = 120 + 360 * 3 + 480
    Assert (Get-StageAt $script:StagePlan ($pulse0 + 1)).Cpu '출렁임 켬'
    Assert (-not (Get-StageAt $script:StagePlan ($pulse0 + 11)).Cpu) '출렁임 끔'
    Assert (Get-StageAt $script:StagePlan 99999).Done '완료'
    Assert-Eq (Get-StageAt $script:StagePlan 0).TotalSec 1920 '전체 32분'
}
It '단계별: 출렁임에서 꺼짐 → 파워 품질 / 전체 부하 → 파워 용량 / GPU 단독 → 그래픽카드' {
    $rows = (Rep 5 @('idle', 3, 100, 40, 1, 30, '', 0, '')) + (Rep 5 @('cpu', 100, 98, 45, 1, 35, '', 0, '')) + (Rep 5 @('full', 100, 97, 70, 99, 280, 'PWRCAP', 0, '')) + (Rep 5 @('pulse', 100, 97, 72, 99, 290, '', 0, ''))
    $a = Read-BlackboxAnalysis (New-Bb2File 'p.csv' $rows)
    Assert $a.Abrupt '끊김'; Assert-Eq $a.LastStage 'pulse' '단계'; Assert-Eq $a.Cause 'PSU' '파워'; Assert ($a.Title -match '출렁임') '제목'
    Assert-Eq @($a.Stages).Count 4 '단계 요약'
    $a2 = Read-BlackboxAnalysis (New-Bb2File 'q.csv' ((Rep 5 @('cpu', 100, 98, 45, 1, 35, '', 0, '')) + (Rep 3 @('full', 100, 97, 70, 99, 280, '', 0, ''))))
    Assert ($a2.Title -match '전체 부하') '전체'; Assert-Eq $a2.Cause 'PSU' '파워'
    $a3 = Read-BlackboxAnalysis (New-Bb2File 'r.csv' (Rep 4 @('gpu', 5, 100, 75, 99, 250, '', 0, '')))
    Assert-Eq $a3.Cause 'GPU_HW' 'GPU'
    $a4 = Read-BlackboxAnalysis (New-Bb2File 's.csv' (Rep 4 @('cpu', 100, 98, 50, 1, 30, '', 0, '')))
    Assert-Eq $a4.Cause 'CPU_OC' 'CPU'
}
It 'RAM 검사 오류 → RAM (꺼지지 않아도), 감속 신호·CPU 스로틀링 메모' {
    $a = Read-BlackboxAnalysis (New-Bb2File 't.csv' ((Rep 3 @('ram', 50, 100, 40, 1, 30, '', 0, '')) + (Rep 3 @('ram', 50, 100, 40, 1, 30, '', 2, ''))) -Stop)
    Assert-Eq $a.Level 'bad' '위험'; Assert-Eq $a.Cause 'RAM' 'RAM'; Assert-Eq $a.RamErrors 2 '오류 수'
    $a2 = Read-BlackboxAnalysis (New-Bb2File 'u.csv' (Rep 6 @('gpu', 5, 100, 70, 99, 250, 'HWSLOW+PBRAKE', 0, '')) -Stop)
    Assert-Eq $a2.Level 'warn' '경고'; Assert ($a2.Throttle -contains 'HWSLOW') '감속'; Assert ($a2.Detail -match '하드웨어 감속') '메모'
    $a3 = Read-BlackboxAnalysis (New-Bb2File 'v.csv' (Rep 6 @('cpu', 100, 45, 60, 1, 30, '', 0, '')) -Stop)
    Assert ($a3.Detail -match '클럭') '스로틀링'; Assert-Eq $a3.Cause 'THERMAL' '과열'
    $all = (Rep 2 @('idle', 3, 100, 40, 1, 30, '', 0, '')) + (Rep 2 @('cpu', 100, 98, 45, 1, 35, '', 0, '')) + (Rep 2 @('ram', 50, 100, 40, 1, 30, '', 0, '')) + (Rep 2 @('gpu', 5, 100, 70, 99, 250, '', 0, '')) + (Rep 2 @('full', 100, 97, 72, 99, 280, '', 0, '')) + (Rep 2 @('pulse', 100, 97, 72, 99, 280, '', 0, ''))
    $a4 = Read-BlackboxAnalysis (New-Bb2File 'w.csv' $all -Stop)
    Assert-Eq $a4.Level 'ok' '통과'; Assert ($a4.Title -match '전 단계 통과') '통과 제목'
}
It 'memtest_vulkan 출력 해석과 VRAM 오류·시작 실패 판정' {
    $lg = Join-Path $OutDir 'gpu.log'
    [IO.File]::WriteAllText($lg, "Testing 1: NVIDIA`nError found. Mode NEXT_RE_READ, total errors 0x10 out of 0x1000`nError found. Mode INITIAL_READ`nRuntime error: ERROR_DEVICE_LOST while getting () in context wait_for_fences`n")
    $g = Get-GpuLoadStatus $lg; Assert-Eq $g.Errors 2 '오류 줄'; Assert $g.DeviceLost '장치 끊김'; Assert $g.Testing '시작됨'
    [IO.File]::WriteAllText($lg, "memtest_vulkan: early exit during init: The library failed to load`n")
    Assert (Get-GpuLoadStatus $lg).InitFailed '시작 실패'
    Assert-Eq (Get-GpuLoadStatus (Join-Path $OutDir 'none.log')).Errors 0 '파일 없음'
    $a = Read-BlackboxAnalysis (New-Bb2File 'g1.csv' ((Rep 3 @('gpu', 5, 100, 70, 99, 250, '', 0, '', 0)) + (Rep 3 @('gpu', 5, 100, 70, 99, 250, '', 0, '', 4))) -Stop)
    Assert-Eq $a.Level 'bad' 'VRAM 오류 = 위험'; Assert-Eq $a.Cause 'GPU_HW' '그래픽카드'; Assert-Eq $a.GpuTestErrors 4 '오류 수'
    $all = @(); foreach ($k in 'idle', 'cpu', 'ram', 'gpu', 'full', 'pulse') { $all += (Rep 2 @($k, 100, 98, 60, 99, 250, '', 0, '')) }
    $all[6] = @('gpu', 5, 100, 40, 0, 20, '', 0, 'GPUFAIL')
    $b = Read-BlackboxAnalysis (New-Bb2File 'g2.csv' $all -Stop)
    Assert ($b.Title -notmatch '전 단계 통과') 'GPU 미시험이면 전 단계 통과 아님'; Assert ($b.Detail -match 'GPU 단계는 시험되지 않음') '안내'
}
It '수리 후 전 단계 통과 기록이 더 새로우면 이전 실패는 참고로만 (점수 감점 없음)' {
    $bad = Read-BlackboxAnalysis (New-Bb2File 'h1.csv' (Rep 4 @('full', 100, 97, 70, 99, 280, '', 0, '')))
    $all = @(); foreach ($k in 'idle', 'cpu', 'ram', 'gpu', 'full', 'pulse') { $all += (Rep 2 @($k, 100, 98, 60, 99, 250, '', 0, '')) }
    $ok = Read-BlackboxAnalysis (New-Bb2File 'h2.csv' $all -Stop)
    $ok.Start = '2026-11-15T10:00:00'; $ok.End = '2026-11-15T10:40:00'   # 실패(11-14) 다음 날 통과
    $dx = Get-Diagnosis -Data (New-Scenario @{ Blackbox = @($bad, $ok) })
    Assert (-not (@($dx.Causes) | Where-Object { $_.Key -eq 'PSU' })) '파워 감점 없음'
    Assert (@($dx.Findings) | Where-Object { $_.Title -match '이후 테스트 통과' }) '해결 표시'
    $dx2 = Get-Diagnosis -Data (New-Scenario @{ Blackbox = @($bad) })
    Assert-Eq (Top $dx2) 'PSU' '통과 기록 없으면 그대로 파워'
    $script:UiLang = 'en'; try { Assert ((Tr "$($bad.Title) (이후 테스트 통과)") -notmatch '[가-힣]') '영어' } finally { $script:UiLang = 'ko' }
}
It 'GPU 도구 미실행 상태의 단계에서 꺼지면 실제 부하 기준으로 판정' {
    $r1 = @(,@('gpu', 5, 100, 40, 0, 20, '', 0, 'GPUFAIL')) + (Rep 3 @('gpu', 5, 100, 40, 0, 20, '', 0, ''))
    $a = Read-BlackboxAnalysis (New-Bb2File 'k1.csv' $r1)
    Assert ($a.Title -notmatch 'GPU 단독') 'GPU 탓 아님'; Assert ($a.Title -match '대기') '대기와 같음'
    $r2 = @(,@('full', 100, 97, 40, 0, 20, '', 0, 'GPUFAIL')) + (Rep 3 @('full', 100, 97, 40, 0, 20, '', 0, ''))
    Assert ((Read-BlackboxAnalysis (New-Bb2File 'k2.csv' $r2)).Title -match 'CPU 단독') '전체 → CPU 단독'
    Assert ((Read-BlackboxAnalysis (New-Bb2File 'k3.csv' (Rep 3 @('gpu', 5, 100, 70, 99, 250, '', 0, '')))).Title -match 'GPU 단독') 'GPU 정상 실행이면 그대로'
}
It '직접 설정 모드 기록: 단계 이름이 내부 키(manual) 대신 표시' {
    $a = Read-BlackboxAnalysis (New-Bb2File 'm1.csv' (Rep 3 @('manual', 100, 98, 60, 99, 250, '', 0, '')))
    Assert-Eq @($a.Stages)[0].Name '직접 설정' '이름'; Assert ($a.Detail -match '\[직접 설정 단계\]') '판정 문구'
    $script:UiLang = 'en'; try { Assert ((Tr $a.Detail) -match '\[Manual stage\]') '영어' } finally { $script:UiLang = 'ko' }
}
It '블랙박스 그래프: 요약 계열(최대 300점)·단계 구간·끊긴 지점 표시, JSON 왕복 후에도 그림' {
    $rows = @(); foreach ($k in 'idle', 'cpu', 'ram', 'gpu', 'full') { $rows += (Rep 150 @($k, 90, 98, 65, 90, 230, '', 0, '')) }
    $a = Read-BlackboxAnalysis (New-Bb2File 'ch1.csv' $rows)
    Assert (@($a.Series.Sec).Count -le 300) "점 수 $(@($a.Series.Sec).Count)"
    $svg = Get-BlackboxChartSvg $a
    Assert ($svg -match '<polyline') '선'; Assert ($svg -match '기록 끊김') '끊김 표시'; Assert ($svg -match 'VRAM 단독 부하') '단계 이름'
    $d = New-Scenario @{ Blackbox = @($a) }
    $h = New-HtmlReport -Data (RoundTrip $d) -Dx (Get-Diagnosis -Data (RoundTrip $d))
    Assert ($h -match 'bbc') 'JSON 왕복 보고서에 그래프'
    Assert-Eq (Get-BlackboxChartSvg ([ordered]@{ Series = $null })) '' '계열 없으면 빈 값'
    # 좁은 구간 이름은 줄이거나 생략 (전체 30분 중 10초짜리 구간)
    $narrow = [ordered]@{ Abrupt = $false; Series = [ordered]@{ Sec = @(0, 10, 1800); Temp = @(50, 50, 50); Pow = @(1, 1, 1); Cpu = @(1, 1, 1); Stage = @('pulse', 'idle', 'idle') } }
    Assert ((Get-BlackboxChartSvg $narrow) -notmatch '전력 출렁임') '좁은 구간 이름 생략'
    # 값이 중간 높이로 그려지는지 (정수 Min 함정 회귀 방지): 50°C → 0~100 축의 가운데 근처
    $flat = [ordered]@{ Abrupt = $false; Series = [ordered]@{ Sec = @(0, 60); Temp = @(50, 50); Pow = @(100, 100); Cpu = @(50, 50); Stage = @('cpu', 'cpu') } }
    $m = [regex]::Match((Get-BlackboxChartSvg $flat), "points='34,([\d\.]+) ")
    Assert ($m.Success -and [double]$m.Groups[1].Value -gt 60 -and [double]$m.Groups[1].Value -lt 100) "가운데 높이: $($m.Groups[1].Value)"
}
It '블랙박스 단계별 최고값 표: 꺼진 단계 표시' {
    $rows = (Rep 3 @('cpu', 100, 98, 50, 1, 30, '', 0, '')) + (Rep 3 @('full', 100, 97, 78, 99, 281, '', 0, ''))
    $a = Read-BlackboxAnalysis (New-Bb2File 'st1.csv' $rows)
    $t = Get-BlackboxStageTable $a
    Assert ($t -match '여기서 꺼짐') '꺼진 단계'; Assert ($t -match '281 W') '최고 전력'; Assert ($t -match '통과') '앞 단계 통과'
    Assert-Eq (Get-BlackboxStageTable ([ordered]@{ Stages = @() })) '' '단계 없으면 빈 값'
    $script:UiLang = 'en'; try { Assert ((Tr $t) -notmatch '[가-힣]') "영어: $(Tr $t)" } finally { $script:UiLang = 'ko' }
}
It '과열 보호: 95°C 이상 3회 연속이면 중지, 중간에 내려가면 초기화, 판정은 과열' {
    $st = @{ Hot = 0 }
    Assert (-not (Test-OverheatGuard $st 96)) '1회'; Assert (-not (Test-OverheatGuard $st 97)) '2회'; Assert (Test-OverheatGuard $st 95) '3회 → 중지'
    $st2 = @{ Hot = 0 }; [void](Test-OverheatGuard $st2 96); [void](Test-OverheatGuard $st2 80); [void](Test-OverheatGuard $st2 96)
    Assert (-not (Test-OverheatGuard $st2 $null)) '온도 없음/하강 시 초기화'
    $a = Read-BlackboxAnalysis (New-Bb2File 'oh.csv' ((Rep 3 @('gpu', 5, 100, 96, 99, 250, 'HWTHERM', 0, '')) + @(,@('gpu', 5, 100, 97, 99, 250, '', 0, 'OVERHEAT_STOP'))) -Stop)
    Assert-Eq $a.Level 'bad' '위험'; Assert-Eq $a.Cause 'THERMAL' '과열'; Assert ($a.Title -match '과열 보호') '제목'
    $script:UiLang = 'en'; try { Assert ((Tr "$($a.Title) $($a.Detail)") -notmatch '[가-힣]') "영어: $(Tr $a.Detail)" } finally { $script:UiLang = 'ko' }
}
It 'NVIDIA 감속 원인 해석' {
    Assert-Eq (ConvertFrom-NvThrottle '0x0000000000000004') 'PWRCAP' '전력 제한'
    Assert-Eq (ConvertFrom-NvThrottle '0x88') 'HWSLOW+PBRAKE' '하드웨어'
    Assert-Eq (ConvertFrom-NvThrottle '0x60') 'SWTHERM+HWTHERM' '온도'
    Assert-Eq (ConvertFrom-NvThrottle '[N/A]') '' '없음'
}
It 'Windows 안 RAM 검사: 실제 패턴 쓰기/읽기, 오류 0' {
    Start-RamTest -MB 128
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ((Get-RamTestState).Passes -lt 1 -and $sw.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Milliseconds 200 }
    $during = [GC]::GetTotalMemory($false)
    $st = Get-RamTestState; Stop-RamTest
    $after = [GC]::GetTotalMemory($false)
    Assert ($during - $after -gt 100MB) "중지 후 메모리 반환 ($([int]($during / 1MB)) MB → $([int]($after / 1MB)) MB)"
    Assert ($st.Passes -ge 1) "1회 이상 완료 ($($st.TestedMB) MB)"
    Assert-Eq $st.Errors 0 'RAM 오류 없음'
    Assert (-not (Get-RamTestState).Running) '중지됨'
}
It '실제 기록기: 줄 기록 후 중지 표시, CPU 부하 시작/중지' {
    $job = Start-Blackbox -Dir (Join-Path $OutDir 'bb') -IntervalSec 0.3 -NoEvents
    $cpu = Start-CpuStress -Threads 2
    # 첫 기록은 센서 준비(최초 1회 컴파일) 때문에 늦을 수 있으므로 3줄 이상 쌓일 때까지 대기 (최대 30초)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($job.Sync.Rows -lt 3 -and $sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 200 }
    Stop-CpuStress $cpu
    Stop-Blackbox $job
    Assert ($null -eq $job.Sync.Error) "오류: $($job.Sync.Error)"
    $lines = @(Get-Content $job.Path)
    Assert ($lines.Count -ge 6) "줄 수 $($lines.Count)"
    Assert ($lines[-1] -match ',STOP$') '중지 표시'
    $a = Read-BlackboxAnalysis $job.Path; Assert (-not $a.Abrupt) '정상 종료'
}
It '기록기: 순간 쓰기 오류는 다시 시도, 계속되면 기록 오류로 표시 (갑자기 꺼짐으로 오판 안 함)' {
    $job = Start-Blackbox -Dir (Join-Path $OutDir 'bb3') -IntervalSec 0.1 -NoEvents
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($job.Sync.Rows -lt 2 -and $sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 100 }
    $bad = Join-Path (Join-Path $OutDir 'no_such_dir_x') 'y.csv'
    $job.Sync.Path = $bad
    $sw.Restart(); while (-not $job.Sync.Warn -and $sw.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 50 }
    Assert ([string]$job.Sync.Warn) '순간 오류 감지'
    $job.Sync.Path = $job.Path; $r0 = $job.Sync.Rows
    $sw.Restart(); while ($job.Sync.Rows -le $r0 -and $sw.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 50 }
    Assert ($job.Sync.Rows -gt $r0) '다시 기록 계속'; Assert ($null -eq $job.Sync.Error) '오류로 멈추지 않음'
    $job.Sync.Path = $bad
    $sw.Restart(); while (-not $job.Sync.Done -and $sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 100 }
    Assert $job.Sync.Done '계속되는 오류면 중지'; Assert ([string]$job.Sync.Error) '오류 보고'
    Stop-Blackbox $job
    $a = Read-BlackboxAnalysis $job.Path
    Assert (-not $a.Abrupt) '전원 차단으로 오판 안 함'; Assert ($a.Events.ContainsKey('LOGERR')) '기록 오류 표시'
    Assert (@($a.Notes) -match '기록 오류').Count '안내'
}
It '화면 → 기록기 사건 전달: 연달아 생겨도, 쓰기 실패해도 잃지 않음' {
    $sy = [hashtable]::Synchronized(@{ Pending = '' })
    Add-BlackboxEvent $sy 'GPUFAIL'; Add-BlackboxEvent $sy 'OVERHEAT_STOP'
    Assert-Eq (Get-BlackboxPending $sy) 'GPUFAIL ; OVERHEAT_STOP' '둘 다 전달'; Assert-Eq $sy.Pending '' '꺼내면 비움'
    # 실제 기록기: 쓰기 실패 중 생긴 사건이 복구 후 기록되는지
    $job = Start-Blackbox -Dir (Join-Path $OutDir 'bb4') -IntervalSec 0.1 -NoEvents
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($job.Sync.Rows -lt 2 -and $sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 100 }
    $job.Sync.Path = Join-Path (Join-Path $OutDir 'no_such_dir_z') 'z.csv'
    Add-BlackboxEvent $job.Sync 'OVERHEAT_STOP'
    $sw.Restart(); while (-not $job.Sync.Warn -and $sw.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 50 }
    Start-Sleep -Milliseconds 300
    $job.Sync.Path = $job.Path; $r0 = $job.Sync.Rows
    $sw.Restart(); while ($job.Sync.Rows -le $r0 + 1 -and $sw.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 50 }
    Stop-Blackbox $job
    $a = Read-BlackboxAnalysis $job.Path
    Assert-Eq $a.Events['OVERHEAT_STOP'] 1 '실패 중 사건도 정확히 한 번 기록'
}
It '기록 중 창 닫기: 확인 질문 (기록 중일 때만, 영어 번역)' {
    Assert-Eq (Get-BlackboxCloseQuestion @{ Box = $null }) '' '기록 안 하면 묻지 않음'
    Assert-Eq (Get-BlackboxCloseQuestion $null) '' 'null 안전'
    $q = Get-BlackboxCloseQuestion @{ Box = @{ Sync = @{ Rows = 42 } } }
    Assert ($q -match '42 줄' -and $q -match '닫을까요') '질문'
    $old = $script:UiLang; $script:UiLang = 'en'
    try { $e = Tr $q; Assert ($e -notmatch '[가-힣]') "영어: $e"; Assert ($e -match '42 rows') '줄 수 유지' } finally { $script:UiLang = $old }
}
It '기록 화면: 쓰기 재시도 중이면 경고 문구 (영어 번역 포함)' {
    Assert-Eq (Get-BlackboxWarnText @{ Warn = '' }) '' '정상이면 없음'
    Assert-Eq (Get-BlackboxWarnText $null) '' 'null 안전'
    $w = Get-BlackboxWarnText @{ Warn = 'IO error' }; Assert ($w -match '다시 시도 중') '경고'
    $old = $script:UiLang; $script:UiLang = 'en'
    try { $e = Tr ("기록 중 · 3 분 · 10 줄" + $w); Assert ($e -notmatch '[가-힣]') "영어: $e"; Assert ($e -match 'retrying') '영문 문구' } finally { $script:UiLang = $old }
}
It '화면 쪽 사건(GPU 도구 실패)이 기록에 남아 GPU 단계 미시험으로 판정' {
    $job = Start-Blackbox -Dir (Join-Path $OutDir 'bb2') -IntervalSec 0.3 -NoEvents
    $job.Sync.Stage = 'gpu'; Add-BlackboxEvent $job.Sync 'GPUFAIL'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($job.Sync.Rows -lt 2 -and $sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 200 }
    Stop-Blackbox $job
    $a = Read-BlackboxAnalysis $job.Path
    Assert ($a.Events.ContainsKey('GPUFAIL')) '사건 기록'; Assert ($a.Detail -match 'GPU 단계는 시험되지 않음') '판정 안내'
    Assert-Eq $job.Sync.Pending '' '한 번만 기록'
}

It '지역 설정 무관: 시간·소수 형식 (핀란드어 시간 구분자, 독일어 소수점)' {
    $old = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('fi-FI')
        $t = Format-T (Get-Date '2026-11-14T10:20:30')
        Assert-Eq $t '2026-11-14T10:20:30' '시간 형식'
        Assert-Eq (ConvertTo-Date $t).Minute 20 '다시 읽기'
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
        Assert-Eq (ConvertTo-CsvField 72.5) '72.5' '소수점'
        Assert-Eq (ConvertTo-CsvField 'a,b') 'a;b' '쉼표 치환'
        Assert-Eq (ConvertTo-CsvField $null) '' 'null'
        Assert-Eq (ConvertTo-CsvField 3) '3' '정수'
        # 핀란드어 설정 + 영어 보고서: '이후 테스트 통과' 안내 시간도 번역 규칙에 맞아야 함
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('fi-FI')
        $bad = Read-BlackboxAnalysis (New-Bb2File 'fi1.csv' (Rep 4 @('full', 100, 97, 70, 99, 280, '', 0, '')))
        $allF = @(); foreach ($k in 'idle', 'cpu', 'ram', 'gpu', 'full', 'pulse') { $allF += (Rep 2 @($k, 100, 98, 60, 99, 250, '', 0, '')) }
        $ok = Read-BlackboxAnalysis (New-Bb2File 'fi2.csv' $allF -Stop); $ok.End = '2026-11-15T10:40:00'
        $script:UiLang = 'en'
        try { $f = @((Get-Diagnosis -Data (New-Scenario @{ Blackbox = @($bad, $ok) })).Findings | Where-Object { $_.Title -match '이후 테스트 통과' })[0]; Assert ((Tr $f.Detail) -notmatch '[가-힣]') "영어 번역: $(Tr $f.Detail)"; Assert ($f.Detail -match '10:40') '시간 구분자 :' }
        finally { $script:UiLang = 'ko' }
    } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $old }
}

Write-Host "`n[영어]" -ForegroundColor Cyan

It '영어 보고서·요약에 한글이 남지 않음 (모든 시나리오)' {
    $script:UiLang = 'en'
    try {
        $left = @{}
        $all = @($scenarios.Keys | ForEach-Object { New-Scenario $scenarios[$_].Data })
        $x = New-Scenario @{ Shutdowns = @([ordered]@{ T = (T 1); Code = ''; PowerButton = $true; Sleep = $true }); DriverInstalls = @([ordered]@{ T = (T 9); Msg = 'NVIDIA driver' }); GpuEvents = @([ordered]@{ T = (T 8); Source = 'Display'; Id = 4101; Xid = 79; Msg = 'x' }); OcTools = @('MSIAfterburner'); GpuSensors = @([ordered]@{ Index = 0; TempC = 95; FanRPM = 2000 }) }
        $x.System.CrashDump = 0; $x.System.PageFiles = 0; $x.System.IsVM = $true; $x.System.FastStartup = 1; $x.System.CPU = 'Intel(R) Core(TM) i9-14900K'; $x.System.BIOSDate = (T 2000); $x.Meta.IsAdmin = $false
        $x.Gpus[0].DriverDate = (T 800); $x.Errors = @([ordered]@{ Step = 'disk'; Msg = 'x' }); $x.MemDiag = @([ordered]@{ T = (T 1); Id = 1202; Failed = $true; Msg = 'x' })
        $x.Disks = @([ordered]@{ Name = 'SSD'; Media = 'SSD'; Bus = 'NVMe'; SizeGB = 1; Health = 'Warning'; TempC = 75; WearPct = 95; ReadErr = 3 }); $x.Thermal = @(95)
        $x.Dimms = @([ordered]@{ Slot = 'A'; SizeGB = 8; ConfiguredMHz = 3600; RatedMHz = 2133; Part = 'X'; DDR = 'DDR4' }, [ordered]@{ Slot = 'B'; SizeGB = 16; ConfiguredMHz = 3600; RatedMHz = 2133; Part = 'Y'; DDR = 'DDR4' })
        $x.Whea = @(17, 18, 19, 47 | ForEach-Object { [ordered]@{ T = (T 2); Id = $_; Level = 3; Comp = 'x'; Msg = 'x' } })
        $x.BugChecks = @('0x116', '0x1A', '0x124', '0x9F', '0x12345' | ForEach-Object { [ordered]@{ T = (T 3); Code = $_ } })
        $x.Blackbox = @(
            (Read-BlackboxAnalysis (New-BbFile 'en1.csv' (@(1..5 | ForEach-Object { ,@(100, 72, 99, 280, 1, 1, '') })))),
            (Read-BlackboxAnalysis (New-BbFile 'en2.csv' (@(1..5 | ForEach-Object { ,@(10, 95, 5, 80, 0, 0, '') })))),
            (Read-BlackboxAnalysis (New-BbFile 'en3.csv' (@(1..5 | ForEach-Object { ,@(10, 50, 5, 80, 0, 0, '') })))),
            (Read-BlackboxAnalysis (New-BbFile 'en4.csv' (@(@(10, 50, 5, 80, 0, 0, 'WHEA 19'))) -Stop)),
            (Read-BlackboxAnalysis (New-BbFile 'en5.csv' (@(@(10, 50, 5, 80, 0, 0, ''))) -Stop)))
        foreach ($k in 'idle', 'cpu', 'ram', 'gpu', 'full', 'pulse') { $x.Blackbox += (Read-BlackboxAnalysis (New-Bb2File "en-$k.csv" (Rep 6 @($k, 100, 50, 60, 99, 250, 'HWSLOW+HWTHERM', 0, 'WHEA 19')))) }
        $x.Blackbox += (Read-BlackboxAnalysis (New-Bb2File 'en-r.csv' (Rep 3 @('ram', 50, 100, 40, 1, 30, '', 3, '')) -Stop))
        $x.Blackbox += (Read-BlackboxAnalysis (New-Bb2File 'en-o.csv' (Rep 2 @('gpu', 5, 100, 70, 99, 250, 'SWTHERM', 0, '')) -Stop))
        $allSt = @(); foreach ($k in 'idle', 'cpu', 'ram', 'gpu', 'full', 'pulse') { $allSt += (Rep 2 @($k, 100, 98, 60, 99, 250, '', 0, '')) }
        $x.Blackbox += (Read-BlackboxAnalysis (New-Bb2File 'en-a.csv' $allSt -Stop))
        $x.Blackbox += (Read-BlackboxAnalysis (New-Bb2File 'en-g.csv' (Rep 3 @('gpu', 5, 100, 70, 99, 250, '', 0, 'GPUFAIL ; GPULOST', 3)) -Stop))

        $all += $x
        foreach ($d in $all) {
            $dx = Get-Diagnosis -Data $d
            $dx.Previous = [ordered]@{ Created = (T 3); Health = 50; New = [ordered]@{ PowerLoss = 1; Bsod = 0; Gpu = 0; Whea = 0; Disk = 0 }; NewTotal = 1 }
            foreach ($txt in @((New-HtmlReport -Data $d -Dx $dx), (Get-SummaryText $d $dx))) {
                foreach ($m in [regex]::Matches($txt, '[^<>"]{0,25}[가-힣]+[^<>"]{0,25}')) { $left[$m.Value.Trim()] = 1 }
            }
        }
        $dx2 = Get-Diagnosis -Data (New-Scenario @{}); $dx2.Previous = [ordered]@{ Created = (T 3); Health = 90; New = [ordered]@{ PowerLoss = 0; Bsod = 0; Gpu = 0; Whea = 0; Disk = 0 }; NewTotal = 0 }
        foreach ($m in [regex]::Matches((New-HtmlReport -Data (New-Scenario @{}) -Dx $dx2), '[^<>"]{0,25}[가-힣]+[^<>"]{0,25}')) { $left[$m.Value.Trim()] = 1 }
        foreach ($t in $script:ExternalTools) { foreach ($s in $t.Label, $t.Desc, $t.Help) { if ((Tr $s) -match '[가-힣]') { $left[(Tr $s)] = 1 } } }
        Assert-Eq $left.Count 0 ("남은 한글: " + (($left.Keys | Select-Object -First 40) -join ' ¦ '))
    } finally { $script:UiLang = 'ko' }
}

Write-Host "`n[소스 규칙]" -ForegroundColor Cyan



It 'PCCheck.ps1 은 UTF-8 BOM (PowerShell 5.1 한글 깨짐 방지)' {
    $b = [IO.File]::ReadAllBytes((Join-Path $root 'PCCheck.ps1')); Assert ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) 'BOM'
}
It '구문 오류 없음' {
    $tk = $null; $er = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'PCCheck.ps1'), [ref]$tk, [ref]$er)
    Assert-Eq @($er).Count 0 (($er | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ')
}
It 'PowerShell 7 전용 문법 미사용 (??, ?., 삼항)' {
    $tk = $null; $er = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'PCCheck.ps1'), [ref]$tk, [ref]$er)
    $bad = @($tk | Where-Object { $_.Kind -in 'QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr' })
    $tern = @($ast.FindAll({ param($n) $n.GetType().Name -eq 'TernaryExpressionAst' }, $true))
    Assert-Eq ($bad.Count + $tern.Count) 0 (($bad | ForEach-Object { "$($_.Extent.StartLineNumber):$($_.Text)" }) -join ', ')
}
It '쉼표 우선순위 함정 없음 (a + (b), c 형태)' {
    $tk = $null; $er = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'PCCheck.ps1'), [ref]$tk, [ref]$er)
    $bad = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.BinaryExpressionAst] -and $n.Operator -in 'Plus', 'Minus', 'Multiply' -and $n.Right -is [System.Management.Automation.Language.ArrayLiteralAst] }, $true))
    Assert-Eq $bad.Count 0 (($bad | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Extent.Text)" }) -join '; ')
}
It '정수 리터럴 [math]::Min/Max 함정 없음 (소수가 정수로 잘림)' {
    # [math]::Min(1, 0.39) 은 정수 버전이 골라져 0 이 됨 → 소수가 섞이는 식에는 1.0 처럼 실수 리터럴을 써야 함
    $src = [IO.File]::ReadAllLines((Join-Path $root 'PCCheck.ps1'))
    $bad = @(); for ($i = 0; $i -lt $src.Length; $i++) { if ($src[$i] -notmatch 'int-ok' -and $src[$i] -match '\[math\]::M(in|ax)\(\d+, [^)]*(\d\.\d|/ |\$eff|\$bw|\$v\b|\$score)') { $bad += "$($i + 1)" } }
    Assert-Eq $bad.Count 0 "줄: $($bad -join ', ')"
}
It '프로그램 버전과 변경 이력 최신 버전이 같음' {
    $cl = [IO.File]::ReadAllText((Join-Path $root 'CHANGELOG.md'))
    $m = [regex]::Match($cl, '(?m)^## (\d+\.\d+\.\d+)')
    Assert $m.Success '변경 이력에 버전 제목'; Assert-Eq $m.Groups[1].Value $script:AppVersion '버전 일치'
}
It '배치 파일은 ASCII + CRLF' {

    $bat = Get-ChildItem $root -Filter *.bat
    Assert ($bat.Count -ge 1) 'bat 존재'
    foreach ($f in $bat) { $b = [IO.File]::ReadAllBytes($f.FullName); Assert (@($b | Where-Object { $_ -gt 127 }).Count -eq 0) "$($f.Name) ASCII"; Assert ([Text.Encoding]::ASCII.GetString($b) -match "`r`n") "$($f.Name) CRLF" }
}

Write-Host "`n결과: 통과 $script:pass · 실패 $script:fail" -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
Remove-Item $OutDir -Recurse -Force -ErrorAction SilentlyContinue
if ($script:fail) { exit 1 }

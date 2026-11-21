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
function RoundTrip($d) { return (ConvertFrom-PCJson (ConvertTo-Json -InputObject $d -Depth 6)) }   # -FromJson 과 같은 경로

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
It 'Windows 메모리 진단: 최근 통과보다 오래된 실패는 해결된 것으로 (참고만)' {
    $old = New-Scenario @{ MemDiag = @([ordered]@{ T = (T 1); Id = 1101; Failed = $false; Msg = 'ok' }, [ordered]@{ T = (T 5); Id = 1202; Failed = $true; Msg = 'err' }) }
    $dx = Get-Diagnosis -Data $old
    Assert (-not (@($dx.Findings) | Where-Object { $_.Title -eq 'Windows 메모리 진단에서 RAM 오류 발견' })) '해결된 실패는 심각 아님'
    $f = @($dx.Findings | Where-Object { $_.Title -match '이후 검사 통과' }); Assert-Eq $f.Count 1 '참고로 표시'; Assert-Eq $f[0].Level 'info' 'info'
    $new = New-Scenario @{ MemDiag = @([ordered]@{ T = (T 1); Id = 1202; Failed = $true; Msg = 'err' }, [ordered]@{ T = (T 5); Id = 1101; Failed = $false; Msg = 'ok' }) }
    Assert (@((Get-Diagnosis -Data $new).Findings | Where-Object { $_.Title -eq 'Windows 메모리 진단에서 RAM 오류 발견' }).Count -eq 1) '통과 후 다시 실패면 심각'
    $lg = $script:UiLang; $script:UiLang = 'en'
    try { $e = Tr "$($f[0].Title) $($f[0].Detail)"; Assert ($e -notmatch '[가-힣]') "영어: $e" } finally { $script:UiLang = $lg }
}
It 'XMP 판정: Core Ultra 200S 의 기본 DDR5-6400 은 XMP 아님, 다른 CPU 는 5600 초과면 XMP' {
    $mk = { param($cpu, $mhz) $d = New-Scenario @{ Dimms = @([ordered]@{ Slot = 'A2'; SizeGB = 16; ConfiguredMHz = $mhz; RatedMHz = 4800; Maker = 'X'; Part = 'P'; DDR = 'DDR5' }) }; $d.System.CPU = $cpu
        @((Get-Diagnosis -Data $d).Findings | Where-Object { $_.Title -match 'XMP' }).Count }
    Assert-Eq (& $mk 'Intel(R) Core(TM) Ultra 9 285K' 6400) 0 'Arrow Lake 6400 은 기본'
    Assert-Eq (& $mk 'Intel(R) Core(TM) Ultra 9 285K' 8000) 1 'Arrow Lake 8000 은 XMP'
    Assert-Eq (& $mk 'AMD Ryzen 7 9800X3D' 6000) 1 'Ryzen 6000 은 EXPO'
    Assert-Eq (& $mk 'AMD Ryzen 7 9800X3D' 5600) 0 'Ryzen 5600 은 기본'
}
It 'Intel 13·14세대 안내: 대상 데스크톱 모델만 (i5-13400·노트북 제외)' {
    $mk = { param($cpu) $d = New-Scenario @{}; $d.System.CPU = $cpu; @((Get-Diagnosis -Data $d).Findings | Where-Object { $_.Title -match '13·14세대' }).Count }
    foreach ($c in '13th Gen Intel(R) Core(TM) i9-13900K', '14th Gen Intel(R) Core(TM) i7-14700KF', '13th Gen Intel(R) Core(TM) i5-13600K', '14th Gen Intel(R) Core(TM) i9-14900') { Assert-Eq (& $mk $c) 1 $c }
    foreach ($c in '13th Gen Intel(R) Core(TM) i5-13400F', '13th Gen Intel(R) Core(TM) i7-13700H', '13th Gen Intel(R) Core(TM) i5-1335U', 'Intel(R) Core(TM) i7-12700K') { Assert-Eq (& $mk $c) 0 $c }
}
It 'JSON 재분석(-FromJson): PowerShell 7 에서도 날짜가 원래 형식 유지 (11/19/2026 같은 지역 형식 아님)' {
    $d = New-Scenario @{ Shutdowns = @([ordered]@{ T = (T 2); Code = ''; PowerButton = $false }) }
    $j = ConvertFrom-PCJson (ConvertTo-Json -InputObject $d -Depth 6)
    Assert ($j.Shutdowns[0].T -is [string]) "문자열 유지 ($($j.Shutdowns[0].T.GetType().Name))"
    Assert ($j.Shutdowns[0].T -match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$') "형식 $($j.Shutdowns[0].T)"
    Assert ($j.Meta.Created -match '^\d{4}-\d\d-\d\dT') '중첩 개체'
    $h = New-HtmlReport -Data $j -Dx (Get-Diagnosis -Data $j)
    Assert ($h -notmatch '\d{1,2}/\d{1,2}/\d{4}') '보고서에 지역 날짜 형식 없음'
    $arr = ConvertFrom-PCJson '[{"Created":"2026-11-10T09:00:00","Health":60},{"Created":"2026-11-14T09:00:00","Health":80}]'
    Assert-Eq @($arr).Count 2 '배열 그대로'; Assert-Eq @($arr)[1].Created '2026-11-14T09:00:00' '배열 안 날짜'
}
It '-ExitCode: 무인 실행 결과를 종료 코드로 (0 양호 · 1 주의 · 2 문제), 지정 안 하면 0' {
    Assert-Eq (Get-ResultExitCode @{ Health = 95; Grade = '양호' }) 0 '양호'
    Assert-Eq (Get-ResultExitCode @{ Health = 75; Grade = '주의' }) 1 '주의'
    Assert-Eq (Get-ResultExitCode @{ Health = 95; Grade = '판단 보류' }) 1 '판단 보류는 양호 아님'
    Assert-Eq (Get-ResultExitCode @{ Health = 40; Grade = '위험' }) 2 '문제'
    $d = New-Scenario @{ Shutdowns = @(1..4 | ForEach-Object { [ordered]@{ T = (T $_); Code = '0x116'; PowerButton = $false } }) }
    $want = Get-ResultExitCode (Get-Diagnosis -Data $d)
    [void][IO.Directory]::CreateDirectory($OutDir)
    $jp = Join-Path $OutDir ('ec_' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($jp, (ConvertTo-Json -InputObject $d -Depth 6), (New-Object Text.UTF8Encoding($true)))
    $exe = $(if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh' }); $ps1 = Join-Path $root 'PCCheck.ps1'
    $null = & $exe -NoProfile -File $ps1 -Mode Silent -FromJson $jp -OutDir (Join-Path $OutDir 'ec1') -NoOpen -Lang ko -ExitCode 2>&1
    Assert-Eq $LASTEXITCODE $want "종료 코드 (기대 $want)"
    Assert ($want -ge 1) '문제 시나리오는 0 아님'
    $null = & $exe -NoProfile -File $ps1 -Mode Silent -FromJson $jp -OutDir (Join-Path $OutDir 'ec2') -NoOpen -Lang ko 2>&1
    Assert-Eq $LASTEXITCODE 0 '-ExitCode 없으면 0'
    $bad = Join-Path $OutDir ('ec_bad_' + [guid]::NewGuid().ToString('N') + '.json'); [IO.File]::WriteAllText($bad, '{ 이건 JSON 아님')
    $null = & $exe -NoProfile -File $ps1 -Mode Silent -FromJson $bad -OutDir (Join-Path $OutDir 'ec3') -NoOpen -Lang ko -ExitCode 2>&1
    Assert-Eq $LASTEXITCODE 3 '읽지 못하면 3 (주의 1 과 구분)'
    $null = & $exe -NoProfile -File $ps1 -Mode Silent -FromJson (Join-Path $OutDir 'missing[1].json') -OutDir (Join-Path $OutDir 'ec4') -NoOpen -Lang ko -ExitCode 2>&1
    Assert-Eq $LASTEXITCODE 3 '파일 없으면 3'
}
It '콘솔 결과 점수 색: 화면·보고서와 같음 (판단 보류는 점수가 높아도 초록 아님)' {
    Assert-Eq (Get-GradeConsoleColor @{ Health = 95; Grade = '양호' }) 'Green' '양호'
    Assert-Eq (Get-GradeConsoleColor @{ Health = 95; Grade = '판단 보류 (기록 필요)' }) 'Yellow' '판단 보류'
    Assert-Eq (Get-GradeConsoleColor @{ Health = 80; Grade = '주의' }) 'Yellow' '주의'
    Assert-Eq (Get-GradeConsoleColor @{ Health = 50; Grade = '위험' }) 'Red' '위험'
    $src = [IO.File]::ReadAllText((Join-Path $root 'PCCheck.ps1'))
    Assert ([regex]::Match($src, '(?s)function Write-ConsoleResult.*?\n\}').Value -match 'Get-GradeConsoleColor') '콘솔 출력에서 사용'
}
It '화면 분석 기간 목록: 명령줄 -Days 값을 그대로 포함 (60 → 90 으로 바뀌지 않음)' {
    Assert-Eq ((Get-DayChoices 30) -join ',') '7,30,90,180' '기본'
    Assert-Eq ((Get-DayChoices 60) -join ',') '7,30,60,90,180' '60 추가'
    Assert-Eq ((Get-DayChoices 365) -join ',') '7,30,90,180,365' '365 추가'
    $src = Get-Content -Raw (Join-Path $PSScriptRoot '..\PCCheck.ps1')
    Assert ($src -match [regex]::Escape('$daysBox.SelectedItem = "$($Days)일"')) '선택값 = 받은 값'
}
It '다음 정밀 검사 추천: 보고서·요약에 표시 (원인 없으면 표시 안 함, 영어 번역)' {
    $d = New-Scenario $scenarios['VRAM 불량: Xid 48/63 + TDR 블루스크린'].Data; $dx = Get-Diagnosis -Data $d
    Assert-Eq (Get-RecommendedToolLabel $dx) '그래픽카드 VRAM 검사' '라벨'
    Assert ((New-HtmlReport -Data $d -Dx $dx) -match '다음 정밀 검사 추천: 그래픽카드 VRAM 검사') '보고서'
    Assert ((Get-SummaryText $d $dx) -match '다음 정밀 검사 추천: 그래픽카드 VRAM 검사') '요약'
    $c = New-Scenario @{}; Assert ((New-HtmlReport -Data $c -Dx (Get-Diagnosis -Data $c)) -notmatch '다음 정밀 검사 추천') '정상 PC 는 없음'
    $lg = $script:UiLang; $script:UiLang = 'en'
    try { $e = New-HtmlReport -Data $d -Dx $dx; Assert ($e -match 'Recommended next test: ') '영어'; Assert ($e -notmatch '다음 정밀') '한글 없음' } finally { $script:UiLang = $lg }
}
It '문서: README 자주 묻는 질문 (외부 전송·100점인데 꺼짐·관리자 권한·경고·결과 보내기·수리 확인)' {
    $readme = Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot '..\README.md')
    Assert ($readme -match '## 자주 묻는 질문') '섹션'
    foreach ($k in '인터넷으로 내 정보가 나가나요', '100점인데', '관리자 권한', '경고를 띄워요', '보내려면', '효과를 확인') { Assert ($readme -match [regex]::Escape($k)) "질문: $k" }
}
It '문서: 판매 준비 체크리스트가 최신 기능(-HideName·shop.txt·Silent·블랙박스 실기 확인)을 다룸' {
    $c = Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot '..\판매-준비-체크리스트.md')
    foreach ($k in '-HideName', 'shop.txt', '-Mode Silent', '블랙박스', '코드 서명') { Assert ($c -match [regex]::Escape($k)) "항목: $k" }
}
It '문서: 여러 PC 무인 검사 배치 예시 (-ExitCode, 큰 종료 코드부터 확인)' {
    $readme = [IO.File]::ReadAllText((Join-Path $root 'README.md'))
    $bat = [regex]::Match($readme, '(?s)```bat\r?\n(.*?)```').Groups[1].Value
    Assert ($bat -match '-Mode Silent -ExitCode') '무인 + 종료 코드'
    Assert ($bat -match '"%~dp0PCCheck\.ps1"') 'USB 위치 기준 경로'
    $i3 = $bat.IndexOf('errorlevel 3'); $i2 = $bat.IndexOf('errorlevel 2'); $i1 = $bat.IndexOf('errorlevel 1')
    Assert ($i3 -ge 0 -and $i3 -lt $i2 -and $i2 -lt $i1) '큰 숫자부터 확인'
    $ck = [IO.File]::ReadAllText((Join-Path $root '판매-준비-체크리스트.md'))
    Assert ($ck -match '-ExitCode') '체크리스트에 안내'
}
It '문서: 사용자용 명령줄 옵션은 모두 README 에 설명됨' {
    $src = Get-Content -Raw (Join-Path $PSScriptRoot '..\PCCheck.ps1')
    $block = [regex]::Match($src, '(?s)\bparam\((.*?)\n\)').Groups[1].Value
    $names = @([regex]::Matches($block, '\$(\w+)') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notin 'GuiSmokeTest', 'LoadOnly' } | Sort-Object -Unique)
    Assert ($names.Count -ge 6) "옵션 수 $($names.Count)"
    $readme = Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot '..\README.md')
    foreach ($n in $names) { Assert ($readme -match "-$n\b") "README 에 -$n 설명 없음" }
}
It '매장 정보(-Shop·shop.txt): 보고서 상단·하단·요약에 표시, HTML 안전, 영어에서도 원문 유지' {
    $dir = Join-Path $OutDir ('shop_' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $dir | Out-Null
    Assert-Eq (Get-ShopText '' $dir) '' '없으면 빈 값'
    [IO.File]::WriteAllText((Join-Path $dir 'shop.txt'), "`r`n  OO컴퓨터 · 010-1234-5678  `r`n둘째 줄", (New-Object System.Text.UTF8Encoding($true)))
    Assert-Eq (Get-ShopText '' $dir) 'OO컴퓨터 · 010-1234-5678' 'shop.txt 첫 줄'
    Assert-Eq (Get-ShopText '직접 입력' $dir) '직접 입력' '-Shop 우선'
    Assert-Eq (Get-ShopText ('가' * 150) $dir).Length 100 '100자 제한'
    $d = New-Scenario @{}; $d.Meta.Shop = 'A&B <컴퓨터>'; $dx = Get-Diagnosis -Data $d
    $h = New-HtmlReport -Data $d -Dx $dx
    Assert ([regex]::Matches($h, '점검: A&amp;B &lt;컴퓨터&gt;').Count -ge 3) '상단·상담 요약·하단, HTML 인코딩'; Assert ($h -match '<footer>점검: ') '하단'
    Assert ((Get-SummaryText $d $dx) -match '점검: A&B <컴퓨터>') '요약'
    $lg = $script:UiLang; $script:UiLang = 'en'
    try { Assert ((New-HtmlReport -Data $d -Dx $dx) -match 'Checked by: A&amp;B &lt;컴퓨터&gt;') '영어: 원문 유지' } finally { $script:UiLang = $lg }
    Assert ((Get-ConsoleRelaunchArgs -Path 'x.ps1' -Days 30 -Shop 'S 1') -join ' ') -match '-Shop "S 1"' '콘솔 재실행에도 전달'
}
It '영어: 시스템 정보가 비어 있어도(수집 실패) 한글이 남지 않음' {
    $d = [ordered]@{ Meta = [ordered]@{ Created = '2026-11-15T10:00:00'; Computer = 'X'; Days = 30; IsAdmin = $true }; System = [ordered]@{} }
    $lg = $script:UiLang; $script:UiLang = 'en'
    try {
        $dx = Get-Diagnosis -Data $d
        foreach ($t in @((New-HtmlReport -Data $d -Dx $dx), (Get-SummaryText $d $dx))) {
            $m = [regex]::Matches($t, '[^<>"]{0,20}[가-힣]+[^<>"]{0,20}'); Assert ($m.Count -eq 0) "한글 남음: $(($m | Select-Object -First 3 | ForEach-Object Value) -join ' | ')"
        }
        Assert-Eq (Tr '(빌드 26100.2314)') '(build 26100.2314)' '소수점 빌드'
    } finally { $script:UiLang = $lg }
}
It '영어: 소스의 모든 Tr "..." 문구(화면·알림)가 번역됨, 짧은 낱말은 다른 낱말 속에서 바뀌지 않음' {
    $src = Get-Content -Raw (Join-Path $PSScriptRoot '..\PCCheck.ps1')
    $lg = $script:UiLang; $script:UiLang = 'en'; $miss = @()
    try {
        foreach ($m in [regex]::Matches($src, '(?:\bTr|Write-TrHost|&\s?\$notify) \(?"((?:[^"`]|`.)*)"|(?:\bTr|Write-TrHost|&\s?\$notify) \(?''([^'']*)''')) {
            $lit = $(if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value })
            if ($lit -notmatch '[가-힣]') { continue }
            $sample = $lit -replace '\$\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)', '12' -replace '\$\w+(\.\w+)*', '12' -replace '\{\d+\}', '12' -replace '`n', "`n"
            if ((Tr $sample) -match '[가-힣]') { $miss += $lit }
        }
        Assert ($miss.Count -eq 0) "번역 없음 $($miss.Count): $(($miss | Select-Object -First 3) -join ' | ')"
        Assert ((Tr '예상하지 못한 오류가 발생했습니다.') -notmatch 'yes') "짧은 낱말 '예' 가 낱말 속에서 바뀜"
        Assert-Eq (Tr '예') 'yes' '단독 낱말은 번역'
    } finally { $script:UiLang = $lg }
}
It '영어 콘솔 모드: 결과 출력에 한글이 남지 않음 (점수 단위 포함)' {
    $lg = $script:UiLang; $script:UiLang = 'en'
    try {
        foreach ($k in $scenarios.Keys) {
            $d = New-Scenario $scenarios[$k].Data; $dx = Get-Diagnosis -Data $d
            $out = (Write-ConsoleResult $dx ([pscustomobject]@{ Html = 'x.html' }) 6>&1 | Out-String)
            $m = [regex]::Matches($out, '.{0,20}[가-힣]+.{0,20}'); Assert ($m.Count -eq 0) "[$k] 한글 남음: $(($m | Select-Object -First 3 | ForEach-Object Value) -join ' | ')"
        }
    } finally { $script:UiLang = $lg }
}
It '메인 화면: Enter 키로 검사 시작 (기본 단추), GUI 자동 검사에서도 확인' {
    $src = Get-Content -Raw (Join-Path $PSScriptRoot '..\PCCheck.ps1')
    Assert ($src -match [regex]::Escape('$f.AcceptButton = $start')) '기본 단추 지정'
    Assert ($src -match [regex]::Escape('$f.AcceptButton -ne $start')) 'CI GUI 흐름 검사에 포함'
}
It '창 제목: 매장 이름 표시 (없으면 프로그램 이름·버전만)' {
    Assert-Eq (Get-WindowTitle '') "$($script:AppName) v$($script:AppVersion)" '기본'
    Assert-Eq (Get-WindowTitle 'OO컴퓨터') "$($script:AppName) v$($script:AppVersion) — OO컴퓨터" '매장'
    $src = Get-Content -Raw (Join-Path $PSScriptRoot '..\PCCheck.ps1')
    Assert ($src -match [regex]::Escape('$f.Text = Get-WindowTitle $script:ShopText')) '메인 창에서 사용'
}
It '디스크 오류: USB·카드 리더에서 난 오류는 PC 내부 디스크 문제로 세지 않음' {
    Assert-Eq (Get-EventDiskNumber 'The device, \Device\Harddisk2\DR2, has a bad block.') 2 '번호 읽기'
    Assert ($null -eq (Get-EventDiskNumber 'no disk here')) '없으면 null'
    $disks = @([ordered]@{ Name = 'Samsung SSD'; DeviceId = '0'; Bus = 'NVMe'; Health = 'Healthy' }, [ordered]@{ Name = 'Card Reader'; DeviceId = '2'; Bus = 'USB'; Health = 'Healthy' })
    $ev = @(1..6 | ForEach-Object { [ordered]@{ T = (T $_); Source = 'disk'; Id = 11; DiskNum = 2; Msg = 'x' } })
    $dx = Get-Diagnosis -Data (New-Scenario @{ Disks = $disks; DiskEvents = $ev })
    Assert (-not (@($dx.Findings) | Where-Object { $_.Title -match '^디스크 오류 기록' })) '내부 디스크 오류로 안 셈'
    Assert-Eq @($dx.Findings | Where-Object { $_.Title -match 'USB·카드 리더 디스크 오류 6 건' }).Count 1 '참고로 표시'
    Assert-Eq $dx.Counts.Disk 0 '디스크 오류 수 0'
    $ev2 = @(1..6 | ForEach-Object { [ordered]@{ T = (T $_); Source = 'disk'; Id = 11; DiskNum = 0; Msg = 'x' } })
    Assert-Eq (Get-Diagnosis -Data (New-Scenario @{ Disks = $disks; DiskEvents = $ev2 })).Counts.Disk 6 '내부 디스크는 그대로'
    $ev3 = @(1..3 | ForEach-Object { [ordered]@{ T = (T $_); Source = 'disk'; Id = 153; DiskNum = 5; Msg = 'x' } })
    Assert-Eq (Get-Diagnosis -Data (New-Scenario @{ Disks = $disks; DiskEvents = $ev3 })).Counts.Disk 0 '목록에 없는 디스크(빈 카드 리더)도 외부'
    $ev4 = @([ordered]@{ T = (T 1); Source = 'disk'; Id = 7; DiskNum = $null; Msg = 'x' })
    Assert-Eq (Get-Diagnosis -Data (New-Scenario @{ Disks = $disks; DiskEvents = $ev4 })).Counts.Disk 1 '번호 모르면 내부로 (보수적)'
    $lg = $script:UiLang; $script:UiLang = 'en'
    try { $f = @($dx.Findings | Where-Object { $_.Title -match 'USB' })[0]; Assert ((Tr "$($f.Title) $($f.Detail)") -notmatch '[가-힣]') '영어' } finally { $script:UiLang = $lg }
}
It '그래픽 오류: 같은 멈춤의 Display 4101 과 LiveKernelEvent 141 은 한 번만 셈' {
    $t0 = (Get-Date).AddDays(-2)
    $ev = @([ordered]@{ T = (Format-T $t0); Source = 'Display'; Id = 4101; Xid = $null; Msg = 'x' },
            [ordered]@{ T = (Format-T $t0.AddSeconds(40)); Source = 'LiveKernelEvent'; Id = 1001; Xid = $null; Msg = 'LiveKernelEvent 141' },
            [ordered]@{ T = (Format-T $t0.AddHours(5)); Source = 'LiveKernelEvent'; Id = 1001; Xid = $null; Msg = 'LiveKernelEvent 117' })
    Assert-Eq @(Merge-GpuEvents $ev).Count 2 '중복 1건 제거, 따로 난 오류 보고는 유지'
    $dx = Get-Diagnosis -Data (New-Scenario @{ GpuEvents = $ev })
    Assert-Eq $dx.Counts.Gpu 2 '진단 집계 2건'
    Assert-Eq @(Merge-GpuEvents @()).Count 0 '빈 목록'
}
It '최근 추세: 최근 7일 문제가 이전보다 2배 이상 잦으면 안내' {
    $mk = { param($daysAgo) @($daysAgo | ForEach-Object { [ordered]@{ T = (T $_); Code = ''; PowerButton = $false } }) }
    $up = New-Scenario @{ Shutdowns = (& $mk @(1, 2, 3, 4, 20)) }; $up.Meta.Days = 30
    $tr = Get-ProblemTrend $up; Assert-Eq $tr.Recent 4 '최근 4'; Assert-Eq $tr.Earlier 1 '이전 1'; Assert $tr.Rising '증가'
    Assert (@((Get-Diagnosis -Data $up).Findings | Where-Object { $_.Title -match '잦아짐' }).Count -eq 1) '안내 표시'
    $flat = New-Scenario @{ Shutdowns = (& $mk @(1, 2, 3, 10, 12, 15, 18, 20, 22, 25)) }; $flat.Meta.Days = 30
    Assert (-not (Get-ProblemTrend $flat).Rising) '고르게 나면 증가 아님'
    $few = New-Scenario @{ Shutdowns = (& $mk @(1, 2)) }; $few.Meta.Days = 30
    Assert (-not (Get-ProblemTrend $few).Rising) '2건뿐이면 판단 안 함'
    $short = New-Scenario @{}; $short.Meta.Days = 7; Assert ($null -eq (Get-ProblemTrend $short)) '기간 7일이면 비교 안 함'
    $bs = New-Scenario @{ BugChecks = @([ordered]@{ T = (T 1); Code = '0x116' }); Shutdowns = @([ordered]@{ T = (T 1); Code = '0x116'; PowerButton = $false }) }; $bs.Meta.Days = 30
    Assert-Eq (Get-ProblemTrend $bs).Recent 1 '블루스크린 1번은 1건 (BugCheck + 41 중복 제외)'
    $lg = $script:UiLang; $script:UiLang = 'en'
    try { $f = @((Get-Diagnosis -Data $up).Findings | Where-Object { $_.Title -match '잦아짐' })[0]; Assert ((Tr "$($f.Title) $($f.Detail)") -notmatch '[가-힣]') "영어: $(Tr $f.Detail)" } finally { $script:UiLang = $lg }
}
It '날짜별 차트: 진단 집계와 같은 기준 (블루스크린 41·그래픽 중복·USB 디스크 제외)' {
    $t0 = (Get-Date).AddDays(-2)
    $d = New-Scenario @{
        Shutdowns = @([ordered]@{ T = (T 1); Code = ''; PowerButton = $false }, [ordered]@{ T = (T 2); Code = '0x116'; PowerButton = $false })
        BugChecks = @([ordered]@{ T = (T 2); Code = '0x116' })
        GpuEvents = @([ordered]@{ T = (Format-T $t0); Source = 'Display'; Id = 4101; Xid = $null; Msg = 'x' }, [ordered]@{ T = (Format-T $t0.AddSeconds(30)); Source = 'LiveKernelEvent'; Id = 1001; Xid = $null; Msg = 'x' })
        Disks = @([ordered]@{ Name = 'SSD'; DeviceId = '0'; Bus = 'NVMe'; Health = 'Healthy' }); DiskEvents = @([ordered]@{ T = (T 1); Source = 'disk'; Id = 11; DiskNum = 3; Msg = 'x' })
    }
    $sr = Get-TimelineSeries $d; $dx = Get-Diagnosis -Data $d
    Assert-Eq @($sr['갑자기 꺼짐'].T).Count $dx.Counts.PowerLoss '꺼짐 = 집계'
    Assert-Eq @($sr['그래픽'].T).Count $dx.Counts.Gpu '그래픽 = 집계'
    Assert-Eq @($sr['디스크 오류'].T).Count $dx.Counts.Disk '디스크 = 집계'
    Assert-Eq @($sr['갑자기 꺼짐'].T).Count 1 '블루스크린 41 제외'
    Assert ((Get-TimelineSvg $d) -match '<svg') '차트 생성'
}
It '그래픽 오류 직후 전원 버튼 강제 종료는 파워 부족 패턴으로 보지 않음' {
    $t0 = (Get-Date).AddDays(-2)
    $gpu = @([ordered]@{ T = (Format-T $t0); Source = 'Display'; Id = 4101; Xid = $null; Msg = 'x' })
    $btn = Get-Diagnosis -Data (New-Scenario @{ GpuEvents = $gpu; Shutdowns = @([ordered]@{ T = (Format-T $t0.AddMinutes(3)); Code = ''; PowerButton = $true }) })
    Assert (-not (@($btn.Findings) | Where-Object { $_.Title -match '^그래픽 오류 직후 꺼짐' })) '파워 패턴 아님'
    Assert-Eq @($btn.Findings | Where-Object { $_.Title -match '강제 종료 1 회' }).Count 1 '멈춤 후 강제 종료로 표시'
    $real = Get-Diagnosis -Data (New-Scenario @{ GpuEvents = $gpu; Shutdowns = @([ordered]@{ T = (Format-T $t0.AddMinutes(3)); Code = ''; PowerButton = $false }) })
    Assert-Eq @($real.Findings | Where-Object { $_.Title -match '^그래픽 오류 직후 꺼짐' }).Count 1 '진짜 전원 차단은 그대로'
    $lg = $script:UiLang; $script:UiLang = 'en'
    try { $f = @($btn.Findings | Where-Object { $_.Title -match '강제 종료' })[0]; Assert ((Tr "$($f.Title) $($f.Detail)") -notmatch '[가-힣]') '영어' } finally { $script:UiLang = $lg }
}
It '블루스크린 코드표: 흔한 코드가 모두 등록되고 설명은 영어로 번역됨' {
    $codes = '0xA', '0x1E', '0x3B', '0x50', '0x7E', '0x7F', '0x9F', '0xC2', '0xD1', '0xEF', '0xF4', '0x101', '0x109', '0x116', '0x117', '0x119', '0x124', '0x133', '0x139', '0x13A', '0x154', '0x18B', '0x19', '0x1A', '0x24', '0x7A', '0x77', '0xC000021A', '0x113', '0x10D', '0x144', '0x15F', '0x1CA'
    $lg = $script:UiLang
    foreach ($c in $codes) {
        $b = Get-BugInfo $c; Assert ($b.N -ne '기타') "$c 미등록"
        $script:UiLang = 'en'; try { Assert ((Tr $b.D) -notmatch '[가-힣]') "$c 설명 번역 없음: $($b.D)" } finally { $script:UiLang = $lg }
    }
    $dx = Get-Diagnosis -Data (New-Scenario @{ BugChecks = @([ordered]@{ T = (T 1); Code = '0x113' }, [ordered]@{ T = (T 2); Code = '0x113' }) })
    Assert-Eq @($dx.Causes)[0].Key 'GPU_DRIVER' '0x113 → 그래픽 드라이버'
}
It 'NVIDIA Xid 표: 설명이 모두 영어로 번역되고 흔한 코드 등록' {
    foreach ($x in 8, 13, 31, 32, 43, 48, 61, 62, 63, 64, 79, 94, 95, 119, 120, 154) { Assert ($script:XidDb.ContainsKey($x)) "Xid $x 미등록" }
    $lg = $script:UiLang; $script:UiLang = 'en'
    try { foreach ($k in $script:XidDb.Keys) { $dd = $script:XidDb[$k].D; Assert ((Tr $dd) -notmatch '[가-힣]') "Xid $k 번역 없음: $dd" } } finally { $script:UiLang = $lg }
}
It '영어: 내장 표(블루스크린·해결 순서·원인·정밀 검사·단계 이름)가 모두 번역됨' {
    $lg = $script:UiLang; $script:UiLang = 'en'; $miss = @()
    try {
        foreach ($k in $script:BugDb.Keys) { if ((Tr $script:BugDb[$k].D) -match '[가-힣]') { $miss += "BUG $k" } }
        foreach ($k in $script:Playbook.Keys) { foreach ($st in $script:Playbook[$k]) { if ((Tr $st) -match '[가-힣]') { $miss += "PB $k" } } }
        foreach ($k in $script:Causes.Keys) { foreach ($t in @($script:Causes[$k].Values)) { if ($t -is [string] -and (Tr $t) -match '[가-힣]') { $miss += "CAUSE $k" } } }
        foreach ($t in $script:ExternalTools) { foreach ($x in $t.Label, $t.Desc, $t.Help) { if ($x -and (Tr $x) -match '[가-힣]') { $miss += "TOOL $($t.Key)" } } }
        foreach ($p in $script:StagePlan) { if ((Tr $p.Name) -match '[가-힣]') { $miss += "STAGE $($p.Key)" } }
        Assert ($miss.Count -eq 0) "번역 없음: $(($miss | Select-Object -Unique) -join ', ')"
    } finally { $script:UiLang = $lg }
}
It '검사 소요 시간: 보고서 하단에 총 시간과 느린 단계 표시 (JSON 재분석 후에도, 영어 번역)' {
    $d = New-Scenario @{}; $d.Meta.ScanSec = 12.3; $d.Meta.StepSec = [ordered]@{ '시스템 정보' = 1.2; 'Windows 안정성 지수' = 8.4 }
    $h = New-HtmlReport -Data $d -Dx (Get-Diagnosis -Data $d)
    Assert ($h -match '검사 소요 12.3초 \(가장 오래 걸린 단계: Windows 안정성 지수 8.4초\)') '표시'
    $j = RoundTrip $d; Assert ((New-HtmlReport -Data $j -Dx (Get-Diagnosis -Data $j)) -match '검사 소요 12.3초') 'JSON 재분석 후에도'
    $d.Meta.StepSec = [ordered]@{ 'a' = 1 }; Assert ((New-HtmlReport -Data $d -Dx (Get-Diagnosis -Data $d)) -notmatch '가장 오래') '5초 미만이면 단계 표시 안 함'
    Assert ((New-HtmlReport -Data (New-Scenario @{}) -Dx (Get-Diagnosis -Data (New-Scenario @{}))) -notmatch '검사 소요') '정보 없으면 표시 안 함'
    $d.Meta.StepSec = [ordered]@{ 'Windows 안정성 지수' = 8.4 }
    $lg = $script:UiLang; $script:UiLang = 'en'
    try { Assert ((New-HtmlReport -Data $d -Dx (Get-Diagnosis -Data $d)) -match 'Scan took 12.3 s \(slowest step: Windows stability index 8.4 s\)') '영어' } finally { $script:UiLang = $lg }
}
It 'CI 배포 ZIP: 브라우저로 볼 수 있는 README.html 포함, 워크플로는 ASCII 만 (5.1 인라인 스크립트 규칙)' {
    $wf = Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot '..\..\.github\workflows\pc-check.yml')
    Assert ($wf -match 'ConvertFrom-Markdown -Path \./README\.md') 'README 변환'; Assert ($wf -match "README\.html") 'README.html 저장'
    Assert (-not ($wf.ToCharArray() | Where-Object { [int]$_ -gt 127 })) '워크플로에 비 ASCII 문자 없음'
    if (Get-Command ConvertFrom-Markdown -ErrorAction SilentlyContinue) { Assert ((ConvertFrom-Markdown -Path (Join-Path $PSScriptRoot '..\README.md')).Html -match '<table') '변환 결과에 표' }
}
It 'CI: 지원 종료 예정(Node 20) 액션 버전을 쓰지 않음' {
    $wf = Get-Content -Raw (Join-Path $PSScriptRoot '..\..\.github\workflows\pc-check.yml')
    Assert ($wf -notmatch 'actions/checkout@v[1-4]\b') 'checkout 은 v5 이상 (Node 24)'
    Assert ($wf -notmatch 'actions/upload-artifact@v[1-5]\b') 'upload-artifact 는 v6 이상 (v5 는 아직 Node 20)'
    Assert ($wf -match 'actions/checkout@v\d+') 'checkout 사용'
}
It '-HideName: PC 이름을 같은 PC 면 같은 코드로 가리고 보고서·요약에 원래 이름이 남지 않음' {
    $d = New-Scenario @{ AppCrashes = @([ordered]@{ T = (T 1); App = 'game.exe'; Msg = 'C:\Users\honggd\AppData\Local\game.exe crashed' }) }
    $d.Meta.Computer = 'HONGGILDONG-PC'
    $d.Blackbox = @([ordered]@{ File = 'PCCheck_blackbox_HONGGILDONG-PC_20261114_100000.csv'; Level = 'ok'; Title = 'x'; Detail = 'y' })
    $d = Hide-ComputerName $d 'honggd'
    Assert ($d.Meta.Computer -match '^PC-[0-9a-f]{6}$') "코드 $($d.Meta.Computer)"
    $c1 = $d.Meta.Computer; $d = Hide-ComputerName $d 'honggd'; Assert-Eq $d.Meta.Computer $c1 '두 번 적용해도 그대로'
    $e = New-Scenario @{}; $e.Meta.Computer = 'honggildong-pc'; $e = Hide-ComputerName $e; Assert-Eq $e.Meta.Computer $c1 '같은 PC 는 같은 코드 (대소문자 무관)'
    $all = ConvertTo-Json -InputObject $d -Depth 8
    Assert ($all -notmatch 'HONGGILDONG') '블랙박스 파일 이름 등 자료 전체에서 PC 이름 제거'
    Assert ($all -notmatch 'honggd') '경로 속 사용자 이름 제거'; Assert ($all -match 'Users\\\\user\\\\') '경로는 user 로'
    $dx = Get-Diagnosis -Data $d
    foreach ($t in @((New-HtmlReport -Data $d -Dx $dx), (Get-SummaryText $d $dx), (ConvertTo-Json -InputObject $d -Depth 6))) { Assert ($t -notmatch 'HONGGILDONG') '원래 이름 없음' }
    Assert ((Get-ConsoleRelaunchArgs -Path 'x.ps1' -Days 30 -HideName) -contains '-HideName') '콘솔 재실행에도 전달'
}
It '-HideName: 짧은 PC 이름(PC)이 다른 낱말(PCIe·PCCheck) 속에서는 바뀌지 않음' {
    $d = New-Scenario @{ Whea = @([ordered]@{ T = (T 1); Id = 17; Level = 3; Comp = 'PCI Express Root Port'; Msg = 'PCIe corrected error' }) }
    $d.Meta.Computer = 'PC'
    $d.Blackbox = @([ordered]@{ File = 'PCCheck_blackbox_PC_20261114_100000.csv'; Level = 'ok'; Title = 'x'; Detail = 'y' })
    $x = Hide-ComputerName $d
    $all = ConvertTo-Json -InputObject $x -Depth 8
    Assert ($all -match 'PCIe corrected error') 'PCIe 유지'; Assert ($all -match 'PCI Express') 'PCI 유지'
    Assert ($all -match 'PCCheck_blackbox_PC-[0-9a-f]{6}_2026') '파일 이름 속 PC 이름만 바뀜'
    Assert ($x.Meta.Computer -match '^PC-[0-9a-f]{6}$') '이름 바뀜'
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
    Assert-Eq (Get-RecommendedTool ([pscustomobject]@{ Causes = @([pscustomobject]@{ Key = 'DRIVER'; Score = 40 }); Counts = @{ Bsod = 0 }; Findings = @() })) '' '블루스크린 없으면 BlueScreenView 추천 안 함'
    Assert-Eq (Get-RecommendedTool ([pscustomobject]@{ Causes = @([pscustomobject]@{ Key = 'DRIVER'; Score = 40 }); Counts = @{ Bsod = 2 }; Findings = @() })) 'bsv' '블루스크린 있으면 추천'
    Assert-Eq (Get-RecommendedTool ([pscustomobject]@{ Causes = @([pscustomobject]@{ Key = 'GPU_DRIVER'; Score = 40 }); Counts = @{ Bsod = 0 }; Findings = @() })) 'vram' 'TDR 만 있으면 VRAM 검사'
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


It 'memtest_vulkan 최신판: 해시(SHA-256)가 없으면 검증 안 된 파일 대신 고정 버전' {
    $script:FakeRel = $null
    function Invoke-RestMethod { return $script:FakeRel }
    try {
        $script:FakeRel = [pscustomobject]@{ assets = @([pscustomobject]@{ name = 'memtest_vulkan-v0.9.0.exe'; browser_download_url = 'https://example.invalid/x.exe'; digest = $null }) }
        $a = Get-MemtestAsset
        Assert-Eq $a.Source 'pinned' '해시 없으면 고정 버전'; Assert ($a.Sha256 -match '^[0-9a-f]{64}$') '고정 버전 해시'
        $script:FakeRel = [pscustomobject]@{ assets = @([pscustomobject]@{ name = 'memtest_vulkan-v0.9.0.exe'; browser_download_url = 'https://example.invalid/x.exe'; digest = ('sha256:' + ('a' * 64)) }) }
        $a = Get-MemtestAsset
        Assert-Eq $a.Source 'api' '해시 있으면 최신판'; Assert-Eq $a.Sha256 ('a' * 64) '해시 전달'
    } finally { Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue }
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
        foreach ($f in $r.Html, $r.Json, $r.Txt) { Assert ((Split-Path $f -Leaf) -match '^PCCheck_([^_]+_)?\d{8}_\d{6}\.') "영문 이름 $f"; Assert (Test-Path $f) '파일 존재' }
    } finally { $script:UiLang = $old }
    Assert ((Get-OutputPrefix) -eq 'PC진단') '한국어는 기존 이름 유지'
}
It '보고서 탭 제목: PC 이름·날짜 포함 (여러 보고서를 열어도 구분, 영어·HideName 반영)' {
    $d = New-Scenario @{}; $d.Meta.Computer = 'SHOP-PC7'; $d.Meta.Created = '2026-11-14T10:00:00'
    $h = New-HtmlReport -Data $d -Dx (Get-Diagnosis -Data $d)
    Assert ($h -match '<title>PC 진단 보고서 — SHOP-PC7 2026-11-14</title>') '한국어 제목'
    $lg = $script:UiLang; $script:UiLang = 'en'
    try { Assert ((New-HtmlReport -Data $d -Dx (Get-Diagnosis -Data $d)) -match '<title>[^<가-힣]+ — SHOP-PC7 2026-11-14</title>') '영어 제목' } finally { $script:UiLang = $lg }
    $x = Hide-ComputerName $d; Assert ((New-HtmlReport -Data $x -Dx (Get-Diagnosis -Data $x)) -notmatch 'SHOP-PC7') 'HideName 이면 제목에도 없음'
}
It '저장 파일 이름: PC 이름 포함 (못 쓰는 문자 제거, HideName 이면 코드)' {
    $dir = Join-Path $OutDir ('fn_' + [guid]::NewGuid().ToString('N'))
    $d = New-Scenario @{}; $d.Meta.Computer = 'SHOP:PC 7'; $d.Meta.Created = '2026-11-14T10:00:00'
    $r = Save-Results -Data $d -Dx (Get-Diagnosis -Data $d) -Dir $dir
    Assert-Eq (Split-Path $r.Html -Leaf) 'PC진단_SHOPPC7_20261114_100000.html' '이름'
    $x = Hide-ComputerName $d; $r2 = Save-Results -Data $x -Dx (Get-Diagnosis -Data $x) -Dir $dir
    Assert ((Split-Path $r2.Html -Leaf) -match '^PC진단_PC-[0-9a-f]{6}_20261114_100000\.html$') "가린 이름 $(Split-Path $r2.Html -Leaf)"
}
It '콘솔 메뉴 요약 복사: 저장된 요약을 클립보드로, 파일 없으면 실패 처리' {
    $dir = Join-Path $OutDir ('cp_' + [guid]::NewGuid().ToString('N'))
    $d = New-Scenario @{}; $r = Save-Results -Data $d -Dx (Get-Diagnosis -Data $d) -Dir $dir
    $script:copied = $null
    function global:Set-Clipboard { param($Value, $ErrorAction) $script:copied = $Value }
    try {
        Assert (Copy-SummaryText $r) '복사 성공'
        Assert ($script:copied -eq [IO.File]::ReadAllText($r.Txt)) '요약 내용 그대로'
        Assert (-not (Copy-SummaryText ([pscustomobject]@{ Txt = (Join-Path $dir 'none.txt') }))) '파일 없으면 false'
    } finally { Remove-Item function:global:Set-Clipboard -ErrorAction SilentlyContinue }
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
        Assert-Eq @($dx2.Trend).Count 1 '점수 변화 1회'
        Assert ([IO.File]::ReadAllText($r.Html) -match "점수 변화: \d\d-\d\d $($dx1.Health) → 지금 $($dx2.Health)") '점수 변화 표시'
        $lg = $script:UiLang; $script:UiLang = 'en'
        try { $he = New-HtmlReport -Data $d2 -Dx $dx2; Assert ($he -match "Score history: \d\d-\d\d $($dx1.Health) → now $($dx2.Health)") '영어' } finally { $script:UiLang = $lg }
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
It '블랙박스: 메모리 검사 오류 뒤 꺼지면 원인과 제목이 일치 (RAM·VRAM)' {
    $a = Read-BlackboxAnalysis (New-Bb2File 'bb_ramerr.csv' (Rep 10 @('full', 95, 99, 70, 99, 300, '', 3, '')))
    Assert-Eq $a.Cause 'RAM' 'RAM 원인'; Assert ($a.Title -match 'RAM 검사 오류 3 건 뒤 꺼짐') "제목 $($a.Title)"
    $g = Read-BlackboxAnalysis (New-Bb2File 'bb_vramerr.csv' (Rep 10 @('gpu', 10, 99, 70, 99, 250, '', 0, '', 5)))
    Assert-Eq $g.Cause 'GPU_HW' 'VRAM 원인'; Assert ($g.Title -match 'VRAM 검사 오류 5 건 뒤 꺼짐') "제목 $($g.Title)"
    $lg = $script:UiLang; $script:UiLang = 'en'
    try { foreach ($t in $a.Title, $g.Title) { Assert ((Tr $t) -notmatch '[가-힣]') "영어: $(Tr $t)" } } finally { $script:UiLang = $lg }
}
It '지난 검사 대비: 노하드는 이후 끝난 블랙박스 이상 기록도 새 문제로 셈' {
    $bad = Read-BlackboxAnalysis (New-Bb2File 'bb_new.csv' (Rep 10 @('full', 95, 99, 70, 99, 300, '', 0, '')))   # 2026-11-14 기록, 갑자기 끊김
    Assert-Eq $bad.Level 'bad' '이상 기록'
    $d = New-Scenario @{ Blackbox = @($bad) }
    $n = Get-NewSince $d (Get-Date '2026-11-13T00:00:00'); Assert-Eq $n.Blackbox 1 '이후 이상 1건'
    $n2 = Get-NewSince $d (Get-Date '2026-11-15T00:00:00'); Assert-Eq $n2.Blackbox 0 '이전 기록은 제외'
    $dx = Get-Diagnosis -Data $d; $dx.Previous = [ordered]@{ Created = '2026-11-13T00:00:00'; Health = 80; New = $n; NewTotal = 1 }
    $h = New-HtmlReport -Data $d -Dx $dx; Assert ($h -match '블랙박스 이상 1') '보고서 항목'
    $lg = $script:UiLang; $script:UiLang = 'en'
    try { Assert ((New-HtmlReport -Data $d -Dx $dx) -match 'Blackbox failure 1') '영어' } finally { $script:UiLang = $lg }
}
It '검사 이력: USB 블랙박스 폴더에도 저장해 노하드 재부팅 후에도 지난 검사 대비 유지' {
    $oldWd = $script:WorkDir; $oldEx = $script:ExtraHistoryDirs
    $usb = Join-Path $OutDir ('usb_' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $usb | Out-Null
    try {
        $script:WorkDir = Join-Path $OutDir ('wd1_' + [guid]::NewGuid().ToString('N')); $script:ExtraHistoryDirs = @($usb)
        $d1 = New-Scenario @{}; $d1.Meta.Created = Format-T (Get-Date).AddDays(-3)
        [void](Save-Results -Data $d1 -Dx (Get-Diagnosis -Data $d1) -Dir $OutDir -Track)
        Assert (Test-Path (Join-Path $usb 'history.json')) 'USB 사본 저장'
        # 재부팅으로 기본 위치가 비워진 상황
        $script:WorkDir = Join-Path $OutDir ('wd2_' + [guid]::NewGuid().ToString('N'))
        Assert-Eq @(Read-History).Count 1 'USB 에서 이력 읽음'
        $d2 = New-Scenario @{}; $dx2 = Get-Diagnosis -Data $d2
        [void](Save-Results -Data $d2 -Dx $dx2 -Dir $OutDir -Track)
        Assert ($null -ne $dx2.Previous) '지난 검사 대비 동작'
        Assert-Eq @(Read-History).Count 2 '중복 없이 2건'
    } finally { $script:WorkDir = $oldWd; $script:ExtraHistoryDirs = $oldEx }
}
It '노하드: 저장 위치를 정하지 않았고 USB 가 있으면 보고서를 USB 에 저장 (바탕화면은 재부팅 시 지워짐)' {
    $dl = New-Scenario @{ Disks = @([ordered]@{ Name = 'iSCSI Disk'; Bus = 'iSCSI'; Health = 'Healthy' }) }
    $nm = New-Scenario @{}
    Assert (Test-Diskless $dl) '노하드 판정'; Assert (-not (Test-Diskless $nm)) '일반 PC'
    Assert-Eq (Get-ReportDir $dl 'C:\Desk\PC진단' $true 'E:\') 'E:\PC진단_reports' 'USB 로'
    Assert-Eq (Get-ReportDir $dl 'D:\내폴더' $false 'E:\') 'D:\내폴더' '직접 정한 위치는 그대로'
    Assert-Eq (Get-ReportDir $dl 'C:\Desk\PC진단' $true '') 'C:\Desk\PC진단' 'USB 없으면 그대로'
    Assert-Eq (Get-ReportDir $nm 'C:\Desk\PC진단' $true 'E:\') 'C:\Desk\PC진단' '일반 PC 는 그대로'
}
It '블랙박스: 직접 고른 폴더에 기록해도 다음 검사에서 찾음' {
    $oldWd = $script:WorkDir; $script:WorkDir = Join-Path $OutDir ('wdbb_' + [guid]::NewGuid().ToString('N'))
    try {
        $dir = Join-Path $OutDir ('custom_' + [guid]::NewGuid().ToString('N'))
        $job = Start-Blackbox -Dir $dir -IntervalSec 0.2 -NoEvents
        $sw = [Diagnostics.Stopwatch]::StartNew(); while ($job.Sync.Rows -lt 2 -and $sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 100 }
        Stop-Blackbox $job
        Assert (@(Get-BlackboxDirMemory) -contains $dir) '폴더 기억'
        $found = @(Find-BlackboxFiles 30)
        Assert (@($found | Where-Object { $_.File -eq [IO.Path]::GetFileName($job.Path) }).Count -eq 1) "찾음 ($($found.Count))"
        foreach ($i in 1..12) { Add-BlackboxDirMemory "X$i" }; Assert-Eq @(Get-BlackboxDirMemory).Count 10 '최근 10개만'
    } finally { $script:WorkDir = $oldWd }
}
It '블랙박스: 폴더 이름에 [ ] 가 있어도 기록을 찾음 (와일드카드로 해석하지 않음)' {
    $oldWd = $script:WorkDir; $oldR = $script:BlackboxSearchRoots
    $usb = Join-Path $OutDir ('usb[1]_' + [guid]::NewGuid().ToString('N'))
    try {
        $script:WorkDir = Join-Path $OutDir ('wdb_' + [guid]::NewGuid().ToString('N'))
        $sub = Join-Path $usb 'PCCheck_blackbox'; New-Item -ItemType Directory -Force -Path $sub | Out-Null
        $f = Join-Path $sub 'PCCheck_blackbox_PC_20990102_000000.csv'
        [IO.File]::Copy((New-Bb2File 'bb_br.csv' (Rep 5 @('idle', 5, 99, 40, 1, 20, '', 0, ''))), $f)
        [IO.File]::SetLastWriteTime($f, (Get-Date))
        $script:BlackboxSearchRoots = @($usb)
        $found = @(Find-BlackboxFiles 30)
        Assert (@($found | Where-Object { $_.File -eq 'PCCheck_blackbox_PC_20990102_000000.csv' }).Count -eq 1) "대괄호 폴더 기록 찾음 ($($found.Count))"
    } finally { $script:WorkDir = $oldWd; $script:BlackboxSearchRoots = $oldR }
}
It '폴더 이름에 [ ] 가 있어도: shop.txt·USB 이력·보고서 파일을 찾음' {
    $d = Join-Path $OutDir ('shop[2]_' + [guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($d)
    [IO.File]::WriteAllText((Join-Path $d 'shop.txt'), "괄호컴퓨터`r`n", (New-Object Text.UTF8Encoding($true)))
    Assert-Eq (Get-ShopText '' $d) '괄호컴퓨터' 'shop.txt 읽음'
    $old = $script:ExtraHistoryDirs
    try { $script:ExtraHistoryDirs = @($d); Assert (@(Get-HistoryPaths) -contains (Join-Path $d 'history.json')) 'USB 이력 경로 포함' } finally { $script:ExtraHistoryDirs = $old }
    $src = [IO.File]::ReadAllText((Join-Path $root 'PCCheck.ps1'))
    $bad = @([regex]::Matches($src, '(?m)(Test-Path|Get-ChildItem|Remove-Item) \$(Dir|f|d|p|exe|dir|file|zip|tmp|_)\b') | ForEach-Object { $_.Value })
    Assert-Eq $bad.Count 0 "와일드카드로 해석되는 경로: $($bad -join ', ')"
}
It 'GPU 도구 출력 경로: 기록 폴더에 [ ] 가 있으면 작업 폴더로 (Start-Process 시작 실패 방지)' {
    $oldWd = $script:WorkDir
    try {
        $script:WorkDir = Join-Path $OutDir ('wdg_' + [guid]::NewGuid().ToString('N'))
        $plain = Join-Path $OutDir 'PCCheck_blackbox/PCCheck_blackbox_PC_20990101_000000.csv'
        Assert-Eq (Get-GpuLogPath $plain) ([IO.Path]::ChangeExtension($plain, '.gpu.log')) '일반 폴더는 기록 옆'
        $br = Join-Path $OutDir 'usb[1]/PCCheck_blackbox/PCCheck_blackbox_PC_20990101_000000.csv'
        $g = Get-GpuLogPath $br
        Assert (-not [Management.Automation.WildcardPattern]::ContainsWildcardCharacters($g)) "와일드카드 문자 없음 ($g)"
        Assert ($g.StartsWith($script:WorkDir)) '작업 폴더 안'
        Assert ($g.EndsWith('PCCheck_blackbox_PC_20990101_000000.gpu.log')) '파일 이름 유지'
        Assert ([IO.Directory]::Exists((Split-Path $g))) '폴더 만들어 둠'
    } finally { $script:WorkDir = $oldWd }
}
It '블랙박스: USB 안 하위 폴더에 기록한 것도 (기억이 지워진 뒤에도) 찾음' {
    $oldWd = $script:WorkDir; $oldR = $script:BlackboxSearchRoots
    $usb = Join-Path $OutDir ('usbroot_' + [guid]::NewGuid().ToString('N'))
    try {
        $script:WorkDir = Join-Path $OutDir ('wdr_' + [guid]::NewGuid().ToString('N'))
        $sub = Join-Path (Join-Path $usb '테스트') 'PCCheck_blackbox'; New-Item -ItemType Directory -Force -Path $sub | Out-Null
        $f = Join-Path $sub 'PCCheck_blackbox_PC_20990101_000000.csv'
        Copy-Item (New-Bb2File 'bb_sub.csv' (Rep 5 @('idle', 5, 99, 40, 1, 20, '', 0, ''))) $f
        (Get-Item $f).LastWriteTime = Get-Date
        $script:BlackboxSearchRoots = @($usb)
        Assert-Eq @(Get-BlackboxDirMemory).Count 0 '기억 없음 (재부팅 상황)'
        $found = @(Find-BlackboxFiles 30)
        Assert (@($found | Where-Object { $_.File -eq 'PCCheck_blackbox_PC_20990101_000000.csv' }).Count -eq 1) "하위 폴더 기록 찾음 ($($found.Count))"
    } finally { $script:WorkDir = $oldWd; $script:BlackboxSearchRoots = $oldR }
}
It '노하드 + 블랙박스 기록 없음: 기록이 비어도 양호라고 하지 않고 판단 보류' {
    $dl = New-Scenario @{ Disks = @([ordered]@{ Name = 'iSCSI'; DeviceId = '0'; Bus = 'iSCSI'; Health = 'Healthy' }) }
    $dx = Get-Diagnosis -Data $dl
    Assert ($dx.Grade -match '판단 보류') "등급 $($dx.Grade)"
    $bb = Read-BlackboxAnalysis (New-Bb2File 'bb_hold.csv' (Rep 5 @('pulse', 50, 99, 60, 90, 200, '', 0, '')) -Stop)
    $dl2 = New-Scenario @{ Disks = $dl.Disks; Blackbox = @($bb) }
    Assert ((Get-Diagnosis -Data $dl2).Grade -notmatch '판단 보류') '블랙박스가 있으면 정상 판정'
    Assert-Eq (Get-Diagnosis -Data (New-Scenario @{})).Grade '양호' '일반 PC 는 그대로'
    Assert-Eq (Get-GradeClass $dx) 'warn' '판단 보류는 주의 색 (초록 아님)'
    Assert-Eq (Get-GradeClass (Get-Diagnosis -Data (New-Scenario @{}))) 'ok' '양호는 초록'
    Assert ((New-HtmlReport -Data $dl -Dx $dx) -match 'class="ring warn"') '보고서 점수 원도 주의 색'
    $lg = $script:UiLang; $script:UiLang = 'en'
    try { Assert ((Tr "상태: $($dx.Grade)") -notmatch '[가-힣]') "영어: $(Tr $dx.Grade)" } finally { $script:UiLang = $lg }
}
It '지난 검사 대비: 같은 이름이라도 하드웨어가 다른 PC 의 기록과 섞지 않음' {
    $a = New-Scenario @{}; $b = New-Scenario @{}; $b.System.CPU = 'Different CPU'
    Assert ((Get-HwFingerprint $a) -ne (Get-HwFingerprint $b)) '지문 다름'; Assert-Eq (Get-HwFingerprint $a) (Get-HwFingerprint (New-Scenario @{})) '같은 PC 는 같은 지문'
    $hist = @([ordered]@{ Created = '2026-11-10T09:00:00'; Computer = $a.Meta.Computer; Fp = (Get-HwFingerprint $b); Health = 40 })
    $dx = Get-Diagnosis -Data $a; Add-Comparison $a $dx $hist
    Assert ($null -eq $dx['Previous']) '다른 PC 기록은 비교 안 함'
    $hist2 = @([ordered]@{ Created = '2026-11-10T09:00:00'; Computer = $a.Meta.Computer; Fp = (Get-HwFingerprint $a); Health = 40 })
    $dx2 = Get-Diagnosis -Data $a; Add-Comparison $a $dx2 $hist2; Assert ($null -ne $dx2['Previous']) '같은 PC 는 비교'
    $g = New-Scenario @{}; $g.Gpus = @([ordered]@{ Name = 'NVIDIA GeForce RTX 5080'; Vendor = 'NVIDIA' }); $g.System.RamGB = 64
    Assert-Eq (Get-HwFingerprint $g) (Get-HwFingerprint $a) '그래픽카드·RAM 교체 후에도 같은 PC (수리 전후 비교 유지)'
    $m1 = New-Scenario @{}; $m1.System.MachineId = (Get-MachineIdHash '4C4C4544-0042-3510-8048-B4C04F4E3132'); $m2 = New-Scenario @{}; $m2.System.MachineId = (Get-MachineIdHash '4C4C4544-0042-3510-8048-B4C04F4E9999')
    Assert ((Get-HwFingerprint $m1) -ne (Get-HwFingerprint $m2)) '같은 모델이라도 보드 ID 가 다르면 다른 PC'
    Assert-Eq (Get-MachineIdHash 'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF') '' '기본값 UUID 무시'
    Assert-Eq (Get-MachineIdHash '03000200-0400-0500-0006-000700080009') '' '흔한 기본값 무시'
    Assert ((Get-MachineIdHash '4C4C4544-0042-3510-8048-B4C04F4E3132') -notmatch '4C4C') '원래 값 저장 안 함'
    $hist3 = @([ordered]@{ Created = '2026-11-10T09:00:00'; Computer = $a.Meta.Computer; Health = 40 })
    $dx3 = Get-Diagnosis -Data $a; Add-Comparison $a $dx3 $hist3; Assert ($null -ne $dx3['Previous']) '지문 없는 예전 기록은 이름만으로'
}
It '해시: FIPS 정책 PC 에서도 동작 (예비 해시는 결정적·12자리), 이력 오류가 나도 보고서 저장' {
    Assert-Eq (Get-ShortHash 'abc') 'ba7816bf8f01' 'SHA-256 앞 6바이트'
    $f1 = Get-FallbackHash 'board|cpu'; Assert-Eq $f1.Length 12 '12자리'; Assert-Eq (Get-FallbackHash 'board|cpu') $f1 '같은 입력 같은 값'
    Assert ((Get-FallbackHash 'board|cpu2') -ne $f1) '다른 입력 다른 값'
    Assert-Eq (Get-FallbackHash '') (Get-FallbackHash '') '빈 문자열'
    $oldWd = $script:WorkDir; $script:WorkDir = Join-Path $OutDir ('wdf_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:WorkDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $script:WorkDir 'history.json'), '{ not json')   # 깨진 이력 파일
    try { $d = New-Scenario @{}; $r = Save-Results -Data $d -Dx (Get-Diagnosis -Data $d) -Dir $OutDir -Track; Assert (Test-Path $r.Html) '이력이 깨져도 보고서 저장' } finally { $script:WorkDir = $oldWd }
}
It '저장: 보고서 생성이 실패해도 원자료(JSON)는 남아 -FromJson 으로 다시 만들 수 있음' {
    $dir = Join-Path $OutDir ('sv_' + [guid]::NewGuid().ToString('N'))
    $orig = ${function:New-HtmlReport}
    try {
        Set-Item function:script:New-HtmlReport { param($Data, $Dx) throw 'boom' }
        $d = New-Scenario @{}; $err = $null
        try { [void](Save-Results -Data $d -Dx (Get-Diagnosis -Data $d) -Dir $dir) } catch { $err = $_.Exception.Message }
        Assert ($err -match '원자료는 저장됨') "오류 안내: $err"
        Assert (@(Get-ChildItem $dir -Filter '*.json').Count -eq 1) 'JSON 저장됨'
    } finally { Set-Item function:script:New-HtmlReport $orig }
    $j = ConvertFrom-PCJson (Get-Content -Raw -Encoding UTF8 (Get-ChildItem $dir -Filter '*.json')[0].FullName)
    Assert ((New-HtmlReport -Data $j -Dx (Get-Diagnosis -Data $j)) -match '<html') 'JSON 으로 다시 생성'
}
It '분석 실패: 예상 못한 오류가 나도 원자료(JSON)는 저장' {
    $dir = Join-Path $OutDir ('dg_' + [guid]::NewGuid().ToString('N'))
    $d = New-Scenario @{}
    Assert-Eq (Invoke-SafeDiagnosis $d $dir).Grade '양호' '정상일 때는 그대로'
    $orig = ${function:Get-Diagnosis}
    try {
        Set-Item function:script:Get-Diagnosis { param($Data) throw 'boom' }
        $err = $null; try { [void](Invoke-SafeDiagnosis $d $dir) } catch { $err = $_.Exception.Message }
        Assert ($err -match '원자료는 저장됨: .+\.json') "안내: $err"
        Assert (@(Get-ChildItem $dir -Filter '*.json').Count -eq 1) 'JSON 저장'
    } finally { Set-Item function:script:Get-Diagnosis $orig }
}
It '빠른 자동 테스트: 같은 6단계를 약 10분으로, 원래 계획은 그대로' {
    $q = Get-QuickPlan
    Assert-Eq (($q | ForEach-Object { $_.Key }) -join ',') (($script:StagePlan | ForEach-Object { $_.Key }) -join ',') '같은 단계'
    # 5.1 의 Measure-Object -Property 는 해시 테이블 키를 읽지 못하므로 직접 합산
    $sq = 0; foreach ($p in $q) { $sq += $p.Sec }; Assert-Eq $sq 600 '10분'
    $sp = 0; foreach ($p in $script:StagePlan) { $sp += $p.Sec }; Assert-Eq $sp 1920 '원래 계획 32분 유지 (복사본 사용)'
    $g = Get-StageAt $q 70; Assert-Eq $g.Key 'cpu' '70초면 CPU 단계'
    $g = Get-StageAt $q 590; Assert-Eq $g.Key 'pulse' '마지막 출렁임'; Assert (Get-StageAt $q 601).Done '끝'
}
It '무인 실행 결과: 파일 경로와 점수·등급·1순위 원인을 돌려줌 (자동화용)' {
    $d = New-Scenario $scenarios['VRAM 불량: Xid 48/63 + TDR 블루스크린'].Data
    $r = Save-Results -Data $d -Dx (Get-Diagnosis -Data $d) -Dir (Join-Path $OutDir ('sl_' + [guid]::NewGuid().ToString('N')))
    Assert (Test-Path $r.Html) '보고서'; Assert ($r.Health -lt 90) "점수 $($r.Health)"; Assert-Eq $r.TopCause 'GPU_HW' '1순위 원인 키'
    Assert ([string]$r.TopCauseName) '원인 이름'; Assert ([string]$r.Grade) '등급'
    $c = New-Scenario @{}; $r2 = Save-Results -Data $c -Dx (Get-Diagnosis -Data $c) -Dir (Join-Path $OutDir ('sl2_' + [guid]::NewGuid().ToString('N')))
    Assert-Eq $r2.TopCause '' '정상 PC 는 원인 없음'; Assert-Eq $r2.Health 100 '100점'
}
It '자동 테스트 종료 예상 시각 표시 (영어 번역)' {
    $now = Get-Date '2026-11-14T14:00:00'
    Assert-Eq (Get-EtaText 1920 $now) '약 14:32 종료' '32분 뒤'
    Assert-Eq (Get-EtaText -30 $now) '약 14:00 종료' '음수는 0'
    $lg = $script:UiLang; $script:UiLang = 'en'
    try { Assert-Eq (Tr (Get-EtaText 600 $now)) 'ends ~14:10' '영어' } finally { $script:UiLang = $lg }
}
It '자동 테스트 완료: 기록을 바로 분석해 판정을 보여 줌 (영어 번역)' {
    $ok = New-Bb2File 'bb_done.csv' (Rep 5 @('pulse', 50, 99, 60, 90, 200, '', 0, '')) -Stop
    $t = Get-BlackboxDoneText $ok
    Assert ($t -match '결과: 블랙박스') "판정 $t"; Assert ($t -match '보고서에도 반영') '안내'
    $ram = New-Bb2File 'bb_done2.csv' (Rep 5 @('ram', 50, 99, 40, 1, 20, '', 2, '')) -Stop
    Assert ((Get-BlackboxDoneText $ram) -match 'RAM') '오류면 상세 포함'
    Assert ((Get-BlackboxDoneText (Join-Path $OutDir 'none.csv')) -match '다시 검사하면') '파일 없으면 기본 안내'
    $lg = $script:UiLang; $script:UiLang = 'en'
    try { $e = Tr (Get-BlackboxDoneText $ok); Assert ($e -notmatch '[가-힣]') "영어: $e" } finally { $script:UiLang = $lg }
}
It '-HideName: 새 블랙박스 기록 파일 이름·머리말에도 실제 PC 이름 대신 코드' {
    $old = $script:HideName; $oldEnv = $env:COMPUTERNAME; $env:COMPUTERNAME = 'HONGGILDONG-PC'
    try {
        $script:HideName = $true
        $job = Start-Blackbox -Dir (Join-Path $OutDir ('bbh_' + [guid]::NewGuid().ToString('N'))) -IntervalSec 0.2 -NoEvents
        $sw = [Diagnostics.Stopwatch]::StartNew(); while ($job.Sync.Rows -lt 1 -and $sw.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 100 }
        Stop-Blackbox $job
        Assert ((Split-Path $job.Path -Leaf) -match '^PCCheck_blackbox_PC-[0-9a-f]{6}_') "파일 이름 $(Split-Path $job.Path -Leaf)"
        Assert ([IO.File]::ReadAllText($job.Path) -notmatch 'HONGGILDONG') '파일 내용에 실제 이름 없음'
        $script:HideName = $false
        $job2 = Start-Blackbox -Dir (Join-Path $OutDir ('bbh2_' + [guid]::NewGuid().ToString('N'))) -IntervalSec 0.2 -NoEvents; Stop-Blackbox $job2
        Assert ((Split-Path $job2.Path -Leaf) -match 'HONGGILDONG-PC') '기본은 실제 이름'
    } finally { $script:HideName = $old; $env:COMPUTERNAME = $oldEnv }
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
It 'CPU 부하: 컴파일된 고부하 연산으로 동작, 일시정지(출렁임)·중지' {
    $c = Start-CpuStress -Threads 2
    try {
        Assert $c.Native '컴파일된 부하 사용'
        $sw = [Diagnostics.Stopwatch]::StartNew(); while ($c.Sync.Loops -lt 2 -and $sw.Elapsed.TotalSeconds -lt 20) { Start-Sleep -Milliseconds 50 }
        Assert ($c.Sync.Loops -ge 2) "연산 진행 ($($c.Sync.Loops))"
        $c.Sync.Pause = $true; Start-Sleep -Milliseconds 800; $p0 = $c.Sync.Loops; Start-Sleep -Milliseconds 800
        Assert ($c.Sync.Loops - $p0 -le 2) "일시정지 중 거의 멈춤 ($($c.Sync.Loops - $p0))"
        $c.Sync.Pause = $false; $p1 = $c.Sync.Loops; $sw.Restart(); while ($c.Sync.Loops -le $p1 -and $sw.Elapsed.TotalSeconds -lt 20) { Start-Sleep -Milliseconds 50 }
        Assert ($c.Sync.Loops -gt $p1) '다시 시작'
    } finally { Stop-CpuStress $c }
    $s0 = $c.Sync.Loops; Start-Sleep -Milliseconds 500; Assert-Eq $c.Sync.Loops $s0 '중지 후 멈춤'
}
It '블랙박스 실시간 오류 감시: 정보 이벤트(USB 연결 시 Ntfs 98 등)는 제외' {
    $f = Get-HwEventFilter (Get-Date).AddMinutes(-1)
    Assert ($f.ContainsKey('Level')) '심각도 필터 있음'
    Assert (-not (@($f.Level) -contains 4)) '정보(4) 제외'
    Assert ((@($f.Level) -contains 2) -and (@($f.Level) -contains 1)) '오류·위험 포함'
    Assert (@($f.ProviderName) -contains 'Microsoft-Windows-WHEA-Logger') 'WHEA 감시'
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
It 'Measure-Object -Property 미사용 (5.1 은 해시 테이블 키를 못 읽어 오류 — 79회 CI 실패 원인)' {
    foreach ($f in (Join-Path $PSScriptRoot '..\PCCheck.ps1'), $PSCommandPath) {
        $bad = @(Select-String -Path $f -Pattern 'Measure-Object\s+-Prop\w*\s+[A-Za-z$(]' | Where-Object { $_.Line -notmatch "Select-String -Path" })
        Assert ($bad.Count -eq 0) "$(Split-Path $f -Leaf) 줄 $(($bad | ForEach-Object LineNumber) -join ',')"
    }
}
It 'Where-Object 축약형(Where-Object Key -eq ...) 미사용 — 5.1 에서 해시 테이블 항목은 조용히 빠짐' {
    $bad = @(Select-String -Path (Join-Path $PSScriptRoot '..\PCCheck.ps1') -Pattern 'Where-Object\s+[A-Za-z]\w*\s+-(eq|ne|match|like|gt|lt|ge|le|in|contains)\b')
    Assert ($bad.Count -eq 0) "줄 $(($bad | ForEach-Object LineNumber) -join ',') — 스크립트 블록 { `$_.Key -eq ... } 사용"
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

It '날짜 형식은 지역 설정(태국 불기 등)과 무관' {
    $old = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture = New-Object Globalization.CultureInfo('th-TH')
        Assert-Eq (Get-FileStamp ([datetime]'2026-03-04T05:06:07')) '20260304_050607' '불기 연도 아님'
    } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $old }
    $src = [IO.File]::ReadAllText((Join-Path $root 'PCCheck.ps1'))
    Assert (-not ($src -match '\{\d:yyyy')) '-f 날짜 서식 없음'
    $bad = @([regex]::Matches($src, "ToString\('[yMdHms:_ -]+'\)") | ForEach-Object { $_.Value })
    Assert-Eq $bad.Count 0 "InvariantCulture 없는 날짜 ToString: $($bad -join ', ')"
}
Write-Host "`n결과: 통과 $script:pass · 실패 $script:fail" -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
Remove-Item $OutDir -Recurse -Force -ErrorAction SilentlyContinue
if ($script:fail) { exit 1 }

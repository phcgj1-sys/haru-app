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
It '전원 버튼 강제 종료는 파워 점수를 낮춤' {
    $a = Get-Diagnosis -Data (New-Scenario @{ Shutdowns = @(1..3 | ForEach-Object { [ordered]@{ T = (T $_); Code = ''; PowerButton = $false } }) })
    $b = Get-Diagnosis -Data (New-Scenario @{ Shutdowns = @(1..3 | ForEach-Object { [ordered]@{ T = (T $_); Code = ''; PowerButton = $true } }) })
    $pa = (@($a.Causes) | Where-Object Key -eq 'PSU').Score; $pb = (@($b.Causes) | Where-Object Key -eq 'PSU').Score
    Assert ($pa -gt [int]$pb) "버튼 없음 $pa > 버튼 $pb"
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

Write-Host "`n[유틸]" -ForegroundColor Cyan
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
    Assert (Test-Path $r.Html) 'html 존재'; Assert (Test-Path $r.Json) 'json 존재'
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

It '백그라운드 수집: 진행 상황 전달 후 데이터 반환' {
    $job = Start-CollectAsync -Days 3
    $sw = [Diagnostics.Stopwatch]::StartNew(); $seen = 0
    while (-not $job.Sync.Done -and $sw.Elapsed.TotalSeconds -lt 120) { if ($job.Sync.I -gt $seen) { $seen = $job.Sync.I }; Start-Sleep -Milliseconds 100 }
    Assert $job.Sync.Done '120초 안에 완료'
    $data = Complete-CollectAsync $job
    Assert ($null -eq $job.Sync.Error) "오류: $($job.Sync.Error)"
    Assert ($null -ne $data) '데이터 반환'
    Assert-Eq $job.Sync.N 11 '단계 수 전달'
    Assert-Eq $data.Meta.Days 3 '기간 전달'
    [void](Get-Diagnosis -Data $data)
}

Write-Host "`n[블랙박스]" -ForegroundColor Cyan
function New-BbFile([string]$name, [object[]]$rows, [switch]$Stop, [string]$Tail) {
    $p = Join-Path $OutDir $name
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $l = @('# PCCheck blackbox,v1,TEST,2026-11-14T10:00:00,2.1.0', $script:BlackboxCols)
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
It '실제 기록기: 줄 기록 후 중지 표시, CPU 부하 시작/중지' {
    $job = Start-Blackbox -Dir (Join-Path $OutDir 'bb') -IntervalSec 0.3 -NoEvents
    $cpu = Start-CpuStress -Threads 2
    Start-Sleep -Seconds 2
    Stop-CpuStress $cpu
    Stop-Blackbox $job
    Assert ($null -eq $job.Sync.Error) "오류: $($job.Sync.Error)"
    $lines = @(Get-Content $job.Path)
    Assert ($lines.Count -ge 5) "줄 수 $($lines.Count)"
    Assert ($lines[-1] -match ',STOP$') '중지 표시'
    $a = Read-BlackboxAnalysis $job.Path; Assert (-not $a.Abrupt) '정상 종료'
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
It '배치 파일은 ASCII + CRLF' {

    $bat = Get-ChildItem $root -Filter *.bat
    Assert ($bat.Count -ge 1) 'bat 존재'
    foreach ($f in $bat) { $b = [IO.File]::ReadAllBytes($f.FullName); Assert (@($b | Where-Object { $_ -gt 127 }).Count -eq 0) "$($f.Name) ASCII"; Assert ([Text.Encoding]::ASCII.GetString($b) -match "`r`n") "$($f.Name) CRLF" }
}

Write-Host "`n결과: 통과 $script:pass · 실패 $script:fail" -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
Remove-Item $OutDir -Recurse -Force -ErrorAction SilentlyContinue
if ($script:fail) { exit 1 }

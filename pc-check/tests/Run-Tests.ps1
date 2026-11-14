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

Write-Host "`n[유틸]" -ForegroundColor Cyan
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
It '배치 파일은 ASCII + CRLF' {
    $bat = Get-ChildItem $root -Filter *.bat
    Assert ($bat.Count -ge 1) 'bat 존재'
    foreach ($f in $bat) { $b = [IO.File]::ReadAllBytes($f.FullName); Assert (@($b | Where-Object { $_ -gt 127 }).Count -eq 0) "$($f.Name) ASCII"; Assert ([Text.Encoding]::ASCII.GetString($b) -match "`r`n") "$($f.Name) CRLF" }
}

Write-Host "`n결과: 통과 $script:pass · 실패 $script:fail" -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
Remove-Item $OutDir -Recurse -Force -ErrorAction SilentlyContinue
if ($script:fail) { exit 1 }

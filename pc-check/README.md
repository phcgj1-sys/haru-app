# PC 원클릭 진단

**갑자기 꺼짐 · 블루스크린 · 그래픽카드(VRAM) · RAM · 디스크** 문제의 원인을 Windows 기록으로 찾아
가능성 높은 순서대로 알려 주고, 해결 순서까지 안내하는 Windows 10/11용 진단 도구입니다.

- 설치 없음 · 인터넷 없이 동작 · **어떤 정보도 외부로 보내지 않음**
- 결과: 상태 점수(0~100), 의심 원인 Top 3(근거 + 해결 순서), 날짜별 차트, A/S 상담용 요약
- **지난 검사 대비**: 부품 교체·설정 변경 후 다시 검사하면 "그 이후 새로 생긴 문제"를 맨 위에 표시 → 수리 효과 확인

## 사용법
1. ZIP 을 **압축 해제** (압축 상태에서 바로 실행하면 안 됩니다)
2. `원클릭검사.bat` 더블클릭 → 관리자 권한 "예"
3. **검사 시작** 클릭 → 5~40초 후 보고서가 자동으로 열립니다 (`바탕화면\PC진단` 에 저장)

`PC원클릭진단.exe` 가 포함된 배포본이라면 exe 를 더블클릭해도 됩니다 (관리자 권한 요청 내장).

> Windows 가 "PC 보호" 창을 띄우면 **추가 정보 → 실행**을 누르세요 (서명되지 않은 스크립트라 표시됩니다).
> 화면 없이 쓰려면 `콘솔모드.bat`.

## 무엇을 분석하나
| 항목 | 근거 | 판단 예 |
|---|---|---|
| 갑자기 꺼짐 | Kernel-Power 41 (코드 0), 6008 | 블루스크린 없이 꺼짐 → 파워·과열·전원 접촉 / 전원 버튼 강제 종료·절전 복귀 중 꺼짐 구분 |
| 블루스크린 | BugCheck 1001 + **미니덤프 헤더 직접 판독** | 30여 개 코드별 원인 가중치 (0x116=그래픽, 0x124=하드웨어, 0x1A=RAM…) |
| 그래픽카드 | TDR 4101, LiveKernelEvent 141/117, nvlddmkm·amdkmdag | NVIDIA Xid 48/63/64/94/95 = **VRAM 오류**, Xid 79 = 버스 이탈 |
| 상관분석 | 이벤트 시간 비교 | 그래픽 오류 직후 15분 내 꺼짐 → 고부하 전력 부족 / 드라이버 설치 직후 문제 시작 |
| 하드웨어 | WHEA 17/18/19/47 | PCIe·CPU·메모리 하드웨어 오류 |
| RAM | 모듈 정보, Windows 메모리 진단 결과 | XMP/EXPO 사용, 서로 다른 RAM 혼용 |
| 디스크 | SMART(상태·온도·마모·읽기오류), disk/Ntfs/stornvme 오류 | |
| 기타 | nvidia-smi 온도, 오버클럭 도구, 드라이버·BIOS 연식, Intel 13/14세대, 가상 머신 감지 | |

## 정밀 검사 (공식 출처에서 받아 실행)
| 버튼 | 도구 | 용도 |
|---|---|---|
| 그래픽카드 VRAM 검사 | memtest_vulkan (GitHub, SHA-256 검증) | VRAM 불량 확인 |
| 블루스크린 원인 드라이버 | NirSoft BlueScreenView | 원인 .sys 파일 확인 |
| RAM 검사 | Windows 메모리 진단 | 재부팅 후 RAM 검사 |
| 온도·전압 모니터링 | HWiNFO (사이트) | 실시간 센서 |
| 파워·GPU 부하 테스트 | OCCT (사이트) | 파워·VRAM 부하 |

라이선스·판매 시 주의: [THIRD-PARTY.md](THIRD-PARTY.md)

## 원격 상담 (기술자용)
보고서 옆의 `.json` 파일을 받으면 어느 PC 에서든 같은 보고서를 다시 만들 수 있습니다.
```powershell
powershell -ExecutionPolicy Bypass -File PCCheck.ps1 -FromJson "PC진단_20261114_120000.json"
```

## 명령줄 옵션
| 옵션 | 설명 |
|---|---|
| `-Mode Gui / Console / Silent` | 화면 / 콘솔+메뉴 / 무인(보고서만) |
| `-Days 90` | 분석 기간 (1~365일) |
| `-OutDir D:\reports` | 저장 위치 |
| `-FromJson file.json` | 저장된 진단 데이터로 보고서 재생성 |
| `-NoOpen` | 보고서 자동 열기 끔 |
| `-Lang en` | 영어 보고서·화면 (기본 `auto`: Windows 언어가 한국어면 한국어, 아니면 영어) |

로그: `%LOCALAPPDATA%\PCCheck\logs` · 검사 이력: `%LOCALAPPDATA%\PCCheck\history.json`

## 개발
- 테스트: `pwsh -File tests/Run-Tests.ps1` (PowerShell 5.1 / 7, 원인 시나리오 9종 + 회귀 테스트, 외부 모듈 불필요)
- CI: `.github/workflows/pc-check.yml` — windows-latest 에서
  단위 테스트(5.1·7) → PSScriptAnalyzer(5.1 호환) → 실제 검사(5.1·7) → GUI 레이아웃 자동 검사(배율 100~200%) →
  외부 도구 실제 다운로드·SHA-256 검증 → EXE 빌드(ps2exe) → 배포 ZIP
- EXE 직접 빌드: `powershell -File build/Build-Exe.ps1 -OutDir dist` (Windows PowerShell 5.1)

- 소스 규칙: `PCCheck.ps1` 은 UTF-8 **BOM** + CRLF (5.1 한글 깨짐 방지), `.bat` 은 ASCII + CRLF

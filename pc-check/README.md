# PC 원클릭 진단 (갑작스런 종료 · 그래픽카드 VRAM · RAM)

Windows 10/11용입니다. **`원클릭검사.bat` 더블클릭** → 관리자 권한 허용 → 끝.

## 1단계: 자동 분석 (설치 없음, 약 10~30초)
Windows가 남긴 최근 30일 기록을 분석해 **바탕화면에 HTML 보고서**를 만들고 자동으로 엽니다.

| 항목 | 보는 기록 | 알 수 있는 것 |
|---|---|---|
| 갑작스런 종료 | Kernel-Power 41, EventLog 6008 | 코드 0 = 블루스크린 없이 꺼짐 → **파워(PSU)·과열·전원 케이블** 의심 |
| 블루스크린 | BugCheck 1001, Minidump | 0x116/0x117 = 그래픽, 0x124 = 하드웨어, 0x1A/0x50 = RAM 등 해설 |
| 그래픽카드 | Display 4101(TDR), nvlddmkm(Xid), amdkmdag | NVIDIA Xid 48/63/64/94/95 = **VRAM 오류 신호** |
| 하드웨어 | WHEA-Logger 17/18/19/47 | PCIe·CPU·메모리 하드웨어 오류 |
| RAM | 모듈 정보, 이전 Windows 메모리 진단 결과 | 슬롯·속도(XMP)·오류 여부 |
| 디스크 | SMART 상태·온도·마모도, disk/Ntfs 오류 | 멈춤·블루스크린의 디스크 원인 |
| 온도 | nvidia-smi(NVIDIA), ACPI 센서 | 과열 여부 |

## 2단계: 정밀 검사 메뉴 (평판 좋은 외부 도구)
| 메뉴 | 도구 | 출처 | 용도 |
|---|---|---|---|
| 1 | **memtest_vulkan** | GitHub `GpuZelenograd/memtest_vulkan` (오픈소스, 최신 릴리스 자동 다운로드) | **VRAM 검사** — NVIDIA·AMD·Intel 모두 지원 |
| 2 | **BlueScreenView** | NirSoft (자동 다운로드) | 블루스크린 원인 드라이버 확인 |
| 3 | **Windows 메모리 진단** | Windows 기본 내장 | RAM 검사 (재부팅) |
| 4 | **HWiNFO** | 공식 사이트 | 온도·전압·전력 실시간 감시 |
| 5 | **OCCT** | 공식 사이트 | 파워·GPU·VRAM 종합 부하 테스트 |

도구는 `%LOCALAPPDATA%\PCCheck` 에 받아지며, 지우면 깔끔히 정리됩니다.

## 결과 읽는 법 (자주 나오는 경우)
- **게임 중 블루스크린 없이 꺼짐(코드 0) 반복** → PSU 용량/노후, 그래픽카드 보조전원 케이블(각각 별도 케이블로), 과열
- **TDR 4101 / 0x116 반복** → DDU로 드라이버 완전 삭제 후 재설치 → 그래도면 memtest_vulkan으로 VRAM 확인
- **memtest_vulkan 에서 error** → VRAM 불량 (오버클럭 해제 후에도 나오면 A/S)
- **WHEA 47 / 0x1A** → XMP·EXPO 끄고 RAM 검사, 한 개씩 꽂아 테스트
- **WHEA 17(PCIe)** → 그래픽카드 재장착, BIOS에서 PCIe 세대 고정

옵션: PowerShell에서 `.\PCCheck.ps1 -Days 90` (기간 변경), `-NoMenu` (보고서만).

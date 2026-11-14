/* PC방 게임 점검 — 데이터
   - 순위: 게임트릭스 PC방 점유율(2026-11-08 일간). 더로그 주간 순위와 조금 다를 수 있음.
   - 요구 사양: 각 게임 공식 안내(라이엇·크래프톤·넥슨·블리자드·스마일게이트·엔씨소프트·로블록스) 기준. 바뀔 수 있음.
   - 부품 점수: PassMark G3D Mark / CPU Mark(전체·단일) 근사치(±10%). 상대 비교용.
   - fps 보정값: g3060 = RTX 3060·1080p·중간 옵션에서 그래픽 한계 fps, c12400 = i5-12400에서 CPU 한계 fps (커뮤니티 벤치마크 경향을 반영한 추정치). cap = 게임 자체 프레임 상한. */
window.RANK_SOURCE = '순위: 게임트릭스 PC방 점유율 2026-11-08';
window.GAMES = [
  { id: 'lol', rank: 1, name: '리그 오브 레전드', short: '롤', share: '34.1%',
    min: { os: 'win10', cpu: ['i3-530', 'A6-3650'], gpu: ['Intel HD 4600', 'HD 6570', 'GT 430'], ram: 2, vram: 1, storage: '16GB' },
    rec: { os: 'win11', cpu: ['i5-8250U', 'Ryzen 3 1200'], gpu: ['GTX 560', 'HD 6950', 'Intel UHD 630'], ram: 4, vram: 2, storage: '16GB SSD' },
    fps: { e: 0.75,  g3060: 480, c12400: 340, cap: 500 },
    checks: ['라이엇 뱅가드(커널 안티치트) 필요 · Windows 10 빌드 19041 이상', 'DirectX 11 필수(DX9 지원 종료) · CPU가 SSE4.2를 지원해야 함'],
    src: 'support.riotgames.com 최소·권장 사양' },
  { id: 'val', rank: 2, name: '발로란트', short: '발로란트', share: '10.2%',
    min: { os: 'win10', cpu: ['Core 2 Duo E8400', 'Athlon 200GE'], gpu: ['Intel HD 4000', 'R5 230'], ram: 4, vram: 1, storage: '약 50GB' },
    rec: { os: 'win10', cpu: ['i5-9400F', 'Ryzen 5 2600X'], gpu: ['GTX 1050 Ti', 'R7 370'], ram: 4, vram: 1, storage: '약 50GB SSD' },
    fps: { e: 0.75,  g3060: 480, c12400: 420, cap: 900 },
    tiers: '공식: 최소 30fps · 권장(i3-4150/GT 730) 60fps · 고사양(i5-9400F/GTX 1050 Ti) 144fps 이상',
    checks: ['라이엇 뱅가드 필요 · Windows 11은 TPM 2.0과 보안 부팅(Secure Boot)이 켜져 있어야 함(VAN9001/9003 오류)', '공식 고사양 기준 = 144fps 이상'],
    src: 'support-valorant.riotgames.com 최소 사양' },
  { id: 'pubg', rank: 3, name: '배틀그라운드', short: '배그', share: '9.1%',
    min: { os: 'win10', cpu: ['i5-4430', 'FX-6300'], gpu: ['GTX 960', 'R7 370'], ram: 8, vram: 2, storage: '40GB' },
    rec: { os: 'win10', cpu: ['i5-6600K', 'Ryzen 5 1600'], gpu: ['GTX 1060 3GB', 'RX 580'], ram: 16, vram: 3, storage: '50GB SSD' },
    fps: { e: 0.9,  g3060: 150, c12400: 175, cap: null },
    checks: ['64비트 전용 · DirectX 11'],
    src: 'Steam 상점 페이지(app 578080)·pubg.com' },
  { id: 'fco', rank: 4, name: 'FC 온라인', short: 'FC 온라인', share: '8.1%',
    min: { os: 'win10', cpu: ['i3-2100', 'Athlon II X4 620'], gpu: ['GT 730', 'HD 7570'], ram: 4, vram: 1, storage: '40GB' },
    rec: { os: 'win10', cpu: ['i5-2550K', 'FX-6350'], gpu: ['GTX 460', 'HD 6870'], ram: 8, vram: 1, storage: '40GB' },
    fps: { e: 0.8,  g3060: 320, c12400: 260, cap: null },
    checks: ['DirectX 11 · 넥슨 런처'],
    src: 'fconline.nexon.com 게임 가이드(공식 사양 표기)' },
  { id: 'ow', rank: 5, name: '오버워치 2', short: '오버워치', share: '5.6%',
    min: { os: 'win10', cpu: ['i3-2100', 'Phenom X3 8650'], gpu: ['GTX 650', 'HD 7750'], ram: 6, vram: 1, storage: '50GB' },
    rec: { os: 'win10', cpu: ['i7-4770', 'Ryzen 5 1600'], gpu: ['GTX 1060 6GB', 'R9 380'], ram: 8, vram: 3, storage: '50GB' },
    fps: { e: 0.85,  g3060: 230, c12400: 340, cap: 600 },
    checks: ['공식 CPU 표기가 "Core i3 / Core i7 / Ryzen 5"처럼 세대가 없어 대표 모델로 계산', '배틀넷 계정 · 일부 계정은 휴대폰 인증(SMS) 필요'],
    src: 'support.blizzard.com 오버워치 2 시스템 요구 사항' },
  { id: 'sa', rank: 6, name: '서든어택', short: '서든', share: '4.5%',
    min: { os: 'win10', cpu: ['Core 2 Duo E6300'], gpu: ['7600 GT'], ram: 2, storage: '40GB' },
    rec: { os: 'win10', cpu: ['i5-2500'], gpu: ['9600 GT'], ram: 8, storage: '40GB' },
    fps: { e: 0.75,  g3060: 520, c12400: 300, cap: null },
    checks: ['공식 사양은 기본 해상도·기본 옵션 기준(엔진이 가벼워 CPU 단일 코어 영향이 큼)'],
    src: 'sa.nexon.com 설치 가이드' },
  { id: 'rbx', rank: 7, name: '로블록스', short: '로블록스', share: '4.0%',
    min: { os: 'win10', cpu: ['Core 2 Duo E8400'], gpu: ['GT 710'], ram: 2, storage: '300MB' },
    rec: { os: 'win10', cpu: ['i5-4460'], gpu: ['GTX 750 Ti'], ram: 8, storage: '1GB' },
    fps: { e: 0.8,  g3060: 320, c12400: 240, cap: 240 },
    checks: ['공식 권장 사양이 따로 없어 권장은 대표값 · DirectX 10 이상 그래픽 필요', '하이페리온 안티치트: 가상 머신에서 실행 불가', '체험(맵)마다 무게 차이가 아주 큼'],
    src: 'en.help.roblox.com 시스템 요구 사항' },
  { id: 'lin', rank: 8, name: '리니지 클래식', short: '리니지', share: '3.1%',
    min: { os: 'win10', cpu: ['i3-4130', 'Ryzen 3 1200'], gpu: ['GTX 1050 Ti', 'RX 580'], ram: 8, vram: 4, storage: 'SSD 40GB' },
    rec: { os: 'win11', cpu: ['i5-11400', 'Ryzen 5 5600'], gpu: ['GTX 1050 Ti', 'RX 580'], ram: 16, vram: 4, storage: 'SSD 40GB' },
    fps: { e: 0.85,  g3060: 200, c12400: 160, cap: null },
    checks: ['공식 CPU 표기는 "인텔 4세대 / 라이젠 1000 이상(최소)", "인텔 11세대 / 라이젠 5000 이상(권장)" → 대표 모델로 계산', 'OpenGL 4.3 이상 · 퍼플(PURPLE) 런처 · SSD 필수'],
    src: 'lineageclassic.plaync.com 다운로드 페이지' },
  { id: 'maple', rank: 9, name: '메이플스토리', short: '메이플', share: '2.5%',
    min: { os: 'win10', cpu: ['Pentium E5200'], gpu: ['GT 430', 'HD 5670'], ram: 4, storage: '35GB' },
    rec: { os: 'win10', cpu: ['Pentium E5200'], gpu: ['GT 430', 'HD 5670'], ram: 8, storage: '35GB' },
    fps: { e: 0.7,  g3060: 400, c12400: 200, cap: null },
    checks: ['공식 안내는 권장 사양만 있음(펜티엄 듀얼코어 이상 · GT 430 이상) → 최소도 같은 값, RAM만 4GB로 계산', '2024-06-20부터 Windows 10 미만 지원 종료', '보스전·사냥터 이펙트가 많으면 CPU 단일 코어가 병목'],
    src: 'maplestory.nexon.com 다운로드·공지' },
  { id: 'la', rank: 10, name: '로스트아크', short: '로아', share: '1.7%',
    min: { os: 'win10', cpu: ['i3-10100', 'Ryzen 3 3100'], gpu: ['GTX 1050 Ti', 'RX 560'], ram: 16, vram: 4, storage: '110GB' },
    rec: { os: 'win10', cpu: ['i5-9400F', 'Ryzen 5 2600'], gpu: ['GTX 1660 Super', 'RX 6600'], ram: 16, vram: 6, storage: '110GB SSD' },
    fps: { e: 0.9,  g3060: 125, c12400: 140, cap: null },
    tiers: '공식: FHD 60Hz 최소/권장, QHD 권장(i5-11400/RTX 3060), UHD 권장(i5-12400/RTX 3080·RAM 32GB)',
    checks: ['공식 사양은 해상도별 60Hz 기준 · SSD 권장(110GB 여유)'],
    src: 'lostark.game.onstove.com 다운로드 페이지' }
];

/* 브라우저 인터넷 측정 대상(no-cors 요청 시간). 게임 매치 서버가 아니라 각 회사 웹/CDN 서버예요. */
window.NET_TARGETS = [
  { name: '클라우드플레어 (1.1.1.1)', url: 'https://1.1.1.1/cdn-cgi/trace' },
  { name: '구글', url: 'https://www.google.com/generate_204' },
  { name: '네이버', url: 'https://www.naver.com/favicon.ico' },
  { name: '넥슨 (웹)', url: 'https://www.nexon.com/favicon.ico' },
  { name: '라이엇 (웹)', url: 'https://www.leagueoflegends.com/favicon.ico' }
];

/* 그래픽: 이름|G3D 점수|VRAM(GB)|별칭(쉼표) */
window.GPU_TABLE = `
7600 GT|180|0.25|geforce 7600gt
9600 GT|750|0.5|9600gt
GT 430|600|1
GT 440|750|1
GTX 460|2400|1
GTX 560|2950|1
GTX 560 Ti|3400|1
GT 710|640|2
GT 730|1000|2
GT 1030|2600|2
GTX 650|1850|1
GTX 660|4100|2
GTX 750 Ti|3900|2
GTX 750|3300|1
GTX 760|4950|2
GTX 770|6000|2
GTX 780|7300|3
GTX 950|5300|2
GTX 960|6000|2
GTX 970|9600|4
GTX 980|11100|4
GTX 1050|4300|2
GTX 1050 Ti|6300|4
GTX 1060 3GB|9000|3|gtx 1060 3gb
GTX 1060 6GB|10000|6|gtx 1060,gtx 1060 6gb
GTX 1070|13400|8
GTX 1070 Ti|14500|8
GTX 1080|15400|8
GTX 1080 Ti|18400|11
GTX 1630|3700|4
GTX 1650|7800|4
GTX 1650 Super|10000|4
GTX 1660|11400|6
GTX 1660 Super|12700|6
GTX 1660 Ti|12900|6
RTX 2060|14000|6
RTX 2060 Super|16300|8
RTX 2070|16000|8
RTX 2070 Super|18300|8
RTX 2080|18700|8
RTX 2080 Super|19600|8
RTX 2080 Ti|21700|11
RTX 3050|12800|8
RTX 3060|17000|12
RTX 3060 Ti|20200|8
RTX 3070|22300|8
RTX 3070 Ti|23500|8
RTX 3080|25000|10
RTX 3080 Ti|26800|12
RTX 3090|26600|24
RTX 3090 Ti|29000|24
RTX 4060|19600|8
RTX 4060 Ti|22500|8
RTX 4070|26900|12
RTX 4070 Super|30000|12
RTX 4070 Ti|31500|12
RTX 4070 Ti Super|31800|16
RTX 4080|34500|16
RTX 4080 Super|34800|16
RTX 4090|38300|24
RTX 5060|22000|8
RTX 5060 Ti|25500|8
RTX 5070|28500|12
RTX 5070 Ti|32500|16
RTX 5080|36000|16
RTX 5090|39000|32
HD 5670|900|1
HD 5770|2300|1
HD 6570|1100|1
HD 6870|3100|1
HD 6950|3700|2
HD 7570|1000|1
HD 7750|1900|1
HD 7770|2900|1
HD 7850|4000|2
HD 7870|4700|2
HD 7950|5200|3
R5 230|450|1|r5 200
R7 240|1100|2
R7 260X|2950|2
R7 370|4500|2
R9 270|4500|2
R9 280|5500|3
R9 290|8300|4
R9 380|5900|4
R9 390|8900|8
RX 460|3700|2
RX 470|7400|4
RX 480|8200|8
RX 550|2900|2
RX 560|3700|4
RX 570|7300|4
RX 580|8600|8|rx 580 2048sp
RX 590|8900|8
RX 5500 XT|9000|8
RX 5600 XT|13600|6
RX 5700|14700|8
RX 5700 XT|16000|8
RX 6400|7300|4
RX 6500 XT|9300|4
RX 6600|15300|8
RX 6600 XT|16300|8
RX 6650 XT|16700|8
RX 6700 XT|19400|12
RX 6750 XT|20200|12
RX 6800|22400|16
RX 6800 XT|25200|16
RX 6900 XT|26900|16
RX 6950 XT|28000|16
RX 7600|16900|8
RX 7600 XT|17500|16
RX 7700 XT|21500|12
RX 7800 XT|23400|16
RX 7900 GRE|25500|16
RX 7900 XT|27800|20
RX 7900 XTX|30500|24
RX 9060 XT|20500|16
RX 9070|25500|16
RX 9070 XT|27500|16
Intel HD 4000|450||hd 4000
Intel HD 4600|650||hd 4600
Intel HD 530|1000||hd 530
Intel HD 520|950||hd 520
Intel UHD 620|1000||uhd 620
Intel UHD 630|1350||uhd 630
Intel UHD 730|1300||uhd 730
Intel UHD 750|1500||uhd 750
Intel UHD 770|1700||uhd 770
Intel Iris Xe|2800||iris xe
Arc A380|6300|6|intel arc a380
Arc A750|13400|8|intel arc a750
Arc A770|14500|16|intel arc a770
Arc B570|14000|10|intel arc b570
Arc B580|15900|12|intel arc b580
Radeon Vega 8|1900||vega 8
Radeon Vega 7|1700||vega 7
Radeon Vega 11|2400||vega 11
Radeon 610M|1300||610m
Radeon 680M|6100||680m
Radeon 780M|7400||780m
`;

/* CPU: 이름|CPU Mark 전체|단일 코어|스레드|별칭(쉼표) */
window.CPU_TABLE = `
Core 2 Duo E6300|500|650|2
Core 2 Duo E8400|1000|1250|2
Pentium E5200|800|850|2|pentium dual core
Phenom X3 8650|800|650|3
Athlon II X4 620|1700|800|4
A6-3650|1900|850|4
i3-530|1150|1050|4
i3-2100|1650|1450|4
i3-4130|2350|1900|4
i3-4150|2400|1950|4
i3-4160|2450|1950|4
i3-6100|3500|2100|4
i3-8100|6100|2300|4
i3-10100|8800|2650|8|i3-10100f
i3-10105|9000|2750|8|i3-10105f
i3-12100|14200|3500|8
i3-13100|15000|3700|8
i5-750|2500|1050|4
i5-2300|3400|1350|4
i5-2400|3800|1450|4
i5-2500|3900|1550|4
i5-2500K|4100|1550|4
i5-2550K|4200|1600|4
i5-3330|4300|1650|4|i5-3300
i5-3470|4650|1750|4
i5-3570K|4900|1850|4
i5-4430|4500|1800|4
i5-4460|4700|1900|4
i5-4570|5100|2000|4
i5-4590|5250|2050|4
i5-4670|5400|2100|4
i5-4690K|5700|2200|4|i5-4690
i5-6400|5100|1850|4
i5-6500|5600|2000|4
i5-6600|6100|2150|4
i5-6600K|6500|2300|4
i5-7400|5900|2100|4
i5-7500|6300|2250|4
i5-8250U|6100|1900|8
i5-8400|9200|2400|6
i5-8500|9600|2500|6
i5-8600K|10000|2650|6|i5-8600
i5-9600K|11000|2800|6|i5-9600kf,i5-9600
i5-9400F|9500|2450|6|i5-9400
i5-10400|12100|2650|12|i5-10400f
i5-10500|12800|2750|12
i5-10600K|14300|2900|12|i5-10600kf
i5-11400|17000|3050|12|i5-11400f
i5-11600K|19800|3300|12|i5-11600kf
i5-12400|19500|3500|12|i5-12400f
i5-12500|20500|3600|12
i5-13500|31500|3850|20
i5-13400|25000|3750|16|i5-13400f
i5-14400|25800|3800|16|i5-14400f
i5-12600K|27500|3900|16|i5-12600kf
i5-13600K|38000|4250|20|i5-13600kf
i5-14600K|39500|4400|20|i5-14600kf
i7-860|2900|1150|8
i7-2600|5300|1600|8
i7-2600K|5500|1700|8
i7-3770|6400|1950|8
i7-4770|7000|2200|8
i7-4790|7200|2300|8|i7-4790k
i7-6700|8000|2350|8|i7-6700k
i7-7700|8600|2550|8|i7-7700k
i7-8700|13000|2700|12|i7-8700k
i7-9700|14200|2800|8|i7-9700k,i7-9700f
i7-10700|17500|2950|16|i7-10700k,i7-10700f
i7-11700|21500|3300|16|i7-11700k,i7-11700f
i7-12700|31000|3900|20|i7-12700k,i7-12700f,i7-12700kf
i7-13700|34500|4200|24|i7-13700k,i7-13700f,i7-13700kf
i7-14700|41000|4350|28|i7-14700k,i7-14700f,i7-14700kf
i9-9900K|18800|2900|16|i9-9900
i9-12900K|41000|4200|24|i9-12900
i9-13900K|59000|4650|32|i9-13900
i9-14900K|60500|4800|32|i9-14900
Core Ultra 5 245K|43000|4500|14|ultra 5 245
Core Ultra 7 265K|58000|4800|20|ultra 7 265
Core Ultra 9 285K|67000|5050|24|ultra 9 285
Phenom II X4 940|2300|1150|4
Phenom II X4 965|2600|1250|4
FX-4300|3300|1500|4
FX-6300|4300|1500|6
FX-6350|4600|1550|6
FX-8350|6000|1550|8
Athlon 200GE|2900|1750|4
Ryzen 3 1200|6200|2000|4
Ryzen 3 2200G|6800|2100|4
Ryzen 3 3200G|7200|2250|4
Ryzen 5 3400G|9300|2350|8
Ryzen 5 4600G|16000|2700|12
Ryzen 3 3100|11800|2550|8
Ryzen 3 4100|11000|2550|8
Ryzen 5 1400|7600|1900|8
Ryzen 5 1500X|8500|2050|8
Ryzen 5 1600|12400|2050|12|ryzen 5 1600x,ryzen 5 1600af
Ryzen 5 2600|13300|2300|12
Ryzen 5 2600X|13900|2400|12
Ryzen 5 3500|12800|2550|6|ryzen 5 3500x
Ryzen 5 3600|17800|2600|12|ryzen 5 3600x
Ryzen 5 4500|16300|2600|12
Ryzen 5 5500|19500|3000|12
Ryzen 5 5600|21500|3250|12|ryzen 5 5600g
Ryzen 5 5600X|22000|3350|12
Ryzen 5 7500F|26500|3900|12
Ryzen 5 7600|27000|3950|12
Ryzen 5 7600X|28700|4150|12
Ryzen 5 8400F|22000|3500|12
Ryzen 5 9600X|30000|4500|12|ryzen 5 9600
Ryzen 7 1700|14800|2000|16
Ryzen 7 2700X|17600|2400|16
Ryzen 7 3700X|22600|2650|16|ryzen 7 3800x
Ryzen 7 5700X|26500|3150|16|ryzen 7 5700
Ryzen 7 5800X|28000|3450|16
Ryzen 7 5800X3D|27500|3200|16
Ryzen 7 5700X3D|26000|3050|16
Ryzen 7 7700|34500|4000|16|ryzen 7 7700x
Ryzen 7 7800X3D|34400|3700|16
Ryzen 7 9700X|37000|4500|16
Ryzen 7 9800X3D|40000|4450|16
Ryzen 9 5900X|39000|3450|24
Ryzen 9 5950X|46000|3500|32
Ryzen 9 7900X|51500|4200|24|ryzen 9 7900
Ryzen 9 7950X|63000|4250|32
Ryzen 9 9950X|66000|4700|32
`;

// PC방 게임 점검 앱 기본 점검 (Playwright)
// 실행: node pcbang/tests/smoke.js   (playwright 가 설치된 환경)
// 페이지 오류, 부품 이름 매칭, 게임 판정, 결과 코드 불러오기, 매장 현황·실전 테스트 흐름을 확인하고
// 하나라도 틀리면 종료 코드 1로 끝납니다.
const { chromium } = require('playwright');
const path = require('path');
const URL = 'file://' + path.resolve(__dirname, '..', 'index.html');
const b64 = o => Buffer.from(JSON.stringify(o), 'utf8').toString('base64');
let fails = 0;
const ok = (cond, msg) => { console.log((cond ? 'ok   ' : 'FAIL ') + msg); if (!cond) fails++; };

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const errs = [];
  page.on('pageerror', e => errs.push(e.message));
  page.on('dialog', d => d.accept());
  await page.goto(URL); await page.waitForTimeout(500);

  // 1. 부품 이름 매칭
  const m = await page.evaluate(() => {
    const P = window.__pcbang;
    const g = x => (P.matchGpu(x) || {}).name || null, c = x => (P.matchCpu(x) || {}).name || null;
    return {
      g1: g('ANGLE (NVIDIA, NVIDIA GeForce RTX 3060 (0x00002504) Direct3D11 vs_5_0 ps_5_0, D3D11)'),
      g2: g('ANGLE (NVIDIA, NVIDIA GeForce GTX 1060 3GB Direct3D11 vs_5_0 ps_5_0, D3D11)'),
      g3: g('NVIDIA GeForce GTX 680M'), g4: g('AMD Radeon 780M Graphics'), g5: g('NVIDIA GeForce RTX 3050 6GB'),
      c1: c('Intel(R) Core(TM) i7-14700F'), c2: c('AMD Ryzen 7 7800X3D 8-Core Processor'), c3: c('12th Gen Intel(R) Core(TM) i7-12700H'), c4: c('AMD Ryzen 7 5800H with Radeon Graphics'), c5: c('AMD Ryzen 9 9950X3D 16-Core Processor'), c6: c('Intel(R) Core(TM) Ultra 7 265F')
    };
  });
  ok(m.g1 === 'RTX 3060', '그래픽: ANGLE 문자열 → RTX 3060');
  ok(m.g2 === 'GTX 1060 3GB', '그래픽: 1060 3GB 구분');
  ok(m.g3 === null, '그래픽: GTX 680M 이 Radeon 680M 으로 잡히지 않음');
  ok(m.g4 === 'Radeon 780M', '그래픽: Radeon 780M');
  ok(m.g5 === 'RTX 3050 6GB', '그래픽: RTX 3050 6GB 구분');
  ok(m.c1 === 'i7-14700', 'CPU: i7-14700F');
  ok(m.c2 === 'Ryzen 7 7800X3D', 'CPU: 7800X3D');
  ok(m.c3 === 'i7-12700H', 'CPU: 노트북 i7-12700H 가 데스크톱으로 잡히지 않음');
  ok(m.c4 === 'Ryzen 7 5800H', 'CPU: 노트북 5800H');
  ok(m.c5 === 'Ryzen 9 9950X3D', 'CPU: 9950X3D 가 9950X 로 잡히지 않음(X3D 보정 유지)');
  ok(m.c6 === 'Core Ultra 7 265', 'CPU: Ultra 7 265F 가 265K 로 잡히지 않음');

  // 1-2. 윈도우 장치 이름·시리즈 이름·새 모델·펜티엄
  const m2 = await page.evaluate(() => {
    const P = window.__pcbang, g = x => (P.matchGpu(x) || {}).name || null, c = x => (P.matchCpu(x) || {}).name || null;
    return [g('AMD Radeon R7 200 Series'), g('AMD Radeon RX 9070 GRE'), g('Intel(R) HD Graphics 630'), g('NVIDIA GeForce RTX 3060 8GB'), g('NVIDIA GeForce RTX 4050 Laptop GPU'),
      c('Intel(R) Pentium(R) Gold G6400 CPU @ 4.00GHz'), c('AMD Ryzen 5 5600G with Radeon Graphics'), c('Intel(R) Core(TM) i3-14100F')];
  });
  ok(JSON.stringify(m2) === JSON.stringify(['R7 240', 'RX 9070 GRE', 'Intel HD 630', 'RTX 3060 8GB', 'RTX 4050 Laptop', 'Pentium Gold G6400', 'Ryzen 5 5600G', 'i3-14100']), '부품: 시리즈 이름·새 모델·펜티엄 인식 ' + JSON.stringify(m2));

  // 1-3. 이름 없는 내장 그래픽을 CPU 로 추정
  const ig = await page.evaluate(() => {
    const P = window.__pcbang, sp = (cpu, gpu) => { const o = P.spec({ manual: {}, det: {}, bench: {}, dev: {}, native: { cpu, gpus: [{ name: gpu }] } }); return o.gpu ? o.gpu.name : null; };
    return [sp('AMD Ryzen 5 5600G with Radeon Graphics', 'AMD Radeon(TM) Graphics'), sp('Intel(R) Core(TM) i5-12400', 'Intel(R) UHD Graphics'), sp('Intel(R) Core(TM) i5-12400F', 'Intel(R) UHD Graphics'), sp('AMD Ryzen 5 5600X', 'AMD Radeon(TM) Graphics'), sp('Intel(R) Core(TM) i5-12400', 'NVIDIA GeForce RTX 3060')];
  });
  // 1-4. 점검 프로그램 VRAM: 내장 그래픽은 VRAM 판정 안 함, 같은 이름의 VRAM 변형 구분
  const vr = await page.evaluate(() => {
    const P = window.__pcbang, opt = { res: '1080', preset: 'mid', target: 'auto' };
    const sp = (gpu, vram) => P.spec({ manual: {}, det: {}, bench: {}, dev: {}, native: { cpu: 'Intel(R) Core(TM) i7-8700', ramGB: 16, os: 'win10', gpus: [{ name: gpu, vram }] } });
    const u = sp('Intel(R) UHD Graphics 630', 0.1);
    return [P.judge(window.GAMES[0], u, opt).level, sp('NVIDIA GeForce RTX 3060', 8).gpu.name, sp('NVIDIA GeForce RTX 3060', 12).gpu.name, sp('NVIDIA GeForce RTX 3060 Ti', 8).gpu.name];
  });
  ok(JSON.stringify(vr) === JSON.stringify(['rec', 'RTX 3060 8GB', 'RTX 3060', 'RTX 3060 Ti']), 'VRAM: UHD 630 롤 권장(작은 전용 메모리로 오판 안 함), 3060 8GB/12GB·3060 Ti 구분 ' + JSON.stringify(vr));
  ok(/Vega 7/.test(ig[0]) && /UHD 730/.test(ig[1]) && ig[2] === null && ig[3] === null && ig[4] === 'RTX 3060', '내장 그래픽 추정: 5600G·i5-12400 추정, F·X 모델은 안 함, 외장 우선 ' + JSON.stringify(ig));

  // 2. 게임 판정
  const j = await page.evaluate(() => {
    const P = window.__pcbang, opt = { res: '1080', preset: 'mid', target: 'auto' };
    const strong = { gpu: P.matchGpu('RTX 3060'), cpu: P.matchCpu('i5-12400'), ram: 16, os: 'win11', src: {}, nat: {} };
    const weak = { gpu: P.matchGpu('Intel UHD 630'), cpu: P.matchCpu('i5-8400'), ram: 8, os: 'win10', src: {}, nat: {} };
    const blocked = Object.assign({}, strong, { nat: { secureBoot: '꺼짐' } });
    return window.GAMES.map(g => [g.id, P.judge(g, strong, opt).level, P.judge(g, weak, opt).level, P.judge(g, blocked, opt).level, P.judge(g, strong, opt).fps]);
  });
  ok(j.every(x => x[1] === 'rec'), '판정: RTX 3060 + i5-12400 + 16GB 는 10개 게임 모두 권장 충족');
  ok(j.find(x => x[0] === 'pubg')[2] === 'fail', '판정: UHD 630 + 8GB 는 배그 사양 부족');
  ok(j.find(x => x[0] === 'val')[3] === 'block' && j.find(x => x[0] === 'lol')[3] === 'block' && j.find(x => x[0] === 'pubg')[3] === 'rec', '판정: Win11 보안 부팅 꺼짐 → 롤·발로란트만 설정 때문에 실행 불가(배그는 그대로)');
  ok(j.every(x => typeof x[4] === 'number' && x[4] > 0), '판정: 모든 게임 예상 FPS 숫자');

  // 3. 점검 프로그램 결과 붙여넣기(악성 HTML 차단 포함)
  const nat = { v: 2, seat: 23, computer: 'PC-023', time: '2026-11-20 10:00', cpu: 'Intel(R) Core(TM) i5-12400F', cores: '<img src=x onerror=alert(1)>', gpus: [{ name: 'NVIDIA GeForce RTX 3060', vram: 12 }], hz: 60, monitorMaxHz: 144, ramGB: 16, os: 'win11', power: '균형 조정', pings: [{ name: 'gw', host: '192.168.0.1', isGateway: true, sent: 20, recv: 20, loss: 0, avg: 0.5 }] };
  await page.click('[data-tab="spec"]');
  await page.fill('#nativeIn', 'PCBANG1:' + b64(nat)); await page.click('#nativeApply'); await page.waitForTimeout(200);
  ok(/적용/.test(await page.textContent('#nativeMsg')), '점검 결과: 적용됨');
  ok(await page.evaluate(() => document.querySelectorAll('img').length) === 0, '점검 결과: HTML 끼어들기 차단');
  await page.click('[data-tab="home"]'); await page.waitForTimeout(200);
  const sum = await page.innerText('#summary');
  ok(/60Hz/.test(sum) && /전원/.test(sum), '홈 요약: 60Hz·전원 옵션 문제 표시');
  ok(!/undefined|NaN|null회/.test(sum), '홈 요약: undefined/NaN 없음');

  // 4. 매장 현황
  await page.click('[data-tab="log"]'); await page.click('#shopAddThis'); await page.waitForTimeout(200);
  ok(/1\/1석/.test(await page.textContent('#shopCount')), '매장 현황: 이 PC 결과 넣기');

  // 5. 실전 테스트 결과
  const g = { v: 1, kind: 'game', seat: 23, computer: 'PC-023', time: '2026-11-20 11:00', durationS: 60, app: 'TslGame.exe', admin: true, pmUsed: true, cpuName: 'Intel(R) Core(TM) i5-12400F', gpuName: 'NVIDIA GeForce RTX 3060', ramGB: 16, hz: 144, fps: { frames: 9000, avg: 150, low1: 90, low01: 60, p50ms: 6.5, p99ms: 11, maxms: 40, stutters: 2, stutterPerMin: 2 }, bottleneck: '그래픽', cpu: { avg: 40, coreAvg: 80 }, gpu: { utilAvg: 97, tempMax: 75 }, mem: { max: 60 }, ping: { gw: { n: 60, loss: 0, avg: 0.6, max: 2, jitter: 0.2, spikes: 0 }, ext: { n: 60, loss: 100 } }, tl: { fps: [150, 149], ftMax: [9, 12], cpu: [40, 41], gpu: [97, 96], mem: [60, 60], gw: [1, 1], ext: [-1, -1] }, verdicts: [] };
  await page.click('[data-tab="game"]');
  await page.click('[data-panel="game"] details > summary'); // 붙여넣기 칸은 접힌 메뉴 안에 있음
  await page.fill('#gtPaste', 'PCBANGG1:' + b64(g)); await page.click('#gtImport'); await page.waitForTimeout(300);
  const det = await page.innerText('#gtDetail');
  ok(/150/.test(det) && /응답 없음/.test(det), '실전 테스트: FPS 표시, 핑 100% 손실은 응답 없음');
  ok(!/undefined|NaN|null회/.test(det), '실전 테스트: undefined/NaN 없음');

  // 5-2. 검토 3차 회귀: 잘못된 경보·집계·빠진 칸
  const r3 = await page.evaluate(() => {
    const P = window.__pcbang, S = P.S;
    const base = { manual: {}, det: {}, bench: {}, dev: {}, net: null, opt: { res: '1080', preset: 'mid', target: 'auto' } };
    // 디스크 OK/Unknown 은 정상, Warning 만 이상
    const nat1 = { cpu: 'Intel(R) Core(TM) i5-12400F', gpus: [{ name: 'NVIDIA GeForce RTX 3060', vram: 12 }], ramGB: 16, os: 'win11', physDisks: [{ name: 'A', health: 'OK' }, { name: 'B', health: 'Unknown' }, { name: 'C', health: 'Warning' }], pings: [{ name: 'gw', host: '1', isGateway: true, recv: 0, loss: 100 }] };
    // problems 는 내부 함수라 홈 요약 대신 spec+판정 경로로 확인할 수 없어 화면 문구로 확인
    return { nat1 };
  });
  await page.click('[data-tab="spec"]'); await page.click('#nativeClear').catch(() => {});
  await page.fill('#nativeIn', 'PCBANG1:' + b64(Object.assign({ v: 2, time: '2026-11-19 10:00', hz: 60, monitorMaxHz: 144, cores: 4 }, r3.nat1))); await page.click('#nativeApply'); await page.waitForTimeout(150);
  ok(!/undefined|null/.test(await page.innerText('#detKv')), '빠진 칸: 내 사양에 undefined/null 없음(스레드 없음)');
  await page.click('[data-tab="home"]'); await page.waitForTimeout(150);
  const h3 = await page.innerText('#summary');
  ok(/디스크 상태 이상: C/.test(h3) && !/디스크 상태 이상: A|디스크 상태 이상: B/.test(h3), '디스크: OK·Unknown 은 정상, Warning 만 이상');
  ok(await page.$$eval('#summary .badbox', e => !e.some(x => /게이트웨이/.test(x.textContent))), '게이트웨이 핑 차단은 고칠 것(빨강)이 아님');
  ok(/60Hz로 동작/.test(h3), '주사율: 점검 결과 60Hz 경고');
  await page.evaluate(() => { const S = window.__pcbang.S; S.dev.hz = 144; S.dev.hzInfo = { hz: 144, at: Date.now() }; });
  await page.click('[data-tab="games"]'); await page.click('[data-tab="home"]'); await page.waitForTimeout(150);
  ok(!/60Hz로 동작/.test(await page.innerText('#summary')), '주사율: 나중에 다시 잰 144Hz 가 우선');
  await page.click('[data-tab="log"]');
  await page.click('#shopAddThis'); await page.waitForTimeout(150);
  const before = await page.textContent('#shopCount'); // 한 번 넣은 뒤 개수 (같은 PC 를 다시 넣어도 그대로여야 함)
  await page.click('#shopAddThis'); await page.click('#shopAddThis'); await page.waitForTimeout(150);
  ok(await page.textContent('#shopCount') === before, '매장 현황: 같은 PC 결과를 다시 넣어도 줄이 늘지 않음 (' + before + ')');

  // 5-3. 실전 테스트: CPU 클럭 저하(PL1) 판정, 해상도 기준 예상치
  const g2 = Object.assign({}, g, { seat: 31, computer: 'PC-031', time: '2026-11-20 12:00', cpuName: 'Intel(R) Core(TM) i7-14700F', gpuName: 'NVIDIA GeForce RTX 5080', resW: 2560, resH: 1440, cpu: { avg: 35, coreAvg: 90, clockStart: 5300, clockEnd: 3600 }, tl: { clk: Array.from({ length: 60 }, (_, i) => i < 28 ? 5300 : 3600), fps: [200, 190] } });
  await page.click('[data-tab="game"]');
  await page.evaluate(c => { document.querySelector('#gtPaste').value = c; document.querySelector('#gtImport').click(); }, 'PCBANGG1:' + b64(g2)); await page.waitForTimeout(300);
  const d2 = await page.innerText('#gtDetail');
  ok(/CPU 클럭 저하 \(5,300→3,600MHz\)/.test(d2) && await page.$('#gtcClk') !== null, '실전 테스트: CPU 클럭 저하 판정·클럭 그래프');
  ok(/같은 부품 예상\(1440p, 측정 화면 2560×1440\)/.test(d2), '실전 테스트: 측정 해상도 기준 예상치');

  // 빈 실전 결과는 목록에서 '정상'이 아니라 '판단 불가'
  await page.evaluate(c => { document.querySelector('#gtPaste').value = c; document.querySelector('#gtImport').click(); }, 'PCBANGG1:' + b64({ v: 1, kind: 'game', time: '2026-11-20 14:05' }));
  await page.waitForTimeout(200);
  ok(/판단 불가/.test(await page.innerText('#gtList')), '실전 테스트: 측정값 없는 결과는 판단 불가로 표시');

  // 깨진 결과 코드(틀린 자료형·null·큰 배열·스크립트 문자열)를 넣어도 오류·스크립트 실행 없음 (고정 시드)
  {
    let seed = 7; const rnd = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
    const weird = () => [null, true, 0, -1, 1e308, '', '<img src=x onerror=window.__xss=1>', 'x'.repeat(3000), [], [null], {}, [1, 'a', {}], '2026-13-45 99:99', Array(3000).fill(3)][Math.floor(rnd() * 14)];
    const mutate = o => Array.isArray(o) ? (rnd() < 0.3 ? weird() : o.map(mutate)) : o && typeof o === 'object' ? Object.fromEntries(Object.keys(o).map(k => [k, rnd() < 0.25 ? weird() : mutate(o[k])])) : rnd() < 0.2 ? weird() : o;
    const NAT = { v: 2, time: '2026-11-20 10:00', seat: 5, computer: 'PC-005', cpu: 'Intel(R) Core(TM) i5-12400F', gpus: [{ name: 'NVIDIA GeForce RTX 4060', vram: 8 }], ramGB: 16, os: 'win11', hz: 144, displays: [{ name: 'M', res: '1920x1080', hz: 144, maxHz: 144, primary: true }], pings: [{ name: '게이트웨이', isGateway: true, avg: 1, loss: 0, recv: 20 }], disks: [{ name: 'C', freeGB: 50 }] };
    const GAME = { v: 1, kind: 'game', seat: 5, time: '2026-11-20 13:00', app: 'TslGame.exe', fps: { avg: 150, low1: 90 }, cpu: { avg: 50, clockStart: 4000, clockEnd: 3900 }, gpu: { utilAvg: 95 }, ping: { gw: { avg: 1, loss: 0 } }, tl: { fps: [150], gw: [1, -1] } };
    const codes = []; for (let i = 0; i < 20; i++) codes.push('PCBANG1:' + b64(mutate(NAT)), 'PCBANGG1:' + b64(mutate(GAME)));
    const before = errs.length;
    await page.evaluate(c => { document.querySelector('#shopPaste').value = c; document.querySelector('#shopImportBtn').click(); }, codes.join('\n')); await page.waitForTimeout(400);
    await page.click('[data-tab="log"]'); await page.waitForTimeout(150); await page.click('[data-tab="game"]'); await page.waitForTimeout(150);
    ok(errs.length === before && !(await page.evaluate(() => window.__xss)), '깨진 결과 코드 40개: 페이지 오류·스크립트 실행 없음');
  }

  // 6. 모바일 폭 가로 넘침
  await page.setViewportSize({ width: 390, height: 844 });
  for (const t of ['home', 'game', 'games', 'log', 'dev', 'fix']) { await page.click(`[data-tab="${t}"]`); await page.waitForTimeout(100); }
  ok(await page.evaluate(() => document.documentElement.scrollWidth) <= 390, '모바일: 가로 넘침 없음');

  const fl = await page.evaluate(() => [window.__pcbang.fpsLabel(58, 144)[1], window.__pcbang.fpsLabel(60, 144)[1]]);
  ok(!/60fps 이상/.test(fl[0]) && /60fps 이상/.test(fl[1]), '프레임 표시: 58fps 를 60fps 이상으로 부르지 않음');

  const capL = await page.evaluate(() => window.__pcbang.fpsLabel(200, 240, 200));
  ok(capL[0] === 'ok' && /게임 자체 제한/.test(capL[1]), '프레임 표시: 서든 200fps 제한을 어려움으로 부르지 않음');

  const fightL = await page.evaluate(() => [window.__pcbang.fpsLabel(162, 144, null, 0.7), window.__pcbang.fpsLabel(220, 144, null, 0.7)]);
  ok(fightL[0][0] === 'warn' && fightL[1][0] === 'ok', '프레임 표시: 배그 교전 중 목표 미달이면 유지 예상이라 하지 않음');

  const hzC = await page.evaluate(() => { const P = window.__pcbang; return [P.chkHz({ hz: 60 }, { monitorMaxHz: 60 })[0], P.chkHz({ hz: 60 }, { monitorMaxHz: 144 })[0], P.chkHz({}, { hz: 144 })[0], P.chkHz({ hz: 60 }, {})[0]]; });
  ok(hzC.join() === 'ok,bad,ok,', '체크리스트 주사율: 원래 60Hz 정상·144Hz 모니터 60Hz 불량·점검 프로그램 Hz 사용·모르면 직접 확인 (' + hzC.join() + ')');

  const fx = await page.evaluate(() => { const t = q => (window.__pcbang.fixSearch(q)[0] || {}).t || ''; return { pubg: t('pubg'), ow: t('overwatch'), on: t('안켜짐'), snd: t('소리 안나요'), fr: t('배그 프레임'), van: t('van9003'), v81: t('VAN81') }; });
  ok(/BattlEye/.test(fx.pubg) && /배틀넷/.test(fx.ow) && /실행|시작/.test(fx.on) && /헤드셋/.test(fx.snd) && /프레임/.test(fx.fr) && /9003/.test(fx.van) && /-81/.test(fx.v81), '문제 해결 검색: 영어 게임 이름·일상 표현·게임+증상 (' + Object.values(fx).map(x => x.slice(0, 8)).join(' / ') + ')');

  const lab = await page.evaluate(() => { const P = window.__pcbang, G = window.GAMES; const val = G.find(g => g.id === 'val'), sa = G.find(g => g.id === 'sa'); return [P.levelOf(val, { level: 'rec' })[1], P.fpsText(sa, { fps: 200 }), P.fpsText(sa, { fps: 150 })]; });
  ok(/고사양/.test(lab[0]) && lab[1] === '200+' && lab[2] === '약 150', '판정 문구 공용: 발로란트 고사양 충족·서든 200+ (' + lab.join(' / ') + ')');

  const igc = await page.evaluate(() => { const f = c => (window.__pcbang.igpuFromCpu(c) || {}).name || null; return [f('Intel(R) Core(TM) Ultra 5 245K'), f('Intel(R) Core(TM) Ultra 5 245KF'), f('AMD Ryzen 5 7500F 6-Core Processor'), f('AMD Ryzen 5 7600 6-Core Processor')]; });
  ok(/울트라 245/.test(igc[0]) && igc[1] === null && igc[2] === null && /2CU/.test(igc[3]), '내장 그래픽 추정: 코어 울트라 245K 있음·245KF·7500F 없음·7600 2CU');

  const cpuOrd = await page.evaluate(() => { const P = window.__pcbang, pubg = window.GAMES.find(g => g.id === 'pubg'), gm = P.matchGpu('RTX 5090'); const f = c => P.judge(pubg, { gpu: gm, cpu: P.matchCpu(c), ram: 32, vram: 32, src: {}, hz: 240 }, { res: '1080', preset: 'low', target: 'auto' }).fps; return [f('Ryzen 7 7800X3D'), f('i7-14700'), f('i5-12400')]; });
  ok(cpuOrd[0] > cpuOrd[1] && cpuOrd[1] > cpuOrd[2], '배그 CPU 순서: 7800X3D > 14700 > 12400 (' + cpuOrd.join(' / ') + ')');

  // 7. 웹 결과 파일 이름이 점검 프로그램 결과(seat-23.txt)와 겹치지 않음
  const ctx2 = await browser.newContext({ acceptDownloads: true }); const p3 = await ctx2.newPage();
  p3.on('pageerror', e => errs.push(e.message));
  await p3.goto(URL + '?seat=23'); await p3.waitForTimeout(300);
  const [dl] = await Promise.all([p3.waitForEvent('download'), p3.click('#codeSave')]);
  ok(dl.suggestedFilename() === 'seat-23-web.txt', '결과 파일 저장: seat-23-web.txt (점검 프로그램 파일을 덮어쓰지 않음)');
  await ctx2.close();

  // 8. 마우스 테스트: 새로 고침 후 저장값 표시, 다음 클릭에 채터링 기록이 0으로 덮이지 않음, 초기화는 지움
  const p4 = await (await browser.newContext()).newPage(); p4.on('pageerror', e => errs.push(e.message));
  await p4.goto(URL); await p4.waitForTimeout(300);
  // 이전에 측정한 결과가 저장돼 있는 상태 (좌석 입력 change 가 save() 를 부름)
  await p4.evaluate(() => { const S = window.__pcbang.S; S.dev.chatter = 2; S.dev.mBtns = [5, 1, 3, 0, 0]; S.dev.pollMax = 998; S.dev.pollAvg = 990; document.querySelector('#seatIn').dispatchEvent(new Event('change')); });
  await p4.reload(); await p4.waitForTimeout(300); await p4.click('[data-tab="dev"]');
  const mv1 = await p4.innerText('#mouseVerdict');
  await p4.click('#mousePad', { button: 'right' }); await p4.waitForTimeout(200);
  const md = await p4.evaluate(() => ({ c: window.__pcbang.S.dev.chatter, b: window.__pcbang.S.dev.mBtns }));
  ok(/채터링\) 의심 2회/.test(mv1) && md.c === 2 && md.b[0] === 5 && md.b[2] === 4, '마우스: 새로 고침 후 이전 기록 표시·이어서 셈 (채터링 ' + md.c + ', 버튼 ' + md.b + ')');
  await p4.click('#mouseReset'); const md2 = await p4.evaluate(() => window.__pcbang.S.dev.chatter);
  ok(!md2 && (await p4.innerText('#mouseVerdict')).trim() === '', '마우스: 초기화하면 기록 지움');
  await p4.context().close();

  // 9. 마이크: 탭을 떠나면 꺼짐, 두 번 눌러도 하나만, 정상 결과는 새로 고침 후에도 남음 (큰 소리 가짜 마이크)
  {
    const p5 = await (await browser.newContext()).newPage(); p5.on('pageerror', e => errs.push(e.message));
    await p5.addInitScript(() => { window.__tracks = []; navigator.mediaDevices.getUserMedia = async () => { await new Promise(r => setTimeout(r, 100)); const c = new AudioContext(); const o = c.createOscillator(); const d = c.createMediaStreamDestination(); o.connect(d); o.start(); await c.resume(); d.stream.getTracks().forEach(t => window.__tracks.push(t)); return d.stream; }; });
    await p5.goto(URL + '#dev'); await p5.waitForTimeout(300);
    await p5.evaluate(() => { document.querySelector('#micRun').click(); document.querySelector('#micRun').click(); }); await p5.waitForTimeout(700);
    const t1 = await p5.evaluate(() => window.__tracks.map(t => t.readyState).join());
    await p5.click('[data-tab="home"]'); await p5.waitForTimeout(150);
    const t2 = await p5.evaluate(() => window.__tracks.map(t => t.readyState).join());
    await p5.reload(); await p5.waitForTimeout(300);
    const mic = await p5.evaluate(() => window.__pcbang.S.dev.mic);
    ok(t1 === 'live' && t2 === 'ended' && mic === 'ok', '마이크: 두 번 눌러도 1개·탭 떠나면 꺼짐·정상 결과 저장 (' + t1 + ' → ' + t2 + ', ' + mic + ')');
    await p5.context().close();
  }

  // 반응 속도: 시작 후 탭을 떠나면 취소, Space 반복 입력은 '너무 빨랐어요'가 아님
  {
    const p7 = await (await browser.newContext()).newPage(); p7.on('pageerror', e => errs.push(e.message));
    await p7.goto(URL + '#dev'); await p7.waitForTimeout(200);
    await p7.click('#react'); await p7.click('[data-tab="home"]'); await p7.click('[data-tab="dev"]');
    const r1 = await p7.innerText('#react');
    await p7.focus('#react');
    await p7.evaluate(() => { const el = document.querySelector('#react'); el.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', bubbles: true })); el.dispatchEvent(new KeyboardEvent('keydown', { key: ' ', repeat: true, bubbles: true })); });
    const r2 = await p7.innerText('#react');
    ok(/눌러 시작/.test(r1) && !/너무 빨랐/.test(r2), '반응 속도: 탭 떠나면 취소·Space 반복 무시 (' + r1.trim() + ' / ' + r2.trim().slice(0, 20) + ')');
    await p7.context().close();
  }

  // 키보드: 한/영 키(code 없음)가 계속 눌린 상태로 남지 않음, 새로 고침 뒤 누른 키 수 유지
  {
    const p8 = await (await browser.newContext()).newPage(); p8.on('pageerror', e => errs.push(e.message));
    await p8.goto(URL + '#dev'); await p8.waitForTimeout(200); await p8.click('#kb'); await p8.focus('#kb');
    await p8.evaluate(() => { document.dispatchEvent(new KeyboardEvent('keydown', { key: 'HangulMode', code: '', bubbles: true })); document.dispatchEvent(new KeyboardEvent('keyup', { key: 'HangulMode', code: '', bubbles: true })); });
    for (const k of ['KeyA', 'KeyB', 'KeyC', 'KeyD', 'KeyE', 'KeyF']) await p8.keyboard.press(k);
    const kmax = await p8.innerText('#kbMax'), c1 = +(await p8.innerText('#kbCount'));
    await p8.reload(); await p8.waitForTimeout(200); await p8.click('[data-tab="dev"]'); await p8.click('#kb'); await p8.focus('#kb'); await p8.keyboard.press('KeyQ');
    const c2 = +(await p8.innerText('#kbCount'));
    ok(kmax === '1' && c2 === c1 + 1, '키보드: 한/영 키 안 남음(최대 동시 ' + kmax + ')·새로 고침 뒤 키 수 ' + c1 + ' → ' + c2);
    await p8.context().close();
  }

  // 점검 프로그램: 게이트웨이 정상·외부 핑 전부 무응답 → TCP 도 실패면 '외부 인터넷 응답 없음', TCP 성공이면 '핑만 막힘'
  {
    const pr = await page.evaluate(() => { const P = window.__pcbang; const pings = [{ name: 'gw', isGateway: true, avg: 1, loss: 0, recv: 20 }, { name: 'KT', avg: null, loss: 100, recv: 0 }];
      const run = tcp => P.problems ? P.problems({ det: {}, dev: {}, bench: {}, manual: {}, opt: P.S.opt, native: { pings, tcp } }).map(x => x.id) : null; return [run([{ name: 'n', ok: false }]), run([{ name: 'n', ok: true }])]; });
    ok(pr[0] && pr[0].indexOf('extdead') >= 0 && pr[1].indexOf('extping') >= 0 && pr[1].indexOf('extdead') < 0, '점검 프로그램: 외부 핑 전부 무응답 판정 (' + (pr[0] || []).filter(x => /ext/.test(x)) + ' / ' + (pr[1] || []).filter(x => /ext/.test(x)) + ')');
  }

  // 실전 테스트: 60fps 상한 + 144Hz 모니터면 '묶여 있음' 안내, 서든 200(엔진 상한)은 안내 없음
  {
    const cp = await page.evaluate(() => { const P = window.__pcbang; return null; });
    const mk = (seat, app, avg, hz) => 'PCBANGG1:' + b64({ v: 1, kind: 'game', seat, time: '2026-11-21 11:0' + seat, app, hz, fps: { avg, low1: avg * 0.8 }, cpu: { avg: 40 }, gpu: { utilAvg: 50 }, tl: {} });
    await page.click('[data-tab="game"]');
    await page.evaluate(c => { document.querySelector('#gtPaste').value = c; document.querySelector('#gtImport').click(); }, [mk(71, 'TslGame.exe', 60.1, 144), mk(72, 'SuddenAttack.exe', 199.6, 240)].join('\n'));
    await page.waitForTimeout(200);
    const t = await page.innerText('#gtList');
    const i71 = await page.$$eval('[data-gt]', (els) => els.findIndex(e => /71번/.test(e.innerText))), i72 = await page.$$eval('[data-gt]', (els) => els.findIndex(e => /72번/.test(e.innerText)));
    await page.click('[data-gt="' + i71 + '"]'); const d71 = await page.innerText('#gtDetail');
    await page.click('[data-gt="' + i72 + '"]'); const d72 = await page.innerText('#gtDetail');
    ok(/60에 묶여/.test(d71) && !/묶여/.test(d72), '실전 테스트: 60fps 상한은 안내·서든 200 은 안내 없음');
  }

  // 매장 현황: 오래된 점검 결과를 나중에 넣어도 최신 결과 유지, 이력 방향·중복
  {
    const p9 = await (await browser.newContext()).newPage(); p9.on('pageerror', e => errs.push(e.message));
    await p9.goto(URL); await p9.waitForTimeout(200);
    const nat = (time, drv) => 'PCBANG1:' + b64({ v: 2, time, seat: 61, computer: 'PC-061', cpu: 'Intel(R) Core(TM) i5-12400F', gpus: [{ name: 'NVIDIA GeForce RTX 4060', vram: 8, driver: drv }], ramGB: 16, os: 'win11' });
    const imp = async t => { await p9.evaluate(t => { document.querySelector('#shopPaste').value = t; document.querySelector('#shopImportBtn').click(); }, t); await p9.waitForTimeout(150); };
    const A = nat('2026-11-20 10:00', '566.03'), B = nat('2026-11-21 09:00', '572.16');
    await imp(B); await imp(A); await imp(B); await imp(A);
    const e = await p9.evaluate(() => JSON.parse(localStorage.getItem('pcbang_store_v1'))['seat:61']);
    ok(e.native.gpus[0].driver === '572.16' && e.history.length === 1 && e.history[0].from === '2026-11-20 10:00', '매장 현황: 오래된 결과가 최신을 덮지 않음·이력 1개 방향 맞음 (' + e.native.gpus[0].driver + ', 이력 ' + e.history.length + ')');
    await p9.context().close();
  }

  // 부품 우선순위: 점검 프로그램 값이 직접 입력보다 우선, 무시된 직접 입력은 알림
  {
    const sp = await page.evaluate(() => { const P = window.__pcbang, S = P.S; const base = { det: {}, dev: {}, bench: {}, opt: S.opt, manual: { gpu: 'RTX 3060', ram: '8' } };
      const a = P.spec(Object.assign({}, base, { native: {} })), b = P.spec(Object.assign({}, base, { native: { gpus: [{ name: 'NVIDIA GeForce RTX 4060', vram: 8 }], ramGB: 16 } }));
      return [a.gpu && a.gpu.name, a.ram, b.gpu && b.gpu.name, b.ram, b.manualIgnored.length]; });
    ok(sp.join() === 'RTX 3060,8,RTX 4060,16,2', '부품 우선순위: 점검 프로그램 > 직접 입력, 무시된 직접 입력 알림 (' + sp.join() + ')');
  }

  // 매장 현황: 같은 PC 가 'PC 이름' 줄과 '좌석' 줄로 갈라지지 않음 (양쪽 순서)
  {
    const pA = await (await browser.newContext()).newPage(); pA.on('pageerror', e => errs.push(e.message));
    await pA.goto(URL); await pA.waitForTimeout(200);
    const nat = (seat, comp, time) => 'PCBANG1:' + b64({ v: 2, time, seat, computer: comp, cpu: 'Intel(R) Core(TM) i5-12400F', gpus: [{ name: 'NVIDIA GeForce RTX 4060', vram: 8 }], ramGB: 16, os: 'win11' });
    const imp = async t => { await pA.evaluate(t => { document.querySelector('#shopPaste').value = t; document.querySelector('#shopImportBtn').click(); }, t); await pA.waitForTimeout(150); };
    await imp(nat(null, 'PC-030', '2026-11-20 10:00')); await imp(nat(30, 'PC-030', '2026-11-21 10:00'));   // 이름 줄 먼저 → 좌석 줄로 합침
    await imp(nat(40, 'PC-040', '2026-11-20 10:00')); await imp(nat(null, 'PC-040', '2026-11-21 10:00')); // 좌석 줄 먼저 → 이름만 온 결과도 그 줄로
    const keys = await pA.evaluate(() => Object.keys(JSON.parse(localStorage.getItem('pcbang_store_v1'))).sort().join());
    const t40 = await pA.evaluate(() => JSON.parse(localStorage.getItem('pcbang_store_v1'))['seat:40'].native.time);
    ok(keys === 'seat:30,seat:40' && t40 === '2026-11-21 10:00', '매장 현황: 같은 PC 는 한 줄 (' + keys + ', 40번 최신 ' + t40 + ')');
    await pA.context().close();
  }

  // 매장 현황 CSV·RAM: 빈 값은 빈 칸('- 아님), 게이트웨이 0.1 단위, 브라우저 '8+'보다 실전 테스트의 정확한 RAM 우선
  {
    const pB = await (await browser.newContext({ acceptDownloads: true })).newPage(); pB.on('pageerror', e => errs.push(e.message));
    await pB.goto(URL); await pB.waitForTimeout(200);
    const web = 'PCBANGW1:' + b64({ v: 1, seat: '81', at: Date.now(), det: { renderer: '', threads: 8, memGB: 8 }, manual: {}, bench: {}, dev: {} });
    const game = 'PCBANGG1:' + b64({ v: 1, kind: 'game', seat: 81, time: '2026-11-21 12:00', app: 'TslGame.exe', ramGB: 16, fps: { avg: 100, low1: 70 }, cpu: {}, gpu: {}, tl: {} });
    const nat = 'PCBANG1:' + b64({ v: 2, time: '2026-11-21 10:00', seat: 82, cpu: 'Intel(R) Core(TM) i5-12400F', gpus: [{ name: 'NVIDIA GeForce RTX 4060', vram: 8 }], ramGB: 16, os: 'win11', pings: [{ name: 'gw', isGateway: true, avg: 1.234, loss: 0, recv: 20 }] });
    await pB.evaluate(t => { document.querySelector('#shopPaste').value = t; document.querySelector('#shopImportBtn').click(); }, [web, game, nat].join('\n')); await pB.waitForTimeout(300);
    await pB.click('[data-tab="log"]'); await pB.waitForTimeout(150);
    const [dl] = await Promise.all([pB.waitForEvent('download'), pB.click('#shopCsv')]);
    const csv = require('fs').readFileSync(await dl.path(), 'utf8').split('\r\n');
    const r81 = csv.find(l => l.startsWith('81,')) || '', r82 = csv.find(l => l.startsWith('82,')) || '';
    ok(!/'-/.test(r81) && r81.split(',')[5] === '16' && r82.split(',')[7] === '1.2', 'CSV: 빈 칸·RAM 16(실전 테스트 우선)·게이트웨이 1.2 (' + r81.split(',').slice(3, 6).join('|') + ' / ' + r82.split(',')[7] + ')');
    await pB.context().close();
  }

  // XMP: 메모리 오버클럭이 막힌 칩셋(H610M·B460M)은 경고 대신 참고, B760 은 그대로 경고
  {
    const xm = await page.evaluate(() => { const P = window.__pcbang; const run = board => P.problems({ det: {}, dev: {}, bench: {}, manual: {}, opt: P.S.opt, native: { board, ramXmpOff: true, ramSpeed: 2666, ramRated: 3200 } }).filter(x => /^xmp/.test(x.id)).map(x => x.id).join(); return [run('ASUS PRIME H610M-E D4'), run('MSI B460M PRO'), run('ASUS PRIME B760M-K')]; });
    ok(xm.join('/') === 'xmplock/xmplock/xmp', 'XMP: H610M·B460M 은 참고, B760 은 경고 (' + xm.join('/') + ')');
  }

  // 전원 관리: 듀얼 CCD X3D 는 균형 조정이 정상, 일반 CPU 는 균형 조정 경고
  {
    const pw = await page.evaluate(() => { const P = window.__pcbang; const run = (cpu, power) => P.problems({ det: {}, dev: {}, bench: {}, manual: {}, opt: P.S.opt, native: { cpu, power } }).filter(x => x.id === 'power').map(x => x.lv).join() || '-'; return [run('AMD Ryzen 9 7950X3D 16-Core Processor', '균형 조정'), run('AMD Ryzen 9 7950X3D 16-Core Processor', '고성능'), run('AMD Ryzen 7 7800X3D 8-Core Processor', '균형 조정')]; });
    ok(pw.join('/') === '-/info/warn', '전원 관리: 7950X3D 균형 정상·고성능 참고, 7800X3D 균형 경고 (' + pw.join('/') + ')');
  }

  // 모니터가 내장 그래픽 단자에 연결: 외장 그래픽이 있으면 '고칠 것', 내장 그래픽만 있는 PC 는 아님
  {
    const ig = await page.evaluate(() => { const P = window.__pcbang; const run = (gpus, adapter) => P.problems({ det: {}, dev: {}, bench: {}, manual: {}, opt: P.S.opt, native: { hz: 60, monitorMaxHz: 60, gpus, displays: [{ name: 'M', res: '1920x1080', hz: 60, maxHz: 60, primary: true, adapter }] } }).some(x => x.id === 'igport');
      return [run([{ name: 'NVIDIA GeForce RTX 4060' }, { name: 'Intel(R) UHD Graphics 730' }], 'Intel(R) UHD Graphics 730'), run([{ name: 'NVIDIA GeForce RTX 4060' }], 'NVIDIA GeForce RTX 4060'), run([{ name: 'Intel(R) UHD Graphics 730' }], 'Intel(R) UHD Graphics 730')]; });
    ok(ig.join() === 'true,false,false', '모니터 단자: 외장 그래픽 있는데 내장 단자면 경고, 정상 연결·내장만 있는 PC 는 아님 (' + ig.join() + ')');
  }

  // 주사율: 240Hz 모니터를 144Hz 로 쓰면 경고·체크리스트 불량, 143/144 는 정상
  {
    const hl = await page.evaluate(() => { const P = window.__pcbang; const run = (hz, mx) => P.problems({ det: {}, dev: {}, bench: {}, manual: {}, opt: P.S.opt, native: { hz, monitorMaxHz: mx } }).some(x => x.id === 'hzlow') + ':' + P.chkHz({}, { hz, monitorMaxHz: mx })[0]; return [run(144, 240), run(143, 144)]; });
    ok(hl.join('/') === 'true:bad/false:ok', '주사율: 최대보다 낮은 설정(144/240) 경고, 143/144 정상 (' + hl.join('/') + ')');
  }

  // 네트워크: 와이파이 867Mbps 에 '랜 연결 속도' 경고 안 함, 유선 100Mbps 는 경고
  {
    const nw = await page.evaluate(() => { const P = window.__pcbang; const run = a => P.problems({ det: {}, dev: {}, bench: {}, manual: {}, opt: P.S.opt, native: { adapter: a } }).filter(x => /wifi|link/.test(x.id)).map(x => x.id).join() || '-'; return [run('무선(와이파이) · Intel(R) Wi-Fi 6 AX201 867Mbps'), run('유선 · Realtek PCIe GbE Family Controller 100Mbps')]; });
    ok(nw.join('/') === 'wifi/link', '네트워크: 와이파이는 와이파이 경고만, 유선 100Mbps 는 속도 경고 (' + nw.join('/') + ')');
  }

  // TPM 1.2 는 Win11 뱅가드 실행 불가, 노하드 PC 보안 부팅 안내는 PXE 주의
  {
    const tp = await page.evaluate(() => { const P = window.__pcbang; const run = nat => P.problems({ det: {}, dev: {}, bench: {}, manual: {}, opt: P.S.opt, native: Object.assign({ os: 'win11' }, nat) }); return [run({ tpm: '있음 (1.2)', secureBoot: '켜짐' }).some(x => x.id === 'tpm'), /노하드/.test((run({ tpm: '있음 (2.0)', secureBoot: '꺼짐', diskless: true }).find(x => x.id === 'sb') || {}).fix || '')]; });
    ok(tp.join() === 'true,true', 'TPM 1.2 경고·노하드 보안 부팅 안내 (' + tp.join() + ')');
  }

  // 게이트웨이 핑: 1번 손실·한 번 튐은 참고, 2/20 손실·계속 느림은 고칠 것
  {
    const gg = await page.evaluate(() => { const P = window.__pcbang; const run = g => P.problems({ det: {}, dev: {}, bench: {}, manual: {}, opt: P.S.opt, native: { pings: [Object.assign({ name: 'gw', isGateway: true, recv: 20 }, g)] } }).filter(x => /^gw/.test(x.id)).map(x => x.lv).join() || '-';
      return [run({ loss: 5, recv: 19, avg: 0.9, med: 1, min: 0 }), run({ loss: 0, avg: 3.9, med: 1, min: 0, max: 60 }), run({ loss: 10, recv: 18, avg: 1, med: 1 }), run({ loss: 0, avg: 8.2, med: 8, min: 6 })]; });
    ok(gg.join('/') === 'info/info/bad/bad', '게이트웨이 핑: 1번 손실·한 번 튐 참고, 2번 손실·계속 느림 고칠 것 (' + gg.join('/') + ')');
  }

  // 10. 웹 인터넷 측정: 전부 503(차단 페이지)이면 '좋아요'가 아님, 1.1.1.1 하나만 막혀도 '불안정'이 아님
  for (const [label, handler, expectOk] of [
    ['503', r => r.fulfill({ status: 503, headers: { 'access-control-allow-origin': '*' }, body: 'blocked' }), false],
    ['1.1.1.1 차단', r => r.request().url().includes('1.1.1.1') ? r.abort() : r.fulfill({ status: 200, headers: { 'access-control-allow-origin': '*' }, body: 'ok' }), true]
  ]) {
    const p6 = await (await browser.newContext()).newPage(); p6.on('pageerror', e => errs.push(e.message));
    await p6.route(/^https:/, handler); await p6.goto(URL + '#net'); await p6.waitForTimeout(200);
    await p6.click('#netRun'); await p6.waitForFunction(() => !document.querySelector('#netRun').disabled, null, { timeout: 60000 });
    const isOk = !!(await p6.$('#netVerdict .okbox'));
    ok(isOk === expectOk, '인터넷 측정(' + label + '): ' + (expectOk ? '좋아요' : '좋아요 아님') + ' — ' + (await p6.innerText('#netVerdict')).slice(0, 40));
    await p6.context().close();
  }

  ok(errs.length === 0, '페이지 오류 없음' + (errs.length ? ': ' + errs.join(' / ') : ''));
  await browser.close();
  console.log(fails ? `\n${fails}개 실패` : '\n모두 통과');
  process.exit(fails ? 1 : 0);
})();

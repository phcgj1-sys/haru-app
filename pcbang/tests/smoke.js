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
      c1: c('Intel(R) Core(TM) i7-14700F'), c2: c('AMD Ryzen 7 7800X3D 8-Core Processor'), c3: c('12th Gen Intel(R) Core(TM) i7-12700H'), c4: c('AMD Ryzen 7 5800H with Radeon Graphics')
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
  const before = await page.textContent('#shopCount');
  await page.click('#shopAddThis'); await page.click('#shopAddThis'); await page.waitForTimeout(150);
  ok(await page.textContent('#shopCount') === before, '매장 현황: 같은 PC 결과를 다시 넣어도 줄이 늘지 않음 (' + before + ')');

  // 5-3. 실전 테스트: CPU 클럭 저하(PL1) 판정, 해상도 기준 예상치
  const g2 = Object.assign({}, g, { seat: 31, computer: 'PC-031', time: '2026-11-20 12:00', cpuName: 'Intel(R) Core(TM) i7-14700F', gpuName: 'NVIDIA GeForce RTX 5080', resW: 2560, resH: 1440, cpu: { avg: 35, coreAvg: 90, clockStart: 5300, clockEnd: 3600 }, tl: { clk: Array.from({ length: 60 }, (_, i) => i < 28 ? 5300 : 3600), fps: [200, 190] } });
  await page.click('[data-tab="game"]');
  await page.evaluate(c => { document.querySelector('#gtPaste').value = c; document.querySelector('#gtImport').click(); }, 'PCBANGG1:' + b64(g2)); await page.waitForTimeout(300);
  const d2 = await page.innerText('#gtDetail');
  ok(/CPU 클럭 저하 \(5,300→3,600MHz\)/.test(d2) && await page.$('#gtcClk') !== null, '실전 테스트: CPU 클럭 저하 판정·클럭 그래프');
  ok(/같은 부품 예상\(1440p, 측정 화면 2560×1440\)/.test(d2), '실전 테스트: 측정 해상도 기준 예상치');

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

  // 7. 웹 결과 파일 이름이 점검 프로그램 결과(seat-23.txt)와 겹치지 않음
  const ctx2 = await browser.newContext({ acceptDownloads: true }); const p3 = await ctx2.newPage();
  p3.on('pageerror', e => errs.push(e.message));
  await p3.goto(URL + '?seat=23'); await p3.waitForTimeout(300);
  const [dl] = await Promise.all([p3.waitForEvent('download'), p3.click('#codeSave')]);
  ok(dl.suggestedFilename() === 'seat-23-web.txt', '결과 파일 저장: seat-23-web.txt (점검 프로그램 파일을 덮어쓰지 않음)');
  await ctx2.close();

  ok(errs.length === 0, '페이지 오류 없음' + (errs.length ? ': ' + errs.join(' / ') : ''));
  await browser.close();
  console.log(fails ? `\n${fails}개 실패` : '\n모두 통과');
  process.exit(fails ? 1 : 0);
})();

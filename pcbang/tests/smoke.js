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
  ok(j.find(x => x[0] === 'val')[3] === 'block', '판정: Win11 보안 부팅 꺼짐 → 발로란트 설정 때문에 실행 불가');
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

  // 6. 모바일 폭 가로 넘침
  await page.setViewportSize({ width: 390, height: 844 });
  for (const t of ['home', 'game', 'games', 'log', 'dev', 'fix']) { await page.click(`[data-tab="${t}"]`); await page.waitForTimeout(100); }
  ok(await page.evaluate(() => document.documentElement.scrollWidth) <= 390, '모바일: 가로 넘침 없음');

  ok(errs.length === 0, '페이지 오류 없음' + (errs.length ? ': ' + errs.join(' / ') : ''));
  await browser.close();
  console.log(fails ? `\n${fails}개 실패` : '\n모두 통과');
  process.exit(fails ? 1 : 0);
})();

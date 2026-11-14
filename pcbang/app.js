/* PC방 게임 점검 — 브라우저만으로 동작. data.js(GAMES, GPU_TABLE, CPU_TABLE)를 먼저 불러와야 함. */
(function () {
'use strict';
var $ = function (s, r) { return (r || document).querySelector(s); };
var $$ = function (s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); };
var esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]; }); };
var fmt = function (n, d) { if (n == null || !isFinite(n)) return '-'; return Number(n).toLocaleString('ko-KR', { maximumFractionDigits: d == null ? 0 : d, minimumFractionDigits: d || 0 }); };
var median = function (a) { if (!a.length) return NaN; var b = a.slice().sort(function (x, y) { return x - y; }); var m = b.length >> 1; return b.length % 2 ? b[m] : (b[m - 1] + b[m]) / 2; };
var sleep = function (ms) { return new Promise(function (r) { setTimeout(r, ms); }); };
var store = {
  get: function (k, d) { try { var v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } },
  set: function (k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} }
};
var KEY = 'pcbang_check_v1';
var toastT;
function toast(msg) { var t = $('#toast'); t.textContent = msg; t.classList.add('show'); clearTimeout(toastT); toastT = setTimeout(function () { t.classList.remove('show'); }, 2200); }

/* ---------------- 상태 ---------------- */
var S = store.get(KEY, null) || {};
S.manual = S.manual || {};      // 직접 고른 값 {cpu, gpu, ram, os}
S.det = S.det || {};            // 자동 감지
S.bench = S.bench || {};        // {cpuSingle, cpuMulti, gpu}
S.net = S.net || null;          // 브라우저 인터넷 측정
S.native = S.native || null;    // 윈도우 점검 프로그램 결과
S.dev = S.dev || {};            // {hz, pollMax, pollAvg, chatter, kbMax, kbChat, react}
S.seat = S.seat || '';
S.opt = S.opt || { res: '1080', preset: 'mid', target: 'auto' };
function save() { var c = {}; for (var k in S) if (k !== 'records') c[k] = S[k]; store.set(KEY, c); }
var records = store.get(KEY + '_rec', []);

/* ---------------- 테마 ---------------- */
function applyTheme() {
  var t = store.get('pcbang_theme', null);
  if (!t) t = (window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light';
  document.documentElement.setAttribute('data-theme', t);
  $('#themeBtn').textContent = t === 'dark' ? '밝은 화면' : '어두운 화면';
  var m = document.querySelector('meta[name=theme-color]'); if (m) m.content = t === 'dark' ? '#0E1116' : '#F5F6F8';
}
$('#themeBtn').addEventListener('click', function () { var cur = document.documentElement.getAttribute('data-theme'); store.set('pcbang_theme', cur === 'dark' ? 'light' : 'dark'); applyTheme(); });
applyTheme();

/* ---------------- 탭 ---------------- */
function showTab(name) {
  $$('.tabs button').forEach(function (b) { b.setAttribute('aria-selected', b.dataset.tab === name ? 'true' : 'false'); });
  $$('[data-panel]').forEach(function (p) { p.hidden = p.dataset.panel !== name; });
  if (name === 'games') renderGames();
  if (name === 'log') renderRecords();
  if (name === 'spec') renderSpec();
  if (name === 'dev') { buildKeyboard(); }
  try { history.replaceState(null, '', '#' + name); } catch (e) {}
  window.scrollTo(0, 0);
}
$$('.tabs button').forEach(function (b) { b.addEventListener('click', function () { showTab(b.dataset.tab); }); });
document.addEventListener('click', function (e) { var g = e.target.closest && e.target.closest('[data-goto]'); if (g) { e.preventDefault(); showTab(g.dataset.goto); } });

/* ---------------- 부품 표 ---------------- */
function parseTable(txt, kind) {
  return txt.trim().split('\n').map(function (line) {
    var p = line.split('|').map(function (s) { return s.trim(); });
    var o = { name: p[0] };
    if (kind === 'gpu') { o.score = +p[1]; o.vram = p[2] ? +p[2] : null; o.alias = (p[3] || '').split(',').filter(Boolean); }
    else { o.multi = +p[1]; o.single = +p[2]; o.threads = p[3] ? +p[3] : null; o.alias = (p[4] || '').split(',').filter(Boolean); }
    return o;
  });
}
var GPUS = parseTable(window.GPU_TABLE, 'gpu');
var CPUS = parseTable(window.CPU_TABLE, 'cpu');
var GAMES = window.GAMES;

// 그래픽 이름 정규화: detect-gpu(pmndrs)의 cleanRenderer 방식을 참고해 ANGLE 껍질, Direct3D 꼬리, (R)(TM) 등을 걷어 냄
function cleanRenderer(r) {
  r = String(r || '').toLowerCase();
  r = r.replace(/, or similar$/, '');
  r = r.replace(/.*angle ?\((.+)\)(?: on vulkan [0-9.]+)?$/i, '$1');
  r = r.replace(/\s(\d{1,2}gb|direct3d.+$)|\(r\)|\(tm\)| \([^)]+\)$/g, '');
  r = r.replace(/\(0x[0-9a-f]+\)/g, '');
  r = r.replace(/(?:vulkan|opengl) \d+\.\d+(?:\.\d+)?(?: \((.*)\))?/, '$1');
  r = r.replace(/,\s*(d3d\d+|opengl|vulkan|metal).*$/, '');
  // 'nvidia, nvidia geforce rtx 3060' → 마지막 쉼표 뒤가 모델
  if (r.indexOf(',') >= 0) r = r.split(',').slice(1).join(',');
  return r.replace(/\s+/g, ' ').trim();
}
function gkey(s) {
  return String(s).toLowerCase()
    .replace(/\(r\)|\(tm\)|®|™/g, '')
    .replace(/\b(nvidia|geforce|amd|ati|radeon|intel|graphics|series|gpu|corporation|technologies|inc\.?)\b/g, '')
    .replace(/[^a-z0-9]/g, '');
}
GPUS.forEach(function (g) { g.keys = [gkey(g.name)].concat(g.alias.map(gkey)).filter(Boolean); });
function matchGpu(raw) {
  if (!raw) return null;
  var lower = String(raw).toLowerCase();
  var k = gkey(cleanRenderer(raw)) || gkey(raw);
  var best = null, bestLen = 0;
  GPUS.forEach(function (g) {
    g.keys.forEach(function (key) {
      var i = k.indexOf(key);
      while (i >= 0) {
        var next = k.charAt(i + key.length);
        var prev = i > 0 ? k.charAt(i - 1) : '';
        var okNext = !/[0-9]/.test(next);
        var okPrev = !(/[0-9]/.test(prev) && /^[0-9]/.test(key));
        if (okNext && okPrev && key.length > bestLen) { best = g; bestLen = key.length; }
        i = k.indexOf(key, i + 1);
      }
    });
  });
  if (!best) return null;
  // 메모리 용량만 다른 모델(GTX 1060 3GB/6GB 등): 원래 문자열의 용량으로 고름
  var gbm = lower.match(/(\d{1,2})\s?gb/);
  if (gbm) {
    var alt = GPUS.filter(function (g) { return g !== best && g.name.replace(/ \d+GB$/i, '') === best.name.replace(/ \d+GB$/i, '') && g.name.toLowerCase().slice(-(gbm[1].length + 3)) === ' ' + gbm[1] + 'gb'; })[0];
    if (alt) best = alt;
  }
  var mobile = /laptop|mobile|max-q|\bmx\d|notebook/.test(lower) || /\d{3,4}m\b/.test(lower.replace(/radeon \d{3}m/, ''));
  var isIgpuName = /^(radeon)?\d{3}m$/.test(best.keys[0]);
  return { name: best.name + (mobile && !isIgpuName ? ' (노트북)' : ''), score: Math.round(best.score * (mobile && !isIgpuName ? 0.72 : 1)), vram: best.vram, base: best };
}
function ckey(s) {
  s = String(s).toLowerCase().replace(/\(r\)|\(tm\)|®|™/g, '').replace(/\s+/g, ' ');
  s = s.replace(/라이젠/g, 'ryzen ').replace(/코어/g, 'core ').replace(/인텔/g, '').replace(/울트라/g, 'ultra ');
  var m;
  if ((m = s.match(/core\s*ultra\s*([3579])\s*(?:processor\s*)?(\d{3})([a-z]*)/)) || (m = s.match(/\bultra\s*([3579])\s*(\d{3})([a-z]*)/))) return 'ultra' + m[1] + m[2] + (m[3].indexOf('k') >= 0 ? 'k' : '');
  if ((m = s.match(/\bi([3579])[\s-]*(\d{4,5})([a-z]*)/))) return 'i' + m[1] + m[2] + (m[3].indexOf('k') >= 0 ? 'k' : '');
  if ((m = s.match(/ryzen\s*([3579])?\s*(?:pro\s*)?(\d{4})([a-z0-9]*)/)) || (m = s.match(/^\s*()(\d{4})(x3d|xt|x|g|ge|f)?\s*$/))) {
    var suf = m[3] || ''; suf = /x3d/.test(suf) ? 'x3d' : /xt/.test(suf) ? 'xt' : /x/.test(suf) ? 'x' : /g/.test(suf) ? 'g' : '';
    return 'r' + m[2] + suf;
  }
  if ((m = s.match(/fx[\s-]*(\d{4})/))) return 'fx' + m[1];
  if ((m = s.match(/phenom.*?(\d{3,4})/))) return 'phenom' + m[1];
  if ((m = s.match(/athlon.*?(\d{3,4})(ge|g)?/))) return 'athlon' + m[1] + (m[2] || '');
  if ((m = s.match(/(e\d{4}|q\d{4})/))) return m[1];
  return s.replace(/[^a-z0-9]/g, '');
}
CPUS.forEach(function (c) { c.keys = [ckey(c.name)].concat(c.alias.map(ckey)); });
function matchCpu(raw) {
  if (!raw) return null;
  var k = ckey(raw);
  if (!k) return null;
  var hit = null;
  CPUS.forEach(function (c) { if (!hit && c.keys.indexOf(k) >= 0) hit = c; });
  if (!hit && /^r\d{4}/.test(k)) { // 접미사만 다른 라이젠(예: 5600G → 5600 근사)
    var base = k.replace(/(x3d|xt|x|g)$/, '');
    CPUS.forEach(function (c) { if (!hit && c.keys[0].replace(/(x3d|xt|x|g)$/, '') === base) hit = c; });
  }
  if (!hit && /^i\d\d{4,5}k$/.test(k)) { var nk = k.slice(0, -1); CPUS.forEach(function (c) { if (!hit && c.keys.indexOf(nk) >= 0) hit = c; }); }
  if (!hit && /^i\d\d{4,5}$/.test(k)) { CPUS.forEach(function (c) { if (!hit && c.keys.indexOf(k + 'k') >= 0) hit = c; }); }
  return hit ? { name: hit.name, multi: hit.multi, single: hit.single, threads: hit.threads } : null;
}
function gpuScoreOfList(list) {
  var sc = (list || []).map(function (n) { var m = matchGpu(n); return m ? m.score : null; }).filter(function (x) { return x; });
  return sc.length ? Math.min.apply(null, sc) : null;
}
function cpuOfList(list) {
  var c = (list || []).map(matchCpu).filter(Boolean);
  if (!c.length) return null;
  return { multi: Math.min.apply(null, c.map(function (x) { return x.multi; })), single: Math.min.apply(null, c.map(function (x) { return x.single; })) };
}
// 게임용 CPU 지수: 단일 코어 60% + 전체 40% (게임은 단일 코어 영향이 큼)
function cpuIndex(c) { return c ? 0.6 * (c.single / 2500) + 0.4 * (c.multi / 10000) : null; }

/* ---------------- 자동 감지 ---------------- */
async function detect() {
  var d = { at: Date.now() };
  try {
    var cv = document.createElement('canvas');
    var gl = cv.getContext('webgl2', { powerPreference: 'high-performance' }) || cv.getContext('webgl', { powerPreference: 'high-performance' });
    if (gl) {
      var ext = /firefox/i.test(navigator.userAgent) ? null : gl.getExtension('WEBGL_debug_renderer_info');
      d.renderer = ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
      d.vendor = ext ? gl.getParameter(ext.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR);
      d.webgl = (typeof WebGL2RenderingContext !== 'undefined' && gl instanceof WebGL2RenderingContext) ? 2 : 1;
      var lose = gl.getExtension('WEBGL_lose_context'); if (lose) lose.loseContext();
    } else d.webgl = 0;
  } catch (e) { d.webgl = 0; }
  try {
    if (navigator.gpu) {
      var ad = await Promise.race([navigator.gpu.requestAdapter({ powerPreference: 'high-performance' }), sleep(1500).then(function () { return null; })]);
      if (ad) { var info = ad.info || (ad.requestAdapterInfo ? await ad.requestAdapterInfo() : null); if (info) d.webgpu = [info.vendor, info.architecture, info.description].filter(Boolean).join(' / ') || '지원'; else d.webgpu = '지원'; }
    }
  } catch (e) {}
  d.threads = navigator.hardwareConcurrency || null;
  d.memGB = navigator.deviceMemory || null;
  d.screen = { w: screen.width, h: screen.height, dpr: window.devicePixelRatio || 1 };
  d.ua = navigator.userAgent;
  d.os = /Windows/.test(navigator.userAgent) ? 'win' : /Mac OS X/.test(navigator.userAgent) ? 'mac' : /Android/.test(navigator.userAgent) ? 'android' : /Linux/.test(navigator.userAgent) ? 'linux' : 'other';
  d.osName = { win: 'Windows', mac: 'macOS', android: 'Android', linux: 'Linux', other: '알 수 없음' }[d.os];
  try {
    if (navigator.userAgentData && navigator.userAgentData.getHighEntropyValues) {
      var hv = await navigator.userAgentData.getHighEntropyValues(['platformVersion', 'architecture', 'bitness']);
      d.bitness = hv.bitness; d.arch = hv.architecture;
      if (navigator.userAgentData.platform === 'Windows') {
        var major = parseInt((hv.platformVersion || '0').split('.')[0], 10);
        d.win = major >= 13 ? 'win11' : major > 0 ? 'win10' : 'win7';
        d.osName = d.win === 'win11' ? 'Windows 11' : d.win === 'win10' ? 'Windows 10' : 'Windows 7/8.1';
      }
    } else if (d.os === 'win') d.osName = 'Windows 10 또는 11';
  } catch (e) {}
  if (/WOW64|Win64|x64/.test(navigator.userAgent) || d.bitness === '64') d.is64 = true;
  S.det = d; save();
  return d;
}
function softwareRenderer(r) { return /swiftshader|llvmpipe|basic render|microsoft basic|softpipe|software/i.test(r || ''); }

/* ---------------- 최종 사양 ---------------- */
function spec() {
  var o = { src: {} };
  var nat = S.native || {};
  // GPU: 직접 입력 > 점검 프로그램 > 자동 감지
  var gm = null;
  if (S.manual.gpu) { gm = matchGpu(S.manual.gpu); o.src.gpu = '직접 입력'; }
  if (!gm && nat.gpus && nat.gpus.length) {
    var cands = nat.gpus.map(function (g) { var m = matchGpu(g.name); if (m && g.vram) m.vramReal = g.vram; return m; }).filter(Boolean).sort(function (a, b) { return b.score - a.score; });
    if (cands.length) { gm = cands[0]; o.src.gpu = '점검 프로그램'; }
  }
  if (!gm && S.det.renderer) { gm = matchGpu(S.det.renderer); if (gm) o.src.gpu = '자동 감지'; }
  o.gpu = gm;
  o.gpuRaw = S.manual.gpu || (nat.gpus && nat.gpus[0] && nat.gpus[0].name) || S.det.renderer || '';
  o.vram = gm && (gm.vramReal || gm.vram) || null;
  // CPU
  var cm = null;
  if (S.manual.cpu) { cm = matchCpu(S.manual.cpu); o.src.cpu = '직접 입력'; }
  if (!cm && nat.cpu) { cm = matchCpu(nat.cpu); if (cm) o.src.cpu = '점검 프로그램'; }
  if (!cm && S.bench.cpuSingle) { // 브라우저 측정값으로 대략 추정
    cm = { name: '측정 기반 추정', single: Math.round(S.bench.cpuSingle * BENCH_TO_ST), multi: Math.round((S.bench.cpuMulti || S.bench.cpuSingle) * BENCH_TO_ST * 0.85 * 3.0), estimated: true };
    o.src.cpu = '벤치마크 추정';
  }
  o.cpu = cm;
  o.cpuRaw = S.manual.cpu || nat.cpu || '';
  // RAM
  o.ram = S.manual.ram ? +S.manual.ram : nat.ramGB ? Math.round(nat.ramGB) : null;
  o.src.ram = S.manual.ram ? '직접 입력' : nat.ramGB ? '점검 프로그램' : null;
  if (!o.ram && S.det.memGB) { o.ramAtLeast = S.det.memGB; }
  // OS
  o.os = S.manual.os || nat.os || S.det.win || null;
  o.threads = (nat.threads) || S.det.threads || (cm && cm.threads) || null;
  o.hz = (nat.hz) || S.dev.hz || null;
  return o;
}
// 브라우저 CPU 점수 → PassMark 단일 코어 근사 환산 계수 (Xeon 2.1GHz 기준 실측 보정, 대략값)
var BENCH_TO_ST = 1.0;

/* ---------------- 게임 판정 ---------------- */
var PRESET = { low: 1.65, mid: 1.0, high: 0.72 };
var RES = { '1080': 1, '1440': 0.6, '2160': 0.3 };
function judge(game, sp, opt) {
  var r = { comps: [], issues: [], level: 'ok' };
  var minG = gpuScoreOfList(game.min.gpu), recG = gpuScoreOfList(game.rec.gpu);
  var minC = cpuOfList(game.min.cpu), recC = cpuOfList(game.rec.cpu);
  function lvl(v, mn, rc) { if (v == null || mn == null) return 'unk'; if (v >= (rc || mn)) return 'rec'; if (v >= mn * 0.95) return 'min'; return 'fail'; }
  // GPU
  var gL = sp.gpu ? lvl(sp.gpu.score, minG, recG) : 'unk';
  r.comps.push({ k: '그래픽', v: sp.gpu ? sp.gpu.score : null, mn: minG, rc: recG, l: gL });
  // CPU
  var ci = cpuIndex(sp.cpu), cmi = cpuIndex(minC), cri = cpuIndex(recC);
  var cL = sp.cpu ? lvl(ci, cmi, cri) : 'unk';
  r.comps.push({ k: 'CPU', v: ci, mn: cmi, rc: cri, l: cL, est: sp.cpu && sp.cpu.estimated });
  // RAM
  var ram = sp.ram || null;
  var rL = ram ? lvl(ram, game.min.ram, game.rec.ram) : (sp.ramAtLeast ? (sp.ramAtLeast >= game.min.ram ? (sp.ramAtLeast >= game.rec.ram ? 'rec' : 'min') : 'unk') : 'unk');
  r.comps.push({ k: 'RAM', v: ram || sp.ramAtLeast, mn: game.min.ram, rc: game.rec.ram, l: rL, atLeast: !ram && sp.ramAtLeast });
  // VRAM
  if (game.rec.vram && sp.vram) {
    var vL = lvl(sp.vram, game.min.vram || 1, game.rec.vram);
    r.comps.push({ k: 'VRAM', v: sp.vram, mn: game.min.vram || 1, rc: game.rec.vram, l: vL });
  }
  // OS
  if (sp.os) {
    var need = game.min.os || 'win10';
    var osOk = sp.os === 'win11' || (sp.os === 'win10' && need !== 'win11') || (sp.os === 'win7' && need === 'win7');
    if (sp.os === 'win10-32') osOk = false;
    if (!osOk) r.issues.push({ l: 'fail', t: '운영체제: ' + (need === 'win11' ? 'Windows 11' : 'Windows 10 64비트 이상') + ' 필요' });
  }
  (game.checks || []).forEach(function (c) { r.issues.push({ l: 'info', t: c }); });
  var ls = r.comps.map(function (c) { return c.l; });
  if (ls.indexOf('fail') >= 0 || r.issues.some(function (i) { return i.l === 'fail'; })) r.level = 'fail';
  else if (ls.indexOf('unk') >= 0 && !(sp.gpu)) r.level = 'unk';
  else if (ls.indexOf('min') >= 0) r.level = 'min';
  else if (ls.indexOf('unk') >= 0) r.level = 'partial';
  else r.level = 'rec';
  // FPS 추정: 그래픽 한계와 CPU 한계 중 낮은 쪽 (병목 모델)
  if (sp.gpu) {
    var f = game.fps;
    // 저사양 그래픽은 가벼운 게임에서 점수 비율보다 덜 떨어짐 → 지수(e) < 1 로 완만하게
    var gpuFps = Math.pow(sp.gpu.score / 17000, f.e || 0.85) * f.g3060 * PRESET[opt.preset] * RES[opt.res];
    var cpuFps = sp.cpu ? (cpuIndex(sp.cpu) / cpuIndex({ single: 3500, multi: 19500 })) * f.c12400 * (opt.preset === 'low' ? 1.08 : opt.preset === 'high' ? 0.95 : 1) : null;
    var fps = cpuFps == null ? gpuFps : Math.min(gpuFps, cpuFps);
    if (f.cap) fps = Math.min(fps, f.cap);
    if (ram && ram < game.min.ram) fps *= 0.55;
    else if (ram && ram < game.rec.ram) fps *= 0.9;
    r.fps = Math.max(1, Math.round(fps));
    r.bottleneck = cpuFps == null ? null : (cpuFps < gpuFps * 0.9 ? 'CPU' : gpuFps < cpuFps * 0.9 ? '그래픽' : null);
    r.fpsNoCpu = cpuFps == null;
  }
  return r;
}
var LV = { rec: ['ok', '권장 사양 충족'], min: ['warn', '최소 사양만 충족'], fail: ['bad', '사양 부족'], unk: ['', '정보 부족'], partial: ['info', '일부 확인 필요'] };
function targetFps(opt) { if (opt.target !== 'auto') return +opt.target; var hz = spec().hz; return hz ? Math.min(hz, 240) : 60; }
function fpsLabel(fps, tgt) {
  if (fps >= tgt) return ['ok', tgt + 'fps 이상 유지 예상'];
  if (fps >= Math.min(60, tgt) * 0.95) return ['warn', '60fps 이상, ' + tgt + 'fps는 어려움'];
  if (fps >= 30) return ['warn', '30~60fps (옵션 낮춤 권장)'];
  return ['bad', '30fps 미만 (원활하지 않음)'];
}
function renderGames() {
  var sp = spec(), opt = S.opt;
  $('#optRes').value = opt.res; $('#optPreset').value = opt.preset; $('#optTarget').value = opt.target;
  $('#rankSrc').textContent = window.RANK_SOURCE || '';
  var w = [];
  if (!sp.gpu) w.push('<div class="warnbox">그래픽카드를 알아내지 못했어요. <a href="#spec" data-goto="spec">내 사양</a>에서 직접 고르세요.</div>');
  if (!sp.cpu) w.push('<div class="warnbox">CPU를 모르면 그래픽 기준으로만 계산해요. <a href="#spec" data-goto="spec">내 사양</a>에서 CPU를 고르거나 <a href="#bench" data-goto="bench">CPU 측정</a>을 하세요.</div>');
  else if (sp.cpu.estimated) w.push('<div class="note">CPU는 브라우저 측정값으로 대략 추정했어요. 정확히 하려면 <a href="#spec" data-goto="spec">내 사양</a>에서 CPU 모델을 고르세요.</div>');
  if (S.det.renderer && softwareRenderer(S.det.renderer)) {
    if (sp.gpu && sp.src.gpu !== '자동 감지') w.push('<div class="note">브라우저가 그래픽카드를 쓰지 않고 있어요(하드웨어 가속 꺼짐). 판정은 ' + esc(sp.src.gpu) + ' 값(' + esc(sp.gpu.name) + ')으로 했지만, 그래픽 드라이버가 제대로 설치됐는지 확인하세요.</div>');
    else w.push('<div class="badbox">그래픽 가속이 꺼져 있거나 그래픽 드라이버가 없어요(' + esc(S.det.renderer) + '). 실제 게임도 매우 느릴 수 있어요. 드라이버 설치와 브라우저의 하드웨어 가속 설정을 확인하세요.</div>');
  }
  $('#gameWarn').innerHTML = w.join('');
  var tgt = targetFps(opt);
  $('#gameGrid').innerHTML = GAMES.map(function (g) {
    var j = judge(g, sp, opt), lv = LV[j.level];
    var fpsHtml = '';
    if (j.fps != null) {
      var fl = fpsLabel(j.fps, tgt);
      fpsHtml = '<div class="fps"><b>' + (j.fps >= (g.fps.cap || 9999) ? g.fps.cap + '+' : '약 ' + fmt(j.fps)) + '</b><span class="muted small">fps 예상</span><span class="pill ' + fl[0] + '">' + fl[1] + '</span></div>' +
        (j.bottleneck ? '<div class="xs muted">병목: ' + j.bottleneck + (j.bottleneck === 'CPU' ? ' (그래픽 옵션을 낮춰도 크게 안 오름)' : ' (옵션·해상도를 낮추면 올라감)') + '</div>' : '') +
        (j.fpsNoCpu ? '<div class="xs muted">CPU 미확인: 그래픽 기준 값</div>' : '');
    }
    var comps = j.comps.map(function (c) {
      var col = c.l === 'rec' ? 'var(--ok)' : c.l === 'min' ? 'var(--warn)' : c.l === 'fail' ? 'var(--bad)' : 'var(--line)';
      var pct = c.v != null && c.rc ? Math.min(100, Math.round(c.v / c.rc * 100)) : 0;
      var txt = c.l === 'unk' ? '모름' : c.l === 'rec' ? '권장 ✓' : c.l === 'min' ? '최소 ✓' : '부족 ✗';
      if (c.atLeast && c.l !== 'unk') txt = c.atLeast + 'GB 이상 · ' + txt;
      return '<span>' + c.k + '</span><span class="meter" title="권장 대비 ' + pct + '%"><i style="width:' + pct + '%;background:' + col + '"></i></span><span>' + txt + '</span>';
    }).join('');
    var issues = j.issues.map(function (i) { return '<div class="xs ' + (i.l === 'fail' ? 'badbox' : 'muted') + '">' + (i.l === 'fail' ? '' : '· ') + esc(i.t) + '</div>'; }).join('');
    return '<article class="card game"><div class="gh"><span class="rank">' + g.rank + '</span><span class="gn">' + esc(g.name) + (g.share ? ' <span class="xs muted">' + esc(g.share) + '</span>' : '') + '</span><span class="pill ' + lv[0] + '">' + lv[1] + '</span></div>' +
      fpsHtml + '<div class="comp">' + comps + '</div>' + issues +
      '<details><summary>공식 요구 사양 보기</summary>' + reqTable(g) + '</details></article>';
  }).join('');
}
function reqTable(g) {
  function row(k, a, b) { return '<tr><th>' + k + '</th><td>' + esc(a || '-') + '</td><td>' + esc(b || '-') + '</td></tr>'; }
  var m = g.min, r = g.rec;
  var osN = function (o) { return o === 'win11' ? 'Windows 11' : o === 'win7' ? 'Windows 7 64비트 이상' : 'Windows 10 64비트'; };
  return '<div class="tblwrap"><table><thead><tr><th></th><th>최소</th><th>권장</th></tr></thead><tbody>' +
    row('CPU', (m.cpu || []).join(' / '), (r.cpu || []).join(' / ')) +
    row('그래픽', (m.gpu || []).join(' / '), (r.gpu || []).join(' / ')) +
    row('RAM', m.ram + 'GB', r.ram + 'GB') +
    (m.vram || r.vram ? row('VRAM', m.vram ? m.vram + 'GB' : '', r.vram ? r.vram + 'GB' : '') : '') +
    row('운영체제', osN(m.os), osN(r.os || m.os)) +
    (m.storage ? row('저장 공간', m.storage, r.storage || m.storage) : '') +
    '</tbody></table></div>' + (g.src ? '<div class="xs muted">출처: ' + esc(g.src) + '</div>' : '');
}
['#optRes', '#optPreset', '#optTarget'].forEach(function (id) {
  $(id).addEventListener('change', function () { S.opt = { res: $('#optRes').value, preset: $('#optPreset').value, target: $('#optTarget').value }; save(); renderGames(); });
});

/* ---------------- 내 사양 탭 ---------------- */
function fillLists() {
  $('#cpuList').innerHTML = CPUS.map(function (c) { return '<option value="' + esc(c.name) + '">'; }).join('');
  $('#gpuList').innerHTML = GPUS.map(function (g) { return '<option value="' + esc(g.name) + '">'; }).join('');
}
function renderSpec() {
  var d = S.det, sp = spec(), nat = S.native;
  var rows = [];
  function kv(k, v) { rows.push('<dt>' + k + '</dt><dd>' + v + '</dd>'); }
  kv('그래픽(브라우저)', d.renderer ? esc(d.renderer) + (sp.gpu && sp.src.gpu === '자동 감지' ? ' <span class="pill ok">' + esc(sp.gpu.name) + ' · 점수 ' + fmt(sp.gpu.score) + '</span>' : (matchGpu(d.renderer) ? '' : ' <span class="pill warn">표에 없음</span>')) : '<span class="muted">못 읽음</span>');
  if (d.webgpu) kv('WebGPU', esc(d.webgpu));
  kv('CPU 스레드', d.threads ? d.threads + '개 (논리 코어)' : '-');
  kv('메모리(브라우저)', d.memGB ? d.memGB + 'GB 이상 (브라우저는 2의 거듭제곱으로 내림한 근사값만 알려 줘요. 예: 12GB → 8GB)' : '<span class="muted">못 읽음 (크롬·엣지만 지원)</span>');
  kv('운영체제', esc(d.osName || '-') + (d.is64 ? ' · 64비트' : ''));
  kv('화면', d.screen ? d.screen.w + '×' + d.screen.h + ' (배율 ' + d.screen.dpr + ') → 실제 ' + Math.round(d.screen.w * d.screen.dpr) + '×' + Math.round(d.screen.h * d.screen.dpr) : '-');
  kv('모니터 주사율', S.dev.hz ? S.dev.hz + 'Hz' : '<a href="#dev" data-goto="dev">측정하기</a>');
  if (nat) {
    kv('점검 프로그램', '<span class="pill ok">적용됨 ' + esc(nat.time || '') + '</span>');
    kv('· CPU', esc(nat.cpu || '-') + (nat.cores ? ' (' + nat.cores + '코어 ' + nat.threads + '스레드)' : ''));
    kv('· 그래픽', (nat.gpus || []).map(function (g) { return esc(g.name) + (g.vram ? ' ' + g.vram + 'GB' : '') + (g.driver ? ' · 드라이버 ' + esc(g.driver) : ''); }).join('<br>') || '-');
    kv('· RAM', nat.ramGB ? nat.ramGB + 'GB' + (nat.ramSpeed ? ' · ' + nat.ramSpeed + 'MHz' : '') + (nat.ramSticks ? ' · ' + nat.ramSticks + '개' : '') : '-');
    kv('· 운영체제', esc(nat.osName || '-'));
    if (nat.power) kv('· 전원 관리', esc(nat.power));
    if (nat.disks) kv('· 저장 장치', nat.disks.map(function (x) { return esc(x.name) + ' 남은 ' + x.free + '/' + x.size + 'GB'; }).join('<br>'));
  }
  $('#detKv').innerHTML = rows.join('');
  var w = [];
  if (d.renderer && softwareRenderer(d.renderer)) w.push('<div class="badbox">소프트웨어 렌더링 중이에요. 그래픽 드라이버가 없거나 브라우저 하드웨어 가속이 꺼져 있어요.</div>');
  if (d.renderer && /intel|uhd|iris/i.test(d.renderer) && nat && nat.gpus && nat.gpus.length > 1) w.push('<div class="warnbox">브라우저가 내장 그래픽을 쓰고 있어요. 게임은 외장 그래픽으로 돌아가는지 그래픽 설정에서 확인하세요.</div>');
  if (/firefox/i.test(navigator.userAgent)) w.push('<div class="note">파이어폭스는 그래픽카드 이름을 비슷한 모델로 바꿔서 알려 줘요. 정확한 판정은 크롬이나 엣지에서 하세요.</div>');
  if (sp.hz && S.det.screen && sp.hz <= 61 && S.dev.hzMax && S.dev.hzMax > 61) w.push('');
  if (nat && nat.power && /절전|power saver|balanced|균형/i.test(nat.power)) w.push('<div class="warnbox">전원 관리 옵션이 \'' + esc(nat.power) + '\'예요. PC방은 \'고성능\'으로 두는 게 좋아요.</div>');
  $('#detWarn').innerHTML = w.join('');
  $('#cpuIn').value = S.manual.cpu || ''; $('#gpuIn').value = S.manual.gpu || ''; $('#ramIn').value = S.manual.ram || ''; $('#osIn').value = S.manual.os || '';
  showMatch();
}
function showMatch() {
  var c = $('#cpuIn').value.trim(), g = $('#gpuIn').value.trim(), out = [];
  if (c) { var cm = matchCpu(c); out.push(cm ? '<span class="pill ok">CPU: ' + esc(cm.name) + ' · 단일 ' + fmt(cm.single) + ' / 전체 ' + fmt(cm.multi) + '</span>' : '<span class="pill warn">CPU "' + esc(c) + '"를 표에서 못 찾았어요. 목록에서 가까운 것을 고르세요.</span>'); }
  if (g) { var gm = matchGpu(g); out.push(gm ? '<span class="pill ok">그래픽: ' + esc(gm.name) + ' · 점수 ' + fmt(gm.score) + '</span>' : '<span class="pill warn">그래픽 "' + esc(g) + '"를 표에서 못 찾았어요.</span>'); }
  $('#matchInfo').innerHTML = out.join(' ');
}
$('#cpuIn').addEventListener('input', showMatch);
$('#gpuIn').addEventListener('input', showMatch);
$('#saveSpec').addEventListener('click', function () {
  S.manual = { cpu: $('#cpuIn').value.trim(), gpu: $('#gpuIn').value.trim(), ram: $('#ramIn').value, os: $('#osIn').value };
  save(); toast('저장했어요'); showTab('games');
});
$('#clearSpec').addEventListener('click', function () { S.manual = {}; save(); renderSpec(); toast('직접 고른 값을 지웠어요'); });
$('#redetect').addEventListener('click', async function () { await detect(); renderSpec(); toast('다시 감지했어요'); });

/* 윈도우 점검 프로그램 결과: "PCBANG1:" + base64(UTF-8 JSON) */
function decodeNative(txt) {
  var m = String(txt).match(/PCBANG1:([A-Za-z0-9+/=\s]+)/);
  if (!m) throw new Error('PCBANG1: 로 시작하는 코드가 없어요');
  var b64 = m[1].replace(/\s+/g, '');
  var bin = atob(b64), bytes = new Uint8Array(bin.length);
  for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  var json = new TextDecoder('utf-8').decode(bytes).replace(/^﻿/, '');
  var o = JSON.parse(json);
  if (!o || typeof o !== 'object') throw new Error('형식이 달라요');
  // 형 정리 (PowerShell 결과는 단일 항목이면 배열이 아닐 수 있음)
  ['gpus', 'pings', 'tcp', 'disks'].forEach(function (k) { if (o[k] && !Array.isArray(o[k])) o[k] = [o[k]]; });
  return o;
}
$('#nativeApply').addEventListener('click', function () {
  try {
    var o = decodeNative($('#nativeIn').value);
    S.native = o; save(); renderSpec(); renderNativeNet();
    $('#nativeMsg').innerHTML = '<span class="pill ok">적용했어요</span>';
    toast('점검 프로그램 결과를 적용했어요');
  } catch (e) { $('#nativeMsg').innerHTML = '<span class="pill bad">읽지 못했어요: ' + esc(e.message) + '</span>'; }
});

/* ---------------- CPU 벤치마크 (Web Worker) ---------------- */
var WORKER_SRC = 'onmessage=function(e){var dur=e.data.dur,t0=performance.now(),n=0,acc=0;' +
  'function work(){var a=new Float64Array(256),s=0,x=12345;for(var i=0;i<256;i++){x=(x*1103515245+12345)&0x7fffffff;a[i]=x/2147483647;}' +
  'for(var k=0;k<4;k++){for(var i=1;i<256;i++){s+=Math.sqrt(a[i]*a[i-1]+1)*Math.sin(a[i]);}}' +
  'var o={};for(var j=0;j<64;j++){o["k"+(j&15)]=(o["k"+(j&15)]||0)+j;}' +
  'var arr=[];for(var j=0;j<128;j++)arr.push((j*7919)%128);arr.sort(function(p,q){return p-q});' +
  'var str="";for(var j=0;j<16;j++)str+=String.fromCharCode(65+(j*7)%26);' +
  'return s+arr[5]+str.length+o.k3;}' +
  'while(performance.now()-t0<dur){for(var r=0;r<20;r++){acc+=work();n++;}}' +
  'postMessage({n:n,ms:performance.now()-t0,acc:acc});};';
function runWorkers(count, dur) {
  var url = URL.createObjectURL(new Blob([WORKER_SRC], { type: 'text/javascript' }));
  var ws = [];
  var ps = [];
  for (var i = 0; i < count; i++) {
    (function () {
      var w = new Worker(url); ws.push(w);
      ps.push(new Promise(function (res, rej) { w.onmessage = function (e) { res(e.data); }; w.onerror = rej; w.postMessage({ dur: dur }); }));
    })();
  }
  return Promise.all(ps).then(function (rs) { ws.forEach(function (w) { w.terminate(); }); URL.revokeObjectURL(url); return rs; });
}
async function benchCpu(onProg) {
  var prog = function (p) { if (onProg) onProg(p); };
  prog(5);
  await runWorkers(1, 400); // 예열(JIT)
  prog(15);
  var single = [];
  for (var i = 0; i < 2; i++) { var r = await runWorkers(1, 1000); single.push(r[0].n / r[0].ms * 1000); prog(20 + i * 20); }
  var th = Math.max(1, Math.min(navigator.hardwareConcurrency || 4, 64));
  var rs = await runWorkers(th, 2000);
  prog(95);
  var multi = rs.reduce(function (a, r) { return a + r.n / r.ms * 1000; }, 0);
  // 점수 단위: 초당 작업 수 / 10
  var res = { cpuSingle: Math.round(Math.max.apply(null, single) / 10), cpuMulti: Math.round(multi / 10), threads: th, at: Date.now() };
  prog(100);
  return res;
}
$('#cpuRun').addEventListener('click', async function () {
  var b = this; b.disabled = true; $('#cpuOut').innerHTML = '<span class="muted small">측정 중… 다른 창을 건드리지 마세요</span>';
  try { var r = await benchCpu(function (p) { $('#cpuBar').style.width = p + '%'; }); Object.assign(S.bench, r); save(); renderCpuOut(); }
  catch (e) { $('#cpuOut').innerHTML = '<span class="pill bad">측정 실패: ' + esc(e.message) + '</span>'; }
  b.disabled = false;
});
function renderCpuOut() {
  var b = S.bench; if (!b.cpuSingle) return;
  $('#cpuOut').innerHTML = '<div class="stat"><b>' + fmt(b.cpuSingle) + '</b><span>단일 코어 점수</span></div><div class="stat"><b>' + fmt(b.cpuMulti) + '</b><span>전체 코어 점수 (' + b.threads + '스레드)</span></div><div class="stat"><b>' + fmt(b.cpuMulti / b.cpuSingle, 1) + '배</b><span>코어 확장</span></div>';
}

/* ---------------- GPU 벤치마크 (WebGL) ---------------- */
var VS = 'attribute vec2 p;void main(){gl_Position=vec4(p,0.,1.);}';
var FS = 'precision highp float;uniform vec2 res;uniform float t;' +
  'float map(vec3 p){vec3 q=fract(p)-.5;return length(q)-.25+.05*sin(p.x*3.+t)*sin(p.y*3.)*sin(p.z*3.);}' +
  'void main(){vec2 uv=(gl_FragCoord.xy*2.-res)/res.y;vec3 ro=vec3(0.,0.,t*.5),rd=normalize(vec3(uv,1.5));float d=0.;vec3 col=vec3(0.);' +
  'for(int i=0;i<64;i++){vec3 p=ro+rd*d;float h=map(p);if(h<.001)break;d+=h*.8;}' +
  'vec3 p=ro+rd*d;vec2 e=vec2(.002,0.);vec3 n=normalize(vec3(map(p+e.xyy)-map(p-e.xyy),map(p+e.yxy)-map(p-e.yxy),map(p+e.yyx)-map(p-e.yyx)));' +
  'col=(.5+.5*n)*exp(-d*.12)*(.6+.4*dot(n,normalize(vec3(.4,.8,-.4))));gl_FragColor=vec4(col,1.);}';
async function benchGpu(onProg) {
  var cv = $('#gpuCanvas');
  var W = 1280, H = 720; cv.width = W; cv.height = H;
  var gl = cv.getContext('webgl', { powerPreference: 'high-performance', antialias: false, preserveDrawingBuffer: false });
  if (!gl) throw new Error('WebGL을 쓸 수 없어요');
  function sh(type, src) { var s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s)); return s; }
  var pr = gl.createProgram(); gl.attachShader(pr, sh(gl.VERTEX_SHADER, VS)); gl.attachShader(pr, sh(gl.FRAGMENT_SHADER, FS)); gl.linkProgram(pr); gl.useProgram(pr);
  var buf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buf); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  var loc = gl.getAttribLocation(pr, 'p'); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
  var uRes = gl.getUniformLocation(pr, 'res'), uT = gl.getUniformLocation(pr, 't');
  gl.viewport(0, 0, W, H); gl.uniform2f(uRes, W, H);
  var px = new Uint8Array(4);
  function batch(k, t) { var t0 = performance.now(); for (var i = 0; i < k; i++) { gl.uniform1f(uT, t + i * 0.01); gl.drawArrays(gl.TRIANGLES, 0, 3); } gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px); return performance.now() - t0; }
  var k = 1, t = 0;
  batch(1, 0); // 셰이더 컴파일·예열
  // 한 묶음이 약 50ms 걸리도록 그리기 횟수 조절
  for (var a = 0; a < 12; a++) { var ms = batch(k, t); if (ms > 40 || k >= 512) break; k = Math.min(512, k * 2); await new Promise(requestAnimationFrame); }
  var rates = [], start = performance.now(), dur = 6000;
  while (performance.now() - start < dur) {
    t += 0.05;
    var ms2 = batch(k, t);
    if (ms2 > 0) rates.push(k * W * H / ms2 / 1000); // 밀리초당 화소 → 초당 백만 화소
    if (onProg) onProg(Math.min(99, (performance.now() - start) / dur * 100));
    await new Promise(requestAnimationFrame);
  }
  var lose = gl.getExtension('WEBGL_lose_context');
  var score = Math.round(median(rates.slice(Math.floor(rates.length * 0.2))));
  setTimeout(function () { if (lose) lose.loseContext(); }, 50);
  return { gpu: score, gpuFrames: rates.length, gpuK: k, at: Date.now() };
}
$('#gpuRun').addEventListener('click', async function () {
  var b = this; b.disabled = true; $('#gpuOut').innerHTML = '<span class="muted small">측정 중…</span>';
  try { var r = await benchGpu(function (p) { $('#gpuBar').style.width = p + '%'; }); Object.assign(S.bench, r); save(); $('#gpuBar').style.width = '100%'; renderGpuOut(); }
  catch (e) { $('#gpuOut').innerHTML = '<span class="pill bad">측정 실패: ' + esc(e.message) + '</span>'; }
  b.disabled = false;
});
function renderGpuOut() {
  var b = S.bench; if (!b.gpu) return;
  $('#gpuOut').innerHTML = '<div class="stat"><b>' + fmt(b.gpu) + '</b><span>그래픽 점수 (초당 백만 화소, 무거운 셰이더)</span></div>' +
    (S.det.renderer && softwareRenderer(S.det.renderer) ? '<span class="pill bad">소프트웨어 렌더링: 실제 그래픽카드 점수가 아님</span>' : '');
}

/* ---------------- 모니터 주사율 ---------------- */
var COMMON_HZ = [30, 50, 60, 75, 85, 90, 100, 120, 144, 160, 165, 170, 175, 180, 200, 240, 280, 300, 360, 390, 480, 500, 540];
function measureHz(ms) {
  return new Promise(function (res) {
    var ts = [], t0 = null;
    function f(t) { if (t0 == null) t0 = t; ts.push(t); if (t - t0 < ms) requestAnimationFrame(f); else done(); }
    function done() {
      var d = []; for (var i = 1; i < ts.length; i++) d.push(ts[i] - ts[i - 1]);
      d = d.slice(Math.floor(d.length * 0.25)); // 앞부분 버림
      var med = median(d), hz = 1000 / med;
      var snap = COMMON_HZ.reduce(function (a, b) { return Math.abs(b - hz) < Math.abs(a - hz) ? b : a; });
      if (Math.abs(snap - hz) / hz > 0.04) snap = Math.round(hz);
      var jit = median(d.map(function (x) { return Math.abs(x - med); }));
      var drops = d.filter(function (x) { return x > med * 1.5; }).length;
      res({ hz: snap, raw: hz, jitter: jit, drops: drops, frames: d.length });
    }
    requestAnimationFrame(f);
  });
}
$('#hzRun').addEventListener('click', async function () {
  var b = this; b.disabled = true; $('#hzOut').innerHTML = '<span class="muted small">측정 중… 가만히 두세요</span>';
  var r = await measureHz(3000); S.dev.hz = r.hz; S.dev.hzInfo = r; save(); renderHz(); b.disabled = false;
});
function renderHz() {
  var r = S.dev.hzInfo; if (!r) return;
  var v = r.hz <= 61 ? '<div class="warnbox">60Hz로 돌고 있어요. 144Hz 이상 모니터라면 <b>바탕화면 우클릭 → 디스플레이 설정 → 고급 디스플레이 → 새로 고침 빈도</b>에서 올리고, 모니터 케이블이 DP(또는 HDMI 2.0 이상)인지 확인하세요. 노트북 절전 모드나 브라우저 절전 모드에서도 낮게 나와요.</div>' : '<div class="okbox">' + r.hz + 'Hz로 잘 돌고 있어요.</div>';
  $('#hzOut').innerHTML = '<div class="stat"><b>' + r.hz + 'Hz</b><span>측정 ' + fmt(r.raw, 1) + 'Hz · 프레임 ' + r.frames + '</span></div><div class="stat"><b>' + r.drops + '</b><span>끊긴 프레임</span></div>' + v;
}

/* ---------------- 반응 속도 ---------------- */
(function () {
  var el = $('#react'), state = 'idle', timer, t0, tries = [];
  function set(bg, txt) { el.style.background = bg; el.style.color = bg === 'var(--soft)' ? 'var(--fg)' : '#fff'; el.innerHTML = txt; }
  function arm() { state = 'wait'; set('#B42B23', '초록색이 되면 바로 누르세요'); timer = setTimeout(function () { state = 'go'; set('#127A42', '지금!'); requestAnimationFrame(function () { t0 = performance.now(); }); }, 1500 + Math.random() * 3000); }
  el.addEventListener('pointerdown', function (e) {
    e.preventDefault();
    if (state === 'idle' || state === 'result') { arm(); return; }
    if (state === 'wait') { clearTimeout(timer); state = 'result'; set('var(--soft)', '너무 빨랐어요!<br><span class="small">다시 누르면 재시작</span>'); return; }
    if (state === 'go') {
      var ms = Math.round(performance.now() - (t0 || performance.now()));
      tries.push(ms); state = 'result';
      set('var(--soft)', ms + 'ms<br><span class="small">' + (tries.length < 5 ? (5 - tries.length) + '번 더 (누르면 계속)' : '끝! 다시 누르면 새로 시작') + '</span>');
      if (tries.length >= 5) { var m = Math.round(median(tries)); S.dev.react = m; save(); $('#reactOut').innerHTML = '<div class="stat"><b>' + m + 'ms</b><span>5회 중간값 · 보통 200~280ms</span></div><span class="small muted">' + tries.join(', ') + 'ms</span>'; tries = []; }
      else $('#reactOut').innerHTML = '<span class="small muted">' + tries.join(', ') + 'ms</span>';
    }
  });
  el.addEventListener('keydown', function (e) { if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); el.dispatchEvent(new PointerEvent('pointerdown')); } });
})();

/* ---------------- 마우스 ---------------- */
(function () {
  var pad = $('#mousePad');
  var BTN = [['왼쪽', 0], ['가운데(휠)', 1], ['오른쪽', 2], ['뒤로(4)', 3], ['앞으로(5)', 4]];
  var st;
  function reset() {
    st = { cnt: [0, 0, 0, 0, 0], chat: [0, 0, 0, 0, 0], last: [0, 0, 0, 0, 0], up: [0, 0, 0, 0, 0], evts: [], max: 0, samples: [], clicks: [] };
    $('#mBtns').innerHTML = BTN.map(function (b) { return '<div id="mb' + b[1] + '">' + b[0] + '<b>0</b><span class="xs">채터링 0</span></div>'; }).join('') ;
    ['#mHz', '#mHzMax', '#mHzAvg', '#mCps'].forEach(function (i) { $(i).textContent = '-'; });
    $('#mouseVerdict').innerHTML = '';
  }
  reset();
  $('#mouseReset').addEventListener('click', reset);
  var useRaw = 'onpointerrawupdate' in window;
  function onMove(e) {
    if (e.pointerType && e.pointerType !== 'mouse') return;
    var now = performance.now();
    var n = 1;
    if (!useRaw && e.getCoalescedEvents) { var c = e.getCoalescedEvents(); n = c.length || 1; }
    for (var i = 0; i < n; i++) st.evts.push(now);
  }
  pad.addEventListener(useRaw ? 'pointerrawupdate' : 'pointermove', onMove);
  setInterval(function () {
    if (!st) return;
    var now = performance.now();
    while (st.evts.length && st.evts[0] < now - 1000) st.evts.shift();
    var hz = st.evts.length;
    if (hz > 20) {
      $('#mHz').textContent = hz;
      st.samples.push(hz); if (st.samples.length > 30) st.samples.shift();
      if (hz > st.max) st.max = hz;
      $('#mHzMax').textContent = st.max;
      var top = st.samples.slice().sort(function (a, b) { return b - a; }).slice(0, 5);
      $('#mHzAvg').textContent = Math.round(median(top));
      S.dev.pollMax = st.max; S.dev.pollAvg = Math.round(median(top)); save();
      verdict();
    } else if (st.max) $('#mHz').textContent = '0';
    while (st.clicks.length && st.clicks[0] < now - 1000) st.clicks.shift();
    if (st.clicks.length) $('#mCps').textContent = st.clicks.length;
  }, 250);
  function verdict() {
    var h = [];
    var m = st.max;
    if (m) {
      var cls = m >= 900 ? 'ok' : m >= 450 ? 'ok' : m >= 200 ? 'warn' : 'bad';
      var txt = m >= 900 ? '약 1000Hz(게이밍 마우스 정상)' : m >= 450 ? '약 500Hz' : m >= 200 ? '약 250Hz (게이밍엔 낮은 편)' : '125Hz 수준 (사무용 마우스이거나 설정이 낮음)';
      h.push('<span class="pill ' + cls + '">폴링레이트: ' + txt + '</span>');
      if (!useRaw) h.push('<span class="xs muted">이 브라우저는 정밀 측정(pointerrawupdate)을 지원하지 않아 실제보다 낮게 나올 수 있어요. 크롬·엣지를 쓰세요.</span>');
    }
    var chat = st.chat.reduce(function (a, b) { return a + b; }, 0);
    if (chat) h.push('<span class="pill bad">더블클릭(채터링) 의심 ' + chat + '회 — 스위치 교체 필요</span>');
    $('#mouseVerdict').innerHTML = '<div class="row">' + h.join('') + '</div>';
    S.dev.chatter = chat; save();
  }
  pad.addEventListener('contextmenu', function (e) { e.preventDefault(); });
  pad.addEventListener('auxclick', function (e) { e.preventDefault(); });
  pad.addEventListener('mousedown', function (e) {
    e.preventDefault(); pad.classList.add('active');
    var b = e.button; if (b < 0 || b > 4) return;
    var now = performance.now();
    // 직전 버튼 뗀 뒤 아주 짧은 시간(60ms 미만)에 다시 눌림 = 채터링
    if (st.last[b] && now - st.last[b] < 80 && st.up[b] && now - st.up[b] < 60) { st.chat[b]++; }
    st.last[b] = now; st.cnt[b]++; st.clicks.push(now);
    var el = $('#mb' + b); el.classList.add('on'); el.querySelector('b').textContent = st.cnt[b];
    el.querySelector('span').textContent = '채터링 ' + st.chat[b]; if (st.chat[b]) el.classList.add('chat');
    verdict();
  });
  window.addEventListener('mouseup', function (e) { var b = e.button; if (b < 0 || b > 4 || !st) return; st.up[b] = performance.now(); var el = $('#mb' + b); if (el) el.classList.remove('on'); });
  pad.addEventListener('mouseleave', function () { pad.classList.remove('active'); });
  // 뒤로/앞으로 버튼이 페이지 이동을 일으키지 않게
  pad.addEventListener('mouseup', function (e) { if (e.button === 3 || e.button === 4) e.preventDefault(); });
})();

/* ---------------- 키보드 ---------------- */
var KB_ROWS = [
  [['Escape', 'Esc', 1], ['gap'], ['F1', 'F1'], ['F2', 'F2'], ['F3', 'F3'], ['F4', 'F4'], ['gap'], ['F5', 'F5'], ['F6', 'F6'], ['F7', 'F7'], ['F8', 'F8'], ['gap'], ['F9', 'F9'], ['F10', 'F10'], ['F11', 'F11'], ['F12', 'F12'], ['gap'], ['PrintScreen', 'PrtSc'], ['ScrollLock', 'ScrLk'], ['Pause', 'Pause']],
  [['Backquote', '`'], ['Digit1', '1'], ['Digit2', '2'], ['Digit3', '3'], ['Digit4', '4'], ['Digit5', '5'], ['Digit6', '6'], ['Digit7', '7'], ['Digit8', '8'], ['Digit9', '9'], ['Digit0', '0'], ['Minus', '-'], ['Equal', '='], ['Backspace', '← Back', 2], ['gap'], ['Insert', 'Ins'], ['Home', 'Home'], ['PageUp', 'PgUp'], ['gap'], ['NumLock', 'Num'], ['NumpadDivide', '/'], ['NumpadMultiply', '*'], ['NumpadSubtract', '-']],
  [['Tab', 'Tab', 1.5], ['KeyQ', 'Q'], ['KeyW', 'W'], ['KeyE', 'E'], ['KeyR', 'R'], ['KeyT', 'T'], ['KeyY', 'Y'], ['KeyU', 'U'], ['KeyI', 'I'], ['KeyO', 'O'], ['KeyP', 'P'], ['BracketLeft', '['], ['BracketRight', ']'], ['Backslash', '\\', 1.5], ['gap'], ['Delete', 'Del'], ['End', 'End'], ['PageDown', 'PgDn'], ['gap'], ['Numpad7', '7'], ['Numpad8', '8'], ['Numpad9', '9'], ['NumpadAdd', '+']],
  [['CapsLock', 'Caps', 1.8], ['KeyA', 'A'], ['KeyS', 'S'], ['KeyD', 'D'], ['KeyF', 'F'], ['KeyG', 'G'], ['KeyH', 'H'], ['KeyJ', 'J'], ['KeyK', 'K'], ['KeyL', 'L'], ['Semicolon', ';'], ['Quote', "'"], ['Enter', 'Enter', 2.2], ['gap'], ['gap3'], ['gap'], ['Numpad4', '4'], ['Numpad5', '5'], ['Numpad6', '6']],
  [['ShiftLeft', 'Shift', 2.4], ['KeyZ', 'Z'], ['KeyX', 'X'], ['KeyC', 'C'], ['KeyV', 'V'], ['KeyB', 'B'], ['KeyN', 'N'], ['KeyM', 'M'], ['Comma', ','], ['Period', '.'], ['Slash', '/'], ['ShiftRight', 'Shift', 2.6], ['gap'], ['gap1'], ['ArrowUp', '↑'], ['gap1'], ['gap'], ['Numpad1', '1'], ['Numpad2', '2'], ['Numpad3', '3'], ['NumpadEnter', 'Ent']],
  [['ControlLeft', 'Ctrl', 1.4], ['MetaLeft', 'Win', 1.2], ['AltLeft', 'Alt', 1.2], ['Lang2', '한자', 1.1], ['Space', 'Space', 4.2], ['Lang1', '한/영', 1.1], ['AltRight', 'Alt', 1.2], ['ContextMenu', 'Menu', 1.2], ['ControlRight', 'Ctrl', 1.4], ['gap'], ['ArrowLeft', '←'], ['ArrowDown', '↓'], ['ArrowRight', '→'], ['gap'], ['Numpad0', '0', 2.1], ['NumpadDecimal', '.']]
];
// 키 코드 별칭(한/영·한자는 키보드·드라이버마다 다르게 옴)
var CODE_ALIAS = { HangulMode: 'Lang1', HanjaMode: 'Lang2', OSLeft: 'MetaLeft', OSRight: 'MetaLeft', MetaRight: 'MetaLeft', IntlBackslash: 'Backslash' };
var kbBuilt = false, kb = null;
function buildKeyboard() {
  if (kbBuilt) return; kbBuilt = true;
  var U = 38;
  $('#kb').innerHTML = KB_ROWS.map(function (row) {
    return '<div class="kr">' + row.map(function (k) {
      if (k[0] === 'gap') return '<span class="gap"></span>';
      if (k[0] === 'gap1') return '<span class="gap" style="width:' + U + 'px"></span>';
      if (k[0] === 'gap3') return '<span class="gap" style="width:' + (U * 3 + 8) + 'px"></span>';
      var w = k[2] ? Math.round(U * k[2] + 4 * (k[2] - 1)) : U;
      return '<span class="k" data-code="' + k[0] + '" style="width:' + w + 'px">' + esc(k[1]) + '</span>';
    }).join('') + '</div>';
  }).join('');
  kbReset();
}
function kbReset() { kb = { done: {}, down: {}, max: 0, lastUp: {}, chat: 0 }; $$('#kb .k').forEach(function (e) { e.className = 'k'; }); ['#kbCount', '#kbNow', '#kbMax', '#kbChat'].forEach(function (i) { $(i).textContent = '0'; }); $('#kbLast').textContent = '마지막 키: -'; }
$('#kbReset').addEventListener('click', kbReset);
function kbEl(code) { return $('#kb .k[data-code="' + code + '"]'); }
function kbActive() { return !$('[data-panel="dev"]').hidden && document.activeElement && (document.activeElement.id === 'kb' || document.activeElement === document.body); }
document.addEventListener('keydown', function (e) {
  if (!kb || !kbActive()) return;
  var code = CODE_ALIAS[e.code] || e.code || (e.key === 'HangulMode' ? 'Lang1' : e.key === 'HanjaMode' ? 'Lang2' : '');
  if (!code) return;
  if (!(e.ctrlKey && (e.key === 'r' || e.key === 'R')) && code !== 'F5' && code !== 'F12' || document.activeElement.id === 'kb') e.preventDefault();
  if (e.repeat) return;
  var now = performance.now();
  if (kb.lastUp[code] && now - kb.lastUp[code] < 30) { kb.chat++; var c = kbEl(code); if (c) c.classList.add('chat'); }
  kb.down[code] = 1; kb.done[code] = 1;
  var n = Object.keys(kb.down).length; if (n > kb.max) kb.max = n;
  var el = kbEl(code); if (el) { el.classList.add('down', 'done'); }
  $('#kbCount').textContent = Object.keys(kb.done).length; $('#kbNow').textContent = n; $('#kbMax').textContent = kb.max; $('#kbChat').textContent = kb.chat;
  $('#kbLast').textContent = '마지막 키: ' + code + ' (' + (e.key === ' ' ? 'Space' : e.key) + ')';
  S.dev.kbMax = kb.max; S.dev.kbChat = kb.chat; S.dev.kbKeys = Object.keys(kb.done).length;
});
document.addEventListener('keyup', function (e) {
  if (!kb) return;
  var code = CODE_ALIAS[e.code] || e.code; if (!code) return;
  delete kb.down[code]; kb.lastUp[code] = performance.now();
  var el = kbEl(code); if (el) el.classList.remove('down');
  if (code === 'PrintScreen') { kb.done[code] = 1; if (el) el.classList.add('done'); $('#kbCount').textContent = Object.keys(kb.done).length; }
  $('#kbNow').textContent = Object.keys(kb.down).length;
  save();
});
window.addEventListener('blur', function () { if (kb) { kb.down = {}; $$('#kb .k.down').forEach(function (e) { e.classList.remove('down'); }); $('#kbNow').textContent = '0'; } });
$('#kb').addEventListener('click', function () { $('#kb').focus(); });

/* ---------------- 소리·마이크 ---------------- */
var actx = null;
function ac() { if (!actx) actx = new (window.AudioContext || window.webkitAudioContext)(); if (actx.state === 'suspended') actx.resume(); return actx; }
$$('[data-tone]').forEach(function (b) {
  b.addEventListener('click', function () {
    var c = ac(), v = b.dataset.tone, now = c.currentTime;
    var o = c.createOscillator(), g = c.createGain(), p = c.createStereoPanner ? c.createStereoPanner() : null;
    o.type = 'sine'; o.frequency.value = 520;
    g.gain.setValueAtTime(0, now); g.gain.linearRampToValueAtTime(0.12, now + 0.05);
    var dur = v === 'sweep' ? 2.4 : 0.9;
    g.gain.setValueAtTime(0.12, now + dur - 0.1); g.gain.linearRampToValueAtTime(0, now + dur);
    if (p) { if (v === 'sweep') { p.pan.setValueAtTime(-1, now); p.pan.linearRampToValueAtTime(1, now + dur); } else p.pan.value = +v; o.connect(g); g.connect(p); p.connect(c.destination); }
    else { o.connect(g); g.connect(c.destination); }
    o.start(now); o.stop(now + dur + 0.05);
    var where = v === '-1' ? '왼쪽' : v === '1' ? '오른쪽' : v === '0' ? '가운데' : '왼쪽에서 오른쪽으로';
    $('#toneAsk').innerHTML = '소리가 <b>' + where + '</b>에서 들렸나요? 반대쪽에서 들리면 헤드셋 좌우가 바뀐 거예요(윈도우 소리 설정의 모노 오디오·스피커 구성 확인).';
  });
});
(function () {
  var stream = null, raf = 0;
  $('#micRun').addEventListener('click', async function () {
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
      var c = ac(), src = c.createMediaStreamSource(stream), an = c.createAnalyser(); an.fftSize = 1024; src.connect(an);
      var buf = new Float32Array(an.fftSize), peak = 0;
      var label = stream.getAudioTracks()[0] && stream.getAudioTracks()[0].label;
      $('#micRun').hidden = true; $('#micStop').hidden = false;
      (function loop() {
        an.getFloatTimeDomainData(buf); var s = 0; for (var i = 0; i < buf.length; i++) s += buf[i] * buf[i];
        var rms = Math.sqrt(s / buf.length), db = 20 * Math.log10(rms + 1e-8), lvl = Math.max(0, Math.min(100, (db + 60) / 60 * 100));
        if (lvl > peak) peak = lvl;
        $('#micBar').style.width = lvl + '%';
        $('#micOut').textContent = (label ? label + ' · ' : '') + '지금 ' + Math.round(db) + 'dB · 최고 ' + Math.round(peak) + '%' + (peak > 30 ? ' · 마이크 정상' : ' · 말을 해 보세요');
        S.dev.mic = peak > 30 ? 'ok' : 'low';
        raf = requestAnimationFrame(loop);
      })();
    } catch (e) { $('#micOut').textContent = '마이크를 쓸 수 없어요: ' + (e.name === 'NotAllowedError' ? '권한이 거부됐어요(주소창 왼쪽 자물쇠에서 허용)' : e.name === 'NotFoundError' ? '마이크가 연결되지 않았어요' : e.message); S.dev.mic = 'none'; }
    save();
  });
  $('#micStop').addEventListener('click', function () { cancelAnimationFrame(raf); if (stream) stream.getTracks().forEach(function (t) { t.stop(); }); stream = null; $('#micRun').hidden = false; $('#micStop').hidden = true; $('#micBar').style.width = '0'; });
})();

/* ---------------- 인터넷 (브라우저) ---------------- */
// 응답 시간 측정 대상. no-cors 요청은 내용은 못 읽지만 걸린 시간은 잴 수 있음.
var NET_TARGETS = window.NET_TARGETS || [];
async function timeFetch(url, mode) {
  var ctl = new AbortController(); var to = setTimeout(function () { ctl.abort(); }, 3000);
  var t0 = performance.now();
  try {
    await fetch(url + (url.indexOf('?') >= 0 ? '&' : '?') + '_=' + Math.random().toString(36).slice(2), { mode: mode || 'no-cors', cache: 'no-store', signal: ctl.signal, credentials: 'omit', referrerPolicy: 'no-referrer' });
    clearTimeout(to);
    return performance.now() - t0;
  } catch (e) { clearTimeout(to); return null; }
}
async function pingTarget(t, n, onEach) {
  await timeFetch(t.url, t.mode); // 첫 연결(DNS·TLS) 제외
  var rs = [], fail = 0;
  for (var i = 0; i < n; i++) { var ms = await timeFetch(t.url, t.mode); if (ms == null) fail++; else rs.push(ms); if (onEach) onEach(); await sleep(60); }
  var med = rs.length ? median(rs) : null, jit = 0;
  for (var j = 1; j < rs.length; j++) jit += Math.abs(rs[j] - rs[j - 1]);
  jit = rs.length > 1 ? jit / (rs.length - 1) : 0;
  return { name: t.name, med: med, min: rs.length ? Math.min.apply(null, rs) : null, jitter: jit, loss: fail / n, n: n };
}
async function speedTest(onProg) {
  // 클라우드플레어 속도 측정 서버(CORS 허용)에서 받아 보기
  var sizes = [1e6, 5e6, 10e6], best = 0;
  for (var i = 0; i < sizes.length; i++) {
    var ctl = new AbortController(), to = setTimeout(function () { ctl.abort(); }, 8000);
    try {
      var t0 = performance.now();
      var r = await fetch('https://speed.cloudflare.com/__down?bytes=' + sizes[i], { cache: 'no-store', signal: ctl.signal, credentials: 'omit' });
      var b = await r.arrayBuffer();
      var sec = (performance.now() - t0) / 1000;
      var mbps = b.byteLength * 8 / sec / 1e6; if (mbps > best) best = mbps;
      clearTimeout(to);
      if (onProg) onProg(i);
      if (sec > 3) break;
    } catch (e) { clearTimeout(to); break; }
  }
  return best || null;
}
function netGrade(r) {
  if (r.med == null || r.loss >= 0.5) return ['bad', '응답 없음'];
  if (r.loss >= 0.1) return ['bad', '실패 많음'];
  if (r.med > 150 || r.jitter > 40) return ['bad', '느림'];
  if (r.med > 70 || r.jitter > 15 || r.loss > 0) return ['warn', '보통'];
  return ['ok', '좋음'];
}
async function runNet(onProg) {
  var N = 15, total = NET_TARGETS.length * N + 3, done = 0;
  var step = function () { done++; if (onProg) onProg(Math.min(99, done / total * 100)); };
  var res = [];
  // 이 앱 서버는 서비스 워커 캐시가 대신 답해 지연이 0에 가깝게 나오므로 측정 대상에서 뺌
  var all = NET_TARGETS.slice();
  total = all.length * N + 3;
  for (var i = 0; i < all.length; i++) res.push(await pingTarget(all[i], N, step));
  var sp = await speedTest(function () { step(); });
  var out = { targets: res, down: sp, at: Date.now(), conn: navigator.connection ? { type: navigator.connection.effectiveType, rtt: navigator.connection.rtt, downlink: navigator.connection.downlink } : null };
  return out;
}
function renderNet() {
  var n = S.net; if (!n) return;
  $('#netTbl tbody').innerHTML = n.targets.map(function (r) {
    var g = netGrade(r);
    return '<tr><td>' + esc(r.name) + '</td><td class="num">' + (r.med != null ? fmt(r.med) + 'ms' : '-') + '</td><td class="num">' + (r.min != null ? fmt(r.min) + 'ms' : '-') + '</td><td class="num">' + fmt(r.jitter) + 'ms</td><td class="num">' + Math.round(r.loss * 100) + '%</td><td><span class="pill ' + g[0] + '">' + g[1] + '</span></td></tr>';
  }).join('');
  $('#netSpeed').innerHTML = '<div class="stat"><b>' + (n.down ? fmt(n.down, 0) + ' Mbps' : '-') + '</b><span>다운로드 (브라우저 1회 측정, 실제 회선보다 낮을 수 있음)</span></div>' + (n.conn && n.conn.type ? '<div class="stat"><b>' + esc(n.conn.type) + '</b><span>브라우저가 보는 연결 등급</span></div>' : '');
  var ok = n.targets.filter(function (r) { return r.med != null; });
  var worst = ok.reduce(function (a, r) { return Math.max(a, r.jitter); }, 0);
  var loss = n.targets.reduce(function (a, r) { return Math.max(a, r.loss); }, 0);
  var bestMed = ok.length ? Math.min.apply(null, ok.map(function (r) { return r.min; })) : null;
  var v;
  if (!ok.length) v = '<div class="badbox">인터넷 응답이 없어요. 랜선·공유기를 확인하세요.</div>';
  else if (loss >= 0.1 || worst > 40) v = '<div class="badbox">응답이 들쭉날쭉하거나 실패가 있어요(지터 ' + fmt(worst) + 'ms, 실패 ' + Math.round(loss * 100) + '%). 게임에서 순간이동·끊김이 생길 수 있어요. 윈도우 점검 프로그램으로 게이트웨이 핑을 확인해 PC~공유기 구간 문제인지 가려 보세요.</div>';
  else if (bestMed > 60) v = '<div class="warnbox">응답이 다소 느려요(최소 ' + fmt(bestMed) + 'ms). 와이파이라면 유선으로 바꿔 보세요.</div>';
  else v = '<div class="okbox">인터넷 상태 좋아요 (최소 ' + fmt(bestMed) + 'ms, 지터 ' + fmt(worst) + 'ms).</div>';
  $('#netVerdict').innerHTML = v;
}
$('#netRun').addEventListener('click', async function () {
  var b = this; b.disabled = true; $('#netVerdict').innerHTML = '<span class="muted small">측정 중…</span>';
  S.net = await runNet(function (p) { $('#netBar').style.width = p + '%'; }); $('#netBar').style.width = '100%'; save(); renderNet(); b.disabled = false;
});
function renderNativeNet() {
  var n = S.native; if (!n) return;
  var rows = (n.pings || []).map(function (p) {
    var g = p.recv === 0 ? ['bad', '응답 없음'] : (p.isGateway ? (p.avg > 3 || p.loss > 0 ? ['bad', '내부망 문제'] : ['ok', '좋음']) : netGrade({ med: p.avg, jitter: p.jitter, loss: p.loss / 100 }));
    return '<tr><td>' + esc(p.name) + (p.isGateway ? ' <span class="pill info">게이트웨이</span>' : '') + '<div class="xs muted mono">' + esc(p.host) + '</div></td><td class="num">' + (p.recv ? fmt(p.avg, p.avg < 10 ? 1 : 0) + 'ms' : '-') + '</td><td class="num">' + (p.recv ? fmt(p.min) + '/' + fmt(p.max) : '-') + '</td><td class="num">' + (p.recv ? fmt(p.jitter, 1) + 'ms' : '-') + '</td><td class="num">' + fmt(p.loss) + '%</td><td><span class="pill ' + g[0] + '">' + g[1] + '</span></td></tr>';
  }).join('');
  var tcp = (n.tcp || []).map(function (p) {
    var g = p.ok ? netGrade({ med: p.avg, jitter: 0, loss: p.fail / Math.max(1, p.n) }) : ['bad', '접속 실패'];
    return '<tr><td>' + esc(p.name) + '<div class="xs muted mono">' + esc(p.host) + ':' + p.port + '</div></td><td class="num">' + (p.ok ? fmt(p.avg) + 'ms' : '-') + '</td><td class="num">' + (p.ok ? fmt(p.min) + 'ms' : '-') + '</td><td><span class="pill ' + g[0] + '">' + g[1] + '</span></td></tr>';
  }).join('');
  var gw = (n.pings || []).filter(function (p) { return p.isGateway; })[0];
  var ext = (n.pings || []).filter(function (p) { return !p.isGateway && p.recv; });
  var extAvg = ext.length ? median(ext.map(function (p) { return p.avg; })) : null;
  var v = '';
  if (gw && (gw.loss > 0 || gw.avg > 3)) v = '<div class="badbox">게이트웨이(공유기/스위치)까지 ' + (gw.loss > 0 ? '손실 ' + gw.loss + '%' : fmt(gw.avg) + 'ms') + ' — 매장 안 네트워크 문제예요. 랜선 교체, 허브 포트 변경, 랜카드 드라이버를 확인하세요.</div>';
  else if (gw && extAvg != null && extAvg > 40) v = '<div class="warnbox">매장 안은 정상인데 외부가 느려요(중간값 ' + fmt(extAvg) + 'ms). 통신사 회선이나 공유기 바깥쪽 문제예요.</div>';
  else if (ext.some(function (p) { return p.loss >= 5; }) || (n.pings || []).some(function (p) { return !p.isGateway && !p.recv; })) v = '<div class="warnbox">매장 안(게이트웨이)은 정상인데 일부 외부 대상에서 손실이 있어요. 한 곳만 응답이 없으면 그 서버가 핑을 막은 것일 수 있어요. 여러 곳에서 손실이 나면 통신사 회선을 확인하세요.</div>';
  else if (gw && extAvg != null) v = '<div class="okbox">게이트웨이 ' + fmt(gw.avg, 1) + 'ms, 외부 ' + fmt(extAvg) + 'ms — 정상이에요.</div>';
  if (n.adapter) v += '<div class="small muted">연결: ' + esc(n.adapter) + '</div>';
  $('#nativeNet').innerHTML = (rows ? '<div class="tblwrap"><table><thead><tr><th>핑(ICMP) 대상</th><th>평균</th><th>최소/최대</th><th>지터</th><th>손실</th><th>판정</th></tr></thead><tbody>' + rows + '</tbody></table></div>' : '') +
    (tcp ? '<div class="tblwrap"><table><thead><tr><th>게임 서버 접속(TCP)</th><th>평균</th><th>최소</th><th>판정</th></tr></thead><tbody>' + tcp + '</tbody></table></div>' : '') + v +
    '<div class="xs muted">측정 시각: ' + esc(n.time || '') + '</div>';
}

/* ---------------- 전체 자동 점검 ---------------- */
var STEPS = [['detect', '사양 감지'], ['hz', '모니터 주사율'], ['cpu', 'CPU 측정'], ['gpu', '그래픽 측정'], ['net', '인터넷 지연·속도']];
function drawSteps(state) {
  $('#allSteps').innerHTML = STEPS.map(function (s) { var v = state[s[0]] || ''; return '<div class="st"><span class="ic">' + (v === 'done' ? '✓' : v === 'run' ? '…' : v === 'err' ? '✗' : '·') + '</span><span' + (v === 'run' ? ' style="font-weight:700"' : v === 'done' ? '' : ' class="muted"') + '>' + s[1] + '</span></div>'; }).join('');
}
$('#runAll').addEventListener('click', async function () {
  var b = this; b.disabled = true;
  S.seat = $('#seatIn').value.trim(); save(); seatPill();
  var st = {}, bar = $('#allBar');
  var setP = function (base, span) { return function (p) { bar.style.width = (base + span * p / 100) + '%'; }; };
  async function step(key, base, span, fn) { st[key] = 'run'; drawSteps(st); try { await fn(setP(base, span)); st[key] = 'done'; } catch (e) { st[key] = 'err'; console.error(e); } bar.style.width = (base + span) + '%'; drawSteps(st); }
  await step('detect', 0, 5, async function () { await detect(); });
  await step('hz', 5, 10, async function () { var r = await measureHz(2500); S.dev.hz = r.hz; S.dev.hzInfo = r; save(); });
  await step('cpu', 15, 25, async function (p) { Object.assign(S.bench, await benchCpu(p)); save(); });
  await step('gpu', 40, 30, async function (p) { Object.assign(S.bench, await benchGpu(p)); save(); });
  await step('net', 70, 30, async function (p) { S.net = await runNet(p); save(); });
  b.disabled = false;
  renderAllOut();
  renderSummary();
  toast('점검이 끝났어요');
});
function renderAllOut() { renderCpuOut(); renderGpuOut(); renderHz(); renderNet(); renderNativeNet(); }
function problems() {
  var p = [], sp = spec();
  if (S.det.renderer && softwareRenderer(S.det.renderer)) p.push('그래픽 드라이버 없음/가속 꺼짐');
  if (!sp.gpu && S.det.renderer) p.push('그래픽카드 미확인');
  if (S.dev.hzInfo && S.dev.hz <= 61) p.push('주사율 60Hz');
  if (S.dev.chatter) p.push('마우스 채터링');
  if (S.dev.kbChat) p.push('키보드 채터링');
  if (S.dev.pollMax && S.dev.pollMax < 200) p.push('마우스 폴링 낮음');
  if (S.net) { var ok = S.net.targets.filter(function (r) { return r.med != null; }); var loss = S.net.targets.reduce(function (a, r) { return Math.max(a, r.loss); }, 0); var jit = ok.reduce(function (a, r) { return Math.max(a, r.jitter); }, 0); if (!ok.length) p.push('인터넷 응답 없음'); else if (loss >= 0.1 || jit > 40) p.push('인터넷 불안정'); }
  if (S.native && S.native.pings) { var gw = S.native.pings.filter(function (x) { return x.isGateway; })[0]; if (gw && (gw.loss > 0 || gw.avg > 3)) p.push('게이트웨이 핑 이상'); }
  if (S.dev.mic === 'none') p.push('마이크 없음');
  var fails = GAMES.filter(function (g) { return judge(g, sp, S.opt).level === 'fail'; }).map(function (g) { return g.short || g.name; });
  if (fails.length) p.push('사양 부족: ' + fails.join(', '));
  return p;
}
function renderSummary() {
  var sp = spec();
  if (!S.det.at) { $('#summary').innerHTML = ''; return; }
  var tgt = targetFps(S.opt);
  var games = GAMES.map(function (g) { var j = judge(g, sp, S.opt); return { g: g, j: j }; });
  var cnt = { rec: 0, min: 0, fail: 0 };
  games.forEach(function (x) { if (cnt[x.j.level] != null) cnt[x.j.level]++; });
  var pr = problems();
  var html = '<div class="card stack"><div class="row between"><div class="h2">점검 결과' + (S.seat ? ' · ' + esc(S.seat) + '번 좌석' : '') + '</div><div class="row"><button class="btn sm" data-goto="games" type="button">게임별 자세히</button><button class="btn sm" id="sumSave" type="button">기록에 저장</button></div></div>' +
    '<div class="row sumrow"><div class="stat"><b>' + esc(sp.gpu ? sp.gpu.name : '그래픽 모름') + '</b><span>그래픽 · ' + esc(sp.src.gpu || '') + '</span></div>' +
    '<div class="stat"><b>' + esc(sp.cpu ? sp.cpu.name : 'CPU 모름') + '</b><span>CPU · ' + esc(sp.src.cpu || '내 사양 탭에서 고르기') + '</span></div>' +
    '<div class="stat"><b>' + (sp.ram ? sp.ram + 'GB' : sp.ramAtLeast ? sp.ramAtLeast + 'GB+' : '-') + '</b><span>RAM</span></div>' +
    '<div class="stat"><b>' + (sp.hz ? sp.hz + 'Hz' : '-') + '</b><span>모니터</span></div></div>' +
    '<div class="row"><span class="pill ok">권장 충족 ' + cnt.rec + '개</span><span class="pill warn">최소만 ' + cnt.min + '개</span><span class="pill bad">부족 ' + cnt.fail + '개</span></div>' +
    (pr.length ? '<div class="badbox">확인할 문제: ' + pr.map(esc).join(' · ') + '</div>' : '<div class="okbox">눈에 띄는 문제가 없어요.</div>') +
    '<div class="tblwrap"><table><thead><tr><th>게임</th><th>판정</th><th>예상 fps (' + S.opt.res + 'p · ' + ({ low: '낮음', mid: '중간', high: '높음' })[S.opt.preset] + ')</th></tr></thead><tbody>' +
    games.map(function (x) { var lv = LV[x.j.level]; var fl = x.j.fps != null ? fpsLabel(x.j.fps, tgt) : null; return '<tr><td>' + x.g.rank + '. ' + esc(x.g.name) + '</td><td><span class="pill ' + lv[0] + '">' + lv[1] + '</span></td><td class="num">' + (x.j.fps != null ? (x.j.fps >= (x.g.fps.cap || 1e9) ? x.g.fps.cap + '+' : '약 ' + fmt(x.j.fps)) + ' <span class="pill ' + fl[0] + '">' + (fl[0] === 'ok' ? '쾌적' : fl[0] === 'warn' ? '보통' : '버벅임') + '</span>' : '-') + '</td></tr>'; }).join('') +
    '</tbody></table></div>' +
    '<p class="xs muted">마우스·키보드·헤드셋·마이크는 <a href="#dev" data-goto="dev">장비 테스트</a>에서 직접 눌러 확인하세요. 게이트웨이·외부 핑은 윈도우 점검 프로그램이 필요해요.</p></div>';
  $('#summary').innerHTML = html;
  $('#sumSave').addEventListener('click', saveRecord);
}

/* ---------------- 좌석 기록 ---------------- */
function seatPill() { $('#seatPill').textContent = S.seat ? S.seat + '번 좌석' : '좌석 미지정'; $('#seatIn').value = S.seat || ''; }
function currentRecord() {
  var sp = spec(), n = S.net, nat = S.native;
  var ok = n ? n.targets.filter(function (r) { return r.med != null && r.name !== '이 앱 서버'; }) : [];
  var gw = nat && nat.pings ? nat.pings.filter(function (x) { return x.isGateway; })[0] : null;
  return {
    seat: S.seat || '-', at: Date.now(),
    cpu: sp.cpu ? sp.cpu.name : (sp.cpuRaw || '-'), gpu: sp.gpu ? sp.gpu.name : (sp.gpuRaw || '-'),
    ram: sp.ram || (sp.ramAtLeast ? sp.ramAtLeast + '+' : '-'), hz: S.dev.hz || null,
    cpuS: S.bench.cpuSingle || null, cpuM: S.bench.cpuMulti || null, gpuB: S.bench.gpu || null,
    net: ok.length ? Math.round(median(ok.map(function (r) { return r.med; }))) : null,
    gw: gw && gw.recv ? Math.round(gw.avg * 10) / 10 : null,
    poll: S.dev.pollMax || null, react: S.dev.react || null,
    probs: problems().join(' / ')
  };
}
function saveRecord() {
  var r = currentRecord();
  records = records.filter(function (x) { return !(S.seat && x.seat === r.seat); });
  records.push(r); records.sort(function (a, b) { return String(a.seat).localeCompare(String(b.seat), 'ko', { numeric: true }); });
  store.set(KEY + '_rec', records); toast((S.seat ? S.seat + '번 좌석' : '결과') + ' 저장했어요'); renderRecords();
}
function renderRecords() {
  $('#recEmpty').hidden = records.length > 0;
  // 같은 그래픽끼리 비교해 중간값보다 20% 이상 낮으면 표시
  function low(rec, key) {
    var same = records.filter(function (x) { return x.gpu === rec.gpu && x[key]; }).map(function (x) { return x[key]; });
    if (same.length < 3 || !rec[key]) return '';
    return rec[key] < median(same) * 0.8 ? ' style="background:var(--warn-soft);color:var(--warn);font-weight:700"' : '';
  }
  $('#recTbl tbody').innerHTML = records.map(function (r, i) {
    var d = new Date(r.at);
    return '<tr><td><b>' + esc(r.seat) + '</b></td><td class="xs">' + (d.getMonth() + 1) + '/' + d.getDate() + ' ' + String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0') + '</td><td class="xs">' + esc(r.cpu) + '</td><td class="xs">' + esc(r.gpu) + '</td><td>' + esc(r.ram) + '</td><td' + (r.hz && r.hz <= 61 ? ' style="color:var(--bad);font-weight:700"' : '') + '>' + (r.hz || '-') + '</td><td class="num"' + low(r, 'cpuS') + '>' + fmt(r.cpuS) + '/' + fmt(r.cpuM) + '</td><td class="num"' + low(r, 'gpuB') + '>' + fmt(r.gpuB) + '</td><td class="num">' + (r.net != null ? r.net + 'ms' : '-') + '</td><td class="num">' + (r.gw != null ? r.gw + 'ms' : '-') + '</td><td class="xs" style="color:var(--bad)">' + esc(r.probs || '') + '</td><td><button class="btn sm" data-del="' + i + '" type="button" aria-label="삭제">삭제</button></td></tr>';
  }).join('');
  $$('[data-del]').forEach(function (b) { b.addEventListener('click', function () { records.splice(+b.dataset.del, 1); store.set(KEY + '_rec', records); renderRecords(); }); });
}
$('#saveRec').addEventListener('click', saveRecord);
$('#clrRec').addEventListener('click', function () { if (!records.length) return; if (confirm('기록 ' + records.length + '개를 모두 지울까요?')) { records = []; store.set(KEY + '_rec', records); renderRecords(); } });
$('#csvRec').addEventListener('click', function () {
  var cols = ['seat', 'at', 'cpu', 'gpu', 'ram', 'hz', 'cpuS', 'cpuM', 'gpuB', 'net', 'gw', 'poll', 'react', 'probs'];
  var head = ['좌석', '날짜', 'CPU', '그래픽', 'RAM(GB)', '주사율(Hz)', 'CPU단일', 'CPU전체', 'GPU점수', '인터넷(ms)', '게이트웨이(ms)', '마우스폴링(Hz)', '반응속도(ms)', '문제'];
  var lines = [head.join(',')].concat(records.map(function (r) { return cols.map(function (c) { var v = c === 'at' ? new Date(r.at).toLocaleString('ko-KR') : r[c]; v = v == null ? '' : String(v); return /[",\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v; }).join(','); }));
  var blob = new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' });
  var a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'pc방-점검-' + new Date().toISOString().slice(0, 10) + '.csv'; document.body.appendChild(a); a.click(); setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 500);
});
$('#copyRep').addEventListener('click', function () {
  var r = currentRecord(), sp = spec(), tgt = targetFps(S.opt);
  var t = ['[PC방 게임 점검] ' + (S.seat ? S.seat + '번 좌석 · ' : '') + new Date().toLocaleString('ko-KR'),
    'CPU: ' + r.cpu + ' / 그래픽: ' + r.gpu + ' / RAM: ' + r.ram + 'GB / 모니터: ' + (r.hz || '-') + 'Hz',
    '벤치: CPU ' + fmt(r.cpuS) + '/' + fmt(r.cpuM) + ' · GPU ' + fmt(r.gpuB) + ' · 인터넷 ' + (r.net != null ? r.net + 'ms' : '-') + ' · 게이트웨이 ' + (r.gw != null ? r.gw + 'ms' : '-'),
    '문제: ' + (r.probs || '없음'), '게임:'].concat(GAMES.map(function (g) { var j = judge(g, sp, S.opt); return ' ' + g.rank + '. ' + g.name + ' — ' + LV[j.level][1] + (j.fps != null ? ' · 약 ' + j.fps + 'fps' : ''); })).join('\n');
  (navigator.clipboard ? navigator.clipboard.writeText(t) : Promise.reject()).then(function () { toast('복사했어요'); }, function () { prompt('아래 글을 복사하세요', t); });
});
$('#seatIn').addEventListener('change', function () { S.seat = this.value.trim(); save(); seatPill(); });

/* ---------------- 시작 ---------------- */
fillLists(); seatPill();
detect().then(function () { renderSummary(); renderSpec(); });
renderAllOut();
var h = (location.hash || '').slice(1);
if (h && $('[data-panel="' + h + '"]')) showTab(h);
if ('serviceWorker' in navigator && location.protocol !== 'file:') navigator.serviceWorker.register('../sw.js').catch(function () {});
// 테스트·디버그용
window.__pcbang = { matchGpu: matchGpu, matchCpu: matchCpu, cleanRenderer: cleanRenderer, judge: judge, spec: spec, decodeNative: decodeNative, S: S };
})();

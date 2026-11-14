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
  set: function (k, v) { try { localStorage.setItem(k, JSON.stringify(v)); return true; } catch (e) { return false; } }
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
S.native = S.native || null;    // 윈도우 점검 프로그램 결과 (불러온 뒤 sanitizeNative로 다시 정리)
S.dev = S.dev || {};            // {hz, pollMax, pollAvg, chatter, kbMax, kbChat, react}
S.seat = S.seat || '';
S.opt = Object.assign({ res: '1080', preset: 'mid', target: 'auto' }, S.opt || {});
if (['1080', '1440', '2160'].indexOf(S.opt.res) < 0) S.opt.res = '1080';
if (['low', 'mid', 'high'].indexOf(S.opt.preset) < 0) S.opt.preset = 'mid';
if (['auto', '60', '144', '240'].indexOf(String(S.opt.target)) < 0) S.opt.target = 'auto';
var saveWarned = false;
function save() { var c = {}; for (var k in S) if (k !== 'records') c[k] = S[k]; if (!store.set(KEY, c) && !saveWarned) { saveWarned = true; setTimeout(function () { toast('브라우저 저장 공간이 부족해 점검 결과를 저장하지 못했어요'); }, 0); } }

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
  if (name === 'home') renderSummary();
  if (name === 'games') renderGames();
  if (name === 'log') renderShop();
  if (name === 'fix') renderFixes();
  if (name === 'spec') renderSpec();
  if (name === 'dev') { buildKeyboard(); renderChk(); }
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
      if (/^\d{3}m$/.test(key) && !/radeon/.test(lower)) return; // 'GTX 680M' 이 'Radeon 680M' 으로 잡히지 않게
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
  if ((m = s.match(/\bi([3579])[\s-]*(\d{4,5})([a-z]*)/))) return 'i' + m[1] + m[2] + (/^(h|u|p|y|g\d)/.test(m[3]) ? 'm' + m[3] : m[3].indexOf('k') >= 0 ? 'k' : '');
  if ((m = s.match(/ryzen\s*([3579])?\s*(?:pro\s*)?(\d{4})([a-z0-9]*)/)) || (m = s.match(/^\s*()(\d{4})(x3d|xt|x|g|ge|f)?\s*$/))) {
 var suf = m[3] || ''; if (/^(h|hs|hx|u|hk)/.test(suf)) return 'r' + m[2] + 'm' + suf; suf = /x3d/.test(suf) ? 'x3d' : /xt/.test(suf) ? 'xt' : /x/.test(suf) ? 'x' : /g/.test(suf) ? 'g' : '';
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
    var base = k.replace(/(x3d|xt|x|g)$/, ''); if (/m/.test(k.slice(5))) base = '-';
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
function spec(st) {
  st = st || S;
  var o = { src: {} };
  var nat = st.native || {};
  o.nat = nat;
  // GPU: 직접 입력 > 점검 프로그램 > 자동 감지
  var gm = null;
  if (st.manual.gpu) { gm = matchGpu(st.manual.gpu); o.src.gpu = '직접 입력'; }
  if (!gm && nat.gpus && nat.gpus.length) {
    var cands = nat.gpus.map(function (g) { var m = matchGpu(g.name); if (m && g.vram) m.vramReal = g.vram; return m; }).filter(Boolean).sort(function (a, b) { return b.score - a.score; });
    if (cands.length) { gm = cands[0]; o.src.gpu = '점검 프로그램'; }
  }
  if (!gm && st.det.renderer) { gm = matchGpu(st.det.renderer); if (gm) o.src.gpu = '자동 감지'; }
  o.gpu = gm;
  o.gpuRaw = st.manual.gpu || (nat.gpus && nat.gpus[0] && nat.gpus[0].name) || st.det.renderer || '';
  o.vram = gm && (gm.vramReal || gm.vram) || null;
  // CPU
  var cm = null;
  if (st.manual.cpu) { cm = matchCpu(st.manual.cpu); o.src.cpu = '직접 입력'; }
  if (!cm && nat.cpu) { cm = matchCpu(nat.cpu); if (cm) o.src.cpu = '점검 프로그램'; }
  if (!cm && st.bench.cpuSingle) { // 브라우저 측정값으로 대략 추정
    cm = { name: '측정 기반 추정', single: Math.round(st.bench.cpuSingle * BENCH_TO_ST), multi: Math.round((st.bench.cpuMulti || st.bench.cpuSingle) * BENCH_TO_ST * 0.75), estimated: true };
    o.src.cpu = '벤치마크 추정';
  }
  o.cpu = cm;
  o.cpuRaw = st.manual.cpu || nat.cpu || '';
  // RAM
  o.ram = st.manual.ram ? +st.manual.ram : nat.ramGB ? Math.round(nat.ramGB) : null;
  o.src.ram = st.manual.ram ? '직접 입력' : nat.ramGB ? '점검 프로그램' : null;
  if (!o.ram && st.det.memGB) { o.ramAtLeast = st.det.memGB; }
  // OS
  o.os = st.manual.os || nat.os || st.det.win || null;
  o.threads = (nat.threads) || st.det.threads || (cm && cm.threads) || null;
  o.hz = (nat.hz) || st.dev.hz || null;
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
  var rL = 'unk';
  if (ram) rL = lvl(ram, game.min.ram, game.rec.ram);
  else if (sp.ramAtLeast) { // 브라우저 값은 2의 거듭제곱으로 내림: 실제는 al 이상 al*2 미만(8 이상이면 상한 모름)
    var al = sp.ramAtLeast, hi = al >= 8 ? Infinity : al * 2;
    rL = al >= game.rec.ram ? 'rec' : al >= game.min.ram ? (hi > game.rec.ram ? 'unk' : 'min') : (hi <= game.min.ram ? 'fail' : 'unk');
  }
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
    if (!osOk) r.issues.push({ l: 'fail', spec: true, t: '운영체제: ' + (need === 'win11' ? 'Windows 11' : 'Windows 10 64비트 이상') + ' 필요' });
  }
  // 발로란트: Windows 11에서는 TPM 2.0 + 보안 부팅이 꺼져 있으면 실행 안 됨
  var nat = sp.nat || {};
  if (game.id === 'val' && sp.os === 'win11') {
    if (/꺼짐/.test(nat.secureBoot || '')) r.issues.push({ l: 'fail', t: '보안 부팅(Secure Boot)이 꺼져 있어 실행 안 됨(VAN9003) — BIOS에서 켜야 함' });
    if (/없음/.test(nat.tpm || '')) r.issues.push({ l: 'fail', t: 'TPM 2.0이 없거나 꺼져 있어 실행 안 됨(VAN9001) — BIOS에서 fTPM/PTT 켜기' });
  }
  if ((game.id === 'lol' || game.id === 'val') && nat.osBuild && nat.osBuild < 19041) r.issues.push({ l: 'fail', t: 'Windows 10 빌드 ' + nat.osBuild + ' — 19041 이상으로 업데이트 필요(VAN 9004)' });
  (game.checks || []).forEach(function (c) { r.issues.push({ l: 'info', t: c }); });
  var ls = r.comps.map(function (c) { return c.l; });
  if (ls.indexOf('fail') >= 0 || r.issues.some(function (i) { return i.l === 'fail' && i.spec; })) r.level = 'fail';
  else if (r.issues.some(function (i) { return i.l === 'fail'; })) r.level = 'block';
  else if (ls.indexOf('unk') >= 0 && !(sp.gpu)) r.level = 'unk';
  else if (ls.indexOf('min') >= 0) r.level = 'min';
  else if (ls.indexOf('unk') >= 0) r.level = 'partial';
  else r.level = 'rec';
  // FPS 추정: 그래픽 한계와 CPU 한계 중 낮은 쪽 (병목 모델)
  if (sp.gpu) {
    var f = game.fps;
    // 저사양 그래픽은 가벼운 게임에서 점수 비율보다 덜 떨어짐 → 지수(e) < 1 로 완만하게
    // 고성능 쪽은 실제 fps가 점수보다 가파르게 오름(eHi), 저사양 쪽은 완만(e)
    var gr = sp.gpu.score / 17000;
    var gpuFps = Math.pow(gr, gr > 1 && f.eHi ? f.eHi : (f.e || 0.85)) * f.g3060 * PRESET[opt.preset] * RES[opt.res];
    var cpuFps = sp.cpu ? (cpuIndex(sp.cpu) / cpuIndex({ single: 3500, multi: 19500 })) * f.c12400 * (opt.preset === 'low' ? 1.08 : opt.preset === 'high' ? 0.95 : 1) : null;
    // X3D(대용량 캐시) CPU는 CPU 부담 큰 게임에서 점수보다 빠름
    if (cpuFps && sp.cpu && /x3d/i.test(sp.cpu.name || '')) cpuFps *= 1.15;
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
var LV = { rec: ['ok', '권장 사양 충족'], min: ['warn', '최소 사양만 충족'], fail: ['bad', '사양 부족'], block: ['bad', '설정 때문에 실행 불가'], unk: ['', '정보 부족'], partial: ['info', '일부 확인 필요'] };
function targetFps(opt) { if (opt.target !== 'auto') return +opt.target; var hz = spec().hz; return hz ? Math.min(hz, 240) : 60; }
function fpsLabel(fps, tgt) {
  if (fps >= tgt) return ['ok', tgt + 'fps 이상 유지 예상'];
  if (tgt > 60 && fps >= 57) return ['warn', '60fps 이상, ' + tgt + 'fps는 어려움'];
  if (fps >= 57) return ['warn', '60fps 근처'];
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
        (j.fpsNoCpu ? '<div class="xs muted">CPU 미확인: 그래픽 기준 값</div>' : '') + '<div class="xs muted">fps 근거: ' + (g.fpsBasis ? '공개 측정값으로 보정' : '공개 측정값이 적어 사양 비례 추정') + '</div>';
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
    if (nat.secureBoot || nat.tpm) kv('· 보안 부팅 / TPM', esc(nat.secureBoot || '-') + ' / ' + esc(nat.tpm || '-'));
    devKv(nat, kv);
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
// 점검 프로그램이 읽은 장치 정보 (내 사양 탭·좌석 보고서 공용)
function devKv(nat, kv) {
  if (nat.computer || nat.seat) kv('· PC 이름', esc(nat.computer || '-') + (nat.seat ? ' (좌석 ' + esc(nat.seat) + ')' : ''));
  if (nat.displays && nat.displays.length) kv('· 모니터', nat.displays.map(function (d) { return esc(d.name || '모니터') + ' ' + esc(d.res) + ' ' + (d.hz || '-') + 'Hz' + (d.maxHz ? ' / 최대 ' + d.maxHz + 'Hz' : '') + (d.primary ? ' (주 모니터)' : ''); }).join('<br>'));
  else if (nat.monitors && nat.monitors.length) kv('· 모니터', nat.monitors.map(esc).join(', ') + (nat.monitorMaxHz ? ' · 최대 ' + nat.monitorMaxHz + 'Hz' : ''));
  if (nat.gpuLive) { var g = nat.gpuLive; kv('· 그래픽 상태', (g.tempC != null ? g.tempC + '°C' : '') + (g.util != null ? ' · 사용률 ' + g.util + '%' : '') + (g.powerW != null ? ' · ' + fmt(g.powerW, 0) + '/' + fmt(g.powerLimitW, 0) + 'W' : '') + (g.pcieGen ? ' · PCIe ' + g.pcieGen + '.0 x' + g.pcieWidth + (g.pcieWidthMax ? '(최대 x' + g.pcieWidthMax + ')' : '') : '') + (g.fanPct != null ? ' · 팬 ' + g.fanPct + '%' : '')); }
  if (nat.ramRated) kv('· 램 정격', nat.ramRated + 'MT/s' + (nat.ramXmpOff ? ' <span class="pill warn">XMP 꺼짐 의심</span>' : ''));
  if (nat.memUsedPct != null) kv('· 메모리 사용', nat.memUsedPct + '%');
  if (nat.physDisks && nat.physDisks.length) kv('· 디스크', nat.physDisks.map(function (d) { return esc(d.name) + ' ' + esc(d.media) + '/' + esc(d.bus) + ' ' + (d.sizeGB || '') + 'GB · ' + esc(d.health || '-'); }).join('<br>') + (nat.diskless ? '<br><span class="pill info">노하드 환경</span>' : ''));
  if (nat.mice && nat.mice.length) kv('· 마우스', nat.mice.map(esc).join(', ') + (nat.mouseSens ? ' · 포인터 속도 ' + nat.mouseSens + '/20' : '') + (nat.mouseAccel ? ' · 가속 켜짐' : ''));
  if (nat.keyboards && nat.keyboards.length) kv('· 키보드', nat.keyboards.map(esc).join(', '));
  if (nat.audio && nat.audio.length) kv('· 오디오', nat.audio.map(esc).join(', '));
  if (nat.vgc || nat.hvci) kv('· 뱅가드 / 메모리 무결성', esc(nat.vgc || '-') + ' / ' + esc(nat.hvci || '-'));
  if (nat.gameMode || nat.hags) kv('· 게임 모드 / HAGS', esc(nat.gameMode || '-') + ' / ' + esc(nat.hags || '-'));
  if (nat.topProcs && nat.topProcs.length) kv('· CPU 많이 쓰는 프로그램', nat.topProcs.slice(0, 5).map(function (t) { return esc(t.name) + ' ' + fmt(t.pct, 0) + '%'; }).join(', '));
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
  return sanitizeNative(o);
}
// 숫자여야 하는 칸은 숫자로 바꿔 둠(이상한 코드가 화면에 HTML로 끼어들지 않게). 글자 칸은 화면에 넣을 때 esc() 처리.
function sanitizeNative(o) {
  if (!o || typeof o !== 'object') return null;
  var num = function (v) { var n = +v; return v == null || v === '' || !isFinite(n) ? null : n; };
  var str = function (v) { return v == null ? null : String(v).slice(0, 200); };
  ['cores', 'threads', 'ramGB', 'ramSpeed', 'ramSticks', 'hz', 'osBuild', 'cpuMHz', 'cpuLoad', 'uptimeH', 'monitorMaxHz', 'ramRated', 'memUsedPct', 'sysFreePct', 'mouseSens', 'v'].forEach(function (k) { if (k in o) o[k] = num(o[k]); });
  ['cpu', 'os', 'osName', 'power', 'adapter', 'time', 'secureBoot', 'tpm', 'computer', 'disklessWhy', 'hvci', 'vgc', 'vgk', 'wuService', 'gameMode', 'hags', 'diskTypes'].forEach(function (k) { if (k in o) o[k] = str(o[k]); });
  if ('seat' in o) o.seat = o.seat == null ? null : String(o.seat).slice(0, 20);
  ['ramXmpOff', 'lowDisk', 'diskless', 'rebootPending', 'mouseAccel'].forEach(function (k) { if (k in o) o[k] = o[k] === true; });
  var strArr = function (a) { return (Array.isArray(a) ? a : a == null ? [] : [a]).slice(0, 20).map(str).filter(Boolean); };
  ['monitors', 'mice', 'keyboards', 'audio', 'warns'].forEach(function (k) { if (k in o) o[k] = strArr(o[k]); });
  var arr = function (a) { return Array.isArray(a) ? a.filter(function (x) { return x && typeof x === 'object'; }) : []; };
  var arr1 = function (a) { return arr(Array.isArray(a) ? a : a == null ? [] : [a]); };
  o.gpus = arr1(o.gpus).map(function (g) { return { name: str(g.name), vram: num(g.vram), driver: str(g.driver), driverDate: /^\d{4}-\d{2}-\d{2}$/.test(g.driverDate || '') ? g.driverDate : null, virtual: !!g.virtual }; });
  o.physDisks = arr1(o.physDisks).map(function (d) { return { name: str(d.name), media: str(d.media), bus: str(d.bus), health: str(d.health), status: str(d.status), sizeGB: num(d.sizeGB) }; });
  o.displays = arr1(o.displays).map(function (d) { return { name: str(d.name), res: str(d.res), hz: num(d.hz), maxHz: num(d.maxHz), primary: d.primary === true }; });
  o.topProcs = arr1(o.topProcs).slice(0, 10).map(function (t) { return { name: str(t.name), pct: num(t.pct) }; });
  if (o.gpuLive && typeof o.gpuLive === 'object') { var gl = o.gpuLive, nl = { name: str(gl.name), driver: str(gl.driver) }; ['tempC', 'util', 'clockMHz', 'clockMaxMHz', 'powerW', 'powerLimitW', 'pcieGen', 'pcieWidth', 'pcieWidthMax', 'fanPct'].forEach(function (k) { nl[k] = num(gl[k]); }); o.gpuLive = nl; } else delete o.gpuLive;
  o.disks = arr(o.disks).map(function (d) { return { name: str(d.name), size: num(d.size), free: num(d.free) }; });
  o.pings = arr(o.pings).map(function (p) { return { name: str(p.name), host: str(p.host), isGateway: p.isGateway === true, sent: num(p.sent), recv: num(p.recv) || 0, loss: num(p.loss) || 0, avg: num(p.avg), min: num(p.min), max: num(p.max), jitter: num(p.jitter) }; });
  o.tcp = arr(o.tcp).map(function (t) { return { name: str(t.name), host: str(t.host), port: num(t.port), ok: t.ok === true, n: num(t.n) || 0, fail: num(t.fail) || 0, avg: num(t.avg), min: num(t.min) }; });
  // 배열은 길이를 제한(저장 공간 보호)
  [['pings', 20], ['tcp', 20], ['disks', 20], ['gpus', 8], ['physDisks', 12], ['displays', 6]].forEach(function (x) { o[x[0]] = (Array.isArray(o[x[0]]) ? o[x[0]] : []).slice(0, x[1]); });
  var KEEP = ['v', 'seat', 'computer', 'time', 'cpu', 'cores', 'threads', 'cpuMHz', 'cpuLoad', 'gpus', 'gpuLive', 'hz', 'monitorMaxHz', 'displays', 'monitors', 'ramGB', 'ramSpeed', 'ramSticks', 'ramRated', 'ramXmpOff', 'memUsedPct', 'os', 'osBuild', 'osName', 'uptimeH', 'power', 'secureBoot', 'tpm', 'disks', 'diskTypes', 'physDisks', 'diskless', 'disklessWhy', 'sysFreePct', 'lowDisk', 'adapter', 'pings', 'tcp', 'hvci', 'vgc', 'vgk', 'wuService', 'rebootPending', 'gameMode', 'hags', 'mouseAccel', 'mouseSens', 'mice', 'keyboards', 'audio', 'topProcs', 'warns'];
  var out = {}; KEEP.forEach(function (k) { if (o[k] !== undefined) out[k] = o[k]; });
  return out;
}
$('#nativeApply').addEventListener('click', function () {
  try {
    var o = decodeNative($('#nativeIn').value);
    S.native = o; if (!S.seat && o.seat) { S.seat = String(o.seat); seatPill(); } save(); renderSpec(); renderNativeNet();
    $('#nativeMsg').innerHTML = '<span class="pill ok">적용했어요</span>';
    toast('점검 프로그램 결과를 적용했어요');
  } catch (e) { $('#nativeMsg').innerHTML = '<span class="pill bad">읽지 못했어요: ' + esc(e.message) + '</span>'; }
});

/* 측정은 한 번에 하나만 (동시에 돌면 서로 점수를 망침) */
var testBusy = false;
function lockTests(on) { testBusy = on; ['#cpuRun', '#gpuRun', '#hzRun', '#netRun', '#runAll'].forEach(function (id) { $(id).disabled = on; }); }

/* ---------------- CPU 벤치마크 (Web Worker) ---------------- */
// 워커마다 JIT가 따로라서, 같은 워커 안에서 0.3초 예열한 뒤 재기 시작
var WORKER_SRC = 'onmessage=function(e){var dur=e.data.dur,t0,n=0,acc=0;' +
  'function work(){var a=new Float64Array(256),s=0,x=12345;for(var i=0;i<256;i++){x=(x*1103515245+12345)&0x7fffffff;a[i]=x/2147483647;}' +
  'for(var k=0;k<4;k++){for(var i=1;i<256;i++){s+=Math.sqrt(a[i]*a[i-1]+1)*Math.sin(a[i]);}}' +
  'var o={};for(var j=0;j<64;j++){o["k"+(j&15)]=(o["k"+(j&15)]||0)+j;}' +
  'var arr=[];for(var j=0;j<128;j++)arr.push((j*7919)%128);arr.sort(function(p,q){return p-q});' +
  'var str="";for(var j=0;j<16;j++)str+=String.fromCharCode(65+(j*7)%26);' +
  'return s+arr[5]+str.length+o.k3;}' +
  'var w0=performance.now();while(performance.now()-w0<300){acc+=work();}t0=performance.now();' +
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
  var done = function () { ws.forEach(function (w) { w.terminate(); }); URL.revokeObjectURL(url); };
  return Promise.all(ps).then(function (rs) { done(); return rs; }, function (e) { done(); throw e; });
}
async function benchCpu(onProg) {
  var prog = function (p) { if (onProg) onProg(p); };
  prog(5);
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
  var b = this; if (testBusy) { toast('다른 측정이 끝난 뒤 눌러 주세요'); return; } lockTests(true); $('#cpuOut').innerHTML = '<span class="muted small">측정 중… 다른 창을 건드리지 마세요</span>';
  try { var r = await benchCpu(function (p) { $('#cpuBar').style.width = p + '%'; }); Object.assign(S.bench, r); save(); renderCpuOut(); }
  catch (e) { $('#cpuOut').innerHTML = '<span class="pill bad">측정 실패: ' + esc(e.message) + '</span>'; }
  lockTests(false);
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
  var old = $('#gpuCanvas'), cv = old.cloneNode(false); old.parentNode.replaceChild(cv, old);
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
    if (gl.isContextLost()) throw new Error('그래픽 연결이 끊겼어요(드라이버 재설정). 다시 측정하세요');
    var ms2 = batch(k, t);
    if (ms2 > 0) rates.push(k * W * H / ms2 / 1000); // 밀리초당 화소 → 초당 백만 화소
    if (onProg) onProg(Math.min(99, (performance.now() - start) / dur * 100));
    await new Promise(requestAnimationFrame);
  }
  var lose = gl.getExtension('WEBGL_lose_context');
  var score = Math.round(median(rates.slice(Math.floor(rates.length * 0.2))));
  if (lose) lose.loseContext();
  if (!rates.length) throw new Error('측정값이 없어요');
  return { gpu: score, gpuFrames: rates.length, gpuK: k, at: Date.now() };
}
$('#gpuRun').addEventListener('click', async function () {
  var b = this; if (testBusy) { toast('다른 측정이 끝난 뒤 눌러 주세요'); return; } lockTests(true); $('#gpuOut').innerHTML = '<span class="muted small">측정 중…</span>';
  try { var r = await benchGpu(function (p) { $('#gpuBar').style.width = p + '%'; }); Object.assign(S.bench, r); save(); $('#gpuBar').style.width = '100%'; renderGpuOut(); }
  catch (e) { $('#gpuOut').innerHTML = '<span class="pill bad">측정 실패: ' + esc(e.message) + '</span>'; }
  lockTests(false);
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
  var b = this; if (testBusy) { toast('다른 측정이 끝난 뒤 눌러 주세요'); return; } lockTests(true); $('#hzOut').innerHTML = '<span class="muted small">측정 중… 가만히 두세요</span>';
  var r = await measureHz(3000); S.dev.hz = r.hz; S.dev.hzInfo = r; save(); renderHz(); lockTests(false);
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
  function reset(keepSaved) {
    if (!keepSaved) { delete S.dev.chatter; delete S.dev.pollMax; delete S.dev.pollAvg; delete S.dev.mBtns; delete S.dev.wheel; save(); }
    st = { cnt: [0, 0, 0, 0, 0], chat: [0, 0, 0, 0, 0], last: [0, 0, 0, 0, 0], up: [0, 0, 0, 0, 0], evts: [], max: 0, samples: [], clicks: [] };
    $('#mBtns').innerHTML = BTN.map(function (b) { return '<div id="mb' + b[1] + '">' + b[0] + '<b>0</b><span class="xs">채터링 0</span></div>'; }).join('') ;
    ['#mHz', '#mHzMax', '#mHzAvg', '#mCps'].forEach(function (i) { $(i).textContent = '-'; });
    $('#mouseVerdict').innerHTML = '';
  }
  reset(true);
  $('#mouseReset').addEventListener('click', function () { reset(false); });
  var useRaw = 'onpointerrawupdate' in window;
  function onMove(e) {
    if (e.pointerType && e.pointerType !== 'mouse') return;
    var now = performance.now();
    var n = 1;
    if (e.getCoalescedEvents) { var c = e.getCoalescedEvents(); n = c.length || 1; }
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
    // 진짜 스위치 튐: 뗀 지 20ms도 안 돼 다시 눌림(사람이 빠르게 연타해도 보통 40ms 이상 떨어져 있음)
    if (st.last[b] && st.up[b] && st.up[b] > st.last[b] && now - st.up[b] < 20 && now - st.last[b] < 100) { st.chat[b]++; }
    st.last[b] = now; st.cnt[b]++; st.clicks.push(now);
    S.dev.mBtns = st.cnt.slice(); save();
    var el = $('#mb' + b); el.classList.add('on'); el.querySelector('b').textContent = st.cnt[b];
    el.querySelector('span').textContent = '채터링 ' + st.chat[b]; if (st.chat[b]) el.classList.add('chat');
    verdict();
  });
  window.addEventListener('mouseup', function (e) { var b = e.button; if ((b === 3 || b === 4) && !$('[data-panel="dev"]').hidden) e.preventDefault(); if (b < 0 || b > 4 || !st) return; st.up[b] = performance.now(); var el = $('#mb' + b); if (el) el.classList.remove('on'); });
  pad.addEventListener('mouseleave', function () { pad.classList.remove('active'); });
  var wheelDir = {};
  pad.addEventListener('wheel', function (e) { e.preventDefault(); wheelDir[e.deltaY < 0 ? 'up' : 'down'] = 1; if (wheelDir.up && wheelDir.down && !S.dev.wheel) { S.dev.wheel = true; save(); toast('휠 위·아래 확인됨'); } }, { passive: false });
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
  kbReset(true);
}
function kbReset(keepSaved) {
  if (keepSaved !== true) { delete S.dev.kbChat; delete S.dev.kbMax; delete S.dev.kbKeys; delete S.dev.kbMissing; save(); }
  kb = { done: {}, down: {}, max: S.dev.kbMax || 0, lastUp: {}, chat: S.dev.kbChat || 0 };
  $$('#kb .k').forEach(function (e) { e.className = 'k'; });
  // 저장된 결과가 있으면 확인한 필수 키를 다시 초록색으로
  if (S.dev.kbMissing) ESS_KEYS.forEach(function (k) { if (S.dev.kbMissing.indexOf(k) < 0) { kb.done[k] = 1; var el = kbEl(k); if (el) el.classList.add('done'); } });
  $('#kbCount').textContent = S.dev.kbKeys || Object.keys(kb.done).length; $('#kbNow').textContent = '0'; $('#kbMax').textContent = kb.max; $('#kbChat').textContent = kb.chat;
  $('#kbLast').textContent = '마지막 키: -';
}
$('#kbReset').addEventListener('click', function () { kbReset(false); });
function kbEl(code) { return $('#kb .k[data-code="' + code + '"]'); }
function kbActive() { return !$('[data-panel="dev"]').hidden && document.activeElement && document.activeElement.id === 'kb'; }
document.addEventListener('keydown', function (e) {
  if (!kb || !kbActive()) return;
  if (e.code === 'Escape' && e.shiftKey) { $('#kb').blur(); toast('키보드 테스트에서 나왔어요'); return; }
  var code = CODE_ALIAS[e.code] || e.code || (e.key === 'HangulMode' ? 'Lang1' : e.key === 'HanjaMode' ? 'Lang2' : '');
  if (!code) return;
  e.preventDefault();
  if (e.repeat) return;
  var now = performance.now();
  if (kb.lastUp[code] && now - kb.lastUp[code] < 30) { kb.chat++; var c = kbEl(code); if (c) c.classList.add('chat'); }
  kb.down[code] = 1; kb.done[code] = 1;
  var n = Object.keys(kb.down).length; if (n > kb.max) kb.max = n;
  var el = kbEl(code); if (el) { el.classList.add('down', 'done'); }
  $('#kbCount').textContent = Object.keys(kb.done).length; $('#kbNow').textContent = n; $('#kbMax').textContent = kb.max; $('#kbChat').textContent = kb.chat;
  $('#kbLast').textContent = '마지막 키: ' + code + ' (' + (e.key === ' ' ? 'Space' : e.key) + ')';
  S.dev.kbMax = kb.max; S.dev.kbChat = kb.chat; S.dev.kbKeys = Object.keys(kb.done).length;
  S.dev.kbMissing = ESS_KEYS.filter(function (k) { return !kb.done[k]; });
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
// 버튼이 나중에 그려져도 동작하도록 문서 전체에서 받음
document.addEventListener('click', function (e) {
  var b = e.target.closest && e.target.closest('[data-tone]'); if (!b) return;
  try { (function () {
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
    $('#toneAsk').innerHTML = '소리가 <b>' + where + '</b>에서 들렸나요? 반대쪽에서 들리면 헤드셋 좌우가 바뀐 거예요(윈도우 소리 설정의 모노 오디오·스피커 구성 확인). 위 체크리스트에 정상/불량을 눌러 주세요.';
  })(); } catch (err) { toast('소리를 낼 수 없어요: 소리 장치를 확인하세요'); }
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
      if (!r.ok) throw new Error('HTTP ' + r.status);
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
  var b = this; if (testBusy) { toast('다른 측정이 끝난 뒤 눌러 주세요'); return; } lockTests(true); $('#netVerdict').innerHTML = '<span class="muted small">측정 중…</span>';
  S.net = await runNet(function (p) { $('#netBar').style.width = p + '%'; }); $('#netBar').style.width = '100%'; save(); renderNet(); lockTests(false);
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
    (tcp ? '<div class="tblwrap"><table><thead><tr><th>게임사 웹 서버 접속(TCP)</th><th>평균</th><th>최소</th><th>판정</th></tr></thead><tbody>' + tcp + '</tbody></table></div>' : '') + v +
    '<div class="xs muted">측정 시각: ' + esc(n.time || '') + '</div>';
}

/* ---------------- 전체 자동 점검 ---------------- */
var STEPS = [['detect', '사양 감지'], ['hz', '모니터 주사율'], ['cpu', 'CPU 측정'], ['gpu', '그래픽 측정'], ['net', '인터넷 지연·속도']];
function drawSteps(state) {
  $('#allSteps').innerHTML = STEPS.map(function (s) { var v = state[s[0]] || ''; return '<div class="st"><span class="ic">' + (v === 'done' ? '✓' : v === 'run' ? '…' : v === 'err' ? '✗' : '·') + '</span><span' + (v === 'run' ? ' style="font-weight:700"' : v === 'done' ? '' : ' class="muted"') + '>' + s[1] + '</span></div>'; }).join('');
}
$('#runAll').addEventListener('click', async function () {
  var b = this; if (testBusy) { toast('다른 측정이 끝난 뒤 눌러 주세요'); return; } lockTests(true);
  S.seat = $('#seatIn').value.trim(); save(); seatPill();
  var st = {}, bar = $('#allBar');
  var setP = function (base, span) { return function (p) { bar.style.width = (base + span * p / 100) + '%'; }; };
  async function step(key, base, span, fn) { st[key] = 'run'; drawSteps(st); try { await fn(setP(base, span)); st[key] = 'done'; } catch (e) { st[key] = 'err'; console.error(e); } bar.style.width = (base + span) + '%'; drawSteps(st); }
  await step('detect', 0, 5, async function () { await detect(); });
  await step('hz', 5, 10, async function () { var r = await measureHz(2500); S.dev.hz = r.hz; S.dev.hzInfo = r; save(); });
  await step('cpu', 15, 25, async function (p) { Object.assign(S.bench, await benchCpu(p)); save(); });
  await step('gpu', 40, 30, async function (p) { Object.assign(S.bench, await benchGpu(p)); save(); });
  await step('net', 70, 30, async function (p) { S.net = await runNet(p); save(); });
  lockTests(false);
  renderAllOut();
  renderSummary();
  toast('점검이 끝났어요');
});
function renderAllOut() { renderCpuOut(); renderGpuOut(); renderHz(); renderNet(); renderNativeNet(); }
// 문제 목록: {id, t(설명), short(짧은 이름), lv('bad' 바로 고칠 것 | 'warn' 확인 | 'info' 참고), fix(조치 방법)}
function problems(st) {
  st = st || S;
  var p = [], sp = spec(st), det = st.det || {}, dev = st.dev || {}, nat = st.native || {};
  var add = function (id, lv, t, fix, short) { p.push({ id: id, lv: lv, t: t, fix: fix, short: short || t }); };
  if (det.renderer && softwareRenderer(det.renderer)) add('swr', nat.gpus && nat.gpus.length ? 'warn' : 'bad', '브라우저 그래픽 가속 꺼짐/드라이버 없음', '그래픽카드 제조사(NVIDIA·AMD·Intel) 최신 드라이버를 설치하고, 브라우저 설정 → 시스템 → "가능한 경우 그래픽 가속 사용"을 켜세요.', '그래픽 가속 꺼짐');
  if (!sp.gpu && (det.renderer || (nat.gpus && nat.gpus.length))) add('gpuunk', 'info', '그래픽카드 모델을 표에서 못 찾음', '내 사양 탭에서 그래픽카드를 직접 고르면 판정이 정확해져요.', '그래픽 미확인');
  // 모니터
  var maxHz = nat.monitorMaxHz || null;
  if (sp.hz && sp.hz <= 61 && (dev.hzInfo || nat.hz)) add('hz60', maxHz && maxHz > 61 ? 'bad' : 'warn', '모니터가 ' + sp.hz + 'Hz로 동작' + (maxHz > 61 ? ' (모니터는 ' + maxHz + 'Hz 지원)' : ''), '바탕화면 우클릭 → 디스플레이 설정 → 고급 디스플레이 → 새로 고침 빈도를 최대로. 안 보이면 케이블을 DP(또는 HDMI 2.0 이상)로 바꾸고, 그래픽카드 단자에 꽂혔는지(메인보드 단자 아님) 확인하세요.', '60Hz 동작');
  // 마우스·키보드·마이크
  if (dev.chatter) add('mchat', 'bad', '마우스 더블클릭(채터링) ' + dev.chatter + '회', '마우스 스위치 고장이에요. 마우스를 교체하거나 스위치를 교체하세요. 임시로는 마우스 소프트웨어에서 디바운스 시간을 늘리세요.', '마우스 채터링');
  if (dev.kbChat) add('kchat', 'bad', '키보드 채터링 의심 ' + dev.kbChat + '회', '키를 한 번 눌렀는데 두 번 입력돼요. 해당 키캡을 빼고 청소하거나 스위치/키보드를 교체하세요.', '키보드 채터링');
  if (dev.pollMax && dev.pollMax < 200) add('poll', 'warn', '마우스 폴링레이트 낮음 (최고 ' + dev.pollMax + 'Hz)', '게이밍 마우스라면 마우스 소프트웨어에서 1000Hz로 설정하세요. 사무용 마우스(125Hz)는 FPS 게임에 불리해요.', '마우스 폴링 낮음');
  chkState(dev).forEach(function (x) {
    // 자동 판정만으로 불량인 항목(주사율·폴링·버튼·키·마이크)은 아래 전용 항목에서 다룸
    if (x.st !== 'bad' || (!(dev.chk || {})[x.c.id] && ['hz', 'poll', 'mbtn', 'keys', 'mic'].indexOf(x.c.id) >= 0)) return;
    var fixes = { screen: '불량 화소·빛샘이 눈에 띄면 모니터 A/S(무결점 보증 기간 확인) 또는 교체하세요.', audL: '단자를 끝까지 꽂고, 다른 헤드셋으로 바꿔 보세요. 같으면 PC 사운드 단자·드라이버, 다르면 헤드셋 고장이에요.', audR: '단자를 끝까지 꽂고, 다른 헤드셋으로 바꿔 보세요. 같으면 PC 사운드 단자·드라이버, 다르면 헤드셋 고장이에요.', mic: '마이크 단자·음소거 스위치·윈도우 입력 장치를 확인하세요.', mbtn: '버튼 스위치 고장이에요. 마우스를 교체하세요.', wheel: '휠 인코더 고장이에요. 청소해 보고 안 되면 교체하세요.', keys: '안 눌리는 키는 키캡을 빼고 청소하고, 그래도 안 되면 키보드를 교체하세요.' };
    add('chk-' + x.c.id, 'bad', x.c.n + ' 불량', fixes[x.c.id] || '', x.c.n + ' 불량');
  });
  if (dev.note) add('note', 'info', '메모: ' + dev.note, '', '메모');
  if (dev.mic === 'none' && !((dev.chk || {}).mic === 'bad')) add('mic', 'warn', '마이크가 연결되지 않았거나 권한 없음', '헤드셋 마이크 단자(분홍색)를 확인하고, 윈도우 소리 설정 → 입력 장치를 확인하세요.', '마이크 없음');
  // 인터넷(브라우저)
  if (st.net && st.net.targets) {
    var ok = st.net.targets.filter(function (r) { return r.med != null; });
    var loss = st.net.targets.reduce(function (a, r) { return Math.max(a, r.loss || 0); }, 0);
    var jit = ok.reduce(function (a, r) { return Math.max(a, r.jitter || 0); }, 0);
    if (!ok.length) add('netnone', 'bad', '인터넷 응답 없음', '랜선 연결, 공유기/허브 전원, 윈도우 네트워크 어댑터 상태를 확인하세요.', '인터넷 안 됨');
    else if (loss >= 0.1 || jit > 40) add('netbad', 'bad', '인터넷 불안정 (지터 ' + fmt(jit) + 'ms, 실패 ' + Math.round(loss * 100) + '%)', '윈도우 점검 프로그램으로 게이트웨이 핑을 확인해 매장 안 문제인지 통신사 문제인지 가려 보세요.', '인터넷 불안정');
  }
  // 윈도우 점검 프로그램 결과
  var gw = (nat.pings || []).filter(function (x) { return x.isGateway; })[0];
  if (gw && !gw.recv) add('gwdead', 'bad', '게이트웨이(공유기) 응답 없음', '랜선·허브 포트·랜카드를 확인하세요. 공유기가 핑을 막아 둔 경우도 있으니 인터넷이 되는지 함께 보세요.', '게이트웨이 무응답');
  else if (gw && (gw.loss > 0 || gw.avg > 3)) add('gw', 'bad', '게이트웨이 핑 이상 (평균 ' + fmt(gw.avg, 1) + 'ms, 손실 ' + gw.loss + '%)', '매장 안 네트워크 문제예요. 랜선 교체(Cat5e 이상), 허브 포트 변경, 랜카드 드라이버 업데이트 순서로 확인하세요.', '게이트웨이 핑');
  var ext = (nat.pings || []).filter(function (x) { return !x.isGateway && x.recv; });
  if (gw && gw.recv && !(gw.loss > 0 || gw.avg > 3) && ext.length && median(ext.map(function (x) { return x.avg; })) > 40) add('ext', 'warn', '외부 핑이 높음 (중간값 ' + fmt(median(ext.map(function (x) { return x.avg; }))) + 'ms)', '매장 안은 정상이에요. 통신사 회선 상태를 문의하세요.', '외부 핑 높음');
  if (nat.adapter) {
    if (/무선|wi-?fi|wireless/i.test(nat.adapter)) add('wifi', 'warn', '와이파이로 연결됨', '게임용 좌석은 유선 랜 연결을 권장해요.', '와이파이');
    var lm = nat.adapter.match(/(\d+)\s*Mbps/); if (lm && +lm[1] > 0 && +lm[1] < 1000) add('link', 'warn', '랜 연결 속도 ' + lm[1] + 'Mbps', '1Gbps가 아니에요. 랜선(8가닥 모두 연결된 Cat5e 이상)과 허브 포트를 확인하세요.', '랜 ' + lm[1] + 'Mbps');
  }
  if (nat.power && !/고성능|최고/.test(nat.power)) add('power', 'warn', '전원 관리 옵션: ' + nat.power, '제어판 → 전원 옵션 → 고성능을 고르세요. 명령 프롬프트: powercfg /setactive SCHEME_MIN', '전원 ' + nat.power);
  if (nat.os === 'win11' && /꺼짐/.test(nat.secureBoot || '')) add('sb', 'bad', '보안 부팅 꺼짐 — 발로란트 실행 불가(VAN9003)', 'BIOS(부팅 때 Del/F2) → Boot → Secure Boot 켜기. CSM이 켜져 있으면 끄고 UEFI 모드로 바꿔야 해요.', '보안 부팅 꺼짐');
  if (nat.os === 'win11' && /없음/.test(nat.tpm || '')) add('tpm', 'bad', 'TPM 2.0 없음/꺼짐 — 발로란트 실행 불가(VAN9001)', 'BIOS에서 인텔은 PTT, AMD는 fTPM을 켜세요.', 'TPM 꺼짐');
  if (nat.osBuild && nat.osBuild < 19041) add('build', 'bad', 'Windows 10 빌드 ' + nat.osBuild + ' — 롤·발로란트 실행 불가(VAN 9004)', '윈도우 업데이트로 최신 버전(22H2 이상)으로 올리세요.', '윈도우 구버전');
  if (nat.os === 'win10-32') add('os32', 'bad', '32비트 윈도우', '인기 게임은 모두 64비트 전용이에요. 64비트 윈도우를 새로 설치해야 해요.', '32비트 윈도우');
  if (nat.ramXmpOff) add('xmp', 'warn', '램이 정격 속도보다 느리게 동작 (XMP/EXPO 꺼짐 의심)', 'BIOS에서 XMP(인텔)/EXPO(AMD) 프로필을 켜면 CPU 병목 게임(롤·발로란트·서든)의 프레임이 올라요.', 'XMP 꺼짐');
  if (nat.rebootPending) add('reboot', 'warn', '재부팅 대기 중인 업데이트가 있음', '영업 전 재부팅하세요. 게임 중 업데이트 재시작을 막을 수 있어요.', '재부팅 필요');
  var now = Date.now();
  (nat.gpus || []).forEach(function (g) {
    if (g.driverDate && !g.virtual) { var age = (now - Date.parse(g.driverDate)) / 864e5; if (age > 365) add('drv', 'warn', '그래픽 드라이버가 오래됨 (' + g.driverDate + ')', '최신 게임 패치는 새 드라이버를 기준으로 맞춰요. NVIDIA 앱/AMD Adrenalin으로 업데이트하세요.', '드라이버 오래됨'); }
  });
  var temp = nat.gpuLive ? nat.gpuLive.tempC : null;
  if (temp != null && temp >= 85) add('hot', 'bad', '그래픽카드 온도 ' + temp + '°C', '먼지 청소, 케이스 팬 동작, 그래픽카드 팬을 확인하세요. 계속 높으면 서멀 그리스를 다시 바르세요.', 'GPU 과열');
  (nat.disks || []).forEach(function (d) { if (d.size && d.free != null && d.free / d.size < 0.1) add('disk', 'warn', d.name + ' 드라이브 여유 공간 ' + d.free + 'GB (' + Math.round(d.free / d.size * 100) + '%)', '게임 패치가 실패할 수 있어요. 필요 없는 파일과 게임을 정리하세요.', '디스크 부족'); });
  if (nat.memUsedPct >= 85) add('mem', 'warn', '메모리 사용량 ' + nat.memUsedPct + '% (점검 시점)', '백그라운드 프로그램을 확인하세요. 게임 중 끊김의 원인이 돼요.' + (nat.topProcs && nat.topProcs.length ? ' CPU를 많이 쓰는 프로그램: ' + nat.topProcs.slice(0, 3).map(function (t) { return t.name; }).join(', ') : ''), '메모리 부족');
  if (nat.topProcs && nat.topProcs.length && nat.topProcs[0].pct >= 25) add('bgcpu', 'warn', '백그라운드 프로그램이 CPU를 많이 씀: ' + nat.topProcs[0].name + ' ' + Math.round(nat.topProcs[0].pct) + '%', '모르는 프로그램이면 채굴·광고 프로그램일 수 있어요. 작업 관리자에서 확인하고 이미지에서 지우세요.', '백그라운드 CPU');
  if (/켜짐/.test(nat.hvci || '')) add('hvci', 'info', '메모리 무결성(HVCI) 켜짐', '보안 기능이지만 게임 성능이 몇 % 떨어질 수 있어요. Windows 보안 → 장치 보안 → 코어 격리에서 바꿀 수 있어요(발로란트 등은 꺼도 실행돼요).', 'HVCI 켜짐');
  if (nat.diskless) add('dl', 'info', '노하드(디스크리스) 환경' + (nat.disklessWhy ? ': ' + nat.disklessWhy : ''), '재부팅하면 좌석의 기록이 지워져요. 결과는 공유 폴더(-Share)로 모으세요. 설정 변경(전원·주사율 등)은 서버 이미지에 해야 유지돼요.', '노하드');
  (nat.physDisks || []).forEach(function (d) { if (d.health && !/healthy|정상/i.test(d.health)) add('diskh', 'bad', '디스크 상태 이상: ' + (d.name || '') + ' (' + d.health + ')', '곧 고장 날 수 있어요. 데이터를 백업하고 교체를 준비하세요.', '디스크 이상'); });
  if (nat.mouseAccel) add('accel', 'info', '포인터 정확도 향상(마우스 가속) 켜짐', '제어판 → 마우스 → 포인터 옵션 → "포인터 정확도 향상" 끄기 (FPS 게임 조준이 일정해져요).', '마우스 가속');
  // 사양 부족 게임
  var fails = GAMES.filter(function (g) { return judge(g, sp, st.opt || S.opt).level === 'fail'; }).map(function (g) { return g.short || g.name; });
  if (fails.length) add('spec', 'warn', '사양 부족: ' + fails.join(', '), '게임 판정의 "부족" 부품(그래픽/CPU/RAM)부터 업그레이드하세요.', '사양 부족 ' + fails.length + '개');
  var ord = { bad: 0, warn: 1, info: 2 };
  return p.sort(function (a, b) { return ord[a.lv] - ord[b.lv]; });
}
function renderSummary() {
  var sp = spec();
  if (!S.det.at) { $('#summary').innerHTML = ''; return; }
  var tgt = targetFps(S.opt);
  var games = GAMES.map(function (g) { var j = judge(g, sp, S.opt); return { g: g, j: j }; });
  var cnt = { rec: 0, min: 0, fail: 0 };
  games.forEach(function (x) { var l = x.j.level === 'block' ? 'fail' : x.j.level; if (cnt[l] != null) cnt[l]++; });
  var pr = problems();
  var html = '<div class="card stack"><div class="row between"><div class="h2">점검 결과' + (S.seat ? ' · ' + esc(S.seat) + '번 좌석' : '') + '</div><div class="row"><button class="btn sm" data-goto="games" type="button">게임별 자세히</button><button class="btn sm" id="sumSave" type="button">매장 현황에 넣기</button></div></div>' +
    '<div class="row sumrow"><div class="stat"><b>' + esc(sp.gpu ? sp.gpu.name : '그래픽 모름') + '</b><span>그래픽 · ' + esc(sp.src.gpu || '') + '</span></div>' +
    '<div class="stat"><b>' + esc(sp.cpu ? sp.cpu.name : 'CPU 모름') + '</b><span>CPU · ' + esc(sp.src.cpu || '내 사양 탭에서 고르기') + '</span></div>' +
    '<div class="stat"><b>' + (sp.ram ? sp.ram + 'GB' : sp.ramAtLeast ? sp.ramAtLeast + 'GB+' : '-') + '</b><span>RAM</span></div>' +
    '<div class="stat"><b>' + (sp.hz ? sp.hz + 'Hz' : '-') + '</b><span>모니터</span></div></div>' +
    '<div class="row"><span class="pill ok">권장 충족 ' + cnt.rec + '개</span><span class="pill warn">최소만 ' + cnt.min + '개</span><span class="pill bad">부족·실행 불가 ' + cnt.fail + '개</span></div>' +
    (pr.length ? '<div class="stack">' + pr.map(function (p) { return '<div class="' + (p.lv === 'bad' ? 'badbox' : p.lv === 'warn' ? 'warnbox' : 'note') + '">' + esc(p.t) + (p.fix ? '<div class="small" style="font-weight:500;margin-top:2px">' + esc(p.fix) + '</div>' : '') + '</div>'; }).join('') + '</div>' : '<div class="okbox">눈에 띄는 문제가 없어요.</div>') +
    '<div class="tblwrap"><table><thead><tr><th>게임</th><th>판정</th><th>예상 fps (' + S.opt.res + 'p · ' + ({ low: '낮음', mid: '중간', high: '높음' })[S.opt.preset] + ')</th></tr></thead><tbody>' +
    games.map(function (x) { var lv = LV[x.j.level]; var fl = x.j.fps != null ? fpsLabel(x.j.fps, tgt) : null; return '<tr><td>' + x.g.rank + '. ' + esc(x.g.name) + '</td><td><span class="pill ' + lv[0] + '">' + lv[1] + '</span></td><td class="num">' + (x.j.fps != null ? (x.j.fps >= (x.g.fps.cap || 1e9) ? x.g.fps.cap + '+' : '약 ' + fmt(x.j.fps)) + ' <span class="pill ' + fl[0] + '">' + (fl[0] === 'ok' ? '쾌적' : fl[0] === 'warn' ? '보통' : '버벅임') + '</span>' : '-') + '</td></tr>'; }).join('') +
    '</tbody></table></div>' +
    (function () { var cl = chkState(S.dev), ok = cl.filter(function (x) { return x.st === 'ok'; }).length; return '<div class="note"><b>다음 단계: 장비 체크리스트 ' + ok + '/' + cl.length + '</b> — 모니터 화면·헤드셋 좌우·마우스·키보드는 <a href="#dev" data-goto="dev">장비 테스트</a>에서 눌러 확인하세요. 게이트웨이·외부 핑과 보안 부팅·TPM은 윈도우 점검 프로그램이 필요해요.</div>'; })() + '</div>';
  $('#summary').innerHTML = html;
  $('#sumSave').addEventListener('click', function () { $('#shopAddThis').click(); });
}

/* ---------------- 문제 해결 안내 ---------------- */
function renderFixes() {
  var q = ($('#fixSearch').value || '').trim().toLowerCase().replace(/\s+/g, ' ');
  var words = q ? q.split(' ') : [];
  var list = (window.FIXES || []).filter(function (f) { var hay = (f.k + ' ' + f.t + ' ' + f.g + ' ' + f.steps.join(' ')).toLowerCase(); return words.every(function (w) { return hay.indexOf(w) >= 0 || hay.replace(/\s/g, '').indexOf(w) >= 0; }); });
  $('#fixList').innerHTML = list.length ? list.map(function (f) {
    return '<article class="card stack"><div class="row between"><div class="h3">' + esc(f.t) + '</div>' + (f.conf === 'high' ? '' : '<span class="pill" title="공식 문서로 확인하지 못한 일반적인 조치">경향</span>') + '</div><div class="xs muted">' + esc(f.g) + '</div><ol class="fixlist">' + f.steps.map(function (s) { return '<li class="small">' + esc(s) + '</li>'; }).join('') + '</ol></article>';
  }).join('') : '<div class="card muted">찾는 내용이 없어요. 다른 말로 찾아보세요.</div>';
}
$('#fixSearch').addEventListener('input', renderFixes);

/* ---------------- 좌석 장비 체크리스트 ---------------- */
// 게임에 꼭 필요한 키(이게 안 눌리면 바로 불만이 나옴)
var ESS_KEYS = ['Escape', 'Tab', 'CapsLock', 'ShiftLeft', 'ControlLeft', 'AltLeft', 'Space', 'Enter', 'Backspace', 'KeyQ', 'KeyW', 'KeyE', 'KeyR', 'KeyT', 'KeyA', 'KeyS', 'KeyD', 'KeyF', 'KeyG', 'KeyZ', 'KeyX', 'KeyC', 'KeyV', 'KeyB', 'Digit1', 'Digit2', 'Digit3', 'Digit4', 'Digit5', 'F1', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'];
var KEY_NAME = function (c) { return c.replace(/^Key|^Digit/, '').replace('ShiftLeft', '왼Shift').replace('ControlLeft', '왼Ctrl').replace('AltLeft', '왼Alt').replace('Arrow', '방향').replace('Escape', 'Esc'); };
// 항목: auto(st)는 'ok'|'bad'|null(아직 모름) 과 설명을 돌려줌. manual 항목은 사람이 누름.
var CHK = [
  { id: 'screen', n: '모니터 화면', d: '불량 화소·얼룩·빛샘', manual: true, tool: 'color' },
  { id: 'hz', n: '모니터 주사율', auto: function (d) { return d.hz ? [d.hz > 61 ? 'ok' : 'bad', d.hz + 'Hz'] : [null, '주사율 측정 필요']; } },
  { id: 'audL', n: '헤드셋 왼쪽 소리', manual: true, tool: 'L' },
  { id: 'audR', n: '헤드셋 오른쪽 소리', manual: true, tool: 'R' },
  { id: 'mic', n: '마이크', manual: true, auto: function (d) { return d.mic === 'ok' ? ['ok', '소리 감지됨'] : d.mic === 'none' ? ['bad', '연결 안 됨/권한 없음'] : d.mic === 'low' ? [null, '소리가 작음: 말해 보세요'] : [null, '마이크 켜기로 확인']; } },
  { id: 'mbtn', n: '마우스 버튼', manual: true, auto: function (d) { var c = d.mBtns || []; if (d.chatter) return ['bad', '채터링 ' + d.chatter + '회']; var miss = ['왼쪽', '가운데', '오른쪽'].filter(function (x, i) { return !(c[i] > 0); }); return miss.length ? [null, '안 누른 버튼: ' + miss.join(', ')] : ['ok', '왼쪽·가운데·오른쪽 확인' + (c[3] > 0 || c[4] > 0 ? ' + 옆 버튼' : '')]; } },
  { id: 'wheel', n: '마우스 휠 굴리기', manual: true, auto: function (d) { return d.wheel ? ['ok', '위·아래 확인'] : [null, '마우스 영역에서 휠을 굴려 보세요']; } },
  { id: 'poll', n: '마우스 폴링레이트', auto: function (d) { return d.pollMax ? [d.pollMax >= 200 ? 'ok' : 'bad', '최고 ' + d.pollMax + 'Hz'] : [null, '마우스 영역에서 빠르게 움직이기']; } },
  { id: 'keys', n: '게임 필수 키 ' + ESS_KEYS.length + '개', manual: true, auto: function (d) { if (d.kbChat) return ['bad', '채터링 의심 ' + d.kbChat + '회']; var m = d.kbMissing; if (!m) return [null, '키보드 그림을 누르고 키를 눌러 보세요']; return m.length ? [null, '남은 키: ' + m.slice(0, 8).map(KEY_NAME).join(' ') + (m.length > 8 ? ' 외 ' + (m.length - 8) + '개' : '')] : ['ok', '모두 입력됨']; } }
];
function chkState(d) {
  var chk = d.chk || {};
  return CHK.map(function (c) {
    var a = c.auto ? c.auto(d) : [null, c.d || ''];
    var st = chk[c.id] || a[0];
    return { c: c, st: st, desc: chk[c.id] ? (chk[c.id] === 'ok' ? '직접 확인: 정상' : '직접 확인: 불량') + (a[1] && c.auto ? ' · ' + a[1] : '') : a[1] };
  });
}
var lastChkHtml = '';
function renderChk() {
  var d = S.dev, list = chkState(d);
  var html = list.map(function (x) {
    var c = x.c, man = (d.chk || {})[c.id];
    var tool = c.tool === 'color' ? '<button class="btn sm" type="button" data-color-test>화면 색 검사</button>' : c.tool ? '<button class="btn sm" type="button" data-tone="' + (c.tool === 'L' ? '-1' : '1') + '">소리 내기</button>' : '';
    var pill = x.st === 'ok' ? '<span class="pill ok">정상</span>' : x.st === 'bad' ? '<span class="pill bad">불량</span>' : '<span class="pill">확인 전</span>';
    return '<div class="ci"><div><div class="cn">' + esc(c.n) + ' ' + pill + '</div><div class="cd">' + esc(x.desc || '') + '</div></div><div class="ca">' + tool +
      (c.manual ? '<button class="btn sm' + (man === 'ok' ? ' sel-ok' : '') + '" type="button" data-chk="' + c.id + '" data-v="ok" aria-pressed="' + (man === 'ok') + '">정상</button><button class="btn sm' + (man === 'bad' ? ' sel-bad' : '') + '" type="button" data-chk="' + c.id + '" data-v="bad" aria-pressed="' + (man === 'bad') + '">불량</button>' : '') + '</div></div>';
  }).join('');
  if (html !== lastChkHtml) { lastChkHtml = html; $('#chkList').innerHTML = html; }
  var ok = list.filter(function (x) { return x.st === 'ok'; }).length, bad = list.filter(function (x) { return x.st === 'bad'; }).length;
  var sum = $('#chkSum'), txt = ok + '/' + list.length + ' 정상' + (bad ? ' · 불량 ' + bad : ''), cls = 'pill ' + (bad ? 'bad' : ok === list.length ? 'ok' : '');
  if (sum.textContent !== txt) sum.textContent = txt;
  if (sum.className !== cls) sum.className = cls;
  if (document.activeElement !== $('#chkNote')) $('#chkNote').value = d.note || '';
}
$('#chkList').addEventListener('click', function (e) {
  var b = e.target.closest('[data-chk]');
  if (b) { S.dev.chk = S.dev.chk || {}; var id = b.dataset.chk; S.dev.chk[id] = S.dev.chk[id] === b.dataset.v ? undefined : b.dataset.v; if (!S.dev.chk[id]) delete S.dev.chk[id]; save(); renderChk(); return; }
  if (e.target.closest('[data-color-test]')) colorTest();
});
$('#chkNote').addEventListener('input', function () { S.dev.note = this.value.trim().slice(0, 120); save(); });
// 장비 테스트 값이 바뀌면 체크리스트도 갱신(내용이 같으면 화면을 건드리지 않아 클릭·포커스가 유지됨)
setInterval(function () { if (!$('[data-panel="dev"]').hidden) renderChk(); }, 500);

/* 화면 색 검사: 전체 화면 단색 → 불량 화소·빛샘 확인 */
function colorTest() {
  var el = $('#colorTest'), hint = $('#colorHint');
  var colors = ['#000000', '#FFFFFF', '#FF0000', '#00FF00', '#0000FF', '#808080'], i = 0;
  el.hidden = false; el.style.background = colors[0]; hint.hidden = false; el.focus();
  if (el.requestFullscreen) el.requestFullscreen().catch(function () {});
  var t = setTimeout(function () { hint.hidden = true; }, 2500);
  function next() { i++; hint.hidden = true; if (i >= colors.length) return end(); el.style.background = colors[i]; }
  function fc() { if (!document.fullscreenElement && !el.hidden) end(); }
  function end() {
    clearTimeout(t); el.hidden = true; el.removeEventListener('click', next); document.removeEventListener('keydown', key, true); document.removeEventListener('fullscreenchange', fc);
    var opener = $('[data-color-test]'); if (opener) opener.focus();
    if (document.fullscreenElement && document.exitFullscreen) document.exitFullscreen().catch(function () {});
    toast('화면에 이상이 있었으면 "불량", 없었으면 "정상"을 눌러 주세요');
  }
  function key(e) { if (el.hidden) return; e.preventDefault(); e.stopPropagation(); if (e.key === 'Escape') end(); else if (e.key === ' ' || e.key === 'Enter' || e.key === 'ArrowRight') next(); }
  el.addEventListener('click', next); document.addEventListener('keydown', key, true);
  document.addEventListener('fullscreenchange', fc);
}

/* ---------------- 좌석 결과 코드·매장 현황 ---------------- */
function seatPill() { $('#seatPill').textContent = S.seat ? S.seat + '번 좌석' : '좌석 미지정'; $('#seatIn').value = S.seat || ''; }
function b64enc(obj) { var bytes = new TextEncoder().encode(JSON.stringify(obj)), bin = ''; for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]); return btoa(bin); }
function b64dec(b64) { var bin = atob(b64.replace(/\s+/g, '')), bytes = new Uint8Array(bin.length); for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i); return JSON.parse(new TextDecoder('utf-8').decode(bytes).replace(/^﻿/, '')); }
// 이 좌석에서 브라우저로 잰 결과(PCBANGW1) + 붙여넣은 점검 프로그램 결과(PCBANG1)
function webPayload() {
  var n = S.net;
  return {
    v: 1, seat: S.seat || '', at: Date.now(),
    det: { renderer: S.det.renderer || '', threads: S.det.threads || null, memGB: S.det.memGB || null, win: S.det.win || null, osName: S.det.osName || '' },
    manual: S.manual || {},
    bench: { cpuSingle: S.bench.cpuSingle || null, cpuMulti: S.bench.cpuMulti || null, gpu: S.bench.gpu || null },
    dev: { chk: S.dev.chk || {}, note: S.dev.note || '', mBtns: S.dev.mBtns || null, wheel: !!S.dev.wheel, kbMissing: S.dev.kbMissing || null, hz: S.dev.hz || null, measuredHz: !!S.dev.hzInfo, pollMax: S.dev.pollMax || null, pollAvg: S.dev.pollAvg || null, chatter: S.dev.chatter || 0, kbChat: S.dev.kbChat || 0, kbMax: S.dev.kbMax || null, kbKeys: S.dev.kbKeys || null, react: S.dev.react || null, mic: S.dev.mic || null },
    net: n ? { targets: n.targets.map(function (t) { return { name: t.name, med: t.med, min: t.min, jitter: t.jitter, loss: t.loss }; }), down: n.down } : null
  };
}
function seatCodes() {
  var lines = ['PCBANGW1:' + b64enc(webPayload())];
  if (S.native) lines.push('PCBANG1:' + b64enc(S.native));
  return lines.join('\n');
}
function sanitizeWeb(o) {
  if (!o || typeof o !== 'object') return null;
  var num = function (v) { var n = +v; return v == null || v === '' || !isFinite(n) ? null : n; };
  var str = function (v) { return v == null ? '' : String(v).slice(0, 200); };
  var d = o.det || {}, m = o.manual || {}, b = o.bench || {}, v = o.dev || {}, n = o.net;
  return {
    seat: str(o.seat).slice(0, 20), at: num(o.at) || Date.now(),
    det: { renderer: str(d.renderer), threads: num(d.threads), memGB: num(d.memGB), win: ['win11', 'win10', 'win7'].indexOf(d.win) >= 0 ? d.win : null, osName: str(d.osName), at: 1 },
    manual: { cpu: str(m.cpu), gpu: str(m.gpu), ram: num(m.ram) ? String(num(m.ram)) : '', os: str(m.os) },
    bench: { cpuSingle: num(b.cpuSingle), cpuMulti: num(b.cpuMulti), gpu: num(b.gpu) },
    dev: { chk: (function (c) { var o = {}; if (c && typeof c === 'object') CHK.forEach(function (x) { if (c[x.id] === 'ok' || c[x.id] === 'bad') o[x.id] = c[x.id]; }); return o; })(v.chk), note: str(v.note).slice(0, 120), mBtns: Array.isArray(v.mBtns) ? v.mBtns.slice(0, 5).map(function (n) { return num(n) || 0; }) : null, wheel: v.wheel === true, kbMissing: Array.isArray(v.kbMissing) ? v.kbMissing.filter(function (k) { return ESS_KEYS.indexOf(k) >= 0; }) : null, hz: num(v.hz), hzInfo: (v.measuredHz || (v.hzInfo && v.hzInfo.hz)) ? { hz: num(v.hz) } : null, pollMax: num(v.pollMax), pollAvg: num(v.pollAvg), chatter: num(v.chatter) || 0, kbChat: num(v.kbChat) || 0, kbMax: num(v.kbMax), kbKeys: num(v.kbKeys), react: num(v.react), mic: ['ok', 'low', 'none'].indexOf(v.mic) >= 0 ? v.mic : null },
    net: n && Array.isArray(n.targets) ? { targets: n.targets.slice(0, 20).map(function (t) { return { name: str(t.name), med: num(t.med), min: num(t.min), jitter: num(t.jitter) || 0, loss: num(t.loss) || 0 }; }), down: num(n.down) } : null
  };
}
// 글 안의 모든 결과 코드를 찾아 [{kind, data}]로
function parseCodes(text) {
  var out = [], re = /(PCBANGW?1):([A-Za-z0-9+/=\s]+?)(?=PCBANG|[^A-Za-z0-9+/=\s]|$)/g, m;
  while ((m = re.exec(text))) {
    try {
      var o = b64dec(m[2]);
      if (m[1] === 'PCBANG1') { ['gpus', 'pings', 'tcp', 'disks'].forEach(function (k) { if (o[k] && !Array.isArray(o[k])) o[k] = [o[k]]; }); var nat = sanitizeNative(o); if (nat) out.push({ kind: 'native', data: nat }); }
      else { var w = sanitizeWeb(o); if (w) out.push({ kind: 'web', data: w }); }
    } catch (e) { out.push({ kind: 'error', data: e.message }); }
  }
  return out;
}
var STORE_KEY = 'pcbang_store_v1';
var shop = store.get(STORE_KEY, {});
function saveShop() { if (!store.set(STORE_KEY, shop)) toast('브라우저 저장 공간이 부족해 매장 현황을 저장하지 못했어요. 백업을 받고 오래된 좌석을 지우세요.'); }
function normSeat(v) { v = String(v == null ? '' : v).trim().slice(0, 20); return /^\d+$/.test(v) ? String(parseInt(v, 10)) : v; }
function addToShop(items, fileSeat) {
  var errors = 0, keys = {};
  items = items.filter(function (it) { if (it.kind === 'error') { errors++; return false; } return true; });
  var seatOf = function (it) { return normSeat(it.kind === 'web' ? it.data.seat : it.data.seat); };
  // 바로 붙어 있는 웹 결과 + 점검 프로그램 결과(순서 무관)는 같은 좌석으로 묶음. 좌석 번호가 서로 다르면 묶지 않음.
  items.forEach(function (it, i) {
    if (it.pair != null) return;
    var nx = items[i + 1];
    if (nx && nx.pair == null && nx.kind !== it.kind) { var a = seatOf(it), b = seatOf(nx); if (!a || !b || a === b) { it.pair = i + 1; nx.pair = i; } }
  });
  var groups = [];
  items.forEach(function (it, i) { if (it.pair != null && it.pair < i) return; groups.push(it.pair != null ? [it, items[it.pair]] : [it]); });
  groups.forEach(function (g) {
    var w = g.filter(function (x) { return x.kind === 'web'; })[0], n = g.filter(function (x) { return x.kind === 'native'; })[0];
    var seat = (w && seatOf(w)) || (n && seatOf(n)) || '';
    var comp = n && n.data.computer ? String(n.data.computer).trim().toUpperCase().slice(0, 40) : '';
    if (!seat && !comp && fileSeat && /^\d{1,4}$/.test(fileSeat)) seat = normSeat(fileSeat);
    // 좌석·PC 이름이 모두 없으면 측정 시각+부품으로 고정 키(같은 파일을 다시 넣어도 중복 안 됨)
    var key = seat ? 'seat:' + seat : comp ? 'pc:' + comp : 'x:' + String((w && w.data.at) || (n && n.data.time) || '') + ':' + String((w && w.data.det && w.data.det.renderer) || (n && n.data.cpu) || '').slice(0, 40);
    var e = Object.prototype.hasOwnProperty.call(shop, key) ? shop[key] : { key: key, seat: seat, computer: '', at: 0 };
    if (n) {
      if (e.native && e.native.time !== n.data.time) { var ch = diffNative(e.native, n.data); if (ch.length) { e.history = (e.history || []).concat([{ at: n.data.time || '', from: e.native.time || '', ch: ch }]).slice(-10); } }
      e.native = n.data; e.computer = comp || e.computer;
    }
    if (w) e.web = w.data;
    e.seat = e.seat || seat;
    var t = Math.max(w ? +w.data.at || 0 : 0, n ? Date.parse(String(n.data.time || '').replace(' ', 'T')) || 0 : 0);
    e.at = Math.max(e.at || 0, t || Date.now());
    shop[key] = e; keys[key] = 1;
  });
  saveShop();
  return { added: Object.keys(keys).length, errors: errors };
}
// 같은 좌석의 이전 점검과 비교해 바뀐 것 (드라이버·윈도우·주사율·전원·램·부품)
function diffNative(a, b) {
  var out = [];
  var cmp = function (label, x, y) { x = x == null ? '' : String(x); y = y == null ? '' : String(y); if (x !== y && (x || y)) out.push(label + ': ' + (x || '없음') + ' → ' + (y || '없음')); };
  cmp('CPU', a.cpu, b.cpu);
  cmp('그래픽', (a.gpus || []).map(function (g) { return g.name; }).join(', '), (b.gpus || []).map(function (g) { return g.name; }).join(', '));
  cmp('그래픽 드라이버', (a.gpus || [])[0] && a.gpus[0].driver, (b.gpus || [])[0] && b.gpus[0].driver);
  cmp('RAM(GB)', a.ramGB, b.ramGB); cmp('램 속도', a.ramSpeed, b.ramSpeed);
  cmp('윈도우 빌드', a.osBuild, b.osBuild); cmp('주사율(Hz)', a.hz, b.hz); cmp('전원 관리', a.power, b.power);
  cmp('보안 부팅', a.secureBoot, b.secureBoot); cmp('TPM', a.tpm, b.tpm); cmp('네트워크', a.adapter, b.adapter);
  return out;
}
function stateOf(e) {
  var w = e.web || {};
  return { manual: w.manual || {}, det: w.det || {}, bench: w.bench || {}, dev: w.dev || {}, net: w.net || null, native: e.native || null, opt: S.opt, seat: e.seat };
}
function shopRows() {
  var all = Object.keys(shop).map(function (k) {
    var e = shop[k], st = stateOf(e), sp = spec(st), pr = problems(st);
    var n = e.native || {}, gw = (n.pings || []).filter(function (x) { return x.isGateway; })[0];
    var ext = (n.pings || []).filter(function (x) { return !x.isGateway && x.recv; });
    var webOk = st.net ? st.net.targets.filter(function (t) { return t.med != null; }) : [];
    var games = GAMES.map(function (g) { return judge(g, sp, S.opt); });
    return {
      e: e, st: st, sp: sp, pr: pr, games: games,
      seat: e.seat || e.computer || '-', at: e.at,
      cpu: sp.cpu ? sp.cpu.name : (sp.cpuRaw || '-').slice(0, 40), gpu: sp.gpu ? sp.gpu.name : softwareRenderer(sp.gpuRaw) ? '그래픽 가속 꺼짐' : (cleanRenderer(sp.gpuRaw) || '-').slice(0, 40),
      ram: sp.ram || (sp.ramAtLeast ? sp.ramAtLeast + '+' : null), hz: sp.hz,
      gw: gw && gw.recv ? gw.avg : null, gwLoss: gw ? gw.loss : null,
      ext: ext.length ? median(ext.map(function (x) { return x.avg; })) : webOk.length ? median(webOk.map(function (t) { return t.med; })) : null,
      cpuB: st.bench.cpuSingle || null, gpuB: st.bench.gpu || null,
      fails: games.filter(function (j) { return j.level === 'fail'; }).length,
      bad: pr.filter(function (p) { return p.lv === 'bad'; }).length, warn: pr.filter(function (p) { return p.lv === 'warn'; }).length
    };
  }).sort(function (a, b) { return String(a.seat).localeCompare(String(b.seat), 'ko', { numeric: true }); });
  // 같은 그래픽카드 좌석보다 측정 점수가 20% 이상 낮으면 성능 저하 의심
  all.forEach(function (r) {
    var slow = [];
    [['cpuB', 'CPU'], ['gpuB', '그래픽']].forEach(function (kk) {
      var grp = kk[0] === 'cpuB' ? 'cpu' : 'gpu';
      if (!r[grp] || r[grp] === '-' || r[grp] === '그래픽 가속 꺼짐' || /추정/.test(r[grp])) return;
      var same = all.filter(function (x) { return x[grp] === r[grp] && x[kk[0]]; }).map(function (x) { return x[kk[0]]; });
      if (same.length >= 3 && r[kk[0]] && r[kk[0]] < median(same) * 0.8) slow.push(kk[1] + ' ' + Math.round((1 - r[kk[0]] / median(same)) * 100) + '%');
    });
    if (slow.length) { r.pr.push({ id: 'slow', lv: 'warn', t: '같은 사양 좌석보다 측정 점수 낮음 (' + slow.join(', ') + ')', short: '성능 저하', fix: '발열(먼지·팬), 전원 관리 옵션, 백그라운드 프로그램, 그래픽 드라이버, 램 XMP 설정을 확인하세요.' }); r.warn++; }
  });
  return all;
}
var shopFilter = 'all', shopQuery = '';
function renderShop() {
  var rows = shopRows();
  $('#shopEmpty').hidden = rows.length > 0;
  $('#shopMain').hidden = rows.length === 0;
  if (!rows.length) return;
  // 요약
  var probCount = {};
  rows.forEach(function (r) { r.pr.forEach(function (p) { var k = p.id; probCount[k] = probCount[k] || { t: p.short || p.t, lv: p.lv, n: 0 }; probCount[k].n++; }); });
  var top = Object.keys(probCount).map(function (k) { return probCount[k]; }).sort(function (a, b) { return (b.lv === 'bad') - (a.lv === 'bad') || b.n - a.n; }).slice(0, 8);
  var badSeats = rows.filter(function (r) { return r.bad; }).length, warnSeats = rows.filter(function (r) { return !r.bad && r.warn; }).length;
  var gpuDist = {}; rows.forEach(function (r) { gpuDist[r.gpu] = (gpuDist[r.gpu] || 0) + 1; });
  var gameFail = GAMES.map(function (g, i) { return { g: g, n: rows.filter(function (r) { return r.games[i].level === 'fail'; }).length }; }).filter(function (x) { return x.n; });
  $('#shopSum').innerHTML =
    '<div class="row sumrow"><div class="stat"><b>' + rows.length + '</b><span>좌석</span></div><div class="stat"><b style="color:var(--bad)">' + badSeats + '</b><span>바로 고칠 좌석</span></div><div class="stat"><b style="color:var(--warn)">' + warnSeats + '</b><span>확인 권장 좌석</span></div><div class="stat"><b style="color:var(--ok)">' + (rows.length - badSeats - warnSeats) + '</b><span>정상 좌석</span></div></div>' +
    (top.length ? '<div class="row">' + top.map(function (p) { return '<span class="pill ' + p.lv + '">' + esc(p.t) + ' ' + p.n + '석</span>'; }).join('') + '</div>' : '') +
    (gameFail.length ? '<div class="small">사양 부족 좌석: ' + gameFail.map(function (x) { return esc(x.g.short || x.g.name) + ' ' + x.n + '석'; }).join(' · ') + '</div>' : '<div class="small muted">모든 좌석이 인기 10개 게임 최소 사양 이상이에요.</div>') +
    '<div class="xs muted">그래픽카드 구성: ' + Object.keys(gpuDist).map(function (k) { return esc(k) + ' ' + gpuDist[k]; }).join(' · ') + '</div>';
  // 같은 그래픽 좌석 사이에서 중간값보다 20% 이상 낮으면 표시
  function low(r, key) {
    var grp = key === 'cpuB' ? 'cpu' : 'gpu';
    if (!r[grp] || r[grp] === '-' || r[grp] === '그래픽 가속 꺼짐') return '';
    var same = rows.filter(function (x) { return x[grp] === r[grp] && x[key]; }).map(function (x) { return x[key]; });
    if (same.length < 3 || !r[key]) return '';
    return r[key] < median(same) * 0.8 ? ' class="num lowv" title="같은 그래픽 좌석 중간값보다 20% 이상 낮음"' : '';
  }
  var q = shopQuery.toLowerCase();
  var shown = rows.filter(function (r) {
    if (shopFilter === 'bad' && !r.bad) return false;
    if (shopFilter === 'issue' && !r.bad && !r.warn) return false;
    if (q && (String(r.seat) + ' ' + r.cpu + ' ' + r.gpu + ' ' + r.pr.map(function (p) { return p.t; }).join(' ')).toLowerCase().indexOf(q) < 0) return false;
    return true;
  });
  $('#shopTbl tbody').innerHTML = shown.map(function (r) {
    var d = new Date(r.at || Date.now());
    var status = r.bad ? '<span class="pill bad">고칠 것 ' + r.bad + '</span>' : r.warn ? '<span class="pill warn">확인 ' + r.warn + '</span>' : '<span class="pill ok">정상</span>';
    var src = (r.e.native ? '<span class="pill info" title="윈도우 점검 프로그램 결과 있음">PC</span>' : '') + (r.e.web ? '<span class="pill" title="브라우저 측정 결과 있음">웹</span>' : '');
    return '<tr data-key="' + esc(r.e.key) + '"><td><button class="linkbtn" type="button" data-open="' + esc(r.e.key) + '"><b>' + esc(r.seat) + '</b></button></td><td>' + status + '</td><td class="xs">' + (d.getMonth() + 1) + '/' + d.getDate() + ' ' + String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0') + ' ' + src + '</td>' +
      '<td class="xs">' + esc(r.cpu) + '</td><td class="xs">' + esc(r.gpu) + '</td><td class="num">' + (r.ram ? esc(r.ram) : '-') + '</td>' +
      '<td class="num' + (r.hz && r.hz <= 61 ? ' badv' : '') + '">' + (r.hz || '-') + '</td>' +
      '<td class="num' + (r.gw != null && (r.gw > 3 || r.gwLoss > 0) ? ' badv' : '') + '">' + (r.gw != null ? fmt(r.gw, 1) + 'ms' + (r.gwLoss ? ' (' + r.gwLoss + '%)' : '') : '-') + '</td>' +
      '<td class="num">' + (r.ext != null ? fmt(r.ext) + 'ms' : '-') + '</td>' +
      '<td' + (low(r, 'cpuB') || ' class="num"') + '>' + fmt(r.cpuB) + '</td><td' + (low(r, 'gpuB') || ' class="num"') + '>' + fmt(r.gpuB) + '</td>' +
      '<td class="xs">' + r.pr.slice(0, 4).map(function (p) { return '<span class="pill ' + p.lv + '">' + esc(p.short || p.t) + '</span>'; }).join(' ') + (r.pr.length > 4 ? ' +' + (r.pr.length - 4) : '') + '</td>' +
      '<td class="noprint"><button class="btn sm" type="button" data-del="' + esc(r.e.key) + '" aria-label="' + esc(r.seat) + ' 삭제">삭제</button></td></tr>';
  }).join('');
  $('#shopCount').textContent = shown.length + '/' + rows.length + '석 표시';
}
function seatReportHTML(r) {
  var tgt = targetFps(S.opt), n = r.e.native || {};
  var d = new Date(r.at || Date.now());
  var h = '<div class="stack"><div class="row between"><div class="h2">' + esc(r.seat) + (/^\d+$/.test(String(r.seat)) ? '번 좌석' : '') + '</div><span class="small muted">' + d.toLocaleString('ko-KR') + '</span></div>' +
    '<dl class="kv"><dt>CPU</dt><dd>' + esc(r.cpu) + (n.cores ? ' · ' + n.cores + '코어 ' + n.threads + '스레드' : '') + '</dd><dt>그래픽</dt><dd>' + esc(r.gpu) + (r.sp.vram ? ' · ' + fmt(r.sp.vram, 0) + 'GB' : '') + '</dd><dt>RAM</dt><dd>' + (r.ram ? esc(r.ram) + 'GB' : '-') + (n.ramSpeed ? ' · ' + n.ramSpeed + 'MT/s' : '') + '</dd><dt>운영체제</dt><dd>' + esc(n.osName || (r.st.det && r.st.det.osName) || '-') + '</dd><dt>모니터</dt><dd>' + (r.hz ? r.hz + 'Hz' : '-') + '</dd>' +
    (n.adapter ? '<dt>네트워크</dt><dd>' + esc(n.adapter) + '</dd>' : '') + (r.gw != null ? '<dt>게이트웨이</dt><dd>' + fmt(r.gw, 1) + 'ms · 손실 ' + (r.gwLoss || 0) + '%</dd>' : '') + (r.ext != null ? '<dt>외부 지연</dt><dd>' + fmt(r.ext) + 'ms</dd>' : '') + (function () { var x = []; devKv(n, function (k, v) { x.push('<dt>' + k.replace(/^· /, '') + '</dt><dd>' + v + '</dd>'); }); return x.join(''); })() + '</dl>';
  if (r.e.history && r.e.history.length) h += '<div class="h3">지난 점검과 달라진 점</div><ul class="fixlist small">' + r.e.history.slice().reverse().map(function (x) { return '<li><b>' + esc(x.from) + ' → ' + esc(x.at) + '</b><br>' + x.ch.map(esc).join('<br>') + '</li>'; }).join('') + '</ul>';
  h += r.pr.length ? '<div class="h3">조치할 것</div><ol class="fixlist">' + r.pr.map(function (p) { return '<li><span class="pill ' + p.lv + '">' + (p.lv === 'bad' ? '고칠 것' : p.lv === 'warn' ? '확인' : '참고') + '</span> <b>' + esc(p.t) + '</b>' + (p.fix ? '<div class="small muted">' + esc(p.fix) + '</div>' : '') + '</li>'; }).join('') + '</ol>' : '<div class="okbox">문제가 없어요.</div>';
  h += '<div class="h3">게임별 판정 (' + S.opt.res + 'p · ' + ({ low: '낮음', mid: '중간', high: '높음' })[S.opt.preset] + ')</div><div class="tblwrap"><table><tbody>' + GAMES.map(function (g, i) { var j = r.games[i], lv = LV[j.level]; return '<tr><td>' + g.rank + '. ' + esc(g.name) + '</td><td><span class="pill ' + lv[0] + '">' + lv[1] + '</span></td><td class="num">' + (j.fps != null ? '약 ' + fmt(j.fps) + 'fps' : '-') + '</td></tr>'; }).join('') + '</tbody></table></div></div>';
  return h;
}
function openSeat(key) {
  var r = shopRows().filter(function (x) { return x.e.key === key; })[0]; if (!r) return;
  $('#seatDlgBody').innerHTML = seatReportHTML(r);
  var dl = $('#seatDlg'); dl.dataset.key = key;
  if (dl.showModal) dl.showModal(); else dl.setAttribute('open', '');
}
function printHTML(html, title) {
  var pa = $('#printArea'); pa.innerHTML = '<h1 style="font-size:20px;margin:0 0 8px">' + esc(title) + '</h1>' + html;
  document.body.classList.add('printing');
  var done = function () { document.body.classList.remove('printing'); pa.innerHTML = ''; window.removeEventListener('afterprint', done); };
  window.addEventListener('afterprint', done);
  window.print();
  if (!('onafterprint' in window)) setTimeout(done, 1500);
}
// 가져오기
async function importText(text, fileSeat) {
  var items = parseCodes(text);
  if (!items.length) return { added: 0, errors: 1 };
  return addToShop(items, fileSeat);
}
$('#shopImportBtn').addEventListener('click', async function () {
  var r = await importText($('#shopPaste').value); $('#shopPaste').value = '';
  toast(r.added ? '좌석 ' + r.added + '개 결과를 불러왔어요' + (r.errors ? ' (' + r.errors + '개 실패)' : '') : '결과 코드를 찾지 못했어요'); renderShop();
});
async function importFiles(files) {
  var added = 0, errors = 0;
  for (var i = 0; i < files.length; i++) {
    var f = files[i]; if (f.size > 2e6) { errors++; continue; }
    var m = f.name.match(/seat[-_ ]?(\d{1,4})\b/i);
    var r = await importText(await f.text(), m ? m[1] : ''); added += r.added; errors += r.errors;
  }
  toast(added ? '좌석 ' + added + '개 결과를 불러왔어요' + (errors ? ' (' + errors + '개 실패)' : '') : '결과 코드를 찾지 못했어요');
  renderShop();
}
$('#shopFile').addEventListener('change', function () { var f = Array.prototype.slice.call(this.files); this.value = ''; importFiles(f); });
(function () {
  var dz = $('#shopDrop');
  ['dragenter', 'dragover'].forEach(function (ev) { dz.addEventListener(ev, function (e) { e.preventDefault(); dz.classList.add('active'); }); });
  ['dragleave', 'drop'].forEach(function (ev) { dz.addEventListener(ev, function (e) { e.preventDefault(); dz.classList.remove('active'); }); });
  dz.addEventListener('drop', function (e) { if (e.dataTransfer && e.dataTransfer.files.length) importFiles(Array.prototype.slice.call(e.dataTransfer.files)); });
})();
$('#shopAddThis').addEventListener('click', function () {
  if (!S.bench.cpuSingle && !S.bench.gpu && !S.dev.hzInfo && !S.native && !Object.keys(S.dev.chk || {}).length && !S.net) { toast('먼저 점검 시작이나 장비 테스트를 하세요'); return; }
  addToShop(parseCodes(seatCodes())); toast('이 PC 결과를 매장 현황에 넣었어요'); renderShop();
});
$('#shopFilter').addEventListener('change', function () { shopFilter = this.value; renderShop(); });
$('#shopSearch').addEventListener('input', function () { shopQuery = this.value.trim(); renderShop(); });
$('#shopTbl').addEventListener('click', function (e) {
  var o = e.target.closest('[data-open]'); if (o) { openSeat(o.dataset.open); return; }
  var d = e.target.closest('[data-del]');
  if (d && confirm('이 좌석 결과를 지울까요?')) { delete shop[d.dataset.del]; saveShop(); renderShop(); }
});
$('#shopBackup').addEventListener('click', function () {
  var n = Object.keys(shop).length; if (!n) { toast('백업할 좌석이 없어요'); return; }
  downloadText('pc방-매장현황-백업-' + new Date().toISOString().slice(0, 10) + '.json', JSON.stringify({ kind: 'pcbang-shop', v: 1, at: Date.now(), shop: shop }), 'application/json');
});
$('#shopRestore').addEventListener('change', async function () {
  var f = this.files[0]; this.value = ''; if (!f) return;
  try {
    var o = JSON.parse(await f.text()); if (!o || o.kind !== 'pcbang-shop' || !o.shop || typeof o.shop !== 'object' || Array.isArray(o.shop)) throw new Error('매장 현황 백업 파일이 아니에요');
    var n = 0;
    Object.keys(o.shop).forEach(function (k) {
      if (!/^(seat|pc|x):/.test(k)) return;
      var e = o.shop[k]; if (!e || typeof e !== 'object') return;
      var clean = { key: String(k).slice(0, 60), seat: String(e.seat || '').slice(0, 20), computer: String(e.computer || '').slice(0, 40), at: +e.at || Date.now(), native: e.native ? sanitizeNative(e.native) : undefined, web: e.web ? sanitizeWeb(e.web) : undefined,
        history: Array.isArray(e.history) ? e.history.slice(-10).map(function (h) { return { at: String(h.at || '').slice(0, 30), from: String(h.from || '').slice(0, 30), ch: Array.isArray(h.ch) ? h.ch.slice(0, 20).map(function (x) { return String(x).slice(0, 200); }) : [] }; }) : undefined };
      if (!clean.native && !clean.web) return;
      var cur = shop[clean.key]; if (!cur || (cur.at || 0) <= clean.at) { shop[clean.key] = clean; n++; }
    });
    saveShop(); renderShop(); toast('좌석 ' + n + '개를 백업에서 불러왔어요');
  } catch (err) { toast('불러오지 못했어요: ' + err.message); }
});
$('#shopClear').addEventListener('click', function () { var n = Object.keys(shop).length; if (!n) return; if (confirm('매장 현황의 좌석 ' + n + '개를 모두 지울까요?')) { shop = {}; saveShop(); renderShop(); } });
$('#shopCsv').addEventListener('click', function () {
  var rows = shopRows();
  var head = ['좌석', '점검 시각', '상태', 'CPU', '그래픽', 'RAM(GB)', '주사율(Hz)', '게이트웨이(ms)', '게이트웨이 손실(%)', '외부 지연(ms)', 'CPU 점수', 'GPU 점수', '사양 부족 게임 수', '문제'];
  var lines = [head].concat(rows.map(function (r) { return [r.seat, new Date(r.at || Date.now()).toLocaleString('ko-KR'), r.bad ? '고칠 것' : r.warn ? '확인' : '정상', r.cpu, r.gpu, r.ram, r.hz, r.gw, r.gwLoss, r.ext != null ? Math.round(r.ext) : '', r.cpuB, r.gpuB, r.fails, r.pr.map(function (p) { return p.t; }).join(' / ')]; }));
  downloadText('pc방-매장점검-' + new Date().toISOString().slice(0, 10) + '.csv', '﻿' + lines.map(function (l) { return l.map(csvCell).join(','); }).join('\r\n'), 'text/csv;charset=utf-8');
});
function csvCell(v) { v = v == null ? '' : String(v); if (/^[=+\-@\t\r]/.test(v)) v = "'" + v; return /[",\r\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v; }
function downloadText(name, text, type) {
  var blob = new Blob([text], { type: type || 'text/plain;charset=utf-8' });
  var a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = name; document.body.appendChild(a); a.click(); setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 500);
}
$('#shopPrint').addEventListener('click', function () {
  var rows = shopRows();
  var html = $('#shopSum').innerHTML + '<table class="ptable"><thead><tr><th>좌석</th><th>CPU</th><th>그래픽</th><th>RAM</th><th>Hz</th><th>게이트웨이</th><th>조치할 것</th></tr></thead><tbody>' +
    rows.map(function (r) { return '<tr><td><b>' + esc(r.seat) + '</b></td><td>' + esc(r.cpu) + '</td><td>' + esc(r.gpu) + '</td><td>' + (r.ram ? esc(r.ram) : '-') + '</td><td>' + (r.hz || '-') + '</td><td>' + (r.gw != null ? fmt(r.gw, 1) + 'ms' : '-') + '</td><td>' + (r.pr.length ? r.pr.map(function (p) { return (p.lv === 'bad' ? '■ ' : '□ ') + esc(p.t); }).join('<br>') : '정상') + '</td></tr>'; }).join('') + '</tbody></table>';
  printHTML(html, 'PC방 매장 점검 보고서 · ' + new Date().toLocaleDateString('ko-KR'));
});
$('#seatDlgClose').addEventListener('click', function () { $('#seatDlg').close ? $('#seatDlg').close() : $('#seatDlg').removeAttribute('open'); });
$('#seatDlgPrint').addEventListener('click', function () { var b = $('#seatDlgBody').innerHTML; $('#seatDlg').close && $('#seatDlg').close(); printHTML(b, 'PC방 좌석 점검 보고서'); });
// 이 좌석 결과 내보내기
$('#codeCopy').addEventListener('click', function () {
  var t = seatCodes();
  (navigator.clipboard ? navigator.clipboard.writeText(t) : Promise.reject()).then(function () { toast('결과 코드를 복사했어요'); }, function () { prompt('아래 코드를 복사하세요', t); });
});
$('#codeSave').addEventListener('click', function () {
  var nm = S.seat ? 'seat-' + S.seat.replace(/[^0-9A-Za-z가-힣_-]/g, '') : 'pcbang-result-' + new Date().toISOString().replace(/[-:T]/g, '').slice(0, 12);
  downloadText(nm + '.txt', seatCodes() + '\r\n');
});
$('#copyRep').addEventListener('click', function () {
  var st = S, sp = spec(), pr = problems();
  var t = ['[PC방 게임 점검] ' + (S.seat ? S.seat + '번 좌석 · ' : '') + new Date().toLocaleString('ko-KR'),
    'CPU: ' + (sp.cpu ? sp.cpu.name : '-') + ' / 그래픽: ' + (sp.gpu ? sp.gpu.name : '-') + ' / RAM: ' + (sp.ram || sp.ramAtLeast || '-') + 'GB / 모니터: ' + (sp.hz || '-') + 'Hz',
    '조치할 것: ' + (pr.length ? pr.map(function (p) { return p.t; }).join(' / ') : '없음'), '게임:'].concat(GAMES.map(function (g) { var j = judge(g, sp, S.opt); return ' ' + g.rank + '. ' + g.name + ' — ' + LV[j.level][1] + (j.fps != null ? ' · 약 ' + j.fps + 'fps' : ''); })).join('\n');
  (navigator.clipboard ? navigator.clipboard.writeText(t) : Promise.reject()).then(function () { toast('복사했어요'); }, function () { prompt('아래 글을 복사하세요', t); });
});
$('#seatIn').addEventListener('change', function () { S.seat = this.value.trim(); save(); seatPill(); });

/* ---------------- 시작 ---------------- */
try { var qs = new URLSearchParams(location.search).get('seat'); if (qs) { S.seat = qs.slice(0, 20); save(); } } catch (e) {}
fillLists(); seatPill();
if (S.native) S.native = sanitizeNative(S.native);
detect().then(function () { renderSummary(); renderSpec(); var t = $('.tabs [aria-selected="true"]'); if (t && t.dataset.tab === 'games') renderGames(); });
renderAllOut();
var h = (location.hash || '').slice(1);
if (h && $('[data-panel="' + h + '"]')) showTab(h);
if ('serviceWorker' in navigator && location.protocol !== 'file:') navigator.serviceWorker.register('../sw.js').catch(function () {});
// 테스트·디버그용
window.__pcbang = { matchGpu: matchGpu, matchCpu: matchCpu, cleanRenderer: cleanRenderer, judge: judge, spec: spec, decodeNative: decodeNative, S: S };
})();

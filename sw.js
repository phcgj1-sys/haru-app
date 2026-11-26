// 하루 학습 — 오프라인용 서비스 워커. 파일을 바꾸면 VERSION을 올리세요(scratchpad gen_sw.py가 올려 줘요).
const VERSION = 'haru-v69';
// 한 번 연 앱 파일은 이 캐시에 두고, 버전이 바뀌어도 지우지 않아요. 열 때마다 뒤에서 새 파일을 받아 바꿔 둬요.
const APPCACHE = 'haru-app';
const FONTCACHE = 'haru-fonts';
const CORE = ['./', './index.html', './manifest.webmanifest', './icons/icon-192.png', './icons/icon-512.png', './privacy.html', './terms.html', './notices.html', './report.js'];
// '모든 수업 오프라인 저장'에서 받는 파일 목록 (scratchpad gen_sw.py가 저장소 파일로 만들어요)
const FILES = [
  "./index.html",
  "./agent/index.html",
  "./agent/lessons.js",
  "./ai/index.html",
  "./ai/lessons.js",
  "./auto/index.html",
  "./auto/lessons.js",
  "./basics/index.html",
  "./basics/lessons.js",
  "./cap/index.html",
  "./cap/lessons.js",
  "./claude/index.html",
  "./claude/lessons.js",
  "./cv/index.html",
  "./cv/lessons.js",
  "./en/content.js",
  "./en/dialogues.js",
  "./en/index.html",
  "./en/scenes.js",
  "./en/sentences.js",
  "./en/words.js",
  "./en/words2.js",
  "./excel/index.html",
  "./excel/lessons.js",
  "./favicon.ico",
  "./fonts/extra/extra.css",
  "./fonts/pretendard/pretendard.css",
  "./found/index.html",
  "./found/lessons.js",
  "./gen/index.html",
  "./gen/lessons.js",
  "./github/index.html",
  "./github/lessons.js",
  "./homepage/index.html",
  "./homepage/lessons.js",
  "./icons/apple-touch-icon.png",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
  "./icons/icon-maskable-192.png",
  "./icons/icon-maskable-512.png",
  "./infra/index.html",
  "./infra/lessons.js",
  "./ja/content.js",
  "./ja/dialogues.js",
  "./ja/index.html",
  "./ja/lang.js",
  "./ja/sentences.js",
  "./ja/words.js",
  "./linux/index.html",
  "./linux/lessons.js",
  "./listen/index.html",
  "./listen/lessons.js",
  "./llm/index.html",
  "./llm/lessons.js",
  "./manifest.webmanifest",
  "./media/index.html",
  "./media/lessons.js",
  "./ml/index.html",
  "./ml/lessons.js",
  "./mm/index.html",
  "./mm/lessons.js",
  "./money/index.html",
  "./money/lessons.js",
  "./multi/index.html",
  "./multi/lessons.js",
  "./network/index.html",
  "./network/lessons.js",
  "./nlp/index.html",
  "./nlp/lessons.js",
  "./notices.html",
  "./plan/data/agent.js",
  "./plan/data/ai.js",
  "./plan/data/auto.js",
  "./plan/data/basics.js",
  "./plan/data/cap.js",
  "./plan/data/claude.js",
  "./plan/data/cv.js",
  "./plan/data/en.js",
  "./plan/data/excel.js",
  "./plan/data/found.js",
  "./plan/data/gen.js",
  "./plan/data/github.js",
  "./plan/data/homepage.js",
  "./plan/data/infra.js",
  "./plan/data/ja.js",
  "./plan/data/linux.js",
  "./plan/data/listen.js",
  "./plan/data/llm.js",
  "./plan/data/media.js",
  "./plan/data/ml.js",
  "./plan/data/mm.js",
  "./plan/data/money.js",
  "./plan/data/multi.js",
  "./plan/data/network.js",
  "./plan/data/nlp.js",
  "./plan/data/re.js",
  "./plan/data/rl.js",
  "./plan/data/safety.js",
  "./plan/data/script.js",
  "./plan/data/sheets.js",
  "./plan/data/th.js",
  "./plan/data/tools.js",
  "./plan/data/winpc.js",
  "./plan/data/writing.js",
  "./plan/data/youtube.js",
  "./plan/index.html",
  "./privacy.html",
  "./re/index.html",
  "./re/lessons.js",
  "./report.js",
  "./rl/index.html",
  "./rl/lessons.js",
  "./safety/index.html",
  "./safety/lessons.js",
  "./script/index.html",
  "./script/lessons.js",
  "./search-index.js",
  "./sheets/index.html",
  "./sheets/lessons.js",
  "./sum/data/agent.js",
  "./sum/data/ai.js",
  "./sum/data/auto.js",
  "./sum/data/basics.js",
  "./sum/data/cap.js",
  "./sum/data/claude.js",
  "./sum/data/cv.js",
  "./sum/data/en.js",
  "./sum/data/excel.js",
  "./sum/data/found.js",
  "./sum/data/gen.js",
  "./sum/data/github.js",
  "./sum/data/homepage.js",
  "./sum/data/infra.js",
  "./sum/data/ja.js",
  "./sum/data/linux.js",
  "./sum/data/listen.js",
  "./sum/data/llm.js",
  "./sum/data/media.js",
  "./sum/data/ml.js",
  "./sum/data/mm.js",
  "./sum/data/money.js",
  "./sum/data/multi.js",
  "./sum/data/network.js",
  "./sum/data/nlp.js",
  "./sum/data/re.js",
  "./sum/data/rl.js",
  "./sum/data/safety.js",
  "./sum/data/script.js",
  "./sum/data/sheets.js",
  "./sum/data/th.js",
  "./sum/data/tools.js",
  "./sum/data/winpc.js",
  "./sum/data/writing.js",
  "./sum/data/youtube.js",
  "./sum/index.html",
  "./terms.html",
  "./th/content.js",
  "./th/dialogues.js",
  "./th/index.html",
  "./th/lang.js",
  "./th/sentences.js",
  "./th/words.js",
  "./tools/index.html",
  "./tools/lessons.js",
  "./winpc/index.html",
  "./winpc/lessons.js",
  "./writing/index.html",
  "./writing/lessons.js",
  "./youtube/index.html",
  "./youtube/lessons.js"
];
self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(CORE)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  // 예전 버전 캐시(haru-vNN)에 있던 앱 파일은 지우기 전에 APPCACHE로 옮겨서, 업데이트 뒤에도 오프라인으로 열리게 해요
  e.waitUntil((async () => {
    const keys = await caches.keys();
    const app = await caches.open(APPCACHE);
    for (const k of keys) {
      if (k === VERSION || k === APPCACHE || k === FONTCACHE) continue;
      if (/^haru-v\d+$/.test(k)) {
        try { const old = await caches.open(k); for (const req of await old.keys()) { if (!(await app.match(req))) { const res = await old.match(req); if (res) await app.put(req, res); } } } catch (err) {}
      }
      await caches.delete(k);
    }
    await self.clients.claim();
  })());
});
function offlinePage() {
  const home = self.registration.scope + 'index.html';
  const html = '<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>인터넷 연결이 필요해요 · 하루 학습</title>'
    + '<link rel="stylesheet" href="' + self.registration.scope + 'fonts/pretendard/pretendard.css">'
    + '<style>:root{color-scheme:light dark}body{margin:0;font-family:"Pretendard Variable",Pretendard,system-ui,sans-serif;background:#F7F7F5;color:#111;line-height:1.6}@media (prefers-color-scheme: dark){body{background:#0F0F10;color:#F2F2F2}.b2{background:#232326!important;color:#F2F2F2!important}}main{max-width:520px;margin:0 auto;padding:48px 20px}h1{font-size:24px;margin:0 0 10px}p{margin:8px 0;font-size:16px}.row{display:flex;gap:10px;flex-wrap:wrap;margin-top:20px}a,button{display:inline-flex;align-items:center;justify-content:center;min-height:48px;padding:0 18px;border-radius:12px;font:inherit;font-weight:700;text-decoration:none;border:0;cursor:pointer}.b1{background:#111;color:#fff}@media (prefers-color-scheme: dark){.b1{background:#F2F2F2;color:#111}}.b2{background:#EFEFEB;color:#111}</style></head>'
    + '<body><main><h1>인터넷 연결이 필요해요</h1><p>이 화면은 아직 이 기기에 저장되지 않았어요.</p><p>인터넷에 연결된 상태로 한 번 열면, 다음부터는 인터넷 없이도 열려요. 홈 화면의 \'모든 수업 오프라인 저장\'을 누르면 모든 앱을 한 번에 저장할 수 있어요.</p>'
    + '<div class="row"><button class="b1" onclick="location.reload()">다시 시도</button><a class="b2" href="' + home + '">하루 학습 홈</a></div></main></body></html>';
  return new Response(html, { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' } });
}
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== location.origin) return;
  // 글꼴: 캐시 먼저(바뀌지 않는 파일)
  if (url.pathname.includes('/fonts/')) {
    e.respondWith(caches.open(FONTCACHE).then(async c => { const hit = await c.match(req); if (hit) return hit; try { const res = await fetch(req); if (res.ok) c.put(req, res.clone()); return res; } catch (err) { return Response.error(); } }));
    return;
  }
  // 앱 파일: 저장해 둔 것을 바로 보여 주고, 뒤에서 새 파일을 받아 바꿔 둬요
  e.respondWith((async () => {
    const hit = await caches.match(req, { ignoreSearch: true });
    const net = fetch(req).then(async res => {
      if (res.ok && res.type === 'basic' && !res.redirected) { const c = await caches.open(APPCACHE); await c.put(req, res.clone()); }
      return res;
    });
    if (hit) { e.waitUntil(net.catch(() => {})); return hit; }
    try { return await net; }
    catch (err) { return req.mode === 'navigate' ? offlinePage() : Response.error(); }
  })());
});
// 허브의 '모든 수업 오프라인 저장': FILES를 받아 APPCACHE에 넣고 진행 상황을 알려 줘요
self.addEventListener('message', e => {
  const d = e.data || {};
  if (d.type !== 'cache-all') return;
  const src = e.source;
  e.waitUntil((async () => {
    const c = await caches.open(APPCACHE);
    let done = 0, failed = 0;
    const total = FILES.length;
    const tell = (fin) => { try { src && src.postMessage({ type: 'cache-progress', done, failed, total, fin: !!fin }); } catch (err) {} };
    const queue = FILES.slice();
    async function worker() {
      while (queue.length) {
        const f = queue.shift();
        try { const res = await fetch(new Request(f, { cache: 'no-cache' })); if (res.ok) await c.put(f, res); else failed++; } catch (err) { failed++; }
        done++;
        if (done % 8 === 0) tell(false);
      }
    }
    await Promise.all([worker(), worker(), worker(), worker()]);
    tell(true);
  })());
});

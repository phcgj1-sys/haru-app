// 하루 학습 — 오프라인용 서비스 워커. 파일을 바꾸면 VERSION을 올리세요.
const VERSION = 'haru-v11';
const FILES = [
  './', './index.html', './manifest.webmanifest', './icons/icon-192.png', './icons/icon-512.png',
  './en/index.html', './en/words.js', './en/words2.js', './en/content.js', './en/sentences.js', './en/dialogues.js', './en/scenes.js',
  './ja/index.html', './ja/lang.js', './ja/words.js', './ja/content.js', './ja/sentences.js', './ja/dialogues.js',
  './th/index.html', './th/lang.js', './th/words.js', './th/content.js', './th/sentences.js', './th/dialogues.js',
  './claude/index.html', './claude/lessons.js',
  './excel/index.html', './excel/lessons.js',
  './youtube/index.html', './youtube/lessons.js',
  './homepage/index.html', './homepage/lessons.js',
  './money/index.html', './money/lessons.js',
  './writing/index.html', './writing/lessons.js',
  './media/index.html', './media/lessons.js',
  './basics/index.html', './basics/lessons.js',
  './listen/index.html', './listen/lessons.js',
  './sheets/index.html', './sheets/lessons.js'
];
self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(FILES)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== VERSION && k !== 'haru-fonts').map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET') return;
  // 글꼴: 캐시 먼저, 없으면 네트워크 후 저장
  if (url.hostname === 'fonts.googleapis.com' || url.hostname === 'fonts.gstatic.com') {
    e.respondWith(caches.open('haru-fonts').then(async c => { const hit = await c.match(e.request); if (hit) return hit; try { const res = await fetch(e.request); if (res.ok) c.put(e.request, res.clone()); return res; } catch (err) { return hit || Response.error(); } }));
    return;
  }
  if (url.origin !== location.origin) return;
  // 앱 파일: 캐시 먼저, 없으면 네트워크
  e.respondWith(caches.match(e.request, { ignoreSearch: true }).then(hit => hit || fetch(e.request).then(res => { if (res.ok) caches.open(VERSION).then(c => c.put(e.request, res.clone())); return res; }).catch(() => caches.match('./index.html'))));
});

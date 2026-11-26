// 하루 학습 — 내용 오류 알리기
// 앱은 아무것도 보내지 않아요. 사용자가 고른 방법(GitHub 이슈, 메일, 복사)으로만 전해져요.
(function () {
  'use strict';
  var REPO = 'https://github.com/phcgj1-sys/haru-app';
  // 문의용 이메일이 생기면 여기에 넣으세요(예: 'help@example.com'). 비어 있으면 메일 버튼을 숨겨요.
  var CONTACT = '';
  var css = '.hr-back{position:fixed;inset:0;z-index:80;background:rgba(0,0,0,.45);display:flex;align-items:flex-end;justify-content:center}'
    + '.hr-sheet{width:100%;max-width:560px;max-height:88vh;overflow:auto;background:var(--surface,#fff);color:var(--fg,#111);border-radius:18px 18px 0 0;padding:18px 16px calc(18px + env(safe-area-inset-bottom,0px));box-shadow:0 -8px 30px rgba(0,0,0,.25);font-size:15px;line-height:1.55}'
    + '.hr-sheet h2{margin:0 0 4px;font-size:19px}.hr-sheet .hr-sub{margin:0 0 12px;color:var(--muted,#666);font-size:13.5px}'
    + '.hr-loc{background:var(--soft,#efefeb);border-radius:12px;padding:10px 12px;font-size:13.5px;white-space:pre-wrap;word-break:keep-all;overflow-wrap:anywhere;margin:0 0 10px}'
    + '.hr-sheet label{display:block;font-weight:700;font-size:14px;margin:4px 0 6px}'
    + '.hr-sheet textarea{width:100%;min-height:84px;border:1px solid var(--line,#ddd);border-radius:12px;padding:10px;font:inherit;font-size:15px;background:var(--bg,#fff);color:inherit;box-sizing:border-box}'
    + '.hr-row{display:flex;flex-wrap:wrap;gap:8px;margin-top:12px}'
    + '.hr-row a,.hr-row button{display:inline-flex;align-items:center;justify-content:center;min-height:46px;padding:0 14px;border-radius:12px;border:0;font:inherit;font-weight:700;font-size:15px;text-decoration:none;cursor:pointer}'
    + '.hr-p{background:var(--fg,#111);color:var(--bg,#fff)}.hr-g{background:var(--soft,#efefeb);color:var(--fg,#111)}'
    + '.hr-note{margin:10px 0 0;color:var(--muted,#666);font-size:12.5px}.hr-msg{margin:8px 0 0;font-weight:700;font-size:13.5px}';
  function addCss() { if (document.getElementById('hr-css')) return; var s = document.createElement('style'); s.id = 'hr-css'; s.textContent = css; document.head.appendChild(s); }
  function esc(t) { return String(t == null ? '' : t).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
  function today() { var d = new Date(); return d.getFullYear() + '-' + ('0' + (d.getMonth() + 1)).slice(-2) + '-' + ('0' + d.getDate()).slice(-2); }
  function locText(c) {
    var L = [];
    L.push('앱: ' + (c.appTitle || '하루 학습') + (c.app ? ' (' + c.app + ')' : ''));
    if (c.lesson) L.push('수업: ' + (c.lessonTitle || '') + ' (' + c.lesson + ')');
    if (c.qn) L.push('문제 ' + c.qn + ': ' + (c.question || ''));
    if (c.answer) L.push('앱이 정답으로 표시한 것: ' + c.answer);
    if (c.item) L.push('항목: ' + c.item);
    return L.join('\n');
  }
  function fullText(c, note) {
    return locText(c) + '\n무엇이 틀렸나요: ' + (note || '(적지 않음)') + '\n날짜: ' + today() + '\n주소: ' + location.pathname;
  }
  function copy(txt, ok, bad) {
    function fb() { var ta = document.createElement('textarea'); ta.value = txt; ta.setAttribute('readonly', ''); ta.style.cssText = 'position:fixed;top:0;left:0;width:1px;height:1px;opacity:0'; document.body.appendChild(ta); try { ta.focus({ preventScroll: true }); } catch (e) {} ta.select(); var r = false; try { r = document.execCommand('copy'); } catch (e) {} document.body.removeChild(ta); if (r) ok(); else bad(); }
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(txt).then(ok, fb); else fb();
  }
  function open(c) {
    c = c || {};
    addCss();
    var prev = document.activeElement;
    var back = document.createElement('div'); back.className = 'hr-back';
    var title = (c.lessonTitle ? '[' + (c.appTitle || '') + '] ' + c.lessonTitle : '[' + (c.appTitle || '하루 학습') + ']') + (c.qn ? ' 문제 ' + c.qn : '') + ' 내용 오류';
    back.innerHTML = '<div class="hr-sheet" role="dialog" aria-modal="true" aria-labelledby="hr-h">'
      + '<h2 id="hr-h" tabindex="-1">틀린 내용 알리기</h2><p class="hr-sub">고쳐서 모든 사람의 앱에 반영할게요. 고마워요!</p>'
      + '<div class="hr-loc">' + esc(locText(c)) + '</div>'
      + '<label for="hr-note">무엇이 틀렸나요? (적지 않아도 돼요)</label><textarea id="hr-note" placeholder="예: 정답이 3번이 아니라 2번인 것 같아요. 2026년부터 기준이 바뀌었어요."></textarea>'
      + '<div class="hr-row"><a class="hr-p" id="hr-gh" target="_blank" rel="noopener">GitHub에 올리기</a>'
      + (CONTACT ? '<a class="hr-g" id="hr-mail">메일로 보내기</a>' : '')
      + '<button type="button" class="hr-g" id="hr-copy">내용 복사</button><button type="button" class="hr-g" id="hr-close">닫기</button></div>'
      + '<p class="hr-msg" id="hr-msg" role="status" aria-live="polite"></p>'
      + '<p class="hr-note">하루 학습은 이 내용을 저장하거나 보내지 않아요. 고른 방법으로만 전해져요. GitHub에 올리려면 GitHub 계정이 필요해요. 계정이 없으면 \'내용 복사\'를 눌러 앱 스토어 문의 메일 등으로 보내 주세요.</p></div>';
    document.body.appendChild(back);
    var note = back.querySelector('#hr-note'), gh = back.querySelector('#hr-gh'), mail = back.querySelector('#hr-mail'), msg = back.querySelector('#hr-msg');
    function sync() {
      var t = fullText(c, note.value.trim());
      gh.href = REPO + '/issues/new?title=' + encodeURIComponent(title) + '&body=' + encodeURIComponent(t.slice(0, 1800));
      if (mail) mail.href = 'mailto:' + CONTACT + '?subject=' + encodeURIComponent('[하루 학습] ' + title) + '&body=' + encodeURIComponent(t.slice(0, 1500));
    }
    sync(); note.addEventListener('input', sync);
    function close() { document.removeEventListener('keydown', onKey); if (back.parentNode) back.parentNode.removeChild(back); try { if (prev && prev.focus) prev.focus({ preventScroll: true }); } catch (e) {} }
    function onKey(e) { if (e.key === 'Escape') close(); }
    document.addEventListener('keydown', onKey);
    back.addEventListener('click', function (e) { if (e.target === back) close(); });
    back.querySelector('#hr-close').addEventListener('click', close);
    back.querySelector('#hr-copy').addEventListener('click', function () {
      copy(fullText(c, note.value.trim()), function () { msg.textContent = '복사했어요. 원하는 곳에 붙여 넣어 보내 주세요.'; }, function () { msg.textContent = '자동 복사가 안 돼요. 위 칸의 글을 길게 눌러 복사해 주세요.'; note.value = fullText(c, note.value.trim()); note.select(); });
    });
    try { back.querySelector('#hr-h').focus({ preventScroll: true }); } catch (e) {}
  }
  window.HaruReport = { open: open };
})();

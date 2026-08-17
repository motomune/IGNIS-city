/* IGNIS CITY — Cookie同意バナー
 *
 * Google アナリティクスは Cookie を使うため、EU/英国からのアクセスでは
 * 同意を得る前に読み込むと GDPR / ePrivacy に触れる。
 * 各ページの <head> では GA を「読み込まない」状態にしてあり、
 * ここで「同意する」が押されたときだけ window.ignisLoadAnalytics() を呼ぶ。
 *
 * ・拒否した場合は GA を一切読み込まない（機能は全部そのまま使える）
 * ・判断は端末に保存し、次回以降バナーを出さない
 * ・ゲーム本体の操作を邪魔しないよう画面下部に出し、決めるまでは何度でも表示する
 */
(function () {
  var KEY = 'ignis_cookie_consent';
  var saved = null;
  try { saved = localStorage.getItem(KEY); } catch (e) {}
  if (saved === 'yes' || saved === 'no') return;   // 判断済みなら何もしない

  var isJa = (function () {
    try {
      var q = new URLSearchParams(location.search).get('lang');
      if (q === 'en') return false;
      if (q === 'ja') return true;
      var st = localStorage.getItem('ignis_game_lang');
      if (st === 'en') return false;
      if (st === 'ja') return true;
    } catch (e) {}
    return /^ja/i.test(navigator.language || '');
  })();

  var T = isJa ? {
    body: 'このサイトでは、利用状況の把握のために Google アナリティクス（Cookie）を使用します。同意しない場合でも、ゲームはすべての機能をそのままお使いいただけます。',
    more: 'プライバシーポリシー',
    ok: '同意する',
    no: '同意しない'
  } : {
    body: 'We use Google Analytics (cookies) to understand how the site is used. Declining changes nothing — every feature keeps working.',
    more: 'Privacy Policy',
    ok: 'Accept',
    no: 'Decline'
  };

  function decide(v) {
    try { localStorage.setItem(KEY, v); } catch (e) {}
    if (v === 'yes' && typeof window.ignisLoadAnalytics === 'function') window.ignisLoadAnalytics();
    var el = document.getElementById('ignis-cookie-bar');
    if (el) el.remove();
  }

  function build() {
    if (document.getElementById('ignis-cookie-bar')) return;
    var bar = document.createElement('div');
    bar.id = 'ignis-cookie-bar';
    bar.setAttribute('role', 'dialog');
    bar.setAttribute('aria-live', 'polite');
    bar.style.cssText =
      'position:fixed;left:0;right:0;bottom:0;z-index:2147483000;' +
      'background:rgba(8,8,16,0.97);border-top:1px solid rgba(255,138,61,0.5);' +
      'backdrop-filter:blur(10px);-webkit-backdrop-filter:blur(10px);' +
      'padding:14px 16px calc(14px + env(safe-area-inset-bottom,0px));' +
      'display:flex;gap:12px;align-items:center;justify-content:center;flex-wrap:wrap;' +
      "font-family:'Hiragino Sans','Yu Gothic','Noto Sans JP',system-ui,sans-serif;";

    var txt = document.createElement('div');
    txt.style.cssText = 'flex:1 1 280px;min-width:0;max-width:640px;font-size:12px;line-height:1.7;color:rgba(255,255,255,0.82);';
    txt.appendChild(document.createTextNode(T.body + ' '));
    var a = document.createElement('a');
    a.href = 'legal.html#privacy';
    a.target = '_blank';
    a.rel = 'noopener';
    a.textContent = T.more;
    a.style.cssText = 'color:#ff8a3d;';
    txt.appendChild(a);

    var btns = document.createElement('div');
    btns.style.cssText = 'display:flex;gap:8px;flex:0 0 auto;';
    function mk(label, val, primary) {
      var b = document.createElement('button');
      b.type = 'button';
      b.textContent = label;
      b.style.cssText =
        'padding:10px 18px;border-radius:10px;font-size:13px;font-weight:800;cursor:pointer;white-space:nowrap;' +
        (primary
          ? 'border:none;background:linear-gradient(135deg,#ff6a00,#ee0979);color:#fff;'
          : 'border:1px solid rgba(255,255,255,0.28);background:rgba(255,255,255,0.06);color:rgba(255,255,255,0.85);');
      b.addEventListener('click', function () { decide(val); });
      return b;
    }
    btns.appendChild(mk(T.no, 'no', false));
    btns.appendChild(mk(T.ok, 'yes', true));

    bar.appendChild(txt);
    bar.appendChild(btns);
    document.body.appendChild(bar);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', build);
  else build();
})();

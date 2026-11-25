import { createPet } from '../kit/body.js';
import { createWhaleFigure } from '../whale/figure.js';

const $ = id => document.getElementById(id);
const stage = $('stage'), bubble = $('bubble');
const qs = new URLSearchParams(location.search);
const clampNum = (v, lo, hi, d) => { const n = Number(v); return Number.isFinite(n) ? Math.max(lo, Math.min(hi, n)) : d; };

let scale = clampNum(qs.get('scale'), .5, 2.2, 1);
let scheme = qs.get('scheme') || 'deepseek';
let outfit = qs.get('outfit') || 'maid';
let active = true;
let hideTimer = 0;

const post = msg => { try { window.cooHost.post(msg); } catch (e) {} };
const fmtMoney = (n, cur) => (cur === 'USD' ? '$' : '¥') + Number(n || 0).toLocaleString('zh-CN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });

window.__cooErrs = [];
addEventListener('error', e => {
  window.__cooErrs.push(String(e.message) + ' @' + (e.filename || '') + ':' + e.lineno);
  post({ type: 'jsError', message: String(e.message) + ' @' + (e.filename || '') + ':' + e.lineno });
});
addEventListener('unhandledrejection', e => {
  window.__cooErrs.push(String(e.reason && (e.reason.stack || e.reason)));
  post({ type: 'jsError', message: String(e.reason && (e.reason.stack || e.reason)) });
});

let figure, ctl;
try {
  figure = await createWhaleFigure(undefined, { scheme: `${scheme}-${outfit}`, canvasHost: $('whaleLayer') });
  ctl = createPet(
    { petG: $('pet'), shadowEl: $('shadow'), fxG: $('fx') },
    {
      figure, sfx: {},
      roam: qs.get('roam') === '0' ? 'off' : 'free',
      enter: 'drop',
      ground: 'free',
      bounds: () => ({ W: innerWidth, H: innerHeight, floorY: innerHeight - 14, S: .55 * scale }),
    }
  );
} catch (e) {
  post({ type: 'jsError', message: 'figure init failed: ' + String(e && (e.stack || e)) });
  throw e;
}
new ResizeObserver(() => ctl.resize()).observe(stage);

const pt = e => { const r = stage.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; };
let press = null;
stage.addEventListener('pointerdown', e => {
  if (e.button !== 0) return;
  const p = pt(e);
  if (!ctl.pointerDown(p)) return;
  post({ type: 'press', on: true });
  try { stage.setPointerCapture(e.pointerId); } catch (err) {}
  press = { id: e.pointerId, x: e.clientX, y: e.clientY, t: performance.now(), moved: 0 };
});
stage.addEventListener('pointermove', e => {
  stage.style.cursor = ctl.pointerMove(pt(e)) || '';
  // a drag whose pointerup was swallowed outside the window would otherwise stay stuck
  if (ctl.pressing && e.buttons === 0) {
    ctl.pointerUp();
    post({ type: 'press', on: false });
  }
  if (press && e.pointerId === press.id) {
    press.moved = Math.max(press.moved, Math.hypot(e.clientX - press.x, e.clientY - press.y));
  }
});
const endPress = e => {
  ctl.pointerUp();
  post({ type: 'press', on: false });
  if (press && e.pointerId === press.id) {
    const tap = press.moved < 6 && performance.now() - press.t < 700;
    press = null;
    if (tap) post({ type: 'petClick' });
  }
};
stage.addEventListener('pointerup', endPress);
stage.addEventListener('pointercancel', endPress);
stage.addEventListener('pointerleave', () => { ctl.pointerLeave(); });
stage.addEventListener('contextmenu', e => {
  e.preventDefault();
  if (ctl.hitPet(pt(e))) post({ type: 'menu' });
});

function render(p) {
  $('when').textContent = p.when || '';
  $('headline').textContent = '';
  $('meta').textContent = '';
  $('extra').textContent = '';
  $('hint').textContent = '';
  $('meter').style.display = 'none';
  if (p.pending) {
    const s = document.createElement('div'); s.className = 'pending'; s.textContent = '让我看看 DeepSeek 余额';
    $('headline').append(s);
    return;
  }
  if (!p.ok) {
    const s = document.createElement('div'); s.className = 'err'; s.textContent = p.error || '暂时查不到余额';
    $('headline').append(s);
    $('hint').textContent = '托盘菜单 → 设置 API Key';
    return;
  }
  const b = document.createElement('b'); b.textContent = fmtMoney(p.total, p.currency);
  const of = document.createElement('span'); of.className = 'of'; of.textContent = ' ' + (p.currency || 'CNY');
  $('headline').append('余额 ', b, of);
  const meta = [];
  if (Number(p.toppedUp) > 0) meta.push('充值 ' + fmtMoney(p.toppedUp, p.currency));
  if (Number(p.granted) > 0) meta.push('赠送 ' + fmtMoney(p.granted, p.currency));
  if (p.available === false) meta.push('账户不可用');
  $('meta').textContent = meta.join(' · ');
  if (Array.isArray(p.infos) && p.infos.length > 1) {
    $('extra').textContent = p.infos.filter(i => i.currency !== p.currency).map(i => i.currency + ' ' + fmtMoney(i.total, i.currency)).join(' · ');
  }
}

function showBubble(p, secs) {
  render(p);
  bubble.hidden = false;
  requestAnimationFrame(() => bubble.classList.add('show'));
  clearTimeout(hideTimer);
  hideTimer = setTimeout(() => window.coo.hideBubble(), (secs || 12) * 1000);
  ctl.holdRoam((secs || 12) * .7);
  if (p.ok && !p.pending) {
    ctl.act('wave');
    ctl.setExpr('happy', 2.2);
  } else if (p.pending) {
    ctl.act('look');
    ctl.setThinking(true);
  } else {
    ctl.setThinking(false);
    ctl.setExpr('sad', 2.4);
  }
  if (!p.pending) ctl.setThinking(false);
}

window.coo = {
  showBalance: (p, secs) => showBubble(p, secs),
  updateBalance: p => { if (!bubble.hidden) render(p); },
  hideBubble() {
    bubble.classList.remove('show');
    hideTimer = setTimeout(() => { bubble.hidden = true; }, 200);
  },
  setScheme(sc, of) {
    scheme = sc; outfit = of;
    figure.setScheme(`${sc}-${of}`, { fade: .35 }).then(() => {
      ctl.pet.sqv += 1.2;
      ctl.setExpr('happy', 1.4);
    }).catch(e => post({ type: 'jsError', message: 'setScheme: ' + String(e) }));
  },
  setScale(v) { scale = clampNum(v, .5, 2.2, 1); ctl.resize(); },
  setRoam(on) { ctl.setRoam(on ? 'free' : 'off'); if (!on) ctl.act('stand'); },
  poke() { ctl.act('hop'); },
  setActive(on) { active = !!on; },
  state() { return { scheme, outfit, scale, box: ctl.layout().box, mode: ctl.pet.mode, y: Math.round(ctl.pet.gy) }; },
};

if (window.cooHost) {
  window.cooHost.on(msg => {
    if (!msg) return;
    switch (msg.type) {
      case 'balance': window.coo.showBalance(msg.data, msg.seconds); break;
      case 'update': window.coo.updateBalance(msg.data); break;
      case 'hideBubble': window.coo.hideBubble(); break;
      case 'scheme': window.coo.setScheme(msg.scheme, msg.outfit); break;
      case 'scale': window.coo.setScale(msg.scale); break;
      case 'roam': window.coo.setRoam(!!msg.roam); break;
      case 'active': window.coo.setActive(!!msg.active); break;
      case 'poke': window.coo.poke(); break;
    }
  });
}

function placeBubble() {
  if (bubble.hidden) return;
  const a = ctl.anchor();
  const bw = bubble.offsetWidth || 240, bh = bubble.offsetHeight || 96;
  const cx = Math.min(Math.max(a.x, bw / 2 + 8), innerWidth - bw / 2 - 8);
  bubble.style.left = cx + 'px';
  bubble.style.top = Math.max(a.y - 2, bh + 10) + 'px';
}

let lastReport = 0;
function report(now) {
  if (now - lastReport < 120) return;
  lastReport = now;
  const l = ctl.layout();
  post({ type: 'layout', box: l.box, pressing: !!ctl.pressing, mode: l.mode });
}

let last = performance.now();
function frame(now) {
  requestAnimationFrame(frame);
  // a full-screen transparent stage is costly to paint; halve the rate except while she is handled
  const quick = ctl.pressing || ctl.pet.mode === 'drag' || ctl.pet.mode === 'air';
  if (!quick && now - last < 1000 / 32) return;
  const dt = Math.min(.05, (now - last) / 1000);
  last = now;
  if (active && !document.hidden) {
    ctl.step(dt);
    ctl.render();
    placeBubble();
    report(now);
  }
}
requestAnimationFrame(frame);
post({ type: 'ready' });

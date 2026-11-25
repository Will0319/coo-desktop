'use strict';
const $ = id => document.getElementById(id);
const host = window.settingsHost;

let state = null;
let keyShown = false;
let busy = false;

const money = (n, cur) => (cur === 'USD' ? '$' : '¥') + Number(n || 0).toFixed(2);

function setState(text, kind) {
  const el = $('keyState');
  el.textContent = text || '';
  el.className = 'state' + (kind ? ' ' + kind : '');
}

function buildSelect(el, options, value) {
  el.textContent = '';
  for (const [id, name] of options) {
    const o = document.createElement('option');
    o.value = id;
    o.textContent = name;
    if (id === value) o.selected = true;
    el.append(o);
  }
}

function renderKey() {
  const input = $('key');
  if (state.hasKey) {
    input.placeholder = '已保存 ' + state.keyMask + '，输入新 Key 可替换';
  } else {
    input.placeholder = 'sk-…';
  }
  if (!input.value) {
    setState(state.hasKey
      ? '已保存 ' + state.keyMask + ' · 只保存在本机，余额每 5 分钟自动刷新'
      : '还没有保存 Key：填入后点“保存并测试”', state.hasKey ? 'ok' : '');
  }
}

function renderBalance() {
  const b = state.balance;
  const amount = $('amount'), breakdown = $('breakdown'), meta = $('meta');
  amount.textContent = '';
  breakdown.textContent = '';
  meta.textContent = '';

  if (!state.hasKey) {
    amount.className = 'amount muted';
    amount.textContent = '尚未设置 Key';
    meta.textContent = '保存 API Key 后自动查询余额';
    return;
  }
  if (!b) {
    amount.className = 'amount muted';
    amount.textContent = '尚未查询';
    meta.textContent = '点击右上角“刷新”，或点一下桌面上的 Coo';
    return;
  }
  if (b.pending) {
    amount.className = 'amount muted';
    amount.textContent = '正在查询…';
    return;
  }
  if (!b.ok) {
    amount.className = 'amount err';
    amount.textContent = b.error || '查询失败';
    if (b.when) meta.textContent = '查询时间 ' + b.when;
    return;
  }
  amount.className = 'amount';
  amount.append(document.createTextNode(money(b.total)));
  const cur = document.createElement('span');
  cur.className = 'cur';
  cur.textContent = b.currency || 'CNY';
  amount.append(cur);

  if (Number(b.toppedUp) > 0) {
    const s = document.createElement('span');
    s.append('充值 ');
    const v = document.createElement('b');
    v.textContent = money(b.toppedUp, b.currency);
    s.append(v);
    breakdown.append(s);
  }
  if (Number(b.granted) > 0) {
    const s = document.createElement('span');
    s.append('赠送 ');
    const v = document.createElement('b');
    v.textContent = money(b.granted, b.currency);
    s.append(v);
    breakdown.append(s);
  }

  const bits = [];
  if (b.when) bits.push('更新于 ' + b.when);
  if (b.available === false) bits.push('账户当前不可用');
  if (Array.isArray(b.infos) && b.infos.length > 1) {
    bits.push(b.infos.filter(i => i.currency !== b.currency)
      .map(i => i.currency + ' ' + money(i.total, i.currency)).join(' · '));
  }
  meta.textContent = bits.join(' · ');
}

function renderLook() {
  const s = state.settings;
  buildSelect($('scheme'), state.schemes, s.scheme);
  buildSelect($('outfit'), state.outfits, s.outfit);
  $('scale').value = String(s.scale);
  $('scaleOut').textContent = Number(s.scale).toFixed(1) + '×';
  $('roam').checked = !!s.roam;
  $('autostart').checked = !!s.autostart;
}

function render() {
  $('ver').textContent = 'v' + state.version;
  $('file').textContent = 'config.json · 只保存在本机';
  $('file').title = state.file;
  renderKey();
  renderBalance();
  renderLook();
}

function setBusy(on, id, text) {
  busy = on;
  for (const b of ['save', 'test', 'clear', 'refresh']) $(b).disabled = on;
  if (id) $(id).textContent = text;
}

async function load() {
  state = await host.get();
  render();
}

$('eye').addEventListener('click', () => {
  keyShown = !keyShown;
  $('key').type = keyShown ? 'text' : 'password';
  $('eye').textContent = keyShown ? '隐藏' : '显示';
});

async function save() {
  if (busy) return;
  setBusy(true, 'save', '保存中…');
  try {
    const r = await host.save($('key').value);
    state = r.payload;
    $('key').value = '';
    render();
    if (r.ok) {
      setState('保存成功，接口验证通过 · 余额 ' + money(r.balance.total, r.balance.currency) + ' ' + (r.balance.currency || 'CNY'), 'ok');
    } else {
      setState((r.balance && r.balance.error) || '保存了，但查询失败', 'err');
    }
  } catch (e) {
    setState('保存失败：' + ((e && e.message) || e), 'err');
  } finally {
    setBusy(false, 'save', '保存并测试');
  }
}

async function test() {
  if (busy) return;
  setBusy(true, 'test', '测试中…');
  try {
    const r = await host.test($('key').value);
    if (r.ok) {
      setState('接口可用 · ' + money(r.total, r.currency) + ' ' + (r.currency || 'CNY'), 'ok');
    } else {
      setState(r.error || '测试失败', 'err');
    }
  } catch (e) {
    setState('测试失败：' + ((e && e.message) || e), 'err');
  } finally {
    setBusy(false, 'test', '仅测试');
  }
}

async function refresh() {
  if (busy) return;
  setBusy(true, 'refresh', '查询中…');
  try {
    const r = await host.refresh();
    state = r.payload;
    render();
    if (!r.ok) setState((r.balance && r.balance.error) || '查询失败', 'err');
    else setState('查询成功 · ' + r.balance.when, 'ok');
  } catch (e) {
    setState('查询失败：' + ((e && e.message) || e), 'err');
  } finally {
    setBusy(false, 'refresh', '刷新');
  }
}

$('save').addEventListener('click', save);
$('test').addEventListener('click', test);
$('refresh').addEventListener('click', refresh);

$('clear').addEventListener('click', async () => {
  if (busy) return;
  if (!confirm('清除本机保存的 DeepSeek API Key？')) return;
  setBusy(true);
  try {
    state = await host.clear();
    render();
    setState('已清除本机保存的 API Key', '');
  } finally {
    setBusy(false);
  }
});

$('key').addEventListener('keydown', e => { if (e.key === 'Enter') save(); });

$('scheme').addEventListener('change', async () => {
  state = await host.appearance({ scheme: $('scheme').value, outfit: $('outfit').value });
});

$('outfit').addEventListener('change', async () => {
  state = await host.appearance({ scheme: $('scheme').value, outfit: $('outfit').value });
});

$('scale').addEventListener('input', () => {
  $('scaleOut').textContent = Number($('scale').value).toFixed(1) + '×';
});
$('scale').addEventListener('change', async () => {
  state = await host.appearance({ scale: Number($('scale').value), scheme: $('scheme').value, outfit: $('outfit').value });
});

$('roam').addEventListener('change', async () => {
  state = await host.appearance({ roam: $('roam').checked, scheme: $('scheme').value, outfit: $('outfit').value });
});

$('autostart').addEventListener('change', async () => {
  state = await host.appearance({ autostart: $('autostart').checked, scheme: $('scheme').value, outfit: $('outfit').value });
});

$('getKey').addEventListener('click', () => host.openKeys());
$('folder').addEventListener('click', () => host.openFolder());
$('close').addEventListener('click', () => host.close());
document.addEventListener('keydown', e => { if (e.key === 'Escape') host.close(); });

host.onBalance(b => {
  if (!b) return;
  state.balance = b;
  renderBalance();
});

load().catch(e => setState('读取设置失败：' + ((e && e.message) || e), 'err'));
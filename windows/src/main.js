'use strict';
const { app, BrowserWindow, Tray, Menu, ipcMain, screen, protocol, nativeImage, shell, powerMonitor } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const http = require('http');
const store = require('./store');
const { fetchBalance } = require('./deepseek');

const APP_DIR = path.join(__dirname, '..');
const WEB_ROOT = path.join(APP_DIR, 'web');
const IS_WIN = process.platform === 'win32';
const IS_MAC = process.platform === 'darwin';

const argv = process.argv.slice(1);
const flag = name => argv.some(a => a === '--' + name || a.startsWith('--' + name + '='));
const flagValue = name => {
  const hit = argv.find(a => a.startsWith('--' + name + '='));
  return hit ? hit.slice(name.length + 3) : '';
};

const SCHEMES = [
  ['deepseek', 'DeepSeek'],
  ['harness', 'Harness'],
  ['chatgpt', 'ChatGPT'],
  ['claude', 'Claude'],
  ['gemini', 'Gemini'],
  ['kimi', 'Kimi'],
  ['minimax', 'MiniMax'],
  ['qwen', 'Qwen'],
];
const OUTFITS = [['maid', '女仆装'], ['cape', '冬装'], ['crew', '店员装']];
const SIZES = [0.8, 1, 1.2, 1.5];

let win = null;
let tray = null;
let settingsWin = null;
let quitting = false;
let snapshotting = false;
let stageReady = false;
let stageReadyWaiters = [];

let lastBox = null;
let lastPressing = false;
let lastMsgAt = 0;
let interactive = null;

let balance = null;
let refreshBusy = false;
let refreshTimer = 0;
let previewKeyMask = '';

/* ---------- helpers ---------- */

function logLine(text) {
  const line = '[' + new Date().toISOString() + '] ' + text + '\n';
  try { fs.appendFileSync(path.join(app.getPath('userData'), 'coo.log'), line); } catch (e) {}
  console.log(text);
}

function money(n, cur) {
  const sym = cur === 'USD' ? '$' : '¥';
  return sym + Number(n || 0).toFixed(2);
}

function clockNow() {
  const d = new Date();
  const p = n => String(n).padStart(2, '0');
  return p(d.getHours()) + ':' + p(d.getMinutes());
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

/* ---------- protocol: coo://app/<path> -> web/<path> ---------- */

protocol.registerSchemesAsPrivileged([{
  scheme: 'coo',
  privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true, stream: true },
}]);

function registerProtocol() {
  protocol.registerFileProtocol('coo', (request, callback) => {
    let rel = '/stage/index.html';
    try {
      const u = new URL(request.url);
      rel = decodeURIComponent(u.pathname || '/');
    } catch (e) {}
    if (rel === '/' || rel === '') rel = '/stage/index.html';
    const full = path.resolve(WEB_ROOT, '.' + rel);
    if (full !== WEB_ROOT && !full.startsWith(WEB_ROOT + path.sep)) {
      callback({ error: -10 });
      return;
    }
    callback({ path: full });
  });
}

/* ---------- stage window ---------- */

function stageQuery() {
  const s = store.getSettings();
  const q = new URLSearchParams({
    scheme: s.scheme,
    outfit: s.outfit,
    scale: String(s.scale),
    roam: s.roam ? '1' : '0',
  });
  return '?' + q.toString();
}

function createOverlay(opts) {
  opts = opts || {};
  const display = screen.getPrimaryDisplay();
  const wa = display.workArea;
  const size = opts.size || wa;
  const x = opts.x != null ? opts.x : wa.x;
  const y = opts.y != null ? opts.y : wa.y;

  win = new BrowserWindow({
    x, y,
    width: size.width, height: size.height,
    transparent: true,
    frame: false,
    resizable: false,
    movable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    hasShadow: false,
    alwaysOnTop: true,
    focusable: false,
    show: false,
    type: IS_WIN ? 'toolbar' : 'panel',
    webPreferences: {
      preload: path.join(__dirname, 'preload-overlay.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      backgroundThrottling: false,
      spellcheck: false,
      devTools: flag('devtools'),
    },
  });
  win.setMenu(null);
  win.setMenuBarVisibility(false);
  win.setAlwaysOnTop(true, 'screen-saver');
  win.setSkipTaskbar(true);
  if (IS_MAC) win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });

  win.setIgnoreMouseEvents(true, { forward: true });
  interactive = false;

  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', (e, url) => { if (!url.startsWith('coo://app/')) e.preventDefault(); });
  win.webContents.on('render-process-gone', (e, details) => {
    logLine('renderer gone: ' + (details && details.reason) + ', reloading');
    setTimeout(() => { if (win && !win.isDestroyed()) win.reload(); }, 1000);
  });

  win.loadURL('coo://app/stage/index.html' + stageQuery());
  win.once('ready-to-show', () => {
    win.showInactive();
  });
  win.on('closed', () => { win = null; });
  return win;
}

function setInteractive(on) {
  if (!win || win.isDestroyed() || snapshotting) return;
  on = !!on;
  if (interactive === on) return;
  interactive = on;
  try {
    if (on) win.setIgnoreMouseEvents(false);
    else win.setIgnoreMouseEvents(true, { forward: true });
  } catch (e) {}
}

function cursorPoll() {
  if (!win || win.isDestroyed() || !win.isVisible()) return;
  if (snapshotting) return;
  const now = Date.now();
  // a lost pointerup must not leave the whole screen swallowing clicks
  if (lastPressing && now - lastMsgAt > 1500) lastPressing = false;
  const p = screen.getCursorScreenPoint();
  const b = win.getBounds();
  const x = p.x - b.x, y = p.y - b.y;
  let over = false;
  if (lastBox) {
    over = x >= lastBox.x - 10 && x <= lastBox.x + lastBox.w + 10 &&
           y >= lastBox.y - 10 && y <= lastBox.y + lastBox.h + 10;
  }
  setInteractive(over || lastPressing);
}

function layoutWindow() {
  if (!win || win.isDestroyed()) return;
  const wa = screen.getPrimaryDisplay().workArea;
  win.setBounds({ x: wa.x, y: wa.y, width: wa.width, height: wa.height });
}

/* ---------- stage messages ---------- */

function toStage(msg) {
  if (win && !win.isDestroyed()) win.webContents.send('coo-event', msg);
}

function toSettings(msg) {
  if (settingsWin && !settingsWin.isDestroyed()) settingsWin.webContents.send('balance-event', msg);
}

function waitStageReady(timeout) {
  if (stageReady) return Promise.resolve(true);
  return new Promise(resolve => {
    const t = setTimeout(() => resolve(false), timeout || 20000);
    stageReadyWaiters.push(() => { clearTimeout(t); resolve(true); });
  });
}

ipcMain.on('coo', (e, msg) => {
  if (!msg || typeof msg !== 'object') return;
  switch (msg.type) {
    case 'ready':
      stageReady = true;
      stageReadyWaiters.splice(0).forEach(fn => fn());
      break;
    case 'layout':
      if (msg.box && typeof msg.box.x === 'number') lastBox = msg.box;
      lastPressing = !!msg.pressing;
      lastMsgAt = Date.now();
      break;
    case 'press':
      lastPressing = !!msg.on;
      lastMsgAt = Date.now();
      if (msg.on) setInteractive(true);
      break;
    case 'petClick':
      onPetClick();
      break;
    case 'menu':
      if (tray) tray.popUpContextMenu(buildMenu());
      break;
    case 'jsError':
      logLine('renderer: ' + msg.message);
      break;
  }
});

/* ---------- balance ---------- */

function setBalance(data) {
  if (data) data.at = data.at || Date.now();
  balance = data;
  refreshTray();
  toSettings(data);
}

function sendBalance(data, seconds) {
  toStage({ type: 'balance', data, seconds });
}

function updateBubble(data) {
  toStage({ type: 'update', data });
}

async function refresh(opts) {
  opts = opts || {};
  const key = store.getKey();
  if (!key) {
    const data = { ok: false, error: '还没有设置 DeepSeek API Key', when: clockNow(), noKey: true };
    setBalance(data);
    if (opts.show) sendBalance(data, 12);
    return data;
  }
  if (refreshBusy) {
    if (opts.show) sendBalance({ pending: true, when: '正在查询' }, 30);
    return balance;
  }
  refreshBusy = true;
  if (opts.show) sendBalance({ pending: true, when: '正在查询' }, 30);
  let res;
  try {
    res = await fetchBalance(key);
  } catch (e) {
    res = { ok: false, error: '查询出错：' + ((e && e.message) || e) };
  }
  refreshBusy = false;
  const data = Object.assign({ when: clockNow() }, res);
  setBalance(data);
  if (opts.show) sendBalance(data, 14);
  else updateBubble(data);
  return data;
}

function onPetClick() {
  const fresh = balance && !balance.pending && (Date.now() - (balance.at || 0) < 30000);
  if (fresh) sendBalance(balance, 12);
  else refresh({ show: true });
}

/* ---------- tray ---------- */

function trayIcon() {
  const img = nativeImage.createFromPath(path.join(APP_DIR, 'assets', 'coo_head.png'));
  return img.isEmpty() ? img : img.resize({ width: IS_WIN ? 32 : 18, height: IS_WIN ? 32 : 18 });
}

function trayStatus() {
  if (!store.getKey()) return '未设置 API Key';
  if (refreshBusy) return '正在查询…';
  if (!balance) return '余额尚未查询';
  if (!balance.ok) return '查询失败';
  return '余额 ' + money(balance.total, balance.currency);
}

function osAutostartOn() {
  try {
    return app.getLoginItemSettings({ path: IS_WIN ? process.execPath : undefined }).openAtLogin;
  } catch (e) { return false; }
}

function setAutostart(on) {
  store.setSettings({ autostart: !!on });
  if (app.isPackaged) {
    try { app.setLoginItemSettings({ openAtLogin: !!on, path: process.execPath, args: [] }); }
    catch (e) { logLine('autostart failed: ' + e.message); }
  }
  refreshTray();
}

function currentBalanceForMenu() {
  if (!store.getKey()) return '未设置 API Key';
  if (!balance) return '余额尚未查询';
  if (balance.pending) return '正在查询…';
  if (!balance.ok) return balance.error || '查询失败';
  return '余额 ' + money(balance.total, balance.currency) + ' ' + (balance.currency || 'CNY') + (balance.when ? ' · ' + balance.when : '');
}

function buildMenu() {
  const s = store.getSettings();
  const scheme = s.scheme, outfit = s.outfit;
  return Menu.buildFromTemplate([
    { label: 'Coo · ' + currentBalanceForMenu(), enabled: false },
    { type: 'separator' },
    { label: '查询余额', click: () => refresh({ show: true }) },
    { label: '设置 API Key…', click: openSettings },
    { type: 'separator' },
    {
      label: '配色', submenu: SCHEMES.map(([id, name]) => ({
        label: name, type: 'radio', checked: scheme === id,
        click: () => applyLook({ scheme: id, outfit }),
      })),
    },
    {
      label: '服装', submenu: OUTFITS.map(([id, name]) => ({
        label: name, type: 'radio', checked: outfit === id,
        click: () => applyLook({ scheme, outfit: id }),
      })),
    },
    {
      label: '大小', submenu: SIZES.map(v => ({
        label: v + '×', type: 'radio', checked: Math.abs(s.scale - v) < 0.01,
        click: () => setScale(v),
      })),
    },
    {
      label: '自由活动', type: 'checkbox', checked: !!s.roam,
      click: item => setRoam(item.checked),
    },
    {
      label: '开机自启', type: 'checkbox', checked: !!s.autostart,
      click: item => setAutostart(item.checked),
    },
    { type: 'separator' },
    { label: win && win.isVisible() ? '隐藏 Coo' : '显示 Coo', click: toggleShow },
    { label: '打开数据文件夹', click: () => shell.openPath(path.dirname(store.filePath())) },
    { type: 'separator' },
    { label: '退出 Coo', click: () => { quitting = true; app.quit(); } },
  ]);
}

function refreshTray() {
  if (!tray) return;
  tray.setToolTip('Coo · ' + trayStatus());
  tray.setContextMenu(buildMenu());
}

function createTray() {
  tray = new Tray(trayIcon());
  refreshTray();
}

function toggleShow() {
  if (!win) return;
  if (win.isVisible()) win.hide();
  else win.showInactive();
  refreshTray();
}

/* ---------- look & feel ---------- */

function applyLook(patch) {
  store.setSettings(patch);
  if (patch.scheme || patch.outfit) {
    toStage({ type: 'scheme', scheme: patch.scheme, outfit: patch.outfit });
  }
  refreshTray();
}

function setScale(v) {
  store.setSettings({ scale: v });
  toStage({ type: 'scale', scale: v });
  refreshTray();
}

function setRoam(on) {
  store.setSettings({ roam: !!on });
  toStage({ type: 'roam', roam: !!on });
  refreshTray();
}

/* ---------- settings window ---------- */

function settingsPayload() {
  return {
    hasKey: !!previewKeyMask || !!store.getKey(),
    keyMask: previewKeyMask || store.maskedKey(),
    settings: store.getSettings(),
    balance,
    file: store.filePath(),
    version: app.getVersion(),
    platform: process.platform,
    schemes: SCHEMES,
    outfits: OUTFITS,
  };
}

function openSettings() {
  if (settingsWin && !settingsWin.isDestroyed()) {
    settingsWin.show();
    settingsWin.focus();
    return;
  }
  const wa = screen.getPrimaryDisplay().workArea;
  settingsWin = new BrowserWindow({
    width: 460,
    height: Math.max(560, Math.min(700, wa.height - 40)),
    resizable: false,
    maximizable: false,
    fullscreenable: false,
    title: 'Coo · DeepSeek',
    icon: path.join(APP_DIR, 'assets', 'coo_head.png'),
    backgroundColor: '#f4f7ff',
    show: false,
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload-settings.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      devTools: true,
    },
  });
  settingsWin.setMenu(null);
  settingsWin.setMenuBarVisibility(false);
  settingsWin.loadURL('coo://app/settings/index.html');
  settingsWin.once('ready-to-show', () => settingsWin.show());
  settingsWin.on('closed', () => { settingsWin = null; });
}

ipcMain.handle('settings:get', () => settingsPayload());

ipcMain.handle('settings:save', async (e, key) => {
  const k = String(key || '').trim();
  if (k) store.setKey(k);
  const res = await refresh({ show: true });
  toSettings(res);
  return { ok: !!res && res.ok !== false, balance: res, payload: settingsPayload() };
});

ipcMain.handle('settings:test', async (e, key) => {
  const k = String(key || '').trim() || store.getKey();
  if (!k) return { ok: false, error: '请先填写 API Key' };
  const res = await fetchBalance(k);
  return res;
});

ipcMain.handle('settings:refresh', async () => {
  const res = await refresh({ show: true });
  return { ok: !!res && res.ok !== false, balance: res, payload: settingsPayload() };
});

ipcMain.handle('settings:appearance', (e, patch) => {
  const p = {};
  if (patch && SCHEMES.some(s => s[0] === patch.scheme)) p.scheme = patch.scheme;
  if (patch && OUTFITS.some(o => o[0] === patch.outfit)) p.outfit = patch.outfit;
  if (patch && Number.isFinite(Number(patch.scale))) p.scale = Math.max(0.5, Math.min(2.2, Number(patch.scale)));
  if (patch && typeof patch.roam === 'boolean') p.roam = patch.roam;
  applyLook(p);
  if (p.scale != null) setScale(p.scale);
  if (p.roam != null) setRoam(p.roam);
  if (patch && typeof patch.autostart === 'boolean') setAutostart(patch.autostart);
  return settingsPayload();
});

ipcMain.handle('settings:clear', () => {
  store.clearKey();
  balance = null;
  refreshTray();
  return settingsPayload();
});

ipcMain.handle('settings:open-keys', () => {
  shell.openExternal('https://platform.deepseek.com/api_keys');
});

ipcMain.handle('settings:open-folder', () => {
  shell.openPath(path.dirname(store.filePath()));
});

ipcMain.handle('settings:close', () => {
  if (settingsWin) settingsWin.close();
});

/* ---------- start / quit ---------- */

function applyStoredAutostart() {
  // only a packaged build can register a meaningful login item
  if (!app.isPackaged) return;
  const want = !!store.getSettings().autostart;
  if (want === osAutostartOn()) return;
  try { app.setLoginItemSettings({ openAtLogin: want, path: process.execPath, args: [] }); } catch (e) {}
}

function startNormal() {
  createOverlay();
  createTray();
  applyStoredAutostart();
  setInterval(cursorPoll, IS_WIN ? 20 : 33);

  win.webContents.on('console-message', (e, level, message) => {
    if (level >= 2) logLine('console: ' + message);
  });

  if (flag('probe')) {
    setInterval(async () => {
      try {
        const state = await win.webContents.executeJavaScript('window.coo && window.coo.state()');
        const vis = await win.webContents.executeJavaScript('document.visibilityState + "/" + document.hidden + "/" + innerWidth + "x" + innerHeight + "/" + (document.querySelector("canvas")||{}).width');
        logLine('probe ' + JSON.stringify(state) + ' ' + vis +
          ' winVisible=' + win.isVisible() + ' opacity=' + win.getOpacity() + ' bounds=' + JSON.stringify(win.getBounds()) +
          ' bg=' + win.getBackgroundColor());
      } catch (e) {
        logLine('probe failed: ' + ((e && e.message) || e));
      }
    }, 1500);
  }

  screen.on('display-metrics-changed', layoutWindow);
  screen.on('display-added', layoutWindow);
  screen.on('display-removed', layoutWindow);
  powerMonitor.on('resume', () => refresh({ show: false }));

  refreshTimer = setInterval(() => {
    if (store.getKey()) refresh({ show: false });
  }, 5 * 60 * 1000);

  setTimeout(async () => {
    if (flag('no-first-run')) return;
    const ready = await waitStageReady(15000);
    if (!ready) logLine('stage never reported ready');
    if (!store.getKey()) {
      refresh({ show: true });
      setTimeout(openSettings, 1100);
    } else {
      refresh({ show: true });
    }
  }, 900);
}

/* ---------- dev: snapshots & self test ---------- */

async function runSnapshot() {
  snapshotting = true;
  const out = flagValue('snapshot') || path.join(APP_DIR, 'dist', 'stage-preview.png');
  fs.mkdirSync(path.dirname(out), { recursive: true });
  createOverlay({ size: { width: 900, height: 700 }, x: 120, y: 80 });
  await waitStageReady(20000);
  await sleep(1200);
  sendBalance({
    ok: true, available: true, currency: 'CNY',
    total: 110, granted: 10, toppedUp: 100, when: clockNow(),
    infos: [{ currency: 'CNY', total: 110, granted: 10, toppedUp: 100 }],
  }, 60);
  await sleep(900);
  // a transparent capture loses the bubble's shadow to the alpha channel; preview on white
  await win.webContents.executeJavaScript("document.documentElement.style.background = '#ffffff'; document.body.style.background = '#ffffff';");
  await sleep(200);
  const img = await win.webContents.capturePage();
  fs.writeFileSync(out, img.toPNG());
  console.log('[snapshot] wrote ' + out + ' (' + img.getSize().width + 'x' + img.getSize().height + ')');
  app.exit(0);
}

async function runSettingsSnapshot() {
  snapshotting = true;
  const out = flagValue('settings-snapshot') || path.join(APP_DIR, 'dist', 'settings-preview.png');
  fs.mkdirSync(path.dirname(out), { recursive: true });
  previewKeyMask = 'sk-…9f3a';
  balance = {
    ok: true, available: true, currency: 'CNY',
    total: 110, granted: 10, toppedUp: 100, when: clockNow(),
    infos: [{ currency: 'CNY', total: 110, granted: 10, toppedUp: 100 }],
  };
  openSettings();
  await new Promise(resolve => settingsWin.webContents.once('did-finish-load', resolve));
  await sleep(1200);
  const img = await settingsWin.webContents.capturePage();
  fs.writeFileSync(out, img.toPNG());
  console.log('[snapshot] wrote ' + out + ' (' + img.getSize().width + 'x' + img.getSize().height + ')');
  app.exit(0);
}

async function runSelfTest() {
  const results = [];
  const check = (name, ok, extra) => {
    results.push(!!ok);
    console.log((ok ? 'PASS ' : 'FAIL ') + name + (extra ? '  —  ' + extra : ''));
  };

  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'coo-test-'));
  app.setPath('userData', tmp);
  store.init();

  store.setKey('sk-test-1234');
  check('store 写入并读回 Key', store.getKey() === 'sk-test-1234', '加密=' + (store.filePath() && fs.readFileSync(store.filePath(), 'utf8').includes('keyEnc')));
  check('store 掩码', store.maskedKey() === 'sk-…1234', store.maskedKey());
  store.setSettings({ scale: 1.2, roam: false });
  store.init();
  check('store 设置持久化', store.getSettings().scale === 1.2 && store.getSettings().roam === false);
  store.clearKey();
  check('store 清除 Key', store.getKey() === '' && store.maskedKey() === '');

  const server = http.createServer((req, res) => {
    if (req.headers.authorization === 'Bearer sk-good') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        is_available: true,
        balance_infos: [{ currency: 'CNY', total_balance: '110.00', granted_balance: '10.00', topped_up_balance: '100.00' }],
      }));
    } else {
      res.writeHead(401, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ error: { message: 'Authentication Fails', type: 'authentication_error' } }));
    }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = 'http://127.0.0.1:' + server.address().port;

  const good = await fetchBalance('sk-good', { base });
  check('余额 200 解析', good.ok && good.total === 110 && good.granted === 10 && good.toppedUp === 100 && good.currency === 'CNY', JSON.stringify(good));

  const bad = await fetchBalance('sk-bad', { base });
  check('401 提示', !bad.ok && /401/.test(bad.error), bad.error);

  const down = await fetchBalance('sk-good', { base: 'http://127.0.0.1:1', timeout: 1500 });
  check('网络失败提示', !down.ok && /网络/.test(down.error), down.error);

  server.close();
  fs.rmSync(tmp, { recursive: true, force: true });
  const passed = results.filter(Boolean).length;
  console.log('[self-test] ' + passed + '/' + results.length + ' passed');
  app.exit(passed === results.length ? 0 : 1);
}

/* ---------- app lifecycle ---------- */

const devTask = flag('self-test') || flag('snapshot') || flag('settings-snapshot');

if (!devTask && !app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (win) { win.showInactive(); refreshTray(); }
  });

  app.whenReady().then(() => {
    registerProtocol();
    store.init();
    if (IS_WIN) app.setAppUserModelId('com.coo.deepseek');
    if (IS_MAC && devTask) app.dock.hide();

    if (flag('self-test')) return runSelfTest();
    if (flag('snapshot')) return runSnapshot();
    if (flag('settings-snapshot')) return runSettingsSnapshot();
    startNormal();
  });
}

app.on('before-quit', () => { quitting = true; });
app.on('window-all-closed', () => {
  if (quitting) app.quit();
});
app.on('will-quit', () => {
  if (refreshTimer) clearInterval(refreshTimer);
});
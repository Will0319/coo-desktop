'use strict';
const fs = require('fs');
const path = require('path');
const { app, safeStorage } = require('electron');

let file = null;
let data = {};

function init() {
  file = path.join(app.getPath('userData'), 'config.json');
  try { data = JSON.parse(fs.readFileSync(file, 'utf8')) || {}; } catch (e) { data = {}; }
  // migrate a plaintext key to encrypted storage when the platform supports it
  if (data.keyPlain && canEncrypt()) setKey(data.keyPlain);
}

function canEncrypt() {
  try { return safeStorage.isEncryptionAvailable(); } catch (e) { return false; }
}

function persist() {
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(data, null, 2), { mode: 0o600 });
  } catch (e) { console.error('[store] save failed', e); }
}

function getKey() {
  if (data.keyEnc) {
    try { return safeStorage.decryptString(Buffer.from(data.keyEnc, 'base64')); } catch (e) { return ''; }
  }
  return data.keyPlain || '';
}

function setKey(key) {
  key = String(key || '').trim();
  if (canEncrypt()) {
    data.keyEnc = safeStorage.encryptString(key).toString('base64');
    delete data.keyPlain;
  } else {
    data.keyPlain = key;
    delete data.keyEnc;
  }
  persist();
}

function clearKey() {
  delete data.keyEnc;
  delete data.keyPlain;
  persist();
}

function maskedKey() {
  const k = getKey();
  if (!k) return '';
  if (k.length <= 8) return k.slice(0, 2) + '****';
  return k.slice(0, 3) + '…' + k.slice(-4);
}

function getSettings() {
  return {
    scheme: data.scheme || 'deepseek',
    outfit: data.outfit || 'maid',
    scale: Number(data.scale) || 1,
    roam: data.roam !== false,
    autostart: data.autostart === true,
  };
}

function setSettings(patch) {
  Object.assign(data, patch);
  persist();
}

function filePath() { return file; }

module.exports = { init, getKey, setKey, clearKey, maskedKey, getSettings, setSettings, filePath };
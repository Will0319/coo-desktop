'use strict';
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('settingsHost', {
  get: () => ipcRenderer.invoke('settings:get'),
  save: key => ipcRenderer.invoke('settings:save', key),
  test: key => ipcRenderer.invoke('settings:test', key),
  refresh: () => ipcRenderer.invoke('settings:refresh'),
  appearance: patch => ipcRenderer.invoke('settings:appearance', patch),
  clear: () => ipcRenderer.invoke('settings:clear'),
  openKeys: () => ipcRenderer.invoke('settings:open-keys'),
  openFolder: () => ipcRenderer.invoke('settings:open-folder'),
  close: () => ipcRenderer.invoke('settings:close'),
  onBalance: cb => { ipcRenderer.on('balance-event', (e, b) => cb(b)); },
});
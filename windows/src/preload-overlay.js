'use strict';
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('cooHost', {
  post: msg => ipcRenderer.send('coo', msg),
  on: cb => { ipcRenderer.on('coo-event', (e, msg) => cb(msg)); },
});
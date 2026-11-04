const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('cleaner', { open: () => ipcRenderer.invoke('open-cleaner') });

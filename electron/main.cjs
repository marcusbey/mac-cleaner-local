const { app, BrowserWindow, ipcMain, Menu, dialog } = require('electron');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { execFile } = require('node:child_process');
const { access } = require('node:fs/promises');
const { nativeBundle, launchArguments } = require('./launcher.cjs');
let window;
const page = pathToFileURL(path.join(__dirname, 'index.html')).href;
const resources = () => app.isPackaged ? process.resourcesPath : path.resolve(__dirname, '../dist');
async function launchNative() {
  await access(nativeBundle(resources()));
  return new Promise((resolve, reject) => execFile('/usr/bin/open', launchArguments(resources()), { timeout: 15000 }, error => error ? reject(error) : resolve(true)));
}
if (!app.requestSingleInstanceLock()) { app.quit(); }
else {
  app.on('second-instance', () => { window?.show(); window?.focus(); });
  app.whenReady().then(() => {
    Menu.setApplicationMenu(Menu.buildFromTemplate([{ label: app.name, submenu: [{ role: 'about' }, { type: 'separator' }, { role: 'quit' }] }, { role:'editMenu' }, {role:'windowMenu'}]));
    ipcMain.handle('open-cleaner', async event => {
      if (!window || event.sender !== window.webContents || event.senderFrame !== window.webContents.mainFrame || event.senderFrame.url !== page) throw new Error('Invalid request');
      try { await launchNative(); return { ok: true }; }
      catch { return { ok:false, message:'macOS could not open the bundled cleaner. Move the complete app to Applications and try again.' }; }
    });
    window = new BrowserWindow({ width: 650, height: 590, minWidth:570, minHeight:540, title: 'App Cleaner Desktop', backgroundColor:'#0b293e', webPreferences: { preload:path.join(__dirname,'preload.cjs'), nodeIntegration:false, contextIsolation:true, sandbox:true, webSecurity:true } });
    window.webContents.setWindowOpenHandler(() => ({ action:'deny' }));
    window.webContents.on('will-navigate', event => event.preventDefault());
    window.webContents.session.setPermissionRequestHandler((_contents,_permission,callback)=>callback(false));
    window.webContents.session.setPermissionCheckHandler(()=>false);
    window.loadFile(path.join(__dirname,'index.html'));
    app.on('activate',()=>{window?.show();});
  }).catch(error=>{dialog.showErrorBox('Unable to start App Cleaner',error.message);app.quit();});
}
app.on('window-all-closed',()=>app.quit());

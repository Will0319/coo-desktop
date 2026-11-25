# Coo for Windows

An Electron port of the Coopanion whale desktop companion, showing the DeepSeek
account balance. A transparent, always-on-top, click-through stage covers the
primary screen's work area; only the whale is clickable. A tray icon offers the
balance, API-key settings, outfits, size, roaming, autostart, hide/quit.

## Run from source (macOS or Windows)

```
npm install
npm start
```

Electron 22 is the last line that runs on Windows 7/8.1 and on macOS 12 (this
machine). The asset protocol is `coo://app/<path>` mapped to `web/<path>`.

## DeepSeek key & balance

- API: `GET https://api.deepseek.com/user/balance` with `Authorization: Bearer <key>`
- The key is stored in `%APPDATA%\Coo\config.json` encrypted with the OS keystore
  (`safeStorage` / DPAPI), falling back to plaintext only when encryption is
  unavailable.
- Balance refreshes at startup, on demand, and every 5 minutes.
- Settings: tray → 设置 API Key…, or the first-run window.

## Layout

```
src/main.js             window, click-through polling, tray, IPC, refresh
src/deepseek.js         balance HTTP client
src/store.js            config.json + encrypted key
src/preload-overlay.js  window.cooHost (post/on)
src/preload-settings.js window.settingsHost
web/stage/              transparent full-screen pet stage + bubble
web/settings/           API key / balance / appearance window
web/kit, web/whale/     Coopanion rig and assets (see THIRD-PARTY-NOTICE.md)
tools/pack-win.js       downloads Electron win32-x64 and builds the zip
```

## Packaging (run on macOS)

```
npm run pack:win
```

Builds `dist/Coo-Windows-x64.zip` from the official Electron
`electron-v22.3.27-win32-x64.zip` (npmmirror, GitHub fallback). The app source
lives unpacked under `resources/app` (no asar), which also satisfies AGPL source
availability. The zip extracts to a `Coo/` folder with `Coo.exe`, `README.txt`
(Chinese quick start), and the licence notice.

The Windows runtime itself could not be executed on this macOS machine; the
renderer, balance client, store, and IPC were exercised locally with Electron.

## Dev flags

```
electron . --self-test                    # store + mock DeepSeek server tests
electron . --snapshot[=path]              # stage preview PNG (900x700, sample balance)
electron . --settings-snapshot[=path]     # settings window preview PNG
electron . --no-first-run                 # skip startup bubble/settings
electron . --probe                        # log stage state to coo.log every 1.5s
```

## Known limitations

- The exe is unsigned (SmartScreen warning) and keeps Electron's default icon in
  Explorer/taskbar; the tray icon is Coo's.
- Click-through uses a 33 ms cursor poll plus renderer `pressing` messages; a lost
  pointer release is recovered by the renderer (buttons == 0 on move) and a main
  process watchdog.
- Autostart records the current `Coo.exe` path; moving the folder requires
  toggling it again.
- Only the primary display is covered; display changes re-fit the stage.
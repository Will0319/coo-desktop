'use strict';
/**
 * Builds dist/Coo-Windows-x64.zip from the official Electron win32-x64 archive.
 * Runs on macOS (ditto) and Windows (PowerShell Expand-Archive / Compress-Archive).
 */
const fs = require('fs');
const path = require('path');
const https = require('https');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

const ROOT = path.join(__dirname, '..');
const VER = require('../package.json').devDependencies.electron;
const ZIP_NAME = 'electron-v' + VER + '-win32-x64.zip';
const CACHE_DIR = path.join(__dirname, '.cache');
const CACHE = path.join(CACHE_DIR, ZIP_NAME);
const BUILD = path.join(ROOT, 'build');
const OUT = path.join(BUILD, 'Coo');
const DIST = path.join(ROOT, 'dist');
const OUT_ZIP = path.join(DIST, 'Coo-Windows-x64.zip');

const URLS = [
  'https://npmmirror.com/mirrors/electron/' + VER + '/' + ZIP_NAME,
  'https://github.com/electron/electron/releases/download/v' + VER + '/' + ZIP_NAME,
];

const COPY = ['src', 'web', 'assets'];
const DOCS = ['README.txt', 'THIRD-PARTY-NOTICE.md', 'LICENSE-Coopanion.txt'];

function human(n) {
  return (n / 1048576).toFixed(1) + ' MB';
}

function download(url, out) {
  return new Promise((resolve, reject) => {
    const get = (u, depth) => {
      if (depth > 6) return reject(new Error('too many redirects'));
      https.get(u, res => {
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          res.resume();
          return get(new URL(res.headers.location, u).toString(), depth + 1);
        }
        if (res.statusCode !== 200) {
          res.resume();
          return reject(new Error('HTTP ' + res.statusCode + ' ' + u));
        }
        const total = Number(res.headers['content-length'] || 0);
        let got = 0;
        let mark = 0;
        const tmp = out + '.part';
        const ws = fs.createWriteStream(tmp);
        res.on('data', d => {
          got += d.length;
          if (total && got - mark > total / 10) {
            mark = got;
            process.stdout.write('  ' + Math.round(got / total * 100) + '%  ');
          }
        });
        res.pipe(ws);
        ws.on('finish', () => {
          ws.close(() => {
            fs.renameSync(tmp, out);
            if (total) process.stdout.write('\n');
            resolve();
          });
        });
        ws.on('error', reject);
        res.on('error', reject);
      }).on('error', reject);
    };
    get(url, 0);
  });
}

async function ensureElectron() {
  fs.mkdirSync(CACHE_DIR, { recursive: true });
  if (fs.existsSync(CACHE) && fs.statSync(CACHE).size > 50 * 1048576) {
    console.log('using cached ' + CACHE + ' (' + human(fs.statSync(CACHE).size) + ')');
    return;
  }
  for (const url of URLS) {
    try {
      console.log('downloading ' + url);
      await download(url, CACHE);
      console.log('saved ' + CACHE + ' (' + human(fs.statSync(CACHE).size) + ')');
      return;
    } catch (e) {
      console.log('failed: ' + e.message);
      try { fs.unlinkSync(CACHE); } catch (err) {}
    }
  }
  throw new Error('could not download ' + ZIP_NAME);
}

function unzip(zip, dest) {
  fs.mkdirSync(dest, { recursive: true });
  if (process.platform === 'darwin') {
    execFileSync('ditto', ['-x', '-k', zip, dest], { stdio: 'inherit' });
  } else if (process.platform === 'win32') {
    execFileSync('powershell.exe', ['-NoProfile', '-Command',
      "Expand-Archive -LiteralPath '" + zip + "' -DestinationPath '" + dest + "' -Force"], { stdio: 'inherit' });
  } else {
    execFileSync('unzip', ['-q', '-o', zip, '-d', dest], { stdio: 'inherit' });
  }
}

function zipDir(dir, zip) {
  try { fs.unlinkSync(zip); } catch (e) {}
  if (process.platform === 'darwin') {
    execFileSync('ditto', ['-c', '-k', '--keepParent', dir, zip], { stdio: 'inherit' });
  } else if (process.platform === 'win32') {
    execFileSync('powershell.exe', ['-NoProfile', '-Command',
      "Compress-Archive -Path '" + dir + "' -DestinationPath '" + zip + "' -Force"], { stdio: 'inherit' });
  } else {
    execFileSync('zip', ['-qr', zip, path.basename(dir)], { cwd: path.dirname(dir), stdio: 'inherit' });
  }
}

function copyTree(src, dst) {
  const st = fs.statSync(src);
  if (st.isDirectory()) {
    fs.mkdirSync(dst, { recursive: true });
    for (const name of fs.readdirSync(src)) copyTree(path.join(src, name), path.join(dst, name));
  } else {
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.copyFileSync(src, dst);
  }
}

async function main() {
  await ensureElectron();

  console.log('unpacking Electron...');
  fs.rmSync(OUT, { recursive: true, force: true });
  fs.mkdirSync(OUT, { recursive: true });
  unzip(CACHE, OUT);

  const exe = path.join(OUT, 'electron.exe');
  if (!fs.existsSync(exe)) throw new Error('electron.exe not found after unzip');
  fs.renameSync(exe, path.join(OUT, 'Coo.exe'));

  const appDir = path.join(OUT, 'resources', 'app');
  fs.rmSync(appDir, { recursive: true, force: true });
  fs.mkdirSync(appDir, { recursive: true });

  fs.writeFileSync(path.join(appDir, 'package.json'), JSON.stringify({
    name: 'coo-deepseek',
    productName: 'Coo',
    version: '1.0.0',
    description: 'Coo — a desktop whale companion that shows your DeepSeek balance',
    main: 'src/main.js',
    license: 'AGPL-3.0-or-later',
  }, null, 2) + '\n');

  for (const name of COPY) {
    const src = path.join(ROOT, name);
    if (!fs.existsSync(src)) {
      console.log('skip missing ' + name);
      continue;
    }
    copyTree(src, path.join(appDir, name));
  }

  // only the app we ship is needed under resources
  fs.rmSync(path.join(OUT, 'resources', 'default_app.asar'), { force: true });

  // keep the licence and the user guide visible next to Coo.exe
  for (const name of DOCS) {
    const src = path.join(ROOT, name);
    if (fs.existsSync(src)) fs.copyFileSync(src, path.join(OUT, name));
  }

  console.log('staging ready: ' + OUT);

  fs.mkdirSync(DIST, { recursive: true });
  console.log('zipping...');
  zipDir(OUT, OUT_ZIP);

  const size = fs.statSync(OUT_ZIP).size;
  const sha = crypto.createHash('sha256').update(fs.readFileSync(OUT_ZIP)).digest('hex');
  console.log('\nbuilt ' + OUT_ZIP + ' (' + human(size) + ')');
  console.log('sha256 ' + sha);

  // quick content verification
  if (process.platform !== 'win32') {
    const list = execFileSync('unzip', ['-l', OUT_ZIP]).toString();
    const must = [
      'Coo/Coo.exe',
      'Coo/README.txt',
      'Coo/resources/app/src/main.js',
      'Coo/resources/app/web/stage/index.html',
      'Coo/resources/app/web/whale/model.json',
      'Coo/resources/app/web/settings/index.html',
    ];
    let missing = 0;
    for (const m of must) {
      const ok = list.includes(m);
      console.log((ok ? 'ok   ' : 'MISS ') + m);
      if (!ok) missing++;
    }
    if (missing) process.exitCode = 1;
  }
}

main().catch(e => {
  console.error('pack failed: ' + (e && e.stack || e));
  process.exit(1);
});
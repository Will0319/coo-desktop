'use strict';
const https = require('https');
const http = require('http');
const { URL } = require('url');

const num = v => { const n = Number(v); return Number.isFinite(n) ? n : 0; };

function httpError(status, raw) {
  if (status === 401) return 'API Key 无效或已失效（401）';
  if (status === 403) return '这个 Key 没有权限查询余额（403）';
  if (status === 429) return '请求太频繁，请稍后再试（429）';
  return '请求失败（HTTP ' + status + '）';
}

function netError(e) {
  const code = e && e.code;
  if (code === 'ENOTFOUND' || code === 'EAI_AGAIN') return '网络连接失败：无法访问 api.deepseek.com';
  if (code === 'ECONNREFUSED') return '网络连接失败：连接被拒绝';
  if (code === 'ECONNRESET') return '网络连接失败：连接被重置';
  return '网络错误：' + ((e && e.message) || code || 'unknown');
}

/**
 * GET {base}/user/balance  →  { ok, available, currency, total, granted, toppedUp, infos, status }
 * Failure: { ok: false, error, status? }
 */
function fetchBalance(key, opts) {
  opts = opts || {};
  const base = opts.base || 'https://api.deepseek.com';
  const timeout = opts.timeout || 12000;
  const url = new URL('/user/balance', base);
  const mod = url.protocol === 'http:' ? http : https;
  return new Promise(resolve => {
    let settled = false;
    const done = r => { if (!settled) { settled = true; resolve(r); } };
    const req = mod.request({
      protocol: url.protocol,
      hostname: url.hostname,
      port: url.port || undefined,
      path: url.pathname + url.search,
      method: 'GET',
      headers: { Authorization: 'Bearer ' + key, Accept: 'application/json' },
      timeout,
    }, res => {
      let raw = '';
      res.setEncoding('utf8');
      res.on('data', d => {
        raw += d;
        if (raw.length > 1e6) req.destroy();
      });
      res.on('end', () => {
        let j = null;
        try { j = JSON.parse(raw); } catch (e) {}
        if (res.statusCode === 200 && j && Array.isArray(j.balance_infos) && j.balance_infos.length) {
          const infos = j.balance_infos.map(x => ({
            currency: String(x.currency || 'CNY'),
            total: num(x.total_balance),
            granted: num(x.granted_balance),
            toppedUp: num(x.topped_up_balance),
          }));
          const primary = infos.find(i => i.currency === 'CNY') || infos[0];
          done({
            ok: true,
            available: j.is_available !== false,
            currency: primary.currency,
            total: primary.total,
            granted: primary.granted,
            toppedUp: primary.toppedUp,
            infos,
            status: res.statusCode,
          });
        } else if (res.statusCode === 200) {
          done({ ok: false, error: '接口没有返回余额信息', status: 200 });
        } else {
          // the API's own wording can be terse English; for auth/rate errors say it in plain Chinese
          const friendly = httpError(res.statusCode, raw);
          const msg = (res.statusCode === 401 || res.statusCode === 403 || res.statusCode === 429)
            ? friendly
            : ((j && j.error && j.error.message) || (j && j.message) || friendly);
          done({ ok: false, error: msg, status: res.statusCode });
        }
      });
    });
    req.on('timeout', () => { req.destroy(); done({ ok: false, error: '请求超时，请检查网络' }); });
    req.on('error', e => done({ ok: false, error: netError(e) }));
    req.end();
  });
}

module.exports = { fetchBalance };
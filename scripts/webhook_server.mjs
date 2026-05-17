/**
 * Pro Cloud v2 — TradingView Webhook → Telegram
 * TradingView'den gelen alert'ı alır, Telegram'a gönderir.
 * PM2 ile 7/24 çalışır, bilgisayar açık olduğu sürece.
 *
 * TradingView Alert Kurulumu:
 *   1. TradingView → Alerts (saat ikonu) → + New Alert
 *   2. Condition: Pro TP/SL/SR Cloud v2 → "🟢 Pro Cloud LONG" veya "🔴 Pro Cloud SHORT"
 *   3. Actions: Webhook URL → http://<BU_BİLGİSAYAR_IP>:3001/webhook
 *   4. Message: {"direction":"{{plot_0}}","ticker":"{{ticker}}","close":"{{close}}","interval":"{{interval}}","time":"{{timenow}}"}
 */

import http    from 'http';
import https   from 'https';
import fs      from 'fs';
import path    from 'path';
import { fileURLToPath } from 'url';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const LOG  = path.join(ROOT, 'logs', 'webhook.log');
fs.mkdirSync(path.join(ROOT, 'logs'), { recursive: true });

// .env oku
const env = Object.fromEntries(
  fs.readFileSync(path.join(ROOT, '.env'), 'utf8')
    .split('\n').filter(l => l.includes('='))
    .map(l => [l.split('=')[0].trim(), l.slice(l.indexOf('=')+1).trim()])
);

const TOKEN = env.TELEGRAM_BOT_TOKEN;
const CHAT  = env.TELEGRAM_CHAT_ID;
const PORT  = parseInt(env.WEBHOOK_PORT || '3001');

const now = () => new Date().toLocaleString('tr-TR');

function log(msg) {
  const line = `[${now()}] ${msg}`;
  console.log(line);
  try { fs.appendFileSync(LOG, line + '\n'); } catch {}
}

async function telegram(text) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ chat_id: CHAT, text, parse_mode: 'HTML' });
    const req  = https.request({
      hostname: 'api.telegram.org',
      path:     `/bot${TOKEN}/sendMessage`,
      method:   'POST',
      headers:  { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, res => {
      let d = '';
      res.on('data', c => d += c);
      res.on('end', () => {
        const j = JSON.parse(d);
        j.ok ? resolve() : reject(new Error(j.description));
      });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

function formatMesaj(data) {
  const isLong  = (data.direction || '').toUpperCase().includes('LONG');
  const ico     = isLong ? '🟢' : '🔴';
  const yon     = isLong ? 'AL' : 'SAT';
  const ticker  = data.ticker  || '?';
  const close   = data.close   || '?';
  const tf      = data.interval|| '?';

  return `${ico} <b>${yon} — Pro Cloud v2</b>

📊 ${ticker} · ${tf}dk
⏰ ${now()}
💰 Fiyat: <b>${close}</b>

<i>TradingView alert tetiklendi</i>`;
}

const server = http.createServer((req, res) => {
  if (req.method !== 'POST' || req.url !== '/webhook') {
    res.writeHead(404);
    res.end('Not found');
    return;
  }

  let body = '';
  req.on('data', chunk => body += chunk);
  req.on('end', async () => {
    res.writeHead(200);
    res.end('OK');

    try {
      const data = JSON.parse(body);
      log(`Webhook alındı: ${JSON.stringify(data)}`);
      const msg = formatMesaj(data);
      await telegram(msg);
      log('Telegram gönderildi ✓');
    } catch (e) {
      log(`HATA: ${e.message} | body: ${body}`);
    }
  });
});

server.listen(PORT, () => {
  log(`━━━ Webhook sunucusu başladı → port ${PORT} ━━━`);
  log(`URL: http://localhost:${PORT}/webhook`);
  log(`TradingView alert URL: http://<IP>:${PORT}/webhook`);
});

process.on('SIGINT',  () => { log('Durdu.'); process.exit(0); });
process.on('SIGTERM', () => { log('Durdu.'); process.exit(0); });

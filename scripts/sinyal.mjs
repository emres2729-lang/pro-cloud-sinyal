import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';
import { spawn } from 'child_process';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const STATE = path.join(ROOT, 'logs', 'sinyal_state.json');
const LOG   = path.join(ROOT, 'logs', 'sinyal.log');

fs.mkdirSync(path.join(ROOT, 'logs'), { recursive: true });

// ── Config ────────────────────────────────────────────────────────
const env = Object.fromEntries(
  fs.readFileSync(path.join(ROOT, '.env'), 'utf8')
    .split('\n').filter(l => l.includes('='))
    .map(l => [l.split('=')[0].trim(), l.slice(l.indexOf('=')+1).trim()])
);

const TOKEN    = env.TELEGRAM_BOT_TOKEN;
const CHAT     = env.TELEGRAM_CHAT_ID;
const INTERVAL = parseInt(env.CHECK_INTERVAL_SEC || '60') * 1000;
const DRY      = process.argv.includes('--dry');

// ── Helpers ───────────────────────────────────────────────────────
const delay = ms => new Promise(r => setTimeout(r, ms));
const now   = () => new Date().toLocaleString('tr-TR');

function log(msg) {
  const line = `[${now()}] ${msg}`;
  console.log(line);
  try { fs.appendFileSync(LOG, line + '\n'); } catch {}
}

function loadState() {
  try { return JSON.parse(fs.readFileSync(STATE, 'utf8')); } catch { return { lastTs: 0 }; }
}
function saveState(s) { fs.writeFileSync(STATE, JSON.stringify(s)); }

// ── TradingView bağlantısı ────────────────────────────────────────
async function connect() {
  const { connect: c } = await import(
    new URL(`file:///${path.join(ROOT, 'src/connection.js').replace(/\\/g, '/')}`)
  );
  await c();
}

async function disconnect() {
  try {
    const { disconnect: d } = await import(
      new URL(`file:///${path.join(ROOT, 'src/connection.js').replace(/\\/g, '/')}`)
    );
    await d();
  } catch {}
}

// ── Sinyal oku ────────────────────────────────────────────────────
async function okusinyali() {
  const data = await import(
    new URL(`file:///${path.join(ROOT, 'src/core/data.js').replace(/\\/g, '/')}`)
  );

  const result = await data.getPineLabels({
    study_filter: 'Pro TP',
    max_labels: 20,
  });

  const labels = result?.studies?.[0]?.labels || [];

  // MCP label v2: LONG|v:2|score:...|entry:...|ts:xxx
  const mcpLabel = labels
    .map(l => l.text || '')
    .filter(t => /^(LONG|SHORT)\|v:2\|/.test(t))  // sadece v2 labelları
    .pop(); // son sinyal

  if (!mcpLabel) return null;

  const parts = Object.fromEntries(
    mcpLabel.split('|').slice(1).map(p => {
      const [k, v] = p.split(':');
      return [k, isNaN(v) ? v : parseFloat(v)];
    })
  );
  parts.direction = mcpLabel.startsWith('LONG') ? 'LONG' : 'SHORT';
  return parts;
}

// ── Telegram ──────────────────────────────────────────────────────
async function telegram(msg) {
  const r = await fetch(`https://api.telegram.org/bot${TOKEN}/sendMessage`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: CHAT, text: msg, parse_mode: 'HTML' }),
  });
  const d = await r.json();
  if (!d.ok) throw new Error(d.description);
}

function formatMesaj(s) {
  const al  = s.direction === 'LONG';
  const ico = al ? '🟢' : '🔴';
  const yon = al ? 'AL' : 'SAT';

  const konfluence = [
    s.choch && (al ? 'CHoCH↑' : 'CHoCH↓'),
    !s.choch && s.bos && (al ? 'BOS↑' : 'BOS↓'),
    s.rdema && 'RSI>EMA21',
    s.mdema && 'MACD+',
    s.emas  && 'EMA 5›22›50',
  ].filter(Boolean).join(' · ');

  return `${ico} <b>${yon} — Pro Cloud v2</b>

📊 ${env.TV_SYMBOL || 'XAUUSD'} · ${env.TV_TIMEFRAME || '15'}dk
⏰ ${now()}

▸ Giriş: <b>${s.entry}</b>
✖ Stop:  ${s.sl}
✔ TP1:  ${s.tp1}  <i>(RR 1:${s.rr})</i>
✔ TP2:  ${s.tp2}
✔ TP3:  ${s.tp3}

Skor ${s.score}/10 · RSI ${s.rsi}${konfluence ? '\n' + konfluence : ''}`;
}

// ── Ana loop ──────────────────────────────────────────────────────
async function main() {
  log('━━━ Pro Cloud v2 Sinyal Motoru başladı' + (DRY ? ' [DRY]' : '') + ' ━━━');

  await connect();
  log('TradingView bağlantısı kuruldu');

  const state = loadState();
  let tur = 0;

  process.on('SIGINT',  () => { log('Durdu.'); disconnect(); process.exit(0); });
  process.on('SIGTERM', () => { log('Durdu.'); disconnect(); process.exit(0); });

  while (true) {
    tur++;
    try {
      const sig = await okusinyali();

      if (!sig) {
        if (tur % 5 === 0) log(`#${tur} bekleniyor...`);
      } else if ((sig.ts || 0) > state.lastTs) {
        log(`#${tur} YENİ SİNYAL → ${sig.direction} @ ${sig.entry} | skor:${sig.score}/10`);
        const msg = formatMesaj(sig);

        if (!DRY) {
          await telegram(msg);
          log('Telegram gönderildi ✓');
        } else {
          log('[DRY] Mesaj:\n' + msg);
        }

        state.lastTs = sig.ts || 0;
        saveState(state);
      } else {
        if (tur % 10 === 0) log(`#${tur} sinyal değişmedi`);
      }
    } catch (e) {
      log(`HATA: ${e.message}`);
      // Bağlantı kopmuşsa yeniden bağlan
      if (e.message.includes('WebSocket') || e.message.includes('connect') || e.message.includes('CDP')) {
        log('Yeniden bağlanıyor...');
        await delay(5000);
        try { await connect(); log('Bağlantı yenilendi'); } catch {}
      }
    }

    await delay(INTERVAL);
  }
}

main().catch(e => { log('FATAL: ' + e.message); process.exit(1); });

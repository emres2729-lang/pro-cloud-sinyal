/**
 * Pro Cloud v2 — Bağımsız Sinyal Motoru
 * TradingView Desktop, CDP, bilgisayar gerektirmez.
 * GitHub Actions'ta her 5 dakikada çalışır → sinyal gelince Telegram'a gönderir.
 *
 * Veri kaynağı: Yahoo Finance (ücretsiz, API key gerektirmez)
 * Semboller: GC=F (Altın), BTC-USD (Bitcoin), EURUSD=X, GBPUSD=X
 */

import fs   from 'fs';
import https from 'https';
import path  from 'path';
import { fileURLToPath } from 'url';

const ROOT      = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const STATE_DIR = path.join(ROOT, 'data');
const STATE_F   = path.join(STATE_DIR, 'cloud_state.json');
fs.mkdirSync(STATE_DIR, { recursive: true });

// ── CONFIG ──────────────────────────────────────────────────────
const TOKEN  = process.env.TELEGRAM_BOT_TOKEN;
const CHAT   = process.env.TELEGRAM_CHAT_ID;
const DRY    = process.argv.includes('--dry');

const SEMBOLLER = [
  { yahoo: 'GC=F',      isim: 'XAUUSD', tf: '15m', range: '5d'  },
  { yahoo: 'BTC-USD',   isim: 'BTCUSD', tf: '15m', range: '5d'  },
  { yahoo: 'EURUSD=X',  isim: 'EURUSD', tf: '1h',  range: '10d' },
  { yahoo: 'GBPUSD=X',  isim: 'GBPUSD', tf: '1h',  range: '10d' },
];

// ── STATE ────────────────────────────────────────────────────────
function loadState()  { try { return JSON.parse(fs.readFileSync(STATE_F, 'utf8')); } catch { return {}; } }
function saveState(s) { fs.writeFileSync(STATE_F, JSON.stringify(s, null, 2)); }

// ── UTILS ────────────────────────────────────────────────────────
const now = () => new Date().toLocaleString('tr-TR', { timeZone: 'Europe/Istanbul' });
const log = (...a) => console.log(`[${now()}]`, ...a);

function get(url) {
  return new Promise((res, rej) => {
    https.get(url, { headers: { 'User-Agent': 'Mozilla/5.0' } }, r => {
      let d = '';
      r.on('data', c => d += c);
      r.on('end', () => {
        try { res(JSON.parse(d)); }
        catch { rej(new Error('JSON parse hatası: ' + d.slice(0, 100))); }
      });
    }).on('error', rej);
  });
}

// ── INDICATORS ──────────────────────────────────────────────────
function rma(vals, p) {
  if (vals.length < p) return [vals.reduce((a,b) => a+b) / vals.length];
  const r = [vals.slice(0, p).reduce((a,b)=>a+b) / p];
  for (let i = p; i < vals.length; i++)
    r.push((r.at(-1) * (p-1) + vals[i]) / p);
  return r;
}

function ema(vals, p) {
  if (!vals.length) return [];
  const k = 2 / (p + 1), r = [vals[0]];
  for (let i = 1; i < vals.length; i++)
    r.push(vals[i] * k + r.at(-1) * (1 - k));
  return r;
}

function dema(vals, p) {
  const e1 = ema(vals, p), e2 = ema(e1, p);
  return e1.map((v, i) => 2*v - e2[i]);
}

function calcATR(H, L, C, p) {
  const tr = [H[0] - L[0]];
  for (let i = 1; i < C.length; i++)
    tr.push(Math.max(H[i]-L[i], Math.abs(H[i]-C[i-1]), Math.abs(L[i]-C[i-1])));
  return rma(tr, p);
}

function calcRSI(C, p) {
  const g = [], l = [];
  for (let i = 1; i < C.length; i++) {
    const d = C[i] - C[i-1];
    g.push(Math.max(d, 0)); l.push(Math.max(-d, 0));
  }
  const ag = rma(g, p), al = rma(l, p);
  return ag.map((v, i) => al[i] === 0 ? 100 : 100 - 100 / (1 + v / al[i]));
}

function calcSuperTrend(H, L, C, p, mult) {
  const atrV   = calcATR(H, L, C, p);
  const offset = C.length - atrV.length;
  const ubs = [], lbs = [], dirs = [];

  for (let i = 0; i < C.length; i++) {
    const ai = i - offset;
    const hl2 = (H[i] + L[i]) / 2;
    const a   = ai >= 0 ? atrV[ai] : atrV[0];
    const ub  = hl2 + mult * a;
    const lb  = hl2 - mult * a;

    const pUB  = ubs[i-1] ?? ub;
    const pLB  = lbs[i-1] ?? lb;
    const pC   = C[i-1]   ?? C[i];
    const fUB  = (ub < pUB || pC > pUB) ? ub : pUB;
    const fLB  = (lb > pLB || pC < pLB) ? lb : pLB;

    ubs.push(fUB); lbs.push(fLB);

    const pD = dirs[i-1] ?? 1;
    dirs.push(pD === 1 ? (C[i] > fUB ? -1 : 1) : (C[i] < fLB ? 1 : -1));
  }
  return dirs;
}

// ── DATA FETCH ───────────────────────────────────────────────────
async function fetchOHLCV(yahoo, tf, range) {
  const url = `https://query1.finance.yahoo.com/v8/finance/chart/${yahoo}?interval=${tf}&range=${range}`;
  const data = await get(url);
  const res  = data.chart?.result?.[0];
  if (!res) throw new Error(`Yahoo Finance hatası: ${yahoo}`);

  const ts = res.timestamp;
  const q  = res.indicators.quote[0];
  return ts.map((t, i) => ({
    time:   t * 1000,
    open:   q.open[i],
    high:   q.high[i],
    low:    q.low[i],
    close:  q.close[i],
    volume: q.volume[i] || 0,
  })).filter(c => c.close != null && c.high != null);
}

// ── SIGNAL DETECTION ────────────────────────────────────────────
function analiz(candles) {
  if (candles.length < 100) return null;

  const H  = candles.map(c => c.high);
  const L  = candles.map(c => c.low);
  const C  = candles.map(c => c.close);
  const V  = candles.map(c => c.volume);

  // SuperTrend 14/3
  const dirs     = calcSuperTrend(H, L, C, 14, 3.0);
  const bull     = dirs.at(-1) < 0;
  const bear     = dirs.at(-1) > 0;
  const bullCross = bull && dirs.at(-2) >= 0;
  const bearCross = bear && dirs.at(-2) <= 0;
  if (!bullCross && !bearCross) return null;

  // RSI(14) vs EMA(21)
  const rsiV  = calcRSI(C, 14);
  const rsiE  = ema(rsiV, 21);
  const rsiBull = rsiV.at(-1) > rsiE.at(-1);

  // MACD DEMA(12,26,9)
  const dFast  = dema(C, 12);
  const dSlow  = dema(C, 26);
  const n      = Math.min(dFast.length, dSlow.length);
  const macdL  = dFast.slice(-n).map((v,i) => v - dSlow.slice(-n)[i]);
  const macdS  = dema(macdL, 9);
  const macdH  = macdL.slice(-macdS.length).map((v,i) => v - macdS[i]);
  const macdBull = macdH.at(-1) > 0;

  // EMA Stack 5/22/50
  const e5  = ema(C, 5).at(-1);
  const e22 = ema(C, 22).at(-1);
  const e50 = ema(C, 50).at(-1);
  const emasBull = e5 > e22 && e22 > e50;
  const emasBear = e5 < e22 && e22 < e50;

  // Hacim
  const volMa = V.slice(-21,-1).reduce((a,b)=>a+b,0) / 20;
  const volBull = V.at(-1) > volMa * 1.2 && C.at(-1) > C.at(-2);
  const volBear = V.at(-1) > volMa * 1.2 && C.at(-1) < C.at(-2);

  // ATR
  const atrV = calcATR(H, L, C, 14).at(-1);

  if (bullCross) {
    const score = (rsiBull?1:0) + (macdBull?1:0) + (emasBull?1:0) + (volBull?1:0);
    if (score < 2) return null;
    return {
      direction: 'LONG', score, maxScore: 4,
      close: C.at(-1), atr: atrV, time: candles.at(-1).time,
      rsi: rsiV.at(-1).toFixed(1),
      tp1: (C.at(-1) + atrV * 2.0).toFixed(3),
      tp2: (C.at(-1) + atrV * 3.5).toFixed(3),
      sl:  (C.at(-1) - atrV * 1.0).toFixed(3),
      konfluence: [rsiBull&&'RSI✓', macdBull&&'MACD✓', emasBull&&'EMA✓', volBull&&'Vol✓'].filter(Boolean).join(' · '),
    };
  }

  if (bearCross) {
    const score = (!rsiBull?1:0) + (!macdBull?1:0) + (emasBear?1:0) + (volBear?1:0);
    if (score < 2) return null;
    return {
      direction: 'SHORT', score, maxScore: 4,
      close: C.at(-1), atr: atrV, time: candles.at(-1).time,
      rsi: rsiV.at(-1).toFixed(1),
      tp1: (C.at(-1) - atrV * 2.0).toFixed(3),
      tp2: (C.at(-1) - atrV * 3.5).toFixed(3),
      sl:  (C.at(-1) + atrV * 1.0).toFixed(3),
      konfluence: [!rsiBull&&'RSI✓', !macdBull&&'MACD✓', emasBear&&'EMA✓', volBear&&'Vol✓'].filter(Boolean).join(' · '),
    };
  }

  return null;
}

// ── TELEGRAM ────────────────────────────────────────────────────
function telegram(text) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ chat_id: CHAT, text, parse_mode: 'HTML' });
    const req = https.request({
      hostname: 'api.telegram.org',
      path: `/bot${TOKEN}/sendMessage`,
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data', c=>d+=c); r.on('end', () => res(JSON.parse(d))); });
    req.on('error', rej);
    req.write(body); req.end();
  });
}

function formatMesaj(sig, isim, tf) {
  const al  = sig.direction === 'LONG';
  const ico = al ? '🟢' : '🔴';
  const yon = al ? 'AL' : 'SAT';
  return `${ico} <b>${yon} — Pro Cloud v2</b>

📊 ${isim} · ${tf}
⏰ ${now()}
☁️ <i>GitHub Actions (bulut)</i>

▸ Giriş: <b>${sig.close.toFixed(3)}</b>
✖ Stop:  ${sig.sl}
✔ TP1:  ${sig.tp1}
✔ TP2:  ${sig.tp2}

Skor ${sig.score}/${sig.maxScore} · RSI ${sig.rsi}
${sig.konfluence}`;
}

// ── MAIN ─────────────────────────────────────────────────────────
async function main() {
  log('━━━ Pro Cloud Bulut Sinyal Tarama ━━━' + (DRY ? ' [DRY]' : ''));
  const state = loadState();
  let yeniSinyal = false;

  for (const { yahoo, isim, tf, range } of SEMBOLLER) {
    try {
      log(`Taranıyor: ${isim} (${tf})`);
      const candles = await fetchOHLCV(yahoo, tf, range);
      log(`  ${candles.length} bar alındı`);

      const sig = analiz(candles);
      if (!sig) {
        log(`  Sinyal yok`);
        continue;
      }

      const key    = `${isim}_${tf}`;
      const lastTs = state[key] || 0;
      if (sig.time <= lastTs) {
        log(`  Sinyal biliniyor (ts: ${sig.time})`);
        continue;
      }

      log(`  YENİ SİNYAL → ${sig.direction} @ ${sig.close} | Skor:${sig.score}/${sig.maxScore}`);
      const msg = formatMesaj(sig, isim, tf);

      if (!DRY) {
        const r = await telegram(msg);
        if (r.ok) { log('  Telegram ✓'); } else { log('  Telegram HATA:', r.description); }
      } else {
        log('[DRY] Mesaj:\n' + msg);
      }

      state[key] = sig.time;
      yeniSinyal = true;
    } catch (e) {
      log(`  HATA ${isim}: ${e.message}`);
    }
  }

  saveState(state);
  log(`Tamamlandı. Yeni sinyal: ${yeniSinyal}`);
}

main().catch(e => { log('FATAL:', e.message); process.exit(1); });

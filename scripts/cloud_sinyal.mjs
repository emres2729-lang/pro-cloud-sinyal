/**
 * Pro Cloud v2 — Bulut Sinyal Motoru
 * Pine Script "Pro TP/SL/SR Cloud v2" ile birebir aynı mantık:
 *   SuperTrend(14,3) + MTF(4h) + RSI DEMA + MACD DEMA + EMA Stack + SMC BOS/CHoCH + Hacim
 *   Skor >= 3/5, MTF filtre zorunlu
 *
 * Veri: Yahoo Finance (ücretsiz)
 */

import fs   from 'fs';
import https from 'https';
import path  from 'path';
import { fileURLToPath } from 'url';

const ROOT      = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const STATE_DIR = path.join(ROOT, 'data');
const STATE_F   = path.join(STATE_DIR, 'cloud_state.json');
fs.mkdirSync(STATE_DIR, { recursive: true });

const TOKEN = process.env.TELEGRAM_BOT_TOKEN;
const CHAT  = process.env.TELEGRAM_CHAT_ID;
const DRY   = process.argv.includes('--dry');

const SEMBOLLER = [
  // ── Endeksler ──────────────────────────────────────────────────
  { yahoo: '^VIX',     isim: 'VIX',    tf: '1h',  range: '30d' },
  { yahoo: '^NDX',     isim: 'US100',  tf: '15m', range: '5d'  },
  { yahoo: '^DJI',     isim: 'US30',   tf: '15m', range: '5d'  },
  { yahoo: '^GSPC',    isim: 'SP500',  tf: '15m', range: '5d'  },
  { yahoo: '^GDAXI',   isim: 'DE40',   tf: '15m', range: '5d'  },
  { yahoo: 'XU100.IS', isim: 'XU100',  tf: '1h',  range: '30d' },
  // ── Emtia ──────────────────────────────────────────────────────
  { yahoo: 'GC=F',     isim: 'GOLD',   tf: '15m', range: '5d'  },
  { yahoo: 'SI=F',     isim: 'SILVER', tf: '15m', range: '5d'  },
  { yahoo: 'BZ=F',     isim: 'BRENT',  tf: '1h',  range: '30d' },
  { yahoo: 'CL=F',     isim: 'USOIL',  tf: '15m', range: '5d'  },
  // ── Forex ──────────────────────────────────────────────────────
  { yahoo: 'EURUSD=X', isim: 'EURUSD', tf: '1h',  range: '30d' },
  { yahoo: 'AUDCAD=X', isim: 'AUDCAD', tf: '1h',  range: '30d' },
  { yahoo: 'USDJPY=X', isim: 'USDJPY', tf: '1h',  range: '30d' },
  { yahoo: 'EURJPY=X', isim: 'EURJPY', tf: '1h',  range: '30d' },
  { yahoo: 'USDCHF=X', isim: 'USDCHF', tf: '1h',  range: '30d' },
  { yahoo: 'USDCAD=X', isim: 'USDCAD', tf: '1h',  range: '30d' },
  { yahoo: 'CADCHF=X', isim: 'CADCHF', tf: '1h',  range: '30d' },
  { yahoo: 'EURCAD=X', isim: 'EURCAD', tf: '1h',  range: '30d' },
  { yahoo: 'EURGBP=X', isim: 'EURGBP', tf: '1h',  range: '30d' },
  { yahoo: 'EURCHF=X', isim: 'EURCHF', tf: '1h',  range: '30d' },
  { yahoo: 'GBPUSD=X', isim: 'GBPUSD', tf: '1h',  range: '30d' },
  { yahoo: 'GBPAUD=X', isim: 'GBPAUD', tf: '1h',  range: '30d' },
  { yahoo: 'GBPJPY=X', isim: 'GBPJPY', tf: '1h',  range: '30d' },
  { yahoo: 'AUDUSD=X', isim: 'AUDUSD', tf: '1h',  range: '30d' },
  { yahoo: 'GBPNZD=X', isim: 'GBPNZD', tf: '1h',  range: '30d' },
  { yahoo: 'CHFJPY=X', isim: 'CHFJPY', tf: '1h',  range: '30d' },
];

// ── STATE ─────────────────────────────────────────────────────────
function loadState()  { try { return JSON.parse(fs.readFileSync(STATE_F,'utf8')); } catch { return {}; } }
function saveState(s) { fs.writeFileSync(STATE_F, JSON.stringify(s, null, 2)); }

// ── UTILS ─────────────────────────────────────────────────────────
const now = () => new Date().toLocaleString('tr-TR', { timeZone: 'Europe/Istanbul' });
const log = (...a) => console.log(`[${now()}]`, ...a);

function get(url) {
  return new Promise((res, rej) => {
    https.get(url, { headers: { 'User-Agent': 'Mozilla/5.0' } }, r => {
      let d = '';
      r.on('data', c => d += c);
      r.on('end', () => { try { res(JSON.parse(d)); } catch { rej(new Error('JSON: ' + d.slice(0,80))); } });
    }).on('error', rej);
  });
}

// ── INDIKATÖRLER (Pine Script birebir) ────────────────────────────

// Wilder's RMA (Pine: ta.rma)
function rma(vals, p) {
  if (vals.length < p) return [vals.reduce((a,b)=>a+b)/vals.length];
  const r = [vals.slice(0,p).reduce((a,b)=>a+b)/p];
  for (let i = p; i < vals.length; i++)
    r.push((r.at(-1)*(p-1) + vals[i]) / p);
  return r;
}

// EMA (Pine: ta.ema)
function ema(vals, p) {
  if (!vals.length) return [];
  const k = 2/(p+1), r = [vals[0]];
  for (let i = 1; i < vals.length; i++)
    r.push(vals[i]*k + r.at(-1)*(1-k));
  return r;
}

// DEMA (Pine: dema(x,n) => 2*ta.ema(x,n) - ta.ema(ta.ema(x,n),n))
function dema(vals, p) {
  const e1 = ema(vals, p), e2 = ema(e1, p);
  return e1.map((v,i) => 2*v - e2[i]);
}

// ATR (Pine: ta.atr)
function calcATR(H, L, C, p) {
  const tr = [H[0]-L[0]];
  for (let i = 1; i < C.length; i++)
    tr.push(Math.max(H[i]-L[i], Math.abs(H[i]-C[i-1]), Math.abs(L[i]-C[i-1])));
  return rma(tr, p);
}

// RSI (Pine: ta.rsi)
function calcRSI(C, p) {
  const g=[], l=[];
  for (let i=1; i<C.length; i++) {
    const d = C[i]-C[i-1];
    g.push(Math.max(d,0)); l.push(Math.max(-d,0));
  }
  const ag = rma(g,p), al = rma(l,p);
  return ag.map((v,i) => al[i]===0 ? 100 : 100 - 100/(1+v/al[i]));
}

// SuperTrend (Pine: ta.supertrend)
function calcSuperTrend(H, L, C, p, mult) {
  const atrV = calcATR(H, L, C, p);
  const off  = C.length - atrV.length;
  const ubs=[], lbs=[], dirs=[];
  for (let i=0; i<C.length; i++) {
    const ai  = i - off;
    const hl2 = (H[i]+L[i])/2;
    const a   = ai>=0 ? atrV[ai] : atrV[0];
    const ub  = hl2 + mult*a, lb = hl2 - mult*a;
    const pUB = ubs[i-1]??ub, pLB = lbs[i-1]??lb, pC = C[i-1]??C[i];
    const fUB = (ub<pUB || pC>pUB) ? ub : pUB;
    const fLB = (lb>pLB || pC<pLB) ? lb : pLB;
    ubs.push(fUB); lbs.push(fLB);
    const pD = dirs[i-1]??1;
    dirs.push(pD===1 ? (C[i]>fUB?-1:1) : (C[i]<fLB?1:-1));
  }
  return dirs;
}

// Pivot High/Low (Pine: ta.pivothigh / ta.pivotlow, leftbars=len, rightbars=len)
function calcPivots(H, L, len) {
  const ph = new Array(H.length).fill(null);
  const pl = new Array(L.length).fill(null);
  for (let i=len; i<H.length-len; i++) {
    let isPH=true, isPL=true;
    for (let j=i-len; j<=i+len; j++) {
      if (j===i) continue;
      if (H[j]>=H[i]) isPH=false;
      if (L[j]<=L[i]) isPL=false;
    }
    if (isPH) ph[i]=H[i];
    if (isPL) pl[i]=L[i];
  }
  return { ph, pl };
}

// SMC BOS / CHoCH (Pine: tam karşılık)
function calcSMC(C, H, L, len=10) {
  const { ph, pl } = calcPivots(H, L, len);
  const n = C.length;
  const smc_bull=new Array(n).fill(false), bos_bull=new Array(n).fill(false),
        bos_bear=new Array(n).fill(false), choch_bull=new Array(n).fill(false),
        choch_bear=new Array(n).fill(false);
  let last_sh=null, last_sl=null, bull=false, bb_done=false, bs_done=false;
  for (let i=0; i<n; i++) {
    if (ph[i]!==null) { last_sh=ph[i]; bb_done=false; }
    if (pl[i]!==null) { last_sl=pl[i]; bs_done=false; }
    const bos_b = last_sh!==null && C[i]>last_sh && !bb_done;
    const bos_s = last_sl!==null && C[i]<last_sl && !bs_done;
    choch_bull[i] = bos_b && !bull;
    choch_bear[i] = bos_s &&  bull;
    bos_bull[i]   = bos_b;
    bos_bear[i]   = bos_s;
    if (bos_b) { bb_done=true; bull=true; }
    if (bos_s) { bs_done=true; bull=false; }
    smc_bull[i] = bull;
  }
  return { smc_bull, bos_bull, bos_bear, choch_bull, choch_bear };
}

// 4h Resample (1h barları 4h'e dönüştür)
function resampleTo4H(candles1h) {
  const groups = new Map();
  for (const c of candles1h) {
    const key = Math.floor(c.time / (4*3600*1000)) * (4*3600*1000);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(c);
  }
  return [...groups.entries()]
    .sort((a,b) => a[0]-b[0])
    .filter(([,bars]) => bars.length >= 2)
    .map(([time, bars]) => ({
      time, open: bars[0].open,
      high:   Math.max(...bars.map(b=>b.high)),
      low:    Math.min(...bars.map(b=>b.low)),
      close:  bars.at(-1).close,
      volume: bars.reduce((s,b)=>s+b.volume,0),
    }));
}

// ── DATA FETCH ────────────────────────────────────────────────────
async function fetchOHLCV(yahoo, tf, range) {
  const url = `https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(yahoo)}?interval=${tf}&range=${range}`;
  const data = await get(url);
  const res  = data.chart?.result?.[0];
  if (!res) throw new Error(`Yahoo hatası: ${yahoo}`);
  const ts=res.timestamp, q=res.indicators.quote[0];
  return ts.map((t,i) => ({
    time: t*1000, open: q.open[i], high: q.high[i],
    low: q.low[i], close: q.close[i], volume: q.volume[i]||0,
  })).filter(c => c.close!=null && c.high!=null && c.open!=null);
}

// ── SİNYAL ANALİZİ (Pine Script birebir) ─────────────────────────
async function analiz(yahoo, tf, range) {
  // İki fetch paralel: ana TF + 1h (MTF için)
  const htfRange = tf === '15m' ? '60d' : '60d';
  const [candles, htf1h] = await Promise.all([
    fetchOHLCV(yahoo, tf, range),
    fetchOHLCV(yahoo, '1h', htfRange).catch(() => []),
  ]);

  if (candles.length < 100) return null;

  const H = candles.map(c=>c.high), L = candles.map(c=>c.low);
  const C = candles.map(c=>c.close), O = candles.map(c=>c.open);
  const V = candles.map(c=>c.volume);

  // ── SuperTrend(14, 3.0) ──────────────────────────────────────
  const dirs      = calcSuperTrend(H, L, C, 14, 3.0);
  const bull      = dirs.at(-1) < 0;
  const bear      = dirs.at(-1) > 0;
  const bullCross = bull && dirs.at(-2) >= 0;
  const bearCross = bear && dirs.at(-2) <= 0;
  if (!bullCross && !bearCross) return null;

  // ── MTF Filtre: 4h SuperTrend ────────────────────────────────
  let htf_bull = false, htf_bear = false;
  try {
    const htf4h = resampleTo4H(htf1h);
    if (htf4h.length >= 30) {
      const htf_dirs = calcSuperTrend(
        htf4h.map(c=>c.high), htf4h.map(c=>c.low), htf4h.map(c=>c.close), 14, 3.0
      );
      htf_bull = htf_dirs.at(-1) < 0;
      htf_bear = htf_dirs.at(-1) > 0;
    }
  } catch { /* MTF başarısız → sinyal engellenir */ }

  if (bullCross && !htf_bull) return null;
  if (bearCross && !htf_bear) return null;

  // ── RSI(14) vs EMA(21) — Pine: ta.rsi + ta.ema ───────────────
  const rsiV    = calcRSI(C, 14);
  const rsiE    = ema(rsiV, 21);
  const rsiBull = rsiV.at(-1) > rsiE.at(-1);
  const rsiBear = rsiV.at(-1) < rsiE.at(-1);

  // ── MACD DEMA(12,26,9) ────────────────────────────────────────
  const dFast   = dema(C, 12), dSlow = dema(C, 26);
  const nn      = Math.min(dFast.length, dSlow.length);
  const macdL   = dFast.slice(-nn).map((v,i)=>v-dSlow.slice(-nn)[i]);
  const macdS   = dema(macdL, 9);
  const macdH   = macdL.slice(-macdS.length).map((v,i)=>v-macdS[i]);
  const macdBull = macdH.at(-1) > 0;
  const macdBear = macdH.at(-1) < 0;

  // ── EMA Stack 5/22/50 ────────────────────────────────────────
  const e5=ema(C,5).at(-1), e22=ema(C,22).at(-1), e50=ema(C,50).at(-1);
  const emasBull = e5>e22 && e22>e50;
  const emasBear = e5<e22 && e22<e50;

  // ── SMC BOS / CHoCH (pivot len=10) ──────────────────────────
  const smc      = calcSMC(C, H, L, 10);
  const smcBull  = smc.smc_bull.at(-1);
  const bosBull  = smc.bos_bull.at(-1);
  const bosBear  = smc.bos_bear.at(-1);
  const chochBull= smc.choch_bull.at(-1);
  const chochBear= smc.choch_bear.at(-1);

  // ── Hacim: volume > SMA(20)*1.2 AND close > open ─────────────
  const volSma  = V.slice(-21,-1).reduce((a,b)=>a+b,0) / 20;
  const volBull = V.at(-1) > volSma*1.2 && C.at(-1) > O.at(-1);
  const volBear = V.at(-1) > volSma*1.2 && C.at(-1) < O.at(-1);

  // ── ATR ──────────────────────────────────────────────────────
  const atrV = calcATR(H, L, C, 14).at(-1);

  // ── SKOR ve SİNYAL (Pine: score >= 3/5) ─────────────────────
  const buildReason = (isLong) => [
    isLong
      ? (chochBull?'CHoCH↑': bosBull?'BOS↑': smcBull?'Swing↑':'ST↑')
      : (chochBear?'CHoCH↓': bosBear?'BOS↓': !smcBull?'Swing↓':'ST↓'),
    isLong ? (rsiBull &&'RSI✓')  : (rsiBear &&'RSI✓'),
    isLong ? (macdBull&&'MACD✓') : (macdBear&&'MACD✓'),
    isLong ? (emasBull&&'EMA✓')  : (emasBear&&'EMA✓'),
    isLong ? (volBull &&'Vol✓')  : (volBear &&'Vol✓'),
    'MTF✓',
  ].filter(Boolean).join(' · ');

  if (bullCross) {
    const score = (smcBull?1:0)+(rsiBull?1:0)+(macdBull?1:0)+(emasBull?1:0)+(volBull?1:0);
    if (score < 3) return null;
    return {
      direction:'LONG', score, maxScore:5,
      close:C.at(-1), atr:atrV, time:candles.at(-1).time,
      rsi:rsiV.at(-1).toFixed(1),
      tp1:(C.at(-1)+atrV*2.0).toFixed(5),
      tp2:(C.at(-1)+atrV*3.5).toFixed(5),
      tp3:(C.at(-1)+atrV*5.0).toFixed(5),
      sl: (C.at(-1)-atrV*1.0).toFixed(5),
      konfluence: buildReason(true),
    };
  }

  if (bearCross) {
    const score = (!smcBull?1:0)+(rsiBear?1:0)+(macdBear?1:0)+(emasBear?1:0)+(volBear?1:0);
    if (score < 3) return null;
    return {
      direction:'SHORT', score, maxScore:5,
      close:C.at(-1), atr:atrV, time:candles.at(-1).time,
      rsi:rsiV.at(-1).toFixed(1),
      tp1:(C.at(-1)-atrV*2.0).toFixed(5),
      tp2:(C.at(-1)-atrV*3.5).toFixed(5),
      tp3:(C.at(-1)-atrV*5.0).toFixed(5),
      sl: (C.at(-1)+atrV*1.0).toFixed(5),
      konfluence: buildReason(false),
    };
  }
  return null;
}

// ── TELEGRAM ──────────────────────────────────────────────────────
function telegram(text) {
  return new Promise((res,rej) => {
    const body = JSON.stringify({ chat_id:CHAT, text, parse_mode:'HTML' });
    const req = https.request({
      hostname:'api.telegram.org', path:`/bot${TOKEN}/sendMessage`, method:'POST',
      headers:{ 'Content-Type':'application/json','Content-Length':Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>res(JSON.parse(d))); });
    req.on('error',rej);
    req.write(body); req.end();
  });
}

function formatMesaj(sig, isim, tf) {
  const al  = sig.direction==='LONG';
  const ico = al ? '🟢' : '🔴';
  const yon = al ? 'AL' : 'SAT';
  const rr  = (2.0/1.0).toFixed(1);
  return `${ico} <b>${yon} — Pro Cloud v2</b>

📊 ${isim} · ${tf.toUpperCase()}
⏰ ${now()}
☁️ <i>GitHub Actions · bilgisayar kapalı olsa da çalışır</i>

▸ Giriş:  <b>${sig.close.toFixed ? sig.close.toFixed(5) : sig.close}</b>
✖ Stop:   ${sig.sl}
✔ TP1:   ${sig.tp1}
✔ TP2:   ${sig.tp2}
✔ TP3:   ${sig.tp3}

Skor ${sig.score}/${sig.maxScore} · RSI ${sig.rsi} · RR 1:${rr}
${sig.konfluence}`;
}

// ── MAIN ──────────────────────────────────────────────────────────
async function main() {
  log('━━━ Pro Cloud v2 — Tam Sistem (SuperTrend+MTF+SMC+DEMA)' + (DRY?' [DRY]':'') + ' ━━━');
  const state = loadState();
  let yeniSinyal = false;

  for (const { yahoo, isim, tf, range } of SEMBOLLER) {
    try {
      log(`Taranıyor: ${isim} (${tf})`);
      const sig = await analiz(yahoo, tf, range);

      if (!sig) { log(`  Sinyal yok`); continue; }

      const key    = `${isim}_${tf}`;
      const lastTs = state[key] || 0;
      if (sig.time <= lastTs) { log(`  Sinyal biliniyor`); continue; }

      log(`  YENİ → ${sig.direction} @ ${sig.close} | Skor:${sig.score}/${sig.maxScore} | ${sig.konfluence}`);
      const msg = formatMesaj(sig, isim, tf);

      if (!DRY) {
        const r = await telegram(msg);
        if (r.ok) log('  Telegram ✓'); else log('  Telegram HATA:', r.description);
      } else {
        log('[DRY]\n' + msg);
      }

      state[key] = sig.time;
      yeniSinyal = true;
    } catch(e) {
      log(`  HATA ${isim}: ${e.message}`);
    }
  }

  saveState(state);
  log(`Tamamlandı. Yeni sinyal: ${yeniSinyal}`);
}

main().catch(e => { log('FATAL:', e.message); process.exit(1); });

/**
 * propicks_score.mjs — Pure scoring functions + VIX-based regime detection
 * No browser, no I/O (except detectRegime which fetches Yahoo Finance).
 */

import https from 'https';

// ── SCORE STOCK ───────────────────────────────────────────────────────────────

/**
 * scoreStock — computes 0-100 score with breakdown
 *
 * @param {object} stock  — scraped stock object
 * @param {string} regime — 'bull' | 'bear' | 'panic' | 'sideways' | 'neutral'
 * @returns {{ score: number, breakdown: object }}
 */
export function scoreStock(stock, regime = 'neutral') {
  let ai_signal    = 0;
  let momentum     = 0;
  let fundamental  = 0;
  let quality      = 0;
  let penalty      = 0;

  // ── AI Signal (0-25) ──────────────────────────────────────────────────────
  const stratCount = stock.strategy_count ?? (Array.isArray(stock.strategies) ? stock.strategies.length : 1);
  if      (stratCount >= 3) ai_signal = 23;
  else if (stratCount === 2) ai_signal = 18;
  else                       ai_signal = 10;

  if (stock.is_new) ai_signal = Math.min(25, ai_signal + 5);

  // ── Momentum (0-25) ───────────────────────────────────────────────────────
  const chg = stock.momentum_1d ?? 0;
  if      (chg >  3) momentum = 20;
  else if (chg >  1) momentum = 16;
  else if (chg >= 0) momentum = 12;
  else if (chg > -1) momentum = 8;
  else if (chg > -3) momentum = 4;
  else               momentum = 0;

  // Regime adjustments on momentum
  if (regime === 'panic' || regime === 'bear') {
    momentum = Math.round(momentum * 0.6);
  } else if (regime === 'bull') {
    momentum = Math.min(25, Math.round(momentum * 1.2));
  }

  // ── Fundamental (0-30) ───────────────────────────────────────────────────
  const pe = stock.pe;
  if      (pe == null || pe === 0) fundamental = 10; // missing — neutral
  else if (pe > 0 && pe <= 10)    fundamental = 25;  // deep value
  else if (pe > 10 && pe <= 15)   fundamental = 20;
  else if (pe > 15 && pe <= 20)   fundamental = 15;
  else if (pe > 20 && pe <= 30)   fundamental = 10;
  else if (pe > 30 && pe <= 50)   fundamental = 5;
  else if (pe < 0 || pe > 50)     fundamental = 0;

  // Forward P/E bonus: growing earnings (forward < trailing)
  const fpe = stock.forward_pe;
  if (fpe != null && pe != null && pe > 0 && fpe > 0 && fpe < pe) {
    fundamental = Math.min(30, fundamental + 5);
  }

  // ── Quality (0-20) ───────────────────────────────────────────────────────
  const risk = (stock.risk_level ?? '').toLowerCase();
  if      (risk === 'low')    quality = 15;
  else if (risk === 'medium') quality = 8;
  else if (risk === 'high')   quality = 0;
  else                        quality = 0;

  if (stock.ai_rationale && stock.ai_rationale.length > 10) {
    quality = Math.min(20, quality + 5);
  }

  // ── Penalties ─────────────────────────────────────────────────────────────
  // BIST masked ticker pattern e.g. ABCD:EFGH (cross-market masked)
  if (/^[A-Z]{2,4}:[A-Z]{3,5}$/.test(stock.ticker ?? '')) {
    penalty = -20;
  }

  // ── Final Score ──────────────────────────────────────────────────────────
  const raw = ai_signal + momentum + fundamental + quality + penalty;
  const score = Math.max(0, Math.min(100, Math.round(raw)));

  return {
    score,
    breakdown: {
      ai_signal,
      momentum,
      fundamental,
      quality,
      penalty,
    },
  };
}

// ── DETECT REGIME ─────────────────────────────────────────────────────────────

/**
 * detectRegime — fetches VIX from Yahoo Finance and classifies market regime
 * @returns {Promise<'bull'|'bear'|'panic'|'sideways'|'neutral'>}
 */
export async function detectRegime() {
  const VIX_URL = 'https://query1.finance.yahoo.com/v8/finance/chart/%5EVIX?interval=1d&range=5d';

  try {
    const data = await fetchJson(VIX_URL);
    const closes = data?.chart?.result?.[0]?.indicators?.quote?.[0]?.close ?? [];
    const validCloses = closes.filter(v => v != null && !isNaN(v));
    if (validCloses.length === 0) {
      console.log('[Regime] No VIX data available — using neutral');
      return 'neutral';
    }
    const vix = validCloses[validCloses.length - 1];
    console.log(`[Regime] VIX = ${vix.toFixed(2)}`);

    if      (vix > 30) return 'panic';
    else if (vix > 20) return 'bear';
    else if (vix > 15) return 'sideways';
    else               return 'bull';
  } catch (e) {
    console.log(`[Regime] VIX fetch error: ${e.message.slice(0, 80)} — using neutral`);
    return 'neutral';
  }
}

// ── HTTP HELPER ───────────────────────────────────────────────────────────────

function fetchJson(url) {
  return new Promise((resolve, reject) => {
    const req = https.get(url, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (compatible; investbot/1.0)',
        'Accept': 'application/json',
      },
      timeout: 10_000,
    }, res => {
      let body = '';
      res.on('data', c => { body += c; });
      res.on('end', () => {
        try { resolve(JSON.parse(body)); }
        catch (e) { reject(new Error(`JSON parse failed: ${e.message}`)); }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('VIX request timed out')); });
  });
}

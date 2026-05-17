/**
 * propicks_diff.mjs — Portfolio diff computation and signal generation
 * Pure functions — no browser, no I/O.
 */

// ── COMPUTE DIFF ──────────────────────────────────────────────────────────────

/**
 * computeDiff — compares today's stocks against previous day snapshot
 *
 * @param {object[]} todayStocks   — current scrape results (enriched with score)
 * @param {object[]} prevStocks    — previous snapshot rows from DB
 * @returns {DiffResult}
 */
export function computeDiff(todayStocks, prevStocks) {
  const todayMap = new Map(todayStocks.map(s => [s.ticker, s]));
  const prevMap  = new Map(prevStocks.map(s => [s.ticker, s]));

  const new_entries  = [];
  const exits        = [];
  const score_up     = [];
  const score_down   = [];
  const sector_rotation = [];
  const unchanged    = [];

  // New entries: in today but not in prev
  for (const [ticker, stock] of todayMap) {
    if (!prevMap.has(ticker)) {
      new_entries.push(stock);
    }
  }

  // Exits: in prev but not in today
  for (const [ticker, stock] of prevMap) {
    if (!todayMap.has(ticker)) {
      exits.push(stock);
    }
  }

  // Score changes and sector rotation for stocks present in both
  for (const [ticker, stock] of todayMap) {
    const prev = prevMap.get(ticker);
    if (!prev) continue;

    const prevScore = prev.score ?? 0;
    const delta     = (stock.score ?? 0) - prevScore;

    if (delta > 8) {
      score_up.push({ stock, prevScore, delta });
    } else if (delta < -8) {
      score_down.push({ stock, prevScore, delta });
    } else {
      unchanged.push(stock);
    }

    // Sector rotation: sector present in both and changed
    if (stock.sector && prev.sector && stock.sector !== prev.sector) {
      sector_rotation.push({ from: prev.sector, to: stock.sector, ticker });
    }
  }

  // Sort by delta magnitude for easy prioritisation
  score_up.sort((a, b) => b.delta - a.delta);
  score_down.sort((a, b) => a.delta - b.delta);

  return {
    new_entries,
    exits,
    score_up,
    score_down,
    sector_rotation,
    unchanged,
  };
}

// ── GENERATE SIGNALS ──────────────────────────────────────────────────────────

/**
 * generateSignals — maps diff result to signal objects ready for DB/Telegram
 *
 * @param {DiffResult} diff
 * @param {string}     runId
 * @param {string}     date   — ISO date string e.g. '2026-05-17'
 * @returns {SignalObject[]}
 */
export function generateSignals(diff, runId, date) {
  const signals = [];
  const now     = new Date().toISOString();

  // ── NEW ENTRIES ──────────────────────────────────────────────────────────
  for (const stock of diff.new_entries) {
    const score    = stock.score ?? 0;
    const priority = score >= 70 ? 'HIGH' : score >= 50 ? 'MEDIUM' : 'LOW';
    signals.push({
      run_id:       runId,
      signal_date:  date,
      ticker:       stock.ticker,
      company_name: stock.company_name ?? null,
      market:       stock.market ?? null,
      signal_type:  'NEW_ENTRY',
      priority,
      score,
      prev_score:   null,
      score_delta:  null,
      strategies:   normaliseStrategies(stock),
      details:      buildDetails(stock, null, null),
      created_at:   now,
    });
  }

  // ── EXITS ────────────────────────────────────────────────────────────────
  for (const stock of diff.exits) {
    const score    = stock.score ?? 0;
    const priority = score >= 70 ? 'MEDIUM' : 'LOW'; // exits are warnings
    signals.push({
      run_id:       runId,
      signal_date:  date,
      ticker:       stock.ticker,
      company_name: stock.company_name ?? null,
      market:       stock.market ?? null,
      signal_type:  'EXIT',
      priority,
      score:        null,
      prev_score:   score,
      score_delta:  null,
      strategies:   normaliseStrategies(stock),
      details:      `Removed from ProPicks. Previous score: ${score}`,
      created_at:   now,
    });
  }

  // ── SCORE UP ─────────────────────────────────────────────────────────────
  for (const { stock, prevScore, delta } of diff.score_up) {
    const priority = delta >= 20 ? 'MEDIUM' : 'LOW';
    signals.push({
      run_id:       runId,
      signal_date:  date,
      ticker:       stock.ticker,
      company_name: stock.company_name ?? null,
      market:       stock.market ?? null,
      signal_type:  'SCORE_UP',
      priority,
      score:        stock.score ?? null,
      prev_score:   prevScore,
      score_delta:  delta,
      strategies:   normaliseStrategies(stock),
      details:      buildDetails(stock, prevScore, delta),
      created_at:   now,
    });
  }

  // ── SCORE DOWN ───────────────────────────────────────────────────────────
  for (const { stock, prevScore, delta } of diff.score_down) {
    const priority = delta <= -20 ? 'MEDIUM' : 'LOW';
    signals.push({
      run_id:       runId,
      signal_date:  date,
      ticker:       stock.ticker,
      company_name: stock.company_name ?? null,
      market:       stock.market ?? null,
      signal_type:  'SCORE_DOWN',
      priority,
      score:        stock.score ?? null,
      prev_score:   prevScore,
      score_delta:  delta,
      strategies:   normaliseStrategies(stock),
      details:      buildDetails(stock, prevScore, delta),
      created_at:   now,
    });
  }

  // ── SECTOR ROTATION ───────────────────────────────────────────────────────
  for (const rot of diff.sector_rotation) {
    signals.push({
      run_id:       runId,
      signal_date:  date,
      ticker:       rot.ticker,
      company_name: null,
      market:       null,
      signal_type:  'SECTOR_ROTATION',
      priority:     'LOW',
      score:        null,
      prev_score:   null,
      score_delta:  null,
      strategies:   [],
      details:      `Sector changed: ${rot.from} → ${rot.to}`,
      created_at:   now,
    });
  }

  return signals;
}

// ── HELPERS ───────────────────────────────────────────────────────────────────

function normaliseStrategies(stock) {
  if (Array.isArray(stock.strategies)) return stock.strategies;
  if (typeof stock.strategies === 'string' && stock.strategies.length > 0) {
    return stock.strategies.split(',');
  }
  if (stock.strategy_name) return [stock.strategy_name];
  return [];
}

function buildDetails(stock, prevScore, delta) {
  const parts = [];
  if (stock.momentum_1d != null) parts.push(`1d: ${stock.momentum_1d > 0 ? '+' : ''}${stock.momentum_1d.toFixed(2)}%`);
  if (stock.pe != null)          parts.push(`P/E: ${stock.pe.toFixed(1)}`);
  if (stock.risk_level)          parts.push(`Risk: ${stock.risk_level}`);
  if (prevScore != null && delta != null) parts.push(`Score: ${prevScore}→${(prevScore + delta)}`);
  if (stock.ai_rationale)        parts.push(stock.ai_rationale.slice(0, 100));
  return parts.join(' · ') || null;
}

/**
 * propicks_run.mjs — Main orchestrator
 *
 * Usage:
 *   node scripts/propicks_run.mjs --mode=session-check
 *   node scripts/propicks_run.mjs --mode=discover
 *   node scripts/propicks_run.mjs --mode=dry
 *   node scripts/propicks_run.mjs --mode=normal          (default)
 *   node scripts/propicks_run.mjs --mode=test-telegram
 */

import path from 'path';
import fs   from 'fs';
import { fileURLToPath } from 'url';

import {
  initDb, startRun, finishRun,
  saveSnapshot, loadPrevSnapshot,
  saveSignal, logError,
} from './propicks_db.mjs';

import { createBrowser, closeBrowser }  from './propicks_browser.mjs';
import { checkSession }                  from './propicks_session.mjs';
import { discoverStrategies }            from './propicks_discover.mjs';
import { scrapeStrategy }                from './propicks_scrape.mjs';
import { scoreStock, detectRegime }      from './propicks_score.mjs';
import { computeDiff, generateSignals }  from './propicks_diff.mjs';
import { sendTelegram, sendSignals }     from './propicks_telegram.mjs';
import * as db                           from './propicks_db.mjs';

const ROOT     = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const DATA_DIR = path.join(ROOT, 'data');
const LOG_DIR  = path.join(ROOT, 'data', 'logs');

fs.mkdirSync(DATA_DIR, { recursive: true });
fs.mkdirSync(LOG_DIR,  { recursive: true });

// ── LOGGING ───────────────────────────────────────────────────────────────────

const logLines = [];
function log(...args) {
  const ts   = new Date().toLocaleString('tr-TR', { timeZone: 'Europe/Istanbul' });
  const line = `[${ts}] ${args.join(' ')}`;
  console.log(line);
  logLines.push(line);
}

function flushLog(runId) {
  try {
    const logFile = path.join(LOG_DIR, `${runId}.log`);
    fs.writeFileSync(logFile, logLines.join('\n') + '\n');
  } catch { /* non-fatal */ }
}

// ── ARG PARSING ───────────────────────────────────────────────────────────────

function parseArgs() {
  const modeArg = process.argv.find(a => a.startsWith('--mode='));
  return {
    mode:    modeArg ? modeArg.replace('--mode=', '') : 'normal',
    offline: process.argv.includes('--offline'),
  };
}

// ── MERGE BY TICKER ───────────────────────────────────────────────────────────

/**
 * mergeByTicker — consolidates duplicate tickers from multiple strategies
 * and re-scores using updated strategy_count.
 */
function mergeByTicker(stocks, regime) {
  const map = new Map();

  for (const stock of stocks) {
    const key = stock.ticker;
    if (!map.has(key)) {
      map.set(key, {
        ...stock,
        strategy_count: 1,
        strategies:     [stock.strategy_name].filter(Boolean),
      });
    } else {
      const existing = map.get(key);
      existing.strategy_count++;
      if (stock.strategy_name && !existing.strategies.includes(stock.strategy_name)) {
        existing.strategies.push(stock.strategy_name);
      }
      if (stock.is_new)                                          existing.is_new       = true;
      if (existing.company_name == null && stock.company_name)  existing.company_name = stock.company_name;
      if (existing.pe         == null && stock.pe != null)      existing.pe           = stock.pe;
      if (existing.forward_pe == null && stock.forward_pe != null) existing.forward_pe = stock.forward_pe;
      if (existing.risk_level == null && stock.risk_level)      existing.risk_level   = stock.risk_level;
      if (existing.ai_rationale == null && stock.ai_rationale)  existing.ai_rationale = stock.ai_rationale;
      if (existing.sector     == null && stock.sector)          existing.sector       = stock.sector;
    }
  }

  // Re-score with updated strategy_count
  return [...map.values()].map(stock => {
    const { score, breakdown } = scoreStock(stock, regime);
    return { ...stock, score, score_breakdown: breakdown };
  }).sort((a, b) => (b.score ?? 0) - (a.score ?? 0));
}

// ── MAIN ──────────────────────────────────────────────────────────────────────

async function main() {
  const { mode, offline } = parseArgs();
  const TOKEN   = process.env.TELEGRAM_BOT_TOKEN;
  const CHAT    = process.env.TELEGRAM_CHAT_ID;
  const runId   = `run_${Date.now()}`;
  const today   = new Date().toISOString().slice(0, 10);

  log('═'.repeat(60));
  log(`  ProPicks AI — ${mode.toUpperCase()} — ${today}`);
  log(`  runId: ${runId}`);
  log('═'.repeat(60));

  initDb();
  startRun(runId, mode);

  // ── MODE: test-telegram ───────────────────────────────────────────────────
  if (mode === 'test-telegram') {
    if (!TOKEN || !CHAT) {
      log('ERROR: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID missing');
      finishRun(runId, 'error', { notes: 'Missing Telegram credentials' });
      flushLog(runId);
      process.exit(1);
    }
    try {
      const ts   = new Date().toLocaleTimeString('tr-TR', { timeZone: 'Europe/Istanbul' });
      const resp = await sendTelegram(
        `✅ <b>ProPicks AI — Test</b>\n\nTelegram bağlantısı çalışıyor.\n🕐 ${ts}`,
        TOKEN, CHAT
      );
      log(resp.ok ? '✓ Telegram test OK' : `✗ Telegram test FAILED: ${resp.description}`);
      finishRun(runId, resp.ok ? 'success' : 'error', { notes: resp.description ?? null });
    } catch (e) {
      log(`Telegram test error: ${e.message}`);
      finishRun(runId, 'error', { notes: e.message.slice(0, 200) });
    }
    flushLog(runId);
    return;
  }

  // ── MODE: session-check ───────────────────────────────────────────────────
  if (mode === 'session-check') {
    log('Checking session status...');
    const result = await checkSession();
    log(`Session status: ${result.status}`);
    if (result.url)   log(`  URL: ${result.url}`);
    if (result.error) log(`  Error: ${result.error}`);
    finishRun(runId, 'success', { notes: result.status });
    flushLog(runId);
    return;
  }

  // ── MODE: discover ────────────────────────────────────────────────────────
  if (mode === 'discover') {
    let handle = null;
    try {
      handle = await createBrowser(true);
      const strategies = await discoverStrategies(handle.page);
      log(`\nDiscovered ${strategies.length} strategies:`);
      for (const s of strategies) {
        log(`  [${s.market}] ${s.slug.padEnd(35)} "${s.name}"`);
      }
      finishRun(runId, 'success', { notes: `${strategies.length} strategies` });
    } catch (e) {
      log(`Discover error: ${e.message}`);
      logError(runId, 'DISCOVER_ERROR', 'discover', e.message, null);
      finishRun(runId, 'error', { notes: e.message.slice(0, 200) });
    } finally {
      if (handle) await closeBrowser(handle);
    }
    flushLog(runId);
    return;
  }

  // ── MODE: dry | normal ────────────────────────────────────────────────────

  const isDry = mode === 'dry';

  if (!isDry && (!TOKEN || !CHAT)) {
    log('ERROR: TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID missing for normal mode');
    finishRun(runId, 'error', { notes: 'Missing Telegram credentials' });
    flushLog(runId);
    process.exit(1);
  }

  // ── Step 1: Session check ─────────────────────────────────────────────────
  if (!offline) {
    log('Checking session...');
    const sessionResult = await checkSession();
    log(`Session status: ${sessionResult.status}`);

    if (sessionResult.status !== 'AUTH_OK') {
      const msg = `Session not authenticated: ${sessionResult.status}`;
      log(`FATAL: ${msg}`);
      logError(runId, 'AUTH_FAILED', 'session_check', msg, null);
      finishRun(runId, 'error', { notes: msg });

      if (!isDry && TOKEN && CHAT) {
        try {
          await sendTelegram(
            `⚠️ <b>ProPicks AI — Auth Hatası</b>\n\nOturum durumu: ${sessionResult.status}\n\n` +
            `propicks_auth_kur.mjs çalıştırarak oturumu yenile.`,
            TOKEN, CHAT
          );
        } catch { /* non-fatal */ }
      }
      flushLog(runId);
      process.exit(1);
    }
    log('Session OK — proceeding');
  } else {
    log('[OFFLINE] Skipping session check');
  }

  // ── Step 2: Detect regime ─────────────────────────────────────────────────
  let regime = 'neutral';
  if (!offline) {
    try {
      regime = await detectRegime();
      log(`Market regime: ${regime}`);
    } catch (e) {
      log(`Regime detection failed: ${e.message} — using neutral`);
    }
  } else {
    log('[OFFLINE] Skipping regime detection — using neutral');
  }

  // ── Steps 3-4: Discover & Scrape ─────────────────────────────────────────
  const allStocks = [];
  let handle = null;

  try {
    handle = await createBrowser(true);
    const { page } = handle;

    log('Discovering strategies...');
    const strategies = await discoverStrategies(page);
    log(`Scraping ${strategies.length} strategies...`);

    for (const strategy of strategies) {
      log(`  Scraping: ${strategy.slug} [${strategy.market}]`);
      try {
        const rawStocks = await scrapeStrategy(page, strategy.slug, strategy.name, strategy.market, runId);
        log(`    → ${rawStocks.length} stocks`);

        for (const stock of rawStocks) {
          allStocks.push({
            ...stock,
            strategy_slug: strategy.slug,
            strategy_name: strategy.name,
            market:        strategy.market,
            snapshot_date: today,
          });
        }
      } catch (e) {
        log(`  Strategy ${strategy.slug} failed: ${e.message.slice(0, 100)}`);
        logError(runId, 'STRATEGY_FAILED', strategy.slug, e.message, null);
      }

      await new Promise(r => setTimeout(r, 1500));
    }

    log(`Total raw stocks: ${allStocks.length}`);

    // ── Step 5: Merge & Re-score ──────────────────────────────────────────
    const merged = mergeByTicker(allStocks, regime);
    log(`After ticker merge: ${merged.length} unique stocks`);

    // ── Step 6: Load prev snapshot & compute diff ─────────────────────────
    log('Loading previous snapshot...');
    const prevStocks = loadPrevSnapshot(today);
    log(`Previous snapshot: ${prevStocks.length} records`);

    let signals = [];
    if (prevStocks.length > 0) {
      const diff = computeDiff(merged, prevStocks);
      signals    = generateSignals(diff, runId, today);
      log(`Diff: ${diff.new_entries.length} new, ${diff.exits.length} exits, ` +
          `${diff.score_up.length} up, ${diff.score_down.length} down`);
      log(`Generated ${signals.length} signals`);
    } else {
      log('No previous snapshot — baseline created, no signals on first run');
    }

    // ── Step 7: Persist ───────────────────────────────────────────────────
    log('Saving snapshots...');
    for (const stock of merged) {
      saveSnapshot(runId, stock);
    }

    log('Saving signals...');
    for (const signal of signals) {
      saveSignal(runId, signal);
    }

    // ── Step 8: Send Telegram ─────────────────────────────────────────────
    const newCount  = signals.filter(s => s.signal_type === 'NEW_ENTRY').length;
    const exitCount = signals.filter(s => s.signal_type === 'EXIT').length;

    if (signals.length > 0) {
      log(`Sending ${signals.length} signals (dry=${isDry})...`);
      await sendSignals(signals, merged, regime, db, runId, TOKEN, CHAT, isDry);
    } else {
      log('No signals to send');
      if (!isDry && TOKEN && CHAT) {
        const ts = new Date().toLocaleTimeString('tr-TR', { timeZone: 'Europe/Istanbul' });
        await sendTelegram(
          `📊 <b>ProPicks AI — Günlük Tarama</b>\n\n📅 ${today} · Rejim: ${regime}\n` +
          `Hisse sayısı: ${merged.length}\nDeğişiklik tespit edilmedi.\n🕐 ${ts}`,
          TOKEN, CHAT
        ).catch(e => log(`No-change notification error: ${e.message}`));
      }
    }

    // ── Summary ───────────────────────────────────────────────────────────
    log('');
    log('═'.repeat(60));
    log(`  TAMAMLANDI`);
    log(`  Taranan hisse:  ${merged.length}`);
    log(`  Yeni eklenen:   ${newCount}`);
    log(`  Çıkarılan:      ${exitCount}`);
    log(`  Sinyal sayısı:  ${signals.length}`);
    log(`  Rejim:          ${regime}`);
    log('═'.repeat(60));

    finishRun(runId, 'success', {
      regime,
      total_stocks: merged.length,
      new_entries:  newCount,
      exits:        exitCount,
    });

  } catch (e) {
    log(`CRITICAL ERROR: ${e.message}`);
    log(e.stack ?? '');
    logError(runId, 'CRITICAL', 'main', e.message, null);
    finishRun(runId, 'error', { notes: e.message.slice(0, 200) });

    if (!isDry && TOKEN && CHAT) {
      try {
        await sendTelegram(
          `⚠️ <b>ProPicks AI — Kritik Hata</b>\n\n${e.message.slice(0, 300)}`,
          TOKEN, CHAT
        );
      } catch { /* non-fatal */ }
    }

    flushLog(runId);
    process.exit(1);
  } finally {
    if (handle) await closeBrowser(handle);
  }

  flushLog(runId);
}

main().catch(e => {
  console.error('[FATAL]', e.message);
  console.error(e.stack ?? '');
  process.exit(1);
});

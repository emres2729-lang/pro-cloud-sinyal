/**
 * propicks_db.mjs — Persistent storage layer
 * Primary: better-sqlite3 (sync)
 * Fallback: JSON file storage (same interface)
 */

import fs   from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const ROOT    = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const DB_FILE = path.join(ROOT, 'data', 'propicks.db');
const JSON_FILE = path.join(ROOT, 'data', 'propicks_json.json');

const now = () => new Date().toISOString();
const log = (...a) => console.log(`[DB ${new Date().toLocaleTimeString('tr-TR')}]`, ...a);

// ── SQLITE BACKEND ────────────────────────────────────────────────────────────

const SCHEMA = `
CREATE TABLE IF NOT EXISTS runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT UNIQUE NOT NULL,
  mode TEXT NOT NULL,
  started_at TEXT NOT NULL,
  finished_at TEXT,
  status TEXT DEFAULT 'running',
  regime TEXT,
  total_stocks INTEGER DEFAULT 0,
  new_entries INTEGER DEFAULT 0,
  exits INTEGER DEFAULT 0,
  notes TEXT
);

CREATE TABLE IF NOT EXISTS snapshots (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  snapshot_date TEXT NOT NULL,
  market TEXT NOT NULL,
  strategy_slug TEXT NOT NULL,
  strategy_name TEXT,
  ticker TEXT NOT NULL,
  company_name TEXT,
  sector TEXT,
  score INTEGER,
  score_breakdown TEXT,
  pe REAL,
  forward_pe REAL,
  momentum_1d REAL,
  risk_level TEXT,
  ai_rationale TEXT,
  is_new INTEGER DEFAULT 0,
  strategy_count INTEGER DEFAULT 1,
  strategies TEXT,
  scraped_at TEXT NOT NULL,
  UNIQUE(snapshot_date, strategy_slug, ticker)
);

CREATE TABLE IF NOT EXISTS signals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT NOT NULL,
  signal_date TEXT NOT NULL,
  ticker TEXT NOT NULL,
  company_name TEXT,
  market TEXT,
  signal_type TEXT NOT NULL,
  priority TEXT NOT NULL DEFAULT 'LOW',
  score INTEGER,
  prev_score INTEGER,
  score_delta INTEGER,
  strategies TEXT,
  details TEXT,
  telegram_sent INTEGER DEFAULT 0,
  created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS telegram_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT,
  message_hash TEXT UNIQUE NOT NULL,
  priority TEXT,
  ticker TEXT,
  signal_type TEXT,
  message_preview TEXT,
  sent_at TEXT,
  api_response TEXT
);

CREATE TABLE IF NOT EXISTS errors (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  run_id TEXT,
  error_code TEXT NOT NULL,
  context TEXT,
  message TEXT,
  screenshot_path TEXT,
  created_at TEXT NOT NULL
);
`;

// ── TRY TO LOAD BETTER-SQLITE3 ────────────────────────────────────────────────

let sqlite3 = null;
let usingSqlite = false;

try {
  const mod = await import('better-sqlite3');
  sqlite3 = mod.default;
  usingSqlite = true;
  log('better-sqlite3 loaded — using SQLite backend');
} catch {
  log('better-sqlite3 not available — falling back to JSON backend');
}

// ── SQLITE IMPLEMENTATION ─────────────────────────────────────────────────────

let db = null;

function initSqlite() {
  fs.mkdirSync(path.dirname(DB_FILE), { recursive: true });
  db = sqlite3(DB_FILE);
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  db.exec(SCHEMA);
  return true;
}

function startRunSqlite(runId, mode) {
  db.prepare(
    'INSERT OR IGNORE INTO runs (run_id, mode, started_at, status) VALUES (?, ?, ?, ?)'
  ).run(runId, mode, now(), 'running');
}

function finishRunSqlite(runId, status, stats = {}) {
  db.prepare(
    `UPDATE runs SET finished_at=?, status=?, regime=?, total_stocks=?, new_entries=?, exits=?, notes=?
     WHERE run_id=?`
  ).run(
    now(), status,
    stats.regime ?? null,
    stats.total_stocks ?? 0,
    stats.new_entries ?? 0,
    stats.exits ?? 0,
    stats.notes ?? null,
    runId
  );
}

function saveSnapshotSqlite(runId, stock) {
  try {
    db.prepare(`
      INSERT OR IGNORE INTO snapshots
        (run_id, snapshot_date, market, strategy_slug, strategy_name, ticker, company_name,
         sector, score, score_breakdown, pe, forward_pe, momentum_1d, risk_level,
         ai_rationale, is_new, strategy_count, strategies, scraped_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    `).run(
      runId,
      stock.snapshot_date ?? new Date().toISOString().slice(0, 10),
      stock.market ?? 'OTHER',
      stock.strategy_slug ?? '',
      stock.strategy_name ?? null,
      stock.ticker,
      stock.company_name ?? null,
      stock.sector ?? null,
      stock.score ?? null,
      stock.score_breakdown ? JSON.stringify(stock.score_breakdown) : null,
      stock.pe ?? null,
      stock.forward_pe ?? null,
      stock.momentum_1d ?? null,
      stock.risk_level ?? null,
      stock.ai_rationale ?? null,
      stock.is_new ? 1 : 0,
      stock.strategy_count ?? 1,
      Array.isArray(stock.strategies) ? stock.strategies.join(',') : (stock.strategies ?? null),
      now()
    );
  } catch (e) {
    log('saveSnapshot error:', e.message.slice(0, 100));
  }
}

function loadPrevSnapshotSqlite(date) {
  // Find most recent snapshot_date strictly before date
  const prevDate = db.prepare(
    `SELECT MAX(snapshot_date) as d FROM snapshots WHERE snapshot_date < ?`
  ).get(date);
  if (!prevDate?.d) return [];
  const rows = db.prepare(
    `SELECT * FROM snapshots WHERE snapshot_date = ?`
  ).all(prevDate.d);
  return rows.map(r => ({
    ...r,
    score_breakdown: r.score_breakdown ? JSON.parse(r.score_breakdown) : null,
    strategies: r.strategies ? r.strategies.split(',') : [],
    is_new: !!r.is_new,
  }));
}

function saveSignalSqlite(runId, signal) {
  try {
    db.prepare(`
      INSERT INTO signals
        (run_id, signal_date, ticker, company_name, market, signal_type, priority,
         score, prev_score, score_delta, strategies, details, telegram_sent, created_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    `).run(
      runId,
      signal.signal_date,
      signal.ticker,
      signal.company_name ?? null,
      signal.market ?? null,
      signal.signal_type,
      signal.priority ?? 'LOW',
      signal.score ?? null,
      signal.prev_score ?? null,
      signal.score_delta ?? null,
      Array.isArray(signal.strategies) ? signal.strategies.join(',') : (signal.strategies ?? null),
      signal.details ?? null,
      0,
      now()
    );
  } catch (e) {
    log('saveSignal error:', e.message.slice(0, 100));
  }
}

function wasTelegramSentSqlite(hash) {
  const row = db.prepare('SELECT id FROM telegram_log WHERE message_hash = ?').get(hash);
  return !!row;
}

function logTelegramSqlite(runId, hash, priority, ticker, signalType, preview, apiResponse) {
  try {
    db.prepare(`
      INSERT OR IGNORE INTO telegram_log
        (run_id, message_hash, priority, ticker, signal_type, message_preview, sent_at, api_response)
      VALUES (?,?,?,?,?,?,?,?)
    `).run(
      runId ?? null,
      hash,
      priority ?? null,
      ticker ?? null,
      signalType ?? null,
      preview?.slice(0, 200) ?? null,
      now(),
      apiResponse ? JSON.stringify(apiResponse) : null
    );
  } catch (e) {
    log('logTelegram error:', e.message.slice(0, 100));
  }
}

function logErrorSqlite(runId, errorCode, context, message, screenshotPath) {
  try {
    db.prepare(`
      INSERT INTO errors (run_id, error_code, context, message, screenshot_path, created_at)
      VALUES (?,?,?,?,?,?)
    `).run(
      runId ?? null,
      errorCode,
      context ?? null,
      message?.slice(0, 500) ?? null,
      screenshotPath ?? null,
      now()
    );
  } catch (e) {
    log('logError error:', e.message.slice(0, 100));
  }
}

// ── JSON FALLBACK BACKEND ─────────────────────────────────────────────────────

function loadJson() {
  try { return JSON.parse(fs.readFileSync(JSON_FILE, 'utf8')); }
  catch { return { runs: [], snapshots: [], signals: [], telegram_log: [], errors: [] }; }
}

function saveJson(data) {
  fs.mkdirSync(path.dirname(JSON_FILE), { recursive: true });
  fs.writeFileSync(JSON_FILE, JSON.stringify(data, null, 2));
}

function initJson() {
  const data = loadJson();
  if (!data.runs) data.runs = [];
  if (!data.snapshots) data.snapshots = [];
  if (!data.signals) data.signals = [];
  if (!data.telegram_log) data.telegram_log = [];
  if (!data.errors) data.errors = [];
  saveJson(data);
  return true;
}

function startRunJson(runId, mode) {
  const data = loadJson();
  if (!data.runs.find(r => r.run_id === runId)) {
    data.runs.push({ run_id: runId, mode, started_at: now(), status: 'running' });
    saveJson(data);
  }
}

function finishRunJson(runId, status, stats = {}) {
  const data = loadJson();
  const run = data.runs.find(r => r.run_id === runId);
  if (run) {
    Object.assign(run, {
      finished_at: now(),
      status,
      regime: stats.regime ?? null,
      total_stocks: stats.total_stocks ?? 0,
      new_entries: stats.new_entries ?? 0,
      exits: stats.exits ?? 0,
      notes: stats.notes ?? null,
    });
    saveJson(data);
  }
}

function saveSnapshotJson(runId, stock) {
  const data = loadJson();
  const date = stock.snapshot_date ?? new Date().toISOString().slice(0, 10);
  const key = `${date}|${stock.strategy_slug}|${stock.ticker}`;
  const exists = data.snapshots.find(
    s => s.snapshot_date === date && s.strategy_slug === stock.strategy_slug && s.ticker === stock.ticker
  );
  if (!exists) {
    data.snapshots.push({
      id: data.snapshots.length + 1,
      run_id: runId,
      snapshot_date: date,
      market: stock.market ?? 'OTHER',
      strategy_slug: stock.strategy_slug ?? '',
      strategy_name: stock.strategy_name ?? null,
      ticker: stock.ticker,
      company_name: stock.company_name ?? null,
      sector: stock.sector ?? null,
      score: stock.score ?? null,
      score_breakdown: stock.score_breakdown ?? null,
      pe: stock.pe ?? null,
      forward_pe: stock.forward_pe ?? null,
      momentum_1d: stock.momentum_1d ?? null,
      risk_level: stock.risk_level ?? null,
      ai_rationale: stock.ai_rationale ?? null,
      is_new: !!stock.is_new,
      strategy_count: stock.strategy_count ?? 1,
      strategies: Array.isArray(stock.strategies) ? stock.strategies : [],
      scraped_at: now(),
    });
    saveJson(data);
  }
}

function loadPrevSnapshotJson(date) {
  const data = loadJson();
  const dates = [...new Set(data.snapshots.map(s => s.snapshot_date))]
    .filter(d => d < date)
    .sort();
  if (dates.length === 0) return [];
  const latest = dates[dates.length - 1];
  return data.snapshots.filter(s => s.snapshot_date === latest);
}

function saveSignalJson(runId, signal) {
  const data = loadJson();
  data.signals.push({
    id: data.signals.length + 1,
    run_id: runId,
    signal_date: signal.signal_date,
    ticker: signal.ticker,
    company_name: signal.company_name ?? null,
    market: signal.market ?? null,
    signal_type: signal.signal_type,
    priority: signal.priority ?? 'LOW',
    score: signal.score ?? null,
    prev_score: signal.prev_score ?? null,
    score_delta: signal.score_delta ?? null,
    strategies: Array.isArray(signal.strategies) ? signal.strategies : [],
    details: signal.details ?? null,
    telegram_sent: 0,
    created_at: now(),
  });
  saveJson(data);
}

function wasTelegramSentJson(hash) {
  const data = loadJson();
  return !!data.telegram_log.find(l => l.message_hash === hash);
}

function logTelegramJson(runId, hash, priority, ticker, signalType, preview, apiResponse) {
  const data = loadJson();
  if (!data.telegram_log.find(l => l.message_hash === hash)) {
    data.telegram_log.push({
      id: data.telegram_log.length + 1,
      run_id: runId ?? null,
      message_hash: hash,
      priority: priority ?? null,
      ticker: ticker ?? null,
      signal_type: signalType ?? null,
      message_preview: preview?.slice(0, 200) ?? null,
      sent_at: now(),
      api_response: apiResponse ? JSON.stringify(apiResponse) : null,
    });
    saveJson(data);
  }
}

function logErrorJson(runId, errorCode, context, message, screenshotPath) {
  const data = loadJson();
  data.errors.push({
    id: data.errors.length + 1,
    run_id: runId ?? null,
    error_code: errorCode,
    context: context ?? null,
    message: message?.slice(0, 500) ?? null,
    screenshot_path: screenshotPath ?? null,
    created_at: now(),
  });
  saveJson(data);
}

// ── UNIFIED EXPORTS ───────────────────────────────────────────────────────────

export function initDb() {
  fs.mkdirSync(path.join(ROOT, 'data'), { recursive: true });
  if (usingSqlite) return initSqlite();
  return initJson();
}

export function startRun(runId, mode) {
  if (usingSqlite) return startRunSqlite(runId, mode);
  return startRunJson(runId, mode);
}

export function finishRun(runId, status, stats = {}) {
  if (usingSqlite) return finishRunSqlite(runId, status, stats);
  return finishRunJson(runId, status, stats);
}

export function saveSnapshot(runId, stock) {
  if (usingSqlite) return saveSnapshotSqlite(runId, stock);
  return saveSnapshotJson(runId, stock);
}

export function loadPrevSnapshot(date) {
  if (usingSqlite) return loadPrevSnapshotSqlite(date);
  return loadPrevSnapshotJson(date);
}

export function saveSignal(runId, signal) {
  if (usingSqlite) return saveSignalSqlite(runId, signal);
  return saveSignalJson(runId, signal);
}

export function wasTelegramSent(hash) {
  if (usingSqlite) return wasTelegramSentSqlite(hash);
  return wasTelegramSentJson(hash);
}

export function logTelegram(runId, hash, priority, ticker, signalType, preview, apiResponse) {
  if (usingSqlite) return logTelegramSqlite(runId, hash, priority, ticker, signalType, preview, apiResponse);
  return logTelegramJson(runId, hash, priority, ticker, signalType, preview, apiResponse);
}

export function logError(runId, errorCode, context, message, screenshotPath) {
  if (usingSqlite) return logErrorSqlite(runId, errorCode, context, message, screenshotPath);
  return logErrorJson(runId, errorCode, context, message, screenshotPath);
}

export const backend = usingSqlite ? 'sqlite' : 'json';

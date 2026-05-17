/**
 * propicks_scrape.mjs — Per-strategy stock scraper with retry logic and screenshot on failure
 */

import fs   from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { logError } from './propicks_db.mjs';

const ROOT        = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const SCREENS_DIR = path.join(ROOT, 'data', 'screens');

const log = (...a) => console.log(`[Scrape ${new Date().toLocaleTimeString('tr-TR')}]`, ...a);
const delay = ms => new Promise(r => setTimeout(r, ms));

const BASE_URL = 'https://www.investing.com';

// ── HELPERS ───────────────────────────────────────────────────────────────────

function cleanTicker(raw) {
  if (!raw) return null;
  const t = raw.trim()
    .replace(/[^A-Z0-9.]/g, '')  // only letters, digits, dot
    .slice(0, 10);
  // Reject masked tickers like XXXX:XXXX
  if (/^X{2,}$/.test(t)) return null;
  if (t.length < 1 || t.length > 10) return null;
  return t || null;
}

function parseNumber(raw) {
  if (!raw) return null;
  const cleaned = String(raw)
    .replace(/[^\d.,-]/g, '')
    .replace(',', '.');
  const n = parseFloat(cleaned);
  return isNaN(n) ? null : n;
}

function parsePercent(raw) {
  if (!raw) return null;
  const cleaned = String(raw)
    .replace('%', '')
    .replace(',', '.')
    .trim();
  const n = parseFloat(cleaned);
  return isNaN(n) ? null : n;
}

function truncate(str, max = 200) {
  if (!str) return null;
  const s = String(str).trim();
  return s.length > max ? s.slice(0, max) + '…' : s;
}

// ── MAIN SCRAPER ──────────────────────────────────────────────────────────────

/**
 * scrapeStrategy — scrapes one ProPicks strategy page
 *
 * @param {import('playwright').Page} page
 * @param {string} slug
 * @param {string} name
 * @param {string} market — 'US' | 'EU' | 'TR' | 'OTHER'
 * @param {string} [runId] — for error logging
 * @returns {Promise<Array<StockObject>>}
 */
export async function scrapeStrategy(page, slug, name, market, runId = null) {
  const url = `${BASE_URL}/pro/propicks/${slug}`;
  const maxAttempts = 3;
  let lastError = null;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      log(`[${slug}] Attempt ${attempt}/${maxAttempts} — ${url}`);

      await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 25_000 });
      await page.waitForTimeout(4000);

      // ── APPROACH 1: standard <table> ────────────────────────────────────────
      let stocks = await tryTableApproach(page, slug, name, market);

      // ── APPROACH 2: React component rows ────────────────────────────────────
      if (stocks.length === 0) {
        log(`[${slug}] Table empty — trying React row selectors`);
        stocks = await tryReactApproach(page, slug, name, market);
      }

      // ── APPROACH 3: generic ticker scan ─────────────────────────────────────
      if (stocks.length === 0) {
        log(`[${slug}] React rows empty — trying generic ticker scan`);
        stocks = await tryGenericApproach(page, slug, name, market);
      }

      if (stocks.length > 0) {
        log(`[${slug}] Found ${stocks.length} stocks`);
        return stocks;
      }

      log(`[${slug}] No stocks found on attempt ${attempt}`);
      lastError = new Error('No stocks found after all selector approaches');

    } catch (e) {
      lastError = e;
      log(`[${slug}] Attempt ${attempt} error: ${e.message.slice(0, 100)}`);

      // Screenshot on failure
      try {
        fs.mkdirSync(SCREENS_DIR, { recursive: true });
        const screenshotPath = path.join(SCREENS_DIR, `${slug}_${Date.now()}.png`);
        await page.screenshot({ path: screenshotPath, fullPage: false });
        log(`[${slug}] Screenshot saved: ${screenshotPath}`);
        logError(runId, 'SELECTOR_FAILED', slug, e.message, screenshotPath);
      } catch (ssErr) {
        log(`[${slug}] Screenshot failed: ${ssErr.message.slice(0, 60)}`);
        logError(runId, 'SELECTOR_FAILED', slug, e.message, null);
      }
    }

    if (attempt < maxAttempts) {
      const waitMs = 5000 * attempt; // exponential: 5s, 10s
      log(`[${slug}] Waiting ${waitMs}ms before retry...`);
      await delay(waitMs);
    }
  }

  // All attempts failed — log and return empty
  log(`[${slug}] All ${maxAttempts} attempts failed — returning empty array`);
  if (lastError) {
    try {
      fs.mkdirSync(SCREENS_DIR, { recursive: true });
      const screenshotPath = path.join(SCREENS_DIR, `${slug}_final_${Date.now()}.png`);
      await page.screenshot({ path: screenshotPath, fullPage: false }).catch(() => {});
      logError(runId, 'SELECTOR_FAILED', slug, lastError.message, screenshotPath);
    } catch { /* ignore */ }
  }
  return [];
}

// ── APPROACH 1: STANDARD TABLE ────────────────────────────────────────────────

async function tryTableApproach(page, slug, name, market) {
  const rows = await page.$$('table tbody tr');
  if (rows.length === 0) return [];

  const stocks = [];
  for (const row of rows) {
    try {
      const cells = await row.$$eval('td', tds => tds.map(td => td.innerText?.trim() ?? ''));
      if (cells.length < 2) continue;

      const tickerRaw = cells[0]?.split('\n')[0]?.trim() ?? '';
      const ticker = cleanTicker(tickerRaw.toUpperCase());
      if (!ticker) continue;

      const companyRaw = cells[0]?.split('\n')[1]?.trim() || cells[1]?.trim() || '';
      const company_name = companyRaw.slice(0, 80) || null;

      const rowHtml = await row.evaluate(el => el.innerHTML).catch(() => '');
      const is_new  = /new|yeni|added/i.test(rowHtml);

      const stock = buildStock({
        ticker,
        company_name,
        momentum_1d: parsePercent(cells[3] ?? cells[2] ?? ''),
        pe:          parseNumber(cells[5] ?? cells[6] ?? ''),
        forward_pe:  parseNumber(cells[6] ?? cells[7] ?? ''),
        is_new,
        risk_level:  extractRisk(rowHtml),
        ai_rationale: truncate(extractAiText(rowHtml)),
        sector:      null,
        slug,
        name,
        market,
      });

      stocks.push(stock);
    } catch { /* skip malformed row */ }
  }
  return stocks;
}

// ── APPROACH 2: REACT COMPONENT ROWS ─────────────────────────────────────────

async function tryReactApproach(page, slug, name, market) {
  const rows = await page.$$('[class*="tableRow"], [class*="stock-row"], [class*="instrumentRow"]');
  if (rows.length === 0) return [];

  const stocks = [];
  for (const row of rows) {
    try {
      const rowText = await row.evaluate(el => el.innerText ?? '');
      const rowHtml = await row.evaluate(el => el.innerHTML ?? '');

      // Extract ticker from symbol/ticker span
      const tickerEl = await row.$('[class*="symbol"], [class*="ticker"], [class*="Symbol"]');
      const tickerRaw = tickerEl
        ? await tickerEl.evaluate(el => el.innerText?.trim() ?? '')
        : extractTickerFromText(rowText);

      const ticker = cleanTicker((tickerRaw ?? '').toUpperCase());
      if (!ticker) continue;

      const nameEl = await row.$('[class*="name"], [class*="title"], [class*="Name"]');
      const company_name = nameEl
        ? (await nameEl.evaluate(el => el.innerText?.trim() ?? '')).slice(0, 80)
        : null;

      const changeEl = await row.$('[class*="change"], [class*="percent"], [class*="Change"]');
      const changeRaw = changeEl
        ? await changeEl.evaluate(el => el.innerText?.trim() ?? '')
        : null;

      const peEl = await row.$('[class*="pe"], [class*="PE"], [data-test*="pe"]');
      const peRaw = peEl
        ? await peEl.evaluate(el => el.innerText?.trim() ?? '')
        : null;

      const is_new = /new|yeni|added/i.test(rowHtml);

      const stock = buildStock({
        ticker,
        company_name,
        momentum_1d: parsePercent(changeRaw),
        pe:          parseNumber(peRaw),
        forward_pe:  null,
        is_new,
        risk_level:  extractRisk(rowHtml),
        ai_rationale: truncate(extractAiText(rowHtml)),
        sector:      null,
        slug,
        name,
        market,
      });

      stocks.push(stock);
    } catch { /* skip */ }
  }
  return stocks;
}

// ── APPROACH 3: GENERIC TICKER SCAN ──────────────────────────────────────────

async function tryGenericApproach(page, slug, name, market) {
  // Any element containing a 1-6 char uppercase ticker pattern in text
  const candidates = await page.evaluate(() => {
    const TICKER_RE = /\b([A-Z]{1,6})\b/;
    const results = [];
    const elements = document.querySelectorAll('[class*="row"], [class*="item"], [class*="card"], li, tr');
    elements.forEach(el => {
      const text = el.innerText?.trim() ?? '';
      const match = text.match(TICKER_RE);
      if (!match) return;
      // Sanity check: element should be reasonably small
      if (text.length > 500) return;
      results.push({
        ticker:   match[1],
        fullText: text.slice(0, 200),
        html:     el.innerHTML?.slice(0, 500) ?? '',
      });
    });
    return results.slice(0, 50); // cap
  });

  const stocks = [];
  const seenTickers = new Set();

  for (const item of candidates) {
    const ticker = cleanTicker(item.ticker);
    if (!ticker || seenTickers.has(ticker)) continue;
    // Exclude common false positives
    if (/^(THE|AND|FOR|NEW|GET|PRO|TOP|MID|LOW|HIGH|BUY|SELL)$/.test(ticker)) continue;

    seenTickers.add(ticker);
    const is_new = /new|yeni|added/i.test(item.html);

    stocks.push(buildStock({
      ticker,
      company_name:  null,
      momentum_1d:   parsePercent(extractNumberPattern(item.fullText, /%/)),
      pe:            null,
      forward_pe:    null,
      is_new,
      risk_level:    extractRisk(item.html),
      ai_rationale:  null,
      sector:        null,
      slug,
      name,
      market,
    }));
  }
  return stocks;
}

// ── UTILITIES ─────────────────────────────────────────────────────────────────

function buildStock({ ticker, company_name, momentum_1d, pe, forward_pe, is_new, risk_level, ai_rationale, sector, slug, name, market }) {
  const parseStatus = {
    ticker:       ticker ? 'ok' : 'missing',
    company_name: company_name ? 'ok' : 'missing',
    momentum_1d:  momentum_1d != null ? 'ok' : 'missing',
    pe:           pe != null ? 'ok' : 'missing',
    forward_pe:   forward_pe != null ? 'ok' : 'missing',
    risk_level:   risk_level ? 'ok' : 'missing',
    ai_rationale: ai_rationale ? 'ok' : 'missing',
    sector:       sector ? 'ok' : 'missing',
  };
  return {
    ticker,
    company_name:   company_name ?? null,
    momentum_1d:    momentum_1d ?? null,
    pe:             pe ?? null,
    forward_pe:     forward_pe ?? null,
    is_new:         !!is_new,
    risk_level:     risk_level ?? null,
    ai_rationale:   ai_rationale ?? null,
    sector:         sector ?? null,
    strategy_slug:  slug,
    strategy_name:  name,
    market,
    snapshot_date:  new Date().toISOString().slice(0, 10),
    scraped_at:     new Date().toISOString(),
    parse_status:   parseStatus,
  };
}

function extractRisk(html) {
  if (/low.?risk|risk.?low/i.test(html))    return 'Low';
  if (/high.?risk|risk.?high/i.test(html))  return 'High';
  if (/med.?risk|risk.?med/i.test(html))    return 'Medium';
  return null;
}

function extractAiText(html) {
  // Look for common AI explanation containers
  const match = html.match(/ai.{0,30}?[">]([^<]{20,})<\//i)
    || html.match(/rationale[^>]*>([^<]{20,})<\//i)
    || html.match(/analysis[^>]*>([^<]{20,})<\//i);
  return match ? match[1].trim() : null;
}

function extractTickerFromText(text) {
  const match = text.match(/\b([A-Z]{1,6})\b/);
  return match ? match[1] : null;
}

function extractNumberPattern(text, pattern) {
  const re = new RegExp(`([\\d.,+-]+)\\s*${pattern.source ?? pattern}`);
  const match = text.match(re);
  return match ? match[1] : null;
}

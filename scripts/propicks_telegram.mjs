/**
 * propicks_telegram.mjs — Telegram messaging layer with dedup, batching and dry-run
 */

import https  from 'https';
import crypto from 'crypto';

const log = (...a) => console.log(`[Telegram ${new Date().toLocaleTimeString('tr-TR')}]`, ...a);
const delay = ms => new Promise(r => setTimeout(r, ms));

const MAX_MSG_LEN = 3800; // Telegram limit is 4096; stay safe

// ── SIGNAL TYPE TRANSLATIONS ──────────────────────────────────────────────────
const SIGNAL_TYPE_TR = {
  NEW_ENTRY:       'Yeni Eklendi',
  EXIT:            'Çıkarıldı',
  SCORE_UP:        'Puan Arttı',
  SCORE_DOWN:      'Puan Düştü',
  SECTOR_ROTATION: 'Sektör Rotasyonu',
};

// ── RAW SEND ──────────────────────────────────────────────────────────────────

/**
 * sendTelegram — sends a single message via Bot API
 * @param {string} text     — HTML-formatted message
 * @param {string} token
 * @param {string} chatId
 * @returns {Promise<object>} — Telegram API response
 */
export function sendTelegram(text, token, chatId) {
  if (!token || !chatId) {
    throw new Error('sendTelegram: token and chatId are required');
  }
  const body = JSON.stringify({
    chat_id:                  chatId,
    text,
    parse_mode:               'HTML',
    disable_web_page_preview: true,
  });
  return new Promise((resolve, reject) => {
    const req = https.request(
      {
        hostname: 'api.telegram.org',
        path:     `/bot${token}/sendMessage`,
        method:   'POST',
        headers:  {
          'Content-Type':   'application/json',
          'Content-Length': Buffer.byteLength(body),
        },
        timeout: 15_000,
      },
      res => {
        let data = '';
        res.on('data', c => { data += c; });
        res.on('end', () => {
          try { resolve(JSON.parse(data)); }
          catch (e) { reject(new Error(`Telegram JSON parse error: ${e.message}`)); }
        });
      }
    );
    req.on('error', reject);
    req.on('timeout', () => { req.destroy(); reject(new Error('Telegram request timed out')); });
    req.write(body);
    req.end();
  });
}

// ── MAIN ENTRY ────────────────────────────────────────────────────────────────

/**
 * sendSignals — dedup, prioritise, format and send/dry-print signals
 *
 * @param {object[]} signals  — from generateSignals()
 * @param {object[]} stocks   — all stocks this run (for summary top-5)
 * @param {string}   regime
 * @param {object}   db       — propicks_db module exports
 * @param {string}   runId
 * @param {string}   token
 * @param {string}   chatId
 * @param {boolean}  dry      — if true, console.log instead of sending
 */
export async function sendSignals(signals, stocks, regime, db, runId, token, chatId, dry = false) {
  if (!signals || signals.length === 0) {
    log('No signals to send.');
    return;
  }

  const today    = new Date().toISOString().slice(0, 10);
  const timeStr  = new Date().toLocaleTimeString('tr-TR', { timeZone: 'Europe/Istanbul' });

  // Separate by priority
  const high   = signals.filter(s => s.priority === 'HIGH');
  const medium = signals.filter(s => s.priority === 'MEDIUM');
  const low    = signals.filter(s => s.priority === 'LOW' && (s.score ?? 0) >= 50);

  log(`Signals: ${high.length} HIGH, ${medium.length} MEDIUM, ${low.length} LOW (≥50 score)`);

  // ── HIGH — individual messages ─────────────────────────────────────────────
  for (const signal of high) {
    const hash = hashSignal(signal.ticker, signal.signal_type, today);
    if (db.wasTelegramSent(hash)) {
      log(`[HIGH] ${signal.ticker} already sent — skipping`);
      continue;
    }
    const stock   = findStock(stocks, signal.ticker);
    const message = formatHighMessage(signal, stock, timeStr);
    await sendAndLog({ message, hash, signal, db, runId, token, chatId, dry });
  }

  // ── MEDIUM — individual messages ───────────────────────────────────────────
  for (const signal of medium) {
    const hash = hashSignal(signal.ticker, signal.signal_type, today);
    if (db.wasTelegramSent(hash)) {
      log(`[MEDIUM] ${signal.ticker} already sent — skipping`);
      continue;
    }
    const message = formatMediumMessage(signal, timeStr);
    await sendAndLog({ message, hash, signal, db, runId, token, chatId, dry });
  }

  // ── LOW — batched summary ─────────────────────────────────────────────────
  if (low.length > 0) {
    // Filter already sent
    const newLow = low.filter(s => !db.wasTelegramSent(hashSignal(s.ticker, s.signal_type, today)));

    if (newLow.length > 0) {
      const topStocks = [...stocks]
        .sort((a, b) => (b.score ?? 0) - (a.score ?? 0))
        .slice(0, 5);

      const newEntries = newLow.filter(s => s.signal_type === 'NEW_ENTRY');
      const exits      = newLow.filter(s => s.signal_type === 'EXIT');

      const batchHash = hashSignal('LOW_BATCH', 'DAILY_SUMMARY', today);
      if (!db.wasTelegramSent(batchHash)) {
        const batchMessages = formatLowBatch(newLow.slice(0, 10), topStocks, newEntries.length, exits.length, regime, today, timeStr);

        for (const msg of batchMessages) {
          if (dry) {
            log('[DRY LOW BATCH]\n' + stripHtml(msg));
          } else {
            try {
              const resp = await sendTelegram(msg, token, chatId);
              log(`LOW batch sent: ok=${resp.ok}`);
            } catch (e) {
              log(`LOW batch error: ${e.message.slice(0, 80)}`);
            }
            await delay(500);
          }
        }

        db.logTelegram(runId, batchHash, 'LOW', null, 'DAILY_SUMMARY', 'Low batch summary', null);
        // Mark individual low signals as sent
        for (const s of newLow.slice(0, 10)) {
          const h = hashSignal(s.ticker, s.signal_type, today);
          db.logTelegram(runId, h, 'LOW', s.ticker, s.signal_type, `${s.ticker} low batch`, null);
        }
      }
    }
  }
}

// ── SEND + LOG HELPER ─────────────────────────────────────────────────────────

async function sendAndLog({ message, hash, signal, db, runId, token, chatId, dry }) {
  const chunks = splitMessage(message);
  for (const chunk of chunks) {
    if (dry) {
      log(`[DRY ${signal.priority}] ${signal.ticker}\n` + stripHtml(chunk));
    } else {
      try {
        const resp = await sendTelegram(chunk, token, chatId);
        log(`${signal.priority} ${signal.ticker}: ok=${resp.ok}`);
        db.logTelegram(runId, hash, signal.priority, signal.ticker, signal.signal_type,
          chunk.slice(0, 100), resp);
      } catch (e) {
        log(`Send error for ${signal.ticker}: ${e.message.slice(0, 80)}`);
        db.logTelegram(runId, hash, signal.priority, signal.ticker, signal.signal_type,
          chunk.slice(0, 100), { error: e.message });
      }
      await delay(500);
    }
  }
  // Mark as sent regardless of dry to prevent double sends on re-runs
  if (!db.wasTelegramSent(hash)) {
    db.logTelegram(runId, hash, signal.priority, signal.ticker, signal.signal_type,
      message.slice(0, 100), dry ? 'DRY_RUN' : null);
  }
}

// ── FORMAT FUNCTIONS ──────────────────────────────────────────────────────────

function formatHighMessage(signal, stock, timeStr) {
  const typeTr     = SIGNAL_TYPE_TR[signal.signal_type] ?? signal.signal_type;
  const strategies = formatStrategies(signal.strategies);
  const rationale  = stock?.ai_rationale ?? signal.details ?? '';

  let msg = `🚨 <b>HIGH PRIORITY — ProPicks AI</b>\n\n`;
  msg += `📌 <b>${signal.ticker}</b>`;
  if (signal.company_name) msg += ` · ${signal.company_name.slice(0, 40)}`;
  msg += `\n`;
  if (signal.prev_score != null && signal.score != null) {
    msg += `📊 Skor: ${signal.score}/100 (${signal.prev_score}→${signal.score})\n`;
  } else if (signal.score != null) {
    msg += `📊 Skor: ${signal.score}/100\n`;
  }
  msg += `🏦 Piyasa: ${signal.market ?? '-'} · ${strategies}\n`;
  msg += `📈 Sinyal: ${typeTr}\n`;
  if (rationale) msg += `💡 ${rationale.slice(0, 200)}\n`;
  msg += `🕐 ${timeStr}`;
  return msg;
}

function formatMediumMessage(signal, timeStr) {
  const typeTr     = SIGNAL_TYPE_TR[signal.signal_type] ?? signal.signal_type;
  const strategies = formatStrategies(signal.strategies);

  let msg = `⚡ <b>${typeTr} — ProPicks</b>\n\n`;
  msg += `<b>${signal.ticker}</b>`;
  if (signal.company_name) msg += ` · ${signal.company_name.slice(0, 40)}`;
  msg += `\n`;
  if (signal.score != null) msg += `Skor: ${signal.score}/100 · ${signal.market ?? '-'}\n`;
  msg += `Strateji: ${strategies}\n`;
  if (signal.score_delta != null) {
    msg += `Delta: ${signal.score_delta > 0 ? '+' : ''}${signal.score_delta} puan\n`;
  }
  msg += `🕐 ${timeStr}`;
  return msg;
}

function formatLowBatch(lowSignals, topStocks, newCount, exitCount, regime, date, timeStr) {
  const dateFormatted = new Date(date).toLocaleDateString('tr-TR', {
    weekday: 'long', day: 'numeric', month: 'long',
  });

  let msg = `📊 <b>Günlük Özet — ProPicks</b>\n`;
  msg += `📅 ${dateFormatted} · Rejim: ${regime}\n\n`;

  msg += `Yeni: <b>${newCount}</b> hisse\n`;
  msg += `Çıkan: <b>${exitCount}</b> hisse\n\n`;

  if (topStocks.length > 0) {
    msg += `<b>En Güçlü ${Math.min(5, topStocks.length)}:</b>\n`;
    topStocks.forEach((s, i) => {
      const strats = formatStrategies(s.strategies ?? (s.strategy_name ? [s.strategy_name] : []));
      msg += `${i + 1}. <b>${s.ticker}</b> ${s.score ?? '?'}/100 · ${strats}\n`;
    });
    msg += '\n';
  }

  if (lowSignals.length > 0) {
    msg += `<b>Diğer Sinyaller:</b>\n`;
    for (const s of lowSignals.slice(0, 10)) {
      const typeTr = SIGNAL_TYPE_TR[s.signal_type] ?? s.signal_type;
      msg += `• <b>${s.ticker}</b> ${typeTr}`;
      if (s.score != null) msg += ` · ${s.score}/100`;
      msg += '\n';
    }
    msg += '\n';
  }

  msg += `🕐 ${timeStr}`;

  return splitMessage(msg);
}

// ── UTILITIES ─────────────────────────────────────────────────────────────────

export function hashSignal(ticker, signalType, date) {
  return crypto.createHash('sha1')
    .update(`${ticker}|${signalType}|${date}`)
    .digest('hex');
}

function findStock(stocks, ticker) {
  return stocks.find(s => s.ticker === ticker) ?? null;
}

function formatStrategies(strategies) {
  if (!strategies || strategies.length === 0) return '—';
  if (Array.isArray(strategies)) return strategies.slice(0, 3).join(', ');
  return String(strategies);
}

function splitMessage(msg) {
  if (msg.length <= MAX_MSG_LEN) return [msg];

  const chunks = [];
  const lines  = msg.split('\n');
  let   cur    = '';

  for (const line of lines) {
    if ((cur + '\n' + line).length > MAX_MSG_LEN) {
      if (cur) chunks.push(cur.trim());
      cur = line;
    } else {
      cur += (cur ? '\n' : '') + line;
    }
  }
  if (cur) chunks.push(cur.trim());
  return chunks;
}

function stripHtml(html) {
  return html.replace(/<[^>]+>/g, '');
}

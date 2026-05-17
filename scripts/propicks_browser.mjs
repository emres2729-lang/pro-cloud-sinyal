/**
 * propicks_browser.mjs — Browser factory with stealth patches and session loading
 */

import { chromium } from 'playwright';
import fs   from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const ROOT         = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const SESSION_FILE = path.join(ROOT, 'data', 'investing_session.json');

const log = (...a) => console.log(`[Browser ${new Date().toLocaleTimeString('tr-TR')}]`, ...a);

// ── STEALTH INIT SCRIPT ───────────────────────────────────────────────────────
const STEALTH_JS = `
  Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
  if (!window.chrome) window.chrome = { runtime: {}, loadTimes: () => {}, csi: () => {}, app: {} };
  if (navigator.permissions?.query) {
    const _orig = navigator.permissions.query.bind(navigator.permissions);
    navigator.permissions.query = (p) => p.name === 'notifications' ? Promise.resolve({ state: Notification.permission }) : _orig(p);
  }
  Object.defineProperty(navigator, 'plugins', { get: () => { const a=[1,2,3,4,5]; a.item=i=>a[i]; a.namedItem=()=>null; a.refresh=()=>{}; return a; } });
  Object.defineProperty(navigator, 'languages', { get: () => ['de-DE','de','en-US','en'] });
  Object.defineProperty(navigator, 'platform', { get: () => 'Win32' });
  Object.defineProperty(navigator, 'hardwareConcurrency', { get: () => 8 });
`;

/**
 * createBrowser — launches stealth Chromium, loads session if available
 * @param {boolean} headless
 * @returns {{ browser, context, page }}
 */
export async function createBrowser(headless = true) {
  const browser = await chromium.launch({
    headless,
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
      '--disable-blink-features=AutomationControlled',
      '--disable-infobars',
      '--lang=de-DE',
      '--window-size=1280,900',
    ],
    slowMo: headless ? 0 : 30,
  });

  // Try to load full storageState from session file
  let storageState = undefined;
  if (fs.existsSync(SESSION_FILE)) {
    try {
      storageState = JSON.parse(fs.readFileSync(SESSION_FILE, 'utf8'));
      log(`Session loaded from ${SESSION_FILE} (${storageState.cookies?.length ?? 0} cookies)`);
    } catch (e) {
      log(`Warning: could not parse session file — ${e.message.slice(0, 80)}`);
    }
  } else {
    // Fall back to INVESTING_COOKIES env var (base64 encoded full storageState or cookie array)
    const cookiesB64 = process.env.INVESTING_COOKIES;
    if (cookiesB64) {
      try {
        const parsed = JSON.parse(Buffer.from(cookiesB64, 'base64').toString('utf8'));
        // Support both full storageState and bare cookie array
        if (Array.isArray(parsed)) {
          storageState = { cookies: parsed, origins: [] };
        } else if (parsed.cookies) {
          storageState = parsed;
        }
        log(`Session loaded from INVESTING_COOKIES env (${storageState?.cookies?.length ?? 0} cookies)`);
      } catch (e) {
        log(`Warning: could not parse INVESTING_COOKIES env — ${e.message.slice(0, 80)}`);
      }
    } else {
      log('No session file and no INVESTING_COOKIES env — browser will be unauthenticated');
    }
  }

  const contextOptions = {
    userAgent:
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    viewport: { width: 1280, height: 900 },
    locale: 'de-DE',
    timezoneId: 'Europe/Berlin',
    extraHTTPHeaders: {
      'Accept-Language': 'de-DE,de;q=0.9,en-US;q=0.8,en;q=0.7',
    },
  };

  // Only inject storageState if we have it — otherwise context has no session
  if (storageState) {
    contextOptions.storageState = storageState;
  }

  const context = await browser.newContext(contextOptions);
  await context.addInitScript(STEALTH_JS);

  const page = await context.newPage();
  page.setDefaultTimeout(30_000);

  return { browser, context, page };
}

/**
 * closeBrowser — graceful shutdown
 * @param {{ browser }} param0
 */
export async function closeBrowser({ browser }) {
  try {
    await browser.close();
  } catch (e) {
    log(`Warning: browser.close() error — ${e.message.slice(0, 80)}`);
  }
}

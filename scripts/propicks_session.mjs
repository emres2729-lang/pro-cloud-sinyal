/**
 * propicks_session.mjs — Auth status checker
 * Returns structured status without throwing.
 */

import { createBrowser, closeBrowser } from './propicks_browser.mjs';

const log = (...a) => console.log(`[Session ${new Date().toLocaleTimeString('tr-TR')}]`, ...a);

const PROPICKS_URL = 'https://www.investing.com/pro/propicks';

/**
 * checkSession — verifies that the stored session can access ProPicks
 *
 * Returns one of:
 *   { status: 'AUTH_OK',               url }
 *   { status: 'AUTH_EXPIRED',          url }
 *   { status: 'CAPTCHA_DETECTED',      url }
 *   { status: 'SUBSCRIPTION_BLOCKED',  url }
 *   { status: 'NETWORK_ERROR',         error }
 *   { status: 'UNKNOWN_LAYOUT',        url, html }
 */
export async function checkSession() {
  let handle = null;
  try {
    log('Launching headless browser for session check...');
    handle = await createBrowser(true);
    const { page } = handle;

    try {
      await page.goto(PROPICKS_URL, { waitUntil: 'domcontentloaded', timeout: 25_000 });
    } catch (navErr) {
      // Navigation timeout is non-fatal — still check what loaded
      log(`Navigation warning: ${navErr.message.slice(0, 80)}`);
    }

    // Wait a bit for SPA redirect to settle
    await page.waitForTimeout(3000);

    const url = page.url();
    log(`Current URL: ${url}`);

    // AUTH_EXPIRED — redirected to login/register
    if (/\/(login|register)/.test(url)) {
      log('Status: AUTH_EXPIRED');
      return { status: 'AUTH_EXPIRED', url };
    }

    // Read visible text for content checks
    let bodyText = '';
    try {
      bodyText = await page.evaluate(() => document.body?.innerText ?? '');
    } catch { /* ignore evaluation errors */ }

    // CAPTCHA_DETECTED
    if (/captcha|recaptcha|robot|i am not a robot/i.test(bodyText)) {
      log('Status: CAPTCHA_DETECTED');
      return { status: 'CAPTCHA_DETECTED', url };
    }

    // SUBSCRIPTION_BLOCKED — Pro subscription wall
    if (/subscribe|upgrade|pro plan|get pro|unlock pro/i.test(bodyText)) {
      log('Status: SUBSCRIPTION_BLOCKED');
      return { status: 'SUBSCRIPTION_BLOCKED', url };
    }

    // AUTH_OK — strategy links found on the page
    const strategyLinks = await page.$$('a[href*="/pro/propicks/"]');
    if (strategyLinks.length > 0) {
      log(`Status: AUTH_OK (${strategyLinks.length} strategy links found)`);
      return { status: 'AUTH_OK', url };
    }

    // AUTH_EXPIRED fallback — still on a login-related URL
    if (/\/login|\/register|accounts\.google|oauth/i.test(url)) {
      log('Status: AUTH_EXPIRED (URL pattern)');
      return { status: 'AUTH_EXPIRED', url };
    }

    // UNKNOWN_LAYOUT — authenticated but no recognisable structure
    const html = await page.content().catch(() => '');
    log('Status: UNKNOWN_LAYOUT');
    return { status: 'UNKNOWN_LAYOUT', url, html: html.slice(0, 2000) };

  } catch (e) {
    log(`Network/browser error: ${e.message.slice(0, 120)}`);
    return { status: 'NETWORK_ERROR', error: e.message };
  } finally {
    if (handle) await closeBrowser(handle);
  }
}

/**
 * Investing.com Pro — Kalıcı Oturum Kurulumu
 * Çalıştır: node scripts/propicks_auth_kur.mjs
 *
 * Özellikler:
 *  - Full storage state (cookies + localStorage + sessionStorage + IndexedDB)
 *  - Stealth patches (navigator.webdriver gizleme)
 *  - Almanya dahil tüm ülkelerden çalışır (www.investing.com)
 *  - Login durumu otomatik tespit
 */

import { chromium } from 'playwright';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const ROOT    = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT_DIR = path.join(ROOT, 'data');
const OUT     = path.join(OUT_DIR, 'investing_session.json');  // cookies + storage

fs.mkdirSync(OUT_DIR, { recursive: true });

const TIMEOUT_MS   = 600_000;  // 10 dakika
const BASE_URL     = 'https://www.investing.com';
const LOGIN_URL    = `${BASE_URL}/login`;
const PROPICKS_URL = `${BASE_URL}/pro/propicks`;

// ── Stealth Init Script ──────────────────────────────────────────────────────
const STEALTH_SCRIPT = `
  // webdriver flag kaldır
  Object.defineProperty(navigator, 'webdriver', { get: () => undefined });

  // chrome nesnesi ekle
  if (!window.chrome) {
    window.chrome = {
      runtime: {}, loadTimes: () => {}, csi: () => {}, app: {},
    };
  }

  // Permissions API patch
  if (navigator.permissions && navigator.permissions.query) {
    const _orig = navigator.permissions.query.bind(navigator.permissions);
    navigator.permissions.query = (params) =>
      params.name === 'notifications'
        ? Promise.resolve({ state: Notification.permission })
        : _orig(params);
  }

  // Fake plugin listesi
  Object.defineProperty(navigator, 'plugins', {
    get: () => {
      const arr = [1,2,3,4,5];
      arr.item = i => arr[i];
      arr.namedItem = () => null;
      arr.refresh = () => {};
      return arr;
    }
  });

  // Dil ayarı — gerçek tarayıcı gibi
  Object.defineProperty(navigator, 'languages', {
    get: () => ['de-DE', 'de', 'en-US', 'en']
  });

  // Platform spoof
  Object.defineProperty(navigator, 'platform', { get: () => 'Win32' });

  // Hardware concurrency
  Object.defineProperty(navigator, 'hardwareConcurrency', { get: () => 8 });
`;

// ── Yardımcılar ──────────────────────────────────────────────────────────────
const log = (...a) => console.log(new Date().toLocaleTimeString('tr-TR'), ...a);

async function isLoggedIn(page) {
  const url = page.url();
  // Giriş/kayıt sayfasında değilse ve Google auth'ta değilse giriş yapılmış
  if (url.includes('/login') || url.includes('/register') || url.includes('accounts.google')) {
    return false;
  }
  // Pro badge veya kullanıcı menüsü var mı?
  const proIndicators = [
    '[class*="avatarImg"]',
    '[class*="userMenu"]',
    '[class*="HeaderProfile"]',
    'a[href*="/pro"]',
    '[data-test="user-menu"]',
  ];
  for (const sel of proIndicators) {
    try {
      const el = await page.$(sel);
      if (el) return true;
    } catch { /* continue */ }
  }
  // URL investing.com ve login sayfası değilse muhtemelen giriş yapılmış
  return url.includes('investing.com') && !url.includes('/login');
}

// ── Ana Fonksiyon ─────────────────────────────────────────────────────────────
console.log('='.repeat(60));
console.log('  Investing.com Pro — Kalıcı Oturum Kurulumu');
console.log('='.repeat(60));
console.log('\n>>> YAPMAN GEREKEN:');
console.log('  1. Birazdan Chromium tarayıcısı açılacak');
console.log('  2. www.investing.com/login sayfasına gidecek');
console.log('  3. "Google ile giriş yap" butonuna tıkla');
console.log('  4. Google hesabınla giriş yap');
console.log('  5. Ana sayfaya yönlenince bu terminal devam edecek');
console.log('\n  NOT: Almanya\'dan çalışıyorsan sorun yok — www. subdomain kullanılıyor\n');

const browser = await chromium.launch({
  headless: false,
  slowMo: 30,
  args: [
    '--start-maximized',
    '--disable-blink-features=AutomationControlled',
    '--no-sandbox',
    '--disable-infobars',
    '--disable-dev-shm-usage',
    '--lang=de-DE',
  ],
});

const context = await browser.newContext({
  viewport: null,
  userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  locale: 'de-DE',
  timezoneId: 'Europe/Berlin',
  extraHTTPHeaders: {
    'Accept-Language': 'de-DE,de;q=0.9,en-US;q=0.8,en;q=0.7',
  },
});

// Stealth init script — her sayfada çalış
await context.addInitScript(STEALTH_SCRIPT);

const page = await context.newPage();

log('Giriş sayfası açılıyor...');
try {
  await page.goto(LOGIN_URL, { waitUntil: 'domcontentloaded', timeout: 30_000 });
} catch {
  // Timeout olsa da devam et
}
await page.bringToFront();

log('Giriş bekleniyor... (max 10 dakika)');
log('(Açılan pencerede Google ile giriş yap)');
console.log();

let girisBasarili = false;
const deadline = Date.now() + TIMEOUT_MS;
let dotCount = 0;

while (Date.now() < deadline) {
  await new Promise(r => setTimeout(r, 2000));
  dotCount++;

  const url = page.url();

  // Google OAuth redirect — bekle
  if (url.includes('accounts.google') || url.includes('oauth2')) {
    if (dotCount % 10 === 0) process.stdout.write('\n  [Google OAuth bekleniyor...]');
    else process.stdout.write('.');
    continue;
  }

  // Başarılı giriş tespiti
  if (await isLoggedIn(page)) {
    girisBasarili = true;
    break;
  }

  // Hâlâ giriş sayfasındaysa bekle
  if (url.includes('/login') || url.includes('/register')) {
    if (dotCount % 15 === 0) process.stdout.write('\n  [Giriş sayfası bekleniyor...]');
    else process.stdout.write('.');
    continue;
  }

  // URL değiştiyse ve login sayfasında değilse → başarılı
  if (url.includes('investing.com') && !url.includes('/login')) {
    girisBasarili = true;
    break;
  }

  process.stdout.write('.');
}

console.log();

if (!girisBasarili) {
  console.error('\n✗ Zaman aşımı (10 dakika) — giriş yapılmadı.');
  console.error('  Tekrar çalıştır: node scripts/propicks_auth_kur.mjs');
  await browser.close();
  process.exit(1);
}

log(`✓ Giriş başarılı → ${page.url()}`);

// Pro sayfasına git — tüm Pro cookie + storage al
log('Pro/ProPicks sayfası açılıyor...');
try {
  await page.goto(PROPICKS_URL, { waitUntil: 'domcontentloaded', timeout: 20_000 });
  await new Promise(r => setTimeout(r, 4_000));
} catch {
  // Timeout olsa da storage'ı al
  await new Promise(r => setTimeout(r, 2_000));
}

// FULL storage state kaydet (cookies + localStorage + sessionStorage + IndexedDB)
const storageState = await context.storageState();

// Sadece investing.com veya fusionauth domain'leri
storageState.cookies = storageState.cookies.filter(c =>
  c.domain.includes('investing.com') || c.domain.includes('fusionauth')
);

if (storageState.cookies.length === 0) {
  console.error('\n✗ HATA: Investing.com cookie bulunamadı.');
  console.error('  Pro sayfasının yüklendiğinden emin ol ve tekrar dene.');
  await browser.close();
  process.exit(1);
}

// Session dosyasını kaydet
fs.writeFileSync(OUT, JSON.stringify(storageState, null, 2));
log(`✓ Session kaydedildi: ${OUT}`);
log(`  Cookie sayısı: ${storageState.cookies.length}`);
log(`  Origin sayısı: ${storageState.origins?.length ?? 0} (localStorage/sessionStorage)`);

// GitHub Secret için base64 çıktı
const b64 = Buffer.from(JSON.stringify(storageState)).toString('base64');

console.log('\n' + '='.repeat(60));
console.log('GitHub Secret olarak ekle:');
console.log('  Repo → Settings → Secrets → Actions → New secret');
console.log('  Ad  : INVESTING_COOKIES');
console.log('  Değer (aşağıdaki tek satırı kopyala):');
console.log('='.repeat(60));
console.log(b64);
console.log('='.repeat(60) + '\n');
console.log('✓ Bitti. Artık GitHub Actions çalışabilir.');

await browser.close();

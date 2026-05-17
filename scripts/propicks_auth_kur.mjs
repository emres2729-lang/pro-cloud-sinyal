/**
 * Investing.com Pro — Bir Kerelik Oturum Kurulumu
 * Çalıştır: node scripts/propicks_auth_kur.mjs
 * Tarayıcı açılır → Google ile giriş yap → pencere kapanır → cookies.json oluşur
 */

import { chromium } from 'playwright';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT  = path.join(ROOT, 'data', 'investing_cookies.json');

fs.mkdirSync(path.join(ROOT, 'data'), { recursive: true });

console.log('='.repeat(60));
console.log('  Investing.com Pro Oturum Kurulumu');
console.log('='.repeat(60));
console.log('Tarayıcı açılıyor — Google ile giriş yap.');
console.log('Giriş tamamlandığında bu pencere otomatik kapanacak.\n');

const browser = await chromium.launch({ headless: false, slowMo: 100 });
const context = await browser.newContext();
const page    = await context.newPage();

await page.goto('https://tr.investing.com/login', { waitUntil: 'domcontentloaded' });

// Kullanıcının giriş yapmasını bekle (max 3 dakika)
console.log('Giriş bekleniyor... (max 3 dakika)');
try {
  await page.waitForFunction(
    () => !window.location.href.includes('/login') && !window.location.href.includes('/register'),
    { timeout: 180_000 }
  );
} catch {
  console.error('Zaman aşımı — giriş yapılmadı.');
  await browser.close();
  process.exit(1);
}

console.log(`\nGiriş başarılı → ${page.url()}`);

// Birkaç saniye bekle — Pro sayfasına git, oturumun tam yüklendiğinden emin ol
await page.goto('https://tr.investing.com/pro/propicks', { waitUntil: 'domcontentloaded' });
await new Promise(r => setTimeout(r, 3000));

// Cookies + storage state kaydet
const state   = await context.storageState();
const cookies = state.cookies.filter(c =>
  c.domain.includes('investing.com') || c.domain.includes('fusionauth')
);

fs.writeFileSync(OUT, JSON.stringify(cookies, null, 2));
console.log(`\nCookies kaydedildi: ${OUT}`);
console.log(`Toplam: ${cookies.length} cookie`);

// GitHub Secret için base64 çıktı
const b64 = Buffer.from(JSON.stringify(cookies)).toString('base64');
console.log('\n' + '='.repeat(60));
console.log('GitHub Secret olarak ekle:');
console.log('  Ad  : INVESTING_COOKIES');
console.log('  Değer:');
console.log(b64);
console.log('='.repeat(60) + '\n');

await browser.close();
console.log('Bitti.');

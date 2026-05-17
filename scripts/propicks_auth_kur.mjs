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

const TIMEOUT_MS = 600_000; // 10 dakika

console.log('='.repeat(60));
console.log('  Investing.com Pro Oturum Kurulumu');
console.log('='.repeat(60));
console.log('\n>>> YAPMAN GEREKEN:');
console.log('  1. Birazdan Chromium tarayıcısı açılacak');
console.log('  2. Açılan pencerede Investing.com\'a GİRİŞ YAP');
console.log('     (Google ile giriş butonu)');
console.log('  3. Pro sayfasına erişebildiğini gördükten sonra');
console.log('     bu terminal kendiliğinden devam edecek\n');
console.log('Tarayıcı açılıyor...\n');

const browser = await chromium.launch({
  headless: false,
  slowMo: 50,
  args: ['--start-maximized'],
});

const context = await browser.newContext({
  viewport: null,  // maximized ile çalışsın
  userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36',
});
const page = await context.newPage();

// Giriş sayfasına git
await page.goto('https://www.investing.com/login', { waitUntil: 'domcontentloaded', timeout: 30000 });
await page.bringToFront();

console.log('Giriş bekleniyor... (max 10 dakika)');
console.log('(Açılan Chromium penceresine gidip Google ile giriş yap)\n');

// Giriş tamamlanana kadar bekle:
// URL /login veya /register dışına çıkınca VEYA Pro sayfası yüklenince
let girisBasarili = false;
const deadline = Date.now() + TIMEOUT_MS;

while (Date.now() < deadline) {
  await new Promise(r => setTimeout(r, 2000));

  const url = page.url();

  // Giriş sayfasından çıktıysa başarılı
  if (!url.includes('/login') && !url.includes('/register') && !url.includes('accounts.google')) {
    girisBasarili = true;
    break;
  }

  // Google OAuth callback — bekle, yönlendirme olacak
  if (url.includes('accounts.google') || url.includes('oauth')) {
    process.stdout.write('.');
    continue;
  }

  process.stdout.write('.');
}

if (!girisBasarili) {
  console.error('\n\nZaman aşımı (10 dakika) — giriş yapılmadı.');
  console.error('Tekrar dene: node scripts/propicks_auth_kur.mjs');
  await browser.close();
  process.exit(1);
}

console.log(`\n\nGiriş başarılı → ${page.url()}`);

// Pro sayfasına git — tüm Pro cookie'leri al
console.log('Pro sayfasına yönlendiriliyor...');
try {
  await page.goto('https://www.investing.com/pro/propicks', { waitUntil: 'domcontentloaded', timeout: 15000 });
} catch {
  // timeout olsa da devam et
}
await new Promise(r => setTimeout(r, 3000));

// Cookies + storage state kaydet
const state   = await context.storageState();
const cookies = state.cookies.filter(c =>
  c.domain.includes('investing.com') || c.domain.includes('fusionauth')
);

if (cookies.length === 0) {
  console.error('HATA: Cookie bulunamadı. Giriş tam tamamlanmamış olabilir.');
  console.error('Tekrar dene ve Pro sayfasının yüklendiğinden emin ol.');
  await browser.close();
  process.exit(1);
}

fs.writeFileSync(OUT, JSON.stringify(cookies, null, 2));
console.log(`\nCookies kaydedildi: ${OUT}`);
console.log(`Toplam: ${cookies.length} cookie`);

// GitHub Secret için base64 çıktı
const b64 = Buffer.from(JSON.stringify(cookies)).toString('base64');
console.log('\n' + '='.repeat(60));
console.log('GitHub Secret olarak ekle:');
console.log('  Repo: github.com/emres2729-lang/pro-cloud-sinyal');
console.log('  Yol : Settings → Secrets → Actions → New secret');
console.log('  Ad  : INVESTING_COOKIES');
console.log('  Değer (aşağıdaki tek satırı kopyala):');
console.log('='.repeat(60));
console.log(b64);
console.log('='.repeat(60) + '\n');

await browser.close();
console.log('Bitti. Artık GitHub Actions çalışabilir.');

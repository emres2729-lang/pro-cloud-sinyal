/**
 * ProPicks Cloud — Günlük AI Hisse İstihbarat Sistemi
 * Playwright ile Investing.com Pro'ya giriş, TR/US/EU ProPicks tarama,
 * günlük karşılaştırma, 0-100 skor, Telegram hedge-fon raporu.
 */

import { chromium } from 'playwright';
import fs   from 'fs';
import https from 'https';
import path  from 'path';
import { fileURLToPath } from 'url';

const ROOT     = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const DATA_DIR = path.join(ROOT, 'data');
fs.mkdirSync(DATA_DIR, { recursive: true });

const EMAIL    = process.env.INVESTING_EMAIL;
const PASSWORD = process.env.INVESTING_PASSWORD;
const TOKEN    = process.env.TELEGRAM_BOT_TOKEN;
const CHAT     = process.env.TELEGRAM_CHAT_ID;
const DRY      = process.argv.includes('--dry');

const STATE_FILE    = path.join(DATA_DIR, 'propicks_state.json');
const PREV_FILE     = path.join(DATA_DIR, 'propicks_prev.json');

const now = () => new Date().toLocaleString('tr-TR', { timeZone: 'Europe/Istanbul' });
const log = (...a) => console.log(`[${now()}]`, ...a);
const delay = ms => new Promise(r => setTimeout(r, ms));

// ── STRATEJI LİSTESİ ────────────────────────────────────────────────────
const STRATEGIES = {
  US: [
    { id: 'beat-sp-500',      name: "S&P 500'ü Geride Bırakın" },
    { id: 'tech-titans',      name: 'Teknoloji Devleri'         },
    { id: 'top-value-stocks', name: 'En İyi Değer Sunan'        },
    { id: 'midcap-movers',    name: 'Orta Ölçekli Şirketler'    },
    { id: 'dominate-the-dow', name: 'Dow Performansı'           },
  ],
  EU: [
    { id: 'beat-dax',         name: "DAX'ı Geride Bırakın"  },
    { id: 'top-eu-stocks',    name: 'Top Avrupa Hisseleri'  },
    { id: 'european-gems',    name: 'Avrupa Mücevherleri'   },
  ],
  TR: [
    { id: 'bist-stars',       name: 'BIST Yıldızları'  },
    { id: 'tr-value',         name: 'Türkiye Değer'     },
    { id: 'bist20-picks',     name: 'BIST20 ProPicks'   },
  ],
};

const BASE = 'https://www.investing.com';

// ── STATE ────────────────────────────────────────────────────────────────
function loadState(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return {}; }
}
function saveState(file, data) {
  fs.writeFileSync(file, JSON.stringify(data, null, 2));
}

// ── LOGIN ────────────────────────────────────────────────────────────────
async function login(page) {
  log('Investing.com Pro giriş yapılıyor...');
  await page.goto(`${BASE}/login`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await delay(2000);

  // Email
  const emailSel = ['input[name="email"]', '#email', 'input[type="email"]', 'input[placeholder*="mail" i]'];
  let emailFilled = false;
  for (const sel of emailSel) {
    try {
      await page.fill(sel, EMAIL, { timeout: 3000 });
      emailFilled = true;
      log(`  Email girildi (${sel})`);
      break;
    } catch {}
  }
  if (!emailFilled) throw new Error('Email input bulunamadı');

  // Password
  const passSel = ['input[name="password"]', '#password', 'input[type="password"]'];
  let passFilled = false;
  for (const sel of passSel) {
    try {
      await page.fill(sel, PASSWORD, { timeout: 3000 });
      passFilled = true;
      log(`  Şifre girildi (${sel})`);
      break;
    } catch {}
  }
  if (!passFilled) throw new Error('Password input bulunamadı');

  // Submit
  const submitSel = ['button[type="submit"]', 'input[type="submit"]', 'button:has-text("Sign In")', 'button:has-text("Giriş")'];
  for (const sel of submitSel) {
    try {
      await page.click(sel, { timeout: 3000 });
      log(`  Giriş butonu tıklandı (${sel})`);
      break;
    } catch {}
  }

  await delay(4000);

  // Captcha kontrolü
  const captcha = await page.$('[class*="captcha"], #captcha, iframe[src*="captcha"]');
  if (captcha) {
    log('⚠ CAPTCHA tespit edildi — giriş başarısız olabilir');
    await sendTelegram(`⚠️ <b>ProPicks Cloud</b>\n\nCAPTCHA nedeniyle Investing.com girişi başarısız.\nManüel giriş gerekiyor.`);
    throw new Error('CAPTCHA bloğu');
  }

  // Giriş başarı kontrolü
  const url = page.url();
  if (url.includes('/login') || url.includes('/register')) {
    throw new Error(`Giriş başarısız — hâlâ login sayfasında: ${url}`);
  }

  log(`✓ Giriş başarılı → ${url}`);
}

// ── STRATEJİ SAYFASI ÇEK ───────────────────────────────────────────────
async function fetchStrategy(page, stratId, stratName, bolge) {
  const url = `${BASE}/pro/propicks/${stratId}`;
  log(`  Taranıyor: ${stratName} (${url})`);

  try {
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 20000 });
    await delay(3000);

    // Tablo yüklenene kadar bekle
    try {
      await page.waitForSelector('table tbody tr, [class*="tableRow"], [class*="stock-row"]', { timeout: 10000 });
    } catch {
      log(`    Tablo bulunamadı: ${stratName}`);
      return [];
    }

    // Hisseleri çek
    const stocks = await page.evaluate((bolge, stratName) => {
      const results = [];

      // Tablo yaklaşımı
      const table = document.querySelector('table');
      if (table) {
        const rows = table.querySelectorAll('tbody tr');
        rows.forEach(row => {
          const cells = [...row.querySelectorAll('td')].map(td => td.innerText.trim());
          if (cells.length < 2) return;

          const ticker  = cells[0]?.split('\n')[0]?.trim() || '';
          const sirket  = cells[0]?.split('\n')[1]?.trim() || cells[1]?.trim() || '';
          const fiyat   = cells[2]?.replace(',', '.') || cells[1]?.replace(',', '') || '';
          const degisim = cells[3] || cells[2] || '';
          const piyasaDegeri = cells[4] || '';
          const pe      = cells[5] || cells[6] || '';

          // Yeni eklendi mi?
          const isNew = row.innerHTML.toLowerCase().includes('new') ||
                        row.innerHTML.toLowerCase().includes('yeni') ||
                        row.className.toLowerCase().includes('new');

          if (ticker && ticker.length > 0 && ticker.length <= 10) {
            results.push({
              ticker, sirket, fiyat,
              degisim:    parseFloat(degisim.replace('%', '').replace(',', '.')) || 0,
              piyasaDeg:  piyasaDegeri,
              pe:         pe,
              yeniEklendi: isNew,
              strateji:   stratName,
              bolge,
              tarih:      new Date().toISOString().slice(0, 10),
            });
          }
        });
      }

      // React/SPA yaklaşımı (tablo yoksa)
      if (results.length === 0) {
        const rows = document.querySelectorAll('[class*="tableRow"], [class*="stock-row"], [class*="instrumentRow"]');
        rows.forEach(row => {
          const ticker = row.querySelector('[class*="symbol"], [class*="ticker"]')?.innerText?.trim();
          const sirket = row.querySelector('[class*="name"], [class*="title"]')?.innerText?.trim();
          const fiyat  = row.querySelector('[class*="price"]')?.innerText?.trim();
          const degStr = row.querySelector('[class*="change"], [class*="percent"]')?.innerText?.trim();
          const isNew  = row.innerHTML.toLowerCase().includes('new') || row.innerHTML.toLowerCase().includes('yeni');

          if (ticker) {
            results.push({
              ticker, sirket: sirket || '', fiyat: fiyat || '',
              degisim: parseFloat((degStr || '0').replace('%','').replace(',','.')) || 0,
              piyasaDeg: '', pe: '',
              yeniEklendi: isNew,
              strateji: stratName, bolge,
              tarih: new Date().toISOString().slice(0, 10),
            });
          }
        });
      }

      return results;
    }, bolge, stratName);

    log(`    → ${stocks.length} hisse bulundu`);
    return stocks;

  } catch (e) {
    log(`    HATA ${stratName}: ${e.message.slice(0, 80)}`);
    return [];
  }
}

// ── HİSSE BİRLEŞTİR (aynı ticker birden fazla stratejide) ───────────────
function birlestir(allStocks) {
  const map = new Map();
  for (const s of allStocks) {
    const key = s.ticker;
    if (!map.has(key)) {
      map.set(key, { ...s, stratejiler: [s.strateji], stratSayisi: 1 });
    } else {
      const ex = map.get(key);
      if (!ex.stratejiler.includes(s.strateji)) {
        ex.stratejiler.push(s.strateji);
        ex.stratSayisi++;
        if (s.yeniEklendi) ex.yeniEklendi = true;
      }
    }
  }
  return [...map.values()];
}

// ── SKOR (0-100) ────────────────────────────────────────────────────────
function skorHesapla(hisse) {
  let skor = 0;

  // Strateji sayısı (max 5 → 30 puan)
  skor += Math.min(hisse.stratSayisi * 10, 30);

  // Momentum — pozitif değişim iyi (max 20 puan)
  const deg = hisse.degisim || 0;
  if      (deg >  3) skor += 20;
  else if (deg >  1) skor += 15;
  else if (deg >  0) skor += 10;
  else if (deg > -1) skor += 5;
  else if (deg > -3) skor += 2;
  // < -3: 0 puan

  // P/E değerleme (max 20 puan)
  const pe = parseFloat((hisse.pe || '').replace(',', '.')) || 0;
  if      (pe > 0 && pe < 15)  skor += 20; // ucuz
  else if (pe >= 15 && pe < 25) skor += 15; // makul
  else if (pe >= 25 && pe < 40) skor += 8;  // pahalı ama büyüme
  else if (pe === 0)             skor += 10; // bilinmiyor — nötr

  // Yeni eklendi bonus (10 puan)
  if (hisse.yeniEklendi) skor += 10;

  // BIST maskeli sembol cezası
  if (/^X+:X+$/.test(hisse.ticker)) skor -= 20;

  return Math.max(0, Math.min(100, Math.round(skor)));
}

// ── GÜNLÜK KARŞILAŞTIRMA ────────────────────────────────────────────────
function karsilastir(bugun, dun) {
  const bugunMap = new Map(bugun.map(h => [h.ticker, h]));
  const dunMap   = new Map(dun.map(h => [h.ticker, h]));

  const yeniEklenen  = bugun.filter(h => !dunMap.has(h.ticker));
  const cikarilanlar = dun.filter(h => !bugunMap.has(h.ticker));

  const puanYukselenler = bugun
    .filter(h => dunMap.has(h.ticker) && h.skor > (dunMap.get(h.ticker)?.skor || 0) + 5)
    .sort((a, b) => (b.skor - (dunMap.get(b.ticker)?.skor || 0)) - (a.skor - (dunMap.get(a.ticker)?.skor || 0)));

  return { yeniEklenen, cikarilanlar, puanYukselenler };
}

// ── TELEGRAM ─────────────────────────────────────────────────────────────
function sendTelegram(text) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ chat_id: CHAT, text, parse_mode: 'HTML', disable_web_page_preview: true });
    const req = https.request({
      hostname: 'api.telegram.org',
      path: `/bot${TOKEN}/sendMessage`,
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d = ''; r.on('data', c => d += c); r.on('end', () => res(JSON.parse(d))); });
    req.on('error', rej);
    req.write(body); req.end();
  });
}

// ── RAPOR FORMATLA ───────────────────────────────────────────────────────
function formatRapor(bolge, hisseler, prev, etikle) {
  const dunMap = new Map((prev[bolge] || []).map(h => [h.ticker, h]));
  const { yeniEklenen, cikarilanlar, puanYukselenler } = karsilastir(hisseler, prev[bolge] || []);
  const enGuclu = hisseler.sort((a, b) => b.skor - a.skor).slice(0, 5);

  const BOLGE_ADI = { US: 'ABD', EU: 'AVRUPA', TR: 'TÜRKİYE / BIST' };
  const ad = BOLGE_ADI[bolge] || bolge;

  let msg = `\n<b>━━ ${ad} ━━</b>\n`;

  if (yeniEklenen.length > 0) {
    msg += `\n🟢 <b>Yeni Eklenenler</b>\n`;
    for (const h of yeniEklenen.slice(0, 5)) {
      msg += `<b>${h.ticker}</b> ${h.sirket ? '· ' + h.sirket.slice(0,25) : ''}\n`;
      msg += `Skor: ${h.skor}/100 · Strateji: ${h.stratejiler.join(', ').slice(0,50)}\n`;
      if (h.degisim !== 0) msg += `Değişim: ${h.degisim > 0 ? '+' : ''}${h.degisim.toFixed(2)}%\n`;
      msg += '\n';
    }
  }

  if (cikarilanlar.length > 0) {
    msg += `🔴 <b>Çıkarılanlar</b>\n`;
    for (const h of cikarilanlar.slice(0, 5)) {
      msg += `<b>${h.ticker}</b> · Eski skor: ${h.skor || '?'}\n`;
    }
    msg += '\n';
  }

  if (puanYukselenler.length > 0) {
    msg += `📈 <b>Puanı Yükselenler</b>\n`;
    for (const h of puanYukselenler.slice(0, 3)) {
      const eskiSkor = dunMap.get(h.ticker)?.skor || 0;
      msg += `<b>${h.ticker}</b> ${eskiSkor}→${h.skor} puan\n`;
    }
    msg += '\n';
  }

  if (enGuclu.length > 0) {
    msg += `⭐ <b>En Güçlü (Skor ≥ 60)</b>\n`;
    const yuksek = enGuclu.filter(h => h.skor >= 60);
    if (yuksek.length === 0) {
      msg += `— Bu bölgede eşiği geçen hisse yok\n`;
    } else {
      for (const h of yuksek) {
        msg += `<b>${h.ticker}</b> ${h.skor}/100`;
        if (h.stratSayisi > 1) msg += ` · ${h.stratSayisi} strateji`;
        if (h.degisim) msg += ` · ${h.degisim > 0 ? '+' : ''}${h.degisim.toFixed(2)}%`;
        msg += '\n';
      }
    }
    msg += '\n';
  }

  return msg;
}

// ── ANA FONKSİYON ────────────────────────────────────────────────────────
async function main() {
  log('═══════════════════════════════════════════════');
  log('  ProPicks Cloud — Günlük AI İstihbarat');
  log(`  Tarih: ${new Date().toLocaleDateString('tr-TR')}`);
  log('═══════════════════════════════════════════════');

  if (!EMAIL || !PASSWORD) {
    log('HATA: INVESTING_EMAIL veya INVESTING_PASSWORD eksik');
    process.exit(1);
  }

  // Önceki günün verisi
  const prev = loadState(STATE_FILE);
  // Bugünün verisini doldur
  const bugun = { US: [], EU: [], TR: [], tarih: new Date().toISOString().slice(0, 10) };

  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-dev-shm-usage'],
  });

  const context = await browser.newContext({
    userAgent: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36',
    viewport: { width: 1280, height: 900 },
    locale: 'tr-TR',
  });

  const page = await context.newPage();
  page.setDefaultTimeout(30000);

  try {
    // 1. GİRİŞ
    await login(page);
    await delay(2000);

    // 2. HER BÖLGE İÇİN STRATEJİLERİ TARA
    for (const [bolge, stratejiler] of Object.entries(STRATEGIES)) {
      log(`\n── ${bolge} bölgesi taranıyor (${stratejiler.length} strateji) ──`);
      const bolgeHisseler = [];

      for (const str of stratejiler) {
        const stocks = await fetchStrategy(page, str.id, str.name, bolge);
        bolgeHisseler.push(...stocks);
        await delay(1500);
      }

      // Birleştir ve skor hesapla
      const birlesik = birlestir(bolgeHisseler).map(h => ({ ...h, skor: skorHesapla(h) }));
      bugun[bolge] = birlesik.sort((a, b) => b.skor - a.skor);
      log(`  ${bolge} toplam: ${bugun[bolge].length} benzersiz hisse`);
    }

  } catch (e) {
    log('KRİTİK HATA:', e.message);
    if (!DRY) {
      await sendTelegram(`⚠️ <b>ProPicks Cloud HATA</b>\n\n${e.message.slice(0, 200)}`);
    }
  } finally {
    await browser.close();
  }

  // 3. TELEGRAM RAPORU OLUŞTUR
  const toplamHisse = Object.values(bugun).flat().filter(Array.isArray).flat().length;

  let msg = `🏦 <b>GÜNLÜK AI PİYASA TARAMASI</b>\n`;
  msg += `📅 ${new Date().toLocaleDateString('tr-TR', { weekday:'long', day:'numeric', month:'long' })}\n`;
  msg += `☁️ <i>Investing.com Pro · ProPicks AI</i>\n\n`;

  // Bölge raporları
  for (const bolge of ['TR', 'US', 'EU']) {
    if (bugun[bolge]?.length > 0) {
      msg += formatRapor(bolge, bugun[bolge], prev, bolge);
    }
  }

  // Genel özet
  const tumHisseler = [...(bugun.TR || []), ...(bugun.US || []), ...(bugun.EU || [])];
  const yeniTopla   = tumHisseler.filter(h => !loadState(STATE_FILE)[h.bolge]?.find(p => p.ticker === h.ticker));

  msg += `\n<b>━━ SEKTÖR ROTASYONU ━━</b>\n`;
  const bolge_us = bugun.US || [];
  const techAgirligi = bolge_us.filter(h => h.stratejiler?.some(s => s.toLowerCase().includes('tech')));
  msg += techAgirligi.length > 0
    ? `📡 Teknoloji: ${techAgirligi.slice(0,3).map(h=>h.ticker).join(' · ')}\n`
    : `— Sektör sinyali yetersiz\n`;

  msg += `\n<b>━━ RİSK UYARISI ━━</b>\n`;
  const dusukSkor = tumHisseler.filter(h => h.skor < 40);
  if (dusukSkor.length > 0) {
    msg += `⚠ Düşük skor (<40): ${dusukSkor.slice(0,3).map(h=>h.ticker).join(' · ')}\n`;
  }
  msg += `Tarama: ${new Date().toLocaleTimeString('tr-TR', { timeZone:'Europe/Istanbul' })}`;

  // 4. GÖNDER
  if (DRY) {
    log('\n[DRY]\n' + msg.replace(/<[^>]+>/g, ''));
  } else {
    // Telegram 4096 karakter limiti — gerekirse böl
    const chunks = [];
    let cur = '';
    for (const line of msg.split('\n')) {
      if ((cur + '\n' + line).length > 3800) {
        chunks.push(cur);
        cur = line;
      } else {
        cur += (cur ? '\n' : '') + line;
      }
    }
    if (cur) chunks.push(cur);

    for (const chunk of chunks) {
      const r = await sendTelegram(chunk);
      if (r.ok) log('✓ Telegram gönderildi');
      else log('✗ Telegram HATA:', r.description);
      await delay(500);
    }
  }

  // 5. STATE KAYDET
  if (Object.keys(prev).length) saveState(PREV_FILE, prev);
  saveState(STATE_FILE, bugun);
  log('\nTamamlandı.');
}

main().catch(e => { log('FATAL:', e.message); process.exit(1); });

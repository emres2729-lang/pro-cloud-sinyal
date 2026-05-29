# ProCloudGoldEA — MetaTrader 5 Otomatik Al-Sat Robotu (XAUUSD / Altın)

Çok katmanlı **trend-pullback (geri çekilme)** stratejisi + sıkı risk yönetimi ile altın (XAUUSD) için tasarlanmış MQL5 Expert Advisor.

> ⚠️ **ÖNEMLİ — ÖNCE OKU:** Hiçbir EA kâr garantisi vermez. Geçmiş performans gelecek sonucu garantilemez. Kaldıraçlı işlemler **bütün sermayeni kaybetmene** yol açabilir. Bu yazılım eğitim/araştırma amaçlıdır. Gerçek parada kullanmadan önce **mutlaka demo hesapta + Strateji Test Cihazı (backtest) ile** kendi broker'ında doğrula. Tüm risk sana aittir.

---

## Neden bu strateji? (Felsefe)

Piyasada "kesin para kazandıran sihirli indikatör" yoktur — olsaydı satılmazdı. Gerçek sistematik trading'de kâr şu üç şeyden gelir:

1. **İstatistiksel avantaj (edge):** Birden çok şartın aynı anda doğrulanması (confluence) ile rastgele girişlerden daha iyi olasılık.
2. **Risk yönetimi:** Kazançların kayıplardan büyük olması (pozitif risk:ödül) + her işlemde küçük, sabit risk.
3. **Disiplin:** Kuralların duygusuz, tutarlı uygulanması — EA'nın asıl gücü budur.

Bu EA, "tek indikatör kesişimi" gibi naif yaklaşımlar yerine **5 katmanlı bir filtre zinciri** kullanır.

---

## Strateji mantığı

İşlem açılması için **tüm** şartların sağlanması gerekir:

| Katman | Filtre | Amaç |
|--------|--------|------|
| 1 | **Üst zaman dilimi trend** (H1: fiyat > EMA200 ve EMA50 > EMA200) | Sadece ana trend yönünde işlem |
| 2 | **EMA dizilimi** (giriş TF: EMA21 / EMA50 hizalı) | Yerel trend teyidi |
| 3 | **Pullback + tepki** (fiyat EMA21'e çekilip oradan tepki verir) | İyi giriş fiyatı, kovalamayı önler |
| 4 | **ADX ≥ eşik** | Yatay (range) piyasayı eler — altında en çok para burada kaybedilir |
| 5 | **RSI momentum** + **ATR volatilite** + **seans** + **spread** | Gürültü, ölü piyasa ve yüksek maliyet filtreleri |

**Çıkış / yönetim:**
- ATR tabanlı **Stop Loss** (altının volatilitesine uyum sağlar)
- **R-katı Take Profit** (varsayılan 1:2 risk:ödül)
- **Break-even**: 1R kâra ulaşınca stop girişe çekilir (risksiz işlem)
- **ATR trailing stop**: trend devam ederse kârı kovalar

**Sermaye koruması:**
- Her işlemde **sabit % risk** → lot otomatik hesaplanır
- **Günlük zarar limiti**: limit dolunca o gün işlem durur
- Maksimum eşzamanlı pozisyon sayısı
- Spread çok genişlediğinde işlem açmaz

---

## Kurulum

1. MetaTrader 5'i aç → **Dosya → Veri Klasörünü Aç** (File → Open Data Folder).
2. `mt5/Experts/ProCloudGoldEA.mq5` dosyasını `MQL5/Experts/` klasörüne kopyala.
3. MetaTrader'da **Gezgin (Navigator)** panelinde sağ tık → **Yenile** (Refresh).
4. **MetaEditor**'ı aç, `ProCloudGoldEA.mq5`'i aç ve **Derle (F7)** — hata olmamalı.
5. XAUUSD grafiğini aç (önerilen zaman dilimi: **M15**), EA'yı grafiğe sürükle.
6. Ayarlar penceresinde **Load** ile `mt5/Presets/ProCloudGoldEA_XAUUSD_M15.set` dosyasını yükle.
7. **"Algo Trading"** butonunun aktif (yeşil) olduğundan emin ol.

---

## Backtest (Strateji Test Cihazı) — Gerçek paradan ÖNCE şart

1. MetaTrader 5'te **Görünüm → Strateji Test Cihazı** (Ctrl+R).
2. Expert: `ProCloudGoldEA`, Sembol: `XAUUSD`, Zaman dilimi: `M15`.
3. **Model: "Her tik" (Every tick based on real ticks)** seç — gerçekçi sonuç için.
4. Mümkün olan en uzun tarih aralığını seç (en az 1-2 yıl).
5. **Spread:** "Current" yerine gerçekçi sabit değer (ör. altında 20-40 puan) kullan.
6. Çalıştır ve şunlara bak:
   - **Profit Factor** (> 1.3 iyi)
   - **Maksimum Drawdown %** (düşük olmalı — sermayenin kaldırabileceği seviye)
   - **Toplam işlem sayısı** (anlamlı sonuç için 100+)
   - **Recovery Factor**, **Sharpe Ratio**

> Backtest'te güzel görünmesi yetmez. **Forward test** (demo'da canlı veri ile birkaç hafta) yapmadan gerçek paraya geçme.

---

## Optimizasyon

Strateji Test Cihazı'nda **Optimization** sekmesinden şu parametreleri tara:

- `InpADXMin` (18–28, adım 2)
- `InpSL_ATR_Mult` (1.2–2.5, adım 0.1)
- `InpTP_R_Mult` (1.5–3.0, adım 0.25)
- `InpFastEMA` (14–34, adım 2)

> **Aşırı optimizasyondan (overfitting) kaçın.** Çok fazla parametreyi geçmişe birebir uydurmak canlıda çöker. Az sayıda, mantıklı parametre + **walk-forward / out-of-sample test** kullan.

---

## Parametre referansı

| Parametre | Varsayılan | Açıklama |
|-----------|-----------|----------|
| `InpRiskPercent` | 1.0 | İşlem başına risk (% bakiye). Yeni başlayan: 0.5 |
| `InpMaxDailyLossPct` | 4.0 | Günlük maks. zarar → o gün dur |
| `InpMaxPositions` | 1 | Aynı anda maks. pozisyon |
| `InpMaxSpreadPoints` | 60 | Üstündeyse işlem açma |
| `InpFixedLot` | 0.0 | >0 ise % risk yerine sabit lot |
| `InpTrendTF` | H1 | Trend zaman dilimi |
| `InpADXMin` | 22.0 | Min trend gücü (yükselt → daha az ama daha güçlü sinyal) |
| `InpSL_ATR_Mult` | 1.8 | SL = ATR × bu |
| `InpTP_R_Mult` | 2.0 | TP = R-katı (risk:ödül) |
| `InpUseTrailing` | true | ATR trailing stop |
| `InpStartHour`/`InpEndHour` | 8 / 21 | Seans saatleri (sunucu saati!) |

> **Sunucu saati uyarısı:** Seans saatleri broker sunucu saatine göredir, kendi yerel saatine değil. Broker'ın GMT offset'ini öğrenip saatleri ona göre ayarla.

---

## Risk uyarısı (tekrar)

- Bu bir **araç**tır, ATM değil. Piyasa koşulları değişir; her stratejinin kayıp dönemleri (drawdown) olur.
- **Sadece kaybetmeyi göze alabileceğin parayla** ve düşük risk yüzdesiyle başla.
- Önce **demo → küçük gerçek hesap → kademeli artış** yolunu izle.
- Bu yazılım finansal tavsiye değildir.

---

## Dosya yapısı

```
mt5/
├── Experts/
│   └── ProCloudGoldEA.mq5          # Ana EA (tek dosya, kendi kendine yeterli)
├── Presets/
│   └── ProCloudGoldEA_XAUUSD_M15.set  # Önerilen başlangıç ayarları
└── README.md                        # Bu dosya
```

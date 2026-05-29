# Pro Cloud Sinyal — MetaTrader 5 Otomatik Al-Sat Robotları (XAUUSD / Altın)

Bu klasörde iki adet birbirini tamamlayan MQL5 Expert Advisor bulunur:

| EA | Strateji | Piyasa rejimi | Önerilen TF |
|----|----------|---------------|-------------|
| **ProCloudGoldEA** | Çok katmanlı trend-pullback | Trend günleri | M15 |
| **ProCloudLiquidityEA** | Asya range likidite süpürme → denge dönüşü | Range/dengeli günler | M5 / M15 |

> İkisi farklı piyasa koşullarında çalışır. **Farklı `Magic Number` ile** ayrı grafiklerde aynı anda çalıştırılabilirler.

---

# 1) ProCloudGoldEA — Trend-Pullback Robotu

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

---

# 2) ProCloudLiquidityEA — Asya Range Likidite Süpürme Robotu

Senin fikrinden doğan strateji: **"Gece range'i + likidite süpürme → orta band (denge) dönüşü"** — kurumsal trader'ların kullandığı mean-reversion modeli.

### Nasıl çalışır?

1. **Range oluşumu:** Gece penceresinde (varsayılan **02:00–06:00 sunucu saati**) range hesaplanır:
   - **RH** = pencerenin en yükseği (üst likidite)
   - **RL** = pencerenin en düşüğü (alt likidite)
   - **EQ** = (RH + RL) / 2 = orta band / denge
2. **Likidite süpürme:** Trade penceresinde (range bitiminden `InpTradeEndHour`'a kadar) fiyat range dışına taşıp **likidite süzer** (`InpSweepMinPoints` kadar penetrasyon = gürültü filtresi).
3. **MSS teyidi (PROFESYONEL ÇEKİRDEK):** ICT araştırmasının kritik bulgusu — **süpürme tek başına giriş sinyali değildir.** Süpürmeden sonra **Market Structure Shift (MSS / yapı kırılımı = CHoCH)** beklenir: fiyatın son `InpMSS_Lookback` barlık mikro yapıyı ters yönde kırması. Bu, "düşen bıçağı tutmayı" ciddi şekilde azaltır. (`InpEntryMode=ENTRY_MSS`)
4. **Giriş:** MSS onayında süpürme yönünün **tersine** girilir:
   - Üst süpürüldü + aşağı MSS → **SAT** (SL süpürme tepesinin üstü)
   - Alt süpürüldü + yukarı MSS → **AL** (SL süpürme dibinin altı)
5. **Yönetim (koşucu modu):** EQ'da pozisyonun `InpPartialPercent`'i kapatılır, stop BE'ye çekilir, kalan **karşı likiditeye** (RL/RH) taşınır.
6. **Zaman stopu:** `InpForceCloseHour`'da açık pozisyon kapatılır (gece riski yok).

### Giriş modları (`InpEntryMode`)

| Mod | Davranış | Kime |
|-----|----------|------|
| `ENTRY_MSS` (önerilen) | Süpürme → **yapı kırılımı teyidi** → gir | Daha az ama daha kaliteli sinyal |
| `ENTRY_IMMEDIATE` | Süpürme + içeri kapanış → anında gir | Agresif, daha çok sinyal |

### Profesyonel kurallar (yerleşik)

- **MSS (yapı kırılımı) teyitli giriş** — araştırma temelli çekirdek
- **HTF bias filtresi** (`InpBiasFilter=BIAS_HTF`): yalnızca üst zaman dilimi trendi yönünde fade
- Stop manipülasyon fitilinin tam dışında (mantıklı invalidasyon)
- **Günde tek setup** (`InpOneTradePerDay`) → aşırı işlem yok
- **Range kalite filtresi**: çok küçük (gürültü) / çok büyük (trend günü) range elenir
- **Prop-firm seviyesi risk:** günlük zarar limiti + **toplam drawdown** (`InpMaxTotalDDPct`) dolunca EA **kalıcı durur** + opsiyonel equity-peak trailing
- Range/RH/RL/EQ çizgileri grafiğe çizilir → görsel doğrulama

### Kurulum & test

`ProCloudLiquidityEA.mq5`'i `MQL5/Experts/` klasörüne kopyala, derle (F7), **XAUUSD M5/M15** grafiğine sürükle, `ProCloudLiquidityEA_XAUUSD_M5.set` presetini yükle. Backtest'i "her tik" modeliyle yap.

> ⚠️ **Sunucu saati:** `02:00–06:00` MT5 **sunucu saatidir**, yerel saatin değil. Sunucu saatini öğrenmek için grafikteki son bar'ın saatine bak veya **Market Watch** üzerinde sembolün saatini kontrol et. Türkiye (GMT+3) ile broker'ın (genelde GMT+2/+3) arasında 0-1 saat fark olabilir; saatleri ona göre kaydır.

> ⚠️ **Puan/ondalık uyarısı:** Varsayılan puan değerleri (MinRange=150, Sweep=20, SL buffer=30) altının **2 ondalıklı** (1$ = 100 puan) gösterildiğini varsayar. Broker'ın altını **3 ondalıklı** gösteriyorsa bu değerleri **×10** yap.

> ⚠️ **Küçük hesap notu:** Risk yüzdesinden hesaplanan lot, broker'ın minimum lotunun (0.01) altına düşerse EA o işlemi **açmaz** (riski aşmamak için). Çok küçük hesapta işlem görmüyorsan `InpRiskPercent`'i artır veya `InpFixedLot` kullan.

### Önemli parametreler

| Parametre | Varsayılan | Açıklama |
|-----------|-----------|----------|
| `InpEntryMode` | ENTRY_MSS | Giriş modu (MSS teyitli / Immediate) |
| `InpMSS_Lookback` | 3 | MSS: kaç barlık mikro swing kırılmalı |
| `InpConfirmWindowBars` | 12 | Süpürme sonrası MSS için maks. bekleme barı |
| `InpBiasFilter` | BIAS_OFF | HTF trend filtresi (OFF / BIAS_HTF) |
| `InpRangeStartHour` / `InpRangeEndHour` | 2 / 6 | Range penceresi (sunucu saati) |
| `InpTradeEndHour` | 12 | Bu saatten sonra yeni setup aranmaz |
| `InpForceCloseHour` | 16 | Zaman stopu — açık pozisyon kapatılır |
| `InpSweepMinPoints` | 20 | Likidite için min penetrasyon |
| `InpUseRunner` | true | EQ'da yarı kapa + koşucu |
| `InpPartialPercent` | 50 | EQ'da kapatılacak yüzde |
| `InpOneTradePerDay` | true | Günde tek setup |
| `InpMaxTotalDDPct` | 10.0 | Toplam drawdown limiti → EA kalıcı durur |
| `InpUseTrailingDD` | false | Max DD'yi equity zirvesinden ölç (prop-firm trailing) |

---

## Araştırma & metodoloji

Bu EA'lar rastgele değil, kurumsal/ICT (Inner Circle Trader) ve prop-firm literatürüne dayanır:

- **Asya Range & Likidite Süpürme:** Asya seansında oluşan range'in üst/alt likiditesi Londra/NY açılışında süpürülür ("Judas swing" / stop avı), ardından denge bölgesine dönüş eğilimi.
- **Market Structure Shift (MSS / CHoCH):** ICT'nin temel kuralı — *"Süpürme tek başına giriş değildir; tetikleyici, süpürme sonrası mikro yapı kırılımıdır."* EA tam olarak bunu uygular.
- **Prop-firm risk standardı:** Çoğu fon **günlük %4-5 + toplam %10 drawdown** uygular; ihlal = hesap iptali. EA'da günlük + toplam DD koruması ve opsiyonel equity-peak trailing bu standarda göre tasarlandı.

**Kaynaklar:**
- [ICT Asian Range — Session Times, Liquidity Sweep Strategy](https://innercircletrader.net/tutorials/ict-asian-range/)
- [ICT Asian Session Liquidity Sweep Model](https://icttrading.org/ict-asian-session-liquidity-sweep-model/)
- [ICT Fair Value Gap (FVG) — 6-Step Strategy](https://innercircletrader.net/tutorials/fair-value-gap-trading-strategy/)
- [Master XAUUSD Order Blocks: Gold Trading with ICT Strategy (FXNX)](https://fxnx.com/en/blog/xauusd-order-blocks-gold-trading-ict-guide)
- [MT5 Prop Firm EA Rules: Daily Loss, News, Lots (AlfaTactix)](https://alfatactix.com/academy/mql5-ea/ea-prop-firm-rules-mt5)
- [Prop Firm Drawdown Rules Explained: Daily vs Max (ThinkCapital)](https://www.thinkcapital.com/prop-firm-drawdown-rules/)

> **Gelecek adım (opsiyonel):** MSS sonrası oluşan **FVG (Fair Value Gap)** bölgesine limit emirle giriş — daha iyi fiyat/R:R. İstenirse eklenebilir.

---

## Dosya yapısı

```
mt5/
├── Experts/
│   ├── ProCloudGoldEA.mq5             # Trend-pullback EA
│   └── ProCloudLiquidityEA.mq5        # Asya range likidite süpürme EA
├── Presets/
│   ├── ProCloudGoldEA_XAUUSD_M15.set
│   └── ProCloudLiquidityEA_XAUUSD_M5.set
└── README.md                          # Bu dosya
```

//+------------------------------------------------------------------+
//|                                       ProCloudLiquidityEA.mq5     |
//|              Pro Cloud Sinyal - Asya Range Likidite Suzme EA (Pro)|
//|                                                                  |
//|  Strateji: "Asya Range + Likidite Suzme -> MSS Teyidi -> Denge"  |
//|    1) Gece penceresinde (orn. 02:00-06:00 sunucu saati) range    |
//|       olusur: RH (ust), RL (alt), EQ (orta band = %50).          |
//|    2) Fiyat range disina cikip likidite suzer (stop avi).        |
//|    3) PROFESYONEL TEYIT: suzme tek basina giris DEGILDIR.         |
//|       Suzme sonrasi Market Structure Shift (MSS) beklenir =       |
//|       fiyatin mikro yapiyi ters yonde kirmasi (CHoCH).            |
//|    4) MSS onayinda suzme yonunun TERSINE girilir, hedef EQ;       |
//|       kosucu modda kalan karsi likiditeye tasinir.               |
//|                                                                  |
//|  Risk (prop-firm seviyesi):                                      |
//|    - % risk lot + gunluk zarar limiti (equity bazli)             |
//|    - TOPLAM max drawdown -> EA kalici durur                      |
//|    - Equity-peak trailing drawdown secenegi                      |
//|    - Gunde tek setup, zaman stopu, range kalite filtresi         |
//|                                                                  |
//|  Arastirma temeli: ICT Asian Range / Liquidity Sweep / MSS /     |
//|  CHoCH metodolojisi + prop-firm drawdown standartlari.           |
//|                                                                  |
//|  UYARI: Kar garantisi YOKTUR. Once DEMO + Strateji Test Cihazi.  |
//|  Saatler SUNUCU saatine goredir.                                 |
//+------------------------------------------------------------------+
#property copyright "Pro Cloud Sinyal"
#property link      "https://github.com/emres2729-lang/pro-cloud-sinyal"
#property version   "3.00"
#property description "Asya range + likidite suzme + MSS + FVG/OB konfluans + HTF miknatis + haber filtresi (XAUUSD)."

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

//==================================================================//
//                            ENUMS                                 //
//==================================================================//
enum ENUM_ENTRY_MODE
{
   ENTRY_IMMEDIATE = 0, // Hizli: suzme + iceri kapanis -> aninda gir (agresif)
   ENTRY_MSS       = 1  // Teyitli: suzme + yapi kirilimi (MSS) -> gir (ONERILEN)
};

enum ENUM_BIAS_FILTER
{
   BIAS_OFF   = 0, // Her iki yon (saf mean-reversion)
   BIAS_HTF   = 1  // Sadece HTF trend yonunde fade et (sweep karsi-trend olmali)
};

//==================================================================//
//                            INPUTS                                //
//==================================================================//
input group "=== Genel ==="
input long     InpMagic          = 20260530;   // Magic Number (diger EA'lardan FARKLI!)
input string   InpComment        = "ProCloudLiq"; // Islem yorumu

input group "=== Risk Yonetimi (Prop-Firm Seviyesi) ==="
input double   InpRiskPercent    = 1.0;        // Islem basina risk (% bakiye)
input double   InpMaxDailyLossPct= 4.0;        // Gunluk maks. zarar (%) -> gun durur
input double   InpMaxTotalDDPct  = 10.0;       // TOPLAM maks. drawdown (%) -> EA KALICI durur
input bool     InpUseTrailingDD  = false;      // true: max DD equity-zirvesinden olculur (daha siki)
input double   InpMaxSpreadPoints= 60;         // Maks. izin verilen spread (puan)
input double   InpFixedLot       = 0.0;        // >0 ise sabit lot kullanir

input group "=== Range / Seans (Sunucu Saati) ==="
input int      InpRangeStartHour = 2;          // Range baslangic saati (sunucu)
input int      InpRangeEndHour   = 6;          // Range bitis saati (sunucu)
input int      InpTradeEndHour   = 12;         // Bu saatten sonra yeni setup aranmaz
input int      InpForceCloseHour = 16;         // Zaman stopu - acik pozisyon kapatilir

input group "=== Range Kalite Filtresi ==="
input double   InpMinRangePoints = 150;        // Min range boyu (puan)
input double   InpMaxRangePoints = 2000;       // Maks range boyu (puan) - trend gununu eler
// NOT: Altin 2 ondalikli ise 1$=100 puan. 3 ondalikli ise puan degerlerini x10 yapin.

input group "=== Giris / Teyit (PROFESYONEL) ==="
input ENUM_ENTRY_MODE InpEntryMode = ENTRY_MSS; // Giris modu (ONERILEN: MSS teyitli)
input double   InpSweepMinPoints = 20;         // Likidite icin min penetrasyon (puan)
input int      InpMSS_Lookback   = 3;          // MSS: kac barlik mikro swing kirilmali
input int      InpConfirmWindowBars = 12;      // Suzme sonrasi MSS icin maks bekleme bari
input double   InpSLBufferPoints = 30;         // SL, suzme fitilinin disinda buffer (puan)

input group "=== FVG (Fair Value Gap) Girisi ==="
input bool     InpUseFVGEntry    = true;       // MSS sonrasi FVG'ye limit emirle gir (yoksa market)
input double   InpFVGFillRatio   = 0.5;        // FVG icinde giris: 0=proksimal(kolay) 0.5=orta(CE) 1=derin(en iyi fiyat)
input double   InpFVGMinPoints    = 10;        // Min FVG boyu (puan) - cok kucuk bosluk sayilmaz
input int      InpFVGExpiryBars   = 8;         // Limit emir bu kadar barda dolmazsa iptal

input group "=== Order Block (OB) Konfluans ==="
input bool     InpUseOrderBlock   = true;      // FVG'ye ek OB bolgesi kullan (konfluans/precision)

input group "=== HTF FVG Miknatis Hedefi ==="
input bool     InpUseHTF_Magnet   = false;     // Kosucu hedefini en yakin HTF FVG'ye tasi
input ENUM_TIMEFRAMES InpMagnetTF = PERIOD_H1; // Miknatis zaman dilimi
input int      InpMagnetLookback  = 60;        // HTF kac barda FVG aranir

input group "=== Haber Filtresi (Ekonomik Takvim) ==="
input bool     InpUseNewsFilter   = true;      // Yuksek etkili haberlerde islem durdur
input string   InpNewsCurrency    = "USD";     // Hangi para birimi haberleri (altin = USD)
input int      InpNewsBeforeMin   = 30;        // Haberden kac dk ONCE dur
input int      InpNewsAfterMin    = 30;        // Haberden kac dk SONRA dur
input bool     InpNewsHighOnly    = true;      // true: sadece yuksek etki; false: orta+yuksek

input group "=== HTF Bias Filtresi ==="
input ENUM_BIAS_FILTER InpBiasFilter = BIAS_OFF; // Trend yonu filtresi
input ENUM_TIMEFRAMES  InpBiasTF     = PERIOD_H4; // Bias zaman dilimi
input int      InpBiasEMA        = 200;        // Bias EMA periyodu

input group "=== Hedef / Kosucu ==="
input bool     InpUseRunner      = true;       // EQ'da yari kapa + kalani karsi likiditeye tasi
input double   InpPartialPercent = 50.0;       // EQ'da kapatilacak yuzde
input bool     InpBE_AfterPartial= true;       // Kismi kardan sonra SL -> BE
input double   InpBE_BufferPoints= 10;         // BE buffer (puan)

input group "=== Islem Sikligi ==="
input bool     InpOneTradePerDay = true;       // Gunde tek setup

input group "=== Gorsel ==="
input bool     InpDrawRange      = true;       // Range/EQ cizgilerini ciz
input color    InpRangeColor     = clrSlateGray;
input color    InpEQColor        = clrGold;

//==================================================================//
//                         GLOBAL OBJELER                           //
//==================================================================//
CTrade         trade;
CPositionInfo  posInfo;

int      hATR, hBiasEMA;
double   g_point;
int      g_digits;
datetime g_lastBarTime = 0;

// Hesap geneli (kalici)
double   g_initialBalance = 0;
double   g_peakEquity     = 0;
bool     g_eaHalted       = false;  // toplam DD doldu -> kalici dur

// Gunluk durum
datetime g_dayKey         = 0;
double   g_dayStartBalance= 0;
bool     g_tradingHalted  = false;  // gunluk limit
bool     g_rangeReady     = false;
bool     g_rangeValid     = false;
double   g_rh = 0, g_rl = 0, g_eq = 0;
bool     g_tradedToday    = false;

// Suzme / MSS durum makinesi
int      g_sweepState     = 0;      // 0=yok, +1=long icin armed, -1=short icin armed
double   g_sweepExtreme   = 0;      // long: suzme dibi, short: suzme tepesi
int      g_armBars        = 0;      // armed olduktan sonra gecen bar
bool     g_sweptHighDone  = false;
bool     g_sweptLowDone   = false;

// Aktif pozisyon
ulong    g_activeTicket   = 0;
int      g_activeDir      = 0;
double   g_eqTarget       = 0;
bool     g_partialDone    = false;

// FVG bekleyen limit emir
ulong    g_pendingTicket  = 0;
int      g_pendingDir     = 0;
int      g_pendingBars    = 0;

//==================================================================//
//                            OnInit                                //
//==================================================================//
int OnInit()
{
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   hATR = iATR(_Symbol, _Period, 14);
   if(hATR == INVALID_HANDLE) { Print("HATA: ATR handle."); return(INIT_FAILED); }

   if(InpBiasFilter == BIAS_HTF)
   {
      hBiasEMA = iMA(_Symbol, InpBiasTF, InpBiasEMA, 0, MODE_EMA, PRICE_CLOSE);
      if(hBiasEMA == INVALID_HANDLE) { Print("HATA: Bias EMA handle."); return(INIT_FAILED); }
   }

   if(InpRangeStartHour >= InpRangeEndHour)
      Print("UYARI: Range baslangic < bitis olmali (gece yarisi gecisi desteklenmez).");

   g_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_peakEquity     = AccountInfoDouble(ACCOUNT_EQUITY);
   g_eaHalted       = false;

   ResetDailyState();

   PrintFormat("ProCloudLiquidityEA v2 | %s | Range %02d:00-%02d:00 | Giris=%s | Risk=%.2f%% | MaxDD=%.1f%%",
               _Symbol, InpRangeStartHour, InpRangeEndHour,
               (InpEntryMode==ENTRY_MSS?"MSS":"Immediate"), InpRiskPercent, InpMaxTotalDDPct);

   if(StringFind(_Symbol, "XAU") < 0)
      Print("UYARI: Bu EA XAUUSD (Altin) icin ayarlanmistir.");

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   IndicatorRelease(hATR);
   if(InpBiasFilter == BIAS_HTF) IndicatorRelease(hBiasEMA);
   if(InpDrawRange) ObjectsDeleteAll(0, "PCLIQ_");
}

//==================================================================//
//                            OnTick                                //
//==================================================================//
void OnTick()
{
   // Hesap geneli drawdown korumasi (her tick)
   UpdateAccountDrawdownGuard();

   // Yeni gun
   datetime today = DayKey(TimeCurrent());
   if(today != g_dayKey) ResetDailyState();

   // Gunluk zarar korumasi
   UpdateDailyRiskGuard();

   // Acik pozisyon yonetimi + bekleyen emir + zaman stopu
   ManageActivePosition();
   ManagePendingOrder();
   ForceCloseCheck();

   // Yeni bar mi?
   datetime curBar = (datetime)iTime(_Symbol, _Period, 0);
   if(curBar == g_lastBarTime) return;
   g_lastBarTime = curBar;

   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);

   // Range hesapla
   if(!g_rangeReady && t.hour >= InpRangeEndHour)
      ComputeRange(today);

   // Bekleyen FVG emri varsa: bar sayaci + sure asimi iptali
   if(g_pendingTicket != 0)
   {
      g_pendingBars++;
      if(g_pendingBars > InpFVGExpiryBars)
      {
         if(trade.OrderDelete(g_pendingTicket))
            PrintFormat("FVG limit emri %d barda dolmadi -> iptal.", InpFVGExpiryBars);
         ClearPending();
      }
   }

   // Genel kosullar
   if(g_eaHalted || g_tradingHalted) return;
   if(!g_rangeReady || !g_rangeValid) return;
   if(t.hour < InpRangeEndHour || t.hour >= InpTradeEndHour) return;
   if(g_activeTicket != 0 || g_pendingTicket != 0) return;
   if(InpOneTradePerDay && g_tradedToday) return;
   if(!SpreadFilterPass()) return;
   if(!NewsFilterPass()) return;   // yuksek etkili haber penceresinde dur

   ProcessSweepStateMachine();
}

//==================================================================//
//                       RANGE HESAPLAMA                            //
//==================================================================//
void ComputeRange(datetime today)
{
   double rh = -DBL_MAX, rl = DBL_MAX;
   bool found = false;

   for(int i = 1; i < 5000; i++)
   {
      datetime bt = iTime(_Symbol, _Period, i);
      if(bt == 0) break;
      if(DayKey(bt) != today) break;

      MqlDateTime mt; TimeToStruct(bt, mt);
      if(mt.hour >= InpRangeStartHour && mt.hour < InpRangeEndHour)
      {
         double hi = iHigh(_Symbol, _Period, i);
         double lo = iLow (_Symbol, _Period, i);
         if(hi > rh) rh = hi;
         if(lo < rl) rl = lo;
         found = true;
      }
   }

   g_rangeReady = true;
   if(!found) { g_rangeValid = false; Print("Range bulunamadi."); return; }

   g_rh = rh; g_rl = rl;
   g_eq = NormalizeDouble((rh + rl) / 2.0, g_digits);

   double rangePoints = (rh - rl) / g_point;
   g_rangeValid = (rangePoints >= InpMinRangePoints && rangePoints <= InpMaxRangePoints);

   PrintFormat("RANGE | RH=%.*f RL=%.*f EQ=%.*f | %.0f puan | gecerli=%s",
               g_digits, rh, g_digits, rl, g_digits, g_eq, rangePoints,
               (g_rangeValid ? "EVET" : "HAYIR"));

   if(InpDrawRange) DrawRange(today);
}

//==================================================================//
//             SUZME + MSS DURUM MAKINESI (PROFESYONEL)             //
//==================================================================//
void ProcessSweepStateMachine()
{
   double h1 = iHigh (_Symbol, _Period, 1);
   double l1 = iLow  (_Symbol, _Period, 1);
   double c1 = iClose(_Symbol, _Period, 1);
   double o1 = iOpen (_Symbol, _Period, 1);
   double sweepBuf = InpSweepMinPoints * g_point;

   // --- Henuz armed degilse: suzme ara ---
   if(g_sweepState == 0)
   {
      bool highSwept = (h1 > g_rh + sweepBuf) && !g_sweptHighDone;
      bool lowSwept  = (l1 < g_rl - sweepBuf) && !g_sweptLowDone;

      // Bias filtresi: sadece HTF trend yonunde fade
      // (ust suzme -> SAT, bias bearish olmali; alt suzme -> AL, bias bullish olmali)
      if(highSwept && BiasAllows(-1))
      {
         if(InpEntryMode == ENTRY_IMMEDIATE)
         {
            if(c1 < g_rh) { g_sweptHighDone = true; OpenTrade(-1, NormalizeDouble(h1 + InpSLBufferPoints*g_point, g_digits)); }
         }
         else // MSS modu: armed yap, teyit bekle
         {
            g_sweepState   = -1;
            g_sweepExtreme = h1;
            g_armBars      = 0;
            PrintFormat("SUZME (ust) tespit | tepe=%.*f | MSS teyidi bekleniyor...", g_digits, h1);
         }
         return;
      }
      if(lowSwept && BiasAllows(+1))
      {
         if(InpEntryMode == ENTRY_IMMEDIATE)
         {
            if(c1 > g_rl) { g_sweptLowDone = true; OpenTrade(+1, NormalizeDouble(l1 - InpSLBufferPoints*g_point, g_digits)); }
         }
         else
         {
            g_sweepState   = +1;
            g_sweepExtreme = l1;
            g_armBars      = 0;
            PrintFormat("SUZME (alt) tespit | dip=%.*f | MSS teyidi bekleniyor...", g_digits, l1);
         }
         return;
      }
      return;
   }

   // --- Armed: MSS (yapi kirilimi) teyidi bekle ---
   g_armBars++;
   if(g_armBars > InpConfirmWindowBars)
   {
      PrintFormat("MSS teyidi gelmedi (%d bar) | setup iptal.", InpConfirmWindowBars);
      if(g_sweepState > 0) g_sweptLowDone = true; else g_sweptHighDone = true;
      g_sweepState = 0;
      return;
   }

   if(g_sweepState > 0) // LONG icin armed (alt suzuldu)
   {
      // suzme uzadiysa extreme guncelle
      if(l1 < g_sweepExtreme) { g_sweepExtreme = l1; g_armBars = 0; }

      // MSS: son kapanan bar, son N barin tepesini yukari kirdi + bogalı kapanis
      double microHigh = HighestHigh(2, InpMSS_Lookback);
      if(c1 > microHigh && c1 > o1)
      {
         g_sweptLowDone = true;
         g_sweepState   = 0;
         double sl = NormalizeDouble(g_sweepExtreme - InpSLBufferPoints * g_point, g_digits);
         PrintFormat("MSS ONAY (long) | %.*f > mikroTepe %.*f | giriliyor.", g_digits, c1, g_digits, microHigh);
         EnterAfterMSS(+1, sl);
      }
   }
   else // SHORT icin armed (ust suzuldu)
   {
      if(h1 > g_sweepExtreme) { g_sweepExtreme = h1; g_armBars = 0; }

      double microLow = LowestLow(2, InpMSS_Lookback);
      if(c1 < microLow && c1 < o1)
      {
         g_sweptHighDone = true;
         g_sweepState    = 0;
         double sl = NormalizeDouble(g_sweepExtreme + InpSLBufferPoints * g_point, g_digits);
         PrintFormat("MSS ONAY (short) | %.*f < mikroDip %.*f | giriliyor.", g_digits, c1, g_digits, microLow);
         EnterAfterMSS(-1, sl);
      }
   }
}

//==================================================================//
//                         ISLEM ACMA                               //
//==================================================================//
void OpenTrade(int dir, double sl)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price, tp;
   ENUM_ORDER_TYPE type;

   if(dir > 0)
   {
      type = ORDER_TYPE_BUY; price = ask;
      tp = RunnerTarget(+1, price);
      if(price >= g_eq) { Print("AL atlandi: fiyat zaten EQ ustunde."); return; }
   }
   else
   {
      type = ORDER_TYPE_SELL; price = bid;
      tp = RunnerTarget(-1, price);
      if(price <= g_eq) { Print("SAT atlandi: fiyat zaten EQ altinda."); return; }
   }
   tp = NormalizeDouble(tp, g_digits);

   double slDistPoints = MathAbs(price - sl) / g_point;
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stopLevel > 0 && slDistPoints < stopLevel)
   { PrintFormat("Islem atlandi: SL (%.0f) < min (%d).", slDistPoints, stopLevel); return; }

   double lot = CalculateLot(slDistPoints);
   if(lot <= 0) { Print("Islem atlandi: gecersiz lot (risk%/min lot)."); return; }

   if(trade.PositionOpen(_Symbol, type, lot, price, sl, tp, InpComment))
   {
      g_activeTicket = PositionLastTicket();
      g_activeDir    = dir;
      g_eqTarget     = g_eq;
      g_partialDone  = false;
      g_tradedToday  = true;
      PrintFormat("ISLEM ACILDI | %s | lot=%.2f | giris=%.*f | SL=%.*f | TP=%.*f | kosucu=%s",
                  (dir>0?"AL":"SAT"), lot, g_digits, price, g_digits, sl, g_digits, tp,
                  (InpUseRunner?"acik":"kapali"));
   }
   else
      PrintFormat("Islem ACILAMADI | retcode=%d | %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
}

ulong PositionLastTicket()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!posInfo.SelectByTicket(ticket)) continue;
      if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic) return ticket;
   }
   return 0;
}

//==================================================================//
//             MSS SONRASI GIRIS: FVG LIMIT veya MARKET             //
//==================================================================//
void EnterAfterMSS(int dir, double sl)
{
   double zTop, zBot;
   if(ComputeEntryZone(dir, zTop, zBot))
   {
      // zTop = bolgenin ust kenari, zBot = alt kenar
      double entry = (dir > 0)
                     ? NormalizeDouble(zTop - (zTop - zBot) * InpFVGFillRatio, g_digits)  // long: proksimal=ust
                     : NormalizeDouble(zBot + (zTop - zBot) * InpFVGFillRatio, g_digits); // short: proksimal=alt
      if(PlaceFVGLimit(dir, entry, sl)) return;
   }
   // Gecerli bolge yok / limit kurulamadi -> market girisi
   OpenTrade(dir, sl);
}

//------------------------------------------------------------------//
// Giris bolgesi: FVG + OB konfluans. Ikisi de varsa kesisim (en kaliteli),
// yoksa biri, hicbiri yoksa false (-> market).
//------------------------------------------------------------------//
bool ComputeEntryZone(int dir, double &zTop, double &zBot)
{
   bool hasFVG = false, hasOB = false;
   double fTop=0, fBot=0, oTop=0, oBot=0;

   double h1 = iHigh(_Symbol, _Period, 1);
   double l1 = iLow (_Symbol, _Period, 1);
   double h3 = iHigh(_Symbol, _Period, 3);
   double l3 = iLow (_Symbol, _Period, 3);
   double minGap = InpFVGMinPoints * g_point;

   if(InpUseFVGEntry)
   {
      if(dir > 0 && l1 > h3 + minGap) { hasFVG = true; fTop = l1; fBot = h3; } // bogalı FVG
      if(dir < 0 && h1 < l3 - minGap) { hasFVG = true; fTop = l3; fBot = h1; } // ayılı FVG
   }
   if(InpUseOrderBlock)
      hasOB = FindOrderBlock(dir, oTop, oBot);

   if(hasFVG && hasOB)
   {
      double top = MathMin(fTop, oTop);
      double bot = MathMax(fBot, oBot);
      if(top > bot) { zTop = top; zBot = bot; Print("Giris bolgesi: FVG+OB KONFLUANS (kesisim)."); return true; }
      // ortusme yok -> taze imbalance (FVG) tercih
      zTop = fTop; zBot = fBot; return true;
   }
   if(hasFVG) { zTop = fTop; zBot = fBot; return true; }
   if(hasOB)  { zTop = oTop; zBot = oBot; Print("Giris bolgesi: Order Block."); return true; }
   return false;
}

//------------------------------------------------------------------//
// Order Block: displacement oncesi son ters mum (long: son ayı, short: son boğa)
//------------------------------------------------------------------//
bool FindOrderBlock(int dir, double &top, double &bot)
{
   int maxLook = InpMSS_Lookback + InpConfirmWindowBars + 3;
   for(int i = 2; i <= maxLook; i++)
   {
      double o = iOpen(_Symbol, _Period, i);
      double c = iClose(_Symbol, _Period, i);
      if(dir > 0 && c < o) { top = iHigh(_Symbol,_Period,i); bot = iLow(_Symbol,_Period,i); return true; }
      if(dir < 0 && c > o) { top = iHigh(_Symbol,_Period,i); bot = iLow(_Symbol,_Period,i); return true; }
   }
   return false;
}

//------------------------------------------------------------------//
// Kosucu hedefi: HTF FVG miknatisi aktifse en yakin uygun HTF bosluga tasi
//------------------------------------------------------------------//
double RunnerTarget(int dir, double entry)
{
   double def = (dir > 0) ? (InpUseRunner ? g_rh : g_eq) : (InpUseRunner ? g_rl : g_eq);
   if(!(InpUseRunner && InpUseHTF_Magnet)) return def;

   double m = FindHTF_Magnet(dir, entry);
   if(m > 0)
   {
      if(dir > 0 && m > g_eq) return m;
      if(dir < 0 && m < g_eq) return m;
   }
   return def;
}

double FindHTF_Magnet(int dir, double fromPrice)
{
   double best = 0, bestDist = DBL_MAX;
   for(int i = 1; i <= InpMagnetLookback; i++)
   {
      double hiOld = iHigh(_Symbol, InpMagnetTF, i+1);
      double loNew = iLow (_Symbol, InpMagnetTF, i-1);
      double loOld = iLow (_Symbol, InpMagnetTF, i+1);
      double hiNew = iHigh(_Symbol, InpMagnetTF, i-1);

      if(dir > 0 && loNew > hiOld)            // bogalı HTF FVG -> yukari hedef
      {
         double target = hiOld;               // proksimal kenar (ilk dokunulan)
         if(target > fromPrice)
         { double d = target - fromPrice; if(d < bestDist) { bestDist = d; best = target; } }
      }
      if(dir < 0 && hiNew < loOld)            // ayılı HTF FVG -> asagi hedef
      {
         double target = loOld;
         if(target < fromPrice)
         { double d = fromPrice - target; if(d < bestDist) { bestDist = d; best = target; } }
      }
   }
   return best;
}

//------------------------------------------------------------------//
// Haber filtresi: ekonomik takvimde yuksek etkili olay penceresinde dur.
// NOT: Strateji Test Cihazi'nda takvim verisi yoktur -> tester'da pas gecer.
//------------------------------------------------------------------//
bool NewsFilterPass()
{
   if(!InpUseNewsFilter) return true;
   if(MQLInfoInteger(MQL_TESTER)) return true; // tester'da calendar API calismaz

   datetime now  = TimeCurrent();
   datetime from = now - InpNewsAfterMin  * 60;
   datetime to   = now + InpNewsBeforeMin * 60;

   MqlCalendarValue values[];
   int n = CalendarValueHistory(values, from, to, NULL, InpNewsCurrency);
   if(n <= 0) return true;

   ENUM_CALENDAR_EVENT_IMPORTANCE need = InpNewsHighOnly ? CALENDAR_IMPORTANCE_HIGH
                                                         : CALENDAR_IMPORTANCE_MODERATE;
   for(int i = 0; i < n; i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev)) continue;
      if(ev.importance >= need)
         return false; // haber penceresi -> islem yok
   }
   return true;
}

bool PlaceFVGLimit(int dir, double entry, double sl)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   long   stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist   = stopLevel * g_point;

   double tp = NormalizeDouble(RunnerTarget(dir, entry), g_digits);

   double slDistPoints = MathAbs(entry - sl) / g_point;
   if(stopLevel > 0 && slDistPoints < stopLevel) return false;

   double lot = CalculateLot(slDistPoints);
   if(lot <= 0) return false;

   bool ok = false;
   if(dir > 0)
   {
      if(entry >= ask - minDist) return false; // fiyat zaten FVG'yi gecmis -> market'e dus
      ok = trade.BuyLimit(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, InpComment);
   }
   else
   {
      if(entry <= bid + minDist) return false;
      ok = trade.SellLimit(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, InpComment);
   }

   if(ok)
   {
      g_pendingTicket = trade.ResultOrder();
      g_pendingDir    = dir;
      g_pendingBars   = 0;
      PrintFormat("FVG LIMIT EMRI | %s LIMIT | giris=%.*f | SL=%.*f | TP=%.*f | lot=%.2f",
                  (dir>0?"BUY":"SELL"), g_digits, entry, g_digits, sl, g_digits, tp, lot);
      return true;
   }
   PrintFormat("FVG limit kurulamadi (retcode=%d) -> market'e dusuluyor.", trade.ResultRetcode());
   return false;
}

void ManagePendingOrder()
{
   if(g_pendingTicket == 0) return;

   // Hala bekleyen emir mi?
   if(OrderSelect(g_pendingTicket))
   {
      // Setup gecersizlesti mi? Fiyat fill olmadan EQ'ya ulastiysa hareketi kacirdik -> iptal
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      bool eqReached = (g_pendingDir > 0) ? (bid >= g_eq) : (ask <= g_eq);
      if(eqReached)
      {
         if(trade.OrderDelete(g_pendingTicket))
            Print("FVG limit iptal: fiyat dolmadan EQ'ya ulasti (hareket kacti).");
         ClearPending();
      }
      return;
   }

   // Emir havuzda yok -> ya doldu (pozisyon) ya silindi
   ulong posT = PositionLastTicket();
   if(posT != 0 && g_activeTicket == 0)
   {
      g_activeTicket = posT;
      g_activeDir    = g_pendingDir;
      g_eqTarget     = g_eq;
      g_partialDone  = false;
      g_tradedToday  = true;
      Print("FVG LIMIT DOLDU -> pozisyon aktif, yonetim devrede.");
   }
   ClearPending();
}

void ClearPending()
{
   g_pendingTicket = 0;
   g_pendingDir    = 0;
   g_pendingBars   = 0;
}

//==================================================================//
//                   AKTIF POZISYON YONETIMI                        //
//==================================================================//
void ManageActivePosition()
{
   if(g_activeTicket == 0) return;
   if(!posInfo.SelectByTicket(g_activeTicket))
   { g_activeTicket = 0; g_partialDone = false; return; }

   if(!InpUseRunner) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double openPrice = posInfo.PriceOpen();
   double volume    = posInfo.Volume();

   if(!g_partialDone)
   {
      bool reachedEQ = (g_activeDir > 0) ? (bid >= g_eqTarget) : (ask <= g_eqTarget);
      if(reachedEQ)
      {
         double closeVol = NormalizeLot(volume * InpPartialPercent / 100.0);
         if(closeVol > 0 && closeVol < volume)
         {
            if(trade.PositionClosePartial(g_activeTicket, closeVol))
               PrintFormat("KISMI KAPAMA | %.2f lot EQ'da (%.*f).", closeVol, g_digits, g_eqTarget);
         }
         g_partialDone = true;

         if(InpBE_AfterPartial && posInfo.SelectByTicket(g_activeTicket))
         {
            double curTP = posInfo.TakeProfit();
            double be = (g_activeDir > 0)
                        ? NormalizeDouble(openPrice + InpBE_BufferPoints*g_point, g_digits)
                        : NormalizeDouble(openPrice - InpBE_BufferPoints*g_point, g_digits);
            trade.PositionModify(g_activeTicket, be, curTP);
            PrintFormat("BE | SL girise cekildi (%.*f).", g_digits, be);
         }
      }
   }
}

//==================================================================//
//                         ZAMAN STOPU                              //
//==================================================================//
void ForceCloseCheck()
{
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   if(t.hour < InpForceCloseHour) return;

   // Bekleyen emir varsa iptal
   if(g_pendingTicket != 0)
   {
      trade.OrderDelete(g_pendingTicket);
      ClearPending();
   }

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!posInfo.SelectByTicket(ticket)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagic) continue;
      if(trade.PositionClose(ticket))
         PrintFormat("ZAMAN STOPU | Pozisyon kapatildi (>= %02d:00).", InpForceCloseHour);
   }
   if(g_activeTicket != 0 && !posInfo.SelectByTicket(g_activeTicket))
      g_activeTicket = 0;
}

//==================================================================//
//                      LOT HESABI (% RISK)                         //
//==================================================================//
double CalculateLot(double slDistPoints)
{
   if(InpFixedLot > 0.0) return NormalizeLot(InpFixedLot);

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0) return 0;

   double lossPerLot = (slDistPoints * g_point / tickSize) * tickValue;
   if(lossPerLot <= 0) return 0;

   return NormalizeLot(riskMoney / lossPerLot);
}

double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0) lotStep = 0.01;

   lot = MathFloor(lot / lotStep) * lotStep;
   if(lot < minLot) lot = 0;       // risk%'in altina inerse islem acma / partial yapma
   if(lot > maxLot) lot = maxLot;

   int lotDigits = (int)MathRound(MathLog10(1.0/lotStep));
   if(lotDigits < 0) lotDigits = 2;
   return NormalizeDouble(lot, lotDigits);
}

//==================================================================//
//                  RISK KORUMA (GUNLUK + TOPLAM)                   //
//==================================================================//
void UpdateAccountDrawdownGuard()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_peakEquity) g_peakEquity = equity;

   if(g_eaHalted) return;

   // Baseline: trailing modda equity zirvesi, statik modda baslangic bakiyesi
   double baseline = InpUseTrailingDD ? g_peakEquity : g_initialBalance;
   double ddLimit  = baseline * (1.0 - InpMaxTotalDDPct / 100.0);

   if(equity <= ddLimit)
   {
      g_eaHalted = true;
      // Bekleyen emri iptal et
      if(g_pendingTicket != 0) { trade.OrderDelete(g_pendingTicket); ClearPending(); }
      // Guvenlik icin acik pozisyonlari kapat
      for(int i = PositionsTotal()-1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(!posInfo.SelectByTicket(ticket)) continue;
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic)
            trade.PositionClose(ticket);
      }
      g_activeTicket = 0;
      PrintFormat("!!! TOPLAM DRAWDOWN LIMITI (%.1f%%) DOLDU. EA KALICI DURDU. Equity=%.2f, Limit=%.2f",
                  InpMaxTotalDDPct, equity, ddLimit);
      Alert("ProCloudLiquidityEA: Toplam drawdown limiti doldu, EA durdu.");
   }
}

void UpdateDailyRiskGuard()
{
   if(g_tradingHalted) return;
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyPL = equity - g_dayStartBalance;
   double maxLoss = -(g_dayStartBalance * InpMaxDailyLossPct / 100.0);
   if(dailyPL <= maxLoss)
   {
      g_tradingHalted = true;
      PrintFormat("GUNLUK ZARAR LIMITI DOLDU (%.2f / %.2f). Bugun yeni setup yok.", dailyPL, maxLoss);
   }
}

void ResetDailyState()
{
   g_dayKey          = DayKey(TimeCurrent());
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_tradingHalted   = false;
   g_rangeReady      = false;
   g_rangeValid      = false;
   g_rh = 0; g_rl = 0; g_eq = 0;
   g_tradedToday     = false;
   g_sweepState      = 0;
   g_sweptHighDone   = false;
   g_sweptLowDone    = false;
   g_armBars         = 0;
}

//==================================================================//
//                           FILTRELER                              //
//==================================================================//
bool SpreadFilterPass()
{
   return ((double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpreadPoints);
}

// dir: +1 long (alt suzme fade), -1 short (ust suzme fade)
bool BiasAllows(int dir)
{
   if(InpBiasFilter == BIAS_OFF) return true;

   double ema[];
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(hBiasEMA, 0, 0, 2, ema) < 2) return true; // veri yoksa engelleme
   double biasClose = iClose(_Symbol, InpBiasTF, 1);
   bool bull = (biasClose > ema[1]);
   bool bear = (biasClose < ema[1]);

   if(dir > 0) return bull;  // sadece HTF yukari trendde long
   if(dir < 0) return bear;  // sadece HTF asagi trendde short
   return true;
}

//==================================================================//
//                          YARDIMCILAR                             //
//==================================================================//
double HighestHigh(int start, int count)
{
   int idx = iHighest(_Symbol, _Period, MODE_HIGH, count, start);
   if(idx < 0) return iHigh(_Symbol, _Period, start);
   return iHigh(_Symbol, _Period, idx);
}

double LowestLow(int start, int count)
{
   int idx = iLowest(_Symbol, _Period, MODE_LOW, count, start);
   if(idx < 0) return iLow(_Symbol, _Period, start);
   return iLow(_Symbol, _Period, idx);
}

datetime DayKey(datetime t)
{
   MqlDateTime mt; TimeToStruct(t, mt);
   return StringToTime(StringFormat("%04d.%02d.%02d", mt.year, mt.mon, mt.day));
}

void DrawRange(datetime today)
{
   ObjectsDeleteAll(0, "PCLIQ_");
   datetime t1 = today + InpRangeStartHour * 3600;
   datetime t2 = today + InpForceCloseHour * 3600;
   CreateTrend("PCLIQ_RH", t1, g_rh, t2, g_rh, InpRangeColor, STYLE_SOLID);
   CreateTrend("PCLIQ_RL", t1, g_rl, t2, g_rl, InpRangeColor, STYLE_SOLID);
   CreateTrend("PCLIQ_EQ", t1, g_eq, t2, g_eq, InpEQColor,    STYLE_DASH);
}

void CreateTrend(string name, datetime t1, double p1, datetime t2, double p2, color clr, int style)
{
   ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}
//+------------------------------------------------------------------+

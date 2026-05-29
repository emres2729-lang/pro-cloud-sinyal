//+------------------------------------------------------------------+
//|                                            ProCloudGoldEA.mq5     |
//|                              Pro Cloud Sinyal - Gold (XAUUSD) EA  |
//|                                                                  |
//|  Strateji: Cok katmanli trend-pullback sistemi                   |
//|    - Ust zaman dilimi trend filtresi (EMA dizilimi)              |
//|    - EMA'ya geri cekilme + tepki girisi (pullback-continuation)  |
//|    - ADX trend gucu filtresi (yatay piyasayi eler)              |
//|    - RSI momentum teyidi                                         |
//|    - ATR volatilite filtresi                                     |
//|    - Seans (saat) ve spread filtresi                             |
//|                                                                  |
//|  Risk yonetimi:                                                  |
//|    - Sabit % risk ile otomatik lot hesabi                        |
//|    - ATR tabanli SL, R-kati TP                                   |
//|    - Break-even + ATR trailing stop                              |
//|    - Gunluk zarar limiti (hesap korumasi)                        |
//|                                                                  |
//|  UYARI: Hicbir EA kar garantisi vermez. Once DEMO + Strateji     |
//|  Test Cihazi ile dogrulayin. Gercek para riski size aittir.      |
//+------------------------------------------------------------------+
#property copyright "Pro Cloud Sinyal"
#property link      "https://github.com/emres2729-lang/pro-cloud-sinyal"
#property version   "1.00"
#property description "Coklu-konfluans trend pullback EA - XAUUSD (Altin) icin optimize. ATR tabanli risk yonetimi, gunluk zarar limiti, seans filtresi."

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

//==================================================================//
//                            INPUTS                                //
//==================================================================//
input group "=== Genel ==="
input long     InpMagic          = 20260529;   // Magic Number (her EA icin benzersiz)
input string   InpComment        = "ProCloudGold"; // Islem yorumu

input group "=== Risk Yonetimi (Prop-Firm Seviyesi) ==="
input double   InpRiskPercent    = 1.0;        // Islem basina risk (% bakiye)
input double   InpMaxDailyLossPct= 4.0;        // Gunluk maks. zarar (%) -> islem durur
input double   InpMaxTotalDDPct  = 10.0;       // TOPLAM maks. drawdown (%) -> EA KALICI durur
input bool     InpUseTrailingDD  = false;      // true: max DD equity-zirvesinden olculur
input int      InpMaxPositions   = 1;          // Ayni anda maks. pozisyon sayisi
input double   InpMaxSpreadPoints= 60;         // Maks. izin verilen spread (puan)
input double   InpFixedLot       = 0.0;        // >0 ise sabit lot kullanir (% risk yerine)

input group "=== Trend Filtresi (Ust Zaman Dilimi) ==="
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_H1;  // Trend zaman dilimi
input int      InpTrendEMA       = 200;        // Ana trend EMA (HTF)
input int      InpTrendFastEMA   = 50;         // Hizli trend EMA (HTF)

input group "=== Giris (Calisma Zaman Dilimi) ==="
input int      InpFastEMA        = 21;         // Pullback EMA (giris TF)
input int      InpSlowEMA        = 50;         // Yon EMA (giris TF)
input int      InpADXPeriod      = 14;         // ADX periyodu
input double   InpADXMin         = 22.0;       // Min. ADX (trend gucu esigi)
input int      InpRSIPeriod      = 14;         // RSI periyodu
input double   InpRSIBuyMin      = 50.0;       // Alim icin min RSI
input double   InpRSISellMax     = 50.0;       // Satim icin maks RSI

input group "=== Stop / Hedef ==="
input int      InpATRPeriod      = 14;         // ATR periyodu
input double   InpSL_ATR_Mult    = 1.8;        // SL = ATR * carpan
input double   InpTP_R_Mult      = 2.0;        // TP = R-kati (risk:odul)
input double   InpATR_MinPoints  = 80;         // Min ATR (puan) - olu piyasa filtresi
input double   InpATR_MaxPoints  = 1200;       // Maks ATR (puan) - asiri volatilite filtresi

input group "=== Pozisyon Yonetimi ==="
input bool     InpUseBreakEven   = true;       // Break-even kullan
input double   InpBreakEvenR     = 1.0;        // Kac R karda BE'ye cek
input double   InpBreakEvenBuffer= 10;         // BE buffer (puan)
input bool     InpUseTrailing    = true;       // ATR trailing stop kullan
input double   InpTrail_ATR_Mult = 2.0;        // Trailing mesafe = ATR * carpan

input group "=== Seans Filtresi (Sunucu Saati) ==="
input bool     InpUseSession     = true;       // Seans filtresi aktif
input int      InpStartHour      = 8;          // Baslangic saati (sunucu)
input int      InpEndHour        = 21;         // Bitis saati (sunucu)
input bool     InpAvoidFriday    = true;       // Cuma gec saatlerde acma
input int      InpFridayStopHour = 19;         // Cuma bu saatten sonra acma

//==================================================================//
//                         GLOBAL OBJELER                           //
//==================================================================//
CTrade         trade;
CPositionInfo  posInfo;

// Indikator handle'lari
int hTrendEMA, hTrendFastEMA;    // HTF
int hFastEMA, hSlowEMA;          // giris TF
int hADX, hRSI, hATR;

double g_point;
int    g_digits;
datetime g_lastBarTime = 0;      // yeni bar tespiti
datetime g_dayStart    = 0;      // gunluk reset
double   g_dayStartBalance = 0;  // gun basi bakiye
bool     g_tradingHalted = false;// gunluk limit doldu mu
double   g_initialBalance = 0;   // EA baslangic bakiyesi (toplam DD baseline)
double   g_peakEquity     = 0;   // equity zirvesi (trailing DD)
bool     g_eaHalted       = false;// toplam DD doldu -> kalici dur

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

   // --- Indikator handle'lari ---
   hTrendEMA     = iMA(_Symbol, InpTrendTF, InpTrendEMA,     0, MODE_EMA, PRICE_CLOSE);
   hTrendFastEMA = iMA(_Symbol, InpTrendTF, InpTrendFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hFastEMA      = iMA(_Symbol, _Period,    InpFastEMA,      0, MODE_EMA, PRICE_CLOSE);
   hSlowEMA      = iMA(_Symbol, _Period,    InpSlowEMA,      0, MODE_EMA, PRICE_CLOSE);
   hADX          = iADX(_Symbol, _Period,   InpADXPeriod);
   hRSI          = iRSI(_Symbol, _Period,   InpRSIPeriod,    PRICE_CLOSE);
   hATR          = iATR(_Symbol, _Period,   InpATRPeriod);

   if(hTrendEMA==INVALID_HANDLE || hTrendFastEMA==INVALID_HANDLE ||
      hFastEMA==INVALID_HANDLE  || hSlowEMA==INVALID_HANDLE ||
      hADX==INVALID_HANDLE      || hRSI==INVALID_HANDLE     || hATR==INVALID_HANDLE)
   {
      Print("HATA: Indikator handle olusturulamadi.");
      return(INIT_FAILED);
   }

   // Risk takibi baslat
   g_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_peakEquity     = AccountInfoDouble(ACCOUNT_EQUITY);
   g_eaHalted       = false;
   ResetDailyTracking();

   PrintFormat("ProCloudGoldEA basladi | Sembol=%s | TF=%s | Risk=%.2f%% | GunlukLimit=%.2f%%",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period), InpRiskPercent, InpMaxDailyLossPct);

   if(StringFind(_Symbol, "XAU") < 0)
      Print("UYARI: Bu EA XAUUSD (Altin) icin ayarlanmistir. Farkli sembolde parametreleri yeniden optimize edin.");

   return(INIT_SUCCEEDED);
}

//==================================================================//
//                           OnDeinit                               //
//==================================================================//
void OnDeinit(const int reason)
{
   IndicatorRelease(hTrendEMA);
   IndicatorRelease(hTrendFastEMA);
   IndicatorRelease(hFastEMA);
   IndicatorRelease(hSlowEMA);
   IndicatorRelease(hADX);
   IndicatorRelease(hRSI);
   IndicatorRelease(hATR);
}

//==================================================================//
//                            OnTick                                //
//==================================================================//
void OnTick()
{
   // 0) Toplam drawdown korumasi (prop-firm seviyesi)
   UpdateAccountDrawdownGuard();

   // 1) Gunluk reset / limit kontrolu
   HandleDailyRiskGuard();

   // 2) Acik pozisyonlari her tick yonet (trailing / break-even)
   ManageOpenPositions();

   // Toplam DD dolduysa hicbir sey yapma
   if(g_eaHalted)
      return;

   // 3) Sadece YENI BAR acildiginda yeni sinyal ara (repaint/asiri islem onleme)
   datetime curBar = (datetime)iTime(_Symbol, _Period, 0);
   if(curBar == g_lastBarTime)
      return;
   g_lastBarTime = curBar;

   // Gunluk limit dolduysa yeni islem acma
   if(g_tradingHalted)
      return;

   // 4) Filtreler
   if(!SessionFilterPass())   return;
   if(!SpreadFilterPass())    return;
   if(CountMyPositions() >= InpMaxPositions) return;

   double atrPoints = GetATRPoints();
   if(atrPoints <= 0) return;
   if(atrPoints < InpATR_MinPoints || atrPoints > InpATR_MaxPoints) return; // volatilite filtresi

   // 5) Sinyal uret
   int signal = GetSignal();          // +1 = AL, -1 = SAT, 0 = yok
   if(signal == 0) return;

   // 6) Islemi ac
   OpenTrade(signal, atrPoints);
}

//==================================================================//
//                        SINYAL MOTORU                             //
//==================================================================//
// Donus: +1 alim, -1 satim, 0 sinyal yok
int GetSignal()
{
   // NOT: Tum buffer dizileri seri (timeseries) olarak ayarlanir.
   //      Boylece index [0]=acilan bar (shift 0), [1]=son KAPANAN bar (shift 1).
   //      Sinyaller son kapanan bar (index 1) uzerinden uretilir (repaint onleme).

   // --- Ust zaman dilimi trend yonu ---
   double htfEma[], htfFast[];
   ArraySetAsSeries(htfEma, true);
   ArraySetAsSeries(htfFast, true);
   if(CopyBuffer(hTrendEMA, 0, 0, 2, htfEma) < 2)   return 0;
   if(CopyBuffer(hTrendFastEMA, 0, 0, 2, htfFast) < 2) return 0;
   double htfClose = iClose(_Symbol, InpTrendTF, 1);

   bool htfBull = (htfClose > htfEma[1]) && (htfFast[1] > htfEma[1]);
   bool htfBear = (htfClose < htfEma[1]) && (htfFast[1] < htfEma[1]);
   if(!htfBull && !htfBear) return 0;

   // --- Giris TF gostergeleri (son kapanan bar = index 1) ---
   double fast[], slow[], adxBuf[], rsiBuf[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   ArraySetAsSeries(adxBuf, true);
   ArraySetAsSeries(rsiBuf, true);
   if(CopyBuffer(hFastEMA, 0, 0, 3, fast) < 3) return 0;
   if(CopyBuffer(hSlowEMA, 0, 0, 3, slow) < 3) return 0;
   if(CopyBuffer(hADX, 0, 0, 2, adxBuf) < 2) return 0;   // 0 = ana ADX hatti
   if(CopyBuffer(hRSI, 0, 0, 2, rsiBuf) < 2) return 0;
   double adx = adxBuf[1];
   double rsi = rsiBuf[1];

   if(adx < InpADXMin) return 0; // trend gucu yetersiz -> yatay piyasa, gec

   // Son kapanan bar fiyatlari
   double c1 = iClose(_Symbol, _Period, 1);
   double o1 = iOpen (_Symbol, _Period, 1);
   double h1 = iHigh (_Symbol, _Period, 1);
   double l1 = iLow  (_Symbol, _Period, 1);

   // --- ALIM: HTF bull + giris TF EMA dizilim + EMA'ya pullback + bogalı tepki ---
   if(htfBull)
   {
      bool emaStack    = fast[1] > slow[1];                 // trend dizilimi
      bool pullbackHit = (l1 <= fast[1]);                   // bar EMA'ya dokundu (geri cekilme)
      bool resumeUp    = (c1 > fast[1]) && (c1 > o1);       // EMA ustunde + bogalı kapanis
      bool momentum    = (rsi >= InpRSIBuyMin);             // momentum teyidi

      if(emaStack && pullbackHit && resumeUp && momentum)
         return +1;
   }

   // --- SATIM: HTF bear + giris TF EMA dizilim + EMA'ya pullback + ayılı tepki ---
   if(htfBear)
   {
      bool emaStack    = fast[1] < slow[1];
      bool pullbackHit = (h1 >= fast[1]);
      bool resumeDn    = (c1 < fast[1]) && (c1 < o1);
      bool momentum    = (rsi <= InpRSISellMax);

      if(emaStack && pullbackHit && resumeDn && momentum)
         return -1;
   }

   return 0;
}

//==================================================================//
//                         ISLEM ACMA                               //
//==================================================================//
void OpenTrade(int signal, double atrPoints)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double slDistPoints = atrPoints * InpSL_ATR_Mult;
   double tpDistPoints = slDistPoints * InpTP_R_Mult;

   double price, sl, tp;
   ENUM_ORDER_TYPE type;

   if(signal > 0)
   {
      type  = ORDER_TYPE_BUY;
      price = ask;
      sl    = NormalizeDouble(price - slDistPoints * g_point, g_digits);
      tp    = NormalizeDouble(price + tpDistPoints * g_point, g_digits);
   }
   else
   {
      type  = ORDER_TYPE_SELL;
      price = bid;
      sl    = NormalizeDouble(price + slDistPoints * g_point, g_digits);
      tp    = NormalizeDouble(price - tpDistPoints * g_point, g_digits);
   }

   // Broker min stop mesafesi kontrolu
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stopLevel > 0 && slDistPoints < stopLevel)
   {
      PrintFormat("Islem atlandi: SL mesafesi (%.0f puan) broker min seviyesinin (%d) altinda.",
                  slDistPoints, stopLevel);
      return;
   }

   double lot = CalculateLot(slDistPoints);
   if(lot <= 0)
   {
      Print("Islem atlandi: gecersiz lot hesabi.");
      return;
   }

   if(trade.PositionOpen(_Symbol, type, lot, price, sl, tp, InpComment))
   {
      PrintFormat("ISLEM ACILDI | %s | lot=%.2f | giris=%.*f | SL=%.*f | TP=%.*f | ATR=%.0fp",
                  (signal>0?"AL":"SAT"), lot, g_digits, price, g_digits, sl, g_digits, tp, atrPoints);
   }
   else
   {
      PrintFormat("Islem ACILAMADI | retcode=%d | %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//==================================================================//
//                      LOT HESABI (% RISK)                         //
//==================================================================//
double CalculateLot(double slDistPoints)
{
   // Sabit lot modu
   if(InpFixedLot > 0.0)
      return NormalizeLot(InpFixedLot);

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0) return 0;

   // 1 lot icin SL'de olusacak zarar
   double slPrice    = slDistPoints * g_point;
   double ticks      = slPrice / tickSize;
   double lossPerLot = ticks * tickValue;
   if(lossPerLot <= 0) return 0;

   double lot = riskMoney / lossPerLot;
   return NormalizeLot(lot);
}

double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0) lotStep = 0.01;

   lot = MathFloor(lot / lotStep) * lotStep;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   int lotDigits = (int)MathRound(MathLog10(1.0/lotStep));
   if(lotDigits < 0) lotDigits = 2;
   return NormalizeDouble(lot, lotDigits);
}

//==================================================================//
//                  POZISYON YONETIMI (BE + TRAIL)                  //
//==================================================================//
void ManageOpenPositions()
{
   if(!InpUseBreakEven && !InpUseTrailing) return;

   double atrPoints = GetATRPoints();
   if(atrPoints <= 0) return;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!posInfo.SelectByTicket(ticket)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic()  != InpMagic) continue;

      ENUM_POSITION_TYPE ptype = posInfo.PositionType();
      double openPrice = posInfo.PriceOpen();
      double curSL     = posInfo.StopLoss();
      double curTP     = posInfo.TakeProfit();

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      // R birimi = acilistaki SL mesafesi (yaklasik), trailing icin ATR kullaniyoruz
      double newSL = curSL;

      if(ptype == POSITION_TYPE_BUY)
      {
         double profitPoints = (bid - openPrice) / g_point;

         // Break-even
         if(InpUseBreakEven)
         {
            double initialRiskPts = MathAbs(openPrice - curSL) / g_point;
            if(initialRiskPts > 0 && profitPoints >= initialRiskPts * InpBreakEvenR)
            {
               double bePrice = NormalizeDouble(openPrice + InpBreakEvenBuffer * g_point, g_digits);
               if(bePrice > newSL) newSL = bePrice;
            }
         }
         // ATR trailing
         if(InpUseTrailing)
         {
            double trailSL = NormalizeDouble(bid - atrPoints * InpTrail_ATR_Mult * g_point, g_digits);
            if(trailSL > newSL && trailSL > openPrice) newSL = trailSL;
         }
         if(newSL > curSL + g_point) // anlamli degisim
            trade.PositionModify(ticket, newSL, curTP);
      }
      else if(ptype == POSITION_TYPE_SELL)
      {
         double profitPoints = (openPrice - ask) / g_point;

         if(InpUseBreakEven)
         {
            double initialRiskPts = MathAbs(curSL - openPrice) / g_point;
            if(initialRiskPts > 0 && profitPoints >= initialRiskPts * InpBreakEvenR)
            {
               double bePrice = NormalizeDouble(openPrice - InpBreakEvenBuffer * g_point, g_digits);
               if(newSL == 0 || bePrice < newSL) newSL = bePrice;
            }
         }
         if(InpUseTrailing)
         {
            double trailSL = NormalizeDouble(ask + atrPoints * InpTrail_ATR_Mult * g_point, g_digits);
            if((newSL == 0 || trailSL < newSL) && trailSL < openPrice) newSL = trailSL;
         }
         if(newSL > 0 && (curSL == 0 || newSL < curSL - g_point))
            trade.PositionModify(ticket, newSL, curTP);
      }
   }
}

//==================================================================//
//                  TOPLAM DRAWDOWN KORUMASI                        //
//==================================================================//
void UpdateAccountDrawdownGuard()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_peakEquity) g_peakEquity = equity;

   if(g_eaHalted) return;

   double baseline = InpUseTrailingDD ? g_peakEquity : g_initialBalance;
   double ddLimit  = baseline * (1.0 - InpMaxTotalDDPct / 100.0);

   if(equity <= ddLimit)
   {
      g_eaHalted = true;
      for(int i = PositionsTotal()-1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(!posInfo.SelectByTicket(ticket)) continue;
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic)
            trade.PositionClose(ticket);
      }
      PrintFormat("!!! TOPLAM DRAWDOWN LIMITI (%.1f%%) DOLDU. EA KALICI DURDU. Equity=%.2f Limit=%.2f",
                  InpMaxTotalDDPct, equity, ddLimit);
      Alert("ProCloudGoldEA: Toplam drawdown limiti doldu, EA durdu.");
   }
}

//==================================================================//
//                       GUNLUK RISK KORUMASI                       //
//==================================================================//
void HandleDailyRiskGuard()
{
   // Yeni gun mu? -> sifirla
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d", t.year, t.mon, t.day));
   if(today != g_dayStart)
      ResetDailyTracking();

   if(g_tradingHalted) return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyPL = equity - g_dayStartBalance;
   double maxLoss = -(g_dayStartBalance * InpMaxDailyLossPct / 100.0);

   if(dailyPL <= maxLoss)
   {
      g_tradingHalted = true;
      PrintFormat("GUNLUK ZARAR LIMITI DOLDU (%.2f / limit %.2f). Bugun yeni islem acilmayacak.",
                  dailyPL, maxLoss);
   }
}

void ResetDailyTracking()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   g_dayStart        = StringToTime(StringFormat("%04d.%02d.%02d", t.year, t.mon, t.day));
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_tradingHalted   = false;
}

//==================================================================//
//                           FILTRELER                              //
//==================================================================//
bool SessionFilterPass()
{
   if(!InpUseSession) return true;

   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);

   // Hafta sonu (cumartesi=6, pazar=0) zaten piyasa kapali; cuma gec saat filtresi
   if(InpAvoidFriday && t.day_of_week == 5 && t.hour >= InpFridayStopHour)
      return false;

   if(t.hour < InpStartHour || t.hour >= InpEndHour)
      return false;

   return true;
}

bool SpreadFilterPass()
{
   double spreadPoints = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spreadPoints > InpMaxSpreadPoints)
   {
      // sessiz gec (her tick log basmasin diye yalnizca debug)
      return false;
   }
   return true;
}

double GetATRPoints()
{
   double atr[1];
   if(CopyBuffer(hATR, 0, 1, 1, atr) < 1) return 0;
   return atr[0] / g_point;
}

//==================================================================//
//                          YARDIMCILAR                             //
//==================================================================//
int CountMyPositions()
{
   int count = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!posInfo.SelectByTicket(ticket)) continue;
      if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic)
         count++;
   }
   return count;
}
//+------------------------------------------------------------------+

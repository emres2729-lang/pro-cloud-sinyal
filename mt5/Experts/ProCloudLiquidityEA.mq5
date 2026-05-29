//+------------------------------------------------------------------+
//|                                       ProCloudLiquidityEA.mq5     |
//|                  Pro Cloud Sinyal - Asya Range Likidite Suzme EA  |
//|                                                                  |
//|  Strateji: "Asya Seansi Range + Likidite Suzme -> Denge Donusu"  |
//|    1) Gece penceresinde (orn. 02:00-06:00 sunucu saati) range    |
//|       olusur: RH (ust), RL (alt), EQ (orta band = %50).          |
//|    2) Trade penceresinde fiyat range disina cikip likidite       |
//|       suzer (fitil disari + govde iceri kapanis = reddetme).     |
//|    3) Suzme yonunun TERSINE girilir, hedef EQ (orta band);       |
//|       kosucu modda kalan karsi likiditeye (RL/RH) tasinir.       |
//|                                                                  |
//|  Profesyonel kurallar:                                           |
//|    - Suzme + iceri kapanis teyidi (knife-catching onleme)        |
//|    - SL suzme fitilinin tam disinda (manipulasyon noktasi)       |
//|    - EQ'da kismi kar + break-even, kalan kosucu                  |
//|    - Gunde tek setup (asiri islem onleme)                        |
//|    - Zaman stopu (seans bitince kapat, gece riski yok)           |
//|    - Range kalite filtresi (cok kucuk/buyuk range elenir)        |
//|    - % risk lot hesabi + gunluk zarar limiti + spread filtresi   |
//|                                                                  |
//|  UYARI: Kar garantisi YOKTUR. Once DEMO + Strateji Test Cihazi.  |
//|  Saatler SUNUCU saatine goredir (kendi yerel saatine degil).     |
//+------------------------------------------------------------------+
#property copyright "Pro Cloud Sinyal"
#property link      "https://github.com/emres2729-lang/pro-cloud-sinyal"
#property version   "1.00"
#property description "Asya range likidite suzme + denge donusu EA (XAUUSD). Suzme teyidi, EQ hedefi, kosucu, gunde tek setup, zaman stopu."

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

//==================================================================//
//                            INPUTS                                //
//==================================================================//
input group "=== Genel ==="
input long     InpMagic          = 20260530;   // Magic Number (ProCloudGold'dan FARKLI olmali!)
input string   InpComment        = "ProCloudLiq"; // Islem yorumu

input group "=== Risk Yonetimi ==="
input double   InpRiskPercent    = 1.0;        // Islem basina risk (% bakiye)
input double   InpMaxDailyLossPct= 4.0;        // Gunluk maks. zarar (%) -> islem durur
input double   InpMaxSpreadPoints= 60;         // Maks. izin verilen spread (puan)
input double   InpFixedLot       = 0.0;        // >0 ise sabit lot kullanir (% risk yerine)

input group "=== Range / Seans (Sunucu Saati) ==="
input int      InpRangeStartHour = 2;          // Range baslangic saati (sunucu)
input int      InpRangeEndHour   = 6;          // Range bitis saati (sunucu) - range bu saatte kesinlesir
input int      InpTradeEndHour   = 12;         // Bu saatten sonra YENI setup aranmaz
input int      InpForceCloseHour = 16;         // Bu saatte acik pozisyon zorla kapatilir (zaman stopu)

input group "=== Range Kalite Filtresi ==="
input double   InpMinRangePoints = 150;        // Min range boyu (puan). Cok kucuk = gec
input double   InpMaxRangePoints = 2000;       // Maks range boyu (puan). Cok buyuk (trend gunu) = gec
// NOT: Altin 2 ondalikli ise 1$ = 100 puan. Broker 3 ondalikli gosteriyorsa bu degerleri x10 yapin.

input group "=== Suzme (Sweep) Tespiti ==="
input double   InpSweepMinPoints = 20;         // Likidite icin fiyatin level'i en az bu kadar gecmesi (puan)
input bool     InpRequireCloseInside = true;   // Govde range icine kapanmali (reddetme teyidi)
input double   InpSLBufferPoints = 30;         // SL, suzme fitilinin disinda bu kadar buffer (puan)

input group "=== Hedef / Kosucu ==="
input bool     InpUseRunner      = true;       // true: EQ'da yari kapa + kalani karsi likiditeye tasi
input double   InpPartialPercent = 50.0;       // EQ'da kapatilacak yuzde (kosucu modu)
input bool     InpBE_AfterPartial= true;       // Kismi kardan sonra SL'i giris (BE) seviyesine cek
input double   InpBE_BufferPoints= 10;         // BE buffer (puan)

input group "=== Islem Sikligi ==="
input bool     InpOneTradePerDay = true;       // true: gunde tek setup. false: yon basina bir setup

input group "=== Gorsel ==="
input bool     InpDrawRange      = true;       // Range/EQ cizgilerini grafige ciz
input color    InpRangeColor     = clrSlateGray; // RH/RL renk
input color    InpEQColor        = clrGold;    // EQ renk

//==================================================================//
//                         GLOBAL OBJELER                           //
//==================================================================//
CTrade         trade;
CPositionInfo  posInfo;

int      hATR;
double   g_point;
int      g_digits;
datetime g_lastBarTime = 0;

// Gunluk durum
datetime g_dayKey        = 0;     // hangi gune ait (00:00)
double   g_dayStartBalance = 0;
bool     g_tradingHalted = false;
bool     g_rangeReady    = false;
bool     g_rangeValid    = false;
double   g_rh = 0, g_rl = 0, g_eq = 0;
bool     g_sweptHighDone = false; // bu yonde setup alindi mi
bool     g_sweptLowDone  = false;
bool     g_tradedToday   = false;

// Aktif pozisyon yonetimi (gunde tek pozisyon mantigi)
ulong    g_activeTicket  = 0;
int      g_activeDir     = 0;     // +1 al, -1 sat
double   g_eqTarget      = 0;
bool     g_partialDone   = false;

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
   if(hATR == INVALID_HANDLE)
   {
      Print("HATA: ATR handle olusturulamadi.");
      return(INIT_FAILED);
   }

   if(InpRangeStartHour >= InpRangeEndHour)
      Print("UYARI: Range baslangic saati bitisten kucuk olmali (gece yarisi gecisi desteklenmez).");

   ResetDailyState();

   PrintFormat("ProCloudLiquidityEA basladi | %s | Range %02d:00-%02d:00 | TradeEnd %02d:00 | ForceClose %02d:00 | Risk=%.2f%%",
               _Symbol, InpRangeStartHour, InpRangeEndHour, InpTradeEndHour, InpForceCloseHour, InpRiskPercent);

   if(StringFind(_Symbol, "XAU") < 0)
      Print("UYARI: Bu EA XAUUSD (Altin) icin ayarlanmistir. Farkli sembolde parametreleri yeniden optimize edin.");

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   IndicatorRelease(hATR);
   if(InpDrawRange)
      ObjectsDeleteAll(0, "PCLIQ_");
}

//==================================================================//
//                            OnTick                                //
//==================================================================//
void OnTick()
{
   // Yeni gun kontrolu + gunluk reset
   datetime today = DayKey(TimeCurrent());
   if(today != g_dayKey)
      ResetDailyState();

   // Gunluk zarar korumasi
   UpdateDailyRiskGuard();

   // Acik pozisyon yonetimi (her tick)
   ManageActivePosition();

   // Zaman stopu
   ForceCloseCheck();

   // Yeni bar mi?
   datetime curBar = (datetime)iTime(_Symbol, _Period, 0);
   if(curBar == g_lastBarTime)
      return;
   g_lastBarTime = curBar;

   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);

   // Range bitis saatinde range'i hesapla
   if(!g_rangeReady && t.hour >= InpRangeEndHour && t.hour < 24)
      ComputeRange(today);

   // Sinyal arama kosullari
   if(!g_rangeReady || !g_rangeValid) return;
   if(g_tradingHalted) return;
   if(t.hour >= InpTradeEndHour) return;          // trade penceresi kapandi
   if(t.hour < InpRangeEndHour) return;           // range henuz bitmedi
   if(g_activeTicket != 0) return;                // zaten acik pozisyon var
   if(InpOneTradePerDay && g_tradedToday) return; // gunde tek setup
   if(!SpreadFilterPass()) return;

   CheckSweepAndTrade();
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
      if(DayKey(bt) != today) break; // onceki gune gecince dur

      MqlDateTime mt;
      TimeToStruct(bt, mt);
      if(mt.hour >= InpRangeStartHour && mt.hour < InpRangeEndHour)
      {
         double hi = iHigh(_Symbol, _Period, i);
         double lo = iLow(_Symbol, _Period, i);
         if(hi > rh) rh = hi;
         if(lo < rl) rl = lo;
         found = true;
      }
   }

   g_rangeReady = true;

   if(!found)
   {
      g_rangeValid = false;
      Print("Range bulunamadi (yeterli bar yok veya pencere bos).");
      return;
   }

   g_rh = rh;
   g_rl = rl;
   g_eq = NormalizeDouble((rh + rl) / 2.0, g_digits);

   double rangePoints = (rh - rl) / g_point;
   g_rangeValid = (rangePoints >= InpMinRangePoints && rangePoints <= InpMaxRangePoints);

   PrintFormat("RANGE | RH=%.*f RL=%.*f EQ=%.*f | boyut=%.0f puan | gecerli=%s",
               g_digits, rh, g_digits, rl, g_digits, g_eq, rangePoints,
               (g_rangeValid ? "EVET" : "HAYIR (filtre disi)"));

   if(InpDrawRange)
      DrawRange(today);
}

//==================================================================//
//                   SUZME TESPITI + ISLEM                          //
//==================================================================//
void CheckSweepAndTrade()
{
   // Son kapanan bar
   double h1 = iHigh (_Symbol, _Period, 1);
   double l1 = iLow  (_Symbol, _Period, 1);
   double c1 = iClose(_Symbol, _Period, 1);

   double sweepBuf = InpSweepMinPoints * g_point;

   // --- UST likidite suzuldu -> SAT (hedef EQ, kosucu RL) ---
   bool highSwept = (h1 > g_rh + sweepBuf);
   bool closedInsideFromTop = (!InpRequireCloseInside) || (c1 < g_rh);
   if(highSwept && closedInsideFromTop && !g_sweptHighDone)
   {
      g_sweptHighDone = true;
      double sl = NormalizeDouble(h1 + InpSLBufferPoints * g_point, g_digits);
      OpenTrade(-1, sl);
      return;
   }

   // --- ALT likidite suzuldu -> AL (hedef EQ, kosucu RH) ---
   bool lowSwept = (l1 < g_rl - sweepBuf);
   bool closedInsideFromBottom = (!InpRequireCloseInside) || (c1 > g_rl);
   if(lowSwept && closedInsideFromBottom && !g_sweptLowDone)
   {
      g_sweptLowDone = true;
      double sl = NormalizeDouble(l1 - InpSLBufferPoints * g_point, g_digits);
      OpenTrade(+1, sl);
      return;
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

   if(dir > 0) // AL: alt suzuldu, hedef yukari (EQ -> RH)
   {
      type  = ORDER_TYPE_BUY;
      price = ask;
      tp    = InpUseRunner ? g_rh : g_eq;   // kosucu: karsi likidite RH
      if(price >= g_eq)  { Print("AL atlandi: fiyat zaten EQ ustunde."); return; }
   }
   else        // SAT: ust suzuldu, hedef asagi (EQ -> RL)
   {
      type  = ORDER_TYPE_SELL;
      price = bid;
      tp    = InpUseRunner ? g_rl : g_eq;
      if(price <= g_eq)  { Print("SAT atlandi: fiyat zaten EQ altinda."); return; }
   }

   tp = NormalizeDouble(tp, g_digits);

   double slDistPoints = MathAbs(price - sl) / g_point;
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stopLevel > 0 && slDistPoints < stopLevel)
   {
      PrintFormat("Islem atlandi: SL mesafesi (%.0f) broker min seviyesi (%d) altinda.", slDistPoints, stopLevel);
      return;
   }

   double lot = CalculateLot(slDistPoints);
   if(lot <= 0) { Print("Islem atlandi: gecersiz lot."); return; }

   if(trade.PositionOpen(_Symbol, type, lot, price, sl, tp, InpComment))
   {
      g_activeTicket = PositionLastTicket();
      g_activeDir    = dir;
      g_eqTarget     = g_eq;
      g_partialDone  = false;
      g_tradedToday  = true;
      PrintFormat("ISLEM ACILDI | %s | lot=%.2f | giris=%.*f | SL=%.*f | TP=%.*f | EQ hedef=%.*f | kosucu=%s",
                  (dir>0?"AL":"SAT"), lot, g_digits, price, g_digits, sl, g_digits, tp, g_digits, g_eq,
                  (InpUseRunner?"acik":"kapali"));
   }
   else
   {
      PrintFormat("Islem ACILAMADI | retcode=%d | %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

// En son actigimiz pozisyonun ticket'ini bul
ulong PositionLastTicket()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!posInfo.SelectByTicket(ticket)) continue;
      if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic)
         return ticket;
   }
   return 0;
}

//==================================================================//
//                   AKTIF POZISYON YONETIMI                        //
//==================================================================//
void ManageActivePosition()
{
   if(g_activeTicket == 0) return;

   // Pozisyon hala acik mi?
   if(!posInfo.SelectByTicket(g_activeTicket))
   {
      // kapanmis (TP/SL/manuel)
      g_activeTicket = 0;
      g_partialDone  = false;
      return;
   }

   if(!InpUseRunner) return; // basit mod: TP zaten EQ'da, ek yonetim yok

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double openPrice = posInfo.PriceOpen();
   double volume    = posInfo.Volume();

   // EQ'ya ulasinca kismi kapat + BE
   if(!g_partialDone)
   {
      bool reachedEQ = (g_activeDir > 0) ? (bid >= g_eqTarget) : (ask <= g_eqTarget);
      if(reachedEQ)
      {
         double closeVol = NormalizeLot(volume * InpPartialPercent / 100.0);
         if(closeVol > 0 && closeVol < volume)
         {
            if(trade.PositionClosePartial(g_activeTicket, closeVol))
               PrintFormat("KISMI KAPAMA | %.2f lot EQ'da kapatildi (%.*f).", closeVol, g_digits, g_eqTarget);
         }
         g_partialDone = true;

         // BE'ye cek
         if(InpBE_AfterPartial && posInfo.SelectByTicket(g_activeTicket))
         {
            double curTP = posInfo.TakeProfit();
            double be;
            if(g_activeDir > 0)
               be = NormalizeDouble(openPrice + InpBE_BufferPoints * g_point, g_digits);
            else
               be = NormalizeDouble(openPrice - InpBE_BufferPoints * g_point, g_digits);
            trade.PositionModify(g_activeTicket, be, curTP);
            PrintFormat("BE | SL giris seviyesine cekildi (%.*f).", g_digits, be);
         }
      }
   }
}

//==================================================================//
//                         ZAMAN STOPU                              //
//==================================================================//
void ForceCloseCheck()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(t.hour < InpForceCloseHour) return;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!posInfo.SelectByTicket(ticket)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagic) continue;

      if(trade.PositionClose(ticket))
         PrintFormat("ZAMAN STOPU | Pozisyon kapatildi (saat >= %02d:00).", InpForceCloseHour);
   }
   if(ticket_was_closed())
      g_activeTicket = 0;
}

bool ticket_was_closed()
{
   return (g_activeTicket != 0 && !posInfo.SelectByTicket(g_activeTicket));
}

//==================================================================//
//                      LOT HESABI (% RISK)                         //
//==================================================================//
double CalculateLot(double slDistPoints)
{
   if(InpFixedLot > 0.0)
      return NormalizeLot(InpFixedLot);

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0) return 0;

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
   if(lot < minLot) lot = 0; // kismi kapamada minLot altina inerse 0 don (kapatma)
   if(lot > maxLot) lot = maxLot;

   int lotDigits = (int)MathRound(MathLog10(1.0/lotStep));
   if(lotDigits < 0) lotDigits = 2;
   return NormalizeDouble(lot, lotDigits);
}

//==================================================================//
//                       GUNLUK RISK KORUMASI                       //
//==================================================================//
void UpdateDailyRiskGuard()
{
   if(g_tradingHalted) return;

   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyPL = equity - g_dayStartBalance;
   double maxLoss = -(g_dayStartBalance * InpMaxDailyLossPct / 100.0);

   if(dailyPL <= maxLoss)
   {
      g_tradingHalted = true;
      PrintFormat("GUNLUK ZARAR LIMITI DOLDU (%.2f / limit %.2f). Bugun yeni setup yok.", dailyPL, maxLoss);
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
   g_sweptHighDone   = false;
   g_sweptLowDone    = false;
   g_tradedToday     = false;
   // aktif pozisyonu sifirlamiyoruz - onceki gunden tasinan olabilir, yonetim devam etsin
}

//==================================================================//
//                           FILTRELER                              //
//==================================================================//
bool SpreadFilterPass()
{
   double spreadPoints = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spreadPoints <= InpMaxSpreadPoints);
}

//==================================================================//
//                          YARDIMCILAR                             //
//==================================================================//
datetime DayKey(datetime t)
{
   MqlDateTime mt;
   TimeToStruct(t, mt);
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

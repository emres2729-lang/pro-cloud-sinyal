//+------------------------------------------------------------------+
//|                                        ProCloudAdaptiveEA.mq5     |
//|         Pro Cloud Sinyal - Rejim-Adaptif Portfoy Yoneticisi      |
//|                                                                  |
//|  Iki stratejiyi tek catida birlestirir ve piyasa REJIMINE gore   |
//|  hangisinin islem acabilecegini otomatik secer:                  |
//|                                                                  |
//|    TREND rejimi (H1 ADX yuksek)  -> Trend-Pullback stratejisi    |
//|    RANGE rejimi (H1 ADX dusuk)   -> Likidite-Suzme stratejisi    |
//|    NEUTRAL                        -> (AUTO modda) yeni islem yok  |
//|                                                                  |
//|  Ortak risk yonetimi (prop-firm): gunluk + toplam drawdown,      |
//|  % risk lot, spread ve ekonomik takvim haber filtresi.           |
//|  Ayni anda TEK pozisyon kurali (cift maruziyet onleme).          |
//|                                                                  |
//|  Onerilen grafik zaman dilimi: M15.                              |
//|  UYARI: Kar garantisi YOKTUR. Once DEMO + Strateji Test Cihazi.  |
//+------------------------------------------------------------------+
#property copyright "Pro Cloud Sinyal"
#property link      "https://github.com/emres2729-lang/pro-cloud-sinyal"
#property version   "1.00"
#property description "Rejim-adaptif: trend gunu->pullback, range gunu->likidite suzme. Ortak prop-firm risk yonetimi. XAUUSD."

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

//==================================================================//
//                            ENUMS                                 //
//==================================================================//
enum ENUM_REGIME { REGIME_NEUTRAL=0, REGIME_TREND=1, REGIME_RANGE=-1 };
enum ENUM_REGIME_MODE
{
   RM_AUTO        = 0, // Rejime gore otomatik sec (ONERILEN)
   RM_FORCE_TREND = 1, // Sadece trend stratejisi
   RM_FORCE_RANGE = 2, // Sadece likidite stratejisi
   RM_BOTH        = 3  // Ikisi de acabilir (yine tek pozisyon kurali)
};
enum ENUM_ENTRY_MODE { ENTRY_IMMEDIATE=0, ENTRY_MSS=1 };

//==================================================================//
//                            INPUTS                                //
//==================================================================//
input group "=== Genel ==="
input long   InpMagicTrend   = 20260540;   // Trend stratejisi magic
input long   InpMagicLiq     = 20260541;   // Likidite stratejisi magic
input ENUM_REGIME_MODE InpRegimeMode = RM_AUTO; // Rejim secim modu

input group "=== Rejim Tespiti ==="
input ENUM_TIMEFRAMES InpRegimeTF = PERIOD_H1; // Rejim olcum zaman dilimi
input int    InpRegimeADXPeriod = 14;      // Rejim ADX periyodu
input double InpTrendADXMin   = 25.0;      // H1 ADX >= bu -> TREND rejimi
input double InpRangeADXMax   = 20.0;      // H1 ADX <= bu -> RANGE rejimi

input group "=== Ortak Risk (Prop-Firm) ==="
input double InpRiskPercent   = 1.0;       // Islem basina risk (% bakiye)
input double InpMaxDailyLossPct = 4.0;     // Gunluk maks zarar (%)
input double InpMaxTotalDDPct = 10.0;      // Toplam maks drawdown (%) -> EA kalici durur
input bool   InpUseTrailingDD = false;     // Max DD equity-zirvesinden olculsun
input double InpMaxSpreadPoints = 60;      // Maks spread (puan)
input double InpFixedLot       = 0.0;      // >0 ise sabit lot

input group "=== Ortak Haber Filtresi ==="
input bool   InpUseNewsFilter = true;      // Yuksek etkili haberde dur (tester'da baypas)
input string InpNewsCurrency  = "USD";     // Haber para birimi
input int    InpNewsBeforeMin = 30;        // Haberden once (dk)
input int    InpNewsAfterMin  = 30;        // Haberden sonra (dk)
input bool   InpNewsHighOnly  = true;      // true: yuksek; false: orta+yuksek

input group "=== TREND Stratejisi ==="
input ENUM_TIMEFRAMES InpT_TrendTF = PERIOD_H1; // Trend yon TF
input int    InpT_TrendEMA   = 200;
input int    InpT_TrendFast  = 50;
input int    InpT_FastEMA    = 21;
input int    InpT_SlowEMA    = 50;
input int    InpT_ADXPeriod  = 14;
input double InpT_ADXMin     = 22.0;
input int    InpT_RSIPeriod  = 14;
input int    InpT_ATRPeriod  = 14;
input double InpT_SL_ATR     = 1.8;
input double InpT_TP_R       = 2.0;
input double InpT_ATR_MinPts = 80;
input double InpT_ATR_MaxPts = 1200;
input bool   InpT_UseBE      = true;
input double InpT_BE_R       = 1.0;
input double InpT_BE_Buf     = 10;
input bool   InpT_UseTrail   = true;
input double InpT_Trail_ATR  = 2.0;
input int    InpT_StartHour  = 8;
input int    InpT_EndHour    = 21;

input group "=== LIKIDITE Stratejisi ==="
input int    InpL_RangeStart = 2;
input int    InpL_RangeEnd   = 6;
input int    InpL_TradeEnd   = 12;
input int    InpL_ForceClose = 16;
input double InpL_MinRangePts = 150;
input double InpL_MaxRangePts = 2000;
input ENUM_ENTRY_MODE InpL_EntryMode = ENTRY_MSS;
input double InpL_SweepMinPts = 20;
input int    InpL_MSS_Lookback = 3;
input int    InpL_ConfirmBars = 12;
input double InpL_SLBufferPts = 30;
input bool   InpL_UseFVG     = true;
input double InpL_FVGFillRatio = 0.5;
input double InpL_FVGMinPts  = 10;
input int    InpL_FVGExpiry  = 8;
input bool   InpL_UseOB      = true;
input bool   InpL_UseMagnet  = false;
input ENUM_TIMEFRAMES InpL_MagnetTF = PERIOD_H1;
input int    InpL_MagnetLook = 60;
input bool   InpL_UseRunner  = true;
input double InpL_PartialPct = 50.0;
input bool   InpL_BE_After   = true;
input double InpL_BE_Buf     = 10;
input bool   InpL_DrawRange  = true;

//==================================================================//
//                         RISK MANAGER                             //
//==================================================================//
class CRiskManager
{
private:
   CTrade        m_trade;
   CPositionInfo m_pos;
   double   m_initialBalance, m_peakEquity, m_dayStartBalance;
   datetime m_dayKey;
   bool     m_eaHalted, m_dayHalted;
   long     m_magicA, m_magicB;
   double   m_point;

public:
   void Init(long magicA, long magicB)
   {
      m_magicA = magicA; m_magicB = magicB;
      m_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      m_initialBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
      m_peakEquity      = AccountInfoDouble(ACCOUNT_EQUITY);
      m_eaHalted = false;
      NewDay(true);
   }

   bool Halted()       const { return m_eaHalted; }
   bool TradingAllowed() const { return (!m_eaHalted && !m_dayHalted); }

   void OnTick()
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity > m_peakEquity) m_peakEquity = equity;

      // Gun degisimi
      datetime dk = DayKey(TimeCurrent());
      if(dk != m_dayKey) NewDay(false);

      if(m_eaHalted) return;

      // Toplam DD
      double baseline = InpUseTrailingDD ? m_peakEquity : m_initialBalance;
      double ddLimit  = baseline * (1.0 - InpMaxTotalDDPct/100.0);
      if(equity <= ddLimit)
      {
         m_eaHalted = true;
         CloseAll();
         PrintFormat("!!! TOPLAM DD (%.1f%%) DOLDU. EA KALICI DURDU. Eq=%.2f Lim=%.2f",
                     InpMaxTotalDDPct, equity, ddLimit);
         Alert("ProCloudAdaptiveEA: Toplam drawdown limiti doldu, EA durdu.");
         return;
      }

      // Gunluk DD
      if(!m_dayHalted)
      {
         double dailyPL = equity - m_dayStartBalance;
         double maxLoss = -(m_dayStartBalance * InpMaxDailyLossPct/100.0);
         if(dailyPL <= maxLoss)
         {
            m_dayHalted = true;
            PrintFormat("GUNLUK ZARAR LIMITI DOLDU (%.2f/%.2f). Bugun yeni islem yok.", dailyPL, maxLoss);
         }
      }
   }

   void NewDay(bool init)
   {
      m_dayKey = DayKey(TimeCurrent());
      m_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      m_dayHalted = false;
   }

   double CalcLot(double slPoints)
   {
      if(InpFixedLot > 0.0) return NormalizeLot(InpFixedLot);
      double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent/100.0;
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickValue<=0 || tickSize<=0) return 0;
      double lossPerLot = (slPoints * m_point / tickSize) * tickValue;
      if(lossPerLot<=0) return 0;
      return NormalizeLot(riskMoney / lossPerLot);
   }

   double NormalizeLot(double lot)
   {
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      if(step<=0) step=0.01;
      lot = MathFloor(lot/step)*step;
      if(lot<minLot) lot=0;
      if(lot>maxLot) lot=maxLot;
      int d=(int)MathRound(MathLog10(1.0/step)); if(d<0) d=2;
      return NormalizeDouble(lot, d);
   }

   bool SpreadOK()
   { return ((double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpreadPoints); }

   bool NewsOK()
   {
      if(!InpUseNewsFilter) return true;
      if(MQLInfoInteger(MQL_TESTER)) return true;
      datetime now=TimeCurrent();
      MqlCalendarValue values[];
      int n=CalendarValueHistory(values, now-InpNewsAfterMin*60, now+InpNewsBeforeMin*60, NULL, InpNewsCurrency);
      if(n<=0) return true;
      ENUM_CALENDAR_EVENT_IMPORTANCE need = InpNewsHighOnly ? CALENDAR_IMPORTANCE_HIGH : CALENDAR_IMPORTANCE_MODERATE;
      for(int i=0;i<n;i++)
      {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev)) continue;
         if(ev.importance >= need) return false;
      }
      return true;
   }

   void CloseAll()
   {
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         ulong t=PositionGetTicket(i);
         if(t==0) continue;
         if(!m_pos.SelectByTicket(t)) continue;
         if(m_pos.Symbol()!=_Symbol) continue;
         if(m_pos.Magic()==m_magicA || m_pos.Magic()==m_magicB)
            m_trade.PositionClose(t);
      }
   }

   static datetime DayKey(datetime t)
   { MqlDateTime mt; TimeToStruct(t,mt); return StringToTime(StringFormat("%04d.%02d.%02d",mt.year,mt.mon,mt.day)); }
};

//==================================================================//
//                       REGIME DETECTOR                            //
//==================================================================//
class CRegime
{
private:
   int m_hADX;
public:
   bool Init()
   {
      m_hADX = iADX(_Symbol, InpRegimeTF, InpRegimeADXPeriod);
      return (m_hADX != INVALID_HANDLE);
   }
   void Deinit() { IndicatorRelease(m_hADX); }

   ENUM_REGIME Detect()
   {
      double adx[];
      ArraySetAsSeries(adx, true);
      if(CopyBuffer(m_hADX, 0, 0, 2, adx) < 2) return REGIME_NEUTRAL;
      double v = adx[1];
      if(v >= InpTrendADXMin) return REGIME_TREND;
      if(v <= InpRangeADXMax) return REGIME_RANGE;
      return REGIME_NEUTRAL;
   }
};

//==================================================================//
//                        TREND STRATEGY                            //
//==================================================================//
class CTrendStrategy
{
private:
   CTrade        m_trade;
   CPositionInfo m_pos;
   CRiskManager *m_risk;
   long   m_magic;
   double m_point; int m_digits;
   int    hTEMA,hTFast,hFast,hSlow,hADX,hRSI,hATR;

public:
   bool Init(CRiskManager *risk)
   {
      m_risk=risk; m_magic=InpMagicTrend;
      m_point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
      m_digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
      m_trade.SetExpertMagicNumber(m_magic);
      m_trade.SetDeviationInPoints(20);
      m_trade.SetTypeFillingBySymbol(_Symbol);
      hTEMA =iMA(_Symbol,InpT_TrendTF,InpT_TrendEMA,0,MODE_EMA,PRICE_CLOSE);
      hTFast=iMA(_Symbol,InpT_TrendTF,InpT_TrendFast,0,MODE_EMA,PRICE_CLOSE);
      hFast =iMA(_Symbol,_Period,InpT_FastEMA,0,MODE_EMA,PRICE_CLOSE);
      hSlow =iMA(_Symbol,_Period,InpT_SlowEMA,0,MODE_EMA,PRICE_CLOSE);
      hADX  =iADX(_Symbol,_Period,InpT_ADXPeriod);
      hRSI  =iRSI(_Symbol,_Period,InpT_RSIPeriod,PRICE_CLOSE);
      hATR  =iATR(_Symbol,_Period,InpT_ATRPeriod);
      return (hTEMA!=INVALID_HANDLE&&hTFast!=INVALID_HANDLE&&hFast!=INVALID_HANDLE&&
              hSlow!=INVALID_HANDLE&&hADX!=INVALID_HANDLE&&hRSI!=INVALID_HANDLE&&hATR!=INVALID_HANDLE);
   }
   void Deinit()
   { IndicatorRelease(hTEMA);IndicatorRelease(hTFast);IndicatorRelease(hFast);
     IndicatorRelease(hSlow);IndicatorRelease(hADX);IndicatorRelease(hRSI);IndicatorRelease(hATR); }

   // Her tick: acik pozisyon yonetimi
   void ManageTick()
   {
      if(!InpT_UseBE && !InpT_UseTrail) return;
      double atrPts=ATRpts(); if(atrPts<=0) return;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong t=PositionGetTicket(i); if(t==0) continue;
         if(!m_pos.SelectByTicket(t)) continue;
         if(m_pos.Symbol()!=_Symbol||m_pos.Magic()!=m_magic) continue;
         double open=m_pos.PriceOpen(), sl=m_pos.StopLoss(), tp=m_pos.TakeProfit();
         double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID), ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         double newSL=sl;
         if(m_pos.PositionType()==POSITION_TYPE_BUY)
         {
            double profPts=(bid-open)/m_point;
            if(InpT_UseBE){ double risk0=MathAbs(open-sl)/m_point;
               if(risk0>0&&profPts>=risk0*InpT_BE_R){ double be=NormalizeDouble(open+InpT_BE_Buf*m_point,m_digits); if(be>newSL) newSL=be; } }
            if(InpT_UseTrail){ double tr=NormalizeDouble(bid-atrPts*InpT_Trail_ATR*m_point,m_digits); if(tr>newSL&&tr>open) newSL=tr; }
            if(newSL>sl+m_point) m_trade.PositionModify(t,newSL,tp);
         }
         else
         {
            double profPts=(open-ask)/m_point;
            if(InpT_UseBE){ double risk0=MathAbs(sl-open)/m_point;
               if(risk0>0&&profPts>=risk0*InpT_BE_R){ double be=NormalizeDouble(open-InpT_BE_Buf*m_point,m_digits); if(newSL==0||be<newSL) newSL=be; } }
            if(InpT_UseTrail){ double tr=NormalizeDouble(ask+atrPts*InpT_Trail_ATR*m_point,m_digits); if((newSL==0||tr<newSL)&&tr<open) newSL=tr; }
            if(newSL>0&&(sl==0||newSL<sl-m_point)) m_trade.PositionModify(t,newSL,tp);
         }
      }
   }

   // Yeni bar: sinyal + (izin varsa) acilis
   void OnBar(bool canOpen)
   {
      if(!canOpen) return;
      if(!SessionOK()) return;
      if(!m_risk.SpreadOK()) return;
      double atrPts=ATRpts(); if(atrPts<=0) return;
      if(atrPts<InpT_ATR_MinPts||atrPts>InpT_ATR_MaxPts) return;
      int sig=Signal(); if(sig==0) return;
      OpenTrade(sig,atrPts);
   }

private:
   double ATRpts(){ double a[]; if(CopyBuffer(hATR,0,1,1,a)<1) return 0; return a[0]/m_point; }

   bool SessionOK()
   { MqlDateTime t; TimeToStruct(TimeCurrent(),t); return (t.hour>=InpT_StartHour && t.hour<InpT_EndHour); }

   int Signal()
   {
      double htfE[],htfF[]; ArraySetAsSeries(htfE,true); ArraySetAsSeries(htfF,true);
      if(CopyBuffer(hTEMA,0,0,2,htfE)<2) return 0;
      if(CopyBuffer(hTFast,0,0,2,htfF)<2) return 0;
      double htfC=iClose(_Symbol,InpT_TrendTF,1);
      bool bull=(htfC>htfE[1]&&htfF[1]>htfE[1]);
      bool bear=(htfC<htfE[1]&&htfF[1]<htfE[1]);
      if(!bull&&!bear) return 0;

      double fast[],slow[],adx[],rsi[];
      ArraySetAsSeries(fast,true);ArraySetAsSeries(slow,true);ArraySetAsSeries(adx,true);ArraySetAsSeries(rsi,true);
      if(CopyBuffer(hFast,0,0,3,fast)<3) return 0;
      if(CopyBuffer(hSlow,0,0,3,slow)<3) return 0;
      if(CopyBuffer(hADX,0,0,2,adx)<2) return 0;
      if(CopyBuffer(hRSI,0,0,2,rsi)<2) return 0;
      if(adx[1]<InpT_ADXMin) return 0;

      double c1=iClose(_Symbol,_Period,1),o1=iOpen(_Symbol,_Period,1);
      double h1=iHigh(_Symbol,_Period,1),l1=iLow(_Symbol,_Period,1);

      if(bull && fast[1]>slow[1] && l1<=fast[1] && c1>fast[1] && c1>o1 && rsi[1]>=50.0) return +1;
      if(bear && fast[1]<slow[1] && h1>=fast[1] && c1<fast[1] && c1<o1 && rsi[1]<=50.0) return -1;
      return 0;
   }

   void OpenTrade(int sig,double atrPts)
   {
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double slPts=atrPts*InpT_SL_ATR, tpPts=slPts*InpT_TP_R;
      double price,sl,tp; ENUM_ORDER_TYPE type;
      if(sig>0){ type=ORDER_TYPE_BUY; price=ask; sl=NormalizeDouble(price-slPts*m_point,m_digits); tp=NormalizeDouble(price+tpPts*m_point,m_digits); }
      else     { type=ORDER_TYPE_SELL;price=bid; sl=NormalizeDouble(price+slPts*m_point,m_digits); tp=NormalizeDouble(price-tpPts*m_point,m_digits); }
      long stopLvl=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
      if(stopLvl>0 && slPts<stopLvl) return;
      double lot=m_risk.CalcLot(slPts); if(lot<=0) return;
      if(m_trade.PositionOpen(_Symbol,type,lot,price,sl,tp,"PCAdaptive-Trend"))
         PrintFormat("[TREND] %s acildi lot=%.2f SL=%.*f TP=%.*f",(sig>0?"AL":"SAT"),lot,m_digits,sl,m_digits,tp);
   }
};

//==================================================================//
//                     LIQUIDITY STRATEGY                           //
//==================================================================//
class CLiquidityStrategy
{
private:
   CTrade        m_trade;
   CPositionInfo m_pos;
   CRiskManager *m_risk;
   long   m_magic;
   double m_point; int m_digits;
   datetime m_lastBar;
   // gun durumu
   datetime m_dayKey;
   bool   m_rangeReady,m_rangeValid,m_tradedToday;
   double m_rh,m_rl,m_eq;
   int    m_sweepState; double m_sweepExtreme; int m_armBars;
   bool   m_sweptHigh,m_sweptLow;
   // pozisyon/pending
   ulong  m_activeTicket; int m_activeDir; double m_eqTarget; bool m_partialDone;
   ulong  m_pendingTicket; int m_pendingDir; int m_pendingBars;

public:
   bool Init(CRiskManager *risk)
   {
      m_risk=risk; m_magic=InpMagicLiq;
      m_point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
      m_digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
      m_trade.SetExpertMagicNumber(m_magic);
      m_trade.SetDeviationInPoints(20);
      m_trade.SetTypeFillingBySymbol(_Symbol);
      ResetDay();
      m_activeTicket=0; m_pendingTicket=0; m_lastBar=0;
      return true;
   }
   void Deinit() { if(InpL_DrawRange) ObjectsDeleteAll(0,"PCAD_"); }

   // Her tick: pending + pozisyon + zaman stopu
   void ManageTick()
   {
      datetime dk=CRiskManager::DayKey(TimeCurrent());
      if(dk!=m_dayKey) ResetDay();
      ManagePosition();
      ManagePending();
      ForceClose();
   }

   // Yeni bar: range + sweep state machine
   void OnBar(bool canOpen)
   {
      MqlDateTime t; TimeToStruct(TimeCurrent(),t);
      if(!m_rangeReady && t.hour>=InpL_RangeEnd) ComputeRange();

      if(m_pendingTicket!=0)
      {
         m_pendingBars++;
         if(m_pendingBars>InpL_FVGExpiry){ m_trade.OrderDelete(m_pendingTicket); ClearPending(); }
      }

      if(!canOpen) return;
      if(!m_rangeReady||!m_rangeValid) return;
      if(t.hour<InpL_RangeEnd||t.hour>=InpL_TradeEnd) return;
      if(m_activeTicket!=0||m_pendingTicket!=0) return;
      if(m_tradedToday) return;
      if(!m_risk.SpreadOK()) return;
      ProcessSweep();
   }

   bool HasExposure() { return (m_activeTicket!=0 || m_pendingTicket!=0); }

private:
   void ResetDay()
   {
      m_dayKey=CRiskManager::DayKey(TimeCurrent());
      m_rangeReady=false; m_rangeValid=false; m_tradedToday=false;
      m_rh=0;m_rl=0;m_eq=0; m_sweepState=0; m_sweptHigh=false; m_sweptLow=false; m_armBars=0;
   }

   void ComputeRange()
   {
      datetime today=m_dayKey; double rh=-DBL_MAX,rl=DBL_MAX; bool found=false;
      for(int i=1;i<5000;i++)
      {
         datetime bt=iTime(_Symbol,_Period,i); if(bt==0) break;
         if(CRiskManager::DayKey(bt)!=today) break;
         MqlDateTime mt; TimeToStruct(bt,mt);
         if(mt.hour>=InpL_RangeStart&&mt.hour<InpL_RangeEnd)
         { double hi=iHigh(_Symbol,_Period,i),lo=iLow(_Symbol,_Period,i);
           if(hi>rh)rh=hi; if(lo<rl)rl=lo; found=true; }
      }
      m_rangeReady=true;
      if(!found){ m_rangeValid=false; return; }
      m_rh=rh; m_rl=rl; m_eq=NormalizeDouble((rh+rl)/2.0,m_digits);
      double rp=(rh-rl)/m_point;
      m_rangeValid=(rp>=InpL_MinRangePts && rp<=InpL_MaxRangePts);
      PrintFormat("[LIQ] RANGE RH=%.*f RL=%.*f EQ=%.*f (%.0f puan) gecerli=%s",
                  m_digits,rh,m_digits,rl,m_digits,m_eq,rp,(m_rangeValid?"E":"H"));
      if(InpL_DrawRange&&m_rangeValid) DrawRange(today);
   }

   void ProcessSweep()
   {
      double h1=iHigh(_Symbol,_Period,1),l1=iLow(_Symbol,_Period,1);
      double c1=iClose(_Symbol,_Period,1),o1=iOpen(_Symbol,_Period,1);
      double buf=InpL_SweepMinPts*m_point;

      if(m_sweepState==0)
      {
         bool hs=(h1>m_rh+buf)&&!m_sweptHigh;
         bool ls=(l1<m_rl-buf)&&!m_sweptLow;
         if(hs)
         {
            if(InpL_EntryMode==ENTRY_IMMEDIATE){ if(c1<m_rh){ m_sweptHigh=true; EnterAfterMSS(-1,NormalizeDouble(h1+InpL_SLBufferPts*m_point,m_digits)); } }
            else { m_sweepState=-1; m_sweepExtreme=h1; m_armBars=0; PrintFormat("[LIQ] ust suzme, MSS bekleniyor"); }
            return;
         }
         if(ls)
         {
            if(InpL_EntryMode==ENTRY_IMMEDIATE){ if(c1>m_rl){ m_sweptLow=true; EnterAfterMSS(+1,NormalizeDouble(l1-InpL_SLBufferPts*m_point,m_digits)); } }
            else { m_sweepState=1; m_sweepExtreme=l1; m_armBars=0; PrintFormat("[LIQ] alt suzme, MSS bekleniyor"); }
            return;
         }
         return;
      }

      m_armBars++;
      if(m_armBars>InpL_ConfirmBars){ if(m_sweepState>0)m_sweptLow=true; else m_sweptHigh=true; m_sweepState=0; return; }

      if(m_sweepState>0)
      {
         if(l1<m_sweepExtreme){ m_sweepExtreme=l1; m_armBars=0; }
         double mh=HH(2,InpL_MSS_Lookback);
         if(c1>mh && c1>o1){ m_sweptLow=true; m_sweepState=0; EnterAfterMSS(+1,NormalizeDouble(m_sweepExtreme-InpL_SLBufferPts*m_point,m_digits)); }
      }
      else
      {
         if(h1>m_sweepExtreme){ m_sweepExtreme=h1; m_armBars=0; }
         double ml=LL(2,InpL_MSS_Lookback);
         if(c1<ml && c1<o1){ m_sweptHigh=true; m_sweepState=0; EnterAfterMSS(-1,NormalizeDouble(m_sweepExtreme+InpL_SLBufferPts*m_point,m_digits)); }
      }
   }

   void EnterAfterMSS(int dir,double sl)
   {
      double zt,zb;
      if(ZoneFVG_OB(dir,zt,zb))
      {
         double entry=(dir>0)?NormalizeDouble(zt-(zt-zb)*InpL_FVGFillRatio,m_digits)
                             :NormalizeDouble(zb+(zt-zb)*InpL_FVGFillRatio,m_digits);
         if(PlaceLimit(dir,entry,sl)) return;
      }
      OpenMarket(dir,sl);
   }

   bool ZoneFVG_OB(int dir,double &zt,double &zb)
   {
      bool hasF=false,hasO=false; double fT=0,fB=0,oT=0,oB=0;
      double h1=iHigh(_Symbol,_Period,1),l1=iLow(_Symbol,_Period,1);
      double h3=iHigh(_Symbol,_Period,3),l3=iLow(_Symbol,_Period,3);
      double mg=InpL_FVGMinPts*m_point;
      if(InpL_UseFVG){
         if(dir>0&&l1>h3+mg){hasF=true;fT=l1;fB=h3;}
         if(dir<0&&h1<l3-mg){hasF=true;fT=l3;fB=h1;}
      }
      if(InpL_UseOB) hasO=FindOB(dir,oT,oB);
      if(hasF&&hasO){ double top=MathMin(fT,oT),bot=MathMax(fB,oB);
         if(top>bot){zt=top;zb=bot;return true;} zt=fT;zb=fB;return true; }
      if(hasF){zt=fT;zb=fB;return true;}
      if(hasO){zt=oT;zb=oB;return true;}
      return false;
   }

   bool FindOB(int dir,double &top,double &bot)
   {
      int maxLook=InpL_MSS_Lookback+InpL_ConfirmBars+3;
      for(int i=2;i<=maxLook;i++){
         double o=iOpen(_Symbol,_Period,i),c=iClose(_Symbol,_Period,i);
         if(dir>0&&c<o){top=iHigh(_Symbol,_Period,i);bot=iLow(_Symbol,_Period,i);return true;}
         if(dir<0&&c>o){top=iHigh(_Symbol,_Period,i);bot=iLow(_Symbol,_Period,i);return true;}
      }
      return false;
   }

   double RunnerTP(int dir,double entry)
   {
      double def=(dir>0)?(InpL_UseRunner?m_rh:m_eq):(InpL_UseRunner?m_rl:m_eq);
      if(!(InpL_UseRunner&&InpL_UseMagnet)) return def;
      double m=Magnet(dir,entry);
      if(m>0){ if(dir>0&&m>m_eq) return m; if(dir<0&&m<m_eq) return m; }
      return def;
   }

   double Magnet(int dir,double from)
   {
      double best=0,bd=DBL_MAX;
      for(int i=1;i<=InpL_MagnetLook;i++){
         double hiOld=iHigh(_Symbol,InpL_MagnetTF,i+1),loNew=iLow(_Symbol,InpL_MagnetTF,i-1);
         double loOld=iLow(_Symbol,InpL_MagnetTF,i+1),hiNew=iHigh(_Symbol,InpL_MagnetTF,i-1);
         if(dir>0&&loNew>hiOld){ double tg=hiOld; if(tg>from){double d=tg-from; if(d<bd){bd=d;best=tg;}} }
         if(dir<0&&hiNew<loOld){ double tg=loOld; if(tg<from){double d=from-tg; if(d<bd){bd=d;best=tg;}} }
      }
      return best;
   }

   bool PlaceLimit(int dir,double entry,double sl)
   {
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      long stopLvl=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL); double minD=stopLvl*m_point;
      double tp=NormalizeDouble(RunnerTP(dir,entry),m_digits);
      double slPts=MathAbs(entry-sl)/m_point;
      if(stopLvl>0&&slPts<stopLvl) return false;
      double lot=m_risk.CalcLot(slPts); if(lot<=0) return false;
      bool ok=false;
      if(dir>0){ if(entry>=ask-minD) return false; ok=m_trade.BuyLimit(lot,entry,_Symbol,sl,tp,ORDER_TIME_GTC,0,"PCAdaptive-Liq"); }
      else     { if(entry<=bid+minD) return false; ok=m_trade.SellLimit(lot,entry,_Symbol,sl,tp,ORDER_TIME_GTC,0,"PCAdaptive-Liq"); }
      if(ok){ m_pendingTicket=m_trade.ResultOrder(); m_pendingDir=dir; m_pendingBars=0;
              PrintFormat("[LIQ] FVG/OB limit %s @%.*f",(dir>0?"BUY":"SELL"),m_digits,entry); return true; }
      return false;
   }

   void OpenMarket(int dir,double sl)
   {
      double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
      double price,tp; ENUM_ORDER_TYPE type;
      if(dir>0){ type=ORDER_TYPE_BUY; price=ask; tp=RunnerTP(+1,price); if(price>=m_eq) return; }
      else     { type=ORDER_TYPE_SELL;price=bid; tp=RunnerTP(-1,price); if(price<=m_eq) return; }
      tp=NormalizeDouble(tp,m_digits);
      double slPts=MathAbs(price-sl)/m_point;
      long stopLvl=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
      if(stopLvl>0&&slPts<stopLvl) return;
      double lot=m_risk.CalcLot(slPts); if(lot<=0) return;
      if(m_trade.PositionOpen(_Symbol,type,lot,price,sl,tp,"PCAdaptive-Liq"))
      { m_activeTicket=LastTicket(); m_activeDir=dir; m_eqTarget=m_eq; m_partialDone=false; m_tradedToday=true;
        PrintFormat("[LIQ] %s market acildi lot=%.2f",(dir>0?"AL":"SAT"),lot); }
   }

   void ManagePosition()
   {
      if(m_activeTicket==0) return;
      if(!m_pos.SelectByTicket(m_activeTicket)){ m_activeTicket=0; m_partialDone=false; return; }
      if(!InpL_UseRunner) return;
      double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
      double open=m_pos.PriceOpen(),vol=m_pos.Volume();
      if(!m_partialDone)
      {
         bool reached=(m_activeDir>0)?(bid>=m_eqTarget):(ask<=m_eqTarget);
         if(reached)
         {
            double cv=m_risk.NormalizeLot(vol*InpL_PartialPct/100.0);
            if(cv>0&&cv<vol) m_trade.PositionClosePartial(m_activeTicket,cv);
            m_partialDone=true;
            if(InpL_BE_After&&m_pos.SelectByTicket(m_activeTicket))
            { double tp=m_pos.TakeProfit();
              double be=(m_activeDir>0)?NormalizeDouble(open+InpL_BE_Buf*m_point,m_digits):NormalizeDouble(open-InpL_BE_Buf*m_point,m_digits);
              m_trade.PositionModify(m_activeTicket,be,tp); }
         }
      }
   }

   void ManagePending()
   {
      if(m_pendingTicket==0) return;
      if(OrderSelect(m_pendingTicket))
      {
         double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID),ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         bool eqR=(m_pendingDir>0)?(bid>=m_eq):(ask<=m_eq);
         if(eqR){ m_trade.OrderDelete(m_pendingTicket); ClearPending(); }
         return;
      }
      ulong p=LastTicket();
      if(p!=0&&m_activeTicket==0){ m_activeTicket=p; m_activeDir=m_pendingDir; m_eqTarget=m_eq; m_partialDone=false; m_tradedToday=true; PrintFormat("[LIQ] limit doldu->pozisyon"); }
      ClearPending();
   }

   void ForceClose()
   {
      MqlDateTime t; TimeToStruct(TimeCurrent(),t);
      if(t.hour<InpL_ForceClose) return;
      if(m_pendingTicket!=0){ m_trade.OrderDelete(m_pendingTicket); ClearPending(); }
      for(int i=PositionsTotal()-1;i>=0;i--)
      { ulong tk=PositionGetTicket(i); if(tk==0) continue;
        if(!m_pos.SelectByTicket(tk)) continue;
        if(m_pos.Symbol()!=_Symbol||m_pos.Magic()!=m_magic) continue;
        m_trade.PositionClose(tk); }
      if(m_activeTicket!=0&&!m_pos.SelectByTicket(m_activeTicket)) m_activeTicket=0;
   }

   void ClearPending(){ m_pendingTicket=0; m_pendingDir=0; m_pendingBars=0; }

   ulong LastTicket()
   { for(int i=PositionsTotal()-1;i>=0;i--){ ulong t=PositionGetTicket(i); if(t==0)continue;
        if(!m_pos.SelectByTicket(t))continue; if(m_pos.Symbol()==_Symbol&&m_pos.Magic()==m_magic) return t; } return 0; }

   double HH(int start,int count){ int idx=iHighest(_Symbol,_Period,MODE_HIGH,count,start); if(idx<0)return iHigh(_Symbol,_Period,start); return iHigh(_Symbol,_Period,idx); }
   double LL(int start,int count){ int idx=iLowest(_Symbol,_Period,MODE_LOW,count,start); if(idx<0)return iLow(_Symbol,_Period,start); return iLow(_Symbol,_Period,idx); }

   void DrawRange(datetime today)
   {
      ObjectsDeleteAll(0,"PCAD_");
      datetime t1=today+InpL_RangeStart*3600, t2=today+InpL_ForceClose*3600;
      Tr("PCAD_RH",t1,m_rh,t2,m_rh,clrSlateGray,STYLE_SOLID);
      Tr("PCAD_RL",t1,m_rl,t2,m_rl,clrSlateGray,STYLE_SOLID);
      Tr("PCAD_EQ",t1,m_eq,t2,m_eq,clrGold,STYLE_DASH);
   }
   void Tr(string n,datetime t1,double p1,datetime t2,double p2,color c,int st)
   { ObjectCreate(0,n,OBJ_TREND,0,t1,p1,t2,p2); ObjectSetInteger(0,n,OBJPROP_COLOR,c);
     ObjectSetInteger(0,n,OBJPROP_STYLE,st); ObjectSetInteger(0,n,OBJPROP_RAY_RIGHT,false);
     ObjectSetInteger(0,n,OBJPROP_BACK,true); ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false); }
};

//==================================================================//
//                        MAIN EA GLUE                              //
//==================================================================//
CRiskManager       g_risk;
CRegime            g_regime;
CTrendStrategy     g_trend;
CLiquidityStrategy g_liq;
datetime           g_lastBar = 0;
ENUM_REGIME        g_curRegime = REGIME_NEUTRAL;

int OnInit()
{
   g_risk.Init(InpMagicTrend, InpMagicLiq);
   if(!g_regime.Init()) { Print("HATA: Rejim ADX handle."); return INIT_FAILED; }
   if(!g_trend.Init(GetPointer(g_risk))) { Print("HATA: Trend strateji init."); return INIT_FAILED; }
   if(!g_liq.Init(GetPointer(g_risk)))   { Print("HATA: Likidite strateji init."); return INIT_FAILED; }

   PrintFormat("ProCloudAdaptiveEA basladi | %s | Mod=%s | TrendADX>=%.0f RangeADX<=%.0f",
               _Symbol, EnumToString(InpRegimeMode), InpTrendADXMin, InpRangeADXMax);
   if(StringFind(_Symbol,"XAU")<0) Print("UYARI: XAUUSD (Altin) icin ayarlanmistir.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   g_regime.Deinit(); g_trend.Deinit(); g_liq.Deinit();
}

void OnTick()
{
   // 1) Ortak risk (gunluk/toplam DD, gun reset)
   g_risk.OnTick();

   // 2) Acik pozisyonlari her zaman yonet (rejimden bagimsiz)
   g_trend.ManageTick();
   g_liq.ManageTick();

   // 3) Yeni bar?
   datetime cur=(datetime)iTime(_Symbol,_Period,0);
   if(cur==g_lastBar) return;
   g_lastBar=cur;

   // 4) Rejimi guncelle
   g_curRegime = g_regime.Detect();

   // 5) Acilis izinleri
   bool riskOK   = g_risk.TradingAllowed();
   bool newsOK   = g_risk.NewsOK();
   bool noExpo   = !AnyExposure();              // tek pozisyon kurali
   bool baseOK   = riskOK && newsOK && noExpo;

   bool trendCanOpen=false, liqCanOpen=false;
   switch(InpRegimeMode)
   {
      case RM_FORCE_TREND: trendCanOpen=baseOK; break;
      case RM_FORCE_RANGE: liqCanOpen=baseOK;   break;
      case RM_BOTH:        trendCanOpen=baseOK;  liqCanOpen=baseOK; break;
      case RM_AUTO:
      default:
         if(g_curRegime==REGIME_TREND) trendCanOpen=baseOK;
         else if(g_curRegime==REGIME_RANGE) liqCanOpen=baseOK;
         // NEUTRAL -> ikisi de false
         break;
   }

   // 6) Modulleri calistir (yeni bar)
   g_trend.OnBar(trendCanOpen);
   g_liq.OnBar(liqCanOpen);
}

// Iki magic'ten herhangi birinde acik pozisyon/pending var mi?
bool AnyExposure()
{
   if(g_liq.HasExposure()) return true;
   CPositionInfo pos;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0) continue;
      if(!pos.SelectByTicket(t)) continue;
      if(pos.Symbol()!=_Symbol) continue;
      if(pos.Magic()==InpMagicTrend || pos.Magic()==InpMagicLiq) return true;
   }
   // bekleyen emirler
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong t=OrderGetTicket(i); if(t==0) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      long mg=OrderGetInteger(ORDER_MAGIC);
      if(mg==InpMagicTrend || mg==InpMagicLiq) return true;
   }
   return false;
}
//+------------------------------------------------------------------+

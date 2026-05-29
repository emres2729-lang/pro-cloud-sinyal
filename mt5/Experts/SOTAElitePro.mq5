//+------------------------------------------------------------------+
//|  SOTA Elite Pro EA v2.0                                          |
//|  SOTA + 137 Gann sinyal motoru + profesyonel yonetim katmani     |
//|  Sinyal: 137 EMA cross + SOTA Fib + Gann yakinlik + RSI div +    |
//|          hacim spike + mum kalibi (confluence skor 0-7)          |
//|  Yonetim: lot modlari, manuel/oto SL-TP, USD/SOTA trailing,      |
//|           Londra/NY seans, haber filtresi, toplam+gunluk DD,     |
//|           TP1/TP2/TP3 + SL + Entry gorsel etiketleri             |
//|  Platform: MetaTrader 5 (MQL5)                                   |
//|                                                                  |
//|  UYARI: Kar garantisi YOKTUR. Once DEMO + Strateji Test Cihazi.  |
//+------------------------------------------------------------------+
#property copyright "SOTA Elite Pro — emres2729"
#property version   "2.00"
#property description "137 Gann/SOTA confluence sinyali + tam profesyonel yonetim (lot/SL-TP/trailing/seans/haber/DD/gorsel)."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ENUMS ━━━
enum ENUM_SIGNAL_TYPE { SIG_BOTH=0, SIG_ONLY_BUY=1, SIG_ONLY_SELL=2 };
enum ENUM_TRAIL_MODE  { TRAIL_OFF=0, TRAIL_SOTA=1, TRAIL_USD=2 };

//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ INPUTS ━━━
input group "=== Sinyal (SOTA 137 Gann) ==="
input int             EMA_Len      = 137;        // EMA uzunlugu (137 GANN)
input ENUM_TIMEFRAMES Dir_TF       = PERIOD_H4;  // Yon EMA zaman dilimi
input int             LookbackBars = 180;        // Swing geriye bakis (mum)
input int             MinScore     = 4;          // Min confluence skoru (0-7)
input int             RSI_Period   = 14;         // RSI periyodu
input int             Div_PivotLB  = 5;          // Divergence pivot lookback
input double          VolSpikeMult = 1.5;        // Hacim spike esigi
input int             VolSmaPer    = 20;         // Hacim SMA periyodu

input group "=== Sinyal Yonu / Trend ==="
input ENUM_SIGNAL_TYPE Signal_Type   = SIG_BOTH; // Islem yonu
input bool             TrendFiltering = true;    // H4+H1 EMA trend filtresi

input group "=== Lot / Risk ==="
input double RiskPercent      = 1.0;     // Risk % (RiskPercentState=true ise)
input bool   RiskPercentState = true;    // true: % risk ile lot hesapla
input double FixLotSize       = 0.01;    // Sabit lot (risk kapaliysa)
input bool   AutoLotIncrease  = false;   // Bakiyeye gore lot artir
input double LotPerBalance    = 3500;    // Her bu kadar bakiyede 1x FixLot

input group "=== SL / TP ==="
input bool   SetManuallySLTP = false;    // true: pip ile; false: ATR+SOTA
input double ATR_Mult        = 1.5;      // ATR stop carpani (oto mod)
input double RiskReward       = 2.0;     // R:R (oto TP yedegi)
input int    PipPoints        = 10;      // 1 pip = kac puan (altinda 10 onerilir)
input double SL_Pip           = 200;     // Manuel SL (pip)
input double TP_Pip           = 600;     // Manuel TP (pip)

input group "=== Trailing ==="
input ENUM_TRAIL_MODE TrailMode = TRAIL_SOTA; // Trailing modu
input double StartProfitUSD = 3.0;       // USD trailing: bu kardan sonra basla
input double DistanceUSD    = 2.0;       // USD trailing: fiyatin gerisinde tut
input double StepUSD        = 1.0;       // USD trailing: min adim

input group "=== Limit / Drawdown ==="
input int    MaxOpenTrades    = 2;       // Max esanli pozisyon
input bool   MaxDD_State      = true;    // Toplam DD korumasi
input double MaxDD            = 0.30;    // Toplam maks DD (0.30 = %30) -> EA durur
input bool   MaxDailyDD_State = true;    // Gunluk DD korumasi
input double MaxDailyDD       = 0.20;    // Gunluk maks DD (0.20 = %20) -> gun durur

input group "=== Seans Filtresi (GMT) ==="
input bool UseSession    = true;         // Seans filtresi
input int  LondonStartGMT= 7;            // Londra baslangic (GMT)
input int  LondonEndGMT  = 16;           // Londra bitis (GMT)
input int  NYStartGMT    = 13;           // NY baslangic (GMT)
input int  NYEndGMT      = 22;           // NY bitis (GMT)
input bool OnlyOverlap   = false;        // Sadece Londra+NY ortak saatleri

input group "=== Haber Filtresi (Ekonomik Takvim) ==="
input bool   UseNewsFilter = true;       // Haberde dur (tester'da baypas)
input string NewsCurrency  = "USD";      // Para birimi
input int    PauseBeforeMin= 60;         // Haberden once (dk)
input int    ResumeAfterMin= 15;         // Haberden sonra (dk)
input bool   NewsHighOnly  = true;       // true: yuksek; false: orta+yuksek

input group "=== Gorsel ==="
input bool  ShowLevels = true;           // SL/Entry/TP1-2-3 ciz
input bool  ShowLabels = true;           // Etiketleri goster
input color ColSL      = clrDeepPink;    // Stop Loss rengi
input color ColTP      = clrMediumSeaGreen; // Take Profit rengi
input color ColEntry   = clrRoyalBlue;   // Giris rengi

input group "=== Genel ==="
input int    MagicNumber  = 137002;
input string CommentTrade = "SOTA Elite Pro";
input bool   ShowLogs     = true;

//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ SOTA FIB ━━━
double FIB[12] = {0.000, 0.174, 0.285, 0.396, 0.417, 0.432, 0.528, 0.639, 0.741, 0.852, 0.963, 1.000};

//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ GLOBAL ━━━
CTrade        trade;
CPositionInfo posinfo;
int      h_ema_dir, h_ema_4h, h_ema_1h, h_rsi, h_atr;
datetime g_last_bar = 0;
double   lv[12];
double   g90, g180, g270;

// Risk/DD takibi
double   g_initBal = 0, g_peakEq = 0, g_dayStartBal = 0;
datetime g_dayKey = 0;
bool     g_eaHalted = false, g_dayHalted = false;

//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ INIT ━━━
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(50);
    trade.SetTypeFillingBySymbol(_Symbol);

    h_ema_dir = iMA(_Symbol, Dir_TF,    EMA_Len, 0, MODE_EMA, PRICE_CLOSE);
    h_ema_4h  = iMA(_Symbol, PERIOD_H4, EMA_Len, 0, MODE_EMA, PRICE_CLOSE);
    h_ema_1h  = iMA(_Symbol, PERIOD_H1, EMA_Len, 0, MODE_EMA, PRICE_CLOSE);
    h_rsi     = iRSI(_Symbol, PERIOD_CURRENT, RSI_Period, PRICE_CLOSE);
    h_atr     = iATR(_Symbol, PERIOD_CURRENT, 14);

    if(h_ema_dir==INVALID_HANDLE || h_ema_4h==INVALID_HANDLE || h_ema_1h==INVALID_HANDLE ||
       h_rsi==INVALID_HANDLE || h_atr==INVALID_HANDLE)
    { Alert("SOTA Pro: Indikator handle olusturulamadi!"); return INIT_FAILED; }

    g_initBal = AccountInfoDouble(ACCOUNT_BALANCE);
    g_peakEq  = AccountInfoDouble(ACCOUNT_EQUITY);
    g_eaHalted = false;
    NewDay();

    PrintFormat("SOTA Elite Pro v2 basladi | Magic=%d | MinScore=%d/7 | Yon=%s | Trail=%s",
                MagicNumber, MinScore, EnumToString(Signal_Type), EnumToString(TrailMode));
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    IndicatorRelease(h_ema_dir); IndicatorRelease(h_ema_4h); IndicatorRelease(h_ema_1h);
    IndicatorRelease(h_rsi); IndicatorRelease(h_atr);
    // Gorseller bilerek silinmez (test/grafik sonrasi gorulebilsin)
}

//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ YARDIMCILAR ━━━
double GetEMA(int handle, int shift=1){ double b[1]; return (CopyBuffer(handle,0,shift,1,b)>0)?b[0]:0.0; }
double GetATR(int shift=1){ double b[1]; return (CopyBuffer(h_atr,0,shift,1,b)>0)?b[0]:0.0; }

datetime DayKey(datetime t){ MqlDateTime m; TimeToStruct(t,m); return StringToTime(StringFormat("%04d.%02d.%02d",m.year,m.mon,m.day)); }

void NewDay(){ g_dayKey=DayKey(TimeCurrent()); g_dayStartBal=AccountInfoDouble(ACCOUNT_BALANCE); g_dayHalted=false; }

bool IsInSession()
{
    if(!UseSession) return true;
    MqlDateTime dt; TimeToStruct(TimeGMT(), dt);
    int h = dt.hour;
    bool lon = (h>=LondonStartGMT && h<LondonEndGMT);
    bool ny  = (h>=NYStartGMT && h<NYEndGMT);
    return OnlyOverlap ? (lon && ny) : (lon || ny);
}

bool NewsOK()
{
    if(!UseNewsFilter) return true;
    if(MQLInfoInteger(MQL_TESTER)) return true; // tester'da takvim yok
    datetime now=TimeCurrent();
    MqlCalendarValue values[];
    int n=CalendarValueHistory(values, now-ResumeAfterMin*60, now+PauseBeforeMin*60, NULL, NewsCurrency);
    if(n<=0) return true;
    ENUM_CALENDAR_EVENT_IMPORTANCE need = NewsHighOnly ? CALENDAR_IMPORTANCE_HIGH : CALENDAR_IMPORTANCE_MODERATE;
    for(int i=0;i<n;i++){ MqlCalendarEvent ev; if(!CalendarEventById(values[i].event_id,ev)) continue; if(ev.importance>=need) return false; }
    return true;
}

int CountMyTrades(int direction=-1)
{
    int count=0;
    for(int i=PositionsTotal()-1;i>=0;i--){
        ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
        if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
        if((int)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
        if(direction>=0 && (int)PositionGetInteger(POSITION_TYPE)!=direction) continue;
        count++;
    }
    return count;
}

void CloseAllMine()
{
    for(int i=PositionsTotal()-1;i>=0;i--){
        ulong t=PositionGetTicket(i); if(!posinfo.SelectByTicket(t)) continue;
        if(posinfo.Symbol()==_Symbol && posinfo.Magic()==MagicNumber) trade.PositionClose(t);
    }
}

//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ DRAWDOWN KORUMA ━━━
void RiskGuard()
{
    double eq=AccountInfoDouble(ACCOUNT_EQUITY);
    if(eq>g_peakEq) g_peakEq=eq;

    if(DayKey(TimeCurrent())!=g_dayKey) NewDay();
    if(g_eaHalted) return;

    if(MaxDD_State)
    {
        double ddLimit = g_initBal*(1.0-MaxDD);
        if(eq<=ddLimit){ g_eaHalted=true; CloseAllMine();
            PrintFormat("!!! TOPLAM DD (%%%.0f) DOLDU -> EA DURDU. Eq=%.2f Lim=%.2f", MaxDD*100, eq, ddLimit);
            Alert("SOTA Pro: Toplam drawdown limiti doldu."); return; }
    }
    if(MaxDailyDD_State && !g_dayHalted)
    {
        double dLimit = g_dayStartBal*(1.0-MaxDailyDD);
        if(eq<=dLimit){ g_dayHalted=true; PrintFormat("GUNLUK DD DOLDU -> bugun yeni islem yok. Eq=%.2f Lim=%.2f", eq, dLimit); }
    }
}

//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ LOT HESABI ━━━
double NormLot(double lot)
{
    double minL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
    double maxL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
    double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP); if(step<=0) step=0.01;
    lot=MathFloor(lot/step)*step;
    return MathMax(minL, MathMin(maxL, lot));
}

double CalcLot(double sl_distance)
{
    if(RiskPercentState && sl_distance>0)
    {
        double risk_amt=AccountInfoDouble(ACCOUNT_BALANCE)*RiskPercent/100.0;
        double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
        double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
        if(tv>0 && ts>0){
            double loss_lot=(sl_distance/ts)*tv;
            if(loss_lot>0) return NormLot(risk_amt/loss_lot);
        }
    }
    if(AutoLotIncrease && LotPerBalance>0)
        return NormLot(FixLotSize * MathMax(1.0, AccountInfoDouble(ACCOUNT_BALANCE)/LotPerBalance));
    return NormLot(FixLotSize);
}

//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ SOTA SEVIYELERI ━━━
void GetSwingHL(int lookback, double &sw_h, double &sw_l)
{
    int count=MathMin(lookback, Bars(_Symbol,PERIOD_CURRENT)-2);
    if(count<10){ sw_h=iHigh(_Symbol,PERIOD_CURRENT,1); sw_l=iLow(_Symbol,PERIOD_CURRENT,1); return; }
    double highs[],lows[];
    if(CopyHigh(_Symbol,PERIOD_CURRENT,1,count,highs)<=0 || CopyLow(_Symbol,PERIOD_CURRENT,1,count,lows)<=0)
    { sw_h=iHigh(_Symbol,PERIOD_CURRENT,1); sw_l=iLow(_Symbol,PERIOD_CURRENT,1); return; }
    sw_h=highs[ArrayMaximum(highs)]; sw_l=lows[ArrayMinimum(lows)];
}

void CalcSOTA(double eff_h, double eff_l, bool is_bull)
{
    double rng=MathMax(eff_h-eff_l,_Point);
    if(is_bull){
        lv[0]=eff_l; lv[11]=eff_h;
        for(int i=1;i<=10;i++) lv[i]=eff_l+(1.0-FIB[i])*rng;
        g90=eff_l+0.25*rng; g180=eff_l+0.50*rng; g270=eff_l+0.75*rng;
    } else {
        lv[0]=eff_h; lv[11]=eff_l;
        for(int i=1;i<=10;i++) lv[i]=eff_h-(1.0-FIB[i])*rng;
        g90=eff_h-0.25*rng; g180=eff_h-0.50*rng; g270=eff_h-0.75*rng;
    }
}

double NextTarget(double price, bool is_long)
{
    if(is_long){ if(price<g90)return g90; if(price<g180)return g180; if(price<g270)return g270; return lv[11]; }
    else       { if(price>g90)return g90; if(price>g180)return g180; if(price>g270)return g270; return lv[11]; }
}

//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ DIVERGENCE / VOL / PATTERN ━━━
bool DetectBullDiv()
{
    int bars=25+Div_PivotLB*2; double lows[],rsi_buf[];
    if(CopyLow(_Symbol,PERIOD_CURRENT,1,bars,lows)<=0) return false;
    if(CopyBuffer(h_rsi,0,1,bars,rsi_buf)<=0) return false;
    int p1=-1,p2=-1;
    for(int i=Div_PivotLB;i<bars-Div_PivotLB;i++){
        bool piv=true; for(int j=1;j<=Div_PivotLB&&piv;j++) if(lows[i]>=lows[i-j]||lows[i]>=lows[i+j]) piv=false;
        if(!piv) continue; if(p1<0)p1=i; else {p2=i;break;}
    }
    if(p1<0||p2<0) return false;
    return (lows[p1]<lows[p2] && rsi_buf[p1]>rsi_buf[p2]);
}

bool DetectBearDiv()
{
    int bars=25+Div_PivotLB*2; double highs[],rsi_buf[];
    if(CopyHigh(_Symbol,PERIOD_CURRENT,1,bars,highs)<=0) return false;
    if(CopyBuffer(h_rsi,0,1,bars,rsi_buf)<=0) return false;
    int p1=-1,p2=-1;
    for(int i=Div_PivotLB;i<bars-Div_PivotLB;i++){
        bool piv=true; for(int j=1;j<=Div_PivotLB&&piv;j++) if(highs[i]<=highs[i-j]||highs[i]<=highs[i+j]) piv=false;
        if(!piv) continue; if(p1<0)p1=i; else {p2=i;break;}
    }
    if(p1<0||p2<0) return false;
    return (highs[p1]>highs[p2] && rsi_buf[p1]<rsi_buf[p2]);
}

bool IsVolSpike()
{
    long vbuf[]; int n=VolSmaPer+2;
    if(CopyTickVolume(_Symbol,PERIOD_CURRENT,1,n,vbuf)<n) return false;
    double sma=0; for(int i=1;i<n;i++) sma+=(double)vbuf[i]; sma/=(n-1);
    return ((double)vbuf[0]>=sma*VolSpikeMult);
}

bool IsBullPat(bool dip_zone)
{
    if(!dip_zone) return false;
    double o=iOpen(_Symbol,PERIOD_CURRENT,1),c=iClose(_Symbol,PERIOD_CURRENT,1);
    double h=iHigh(_Symbol,PERIOD_CURRENT,1),l=iLow(_Symbol,PERIOD_CURRENT,1);
    double o1=iOpen(_Symbol,PERIOD_CURRENT,2),c1=iClose(_Symbol,PERIOD_CURRENT,2);
    double body=MathAbs(c-o),rng=MathMax(h-l,_Point),lo_shad=MathMin(o,c)-l;
    bool hammer=(lo_shad>=2.0*MathMax(body,_Point))&&(body<=0.35*rng)&&(c>o);
    bool bull_eng=(c>o)&&(c1<o1)&&(c>o1)&&(o<=c1);
    return hammer||bull_eng;
}

bool IsBearPat(bool tepe_zone)
{
    if(!tepe_zone) return false;
    double o=iOpen(_Symbol,PERIOD_CURRENT,1),c=iClose(_Symbol,PERIOD_CURRENT,1);
    double h=iHigh(_Symbol,PERIOD_CURRENT,1),l=iLow(_Symbol,PERIOD_CURRENT,1);
    double o1=iOpen(_Symbol,PERIOD_CURRENT,2),c1=iClose(_Symbol,PERIOD_CURRENT,2);
    double body=MathAbs(c-o),rng=MathMax(h-l,_Point),up_shd=h-MathMax(o,c);
    bool shoot=(up_shd>=2.0*MathMax(body,_Point))&&(body<=0.35*rng)&&(c<o);
    bool bear_eng=(c<o)&&(c1>o1)&&(c<o1)&&(o>=c1);
    return shoot||bear_eng;
}

bool TrendOK(bool longDir)
{
    if(!TrendFiltering) return true;
    double e4=GetEMA(h_ema_4h),e1=GetEMA(h_ema_1h),px=iClose(_Symbol,PERIOD_CURRENT,1);
    if(e4<=0||e1<=0) return true;
    return longDir ? (px>e4 && px>e1) : (px<e4 && px<e1);
}

//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ GORSEL ━━━
void DrawLevel(string name,double price,color c,string label)
{
    if(!ShowLevels) return;
    datetime t1=iTime(_Symbol,PERIOD_CURRENT,0);
    datetime t2=t1+PeriodSeconds()*40;
    if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_TREND,0,t1,price,t2,price);
    else { ObjectMove(0,name,0,t1,price); ObjectMove(0,name,1,t2,price); }
    ObjectSetInteger(0,name,OBJPROP_COLOR,c); ObjectSetInteger(0,name,OBJPROP_WIDTH,2);
    ObjectSetInteger(0,name,OBJPROP_RAY_RIGHT,false); ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
    if(ShowLabels){
        string tn=name+"_t";
        if(ObjectFind(0,tn)<0) ObjectCreate(0,tn,OBJ_TEXT,0,t2,price);
        else ObjectMove(0,tn,0,t2,price);
        ObjectSetString(0,tn,OBJPROP_TEXT," "+label); ObjectSetInteger(0,tn,OBJPROP_COLOR,c);
        ObjectSetInteger(0,tn,OBJPROP_FONTSIZE,9); ObjectSetInteger(0,tn,OBJPROP_SELECTABLE,false);
    }
}

void DrawTradeLevels(bool isLong,double entry,double sl,double t1,double t2,double t3)
{
    if(!ShowLevels) return;
    string id=IntegerToString((long)iTime(_Symbol,PERIOD_CURRENT,0));
    DrawLevel("SOTA_EN_"+id, entry, ColEntry, "Entry "+DoubleToString(entry,_Digits));
    DrawLevel("SOTA_SL_"+id, sl,    ColSL,    "Stop Loss "+DoubleToString(sl,_Digits));
    DrawLevel("SOTA_T1_"+id, t1,    ColTP,    "TP1 "+DoubleToString(t1,_Digits));
    DrawLevel("SOTA_T2_"+id, t2,    ColTP,    "TP2 "+DoubleToString(t2,_Digits));
    DrawLevel("SOTA_T3_"+id, t3,    ColTP,    "TP3 "+DoubleToString(t3,_Digits));
}

//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ TRAILING ━━━
void ManagePositions()
{
    if(TrailMode==TRAIL_OFF) return;
    double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
    double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
    double atr=GetATR(1);
    double min_gap=3*_Point;

    for(int i=PositionsTotal()-1;i>=0;i--)
    {
        ulong ticket=PositionGetTicket(i);
        if(!PositionSelectByTicket(ticket)) continue;
        if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
        if((int)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;

        int    ptype=(int)PositionGetInteger(POSITION_TYPE);
        double cur_sl=PositionGetDouble(POSITION_SL);
        double cur_tp=PositionGetDouble(POSITION_TP);
        double open =PositionGetDouble(POSITION_PRICE_OPEN);
        double vol  =PositionGetDouble(POSITION_VOLUME);
        double new_sl=cur_sl;

        if(TrailMode==TRAIL_USD)
        {
            double profit=PositionGetDouble(POSITION_PROFIT);
            if(profit < StartProfitUSD) continue;
            double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
            double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
            double mpp=(ts>0)?(tv/ts)*vol:0; if(mpp<=0) continue; // $ / 1.0 fiyat
            double distP=DistanceUSD/mpp, stepP=StepUSD/mpp;
            if(ptype==POSITION_TYPE_BUY){ double n=bid-distP; if(n>cur_sl+stepP && n>open) new_sl=n; }
            else                        { double n=ask+distP; if((cur_sl<=0||n<cur_sl-stepP) && n<open) new_sl=n; }
        }
        else // TRAIL_SOTA
        {
            if(ptype==POSITION_TYPE_BUY){
                if(bid>=lv[4] && cur_sl<lv[6]-min_gap) new_sl=lv[6];
                else if(bid>=lv[5] && cur_sl<g180-min_gap) new_sl=g180;
                else if(bid>=lv[3]){ double tr=bid-atr*ATR_Mult; if(tr>cur_sl+min_gap) new_sl=tr; }
            } else if(ptype==POSITION_TYPE_SELL){
                if(bid<=lv[4] && (cur_sl<=0||cur_sl>lv[6]+min_gap)) new_sl=lv[6];
                else if(bid<=lv[5] && (cur_sl<=0||cur_sl>g180+min_gap)) new_sl=g180;
                else if(bid<=lv[3]){ double tr=bid+atr*ATR_Mult; if(cur_sl<=0||tr<cur_sl-min_gap) new_sl=tr; }
            }
        }

        if(MathAbs(new_sl-cur_sl)>min_gap)
            if(trade.PositionModify(ticket,new_sl,cur_tp) && ShowLogs)
                Print("Trailing SL -> ",DoubleToString(new_sl,_Digits)," (ticket ",ticket,")");
    }
}

//━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ ANA FONKSIYON ━━━
void OnTick()
{
    RiskGuard();
    ManagePositions();
    if(g_eaHalted) return;

    datetime bt[1];
    if(CopyTime(_Symbol,PERIOD_CURRENT,0,1,bt)<=0) return;
    if(bt[0]==g_last_bar) return;
    g_last_bar=bt[0];

    if(g_dayHalted) return;
    if(!IsInSession()) return;
    if(!NewsOK()) return;

    double close1=iClose(_Symbol,PERIOD_CURRENT,1);
    double close2=iClose(_Symbol,PERIOD_CURRENT,2);
    double ema1=GetEMA(h_ema_dir,1), ema2=GetEMA(h_ema_dir,2);
    if(ema1<=0) return;

    bool is_bull=(close1>=ema1), was_bull=(close2>=ema2);
    bool cross_up=(!was_bull && is_bull), cross_down=(was_bull && !is_bull);
    if(!cross_up && !cross_down) return;

    double atr=GetATR(1); if(atr<=0) return;

    double sw_h,sw_l; GetSwingHL(LookbackBars,sw_h,sw_l);
    CalcSOTA(sw_h,sw_l,is_bull);

    bool dip_zone =(close1<lv[6]);
    bool tepe_zone=(close1>lv[3]);
    bool gann_near=(MathAbs(close1-g90)/MathMax(close1,0.01)<0.005 ||
                    MathAbs(close1-g180)/MathMax(close1,0.01)<0.005 ||
                    MathAbs(close1-g270)/MathMax(close1,0.01)<0.005);
    bool bull_div=DetectBullDiv(), bear_div=DetectBearDiv();
    bool vol_spk=IsVolSpike();
    bool bull_pat=IsBullPat(dip_zone), bear_pat=IsBearPat(tepe_zone);

    int score_long =(is_bull?1:0)+(dip_zone?1:0)+(gann_near?1:0)+(bull_div?1:0)+(vol_spk?1:0)+(bull_pat?1:0)+(cross_up?1:0);
    int score_short=(!is_bull?1:0)+(tepe_zone?1:0)+(gann_near?1:0)+(bear_div?1:0)+(vol_spk?1:0)+(bear_pat?1:0)+(cross_down?1:0);

    if(ShowLogs)
        PrintFormat("SOTA | close=%.2f EMA=%.2f cU=%s cD=%s | L:%d S:%d | dip=%s tepe=%s gann=%s",
            close1,ema1,cross_up?"E":"h",cross_down?"E":"h",score_long,score_short,
            dip_zone?"E":"H",tepe_zone?"E":"H",gann_near?"E":"H");

    if(CountMyTrades()>=MaxOpenTrades) return;

    bool allowLong =(Signal_Type==SIG_BOTH || Signal_Type==SIG_ONLY_BUY);
    bool allowShort=(Signal_Type==SIG_BOTH || Signal_Type==SIG_ONLY_SELL);

    double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
    double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
    double pip=PipPoints*_Point;

    //── LONG ──
    if(cross_up && allowLong && TrendOK(true) && score_long>=MinScore && CountMyTrades(POSITION_TYPE_BUY)==0)
    {
        double sl,tp;
        if(SetManuallySLTP){ sl=ask-SL_Pip*pip; tp=ask+TP_Pip*pip; }
        else { sl=close1-atr*ATR_Mult; tp=NextTarget(close1,true); if(tp<=ask+_Point*10) tp=ask+(ask-sl)*RiskReward; }
        double lot=CalcLot(ask-sl); if(lot<=0) return;
        if(trade.Buy(lot,_Symbol,ask,NormalizeDouble(sl,_Digits),NormalizeDouble(tp,_Digits),CommentTrade))
        {
            DrawTradeLevels(true,ask,sl,g90,g180,g270);
            PrintFormat("LONG ACILDI | lot=%.2f ask=%.2f SL=%.2f TP=%.2f skor=%d/7",lot,ask,sl,tp,score_long);
        }
        else Print("LONG HATASI: ",trade.ResultRetcodeDescription());
    }
    //── SHORT ──
    else if(cross_down && allowShort && TrendOK(false) && score_short>=MinScore && CountMyTrades(POSITION_TYPE_SELL)==0)
    {
        double sl,tp;
        if(SetManuallySLTP){ sl=bid+SL_Pip*pip; tp=bid-TP_Pip*pip; }
        else { sl=close1+atr*ATR_Mult; tp=NextTarget(close1,false); if(tp>=bid-_Point*10) tp=bid-(sl-bid)*RiskReward; }
        double lot=CalcLot(sl-bid); if(lot<=0) return;
        if(trade.Sell(lot,_Symbol,bid,NormalizeDouble(sl,_Digits),NormalizeDouble(tp,_Digits),CommentTrade))
        {
            DrawTradeLevels(false,bid,sl,g90,g180,g270);
            PrintFormat("SHORT ACILDI | lot=%.2f bid=%.2f SL=%.2f TP=%.2f skor=%d/7",lot,bid,sl,tp,score_short);
        }
        else Print("SHORT HATASI: ",trade.ResultRetcodeDescription());
    }
}
//+------------------------------------------------------------------+

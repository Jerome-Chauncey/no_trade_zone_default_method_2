//+------------------------------------------------------------------+
//|                                    PriceInTimeEA.mq5            |
//|       Asian range + NTZ breakout + CSV no-trade skip + News     |
//|       session separators + TP ladder + auto London-close flat    |
//+------------------------------------------------------------------+
#property copyright   "2025 Jerome Chauncey / NTZ"
#property link        "https://github.com/Jerome-Chauncey"
#property version     "1.16"
#property strict


#include <Trade\Trade.mqh>

//―――――――――― Inputs ――――――――――――――――――――――――――――――――――――――――――――
input string  TradeSymbol       = "";       // "" = current chart symbol
input double  LotSize           = 0.10;     // lots per trade
input int     Slippage          = 5;        // slippage in points
input int     MagicNumber       = 10101;    // EA magic number
input int     AsiaThresholdPips = 40;       // skip if Asia > this
input int     TargetCount       = 10;       // TP steps per side
input string  ExcludedDates     = "";       // back-test: "YYYY.MM.DD,..."

//―――――― Globals & State ――――――――――――――――――――――――――――――――――――――――――
CTrade    trade;
string    Sym;
double NYHigh = -DBL_MAX;
double NYLow  = DBL_MAX;
bool   NYActive = false;
int BrokerGMTOffset = 0;

datetime AsiaStart;
datetime FrankfurtOpen;
datetime LondonOpen;
datetime NewYorkOpen;
datetime LondonClose;


// pending-stop tickets we placed
ulong     BuyTicket       = 0;
ulong     SellTicket      = 0;


bool      DoNotTradeDay   = false;  // Asia-too-big or manual
bool      LondonClosed    = false;  // have we run the 19:00 cleanup?
int       lastResetDate   = 0;      // YYYYMMDD

double    AsiaHigh = -DBL_MAX, AsiaLow = DBL_MAX;
double    NTZHigh  = -DBL_MAX, NTZLow  = DBL_MAX, NTZRange = 0.0;

double    TPLevels[21];
bool      TPTrig[21];

datetime  frankOpen      = 0;
bool      OrdersPlaced   = false;
bool      NTZDefined     = false;
bool      PositionOpened = false;
int       lastHour       = -1;

// object names
#define PREF_ASIAN     "SessAsian"
#define PREF_FRANK     "SessFrank"
#define PREF_LON       "SessLondon"
#define PREF_NY        "SessNY"
#define OBJ_HIGH       "NTZ_High"
#define OBJ_LOW        "NTZ_Low"
#define OBJ_INFO       "NTZ_Info"
#define OBJ_RANGE      "Asia_NTZ_Range"

datetime GMTToBroker(int hour,int minute=0)
{
   datetime gmtDay = StringToTime(TimeToString(TimeGMT(),TIME_DATE));
   datetime gmtTime = gmtDay + hour*3600 + minute*60;
   return gmtTime + BrokerGMTOffset;
}

void UpdateSessionTimes()
{
   AsiaStart     = GMTToBroker(0,0);
   FrankfurtOpen = GMTToBroker(7,0);
   LondonOpen    = GMTToBroker(8,0);
   NewYorkOpen   = GMTToBroker(13,0);
   LondonClose   = GMTToBroker(16,0);
}

void BackfillAsiaRange()
{
   AsiaHigh = -DBL_MAX;
   AsiaLow  = DBL_MAX;

   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);

   // Build today timestamps
   datetime dayStart  = StringToTime(
      StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day)
   );

   datetime asiaStart = AsiaStart;
   datetime asiaEnd   = FrankfurtOpen;

   // If before Asia session, nothing to do
   if(now < asiaStart)
      return;

   // Decide end point
   datetime calcEnd = (now < asiaEnd ? now : asiaEnd);

   int startBar = iBarShift(Sym, PERIOD_M1, asiaStart, false);
   int endBar   = iBarShift(Sym, PERIOD_M1, calcEnd,  false);

   if(startBar < 0 || endBar < 0)
      return;

   for(int i = startBar; i >= endBar; i--)
   {
      double hi = iHigh(Sym, PERIOD_M1, i);
      double lo = iLow (Sym, PERIOD_M1, i);

      if(hi > AsiaHigh) AsiaHigh = hi;
      if(lo < AsiaLow)  AsiaLow  = lo;
   }

   PrintFormat(
      "Asia backfilled. High=%.5f Low=%.5f",
      AsiaHigh, AsiaLow
   );
}




//+------------------------------------------------------------------+
//| Clear all daily objects except the bottom-range label           |
//+------------------------------------------------------------------+
void ClearDailyLines()
{
   ObjectDelete(0,OBJ_HIGH);
   ObjectDelete(0,OBJ_LOW);
   ObjectDelete(0,OBJ_INFO);
   for(int i=1;i<=TargetCount;i++)
   {
      ObjectDelete(0,StringFormat("TPB_%d",i));
      ObjectDelete(0,StringFormat("TPS_%d",i));
   }
   for(int i=ObjectsTotal(0)-1;i>=0;i--)
   {
      string nm=ObjectName(0,i);
      if(StringFind(nm,PREF_ASIAN)==0||
         StringFind(nm,PREF_FRANK)==0||
         StringFind(nm,PREF_LON)==0||
         StringFind(nm,PREF_NY)==0)
         ObjectDelete(0,nm);
   }
}

//+------------------------------------------------------------------+
//| Ensure bottom-center range label exists                         |
//+------------------------------------------------------------------+
void EnsureRangeLabel()
{
   if(ObjectFind(0,OBJ_RANGE)==-1)
   {
      ObjectCreate(0,OBJ_RANGE,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,OBJ_RANGE,OBJPROP_CORNER,   CORNER_RIGHT_LOWER);
      ObjectSetInteger(0,OBJ_RANGE,OBJPROP_COLOR,    clrWhite);
      ObjectSetInteger(0,OBJ_RANGE,OBJPROP_FONTSIZE, 10);
      ObjectSetInteger(0,OBJ_RANGE,OBJPROP_YDISTANCE,20);
   }
}

//+------------------------------------------------------------------+
//| Cancel ANY and ALL pending stop orders on this symbol           |
//+------------------------------------------------------------------+
void CancelPendingOrders()
{
   // delete tickets we tracked
   if(BuyTicket>0)  { trade.OrderDelete(BuyTicket);  BuyTicket=0; }
   if(SellTicket>0) { trade.OrderDelete(SellTicket); SellTicket=0; }

   // sweep _all_ pending stops for our symbol
   int total=OrdersTotal();
   for(int i=total-1;i>=0;i--)
   {
      ulong tck=OrderGetTicket(i);
      if(OrderGetString(ORDER_SYMBOL)==Sym)
      {
         ENUM_ORDER_TYPE typ=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(typ==ORDER_TYPE_BUY_STOP||typ==ORDER_TYPE_SELL_STOP)
            trade.OrderDelete(tck);
      }
   }
   OrdersPlaced=false;
   Print("✔️ All pending STOP orders cleared");
}

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit()
{  
   BrokerGMTOffset = (int)(TimeCurrent() - TimeGMT());
   UpdateSessionTimes();
   Sym = StringLen(TradeSymbol)>0 ? TradeSymbol : _Symbol;
   trade.SetExpertMagicNumber(MagicNumber);
   EnsureRangeLabel();

   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   lastResetDate = dt.year*10000 + dt.mon*100 + dt.day;

   BackfillAsiaRange();
   BackfillNTZRange();
   BackfillNYRange();

   // Late-attach guard: after NTZ window
   if(TimeCurrent() >= StringToTime(TimeToString(TimeCurrent(), TIME_DATE) + " 10:00"))
   {
      OrdersPlaced = true;
   }

   return(INIT_SUCCEEDED);
}




//+------------------------------------------------------------------+
//| Expert deinitialization                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ClearDailyLines();
   ObjectDelete(0,OBJ_RANGE);
}

//+------------------------------------------------------------------+
//| Expert tick handler                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime now=TimeCurrent(); MqlDateTime dt; TimeToStruct(now,dt);

   // 1) New-day reset
   int today=dt.year*10000+dt.mon*100+dt.day;
   if(today!=lastResetDate)
   {
      lastResetDate=today;
      
      DoNotTradeDay =false;
      LondonClosed  =false;
      frankOpen     =0;
      OrdersPlaced  =false;
      NTZDefined    =false;
      PositionOpened=false;
      lastHour      =-1;
      AsiaHigh=-DBL_MAX; AsiaLow=DBL_MAX;
      NTZHigh=-DBL_MAX; NTZLow=DBL_MAX; NTZRange=0.0;

      CancelPendingOrders();
      ClearDailyLines();
      EnsureRangeLabel();

      

      if(StringLen(ExcludedDates)>0)
      {
         string arr[]; int cnt=StringSplit(ExcludedDates,',',arr);
         for(int i=0;i<cnt;i++)
         {
            datetime ex=StringToTime(arr[i]+" 00:00");
            MqlDateTime ed; TimeToStruct(ex,ed);
            if(ed.year==dt.year&&ed.mon==dt.mon&&ed.day==dt.day)
            {
               DoNotTradeDay=true;
               PrintFormat("ℹ️ Halted for excluded %s",arr[i]);
               break;
            }
         }
      }
   }

   // 2) London-close flat @19:00
   if(!LondonClosed && now>=LondonClose)
   {
      CancelPendingOrders();
      if(PositionSelect(Sym))
         trade.PositionClose(PositionGetInteger(POSITION_TICKET));
      ClearDailyLines();
      LondonClosed=true;
      Print("✅ London-close flat & cleanup");
   }
   if(LondonClosed) return;  // stop until tomorrow

   // 3) update bottom-center range label
   {
      uint w=(uint)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
      ObjectSetInteger(0,OBJ_RANGE,OBJPROP_XDISTANCE,(int)w/2);
      double aP=(AsiaHigh>AsiaLow? (AsiaHigh-AsiaLow)/(_Point*10.0):0.0),
             nP=(NTZRange>0   ? NTZRange/(_Point*10.0)  :0.0);
      ObjectSetString(0,OBJ_RANGE,OBJPROP_TEXT,
         StringFormat("Asia: %.1f pips\nNTZ : %.1f pips",aP,nP));
   }

   // 4) session separators
   if(now>=AsiaStart && lastHour<1)
   {
      DrawSessionSeparator(AsiaStart,clrYellow,PREF_ASIAN);
      lastHour=1;
   }
   
   if(now>=FrankfurtOpen && lastHour<2)
   {
      DrawSessionSeparator(FrankfurtOpen,clrBlue,PREF_FRANK);
      lastHour=2;
   }
   
   if(now>=LondonOpen && lastHour<3)
   {
      DrawSessionSeparator(LondonOpen,clrGreen,PREF_LON);
      lastHour=3;
   }
   
   if(now>=NewYorkOpen && lastHour<4)
   {
      DrawSessionSeparator(NewYorkOpen,clrRed,PREF_NY);
      lastHour=4;
   }

   // 5) bail if blocked
   if(DoNotTradeDay) return;

   // 6) build Asia 03–09
   if(now>=AsiaStart && now<FrankfurtOpen)
   {
      AsiaHigh=MathMax(AsiaHigh,iHigh(Sym,PERIOD_M1,0));
      AsiaLow =MathMin(AsiaLow, iLow (Sym,PERIOD_M1,0));
   }

   // 7) 09:00 NTZ start & threshold
   if(now>=FrankfurtOpen && frankOpen==0)
   {
      double aP=(AsiaHigh-AsiaLow)/(_Point*10.0);
      if(aP>AsiaThresholdPips)
      {
         DoNotTradeDay=true;
         PrintFormat("🛑 Asia %.1f pips > %d → halt",aP,AsiaThresholdPips);
      }
      frankOpen=now;
   }

   // 8) build NTZ 09–10
   if(now>=FrankfurtOpen && now<LondonOpen)
   {
      NTZHigh=MathMax(NTZHigh,iHigh(Sym,PERIOD_M1,0));
      NTZLow =MathMin(NTZLow, iLow (Sym,PERIOD_M1,0));
   }

   // 9) place stops 09:57–10:00
   if(frankOpen>0 && !OrdersPlaced
      && now>=LondonOpen-180 && now<LondonOpen)
   {
      NTZRange=NTZHigh-NTZLow;
      double nP=NTZRange/(_Point*10.0);
      if(ObjectFind(0,OBJ_HIGH)==-1) ObjectCreate(0,OBJ_HIGH,OBJ_HLINE,0,0,NTZHigh);
      if(ObjectFind(0,OBJ_LOW )==-1) ObjectCreate(0,OBJ_LOW, OBJ_HLINE,0,0,NTZLow);
      ObjectSetDouble(0,OBJ_HIGH,OBJPROP_PRICE,NTZHigh);
      ObjectSetDouble(0,OBJ_LOW, OBJPROP_PRICE,NTZLow);

      if(nP>=10.0 && nP<=30.0)
      {
         SetupTPLevels(); PlacePendingOrders(); DrawTPLevels();
         OrdersPlaced=true; NTZDefined=true;
         PrintFormat("✅ Orders placed — Asia:%.1f, NTZ:%.1f",
                     (AsiaHigh-AsiaLow)/(_Point*10.0),nP);
      }
      else
         PrintFormat("🛑 NTZ %.1f pips outside [10–30] → halt",nP);
   }

   // 10) cancel unfilled stops by 3h after frankOpen
   if(!PositionOpened        // **only if no fill yet**
      && OrdersPlaced        // stops are live
      && frankOpen>0
      && TimeCurrent()>=frankOpen+3*3600)
   {
      Print("⌛ 3h passed without fill → canceling stops");
      CancelPendingOrders();
   }

   // 11) TP ladder & detect fills
   if(NTZDefined) ManageTakeProfits();
   if(!PositionOpened && PositionSelect(Sym))
      PositionOpened=true;
      
   if(NYActive)
   {
      NYHigh = MathMax(NYHigh, iHigh(Sym, PERIOD_M1, 0));
      NYLow  = MathMin(NYLow,  iLow (Sym, PERIOD_M1, 0));
   }

}

void BackfillNTZRange()
{
   NTZHigh  = -DBL_MAX;
   NTZLow   = DBL_MAX;
   NTZRange = 0.0;
   NTZDefined = false;
   frankOpen = 0;

   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);

   datetime dayStart = StringToTime(
      StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day)
   );

   datetime ntzStart = FrankfurtOpen;
   datetime ntzEnd   = LondonOpen;

   // Before NTZ session
   if(now < ntzStart)
      return;

   // Mark Frankfurt open
   frankOpen = ntzStart;

   // Decide end point
   datetime calcEnd = (now < ntzEnd ? now : ntzEnd);

   int startBar = iBarShift(Sym, PERIOD_M1, ntzStart, false);
   int endBar   = iBarShift(Sym, PERIOD_M1, calcEnd,  false);

   if(startBar < 0 || endBar < 0)
      return;

   for(int i = startBar; i >= endBar; i--)
   {
      double hi = iHigh(Sym, PERIOD_M1, i);
      double lo = iLow (Sym, PERIOD_M1, i);

      if(hi > NTZHigh) NTZHigh = hi;
      if(lo < NTZLow)  NTZLow  = lo;
   }

   // Only finalize after 10:00
   if(now >= ntzEnd)
   {
      NTZRange   = NTZHigh - NTZLow;
      NTZDefined = true;

      PrintFormat(
         "NTZ backfilled. High=%.5f Low=%.5f Range=%.1f pips",
         NTZHigh,
         NTZLow,
         NTZRange / (_Point*10.0)
      );
   }
   else
   {
      Print("NTZ building live. Frankfurt session active.");
   }
}


//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
void SetupTPLevels()
{
   ArrayFill(TPTrig,0,ArraySize(TPTrig),false);
   for(int i=1;i<=TargetCount;i++)
   {
      TPLevels[i]            = NTZHigh + i*NTZRange;
      TPLevels[i+TargetCount]= NTZLow  - i*NTZRange;
   }
}
void PlacePendingOrders()
{
   double pip = _Point * 10.0;

   BuyTicket  = trade.BuyStop (LotSize, NTZHigh + pip, Sym, NTZLow - pip, 0, 0, Slippage);
   SellTicket = trade.SellStop(LotSize, NTZLow  - pip, Sym, NTZHigh + pip, 0, 0, Slippage);

}
void DrawTPLevels()
{
   for(int i=1;i<=TargetCount;i++)
   {
      string b=StringFormat("TPB_%d",i),
             s=StringFormat("TPS_%d",i);
      if(ObjectFind(0,b)==-1) ObjectCreate(0,b,OBJ_HLINE,0,0,TPLevels[i]);
      if(ObjectFind(0,s)==-1) ObjectCreate(0,s,OBJ_HLINE,0,0,TPLevels[i+TargetCount]);
   }
}
void ManageTakeProfits()
{
   if(!PositionSelect(Sym)) return;

   ulong  ticket = PositionGetInteger(POSITION_TICKET);
   long   type   = PositionGetInteger(POSITION_TYPE);
   double price  = (type==POSITION_TYPE_BUY
                   ? SymbolInfoDouble(Sym,SYMBOL_BID)
                   : SymbolInfoDouble(Sym,SYMBOL_ASK));

   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double volume    = PositionGetDouble(POSITION_VOLUME);

   // ---- TP1 logic. Partial close. SL unchanged
   if(!TPTrig[1])
   {
      bool hit1 = (type==POSITION_TYPE_BUY  && price>=TPLevels[1]) ||
                  (type==POSITION_TYPE_SELL && price<=TPLevels[1+TargetCount]);

      if(hit1)
      {
         trade.PositionClosePartial(ticket, volume*0.5);
         TPTrig[1]=true;
         Print("TP1 hit. Half position closed. SL unchanged.");
         return;
      }
   }

   // ---- TP2 logic. Move SL to TP1
   if(TPTrig[1] && !TPTrig[2])
   {
      bool hit2 = (type==POSITION_TYPE_BUY  && price>=TPLevels[2]) ||
                  (type==POSITION_TYPE_SELL && price<=TPLevels[2+TargetCount]);

      if(hit2)
      {
         double newSL = (type==POSITION_TYPE_BUY
                        ? TPLevels[1]
                        : TPLevels[1+TargetCount]);

         trade.PositionModify(ticket,newSL,0);
         TPTrig[2]=true;
         Print("TP2 hit. SL moved to TP1.");
         return;
      }
   }

   // ---- TP3 logic. Close remaining position
   if(TPTrig[2] && !TPTrig[3])
   {
      bool hit3 = (type==POSITION_TYPE_BUY  && price>=TPLevels[3]) ||
                  (type==POSITION_TYPE_SELL && price<=TPLevels[3+TargetCount]);

      if(hit3)
      {
         trade.PositionClose(ticket);
         TPTrig[3]=true;
         Print("TP3 hit. Position fully closed.");
         return;
      }
   }
}
void BackfillNYRange()
{
   NYHigh = -DBL_MAX;
   NYLow  = DBL_MAX;
   NYActive = false;

   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);

   datetime dayStart = StringToTime(
      StringFormat("%04d.%02d.%02d 00:00", dt.year, dt.mon, dt.day)
   );

   datetime nyStart = NewYorkOpen;

   // Before New York session
   if(now < nyStart)
      return;

   NYActive = true;

   int startBar = iBarShift(Sym, PERIOD_M1, nyStart, false);
   int endBar   = iBarShift(Sym, PERIOD_M1, now,     false);

   if(startBar < 0 || endBar < 0)
      return;

   for(int i = startBar; i >= endBar; i--)
   {
      double hi = iHigh(Sym, PERIOD_M1, i);
      double lo = iLow (Sym, PERIOD_M1, i);

      if(hi > NYHigh) NYHigh = hi;
      if(lo < NYLow)  NYLow  = lo;
   }

   PrintFormat(
      "NY backfilled. High=%.5f Low=%.5f",
      NYHigh, NYLow
   );
}


void DrawSessionSeparator(datetime t,color c,string p)
{
   string nm=p+TimeToString(t,TIME_DATE|TIME_MINUTES);
   if(ObjectFind(0,nm)==-1)
   {
      ObjectCreate(0,nm,OBJ_VLINE,0,t,0);
      ObjectSetInteger(0,nm,OBJPROP_COLOR,c);
      ObjectSetInteger(0,nm,OBJPROP_WIDTH,2);
   }
}
//+------------------------------------------------------------------+
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

//â€•â€•â€•â€•â€•â€•â€•â€•â€•â€• Inputs â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•
input string  TradeSymbol       = "";       // "" = current chart symbol
input double  LotSize           = 0.10;     // lots per trade
input int     Slippage          = 5;        // slippage in points
input int     MagicNumber       = 10101;    // EA magic number
input int     AsiaThresholdPips = 40;       // skip if Asia > this
input int     TargetCount       = 10;       // TP steps per side
input string  ExcludedDates     = "";       // back-test: "YYYY.MM.DD,..."

//â€•â€•â€•â€•â€•â€• Globals & State â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•â€•
CTrade    trade;
string    Sym;
bool SessionPrinted = false;
string TradeBlockReason = "None";


// pending-stop tickets we placed
ulong     BuyTicket       = 0;
ulong     SellTicket      = 0;

bool      NO_TRADE_TODAY  = false;  // blocked by CSV
bool      DoNotTradeDay   = false;  // Asia-too-big or manual
bool      LondonClosed    = false;  // have we run the 19:00 cleanup?
bool      DailyResetDone  = false;
int       lastResetDate   = 0;      // YYYYMMDD

double    AsiaHigh = -DBL_MAX, AsiaLow = DBL_MAX;
double    NTZHigh  = -DBL_MAX, NTZLow  = DBL_MAX, NTZRange = 0.0;

double    TPLevels[21];

// Model 2 progress is direction-specific because no-OCO allows the opposite
// pending stop to remain active after the first fill.
bool      BuyTP1Done=false,  BuyTP2Done=false,  BuyTP3Done=false;
bool      SellTP1Done=false, SellTP2Done=false, SellTP3Done=false;

datetime  frankOpen      = 0;
bool      OrdersPlaced   = false;
bool      NTZDefined     = false;
bool      NTZLocked      = false;
bool      PositionOpened = false;
datetime LastHeartbeat = 0;
int       lastHour       = -1;
datetime  LastM1ClosedBar = 0;
bool      SessionSchedulePrinted = false;

// object names
#define PREF_ASIAN     "SessAsian"
#define PREF_FRANK     "SessFrank"
#define PREF_LON       "SessLondon"
#define PREF_NY        "SessNY"
#define OBJ_HIGH       "NTZ_High"
#define OBJ_LOW        "NTZ_Low"
#define OBJ_INFO       "NTZ_Info"
#define OBJ_RANGE      "Asia_NTZ_Range"
#define OBJ_STATUS     "NTZ_Status"
#define OBJ_STATUS_BG  "NTZ_Status_BG"

void DrawSessionSeparator(datetime t,color c,string p);

// Strategy-session timestamps, stored in broker-server time.
int BrokerGMTOffset=0;

#define NAIROBI_GMT_OFFSET (3*3600)
#define FRANKFURT_OPEN_HOUR 8
#define LONDON_OPEN_HOUR    8
#define NEWYORK_OPEN_HOUR   8
#define LONDON_CLOSE_HOUR   16

datetime AsiaStart;
datetime FrankfurtOpen;
datetime LondonOpen;
datetime NewYorkOpen;
datetime LondonClose;

//+------------------------------------------------------------------+
//| CSV blocker: skip on NFP, FOMC, ECB, Fed, Retail Sales, Holiday  |
//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
//| Log every CSV event for today into Journal                      |
//+------------------------------------------------------------------+


//+------------------------------------------------------------------+
//| Clear all daily objects except the bottom-range label           |
//+------------------------------------------------------------------+
void ClearDailyLines()
{
   ObjectDelete(0,OBJ_HIGH);
   ObjectDelete(0,OBJ_LOW);
   ObjectDelete(0,OBJ_INFO);
   ObjectDelete(0, "NTZ_Box");
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
//| Model 2 ownership helpers                                       |
//+------------------------------------------------------------------+
bool IsOurSelectedOrder()
{
   if(OrderGetString(ORDER_SYMBOL)!=Sym)
      return false;
   if((int)OrderGetInteger(ORDER_MAGIC)!=MagicNumber)
      return false;

   ENUM_ORDER_TYPE type=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
   return (type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_SELL_STOP);
}

bool IsOurSelectedPosition()
{
   if(PositionGetString(POSITION_SYMBOL)!=Sym)
      return false;
   if((int)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)
      return false;

   long type=PositionGetInteger(POSITION_TYPE);
   return (type==POSITION_TYPE_BUY || type==POSITION_TYPE_SELL);
}

bool SelectManagedPosition(ulong &ticket,long &type)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong candidate=PositionGetTicket(i);
      if(candidate>0 && IsOurSelectedPosition())
      {
         ticket=candidate;
         type=PositionGetInteger(POSITION_TYPE);
         return true;
      }
   }
   ticket=0;
   type=-1;
   return false;
}

int ManagedPositionCount()
{
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && IsOurSelectedPosition())
         count++;
   }
   return count;
}

bool HasManagedPosition()
{
   ulong ticket;
   long type;
   return SelectManagedPosition(ticket,type);
}

//+------------------------------------------------------------------+
//| Cancel only Model 2 pending stops                                |
//+------------------------------------------------------------------+
void CancelPendingOrders()
{
   int total=OrdersTotal();
   for(int i=total-1;i>=0;i--)
   {
      ulong tck=OrderGetTicket(i);
      if(tck>0 && IsOurSelectedOrder())
      {
         if(!trade.OrderDelete(tck))
            PrintFormat("Pending-order delete failed | Ticket: %I64u | Retcode: %u | %s",
                        tck,trade.ResultRetcode(),trade.ResultRetcodeDescription());
      }
   }
   BuyTicket=0;
   SellTicket=0;
   OrdersPlaced=false;
   Print("Model 2 pending STOP orders cleared");
}

bool HasPendingStops()
{
   int total = OrdersTotal();

   for(int i=0;i<total;i++)
   {
      ulong ticket = OrderGetTicket(i);

      if(ticket>0 && IsOurSelectedOrder())
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
void InitSessionSeparatorsAndNTZ()
{
   datetime now = TimeCurrent();

   // These use the same authoritative broker timestamps as the session engine.
   // They deliberately run independently of the news/trading blocker.
   if(now >= AsiaStart)
   {
      DrawSessionSeparator(AsiaStart, clrYellow, PREF_ASIAN);
      if(lastHour < 1) lastHour = 1;
   }
   if(now >= FrankfurtOpen)
   {
      DrawSessionSeparator(FrankfurtOpen, clrBlue, PREF_FRANK);
      if(lastHour < 2) lastHour = 2;
   }
   if(now >= LondonOpen)
   {
      DrawSessionSeparator(LondonOpen, clrGreen, PREF_LON);
      if(lastHour < 3) lastHour = 3;
   }
   if(now >= NewYorkOpen)
   {
      DrawSessionSeparator(NewYorkOpen, clrRed, PREF_NY);
      if(lastHour < 4) lastHour = 4;
   }
}

//+------------------------------------------------------------------+
//| DST-safe session engine                                          |
//+------------------------------------------------------------------+

int NormalizeOffsetToMinute(const int rawOffset)
{
   // TimeCurrent() and TimeGMT() are sampled separately.  Do not let their
   // second-level skew turn a UTC+2 server into UTC+01:59:59.
   if(rawOffset>=0)
      return ((rawOffset+30)/60)*60;
   return -(((-rawOffset+30)/60)*60);
}

datetime MakeCalendarTime(const int year,const int month,const int day,
                          const int hour=0,const int minute=0)
{
   MqlDateTime value={};
   value.year=year;
   value.mon=month;
   value.day=day;
   value.hour=hour;
   value.min=minute;
   value.sec=0;
   return StructToTime(value);
}

int DaysInMonth(const int year,const int month)
{
   if(month==4 || month==6 || month==9 || month==11)
      return 30;
   if(month==2)
      return ((year%4==0 && (year%100!=0 || year%400==0)) ? 29 : 28);
   return 31;
}

int Weekday(const int year,const int month,const int day)
{
   MqlDateTime value;
   TimeToStruct(MakeCalendarTime(year,month,day),value);
   return value.day_of_week;
}

int LastSunday(const int year,const int month)
{
   int day=DaysInMonth(year,month);
   return day-Weekday(year,month,day);
}

int NthSunday(const int year,const int month,const int nth)
{
   int firstSunday=1+((7-Weekday(year,month,1))%7);
   return firstSunday+(nth-1)*7;
}

bool IsFrankfurtDST(const int year,const int month,const int day,const int hour)
{
   if(month<3 || month>10)
      return false;
   if(month>3 && month<10)
      return true;

   if(month==3)
   {
      int start=LastSunday(year,3);
      return (day>start || (day==start && hour>=2));
   }

   int end=LastSunday(year,10);
   return (day<end || (day==end && hour<3));
}

bool IsLondonDST(const int year,const int month,const int day,const int hour)
{
   if(month<3 || month>10)
      return false;
   if(month>3 && month<10)
      return true;

   if(month==3)
   {
      int start=LastSunday(year,3);
      return (day>start || (day==start && hour>=1));
   }

   int end=LastSunday(year,10);
   return (day<end || (day==end && hour<2));
}

bool IsNewYorkDST(const int year,const int month,const int day,const int hour)
{
   if(month<3 || month>11)
      return false;
   if(month>3 && month<11)
      return true;
   if(month==3)
   {
      int start=NthSunday(year,3,2);
      return (day>start || (day==start && hour>=2));
   }

   int end=NthSunday(year,11,1);
   return (day<end || (day==end && hour<2));
}

datetime UTCToBroker(const datetime utcTime)
{
   return utcTime+BrokerGMTOffset;
}

datetime BrokerToNairobi(const datetime brokerTime)
{
   return brokerTime-BrokerGMTOffset+NAIROBI_GMT_OFFSET;
}

datetime NairobiTimeToBroker(const int year,const int month,const int day,
                             const int hour,const int minute=0)
{
   return UTCToBroker(MakeCalendarTime(year,month,day,hour,minute)-NAIROBI_GMT_OFFSET);
}

datetime LocalSessionTimeToBroker(const int year,const int month,const int day,
                                  const int hour,const int minute,const int utcOffset)
{
   return UTCToBroker(MakeCalendarTime(year,month,day,hour,minute)-utcOffset);
}

int NairobiDateKey()
{
   MqlDateTime nairobi;
   TimeToStruct(TimeGMT()+NAIROBI_GMT_OFFSET,nairobi);
   return nairobi.year*10000+nairobi.mon*100+nairobi.day;
}

void UpdateSessionTimes()
{
   BrokerGMTOffset=NormalizeOffsetToMinute((int)(TimeCurrent()-TimeGMT()));

   // Use Nairobi's calendar date as the strategy day.  The definitions below
   // are market-local, converted market/local -> UTC -> broker-server time.
   MqlDateTime nairobi;
   TimeToStruct(TimeGMT()+NAIROBI_GMT_OFFSET,nairobi);
   int year=nairobi.year, month=nairobi.mon, day=nairobi.day;

   AsiaStart=NairobiTimeToBroker(year,month,day,2); // Nairobi has no DST.

   int frankfurtOffset=IsFrankfurtDST(year,month,day,FRANKFURT_OPEN_HOUR) ? 2*3600 : 1*3600;
   int londonOpenOffset=IsLondonDST(year,month,day,LONDON_OPEN_HOUR) ? 1*3600 : 0;
   int londonCloseOffset=IsLondonDST(year,month,day,LONDON_CLOSE_HOUR) ? 1*3600 : 0;
   int newYorkOffset=IsNewYorkDST(year,month,day,NEWYORK_OPEN_HOUR) ? -4*3600 : -5*3600;

   FrankfurtOpen=LocalSessionTimeToBroker(year,month,day,FRANKFURT_OPEN_HOUR,0,frankfurtOffset);
   LondonOpen=LocalSessionTimeToBroker(year,month,day,LONDON_OPEN_HOUR,0,londonOpenOffset);
   NewYorkOpen=LocalSessionTimeToBroker(year,month,day,NEWYORK_OPEN_HOUR,0,newYorkOffset);
   LondonClose=LocalSessionTimeToBroker(year,month,day,LONDON_CLOSE_HOUR,0,londonCloseOffset);
}

string FormatUTCOffset(const int offset)
{
   int absolute=MathAbs(offset);
   string sign=(offset>=0 ? "+" : "-");
   return StringFormat("UTC%s%02d:%02d",sign,absolute/3600,(absolute%3600)/60);
}

int OnInit()
{
   Sym = StringLen(TradeSymbol)>0 ? TradeSymbol : _Symbol;
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Slippage);
   trade.SetAsyncMode(false);

   UpdateSessionTimes();
   EventSetTimer(60);
   EnsureRangeLabel();

   // Initialization is recovery, not a new-day cleanup. Existing Model 2
   // orders and positions must survive chart changes, recompiles and restarts.
   lastResetDate=NairobiDateKey();
   NO_TRADE_TODAY=false;
   DoNotTradeDay =false;
   LondonClosed  =false;
   frankOpen     =0;
   OrdersPlaced  =false;
   NTZDefined    =false;
   NTZLocked     =false;
   PositionOpened=false;
   lastHour      =-1;
   
   AsiaHigh=-DBL_MAX;
   AsiaLow=DBL_MAX;
   NTZHigh=-DBL_MAX;
   NTZLow=DBL_MAX;
   NTZRange=0.0;
   LastM1ClosedBar=0;
   SessionSchedulePrinted=false;

   ClearDailyLines();
   EnsureRangeLabel();
   InitSessionSeparatorsAndNTZ();
   RebuildSessionState();
   RestartRecovery();
   PrintDailySessionSchedule();

   // News blocking never prevents visuals or trade-state recovery.
   FetchNewsFromFF();
   if(NO_TRADE_TODAY) Print("Ã°Å¸â€ºâ€˜ Halted for CSV blocker");

   return(INIT_SUCCEEDED);
}


void InitAsiaRange()
{
   datetime endTime=TimeCurrent();
   if(endTime>FrankfurtOpen)
      endTime=FrankfurtOpen;

   datetime latestBar;
   if(!RebuildM1Range(AsiaStart,endTime,AsiaHigh,AsiaLow,latestBar))
      Print("WARNING Unable to initialize the Asian M1 range yet.");
}

//+------------------------------------------------------------------+
//| M1 range reconstruction                                         |
//+------------------------------------------------------------------+
void ResetTPProgress()
{
   BuyTP1Done=false;  BuyTP2Done=false;  BuyTP3Done=false;
   SellTP1Done=false; SellTP2Done=false; SellTP3Done=false;
}

datetime LatestClosedM1Bar()
{
   return iTime(Sym,PERIOD_M1,1);
}

bool RebuildM1Range(const datetime fromTime,const datetime requestedEnd,
                    double &rangeHigh,double &rangeLow,datetime &latestIncluded)
{
   rangeHigh=-DBL_MAX;
   rangeLow=DBL_MAX;
   latestIncluded=0;
   if(requestedEnd<=fromTime || !EnsureM1History(fromTime))
      return false;

   datetime lastClosed=LatestClosedM1Bar();
   if(lastClosed<=0)
      return false;

   datetime endExclusive=requestedEnd;
   datetime lastClosedEnd=lastClosed+60;
   if(endExclusive>lastClosedEnd)
      endExclusive=lastClosedEnd;
   if(endExclusive<=fromTime)
      return false;

   int startBar=iBarShift(Sym,PERIOD_M1,fromTime,false);
   int endBar=iBarShift(Sym,PERIOD_M1,endExclusive-1,false);
   if(startBar<0 || endBar<0)
      return false;
   if(startBar<endBar)
   {
      int temporary=startBar;
      startBar=endBar;
      endBar=temporary;
   }

   for(int i=startBar;i>=endBar;i--)
   {
      datetime barTime=iTime(Sym,PERIOD_M1,i);
      if(barTime<fromTime || barTime>=endExclusive)
         continue;
      double high=iHigh(Sym,PERIOD_M1,i);
      double low=iLow(Sym,PERIOD_M1,i);
      if(high>rangeHigh) rangeHigh=high;
      if(low<rangeLow) rangeLow=low;
      if(barTime>latestIncluded) latestIncluded=barTime;
   }
   return (rangeHigh>-DBL_MAX && rangeLow<DBL_MAX && rangeHigh>=rangeLow);
}

void ApplyAsiaThreshold()
{
   if(AsiaHigh<=AsiaLow)
      return;
   double asiaPips=(AsiaHigh-AsiaLow)/(_Point*10.0);
   if(asiaPips>AsiaThresholdPips)
   {
      DoNotTradeDay=true;
      PrintFormat("Asia %.1f pips > %d halt",asiaPips,AsiaThresholdPips);
   }
}

void PrintDailySessionSchedule()
{
   if(SessionSchedulePrinted)
      return;
   Print("===== SESSION SCHEDULE =====");
   Print("Broker UTC offset: ",FormatUTCOffset(BrokerGMTOffset));
   Print("Nairobi UTC offset: UTC+03:00");
   PrintFormat("Asia: Nairobi %s | Broker %s",TimeToString(BrokerToNairobi(AsiaStart),TIME_MINUTES),TimeToString(AsiaStart,TIME_MINUTES));
   PrintFormat("Frankfurt: Nairobi %s | Broker %s",TimeToString(BrokerToNairobi(FrankfurtOpen),TIME_MINUTES),TimeToString(FrankfurtOpen,TIME_MINUTES));
   PrintFormat("London: Nairobi %s | Broker %s",TimeToString(BrokerToNairobi(LondonOpen),TIME_MINUTES),TimeToString(LondonOpen,TIME_MINUTES));
   PrintFormat("New York: Nairobi %s | Broker %s",TimeToString(BrokerToNairobi(NewYorkOpen),TIME_MINUTES),TimeToString(NewYorkOpen,TIME_MINUTES));
   PrintFormat("London Close: Nairobi %s | Broker %s",TimeToString(BrokerToNairobi(LondonClose),TIME_MINUTES),TimeToString(LondonClose,TIME_MINUTES));
   PrintFormat("Placement: Nairobi %s | Broker %s",TimeToString(BrokerToNairobi(LondonOpen-180),TIME_MINUTES),TimeToString(LondonOpen-180,TIME_MINUTES));
   PrintFormat("Timeout: Nairobi %s | Broker %s",TimeToString(BrokerToNairobi(LondonOpen+3*3600),TIME_MINUTES),TimeToString(LondonOpen+3*3600,TIME_MINUTES));
   Print("============================");
   SessionSchedulePrinted=true;
}

//+------------------------------------------------------------------+
//| Rebuild session ranges if EA starts mid-day                     |
//+------------------------------------------------------------------+
void RebuildSessionState()
{
   datetime now=TimeCurrent();
   datetime latestBar=0;

   if(now>=AsiaStart)
   {
      datetime asiaEnd=(now<FrankfurtOpen ? now : FrankfurtOpen);
      if(RebuildM1Range(AsiaStart,asiaEnd,AsiaHigh,AsiaLow,latestBar))
      {
         LastM1ClosedBar=latestBar;
         if(now>=FrankfurtOpen)
            ApplyAsiaThreshold();
      }
   }

   if(now>=FrankfurtOpen)
      frankOpen=FrankfurtOpen;

   if(now>=FrankfurtOpen && now<LondonOpen)
   {
      double rebuiltHigh,rebuiltLow;
      if(RebuildM1Range(FrankfurtOpen,now,rebuiltHigh,rebuiltLow,latestBar))
      {
         NTZHigh=rebuiltHigh;
         NTZLow=rebuiltLow;
         NTZRange=NTZHigh-NTZLow;
         LastM1ClosedBar=latestBar;
      }
      return;
   }

   if(now>=LondonOpen)
   {
      double rebuiltHigh,rebuiltLow;
      if(!RebuildM1Range(FrankfurtOpen,LondonOpen,rebuiltHigh,rebuiltLow,latestBar))
      {
         Print("ERROR Cannot rebuild final NTZ range from M1 history.");
         return;
      }
      NTZHigh=rebuiltHigh;
      NTZLow=rebuiltLow;
      NTZRange=NTZHigh-NTZLow;
      NTZDefined=true;
      NTZLocked=true;
      frankOpen=FrankfurtOpen;
      LastM1ClosedBar=latestBar;

      double ntzPips=NTZRange/(_Point*10.0);
      if(ntzPips<10.0 || ntzPips>30.0)
      {
         DoNotTradeDay=true;
         PrintFormat("NTZ %.1f pips outside [10-30]. No trade today.",ntzPips);
      }
      SetupTPLevels();
      DrawNTZBox();
      DrawTPLevels();
      PrintSessionSummary();
      if(HasPendingStops())
         OrdersPlaced=true;
   }
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ClearDailyLines();
   ObjectDelete(0,OBJ_RANGE);
   ObjectDelete(0,OBJ_STATUS);
   ObjectDelete(0,OBJ_STATUS_BG);
   ObjectDelete(0,"NTZ_BG");
   for(int i=0;i<25;i++)
      ObjectDelete(0,"NTZ_LINE_"+IntegerToString(i));
}

//+------------------------------------------------------------------+
//| Fetch Forex Factory News                                         |
//+------------------------------------------------------------------+
bool ParseFFIso8601ToBroker(const string feedTime,const int brokerOffset,
                            datetime &utcTime,datetime &brokerTime)
{
   // Forex Factory timestamps are ISO-8601: YYYY-MM-DDTHH:MM:SS+/-HH:MM
   if(StringLen(feedTime)<20)
      return false;

   string base=StringSubstr(feedTime,0,19);
   StringReplace(base,"-",".");
   StringReplace(base,"T"," ");

   datetime localTime=StringToTime(base);
   if(localTime==0)
      return false;

   string tz=StringSubstr(feedTime,19);
   int tzOffset=0;
   if(tz!="Z")
   {
      if(StringLen(tz)<6 ||
         (StringSubstr(tz,0,1)!="+" && StringSubstr(tz,0,1)!="-") ||
         StringSubstr(tz,3,1)!=":")
         return false;

      int sign=(StringSubstr(tz,0,1)=="-" ? -1 : 1);
      int hours=(int)StringToInteger(StringSubstr(tz,1,2));
      int mins =(int)StringToInteger(StringSubstr(tz,4,2));
      if(hours>23 || mins>59)
         return false;

      tzOffset=sign*(hours*3600+mins*60);
   }

   utcTime=localTime-tzOffset;
   brokerTime=utcTime+brokerOffset;
   return true;
}

void FetchNewsFromFF()
{
   NO_TRADE_TODAY   = false;
   TradeBlockReason = "None";

   string url = "https://nfs.faireconomy.media/ff_calendar_thisweek.json";
   uchar post[], result[];
   string headers;

   int res = WebRequest("GET", url, "", "", 10000, post, 0, result, headers);
   if(res == -1)
   {
      PrintFormat("WebRequest failed: %d", GetLastError());
      return;
   }

   string json = CharArrayToString(result);

   datetime nowBroker = TimeCurrent();
   MqlDateTime td;
   TimeToStruct(nowBroker, td);
   int todayKey = td.year*10000 + td.mon*100 + td.day;

   // Reuse the normalized execution-clock offset used by the session engine.
   int brokerOffset=BrokerGMTOffset;

   string blockers[] =
   {
      "Non-Farm",
      "Interest Rate",
      "Rate Decision",
      "Monetary Policy",
      "Policy Statement",
      "FOMC",
      "Fed",
      "ECB",
      "Central Bank",
      "Bank Holiday",
      "Holiday"
   };

   bool foundAny = false;

   string events[];
   int n = StringSplit(json, '{', events);

   for(int i = 0; i < n; i++)
   {
      string ev = events[i];

      int dpos = StringFind(ev, "\"date\":\"");
      int tpos = StringFind(ev, "\"title\":\"");
      int ipos = StringFind(ev, "\"impact\":\"");
      int cpos = StringFind(ev, "\"country\":\"");

      if(dpos < 0 || tpos < 0 || ipos < 0)
         continue;

      // ---- IMPACT ----
      string impact = StringSubstr(ev, ipos + 10);
      int iend = StringFind(impact, "\"");
      if(iend > 0)
         impact = StringSubstr(impact, 0, iend);

      // ---- TITLE / COUNTRY ----
      string title = StringSubstr(ev, tpos + 9);
      int endq = StringFind(title, "\"");
      if(endq > 0)
         title = StringSubstr(title, 0, endq);

      string country="";
      if(cpos >= 0)
      {
         country = StringSubstr(ev, cpos + 11);
         endq = StringFind(country, "\"");
         if(endq > 0)
            country = StringSubstr(country, 0, endq);
      }

      // ---- COMPLETE ISO-8601 TIME CONVERSION ----
      string fullDate=StringSubstr(ev,dpos+8);
      endq=StringFind(fullDate,"\"");
      if(endq <= 0)
         continue;
      fullDate=StringSubstr(fullDate,0,endq);

      datetime evUTC,evBroker;
      if(!ParseFFIso8601ToBroker(fullDate,brokerOffset,evUTC,evBroker))
      {
         PrintFormat("Skipping FF event with invalid ISO time: %s | %s",title,fullDate);
         continue;
      }

      MqlDateTime evd;
      TimeToStruct(evBroker, evd);
      int evKey = evd.year*10000 + evd.mon*100 + evd.day;

      bool isHoliday=(StringFind(title,"Bank Holiday")>=0 ||
                      StringFind(title,"Holiday")>=0);
      if(isHoliday)
      {
         bool isToday=(evKey==todayKey);
         PrintFormat("HOLIDAY EVENT | %s | %s | Feed: %s | UTC: %s | Broker: %s | Current broker date: %s | %s",
                     country,title,fullDate,
                     TimeToString(evUTC,TIME_DATE|TIME_MINUTES),
                     TimeToString(evBroker,TIME_DATE|TIME_MINUTES),
                     TimeToString(nowBroker,TIME_DATE),
                     (isToday ? "BLOCK" : "SKIP: not today"));

         if(!isToday)
            continue;

         PrintFormat("HOLIDAY BLOCKER | %s | %s | Broker: %s",
                     country,title,TimeToString(evBroker,TIME_DATE|TIME_MINUTES));
         foundAny=true;
         TradeBlockReason="Bank Holiday";
         break;
      }

      if(evKey != todayKey)
         continue;

      // ---- STRATEGY MATCH ----
      for(int j = 0; j < ArraySize(blockers); j++)
      {
         if(StringFind(title, blockers[j]) >= 0)
         {
            // ---- HIGH IMPACT BLOCK ----
            if(impact == "High")
            {
               PrintFormat("HIGH IMPACT BLOCKER: %s | %s",
                           title,
                           TimeToString(evBroker, TIME_DATE|TIME_MINUTES));

               foundAny = true;
               TradeBlockReason = "High Impact News";
               break;
            }
         }
      }

      if(foundAny)
         break;
   }

   // ---- FINAL DECISION ----
   if(foundAny)
   {
      NO_TRADE_TODAY = true;

      Print("Trading disabled today");
      Print("Reason: ", TradeBlockReason);
   }
   else
   {
      NO_TRADE_TODAY   = false;
      TradeBlockReason = "None";

      Print("No HIGH impact strategic blockers today");
   }
}

//+------------------------------------------------------------------+
//| Ensure M1 History Loaded                                         |
//+------------------------------------------------------------------+
bool EnsureM1History(datetime fromTime)
{
   int bars = iBars(Sym, PERIOD_M1);

   if(bars <= 0)
   {
      Print("WARNING No M1 bars available");
      return false;
   }

   int shift = iBarShift(Sym, PERIOD_M1, fromTime, false);

   if(shift == -1)
   {
      Print("Loading M1 history...");

      datetime now = TimeCurrent();

      MqlRates rates[];
      ArraySetAsSeries(rates,true);

      int copied = CopyRates(Sym, PERIOD_M1, fromTime, now, rates);

      if(copied <= 0)
      {
         Print("ERROR Failed to load M1 history");
         return false;
      }

      Sleep(200);

      shift = iBarShift(Sym, PERIOD_M1, fromTime, false);

      if(shift == -1)
      {
         Print("ERROR History still unavailable");
         return false;
      }

      Print("M1 history loaded successfully");
   }

   return true;
}

//+------------------------------------------------------------------+
//| Session Integrity Check                                          |
//+------------------------------------------------------------------+
void ValidateSessionState()
{
   static datetime lastCheck = 0;
   if(TimeCurrent() - lastCheck < 60)
      return;
   lastCheck = TimeCurrent();

   datetime now=TimeCurrent();
   bool asiaInvalid=(now>=AsiaStart && (AsiaHigh==-DBL_MAX || AsiaLow==DBL_MAX || AsiaHigh<AsiaLow));
   bool ntzInvalid=(now>=LondonOpen && (NTZHigh==-DBL_MAX || NTZLow==DBL_MAX || NTZHigh<NTZLow));
   if(asiaInvalid || ntzInvalid)
   {
      Print("WARNING Session state invalid. Rebuilding from M1 history...");
      RebuildSessionState();
   }
}


//+------------------------------------------------------------------+
//| Debug Status Panel                                               |
//+------------------------------------------------------------------+
void UpdateStatusPanel()
{
   const int x=10;
   const int y=20;
   const int line=13;
   double pip=_Point*10.0;
   double asiaP=(AsiaHigh>AsiaLow ? (AsiaHigh-AsiaLow)/pip : 0.0);
   double ntzP=(NTZRange>0.0 ? NTZRange/pip : 0.0);
   datetime now=TimeCurrent();

   string asiaStatus=(now<AsiaStart ? "WAITING" : (now<FrankfurtOpen ? "BUILDING" : "COMPLETE"));
   string ntzStatus=(now<FrankfurtOpen ? "WAITING" : (now<LondonOpen ? "BUILDING" : "COMPLETE"));
   string londonStatus=(now<LondonOpen ? "WAITING" : "OPENED");
   string newYorkStatus=(now<NewYorkOpen ? "WAITING" : "OPENED");
   string trading=(NO_TRADE_TODAY || DoNotTradeDay ? "DISABLED" : "ENABLED");
   string tradeDay=(NO_TRADE_TODAY || DoNotTradeDay ? "NO" : "YES");
   string orderStatus=(HasPendingStops() || OrdersPlaced ? "PLACED" : "NOT PLACED");
   int symbolDigits=(int)SymbolInfoInteger(Sym,SYMBOL_DIGITS);

   ulong ticket;
   long type;
   bool hasPosition=SelectManagedPosition(ticket,type);
   int positionCount=ManagedPositionCount();
   string direction="-",volume="-",slText="-",tpText="-",stageText="-";
   if(hasPosition)
   {
      PositionSelectByTicket(ticket);
      bool buy=(type==POSITION_TYPE_BUY);
      double tp1=TargetLevel(type,1);
      double tp2=TargetLevel(type,2);
      double tp3=TargetLevel(type,3);
      direction=(buy ? "BUY" : "SELL");
      volume=DoubleToString(PositionGetDouble(POSITION_VOLUME),2);
      slText=DoubleToString(ExpectedOriginalSL(type),symbolDigits)+" / "+DoubleToString(PositionGetDouble(POSITION_SL),symbolDigits);
      tpText=DoubleToString(tp1,symbolDigits)+" / "+DoubleToString(tp2,symbolDigits)+" / "+DoubleToString(tp3,symbolDigits);
      stageText=StringFormat("TP1 %s  TP2 %s  TP3 %s",
                 (buy ? (BuyTP1Done ? "DONE" : "WAIT") : (SellTP1Done ? "DONE" : "WAIT")),
                 (buy ? (BuyTP2Done ? "DONE" : "WAIT") : (SellTP2Done ? "DONE" : "WAIT")),
                 (buy ? (BuyTP3Done ? "DONE" : "BROKER") : (SellTP3Done ? "DONE" : "BROKER")));
   }

   string lines[30];
   lines[0]="NTZ EA STATUS";
   lines[1]="EA Status: ACTIVE   Trading: "+trading;
   lines[2]="Trade Day: "+tradeDay+"   Reason: "+TradeBlockReason;
   lines[3]="SESSION STATUS";
   lines[4]="Asia: "+asiaStatus+"   Frankfurt/NTZ: "+ntzStatus;
   lines[5]="London: "+londonStatus+"   New York: "+newYorkStatus;
   lines[6]="SESSION TIMES (Nairobi | Broker)";
   lines[7]="Asia: "+TimeToString(BrokerToNairobi(AsiaStart),TIME_MINUTES)+" | "+TimeToString(AsiaStart,TIME_MINUTES);
   lines[8]="Frankfurt: "+TimeToString(BrokerToNairobi(FrankfurtOpen),TIME_MINUTES)+" | "+TimeToString(FrankfurtOpen,TIME_MINUTES);
   lines[9]="London: "+TimeToString(BrokerToNairobi(LondonOpen),TIME_MINUTES)+" | "+TimeToString(LondonOpen,TIME_MINUTES);
   lines[10]="New York: "+TimeToString(BrokerToNairobi(NewYorkOpen),TIME_MINUTES)+" | "+TimeToString(NewYorkOpen,TIME_MINUTES);
   lines[11]="London close: "+TimeToString(BrokerToNairobi(LondonClose),TIME_MINUTES)+" | "+TimeToString(LondonClose,TIME_MINUTES);
   lines[12]="Offsets: Broker "+FormatUTCOffset(BrokerGMTOffset)+"  Nairobi UTC+03:00";
   lines[13]="PLACEMENT";
   lines[14]="Placement: "+TimeToString(BrokerToNairobi(LondonOpen-180),TIME_MINUTES)+" | "+TimeToString(LondonOpen-180,TIME_MINUTES);
   lines[15]="Timeout: "+TimeToString(BrokerToNairobi(LondonOpen+3*3600),TIME_MINUTES)+" | "+TimeToString(LondonOpen+3*3600,TIME_MINUTES);
   lines[16]="RANGES";
   lines[17]="Asia Range: "+DoubleToString(asiaP,1)+" pips   NTZ Range: "+DoubleToString(ntzP,1)+" pips";
   lines[18]="ORDERS";
   lines[19]="Orders: "+orderStatus+"   Position: "+(hasPosition ? "OPEN" : "NONE")+(positionCount>1 ? " (MULTIPLE)" : "");
   lines[20]="MODEL 2 MANAGEMENT";
   lines[21]="Direction: "+direction+"   Volume: "+volume;
   lines[22]="Original SL / Current SL: "+slText;
   lines[23]="TP1 / TP2 / TP3: "+tpText;
   lines[24]=stageText;
   int totalLines=25;
   int panelHeight=(totalLines*line)+14;

   if(ObjectFind(0,"NTZ_BG")==-1)
   {
      ObjectCreate(0,"NTZ_BG",OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,"NTZ_BG",OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,"NTZ_BG",OBJPROP_XDISTANCE,x);
      ObjectSetInteger(0,"NTZ_BG",OBJPROP_YDISTANCE,y);
      ObjectSetInteger(0,"NTZ_BG",OBJPROP_XSIZE,405);
      ObjectSetInteger(0,"NTZ_BG",OBJPROP_BGCOLOR,clrBlack);
      ObjectSetInteger(0,"NTZ_BG",OBJPROP_BORDER_COLOR,clrAqua);
   }

   ObjectSetInteger(0,"NTZ_BG",OBJPROP_YSIZE,panelHeight);

   for(int i=0;i<totalLines;i++)
   {
      string name="NTZ_LINE_"+IntegerToString(i);

      if(ObjectFind(0,name)==-1)
      {
         ObjectCreate(0,name,OBJ_LABEL,0,0,0);
         ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(0,name,OBJPROP_COLOR,clrWhite);
         ObjectSetInteger(0,name,OBJPROP_FONTSIZE,8);
         ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
      }

      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x+10);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y+5+(i*line));
      ObjectSetString(0,name,OBJPROP_TEXT,lines[i]);
   }
}


//+------------------------------------------------------------------+
//| EA Watchdog                                                      |
//+------------------------------------------------------------------+
void WatchdogMonitor()
{
   static datetime lastCheck = 0;
   if(TimeCurrent() - lastCheck < 60)
      return;
   lastCheck = TimeCurrent();
   datetime now=TimeCurrent();
   lastCheck=now;

   // A flat high is normal. Only actual M1 data staleness or invalid state is
   // a recovery condition.
   datetime latestClosed=LatestClosedM1Bar();
   bool activeRange=(now>=AsiaStart && now<LondonOpen);
   bool staleData=(activeRange && (latestClosed<=0 || now-latestClosed>180));
   bool invalidRange=(now>=AsiaStart && now<FrankfurtOpen &&
                      (AsiaHigh==-DBL_MAX || AsiaLow==DBL_MAX || AsiaHigh<AsiaLow));
   if(staleData || invalidRange)
   {
      Print("WATCHDOG: M1 session data is stale or invalid. Rebuilding...");
      RebuildSessionState();
   }
   LastHeartbeat=now;
}

void Heartbeat()
{
   static datetime last = 0;

   if(TimeCurrent() - last >= 300)
   {
      Print("EA Heartbeat OK - ", TimeToString(TimeCurrent()));
      last = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| Restart Recovery                                                 |
//+------------------------------------------------------------------+
bool PriceNear(const double left,const double right)
{
   double tickSize=SymbolInfoDouble(Sym,SYMBOL_TRADE_TICK_SIZE);
   double tolerance=MathMax((tickSize>0.0 ? tickSize : _Point)*0.5,_Point*0.5);
   return MathAbs(left-right)<=tolerance;
}

void RecoverTPStateForSelectedPosition(const long type)
{
   if(NTZRange<=0.0)
      return;
   SetupTPLevels();

   bool buy=(type==POSITION_TYPE_BUY);
   double volume=PositionGetDouble(POSITION_VOLUME);
   double sl=PositionGetDouble(POSITION_SL);
   double step=SymbolInfoDouble(Sym,SYMBOL_VOLUME_STEP);
   double tolerance=MathMax(step*0.5,0.00000001);
   bool reduced=(volume<LotSize-tolerance);
   double tp1=TargetLevel(type,1);

   if(buy)
   {
      BuyTP1Done=reduced;
      BuyTP2Done=(reduced && PriceNear(sl,tp1));
      BuyTP3Done=false;
   }
   else
   {
      SellTP1Done=reduced;
      SellTP2Done=(reduced && PriceNear(sl,tp1));
      SellTP3Done=false;
   }
}

void RestartRecovery()
{
   static bool recovered = false;
   if(recovered)
      return;

   ulong ticket;
   long type;
   if(SelectManagedPosition(ticket,type))
   {
      PositionOpened = true;
      for(int i=PositionsTotal()-1;i>=0;i--)
      {
         ulong candidate=PositionGetTicket(i);
         if(candidate>0 && IsOurSelectedPosition())
            RecoverTPStateForSelectedPosition(PositionGetInteger(POSITION_TYPE));
      }
      Print("Recovery: Existing Model 2 position(s) detected");
   }
   if(HasPendingStops())
   {
      OrdersPlaced = true;
      Print("Recovery: Existing Model 2 pending order(s) detected");
   }
   if(NTZHigh != -DBL_MAX && NTZLow != DBL_MAX)
   {
      NTZRange = NTZHigh - NTZLow;
      if(NTZRange > 0)
      {
         SetupTPLevels();
         DrawTPLevels();
         Print("Recovery: TP ladder rebuilt");
         Print("Recovery: TP levels rebuilt without resetting TP progress");
      }
   }
   recovered = true;
}

//+------------------------------------------------------------------+
//| Expert tick handler                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime now=TimeCurrent();
   int today=NairobiDateKey();

   // A genuine strategy-day transition is allowed to clear stale Model 2
   // pending orders. This is deliberately not performed by OnInit().
   if(today!=lastResetDate)
   {
      UpdateSessionTimes();
      lastResetDate=today;
      DailyResetDone = false;
      NO_TRADE_TODAY=false;
      DoNotTradeDay =false;
      LondonClosed  =false;
      frankOpen     =0;
      OrdersPlaced  =false;
      NTZDefined    =false;
      NTZLocked     =false;
      PositionOpened=HasManagedPosition();
      SessionPrinted = false;
      SessionSchedulePrinted=false;
      lastHour      =-1;
      AsiaHigh=-DBL_MAX; AsiaLow=DBL_MAX;
      NTZHigh=-DBL_MAX; NTZLow=DBL_MAX; NTZRange=0.0;
      LastM1ClosedBar=0;
      if(!PositionOpened)
         ResetTPProgress();

      CancelPendingOrders();
      ClearDailyLines();
      EnsureRangeLabel();
      InitSessionSeparatorsAndNTZ();
      PrintDailySessionSchedule();
      FetchNewsFromFF();
      if(NO_TRADE_TODAY) Print("ðŸ›‘ Halted for CSV blocker");

      if(!NO_TRADE_TODAY && StringLen(ExcludedDates)>0)
      {
         string arr[]; int cnt=StringSplit(ExcludedDates,',',arr);
         MqlDateTime nairobiDate;
         TimeToStruct(TimeGMT()+NAIROBI_GMT_OFFSET,nairobiDate);
         for(int i=0;i<cnt;i++)
         {
            datetime ex=StringToTime(arr[i]+" 00:00");
            MqlDateTime ed; TimeToStruct(ex,ed);
            if(ed.year==nairobiDate.year&&ed.mon==nairobiDate.mon&&ed.day==nairobiDate.day)
            {
               DoNotTradeDay=true;
               PrintFormat("â„¹ï¸ Halted for excluded %s",arr[i]);
               break;
            }
         }
      }
   }

   ValidateSessionState();
   WatchdogMonitor();
   Heartbeat();
   RestartRecovery();

   datetime latestClosed=LatestClosedM1Bar();
   if(now<LondonOpen && latestClosed>LastM1ClosedBar)
      RebuildSessionState();
   if(now>=LondonOpen && !NTZLocked)
      RebuildSessionState();

   // London-close forced cleanup is restricted to this EA's magic/symbol.
   if(!DailyResetDone && now>=LondonClose)
   {
      CancelPendingOrders();
      CloseManagedPositions();
      ClearDailyLines();
      NO_TRADE_TODAY  = false;
      DoNotTradeDay   = false;
      frankOpen       = 0;
      OrdersPlaced    = false;
      NTZDefined      = false;
      NTZLocked       = false;
      PositionOpened  = false;
      SessionPrinted  = false;
      lastHour        = -1;
      AsiaHigh = -DBL_MAX;
      AsiaLow  = DBL_MAX;
      NTZHigh  = -DBL_MAX;
      NTZLow   = DBL_MAX;
      NTZRange = 0.0;
      ResetTPProgress();
      LondonClosed   = true;
      DailyResetDone = true;
      Print("London close cleanup + FULL RESET complete");
      UpdateStatusPanel();
      return;
   }

   // Update bottom-center range label.
   {
      uint w=(uint)ChartGetInteger(0,CHART_WIDTH_IN_PIXELS);
      ObjectSetInteger(0,OBJ_RANGE,OBJPROP_XDISTANCE,(int)w/2);
      double pip = SymbolInfoDouble(Sym,SYMBOL_POINT) * 10;
      double aP=(AsiaHigh>AsiaLow? (AsiaHigh-AsiaLow)/pip :0.0);
      double nP=(NTZRange>0 ? NTZRange/pip :0.0);
      string txt = StringFormat("ðŸ“Š Asian Range: %.1f pips\nðŸ“Š NTZ Range: %.1f pips",aP,nP);
      ObjectSetString(0,OBJ_RANGE,OBJPROP_TEXT,txt);
      
      color c = clrWhite;
      if(aP > AsiaThresholdPips) c = clrRed;
      else if(nP >= 10.0 && nP <= 30.0) c = clrLime;
      else if(nP > 0) c = clrOrange;
      ObjectSetInteger(0,OBJ_RANGE,OBJPROP_COLOR,c);
      ObjectSetInteger(0,OBJ_RANGE,OBJPROP_FONTSIZE,14);
   }

   // Visuals remain available even on a blocked day.
   InitSessionSeparatorsAndNTZ();

   // Existing positions remain managed even if new trading is blocked.
   if(NTZRange>0.0 && HasManagedPosition())
      ManageTakeProfits();
   PositionOpened=HasManagedPosition();

   // Preserve the same-date, London-open-relative timeout guard.
   if(!PositionOpened && HasPendingStops() && LondonOpen>0
      && TimeToString(LondonOpen,TIME_DATE)==TimeToString(now,TIME_DATE)
      && now>=LondonOpen+3*3600)
   {
      Print("3 hours after London open passed without fill. Canceling stops.");
      CancelPendingOrders();
   }

   UpdateStatusPanel();
   if(NO_TRADE_TODAY || DoNotTradeDay)
      return;

   // Place stops only during the exact LondonOpen-180 to LondonOpen window.
   if(frankOpen>0 && !OrdersPlaced && !HasPendingStops()
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
         SetupTPLevels(); 
         if(PlacePendingOrders())
         {
            DrawTPLevels();
            DrawNTZBox();
            OrdersPlaced=true;
            NTZDefined=true;
            PrintSessionSummary();
            PrintFormat("âœ… Orders placed â€” Asia:%.1f, NTZ:%.1f",
                        (AsiaHigh-AsiaLow)/(_Point*10.0),nP);
         }
         else
            Print("Pending order placement failed. OrdersPlaced remains false.");
      }
      else
         PrintFormat("ðŸ›‘ NTZ %.1f pips outside [10â€“30] â†’ halt",nP);
   }
}

void OnTimer()
{
   OnTick();
}

void PrintSessionSummary()
{
   if(SessionPrinted) return;

   if(AsiaHigh <= AsiaLow) return;
   if(NTZRange <= 0) return;   // wait until NTZ is defined

   double asiaPips = (AsiaHigh - AsiaLow) / (_Point * 10.0);
   double ntzPips  = NTZRange / (_Point * 10.0);

   PrintFormat("SESSION SUMMARY");
   PrintFormat("Asia High: %.5f | Asia Low: %.5f | Asia Range: %.1f pips",
               AsiaHigh, AsiaLow, asiaPips);

   PrintFormat("NTZ High: %.5f | NTZ Low: %.5f | NTZ Range: %.1f pips",
               NTZHigh, NTZLow, ntzPips);

   SessionPrinted = true;
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
void SetupTPLevels()
{
   // Price calculation is intentionally separate from TP-progress reset.
   // Restart recovery may rebuild these prices without erasing TP1/TP2 state.
   for(int i=1;i<=10;i++)
   {
      TPLevels[i]            = NTZHigh + i*NTZRange;
      TPLevels[10+i]         = NTZLow  - i*NTZRange;
   }
}

double TargetLevel(const long positionType,const int level)
{
   return (positionType==POSITION_TYPE_BUY ? TPLevels[level] : TPLevels[10+level]);
}

double NormalizeTradePrice(const double price)
{
   double tickSize=SymbolInfoDouble(Sym,SYMBOL_TRADE_TICK_SIZE);
   if(tickSize<=0.0)
      tickSize=_Point;
   return NormalizeDouble(MathRound(price/tickSize)*tickSize,(int)SymbolInfoInteger(Sym,SYMBOL_DIGITS));
}

double ExpectedOriginalSL(const long positionType)
{
   double pip=_Point*10.0;
   return NormalizeTradePrice(positionType==POSITION_TYPE_BUY ? NTZLow-pip : NTZHigh+pip);
}

bool ValidateTP3(const long orderType,const double entry,const double tp3)
{
   double minimumDistance=SymbolInfoInteger(Sym,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   if(orderType==ORDER_TYPE_BUY_STOP)
      return (tp3>entry && tp3-entry>=minimumDistance);
   return (tp3<entry && entry-tp3>=minimumDistance);
}

void LogTradeFailure(const string action)
{
   PrintFormat("%s failed | Retcode: %u | %s",action,
               trade.ResultRetcode(),trade.ResultRetcodeDescription());
}

bool VerifyPendingTP3(const ulong ticket,const double expectedTP)
{
   if(ticket==0 || !OrderSelect(ticket) || !IsOurSelectedOrder())
      return false;
   return PriceNear(OrderGetDouble(ORDER_TP),expectedTP);
}

bool PlacePendingOrders()
{
   double ask = SymbolInfoDouble(Sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(Sym, SYMBOL_BID);
   double pip=_Point*10.0;
   double buyStopPrice=NormalizeTradePrice(NTZHigh+pip);
   double sellStopPrice=NormalizeTradePrice(NTZLow-pip);
   double buySL=NormalizeTradePrice(NTZLow-pip);
   double sellSL=NormalizeTradePrice(NTZHigh+pip);
   double buyTP3=NormalizeTradePrice(TargetLevel(POSITION_TYPE_BUY,3));
   double sellTP3=NormalizeTradePrice(TargetLevel(POSITION_TYPE_SELL,3));

   if(!ValidateTP3(ORDER_TYPE_BUY_STOP,buyStopPrice,buyTP3) ||
      !ValidateTP3(ORDER_TYPE_SELL_STOP,sellStopPrice,sellTP3))
   {
      PrintFormat("TP3 validation failed; no pending order sent | Buy TP3 %.5f | Sell TP3 %.5f | Stops level %d",
                  buyTP3,sellTP3,(int)SymbolInfoInteger(Sym,SYMBOL_TRADE_STOPS_LEVEL));
      return false;
   }

   // Preserve the original buy/sell stop entry mathematics and market-side checks.
   if(buyStopPrice > ask && sellStopPrice < bid)
   {
      bool buyPlaced=trade.BuyStop(LotSize,buyStopPrice,Sym,buySL,buyTP3);
      if(buyPlaced)
      {
         BuyTicket=trade.ResultOrder();
         if(!VerifyPendingTP3(BuyTicket,buyTP3))
         {
            PrintFormat("BUY STOP TP3 verification failed | Ticket: %I64u | Expected TP: %.5f",BuyTicket,buyTP3);
            if(BuyTicket>0 && OrderSelect(BuyTicket) && IsOurSelectedOrder())
               trade.OrderDelete(BuyTicket);
            BuyTicket=0;
            buyPlaced=false;
         }
      }
      else
         LogTradeFailure("BUY STOP with TP3");

      bool sellPlaced=trade.SellStop(LotSize,sellStopPrice,Sym,sellSL,sellTP3);
      if(sellPlaced)
      {
         SellTicket=trade.ResultOrder();
         if(!VerifyPendingTP3(SellTicket,sellTP3))
         {
            PrintFormat("SELL STOP TP3 verification failed | Ticket: %I64u | Expected TP: %.5f",SellTicket,sellTP3);
            if(SellTicket>0 && OrderSelect(SellTicket) && IsOurSelectedOrder())
               trade.OrderDelete(SellTicket);
            SellTicket=0;
            sellPlaced=false;
         }
      }
      else
         LogTradeFailure("SELL STOP with TP3");

      if(buyPlaced || sellPlaced)
      {
         OrdersPlaced=true;
         PrintFormat("Pending orders placed with broker-side TP3 | Buy: %s | Sell: %s",
                     (buyPlaced ? "success" : "failed"),(sellPlaced ? "success" : "failed"));
         return true;
      }
      return false;
   }

   PrintFormat("Invalid stop levels - BuyStop: %.5f vs Ask: %.5f | SellStop: %.5f vs Bid: %.5f",
               buyStopPrice, ask, sellStopPrice, bid);
   return false;
}

void DrawTPLevels()
{
   int count=MathMin(TargetCount,10);
   for(int i=1;i<=count;i++)
   {
      string b=StringFormat("TPB_%d",i),
             s=StringFormat("TPS_%d",i);
      if(ObjectFind(0,b)==-1) {
         ObjectCreate(0,b,OBJ_HLINE,0,0,TPLevels[i]);
         ObjectSetString(0,b,OBJPROP_TEXT,StringFormat("TP Buy %d",i));
      }
      ObjectSetDouble(0,b,OBJPROP_PRICE,TPLevels[i]);
      if(ObjectFind(0,s)==-1) {
         ObjectCreate(0,s,OBJ_HLINE,0,0,TPLevels[10+i]);
         ObjectSetString(0,s,OBJPROP_TEXT,StringFormat("TP Sell %d",i));
      }
      ObjectSetDouble(0,s,OBJPROP_PRICE,TPLevels[10+i]);
   }
}


//+------------------------------------------------------------------+
//| Draw NTZ shaded rectangle                                        |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Draw NTZ shaded rectangle                                        |
//+------------------------------------------------------------------+
void DrawNTZBox()
{
   // Create rectangle if it doesn't exist
   if(ObjectFind(0,"NTZ_Box")==-1)
   {
      ObjectCreate(0,"NTZ_Box",OBJ_RECTANGLE,0,
                   frankOpen,NTZHigh,
                   frankOpen+3600,NTZLow);
   }
   else
   {
      // Update coordinates
      ObjectMove(0,"NTZ_Box",0,frankOpen,NTZHigh);
      ObjectMove(0,"NTZ_Box",1,frankOpen+3600,NTZLow);
   }

   // Style
   ObjectSetInteger(0,"NTZ_Box",OBJPROP_COLOR,clrAqua);
   ObjectSetInteger(0,"NTZ_Box",OBJPROP_STYLE,STYLE_SOLID);
   ObjectSetInteger(0,"NTZ_Box",OBJPROP_WIDTH,1);
   ObjectSetInteger(0,"NTZ_Box",OBJPROP_BACK,true);
}





bool TP1Done(const bool buy)
{
   return (buy ? BuyTP1Done : SellTP1Done);
}

bool TP2Done(const bool buy)
{
   return (buy ? BuyTP2Done : SellTP2Done);
}

void MarkTP1Done(const bool buy)
{
   if(buy) BuyTP1Done=true; else SellTP1Done=true;
}

void MarkTP2Done(const bool buy)
{
   if(buy) BuyTP2Done=true; else SellTP2Done=true;
}

bool EnsurePositionTP3(const ulong ticket,const double expectedTP)
{
   if(!PositionSelectByTicket(ticket) || !IsOurSelectedPosition())
      return false;

   double currentTP=PositionGetDouble(POSITION_TP);
   if(PriceNear(currentTP,expectedTP))
      return true;

   double currentSL=PositionGetDouble(POSITION_SL);
   if(!trade.PositionModify(ticket,currentSL,expectedTP))
   {
      LogTradeFailure("Restore Model 2 broker-side TP3");
      return false;
   }
   if(!PositionSelectByTicket(ticket) || !IsOurSelectedPosition() ||
      !PriceNear(PositionGetDouble(POSITION_TP),expectedTP))
   {
      PrintFormat("TP3 restore verification failed | Ticket: %I64u | Expected TP: %.5f",
                  ticket,expectedTP);
      return false;
   }
   PrintFormat("TP3 restored on live position | Ticket: %I64u | TP3: %.5f",ticket,expectedTP);
   return true;
}

bool VerifyTP1State(const ulong ticket,const double expectedVolume,
                    const double originalSL,const double tp3,const double volumeStep)
{
   if(!PositionSelectByTicket(ticket) || !IsOurSelectedPosition())
   {
      Print("TP1 verification failed: the managed position no longer exists.");
      return false;
   }

   double tolerance=MathMax(volumeStep*0.5,0.00000001);
   if(MathAbs(PositionGetDouble(POSITION_VOLUME)-expectedVolume)>tolerance)
   {
      PrintFormat("TP1 verification failed: expected volume %.8f, actual %.8f",
                  expectedVolume,PositionGetDouble(POSITION_VOLUME));
      return false;
   }

   double afterSL=PositionGetDouble(POSITION_SL);
   double afterTP=PositionGetDouble(POSITION_TP);
   if(!PriceNear(afterTP,tp3))
   {
      // Some brokers remove protection on partial close. Restore TP3 and the
      // unchanged original SL before declaring TP1 complete.
      if(!trade.PositionModify(ticket,originalSL,tp3))
      {
         LogTradeFailure("Restore SL/TP3 after TP1 partial close");
         return false;
      }
      if(!PositionSelectByTicket(ticket) || !IsOurSelectedPosition())
         return false;
      afterSL=PositionGetDouble(POSITION_SL);
      afterTP=PositionGetDouble(POSITION_TP);
   }

   if(!PriceNear(afterSL,originalSL) || !PriceNear(afterTP,tp3))
   {
      PrintFormat("TP1 verification failed | SL %.5f expected %.5f | TP %.5f expected %.5f",
                  afterSL,originalSL,afterTP,tp3);
      return false;
   }
   return true;
}

void ManageModel2Position(const ulong ticket,const long type)
{
   if(!PositionSelectByTicket(ticket) || !IsOurSelectedPosition())
      return;

   bool buy=(type==POSITION_TYPE_BUY);
   double price=(buy ? SymbolInfoDouble(Sym,SYMBOL_BID) : SymbolInfoDouble(Sym,SYMBOL_ASK));
   double tp1=NormalizeTradePrice(TargetLevel(type,1));
   double tp2=NormalizeTradePrice(TargetLevel(type,2));
   double tp3=NormalizeTradePrice(TargetLevel(type,3));

   // A live Model 2 position must always retain broker-side TP3.
   if(!EnsurePositionTP3(ticket,tp3))
      return;
   if(!PositionSelectByTicket(ticket) || !IsOurSelectedPosition())
      return;

   if(!TP1Done(buy))
   {
      bool hitTP1=(buy ? price>=tp1 : price<=tp1);
      if(!hitTP1)
         return;

      double currentVolume=PositionGetDouble(POSITION_VOLUME);
      double minimumVolume=SymbolInfoDouble(Sym,SYMBOL_VOLUME_MIN);
      double volumeStep=SymbolInfoDouble(Sym,SYMBOL_VOLUME_STEP);
      if(minimumVolume<=0.0 || volumeStep<=0.0)
      {
         Print("TP1 ERROR: invalid broker volume settings.");
         return;
      }

      double closeVolume=NormalizeDouble(MathFloor((currentVolume*0.5)/volumeStep)*volumeStep,8);
      double expectedRemain=NormalizeDouble(currentVolume-closeVolume,8);
      if(closeVolume<minimumVolume || expectedRemain<minimumVolume || closeVolume>=currentVolume)
      {
         PrintFormat("TP1 ABORTED: cannot safely split volume %.8f with step %.8f and min %.8f",
                     currentVolume,volumeStep,minimumVolume);
         return;
      }

      if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      {
         Print("TP1 ABORTED: Model 2 partial-close management requires the configured hedging account.");
         return;
      }

      double originalSL=PositionGetDouble(POSITION_SL);
      if(!trade.PositionClosePartial(ticket,closeVolume,(ulong)Slippage))
      {
         LogTradeFailure("TP1 partial close");
         return;
      }

      if(!VerifyTP1State(ticket,expectedRemain,originalSL,tp3,volumeStep))
         return;

      MarkTP1Done(buy);
      PrintFormat("TP1 SUCCESS | Ticket: %I64u | Closed: %.8f | Remaining: %.8f | SL preserved: %.5f | TP3: %.5f",
                  ticket,closeVolume,expectedRemain,originalSL,tp3);
      return;
   }

   if(!TP2Done(buy))
   {
      bool hitTP2=(buy ? price>=tp2 : price<=tp2);
      if(!hitTP2)
         return;

      if(!trade.PositionModify(ticket,tp1,tp3))
      {
         LogTradeFailure("TP2 move SL to TP1");
         return;
      }
      if(!PositionSelectByTicket(ticket) || !IsOurSelectedPosition() ||
         !PriceNear(PositionGetDouble(POSITION_SL),tp1) ||
         !PriceNear(PositionGetDouble(POSITION_TP),tp3))
      {
         PrintFormat("TP2 verification failed | Ticket: %I64u | Expected SL %.5f | Expected TP %.5f",
                     ticket,tp1,tp3);
         return;
      }
      MarkTP2Done(buy);
      PrintFormat("TP2 SUCCESS | Ticket: %I64u | SL moved to TP1 %.5f | TP3 retained %.5f",
                  ticket,tp1,tp3);
      return;
   }

   // TP3 is broker-side protection. Never issue a competing PositionClose().
   if((buy ? price>=tp3 : price<=tp3))
      PrintFormat("TP3 reached for ticket %I64u; awaiting broker-side TP closure.",ticket);
}

void ManageTakeProfits()
{
   ulong tickets[];
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && IsOurSelectedPosition())
      {
         ArrayResize(tickets,count+1);
         tickets[count++]=ticket;
      }
   }

   for(int i=0;i<count;i++)
   {
      if(PositionSelectByTicket(tickets[i]) && IsOurSelectedPosition())
         ManageModel2Position(tickets[i],PositionGetInteger(POSITION_TYPE));
   }
}

void CloseManagedPositions()
{
   ulong tickets[];
   int count=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && IsOurSelectedPosition())
      {
         ArrayResize(tickets,count+1);
         tickets[count++]=ticket;
      }
   }
   for(int i=0;i<count;i++)
   {
      if(!trade.PositionClose(tickets[i],(ulong)Slippage))
         LogTradeFailure("London-close managed-position cleanup");
   }
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

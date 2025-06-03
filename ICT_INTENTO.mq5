//+------------------------------------------------------------------+
//|                                       Liquidity 7.0 VOLATILIDAD.mq5 |
//| EA basado en el estilo ICT con mejoras en selección de entradas |
//| basadas en sesgos, zonas de liquidez y otras funciones avanzadas |
//|                         *** CÓDIGO CORREGIDO *** |
//+------------------------------------------------------------------+
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------+
//| Estructuras y variables globales y enumerados adicionales         |
//+------------------------------------------------------------------+
struct SwingPoint
{
   datetime time;
   double   price;
   bool     isHigh;
};

struct LiquidityZone {
   double   price;
   bool     isBuySide;
   datetime time;
   double   strength; // Puntuación de la fuerza/importancia de la zona
   string   type;     // Nuevo campo: "Swing", "EQH/EQL", "Session", "Old H/L"
};

struct OrderBlock {
    bool     isBullish;
    double   openPrice;
    double   closePrice;
    double   highPrice;
    double   lowPrice;
    datetime time;
    bool     isSwept;
    double   quality;
    bool     hasHTFConfluence;
    bool     isPremium;
    bool     isValid;
    double   relativeSize;
    double   volumeRatio;      // Ratio: Volumen del OB / Volumen Promedio
    long     obTickVolume;     // Volumen de tick de la vela del OB
 };

struct FairValueGap {
   double startPrice;
   double endPrice;
   bool   isBullish;
};

struct BreakerBlock {
   double   price;
   bool     isBullish;
   datetime obTime; // Cambiado de time a obTime para evitar confusión con otros 'time'
};

// Estructuras para zonas de liquidez en H1 y H4 (pueden simplificarse o eliminarse si todo se maneja en LiquidityZone)
struct LiquidityZoneH1 {
   double   price;
   bool     isBuySide;
   datetime time;
   double   strength;
};

struct LiquidityZoneH4 {
   double   price;
   bool     isBuySide;
   datetime time;
   double   strength;
};

// *** NUEVA ESTRUCTURA PARA g_CurrentSetup ***
struct CurrentTradeSetup
{
   bool     isValid;          // La configuración es válida para operar?
   string   poiType;          // Tipo de POI (OB, BB, FVG, etc.)
   bool     isLong;           // Dirección del trade
   double   entryPrice;       // Precio de entrada sugerido
   double   stopLoss;         // Precio de Stop Loss sugerido
   double   takeProfit;       // Precio de Take Profit sugerido
   double   poiPrice;         // Precio del POI
   datetime poiTime;          // Tiempo del POI
   double   poiQuality;       // Calidad del POI
   // Añade más campos según necesites para definir un "setup"
};
CurrentTradeSetup g_CurrentSetup; // Variable global para la configuración actual


enum MarketRegime
{
    HIGH_VOLATILITY,
    LOW_VOLATILITY,
    RANGE_MARKET
};

enum MarketStructureState
{
   MSS_BULLISH,
   MSS_BEARISH,
   MSS_RANGE,
   MSS_UNKNOWN
};

enum EntryMode { ENTRY_MEDIUM = 0, ENTRY_AGGRESSIVE = 1 };

//+------------------------------------------------------------------+
//| Arrays y Variables Globales                                      |
//+------------------------------------------------------------------+
LiquidityZone    liquidityZones[]; // Array principal para TODAS las zonas de liquidez
OrderBlock       orderBlocks[];
FairValueGap     fairValueGaps[];
BreakerBlock     breakerBlocks[];
// Los arrays específicos H1/H4 pueden eliminarse si integramos todo en liquidityZones
// LiquidityZoneH1  liquidityZonesH1[];
// LiquidityZoneH4  liquidityZonesH4[];

// Variables globales para bias y control
bool g_H4BiasBullish = false;
bool g_D1BiasBullish = false;
static int partialClosedFlags[100];
static int tradesToday = 0;
MarketStructureState m15Structure = MSS_UNKNOWN;
MarketRegime g_regime = RANGE_MARKET; // Inicializar con un valor por defecto
static datetime lastH4TradeTime = 0;
double g_swingHigh_M15 = 0.0;
double g_swingLow_M15  = 0.0;

// Variables dinámicas (modificables por volatilidad, etc.)
double dyn_ATRMultiplierForMinPenetration;
double dyn_ATRMultiplierForMaxPenetration;
int    dyn_BreakEvenPips;
int    dyn_TrailingDistancePips;

// Variables para almacenar máximos/mínimos de sesiones y días/semanas/meses anteriores
double AsiaHigh = 0, AsiaLow = 0;
double LondonHigh = 0, LondonLow = 0;
double NYHigh = 0, NYLow = 0;
datetime AsiaStartTime, LondonStartTime, NYStartTime; // Para saber si la sesión ha comenzado
double PDH = 0, PDL = 0; // Previous Day High/Low
double PWH = 0, PWL = 0; // Previous Week High/Low
double PMH = 0, PML = 0; // Previous Month High/Low

// *** NUEVO: Almacenamiento para volúmenes iniciales ***
ulong  g_positionTickets[]; // Almacena los tickets de las posiciones activas
double g_initialVolumes[];  // Almacena el volumen inicial correspondiente a cada ticket

//+------------------------------------------------------------------+
//| Inputs del EA Agrupados                                          |
//+------------------------------------------------------------------+

// --- Configuración General de Trading ---
input group "--- Configuración General de Trading ---"
input double LotSize                  = 10;      // Lote base para las operaciones
input int    MaxTradesPerDay          = 3;       // Máximo de trades permitidos por día
input int    StopLossPips             = 10;      // Stop Loss inicial en pips
input int    EntryTolerancePips       = 5;       // Tolerancia en pips para la entrada respecto al POI
input int    MinimumHoldTimeSeconds   = 300;     // Tiempo mínimo en segundos antes de gestionar un trade (opcional)
input double RiskRewardRatio          = 3.0;     // Ratio Riesgo:Beneficio para el TP inicial
input int    BufferPips               = 20;      // Buffer general en pips (usado en Trailing Fractal, etc.)

// --- Gestión de Riesgo y Stops ---
input group "--- Gestión de Riesgo y Stops ---"
input bool   UseBreakEven             = true;    // Activar/Desactivar Break Even
input int    BreakEvenPips            = 15;      // Pips en positivo para mover SL a Break Even
input bool   UseTrailingStop          = false;   // Activar/Desactivar Trailing Stop estándar (ignorado si Trailing Fractal está activo)
input int    TrailingDistancePips     = 10;      // Distancia en pips para el Trailing Stop estándar
input bool   UsePartialClose          = false;   // Activar/Desactivar lógica de cierres parciales avanzados
input int    PartialClosePips         = 20;      // Pips para el primer cierre parcial (No usado en la lógica avanzada actual)
input double PartialClosePercent      = 50.0;    // Porcentaje a cerrar en el primer parcial (No usado en la lógica avanzada actual)
input bool   UseFractalStopHuntTrailing = true;   // Activar/Desactivar Trailing Stop basado en Fractales M15
input int    FractalTrailingDepth     = 2;       // Profundidad del fractal para el trailing (2 = fractal de 5 barras)
input int    FractalTrailingSearchBars= 100;     // Barras hacia atrás para buscar el fractal desde la entrada
input double FractalTrailingBufferPips= 3.0;     // Buffer en pips para el SL fractal

// --- Filtros de Sesión y Bias ---
input group " --- Filtros de Sesión y Bias ---"
input bool   FilterBySessions         = false;   // Activar/Desactivar filtro por sesiones de trading
input int    AsiaOpen                 = 23;      // Hora de Apertura Sesión Asiática (GMT del servidor)
input int    AsiaClose                = 7;       // Hora de Cierre Sesión Asiática (GMT del servidor)
input int    LondonOpen               = 7;       // Hora de Apertura Sesión Londres (GMT del servidor)
input int    LondonClose              = 10;      // Hora de Cierre Sesión Londres (GMT del servidor)
input int    NYOpen                   = 13;      // Hora de Apertura Sesión Nueva York (GMT del servidor)
input int    NYClose                  = 16;      // Hora de Cierre Sesión Nueva York (GMT del servidor)
input bool   UseDailyBias             = true;    // Considerar el Bias Diario (D1) para filtrar trades
input bool   UseH1Confirmation        = true;    // Requerir confirmación del Bias H1 (o H4 si H1 no es claro)

// --- Parámetros de Estructura de Mercado (M15) y ATR ---
input group " --- Parámetros de Estructura de Mercado (M15) y ATR ---"
input int    FractalLookback_M15      = 40;      // Lookback para la detección de estructura en M15
input int    ATRPeriod_M15            = 14;      // Período del ATR en M15
input double ATRMultiplier            = 1.0;     // Multiplicador ATR general (puede usarse en SL/TP inicial o buffers)
input int    ATR_MA_Period            = 20;      // Período de la Media Móvil del ATR (para suavizado y SL dinámico)
input double ATR_Volatility_Multiplier= 1.0;     // Multiplicador de volatilidad para el SL dinámico

// --- Parámetros de Order Blocks (OB) y Niveles Clave ---
input group " --- Parámetros de Order Blocks (OB) y Niveles Clave ---"
input int    OB_MinRangePips          = 20;      // Rango mínimo en pips para considerar un Order Block válido
input bool   UseKeyLevelsForSLTP      = true;    // Usar niveles clave (liquidez) para ajustar TP/SL (lógica no implementada completamente)
input double KeyLevelTP_MarginPips    = 5.0;     // Margen en pips para TP cerca de niveles clave
input double KeyLevelTP_MinStrength   = 7.5;     // *** NUEVO INPUT *** Fuerza mínima de una zona de liquidez para ser considerada como TP
input double ATRBufferFactor          = 1;       // Factor para buffers basados en ATR (ej: SL de OB = ATR * Factor)
input int    OBEntryMode              = 1;       // Modo de entrada en Order Block: 0=Open, 1=50% cuerpo, 2=Wick (Low/High)
input int    MaxOBsToStore            = 15;      // Máximo de OBs a identificar y almacenar
input double VolumeOBMultiplier       = 1.5;     // Multiplicador: Volumen del OB vs Promedio para calificar
input double VolumeDisplacementMultiplier = 1.3; // Multiplicador: Volumen de Desplazamiento vs Promedio para calificar

// --- Parámetros de Detección de Liquidez ---
input group "--- Parámetros de Detección de Liquidez ---"
input int    SWING_LOOKBACK_LIQUIDITY = 20;      // Lookback en barras para identificar Swing Points (M15/H1/H4)
input double EQH_EQL_TolerancePips    = 1.0;     // Tolerancia en pips para considerar Equal Highs/Lows
// Los siguientes inputs de liquidez no se usan activamente con la nueva lógica de AddLiquidityZone pero se mantienen por si se reutilizan
input group "--- AddLiquidityZone (Legacy) ---" // Renombrado grupo para claridad
input int    CONSEC_BARS_LIQUIDITY    = 3;       // (No usado en lógica actual) Barras consecutivas para EQH/EQL simple
input double MIN_SIZE_PIPS_LIQUIDITY  = 5;       // (No usado en lógica actual) Tamaño mínimo en pips de una zona de liquidez simple
input double ATRMultiplierForLiquidity= 1.0;     // (No usado en lógica actual) Multiplicador ATR para detección de liquidez simple

// --- Parámetros de Caza de Liquidez (Stop Hunt) ---
input group " --- Parámetros de Caza de Liquidez (Stop Hunt) ---"
input double StopHuntBufferPips       = 3.0;     // Buffer para ajustar SL inicial si está cerca de un nivel de liquidez
// Los siguientes inputs de Stop Hunt no se usan directamente, se usan versiones dinámicas basadas en ATRMultiplierForMin/MaxPenetration
input int    MIN_PENETRATION_PIPS      = 3;       // (No usado directamente) Mínima penetración en pips del nivel de liquidez
input int    MAX_PENETRATION_PIPS      = 15;      // (No usado directamente) Máxima penetración en pips del nivel de liquidez
input int    REVERSAL_CONFIRMATION_BARS= 2;       // (No usado directamente, BaseMinReversalBars lo reemplaza) Barras de confirmación de reversión post-hunt
input double REVERSAL_STRENGTH_PERCENT = 50;      // Porcentaje mínimo de reversión sobre la penetración para confirmar el hunt

// --- Parámetros Dinámicos Basados en Volatilidad (Inputs Base para Stop Hunt) ---
input group "--- Parámetros Dinámicos Basados en Volatilidad (Inputs Base para Stop Hunt)"
input double ATRMultiplierForMinPenetration = 0.5; // Factor ATR para la *mínima* penetración requerida en un Stop Hunt
input double ATRMultiplierForMaxPenetration = 2.5; // Factor ATR para la *máxima* penetración permitida en un Stop Hunt
input int    BaseMinReversalBars        = 2;       // Número base de barras de confirmación para la reversión post-hunt
input double VolumeDivergenceMultiplier = 1.5;     // Multiplicador para detectar divergencia de volumen en la reversión del hunt

// --- Parámetros de Fair Value Gap (FVG) ---
input group " --- Parámetros de Fair Value Gap (FVG) ---"
input int    FVGEntryMode             = ENTRY_MEDIUM; // Modo de entrada en FVG: 0 = Medio (50% del gap), 1 = Agresivo (inicio del gap)

// --- Parámetros de R:R Dinámico por Volatilidad ---
input group "--- R:R Dinámico por Volatilidad ---"
input bool   UseDynamicRRAdjust         = true;    // Activar/Desactivar ajuste dinámico de R:R
input ENUM_TIMEFRAMES VolatilityTFforRR = PERIOD_D1; // Timeframe para medir volatilidad para R:R (D1 o W1)

// *** NUEVOS INPUTS ***
input double MinRR_ForKeyLevelTP      = 1.5;     // R:R MÍNIMO base para TP en Nivel Clave
input double MaxRR_ForKeyLevelTP      = 5.0;     // R:R MÁXIMO base para TP en Nivel Clave

input double Inp_RR_LowVolFactor      = 0.8;     // Factor para R:R en BAJA volatilidad
input double Inp_RR_MediumVolFactor   = 1.0;     // Factor para R:R en MEDIA volatilidad (1.0 = R:R base)
input double Inp_RR_HighVolFactor     = 1.2;     // Factor para R:R en ALTA volatilidad

input int    Inp_RR_ATR_Period        = 14;      // Período del ATR para medir volatilidad en VolatilityTFforRR
input int    Inp_RR_ATR_AvgPeriod     = 10;      // Período para la media móvil del ATR
input double Inp_RR_LowVolThrMult     = 0.85;    // Límite SUPERIOR para BAJA volatilidad (ATR < AvgATR * EsteValor)
input double Inp_RR_HighVolThrMult    = 1.15;    // Límite INFERIOR para ALTA volatilidad (ATR > AvgATR * EsteValor)


//+------------------------------------------------------------------+
//| Declaraciones Adelantadas de Funciones                           |
//+------------------------------------------------------------------+
// Funciones de Indicadores y Cálculos Auxiliares
bool   GetADXValues(string symbol, ENUM_TIMEFRAMES tf, int period, int barShift, double &adxVal, double &plusDiVal, double &minusDiVal);
double GetEMAValue(string symbol, ENUM_TIMEFRAMES tf, int periodEMA, int barShift=0);
double ComputeATR(ENUM_TIMEFRAMES tf, int period, int shift = 0); // Función ATR unificada
double ComputeATR_M15(int period); // Mantenida por compatibilidad
double ComputeATR_H1(int period);  // Mantenida por compatibilidad
double ComputeATR_H4(int period);  // Mantenida por compatibilidad
double ComputeATR_M5(int period);  // Mantenida por compatibilidad
double AdaptiveVolatility(int period); // <--- Función corregida
double GetAdaptiveFactor(int atrPeriod, int maPeriod);
double CalculateDynamicSLBuffer_M15();
double ComputeATR_M15_Shift(int period, int shift); // *** CORRECCIÓN: Declaración adelantada necesaria ***
double ComputeVolatilityStdDev(int period);
double ComputeRelativeRange(int period);
double ComputeROC(int period);
double CalculateDynamicVolatilityIndex(int atrPeriod, int stddevPeriod, int rocPeriod);
MarketRegime DetermineMarketRegime(double volatilityIndex, double highThreshold, double lowThreshold);
void   AdjustParametersBasedOnVolatility(MarketRegime regime);
double CalculateLotSize();
double CalculateSmartStopBuffer(); // Buffer inteligente para SL inicial
bool   IsVolumeTrendingUp(int barIndex, int lookback=3); // ¿Volumen creciente?

// Funciones de Detección de Elementos ICT
void   DetectLiquidity(); // Función principal de liquidez (modificada)
void   DetectFairValueGaps();
void   DetectOrderBlocks();
void   DetectBreakerBlocks();
void   DetectJudasSwing(); // Placeholder
bool   DetectStopHunt(double level, bool isBuySideLiquidity, int &huntStrength);
bool   IsLiquidityZoneConfirmedByVolume(double price, bool isBuySide, datetime time);
void   AddLiquidityZone(double price, bool isBuySide, datetime time, double strength, string type, double tolerancePips = 1.0); // Nueva función auxiliar
void   UpdateOldHighsLows(); // Nueva función
void   UpdateSessionHighsLows(); // Nueva función

// Funciones de Estructura de Mercado y Bias
bool   ComputeH1Bias(); // Devuelve true si H1 es alcista (o H4 si H1 no es claro)
bool   ComputeM30Bias(); // Placeholder o lógica simple
void   ComputeH4Bias(); // Actualiza g_H4BiasBullish
void   ComputeD1Bias(); // Actualiza g_D1BiasBullish
MarketStructureState DetectMarketStructureM15(int lookbackBars, int pivotStrength); // Wrapper
MarketStructureState DetectMarketStructureH1(int lookbackBars, int pivotStrength); // Wrapper
MarketStructureState DetectMarketStructure(ENUM_TIMEFRAMES tf, int lookbackBars, int pivotStrength); // Nueva función unificada
double CalculateMarketStructureScore(int lookbackBars); // Placeholder o lógica simple
double CalculateLiquidityZoneWeight(const LiquidityZone &lz); // Placeholder
bool   IsLiquidityZoneStrong(const LiquidityZone &lz); // Placeholder (podría usar fuerza)
bool   IsH1BiasAligned(bool isBullishEntry); // Compara entrada con H1/H4 bias
double CalculateH1MarketScore(int lookbackBars); // Placeholder
bool   IsMultiTFConfirmation(MarketStructureState m15State, MarketStructureState h1State); // Placeholder
double CalculateStructureWeight(MarketStructureState state, double score); // Placeholder
bool   IsSignalQualityAcceptable(double m15Score, double h1Score); // Placeholder
bool   DetectBOS(ENUM_TIMEFRAMES tf, int barIndex, bool isBullish, int lookback=30); // Función unificada BOS
bool   DetectChoCH(ENUM_TIMEFRAMES tf, int barIndex, bool isBullish, int lookback=30); // Función unificada ChoCH
bool   DetectBOS_M15(bool isBullish); // Wrapper M15
bool   DetectChoCH_M15(bool isBullish); // Wrapper M15

// Funciones de Gestión de Órdenes y Riesgo
void   CheckTradeEntries(); // Lógica principal de entradas POI
void   CheckLiquidityHunting(); // Lógica de entradas Stop Hunt
void   ManageRisk(); // Gestión general (BE, Parciales, llamadas a Trailings)
bool   OpenTradeSimple(bool isLong, double lot, double entryPrice, double stopLoss, string comment); // Abrir trade con ajustes
void   ManagePartialWithFixedTP_Advanced(); // Lógica de parciales 2R/3R
void   AdvancedAdaptiveTrailing(ulong ticket, double fixedTakeProfit); // Trailing adaptativo post-parciales
void   ApplyStopHuntFractalTrailing(ulong ticket, int fractalDepth, double bufferPips, int searchBarsAfterEntry); // Trailing fractal
void   ManageSLWithStopRunProtection(); // Ajuste defensivo del SL ante hunts
bool   IsStopLossNearLiquidityLevel(double proposedSL, double proximityRangePips); // Chequeo de SL vs Liquidez
// *** NUEVA DECLARACIÓN ADELANTADA ***
bool   IsStopLossDangerouslyNearLiquidity(double proposedSL, bool isLongTrade, double entryPrice, double &adjustedSL_output, double proximityPipsToConsider = 5.0, double adjustmentPips = 3.0);
// *** NUEVO: Funciones auxiliares para volumen inicial ***
void   StoreInitialVolume(ulong ticket, double volume);
double GetStoredInitialVolume(ulong ticket);
void   RemoveStoredVolume(ulong ticket);

// Funciones relacionadas con Order Blocks
bool   CheckHTFConfluence(OrderBlock &ob); // Placeholder
bool   IsPremiumPosition(OrderBlock &ob); // Placeholder
double ComputeATRSlope(int period); // Placeholder
double AssessOBQuality(OrderBlock &ob); // Evaluar calidad OB
bool   IsOBSwept(OrderBlock &ob); // Chequear si OB fue mitigado
void   SortOrderBlocksByQuality(); // Ordenar OBs

// Otras funciones
bool   IsSignalRefined(bool isBullish); // Placeholder para calidad de vela

// Variables para R:R Dinámico
double g_dyn_MinRR_ForKeyLevelTP; // Se inicializará en OnInit
double g_dyn_MaxRR_ForKeyLevelTP; // Se inicializará en OnInit

// *** NUEVA DECLARACIÓN ADELANTADA ***
void UpdateDynamicRiskRewardRatios(); // Para OnTick

//+------------------------------------------------------------------+
//| Funciones Auxiliares para Indicadores                            |
//+------------------------------------------------------------------+
bool GetADXValues(string symbol, ENUM_TIMEFRAMES tf, int period, int barShift, double &adxVal, double &plusDiVal, double &minusDiVal)
{
   int adxHandle = iADX(symbol, tf, period);
   if(adxHandle == INVALID_HANDLE)
   {
      Print("Error al crear handle de iADX(", symbol, ", ", EnumToString(tf), "). Code=", GetLastError());
      return false;
   }
   double adxBuffer[], plusDiBuffer[], minusDiBuffer[];
   if(CopyBuffer(adxHandle, 0, barShift, 1, adxBuffer) <= 0 ||
      CopyBuffer(adxHandle, 1, barShift, 1, plusDiBuffer) <= 0 ||
      CopyBuffer(adxHandle, 2, barShift, 1, minusDiBuffer) <= 0)
   {
      // No imprimir error si es solo falta de datos calculados
      // Print("Error CopyBuffer ADX(", symbol, ", ", EnumToString(tf), "): ", GetLastError());
      return false;
   }
   adxVal    = adxBuffer[0];
   plusDiVal = plusDiBuffer[0];
   minusDiVal= minusDiBuffer[0];
   return true;
}

double GetEMAValue(string symbol, ENUM_TIMEFRAMES tf, int periodEMA, int barShift=0)
{
   int maHandle = iMA(symbol, tf, periodEMA, 0, MODE_EMA, PRICE_CLOSE);
   if(maHandle == INVALID_HANDLE)
   {
      Print("Error al crear handle de iMA(", symbol, ", ", EnumToString(tf), "). Code=", GetLastError());
      return 0.0;
   }
   double maBuffer[];
   if(CopyBuffer(maHandle, 0, barShift, 1, maBuffer) <= 0)
   {
      // No imprimir error si es solo falta de datos calculados
      // Print("Error CopyBuffer EMA(", symbol, ", ", EnumToString(tf), "): ", GetLastError());
      return 0.0;
   }
   return maBuffer[0];
}

// Función ATR Unificada
double ComputeATR(ENUM_TIMEFRAMES tf, int period, int shift = 0)
{
   // Usar un handle estático para eficiencia
   static int atrHandles[10]; // Asumir máximo 10 TFs usados
   static ENUM_TIMEFRAMES atrTFs[10];
   static int atrPeriods[10];
   int handleIndex = -1;

   // Buscar handle existente
   for(int i=0; i<ArraySize(atrHandles); i++)
   {
      if(atrHandles[i] != 0 && atrTFs[i] == tf && atrPeriods[i] == period)
      {
         handleIndex = i;
         break;
      }
   }

   // Crear handle si no existe
   if(handleIndex == -1)
   {
      for(int i=0; i<ArraySize(atrHandles); i++)
      {
         if(atrHandles[i] == 0) // Encontrar slot vacío
         {
            atrHandles[i] = iATR(Symbol(), tf, period);
            if(atrHandles[i] != INVALID_HANDLE)
            {
               atrTFs[i] = tf;
               atrPeriods[i] = period;
               handleIndex = i;
            } else {
                Print("Error creando handle ATR(", Symbol(), ", ", EnumToString(tf), ", ", period, "). Code:", GetLastError());
                return 0.0; // Error crítico
            }
            break;
         }
      }
       if(handleIndex == -1) { Print("No hay slots para handle ATR"); return 0.0;} // Si no hay slots
   }


   double atr_buffer[];
   if(CopyBuffer(atrHandles[handleIndex], 0, shift, 1, atr_buffer) > 0)
      return atr_buffer[0];
   else
   {
      // Print("Error al copiar buffer ATR en ", EnumToString(tf), ". Code: ", GetLastError()); // Comentado para reducir spam
      return 0.0;
   }
}
// Funciones ATR específicas (llaman a la unificada)
double ComputeATR_M15(int period) { return ComputeATR(PERIOD_M15, period); }
double ComputeATR_H1(int period)  { return ComputeATR(PERIOD_H1, period); }
double ComputeATR_H4(int period)  { return ComputeATR(PERIOD_H4, period); }
double ComputeATR_M5(int period)  { return ComputeATR(PERIOD_M5, period); }


//---------------------------------------------------------
// Función AdaptiveVolatility (CORREGIDA)
//---------------------------------------------------------
// Devuelve un factor basado en el régimen de volatilidad actual.
double AdaptiveVolatility(int period) // El 'period' no se usa aquí actualmente
{
   // Usa directamente la variable global g_regime que se actualiza en OnTick
   if(g_regime == HIGH_VOLATILITY) return 1.2; // Factor para alta volatilidad
   if(g_regime == LOW_VOLATILITY) return 0.8;  // Factor para baja volatilidad
   // if(g_regime == RANGE_MARKET) return 1.0; // Factor para rango (implícito en el return final)

   return 1.0; // Valor base por defecto (si es rango o no se pudo determinar)
}

// Calcula un factor basado en el ATR actual vs su media móvil
double GetAdaptiveFactor(int atrPeriod, int maPeriod)
{
   double currentATR = ComputeATR(PERIOD_M15, atrPeriod, 0); // ATR de la vela actual
   if(currentATR <= 0) return 1.0; // Evitar división por cero

   double sumATR = 0.0;
   int barsCalculated = 0;
   for(int i = 1; i <= maPeriod; i++) // Empezar desde la vela anterior (shift=1)
   {
      double pastATR = ComputeATR(PERIOD_M15, atrPeriod, i);
      if(pastATR > 0)
      {
         sumATR += pastATR;
         barsCalculated++;
      }
   }

   if(barsCalculated == 0) return 1.0; // No se pudo calcular la media

   double avgATR = sumATR / barsCalculated;
   if(avgATR <= 0) return 1.0; // Evitar división por cero

   return currentATR / avgATR; // Ratio ATR actual vs promedio
}

// Calcula un buffer dinámico para SL basado en ATR suavizado y volatilidad
double CalculateDynamicSLBuffer_M15()
{
   double currentATR = ComputeATR_M15(ATRPeriod_M15);
   if(currentATR <= 0) return _Point * 100; // Retornar un buffer fijo si ATR falla

   double sumATR = 0.0;
   int barsCalculated = 0;
   for(int i = 1; i <= ATR_MA_Period; i++) // Empezar shift=1
   {
      // *** CORRECCIÓN: Usar ComputeATR unificada con shift ***
      double pastATR = ComputeATR(PERIOD_M15, ATRPeriod_M15, i);
      if(pastATR > 0)
      {
         sumATR += pastATR;
         barsCalculated++;
      }
   }

   double atrMA = (barsCalculated > 0) ? (sumATR / barsCalculated) : currentATR; // Usar ATR actual si MA falla
   double smoothedATR = (currentATR + atrMA) / 2.0; // Media simple entre ATR actual y su MA

   double adaptiveMultiplier = GetAdaptiveFactor(ATRPeriod_M15, ATR_MA_Period); // Factor adaptativo ATR vs MA(ATR)
   double volatilityRegimeFactor = AdaptiveVolatility(0); // Factor del régimen de volatilidad

   // Buffer final: ATR Suavizado * Factor General * Factor Volatilidad * Factor Adaptativo
   double dynamicBuffer = smoothedATR * ATRBufferFactor * ATR_Volatility_Multiplier * adaptiveMultiplier * volatilityRegimeFactor;

   // Asegurar un buffer mínimo (ej: 5 pips)
   double minBufferPips = 5.0;
   double minBuffer = minBufferPips * _Point * (SymbolInfoInteger(Symbol(), SYMBOL_DIGITS) % 2 == 1 ? 10 : 1); // Ajuste pip
    if (minBuffer == 0 && _Point > 0) minBuffer = minBufferPips * _Point;
    else if (minBuffer == 0) minBuffer = minBufferPips * 0.0001; // Fallback

   return MathMax(minBuffer, dynamicBuffer);
}

// Función auxiliar para ComputeATR con shift (si ComputeATR unificada no lo soporta)
// --> Esta función ya no es estrictamente necesaria si ComputeATR maneja shift, pero la dejamos por si acaso.
double ComputeATR_M15_Shift(int period, int shift)
{
    // Reimplementar cálculo manual si CopyBuffer no funciona bien con shift en iATR
    double sumTR = 0.0;
    int calculated_bars = 0;
    int startBar = shift + 1; // Corrección: shift empieza en 0, así que necesitamos barra 1 para shift 0.
    int endBar = shift + period;
    int totalBars = Bars(Symbol(), PERIOD_M15);

    if (endBar >= totalBars) return 0.0; // No hay suficientes datos

    for (int i = startBar; i <= endBar; i++)
    {
        if (i + 1 >= totalBars) continue; // Necesitamos i+1 para prevClose
        double high = iHigh(Symbol(), PERIOD_M15, i);
        double low = iLow(Symbol(), PERIOD_M15, i);
        double prevClose = iClose(Symbol(), PERIOD_M15, i + 1);
        double tr = MathMax(high - low, MathMax(MathAbs(high - prevClose), MathAbs(low - prevClose)));
        sumTR += tr;
        calculated_bars++;
    }
    if (calculated_bars == 0) return 0.0;
    return sumTR / calculated_bars;
}


// Calcula Desviación Estándar de precios de cierre (usado en índice de volatilidad)
double ComputeVolatilityStdDev(int period)
{
    if (period <= 1) return 0.0;
    double priceData[];
    if(CopyClose(Symbol(), PERIOD_M5, 0, period, priceData) != period) return 0.0; // Usar M5 para volatilidad rápida

    double sum = 0.0;
    for(int i = 0; i < period; i++) sum += priceData[i];
    double mean = sum / period;
    double varianceSum = 0.0;
    for(int i = 0; i < period; i++) varianceSum += MathPow(priceData[i] - mean, 2);
    // Usar N-1 para muestra si es necesario, pero N es común para indicadores
    if (period == 0) return 0.0;
    return MathSqrt(varianceSum / period);
}

// Calcula Rango Relativo (rango actual vs promedio, usado en índice de volatilidad)
double ComputeRelativeRange(int period)
{
    if(period <= 0) return 1.0;
    double currentRange = iHigh(Symbol(), PERIOD_M5, 0) - iLow(Symbol(), PERIOD_M5, 0);
    if(currentRange <= 0) return 1.0;

    double sumRange = 0.0;
    int calculatedBars = 0;
    for(int i = 1; i <= period; i++) // Usar velas anteriores para promedio
    {
        double range = iHigh(Symbol(), PERIOD_M5, i) - iLow(Symbol(), PERIOD_M5, i);
        if(range > 0) {
            sumRange += range;
            calculatedBars++;
        }
    }
    if(calculatedBars == 0) return 1.0;
    double avgRange = sumRange / calculatedBars;
    if(avgRange <= 0) return 1.0;

    return currentRange / avgRange;
}

// Calcula Rate of Change (usado en índice de volatilidad)
double ComputeROC(int period)
{
   if(period <= 0) return 0.0;
   if(iBars(Symbol(), PERIOD_M5) <= period) return 0.0; // Datos insuficientes
   double currentPrice = iClose(Symbol(), PERIOD_M5, 0);
   double previousPrice = iClose(Symbol(), PERIOD_M5, period);
   if(previousPrice == 0) return 0.0; // Evitar división por cero

   return ((currentPrice - previousPrice) / previousPrice) * 100.0;
}

// Calcula Índice de Volatilidad Combinado
double CalculateDynamicVolatilityIndex(int atrPeriod, int stddevPeriod, int rocPeriod)
{
    // Usar M5 para cálculos de volatilidad rápida
    double atr = ComputeATR(PERIOD_M5, atrPeriod);
    double stddev = ComputeVolatilityStdDev(stddevPeriod);
    double relativeRange = ComputeRelativeRange(atrPeriod); // Usa M5 dentro de la función
    double roc = ComputeROC(rocPeriod); // Usa M5 dentro de la función

    // Ponderación (ajustable)
    double atrWeight = 0.4;
    double stddevWeight = 0.3;
    double relRangeWeight = 0.15;
    double rocWeight = 0.15;

    // Normalizar componentes si es necesario (ej: dividir por precio o ATR para comparar)
    // Aquí se usan valores directos con ponderación simple
    // Asegurarse que los componentes no sean negativos donde no deben (ej: stddev)
    double volatilityIndex = (atr * atrWeight) + (MathMax(0, stddev) * stddevWeight) + (relativeRange * relRangeWeight) + (MathAbs(roc) * rocWeight);

    return volatilityIndex;
}

// Determina el Régimen de Mercado basado en el Índice de Volatilidad
MarketRegime DetermineMarketRegime(double volatilityIndex, double highThreshold, double lowThreshold)
{
    // Los umbrales dependen de la escala del volatilityIndex calculado.
    // Se necesita calibración con datos históricos o pruebas.
    // Ejemplo de umbrales (¡NECESITAN AJUSTE!):
    // double calibratedHighThreshold = highThreshold * ComputeATR(PERIOD_D1, 14); // Escalar con ATR diario?
    // double calibratedLowThreshold = lowThreshold * ComputeATR(PERIOD_D1, 14);
    // Usaremos umbrales fijos por ahora (requieren ajuste)
    if(volatilityIndex > highThreshold) return HIGH_VOLATILITY;
    if(volatilityIndex < lowThreshold) return LOW_VOLATILITY;
    return RANGE_MARKET;
}

// Ajusta Parámetros Dinámicos basado en el Régimen de Mercado
void AdjustParametersBasedOnVolatility(MarketRegime regime)
{
    // Ajustar variables dyn_* globales
    switch(regime)
    {
        case HIGH_VOLATILITY:
            dyn_ATRMultiplierForMinPenetration = ATRMultiplierForMinPenetration * 1.3; // Más penetración permitida
            dyn_ATRMultiplierForMaxPenetration = ATRMultiplierForMaxPenetration * 1.3;
            dyn_BreakEvenPips = BreakEvenPips + 5; // BE más holgado
            dyn_TrailingDistancePips = TrailingDistancePips + 5; // Trailing más holgado
            break;
        case LOW_VOLATILITY:
            dyn_ATRMultiplierForMinPenetration = ATRMultiplierForMinPenetration * 0.7; // Menos penetración
            dyn_ATRMultiplierForMaxPenetration = ATRMultiplierForMaxPenetration * 0.7;
            dyn_BreakEvenPips = MathMax(5, BreakEvenPips - 5); // BE más ajustado (mín 5)
            dyn_TrailingDistancePips = MathMax(5, TrailingDistancePips - 5); // Trailing más ajustado (mín 5)
            break;
        case RANGE_MARKET:
        default: // Volver a valores base de los inputs
            dyn_ATRMultiplierForMinPenetration = ATRMultiplierForMinPenetration;
            dyn_ATRMultiplierForMaxPenetration = ATRMultiplierForMaxPenetration;
            dyn_BreakEvenPips = BreakEvenPips;
            dyn_TrailingDistancePips = TrailingDistancePips;
            break;
    }
}

// Verifica si el volumen ha estado creciendo en las últimas barras
bool IsVolumeTrendingUp(int barIndex, int lookback=3)
{
   if(barIndex < lookback || lookback <= 0) return false;
   // Usar M5 para volumen, como en otras partes
   if(barIndex + 1 >= iBars(Symbol(), PERIOD_M5)) return false; // Necesitamos barra k+1

   for(int k = barIndex; k > barIndex - lookback; k--)
   {
      if(k+1 >= iBars(Symbol(), PERIOD_M5)) return false; // Asegurar k+1 válido
      // Comparar volumen real (tick_volume)
      long vol_k = iTickVolume(Symbol(), PERIOD_M5, k);
      long vol_k1 = iTickVolume(Symbol(), PERIOD_M5, k+1);
      if(vol_k <= vol_k1)
         return false; // No estrictamente creciente
   }
   return true; // Todas las barras tuvieron volumen mayor que la anterior
}


//+------------------------------------------------------------------+
//| Funciones de Detección de Elementos ICT                          |
//+------------------------------------------------------------------+

// Función auxiliar para añadir zonas de liquidez evitando duplicados cercanos
void AddLiquidityZone(double price, bool isBuySide, datetime time, double strength, string type, double tolerancePips = 1.0)
{
    double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
    // Ajustar cálculo de tolerancia: tolerancePips * point da una fracción muy pequeña. Usar point*10 o similar.
    double tolerance = tolerancePips * (point == 0 ? 0.00001 : point) * (Digits() % 2 == 1 ? 10 : 1); // Tolerancia en precio absoluto (ajustado)
    if (tolerance <= 0 && point > 0) tolerance = tolerancePips * point;
    else if (tolerance <= 0) tolerance = tolerancePips * 0.0001; // Fallback si point es 0

    bool exists = false;
    int existingIndex = -1;
    for(int i = ArraySize(liquidityZones) - 1; i >= 0; i--) // Buscar desde el final (más recientes)
    {
        // Comprobar si ya existe una zona MUY similar (mismo lado, precio cercano)
        if(liquidityZones[i].isBuySide == isBuySide && MathAbs(liquidityZones[i].price - price) <= tolerance)
        {
            exists = true;
            existingIndex = i;
            break; // Encontrada una coincidencia cercana
        }
    }

    if(exists) // Si existe, actualizar si la nueva zona es más fuerte o más reciente
    {
        if(strength > liquidityZones[existingIndex].strength || (strength == liquidityZones[existingIndex].strength && time > liquidityZones[existingIndex].time))
        {
            liquidityZones[existingIndex].price = price;
            liquidityZones[existingIndex].time = time;
            liquidityZones[existingIndex].strength = strength;
            liquidityZones[existingIndex].type = type; // Actualizar tipo también
        }
    }
     else // Si no existe, añadirla
    {
        LiquidityZone lz;
        lz.price = price;
        lz.isBuySide = isBuySide;
        lz.time = time;
        lz.strength = strength;
        lz.type = type;

        int sz = ArraySize(liquidityZones);
        ArrayResize(liquidityZones, sz + 1);
        liquidityZones[sz] = lz;
    }
}

// Nueva función para actualizar máximos/mínimos del día/semana/mes anterior
void UpdateOldHighsLows()
{
    datetime now = TimeCurrent(); // Usar tiempo actual como referencia para la zona

    // --- Previous Day High/Low (PDH/PDL) ---
    double dailyHighs[], dailyLows[];
    // Pedir 2 barras y usar índice [1] para el día anterior (barra 0 es actual incompleta)
    if(CopyHigh(Symbol(), PERIOD_D1, 1, 1, dailyHighs) > 0 && dailyHighs[0] != 0)
         AddLiquidityZone(dailyHighs[0], true, now, 9.5, "PDH"); // Muy alta fuerza
    if(CopyLow(Symbol(), PERIOD_D1, 1, 1, dailyLows) > 0 && dailyLows[0] != 0)
         AddLiquidityZone(dailyLows[0], false, now, 9.5, "PDL");

    // --- Previous Week High/Low (PWH/PWL) ---
    double weeklyHighs[], weeklyLows[];
    if(CopyHigh(Symbol(), PERIOD_W1, 1, 1, weeklyHighs) > 0 && weeklyHighs[0] != 0)
         AddLiquidityZone(weeklyHighs[0], true, now, 9.7, "PWH"); // Semanal aún más fuerte
    if(CopyLow(Symbol(), PERIOD_W1, 1, 1, weeklyLows) > 0 && weeklyLows[0] != 0)
         AddLiquidityZone(weeklyLows[0], false, now, 9.7, "PWL");

    // --- Previous Month High/Low (PMH/PML) ---
    double monthlyHighs[], monthlyLows[];
    if(CopyHigh(Symbol(), PERIOD_MN1, 1, 1, monthlyHighs) > 0 && monthlyHighs[0] != 0)
         AddLiquidityZone(monthlyHighs[0], true, now, 9.9, "PMH"); // Mensual máxima fuerza
    if(CopyLow(Symbol(), PERIOD_MN1, 1, 1, monthlyLows) > 0 && monthlyLows[0] != 0)
         AddLiquidityZone(monthlyLows[0], false, now, 9.9, "PML");
}

// Nueva función para actualizar máximos/mínimos de sesiones
void UpdateSessionHighsLows()
{
    // Esta función necesita una implementación más robusta para calcular
    // correctamente los H/L de sesiones pasadas basadas en las horas input.
    // La lógica actual es un placeholder y solo añade zonas si las variables globales tienen valor.
    // Aquí se debería buscar hacia atrás en el historial M1/M5 para encontrar los H/L reales
    // dentro de los rangos horarios definidos por AsiaOpen/Close, LondonOpen/Close, NYOpen/Close.
    datetime nowTime = TimeCurrent();
    // Añadir los H/L guardados (si existen) a las zonas - ESTO ES INCORRECTO, necesita cálculo real
    if(AsiaHigh != 0) AddLiquidityZone(AsiaHigh, true, nowTime, 8.5, "Asia H");
    if(AsiaLow != 0) AddLiquidityZone(AsiaLow, false, nowTime, 8.5, "Asia L");
    if(LondonHigh != 0) AddLiquidityZone(LondonHigh, true, nowTime, 9.0, "London H"); // Londres más importante
    if(LondonLow != 0) AddLiquidityZone(LondonLow, false, nowTime, 9.0, "London L");
    if(NYHigh != 0) AddLiquidityZone(NYHigh, true, nowTime, 8.8, "NY H"); // NY también importante
    if(NYLow != 0) AddLiquidityZone(NYLow, false, nowTime, 8.8, "NY L");
}


// Función Principal de Detección de Liquidez (Modificada)
void DetectLiquidity()
{
    ArrayResize(liquidityZones, 0); // Limpiar zonas anteriores
    const int MAX_LOOKBACK = 200;   // Lookback para swings y EQH/EQL
    const int SWING_LOOKBACK = SWING_LOOKBACK_LIQUIDITY; // Usar input
    double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
    double eqTolerance = EQH_EQL_TolerancePips * (point == 0 ? 0.00001 : point) * (Digits() % 2 == 1 ? 10 : 1); // Tolerancia para EQH/EQL (ajustado)
    if (eqTolerance <= 0 && point > 0) eqTolerance = EQH_EQL_TolerancePips * point;
    else if (eqTolerance <= 0) eqTolerance = EQH_EQL_TolerancePips * 0.0001; // Fallback

    // 1. Añadir Old Highs/Lows (PDH/L, PWH/L, PMH/L)
    UpdateOldHighsLows();

    // 2. Añadir Session Highs/Lows (si están calculados) - Requiere implementación real
    UpdateSessionHighsLows();

    // 3. Detectar Swings y EQH/EQL en M15, H1, H4
    ENUM_TIMEFRAMES tfs[] = {PERIOD_M15, PERIOD_H1, PERIOD_H4};
    int pivotStrength = 2; // Simple fractal de 5 barras

    for(int tf_idx = 0; tf_idx < ArraySize(tfs); tf_idx++)
    {
        ENUM_TIMEFRAMES tf = tfs[tf_idx];
        int totalBars = iBars(Symbol(), tf);
        if(totalBars < SWING_LOOKBACK + pivotStrength*2 + 1) continue; // Necesitamos barras suficientes

        // Almacenar últimos N swing highs/lows para buscar EQH/EQL
        SwingPoint recentSwings[];
        int recentSwingCount = 0;
        int maxRecentSwings = 15; // Guardar los últimos 15 swings por TF

        for(int i = MathMin(totalBars - pivotStrength -1, MAX_LOOKBACK + pivotStrength) ; i >= pivotStrength; i--) // Buscar swings recientes hasta MAX_LOOKBACK + margen
        {
             if(i >= totalBars - pivotStrength) continue; // Evitar índice fuera de rango para i-j

            double currentHigh = iHigh(Symbol(), tf, i);
            double currentLow = iLow(Symbol(), tf, i);
            bool isSwingHigh = true, isSwingLow = true;

            for(int j = 1; j <= pivotStrength; j++)
            {
                // No necesitamos i+j >= totalBars chequeo por el límite del loop (ya cubierto)
                 if(i-j < 0) { // Chequeo límite izquierdo
                    isSwingHigh=false; isSwingLow=false; break;
                 }
                if(iHigh(Symbol(), tf, i + j) > currentHigh || iHigh(Symbol(), tf, i - j) > currentHigh) isSwingHigh = false;
                if(iLow(Symbol(), tf, i + j) < currentLow || iLow(Symbol(), tf, i - j) < currentLow) isSwingLow = false;
                if (!isSwingHigh && !isSwingLow) break;
            }

            if(isSwingHigh)
            {
                // Añadir zona de swing high
                AddLiquidityZone(currentHigh, true, iTime(Symbol(), tf, i), 7.0 + tf_idx, "Swing " + EnumToString(tf));
                // Guardar para EQH/EQL si hay espacio
                if(recentSwingCount < maxRecentSwings) {
                   ArrayResize(recentSwings, recentSwingCount + 1);
                   recentSwings[recentSwingCount].price = currentHigh;
                   recentSwings[recentSwingCount].isHigh = true;
                   recentSwings[recentSwingCount].time = iTime(Symbol(), tf, i);
                   recentSwingCount++;
                }
                 i -= pivotStrength; // Saltar barras dentro del fractal
            }
            else if(isSwingLow)
            {
                 // Añadir zona de swing low
                AddLiquidityZone(currentLow, false, iTime(Symbol(), tf, i), 7.0 + tf_idx, "Swing " + EnumToString(tf));
                // Guardar para EQH/EQL si hay espacio
                 if(recentSwingCount < maxRecentSwings) {
                   ArrayResize(recentSwings, recentSwingCount + 1);
                   recentSwings[recentSwingCount].price = currentLow;
                   recentSwings[recentSwingCount].isHigh = false;
                   recentSwings[recentSwingCount].time = iTime(Symbol(), tf, i);
                   recentSwingCount++;
                 }
                  i -= pivotStrength; // Saltar barras dentro del fractal
            }
        } // Fin loop barras (i)

        // Detectar EQH/EQL dentro de los swings recientes del TF actual
        for(int i = 0; i < recentSwingCount; i++)
        {
            for(int j = i + 1; j < recentSwingCount; j++)
            {
                // Mismo tipo (ambos high o ambos low) y precio muy cercano
                if(recentSwings[i].isHigh == recentSwings[j].isHigh && MathAbs(recentSwings[i].price - recentSwings[j].price) <= eqTolerance)
                {
                    // Encontrado EQH/EQL
                    double eqPrice = (recentSwings[i].price + recentSwings[j].price) / 2.0; // Precio promedio
                    datetime eqTime = MathMax(recentSwings[i].time, recentSwings[j].time); // Tiempo del más reciente
                    double eqStrength = 8.5 + tf_idx; // Alta fuerza para EQH/EQL
                    string eqType = (recentSwings[i].isHigh ? "EQH " : "EQL ") + EnumToString(tf);

                    // Añadir zona EQH/EQL (la función maneja duplicados cercanos)
                    AddLiquidityZone(eqPrice, recentSwings[i].isHigh, eqTime, eqStrength, eqType, eqTolerance);
                }
            }
        } // Fin loop detección EQH/EQL (j)
    } // Fin loop timeframes (tf_idx)

    // Opcional: Ordenar el array final por fuerza o precio si es necesario
    // ...

    // Print("Detectadas ", ArraySize(liquidityZones), " zonas de liquidez finales."); // Opcional
}


void DetectFairValueGaps()
{
   ArrayResize(fairValueGaps, 0);
   int totalM5 = iBars(Symbol(), PERIOD_M5);
   if(totalM5 < 3) return;

   for(int i = 2; i < MathMin(totalM5, 500); i++) // Limitar lookback a 500 barras M5 para eficiencia
   {
      // Vela 0: i-2
      // Vela 1: i-1
      // Vela 2: i
      double c0High = iHigh(Symbol(), PERIOD_M5, i - 2);
      double c0Low  = iLow(Symbol(), PERIOD_M5, i - 2);
      // Vela 1 (vela central) no se usa directamente para definir los límites del FVG
      double c2High = iHigh(Symbol(), PERIOD_M5, i);
      double c2Low  = iLow(Symbol(), PERIOD_M5, i);

      // Bullish FVG (Gap entre High de vela 0 y Low de vela 2)
      if(c0High < c2Low)
      {
         FairValueGap fvg;
         fvg.startPrice = c0High;
         fvg.endPrice = c2Low;
         fvg.isBullish = true;
         int sz = ArraySize(fairValueGaps);
         ArrayResize(fairValueGaps, sz + 1);
         fairValueGaps[sz] = fvg;
      }
      // Bearish FVG (Gap entre Low de vela 0 y High de vela 2)
      else if(c0Low > c2High) // Usar else if para evitar FVGs de 1 pip si H0==L2 etc.
      {
         FairValueGap fvg;
         fvg.startPrice = c2High; // Bearish FVG va de High vela 2
         fvg.endPrice = c0Low;   // a Low vela 0
         fvg.isBullish = false;
         int sz = ArraySize(fairValueGaps);
         ArrayResize(fairValueGaps, sz + 1);
         fairValueGaps[sz] = fvg;
      }
   }
   // Print("Detectados ", ArraySize(fairValueGaps), " Fair Value Gaps (M5)"); // Opcional
}


void DetectOrderBlocks()
{
   ArrayResize(orderBlocks, 0);
   int totalM5 = iBars(Symbol(), PERIOD_M5);
   if(totalM5 < 10) return; // Necesitamos algunas barras

   bool biasBullish = g_H4BiasBullish; // Usar el bias H4 para filtrar OBs
   int maxLookback = 100; // Cuántas velas M5 hacia atrás buscar (podría ser un input)
   // int maxObsToFind = 5; // Original
   int maxObsToFind = MaxOBsToStore; // Usar el input global
   int obsFound = 0;
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double minRangePipsValue = (OB_MinRangePips < 1) ? 1.0 : (double)OB_MinRangePips; // Asegurar mínimo 1 pip
   double minRangePoints = minRangePipsValue * point * (Digits() % 2 == 1 ? 10 : 1);
   if(minRangePoints <= 0 && point > 0) minRangePoints = minRangePipsValue * point; // Para JPY pairs, etc. si el anterior falla
   else if(minRangePoints <= 0) minRangePoints = minRangePipsValue * 0.0001; // Fallback muy genérico

   // Empezar desde la penúltima vela M5 e ir hacia atrás
   for(int i = totalM5 - 2; i >= MathMax(0, totalM5 - maxLookback) && obsFound < maxObsToFind; i--)
   {
       if(i+1 >= totalM5) continue; // Asegurar que i+1 es válido

      double op = iOpen(Symbol(), PERIOD_M5, i);
      double cl = iClose(Symbol(), PERIOD_M5, i);
      bool isCandidateOB = false;
      // Si buscamos OB alcista (bias alcista), la vela candidata es bajista
      if(biasBullish && cl < op) isCandidateOB = true;
      // Si buscamos OB bajista (bias bajista), la vela candidata es alcista
      else if(!biasBullish && cl > op) isCandidateOB = true;

      if(isCandidateOB)
      {
         double nextOpen = iOpen(Symbol(), PERIOD_M5, i+1);
         double nextClose= iClose(Symbol(), PERIOD_M5, i+1);
         double nextHigh = iHigh(Symbol(), PERIOD_M5, i+1);
         double nextLow  = iLow(Symbol(), PERIOD_M5, i+1);
         double candidateHigh = iHigh(Symbol(), PERIOD_M5, i);
         double candidateLow  = iLow(Symbol(), PERIOD_M5, i);

         bool displacement = false;
         double displacementThresholdATR = ComputeATR(PERIOD_M5, 14);
         if (displacementThresholdATR <= 0 && point > 0) displacementThresholdATR = point * 10; // Fallback 10 puntos
         else if (displacementThresholdATR <= 0) displacementThresholdATR = 0.0001 * 10;

         double displacementThreshold = displacementThresholdATR * 0.5; // Requiere 0.5 ATR de desplazamiento

         if(biasBullish && nextClose > candidateHigh + displacementThreshold) displacement = true; // Desplazamiento alcista
         if(!biasBullish && nextClose < candidateLow - displacementThreshold) displacement = true; // Desplazamiento bajista

         if (!displacement) continue; // Ignorar si no hubo desplazamiento claro

         OrderBlock candidateOB; // Crear aquí para pasarla a AssessOBQuality
         candidateOB.isBullish = biasBullish; // El OB es del tipo del bias
         candidateOB.openPrice = op;
         candidateOB.closePrice = cl;
         candidateOB.highPrice = candidateHigh;
         candidateOB.lowPrice = candidateLow;
         candidateOB.time = iTime(Symbol(), PERIOD_M5, i);
         candidateOB.isValid = true;

         if((candidateOB.highPrice - candidateOB.lowPrice) < minRangePoints) candidateOB.isValid = false;

         if(candidateOB.isValid)
         {
           candidateOB.isSwept = IsOBSwept(candidateOB); // Chequear si fue mitigado ANTES de evaluar calidad
           candidateOB.quality = AssessOBQuality(candidateOB); // Calcula calidad (y ahora actualiza volumeRatio y obTickVolume en candidateOB)

           // Solo añadir OBs válidos, de alta calidad y no barridos
           if(!candidateOB.isSwept && candidateOB.quality >= 6.5) // Umbral de calidad (podría ser input)
           {
              int sz = ArraySize(orderBlocks);
              ArrayResize(orderBlocks, sz + 1);
              orderBlocks[sz] = candidateOB; // Guardar el OB evaluado y poblado
              obsFound++;
              // PrintFormat("Detectado OB %s (M5): %s Precio Vela OB: O:%G H:%G L:%G C:%G Calidad:%.1f VolRatio:%.2f VolTick:%d",
              //    (biasBullish ? "Alcista" : "Bajista"),
              //    TimeToString(candidateOB.time),
              //    candidateOB.openPrice, candidateOB.highPrice, candidateOB.lowPrice, candidateOB.closePrice,
              //    candidateOB.quality, candidateOB.volumeRatio, candidateOB.obTickVolume);
           }
         }
      }
   }

   SortOrderBlocksByQuality(); // Ordenar por calidad descendente (calidad ahora incluye mejor evaluación de volumen)
   // Print("Detectados ", ArraySize(orderBlocks), " Order Blocks (M5) válidos y ordenados por calidad.");
}

void DetectBreakerBlocks()
{
    ArrayResize(breakerBlocks, 0);
    int numOrderBlocks = ArraySize(orderBlocks);
    if(numOrderBlocks == 0) return;

    double atrM15 = ComputeATR(PERIOD_M15, 14);
    // double toleranceBase = atrM15 * 0.3; // No usado directamente aquí
    double qualityThreshold = 6.0; // Umbral de calidad

    // Iterar OBs detectados (ya están ordenados por calidad, podríamos limitar la búsqueda)
    for(int i = 0; i < numOrderBlocks; i++)
    {
        OrderBlock ob = orderBlocks[i];
        // Un Breaker se forma cuando un OB falla (es penetrado) y luego el precio revierte creando estructura opuesta
        // Podríamos buscar OBs que SÍ fueron barridos (isSwept = true)
        if(!ob.isSwept) continue; // Considerar solo OBs barridos como candidatos a Breaker

        int obBarIndexM5 = iBarShift(Symbol(), PERIOD_M5, ob.time, false);
        if(obBarIndexM5 < 0) continue;

        int lookforwardBars = 20; // Cuántas barras M5 mirar *después* del barrido del OB
        bool structureShifted = false;
        bool breakerIsBullish = !ob.isBullish; // El Breaker es opuesto al OB original
        double breakerPrice = 0.0;
        datetime breakerTime = 0;
        int shiftBarIndex = -1; // Índice de la barra que confirma el cambio estructural

        // Buscar desde la barra siguiente al OB hacia el presente
        for(int j = obBarIndexM5 - 1; j >= MathMax(0, obBarIndexM5 - lookforwardBars); j--)
        {
            // Buscar BOS/ChoCH en la dirección OPUESTA al OB original después de la mitigación
            // Pasar el índice 'j' donde buscar el BOS/ChoCH
            if(DetectBOS(PERIOD_M5, j, breakerIsBullish, 15) || DetectChoCH(PERIOD_M5, j, breakerIsBullish, 15))
            {
                structureShifted = true;
                shiftBarIndex = j; // Barra que confirma el cambio
                breakerTime = iTime(Symbol(), PERIOD_M5, j); // Tiempo del cambio estructural

                // El precio del Breaker es el High/Low del OB original que falló
                breakerPrice = breakerIsBullish ? ob.highPrice : ob.lowPrice;
                break; // Encontrar el primer cambio estructural post-barrido
            }
        }

        if(structureShifted)
        {
             // Calcular calidad del Breaker (simplificado aquí)
             // Podría incluir volumen del rompimiento, FVG creado, etc.
             double qualityScore = 7.0; // Asignar una calidad base alta a los breakers

             // Validar que el precio actual no haya mitigado ya el Breaker
             // bool isBreakerMitigated = ... (Lógica de mitigación de Breaker) ...

             if(qualityScore >= qualityThreshold /* && !isBreakerMitigated */)
             {
                 BreakerBlock bb;
                 bb.isBullish = breakerIsBullish;
                 bb.price = breakerPrice;
                 bb.obTime = breakerTime; // Guardar tiempo del cambio estructural
                 int sz = ArraySize(breakerBlocks);
                 ArrayResize(breakerBlocks, sz + 1);
                 breakerBlocks[sz] = bb;
                 // Print("Detectado Breaker Block ", (breakerIsBullish ? "Alcista" : "Bajista"), " Precio:", breakerPrice); // Opcional
             }
        }
    }
     // Print("Detectados ", ArraySize(breakerBlocks), " Breaker Blocks."); // Opcional
}


void DetectJudasSwing()
{
   // Placeholder - Implementación requiere lógica de sesión y barrido de H/L clave.
}

bool IsLiquidityZoneConfirmedByVolume(double price, bool isBuySide, datetime time)
{
    // Implementación básica: verificar si el volumen en las barras cercanas
    // a la formación de la zona fue significativamente alto.
    const int VOLUME_LOOKBACK = 5; // Barras a mirar alrededor del tiempo de la zona
    const double VOL_INCREASE_FACTOR = 1.3; // Volumen debe ser X veces el promedio
    const int BARS_FOR_AVG_VOLUME = 20; // Período para calcular el volumen promedio

    int timeBarIndexM5 = iBarShift(Symbol(), PERIOD_M5, time, false);
    if(timeBarIndexM5 < 0 || timeBarIndexM5 >= iBars(Symbol(), PERIOD_M5)) return false;

    // Calcular volumen promedio anterior
    double avgVolume = 0;
    long tickVolSum = 0;
    int validBars = 0;
    for(int i = timeBarIndexM5 + 1; i <= MathMin(iBars(Symbol(), PERIOD_M5) - 1, timeBarIndexM5 + BARS_FOR_AVG_VOLUME); i++)
    {
        tickVolSum += iTickVolume(Symbol(), PERIOD_M5, i);
        validBars++;
    }
    if(validBars == 0) return false;
    avgVolume = (double)tickVolSum / validBars;
    if(avgVolume <= 0) return false;

    // Verificar volumen en las barras cercanas a la formación de la zona
    for(int i = MathMax(0, timeBarIndexM5 - VOLUME_LOOKBACK / 2); i <= MathMin(iBars(Symbol(), PERIOD_M5) - 1, timeBarIndexM5 + VOLUME_LOOKBACK / 2); i++)
    {
        double barVolume = (double)iTickVolume(Symbol(), PERIOD_M5, i);
        if(barVolume > avgVolume * VOL_INCREASE_FACTOR)
        {
             // Opcional: Verificar si la barra tocó la zona de precio
             // double barLow = iLow(Symbol(), PERIOD_M5, i);
             // double barHigh = iHigh(Symbol(), PERIOD_M5, i);
             // if(price >= barLow && price <= barHigh) return true;
            return true; // Volumen alto encontrado cerca de la zona
        }
    }

    return false;
}

bool IsStopLossNearLiquidityLevel(double proposedSL, double proximityRangePips)
{
    if(ArraySize(liquidityZones) == 0 || proximityRangePips <= 0) return false;
    double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
    double proximityRange = proximityRangePips * (point == 0 ? 0.00001 : point) * (Digits() % 2 == 1 ? 10 : 1); // Tolerancia en precio (ajustado)
    if (proximityRange <= 0 && point > 0) proximityRange = proximityRangePips * point;
    else if (proximityRange <= 0) proximityRange = proximityRangePips * 0.0001; // Fallback

    for(int i = 0; i < ArraySize(liquidityZones); i++)
    {
        // Considerar solo zonas de liquidez fuertes (ej: fuerza > 7.5)
        if(liquidityZones[i].strength >= 7.5)
        {
            double dist = MathAbs(liquidityZones[i].price - proposedSL);
            if(dist <= proximityRange)
            {
                // Print("Advertencia: SL propuesto (", proposedSL, ") cerca de zona de liquidez (", liquidityZones[i].price, ", Tipo: ", liquidityZones[i].type, ")"); // Opcional
                return true;
            }
        }
    }
    return false;
}


// *** IMPLEMENTACIÓN DE LA FUNCIÓN CORREGIDA ***
bool IsStopLossDangerouslyNearLiquidity(double proposedSL, bool isLongTrade, double entryPrice, double &adjustedSL_output, double proximityPipsToConsider = 5.0, double adjustmentPips = 3.0)
{
    adjustedSL_output = proposedSL; // Por defecto, no hay ajuste
    if (ArraySize(liquidityZones) == 0 || proximityPipsToConsider <= 0) return false;

    double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
    double pips_factor_calc = (digits == 3 || digits == 5 || digits == 1) ? 10.0 : 1.0;

    double proximityRangePoints = proximityPipsToConsider * point * pips_factor_calc;
    if (proximityRangePoints <= 0 && point > 0) proximityRangePoints = proximityPipsToConsider * point;
    else if (proximityRangePoints <= 0) proximityRangePoints = proximityPipsToConsider * 0.0001; // Fallback

    double adjustmentValuePoints = adjustmentPips * point * pips_factor_calc;
    if (adjustmentValuePoints <= 0 && point > 0) adjustmentValuePoints = adjustmentPips * point;
    else if (adjustmentValuePoints <= 0) adjustmentValuePoints = adjustmentPips * 0.0001; // Fallback


    for (int i = 0; i < ArraySize(liquidityZones); i++)
    {
        // Considerar solo zonas de liquidez fuertes (ej: fuerza > 7.5)
        // Y que estén en el lado "incorrecto" del SL (es decir, que el SL podría ser cazado hacia ellas)
        if (liquidityZones[i].strength < 7.5) continue;

        bool isRelevantZone = false;
        // Para una COMPRA, el SL está ABAJO. Una zona de liquidez de VENTA (un mínimo) debajo del SL es peligrosa.
        if (isLongTrade && !liquidityZones[i].isBuySide && liquidityZones[i].price < proposedSL) {
            isRelevantZone = true;
        }
        // Para una VENTA, el SL está ARRIBA. Una zona de liquidez de COMPRA (un máximo) encima del SL es peligrosa.
        else if (!isLongTrade && liquidityZones[i].isBuySide && liquidityZones[i].price > proposedSL) {
            isRelevantZone = true;
        }

        if(isRelevantZone) {
            double dist = MathAbs(liquidityZones[i].price - proposedSL);
            if (dist <= proximityRangePoints)
            {
                PrintFormat("Advertencia: SL propuesto (%.*f) peligrosamente cerca de liquidez (%.*f, Tipo: %s).",
                            digits, proposedSL, digits, liquidityZones[i].price, liquidityZones[i].type);
                if (isLongTrade) { // Mover SL más abajo
                    adjustedSL_output = liquidityZones[i].price - adjustmentValuePoints;
                } else { // Mover SL más arriba
                    adjustedSL_output = liquidityZones[i].price + adjustmentValuePoints;
                }
                adjustedSL_output = NormalizeDouble(adjustedSL_output, digits);

                // Asegurarse que el nuevo SL no cruce el precio de entrada o se vuelva inválido
                if(isLongTrade && adjustedSL_output >= entryPrice) adjustedSL_output = proposedSL; // Revertir si inválido
                if(!isLongTrade && adjustedSL_output <= entryPrice) adjustedSL_output = proposedSL; // Revertir si inválido

                if(adjustedSL_output != proposedSL) {
                    PrintFormat(">> SL ajustado por peligro de liquidez a: %.*f", digits, adjustedSL_output);
                    return true; // Ajuste realizado
                }
            }
        }
    }
    return false; // No se necesitó ajuste
}


bool DetectStopHunt(double level, bool isBuySideLiquidity, int &huntStrength)
{
    // isBuySideLiquidity: true si 'level' es un nivel de liquidez de compra (un máximo)
    //                   false si 'level' es liquidez de venta (un mínimo)

    double atrM5 = ComputeATR(PERIOD_M5, 14);
    if(atrM5 <= 0) return false;

    // Usar parámetros dinámicos ajustados por volatilidad
    double minPenetrationPoints = atrM5 * dyn_ATRMultiplierForMinPenetration;
    double maxPenetrationPoints = atrM5 * dyn_ATRMultiplierForMaxPenetration;
    int dynamicReversalBars = BaseMinReversalBars + (g_regime == HIGH_VOLATILITY ? 1 : 0);

    huntStrength = 0;
    int lookbackBars = 30; // Aumentar lookback para buscar penetración
    int penetrationBar = -1; // Índice de la barra M5 que penetró el nivel
    double penetrationPrice = 0; // Precio exacto de la penetración (High o Low)
    double penetrationDepth = 0; // Cuánto penetró más allá del nivel (en puntos)

    for(int i = 1; i < lookbackBars && i < iBars(Symbol(), PERIOD_M5); i++) // Empezar desde la vela anterior (shift=1)
    {
        if(isBuySideLiquidity) // Buscamos ruptura del HIGH
        {
            double high = iHigh(Symbol(), PERIOD_M5, i);
            // Penetración: high > level Y high no excede level + maxPenetration
            if(high > level && high <= level + maxPenetrationPoints)
            {
                if(penetrationBar == -1 || high > penetrationPrice) // Guardar la penetración más alta
                {
                   penetrationBar = i;
                   penetrationPrice = high;
                   penetrationDepth = high - level;
                }
            }
        }
        else // Buscamos ruptura del LOW
        {
            double low = iLow(Symbol(), PERIOD_M5, i);
            // Penetración: low < level Y low no excede level - maxPenetration
            if(low < level && low >= level - maxPenetrationPoints)
            {
                 if(penetrationBar == -1 || low < penetrationPrice) // Guardar la penetración más baja
                 {
                     penetrationBar = i;
                     penetrationPrice = low;
                     penetrationDepth = level - low;
                 }
            }
        }
        // Si encontramos una penetración válida mínima, podríamos dejar de buscar más atrás
        // if (penetrationBar != -1 && penetrationDepth >= minPenetrationPoints) break;
    }

    // Validar si se encontró una penetración y si fue suficiente
    if(penetrationBar == -1 || penetrationDepth < minPenetrationPoints) return false;

    // --- Confirmación de Reversión ---
    // Verificar si las velas *después* de la penetración (índices < penetrationBar) cerraron de vuelta al otro lado del nivel
    bool reversalConfirmed = false;
    double reversalMagnitude = 0; // Cuánto revirtió el precio desde el extremo de la penetración
    int barsChecked = 0;
    for (int k = penetrationBar - 1; k >= MathMax(0, penetrationBar - dynamicReversalBars - 1); k--) // Mirar las siguientes N barras
    {
        barsChecked++;
        double closeK = iClose(Symbol(), PERIOD_M5, k);

        if(isBuySideLiquidity) // Penetró HIGH, buscamos cierre ABAJO del nivel
        {
            if(closeK < level)
            {
               // Calcular magnitud desde el High de la penetración hasta el Low más bajo de la reversión
               double lowestLowAfter = iLow(Symbol(), PERIOD_M5, k);
               // Buscar el low más bajo desde k hasta la barra ANTERIOR a la penetración (exclusive)
               for(int l=k+1; l < penetrationBar; l++) lowestLowAfter = MathMin(lowestLowAfter, iLow(Symbol(), PERIOD_M5,l));
               // NO incluir barra de penetración en el low de la reversión

               reversalMagnitude = penetrationPrice - lowestLowAfter;
               if (penetrationDepth > 0 && (reversalMagnitude / penetrationDepth * 100.0) >= REVERSAL_STRENGTH_PERCENT) {
                  reversalConfirmed = true;
                  break; // Reversión confirmada
               }
            }
        }
        else // Penetró LOW, buscamos cierre ARRIBA del nivel
        {
            if(closeK > level)
            {
                // Calcular magnitud desde el Low de la penetración hasta el High más alto de la reversión
               double highestHighAfter = iHigh(Symbol(), PERIOD_M5, k);
               for(int l=k+1; l < penetrationBar; l++) highestHighAfter = MathMax(highestHighAfter, iHigh(Symbol(), PERIOD_M5,l));

               reversalMagnitude = highestHighAfter - penetrationPrice;
               if (penetrationDepth > 0 && (reversalMagnitude / penetrationDepth * 100.0) >= REVERSAL_STRENGTH_PERCENT) {
                  reversalConfirmed = true;
                  break; // Reversión confirmada
               }
            }
        }
        if (barsChecked >= dynamicReversalBars) break; // No buscar más allá de las barras de confirmación
    }


    if(reversalConfirmed)
    {
        // Calcular Fuerza del Hunt (simplificado)
        huntStrength = 5; // Base
        if (reversalMagnitude > atrM5 * 1.5) huntStrength += 2; // Reversión fuerte

        // Volumen: Comprobar si el volumen aumentó en la reversión comparado con la penetración
        long penetrationVol = iTickVolume(Symbol(), PERIOD_M5, penetrationBar);
        double avgReversalVol = 0;
        long reversalVolSum = 0;
        int volCount = 0;
        for(int k=penetrationBar-1; k >= MathMax(0, penetrationBar - dynamicReversalBars -1); k--) // Barras post-penetración
        {
           reversalVolSum += iTickVolume(Symbol(), PERIOD_M5, k);
           volCount++;
        }
        if(volCount>0) avgReversalVol = (double)reversalVolSum / volCount;

        if(penetrationVol > 0 && avgReversalVol > penetrationVol * VolumeDivergenceMultiplier) huntStrength += 3; // Divergencia de volumen fuerte

        huntStrength = MathMin(huntStrength, 10);
        // Print("Stop Hunt Detectado: Nivel=", level, " Liquidez=", (isBuySideLiquidity?"Compra":"Venta"), " Fuerza=", huntStrength); // Opcional
    }

    return reversalConfirmed;
}


//+------------------------------------------------------------------+
//| Funciones de Estructura de Mercado y Bias                        |
//+------------------------------------------------------------------+

// Función Unificada para Detectar Estructura (BOS/ChoCH) -> Lógica Secuencia Swings
MarketStructureState DetectMarketStructure(ENUM_TIMEFRAMES tf, int lookbackBars, int pivotStrength)
{
    int totalBars = iBars(Symbol(), tf);
    if(totalBars < lookbackBars + pivotStrength + 2) return MSS_UNKNOWN;

    SwingPoint swings[];
    ArrayResize(swings, 0);
    int swingsToFind = 10; // Buscar más swings para análisis más robusto

    // 1. Encontrar Swing Points (Fractales)
    for(int i = MathMin(totalBars - pivotStrength - 1, lookbackBars + pivotStrength) ; i >= pivotStrength && ArraySize(swings) < swingsToFind ; i--)
    {
        if(i >= totalBars - pivotStrength || i < pivotStrength) continue; // Asegurar índices válidos para j

        double currentHigh = iHigh(Symbol(), tf, i);
        double currentLow = iLow(Symbol(), tf, i);
        bool isSwingHigh = true, isSwingLow = true;

        for(int j = 1; j <= pivotStrength; j++)
        {
             if(iHigh(Symbol(), tf, i + j) >= currentHigh || iHigh(Symbol(), tf, i - j) >= currentHigh) isSwingHigh = false; // Usar >= para evitar EQH como swing
             if(iLow(Symbol(), tf, i + j) <= currentLow || iLow(Symbol(), tf, i - j) <= currentLow) isSwingLow = false;    // Usar <= para evitar EQL como swing
             if(!isSwingHigh && !isSwingLow) break;
        }

        if(isSwingHigh)
        {
           int sz = ArraySize(swings);
           ArrayResize(swings, sz+1);
           swings[sz].time = iTime(Symbol(), tf, i);
           swings[sz].price = currentHigh;
           swings[sz].isHigh = true;
           i = i - pivotStrength; // Saltar barras dentro del fractal encontrado
        }
        else if(isSwingLow)
        {
           int sz = ArraySize(swings);
           ArrayResize(swings, sz+1);
           swings[sz].time = iTime(Symbol(), tf, i);
           swings[sz].price = currentLow;
           swings[sz].isHigh = false;
           i = i - pivotStrength; // Saltar barras dentro del fractal encontrado
        }
    }

    if(ArraySize(swings) < 4) return MSS_UNKNOWN; // Necesitamos al menos 4 puntos para definir tendencia

    // Ordenar swings por tiempo (más RECIENTE primero) - Bubble sort simple
    for(int i = 0; i < ArraySize(swings)-1; i++)
    {
       for(int j = 0; j < ArraySize(swings)-1-i; j++)
       {
          if(swings[j].time < swings[j+1].time) // Cambiado a < para más reciente primero
          {
             SwingPoint tmp = swings[j];
             swings[j] = swings[j+1];
             swings[j+1] = tmp;
          }
       }
    }

    // 2. Analizar la secuencia de los últimos 4 swings (más recientes)
    SwingPoint p4 = swings[0]; // Más reciente
    SwingPoint p3 = swings[1];
    SwingPoint p2 = swings[2];
    SwingPoint p1 = swings[3]; // Más antiguo de los 4

    // Verificar secuencia alternante H-L-H-L o L-H-L-H
    if(p4.isHigh == p2.isHigh || p3.isHigh == p1.isHigh || p4.isHigh == p3.isHigh) return MSS_RANGE; // No alternante -> Rango/Indefinido

    // Tendencia Alcista: Higher Highs (HH) y Higher Lows (HL)
    // p4(H) > p2(H) AND p3(L) > p1(L)
    if(p4.isHigh && !p3.isHigh) // Último es High, anterior Low (H-L-H-L)
    {
       if(p4.price > p2.price && p3.price > p1.price) return MSS_BULLISH;
       // Cambio estructural potencial (ChoCH bajista implícito: p4(H) > p2(H) pero p3(L) < p1(L) o p4(H) < p2(H))
       if(p4.price < p2.price || p3.price < p1.price) return MSS_BEARISH; // O al menos cambio hacia rango/bajista
    }
    // Tendencia Bajista: Lower Highs (LH) y Lower Lows (LL)
    // p3(H) < p1(H) AND p4(L) < p2(L)
    else if(!p4.isHigh && p3.isHigh) // Último es Low, anterior High (L-H-L-H)
    {
       if(p3.price < p1.price && p4.price < p2.price) return MSS_BEARISH;
       // Cambio estructural potencial (ChoCH alcista implícito: p3(H) < p1(H) pero p4(L) > p2(L) o p3(H) > p1(H))
       if(p3.price > p1.price || p4.price > p2.price) return MSS_BULLISH; // O al menos cambio hacia rango/alcista
    }

    // Si no cumple patrones claros de tendencia o cambio, considerar rango
    return MSS_RANGE;
}

// Funciones wrapper para M15 y H1
MarketStructureState DetectMarketStructureM15(int lookbackBars, int pivotStrength) { return DetectMarketStructure(PERIOD_M15, lookbackBars, pivotStrength); }
MarketStructureState DetectMarketStructureH1(int lookbackBars, int pivotStrength) { return DetectMarketStructure(PERIOD_H1, lookbackBars, pivotStrength); }


// Función Unificada para BOS - Reimplementada para claridad
bool DetectBOS(ENUM_TIMEFRAMES tf, int barIndex, bool isBullish, int lookback=30)
{
    int totalBars = Bars(Symbol(), tf);
    if (barIndex < 0 || barIndex >= totalBars) return false; // barIndex debe ser válido

    // 1. Encontrar el último swing relevante OPUESTO al BOS esperado, ANTERIOR a barIndex
    int lastOppositeSwingIdx = -1;
    double lastOppositeSwingPrice = 0;
    int pivotStrength = 2; // Fractal 5 barras

    // Buscar hacia atrás desde barIndex + 1
    for(int i = barIndex + 1; i <= barIndex + lookback; i++)
    {
         if (i >= totalBars - pivotStrength || i < pivotStrength) break; // Asegurar espacio para fractal

         bool isSwing = true;
         double price = !isBullish ? iHigh(Symbol(), tf, i) : iLow(Symbol(), tf, i); // Swing opuesto

         for(int j=1; j<=pivotStrength; j++){
            // Check i+j and i-j validity implicitly covered by outer loop bounds check
            if(!isBullish && (iHigh(Symbol(), tf, i+j) > price || iHigh(Symbol(), tf, i-j) > price)) {isSwing = false; break;}
            if(isBullish && (iLow(Symbol(), tf, i+j) < price || iLow(Symbol(), tf, i-j) < price)) {isSwing = false; break;}
         }
         if (isSwing) {
             lastOppositeSwingIdx = i;
             lastOppositeSwingPrice = price;
             break; // Encontrar el más reciente anterior a barIndex
         }
    }
    if (lastOppositeSwingIdx == -1) return false; // No se encontró swing opuesto

    // 2. Encontrar el swing del MISMO tipo que el BOS, ANTERIOR al swing opuesto encontrado
    int relevantSwingIdx = -1;
    double relevantSwingPrice = 0;
    for(int i = lastOppositeSwingIdx + 1; i <= lastOppositeSwingIdx + lookback; i++) // Buscar más atrás
    {
         if (i >= totalBars - pivotStrength || i < pivotStrength) break;

         bool isSwing = true;
         double price = isBullish ? iHigh(Symbol(), tf, i) : iLow(Symbol(), tf, i); // Mismo tipo que BOS

         for(int j=1; j<=pivotStrength; j++){
            if(isBullish && (iHigh(Symbol(), tf, i+j) > price || iHigh(Symbol(), tf, i-j) > price)) {isSwing = false; break;}
            if(!isBullish && (iLow(Symbol(), tf, i+j) < price || iLow(Symbol(), tf, i-j) < price)) {isSwing = false; break;}
         }
         if (isSwing) {
             relevantSwingIdx = i;
             relevantSwingPrice = price;
             break; // Encontrar el más reciente anterior al opuesto
         }
    }
    if (relevantSwingIdx == -1) return false; // No se encontró swing del mismo tipo

    // 3. Verificar si la vela en barIndex rompió el swing relevante del mismo tipo (relevantSwingPrice)
    if (isBullish)
        return iHigh(Symbol(), tf, barIndex) > relevantSwingPrice; // Rompimiento del High
    else
        return iLow(Symbol(), tf, barIndex) < relevantSwingPrice; // Rompimiento del Low
}

// Función Unificada para ChoCH - Reimplementada para claridad
bool DetectChoCH(ENUM_TIMEFRAMES tf, int barIndex, bool isBullish, int lookback=30)
{
     int totalBars = Bars(Symbol(), tf);
     if (barIndex < 0 || barIndex >= totalBars) return false;

    // 1. Encontrar el último swing relevante del MISMO tipo que el ChoCH esperado, ANTERIOR a barIndex
    int lastSameTypeSwingIdx = -1;
    double lastSameTypeSwingPrice = 0;
    int pivotStrength = 2;

    // Buscar hacia atrás desde barIndex + 1
    for(int i = barIndex + 1; i <= barIndex + lookback; i++)
    {
         if (i >= totalBars - pivotStrength || i < pivotStrength) break;

         bool isSwing = true;
         double price = isBullish ? iHigh(Symbol(), tf, i) : iLow(Symbol(), tf, i); // Mismo tipo

         for(int j=1; j<=pivotStrength; j++){
             if(isBullish && (iHigh(Symbol(), tf, i+j) > price || iHigh(Symbol(), tf, i-j) > price)) {isSwing = false; break;}
             if(!isBullish && (iLow(Symbol(), tf, i+j) < price || iLow(Symbol(), tf, i-j) < price)) {isSwing = false; break;}
         }
         if (isSwing) {
             lastSameTypeSwingIdx = i;
             lastSameTypeSwingPrice = price;
             break; // Encontrar el más reciente anterior a barIndex
         }
    }
    if (lastSameTypeSwingIdx == -1) return false; // No se encontró swing del mismo tipo

    // 2. Encontrar el swing OPUESTO, ANTERIOR al swing del mismo tipo encontrado
    int relevantOppositeSwingIdx = -1;
    double relevantOppositeSwingPrice = 0;
    for(int i = lastSameTypeSwingIdx + 1; i <= lastSameTypeSwingIdx + lookback; i++) // Buscar más atrás
    {
         if (i >= totalBars - pivotStrength || i < pivotStrength) break;

         bool isSwing = true;
         double price = !isBullish ? iHigh(Symbol(), tf, i) : iLow(Symbol(), tf, i); // Tipo opuesto

         for(int j=1; j<=pivotStrength; j++){
             if(!isBullish && (iHigh(Symbol(), tf, i+j) > price || iHigh(Symbol(), tf, i-j) > price)) {isSwing = false; break;}
             if(isBullish && (iLow(Symbol(), tf, i+j) < price || iLow(Symbol(), tf, i-j) < price)) {isSwing = false; break;}
         }
         if (isSwing) {
             relevantOppositeSwingIdx = i;
             relevantOppositeSwingPrice = price;
             break; // Encontrar el más reciente anterior al del mismo tipo
         }
    }
     if (relevantOppositeSwingIdx == -1) return false; // No se encontró swing opuesto

    // 3. Verificar si la vela en barIndex rompió el swing opuesto relevante (relevantOppositeSwingPrice)
    if (isBullish) // ChoCH Alcista rompe el último LH relevante
        return iHigh(Symbol(), tf, barIndex) > relevantOppositeSwingPrice;
    else          // ChoCH Bajista rompe el último HL relevante
        return iLow(Symbol(), tf, barIndex) < relevantOppositeSwingPrice;
}

// Wrappers M15
bool DetectBOS_M15(bool isBullish) { return DetectBOS(PERIOD_M15, 1, isBullish); } // Detectar en la vela cerrada anterior
bool DetectChoCH_M15(bool isBullish) { return DetectChoCH(PERIOD_M15, 1, isBullish); }


// Funciones de Bias
void ComputeH4Bias()
{
   int adxPeriod = 14; // Podría hacerse dinámico GetDynamicADXPeriod();
   double adxVal, plusDiVal, minusDiVal;
   // Usar vela cerrada (shift=1) para evitar cambios intra-vela
   if(!GetADXValues(Symbol(), PERIOD_H4, adxPeriod, 1, adxVal, plusDiVal, minusDiVal))
   {
      // Mantener el sesgo anterior si falla la lectura
      // Print("Fallo ADX en H4. Mantengo sesgo anterior."); // Opcional
      return;
   }

   double ema20 = GetEMAValue(Symbol(), PERIOD_H4, 20, 1); // Vela cerrada
   double ema50 = GetEMAValue(Symbol(), PERIOD_H4, 50, 1); // Vela cerrada
   if (ema20 == 0.0 || ema50 == 0.0) return; // No calcular si EMAs fallan
   double closePrice = iClose(Symbol(), PERIOD_H4, 1); // Vela cerrada

   // Condiciones más estrictas: Necesita tendencia y alineación de EMAs/DI
   bool strongTrend = (adxVal >= 23.0); // Umbral ADX un poco más alto
   bool diBullish   = (plusDiVal > minusDiVal + 2); // DI+ claramente por encima de DI-
   bool diBearish   = (minusDiVal > plusDiVal + 2); // DI- claramente por encima de DI+
   bool emaBullish  = (closePrice > ema20 && ema20 > ema50);
   bool emaBearish  = (closePrice < ema20 && ema20 < ema50);

   // Determinar sesgo
   if(strongTrend && diBullish && emaBullish) g_H4BiasBullish = true;
   else if(strongTrend && diBearish && emaBearish) g_H4BiasBullish = false;
   // else: Si no hay tendencia fuerte o hay señales mixtas, MANTENER el sesgo H4 anterior.
   // Print("Sesgo H4: ", g_H4BiasBullish ? "BULLISH" : "BEARISH"); // Opcional
}


void ComputeD1Bias()
{
    int adxPeriod = 14;
    double adxVal, plusDiVal, minusDiVal;
    if(!GetADXValues(Symbol(), PERIOD_D1, adxPeriod, 1, adxVal, plusDiVal, minusDiVal)) // Vela cerrada
    {
        // Mantener sesgo anterior si falla
        return;
    }

    double ema20 = GetEMAValue(Symbol(), PERIOD_D1, 20, 1); // Vela cerrada
    double ema50 = GetEMAValue(Symbol(), PERIOD_D1, 50, 1); // Vela cerrada
    if (ema20 == 0.0 || ema50 == 0.0) return;
    double closePrice = iClose(Symbol(), PERIOD_D1, 1); // Vela cerrada

    bool strongTrend = (adxVal >= 23.0);
    bool diBullish   = (plusDiVal > minusDiVal + 2);
    bool diBearish   = (minusDiVal > plusDiVal + 2);
    bool emaBullish  = (closePrice > ema20 && ema20 > ema50);
    bool emaBearish  = (closePrice < ema20 && ema20 < ema50);

    if(strongTrend && diBullish && emaBullish) g_D1BiasBullish = true;
    else if(strongTrend && diBearish && emaBearish) g_D1BiasBullish = false;
    // else: Mantener sesgo D1 anterior si no hay claridad

    // Print("Sesgo D1: ", g_D1BiasBullish ? "BULLISH" : "BEARISH"); // Opcional
}

bool ComputeH1Bias() // Similar a H4 pero en H1
{
    int adxPeriod = 14;
    double adxVal, plusDiVal, minusDiVal;
    if(!GetADXValues(Symbol(), PERIOD_H1, adxPeriod, 1, adxVal, plusDiVal, minusDiVal))
    {
        // Print("Fallo ADX en H1. Usando sesgo H4."); // Opcional
        return g_H4BiasBullish; // Devolver sesgo H4 si H1 falla
    }

    double ema20 = GetEMAValue(Symbol(), PERIOD_H1, 20, 1);
    double ema50 = GetEMAValue(Symbol(), PERIOD_H1, 50, 1);
    if (ema20 == 0.0 || ema50 == 0.0) return g_H4BiasBullish; // Fallback a H4 si EMAs fallan
    double closePrice = iClose(Symbol(), PERIOD_H1, 1);

    bool strongTrend = (adxVal >= 23.0);
    bool diBullish   = (plusDiVal > minusDiVal + 2);
    bool diBearish   = (minusDiVal > plusDiVal + 2);
    bool emaBullish  = (closePrice > ema20 && ema20 > ema50);
    bool emaBearish  = (closePrice < ema20 && ema20 < ema50);

    if(strongTrend && diBullish && emaBullish) return true;  // H1 Bullish
    else if(strongTrend && diBearish && emaBearish) return false; // H1 Bearish
    else return g_H4BiasBullish; // Si H1 no es claro, usar sesgo H4
}

// Comprueba si la entrada propuesta coincide con H1 (o H4 si H1 no es claro)
bool IsH1BiasAligned(bool isBullishEntry)
{
    bool h1BiasIsBullish = ComputeH1Bias(); // Obtiene el sesgo H1 (o H4 si H1 falla)
    return (isBullishEntry == h1BiasIsBullish);
}

bool ComputeM30Bias()
{
    // Placeholder o implementación simple
    double close = iClose(Symbol(), PERIOD_M30, 1);
    double ema = GetEMAValue(Symbol(), PERIOD_M30, 20, 1);
    if (ema == 0) return g_H4BiasBullish; // Fallback
    return (close > ema);
}

//+------------------------------------------------------------------+
//| Funciones de Gestión de Órdenes y Riesgo                         |
//+------------------------------------------------------------------+

// *** NUEVO: Almacenamiento de Volumen Inicial ***
// Buscar índice de un ticket en el array global
int FindTicketIndex(ulong ticket) {
    for(int i = 0; i < ArraySize(g_positionTickets); i++) {
        if(g_positionTickets[i] == ticket) return i;
    }
    return -1; // No encontrado
}

// Almacenar volumen inicial para un ticket
void StoreInitialVolume(ulong ticket, double volume) {
    int index = FindTicketIndex(ticket);
    if(index == -1) { // Si no existe, añadir
        int size = ArraySize(g_positionTickets);
        ArrayResize(g_positionTickets, size + 1);
        ArrayResize(g_initialVolumes, size + 1);
        g_positionTickets[size] = ticket;
        g_initialVolumes[size] = volume;
        //Print("Volumen inicial ", volume, " almacenado para ticket ", ticket); // Debug
    } else { // Si ya existe (poco probable, pero por si acaso), actualizar
        g_initialVolumes[index] = volume;
         //Print("Volumen inicial ", volume, " actualizado para ticket ", ticket); // Debug
    }
}

// Obtener volumen inicial para un ticket
double GetStoredInitialVolume(ulong ticket) {
    int index = FindTicketIndex(ticket);
    if(index != -1) {
        return g_initialVolumes[index];
    }
    //Print("Advertencia: No se encontró volumen inicial para ticket ", ticket); // Debug
    return 0.0; // Retornar 0 si no se encuentra
}

// Eliminar un ticket y su volumen del almacenamiento (cuando la posición se cierra)
void RemoveStoredVolume(ulong ticket) {
    int index = FindTicketIndex(ticket);
    if(index != -1) {
        int lastIdx = ArraySize(g_positionTickets) - 1;
        // Mover el último elemento a la posición del eliminado (si no es el último)
        if (index != lastIdx) {
             g_positionTickets[index] = g_positionTickets[lastIdx];
             g_initialVolumes[index] = g_initialVolumes[lastIdx];
        }
        // Reducir tamaño de los arrays
        ArrayResize(g_positionTickets, lastIdx);
        ArrayResize(g_initialVolumes, lastIdx);
         //Print("Volumen almacenado eliminado para ticket ", ticket); // Debug
    }
}
// *** FIN Almacenamiento de Volumen Inicial ***


double CalculateLotSize()
{
   string sym = Symbol();
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0) return SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN); // Salir si no hay balance

   double riskPercent = 0.5; // 0.5% de riesgo por trade (ajustable)
   double maxRiskAmount = (riskPercent / 100.0) * balance;

   // Usar StopLossPips del input como base para el cálculo
   double slPipsValue = (StopLossPips < 5) ? 5.0 : (double)StopLossPips; // SL mínimo de 5 pips
   if (slPipsValue <= 0) slPipsValue = 10.0; // Fallback si input es inválido

   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(point <= 0) return SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN); // Salir si falla point

   // Intentar obtener Tick Value y Size directamente
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);

   // Si fallan, intentar calcular (Forex principalmente)
   if(tickValue <=0 || tickSize <=0) {
       double lotSize = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
       string profitCurrency = SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);
       string accountCurrency = AccountInfoString(ACCOUNT_CURRENCY);

       if (lotSize > 0 && profitCurrency != "" && accountCurrency != "") {
           if (profitCurrency == accountCurrency) { // Cotización directa (ej: EURUSD en cuenta EUR)
               tickValue = point * lotSize;
               tickSize = point;
           } else { // Necesita conversión
               string conversionPair1 = profitCurrency + accountCurrency; // Ej: USDJPY
               string conversionPair2 = accountCurrency + profitCurrency; // Ej: JPYUSD
               double rate1 = SymbolInfoDouble(conversionPair1, SYMBOL_ASK); // Usar Ask para convertir coste
               double rate2 = SymbolInfoDouble(conversionPair2, SYMBOL_ASK);

               if(rate1 > 0) { // Si existe el par directo (Profit -> Account)
                  tickValue = point * lotSize * rate1;
                  tickSize = point;
               } else if (rate2 > 0) { // Si existe el par inverso (Account -> Profit)
                  tickValue = point * lotSize / rate2; // Dividir por la tasa inversa
                  tickSize = point;
               }
               // Si no se encuentra par de conversión, tickValue permanecerá 0 o negativo
           }
       }
       // Si el cálculo falla, usar fallback muy genérico (poco fiable)
       if (tickValue <= 0) {
           tickValue = point * 100000; // Asume contrato 100k (Forex estándar)
           tickSize = point;
           Print("Advertencia: No se pudo calcular Tick Value para ", sym, ". Usando fallback genérico.");
       }
   }

   // Calcular valor del pip en la moneda de la cuenta
   double pipValueInAccountCurrency = 0;
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double pipSize = (digits == 3 || digits == 5 || digits == 1) ? point * 10 : point; // Ajuste para JPY y otros
   if (tickSize > 0) {
     pipValueInAccountCurrency = (tickValue / tickSize) * pipSize;
   }

   if(pipValueInAccountCurrency <= 0) {
        Print("Error calculando pip value para ", sym, ". Usando lote mínimo.");
        return SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   }

   double lotBasedOnRisk = maxRiskAmount / (slPipsValue * pipValueInAccountCurrency);

   // Ajustar a mínimo, máximo y step del broker
   double minVolume = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxVolume = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double volumeStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

   if (minVolume <= 0 || volumeStep <=0 || maxVolume <=0) {
         Print("Error obteniendo info de volumen para ", sym, ". Usando 0.01.");
         minVolume = 0.01; volumeStep = 0.01; maxVolume = 100; // Fallbacks comunes
    }


   double finalLot = lotBasedOnRisk;
   if (finalLot < minVolume) finalLot = minVolume;
   if (finalLot > maxVolume) finalLot = maxVolume;

   // Redondear hacia abajo al step más cercano
   finalLot = MathFloor(finalLot / volumeStep) * volumeStep;

   // Limitar por el input del usuario si es menor que el calculado por riesgo
   if (LotSize > 0 && finalLot > LotSize) finalLot = LotSize; // Solo limitar si LotSize es positivo

   // Asegurarse de que no sea menor que el mínimo después de la limitación del input y redondear de nuevo
   if (finalLot < minVolume) finalLot = minVolume;
   finalLot = MathFloor(finalLot / volumeStep) * volumeStep; // Redondear de nuevo por si LotSize no era múltiplo del step

   // Última verificación contra cero
   if (finalLot <= 0) finalLot = minVolume;

   return NormalizeDouble(finalLot, 2); // Normalizar a 2 decimales
}

// Nueva función auxiliar para llamar desde OnInit con valores potencialmente corregidos
void UpdateDynamicRiskRewardRatiosOnInit(ENUM_TIMEFRAMES tf_param,       // Renombrado para evitar conflicto
                                      double lowFactor_param,    // Renombrado
                                      double medFactor_param,    // Renombrado
                                      double highFactor_param,   // Renombrado
                                      int atrPeriod_param,      // Renombrado
                                      int atrAvgPeriod_param,   // Renombrado
                                      double lowThr_param,       // Renombrado
                                      double highThr_param,      // Renombrado
                                      double baseMinRR_param,    // Renombrado
                                      double baseMaxRR_param)    // Renombrado
{
    // Asignar los valores base PASADOS COMO PARÁMETROS
    g_dyn_MinRR_ForKeyLevelTP = baseMinRR_param;
    g_dyn_MaxRR_ForKeyLevelTP = baseMaxRR_param;

    // No necesitamos el check de UseDynamicRRAdjust aquí porque se llama condicionalmente desde OnInit

    double atrCurrent = ComputeATR(tf_param, atrPeriod_param, 1);
    if (atrCurrent <= 0) {
        PrintFormat("UpdateDynamicRiskRewardRatiosOnInit: ATR de %s inválido. Se usarán R:R base.", EnumToString(tf_param));
        return; // g_dyn_... ya tienen los baseMinRR_param y baseMaxRR_param
    }

    double sumAtr = 0; int countAtr = 0;
    for (int i = 2; i <= atrAvgPeriod_param + 1; i++) {
        double pastAtr = ComputeATR(tf_param, atrPeriod_param, i);
        if (pastAtr > 0) { sumAtr += pastAtr; countAtr++; }
    }
    if (countAtr == 0) {
        PrintFormat("UpdateDynamicRiskRewardRatiosOnInit: No se pudo promediar ATR de %s. Se usarán R:R base.", EnumToString(tf_param));
        return; // g_dyn_... ya tienen los baseMinRR_param y baseMaxRR_param
    }
    double atrAvg = sumAtr / countAtr;

    MarketRegime volRegime;
    if (atrCurrent < atrAvg * lowThr_param) volRegime = LOW_VOLATILITY;
    else if (atrCurrent > atrAvg * highThr_param) volRegime = HIGH_VOLATILITY;
    else volRegime = RANGE_MARKET; // "MEDIA"

    double factorToApply = medFactor_param;
    if(volRegime == HIGH_VOLATILITY) factorToApply = highFactor_param;
    else if(volRegime == LOW_VOLATILITY) factorToApply = lowFactor_param;

    g_dyn_MinRR_ForKeyLevelTP = baseMinRR_param * factorToApply;
    g_dyn_MaxRR_ForKeyLevelTP = baseMaxRR_param * factorToApply;

    // Asegurar límites
    g_dyn_MinRR_ForKeyLevelTP = MathMax(0.5, g_dyn_MinRR_ForKeyLevelTP);
    g_dyn_MaxRR_ForKeyLevelTP = MathMax(g_dyn_MinRR_ForKeyLevelTP + 0.5, g_dyn_MaxRR_ForKeyLevelTP);
    g_dyn_MaxRR_ForKeyLevelTP = MathMin(15.0, g_dyn_MaxRR_ForKeyLevelTP);

    PrintFormat("OnInit - R:R Dinámico Inicializado: Vol de %s. MinRR: %.2f, MaxRR: %.2f",
       EnumToString(tf_param), g_dyn_MinRR_ForKeyLevelTP, g_dyn_MaxRR_ForKeyLevelTP);
}

bool OpenTradeSimple(bool isLong, double lot, double priceSignalOrigin, double initialStopLoss, string comment)
{
   double point_val = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   int    digits_val = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);

   if (point_val <= 0) {
        PrintFormat("OpenTradeSimple ERROR: SYMBOL_POINT no es válido (%.*f) para %s. Abortando.", digits_val, point_val, Symbol());
        return false;
   }

   PrintFormat("OpenTradeSimple: Intento op %s. Lote: %.2f, OrigenPrecio: %.*f, SLInicial: %.*f, Comentario: '%s'",
               (isLong ? "COMPRA" : "VENTA"), lot,
               digits_val, priceSignalOrigin,
               digits_val, initialStopLoss,
               comment);

   if(lot <= 0) {
      PrintFormat("OpenTradeSimple: Lote inválido (%.2f). Abortando.", lot);
      return false;
   }
   lot = NormalizeDouble(lot, 2);

   double actualEntryPrice = SymbolInfoDouble(Symbol(), isLong ? SYMBOL_ASK : SYMBOL_BID);
   if(actualEntryPrice == 0.0) {
       PrintFormat("OpenTradeSimple: No se pudo obtener el precio de mercado actual (Ask/Bid) para %s. Abortando.", Symbol());
       return false;
   }
   PrintFormat("OpenTradeSimple: Precio actual de mercado para %s: %.*f", (isLong ? "Ask" : "Bid"), digits_val, actualEntryPrice);


   double finalStopLoss = initialStopLoss;
   double adjustedSLByLiquidity = finalStopLoss;

   if (UseKeyLevelsForSLTP) {
        if (IsStopLossDangerouslyNearLiquidity(finalStopLoss, isLong, actualEntryPrice, adjustedSLByLiquidity, StopHuntBufferPips, StopHuntBufferPips + 2.0)) {
            PrintFormat(">> OpenTradeSimple: SL original %.*f ajustado por cercanía a liquidez a %.*f", digits_val, finalStopLoss, digits_val, adjustedSLByLiquidity);
            finalStopLoss = adjustedSLByLiquidity;
        }
   }
   else if (StopHuntBufferPips > 0 && IsStopLossNearLiquidityLevel(finalStopLoss, StopHuntBufferPips)) {
        double smartBufferPipsValue = StopHuntBufferPips;
        double pipMonetaryValueSL = (digits_val == 3 || digits_val == 5 || digits_val == 1) ? point_val * 10 : point_val;
        double smartBufferValue = smartBufferPipsValue * pipMonetaryValueSL;

        if (smartBufferValue <= 0 && smartBufferPipsValue > 0 && point_val > 0) smartBufferValue = smartBufferPipsValue * point_val;
        else if (smartBufferValue <= 0 && smartBufferPipsValue > 0) smartBufferValue = smartBufferPipsValue * (digits_val <=3 ? 0.01 : 0.0001);
        
        if(smartBufferValue > 0) {
            finalStopLoss = isLong ? finalStopLoss - smartBufferValue : finalStopLoss + smartBufferValue;
            PrintFormat(">> OpenTradeSimple (Buffer SL Simple): SL original %.*f ajustado a %.*f", digits_val, initialStopLoss, digits_val, finalStopLoss);
        }
   }

   double riskInPrice = MathAbs(actualEntryPrice - finalStopLoss);
   if(riskInPrice < point_val * 1.0) {
      PrintFormat("OpenTradeSimple ERROR: Riesgo calculado (%.*f) demasiado pequeño. Entry: %.*f, SL: %.*f. Abortando.",
                  digits_val, riskInPrice, digits_val, actualEntryPrice, digits_val, finalStopLoss);
      return false;
   }
   PrintFormat("OpenTradeSimple: Riesgo en precio: %.*f (%.1f puntos)", digits_val, riskInPrice, riskInPrice/point_val);

   double finalTakeProfit = 0;
   if (UseKeyLevelsForSLTP) {
        double bestKeyLevelTP = 0;
        double bestKeyLevelStrength = 0;
        string bestKeyLevelType = "";

        for (int i = 0; i < ArraySize(liquidityZones); i++) {
            LiquidityZone lz = liquidityZones[i];
            if (lz.strength < KeyLevelTP_MinStrength) continue;

            bool lzIsTarget = false;
            if (isLong && lz.isBuySide && lz.price > actualEntryPrice) lzIsTarget = true;
            if (!isLong && !lz.isBuySide && lz.price < actualEntryPrice) lzIsTarget = true;

            if (lzIsTarget) {
                double potentialTP = lz.price;
                double tpMarginPipsValue = KeyLevelTP_MarginPips; 
                double pipMonetaryValueTP = (digits_val == 3 || digits_val == 5 || digits_val == 1) ? point_val * 10 : point_val;
                double tpMarginPoints = tpMarginPipsValue * pipMonetaryValueTP;

                if (tpMarginPoints <= 0 && tpMarginPipsValue > 0 && point_val > 0) tpMarginPoints = tpMarginPipsValue * point_val;
                else if (tpMarginPoints <= 0 && tpMarginPipsValue > 0) tpMarginPoints = tpMarginPipsValue * (digits_val <=3 ? 0.01 : 0.0001);

                if(tpMarginPoints > 0){
                    if (isLong) potentialTP -= tpMarginPoints;
                    else potentialTP += tpMarginPoints;
                }

                double rewardInPrice = MathAbs(potentialTP - actualEntryPrice);
                double currentDynamicRR = (riskInPrice > 0) ? rewardInPrice / riskInPrice : 0;

                if (currentDynamicRR >= g_dyn_MinRR_ForKeyLevelTP && currentDynamicRR <= g_dyn_MaxRR_ForKeyLevelTP) {
                    bool assignThisTP = false;
                    if (bestKeyLevelTP == 0) {
                        assignThisTP = true;
                    } else {
                        if (isLong) {
                            if ((potentialTP > bestKeyLevelTP && lz.strength >= bestKeyLevelStrength - 0.5) || (lz.strength > bestKeyLevelStrength + 0.5 && potentialTP >= bestKeyLevelTP * 0.95 )) assignThisTP = true;
                        } else {
                            if ((potentialTP < bestKeyLevelTP && lz.strength >= bestKeyLevelStrength - 0.5) || (lz.strength > bestKeyLevelStrength + 0.5 && potentialTP <= bestKeyLevelTP * 1.05 )) assignThisTP = true;
                        }
                    }
                    if (assignThisTP) {
                        bestKeyLevelTP = potentialTP;
                        bestKeyLevelStrength = lz.strength;
                        bestKeyLevelType = lz.type;
                    }
                }
            }
        }

        if (bestKeyLevelTP != 0) {
            finalTakeProfit = bestKeyLevelTP;
            double rr_final_print = (riskInPrice > 0) ? MathAbs(finalTakeProfit - actualEntryPrice) / riskInPrice : 0;
            PrintFormat(">> OpenTradeSimple: TP ajustado a Nivel Clave %.*f (%s, Str:%.1f, RR: %.2f DynMinRR:%.2f DynMaxRR:%.2f)",
                       digits_val, finalTakeProfit, bestKeyLevelType, bestKeyLevelStrength, rr_final_print, g_dyn_MinRR_ForKeyLevelTP, g_dyn_MaxRR_ForKeyLevelTP);
        } else {
            if(RiskRewardRatio > 0) finalTakeProfit = isLong ? actualEntryPrice + (riskInPrice * RiskRewardRatio) : actualEntryPrice - (riskInPrice * RiskRewardRatio);
            else finalTakeProfit = 0.0;
            PrintFormat(">> OpenTradeSimple: No se encontró Nivel Clave para TP (DynMinRR:%.2f DynMaxRR:%.2f). Usando R:R fijo del input: %.2f. TP: %s",
                        g_dyn_MinRR_ForKeyLevelTP, g_dyn_MaxRR_ForKeyLevelTP, RiskRewardRatio, (finalTakeProfit == 0.0 ? "Sin TP" : DoubleToString(finalTakeProfit, digits_val)));
        }
   } else {
        if(RiskRewardRatio > 0) finalTakeProfit = isLong ? actualEntryPrice + (riskInPrice * RiskRewardRatio) : actualEntryPrice - (riskInPrice * RiskRewardRatio);
        else finalTakeProfit = 0.0;
        PrintFormat(">> OpenTradeSimple: UseKeyLevelsForSLTP desactivado. Usando R:R fijo de Input: %.2f. TP: %s", RiskRewardRatio, (finalTakeProfit == 0.0 ? "Sin TP" : DoubleToString(finalTakeProfit, digits_val)));
   }

   finalStopLoss = NormalizeDouble(finalStopLoss, digits_val);
   if(finalTakeProfit != 0.0) finalTakeProfit = NormalizeDouble(finalTakeProfit, digits_val);

   double stopsLevelPoints = (double)SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL) * point_val;
   if (stopsLevelPoints < point_val) stopsLevelPoints = 2 * point_val;

   if (isLong) {
       finalStopLoss = MathMin(finalStopLoss, actualEntryPrice - stopsLevelPoints);
       if (finalTakeProfit != 0.0) finalTakeProfit = MathMax(finalTakeProfit, actualEntryPrice + stopsLevelPoints);
   } else {
       finalStopLoss = MathMax(finalStopLoss, actualEntryPrice + stopsLevelPoints);
       if (finalTakeProfit != 0.0) finalTakeProfit = MathMin(finalTakeProfit, actualEntryPrice - stopsLevelPoints);
   }
   
   finalStopLoss = NormalizeDouble(finalStopLoss, digits_val);
   if(finalTakeProfit != 0.0) finalTakeProfit = NormalizeDouble(finalTakeProfit, digits_val);

   if ((isLong && finalStopLoss >= actualEntryPrice) || (!isLong && finalStopLoss <= actualEntryPrice)) {
        PrintFormat("OpenTradeSimple ERROR CRÍTICO: SL Final (%.*f) inválido respecto al precio de entrada (%.*f) tras ajustes. Abortando.", digits_val, finalStopLoss, digits_val, actualEntryPrice);
        return false;
   }
   if (finalTakeProfit != 0.0) {
        if ((isLong && finalTakeProfit <= actualEntryPrice) || (!isLong && finalTakeProfit >= actualEntryPrice)) {
            PrintFormat("OpenTradeSimple ERROR CRÍTICO: TP Final (%.*f) inválido respecto al precio de entrada (%.*f) tras ajustes. Abortando TP.", digits_val, finalTakeProfit, digits_val, actualEntryPrice);
            finalTakeProfit = 0.0;
        }
        if (isLong && finalStopLoss >= finalTakeProfit && finalTakeProfit != 0.0) { 
             PrintFormat("OpenTradeSimple ERROR CRÍTICO (BUY): SL Final (%.*f) >= TP Final (%.*f). Configurando TP a 0.", digits_val, finalStopLoss, digits_val, finalTakeProfit);
             finalTakeProfit = 0.0;
        }
        if (!isLong && finalStopLoss <= finalTakeProfit && finalTakeProfit != 0.0) { 
             PrintFormat("OpenTradeSimple ERROR CRÍTICO (SELL): SL Final (%.*f) <= TP Final (%.*f). Configurando TP a 0.", digits_val, finalStopLoss, digits_val, finalTakeProfit);
             finalTakeProfit = 0.0;
        }
   }

   PrintFormat("OpenTradeSimple: Precios finales para envío. ActualEntry: %.*f, SL Final: %.*f, TP Final: %s",
               digits_val, actualEntryPrice,
               digits_val, finalStopLoss,
               (finalTakeProfit == 0.0 ? "0.0 (Sin TP)" : DoubleToString(finalTakeProfit, digits_val)));

   MqlTradeRequest request;
   ZeroMemory(request);
   MqlTradeResult result;
   ZeroMemory(result);

   int magicNumber = 12345;

   request.action = TRADE_ACTION_DEAL;
   request.symbol = Symbol();
   request.volume = lot;
   request.type = isLong ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price = SymbolInfoDouble(Symbol(), isLong ? SYMBOL_ASK : SYMBOL_BID);
   request.sl = finalStopLoss;
   request.tp = finalTakeProfit;
   request.deviation = 100;
   request.magic = magicNumber;
   request.comment = comment;
   request.type_filling = ORDER_FILLING_FOK;

   bool orderSent = false;
   if(!OrderSend(request, result)) {
      PrintFormat("OpenTradeSimple: Falló el envío FOK. Retcode: %u, Comentario servidor: %s, GetLastError(): %d",
                  result.retcode, result.comment, GetLastError());
      if(result.retcode == TRADE_RETCODE_REQUOTE || result.retcode == TRADE_RETCODE_PRICE_OFF ||
         result.retcode == TRADE_RETCODE_CONNECTION || result.retcode == TRADE_RETCODE_TIMEOUT ||
         result.retcode == TRADE_RETCODE_INVALID_FILL) { 
         PrintFormat("OpenTradeSimple: Reintentando con IOC...");
         request.type_filling = ORDER_FILLING_IOC;
         if(!OrderSend(request, result)) {
             PrintFormat("OpenTradeSimple ERROR (IOC): %u - %s. GetLastError(): %d", result.retcode, result.comment, GetLastError());
             return false;
         } else {
              orderSent = true;
              PrintFormat("OpenTradeSimple: Orden IOC enviada. Retcode: %u, Order: %I64u, Deal: %I64u", result.retcode, result.order, result.deal);
         }
      } else {
          return false;
      }
   } else {
        orderSent = true;
        PrintFormat("OpenTradeSimple: Orden FOK enviada. Retcode: %u, Order: %I64u, Deal: %I64u", result.retcode, result.order, result.deal);
   }

   if (orderSent) {
      Sleep(750);
      ulong position_ticket = 0;
      double opened_volume = 0.0;
      datetime currentTimeForCheck = TimeCurrent();


      if(position_ticket == 0 || opened_volume == 0.0) {
          Print("OpenTradeSimple: No se pudo obtener posición por Deal Ticket. Buscando por comentario y tiempo...");
          for(int k = PositionsTotal() - 1; k >= 0; k--) {
              ulong temp_ticket = PositionGetTicket(k);
              if(temp_ticket != 0 && PositionSelectByTicket(temp_ticket)) {
                  if(PositionGetInteger(POSITION_MAGIC) == magicNumber &&
                     PositionGetString(POSITION_SYMBOL) == Symbol() &&
                     PositionGetString(POSITION_COMMENT) == comment &&
                     (datetime)PositionGetInteger(POSITION_TIME) >= (currentTimeForCheck - 15) ) {
                      position_ticket = temp_ticket;
                      opened_volume = PositionGetDouble(POSITION_VOLUME);
                      break;
                  }
              }
          }
      }

      if(position_ticket > 0 && opened_volume > 0.0){
         StoreInitialVolume(position_ticket, opened_volume);
         PrintFormat("OpenTradeSimple: Posición '%s' detectada y registrada. Ticket: %I64u, Volumen: %.2f, SL: %.*f, TP: %s",
                     comment, position_ticket, opened_volume, digits_val, finalStopLoss,
                     (finalTakeProfit == 0.0 ? "Sin TP" : DoubleToString(finalTakeProfit, digits_val)));
         tradesToday++;
         lastH4TradeTime = iTime(Symbol(), PERIOD_H4, 0);
         return true;
      } else {
         PrintFormat("OpenTradeSimple ADVERTENCIA: No se pudo confirmar la posición '%s' o el volumen inicial. Orden enviada (Ticket de orden: %I64u, Deal: %I64u).",
                     comment, result.order, result.deal);
         tradesToday++;
         lastH4TradeTime = iTime(Symbol(), PERIOD_H4, 0);
         return true;
      }
   }
   return false;
}


//+------------------------------------------------------------------+

void CheckTradeEntries()
{
   if(PositionsTotal() > 0 || tradesToday >= MaxTradesPerDay) return;

   // --- Condiciones de Entrada (Bias, Estructura M15) ---
   // (Tu lógica de bias y estructura M15 existente aquí...)
   bool biasCheckOK = true;
   if(UseDailyBias) {
       if(g_D1BiasBullish != g_H4BiasBullish) biasCheckOK = false;
       if(biasCheckOK && UseH1Confirmation && !IsH1BiasAligned(g_H4BiasBullish)) {
           biasCheckOK = false;
       }
   }
   if(!biasCheckOK) return;

   MarketStructureState m15State = DetectMarketStructureM15(FractalLookback_M15, 2);
   bool structureCheckOK = false;
   if((g_H4BiasBullish && m15State == MSS_BULLISH) || (!g_H4BiasBullish && m15State == MSS_BEARISH)) {
       structureCheckOK = true;
   } else if (m15State == MSS_RANGE) {
       structureCheckOK = true; // Permitir entradas en rango si POI es claro
   }
   if(!structureCheckOK) return;


   // --- Buscar Puntos de Interés (POI): OBs o BBs ---
   OrderBlock targetOB; ZeroMemory(targetOB);    // Para el OB con mejor volumen
   BreakerBlock targetBB; ZeroMemory(targetBB);  // Para Breakers
   bool foundPOI_OB = false;
   bool foundPOI_BB = false;
   string poiType = "";
   double poiEntryPrice = 0;
   double poiStopLossPrice = 0;

   OrderBlock bestVolumeOB; ZeroMemory(bestVolumeOB);
   double maxVolumeRatio = 0.0; // O usar 'long maxTickVolume = 0;' si prefieres volumen crudo

   // Buscar OBs (ya ordenados por calidad, pero ahora seleccionaremos el de mayor volumen entre los válidos)
   if (ArraySize(orderBlocks) > 0) {
       for(int i=0; i < ArraySize(orderBlocks); i++)
       {
          // orderBlocks[i] ya tiene 'isValid', 'isSwept', 'quality', 'volumeRatio', 'obTickVolume' poblados desde DetectOrderBlocks
          if(orderBlocks[i].isBullish == g_H4BiasBullish && orderBlocks[i].isValid && !orderBlocks[i].isSwept && orderBlocks[i].quality >= 6.5) // Asegurar filtros básicos
          {
              // Comparar para encontrar el OB con mayor volumeRatio (o obTickVolume)
              if(orderBlocks[i].volumeRatio > maxVolumeRatio) // O 'orderBlocks[i].obTickVolume > maxTickVolume'
              {
                  maxVolumeRatio = orderBlocks[i].volumeRatio; // O 'maxTickVolume = orderBlocks[i].obTickVolume;'
                  bestVolumeOB = orderBlocks[i];
                  foundPOI_OB = true;
              }
          }
       }
   }

   if(foundPOI_OB) {
      targetOB = bestVolumeOB;
      poiType = "OB (Vol)";
      // Calcular Entry/SL para este OB (targetOB)
      double atrM5 = ComputeATR(PERIOD_M5, 14);
      if (atrM5 <= 0 && _Point > 0) atrM5 = _Point * 100; // Fallback
      else if (atrM5 <= 0) atrM5 = 0.0001 * 100;

      double slBufferPipsValue = (StopLossPips < 1) ? 1.0 : (double)StopLossPips;
      double slBuffer = MathMax(slBufferPipsValue * _Point * (Digits()%2==1?10:1), atrM5 * ATRBufferFactor);
      if(slBuffer <= 0 && _Point > 0) slBuffer = slBufferPipsValue * _Point * ATRBufferFactor;
      else if(slBuffer <=0) slBuffer = slBufferPipsValue * 0.0001 * ATRBufferFactor;


      if(g_H4BiasBullish) { // Long
         if(OBEntryMode == 0) poiEntryPrice = targetOB.openPrice;
         else if (OBEntryMode == 1) poiEntryPrice = (targetOB.openPrice + targetOB.closePrice) / 2.0;
         else poiEntryPrice = targetOB.highPrice; // Wick High de la vela BAJISTA (cuerpo del OB)
         poiStopLossPrice = targetOB.lowPrice - slBuffer;
      } else { // Short
         if(OBEntryMode == 0) poiEntryPrice = targetOB.openPrice;
         else if (OBEntryMode == 1) poiEntryPrice = (targetOB.openPrice + targetOB.closePrice) / 2.0;
         else poiEntryPrice = targetOB.lowPrice; // Wick Low de la vela ALCISTA (cuerpo del OB)
         poiStopLossPrice = targetOB.highPrice + slBuffer;
      }
      PrintFormat("POI Candidato por Volumen: Order Block en %s. Calidad:%.1f, VolRatio:%.2f. Entry:%.5f, SL:%.5f",
                  TimeToString(targetOB.time), targetOB.quality, targetOB.volumeRatio, poiEntryPrice, poiStopLossPrice);
   }


   // Si no se encontró OB con volumen adecuado, o como alternativa, buscar Breakers
   // (La lógica de Breakers no se ha modificado para volumen aquí, pero podría hacerse de forma similar)
   if(!foundPOI_OB) // Solo buscar BB si no se encontró un OB por volumen prioritario
   {
       // (Tu lógica existente para buscar BreakerBlocks, si quieres que sea una alternativa)
       // Ejemplo: tomar el primer BB de alta calidad si no hay OBs con volumen
       if (ArraySize(breakerBlocks) > 0) {
            for(int i=0; i < ArraySize(breakerBlocks); i++) {
                // Asumir que DetectBreakerBlocks ya filtra por calidad y no mitigación
                if(breakerBlocks[i].isBullish == g_H4BiasBullish /* && breakerBlocks[i].quality >= X */) { // Añadir filtro de calidad para BB si existe
                    targetBB = breakerBlocks[i];
                    foundPOI_BB = true;
                    poiType = "BB";
                    poiEntryPrice = targetBB.price;
                    // ... (cálculo de SL para BB como lo tenías) ...
                    double atrM5_BB = ComputeATR(PERIOD_M5, 14);
                    if (atrM5_BB <= 0 && _Point > 0) atrM5_BB = _Point * 100;
                    else if (atrM5_BB <= 0) atrM5_BB = 0.0001 * 100;

                    double slBuffer_BB_Pips = (StopLossPips < 1) ? 1.0 : (double)StopLossPips;
                    double slBuffer_BB = MathMax(slBuffer_BB_Pips * _Point * (Digits()%2==1?10:1), atrM5_BB * 1.5);
                    if(slBuffer_BB <= 0 && _Point > 0) slBuffer_BB = slBuffer_BB_Pips * _Point * 1.5;
                    else if(slBuffer_BB <=0) slBuffer_BB = slBuffer_BB_Pips * 0.0001 * 1.5;


                    if(g_H4BiasBullish) poiStopLossPrice = poiEntryPrice - slBuffer_BB;
                    else poiStopLossPrice = poiEntryPrice + slBuffer_BB;
                    PrintFormat("POI Candidato Alternativo: Breaker Block en %s. Entry:%.5f, SL:%.5f", TimeToString(targetBB.obTime), poiEntryPrice, poiStopLossPrice);
                    break;
                }
            }
       }
   }

   if(!foundPOI_OB && !foundPOI_BB) return; // Salir si no hay POI válido

   // Determinar el POI final a usar (OB por volumen tiene prioridad)
   bool useOB = foundPOI_OB;
   if (!foundPOI_OB && foundPOI_BB) {
       // Ya tenemos poiEntryPrice y poiStopLossPrice para BB
   } else if (!foundPOI_OB && !foundPOI_BB) {
       return; // No POI
   }
   // Si foundPOI_OB es true, poiEntryPrice y poiStopLossPrice ya están seteados para el targetOB


   // 4. Verificar si el Precio Actual está cerca del POI para entrar
   double currentAsk = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double entryTolerancePipsValue = (EntryTolerancePips < 0) ? 0.0 : (double)EntryTolerancePips;
   double entryTolerancePoints = entryTolerancePipsValue * point * (Digits() % 2 == 1 ? 10 : 1);
   if(entryTolerancePoints <= 0 && point > 0 && entryTolerancePipsValue > 0) entryTolerancePoints = entryTolerancePipsValue * point;
   else if(entryTolerancePoints <= 0 && entryTolerancePipsValue > 0) entryTolerancePoints = entryTolerancePipsValue * 0.0001;


   bool priceIsInZone = false;
   if(g_H4BiasBullish) // Long Entry Check
   {
       if(currentAsk <= poiEntryPrice + entryTolerancePoints && currentAsk > poiStopLossPrice) {
           priceIsInZone = true;
           if(currentAsk > poiEntryPrice && OBEntryMode != 0) poiEntryPrice = currentAsk; // Ajustar a mercado si ya pasó un poco (excepto si es OBEntryMode Open)
       }
   }
   else // Short Entry Check
   {
       if(currentBid >= poiEntryPrice - entryTolerancePoints && currentBid < poiStopLossPrice) {
            priceIsInZone = true;
            if(currentBid < poiEntryPrice && OBEntryMode != 0) poiEntryPrice = currentBid; // Ajustar a mercado
       }
   }

   if(!priceIsInZone) return; // Precio no está en zona de entrada

   // 5. Abrir Trade
   double lot = CalculateLotSize();
   string comment = "ICT ";
   comment += poiType;
   comment += g_H4BiasBullish ? " Buy" : " Sell";
   if (useOB) { // Añadir info del OB al comentario
        comment += " Q" + DoubleToString(targetOB.quality,1) + " VR" + DoubleToString(targetOB.volumeRatio,2);
   }

   poiEntryPrice = NormalizeDouble(poiEntryPrice, _Digits);
   poiStopLossPrice = NormalizeDouble(poiStopLossPrice, _Digits);
   Print("Intentando abrir Trade: ", comment, " Entry:", poiEntryPrice, " SL:", poiStopLossPrice, " Lote:", lot);
   OpenTradeSimple(g_H4BiasBullish, lot, poiEntryPrice, poiStopLossPrice, comment);
}


void CheckLiquidityHunting()
{
    if(PositionsTotal() > 0 || tradesToday >= MaxTradesPerDay) return;

    // Ordenar zonas por fuerza descendente para priorizar las más fuertes
    // Bubble Sort simple por fuerza (descendente) - Podría optimizarse si hay muchas zonas
    for(int i=0; i < ArraySize(liquidityZones)-1; i++){
       for(int j=0; j < ArraySize(liquidityZones)-1-i; j++){
          if(liquidityZones[j].strength < liquidityZones[j+1].strength){
             LiquidityZone temp = liquidityZones[j];
             liquidityZones[j] = liquidityZones[j+1];
             liquidityZones[j+1] = temp;
          }
       }
    }


    for(int i = 0; i < ArraySize(liquidityZones); i++)
    {
        // Considerar solo zonas fuertes (ej: EQH/EQL, Session, Old H/L - fuerza >= 8.5)
        if(liquidityZones[i].strength < 8.5) continue;

        double liquidityLevel = liquidityZones[i].price;
        bool isBuySideLiquidity = liquidityZones[i].isBuySide; // True=High, False=Low
        string zoneType = liquidityZones[i].type;

        // Detectar si hubo un Stop Hunt reciente en esta zona
        int huntStrength = 0;
        bool isStopHunt = DetectStopHunt(liquidityLevel, isBuySideLiquidity, huntStrength);

        if(isStopHunt && huntStrength >= 6) // Umbral de fuerza del hunt
        {
            // --- Confirmación Adicional ---
            // 1. ¿La reversión post-hunt está alineada con el Bias H4?
            bool enterLong = !isBuySideLiquidity; // Si barre Low (BuySide=false), entramos Long
            bool reversalAlignedWithBias = (enterLong == g_H4BiasBullish);

            if(!reversalAlignedWithBias && UseDailyBias) continue; // Ignorar si va contra bias H4

            // 2. ¿Hay alguna señal de confirmación adicional M5? (ej: FVG, BOS/ChoCH post-hunt)
             bool confirmationOK = true; // Añadir lógica si se requiere
             // Necesitaríamos el índice de la barra del hunt desde DetectStopHunt
             // int huntBar = ... ;
             // if (enterLong && !DetectBOS(PERIOD_M5, huntBar-1, true, 5)) confirmationOK = false;
             // if (!enterLong && !DetectBOS(PERIOD_M5, huntBar-1, false, 5)) confirmationOK = false;
             if (!confirmationOK) continue;

            // --- Abrir Trade ---
            double lot = CalculateLotSize(); // Usar cálculo estándar basado en SL fijo del input
            double entryPrice = SymbolInfoDouble(Symbol(), enterLong ? SYMBOL_ASK : SYMBOL_BID); // Entrar a mercado
            double stopLoss = 0.0;
            double atrM5 = ComputeATR(PERIOD_M5, 14);
            if (atrM5 <= 0 && _Point > 0) atrM5 = _Point * 100;
            else if (atrM5 <= 0) atrM5 = 0.0001 * 100;

            double slBufferPoints = MathMax(StopLossPips * _Point * (Digits()%2==1?10:1), atrM5 * 1.5); // SL fijo o ATR * 1.5
            if(slBufferPoints <= 0 && _Point > 0) slBufferPoints = StopLossPips * _Point * 1.5;
            else if(slBufferPoints <= 0) slBufferPoints = StopLossPips * 0.0001 * 1.5; // Fallback

            // Necesitamos el precio extremo de la penetración para poner el SL detrás.
            // DetectStopHunt debería idealmente devolver este precio.
            // Como no lo hace, basamos SL en el nivel de liquidez + buffer por ahora.
            // O podríamos buscar el High/Low de la barra de penetración (más complejo).
            if(enterLong) // Entrar COMPRA después de barrer Low
            {
                 stopLoss = liquidityLevel - slBufferPoints; // SL debajo del Low barrido (nivel original)
                 Print(">> BUYING AFTER STOP HUNT (", zoneType, "): Nivel=", liquidityLevel, ", Fuerza hunt=", huntStrength);
                 OpenTradeSimple(true, lot, entryPrice, stopLoss, "Buy StopHunt " + zoneType);
            }
            else // Entrar VENTA después de barrer High
            {
                 stopLoss = liquidityLevel + slBufferPoints; // SL encima del High barrido (nivel original)
                 Print(">> SELLING AFTER STOP HUNT (", zoneType, "): Nivel=", liquidityLevel, ", Fuerza hunt=", huntStrength);
                 OpenTradeSimple(false, lot, entryPrice, stopLoss, "Sell StopHunt " + zoneType);
            }

            // Salir del loop después de intentar abrir un trade
            return; // Intentar solo un trade por tick
        }
    }
}


void ManageRisk() // Gestión general: BE, Parciales, llamadas a Trailings
{
   datetime currentTime = TimeCurrent();
   int totalPositions = PositionsTotal(); // Guardar total para evitar problemas si se cierra una en el loop

   for(int i = totalPositions - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;

      // Verificar Magic Number (IMPORTANTE)
      if(PositionGetInteger(POSITION_MAGIC) != 12345) continue; // <<< ¡¡¡REEMPLAZA 12345!!!

      // *** CORRECCIÓN: Cast a datetime ***
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);

      // Opcional: No gestionar trades demasiado recientes
      // if(currentTime - openTime < MinimumHoldTimeSeconds) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      if(sym != Symbol()) continue; // Solo gestionar trades del símbolo actual

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double stopLoss = PositionGetDouble(POSITION_SL);
      double takeProf = PositionGetDouble(POSITION_TP);

      // Ignorar si no hay SL inicial? Podría ser una posición sin SL gestionada manualmente.
      // if (stopLoss == 0) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double currentPrice = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
      double point = SymbolInfoDouble(sym, SYMBOL_POINT);
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      double pipsFactor = (digits == 3 || digits == 5 || digits == 1) ? 10.0 : 1.0; // Factor para convertir puntos a pips (0.1 / 1 / 10)

      // Calcular R actual y Pips en positivo
      double initialRiskPoints = 0;
      if(stopLoss != 0) initialRiskPoints = MathAbs(openPrice - stopLoss) / point;

      double currentProfitPoints = 0;
      if(type == POSITION_TYPE_BUY) currentProfitPoints = (currentPrice - openPrice) / point;
      else currentProfitPoints = (openPrice - currentPrice) / point;
      double currentPips = currentProfitPoints / pipsFactor; // Pips actuales en positivo/negativo

      // --- BreakEven (Usa dyn_BreakEvenPips) ---
      if(UseBreakEven && stopLoss != 0) // Solo si hay SL inicial
      {
         // Comprobar si BE ya está puesto (o mejor)
         bool isBEsetOrBetter = false;
         if(type == POSITION_TYPE_BUY && stopLoss >= openPrice) isBEsetOrBetter = true;
         if(type == POSITION_TYPE_SELL && stopLoss <= openPrice) isBEsetOrBetter = true;

         if(!isBEsetOrBetter && currentPips >= dyn_BreakEvenPips)
         {
             double beLevel = openPrice; // SL exacto en la entrada
             // Podría añadirse un pequeño buffer:
             double beBufferPips = 1.0; // 1 pip de buffer
             double beBufferPoints = beBufferPips * point * pipsFactor; // Buffer en puntos
             if(beBufferPoints <=0 && point > 0) beBufferPoints = beBufferPips * point;
             else if(beBufferPoints <=0) beBufferPoints = beBufferPips * 0.0001;


             if (type == POSITION_TYPE_BUY) beLevel += beBufferPoints;
             else beLevel -= beBufferPoints;
             beLevel = NormalizeDouble(beLevel, digits);

             // Modificar solo si el BE es mejor que el SL actual
             if((type == POSITION_TYPE_BUY && beLevel > stopLoss) || (type == POSITION_TYPE_SELL && beLevel < stopLoss))
             {
                if(trade.PositionModify(ticket, beLevel, takeProf)) {
                   Print(">> Pos ", ticket, " BreakEven set at ", beLevel, " (", dyn_BreakEvenPips, " pips reached)");
                   stopLoss = beLevel; // Actualizar SL local para lógica posterior
                } else {
                   Print("Error setting BE for pos ", ticket, ": ", GetLastError());
                }
             }
         }
      } // Fin BreakEven

      // --- Gestión de Cierre Parcial Avanzado (si está activado) ---
      int indexFlag = (int)(ticket % 100); // Simple hashing para el flag
      if(indexFlag < 0 || indexFlag >= 100) indexFlag = 0; // Asegurar índice válido

      if(UsePartialClose && stopLoss != 0) // Necesita SL para calcular R
      {
          ManagePartialWithFixedTP_Advanced(); // Llama a la función avanzada de parciales (opera sobre la pos seleccionada)
          // Re-seleccionar por si el parcial cerró la posición o cambió datos
          if(!PositionSelectByTicket(ticket)) continue; // Pasar a la siguiente si ya no existe
          // Actualizar variables locales por si cambiaron SL/TP/Volumen
           stopLoss = PositionGetDouble(POSITION_SL);
           takeProf = PositionGetDouble(POSITION_TP);
      }

      // --- Seleccionar y Aplicar Estrategia de Trailing ---
      bool trailingApplied = false;
      if(UseFractalStopHuntTrailing)
      {
          // El Trailing Fractal tiene prioridad si está activo
          ApplyStopHuntFractalTrailing(ticket, FractalTrailingDepth, FractalTrailingBufferPips, FractalTrailingSearchBars);
          // Si el SL cambió, actualizar variable local
           if(PositionSelectByTicket(ticket)) stopLoss = PositionGetDouble(POSITION_SL); else continue;
          trailingApplied = true; // Asumir que se intentó aplicar
      }

      // El Trailing Adaptativo se activa DESPUÉS del segundo parcial en ManagePartialWithFixedTP_Advanced
      // Comprobamos el estado para llamar a AdvancedAdaptiveTrailing
      if(UsePartialClose && partialClosedFlags[indexFlag] >= 2) // Si el estado es 2 (o más)
      {
          if(!UseFractalStopHuntTrailing){ // Solo si el fractal no está activo o ya se aplicó
             AdvancedAdaptiveTrailing(ticket, takeProf);
             if(PositionSelectByTicket(ticket)) stopLoss = PositionGetDouble(POSITION_SL); else continue;
             trailingApplied = true; // Se aplicó el adaptativo
          }
      }

      // TrailingStop Estándar (Solo si está activado Y ninguna otra estrategia de trailing avanzada lo gestionó)
      if(UseTrailingStop && !trailingApplied) // Solo si no se aplicó Fractal ni Adaptativo
      {
         if (stopLoss == 0) continue; // No hacer trailing estándar si no hay SL

         double trailDistPips = (double)dyn_TrailingDistancePips; // Usa distancia dinámica
         double offsetPoints = trailDistPips * point * pipsFactor; // Offset en puntos
         if(offsetPoints <=0 && point > 0) offsetPoints = trailDistPips * point;
         else if(offsetPoints <=0) offsetPoints = trailDistPips * 0.0001;

         double desiredSL = 0;
         if(type == POSITION_TYPE_BUY) desiredSL = currentPrice - offsetPoints;
         else desiredSL = currentPrice + offsetPoints;
         desiredSL = NormalizeDouble(desiredSL, digits);

         // Solo modificar si el nuevo SL es mejor que el SL actual
         if((type == POSITION_TYPE_BUY && desiredSL > stopLoss) || (type == POSITION_TYPE_SELL && desiredSL < stopLoss))
         {
             if(trade.PositionModify(ticket, desiredSL, takeProf))
                Print(">> Pos ", ticket, " Standard Trailing Stop updated to ", desiredSL);
             // else: Print error si falla
         }
         // trailingApplied = true; // No necesario marcar aquí si es el último
      }

   } // Fin loop posiciones

    // Limpiar volúmenes almacenados de posiciones que ya no existen
    int storedCount = ArraySize(g_positionTickets);
    for (int k = storedCount - 1; k >= 0; k--) {
        if (!PositionSelectByTicket(g_positionTickets[k])) {
            RemoveStoredVolume(g_positionTickets[k]);
        }
    }
}


// Función para gestionar SL específicamente contra Stop Runs (puede integrarse en ManageRisk o llamarse por separado)
void ManageSLWithStopRunProtection()
{
    int totalPositions = PositionsTotal();
    for(int i = totalPositions-1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(!PositionSelectByTicket(ticket)) continue;
        if(PositionGetInteger(POSITION_MAGIC) != 12345) continue; // <<< ¡¡¡TU NÚMERO MÁGICO!!!

        double sl = PositionGetDouble(POSITION_SL);
        if(sl == 0.0) continue; // Ignorar si no hay SL

        long type = PositionGetInteger(POSITION_TYPE);
        bool isBuy = (type == POSITION_TYPE_BUY);
        int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
        double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);


        // Detectar si se está formando un Stop Hunt *contra* nuestra posición cerca del SL actual
        int huntStrength = 0;
        // Si tenemos una COMPRA (isBuy=true), el SL está abajo. Buscamos un hunt que barra ese LOW (isBuySideLiquidity=false).
        // Si tenemos una VENTA (isBuy=false), el SL está arriba. Buscamos un hunt que barra ese HIGH (isBuySideLiquidity=true).
        bool stopHuntFormado = DetectStopHunt(sl, /*isBuySideLiquidity=*/ !isBuy, huntStrength);

        if(stopHuntFormado && huntStrength >= 5) // Umbral de fuerza ajustable
        {
            double extraBufferPips = 3.0; // Pips extra para alejar el SL
            double extraBuffer = extraBufferPips * point * (digits % 2 == 1 ? 10 : 1);
            if (extraBuffer <= 0 && point > 0) extraBuffer = extraBufferPips * point;
            else if (extraBuffer <= 0) extraBuffer = extraBufferPips * 0.0001; // Fallback

            double newSL = isBuy ? sl - extraBuffer : sl + extraBuffer;
            newSL = NormalizeDouble(newSL, digits);

            // Modificar solo si el nuevo SL es más seguro (más lejos)
            if((isBuy && newSL < sl) || (!isBuy && newSL > sl))
            {
               // Comprobar si el nuevo SL no cruza el precio actual
                double currentPrice = isBuy ? SymbolInfoDouble(Symbol(), SYMBOL_BID) : SymbolInfoDouble(Symbol(), SYMBOL_ASK);
                if ((isBuy && newSL < currentPrice) || (!isBuy && newSL > currentPrice))
                {
                   // *** CORRECCIÓN: Añadir verificación antes de modificar ***
                   double currentTP = PositionGetDouble(POSITION_TP);
                   Print("Intentando modificar SL [StopRunProtect] Pos ", ticket, ". newSL=", newSL, ", currentTP=", currentTP);
                   if(trade.PositionModify(ticket, newSL, currentTP))
                      Print(">> [StopRunProtect] Pos ", ticket, ": SL ajustado a ", newSL, " (Hunt Fuerza: ", huntStrength, ")");
                   else
                      Print("Error ajustando SL [StopRunProtect] Pos ", ticket,": ", GetLastError());
                } else {
                    Print(">> [StopRunProtect] Pos ", ticket, ": Nuevo SL ", newSL, " cruzaría precio actual ", currentPrice, ". No modificado.");
                }
            }
        }
    }
}


// Función Avanzada de Cierre Parcial (2R y 3R) y Activación de Trailing
void ManagePartialWithFixedTP_Advanced()
{
   // Esta función opera sobre la posición seleccionada en el bucle de ManageRisk
   ulong ticket = PositionGetInteger(POSITION_TICKET);
   if(ticket == 0) return;

   double entryPrice      = PositionGetDouble(POSITION_PRICE_OPEN);
   double stopLoss        = PositionGetDouble(POSITION_SL);
   if(stopLoss == 0) return; // Necesitamos SL inicial para calcular R

   double currentPrice    = PositionGetDouble(POSITION_PRICE_CURRENT);
   double fixedTakeProfit = PositionGetDouble(POSITION_TP);
   double currentVolume   = PositionGetDouble(POSITION_VOLUME);
   long   type            = PositionGetInteger(POSITION_TYPE);
   int    digits          = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   double point           = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
   double volStep         = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   double minVol          = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   if (volStep <= 0) volStep = 0.01; // Fallback
   if (minVol <= 0) minVol = 0.01;   // Fallback

   // *** CORRECCIÓN: Usar volumen inicial almacenado ***
   double initialVolume = GetStoredInitialVolume(ticket);
   if(initialVolume <= 0) {
       //Print("Advertencia: No se encontró volumen inicial para ", ticket, " en ManagePartial. Usando volumen actual.");
       initialVolume = currentVolume; // Usar volumen actual como fallback (cambia la lógica de %)
       if (initialVolume <= 0) return; // Salir si ni siquiera el actual es válido
   }

   double initialRisk = MathAbs(entryPrice - stopLoss);
   if(initialRisk < point * 1.0) return; // Riesgo demasiado pequeño

   double currentProfitOrLoss;
   if(type == POSITION_TYPE_BUY) currentProfitOrLoss = currentPrice - entryPrice;
   else currentProfitOrLoss = entryPrice - currentPrice;

   // Calcular R solo si está en positivo
   double currentR = (currentProfitOrLoss > 0 && initialRisk > 0) ? (currentProfitOrLoss / initialRisk) : 0;

   // --- Gestión de Estado de Parciales ---
   int indexFlag = (int)(ticket % 100);
   if(indexFlag < 0 || indexFlag >= 100) indexFlag = 0;
   int stage = partialClosedFlags[indexFlag];

   double TP1_R = 2.0;
   double TP2_R = 3.0;
   double partialClose1_Percent = 30.0; // 30% en TP1 (del inicial)
   double partialClose2_Percent = 30.0; // 30% en TP2 (del inicial)

   // --- Parcial en 2R (stage 0 -> 1) ---
   if(stage == 0 && currentR >= TP1_R)
   {
      double closeVol = initialVolume * (partialClose1_Percent / 100.0);
      // Ajustar al step y mínimo volumen
      closeVol = MathRound(closeVol / volStep) * volStep;
      closeVol = MathMax(minVol, closeVol);
      closeVol = NormalizeDouble(closeVol, 2); // Normalizar

      // Asegurar que queda volumen mínimo después de cerrar Y que closeVol es menor que el actual
      if(closeVol > 0 && currentVolume - closeVol >= minVol && closeVol < currentVolume)
      {
         // Usar CTrade para cerrar parcial
         if(trade.PositionClosePartial(ticket, closeVol))
         {
            Print(">> Pos ", ticket, ": Parcial 1 (", partialClose1_Percent, "%) cerrado en ~", TP1_R, "R. Vol Cerrado: ", closeVol);
            partialClosedFlags[indexFlag] = 1; // Avanzar al siguiente estado
            stage = 1; // Actualizar estado localmente

            // Mover SL a BE + Buffer (opcional) después de re-seleccionar
             if(PositionSelectByTicket(ticket)){ // Re-seleccionar por si acaso
                 double currentSL = PositionGetDouble(POSITION_SL); // SL actual (podría haber cambiado)
                 double currentTP = PositionGetDouble(POSITION_TP);
                 double bufferPipsBE = 1.0; // Pips de buffer para BE
                 double pipsFactor = (digits%2==1?10:1);
                 double beBufferPoints = bufferPipsBE * point * pipsFactor;
                 if(beBufferPoints <= 0 && point > 0) beBufferPoints = bufferPipsBE * point;
                 else if(beBufferPoints <= 0) beBufferPoints = bufferPipsBE * 0.0001; // Fallback

                 double beLevel = entryPrice + (type == POSITION_TYPE_BUY ? beBufferPoints : -beBufferPoints);
                 beLevel = NormalizeDouble(beLevel, digits);

                 if((type == POSITION_TYPE_BUY && beLevel > currentSL) || (type == POSITION_TYPE_SELL && beLevel < currentSL))
                 {
                     if(trade.PositionModify(ticket, beLevel, currentTP))
                         Print(">> Pos ", ticket, ": SL movido a BE + buffer (", beLevel, ") tras Parcial 1");
                     else Print("Error moviendo SL a BE Pos ", ticket, " tras Parcial 1: ", GetLastError());
                 }
            }
         } else { Print("Error cierre parcial 1 Pos ", ticket, ": ", GetLastError()); }
      } else if (closeVol >= currentVolume - minVol) {
          // Si el volumen a cerrar dejaría menos del mínimo, no cerrar parcial
          // Print("Volumen parcial 1 (", closeVol,") demasiado grande para cerrar en Pos ", ticket, ". Volumen actual: ", currentVolume);
      }
   }

   // --- Parcial en 3R (stage 1 -> 2) ---
   // Re-seleccionar la posición porque el cierre parcial anterior puede haber cambiado datos
   if(!PositionSelectByTicket(ticket)) return;
   currentVolume = PositionGetDouble(POSITION_VOLUME); // Obtener volumen actualizado
   currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT); // Actualizar precio
   stopLoss = PositionGetDouble(POSITION_SL); // Actualizar SL
   fixedTakeProfit = PositionGetDouble(POSITION_TP); // Actualizar TP

   // Recalcular R actual con datos frescos
   if(type == POSITION_TYPE_BUY) currentProfitOrLoss = currentPrice - entryPrice;
   else currentProfitOrLoss = entryPrice - currentPrice;
   currentR = (currentProfitOrLoss > 0 && initialRisk > 0) ? (currentProfitOrLoss / initialRisk) : 0;


   if(stage == 1 && currentR >= TP2_R)
   {
      double closeVol = initialVolume * (partialClose2_Percent / 100.0); // Basado en inicial
      // Ajustar al step y mínimo volumen
      closeVol = MathRound(closeVol / volStep) * volStep;
      closeVol = MathMax(minVol, closeVol);
      closeVol = NormalizeDouble(closeVol, 2);

      // Asegurar que queda volumen mínimo después de cerrar Y que closeVol es menor que el actual
      if(closeVol > 0 && currentVolume - closeVol >= minVol && closeVol < currentVolume)
      {
          if(trade.PositionClosePartial(ticket, closeVol))
          {
              Print(">> Pos ", ticket, ": Parcial 2 (", partialClose2_Percent, "%) cerrado en ~", TP2_R, "R. Vol Cerrado: ", closeVol);
              partialClosedFlags[indexFlag] = 2; // Avanzar al estado final (trailing)
              stage = 2; // Actualizar estado localmente
               Print(">> Pos ", ticket, ": Trailing Adaptativo Activado.");
          } else { Print("Error cierre parcial 2 Pos ", ticket, ": ", GetLastError()); }
      } else if (closeVol >= currentVolume - minVol) {
         // Print("Volumen parcial 2 (", closeVol,") demasiado grande para cerrar en Pos ", ticket, ". Volumen actual: ", currentVolume);
      }
   }

   // --- Activar Trailing Adaptativo (stage 2) ---
   // La lógica de trailing se llama desde ManageRisk si stage es >= 2
}

// Trailing Adaptativo Avanzado (Llamado desde ManageRisk si stage >= 2)
void AdvancedAdaptiveTrailing(ulong ticket, double fixedTakeProfit)
{
   if(!PositionSelectByTicket(ticket)) return;

   double currentSL = PositionGetDouble(POSITION_SL);
   // No hacer trailing si no hay SL o si ya está en BE o mejor? Decisión de diseño.
   // if(currentSL == 0) return;

   double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
   long type = PositionGetInteger(POSITION_TYPE);
   int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
   double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);

   // --- Lógica de Trailing ---
   // 1. Base ATR M15
   double atrM15 = ComputeATR(PERIOD_M15, 14);
   if(atrM15 <= 0) return;
   double atrFactor = 1.8; // Factor ATR (más conservador que el fractal)
   double atrBuffer = atrM15 * atrFactor;

   // 2. Ajuste por Estructura M15
   MarketStructureState currentM15Structure = m15Structure; // Usar global
   double structureFactor = 1.0;
   if((type == POSITION_TYPE_BUY && currentM15Structure == MSS_BEARISH) || (type == POSITION_TYPE_SELL && currentM15Structure == MSS_BULLISH)) structureFactor = 0.8; // Ajustar más si va contra M15
   else if ((type == POSITION_TYPE_BUY && currentM15Structure == MSS_BULLISH) || (type == POSITION_TYPE_SELL && currentM15Structure == MSS_BEARISH)) structureFactor = 1.1; // Más holgado si va a favor

   // 3. Ajuste por Volatilidad (Régimen)
    double volatilityFactor = AdaptiveVolatility(0); // Usa global g_regime

   // Calcular SL deseado
   double trailingDistance = atrBuffer * structureFactor * volatilityFactor;
   double desiredSL = 0;

   if(type == POSITION_TYPE_BUY) desiredSL = currentPrice - trailingDistance;
   else desiredSL = currentPrice + trailingDistance;
   desiredSL = NormalizeDouble(desiredSL, digits);

   // 4. Protección Anti-Stop Hunt (Opcional, podría ser redundante con ManageSLWithStopRunProtection)
   // ...

   // Modificar SL solo si es mejor que el actual Y si hay un SL definido
   if(currentSL != 0 && ((type == POSITION_TYPE_BUY && desiredSL > currentSL) || (type == POSITION_TYPE_SELL && desiredSL < currentSL)))
   {
       // Asegurar distancia mínima al precio
       double price_away = (type == POSITION_TYPE_BUY) ? (currentPrice - desiredSL) : (desiredSL - currentPrice);
       double pipsFactor = (digits%2==1?10:1);
       double min_distance_points = 5 * point * pipsFactor; // 5 pips min
       if(min_distance_points <= 0 && point > 0) min_distance_points = 5 * point;
       else if(min_distance_points <= 0) min_distance_points = 5 * 0.0001; // Fallback

       if(price_away >= min_distance_points)
       {
           if(trade.PositionModify(ticket, desiredSL, fixedTakeProfit))
              Print(">> Pos ", ticket, ": Advanced Trailing SL updated to ", desiredSL);
           else Print("Error Adv Trailing Pos ", ticket, ": ", GetLastError());
       }
   }
}

// Función para Trailing Stop basado en Fractales post-entrada
void ApplyStopHuntFractalTrailing(ulong ticket, int fractalDepthInput, double bufferPips, int searchBarsAfterEntry)
{
    if (!UseFractalStopHuntTrailing) return;
    if (!PositionSelectByTicket(ticket)) return;

    long position_type = PositionGetInteger(POSITION_TYPE);
    // *** CORRECCIÓN: Cast a datetime ***
    datetime open_time = (datetime)PositionGetInteger(POSITION_TIME);
    double current_sl = PositionGetDouble(POSITION_SL);
    double current_tp = PositionGetDouble(POSITION_TP); // Necesitamos TP para modificar
    if(current_sl == 0.0) return; // No aplicar si no hay SL inicial

    // Determinar barras y profundidad real del fractal (input es # de barras a cada lado)
    int depth = fractalDepthInput;
    if (depth <= 0) depth = 2; // Mínimo 2 (fractal 5 barras)

    int digits = (int)SymbolInfoInteger(Symbol(), SYMBOL_DIGITS);
    double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
    double pipsFactor = (digits%2==1?10:1);
    double bufferPoints = bufferPips * point * pipsFactor;
    if(bufferPoints <= 0 && point > 0) bufferPoints = bufferPips * point;
    else if(bufferPoints <= 0) bufferPoints = bufferPips * 0.0001; // Fallback


    int totalBarsM15 = iBars(Symbol(), PERIOD_M15);
    int current_bar_idx = totalBarsM15 - 1; // Última vela M15 cerrada
    int open_bar_idx = iBarShift(Symbol(), PERIOD_M15, open_time, false);
    if(open_bar_idx < 0 || open_bar_idx >= totalBarsM15 ) return; // Error o barra fuera de rango

    // Definir rango de búsqueda
    int start_search_idx = MathMax(open_bar_idx, current_bar_idx - searchBarsAfterEntry);
    int end_search_idx = current_bar_idx - depth; // Última barra donde puede terminar un fractal

    double fractal_price = 0;
    int fractal_bar_idx = -1;

    // Buscar el fractal MÁS RECIENTE válido después de la apertura
    for (int i = end_search_idx; i >= start_search_idx; i--)
    {
        if (i < depth || i >= totalBarsM15 - depth) continue; // Asegurar espacio para fractal

        bool is_fractal = true;
        double level = 0;

        if (position_type == POSITION_TYPE_BUY) // Buscamos fractal LOW
        {
            level = iLow(Symbol(), PERIOD_M15, i);
            for (int j = 1; j <= depth; j++)
            {
                if (iLow(Symbol(), PERIOD_M15, i + j) < level || iLow(Symbol(), PERIOD_M15, i - j) < level)
                { is_fractal = false; break; }
            }
        }
        else // Buscamos fractal HIGH
        {
            level = iHigh(Symbol(), PERIOD_M15, i);
            for (int j = 1; j <= depth; j++)
            {
                if (iHigh(Symbol(), PERIOD_M15, i + j) > level || iHigh(Symbol(), PERIOD_M15, i - j) > level)
                { is_fractal = false; break; }
            }
        }

        if (is_fractal)
        {
             // Verificar que el fractal ocurrió en o después de la barra de apertura
             // -> Ya estamos buscando desde start_search_idx que es >= open_bar_idx
            fractal_price = level;
            fractal_bar_idx = i;
            break; // Encontramos el más reciente, salir
        }
    } // Fin loop búsqueda fractal

    if (fractal_bar_idx != -1) // Si se encontró un fractal válido
    {
        double new_sl = 0;
        if (position_type == POSITION_TYPE_BUY) new_sl = fractal_price - bufferPoints;
        else new_sl = fractal_price + bufferPoints;
        new_sl = NormalizeDouble(new_sl, digits);

        // Modificar solo si el nuevo SL basado en fractal es MEJOR que el SL actual
        bool should_modify = false;
        if (position_type == POSITION_TYPE_BUY && new_sl > current_sl) should_modify = true;
        else if (position_type == POSITION_TYPE_SELL && new_sl < current_sl) should_modify = true;

        if (should_modify)
        {
            // Checkear distancia mínima al precio actual
             double currentPrice = (position_type == POSITION_TYPE_BUY) ? SymbolInfoDouble(Symbol(), SYMBOL_BID) : SymbolInfoDouble(Symbol(), SYMBOL_ASK);
             double price_away = MathAbs(currentPrice - new_sl);
             double min_distance_pips = (BufferPips > 0 ? BufferPips : 5); // Usar BufferPips global si es > 0, sino 5 pips
             double min_distance_points = min_distance_pips * point * pipsFactor;
             if(min_distance_points <= 0 && point > 0) min_distance_points = min_distance_pips * point;
             else if(min_distance_points <= 0) min_distance_points = min_distance_pips * 0.0001; // Fallback

             if (price_away >= min_distance_points)
             {
                 if (trade.PositionModify(ticket, new_sl, current_tp)) // Usar current_tp
                 { Print("Pos ", ticket, " SL movido a ", new_sl, " (Fractal M15 Barra ", fractal_bar_idx, ")"); }
                 else { Print("Error modificando SL fractal pos ", ticket, ": ", GetLastError()); }
             }
            // else { Print("SL Fractal ", new_sl, " demasiado cerca del precio ", currentPrice, ". No modificado."); } // Debug
        }
    }
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("+------------------------------------------------------------------+");
   Print("| EA Liquidity 7.0 VOLATILIDAD (R:R Dinámico Avanzado)             |");
   Print("| Build: ", __MQL5BUILD__, ", Fecha: ", __DATE__, " ", TimeToString(TimeLocal(), TIME_MINUTES | TIME_SECONDS));
   Print("+------------------------------------------------------------------+");
   Print("Magic Number: 12345 (¡CAMBIAR SI ES NECESARIO!)");

   Print("--- Configuración de Funciones Clave ---");
   Print("Usar Ajuste Dinámico de R:R: ", (UseDynamicRRAdjust ? "Activado" : "Desactivado"));
   if(UseDynamicRRAdjust) {
       Print("  TF para Volatilidad R:R: ", EnumToString(VolatilityTFforRR));
       Print("  Factor R:R Baja Vol: ", DoubleToString(Inp_RR_LowVolFactor,2));
       Print("  Factor R:R Media Vol: ", DoubleToString(Inp_RR_MediumVolFactor,2));
       Print("  Factor R:R Alta Vol: ", DoubleToString(Inp_RR_HighVolFactor,2));
       Print("  Umbral Baja Vol (Mult): ", DoubleToString(Inp_RR_LowVolThrMult,2));
       Print("  Umbral Alta Vol (Mult): ", DoubleToString(Inp_RR_HighVolThrMult,2));
   }
   // *** CORRECCIÓN: MinRR_ForKeyLevelTP y MaxRR_ForKeyLevelTP son inputs ahora ***
   Print("Input Base MinRR_ForKeyLevelTP: ", DoubleToString(MinRR_ForKeyLevelTP,2));
   Print("Input Base MaxRR_ForKeyLevelTP: ", DoubleToString(MaxRR_ForKeyLevelTP,2));
   Print("Usar Niveles Clave para SL/TP: ", (UseKeyLevelsForSLTP ? "Activado" : "Desactivado"));
   Print("------------------------------------");

   dyn_ATRMultiplierForMinPenetration = ATRMultiplierForMinPenetration;
   dyn_ATRMultiplierForMaxPenetration = ATRMultiplierForMaxPenetration;
   dyn_BreakEvenPips                  = BreakEvenPips;
   dyn_TrailingDistancePips           = TrailingDistancePips;

   // --- Validar Inputs de R:R Dinámico ---
   ENUM_TIMEFRAMES validatedVolatilityTFforRR = VolatilityTFforRR;
   double validatedInp_RR_LowVolThrMult  = Inp_RR_LowVolThrMult;
   double validatedInp_RR_HighVolThrMult = Inp_RR_HighVolThrMult;
   double validatedInp_RR_LowVolFactor   = Inp_RR_LowVolFactor;
   double validatedInp_RR_MediumVolFactor= Inp_RR_MediumVolFactor;
   double validatedInp_RR_HighVolFactor  = Inp_RR_HighVolFactor;
   // *** CORRECCIÓN: Leer de los inputs ***
   double validatedMinRR_Base            = MinRR_ForKeyLevelTP;
   double validatedMaxRR_Base            = MaxRR_ForKeyLevelTP;

   if (UseDynamicRRAdjust)
   {
      if (validatedVolatilityTFforRR != PERIOD_D1 && validatedVolatilityTFforRR != PERIOD_W1)
      {
         Alert("Configuración Advertencia: VolatilityTFforRR (", EnumToString(validatedVolatilityTFforRR), ") debe ser D1 o W1. EA usará D1 internamente.");
         validatedVolatilityTFforRR = PERIOD_D1;
      }
      if (validatedInp_RR_LowVolThrMult >= validatedInp_RR_HighVolThrMult)
      {
         Alert("Configuración Advertencia: Inp_RR_LowVolThrMult (", DoubleToString(validatedInp_RR_LowVolThrMult,2), ") debe ser MENOR que Inp_RR_HighVolThrMult (", DoubleToString(validatedInp_RR_HighVolThrMult,2), "). EA usará 0.85 y 1.15 internamente.");
         validatedInp_RR_LowVolThrMult = 0.85;
         validatedInp_RR_HighVolThrMult = 1.15;
      }
      if (validatedInp_RR_LowVolFactor <=0 || validatedInp_RR_MediumVolFactor <=0 || validatedInp_RR_HighVolFactor <=0)
      {
         Alert("Configuración Advertencia: Los factores de R:R dinámico deben ser > 0. EA usará 0.8, 1.0, 1.2 para factores inválidos internamente.");
         if(validatedInp_RR_LowVolFactor <=0) validatedInp_RR_LowVolFactor = 0.8;
         if(validatedInp_RR_MediumVolFactor <=0) validatedInp_RR_MediumVolFactor = 1.0;
         if(validatedInp_RR_HighVolFactor <=0) validatedInp_RR_HighVolFactor = 1.2;
      }
   }
   if (validatedMinRR_Base <= 0.1)
   {
       Alert("Configuración Advertencia: MinRR_ForKeyLevelTP (",DoubleToString(validatedMinRR_Base,2),") es muy bajo. EA usará 0.5 internamente.");
       validatedMinRR_Base = 0.5;
   }
   if (validatedMaxRR_Base <= validatedMinRR_Base)
   {
       Alert("Configuración Advertencia: MaxRR_ForKeyLevelTP (",DoubleToString(validatedMaxRR_Base,2),") debe ser > MinRR_ForKeyLevelTP (",DoubleToString(validatedMinRR_Base,2),"). EA usará MinRR + 1.5 internamente para MaxRR.");
       validatedMaxRR_Base = validatedMinRR_Base + 1.5;
   }

   // Inicializar g_dyn_... con los valores base (potencialmente validados)
   g_dyn_MinRR_ForKeyLevelTP = validatedMinRR_Base;
   g_dyn_MaxRR_ForKeyLevelTP = validatedMaxRR_Base;

   if (UseDynamicRRAdjust) {
        // Llamar a la función de actualización con los valores validados
        UpdateDynamicRiskRewardRatiosOnInit(
            validatedVolatilityTFforRR,
            validatedInp_RR_LowVolFactor,
            validatedInp_RR_MediumVolFactor,
            validatedInp_RR_HighVolFactor,
            Inp_RR_ATR_Period, // Este input no se valida/corrige aquí, se asume ok
            Inp_RR_ATR_AvgPeriod, // Este input no se valida/corrige aquí, se asume ok
            validatedInp_RR_LowVolThrMult,
            validatedInp_RR_HighVolThrMult,
            validatedMinRR_Base, // Pasar los valores base validados
            validatedMaxRR_Base  // Pasar los valores base validados
        );
   }

   ArrayInitialize(partialClosedFlags, 0);
   ArrayResize(g_positionTickets,0);
   ArrayResize(g_initialVolumes,0);
   tradesToday = 0;
   lastH4TradeTime = 0;
   // *** CORRECCIÓN: g_CurrentSetup está declarada globalmente ***
   ZeroMemory(g_CurrentSetup);

   UpdateOldHighsLows();
   UpdateSessionHighsLows();

   Print("OnInit completado. EA listo.");
   return(INIT_SUCCEEDED);
}




void OnDeinit(const int reason)
{
   Print("EA Liquidity 7.0 VOLATILIDAD detenido. Razón: ", reason);
   // Limpiar objetos gráficos si se usan
   // Limpiar arrays globales si es necesario
   ArrayResize(g_positionTickets,0);
   ArrayResize(g_initialVolumes,0);
}

// Variable global para controlar la frecuencia de actualizaciones intensivas
datetime lastUpdateTime = 0;
int updateFrequencySeconds = 15; // Actualizar detecciones cada 15 segundos (ajustable)

// *** IMPLEMENTACIÓN DE UpdateDynamicRiskRewardRatios PARA ON TICK ***
void UpdateDynamicRiskRewardRatios()
{
    if (!UseDynamicRRAdjust) {
        // Si el ajuste dinámico no está activado, asegúrate de que los valores globales
        // reflejen los inputs base (por si acaso algo los cambió)
        g_dyn_MinRR_ForKeyLevelTP = MinRR_ForKeyLevelTP;
        g_dyn_MaxRR_ForKeyLevelTP = MaxRR_ForKeyLevelTP;
        return;
    }

    // La lógica es muy similar a la de OnInit, pero usando los inputs directamente
    double atrCurrent = ComputeATR(VolatilityTFforRR, Inp_RR_ATR_Period, 1); // Vela cerrada anterior
    if (atrCurrent <= 0) {
        // Podrías imprimir un warning o revertir a valores base
        // PrintFormat("UpdateDynamicRiskRewardRatios (OnTick): ATR de %s inválido. Usando R:R base de inputs.", EnumToString(VolatilityTFforRR));
        g_dyn_MinRR_ForKeyLevelTP = MinRR_ForKeyLevelTP;
        g_dyn_MaxRR_ForKeyLevelTP = MaxRR_ForKeyLevelTP;
        return;
    }

    double sumAtr = 0; int countAtr = 0;
    for (int i = 2; i <= Inp_RR_ATR_AvgPeriod + 1; i++) { // Empezar desde la vela anterior a la actual (i=2 porque atrCurrent es i=1)
        double pastAtr = ComputeATR(VolatilityTFforRR, Inp_RR_ATR_Period, i);
        if (pastAtr > 0) { sumAtr += pastAtr; countAtr++; }
    }

    if (countAtr == 0) {
        // PrintFormat("UpdateDynamicRiskRewardRatios (OnTick): No se pudo promediar ATR de %s. Usando R:R base de inputs.", EnumToString(VolatilityTFforRR));
        g_dyn_MinRR_ForKeyLevelTP = MinRR_ForKeyLevelTP;
        g_dyn_MaxRR_ForKeyLevelTP = MaxRR_ForKeyLevelTP;
        return;
    }
    double atrAvg = sumAtr / countAtr;

    MarketRegime volRegimeDetermined; // Usar una variable local para claridad
    if (atrCurrent < atrAvg * Inp_RR_LowVolThrMult) volRegimeDetermined = LOW_VOLATILITY;
    else if (atrCurrent > atrAvg * Inp_RR_HighVolThrMult) volRegimeDetermined = HIGH_VOLATILITY;
    else volRegimeDetermined = RANGE_MARKET; // "MEDIA"

    double factorToApply = Inp_RR_MediumVolFactor; // Por defecto es el factor medio
    if(volRegimeDetermined == HIGH_VOLATILITY) factorToApply = Inp_RR_HighVolFactor;
    else if(volRegimeDetermined == LOW_VOLATILITY) factorToApply = Inp_RR_LowVolFactor;

    // Actualizar las variables globales g_dyn_...
    g_dyn_MinRR_ForKeyLevelTP = MinRR_ForKeyLevelTP * factorToApply;
    g_dyn_MaxRR_ForKeyLevelTP = MaxRR_ForKeyLevelTP * factorToApply;

    // Asegurar límites para los R:R dinámicos
    g_dyn_MinRR_ForKeyLevelTP = MathMax(0.5, g_dyn_MinRR_ForKeyLevelTP); // Mínimo R:R de 0.5
    g_dyn_MaxRR_ForKeyLevelTP = MathMax(g_dyn_MinRR_ForKeyLevelTP + 0.5, g_dyn_MaxRR_ForKeyLevelTP); // Max RR al menos 0.5 más que Min RR
    g_dyn_MaxRR_ForKeyLevelTP = MathMin(15.0, g_dyn_MaxRR_ForKeyLevelTP); // Límite superior para Max RR

    // Opcional: Imprimir si los valores cambian para depuración
    static double prev_dyn_MinRR = 0, prev_dyn_MaxRR = 0;
    if(g_dyn_MinRR_ForKeyLevelTP != prev_dyn_MinRR || g_dyn_MaxRR_ForKeyLevelTP != prev_dyn_MaxRR) {
       PrintFormat("OnTick - R:R Dinámico Actualizado: Régimen Vol %s (%s). MinRR: %.2f, MaxRR: %.2f. Factor Aplicado: %.2f",
          EnumToString(volRegimeDetermined), EnumToString(VolatilityTFforRR),
          g_dyn_MinRR_ForKeyLevelTP, g_dyn_MaxRR_ForKeyLevelTP, factorToApply);
       prev_dyn_MinRR = g_dyn_MinRR_ForKeyLevelTP;
       prev_dyn_MaxRR = g_dyn_MaxRR_ForKeyLevelTP;
    }
}


void OnTick()
{
   // --- Control de Frecuencia ---
   datetime currentTime = TimeCurrent();
   if (currentTime < lastUpdateTime + updateFrequencySeconds)
   {
       // Gestionar solo SL/TP rápidos si es necesario, pero no re-calcular todo
        if(PositionsTotal() > 0) {
            // Llamadas rápidas que no dependan de detecciones pesadas
            // ManageRisk(); // Podría llamarse aquí para BE/Trailing rápidos, pero cuidado con recálculos innecesarios
        }
       return;
   }
   lastUpdateTime = currentTime; // Actualizar tiempo de la última ejecución completa


   // --- Reset Diario ---
   static datetime lastTradeDay = 0;
   MqlDateTime dtCurrent, dtLast;
   TimeToStruct(currentTime, dtCurrent);
   TimeToStruct(lastTradeDay, dtLast);
   if(dtCurrent.day != dtLast.day || lastTradeDay == 0)
   {
      tradesToday = 0;
      ArrayInitialize(partialClosedFlags, 0);
      // Limpiar almacenamiento de volúmenes al inicio del día? O mantenerlos si hay trades overnight?
      // Por seguridad, limpiamos:
       ArrayResize(g_positionTickets,0);
       ArrayResize(g_initialVolumes,0);

      lastTradeDay = currentTime;
      UpdateOldHighsLows();
      // Resetear sesiones (la lógica de cálculo necesita mejora)
      AsiaHigh = 0; AsiaLow = 0; AsiaStartTime = 0; LondonHigh = 0; LondonLow = 0; LondonStartTime = 0; NYHigh = 0; NYLow = 0; NYStartTime = 0;
      Print("--- Nuevo día (", TimeToString(currentTime, TIME_DATE), ") --- Trades:", tradesToday);
   }

   // --- Filtro por Sesiones ---
   if(FilterBySessions)
   {
      int currentHour = dtCurrent.hour;
      // Lógica de sesión necesita revisión para cruce de medianoche
      bool inAsia   = false; // Lógica placeholder
       if(AsiaOpen > AsiaClose) inAsia = (currentHour >= AsiaOpen || currentHour < AsiaClose); // Cruza medianoche
       else inAsia = (currentHour >= AsiaOpen && currentHour < AsiaClose); // Mismo día

      bool inLondon = (currentHour >= LondonOpen && currentHour < LondonClose);
      bool inNY     = (currentHour >= NYOpen && currentHour < NYClose);

      // Operar solo en Londres y NY? Ajustar según preferencia
      if (!inLondon && !inNY /*&& !inAsia*/) { return; }
   }

   // --- Actualizar Bias (H4 y D1) ---
   if(UseDailyBias)
   {
      ComputeH4Bias(); // Actualiza g_H4BiasBullish
      ComputeD1Bias(); // Actualiza g_D1BiasBullish
   }

   // --- Actualizar Régimen de Volatilidad y Parámetros Dinámicos ---
   double volatilityIndex = CalculateDynamicVolatilityIndex(14, 20, 10); // M5 based
   // *** CALIBRAR ESTOS UMBRALES ***
   MarketRegime currentRegime = DetermineMarketRegime(volatilityIndex, 0.0003, 0.0001); // EJEMPLO - ¡NECESITA AJUSTE REAL!
   if(currentRegime != g_regime)
   {
      AdjustParametersBasedOnVolatility(currentRegime);
      g_regime = currentRegime;
      Print("Nuevo Régimen Volatilidad: ", EnumToString(g_regime), " (Index: ", volatilityIndex, ")");
   }

    // *** CORRECCIÓN: Llamar a la función correcta ***
    UpdateDynamicRiskRewardRatios();

   // --- Detectar Estructura M15 ---
   m15Structure = DetectMarketStructureM15(FractalLookback_M15, 2);

   // --- Detectar Elementos ICT (Liquidez, FVG, OB, BB) ---
   DetectLiquidity();
   DetectFairValueGaps();
   DetectOrderBlocks();
   DetectBreakerBlocks();
   // DetectJudasSwing();

   // --- Gestión de Posiciones Abiertas ---
   if(PositionsTotal() > 0)
   {
      ManageRisk(); // Llama a BE, Parciales, Trailings
      ManageSLWithStopRunProtection(); // Protección defensiva SL
      return; // No buscar nuevas entradas si hay posiciones
   }

   // --- Buscar Nuevas Entradas ---
   // Control para no operar demasiado seguido (ej: solo una vez por vela H4 si hay trades hoy)
   datetime currentH4Time = iTime(Symbol(), PERIOD_H4, 0);
   if(lastH4TradeTime == currentH4Time && tradesToday > 0) {
       // Print("Ya se operó/revisó en esta vela H4."); // Debug
       return;
   }

   // Prioridad 1: Entradas de Caza de Liquidez (Stop Hunts)
   CheckLiquidityHunting();
   if(PositionsTotal() > 0 || tradesToday >= MaxTradesPerDay) return; // Salir si se abrió trade o límite alcanzado

   // Prioridad 2: Entradas en POIs (OBs / Breakers) con confirmación
   CheckTradeEntries();
   // No necesitamos retornar aquí, OnTick termina.

}


// Helper para AssessOBQuality (Placeholder - requiere lógica real)
bool CheckHTFConfluence(OrderBlock &ob) { return false; }
bool IsPremiumPosition(OrderBlock &ob) { return false; }
double ComputeATRSlope(int period){ return 0.0;}


// Evaluar Calidad de Order Block
double AssessOBQuality(OrderBlock &ob) // Pasada por referencia para modificarla directamente
{
    double quality = 5.0; // Base score
    double point = SymbolInfoDouble(Symbol(), SYMBOL_POINT);
    double atrM5 = ComputeATR(PERIOD_M5, 14);
    if(atrM5 <= point && point > 0) atrM5 = point * 100; // Fallback si ATR es muy pequeño
    else if(atrM5 <= 0) atrM5 = 0.0001 * 100;


    // 1. Tamaño Relativo al ATR
    double obRange = ob.highPrice - ob.lowPrice;
    ob.relativeSize = (atrM5 > 0) ? obRange / atrM5 : 1.0;
    if(ob.relativeSize > 1.5) quality += 1.5; // Buen tamaño
    else if (ob.relativeSize < 0.8) quality -= 1.0; // Pequeño

    // 2. Mechas (Wicks)
    double bodySize = MathAbs(ob.closePrice - ob.openPrice);
    if (bodySize > point * 5 || (point == 0 && bodySize > 0.00005) ) // Evitar división por cero o cuerpos muy pequeños, considerar un mínimo (e.g., 5 puntos)
    {
        double upperWick = ob.highPrice - MathMax(ob.openPrice, ob.closePrice);
        double lowerWick = MathMin(ob.openPrice, ob.closePrice) - ob.lowPrice;
        // OB Alcista -> Vela original BAJISTA. Interesa mecha INFERIOR grande
        if(ob.isBullish && lowerWick > bodySize * 0.7) quality += 1.0; // Mecha inferior prominente
        // OB Bajista -> Vela original ALCISTA. Interesa mecha SUPERIOR grande
        if(!ob.isBullish && upperWick > bodySize * 0.7) quality += 1.0; // Mecha superior prominente
    }

    // 3. Confluencia HTF (Placeholder, usa tu lógica)
    ob.hasHTFConfluence = CheckHTFConfluence(ob);
    if(ob.hasHTFConfluence) quality += 1.5;

    // 4. Zona Premium/Discount (Placeholder, usa tu lógica)
    ob.isPremium = IsPremiumPosition(ob);
    if((ob.isBullish && !ob.isPremium) || (!ob.isBullish && ob.isPremium)) quality += 1.0;

    // 5. Volumen del OB vs Promedio y Volumen de Desplazamiento
    int obBarIndexM5 = iBarShift(Symbol(), PERIOD_M5, ob.time, false);
    ob.obTickVolume = 0; // Inicializar
    ob.volumeRatio = 0;  // Inicializar

    if(obBarIndexM5 >= 0)
    {
        ob.obTickVolume = iTickVolume(Symbol(), PERIOD_M5, obBarIndexM5);
        double avgVolume = 0;
        long volSum = 0;
        int volBarsCount = 0;
        int barsM5 = Bars(Symbol(), PERIOD_M5);

        // Calcular volumen promedio de las 10 velas ANTERIORES al OB
        for(int i = obBarIndexM5 + 1; i <= MathMin(barsM5 - 1, obBarIndexM5 + 10); i++) {
           volSum += iTickVolume(Symbol(), PERIOD_M5, i);
           volBarsCount++;
        }
        if(volBarsCount > 0) avgVolume = (double)volSum / volBarsCount;

        if(avgVolume > 0) {
            ob.volumeRatio = (double)ob.obTickVolume / avgVolume;
            if(ob.volumeRatio > VolumeOBMultiplier) { // Usa input global
                quality += 2.0; // Mayor impacto para volumen fuerte en OB
            } else if (ob.volumeRatio < 0.8) {
                quality -= 1.5; // Mayor penalización para volumen bajo en OB
            }
        } else {
            ob.volumeRatio = 0; // No se pudo calcular el ratio
        }

        // 6. Volumen Post-OB (desplazamiento en las siguientes 1-3 velas)
        double displacementVolumeAvg = 0;
        long displacementVolSum = 0;
        int displacementBarsCount = 0;
        // Mirar 3 barras DESPUÉS del OB (índices menores)
        for(int i = obBarIndexM5 - 1; i >= MathMax(0, obBarIndexM5 - 3); i--) {
           displacementVolSum += iTickVolume(Symbol(), PERIOD_M5, i);
           displacementBarsCount++;
        }
        if(displacementBarsCount > 0) displacementVolumeAvg = (double)displacementVolSum / displacementBarsCount;

        // Comparar volumen de desplazamiento con el mismo avgVolume anterior (o recalcular uno para el periodo de desplazamiento)
        if(avgVolume > 0 && displacementVolumeAvg > avgVolume * VolumeDisplacementMultiplier) { // Usa input global
            quality += 2.5; // Mayor impacto para desplazamiento fuerte con volumen
        }
    }

    // 7. ¿Cerca de FVG? (Mejora si el OB creó o está cerca de un FVG alineado)
    // ... (Tu lógica FVG check aquí, puede añadir más 'quality') ...
    // Ejemplo simple: buscar FVG inmediatamente después del OB
    int fvgLookahead = 3; // Cuántas barras después del OB buscar un FVG
    if (obBarIndexM5 - fvgLookahead > 0) {
        for(int k=0; k < ArraySize(fairValueGaps); k++) {
            // Suponiendo que fairValueGaps está ordenado o se busca uno relevante cercano en tiempo
            // Esta lógica necesita refinar cómo se relaciona un FVG específico con un OB
            // Aquí un ejemplo muy básico: si hay un FVG reciente alineado
            // datetime fvgTime = 0; // Necesitarías el tiempo del FVG para comparar
            // if (fairValueGaps[k].isBullish == ob.isBullish && 
            //     iTime(Symbol(), PERIOD_M5, obBarIndexM5 -1) == fvgTime ) // O FVG entre obBarIndexM5-1 y obBarIndexM5-3
            // {
            //    quality += 0.5;
            //    break;
            // }
        }
    }

    return MathMax(1.0, MathMin(10.0, quality)); // Limitar calidad entre 1 y 10
}

// Chequear si un OB ha sido barrido (mitigado)
bool IsOBSwept(OrderBlock &ob)
{
   int obIndex = iBarShift(Symbol(), PERIOD_M5, ob.time, false);
   if(obIndex < 0) return false; // No se encontró la barra

   // Buscar desde la vela siguiente al OB hasta la actual
   for(int i = obIndex - 1; i >= 0; i--)
   {
      if(ob.isBullish) // OB Alcista (vela original bajista) - Buscar si Low fue barrido
      {
          // Considerar mitigación si toca el 50% o el Low
          // double obMidPoint = (ob.openPrice + ob.closePrice) / 2.0; // 50% cuerpo
          // if(iLow(Symbol(), PERIOD_M5, i) <= obMidPoint) return true;
         if(iLow(Symbol(), PERIOD_M5, i) <= ob.lowPrice) return true; // Barrido completo del Low
      }
      else // OB Bajista (vela original alcista) - Buscar si High fue barrido
      {
          // double obMidPoint = (ob.openPrice + ob.closePrice) / 2.0;
          // if(iHigh(Symbol(), PERIOD_M5, i) >= obMidPoint) return true;
         if(iHigh(Symbol(), PERIOD_M5, i) >= ob.highPrice) return true; // Barrido completo del High
      }
   }
   return false; // No barrido
}

// Ordenar Order Blocks por Calidad (Descendente)
void SortOrderBlocksByQuality()
{
   int size = ArraySize(orderBlocks);
   if(size <= 1) return;

   // Bubble Sort simple
   for(int i = 0; i < size - 1; i++)
   {
      for(int j = 0; j < size - i - 1; j++)
      {
         if(orderBlocks[j].quality < orderBlocks[j + 1].quality)
         {
            OrderBlock temp = orderBlocks[j];
            orderBlocks[j] = orderBlocks[j + 1];
            orderBlocks[j + 1] = temp;
         }
      }
   }
}

// Placeholder para IsSignalRefined
bool IsSignalRefined(bool isBullish)
{
    // Añadir lógica para evaluar calidad de vela de señal si es necesario
    return true; // Por defecto, no filtrar
}

// Placeholders adicionales para funciones no implementadas completamente
double CalculateMarketStructureScore(int lookbackBars) { return 50.0; }
double CalculateLiquidityZoneWeight(const LiquidityZone &lz) { return lz.strength; }
bool IsLiquidityZoneStrong(const LiquidityZone &lz) { return lz.strength >= 8.0; }
double CalculateH1MarketScore(int lookbackBars) { return 50.0; }
bool IsMultiTFConfirmation(MarketStructureState m15State, MarketStructureState h1State) { return true; }
double CalculateStructureWeight(MarketStructureState state, double score) { return score; }
bool IsSignalQualityAcceptable(double m15Score, double h1Score) { return true; }

//+------------------------------------------------------------------+



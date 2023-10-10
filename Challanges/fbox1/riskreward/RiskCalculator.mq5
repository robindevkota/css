﻿//+------------------------------------------------------------------+
//|                                               RiskCalculator.mq5 |
//|                             Copyright © 2014-2022, EarnForex.com |
//+------------------------------------------------------------------+
#property copyright "Copyright © 2014-2022, EarnForex.com"
#property link      "https://www.earnforex.com/metatrader-indicators/Risk-Calculator/"
#property version   "1.13"
#property indicator_separate_window
#property indicator_plots 0

// #define _DEBUG

#property description "Calculates total risk and reward based on the existing positions and pending orders."
#property description "Known issues:"
#property description "1. The results may be somewhat inaccurate when quote currency is different from account currency."
#property description "2. Too many pending orders with SL/TP may be too slow to process."
#property description "3. Assumes constant spread on each tick."
#property description "4. Ignores lack of margin for order execution."
#property description "5. Ignores correlations of currency pairs."
#property description "6. Ignores triangular and other forms of arbitrage."
#property description "7. Does not take into account price slippage."

#include <OrderMap.mqh>
#include <StatusObject.mqh>
#include <RemainingOrderObject.mqh>
#include <OrderIterator.mqh>

input group "Main"
input bool   CalculateSpreads = true; // If true, potential loss due to spreads will become the part of the potential maximum loss.
input bool   CalculateSwaps = true; // If true, accrued swaps will become the part of the potential maximum loss.
input double CommissionPerLot = 0; // Commission charged per lot (one side) in account currency.
input bool   UseEquityInsteadOfBalance = false; // If true, Account Equity will be used instead of Account Balance.
input bool   SeparatePendingOpenCalculation = false; // If true, calculate separate risk risk on pending orders and open positions.
input group "Font"
input color  cpFontColor = clrAzure; // Font color to output the currency pair names.
input color  mnFontColor = clrPaleGoldenrod; // Font color to output the risk in money form.
input color  pcFontColor = clrLimeGreen; // Font color to output the risk in percentage form.
input color  hdFontColor = clrBlue; // Font color to output the headers when Reward is shown.
input string FontFace  = "Courier"; // Font name.
input int    FontSize  = 8; // Font size.
input group "Spacing"
input int    scaleY = 15; // Number of pixels per line in output.
input int    offsetX = 20; // Horizontal offset for output.
input int    offsetY = 20; // Vertical offset for output.
input group "Reward"
input bool CalculateReward = false;

// Main object for calculating minimum profit (maximum loss) with its static variables initialized.
double COrderIterator::min_profit = UNDEFINED;
double COrderIterator::max_sell_volume = 0;
bool COrderIterator::hedging = false;
COrderIterator *OrderIterator;

// Global variable for the current output line's vertical indent.
int Y;
// Global variable for the separate indicator window number;
int Window = -1;

// Global variable to store loss due to swaps of the currently open positions. In account currency.
double swap;
// Global variable for spread - it is used in OrderIterator instances but is defined for each currency pair in this file.
double spread;
// Global variable to store loss due to commission that will be incurred based on current trades. In account currency.
double commission;
// Global variable to store the detected account currency.
string AccCurrency;
// Calculated total risk in money form.
double total_risk;
// Calculated total reward in money form.
double total_reward;
// These will be needed only if SeparatePendingOpenCalculation is true.
double total_risk_po;
double total_reward_po;

#ifdef _DEBUG
bool single_run = false;
#endif

uint CalcuationDoneTime = 0; // Time of last recalculation in milliseconds. Used in OnTimer() handler to skip recalculation if less than 1 second passed.

enum target_orders
{
    All,
    OnlyPositions,
    OnlyPending
};

//+------------------------------------------------------------------+
//| Initialization function.                                         |
//+------------------------------------------------------------------+
void OnInit()
{
    IndicatorSetString(INDICATOR_SHORTNAME, "Risk Calculator");
    EventSetTimer(1);
}

//+------------------------------------------------------------------+
//| Deinitialization function.                                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();
    ObjectsDeleteAll(0, Window, OBJ_LABEL);
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Indicator calculation event.                                     |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,      // size of the price[] array
                const int prev_calculated,  // bars handled on a previous call
                const int begin,            // where the significant data start from
                const double& price[]       // array to calculate
               )
{
    // If could not find account currency, probably not connected.
    AccCurrency = AccountInfoString(ACCOUNT_CURRENCY);
    if (AccCurrency == "") return 0;
    if (AccCurrency == "RUR") AccCurrency = "RUB";
    if (AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
        COrderIterator::hedging = true;
    else COrderIterator::hedging = false;

    CalculateRisk();

    return 0;
}

//+------------------------------------------------------------------+
//| Trade event handler.                                             |
//+------------------------------------------------------------------+
void OnTrade()
{
    if (AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
        COrderIterator::hedging = true;
    else COrderIterator::hedging = false;
    CalculateRisk();
}

//+------------------------------------------------------------------+
//| Timer event handler                                              |
//+------------------------------------------------------------------+
void OnTimer()
{
    if (GetTickCount() - CalcuationDoneTime < 1000) return;
    CalculateRisk();
}

//+------------------------------------------------------------------+
//| Main calculation function. Called from event handlers.           |
//+------------------------------------------------------------------+
void CalculateRisk()
{
    int total;
#ifdef _DEBUG
    if (single_run) return;
    Print("Hedging mode = ", COrderIterator::hedging);
#endif

    if (Window == -1) Window = ChartWindowFind();
    ObjectsDeleteAll(0, Window, OBJ_LABEL);

    Y = 0;

    total_risk = 0;
    total_reward = 0;
    total_risk_po = 0;
    total_reward_po = 0;

    ObjectsDeleteAll(0, Window, OBJ_LABEL);

    if ((CalculateReward) || (SeparatePendingOpenCalculation)) // Need headers only if Reward information is displayed or separate pending/positions count is used.
    {
        uint w, h;
        TextSetFont(FontFace, FontSize * -10);
        TextGetSize("A", w, h);

        ObjectCreate(0, "HeaderSymbol", OBJ_LABEL, Window, 0, 0);
        ObjectSetString(0, "HeaderSymbol", OBJPROP_TEXT, "Symbol");
        ObjectSetString(0, "HeaderSymbol", OBJPROP_FONT, FontFace);
        ObjectSetInteger(0, "HeaderSymbol", OBJPROP_FONTSIZE, FontSize);
        ObjectSetInteger(0, "HeaderSymbol", OBJPROP_COLOR, hdFontColor);
        ObjectSetInteger(0, "HeaderSymbol", OBJPROP_CORNER, 0);
        ObjectSetInteger(0, "HeaderSymbol", OBJPROP_XDISTANCE, offsetX);
        ObjectSetInteger(0, "HeaderSymbol", OBJPROP_YDISTANCE, offsetY);

        string risk_text = "Risk";
        if (SeparatePendingOpenCalculation) risk_text += " (Open Positions)";
        ObjectCreate(0, "HeaderRisk", OBJ_LABEL, Window, 0, 0);
        ObjectSetString(0, "HeaderRisk", OBJPROP_TEXT, risk_text);
        ObjectSetString(0, "HeaderRisk", OBJPROP_FONT, FontFace);
        ObjectSetInteger(0, "HeaderRisk", OBJPROP_FONTSIZE, FontSize);
        ObjectSetInteger(0, "HeaderRisk", OBJPROP_COLOR, hdFontColor);
        ObjectSetInteger(0, "HeaderRisk", OBJPROP_CORNER, 0);
        ObjectSetInteger(0, "HeaderRisk", OBJPROP_XDISTANCE, offsetX + 17 * w);
        ObjectSetInteger(0, "HeaderRisk", OBJPROP_YDISTANCE, offsetY);

        int x = 47;
        if (CalculateReward)
        {
            string reward_text = "Reward";
            if (SeparatePendingOpenCalculation) reward_text += " (Open Positions)";
            ObjectCreate(0, "HeaderReward", OBJ_LABEL, Window, 0, 0);
            ObjectSetString(0, "HeaderReward", OBJPROP_TEXT, reward_text);
            ObjectSetString(0, "HeaderReward", OBJPROP_FONT, FontFace);
            ObjectSetInteger(0, "HeaderReward", OBJPROP_FONTSIZE, FontSize);
            ObjectSetInteger(0, "HeaderReward", OBJPROP_COLOR, hdFontColor);
            ObjectSetInteger(0, "HeaderReward", OBJPROP_CORNER, 0);
            ObjectSetInteger(0, "HeaderReward", OBJPROP_XDISTANCE, offsetX + x * w);
            ObjectSetInteger(0, "HeaderReward", OBJPROP_YDISTANCE, offsetY);
            x += 28;
        }
        if (SeparatePendingOpenCalculation)
        {
            risk_text = "Risk (Pending Orders)";
            ObjectCreate(0, "HeaderRiskPO", OBJ_LABEL, Window, 0, 0);
            ObjectSetString(0, "HeaderRiskPO", OBJPROP_TEXT, risk_text);
            ObjectSetString(0, "HeaderRiskPO", OBJPROP_FONT, FontFace);
            ObjectSetInteger(0, "HeaderRiskPO", OBJPROP_FONTSIZE, FontSize);
            ObjectSetInteger(0, "HeaderRiskPO", OBJPROP_COLOR, hdFontColor);
            ObjectSetInteger(0, "HeaderRiskPO", OBJPROP_CORNER, 0);
            ObjectSetInteger(0, "HeaderRiskPO", OBJPROP_XDISTANCE, offsetX + x * w);
            ObjectSetInteger(0, "HeaderRiskPO", OBJPROP_YDISTANCE, offsetY);
            x += 28;

            if (CalculateReward)
            {
                string reward_text = "Reward (Pending Orders)";
                ObjectCreate(0, "HeaderRewardPO", OBJ_LABEL, Window, 0, 0);
                ObjectSetString(0, "HeaderRewardPO", OBJPROP_TEXT, reward_text);
                ObjectSetString(0, "HeaderRewardPO", OBJPROP_FONT, FontFace);
                ObjectSetInteger(0, "HeaderRewardPO", OBJPROP_FONTSIZE, FontSize);
                ObjectSetInteger(0, "HeaderRewardPO", OBJPROP_COLOR, hdFontColor);
                ObjectSetInteger(0, "HeaderRewardPO", OBJPROP_CORNER, 0);
                ObjectSetInteger(0, "HeaderRewardPO", OBJPROP_XDISTANCE, offsetX + x * w);
                ObjectSetInteger(0, "HeaderRewardPO", OBJPROP_YDISTANCE, offsetY);
            }
        }
        Y++;
    }

    // Orders.
    total = OrdersTotal();
    for (int i = 0; i < total; i++)
    {
        if (!OrderSelect(OrderGetTicket(i))) continue;
        CheckCurrencyPair(OrderGetString(ORDER_SYMBOL));
    }

    // Positions.
    total = PositionsTotal();
    for (int i = 0; i < total; i++)
    {
        if (!PositionSelect(PositionGetSymbol(i))) continue;
        CheckCurrencyPair(PositionGetString(POSITION_SYMBOL));
    }

    Y++;

    if (!SeparatePendingOpenCalculation)
    {
        // Do once.
        OutputTotalRisk(total_risk, Risk);
        if (CalculateReward) OutputTotalRisk(total_reward, Reward);
    }
    else // Do twice.
    {
        OutputTotalRisk(total_risk, Risk, OnlyPositions);
        if (CalculateReward) OutputTotalRisk(total_reward, Reward, OnlyPositions);

        OutputTotalRisk(total_risk_po, Risk, OnlyPending);
        if (CalculateReward) OutputTotalRisk(total_reward_po, Reward, OnlyPending);
    }

#ifdef _DEBUG
    single_run = true;
#endif
    ChartRedraw();
    CalcuationDoneTime = GetTickCount(); // Milliseconds.
}

//+-----------------------------------------------------------------------------------------+
//| Checks if currency pair should be processed and adjusts total_risk calculation function.|
//+-----------------------------------------------------------------------------------------+
void CheckCurrencyPair(const string cp)
{
    // This currency pair has already been processed - there is a TEXT_LABEL with its name.
    if (ObjectFind(0, cp) > 0) return;

    if (!SeparatePendingOpenCalculation)
    {
        // Do once.
        // Zero swap loss before proceeding to the next currency pair.
        swap = 0;
        commission = 0;

        double risk = ProcessCurrencyPair(cp, Risk);
        // UNDEFINED is stronger than UNLIMITED. UNLIMITED is stronger than any number.
        if ((risk != UNLIMITED) && (total_risk != UNLIMITED) && (risk != UNDEFINED) && (total_risk != UNDEFINED)) total_risk += risk;
        else if (risk == UNDEFINED) total_risk = UNDEFINED;
        else if (total_risk != UNDEFINED) total_risk = UNLIMITED;

        if (CalculateReward)
        {
            swap = 0;
            commission = 0;

            double reward = ProcessCurrencyPair(cp, Reward);
            if ((reward != UNLIMITED) && (total_reward != UNLIMITED) && (reward != UNDEFINED) && (total_reward != UNDEFINED)) total_reward += reward;
            else if (reward == UNDEFINED) total_reward = UNDEFINED;
            else if (total_reward != UNDEFINED) total_reward = UNLIMITED;
        }
    }
    else // Do twice.
    {
        // Zero swap loss before proceeding to the next currency pair.
        swap = 0;
        commission = 0;

        double risk = ProcessCurrencyPair(cp, Risk, OnlyPositions);
        // UNDEFINED is stronger than UNLIMITED. UNLIMITED is stronger than any number.
        if ((risk != UNLIMITED) && (total_risk != UNLIMITED) && (risk != UNDEFINED) && (total_risk != UNDEFINED)) total_risk += risk;
        else if (risk == UNDEFINED) total_risk = UNDEFINED;
        else if (total_risk != UNDEFINED) total_risk = UNLIMITED;

        if (CalculateReward)
        {
            swap = 0;
            commission = 0;

            double reward = ProcessCurrencyPair(cp, Reward, OnlyPositions);
            if ((reward != UNLIMITED) && (total_reward != UNLIMITED) && (reward != UNDEFINED) && (total_reward != UNDEFINED)) total_reward += reward;
            else if (reward == UNDEFINED) total_reward = UNDEFINED;
            else if (total_reward != UNDEFINED) total_reward = UNLIMITED;
        }

        // Zero swap loss before proceeding to the next currency pair.
        swap = 0;
        commission = 0;

        risk = ProcessCurrencyPair(cp, Risk, OnlyPending);
        // UNDEFINED is stronger than UNLIMITED. UNLIMITED is stronger than any number.
        if ((risk != UNLIMITED) && (total_risk_po != UNLIMITED) && (risk != UNDEFINED) && (total_risk_po != UNDEFINED)) total_risk_po += risk;
        else if (risk == UNDEFINED) total_risk_po = UNDEFINED;
        else if (total_risk_po != UNDEFINED) total_risk_po = UNLIMITED;

        if (CalculateReward)
        {
            swap = 0;
            commission = 0;

            double reward = ProcessCurrencyPair(cp, Reward, OnlyPending);
            if ((reward != UNLIMITED) && (total_reward_po != UNLIMITED) && (reward != UNDEFINED) && (total_reward_po != UNDEFINED)) total_reward_po += reward;
            else if (reward == UNDEFINED) total_reward_po = UNDEFINED;
            else if (total_reward_po != UNDEFINED) total_reward_po = UNLIMITED;
        }
    }
    Y++;
}

//+------------------------------------------------------------------+
//| Calculates and outputs risk for a given currency pair.           |
//+------------------------------------------------------------------+
double ProcessCurrencyPair(const string cp, const mode_of_operation mode, target_orders to = All)
{
#ifdef _DEBUG
    Print(cp);
#endif

    int total;
    COrderIterator::min_profit = UNDEFINED;
    COrderIterator::max_sell_volume = 0;
    OrderIterator = new COrderIterator();
    OrderIterator.mode = mode;

    CDOMObject *order;

    // Maximum loss (risk) in account currency.
    double MoneyRisk = 0;

    if (CalculateSpreads) spread = SymbolInfoInteger(cp, SYMBOL_SPREAD) * SymbolInfoDouble(cp, SYMBOL_POINT);
    else spread = 0;

    if (to != OnlyPositions)
    {
        total = OrdersTotal();
        for (int i = 0; i < total; i++)
        {
            ulong ticket = OrderGetTicket(i);
            if (!OrderSelect(ticket)) continue;

            if (OrderGetString(ORDER_SYMBOL) != cp) continue;

            ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
            double volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
            double sl = OrderGetDouble(ORDER_SL);
            double tp = OrderGetDouble(ORDER_TP);

            commission += CommissionPerLot * volume * 2;
            if ((ot == ORDER_TYPE_SELL_LIMIT) || (ot == ORDER_TYPE_SELL_STOP))
            {
                order = new CRemainingOrderObject(ticket, OrderGetDouble(ORDER_PRICE_OPEN), volume, Sell, sl == 0 ? 0 : sl - spread, tp == 0 ? 0 : tp - spread, Pending, 0, 0);
                OrderIterator.RO.Add(order);
            }
            else if ((ot == ORDER_TYPE_BUY_STOP) || (ot == ORDER_TYPE_BUY_LIMIT))
            {
                order = new CRemainingOrderObject(ticket, OrderGetDouble(ORDER_PRICE_OPEN) - spread, volume, Buy, sl, tp, Pending, 0, 0);
                OrderIterator.RO.Add(order);
            }
            else if (ot == ORDER_TYPE_SELL_STOP_LIMIT)
            {
                double stop_limit = OrderGetDouble(ORDER_PRICE_STOPLIMIT);
                // Add stop-limit order.
                order = new CRemainingOrderObject(ticket, OrderGetDouble(ORDER_PRICE_OPEN), volume, Sell, sl == 0 ? 0 : sl - spread, tp == 0 ? 0 : tp - spread, StopLimit, 0, stop_limit);
                OrderIterator.RO.Add(order);
                // Add inactive limit order.
                order = new CRemainingOrderObject(ticket, stop_limit, volume, Sell, sl == 0 ? 0 : sl - spread, tp == 0 ? 0 : tp - spread, Inactive, ticket, stop_limit);
                OrderIterator.RO.Add(order);
            }
            else if (ot == ORDER_TYPE_BUY_STOP_LIMIT)
            {
                double stop_limit = OrderGetDouble(ORDER_PRICE_STOPLIMIT);
                // Add stop-limit order.
                order = new CRemainingOrderObject(ticket, OrderGetDouble(ORDER_PRICE_OPEN) - spread, volume, Buy, sl, tp, StopLimit, 0, stop_limit - spread);
                OrderIterator.RO.Add(order);
                // Add inactive limit order.
                order = new CRemainingOrderObject(ticket, stop_limit - spread, volume, Buy, sl, tp, Inactive, ticket, stop_limit);
                OrderIterator.RO.Add(order);
            }
        }
    }

    if (to != OnlyPending)
    {
        total = PositionsTotal();
        for (int i = total - 1; i >= 0; i--)
        {
            if (!COrderIterator::hedging)
            {
                if (!PositionSelect(PositionGetSymbol(i))) continue;
            }
            else
            {
                if (PositionGetSymbol(i) != cp) continue;
            }
            if (PositionGetString(POSITION_SYMBOL) != cp) continue;
            ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            double sl = PositionGetDouble(POSITION_SL);
            double tp = PositionGetDouble(POSITION_TP);

            if (CalculateSwaps) swap += PositionGetDouble(POSITION_SWAP);
            double volume = PositionGetDouble(POSITION_VOLUME);
            commission += CommissionPerLot * volume;
            if (pt == POSITION_TYPE_BUY)
            {
                if (!COrderIterator::hedging) OrderIterator.Status = new CStatusObject(PositionGetDouble(POSITION_PRICE_OPEN), volume, Buy, sl, tp);
                else
                {
                    order = new CStatusObject(PositionGetInteger(POSITION_TICKET), PositionGetDouble(POSITION_PRICE_OPEN), volume, Buy, sl, tp);
                    OrderIterator.StatusHedging.Add(order);
                }
                if (sl)
                {
                    if (COrderIterator::hedging) order = new CRemainingOrderObject(0, sl, volume, Sell, 0, 0, SLTP, PositionGetInteger(POSITION_TICKET), 0);
                    else order = new CRemainingOrderObject(0, sl, 0, 0, 0, 0, SLTP, 0, 0);
                    OrderIterator.RO.Add(order);
                }
                if (tp)
                {
                    if (COrderIterator::hedging) order = new CRemainingOrderObject(0, tp, volume, Sell, 0, 0, SLTP, PositionGetInteger(POSITION_TICKET), 0);
                    else order = new CRemainingOrderObject(0, tp, 0, 0, 0, 0, SLTP, 0, 0);
                    OrderIterator.RO.Add(order);
                }
            }
            else if (pt == POSITION_TYPE_SELL)
            {
                if (!COrderIterator::hedging) OrderIterator.Status = new CStatusObject(PositionGetDouble(POSITION_PRICE_OPEN), volume, Sell, sl == 0 ? 0 : sl - spread, tp == 0 ? 0 : tp - spread);
                else
                {
                    order = new CStatusObject(PositionGetInteger(POSITION_TICKET), PositionGetDouble(POSITION_PRICE_OPEN), volume, Sell, sl == 0 ? 0 : sl - spread, tp == 0 ? 0 : tp - spread);
                    OrderIterator.StatusHedging.Add(order);
                }
                if (sl)
                {
                    if (COrderIterator::hedging) order = new CRemainingOrderObject(0, sl == 0 ? 0 : sl - spread, volume, Sell, 0, 0, SLTP, PositionGetInteger(POSITION_TICKET), 0);
                    else order = new CRemainingOrderObject(0, sl == 0 ? 0 : sl - spread, 0, 0, 0, 0, SLTP, 0, 0);
                    OrderIterator.RO.Add(order);
                }
                if (tp)
                {
                    if (COrderIterator::hedging) order = new CRemainingOrderObject(0, tp == 0 ? 0 : tp - spread, volume, Sell, 0, 0, SLTP, PositionGetInteger(POSITION_TICKET), 0);
                    else order = new CRemainingOrderObject(0, tp == 0 ? 0 : tp - spread, 0, 0, 0, 0, SLTP, 0, 0);
                    OrderIterator.RO.Add(order);
                }
            }

            if (!COrderIterator::hedging) break; // Only one position per currency pair possible in netting mode.
        }
    }

    OrderIterator.current_price = SymbolInfoDouble(cp, SYMBOL_BID);

    OrderIterator.Iterate(UNDEFINED);

    delete OrderIterator;

    MoneyRisk = Output(cp, mode, to);

    return MoneyRisk;
}

//+------------------------------------------------------------------+
//| Creates output for one currency pair via a graphical object.     |
//| Returns: risk in account currency.                               |
//+------------------------------------------------------------------+
double Output(const string cp, const mode_of_operation mode, target_orders to = All)
{
    string RiskOutput = "", SecondRiskOutput = "";
    double MoneyRisk = 0;
    if (COrderIterator::min_profit == UNDEFINED) RiskOutput = JustifyRight("Undefined", 25);
    else if (COrderIterator::min_profit == UNLIMITED) RiskOutput = JustifyRight("Unlimited", 25) +  " (" + DoubleToString(MathAbs(COrderIterator::max_sell_volume), 2) + " lot)";
    else
    {
        double UnitCost = CalculateUnitCost(cp, mode);
        double OnePoint = SymbolInfoDouble(cp, SYMBOL_POINT);
        MoneyRisk = -COrderIterator::min_profit * UnitCost / OnePoint - commission;
        if (mode == Reward) MoneyRisk = -MoneyRisk;
        if (CalculateSwaps) MoneyRisk -= swap;
        double Size;
        if (UseEquityInsteadOfBalance) Size = AccountInfoDouble(ACCOUNT_EQUITY);
        else Size = AccountInfoDouble(ACCOUNT_BALANCE);
        double PercentageRisk = (MoneyRisk / Size) * 100;
        RiskOutput = JustifyRight(FormatNumber(DoubleToString(MoneyRisk, 2)) + " " + AccCurrency, 25);
        SecondRiskOutput = JustifyRight(DoubleToString(PercentageRisk, 2) + "%", 25);
    }


    int N = 0; // Offset multiplier.
    uint w, h;
    TextSetFont(FontFace, FontSize * -10);
    TextGetSize("A", w, h);
    h++;

    if (mode == Risk) // No need to repeat the currency pair name when processing Reward.
    {
        ObjectCreate(0, cp, OBJ_LABEL, Window, 0, 0);
        ObjectSetString(0, cp, OBJPROP_TEXT, cp);
        ObjectSetString(0, cp, OBJPROP_FONT, FontFace);
        ObjectSetInteger(0, cp, OBJPROP_FONTSIZE, FontSize);
        ObjectSetInteger(0, cp, OBJPROP_COLOR, cpFontColor);
        ObjectSetInteger(0, cp, OBJPROP_CORNER, 0);
        ObjectSetInteger(0, cp, OBJPROP_XDISTANCE, offsetX + N * w);
        ObjectSetInteger(0, cp, OBJPROP_YDISTANCE, Y * h + offsetY + 1);
    }

    if (mode == Risk) N = 0;
    else
    {
        N = 30;
    }
    if (to == OnlyPending)
    {
        if (mode == Risk) N = 60;
        else
        {
            N = 90;
        }
        if (!CalculateReward) N -= 30;
    }

    string obj_name = cp + EnumToString(mode) + "Amount" + EnumToString(to);
    ObjectCreate(0, obj_name, OBJ_LABEL, Window, 0, 0);
    ObjectSetString(0, obj_name, OBJPROP_TEXT, RiskOutput);
    ObjectSetString(0, obj_name, OBJPROP_FONT, FontFace);
    ObjectSetInteger(0, obj_name, OBJPROP_FONTSIZE, FontSize);
    ObjectSetInteger(0, obj_name, OBJPROP_COLOR, mnFontColor);
    ObjectSetInteger(0, obj_name, OBJPROP_CORNER, 0);
    ObjectSetInteger(0, obj_name, OBJPROP_XDISTANCE, offsetX + (N + 1) * w);
    ObjectSetInteger(0, obj_name, OBJPROP_YDISTANCE, Y * h + offsetY + 1);

    if (SecondRiskOutput != "")
    {
        obj_name = cp + EnumToString(mode) + "Percentage" + EnumToString(to);
        ObjectCreate(0, obj_name, OBJ_LABEL, Window, 0, 0);
        ObjectSetString(0, obj_name, OBJPROP_TEXT, SecondRiskOutput);
        ObjectSetString(0, obj_name, OBJPROP_FONT, FontFace);
        ObjectSetInteger(0, obj_name, OBJPROP_FONTSIZE, FontSize);
        ObjectSetInteger(0, obj_name, OBJPROP_COLOR, pcFontColor);
        ObjectSetInteger(0, obj_name, OBJPROP_CORNER, 0);
        ObjectSetInteger(0, obj_name, OBJPROP_XDISTANCE, offsetX + (N + 10) * w);
        ObjectSetInteger(0, obj_name, OBJPROP_YDISTANCE, Y * h + offsetY + 1);
    }

    if ((COrderIterator::min_profit != UNLIMITED) && (COrderIterator::min_profit != UNDEFINED)) return MoneyRisk;
    else return COrderIterator::min_profit;
}

//+------------------------------------------------------------------+
//| Creates output for combined risk for all currency pairs.         |
//| Inputs: risk - risk in account currency.                         |
//+------------------------------------------------------------------+
void OutputTotalRisk(const double risk, const mode_of_operation mode, target_orders to = All)
{
    string RiskOutput = "", SecondRiskOutput = "";;
    if (risk == 0)
    {
        if (mode == Risk) RiskOutput = JustifyRight("No risk.", 25);
        else RiskOutput = JustifyRight("No reward.", 25);
    }
    else if (risk == UNDEFINED) RiskOutput = JustifyRight("Undefined", 25);
    else if (risk == UNLIMITED) RiskOutput = JustifyRight("Unlimited", 25);
    else
    {
        double Size;
        if (UseEquityInsteadOfBalance) Size = AccountInfoDouble(ACCOUNT_EQUITY);
        else Size = AccountInfoDouble(ACCOUNT_BALANCE);
        double PercentageRisk = (risk / Size) * 100;
        RiskOutput = JustifyRight(FormatNumber(DoubleToString(risk, 2)) + " " + AccCurrency, 25);
        SecondRiskOutput = JustifyRight(DoubleToString(PercentageRisk, 2) + "%", 25);
    }

    int N; // Offset multiplier.
    if (mode == Risk) N = 0;
    else
    {
        N = 30;
    }
    if (to == OnlyPending)
    {
        if (mode == Risk) N = 60;
        else
        {
            N = 90;
        }
        if (!CalculateReward) N -= 30;
    }

    uint w, h;
    TextSetFont(FontFace, FontSize * -10);
    TextGetSize("A", w, h);
    h++;

    if ((mode == Risk) && (to != OnlyPending)) // No need to repeat the currency pair name when processing Reward or got to Pending orders in Separate mode.
    {
        ObjectCreate(0, "Total", OBJ_LABEL, Window, 0, 0);
        ObjectSetString(0, "Total", OBJPROP_TEXT, "Total");
        ObjectSetString(0, "Total", OBJPROP_FONT, FontFace);
        ObjectSetInteger(0, "Total", OBJPROP_FONTSIZE, FontSize);
        ObjectSetInteger(0, "Total", OBJPROP_COLOR, cpFontColor);
        ObjectSetInteger(0, "Total", OBJPROP_CORNER, 0);
        ObjectSetInteger(0, "Total", OBJPROP_XDISTANCE, offsetX + N * w);
        ObjectSetInteger(0, "Total", OBJPROP_YDISTANCE, Y * h + offsetY + 1);
    }
    string obj_name = "TotalAmount" + EnumToString(mode) + EnumToString(to);
    ObjectCreate(0, obj_name, OBJ_LABEL, Window, 0, 0);
    ObjectSetString(0, obj_name, OBJPROP_TEXT, RiskOutput);
    ObjectSetString(0, obj_name, OBJPROP_FONT, FontFace);
    ObjectSetInteger(0, obj_name, OBJPROP_FONTSIZE, FontSize);
    ObjectSetInteger(0, obj_name, OBJPROP_COLOR, mnFontColor);
    ObjectSetInteger(0, obj_name, OBJPROP_CORNER, 0);
    ObjectSetInteger(0, obj_name, OBJPROP_XDISTANCE, offsetX + (N + 1) * w);
    ObjectSetInteger(0, obj_name, OBJPROP_YDISTANCE, Y * h + offsetY + 1);

    if ((SecondRiskOutput != "") && (risk != 0))
    {
        obj_name = "TotalPercentage" + EnumToString(mode) + EnumToString(to);
        ObjectCreate(0, obj_name, OBJ_LABEL, Window, 0, 0);
        ObjectSetString(0, obj_name, OBJPROP_TEXT, SecondRiskOutput);
        ObjectSetString(0, obj_name, OBJPROP_FONT, FontFace);
        ObjectSetInteger(0, obj_name, OBJPROP_FONTSIZE, FontSize);
        ObjectSetInteger(0, obj_name, OBJPROP_COLOR, pcFontColor);
        ObjectSetInteger(0, obj_name, OBJPROP_CORNER, 0);
        ObjectSetInteger(0, obj_name, OBJPROP_XDISTANCE, offsetX + (N + 10) * w);
        ObjectSetInteger(0, obj_name, OBJPROP_YDISTANCE, Y * h + offsetY + 1);
    }
}

//+----------------------------------------------------------------------+
//| Returns a number formatted as money string.                          |
//+----------------------------------------------------------------------+
string FormatNumber(const string number)
{
    string output = "";
    int length = StringLen(number);
    int j = 0;
    // Start from first digit from right starting from the decimal separator. E.g. from '4' in '1234.56'.
    for (int i = length - 4; i >= 0; i--)
    {
        if ((j % 3 == 0) && (j != 0)) output = "," + output;
        output = StringSubstr(number, i, 1) + output;
        j++;
    }
    return(output + StringSubstr(number, length - 3, 3));
}

//+----------------------------------------------------------------------+
//| Returns a string with enough spaces added from the left side to make |
//| it a width length string.                                            |
//+----------------------------------------------------------------------+
string JustifyRight(string text, const int width)
{
    int length = StringLen(text);
    // Cannot do anything - string too long.
    if (length >= width) return text;

    int j = 0;
    // Start from first digit from right starting from the decimal separator. E.g. from '4' in '1234.56'.
    for (int i = width - length; i >= 0; i--)
        text = " " + text;

    return text;
}

//+----------------------------------------------------------------------+
//| Returns unit cost either for Risk or for Reward mode.                |
//+----------------------------------------------------------------------+
double CalculateUnitCost(const string cp, const mode_of_operation mode)
{
    ENUM_SYMBOL_CALC_MODE CalcMode = (ENUM_SYMBOL_CALC_MODE)SymbolInfoInteger(cp, SYMBOL_TRADE_CALC_MODE);

    // No-Forex.
    if ((CalcMode != SYMBOL_CALC_MODE_FOREX) && (CalcMode != SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE) && (CalcMode != SYMBOL_CALC_MODE_FUTURES) && (CalcMode != SYMBOL_CALC_MODE_EXCH_FUTURES) && (CalcMode != SYMBOL_CALC_MODE_EXCH_FUTURES_FORTS))
    {
        double TickSize = SymbolInfoDouble(cp, SYMBOL_TRADE_TICK_SIZE);
        double UnitCost = TickSize * SymbolInfoDouble(cp, SYMBOL_TRADE_CONTRACT_SIZE);
        string ProfitCurrency = SymbolInfoString(cp, SYMBOL_CURRENCY_PROFIT);
        if (ProfitCurrency == "RUR") ProfitCurrency = "RUB";

        // If profit currency is different from account currency.
        if (ProfitCurrency != AccCurrency)
        {
            return(UnitCost * CalculateAdjustment(ProfitCurrency, mode));
        }
        return UnitCost;
    }
    // With Forex instruments, tick value already equals 1 unit cost.
    else
    {
        if (mode == Risk) return SymbolInfoDouble(cp, SYMBOL_TRADE_TICK_VALUE_LOSS);
        else return SymbolInfoDouble(cp, SYMBOL_TRADE_TICK_VALUE_PROFIT);
    }
}

//+-----------------------------------------------------------------------------------+
//| Calculates necessary adjustments for cases when GivenCurrency != AccountCurrency. |
//| Used in two cases: profit adjustment and margin adjustment.                       |
//+-----------------------------------------------------------------------------------+
double CalculateAdjustment(const string ProfitCurrency, const mode_of_operation mode)
{
    string ReferenceSymbol = GetSymbolByCurrencies(ProfitCurrency, AccCurrency);
    bool ReferenceSymbolMode = true;
    // Failed.
    if (ReferenceSymbol == NULL)
    {
        // Reversing currencies.
        ReferenceSymbol = GetSymbolByCurrencies(AccCurrency, ProfitCurrency);
        ReferenceSymbolMode = false;
    }
    // Everything failed.
    if (ReferenceSymbol == NULL)
    {
        Print("Error! Cannot detect proper currency pair for adjustment calculation: ", ProfitCurrency, ", ", AccCurrency, ".");
        ReferenceSymbol = Symbol();
        return 1;
    }
    MqlTick tick;
    SymbolInfoTick(ReferenceSymbol, tick);
    return GetCurrencyCorrectionCoefficient(tick, mode, ReferenceSymbolMode);
}

//+---------------------------------------------------------------------------+
//| Returns a currency pair with specified base currency and profit currency. |
//+---------------------------------------------------------------------------+
string GetSymbolByCurrencies(string base_currency, string profit_currency)
{
    // Cycle through all symbols.
    for (int s = 0; s < SymbolsTotal(false); s++)
    {
        // Get symbol name by number.
        string symbolname = SymbolName(s, false);

        // Skip non-Forex pairs.
        if ((SymbolInfoInteger(symbolname, SYMBOL_TRADE_CALC_MODE) != SYMBOL_CALC_MODE_FOREX) && (SymbolInfoInteger(symbolname, SYMBOL_TRADE_CALC_MODE) != SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE)) continue;

        // Get its base currency.
        string b_cur = SymbolInfoString(symbolname, SYMBOL_CURRENCY_BASE);
        if (b_cur == "RUR") b_cur = "RUB";

        // Get its profit currency.
        string p_cur = SymbolInfoString(symbolname, SYMBOL_CURRENCY_PROFIT);
        if (p_cur == "RUR") p_cur = "RUB";
        
        // If the currency pair matches both currencies, select it in Market Watch and return its name.
        if ((b_cur == base_currency) && (p_cur == profit_currency))
        {
            // Select if necessary.
            if (!(bool)SymbolInfoInteger(symbolname, SYMBOL_SELECT)) SymbolSelect(symbolname, true);

            return symbolname;
        }
    }
    return NULL;
}

//+------------------------------------------------------------------+
//| Get profit correction coefficient based on profit currency,      |
//| calculation mode (profit or loss), reference pair mode (reverse  |
//| or direct), and current prices.                                  |
//+------------------------------------------------------------------+
double GetCurrencyCorrectionCoefficient(MqlTick &tick, const mode_of_operation mode, const bool ReferenceSymbolMode)
{
    if ((tick.ask == 0) || (tick.bid == 0)) return -1; // Data is not yet ready.
    if (mode == Risk)
    {
        // Reverse quote.
        if (ReferenceSymbolMode)
        {
            // Using Buy price for reverse quote.
            return tick.ask;
        }
        // Direct quote.
        else
        {
            // Using Sell price for direct quote.
            return(1 / tick.bid);
        }
    }
    else if (mode == Reward)
    {
        // Reverse quote.
        if (ReferenceSymbolMode)
        {
            // Using Sell price for reverse quote.
            return tick.bid;
        }
        // Direct quote.
        else
        {
            // Using Buy price for direct quote.
            return(1 / tick.ask);
        }
    }
    return -1;
}
//+------------------------------------------------------------------+
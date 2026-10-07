-- TESLES DEALER - drug sales at the doctors (server-side, UE4SS).
--
-- Drop cannabis buds, joints or psychedelic mushrooms on a doctor trader's
-- counter. After a few seconds they disappear and SCUM cash for them
-- appears in their place. Nothing to type.
return {
    -- false: the mod does nothing.
    DrugSales = true,

    -- Prices (SCUM money). A bud is priced whole (6/6 uses): a 3/6 bud
    -- fetches half. Joints and mushrooms are priced per piece: a stack of
    -- five joints fetches five times the price.
    DrugPriceBud = 120,
    DrugPriceJoint = 50,
    DrugPriceMushroom = 80,

    -- How the doctor pays: "cash" (a bundle of SCUM cash on the counter),
    -- "bank" (to the account of the player standing at the counter, with
    -- SCUM's own admin command) or "auto" (cash if this server lets the mod
    -- set a bundle's amount, otherwise the bank).
    DrugPayment = "auto",
    -- The admin command for bank payments ({amount}, {player} = name).
    DrugBankCommand = "#ChangeCurrencyBalance Normal {amount} {player}",

    -- Items in at least this condition (0.9 = 90 %) fetch the full price;
    -- below it the price is the condition share (a 50 % bud: half).
    DrugFullPriceCondition = 0.9,

    -- Which traders buy: any trader whose name contains one of these words
    -- (dealer.log in this folder lists every trader the mod found, with its name).
    DrugTraders = { "doctor", "hospital", "medic", "physician" },

    -- How close to the trader (metres) the goods must lie: the counter in
    -- front of the doctor is within it.
    DrugSaleRadiusM = 2.5,

    -- Seconds the goods must lie still before the doctor takes them.
    DrugSettleSec = 3,

    -- How often the counters are looked at (seconds).
    DrugScanSec = 2,
}

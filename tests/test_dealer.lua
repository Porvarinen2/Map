-- TeslesDealer: prices and the counter rules (dealer/TeslesDealer/Scripts/dealer.lua).
package.path = "../dealer/TeslesDealer/Scripts/?.lua;" .. package.path
local Dl = require("dealer")

local fails = 0
local function check(cond, msg)
    if cond then print("  ok  " .. msg) else print("FAIL: " .. msg); fails = fails + 1 end
end

print("== prices ==")
local cfg = { DrugPriceBud = 120, DrugPriceJoint = 50, DrugPriceMushroom = 80, DrugFullPriceCondition = 0.9 }
check(Dl.price(cfg, Dl.GOODS.cannabis_bud, 6, 1.0) == 120, "a full bud (6/6) in good condition: 120")
check(Dl.price(cfg, Dl.GOODS.cannabis_bud, 1, 0.95) == 20, "one use of a bud: 20")
check(Dl.price(cfg, Dl.GOODS.cannabis_bud, 6, 0.5) == 60, "a bud at 50 %: half")
check(Dl.price(cfg, Dl.GOODS.joint01, 5, 1.0) == 250, "a stack of five joints: five times the price")
check(Dl.price(cfg, Dl.GOODS.psilocybe_cyanescens, nil, 0.92) == 80, "a mushroom above 90 %: full price")

print("== the counter ==")
local cash, destroyed = {}, {}
local items = {}
local bridge = {
    dealer_zones = function() return { { pos = { X = 0, Y = 0, Z = 0 }, name = "Doctor" } } end,
    dealer_items = function() return items end,
    spawn_cash = function(pos, amount) cash[#cash + 1] = amount; return true end,
    destroy_item = function(a) destroyed[#destroyed + 1] = a; return true end,
}
local st = Dl.new()
items = { { key = "bud1", actor = "bud1", good = "cannabis_bud", pos = { X = 10, Y = 0, Z = 0 }, zone = 1, qty = 6, health = 1 },
          { key = "j1", actor = "j1", good = "joint01", pos = { X = 20, Y = 0, Z = 0 }, zone = 1, qty = 5, health = 1 } }
Dl.tick(st, bridge, cfg, 100)
check(#cash == 0, "nothing is bought the moment it lands")
Dl.tick(st, bridge, cfg, 104)
check(#cash == 1 and cash[1] == 370 and #destroyed == 2, "after a few seconds: one cash pile for all of it (370)")
local st2 = Dl.new()
bridge.spawn_cash = function() return false, "test" end
destroyed = {}
Dl.tick(st2, bridge, cfg, 200); Dl.tick(st2, bridge, cfg, 204)
check(#destroyed == 0 and st2.off, "if the cash cannot be paid the goods stay and sales stop")

if fails > 0 then os.exit(1) end
print("dealer tests passed")

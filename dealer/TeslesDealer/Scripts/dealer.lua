-- Drug sales at the doctors. SCUM's traders refuse cannabis and mushrooms
-- (they are blocked from trade, EconomyOverride.json cannot add them), so
-- the mod buys them itself: whatever is dropped on a doctor's counter lies
-- there a few seconds, disappears, and the money for it appears in its
-- place as SCUM cash. No commands.
--
-- Price: the item's full price (config) x the share of it left (a bud is
-- 6/6 uses; joints and mushrooms are counted per piece, a stack of five is
-- five) x its condition (full price from DrugFullPriceCondition up, below
-- that the condition share: a 50 % bud fetches half).
local Dl = {}

-- What the doctors buy: SCUM spawn name -> config key of its price and how
-- its quantity counts. per_piece: the price is for one; uses: the price is
-- for this many uses (the whole item).
Dl.GOODS = {
    cannabis_bud = { name = "Cannabis_Bud", price_key = "DrugPriceBud", default = 120, uses = 6 },
    joint01 = { name = "Joint01", price_key = "DrugPriceJoint", default = 50, per_piece = true },
    psilocybe_cyanescens = { name = "Psilocybe_Cyanescens", price_key = "DrugPriceMushroom", default = 80, per_piece = true },
}

function Dl.price(cfg, good, qty, health)
    cfg = cfg or {}
    local base = tonumber(cfg[good.price_key]) or good.default
    local amount
    if good.per_piece then
        amount = base * math.max(1, qty or 1)
    else
        local uses = good.uses or 1
        amount = base * math.min(uses, math.max(0, qty or uses)) / uses
    end
    local full = tonumber(cfg.DrugFullPriceCondition) or 0.9
    local h = math.max(0, math.min(1, tonumber(health) or 1))
    if h < full then amount = amount * h end
    return math.floor(amount + 0.5)
end

function Dl.new()
    return { seen = {}, next_at = 0, off = false, sales = 0 }
end

-- One look at the counters. bridge: dealer_zones(now), dealer_items(goods,
-- zones, radius_uu, height_uu), spawn_cash(pos, amount) -> ok, why,
-- destroy_item(actor) -> ok. Returns the sales made this time.
function Dl.tick(st, bridge, cfg, now, log)
    cfg = cfg or {}
    if cfg.DrugSales == false or st.off then return {} end
    if now < st.next_at then return {} end
    st.next_at = now + (tonumber(cfg.DrugScanSec) or 2)
    if not (bridge.dealer_zones and bridge.dealer_items and bridge.spawn_cash and bridge.destroy_item) then
        return {}
    end
    local zones = bridge.dealer_zones(now) or {}
    if #zones == 0 then return {} end
    local radius = (tonumber(cfg.DrugSaleRadiusM) or 2.5) * 100
    local items = bridge.dealer_items(Dl.GOODS, zones, radius, 180) or {}
    local settle = tonumber(cfg.DrugSettleSec) or 3

    -- An item is bought once it has lain still on the counter a moment
    -- (not while it is being dragged about).
    local seen, by_zone = {}, {}
    for _, it in ipairs(items) do
        local prev = st.seen[it.key]
        local first = prev and prev.at or now
        if prev and prev.pos and it.pos then
            local dx, dy = it.pos.X - prev.pos.X, it.pos.Y - prev.pos.Y
            if dx * dx + dy * dy > 400 then first = now end
        end
        seen[it.key] = { at = first, pos = it.pos }
        if now - first >= settle then
            by_zone[it.zone] = by_zone[it.zone] or {}
            table.insert(by_zone[it.zone], it)
        end
    end
    st.seen = seen

    local sales = {}
    for zi, list in pairs(by_zone) do
        local total, parts = 0, {}
        local cx, cy, cz = 0, 0, 0
        for _, it in ipairs(list) do
            local good = Dl.GOODS[it.good]
            it.amount = Dl.price(cfg, good, it.qty, it.health)
            total = total + it.amount
            cx, cy, cz = cx + it.pos.X, cy + it.pos.Y, cz + it.pos.Z
        end
        if total > 0 then
            local spot = { X = cx / #list, Y = cy / #list, Z = cz / #list }
            -- The money first: if SCUM's cash cannot be given its amount the
            -- goods stay where they are and sales stop for the session.
            local ok, why = bridge.spawn_cash(spot, total)
            if not ok then
                st.off = true
                if log then log("drug sales off: cash could not be paid (" .. tostring(why) .. ")") end
                return sales
            end
            local paid = 0
            for _, it in ipairs(list) do
                if bridge.destroy_item(it.actor) then
                    paid = paid + it.amount
                    parts[#parts + 1] = string.format("%s x%s %d%% = %d", it.good, tostring(it.qty or 1),
                        math.floor((it.health or 1) * 100 + 0.5), it.amount)
                    st.seen[it.key] = nil
                end
            end
            st.sales = st.sales + 1
            local sale = { zone = zones[zi] and zones[zi].name or tostring(zi), total = total, paid = paid, parts = parts }
            sales[#sales + 1] = sale
            if log then
                log(string.format("drug sale at %s: %d (%s)", sale.zone, total, table.concat(parts, ", ")))
            end
        end
    end
    return sales
end

return Dl

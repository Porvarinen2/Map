-- Squad weapons: SCUM spawn names per squad class. varusteet.lua overrides
-- any of these (its own Weapons list for a class, or KAIKKI for all). A member
-- gets one weapon at random from the list, among those the server has.
--   Weapons   - the weapons
--   Lipas     - put a magazine with some rounds in the weapon (default on)
--   Tahtaimet - scopes for bolt-action and sniper rifles
--   TahtainOsuus - share of those rifles that get a scope (0..1)
local W = {}

local MILITARY = { "Weapon_AK47", "Weapon_AK15", "Weapon_M16A4", "Weapon_AS_Val",
                   "Weapon_SVD_Dragunov", "Weapon_UMP45" }
local SCOPES = { "WeaponScope_Hunter85", "WeaponScope_PU", "WeaponScope_PSO1",
                 "WeaponScope_Kar98k", "WeaponScope_Spektral_DR" }

W.DEFAULTS = {
    police_patrol  = { Weapons = { "Weapon_MP5", "Weapon_M1911", "Weapon_Block21" } },
    military_group = { Weapons = MILITARY, Tahtaimet = SCOPES, TahtainOsuus = 0.35 },
    elite_unit     = { Weapons = MILITARY, Tahtaimet = SCOPES, TahtainOsuus = 0.5 },
    hunters        = { Weapons = { "Weapon_Hunter85", "Weapon_Hunter85_V2", "Weapon_Carbon_Hunter" },
                       Tahtaimet = SCOPES, TahtainOsuus = 0.4 },
}

-- Rifles that may carry a scope (lower-case spawn names).
W.SCOPED = {
    weapon_hunter85 = true, weapon_hunter85_v2 = true, weapon_carbon_hunter = true,
    weapon_98k_karabiner = true, weapon_svd_dragunov = true, weapon_m82a1 = true,
    weapon_mosin_nagant = true, weapon_vss_vintorez = true,
}

-- The magazine that fits a weapon: Weapon_M1911 -> Magazine_M1911.
function W.magazine_for(weapon)
    local base = tostring(weapon):gsub("^[Ww]eapon_", "")
    return "Magazine_" .. base
end

local function nonempty(t) return type(t) == "table" and #t > 0 end

-- The weapon setup of a squad class: varusteet.lua's own class entry wins,
-- then KAIKKI, then the defaults above.
function W.for_class(class, gear)
    gear = gear or {}
    local own, all, def = gear[class] or {}, gear.KAIKKI or gear.ALL or {}, W.DEFAULTS[class] or {}
    local function pick(key)
        for _, src in ipairs({ own, all, def }) do
            local v = src[key]
            if key == "Weapons" or key == "Tahtaimet" then
                if nonempty(v) then return v end
            elseif v ~= nil then
                return v
            end
        end
        return nil
    end
    return {
        Weapons = pick("Weapons") or {},
        Lipas = pick("Lipas"),
        Tahtaimet = pick("Tahtaimet") or {},
        TahtainOsuus = tonumber(pick("TahtainOsuus")) or 0,
    }
end

return W

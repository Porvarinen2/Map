-- The 38 personality traits from the NPC guide. Values are 0..1.
-- `effect` records where a trait actually feeds into a decision, so the live
-- map can be honest about which traits are wired up and which are background
-- colour. It is documentation the code keeps in sync, not a switch.
local T = {}

T.list = {
    { key = "aggression",        fi = "Aggressiivisuus",        effect = "attack" },
    { key = "courage",           fi = "Rohkeus",                effect = "attack,flank,stress" },
    { key = "fearfulness",       fi = "Pelokkuus",              effect = "retreat,flee,stress" },
    { key = "discipline",        fi = "Kuri",                   effect = "cover,flank,orders,leader" },
    { key = "patience",          fi = "Karsivallisyys",         effect = "profile" },
    { key = "impulsiveness",     fi = "Impulsiivisuus",         effect = "profile" },
    { key = "curiosity",         fi = "Uteliaisuus",            effect = "investigate" },
    { key = "paranoia",          fi = "Vainoharhaisuus",        effect = "trauma" },
    { key = "awareness",         fi = "Tarkkaavaisuus",         effect = "investigate" },
    { key = "cautiousness",      fi = "Varovaisuus",            effect = "cover,investigate" },
    { key = "sociability",       fi = "Sosiaalisuus",           effect = "relations" },
    { key = "loyalty",           fi = "Uskollisuus",            effect = "help,leader,relations" },
    { key = "empathy",           fi = "Empatia",                effect = "help" },
    { key = "selfishness",       fi = "Itsekkyys",              effect = "profile" },
    { key = "leadership",        fi = "Johtajuustaipumus",      effect = "leader,morale" },
    { key = "obedience",         fi = "Tottelevaisuus",         effect = "orders" },
    { key = "independence",      fi = "Itsenaisyys",            effect = "profile" },
    { key = "greed",             fi = "Ahneus",                 effect = "archetype,loot" },
    { key = "resourcefulness",   fi = "Kekseliaisyys",          effect = "profile" },
    { key = "riskTolerance",     fi = "Riskinsieto",            effect = "profile" },
    { key = "persistence",       fi = "Sinnikkyys",             effect = "profile" },
    { key = "vindictiveness",    fi = "Kostonhalu",             effect = "profile" },
    { key = "mercy",             fi = "Armollisuus",            effect = "archetype" },
    { key = "territoriality",    fi = "Reviiritietoisuus",      effect = "home" },
    { key = "protectiveness",    fi = "Suojelunhalu",           effect = "help" },
    { key = "combatConfidence",  fi = "Taisteluvarmuus",        effect = "attack" },
    { key = "weaponConfidence",  fi = "Asevarmuus",             effect = "profile" },
    { key = "stealthPreference", fi = "Hiiviskelymieltymys",    effect = "profile" },
    { key = "explorationDrive",  fi = "Tutkimishalu",           effect = "destination" },
    { key = "homeAttachment",    fi = "Kotipaikkasidonnaisuus", effect = "home" },
    { key = "survivalInstinct",  fi = "Selviytymisvietti",      effect = "retreat" },
    { key = "stressResistance",  fi = "Stressinsieto",          effect = "stress,trauma" },
    { key = "decisionConfidence",fi = "Paatosvarmuus",          effect = "leader" },
    { key = "adaptability",      fi = "Sopeutumiskyky",         effect = "profile" },
    { key = "painTolerance",     fi = "Kivunsieto",             effect = "profile" },
    { key = "teamwork",          fi = "Yhteistyokyky",          effect = "relations" },
    { key = "recklessness",      fi = "Uhkarohkeus",            effect = "profile" },
    { key = "composure",         fi = "Maltti",                 effect = "stress,morale" },
}

T.keys = {}
T.index = {}
for i, t in ipairs(T.list) do
    T.keys[i] = t.key
    T.index[t.key] = t
end

T.count = #T.list

return T

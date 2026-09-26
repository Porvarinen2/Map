-- Language of everything the mod shows (live map, command replies, log
-- lines meant for people). config.lua: Language = "en" (default) or "fi".
-- The game logic keeps its Finnish names; they are translated here, on the
-- way out.
local L = { lang = "en" }

L.EN = {
    -- squad classes
    ["Säteilyryhmä"] = "Radiation squad", ["Saaren asukkaat"] = "Islanders",
    ["Metsästäjät"] = "Hunters", ["Kaksikko"] = "Pair", ["Miliisisolu"] = "Militia cell",
    ["Rosvojoukko"] = "Bandit gang", ["Sotilastaustainen ryhmä"] = "Military squad",
    ["Keräilijät"] = "Scavengers", ["Selviytyjäryhmä"] = "Survivor group",
    ["Eliittiyksikkö"] = "Elite unit", ["Bunkkeriryhmä"] = "Bunker squad",
    ["Poliisipartio"] = "Police patrol", ["Yksinäinen kulkija"] = "Lone wanderer",
    -- archetypes
    ["Siviili"] = "Civilian", ["Keräilijä"] = "Scavenger", ["Selviytyjä"] = "Survivor",
    ["Metsästäjä"] = "Hunter", ["Rosvo"] = "Bandit", ["Poliisi"] = "Police officer",
    ["Vartija"] = "Guard", ["Miliisi"] = "Militiaman", ["Entinen sotilas"] = "Ex-soldier",
    ["Veteraani"] = "Veteran", ["Säteilyalueen erikoisosaaja"] = "Radiation specialist",
    ["Bunkkeriasiantuntija"] = "Bunker specialist", ["Eliittitaistelija"] = "Elite fighter",
    -- activities
    ["Odottaa"] = "Waiting", ["Matkalla"] = "Travelling", ["Tutkii rakennuksia"] = "Searching buildings",
    ["Metsastaa"] = "Hunting", ["Leiriytyy"] = "Camping", ["Partioi"] = "Patrolling",
    ["Lepaa"] = "Resting", ["Vartioi aluetta"] = "Guarding the area", ["Taistelee"] = "Fighting",
    ["Vetaytyy"] = "Retreating",
    -- moods
    ["Rauhallinen"] = "Calm", ["Valpas"] = "Alert", ["Jännittynyt"] = "Tense",
    ["Järkyttynyt"] = "Shaken", ["Paniikissa"] = "Panicking", ["Hajoaa pakoon"] = "Routing",
    ["Torjuu zombeja"] = "Fighting off zombies", ["Tutkii ammuskelua"] = "Investigating gunfire",
    ["Suojautuu tulelta"] = "Taking cover", ["Shokissa"] = "In shock",
    ["Väistää ammuskelua"] = "Avoiding gunfire", ["Odottaa hiljaa"] = "Holding still",
    ["Lähestyy pelaajaa"] = "Closing in on a player", ["Lähestyy zombeja"] = "Closing in on zombies",
    ["Jäljittää eläintä"] = "Tracking an animal",
    -- stress
    ["Stressaantunut"] = "Stressed", ["Voimakkaasti stressaantunut"] = "Highly stressed",
    ["Paniikki"] = "Panic",
    -- actions
    ["Hyokkaa"] = "Attack", ["Suojaudu"] = "Take cover", ["Vetaydy"] = "Retreat",
    ["Koukkaa"] = "Flank", ["Tutki"] = "Investigate", ["Auta"] = "Help", ["Pakene"] = "Flee",
    -- standings
    ["Verivihollisuus"] = "Blood feud", ["Vihamielinen"] = "Hostile", ["Epaluuloinen"] = "Suspicious",
    ["Neutraali"] = "Neutral", ["Ystavallinen"] = "Friendly",
    -- traumas
    ["Ylivarovaisuus"] = "Overcaution", ["Menettämisen pelko"] = "Fear of loss",
    ["Vainoharhaisuus"] = "Paranoia", ["Zombitrauma"] = "Zombie trauma",
    ["Taistelun välttely"] = "Combat aversion", ["Kostoreaktio"] = "Vengefulness",
    ["Luottamusvaurio"] = "Trust damage",
    -- zones
    ["Sateilyalue"] = "Radiation zone", ["Saarikaupunki"] = "Island town",
    -- skills
    ["Kivaari"] = "Rifle", ["Pistooli"] = "Pistol", ["Haulikko"] = "Shotgun",
    ["Lahitaistelu"] = "Melee", ["Taktinen liike"] = "Tactical movement",
    ["Suojankaytto"] = "Use of cover", ["Navigointi"] = "Navigation",
    ["Havainnointi"] = "Perception", ["Hiiviskely"] = "Stealth", ["Johtaminen"] = "Leadership",
    ["Ensiapu"] = "First aid", ["Selviytyminen"] = "Survival",
    -- traits
    ["Aggressiivisuus"] = "Aggression", ["Rohkeus"] = "Courage", ["Pelokkuus"] = "Fearfulness",
    ["Kuri"] = "Discipline", ["Karsivallisyys"] = "Patience", ["Impulsiivisuus"] = "Impulsiveness",
    ["Uteliaisuus"] = "Curiosity", ["Tarkkaavaisuus"] = "Awareness", ["Varovaisuus"] = "Cautiousness",
    ["Sosiaalisuus"] = "Sociability", ["Uskollisuus"] = "Loyalty", ["Empatia"] = "Empathy",
    ["Itsekkyys"] = "Selfishness", ["Johtajuustaipumus"] = "Leadership", ["Tottelevaisuus"] = "Obedience",
    ["Itsenaisyys"] = "Independence", ["Ahneus"] = "Greed", ["Kekseliaisyys"] = "Resourcefulness",
    ["Riskinsieto"] = "Risk tolerance", ["Sinnikkyys"] = "Persistence", ["Kostonhalu"] = "Vindictiveness",
    ["Armollisuus"] = "Mercy", ["Reviiritietoisuus"] = "Territoriality", ["Suojelunhalu"] = "Protectiveness",
    ["Taisteluvarmuus"] = "Combat confidence", ["Asevarmuus"] = "Weapon confidence",
    ["Hiiviskelymieltymys"] = "Stealth preference", ["Tutkimishalu"] = "Exploration drive",
    ["Kotipaikkasidonnaisuus"] = "Home attachment", ["Selviytymisvietti"] = "Survival instinct",
    ["Stressinsieto"] = "Stress resistance", ["Paatosvarmuus"] = "Decision confidence",
    ["Sopeutumiskyky"] = "Adaptability", ["Kivunsieto"] = "Pain tolerance",
    ["Yhteistyokyky"] = "Teamwork", ["Uhkarohkeus"] = "Recklessness", ["Maltti"] = "Composure",
    -- stress events
    ["väijytys"] = "ambush", ["vihollinen näkyvissä"] = "enemy in sight",
    ["laukauksia lähellä"] = "shots nearby", ["nälkä"] = "hunger", ["läheltä piti"] = "near miss",
    ["alakynnessä"] = "outnumbered", ["kaukaisia laukauksia"] = "distant shots", ["zombeja"] = "zombies",
    ["zombilauma"] = "zombie horde", ["haavoittui"] = "wounded", ["vakava haava"] = "badly wounded",
    ["toveri kaatui"] = "a comrade fell", ["johtaja kaatui"] = "the leader fell",
    ["johtaja haavoittui"] = "the leader was wounded", ["jano"] = "thirst", ["menetti parinsa"] = "lost a partner",
    -- skill levels
    ["Aloittelija"] = "Beginner", ["Kokematon"] = "Inexperienced", ["Kokenut"] = "Experienced",
    ["Taitava"] = "Skilled", ["Eliitti"] = "Elite",
    -- notes
    ["lepotauko"] = "rest stop", ["kohde"] = "destination",
}

-- Texts that start with a Finnish phrase and go on with a name or number.
L.PREFIX = {
    { "matkalla: ", "travelling to " }, { "kaupunki kayty lapi: ", "town searched: " },
    { "Matkalla: ", "Travelling: " }, { "Tutkii rakennuksia", "Searching buildings" },
    { "Metsastaa", "Hunting" }, { "Leiriytyy", "Camping" }, { "Partioi", "Patrolling" },
    { "Lepaa", "Resting" }, { "Vartioi aluetta", "Guarding the area" }, { "Taistelee", "Fighting" },
    { "Vetaytyy", "Retreating" }, { "Odottaa", "Waiting" },
}

function L.t(s)
    if L.lang == "fi" or type(s) ~= "string" then return s end
    local e = L.EN[s]
    if e then return e end
    for _, p in ipairs(L.PREFIX) do
        if s:sub(1, #p[1]) == p[1] then return p[2] .. s:sub(#p[1] + 1) end
    end
    return s
end

-- One message in both languages.
function L.pick(fi, en)
    if L.lang == "fi" then return fi end
    return en
end

return L

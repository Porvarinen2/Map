-- SmartNPC world points of interest.
-- Coordinates are SCUM world units (cm).
return {
highloot = { points={
  {id="HL_D4_AIRFIELD",label="D4 Military Airfield",sector="D4",x=549496,y=558699,kind="MILITARY",weight=2.2},
  {id="HL_B2_AIRPORT",label="B2 Main Airfield",sector="B2",x=-213012,y=-57004,kind="MILITARY",weight=2.5},
  {id="HL_B3_BOOTCAMP",label="B3 Boot Camp",sector="B3",x=241443,y=-44812,kind="MILITARY",weight=2.2},
  {id="HL_B3_TRAINYARD",label="B3 Train Yard",sector="B3",x=82841,y=-148445,kind="MILITARY",weight=2.0},
  {id="HL_B1_FACTORY",label="B1 Factory",sector="B1",x=-453964,y=-50908,kind="INDUSTRIAL",weight=1.7},
  {id="HL_C2_PRISON",label="C2 Prison",sector="C2",x=-69660,y=156358,kind="MILITARY",weight=1.8},
  {id="HL_D0_BARRACKS",label="D0 Military Barracks",sector="D0",x=-813868,y=528219,kind="MILITARY",weight=1.9},
  {id="HL_A4_NAVAL",label="A4 Naval Base",sector="A4",x=534246,y=-532497,kind="MILITARY",weight=2.4},
  {id="HL_Z1_WEAPONS",label="Z1 Weapons / Torpedo Factory",sector="Z1",x=-447864,y=-715379,kind="MILITARY",weight=2.4},
  {id="HL_C3_RADAR",label="C3 Military Radar & Trenches",sector="C3",x=156042,y=168551,kind="MILITARY",weight=1.8},
  {id="HL_Z0_AIRFIELD",label="Z0 Airfield",sector="Z0",x=-752867,y=-745860,kind="MILITARY",weight=1.7},
  {id="HL_D4_BUNKER",label="D4 Military / Abandoned Bunker",sector="D4",x=467145,y=467258,kind="BUNKER",weight=1.5},
  {id="HL_D3_BUNKER",label="D3 Military / Abandoned Bunker",sector="D3",x=162142,y=467258,kind="BUNKER",weight=1.5},
  {id="HL_D2_BUNKER",label="D2 Military / Abandoned Bunker",sector="D2",x=-142861,y=467258,kind="BUNKER",weight=1.5},
  {id="HL_D1_BUNKER",label="D1 Military / Abandoned Bunker",sector="D1",x=-447864,y=467258,kind="BUNKER",weight=1.5},
  {id="HL_D0_BUNKER",label="D0 Military / Abandoned Bunker",sector="D0",x=-752867,y=467258,kind="BUNKER",weight=1.5},
  {id="HL_C4_BUNKER",label="C4 Military / Abandoned Bunker",sector="C4",x=467145,y=162455,kind="BUNKER",weight=1.5},
  {id="HL_C3_BUNKER",label="C3 Military / Abandoned Bunker",sector="C3",x=162142,y=162455,kind="BUNKER",weight=1.5},
  {id="HL_C2_BUNKER",label="C2 Military / Abandoned Bunker",sector="C2",x=-142861,y=162455,kind="BUNKER",weight=1.5},
  {id="HL_C1_BUNKER",label="C1 Military / Abandoned Bunker",sector="C1",x=-447864,y=162455,kind="BUNKER",weight=1.5},
  {id="HL_B4_BUNKER",label="B4 Military / Abandoned Bunker",sector="B4",x=467145,y=-142349,kind="BUNKER",weight=1.5},
  {id="HL_B3_BUNKER",label="B3 Military / Abandoned Bunker",sector="B3",x=162142,y=-142349,kind="BUNKER",weight=1.5},
  {id="HL_B2_BUNKER",label="B2 Military / Abandoned Bunker",sector="B2",x=-142861,y=-142349,kind="BUNKER",weight=1.5},
  {id="HL_B1_BUNKER",label="B1 Military / Abandoned Bunker",sector="B1",x=-447864,y=-142349,kind="BUNKER",weight=1.5},
  {id="HL_B0_BUNKER",label="B0 Military / Abandoned Bunker",sector="B0",x=-752867,y=-142349,kind="BUNKER",weight=1.5},
  {id="HL_A4_BUNKER",label="A4 Military / Abandoned Bunker",sector="A4",x=467145,y=-447152,kind="BUNKER",weight=1.5},
  {id="HL_A3_BUNKER",label="A3 Military / Abandoned Bunker",sector="A3",x=162142,y=-447152,kind="BUNKER",weight=1.5},
  {id="HL_A2_BUNKER",label="A2 Military / Abandoned Bunker",sector="A2",x=-142861,y=-447152,kind="BUNKER",weight=1.5},
  {id="HL_A1_BUNKER",label="A1 Military / Abandoned Bunker",sector="A1",x=-447864,y=-447152,kind="BUNKER",weight=1.5},
  {id="HL_A0_BUNKER",label="A0 Military / Abandoned Bunker",sector="A0",x=-752867,y=-447152,kind="BUNKER",weight=1.5},
  {id="HL_Z4_BUNKER",label="Z4 Military / Abandoned Bunker",sector="Z4",x=467145,y=-751956,kind="BUNKER",weight=1.5},
  {id="HL_Z3_BUNKER",label="Z3 Military / Abandoned Bunker",sector="Z3",x=162142,y=-751956,kind="BUNKER",weight=1.5},
  {id="HL_Z2_BUNKER",label="Z2 Military / Abandoned Bunker",sector="Z2",x=-142861,y=-751956,kind="BUNKER",weight=1.5},
  {id="HL_Z1_BUNKER",label="Z1 Military / Abandoned Bunker",sector="Z1",x=-447864,y=-751956,kind="BUNKER",weight=1.5},
  {id="HL_Z0_BUNKER",label="Z0 Military / Abandoned Bunker",sector="Z0",x=-752867,y=-751956,kind="BUNKER",weight=1.5},
} } ,
activity = {
  settlements = {
    {
      id="SET_Z1_01", label="Z1 settlement 1", sector="Z1", x=-304899, y=-756200, weight=6,
      stops={
        {x=-310013,y=-750166},
        {x=-274211,y=-744958},
        {x=-287285,y=-759941},
        {x=-337691,y=-747409},
        {x=-290914,y=-730627},
        {x=-333272,y=-769909},
        {x=-306524,y=-767217},
        {x=-321584,y=-730216},
      }
    },
    {
      id="SET_D4_01", label="D4 settlement 1", sector="D4", x=343997, y=341957, weight=6,
      stops={
        {x=322085,y=367308},
        {x=343811,y=335781},
        {x=363346,y=372837},
        {x=336170,y=349983},
        {x=340121,y=374219},
        {x=313851,y=339755},
        {x=361603,y=321523},
        {x=360185,y=346951},
      }
    },
    {
      id="SET_C0_01", label="C0 settlement 1", sector="C0", x=-792874, y=132748, weight=6,
      stops={
        {x=-801865,y=124351},
        {x=-780432,y=161338},
        {x=-825085,y=130104},
        {x=-782238,y=142913},
        {x=-802526,y=145217},
        {x=-811969,y=109358},
        {x=-791143,y=107456},
        {x=-785962,y=126990},
      }
    },
    {
      id="SET_D4_02", label="D4 settlement 2", sector="D4", x=574202, y=336745, weight=4.14,
      stops={
        {x=573040,y=347138},
        {x=540109,y=333146},
        {x=574789,y=331726},
        {x=548313,y=326987},
        {x=583226,y=334698},
        {x=565384,y=330360},
        {x=578147,y=341202},
        {x=569696,y=338358},
      }
    },
    {
      id="SET_Z1_02", label="Z1 settlement 2", sector="Z1", x=-366734, y=-770345, weight=6,
      stops={
        {x=-348011,y=-761198},
        {x=-372466,y=-770932},
        {x=-339519,y=-747587},
        {x=-354312,y=-773292},
        {x=-365244,y=-804262},
        {x=-332889,y=-771034},
        {x=-392770,y=-790147},
        {x=-360335,y=-753912},
      }
    },
    {
      id="SET_C3_01", label="C3 settlement 1", sector="C3", x=235972, y=102223, weight=3.64,
      stops={
        {x=232768,y=109917},
        {x=239170,y=92109},
        {x=227040,y=105430},
        {x=244770,y=104032},
        {x=236617,y=101661},
        {x=230560,y=94104},
        {x=245404,y=96747},
        {x=239957,y=111487},
      }
    },
    {
      id="SET_Z4_01", label="Z4 settlement 1", sector="Z4", x=437122, y=-832884, weight=6,
      stops={
        {x=448076,y=-828068},
        {x=403796,y=-836770},
        {x=439736,y=-842155},
        {x=419769,y=-835362},
        {x=457652,y=-814934},
        {x=457318,y=-852187},
        {x=434278,y=-828672},
        {x=435110,y=-811269},
      }
    },
    {
      id="SET_C0_02", label="C0 settlement 2", sector="C0", x=-873334, y=73932, weight=6,
      stops={
        {x=-888373,y=73340},
        {x=-839382,y=87897},
        {x=-870135,y=62913},
        {x=-896283,y=91194},
        {x=-855389,y=106673},
        {x=-852366,y=74605},
        {x=-872021,y=84536},
        {x=-883940,y=105169},
      }
    },
    {
      id="SET_Z3_01", label="Z3 settlement 1", sector="Z3", x=211387, y=-675792, weight=4.62,
      stops={
        {x=209133,y=-669046},
        {x=186847,y=-684910},
        {x=222182,y=-682357},
        {x=201735,y=-684839},
        {x=219480,y=-668818},
        {x=212460,y=-682303},
        {x=176657,y=-690489},
        {x=199271,y=-674667},
      }
    },
    {
      id="SET_C0_03", label="C0 settlement 3", sector="C0", x=-704219, y=225813, weight=6,
      stops={
        {x=-725025,y=200831},
        {x=-698427,y=221630},
        {x=-685711,y=212032},
        {x=-739621,y=216342},
        {x=-701606,y=200301},
        {x=-705945,y=233150},
        {x=-715040,y=219272},
        {x=-686632,y=226659},
      }
    },
    {
      id="SET_B4_01", label="B4 settlement 1", sector="B4", x=493742, y=-184414, weight=3.52,
      stops={
        {x=492057,y=-182187},
        {x=495557,y=-192814},
        {x=523472,y=-191836},
        {x=500477,y=-185440},
        {x=502241,y=-176817},
        {x=467443,y=-180393},
        {x=497066,y=-215397},
        {x=482616,y=-184218},
      }
    },
    {
      id="SET_A2_01", label="A2 settlement 1", sector="A2", x=-35954, y=-488920, weight=5.84,
      stops={
        {x=-32849,y=-484372},
        {x=-69308,y=-502586},
        {x=-10804,y=-505276},
        {x=-43959,y=-462433},
        {x=-49398,y=-493564},
        {x=-35959,y=-495643},
        {x=-57374,y=-503891},
        {x=-24359,y=-476472},
      }
    },
    {
      id="SET_Z0_01", label="Z0 settlement 1", sector="Z0", x=-871099, y=-848519, weight=3.86,
      stops={
        {x=-836912,y=-848105},
        {x=-882416,y=-859202},
        {x=-867499,y=-842784},
        {x=-864369,y=-866387},
        {x=-859610,y=-856696},
        {x=-894641,y=-851565},
        {x=-876644,y=-844689},
        {x=-868409,y=-852802},
      }
    },
    {
      id="SET_C0_04", label="C0 settlement 4", sector="C0", x=-854709, y=146894, weight=6,
      stops={
        {x=-846277,y=140780},
        {x=-876241,y=124778},
        {x=-870357,y=150078},
        {x=-832356,y=126661},
        {x=-855379,y=115417},
        {x=-852241,y=162551},
        {x=-818582,y=134480},
        {x=-887430,y=142503},
      }
    },
    {
      id="SET_B3_01", label="B3 settlement 1", sector="B3", x=291102, y=-177713, weight=3.68,
      stops={
        {x=272767,y=-179556},
        {x=297129,y=-179465},
        {x=289258,y=-168500},
        {x=288166,y=-188159},
        {x=284280,y=-179109},
        {x=278038,y=-165296},
        {x=303366,y=-186857},
        {x=296560,y=-166529},
      }
    },
    {
      id="SET_B0_01", label="B0 settlement 1", sector="B0", x=-871844, y=-178458, weight=4.11,
      stops={
        {x=-864326,y=-169600},
        {x=-875001,y=-203594},
        {x=-904624,y=-163988},
        {x=-876227,y=-176419},
        {x=-874213,y=-190296},
        {x=-864238,y=-183705},
        {x=-904701,y=-192116},
        {x=-866611,y=-199914},
      }
    },
    {
      id="SET_A4_01", label="A4 settlement 1", sector="A4", x=337292, y=-372031, weight=2.67,
      stops={
        {x=341926,y=-376364},
        {x=327884,y=-372250},
        {x=335644,y=-372260},
        {x=354427,y=-353915},
        {x=348786,y=-399472},
        {x=331959,y=-378653},
        {x=339487,y=-365879},
        {x=346455,y=-370356},
      }
    },
    {
      id="SET_D2_01", label="D2 settlement 1", sector="D2", x=-117159, y=344190, weight=3.09,
      stops={
        {x=-90474,y=322667},
        {x=-121853,y=341668},
        {x=-127075,y=350595},
        {x=-115102,y=348741},
        {x=-101745,y=343048},
        {x=-139552,y=366657},
        {x=-126911,y=379859},
        {x=-109478,y=337856},
      }
    },
    {
      id="SET_D1_01", label="D1 settlement 1", sector="D1", x=-533614, y=473735, weight=3.29,
      stops={
        {x=-544248,y=483107},
        {x=-530801,y=462799},
        {x=-560271,y=500026},
        {x=-519242,y=438402},
        {x=-527589,y=473503},
        {x=-538501,y=472312},
        {x=-533095,y=482975},
        {x=-522998,y=451214},
      }
    },
    {
      id="SET_C1_01", label="C1 settlement 1", sector="C1", x=-497109, y=189331, weight=3.08,
      stops={
        {x=-482984,y=194186},
        {x=-509713,y=183758},
        {x=-498375,y=181769},
        {x=-488427,y=200666},
        {x=-497495,y=195886},
        {x=-518962,y=164266},
        {x=-490783,y=187168},
        {x=-506545,y=190912},
      }
    },
    {
      id="SET_D3_01", label="D3 settlement 1", sector="D3", x=296317, y=383649, weight=6,
      stops={
        {x=269394,y=384512},
        {x=301355,y=350097},
        {x=326944,y=379516},
        {x=293144,y=403699},
        {x=300641,y=379265},
        {x=282600,y=361789},
        {x=317224,y=406582},
        {x=321088,y=361657},
      }
    },
    {
      id="SET_B3_02", label="B3 settlement 2", sector="B3", x=48977, y=2459, weight=2.25,
      stops={
        {x=50107,y=-2162},
        {x=53524,y=6541},
        {x=41828,y=-107},
        {x=86823,y=-3348},
        {x=47903,y=7561},
        {x=48977,y=2016},
        {x=53612,y=784},
        {x=41620,y=5809},
      }
    },
    {
      id="SET_B3_03", label="B3 settlement 3", sector="B3", x=94422, y=-168779, weight=2.81,
      stops={
        {x=102523,y=-156215},
        {x=85295,y=-174498},
        {x=102989,y=-176916},
        {x=92877,y=-176369},
        {x=67825,y=-185121},
        {x=90854,y=-165472},
        {x=100070,y=-169740},
        {x=92932,y=-155556},
      }
    },
    {
      id="SET_B1_01", label="B1 settlement 1", sector="B1", x=-462094, y=-106985, weight=2.71,
      stops={
        {x=-457447,y=-95615},
        {x=-472086,y=-113028},
        {x=-458167,y=-114026},
        {x=-468670,y=-101286},
        {x=-464693,y=-120299},
        {x=-456736,y=-104722},
        {x=-496364,y=-90605},
        {x=-424844,y=-98050},
      }
    },
    {
      id="SET_A1_01", label="A1 settlement 1", sector="A1", x=-343639, y=-363097, weight=2.66,
      stops={
        {x=-339602,y=-363597},
        {x=-361676,y=-326812},
        {x=-359532,y=-352260},
        {x=-341209,y=-354943},
        {x=-341061,y=-371948},
        {x=-349269,y=-356431},
        {x=-377313,y=-339272},
        {x=-355372,y=-369115},
      }
    },
    {
      id="SET_B2_01", label="B2 settlement 1", sector="B2", x=-53089, y=-84649, weight=2.8,
      stops={
        {x=-53811,y=-88605},
        {x=-45287,y=-96313},
        {x=-37656,y=-82650},
        {x=-55040,y=-75786},
        {x=-62153,y=-85656},
        {x=-36016,y=-91329},
        {x=-66693,y=-76103},
        {x=-45086,y=-79702},
      }
    },
    {
      id="SET_C1_02", label="C1 settlement 2", sector="C1", x=-327249, y=196032, weight=3.2,
      stops={
        {x=-331538,y=200982},
        {x=-317306,y=199325},
        {x=-331095,y=183144},
        {x=-295891,y=207470},
        {x=-287196,y=189012},
        {x=-322943,y=186310},
        {x=-325280,y=210789},
        {x=-335407,y=214012},
      }
    },
    {
      id="SET_Z1_03", label="Z1 settlement 3", sector="Z1", x=-439744, y=-672070, weight=4.06,
      stops={
        {x=-430934,y=-700466},
        {x=-436700,y=-668624},
        {x=-416787,y=-678770},
        {x=-451569,y=-665971},
        {x=-438279,y=-683849},
        {x=-422709,y=-690330},
        {x=-442318,y=-707259},
        {x=-450215,y=-693433},
      }
    },
    {
      id="SET_D0_01", label="D0 settlement 1", sector="D0", x=-867374, y=533296, weight=3.19,
      stops={
        {x=-865929,y=526122},
        {x=-862000,y=546221},
        {x=-876128,y=511705},
        {x=-904186,y=521078},
        {x=-852669,y=529448},
        {x=-856418,y=514683},
        {x=-904943,y=542089},
        {x=-874387,y=536052},
      }
    },
    {
      id="SET_C3_02", label="C3 settlement 2", sector="C3", x=161472, y=35962, weight=2.53,
      stops={
        {x=169434,y=27912},
        {x=161069,y=40147},
        {x=152774,y=37641},
        {x=173139,y=37464},
        {x=155583,y=46279},
        {x=153915,y=28729},
        {x=163396,y=32219},
        {x=156223,y=53390},
      }
    },
  },
  hunting = {
    {id="HUNT_A0_01",label="A0 hunting zone 1",sector="A0",x=-605879,y=-538057},
    {id="HUNT_B0_01",label="B0 hunting zone 1",sector="B0",x=-639404,y=-236530},
    {id="HUNT_Z2_01",label="Z2 hunting zone 1",sector="Z2",x=-2429,y=-705573},
    {id="HUNT_B3_01",label="B3 hunting zone 1",sector="B3",x=198722,y=-136021},
    {id="HUNT_A3_01",label="A3 hunting zone 1",sector="A3",x=232247,y=-303536},
    {id="HUNT_B0_02",label="B0 hunting zone 2",sector="B0",x=-672929,y=-102517},
    {id="HUNT_Z0_01",label="Z0 hunting zone 1",sector="Z0",x=-773504,y=-672070},
    {id="HUNT_B4_01",label="B4 hunting zone 1",sector="B4",x=567497,y=-203027},
    {id="HUNT_B2_01",label="B2 hunting zone 1",sector="B2",x=-270629,y=-169524},
    {id="HUNT_C1_01",label="C1 hunting zone 1",sector="C1",x=-572354,y=31495},
    {id="HUNT_B1_01",label="B1 hunting zone 1",sector="B1",x=-371204,y=-2008},
    {id="HUNT_B0_03",label="B0 hunting zone 3",sector="B0",x=-840554,y=-102517},
    {id="HUNT_D3_01",label="D3 hunting zone 1",sector="D3",x=299297,y=467035},
    {id="HUNT_C2_01",label="C2 hunting zone 1",sector="C2",x=-136529,y=266016},
    {id="HUNT_D0_01",label="D0 hunting zone 1",sector="D0",x=-739979,y=467035},
    {id="HUNT_D4_01",label="D4 hunting zone 1",sector="D4",x=466922,y=366525},
    {id="HUNT_Z2_02",label="Z2 hunting zone 2",sector="Z2",x=-170054,y=-672070},
    {id="HUNT_A3_02",label="A3 hunting zone 2",sector="A3",x=98147,y=-337039},
    {id="HUNT_D2_01",label="D2 hunting zone 1",sector="D2",x=-170054,y=467035},
    {id="HUNT_C2_02",label="C2 hunting zone 2",sector="C2",x=-237104,y=64998},
    {id="HUNT_D3_02",label="D3 hunting zone 2",sector="D3",x=198722,y=534041},
    {id="HUNT_B3_02",label="B3 hunting zone 2",sector="B3",x=31097,y=-102517},
  }
} ,
anchors = {
  points={
    {id="BOOT_01_D4",sector="D4",x=343997,y=341957},
    {id="BOOT_02_D3",sector="D3",x=296317,y=383649},
    {id="BOOT_03_D2",sector="D2",x=-117159,y=344190},
    {id="BOOT_04_D1",sector="D1",x=-533614,y=473735},
    {id="BOOT_05_D0",sector="D0",x=-867374,y=533296},
    {id="BOOT_06_C3",sector="C3",x=235972,y=102223},
    {id="BOOT_07_C1",sector="C1",x=-497109,y=189331},
    {id="BOOT_08_C0",sector="C0",x=-792874,y=132748},
    {id="BOOT_09_B4",sector="B4",x=493742,y=-184414},
    {id="BOOT_10_B3",sector="B3",x=291102,y=-177713},
    {id="BOOT_11_B2",sector="B2",x=-53089,y=-84649},
    {id="BOOT_12_B1",sector="B1",x=-462094,y=-106985},
    {id="BOOT_13_B0",sector="B0",x=-871844,y=-178458},
    {id="BOOT_14_A4",sector="A4",x=337292,y=-372031},
    {id="BOOT_15_A2",sector="A2",x=-35954,y=-488920},
    {id="BOOT_16_A1",sector="A1",x=-343639,y=-363097},
    {id="BOOT_17_Z4",sector="Z4",x=437122,y=-832884},
    {id="BOOT_18_Z3",sector="Z3",x=211387,y=-675792},
    {id="BOOT_19_Z1",sector="Z1",x=-304899,y=-756200},
    {id="BOOT_20_Z0",sector="Z0",x=-871099,y=-848519},
  }
} ,
}
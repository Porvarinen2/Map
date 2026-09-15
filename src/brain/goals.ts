import { AgentState, PoiMemory, memoryOf } from "./state";
import { Poi, WorldMap, distance } from "../world/map";

export interface GoalChoice {
  goal: string;
  utility: number;
  poi?: Poi;
  reason: string;
}

const LOOT_COOLDOWN_MIN = 240;
const WALK_M_PER_MIN = 66;

const p = (state: AgentState, key: string): number => state.npc.params[key] ?? 0;
const w = (state: AgentState, goal: string): number => state.npc.goals[goal] ?? 0;
const has = (state: AgentState, flag: string): boolean => state.npc.flags.includes(flag);

/** Night hours are hostile to most people and inviting to a few. */
function nightFactor(state: AgentState, hour: number): number {
  const isNight = hour >= 21 || hour < 5;
  if (!isNight) return 1;
  const vision = p(state, "perception.nightVision");
  const base = state.npc.chronotype === "night" ? 1.1 : 0.45;
  return base * (0.6 + vision) / p(state, "risk.nightMul");
}

function sleepPressure(state: AgentState, hour: number): number {
  const window: Record<string, [number, number]> = {
    early: [21, 5],
    normal: [23, 7],
    night: [8, 15],
  };
  const [from, to] = window[state.npc.chronotype] as [number, number];
  const inWindow = from < to ? hour >= from && hour < to : hour >= from || hour < to;
  return inWindow ? 2.2 : 0.5;
}

/** Perceived cost of walking there, in "utility points". */
/** Read-only memory lookup: scoring must not create memories of unvisited places. */
const peek = (state: AgentState, poi: Poi): PoiMemory =>
  state.memory.get(poi.id) ?? { visits: 0, danger: poi.danger };

function travelCost(state: AgentState, poi: Poi): number {
  const speed = WALK_M_PER_MIN * p(state, "movement.travelSpeedMul");
  const minutes = distance(state, poi) / speed;
  return minutes / 90;
}

function riskOf(state: AgentState, poi: Poi, hour: number): number {
  let risk = peek(state, poi).danger;
  if (poi.underground) risk += p(state, "risk.bunkerAversion");
  if (hour >= 21 || hour < 5) risk *= p(state, "risk.nightMul");
  risk *= 1 + (1 - p(state, "risk.threshold"));
  risk /= 0.6 + state.npc.skills["awareness"]!.level * 0.15 + state.npc.skills["camouflage"]!.level * 0.1;
  return risk;
}

function forbidden(state: AgentState, poi: Poi): boolean {
  if (state.bannedPoi === poi.id) return true;
  if (poi.underground && has(state, "refuses_bunkers")) return true;
  if ((poi.type === "lake" || poi.type === "river" || poi.type === "coast") && has(state, "no_swimming") && poi.fish) {
    return false; // fishing from the shore is fine, swimming is not
  }
  return false;
}

function bestPoi(
  state: AgentState,
  map: WorldMap,
  hour: number,
  filter: (poi: Poi) => boolean,
  score: (poi: Poi) => number,
): Poi | undefined {
  let best: Poi | undefined;
  let bestScore = -Infinity;
  for (const poi of map.pois) {
    if (forbidden(state, poi) || !filter(poi)) continue;
    const value = score(poi) - travelCost(state, poi) - riskOf(state, poi, hour);
    if (value > bestScore) {
      bestScore = value;
      best = poi;
    }
  }
  return best;
}

/** Utility-based goal selection; the winner is turned into an action by tick(). */
export function chooseGoal(state: AgentState, map: WorldMap, minuteOfDay: number): GoalChoice {
  const hour = Math.floor(minuteOfDay / 60);
  const n = state.needs;
  const inv = state.inventory;
  const night = nightFactor(state, hour);
  const options: GoalChoice[] = [];

  const add = (goal: string, utility: number, poi?: Poi, reason = ""): void => {
    if (utility > 0) options.push({ goal, utility, ...(poi ? { poi } : {}), reason });
  };

  if (state.bleeding || state.health < 0.6) {
    add("heal", (1 - state.health) ** 2 * 14 * w(state, "heal") + (state.bleeding ? 6 : 0), undefined, "vuoto/haavat");
  }

  // Thirst and hunger are hard drives: they override plans well before they kill.
  const survival = (need: number): number => need ** 3 * 14 + (need > 0.8 ? 6 : 0);
  if (inv.water > 0) {
    add("water", survival(n.thirst) * w(state, "water"), undefined, "juo repusta");
  } else {
    const src = bestPoi(state, map, hour, (poi) => poi.water, () => 3);
    add("water", survival(n.thirst) * w(state, "water"), src, "hakee vettä");
  }

  if (inv.food > 0) {
    add("food", survival(n.hunger) * 0.9 * w(state, "food"), undefined, "syö repusta");
  } else {
    const src = bestPoi(
      state, map, hour,
      (poi) => poi.lootTier > 0 || !!poi.game || !!poi.fish,
      (poi) => 1.2 + poi.lootTier * 0.2 + (poi.game ? 0.6 : 0) + (poi.fish ? 0.4 : 0),
    );
    add("food", survival(n.hunger) * w(state, "food"), src, "etsii ruokaa");
  }

  const shelter = state.homePoi
    ? map.byId.get(state.homePoi)
    : bestPoi(state, map, hour, (poi) => poi.shelter, (poi) => 1.5 - poi.danger);
  add("rest", n.fatigue ** 3 * 7 * w(state, "rest") * sleepPressure(state, hour), shelter, "nukkuu");

  const gearGap = 1 - inv.gearTier / 5;
  const lootPoi = bestPoi(
    state, map, hour,
    (poi) => poi.lootTier > 0,
    (poi) => {
      const mem = peek(state, poi);
      const fresh = mem.lootedAtMin === undefined
        ? 1
        : Math.min(1, (minuteOfDay + 1440 * 10 - mem.lootedAtMin) / LOOT_COOLDOWN_MIN);
      const ritual = has(state, "fixed_loot_route") && mem.visits > 0 ? 0.4 : 0;
      return (0.5 + poi.lootTier * 0.45) * fresh + ritual;
    },
  );
  add("loot", (0.6 + gearGap * 1.6) * w(state, "loot") * night, lootPoi, "lootti-reitti");

  if (inv.haul > 2 && state.homePoi) {
    add("hoard", inv.haul * 0.25 * w(state, "hoard"), map.byId.get(state.homePoi), "vie kätköön");
  }

  if (state.baseProgress < 1) {
    // Bases go up where it is quiet and buildable, never inside a trader zone or a bunker.
    const buildable = new Set(["farm", "village", "ruins", "forest"]);
    const site = state.homePoi
      ? map.byId.get(state.homePoi)
      : bestPoi(
        state, map, hour,
        (poi) => buildable.has(poi.type) && !poi.trade && !poi.underground,
        (poi) => 1.6 - poi.danger + (poi.farmable ? 0.4 : 0) + (poi.water ? 0.2 : 0),
      );
    add("build", w(state, "build") * (1 - state.baseProgress) * (state.homePoi ? 1 : 0.7), site, "rakentaa tukikohtaa");
  }

  if (state.homePoi) {
    const home = map.byId.get(state.homePoi);
    if (home?.farmable) add("farm", w(state, "farm") * 1.2, home, "hoitaa viljelmää");
  }

  const gameSpot = bestPoi(state, map, hour, (poi) => !!poi.game, () => 1.4);
  if (!has(state, "no_animal_kill")) {
    add("hunt", w(state, "hunt") * (0.5 + n.hunger) * night, gameSpot, "metsästää");
  }
  const fishSpot = bestPoi(state, map, hour, (poi) => !!poi.fish, () => 1.3);
  add("fish", w(state, "fish") * (0.6 + n.hunger * 0.8), fishSpot, "kalastaa");

  const ambushSpot = bestPoi(
    state, map, hour,
    (poi) => poi.lootTier >= 2,
    (poi) => 0.8 + poi.danger * 0.8,
  );
  // Even a patient camper eventually gets restless; boredom is what ends a stakeout.
  add(
    "ambush",
    w(state, "ambush") * (0.4 + inv.gearTier * 0.15) * night * (1 - n.boredom * 0.7),
    ambushSpot,
    "väijyy",
  );

  if (inv.haul > 1 || inv.gearTier >= 3) {
    const trader = bestPoi(state, map, hour, (poi) => !!poi.trade, () => 1.6);
    add("trade", w(state, "trade") * (0.5 + inv.haul * 0.2), trader, "kauppaa");
  }

  const unseen = bestPoi(
    state, map, hour,
    () => true,
    (poi) => 1.4 - Math.min(1, peek(state, poi).visits * 0.35),
  );
  add("explore", w(state, "explore") * (0.3 + n.boredom) * night, unseen, "tutkii saarta");

  if (n.stress > 0.7) add("hide", n.stress * 2, undefined, "rauhoittuu piilossa");

  options.sort((a, b) => b.utility - a.utility);
  const top = options[0] ?? { goal: "idle", utility: 0, reason: "ei mitään tekemistä" };

  // Plan stickiness: disciplined planners do not abandon a goal for a marginal gain.
  const stickiness = 1 + 0.25 * p(state, "mind.planningHorizon");
  if (state.goal && state.goal !== top.goal) {
    const current = options.find((o) => o.goal === state.goal);
    if (current && top.utility < current.utility * stickiness) return current;
  }
  return top;
}

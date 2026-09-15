import { Rng, clamp } from "../core/rng";
import { Npc } from "../core/types";
import { Poi, WorldMap, distance } from "../world/map";
import { chooseGoal } from "./goals";
import { Activity, AgentState, emptyTimeSpent, memoryOf } from "./state";

const WALK_M_PER_MIN = 66;

export interface SimEvent {
  minute: number;
  agent: string;
  text: string;
}

const p = (s: AgentState, key: string): number => s.npc.params[key] ?? 0;
const has = (s: AgentState, flag: string): boolean => s.npc.flags.includes(flag);

export function spawnAgent(npc: Npc, map: WorldMap, rng: Rng): AgentState {
  // Fresh spawns start on the coast with nothing, exactly like a new player.
  const coast = map.pois.filter((poi) => poi.type === "coast" || poi.type === "river");
  const start = coast.length > 0 ? rng.pick(coast) : (map.pois[0] as Poi);
  const state: AgentState = {
    npc,
    x: start.x + rng.float(-400, 400),
    y: start.y + rng.float(-400, 400),
    health: 1,
    bleeding: false,
    needs: { hunger: rng.float(0.1, 0.3), thirst: rng.float(0.1, 0.3), fatigue: rng.float(0, 0.2), stress: 0.1, boredom: 0.2 },
    inventory: { food: 0, water: 0, meds: 0, ammo: rng.int(0, 8), gearTier: 0, haul: 0 },
    awake: true,
    activity: "idle",
    activityTimer: 0,
    goal: "",
    goalUtility: 0,
    baseProgress: 0,
    memory: new Map(),
    deaths: 0,
    kills: 0,
    log: [],
    timeSpent: emptyTimeSpent(),
  };
  if (has(state, "banned_poi")) state.bannedPoi = rng.pick(map.pois).id;
  return state;
}

/** One in-game minute for one agent. */
export function tick(
  state: AgentState,
  map: WorldMap,
  rng: Rng,
  minute: number,
  events: SimEvent[],
): void {
  const minuteOfDay = minute % 1440;
  updateNeeds(state);
  state.timeSpent[state.activity] += 1;

  if (state.health <= 0) {
    die(state, map, rng, minute, events, "menehtyi");
    return;
  }

  if (state.activityTimer > 0) {
    state.activityTimer -= 1;
    if (state.activity === "travel") stepTowardTarget(state, map, rng, minute, events);
    if (state.activityTimer > 0) return;
    finishActivity(state, map, rng, minute, events);
    return;
  }

  const choice = chooseGoal(state, map, minuteOfDay);
  const goalChanged = choice.goal !== state.goal;
  state.goal = choice.goal;
  state.goalUtility = choice.utility;

  const target = choice.poi;
  if (target && distance(state, target) > 60) {
    state.activity = "travel";
    state.activityTarget = target.id;
    const speed = WALK_M_PER_MIN * p(state, "movement.travelSpeedMul");
    state.activityTimer = Math.max(1, Math.round(distance(state, target) / speed));
    if (goalChanged) {
      log(events, minute, state, `${choice.goal}: matkalla ${target.label} (${Math.round(distance(state, target))} m, u ${choice.utility.toFixed(2)})`);
    }
    return;
  }

  startActivityHere(state, map, rng, minute, events, choice.goal, target);
}

function updateNeeds(state: AgentState): void {
  const n = state.needs;
  const sleeping = state.activity === "sleep";
  n.hunger = clamp(n.hunger + (sleeping ? 0.0004 : 0.0008) * p(state, "needs.hungerRate"), 0, 1.3);
  n.thirst = clamp(n.thirst + (sleeping ? 0.0006 : 0.0012) * p(state, "needs.thirstRate"), 0, 1.3);
  n.fatigue = sleeping
    ? clamp(n.fatigue - 0.0035, 0, 1)
    : clamp(n.fatigue + 0.0007 * p(state, "needs.fatigueRate"), 0, 1);
  n.stress = clamp(n.stress - 0.0015 * p(state, "mind.stressDecay"), 0, 1);
  n.boredom = sleeping
    ? clamp(n.boredom - 0.002, 0, 1)
    : clamp(n.boredom + 0.0004 * p(state, "mind.boredomRate"), 0, 1);

  if (state.bleeding) state.health = clamp(state.health - 0.0025, 0, 1);
  if (n.hunger >= 1 || n.thirst >= 1) state.health = clamp(state.health - 0.0012, 0, 1);
  else if (state.health < 1 && !state.bleeding) {
    state.health = clamp(state.health + 0.0005 * p(state, "needs.healRate"), 0, 1);
  }
}

function stepTowardTarget(
  state: AgentState, map: WorldMap, rng: Rng, minute: number, events: SimEvent[],
): void {
  const target = state.activityTarget ? map.byId.get(state.activityTarget) : undefined;
  if (!target) {
    state.activityTimer = 0;
    return;
  }
  const speed = WALK_M_PER_MIN * p(state, "movement.travelSpeedMul");
  const d = distance(state, target);
  const step = Math.min(speed, d);
  if (d > 0) {
    state.x += ((target.x - state.x) / d) * step;
    state.y += ((target.y - state.y) / d) * step;
  }

  // Getting lost is one of the most player-like failure modes there is.
  if (has(state, "gets_lost") && rng.chance(0.0025)) {
    state.activityTimer += rng.int(10, 40);
    log(events, minute, state, "eksyi ja kiertää kehää");
  }
  if (rng.chance(0.0015 * (1 + p(state, "movement.noiseLevel")))) {
    encounter(state, map, rng, minute, events, 0.25, "puppetit matkalla");
  }
}

function startActivityHere(
  state: AgentState, map: WorldMap, rng: Rng, minute: number, events: SimEvent[],
  goal: string, target: Poi | undefined,
): void {
  const inv = state.inventory;
  const durations: Partial<Record<Activity, number>> = {
    eat: 4, drink: 2, heal: 8, loot: 0, sleep: 0, build: 90, farm: 60,
    hunt: 45, fish: 50, trade: 20, ambush: 60, hide: 30, explore: 25, idle: 15,
  };

  const begin = (activity: Activity, minutes: number, note?: string): void => {
    state.activity = activity;
    state.activityTimer = Math.max(1, minutes);
    if (target) state.activityTarget = target.id;
    if (note) log(events, minute, state, note);
  };

  switch (goal) {
    case "water":
      if (inv.water > 0) {
        inv.water -= 1;
        state.needs.thirst = clamp(state.needs.thirst - 0.6, 0, 1);
        begin("drink", durations.drink!, "juo pullosta");
      } else if (target?.water) {
        const unsafe = has(state, "unsafe_water") || !has(state, "boils_water");
        state.needs.thirst = clamp(state.needs.thirst - 0.75, 0, 1);
        inv.water += 1;
        begin("drink", has(state, "boils_water") ? 12 : 3, `juo ${target.label}`);
        if (unsafe && rng.chance(0.12 * (1 - p(state, "needs.sicknessResist")))) {
          state.health = clamp(state.health - 0.12, 0, 1);
          state.needs.stress = clamp(state.needs.stress + 0.1, 0, 1);
          log(events, minute, state, "sairastui likaisesta vedestä");
        }
      } else begin("idle", 10);
      return;

    case "food":
      if (inv.food > 0) {
        inv.food -= 1;
        state.needs.hunger = clamp(state.needs.hunger - 0.55, 0, 1);
        const risky = has(state, "eats_raw") || has(state, "food_poisoning_risk");
        begin("eat", has(state, "needs_fire") ? 18 : durations.eat!, "syö");
        if (risky && rng.chance(0.1 * (1 - p(state, "needs.sicknessResist")))) {
          state.health = clamp(state.health - 0.1, 0, 1);
          log(events, minute, state, "sai ruokamyrkytyksen");
        }
        if (has(state, "leaves_fire_burning") && has(state, "needs_fire")) {
          log(events, minute, state, "jätti nuotion palamaan");
        }
      } else if (target) {
        loot(state, map, rng, minute, events, target);
      } else begin("idle", 10);
      return;

    case "rest": {
      const safe = target?.shelter ?? false;
      const minutes = Math.round((state.needs.fatigue / 0.0035) * (safe ? 1 : 0.6));
      begin("sleep", clamp(minutes, 30, 540), safe ? `nukkuu ${target?.label}` : "nukkuu maastossa");
      state.awake = false;
      return;
    }

    case "heal": {
      const meds = inv.meds > 0;
      if (meds) inv.meds -= 1;
      state.bleeding = false;
      state.health = clamp(state.health + (meds ? 0.3 : 0.1) * p(state, "needs.healRate"), 0, 1);
      begin("heal", meds ? durations.heal! : 20, meds ? "hoitaa haavat" : "sitoo haavat rätillä");
      return;
    }

    case "loot":
      if (target) loot(state, map, rng, minute, events, target);
      else begin("explore", durations.explore!);
      return;

    case "hoard":
      inv.haul = 0;
      state.baseProgress = clamp(state.baseProgress + 0.05, 0, 1);
      begin("build", 20, "purkaa saaliin kätköön");
      return;

    case "build":
      if (!state.homePoi && target) {
        state.homePoi = target.id;
        log(events, minute, state, `valitsi tukikohdan: ${target.label}`);
      }
      state.baseProgress = clamp(state.baseProgress + 0.08, 0, 1);
      begin("build", durations.build!, `rakentaa (${Math.round(state.baseProgress * 100)} %)`);
      if (has(state, "abandons_plans") && rng.chance(0.15)) {
        state.baseProgress = clamp(state.baseProgress - 0.2, 0, 1);
        state.homePoi = undefined;
        log(events, minute, state, "kyllästyi ja hylkäsi projektin");
      }
      return;

    case "farm":
      inv.food += rng.int(1, 3);
      begin("farm", durations.farm!, "hoitaa viljelmää");
      return;

    case "hunt":
      begin("hunt", durations.hunt!, `metsästää ${target?.label ?? "metsässä"}`);
      return;

    case "fish":
      begin("fish", durations.fish!, `kalastaa ${target?.label ?? ""}`.trim());
      return;

    case "trade":
      inv.haul = 0;
      inv.food += 2;
      inv.meds += 1;
      inv.ammo += rng.int(5, 20);
      begin("trade", durations.trade!, `kauppaa ${target?.label ?? ""}`.trim());
      return;

    case "ambush":
      begin("ambush", durations.ambush!, `väijyy ${target?.label ?? ""}`.trim());
      return;

    case "hide":
      begin("hide", durations.hide!, "piiloutuu ja rauhoittuu");
      return;

    case "explore":
      if (target) memoryOf(state, target).visits += 1;
      begin("explore", durations.explore!, `tutkii ${target?.label ?? "ympäristöä"}`);
      return;

    default:
      begin("idle", durations.idle!);
  }
}

function loot(
  state: AgentState, map: WorldMap, rng: Rng, minute: number, events: SimEvent[], poi: Poi,
): void {
  const mem = memoryOf(state, poi);
  mem.visits += 1;
  mem.lootedAtMin = minute;
  const thievery = state.npc.skills["thievery"]!.level;
  const minutes = Math.round(clamp(8 + poi.lootTier * 6 - thievery * 2, 5, 40)
    * (has(state, "long_inventory_pauses") ? 1.4 : 1));
  state.activity = "loot";
  state.activityTarget = poi.id;
  state.activityTimer = minutes;

  const inv = state.inventory;
  const yieldRoll = rng.float(0.4, 1.2) * (1 + thievery * 0.1);
  inv.food += Math.round(yieldRoll * (poi.lootTier >= 1 ? 2 : 0));
  inv.water += Math.round(yieldRoll * (poi.lootTier >= 1 ? 1 : 0));
  if (poi.type === "hospital" || poi.type === "police") inv.meds += rng.int(1, 3);
  inv.ammo += Math.round(yieldRoll * poi.lootTier * 4);
  inv.haul += yieldRoll * poi.lootTier;
  if (poi.lootTier > inv.gearTier && rng.chance(0.04 + poi.lootTier * 0.025)) {
    inv.gearTier = clamp(inv.gearTier + 1, 0, 5);
    log(events, minute, state, `paransi varusteita (tier ${inv.gearTier}) @ ${poi.label}`);
  }
  if (has(state, "loots_everything")) inv.haul += 1;

  log(events, minute, state, `lootaa ${poi.label} (${minutes} min)`);

  const noise = p(state, "movement.noiseLevel") * (has(state, "attracts_puppets") ? 1.4 : 1);
  encounter(state, map, rng, minute, events, poi.danger * noise * 0.7, `${poi.label}`);
}

function encounter(
  state: AgentState, map: WorldMap, rng: Rng, minute: number, events: SimEvent[],
  threat: number, where: string,
): void {
  if (!rng.chance(clamp(threat * 0.5, 0, 0.9))) return;

  const poi = state.activityTarget ? map.byId.get(state.activityTarget) : undefined;
  if (poi) memoryOf(state, poi).danger = clamp(memoryOf(state, poi).danger + 0.05, 0, 1);
  state.needs.stress = clamp(state.needs.stress + 0.25 * p(state, "mind.stressGain"), 0, 1);

  const willFight = state.health > p(state, "combat.retreatHealthPct")
    && rng.chance(p(state, "combat.pushBias") + state.inventory.gearTier * 0.08);

  if (!willFight) {
    state.activityTimer += rng.int(5, 25);
    log(events, minute, state, `perääntyi kohtaamisesta (${where})`);
    return;
  }

  const power = p(state, "combat.accuracyBase") + state.npc.skills["rifles"]!.level * 0.06
    + state.inventory.gearTier * 0.05 + p(state, "combat.coverBias") * 0.1;
  if (rng.chance(clamp(power, 0.1, 0.92))) {
    state.kills += 1;
    state.inventory.haul += rng.float(0.5, 2);
    state.needs.stress = clamp(state.needs.stress + 0.1, 0, 1);
    log(events, minute, state, `voitti taistelun (${where})`);
    if (has(state, "lingers_after_kill")) state.activityTimer += rng.int(3, 8);
  } else {
    const damage = rng.float(0.15, 0.55) * (1.2 - p(state, "needs.injuryResist"));
    state.health = clamp(state.health - damage, 0, 1);
    state.bleeding = rng.chance(0.6);
    log(events, minute, state, `haavoittui taistelussa (${where}), HP ${(state.health * 100).toFixed(0)} %`);
    if (state.health <= 0) die(state, map, rng, minute, events, `kaatui (${where})`);
  }
}

function die(
  state: AgentState, map: WorldMap, rng: Rng, minute: number, events: SimEvent[], cause: string,
): void {
  state.deaths += 1;
  log(events, minute, state, `${cause} - uusi spawn`);
  const fresh = spawnAgent(state.npc, map, rng);
  state.x = fresh.x;
  state.y = fresh.y;
  state.health = 1;
  state.bleeding = false;
  state.needs = fresh.needs;
  state.inventory = fresh.inventory;
  state.activity = "idle";
  state.activityTimer = 0;
  state.goal = "";
  state.baseProgress = clamp(state.baseProgress, 0, 1);
}

function finishActivity(
  state: AgentState, map: WorldMap, rng: Rng, minute: number, events: SimEvent[],
): void {
  const poi = state.activityTarget ? map.byId.get(state.activityTarget) : undefined;
  switch (state.activity) {
    case "sleep":
      state.awake = true;
      state.needs.stress = clamp(state.needs.stress - 0.3, 0, 1);
      log(events, minute, state, "heräsi");
      break;
    case "hunt":
      if (rng.chance(0.55 + state.npc.skills["survival"]!.level * 0.06)) {
        state.inventory.food += rng.int(2, 5);
        log(events, minute, state, "sai saalista");
      } else log(events, minute, state, "ei löytänyt eläimiä");
      break;
    case "fish":
      if (rng.chance(0.5 + state.npc.skills["fishing"]!.level * 0.08)) {
        state.inventory.food += rng.int(1, 4);
        log(events, minute, state, "sai kalaa");
      }
      break;
    case "ambush":
      state.needs.boredom = clamp(state.needs.boredom + 0.12 * p(state, "mind.boredomRate"), 0, 1);
      if (rng.chance(0.12)) encounter(state, map, rng, minute, events, 0.9, "väijytys onnistui");
      else if (state.npc.flags.includes("abandons_plans")) log(events, minute, state, "kyllästyi väijymään");
      break;
    case "explore":
      if (poi) memoryOf(state, poi).visits += 1;
      state.needs.boredom = clamp(state.needs.boredom - 0.3, 0, 1);
      break;
    default:
      break;
  }
  state.activity = "idle";
  state.activityTimer = 0;
}

function log(events: SimEvent[], minute: number, state: AgentState, text: string): void {
  const entry = `${String(Math.floor((minute % 1440) / 60)).padStart(2, "0")}:${String(minute % 60).padStart(2, "0")} ${state.npc.name}: ${text}`;
  state.log.push(entry);
  events.push({ minute, agent: state.npc.id, text: entry });
}

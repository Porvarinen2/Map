import { Npc } from "../core/types";
import { Poi } from "../world/map";

export type Activity =
  | "sleep" | "eat" | "drink" | "travel" | "loot" | "heal" | "hide" | "ambush"
  | "build" | "farm" | "hunt" | "fish" | "trade" | "explore" | "idle";

export interface Needs {
  hunger: number;
  thirst: number;
  fatigue: number;
  stress: number;
  boredom: number;
}

export interface Inventory {
  food: number;
  water: number;
  meds: number;
  ammo: number;
  /** 0 = rags, 5 = full military kit. */
  gearTier: number;
  /** Loot weight carried toward the stash. */
  haul: number;
}

export interface PoiMemory {
  /** In-game minute the NPC last looted this POI; containers respawn over time. */
  lootedAtMin?: number;
  visits: number;
  /** Bad things that happened here; feeds the "paranoid about that field" behaviour. */
  danger: number;
}

export interface AgentState {
  npc: Npc;
  x: number;
  y: number;
  health: number;
  bleeding: boolean;
  needs: Needs;
  inventory: Inventory;
  awake: boolean;
  activity: Activity;
  activityTarget?: string;
  /** Minutes left of the current activity before it resolves. */
  activityTimer: number;
  goal: string;
  goalUtility: number;
  homePoi?: string;
  baseProgress: number;
  memory: Map<string, PoiMemory>;
  bannedPoi?: string;
  deaths: number;
  kills: number;
  log: string[];
  /** Minutes spent per activity, for the "does this look like a player's day" metric. */
  timeSpent: Record<Activity, number>;
}

export const emptyTimeSpent = (): Record<Activity, number> => ({
  sleep: 0, eat: 0, drink: 0, travel: 0, loot: 0, heal: 0, hide: 0, ambush: 0,
  build: 0, farm: 0, hunt: 0, fish: 0, trade: 0, explore: 0, idle: 0,
});

export const memoryOf = (state: AgentState, poi: Poi): PoiMemory => {
  let mem = state.memory.get(poi.id);
  if (!mem) {
    mem = { visits: 0, danger: poi.danger };
    state.memory.set(poi.id, mem);
  }
  return mem;
};

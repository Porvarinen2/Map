import { WorldMap, distance } from "../world/map";
import { chooseGoal } from "./goals";
import { AgentState } from "./state";
import { Decision } from "../server/protocol";

const GOAL_ACTION: Record<string, string> = {
  water: "drink", food: "eat", rest: "sleep", heal: "heal", loot: "loot",
  hoard: "stash", build: "build", farm: "farm", hunt: "hunt", fish: "fish",
  trade: "trade", ambush: "ambush", hide: "hide", explore: "explore", idle: "idle",
};

const p = (s: AgentState, key: string): number => s.npc.params[key] ?? 0;
const has = (s: AgentState, flag: string): boolean => s.npc.flags.includes(flag);

/**
 * Turns the winning goal into an order the game side can execute. Travel is
 * implicit: if the target is far away the action is "travel" toward it.
 */
export function decide(state: AgentState, map: WorldMap, minuteOfDay: number): Decision {
  const choice = chooseGoal(state, map, minuteOfDay);
  const poi = choice.poi;
  const far = poi ? distance(state, poi) > 60 : false;
  const hostile = choice.goal === "hunt" || choice.goal === "ambush";

  state.goal = choice.goal;
  state.goalUtility = choice.utility;

  return {
    t: "decision",
    agentId: state.npc.id,
    action: far ? "travel" : (GOAL_ACTION[choice.goal] ?? "idle"),
    goal: choice.goal,
    ...(poi ? { target: { poi: poi.id, x: poi.x, y: poi.y, label: poi.label } } : {}),
    movement: {
      crouch: p(state, "movement.crouchBias") > 0.5 || choice.goal === "ambush",
      sprint: p(state, "movement.sprintBias") > 0.6 && state.needs.fatigue < 0.7,
      useRoads: p(state, "movement.roadBias") > 0.5 && !has(state, "treeline_hugger"),
      speedMul: p(state, "movement.travelSpeedMul"),
    },
    combat: {
      engage: hostile || p(state, "social.hostilityBase") > 0.6,
      engageRangeMaxM: p(state, "combat.engageRangeMaxM"),
      retreatHealthPct: p(state, "combat.retreatHealthPct"),
      firstShotDelayMs: p(state, "combat.firstShotDelayMs"),
      coverBias: p(state, "combat.coverBias"),
      demandSurrender: has(state, "demands_surrender"),
    },
    ...(state.npc.voice.length > 0 && p(state, "social.chattiness") > 0.5
      ? { speech: { style: state.npc.voice[0] as string, line: "" } }
      : {}),
    reason: `${choice.reason} (u ${choice.utility.toFixed(2)})`,
    ttlSec: far ? 20 : 8,
  };
}

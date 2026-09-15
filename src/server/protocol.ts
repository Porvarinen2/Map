/** Line-delimited JSON protocol between the in-game mod and the brain service. */
export const PROTOCOL_VERSION = 1;

export interface HelloMsg { t: "hello"; version: number; server?: string }
export interface WelcomeMsg { t: "welcome"; protocol: number; brain: string }

export interface SpawnMsg {
  t: "spawn";
  agentId: string;
  seed?: number;
  archetype?: string;
  background?: string;
  x: number;
  y: number;
}

export interface PersonaSummary {
  name: string;
  callsign: string;
  archetype: string;
  background: string;
  age: number;
  sex: string;
  nationality: string;
  chronotype: string;
  traits: string[];
  flags: string[];
  voice: string[];
  loadout: { prefer: string[]; avoid: string[] };
  /** Only the parameters the game side actually needs to act on. */
  params: Record<string, number>;
  skills: Record<string, number>;
}

export interface SpawnedMsg { t: "spawned"; agentId: string; persona: PersonaSummary }

export type ContactKind = "player" | "npc" | "puppet" | "animal" | "vehicle";

export interface Contact {
  kind: ContactKind;
  x: number;
  y: number;
  distM: number;
  armed?: boolean;
  visible?: boolean;
  /** Stable id so the brain can hold grudges against a specific player. */
  id?: string;
}

export interface Sound { kind: "gunshot" | "footstep" | "vehicle" | "explosion"; x: number; y: number; distM: number }

export interface SenseMsg {
  t: "sense";
  agentId: string;
  /** In-game minute of day (0-1439). */
  minute: number;
  x: number;
  y: number;
  health: number;
  bleeding?: boolean;
  atPoi?: string;
  inventory?: { food?: number; water?: number; meds?: number; ammo?: number; gearTier?: number };
  contacts?: Contact[];
  sounds?: Sound[];
}

export interface Decision {
  t: "decision";
  agentId: string;
  action: string;
  goal: string;
  target?: { poi?: string; x?: number; y?: number; label?: string };
  movement: { crouch: boolean; sprint: boolean; useRoads: boolean; speedMul: number };
  combat: {
    engage: boolean;
    engageRangeMaxM: number;
    retreatHealthPct: number;
    firstShotDelayMs: number;
    coverBias: number;
    demandSurrender: boolean;
  };
  speech?: { style: string; line: string };
  reason: string;
  /** How long the game side may act on this decision before asking again. */
  ttlSec: number;
}

export interface EventMsg {
  t: "event";
  agentId: string;
  kind: "damaged" | "died" | "killed" | "looted" | "sawPlayer" | "heardShot" | "trade" | "arrived";
  data?: Record<string, unknown>;
}

export interface DespawnMsg { t: "despawn"; agentId: string }
export interface ErrorMsg { t: "error"; message: string }

export type ClientMsg = HelloMsg | SpawnMsg | SenseMsg | EventMsg | DespawnMsg;
export type ServerMsg = WelcomeMsg | SpawnedMsg | Decision | ErrorMsg;

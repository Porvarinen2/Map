import * as net from "net";
import { Rng, clamp } from "../core/rng";
import { loadDataset } from "../data/load";
import { generateNpc } from "../persona/generate";
import { WorldMap, loadMap } from "../world/map";
import { AgentState, memoryOf } from "../brain/state";
import { decide } from "../brain/decide";
import { advanceNeeds, spawnAgent } from "../brain/tick";
import {
  ClientMsg, Decision, PROTOCOL_VERSION, PersonaSummary, SenseMsg, ServerMsg, SpawnMsg,
} from "./protocol";

const GAME_PARAM_KEYS = [
  "perception.visionRangeM", "perception.hearingRangeM", "perception.reactionTimeMs",
  "perception.nightVision", "perception.falsePositiveChance", "perception.identifyTimeMs",
  "combat.engageRangeMinM", "combat.engageRangeMaxM", "combat.accuracyBase",
  "combat.recoilControl", "combat.firstShotDelayMs", "combat.burstDiscipline",
  "combat.retreatHealthPct", "combat.suppressionTolerance", "combat.coverBias",
  "combat.pushBias", "combat.executeWounded", "movement.crouchBias", "movement.roadBias",
  "movement.sprintBias", "movement.noiseLevel", "movement.travelSpeedMul",
  "social.chattiness", "social.hostilityBase", "social.mercyChance", "social.robberyChance",
];

export interface BrainOptions {
  port: number;
  host: string;
  verbose: boolean;
}

export class BrainService {
  private readonly data = loadDataset();
  private readonly map: WorldMap = loadMap();
  private readonly agents = new Map<string, AgentState>();
  private server?: net.Server;

  constructor(private readonly options: BrainOptions) {}

  listen(): void {
    this.server = net.createServer((socket) => this.handleConnection(socket));
    this.server.listen(this.options.port, this.options.host, () => {
      console.log(`Brain kuuntelee ${this.options.host}:${this.options.port} (protokolla ${PROTOCOL_VERSION})`);
    });
  }

  close(): void {
    this.server?.close();
  }

  private handleConnection(socket: net.Socket): void {
    const peer = `${socket.remoteAddress}:${socket.remotePort}`;
    console.log(`Yhteys ${peer}`);
    socket.setNoDelay(true);
    let buffer = "";

    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      let index = buffer.indexOf("\n");
      while (index >= 0) {
        const line = buffer.slice(0, index).trim();
        buffer = buffer.slice(index + 1);
        if (line.length > 0) this.handleLine(socket, line);
        index = buffer.indexOf("\n");
      }
      // A malformed client must not be able to grow this buffer forever.
      if (buffer.length > 1_000_000) {
        this.send(socket, { t: "error", message: "line too long" });
        socket.destroy();
      }
    });
    socket.on("error", (err) => console.log(`Yhteysvirhe ${peer}: ${err.message}`));
    socket.on("close", () => console.log(`Katkaisi ${peer}`));
  }

  private handleLine(socket: net.Socket, line: string): void {
    let msg: ClientMsg;
    try {
      msg = JSON.parse(line) as ClientMsg;
    } catch {
      this.send(socket, { t: "error", message: "invalid json" });
      return;
    }

    try {
      switch (msg.t) {
        case "hello":
          this.send(socket, { t: "welcome", protocol: PROTOCOL_VERSION, brain: "scum-living-npc" });
          return;
        case "spawn":
          this.send(socket, { t: "spawned", agentId: msg.agentId, persona: this.spawn(msg) });
          return;
        case "sense":
          this.send(socket, this.senseAndDecide(msg));
          return;
        case "event":
          this.applyEvent(msg.agentId, msg.kind, msg.data ?? {});
          return;
        case "despawn":
          this.agents.delete(msg.agentId);
          return;
        default:
          this.send(socket, { t: "error", message: `unknown message type` });
      }
    } catch (err) {
      this.send(socket, { t: "error", message: (err as Error).message });
    }
  }

  private spawn(msg: SpawnMsg): PersonaSummary {
    const seed = msg.seed ?? Math.floor(Math.random() * 0xffffffff);
    const npc = generateNpc(this.data, {
      seed,
      ...(msg.archetype ? { archetype: msg.archetype } : {}),
      ...(msg.background ? { background: msg.background } : {}),
    });
    const state = spawnAgent(npc, this.map, new Rng(seed));
    state.x = msg.x;
    state.y = msg.y;
    this.agents.set(msg.agentId, state);
    if (this.options.verbose) {
      console.log(`+ ${msg.agentId}: ${npc.name} "${npc.callsign}" (${npc.archetypeLabel} / ${npc.backgroundLabel})`);
    }

    const params: Record<string, number> = {};
    for (const key of GAME_PARAM_KEYS) params[key] = npc.params[key] ?? 0;
    const skills: Record<string, number> = {};
    for (const [skill, s] of Object.entries(npc.skills)) skills[skill] = s.level;

    return {
      name: npc.name,
      callsign: npc.callsign,
      archetype: npc.archetype,
      background: npc.background,
      age: npc.age,
      sex: npc.sex,
      nationality: npc.nationality,
      chronotype: npc.chronotype,
      traits: npc.traits,
      flags: npc.flags,
      voice: npc.voice,
      loadout: npc.loadout,
      params,
      skills,
    };
  }

  private senseAndDecide(msg: SenseMsg): Decision | ServerMsg {
    const state = this.agents.get(msg.agentId);
    if (!state) return { t: "error", message: `unknown agent ${msg.agentId}` };

    const minute = msg.minute % 1440;
    if (state.lastMinute !== undefined) {
      const delta = minute >= state.lastMinute ? minute - state.lastMinute : minute + 1440 - state.lastMinute;
      advanceNeeds(state, delta);
    }
    state.lastMinute = minute;

    state.x = msg.x;
    state.y = msg.y;
    state.health = clamp(msg.health, 0, 1);
    state.bleeding = msg.bleeding ?? false;
    if (msg.inventory) {
      const inv = state.inventory;
      inv.food = msg.inventory.food ?? inv.food;
      inv.water = msg.inventory.water ?? inv.water;
      inv.meds = msg.inventory.meds ?? inv.meds;
      inv.ammo = msg.inventory.ammo ?? inv.ammo;
      inv.gearTier = msg.inventory.gearTier ?? inv.gearTier;
    }

    // Contacts and gunfire raise stress and mark the place as dangerous.
    const threats = (msg.contacts ?? []).filter((c) => c.kind === "player" || c.kind === "puppet");
    if (threats.length > 0) {
      state.needs.stress = clamp(
        state.needs.stress + 0.05 * threats.length * (state.npc.params["mind.stressGain"] ?? 1),
        0, 1,
      );
    }
    if ((msg.sounds ?? []).some((s) => s.kind === "gunshot")) {
      state.needs.stress = clamp(state.needs.stress + 0.1, 0, 1);
    }
    const poi = msg.atPoi ? this.map.byId.get(msg.atPoi) : undefined;
    if (poi && threats.length > 0) {
      const mem = memoryOf(state, poi);
      mem.danger = clamp(mem.danger + 0.04, 0, 1);
    }

    const decision = decide(state, this.map, minute);
    // The game side addresses agents by its own id; echo it back untouched.
    decision.agentId = msg.agentId;
    if (this.options.verbose) {
      console.log(`${msg.agentId} ${state.npc.name}: ${decision.action} ${decision.target?.label ?? ""} - ${decision.reason}`);
    }
    return decision;
  }

  private applyEvent(agentId: string, kind: string, data: Record<string, unknown>): void {
    const state = this.agents.get(agentId);
    if (!state) return;
    const stressGain = state.npc.params["mind.stressGain"] ?? 1;

    switch (kind) {
      case "damaged":
        state.needs.stress = clamp(state.needs.stress + 0.2 * stressGain, 0, 1);
        break;
      case "killed":
        state.kills += 1;
        state.needs.stress = clamp(state.needs.stress + 0.08 * stressGain, 0, 1);
        break;
      case "died": {
        state.deaths += 1;
        // A death the NPC survives as a persona: the place is remembered as lethal.
        const poiId = typeof data["poi"] === "string" ? (data["poi"] as string) : undefined;
        const poi = poiId ? this.map.byId.get(poiId) : undefined;
        if (poi) memoryOf(state, poi).danger = clamp(memoryOf(state, poi).danger + 0.3, 0, 1);
        state.needs = { hunger: 0.2, thirst: 0.2, fatigue: 0.1, stress: 0.3, boredom: 0.2 };
        state.inventory = { food: 0, water: 0, meds: 0, ammo: 0, gearTier: 0, haul: 0 };
        break;
      }
      case "looted": {
        const poiId = typeof data["poi"] === "string" ? (data["poi"] as string) : undefined;
        const poi = poiId ? this.map.byId.get(poiId) : undefined;
        if (poi) {
          const mem = memoryOf(state, poi);
          mem.visits += 1;
          mem.lootedAtMin = typeof data["minute"] === "number" ? (data["minute"] as number) : 0;
        }
        break;
      }
      case "heardShot":
        state.needs.stress = clamp(state.needs.stress + 0.12 * stressGain, 0, 1);
        break;
      default:
        break;
    }
  }

  private send(socket: net.Socket, msg: ServerMsg): void {
    socket.write(JSON.stringify(msg) + "\n");
  }
}

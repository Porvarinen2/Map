import { Rng, clamp, round } from "../core/rng";
import {
  ArchetypeDef, BackgroundDef, Chronotype, Dataset, Npc, Rarity, SkillState, TraitDef,
} from "../core/types";
import { resolveParams } from "./params";

const RARITY_WEIGHT: Record<Rarity, number> = { common: 6, uncommon: 3, rare: 1 };
const AXIS_SD = 0.13;
const MAX_TRAITS = 9;
/** Per-category caps keep personalities readable instead of a wall of traits. */
const CATEGORY_CAP: Record<TraitDef["category"], number> = {
  combat: 3, physical: 3, social: 3, mental: 2, quirk: 3, flaw: 2,
};

export interface GenerateOptions {
  seed?: number;
  archetype?: string;
  background?: string;
}

export function generateNpc(data: Dataset, options: GenerateOptions = {}): Npc {
  const seed = options.seed ?? Math.floor(Math.random() * 0xffffffff);
  const rng = new Rng(seed);

  const archetype = options.archetype
    ? requireArchetype(data, options.archetype)
    : rng.weighted(data.archetypes, (a) => a.weight);

  const background = options.background
    ? requireBackground(data, options.background)
    : pickBackground(data, rng, archetype);

  const axes = rollAxes(data, rng, archetype);
  const traits = pickTraits(data, rng, archetype, background, axes);
  const { params, goals } = resolveParams(data.baseline, data.axes, axes, traits, archetype.goals);

  const sex: "male" | "female" = rng.chance(0.82) ? "male" : "female";
  const nationality = rng.weighted(data.names.nationalities, (n) => n.weight);
  const firstNames = sex === "male" ? nationality.male : nationality.female;
  const name = `${rng.pick(firstNames)} ${rng.pick(nationality.last)}`;
  const callsign = `${rng.pick(data.names.callsignAdjectives)} ${rng.pick(data.names.callsignNouns)}`;

  const age = Math.round(clamp(rng.gauss(archetype.ageMean, 7), 17, 63));
  const heightBase = sex === "male" ? 179 : 166;
  const traitIds = new Set(traits.map((t) => t.id));
  const heightCm = Math.round(
    rng.gauss(heightBase, 7) + (traitIds.has("tall_frame") ? 9 : 0) - (traitIds.has("short_frame") ? 9 : 0),
  );
  const bmi = clamp(
    rng.gauss(24, 2.4) + (traitIds.has("heavyset") ? 4.5 : 0) - (traitIds.has("lean_build") ? 3.5 : 0),
    17,
    36,
  );
  const weightKg = Math.round(bmi * (heightCm / 100) ** 2);

  const flags = unique(traits.flatMap((t) => t.flags ?? []));
  const voice = unique(traits.flatMap((t) => t.voice ?? []));

  return {
    id: `npc_${seed.toString(16).padStart(8, "0")}`,
    seed,
    name,
    callsign,
    sex,
    age,
    nationality: nationality.label,
    heightCm,
    weightKg,
    archetype: archetype.id,
    archetypeLabel: archetype.label,
    background: background.id,
    backgroundLabel: background.label,
    axes,
    traits: traits.map((t) => t.id),
    traitBudgetUsed: traits.reduce((sum, t) => sum + t.cost, 0),
    chronotype: resolveChronotype(flags, params, axes, rng),
    skills: rollSkills(data, rng, background, axes),
    params,
    goals,
    flags,
    voice,
    loadout: mergeLoadout(archetype, background, traits),
  };
}

function requireArchetype(data: Dataset, id: string): ArchetypeDef {
  const found = data.archetypes.find((a) => a.id === id);
  if (!found) throw new Error(`Unknown archetype "${id}"`);
  return found;
}

function requireBackground(data: Dataset, id: string): BackgroundDef {
  const found = data.backgroundsById.get(id);
  if (!found) throw new Error(`Unknown background "${id}"`);
  return found;
}

function pickBackground(data: Dataset, rng: Rng, archetype: ArchetypeDef): BackgroundDef {
  const options = Object.entries(archetype.backgrounds);
  const [id] = rng.weighted(options, ([, weight]) => weight);
  return requireBackground(data, id);
}

function rollAxes(data: Dataset, rng: Rng, archetype: ArchetypeDef): Record<string, number> {
  const axes: Record<string, number> = {};
  for (const axis of Object.keys(data.axes)) {
    const mean = archetype.axes[axis] ?? 0.5;
    axes[axis] = round(clamp(rng.gauss(mean, AXIS_SD), 0.02, 0.98));
  }
  return axes;
}

/**
 * Trait selection: flaws first (they refund points), then flavour, then the
 * expensive positive traits until the point budget runs out. Exclusions are
 * enforced both ways so an NPC never ends up both Coward and Fearless.
 */
function pickTraits(
  data: Dataset,
  rng: Rng,
  archetype: ArchetypeDef,
  background: BackgroundDef,
  axes: Record<string, number>,
): TraitDef[] {
  const chosen: TraitDef[] = [];
  const chosenIds = new Set<string>();
  let budget = data.baseline.traitBudget;

  const bias = (t: TraitDef): number => {
    let w = RARITY_WEIGHT[t.rarity];
    w *= 1 + 3 * (archetype.traitPool?.[t.id] ?? 0);
    w *= 1 + 2 * (background.traitBias?.[t.id] ?? 0);
    return w;
  };

  const eligible = (t: TraitDef): boolean => {
    if (chosenIds.has(t.id)) return false;
    for (const ex of t.excludes ?? []) if (chosenIds.has(ex)) return false;
    for (const other of chosen) if ((other.excludes ?? []).includes(t.id)) return false;
    for (const [axis, [min, max]] of Object.entries(t.requires?.axes ?? {})) {
      const value = axes[axis];
      if (value === undefined || value < min || value > max) return false;
    }
    return true;
  };

  const countIn = (category: TraitDef["category"]): number =>
    chosen.filter((t) => t.category === category).length;

  /**
   * "any" = flavour pass (cost ignored), "free" = drawbacks and quirks that cost
   * nothing or refund points, "buy" = positive traits paid from the budget.
   */
  const costAllowed = (t: TraitDef, mode: "any" | "free" | "buy"): boolean =>
    mode === "any" ? true : mode === "free" ? t.cost <= 0 : t.cost >= 1 && t.cost <= budget;

  const take = (category: TraitDef["category"], count: number, mode: "any" | "free" | "buy"): void => {
    for (let i = 0; i < count; i++) {
      if (chosen.length >= MAX_TRAITS || countIn(category) >= CATEGORY_CAP[category]) return;
      const pool = data.traits.filter(
        (t) => t.category === category && eligible(t) && costAllowed(t, mode),
      );
      if (pool.length === 0) return;
      const trait = rng.weighted(pool, bias);
      chosen.push(trait);
      chosenIds.add(trait.id);
      budget -= trait.cost;
    }
  };

  // Flaws and quirks are what make an NPC read as a person rather than a stat block.
  take("flaw", rng.chance(0.3) ? 2 : 1, "any");
  take("quirk", rng.weighted([1, 2, 3], (n) => (n === 3 ? 2 : 4)), "any");
  if (rng.chance(0.55)) take("mental", rng.chance(0.2) ? 2 : 1, "any");

  // Body type: at most one frame trait plus optional extras.
  take("physical", 1, "any");

  // Cheap habits and weaknesses (panic spraying, KOS mouth, lone wolf...) that
  // refund or cost nothing - these are a big part of looking like a real player.
  if (rng.chance(0.7)) take(rng.chance(0.5) ? "combat" : "social", 1, "free");
  if (rng.chance(0.4)) take("social", 1, "free");

  const categories: TraitDef["category"][] = ["combat", "social", "physical", "combat", "mental"];
  let misses = 0;
  for (let guard = 0; budget > 0 && chosen.length < MAX_TRAITS && misses < categories.length; guard++) {
    const before = chosen.length;
    take(categories[guard % categories.length] as TraitDef["category"], 1, "buy");
    misses = chosen.length === before ? misses + 1 : 0;
  }

  return chosen;
}

function resolveChronotype(
  flags: string[],
  params: Record<string, number>,
  axes: Record<string, number>,
  rng: Rng,
): Chronotype {
  // Someone who cannot see in the dark does not become a night operator.
  const nightCapable = (params["perception.nightVision"] ?? 0.35) >= 0.3;
  if (flags.includes("chronotype:night")) return nightCapable ? "night" : "normal";
  if (flags.includes("chronotype:early")) return "early";
  if (!nightCapable) return rng.chance(0.35) ? "early" : "normal";
  const nightPull = (axes["caution"] ?? 0.5) * 0.3 + (axes["aggression"] ?? 0.5) * 0.2
    + (flags.includes("night_travel_ok") ? 0.25 : 0);
  if (rng.chance(0.15 + nightPull * 0.3)) return "night";
  if (rng.chance(0.25)) return "early";
  return "normal";
}

function rollSkills(
  data: Dataset,
  rng: Rng,
  background: BackgroundDef,
  axes: Record<string, number>,
): Record<string, SkillState> {
  const discipline = axes["discipline"] ?? 0.5;
  const skills: Record<string, SkillState> = {};
  for (const skill of data.baseline.skills) {
    const start = background.skills[skill] ?? 0;
    const level = round(clamp(rng.gauss(start, start > 0 ? 0.5 : 0.35), 0, 5), 2);
    const rate = round(clamp((background.aptitude?.[skill] ?? 1) * (0.85 + discipline * 0.35), 0.6, 2), 2);
    skills[skill] = { level, rate };
  }
  return skills;
}

function mergeLoadout(
  archetype: ArchetypeDef,
  background: BackgroundDef,
  traits: TraitDef[],
): { prefer: string[]; avoid: string[] } {
  const prefer = unique([
    ...(archetype.loadout?.prefer ?? []),
    ...(background.loadout?.prefer ?? []),
    ...traits.flatMap((t) => t.loadout?.prefer ?? []),
  ]);
  const avoid = unique([
    ...(archetype.loadout?.avoid ?? []),
    ...(background.loadout?.avoid ?? []),
    ...traits.flatMap((t) => t.loadout?.avoid ?? []),
  ]);
  return { prefer: prefer.filter((i) => !avoid.includes(i)), avoid };
}

const unique = (items: string[]): string[] => [...new Set(items)];

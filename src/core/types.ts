export type TraitCategory = "combat" | "physical" | "social" | "mental" | "quirk" | "flaw";
export type Rarity = "common" | "uncommon" | "rare";

/** A single modifier on a runtime parameter or goal weight. */
export interface Modifier {
  add?: number;
  mul?: number;
}

export type ModifierMap = Record<string, Modifier>;

export interface TraitDef {
  id: string;
  label: string;
  desc: string;
  category: TraitCategory;
  rarity: Rarity;
  /** Trait point cost. Negative costs (flaws) hand points back to the budget. */
  cost: number;
  tags?: string[];
  excludes?: string[];
  requires?: { axes?: Record<string, [number, number]> };
  mods?: ModifierMap;
  /** Multipliers applied to goal utility weights. */
  goalBias?: Record<string, number>;
  /** Behaviour switches the brain reads directly (no numeric meaning). */
  flags?: string[];
  /** Dialogue / proximity-chat style tags. */
  voice?: string[];
  loadout?: { prefer?: string[]; avoid?: string[] };
}

export interface AxisDef {
  label: string;
  /** Effects scale with (value - 0.5) * 2, so 0.5 is neutral. */
  effects: ModifierMap;
}

export interface ArchetypeDef {
  id: string;
  label: string;
  desc: string;
  weight: number;
  ageMean: number;
  axes: Record<string, number>;
  goals?: Record<string, number>;
  traitPool?: Record<string, number>;
  backgrounds: Record<string, number>;
  loadout?: { prefer?: string[]; avoid?: string[] };
}

export interface BackgroundDef {
  id: string;
  label: string;
  /** Starting skill levels (0-5 scale, SCUM-like). */
  skills: Record<string, number>;
  /** Per-skill learning-rate multipliers. */
  aptitude?: Record<string, number>;
  traitBias?: Record<string, number>;
  loadout?: { prefer?: string[]; avoid?: string[] };
}

export interface ParamSpec {
  value: number;
  min: number;
  max: number;
}

export interface Baseline {
  params: Record<string, ParamSpec>;
  goals: Record<string, number>;
  skills: string[];
  traitBudget: number;
}

export interface Nationality {
  id: string;
  label: string;
  weight: number;
  male: string[];
  female: string[];
  last: string[];
}

export interface NameData {
  nationalities: Nationality[];
  callsignAdjectives: string[];
  callsignNouns: string[];
}

export interface Dataset {
  baseline: Baseline;
  axes: Record<string, AxisDef>;
  traits: TraitDef[];
  traitsById: Map<string, TraitDef>;
  archetypes: ArchetypeDef[];
  backgrounds: BackgroundDef[];
  backgroundsById: Map<string, BackgroundDef>;
  names: NameData;
}

export type Chronotype = "early" | "normal" | "night";

export interface SkillState {
  level: number;
  /** XP gain multiplier for this skill. */
  rate: number;
}

export interface Npc {
  id: string;
  seed: number;
  name: string;
  callsign: string;
  sex: "male" | "female";
  age: number;
  nationality: string;
  heightCm: number;
  weightKg: number;
  archetype: string;
  archetypeLabel: string;
  background: string;
  backgroundLabel: string;
  axes: Record<string, number>;
  traits: string[];
  traitBudgetUsed: number;
  chronotype: Chronotype;
  skills: Record<string, SkillState>;
  params: Record<string, number>;
  goals: Record<string, number>;
  flags: string[];
  voice: string[];
  loadout: { prefer: string[]; avoid: string[] };
}

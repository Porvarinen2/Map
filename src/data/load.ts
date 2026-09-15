import * as fs from "fs";
import * as path from "path";
import {
  ArchetypeDef, AxisDef, BackgroundDef, Baseline, Dataset, NameData, TraitDef,
} from "../core/types";

const DATA_DIR = path.resolve(__dirname, "../../data");
const TRAIT_FILES = ["combat", "physical", "social", "mental", "quirks", "flaws"];

function readJson<T>(relative: string): T {
  const file = path.join(DATA_DIR, relative);
  try {
    return JSON.parse(fs.readFileSync(file, "utf8")) as T;
  } catch (err) {
    throw new Error(`Failed to read ${file}: ${(err as Error).message}`);
  }
}

/** Loads every data file and cross-validates ids and modifier keys. */
export function loadDataset(): Dataset {
  const baseline = readJson<Baseline>("baseline.json");
  const axes = readJson<Record<string, AxisDef>>("axes.json");
  const archetypes = readJson<ArchetypeDef[]>("archetypes.json");
  const backgrounds = readJson<BackgroundDef[]>("backgrounds.json");
  const names = readJson<NameData>("names.json");

  const traits: TraitDef[] = [];
  for (const file of TRAIT_FILES) traits.push(...readJson<TraitDef[]>(`traits/${file}.json`));

  const traitsById = new Map(traits.map((t) => [t.id, t]));
  const backgroundsById = new Map(backgrounds.map((b) => [b.id, b]));
  const dataset: Dataset = {
    baseline, axes, traits, traitsById, archetypes, backgrounds, backgroundsById, names,
  };
  validate(dataset);
  return dataset;
}

function validate(d: Dataset): void {
  const errors: string[] = [];
  const paramKeys = new Set(Object.keys(d.baseline.params));
  const goalKeys = new Set(Object.keys(d.baseline.goals));
  const skillKeys = new Set(d.baseline.skills);

  const checkModKey = (key: string, where: string): void => {
    if (key.startsWith("goals.")) {
      if (!goalKeys.has(key.slice("goals.".length))) errors.push(`${where}: unknown goal "${key}"`);
    } else if (!paramKeys.has(key)) {
      errors.push(`${where}: unknown param "${key}"`);
    }
  };

  const seen = new Set<string>();
  for (const t of d.traits) {
    if (seen.has(t.id)) errors.push(`duplicate trait id "${t.id}"`);
    seen.add(t.id);
    for (const key of Object.keys(t.mods ?? {})) checkModKey(key, `trait ${t.id}`);
    for (const goal of Object.keys(t.goalBias ?? {})) {
      if (!goalKeys.has(goal)) errors.push(`trait ${t.id}: unknown goal bias "${goal}"`);
    }
    for (const ex of t.excludes ?? []) {
      if (!d.traitsById.has(ex)) errors.push(`trait ${t.id}: excludes unknown trait "${ex}"`);
    }
    for (const axis of Object.keys(t.requires?.axes ?? {})) {
      if (!d.axes[axis]) errors.push(`trait ${t.id}: requires unknown axis "${axis}"`);
    }
  }

  for (const [axis, def] of Object.entries(d.axes)) {
    for (const key of Object.keys(def.effects)) checkModKey(key, `axis ${axis}`);
  }

  for (const a of d.archetypes) {
    for (const axis of Object.keys(a.axes)) {
      if (!d.axes[axis]) errors.push(`archetype ${a.id}: unknown axis "${axis}"`);
    }
    for (const goal of Object.keys(a.goals ?? {})) {
      if (!goalKeys.has(goal)) errors.push(`archetype ${a.id}: unknown goal "${goal}"`);
    }
    for (const trait of Object.keys(a.traitPool ?? {})) {
      if (!d.traitsById.has(trait)) errors.push(`archetype ${a.id}: unknown trait "${trait}"`);
    }
    for (const bg of Object.keys(a.backgrounds)) {
      if (!d.backgroundsById.has(bg)) errors.push(`archetype ${a.id}: unknown background "${bg}"`);
    }
  }

  for (const b of d.backgrounds) {
    for (const skill of Object.keys(b.skills)) {
      if (!skillKeys.has(skill)) errors.push(`background ${b.id}: unknown skill "${skill}"`);
    }
    for (const skill of Object.keys(b.aptitude ?? {})) {
      if (!skillKeys.has(skill)) errors.push(`background ${b.id}: unknown aptitude skill "${skill}"`);
    }
    for (const trait of Object.keys(b.traitBias ?? {})) {
      if (!d.traitsById.has(trait)) errors.push(`background ${b.id}: unknown trait "${trait}"`);
    }
  }

  if (errors.length > 0) {
    throw new Error(`Dataset validation failed:\n - ${errors.join("\n - ")}`);
  }
}

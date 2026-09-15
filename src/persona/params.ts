import { clamp, round } from "../core/rng";
import { AxisDef, Baseline, ModifierMap, TraitDef } from "../core/types";

interface Accumulator {
  add: number;
  mul: number;
}

const ensure = (map: Map<string, Accumulator>, key: string): Accumulator => {
  let acc = map.get(key);
  if (!acc) {
    acc = { add: 0, mul: 1 };
    map.set(key, acc);
  }
  return acc;
};

/** Applies a modifier map; `scale` in [-1,1] is used for continuous axis effects. */
function apply(map: Map<string, Accumulator>, mods: ModifierMap | undefined, scale = 1): void {
  for (const [key, mod] of Object.entries(mods ?? {})) {
    const acc = ensure(map, key);
    if (mod.add !== undefined) acc.add += mod.add * scale;
    if (mod.mul !== undefined) {
      // Exponential scaling keeps axis effects symmetric around the neutral 0.5.
      acc.mul *= scale === 1 ? mod.mul : Math.pow(mod.mul, scale);
    }
  }
}

export interface ResolvedParams {
  params: Record<string, number>;
  goals: Record<string, number>;
}

/**
 * Resolves the final runtime parameter block: baseline -> additive terms ->
 * multiplicative terms -> clamped to the sane human range.
 */
export function resolveParams(
  baseline: Baseline,
  axes: Record<string, AxisDef>,
  axisValues: Record<string, number>,
  traits: TraitDef[],
  archetypeGoals: Record<string, number> | undefined,
): ResolvedParams {
  const acc = new Map<string, Accumulator>();

  for (const [axis, def] of Object.entries(axes)) {
    const value = axisValues[axis];
    if (value === undefined) continue;
    apply(acc, def.effects, (value - 0.5) * 2);
  }

  for (const trait of traits) {
    apply(acc, trait.mods);
    for (const [goal, mul] of Object.entries(trait.goalBias ?? {})) {
      ensure(acc, `goals.${goal}`).mul *= mul;
    }
  }

  for (const [goal, mul] of Object.entries(archetypeGoals ?? {})) {
    ensure(acc, `goals.${goal}`).mul *= mul;
  }

  const params: Record<string, number> = {};
  for (const [key, spec] of Object.entries(baseline.params)) {
    const a = acc.get(key) ?? { add: 0, mul: 1 };
    params[key] = round(clamp((spec.value + a.add) * a.mul, spec.min, spec.max), 3);
  }

  const goals: Record<string, number> = {};
  for (const [goal, base] of Object.entries(baseline.goals)) {
    const a = acc.get(`goals.${goal}`) ?? { add: 0, mul: 1 };
    goals[goal] = round(clamp((base + a.add) * a.mul, 0.02, 8), 3);
  }

  return { params, goals };
}

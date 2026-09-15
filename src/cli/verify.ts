import { loadDataset } from "../data/load";
import { generateNpc } from "../persona/generate";

/** Consistency gate over a large batch of rolls: no contradictory personas. */
function main(): void {
  const data = loadDataset();
  const total = Number(process.argv[2] ?? 3000);
  const problems: string[] = [];
  const traitUse = new Map<string, number>();

  for (let seed = 1; seed <= total; seed++) {
    const npc = generateNpc(data, { seed });
    const ids = new Set(npc.traits);

    for (const id of npc.traits) {
      traitUse.set(id, (traitUse.get(id) ?? 0) + 1);
      const trait = data.traitsById.get(id);
      if (!trait) {
        problems.push(`${npc.id}: unknown trait ${id}`);
        continue;
      }
      for (const ex of trait.excludes ?? []) {
        if (ids.has(ex)) problems.push(`${npc.id}: ${id} + ${ex} are mutually exclusive`);
      }
      for (const [axis, [min, max]] of Object.entries(trait.requires?.axes ?? {})) {
        const value = npc.axes[axis];
        if (value === undefined || value < min || value > max) {
          problems.push(`${npc.id}: ${id} requires ${axis} in [${min},${max}], got ${value}`);
        }
      }
    }

    if (npc.traitBudgetUsed > data.baseline.traitBudget) {
      problems.push(`${npc.id}: spent ${npc.traitBudgetUsed} of ${data.baseline.traitBudget} trait points`);
    }
    if (npc.traits.length < 3) problems.push(`${npc.id}: only ${npc.traits.length} traits`);

    for (const [key, spec] of Object.entries(data.baseline.params)) {
      const value = npc.params[key];
      if (value === undefined || value < spec.min - 1e-6 || value > spec.max + 1e-6) {
        problems.push(`${npc.id}: param ${key}=${value} outside [${spec.min},${spec.max}]`);
      }
    }
    if ((npc.params["perception.nightVision"] ?? 1) < 0.3 && npc.chronotype === "night") {
      problems.push(`${npc.id}: night chronotype with night vision ${npc.params["perception.nightVision"]}`);
    }
  }

  const unused = data.traits.filter((t) => !traitUse.has(t.id)).map((t) => t.id);
  console.log(`Tarkistettu ${total} NPC:tä, ${data.traits.length} traitia.`);
  console.log(`Käytössä ${traitUse.size}/${data.traits.length} traitia.`);
  if (unused.length > 0) console.log(`Ei koskaan valittu: ${unused.join(", ")}`);

  if (problems.length > 0) {
    console.error(`\nVIRHEET (${problems.length}):`);
    for (const p of problems.slice(0, 25)) console.error(` - ${p}`);
    process.exit(1);
  }
  console.log("Kaikki tarkistukset läpi.");
}

main();

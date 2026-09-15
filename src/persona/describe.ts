import { Dataset, Npc, TraitCategory } from "../core/types";

const CHRONOTYPE_FI: Record<Npc["chronotype"], string> = {
  early: "aamuvirkku",
  normal: "päiväaktiivinen",
  night: "yöaktiivinen",
};

const bar = (value: number, width = 10): string => {
  const filled = Math.round(clamp01(value) * width);
  return "#".repeat(filled) + ".".repeat(width - filled);
};

const clamp01 = (v: number): number => Math.max(0, Math.min(1, v));

function traitsOf(data: Dataset, npc: Npc, category: TraitCategory): string[] {
  return npc.traits
    .map((id) => data.traitsById.get(id))
    .filter((t): t is NonNullable<typeof t> => !!t && t.category === category)
    .map((t) => `${t.label}`);
}

/** Human-readable Finnish biography for tuning NPCs by eye. */
export function describeNpc(data: Dataset, npc: Npc, index?: number): string {
  const lines: string[] = [];
  const head = index === undefined ? "" : `#${index} `;
  lines.push(
    `${head}${npc.name} "${npc.callsign}" - ${npc.age} v, ${npc.sex === "male" ? "mies" : "nainen"}, ${npc.nationality}, ${npc.heightCm} cm / ${npc.weightKg} kg`,
  );
  lines.push(`  Arkkityyppi : ${npc.archetypeLabel}   Tausta: ${npc.backgroundLabel}   Rytmi: ${CHRONOTYPE_FI[npc.chronotype]}   Seed: ${npc.seed}`);

  const axisLine = Object.entries(npc.axes)
    .sort((a, b) => b[1] - a[1])
    .map(([axis, value]) => `${data.axes[axis]?.label ?? axis} ${value.toFixed(2)}`)
    .join("  ");
  lines.push(`  Persoona    : ${axisLine}`);

  const dominant = Object.entries(npc.axes).sort((a, b) => b[1] - a[1]).slice(0, 3);
  lines.push(
    `                ${dominant.map(([axis, v]) => `${data.axes[axis]?.label ?? axis} [${bar(v)}]`).join("  ")}`,
  );

  const groups: [string, TraitCategory][] = [
    ["Taistelu   ", "combat"],
    ["Fyysiset   ", "physical"],
    ["Sosiaaliset", "social"],
    ["Mielentila ", "mental"],
    ["Kvirkit    ", "quirk"],
    ["Heikkoudet ", "flaw"],
  ];
  for (const [label, category] of groups) {
    const items = traitsOf(data, npc, category);
    if (items.length > 0) lines.push(`  ${label} : ${items.join(", ")}`);
  }

  const topSkills = Object.entries(npc.skills)
    .filter(([, s]) => s.level > 0.3)
    .sort((a, b) => b[1].level - a[1].level)
    .slice(0, 6)
    .map(([skill, s]) => `${skill} ${s.level.toFixed(1)} (x${s.rate.toFixed(2)})`);
  lines.push(`  Skillit     : ${topSkills.length > 0 ? topSkills.join(", ") : "ei mitään mainittavaa"}`);

  const p = npc.params;
  lines.push(
    `  Havainto    : näkö ${Math.round(num(p["perception.visionRangeM"]))} m, kuulo ${Math.round(num(p["perception.hearingRangeM"]))} m, reaktio ${Math.round(num(p["perception.reactionTimeMs"]))} ms, yönäkö ${num(p["perception.nightVision"]).toFixed(2)}, virhehavainnot ${(num(p["perception.falsePositiveChance"]) * 100).toFixed(0)} %`,
  );
  lines.push(
    `  Taistelu    : etäisyys ${Math.round(num(p["combat.engageRangeMinM"]))}-${Math.round(num(p["combat.engageRangeMaxM"]))} m, tarkkuus ${num(p["combat.accuracyBase"]).toFixed(2)}, push ${num(p["combat.pushBias"]).toFixed(2)}, suoja ${num(p["combat.coverBias"]).toFixed(2)}, perääntyy ${(num(p["combat.retreatHealthPct"]) * 100).toFixed(0)} % HP:ssa`,
  );
  lines.push(
    `  Liike       : melu ${num(p["movement.noiseLevel"]).toFixed(2)}, kyykky ${num(p["movement.crouchBias"]).toFixed(2)}, tiet ${num(p["movement.roadBias"]).toFixed(2)}, nopeus ${num(p["movement.travelSpeedMul"]).toFixed(2)}, riskikynnys ${num(p["risk.threshold"]).toFixed(2)}`,
  );
  lines.push(
    `  Sosiaalinen : luottamus ${num(p["social.trustBase"]).toFixed(2)}, vihamielisyys ${num(p["social.hostilityBase"]).toFixed(2)}, armo ${num(p["social.mercyChance"]).toFixed(2)}, ryöstö ${num(p["social.robberyChance"]).toFixed(2)}, petos ${num(p["social.betrayalChance"]).toFixed(2)}, kauna ${num(p["social.grudgeDecayDays"]).toFixed(1)} vrk`,
  );

  const topGoals = Object.entries(npc.goals)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 6)
    .map(([goal, w]) => `${goal} ${w.toFixed(2)}`);
  lines.push(`  Tavoitteet  : ${topGoals.join(", ")}`);
  if (npc.flags.length > 0) lines.push(`  Liput       : ${npc.flags.join(", ")}`);
  if (npc.voice.length > 0) lines.push(`  Puhetyyli   : ${npc.voice.join(", ")}`);
  lines.push(`  Varustetoive: ${npc.loadout.prefer.join(", ") || "-"}`);
  lines.push(`  Traittipisteet käytetty: ${npc.traitBudgetUsed}/${data.baseline.traitBudget}`);
  return lines.join("\n");
}

const num = (v: number | undefined): number => v ?? 0;

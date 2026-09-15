import { loadDataset } from "../data/load";
import { generateNpc } from "../persona/generate";
import { describeNpc } from "../persona/describe";
import { Rng } from "../core/rng";

interface Args {
  count: number;
  seed?: number;
  archetype?: string;
  background?: string;
  json: boolean;
  stats: boolean;
}

function parseArgs(argv: string[]): Args {
  const args: Args = { count: 5, json: false, stats: false };
  for (let i = 0; i < argv.length; i++) {
    const key = argv[i];
    const value = argv[i + 1];
    switch (key) {
      case "--count": case "-n": args.count = Number(value); i++; break;
      case "--seed": case "-s": args.seed = Number(value); i++; break;
      case "--archetype": case "-a": args.archetype = value; i++; break;
      case "--background": case "-b": args.background = value; i++; break;
      case "--json": args.json = true; break;
      case "--stats": args.stats = true; break;
      case "--help": case "-h": printHelp(); process.exit(0);
      default:
        if (key?.startsWith("-")) {
          console.error(`Unknown option: ${key}`);
          printHelp();
          process.exit(1);
        }
    }
  }
  if (!Number.isFinite(args.count) || args.count < 1) throw new Error("--count must be >= 1");
  return args;
}

function printHelp(): void {
  console.log(`Usage: npm run roll -- [options]

  -n, --count <n>        how many NPCs to roll (default 5)
  -s, --seed <n>         base seed for reproducible rolls
  -a, --archetype <id>   force an archetype
  -b, --background <id>  force a background
      --json             print raw JSON instead of biographies
      --stats            print distribution stats over the rolled batch`);
}

function main(): void {
  const args = parseArgs(process.argv.slice(2));
  const data = loadDataset();
  const base = args.seed ?? Math.floor(Math.random() * 0xffffffff);
  const rng = new Rng(base);

  const npcs = Array.from({ length: args.count }, () =>
    generateNpc(data, {
      seed: rng.int(1, 0xfffffff),
      ...(args.archetype ? { archetype: args.archetype } : {}),
      ...(args.background ? { background: args.background } : {}),
    }),
  );

  if (args.json) {
    console.log(JSON.stringify(npcs, null, 2));
  } else {
    console.log(`Rullattu ${npcs.length} NPC:tä (base seed ${base})\n`);
    npcs.forEach((npc, i) => console.log(describeNpc(data, npc, i + 1) + "\n"));
  }

  if (args.stats) printStats(npcs);
}

function printStats(npcs: ReturnType<typeof generateNpc>[]): void {
  const count = (values: string[]): string =>
    Object.entries(values.reduce<Record<string, number>>((acc, v) => {
      acc[v] = (acc[v] ?? 0) + 1;
      return acc;
    }, {}))
      .sort((a, b) => b[1] - a[1])
      .slice(0, 12)
      .map(([k, n]) => `${k} ${n}`)
      .join(", ");

  console.log("--- jakaumat ---");
  console.log(`arkkityypit : ${count(npcs.map((n) => n.archetypeLabel))}`);
  console.log(`taustat     : ${count(npcs.map((n) => n.backgroundLabel))}`);
  console.log(`traitit     : ${count(npcs.flatMap((n) => n.traits))}`);
  console.log(`rytmit      : ${count(npcs.map((n) => n.chronotype))}`);
  const avgTraits = npcs.reduce((s, n) => s + n.traits.length, 0) / npcs.length;
  console.log(`traitteja/NPC keskimäärin: ${avgTraits.toFixed(2)}`);
}

main();

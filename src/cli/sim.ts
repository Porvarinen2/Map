import { Rng } from "../core/rng";
import { loadDataset } from "../data/load";
import { generateNpc } from "../persona/generate";
import { loadMap } from "../world/map";
import { AgentState, Activity } from "../brain/state";
import { SimEvent, spawnAgent, tick } from "../brain/tick";

interface Args {
  agents: number;
  days: number;
  seed: number;
  log: boolean;
  agentLog?: number;
}

function parseArgs(argv: string[]): Args {
  const args: Args = { agents: 6, days: 2, seed: 1, log: false };
  for (let i = 0; i < argv.length; i++) {
    const value = argv[i + 1];
    switch (argv[i]) {
      case "--agents": case "-n": args.agents = Number(value); i++; break;
      case "--days": case "-d": args.days = Number(value); i++; break;
      case "--seed": case "-s": args.seed = Number(value); i++; break;
      case "--log": args.log = true; break;
      case "--agent-log": args.agentLog = Number(value); i++; break;
      case "--help": case "-h":
        console.log(`Usage: npm run sim -- [-n agents] [-d days] [-s seed] [--log] [--agent-log <index>]`);
        process.exit(0);
    }
  }
  return args;
}

function main(): void {
  const args = parseArgs(process.argv.slice(2));
  const data = loadDataset();
  const map = loadMap();
  const rng = new Rng(args.seed);

  const agents: AgentState[] = [];
  for (let i = 0; i < args.agents; i++) {
    const npc = generateNpc(data, { seed: rng.int(1, 0xfffffff) });
    agents.push(spawnAgent(npc, map, new Rng(npc.seed)));
  }

  const events: SimEvent[] = [];
  const minutes = args.days * 1440;
  for (let minute = 0; minute < minutes; minute++) {
    for (const agent of agents) {
      tick(agent, map, new Rng(agent.npc.seed + minute * 7919), minute, events);
    }
  }

  if (args.log) {
    for (const event of events) console.log(event.text);
  } else if (args.agentLog !== undefined) {
    const agent = agents[args.agentLog];
    if (!agent) throw new Error(`No agent #${args.agentLog}`);
    console.log(`${agent.npc.name} - ${agent.npc.archetypeLabel} / ${agent.npc.backgroundLabel}\n`);
    for (const line of agent.log) console.log("  " + line);
    console.log("");
  }

  console.log(`Simuloitu ${args.days} vrk x ${agents.length} NPC (seed ${args.seed})\n`);
  for (const agent of agents) summarize(agent, args.days);
}

function summarize(agent: AgentState, days: number): void {
  const total = days * 1440;
  const spent = Object.entries(agent.timeSpent)
    .filter(([, m]) => m > 0)
    .sort((a, b) => b[1] - a[1])
    .map(([activity, m]) => `${activity} ${((m / total) * 100).toFixed(0)}%`)
    .join("  ");
  const n = agent.needs;
  console.log(
    `${agent.npc.name.padEnd(22)} ${agent.npc.archetypeLabel.padEnd(22)} tier ${agent.inventory.gearTier} ` +
    `base ${(agent.baseProgress * 100).toFixed(0)}% tapot ${agent.kills} kuolemat ${agent.deaths} ` +
    `HP ${(agent.health * 100).toFixed(0)}%`,
  );
  console.log(`  vrk: ${spent}`);
  console.log(
    `  tarpeet: nälkä ${n.hunger.toFixed(2)} jano ${n.thirst.toFixed(2)} uupumus ${n.fatigue.toFixed(2)} stressi ${n.stress.toFixed(2)} ` +
    `| koti ${agent.homePoi ?? "-"} | muistettu ${agent.memory.size} paikkaa`,
  );
}

main();

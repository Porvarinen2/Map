import * as net from "net";
import { ServerMsg } from "../server/protocol";

/** Fake in-game client: spawns agents, feeds sense data, prints decisions. */
function main(): void {
  const port = Number(process.argv[2] ?? 7771);
  const agents = Number(process.argv[3] ?? 3);
  const socket = net.createConnection({ port, host: "127.0.0.1" });
  let buffer = "";
  let minute = 6 * 60;
  let ticks = 0;

  const send = (msg: unknown): void => {
    socket.write(JSON.stringify(msg) + "\n");
  };

  socket.on("connect", () => {
    send({ t: "hello", version: 1, server: "test" });
    for (let i = 0; i < agents; i++) {
      send({ t: "spawn", agentId: `a${i}`, seed: 1000 + i, x: 1100, y: 9400 });
    }
    const timer = setInterval(() => {
      minute = (minute + 15) % 1440;
      ticks += 1;
      for (let i = 0; i < agents; i++) {
        send({
          t: "sense",
          agentId: `a${i}`,
          minute,
          x: 1100 + i * 50,
          y: 9400,
          health: 1,
          contacts: ticks % 5 === 0 ? [{ kind: "puppet", x: 1150, y: 9400, distM: 40 }] : [],
        });
      }
      if (ticks >= 8) {
        clearInterval(timer);
        setTimeout(() => socket.end(), 300);
      }
    }, 120);
  });

  socket.on("data", (chunk) => {
    buffer += chunk.toString("utf8");
    let i = buffer.indexOf("\n");
    while (i >= 0) {
      const line = buffer.slice(0, i).trim();
      buffer = buffer.slice(i + 1);
      if (line) {
        const msg = JSON.parse(line) as ServerMsg;
        if (msg.t === "spawned") {
          console.log(`spawned ${msg.agentId}: ${msg.persona.name} (${msg.persona.archetype}) traits=${msg.persona.traits.length}`);
        } else if (msg.t === "decision") {
          console.log(`${msg.agentId} -> ${msg.action.padEnd(8)} ${msg.goal.padEnd(8)} ${msg.target?.label ?? ""} | ${msg.reason}`);
        } else if (msg.t === "error") {
          console.error(`error: ${msg.message}`);
        }
      }
      i = buffer.indexOf("\n");
    }
  });

  socket.on("error", (err) => {
    console.error(`client error: ${err.message}`);
    process.exit(1);
  });
}

main();

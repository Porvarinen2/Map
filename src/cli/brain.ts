import { BrainService } from "../server/brainServer";

const argv = process.argv.slice(2);
const read = (flag: string, fallback: string): string => {
  const i = argv.indexOf(flag);
  return i >= 0 && argv[i + 1] ? (argv[i + 1] as string) : fallback;
};

const service = new BrainService({
  port: Number(read("--port", "7771")),
  host: read("--host", "127.0.0.1"),
  verbose: !argv.includes("--quiet"),
});
service.listen();

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    service.close();
    process.exit(0);
  });
}

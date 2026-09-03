import { EventEmitter } from "node:events";
import { EngineClient } from "./client";

interface ManagedProcess {
  stdin: Bun.FileSink;
  stdout: ReadableStream<Uint8Array>;
  exited: Promise<number>;
  kill(signal?: number | NodeJS.Signals): void;
}

type SpawnEngine = () => ManagedProcess;

export class EngineSupervisor extends EventEmitter {
  client: EngineClient | null = null;
  private process: ManagedProcess | null = null;
  private stopping = false;
  private generation = 0;
  private failures = 0;

  constructor(private readonly spawnEngine: SpawnEngine = defaultSpawn) {
    super();
  }

  start(): void {
    if (this.process || this.stopping) return;
    this.launch();
  }

  async stop(): Promise<void> {
    this.stopping = true;
    this.generation++;
    const process = this.process;
    this.process = null;
    this.client?.close("Application is shutting down");
    this.client = null;
    if (!process) return;
    try {
      process.stdin.end();
      const timeout = Bun.sleep(1_000).then(() => null);
      const exited = await Promise.race([process.exited, timeout]);
      if (exited === null) process.kill("SIGTERM");
    } catch {
      process.kill("SIGTERM");
    }
  }

  private launch(): void {
    const generation = ++this.generation;
    this.emit("status", this.failures ? "restarting" : "starting");
    let process: ManagedProcess;
    try {
      process = this.spawnEngine();
    } catch (error) {
      this.scheduleRestart(generation, error);
      return;
    }
    this.process = process;
    const client = new EngineClient({ write: (line) => void process.stdin.write(line) });
    this.client = client;
    client.on("protocolError", (error) => this.emit("protocolError", error));
    client.on("event", (event, data) => this.emit("event", event, data));
    this.readLines(process.stdout, client, generation);
    process.exited.then((code) => {
      if (this.stopping || generation !== this.generation) return;
      this.process = null;
      client.close(`Engine exited with status ${code}`);
      if (this.client === client) this.client = null;
      this.scheduleRestart(generation, new Error(`Engine exited with status ${code}`));
    });
    this.emit("ready", client);
    this.emit("status", "online");
  }

  private async readLines(
    stream: ReadableStream<Uint8Array>,
    client: EngineClient,
    generation: number,
  ): Promise<void> {
    const reader = stream.getReader();
    const decoder = new TextDecoder();
    let buffer = "";
    try {
      while (!this.stopping && generation === this.generation) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split("\n");
        buffer = lines.pop() ?? "";
        for (const line of lines) client.acceptLine(line.replace(/\r$/, ""));
      }
      if (buffer.trim()) client.acceptLine(buffer);
    } finally {
      reader.releaseLock();
    }
  }

  private scheduleRestart(generation: number, error: unknown): void {
    if (this.stopping || generation !== this.generation) return;
    this.failures++;
    const delay = Math.min(10_000, 250 * 2 ** Math.min(this.failures - 1, 6));
    this.emit("status", "restarting", error instanceof Error ? error.message : String(error));
    setTimeout(() => {
      if (!this.stopping && generation === this.generation) this.launch();
    }, delay);
  }
}

function defaultSpawn(): ManagedProcess {
  const executable = process.env.AUDIBLE_ENGINE ?? "audible-zig";
  return Bun.spawn([executable, "internal", "rpc"], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "inherit",
    env: { ...process.env },
  }) as ManagedProcess;
}

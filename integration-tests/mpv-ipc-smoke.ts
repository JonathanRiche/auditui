import { chmod, lstat, mkdtemp, rm } from "node:fs/promises";
import { rmSync } from "node:fs";
import { createConnection, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

type IpcMessage = {
  request_id?: number;
  error?: string;
  data?: unknown;
  event?: string;
  name?: string;
};

const mpv = process.env.MPV ?? "mpv";
const privateDir = await mkdtemp(join(tmpdir(), "audible-tui-mpv-"));
await chmod(privateDir, 0o700);
const socketPath = join(privateDir, "ipc.sock");
const tonePath = join(privateDir, "synthetic-tone.wav");
if (socketPath.length >= 100) throw new Error("temporary mpv socket path is too long");

let child: ReturnType<typeof Bun.spawn> | undefined;
let socket: Socket | undefined;

function emergencyCleanup(signal: NodeJS.Signals): void {
  socket?.destroy();
  child?.kill("SIGTERM");
  // The directory was returned directly by mkdtemp with a fixed private prefix.
  rmSync(privateDir, { recursive: true, force: true });
  process.removeAllListeners(signal);
  process.kill(process.pid, signal);
}

process.once("SIGINT", emergencyCleanup);
process.once("SIGTERM", emergencyCleanup);

try {
  const generator = Bun.spawn(
    [
      mpv,
      "--no-config",
      "--terminal=no",
      "--video=no",
      `--o=${tonePath}`,
      "--of=wav",
      "--oac=pcm_s16le",
      "--length=3",
      "av://lavfi:sine=frequency=440:sample_rate=48000",
    ],
    { stdin: "ignore", stdout: "ignore", stderr: "pipe" },
  );
  const generatorExit = await generator.exited;
  if (generatorExit !== 0) {
    const stderr = await new Response(generator.stderr).text();
    throw new Error(`mpv could not generate the lavfi tone: ${stderr.trim()}`);
  }

  child = Bun.spawn(
    [
      mpv,
      "--no-config",
      "--idle=yes",
      "--pause=yes",
      "--keep-open=yes",
      "--terminal=no",
      "--no-input-default-bindings",
      "--ao=null",
      "--video=no",
      `--input-ipc-server=${socketPath}`,
      tonePath,
    ],
    { stdin: "ignore", stdout: "ignore", stderr: "pipe" },
  );

  socket = await connectWithRetry(socketPath, child);
  const ipc = makeIpc(socket);

  const socketStat = await lstat(socketPath);
  if (!socketStat.isSocket()) throw new Error("mpv IPC path is not a Unix socket");

  const version = await ipc.command(["get_property", "mpv-version"]);
  if (typeof version !== "string" || version.length === 0) {
    throw new Error("mpv did not report its version over JSON IPC");
  }

  await ipc.command(["observe_property", 1, "pause"]);
  const duration = await pollProperty(
    ipc,
    "duration",
    (value) => typeof value === "number" && value >= 2.9,
  );
  if (typeof duration !== "number") throw new Error("synthetic tone has no duration");

  if ((await ipc.command(["get_property", "pause"])) !== true) {
    throw new Error("mpv did not start the synthetic tone paused");
  }

  await ipc.command(["set_property", "pause", false]);
  await ipc.waitForEvent(
    (message) =>
      message.event === "property-change" && message.name === "pause" && message.data === false,
  );
  await pollProperty(ipc, "time-pos", (value) => typeof value === "number" && value > 0.05);

  await ipc.command(["seek", 0.5, "absolute+exact"]);
  await pollProperty(ipc, "time-pos", (value) => typeof value === "number" && value >= 0.4);

  await ipc.command(["set_property", "speed", 1.25]);
  const speed = await ipc.command(["get_property", "speed"]);
  if (typeof speed !== "number" || Math.abs(speed - 1.25) > 0.001) {
    throw new Error(`unexpected playback speed ${String(speed)}`);
  }

  await ipc.command(["set_property", "pause", true]);
  await ipc.command(["quit"]);
  socket.end();

  const exitCode = await Promise.race([
    child.exited,
    timeout(5_000, "mpv did not exit after the IPC quit command"),
  ]);
  if (exitCode !== 0) {
    const stderr = await new Response(child.stderr).text();
    throw new Error(`mpv exited ${exitCode}: ${stderr.trim()}`);
  }

  console.log(`mpv JSON IPC smoke test passed (${version}, synthetic lavfi tone)`);
} finally {
  socket?.destroy();
  if (child && child.exitCode === null) child.kill("SIGKILL");
  await rm(privateDir, { recursive: true, force: true });
  process.removeListener("SIGINT", emergencyCleanup);
  process.removeListener("SIGTERM", emergencyCleanup);
}

async function connectWithRetry(
  path: string,
  processHandle: ReturnType<typeof Bun.spawn>,
): Promise<Socket> {
  const deadline = Date.now() + 5_000;
  let lastError: unknown;
  while (Date.now() < deadline) {
    if (processHandle.exitCode !== null) {
      const stderr = await new Response(processHandle.stderr).text();
      throw new Error(`mpv exited before IPC was ready: ${stderr.trim()}`);
    }
    try {
      return await new Promise<Socket>((resolve, reject) => {
        const candidate = createConnection({ path });
        candidate.once("connect", () => resolve(candidate));
        candidate.once("error", reject);
      });
    } catch (error) {
      lastError = error;
      await Bun.sleep(25);
    }
  }
  throw new Error(`mpv IPC socket was not ready: ${String(lastError)}`);
}

function makeIpc(connection: Socket) {
  let nextId = 1;
  let buffer = "";
  const pending = new Map<
    number,
    { resolve: (value: unknown) => void; reject: (error: Error) => void }
  >();
  const events: IpcMessage[] = [];
  const eventWaiters: Array<{
    predicate: (message: IpcMessage) => boolean;
    resolve: (message: IpcMessage) => void;
  }> = [];

  connection.setEncoding("utf8");
  connection.on("data", (chunk: string) => {
    buffer += chunk;
    while (true) {
      const newline = buffer.indexOf("\n");
      if (newline < 0) break;
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      if (!line) continue;
      const message = JSON.parse(line) as IpcMessage;
      if (message.request_id !== undefined) {
        const waiter = pending.get(message.request_id);
        if (!waiter) continue;
        pending.delete(message.request_id);
        if (message.error === "success") waiter.resolve(message.data);
        else waiter.reject(new Error(`mpv IPC error: ${message.error ?? "unknown"}`));
        continue;
      }
      const waiterIndex = eventWaiters.findIndex(({ predicate }) => predicate(message));
      if (waiterIndex >= 0) eventWaiters.splice(waiterIndex, 1)[0]!.resolve(message);
      else events.push(message);
    }
  });
  connection.on("error", (error) => {
    for (const waiter of pending.values()) waiter.reject(error);
    pending.clear();
  });

  return {
    command(command: unknown[]): Promise<unknown> {
      const requestId = nextId++;
      return Promise.race([
        new Promise<unknown>((resolve, reject) => {
          pending.set(requestId, { resolve, reject });
          connection.write(`${JSON.stringify({ command, request_id: requestId })}\n`);
        }),
        timeout(3_000, `mpv IPC command timed out: ${String(command[0])}`),
      ]);
    },
    waitForEvent(predicate: (message: IpcMessage) => boolean): Promise<IpcMessage> {
      const existing = events.findIndex(predicate);
      if (existing >= 0) return Promise.resolve(events.splice(existing, 1)[0]!);
      return Promise.race([
        new Promise<IpcMessage>((resolve) => eventWaiters.push({ predicate, resolve })),
        timeout(3_000, "mpv IPC event timed out"),
      ]);
    },
  };
}

async function pollProperty(
  ipc: ReturnType<typeof makeIpc>,
  name: string,
  predicate: (value: unknown) => boolean,
): Promise<unknown> {
  const deadline = Date.now() + 3_000;
  let value: unknown;
  while (Date.now() < deadline) {
    try {
      value = await ipc.command(["get_property", name]);
    } catch (error) {
      // Properties are temporarily unavailable while mpv finishes loading.
      value = error;
    }
    if (predicate(value)) return value;
    await Bun.sleep(25);
  }
  throw new Error(`mpv property ${name} did not reach expected state: ${String(value)}`);
}

function timeout<T = never>(milliseconds: number, message: string): Promise<T> {
  return new Promise((_, reject) => setTimeout(() => reject(new Error(message)), milliseconds));
}

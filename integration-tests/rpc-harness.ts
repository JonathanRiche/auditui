import { chmod, mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

export type RpcMessage = {
  v: number;
  id?: string;
  ok?: boolean;
  result?: Record<string, unknown>;
  error?: { code?: string; message?: string };
  event?: string;
  data?: Record<string, unknown>;
};

type Waiter = {
  predicate: (message: RpcMessage) => boolean;
  resolve: (message: RpcMessage) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
};

export class RpcHarness {
  readonly sandbox: string;
  readonly stateDir: string;
  readonly child: ReturnType<typeof Bun.spawn>;
  readonly messages: RpcMessage[] = [];
  #buffer = "";
  #stderr = "";
  #waiters: Waiter[] = [];
  #nextId = 1;
  #stdoutDone: Promise<void>;

  private constructor(sandbox: string, child: ReturnType<typeof Bun.spawn>) {
    this.sandbox = sandbox;
    this.stateDir = join(sandbox, "state");
    this.child = child;

    this.#stdoutDone = this.#readStdout();
    void this.#readStderr();
  }

  static async start(prefix: string): Promise<RpcHarness> {
    const sandbox = await mkdtemp(join(tmpdir(), prefix));
    await chmod(sandbox, 0o700);
    for (const name of ["home", "config", "data", "state", "cache"]) {
      await mkdir(join(sandbox, name), { recursive: true, mode: 0o700 });
    }

    return RpcHarness.resume(sandbox);
  }

  static async resume(sandbox: string): Promise<RpcHarness> {
    const engine = resolve(process.env.AUDIBLE_ENGINE ?? "engine/zig-out/bin/audible-zig");
    const child = Bun.spawn([engine, "internal", "rpc"], {
      stdin: "pipe",
      stdout: "pipe",
      stderr: "pipe",
      env: compactEnvironment({
        HOME: join(sandbox, "home"),
        TMPDIR: sandbox,
        AUDIBLE_CONFIG_DIR: join(sandbox, "config"),
        AUDIBLE_DATA_DIR: join(sandbox, "data"),
        AUDIBLE_STATE_DIR: join(sandbox, "state"),
        AUDIBLE_CACHE_DIR: join(sandbox, "cache"),
      }),
    });
    return new RpcHarness(sandbox, child);
  }

  async request(method: string, params: Record<string, unknown> = {}): Promise<RpcMessage> {
    const id = `e2e-${this.#nextId++}`;
    this.child.stdin.write(`${JSON.stringify({ v: 1, id, method, params })}\n`);
    return this.waitFor((message) => message.id === id, 5_000, `RPC response for ${method}`);
  }

  waitFor(
    predicate: (message: RpcMessage) => boolean,
    milliseconds = 5_000,
    label = "RPC message",
  ): Promise<RpcMessage> {
    const existing = this.messages.find(predicate);
    if (existing) return Promise.resolve(existing);
    return new Promise((resolve, reject) => {
      const waiter: Waiter = {
        predicate,
        resolve,
        reject,
        timer: setTimeout(() => {
          const index = this.#waiters.indexOf(waiter);
          if (index >= 0) this.#waiters.splice(index, 1);
          reject(new Error(`${label} timed out after ${milliseconds}ms`));
        }, milliseconds),
      };
      this.#waiters.push(waiter);
    });
  }

  async close(): Promise<void> {
    this.child.stdin.end();
    let exitTimer: ReturnType<typeof setTimeout> | undefined;
    const exitCode = await Promise.race([
      this.child.exited,
      new Promise<never>((_, reject) => {
        exitTimer = setTimeout(
          () => reject(new Error("engine did not exit after stdin closed")),
          5_000,
        );
      }),
    ])
      .catch((error) => {
        if (this.child.exitCode === null) this.child.kill("SIGKILL");
        throw error;
      })
      .finally(() => clearTimeout(exitTimer));
    if (exitCode !== 0) throw new Error(`engine exited ${exitCode}: ${this.#stderr.trim()}`);
    await Promise.race([
      this.#stdoutDone,
      Bun.sleep(1_000).then(() => {
        throw new Error("engine stdout remained open after RPC shutdown");
      }),
    ]);
    if (this.#stderr.trim() !== "") {
      throw new Error(`engine emitted diagnostics: ${this.#stderr.trim()}`);
    }
  }

  async cleanup(): Promise<void> {
    if (this.child.exitCode === null) this.child.kill("SIGKILL");
    for (const waiter of this.#waiters) {
      clearTimeout(waiter.timer);
      waiter.reject(new Error("RPC harness was cleaned up"));
    }
    this.#waiters.length = 0;
    await rm(this.sandbox, { recursive: true, force: true });
  }

  async #readStdout(): Promise<void> {
    const reader = this.child.stdout.getReader();
    const decoder = new TextDecoder();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      this.#buffer += decoder.decode(value, { stream: true });
      while (true) {
        const newline = this.#buffer.indexOf("\n");
        if (newline < 0) break;
        const line = this.#buffer.slice(0, newline);
        this.#buffer = this.#buffer.slice(newline + 1);
        if (!line) continue;
        let message: RpcMessage;
        try {
          message = JSON.parse(line) as RpcMessage;
          validateEnvelope(message);
        } catch (error) {
          this.#failWaiters(new Error(`engine stdout violated protocol v1: ${String(error)}`));
          continue;
        }
        this.messages.push(message);
        const index = this.#waiters.findIndex(({ predicate }) => predicate(message));
        if (index >= 0) {
          const waiter = this.#waiters.splice(index, 1)[0]!;
          clearTimeout(waiter.timer);
          waiter.resolve(message);
        }
      }
    }
  }

  async #readStderr(): Promise<void> {
    this.#stderr = await new Response(this.child.stderr).text();
  }

  #failWaiters(error: Error): void {
    for (const waiter of this.#waiters) {
      clearTimeout(waiter.timer);
      waiter.reject(error);
    }
    this.#waiters.length = 0;
  }
}

export function assertOk(message: RpcMessage, label: string): Record<string, unknown> {
  if (message.v !== 1 || message.ok !== true || !message.result) {
    throw new Error(`${label} failed: ${JSON.stringify(message)}`);
  }
  return message.result;
}

function compactEnvironment(overrides: Record<string, string>): Record<string, string> {
  const environment: Record<string, string> = { ...overrides };
  // mpv needs the runtime directory to reach the user's PipeWire/Pulse socket.
  // The RPC sandbox still owns all Audible application and credential paths.
  for (const name of ["PATH", "LANG", "LC_ALL", "TZ", "XDG_RUNTIME_DIR"]) {
    const value = process.env[name];
    if (value !== undefined) environment[name] = value;
  }
  return environment;
}

function validateEnvelope(message: RpcMessage): void {
  if (!message || typeof message !== "object" || message.v !== 1) {
    throw new Error("message must be a protocol-v1 object");
  }
  if (typeof message.event === "string") {
    assertExactKeys(message, ["data", "event", "v"], "event envelope");
    if (!message.data || typeof message.data !== "object")
      throw new Error("event data must be an object");
    return;
  }
  if (
    typeof message.id !== "string" ||
    message.id.length === 0 ||
    typeof message.ok !== "boolean"
  ) {
    throw new Error("response must contain a non-empty id and boolean ok");
  }
  if (message.ok) {
    assertExactKeys(message, ["id", "ok", "result", "v"], "success envelope");
    if (!("result" in message)) throw new Error("successful response must contain result");
  } else {
    assertExactKeys(message, ["error", "id", "ok", "v"], "failure envelope");
    if (
      !message.error ||
      typeof message.error.code !== "string" ||
      typeof message.error.message !== "string"
    ) {
      throw new Error("failed response must contain a structured error");
    }
  }
}

function assertExactKeys(value: object, expected: string[], label: string): void {
  const actual = Object.keys(value).sort();
  const wanted = [...expected].sort();
  if (JSON.stringify(actual) !== JSON.stringify(wanted)) {
    throw new Error(
      `${label} keys ${JSON.stringify(actual)} do not match ${JSON.stringify(wanted)}`,
    );
  }
}

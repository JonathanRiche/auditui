import { chmod, mkdir, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

type RpcResponse = {
  v: number;
  id: string;
  ok: boolean;
  result?: Record<string, unknown>;
  error?: Record<string, unknown>;
};

const engine = resolve(process.env.AUDIBLE_ENGINE ?? "engine/zig-out/bin/audible-zig");
const sandbox = await mkdtemp(join(tmpdir(), "audible-tui-rpc-"));
await chmod(sandbox, 0o700);
const cacheDir = join(sandbox, "cache");
await mkdir(cacheDir, { recursive: true, mode: 0o700 });
await Bun.write(
  join(cacheDir, "library.json"),
  Bun.file("integration-tests/fixtures/library.json"),
);

let child: ReturnType<typeof Bun.spawn> | undefined;
try {
  child = Bun.spawn([engine, "internal", "rpc"], {
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    env: compactEnvironment({
      HOME: join(sandbox, "home"),
      TMPDIR: sandbox,
      AUDIBLE_CONFIG_DIR: join(sandbox, "config"),
      AUDIBLE_DATA_DIR: join(sandbox, "data"),
      AUDIBLE_STATE_DIR: join(sandbox, "state"),
      AUDIBLE_CACHE_DIR: cacheDir,
    }),
  });

  child.stdin.write(
    `${JSON.stringify({ v: 1, id: "smoke-1", method: "health", params: {} })}\n` +
      `${JSON.stringify({ v: 1, id: "smoke-2", method: "library.search", params: { query: "clockwork" } })}\n`,
  );
  child.stdin.end();

  const [output, stderr, exitCode] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  if (exitCode !== 0) throw new Error(`engine exited ${exitCode}: ${stderr.trim()}`);
  if (stderr.trim() !== "")
    throw new Error(`engine emitted diagnostics during smoke test: ${stderr.trim()}`);

  const messages = output
    .split("\n")
    .filter(Boolean)
    .map((line, index) => {
      try {
        return JSON.parse(line) as RpcResponse;
      } catch (error) {
        throw new Error(`stdout line ${index + 1} is not JSON: ${String(error)}`);
      }
    });
  if (messages.length !== 2)
    throw new Error(`expected exactly 2 responses, got ${messages.length}: ${output}`);

  const health = onlyResponse(messages, "smoke-1");
  assertExactKeys(health, ["id", "ok", "result", "v"], "health response");
  if (health.v !== 1 || health.ok !== true || !health.result) {
    throw new Error(`invalid health envelope: ${JSON.stringify(health)}`);
  }
  assertExactKeys(health.result, ["engineVersion", "protocolVersion", "status"], "health result");
  if (
    health.result.protocolVersion !== 1 ||
    health.result.engineVersion !== "0.3.0" ||
    health.result.status !== "ok"
  ) {
    throw new Error(`unexpected health result: ${JSON.stringify(health.result)}`);
  }

  const search = onlyResponse(messages, "smoke-2");
  assertExactKeys(search, ["id", "ok", "result", "v"], "library.search response");
  if (search.v !== 1 || search.ok !== true || !search.result) {
    throw new Error(`invalid search envelope: ${JSON.stringify(search)}`);
  }
  const items = search.result.items;
  if (!Array.isArray(items) || items.length !== 1) {
    throw new Error(`expected one cached search result: ${JSON.stringify(search.result)}`);
  }
  const item = items[0] as Record<string, unknown>;
  if (
    item.id !== "synthetic-b001" ||
    item.asin !== "B000SYNTH1" ||
    item.title !== "The Clockwork Library" ||
    search.result.nextCursor !== null
  ) {
    throw new Error(`cached search result was not preserved: ${JSON.stringify(search.result)}`);
  }

  console.log("Zig RPC health and cached-library smoke tests passed in an isolated sandbox");
} finally {
  if (child?.exitCode === null) child.kill("SIGKILL");
  await rm(sandbox, { recursive: true, force: true });
}

function onlyResponse(messages: RpcResponse[], id: string): RpcResponse {
  const matching = messages.filter((message) => message.id === id);
  if (matching.length !== 1) {
    throw new Error(`expected exactly one response for ${id}, got ${matching.length}`);
  }
  return matching[0]!;
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

function compactEnvironment(overrides: Record<string, string>): Record<string, string> {
  const environment: Record<string, string> = { ...overrides };
  for (const name of ["PATH", "LANG", "LC_ALL", "TZ"]) {
    const value = process.env[name];
    if (value !== undefined) environment[name] = value;
  }
  return environment;
}

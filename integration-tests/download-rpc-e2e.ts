import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { assertOk, RpcHarness } from "./rpc-harness";

const rpc = await RpcHarness.start("audible-tui-download-e2e-");
const sourcePath = join(rpc.sandbox, "source payload.aaxc");
const outputDir = join(rpc.sandbox, "downloads");
const destination = join(outputDir, "source payload.aaxc");
const partial = `${destination}.part`;
const payload = deterministicPayload(256 * 1024 + 37);
const resumeAt = 73_019;

try {
  await mkdir(outputDir, { recursive: true, mode: 0o700 });
  await writeFile(sourcePath, payload);
  await writeFile(partial, payload.subarray(0, resumeAt));

  const result = assertOk(
    await rpc.request("downloads.start", {
      itemId: "synthetic-download-e2e",
      localPath: sourcePath,
      outputDir,
    }),
    "downloads.start",
  );
  if (result.jobId !== "synthetic-download-e2e" || result.state !== "queued") {
    throw new Error(`unexpected queued download: ${JSON.stringify(result)}`);
  }

  const state = await pollJob(rpc, "synthetic-download-e2e", "completed");
  if (state.path !== destination || state.received !== payload.length) {
    throw new Error(`unexpected durable job state: ${JSON.stringify(state)}`);
  }

  const actual = await readFile(destination);
  if (!actual.equals(payload)) throw new Error("resumed local download bytes differ from source");
  try {
    await stat(partial);
    throw new Error("completed download retained its .part file");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }

  const listed = assertOk(await rpc.request("downloads.list"), "downloads.list");
  if (!Array.isArray(listed.jobs) || listed.jobs.length !== 1) {
    throw new Error(`completed download was not listed: ${JSON.stringify(listed)}`);
  }
  const job = listed.jobs[0] as Record<string, unknown>;
  if (job.jobId !== "synthetic-download-e2e" || job.received !== payload.length) {
    throw new Error(`listed job is inconsistent: ${JSON.stringify(job)}`);
  }
  const databasePath = join(rpc.stateDir, "audible-tui.db");
  const mirrored = querySqlite(
    databasePath,
    "SELECT (SELECT count(*) FROM profiles)||'|'||(SELECT count(*) FROM library_items)||'|'||(SELECT count(*) FROM local_files)||'|'||(SELECT count(*) FROM download_jobs)||'|'||(SELECT status FROM download_jobs WHERE id='synthetic-download-e2e');",
  );
  if (mirrored !== "1|1|1|1|completed") {
    throw new Error(`SQLite download mirror is inconsistent: ${mirrored}`);
  }

  await rpc.close();
  const restarted = await RpcHarness.resume(rpc.sandbox);
  const afterRestart = assertOk(
    await restarted.request("downloads.list"),
    "downloads.list after restart",
  );
  const restored = (afterRestart.jobs as Array<Record<string, unknown>>)[0];
  if (
    restored?.jobId !== "synthetic-download-e2e" ||
    restored.state !== "completed" ||
    restored.received !== payload.length
  ) {
    throw new Error(`persistent job was not restored: ${JSON.stringify(afterRestart)}`);
  }
  await restarted.close();
  console.log(
    `download RPC e2e passed (async persistent job, resumed local .part at ${resumeAt} bytes, atomic completion)`,
  );
} finally {
  await rpc.cleanup();
}

async function pollJob(
  harness: RpcHarness,
  jobId: string,
  wanted: string,
): Promise<Record<string, unknown>> {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    const result = assertOk(await harness.request("downloads.list"), "downloads.list poll");
    const job = (result.jobs as Array<Record<string, unknown>>).find(
      (candidate) => candidate.jobId === jobId,
    );
    if (job?.state === wanted) return job;
    await Bun.sleep(15);
  }
  throw new Error(`durable download job ${jobId} did not reach ${wanted}`);
}

function deterministicPayload(length: number): Uint8Array {
  const bytes = new Uint8Array(length);
  for (let index = 0; index < bytes.length; index++) bytes[index] = (index * 31 + 17) & 0xff;
  return bytes;
}

function querySqlite(path: string, sql: string): string {
  const result = Bun.spawnSync(["sqlite3", "-batch", "-bail", path, sql]);
  if (result.exitCode !== 0) {
    throw new Error(`sqlite3 query failed: ${result.stderr.toString().trim()}`);
  }
  return result.stdout.toString().trim();
}

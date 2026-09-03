import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { assertOk, RpcHarness } from "./rpc-harness";

let rpc = await RpcHarness.start("audible-tui-download-cancel-");
const sourcePath = join(rpc.sandbox, "large.aaxc");
const outputDir = join(rpc.sandbox, "downloads");
const destination = join(outputDir, "large.aaxc");
const payload = new Uint8Array(24 * 1024 * 1024);
for (let index = 0; index < payload.length; index++) payload[index] = index & 0xff;

try {
  await mkdir(outputDir, { recursive: true, mode: 0o700 });
  await writeFile(sourcePath, payload);
  const queued = assertOk(
    await rpc.request("downloads.start", {
      itemId: "cancel-retry",
      localPath: sourcePath,
      outputDir,
    }),
    "downloads.start",
  );
  if (queued.state !== "queued") throw new Error(`job was not queued: ${JSON.stringify(queued)}`);
  await pollJob(rpc, "cancel-retry", (job) => job.state === "active" && Number(job.received) > 0);
  const cancel = assertOk(
    await rpc.request("downloads.cancel", { jobId: "cancel-retry" }),
    "downloads.cancel",
  );
  if (cancel.cancelled !== true) throw new Error("active job was not cancelled");
  await pollJob(rpc, "cancel-retry", (job) => job.state === "cancelled");
  const partial = await stat(`${destination}.part`);
  if (partial.size <= 0 || partial.size >= payload.length)
    throw new Error(`unexpected retained partial size ${partial.size}`);

  const sandbox = rpc.sandbox;
  const closeStarted = performance.now();
  await rpc.close();
  const closeElapsed = performance.now() - closeStarted;
  if (closeElapsed > 1_500) {
    throw new Error(`RPC shutdown waited ${closeElapsed.toFixed(0)}ms for a detached download`);
  }
  rpc = await RpcHarness.resume(sandbox);
  await pollJob(rpc, "cancel-retry", (job) => job.state === "cancelled");

  const retried = assertOk(
    await rpc.request("downloads.start", {
      itemId: "cancel-retry",
      localPath: sourcePath,
      outputDir,
    }),
    "downloads retry",
  );
  if (retried.state !== "queued")
    throw new Error(`retry was not queued: ${JSON.stringify(retried)}`);
  const completed = await pollJob(rpc, "cancel-retry", (job) => job.state === "completed", 10_000);
  if (completed.attempts !== 2) {
    throw new Error(`retry attempt history was not preserved: ${JSON.stringify(completed)}`);
  }
  const actual = await readFile(destination);
  if (!actual.equals(payload)) throw new Error("retried download differs from source");
  console.log(`download cancellation/retry passed (resumed ${partial.size} retained bytes)`);
} finally {
  await rpc.close().catch(() => {});
  await rpc.cleanup();
}

async function pollJob(
  harness: RpcHarness,
  jobId: string,
  predicate: (job: Record<string, unknown>) => boolean,
  timeout = 5_000,
): Promise<Record<string, unknown>> {
  const deadline = Date.now() + timeout;
  let last: Record<string, unknown> | undefined;
  while (Date.now() < deadline) {
    const result = assertOk(await harness.request("downloads.list"), "downloads.list poll");
    const job = (result.jobs as Array<Record<string, unknown>>).find(
      (candidate) => candidate.jobId === jobId,
    );
    last = job;
    if (job && predicate(job)) return job;
    await Bun.sleep(10);
  }
  throw new Error(
    `durable download job ${jobId} did not reach expected state; last=${JSON.stringify(last)}`,
  );
}

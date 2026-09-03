import { lstat } from "node:fs/promises";
import { join } from "node:path";
import { assertOk, RpcHarness, type RpcMessage } from "./rpc-harness";

let rpc = await RpcHarness.start("audible-tui-player-e2e-");
const audioPath = join(rpc.sandbox, "synthetic.wav");

try {
  await Bun.write(audioPath, makeWave(90, 48_000, 440));

  const play = assertOk(
    await rpc.request("player.command", {
      command: "play",
      path: audioPath,
      itemId: "synthetic-tone",
      title: "Synthetic Tone",
    }),
    "play",
  );
  assertPlayer(play, "synthetic-tone", false, "play response");
  if (play.title !== "Synthetic Tone")
    throw new Error(`play response lost display title: ${JSON.stringify(play)}`);
  await rpc.waitFor(
    (message) => message.event === "player.state" && message.data?.state === "playing",
    5_000,
    "player.state event",
  );

  const socketPath = join(rpc.stateDir, "mpv.sock");
  await waitForSocket(socketPath);

  const advancing = await waitForPlayerStatus(
    rpc,
    (status) =>
      typeof status.durationSeconds === "number" &&
      status.durationSeconds > 89.5 &&
      status.durationSeconds < 90.5 &&
      typeof status.positionSeconds === "number" &&
      status.positionSeconds > 0.05,
    "duration and advancing position",
  );
  assertPlayer(advancing, "synthetic-tone", false, "advancing status");

  // The socket appearing and accepting engine commands are separate readiness
  // points. Exercise the real player.command path until mpv accepts control.
  const speedChanged = assertOk(
    await requestUntilOk(rpc, "player.command", { command: "set-speed", value: 1.25 }),
    "set-speed",
  );
  if (speedChanged.speed !== 1.25) {
    throw new Error(
      `set-speed response did not retain engine state: ${JSON.stringify(speedChanged)}`,
    );
  }

  const status = assertOk(await rpc.request("player.status"), "player.status");
  assertPlayer(status, "synthetic-tone", false, "active status");
  if (status.speed !== 1.25) {
    throw new Error(`player.status did not retain playback speed: ${JSON.stringify(status)}`);
  }

  const paused = assertOk(
    await requestUntilOk(rpc, "player.command", { command: "pause" }),
    "pause",
  );
  assertPlayer(paused, "synthetic-tone", true, "pause response");
  // Let any samples already queued in the audio driver settle before taking
  // the paused baseline. Older mpv builds can report one final small advance.
  await Bun.sleep(150);
  const pausedBaseline = assertOk(await rpc.request("player.status"), "paused baseline");
  const pausedAt = Number(pausedBaseline.positionSeconds);
  await Bun.sleep(250);
  const stillPaused = assertOk(await rpc.request("player.status"), "paused status");
  if (Math.abs(Number(stillPaused.positionSeconds) - pausedAt) > 0.1) {
    throw new Error(`position advanced while paused: ${JSON.stringify({ pausedAt, stillPaused })}`);
  }

  const sought = assertOk(
    await requestUntilOk(rpc, "player.command", { command: "seek-absolute", value: 2 }),
    "seek-absolute",
  );
  if (typeof sought.positionSeconds !== "number" || Math.abs(sought.positionSeconds - 2) > 0.25) {
    throw new Error(`seek was not reflected in player status: ${JSON.stringify(sought)}`);
  }

  const bookmarked = assertOk(
    await rpc.request("player.command", { command: "bookmark-add", label: "Opening note" }),
    "bookmark-add",
  );
  const bookmarks = bookmarked.bookmarks as Array<Record<string, unknown>>;
  if (
    !Array.isArray(bookmarks) ||
    bookmarks.length !== 1 ||
    bookmarks[0]?.label !== "Opening note"
  ) {
    throw new Error(`bookmark was not returned from durable state: ${JSON.stringify(bookmarked)}`);
  }
  const bookmarkId = Number(bookmarks[0]?.id);

  const volumeChanged = assertOk(
    await rpc.request("player.command", { command: "set-volume", value: 35 }),
    "set-volume",
  );
  if (Math.abs(Number(volumeChanged.volume) - 35) > 0.1)
    throw new Error(`volume did not change: ${JSON.stringify(volumeChanged)}`);

  assertOk(await rpc.request("player.command", { command: "toggle" }), "resume before shutdown");
  assertOk(
    await rpc.request("player.command", { command: "seek-absolute", value: 12 }),
    "seek before shutdown",
  );

  const sandbox = rpc.sandbox;
  // Closing stdin is the engine's clean-shutdown path. Runtime.deinit must
  // sample mpv one final time and commit the position before exiting.
  await rpc.close();
  rpc = await RpcHarness.resume(sandbox);

  const resumed = assertOk(
    await rpc.request("player.command", {
      command: "play",
      path: audioPath,
      itemId: "synthetic-tone",
      title: "Synthetic Tone",
    }),
    "resume play",
  );
  if (Math.abs(Number(resumed.positionSeconds) - 12) > 0.4) {
    throw new Error(`saved position was not restored: ${JSON.stringify(resumed)}`);
  }
  if (
    Math.abs(Number(resumed.volume) - 35) > 0.1 ||
    Math.abs(Number(resumed.speed) - 1.25) > 0.01
  ) {
    throw new Error(`player settings were not restored: ${JSON.stringify(resumed)}`);
  }
  if (!Array.isArray(resumed.bookmarks) || resumed.bookmarks.length !== 1) {
    throw new Error(`durable bookmark was not restored: ${JSON.stringify(resumed)}`);
  }
  assertOk(
    await rpc.request("player.command", { command: "bookmark-delete", bookmarkId }),
    "bookmark-delete",
  );
  const sleeping = assertOk(
    await rpc.request("player.command", { command: "set-sleep-timer", value: 1 }),
    "sleep timer",
  );
  if (sleeping.sleepTimerMode !== "duration" || Number(sleeping.sleepTimerSeconds) > 1) {
    throw new Error(`sleep timer was not armed: ${JSON.stringify(sleeping)}`);
  }
  await waitForPlayerStatus(
    rpc,
    (value) => value.paused === true && value.sleepTimerMode === null,
    "sleep timer pause",
  );

  assertOk(
    await rpc.request("player.command", { command: "seek-absolute", value: 89.8 }),
    "seek near completion",
  );
  assertOk(await rpc.request("player.command", { command: "stop" }), "stop near completion");
  const restarted = assertOk(
    await rpc.request("player.command", {
      command: "play",
      path: audioPath,
      itemId: "synthetic-tone",
      title: "Synthetic Tone",
    }),
    "completed restart",
  );
  if (Number(restarted.positionSeconds) > 0.5) {
    throw new Error(
      `near-complete title did not reset to the beginning: ${JSON.stringify(restarted)}`,
    );
  }
  const stopped = assertOk(await rpc.request("player.command", { command: "stop" }), "final stop");
  assertPlayer(stopped, null, true, "stop response");
  const stoppedStatus = assertOk(await rpc.request("player.status"), "stopped status");
  assertPlayer(stoppedStatus, null, true, "stopped status");

  await rpc.close();
  console.log(
    "real engine player RPC e2e passed (timing, resume/reset, settings, bookmarks, sleep timer)",
  );
} finally {
  await rpc.cleanup();
}

async function waitForPlayerStatus(
  harness: RpcHarness,
  predicate: (status: Record<string, unknown>) => boolean,
  label: string,
): Promise<Record<string, unknown>> {
  const deadline = Date.now() + 5_000;
  let status: Record<string, unknown> = {};
  while (Date.now() < deadline) {
    status = assertOk(await harness.request("player.status"), label);
    if (predicate(status)) return status;
    await Bun.sleep(25);
  }
  throw new Error(`player.status never reported ${label}: ${JSON.stringify(status)}`);
}

async function requestUntilOk(
  harness: RpcHarness,
  method: string,
  params: Record<string, unknown>,
): Promise<RpcMessage> {
  const deadline = Date.now() + 5_000;
  let response: RpcMessage | undefined;
  while (Date.now() < deadline) {
    response = await harness.request(method, params);
    if (response.ok === true) return response;
    if (response.error?.code !== "INTERNAL") break;
    await Bun.sleep(25);
  }
  throw new Error(`mpv control did not become ready: ${JSON.stringify(response)}`);
}

async function waitForSocket(path: string): Promise<void> {
  const deadline = Date.now() + 5_000;
  let lastError: unknown;
  while (Date.now() < deadline) {
    try {
      if ((await lstat(path)).isSocket()) return;
    } catch (error) {
      lastError = error;
    }
    await Bun.sleep(25);
  }
  throw new Error(`mpv socket did not appear: ${String(lastError)}`);
}

function assertPlayer(
  result: Record<string, unknown>,
  itemId: string | null,
  paused: boolean,
  label: string,
): void {
  if (result.itemId !== itemId || result.paused !== paused) {
    throw new Error(`${label} has unexpected state: ${JSON.stringify(result)}`);
  }
}

function makeWave(seconds: number, sampleRate: number, frequency: number): Uint8Array {
  const samples = seconds * sampleRate;
  const bytes = new Uint8Array(44 + samples * 2);
  const view = new DataView(bytes.buffer);
  const ascii = (offset: number, value: string) => {
    for (let index = 0; index < value.length; index++)
      bytes[offset + index] = value.charCodeAt(index);
  };
  ascii(0, "RIFF");
  view.setUint32(4, bytes.length - 8, true);
  ascii(8, "WAVEfmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  ascii(36, "data");
  view.setUint32(40, samples * 2, true);
  for (let index = 0; index < samples; index++) {
    view.setInt16(
      44 + index * 2,
      Math.sin((index * frequency * Math.PI * 2) / sampleRate) * 8_000,
      true,
    );
  }
  return bytes;
}

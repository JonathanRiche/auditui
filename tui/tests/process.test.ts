import { expect, test } from "bun:test";
import { EngineSupervisor } from "../src/engine/process";

test("supervisor exposes a client and shuts down cleanly", async () => {
  let resolveExit!: (code: number) => void;
  const exited = new Promise<number>((resolve) => {
    resolveExit = resolve;
  });
  let ended = false;
  const supervisor = new EngineSupervisor(() => ({
    stdin: {
      write() {
        return 1;
      },
      end() {
        ended = true;
        resolveExit(0);
      },
    } as unknown as Bun.FileSink,
    stdout: new ReadableStream<Uint8Array>({ start() {} }),
    exited,
    kill() {
      resolveExit(143);
    },
  }));
  const statuses: string[] = [];
  supervisor.on("status", (status) => statuses.push(String(status)));
  supervisor.start();
  expect(supervisor.client).not.toBeNull();
  expect(statuses).toEqual(["starting", "online"]);
  await supervisor.stop();
  expect(ended).toBe(true);
  expect(supervisor.client).toBeNull();
});

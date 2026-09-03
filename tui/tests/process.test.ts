import { describe, expect, test } from "bun:test";
import { EngineSupervisor, engineExecutable } from "../src/engine/process";

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

describe("engineExecutable", () => {
  const none = () => false;

  test("explicit AUDITUI_ENGINE wins over everything", () => {
    expect(
      engineExecutable(
        { AUDITUI_ENGINE: "/x/engine", AUDIBLE_ENGINE: "/y" },
        "/opt/bin/auditui-ui",
        () => true,
      ),
    ).toBe("/x/engine");
  });

  test("legacy AUDIBLE_ENGINE is honoured", () => {
    expect(engineExecutable({ AUDIBLE_ENGINE: "/y/engine" }, "/opt/bin/auditui-ui", none)).toBe(
      "/y/engine",
    );
  });

  test("packaged install uses the sibling auditui-engine", () => {
    const seen: string[] = [];
    const exists = (path: string) => {
      seen.push(path);
      return true;
    };
    expect(engineExecutable({}, "/home/u/.local/bin/auditui-ui", exists)).toBe(
      "/home/u/.local/bin/auditui-engine",
    );
    expect(seen).toEqual(["/home/u/.local/bin/auditui-engine"]);
  });

  test("development falls back to audible-zig on PATH", () => {
    expect(engineExecutable({}, "/usr/bin/bun", none)).toBe("audible-zig");
  });
});

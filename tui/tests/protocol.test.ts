import { describe, expect, test } from "bun:test";
import { EngineClient } from "../src/engine/client";
import { parseMessage, RpcRequestError } from "../src/engine/protocol";

describe("protocol parser", () => {
  test("accepts responses and interleaved events", async () => {
    const writes: string[] = [];
    const client = new EngineClient({ write: (line) => void writes.push(line) });
    const events: unknown[] = [];
    client.on("event", (name, data) => events.push([name, data]));
    const result = client.request<{ ok: boolean }>("health");
    client.acceptLine('{"v":1,"event":"player.position","data":{"positionSeconds":9}}');
    client.acceptLine('{"v":1,"id":"1","ok":true,"result":{"ok":true}}');
    expect(await result).toEqual({ ok: true });
    expect(events).toEqual([["player.position", { positionSeconds: 9 }]]);
    expect(JSON.parse(writes[0]!)).toEqual({ v: 1, id: "1", method: "health", params: {} });
  });

  test("turns structured failures into typed errors", async () => {
    const client = new EngineClient({ write() {} });
    const result = client.request("library.list");
    client.acceptLine(
      '{"v":1,"id":"1","ok":false,"error":{"code":"OFFLINE","message":"No network","details":{"retry":true}}}',
    );
    await expect(result).rejects.toEqual(
      new RpcRequestError("OFFLINE", "No network", { retry: true }),
    );
  });

  test("reports malformed input without disrupting a pending request", async () => {
    const client = new EngineClient({ write() {} });
    const errors: Error[] = [];
    client.on("protocolError", (error) => errors.push(error as Error));
    const result = client.request("health");
    client.acceptLine("not-json");
    client.acceptLine('{"v":1,"id":"1","ok":true,"result":{}}');
    await result;
    expect(errors[0]?.message).toBe("Engine emitted malformed JSON");
  });

  test("cancels requests over the protocol", async () => {
    const writes: string[] = [];
    const controller = new AbortController();
    const client = new EngineClient({ write: (line) => void writes.push(line) });
    const result = client.request(
      "library.search",
      { query: "dune" },
      { signal: controller.signal },
    );
    controller.abort();
    await expect(result).rejects.toMatchObject({ name: "AbortError" });
    expect(JSON.parse(writes[1]!)).toEqual({
      v: 1,
      id: "2",
      method: "cancel",
      params: { id: "1" },
    });
  });

  test("rejects unsupported versions and invalid failures", () => {
    expect(() => parseMessage('{"v":2,"id":"1","ok":true,"result":{}}')).toThrow(
      "Unsupported protocol version",
    );
    expect(() => parseMessage('{"v":1,"id":"1","ok":false,"error":{}}')).toThrow("valid error");
  });
});

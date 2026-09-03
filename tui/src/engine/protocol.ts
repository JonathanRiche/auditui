export const PROTOCOL_VERSION = 1 as const;

export interface RpcRequest {
  v: typeof PROTOCOL_VERSION;
  id: string;
  method: string;
  params: Record<string, unknown>;
}

export interface RpcError {
  code: string;
  message: string;
  details?: unknown;
}

export type RpcMessage =
  | { v: 1; id: string; ok: true; result: unknown }
  | { v: 1; id: string; ok: false; error: RpcError }
  | { v: 1; event: string; data: unknown };

export function parseMessage(line: string): RpcMessage {
  let value: unknown;
  try {
    value = JSON.parse(line);
  } catch {
    throw new Error("Engine emitted malformed JSON");
  }
  if (!value || typeof value !== "object") throw new Error("Engine message is not an object");
  const record = value as Record<string, unknown>;
  if (record.v !== PROTOCOL_VERSION)
    throw new Error(`Unsupported protocol version: ${String(record.v)}`);
  if (typeof record.event === "string" && "data" in record) return value as RpcMessage;
  if (typeof record.id !== "string" || typeof record.ok !== "boolean") {
    throw new Error("Engine response is missing id or ok");
  }
  if (record.ok && !("result" in record)) throw new Error("Successful response is missing result");
  if (!record.ok) {
    const error = record.error as Record<string, unknown> | undefined;
    if (!error || typeof error.code !== "string" || typeof error.message !== "string") {
      throw new Error("Failed response is missing a valid error");
    }
  }
  return value as RpcMessage;
}

export class RpcRequestError extends Error {
  constructor(
    public readonly code: string,
    message: string,
    public readonly details?: unknown,
  ) {
    super(message);
    this.name = "RpcRequestError";
  }
}

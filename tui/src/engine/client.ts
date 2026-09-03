import { EventEmitter } from "node:events";
import {
  PROTOCOL_VERSION,
  parseMessage,
  RpcRequestError,
  type RpcMessage,
  type RpcRequest,
} from "./protocol";

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (reason: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

export interface RpcWriter {
  write(line: string): void | Promise<void>;
}

export class EngineClient extends EventEmitter {
  private nextId = 1;
  private readonly pending = new Map<string, PendingRequest>();
  private closed = false;

  constructor(private readonly writer: RpcWriter) {
    super();
  }

  async request<T>(
    method: string,
    params: Record<string, unknown> = {},
    options: { signal?: AbortSignal; timeoutMs?: number } = {},
  ): Promise<T> {
    if (this.closed) throw new Error("Engine connection is closed");
    if (options.signal?.aborted) throw new DOMException("Request cancelled", "AbortError");
    const id = String(this.nextId++);
    const timeoutMs = options.timeoutMs ?? 30_000;
    const request: RpcRequest = { v: PROTOCOL_VERSION, id, method, params };
    return await new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Engine request timed out: ${method}`));
        void this.sendCancellation(id);
      }, timeoutMs);
      this.pending.set(id, { resolve: resolve as (value: unknown) => void, reject, timer });

      const abort = () => {
        const pending = this.pending.get(id);
        if (!pending) return;
        this.pending.delete(id);
        clearTimeout(pending.timer);
        reject(new DOMException("Request cancelled", "AbortError"));
        void this.sendCancellation(id);
      };
      options.signal?.addEventListener("abort", abort, { once: true });
      Promise.resolve(this.writer.write(`${JSON.stringify(request)}\n`)).catch((error: unknown) => {
        const pending = this.pending.get(id);
        if (!pending) return;
        this.pending.delete(id);
        clearTimeout(timer);
        reject(error instanceof Error ? error : new Error(String(error)));
      });
    });
  }

  acceptLine(line: string): void {
    if (!line.trim()) return;
    let message: RpcMessage;
    try {
      message = parseMessage(line);
    } catch (error) {
      this.emit("protocolError", error);
      return;
    }
    if ("event" in message) {
      this.emit("event", message.event, message.data);
      return;
    }
    const pending = this.pending.get(message.id);
    if (!pending) return;
    this.pending.delete(message.id);
    clearTimeout(pending.timer);
    if (message.ok) pending.resolve(message.result);
    else
      pending.reject(
        new RpcRequestError(message.error.code, message.error.message, message.error.details),
      );
  }

  close(reason = "Engine connection closed"): void {
    if (this.closed) return;
    this.closed = true;
    for (const request of this.pending.values()) {
      clearTimeout(request.timer);
      request.reject(new Error(reason));
    }
    this.pending.clear();
    this.removeAllListeners();
  }

  private async sendCancellation(requestId: string): Promise<void> {
    if (this.closed) return;
    const cancel: RpcRequest = {
      v: PROTOCOL_VERSION,
      id: String(this.nextId++),
      method: "cancel",
      params: { id: requestId },
    };
    try {
      await this.writer.write(`${JSON.stringify(cancel)}\n`);
    } catch {
      // The original request already has its useful error; a dead pipe is expected here.
    }
  }
}

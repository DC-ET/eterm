// 同步引擎编排：pull / push（技术方案 §3.3/§3.4）。批量 push 逐条独立事务，任一成功即广播。

import type { Db } from "./store/db.ts";
import { fetchChanges, pushItem, type PushItem, type PushResult } from "./store/syncstore.ts";
import type { Hub } from "./hub.ts";

export interface PullChange {
  entity_type: string;
  entity_id: string;
  op: "upsert" | "delete";
  rev: number;
  ts: string;
  data?: Record<string, unknown>;
}

export interface PullResponse {
  cursor: number;
  has_more: boolean;
  changes: PullChange[];
}

export interface PushResultWire {
  status: string;
  rev?: number;
  server_data?: Record<string, unknown>;
  reason?: string;
}

export class SyncEngine {
  constructor(
    private readonly db: Db,
    private readonly hub: Hub,
  ) {}

  async pull(vaultId: Buffer, cursor: number, limit: number): Promise<PullResponse> {
    const { changes, cursor: newCursor, hasMore } = await fetchChanges(db2this(this.db), vaultId, cursor, limit);
    return {
      cursor: newCursor,
      has_more: hasMore,
      changes: changes.map((c) => ({
        entity_type: c.entityType,
        entity_id: c.entityId,
        op: c.op,
        rev: c.id,
        ts: c.ts,
        ...(c.data ? { data: c.data } : {}),
      })),
    };
  }

  async push(vaultId: Buffer, deviceId: Buffer, items: PushItem[]): Promise<PushResultWire[]> {
    const results: PushResultWire[] = [];
    let maxRev = 0;
    let anyOk = false;
    for (const item of items) {
      const r: PushResult = await pushItem(this.db, vaultId, deviceId, item);
      results.push({
        status: r.status,
        ...(r.rev !== undefined ? { rev: r.rev } : {}),
        ...(r.serverData ? { server_data: r.serverData } : {}),
        ...(r.reason ? { reason: r.reason } : {}),
      });
      if (r.status === "ok") {
        anyOk = true;
        if ((r.rev ?? 0) > maxRev) maxRev = r.rev ?? 0;
      }
    }
    if (anyOk) this.hub.broadcast(maxRev);
    return results;
  }
}

function db2this(db: Db): Db {
  return db;
}

export function parseCursor(s: string | undefined): number {
  if (!s) return 0;
  const n = Number(s);
  if (!Number.isInteger(n) || n < 0) throw new Error("cursor 必须为非负整数");
  return n;
}

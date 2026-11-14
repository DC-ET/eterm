// 同步协议存储核心：pull（changes 增量）与 push（逐条独立事务）。
// 语义与 Go 版 1:1：base_rev 乐观锁、conflict 附服务端数据、tombstone/复活/幂等删除、
// 密钥内容不可变版本化（ssh_key）、rev = changes 表自增 id 回填实体行。

import { type PoolConnection, type RowDataPacket } from "mysql2/promise";
import type { Db } from "./db.ts";
import { PushReject } from "./db.ts";
import { getEntity, selectColumns, type Entity } from "./entities.ts";
import { openField } from "../crypto/field.ts";

export interface ChangeRow {
  id: number;
  entityType: string;
  entityId: string;
  ts: string;
  op: "upsert" | "delete";
  data?: Record<string, unknown>;
}

export interface PushItem {
  entityType: string;
  entityId: string;
  baseRev: number;
  op: string; // upsert | delete
  data?: Record<string, unknown>;
}

export interface PushResult {
  status: "ok" | "conflict" | "rejected";
  rev?: number;
  serverData?: Record<string, unknown>;
  reason?: string;
}

const ok = (rev: number): PushResult => ({ status: "ok", rev });
const rejected = (reason: string): PushResult => ({ status: "rejected", reason });

/** pull：从 cursor 起按序拉取 vault 内变更。实体行整体缺失时跳过该条，cursor 照常前进。 */
export async function fetchChanges(
  db: Db,
  vaultId: Buffer,
  cursor: number,
  limit: number,
): Promise<{ changes: ChangeRow[]; cursor: number; hasMore: boolean }> {
  if (!(limit > 0) || limit > 1000) limit = 200;

  const [rows] = await db.pool.query<RowDataPacket[]>(
    `SELECT id, entity_type, entity_id, ts FROM changes WHERE id > ? AND vault_id = ? ORDER BY id ASC LIMIT ?`,
    [cursor, vaultId, limit + 1],
  );
  const entries = rows.map((r) => ({
    id: Number(r["id"]),
    etype: String(r["entity_type"]),
    entityBuf: r["entity_id"] as Buffer,
    ts: new Date(r["ts"] as Date).toISOString(),
  }));
  const hasMore = entries.length > limit;
  const trimmed = hasMore ? entries.slice(0, limit) : entries;
  if (trimmed.length === 0) return { changes: [], cursor, hasMore: false };

  // 按类型批量取当前实体行
  const byType = new Map<string, typeof trimmed>();
  for (const e of trimmed) {
    const list = byType.get(e.etype) ?? [];
    list.push(e);
    byType.set(e.etype, list);
  }
  const wireById = new Map<string, Record<string, unknown>>();
  for (const [etype, list] of byType) {
    const ent = getEntity(etype);
    if (!ent) throw new Error(`changes 中存在未知实体类型 ${etype}`);
    const ids = list.map((e) => e.entityBuf);
    const [entityRows] = await db.pool.query<RowDataPacket[]>(
      `SELECT ${selectColumns(ent)} FROM ${ent.table} WHERE id IN (?)`,
      [ids],
    );
    for (const r of entityRows) {
      const w = db.rowToWire(ent, r);
      wireById.set(w["id"] as string, w);
    }
  }

  const changes: ChangeRow[] = [];
  for (const e of trimmed) {
    const idStr = db.bytesToUuid(e.entityBuf);
    const w = wireById.get(idStr);
    if (!w) continue; // 行已物理缺失：跳过
    const isDeleted = w["deleted_at"] != null;
    changes.push({
      id: e.id,
      entityType: e.etype,
      entityId: idStr,
      ts: e.ts,
      op: isDeleted ? "delete" : "upsert",
      ...(isDeleted ? {} : { data: w }),
    });
  }
  const newCursor = trimmed[trimmed.length - 1]!.id;
  return { changes, cursor: newCursor, hasMore };
}

function parseUpdatedAt(data: Record<string, unknown> | undefined, def: Date): Date {
  const s = data?.["updated_at"];
  if (typeof s === "string") {
    const d = new Date(s);
    if (!Number.isNaN(d.getTime())) return d;
  }
  return def;
}

/** push 单项（独立事务）。 */
export async function pushItem(
  db: Db,
  vaultId: Buffer,
  deviceId: Buffer,
  item: PushItem,
): Promise<PushResult> {
  const ent = getEntity(item.entityType);
  if (!ent) return rejected("未知实体类型 " + item.entityType);
  if (item.op !== "upsert" && item.op !== "delete") {
    return rejected("op 必须为 upsert|delete");
  }
  let entityId: Buffer;
  try {
    entityId = db.uuidToBytes(item.entityId);
  } catch (e) {
    return rejected((e as Error).message);
  }
  const data = item.data ?? {};
  if (item.op === "upsert") {
    try {
      ent.validate(data);
    } catch (e) {
      return rejected((e as Error).message);
    }
  }

  const conn = await db.pool.getConnection();
  try {
    await conn.beginTransaction();
    const [rows] = await conn.query<RowDataPacket[]>(
      `SELECT rev, deleted_at FROM ${ent.table} WHERE id = ? FOR UPDATE`,
      [entityId],
    );
    const exists = rows.length > 0;
    const curRev = exists ? Number(rows[0]!["rev"]) : 0;
    const deleted = exists ? rows[0]!["deleted_at"] != null : false;

    const commitAndOk = async (rev: number): Promise<PushResult> => {
      await conn.commit();
      conn.release();
      return ok(rev);
    };
    const fail = async (r: PushResult): Promise<PushResult> => {
      await conn.rollback();
      conn.release();
      return r;
    };
    const serverErr = async (e: unknown): Promise<PushResult> => {
      await conn.rollback().catch(() => {});
      conn.release();
      return rejected(`内部错误: ${(e as Error).message}`);
    };
    const conflict = async (): Promise<PushResult> => {
      try {
        const row = await db.scanEntityRow(conn, ent, entityId);
        await conn.rollback();
        conn.release();
        return { status: "conflict", rev: curRev, serverData: row ?? undefined };
      } catch {
        return fail({ status: "conflict", rev: curRev });
      }
    };

    try {
      if (!exists) {
        if (item.op === "delete") return await fail(rejected("entity_not_found"));
        if (item.baseRev !== 0) {
          return await fail(rejected("entity_not_found（base_rev>0 但实体不存在）"));
        }
        await insertEntity(db, conn, ent, entityId, vaultId, data);
        const rev = await allocRev(db, conn, ent, entityId, vaultId, deviceId);
        return await commitAndOk(rev);
      }

      if (deleted) {
        if (item.op === "delete") {
          // 幂等：已是 tombstone
          await conn.commit();
          conn.release();
          return ok(curRev);
        }
        if (curRev !== item.baseRev) return await conflict();
        await updateEntity(db, conn, ent, entityId, data, true);
        const rev = await allocRev(db, conn, ent, entityId, vaultId, deviceId);
        return await commitAndOk(rev);
      }

      // 存活行
      if (item.op === "delete") {
        await conn.query(`UPDATE ${ent.table} SET deleted_at = UTC_TIMESTAMP(3) WHERE id = ?`, [
          entityId,
        ]);
        const rev = await allocRev(db, conn, ent, entityId, vaultId, deviceId);
        return await commitAndOk(rev);
      }
      if (curRev !== item.baseRev) return await conflict();
      const imm = await checkKeyImmutability(db, conn, ent, entityId, data);
      if (imm) return await fail(rejected(imm));
      await updateEntity(db, conn, ent, entityId, data, false);
      const rev = await allocRev(db, conn, ent, entityId, vaultId, deviceId);
      return await commitAndOk(rev);
    } catch (e) {
      if (e instanceof PushReject) return await fail(rejected(e.message));
      return await serverErr(e);
    }
  } catch (outer) {
    // 连接级异常：确保归还连接
    conn.release();
    return rejected(`内部错误: ${(outer as Error).message}`);
  }
}

/** ssh_key 实体：禁止覆盖密钥内容（应创建新版本行并以 superseded_by 指向）。 */
async function checkKeyImmutability(
  db: Db,
  conn: PoolConnection,
  ent: Entity,
  entityId: Buffer,
  data: Record<string, unknown>,
): Promise<string | null> {
  if (ent.type !== "ssh_key") return null;
  const encCols = ["private_enc", "cert_enc", "passphrase_enc"];
  for (const col of encCols) {
    const incoming = data[col];
    if (incoming === undefined || incoming === null) continue;
    if (typeof incoming !== "string") return `字段 ${col} 应为字符串`;
    const [rows] = await conn.query<RowDataPacket[]>(
      `SELECT ${col} FROM ssh_keys WHERE id = ?`,
      [entityId],
    );
    if (rows.length === 0) return "entity_not_found";
    const stored = rows[0]![col] as Buffer;
    let oldPlain: string;
    try {
      oldPlain = openField(db.encKey, stored.toString("utf8")).toString("utf8");
    } catch (e) {
      return `读取原密钥内容失败: ${(e as Error).message}`;
    }
    if (incoming !== oldPlain) {
      return "密钥内容不可变：请创建新版本密钥（新 id）并通过 superseded_by 指向";
    }
  }
  return null;
}

async function insertEntity(
  db: Db,
  conn: PoolConnection,
  ent: Entity,
  entityId: Buffer,
  vaultId: Buffer,
  data: Record<string, unknown>,
): Promise<void> {
  const cols = ["id", "vault_id"];
  const args: unknown[] = [entityId, vaultId];
  for (const c of ent.cols) {
    const v = data[c.name];
    if (v === undefined || v === null) {
      if (c.notNull) throw new PushReject(`缺少必填字段 ${c.name}`);
      cols.push(c.name);
      args.push(null);
      continue;
    }
    cols.push(c.name);
    args.push(db.encodeCell(c.kind, v));
  }
  cols.push("created_at", "updated_at", "rev");
  args.push(new Date(), parseUpdatedAt(data, new Date()), 0);
  await conn.query(
    `INSERT INTO ${ent.table} (${cols.join(", ")}) VALUES (${cols.map(() => "?").join(", ")})`,
    args,
  );
}

async function updateEntity(
  db: Db,
  conn: PoolConnection,
  ent: Entity,
  entityId: Buffer,
  data: Record<string, unknown>,
  resurrect: boolean,
): Promise<void> {
  const sets: string[] = ["updated_at = ?"];
  const args: unknown[] = [parseUpdatedAt(data, new Date())];
  for (const c of ent.cols) {
    if (!(c.name in data)) continue;
    sets.push(`${c.name} = ?`);
    args.push(db.encodeCell(c.kind, data[c.name]));
  }
  if (resurrect) sets.push("deleted_at = NULL");
  args.push(entityId);
  await conn.query(`UPDATE ${ent.table} SET ${sets.join(", ")} WHERE id = ?`, args);
}

/** 写入 changes 取全局 rev，并回填实体行。 */
async function allocRev(
  db: Db,
  conn: PoolConnection,
  ent: Entity,
  entityId: Buffer,
  vaultId: Buffer,
  deviceId: Buffer,
): Promise<number> {
  const [res] = await conn.query(
    `INSERT INTO changes (entity_type, entity_id, vault_id, actor_device, ts) VALUES (?, ?, ?, ?, UTC_TIMESTAMP(3))`,
    [ent.type, entityId, vaultId, deviceId],
  );
  const rev = Number((res as { insertId: number }).insertId);
  await conn.query(`UPDATE ${ent.table} SET rev = ? WHERE id = ?`, [rev, entityId]);
  return rev;
}

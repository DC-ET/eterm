// MySQL 访问层：连接池、UUID、列编解码（DB 值 ↔ wire JSON 值）。
// 编解码语义与 Go 版逐项对齐：enc 列读出即解密、JSON 列原样透传、BINARY(16) ↔ uuid 字符串。

import {
  createPool,
  type Pool,
  type PoolConnection,
  type RowDataPacket,
} from "mysql2/promise";
import { v7 as uuidv7 } from "uuid";
import { openField, sealField } from "../crypto/field.ts";
import { ColKind, type Col, type Entity, selectColumns } from "./entities.ts";

export type Conn = Pool | PoolConnection;

/** push 校验类拒绝（对应 Go 版 PushResult.rejected） */
export class PushReject extends Error {}

export class Db {
  readonly pool: Pool;
  /** 字段加密密钥（AES-256-GCM，取主密钥前 32B） */
  readonly encKey: Buffer;

  constructor(
    cfg: { host: string; port: number; user: string; password: string; database: string },
    encKey: Buffer,
  ) {
    this.encKey = encKey;
    this.pool = createPool({
      host: cfg.host,
      port: cfg.port,
      user: cfg.user,
      password: cfg.password,
      database: cfg.database,
      waitForConnections: true,
      connectionLimit: 20,
      timezone: "Z",
    });
  }

  async close(): Promise<void> {
    await this.pool.end();
  }

  // ---------- UUID ----------

  newUuid(): string {
    return uuidv7();
  }

  uuidToBytes(s: string): Buffer {
    if (!/^[0-9a-fA-F-]{36}$/.test(s)) {
      throw new PushReject(`非法 UUID ${JSON.stringify(s)}`);
    }
    const hex = s.replaceAll("-", "");
    if (hex.length !== 32) throw new PushReject(`非法 UUID ${JSON.stringify(s)}`);
    return Buffer.from(hex, "hex");
  }

  bytesToUuid(b: Buffer): string {
    const h = b.toString("hex");
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
  }

  // ---------- 编解码 ----------

  /** DB 值 → wire 值。enc 列读出即解密（明文仅存在于响应构造瞬间）。 */
  decodeCell(kind: ColKind, v: unknown): unknown {
    if (v === null || v === undefined) return null;
    switch (kind) {
      case ColKind.Uuid:
      case ColKind.UuidNull: {
        const b = v as Buffer;
        if (!Buffer.isBuffer(b) || b.length !== 16) throw new Error(`uuid 列值异常: ${typeof v}`);
        return this.bytesToUuid(b);
      }
      case ColKind.Str:
      case ColKind.StrNull:
        return typeof v === "string" ? v : Buffer.from(v as Buffer).toString("utf8");
      case ColKind.Enc:
      case ColKind.EncNull: {
        const b = v as Buffer;
        if (!Buffer.isBuffer(b)) throw new Error(`加密列值异常: ${typeof v}`);
        return openField(this.encKey, b.toString("utf8")).toString("utf8");
      }
      case ColKind.Json:
      case ColKind.JsonNull:
        return v; // mysql2 已把 JSON 列解析为 JS 对象
      case ColKind.Int:
      case ColKind.IntNull: {
        const n = typeof v === "number" ? v : Number(v);
        if (Number.isNaN(n)) throw new Error(`整数列值异常: ${String(v)}`);
        return n;
      }
      case ColKind.Bool:
      case ColKind.BoolNull:
        return v === 1 || v === true || v === "1" || v === "true";
    }
  }

  /** wire 值 → DB 值。enc 列写入前 Seal。 */
  encodeCell(kind: ColKind, v: unknown): unknown {
    if (v === null || v === undefined) return null;
    switch (kind) {
      case ColKind.Uuid:
      case ColKind.UuidNull:
        return this.uuidToBytes(String(v));
      case ColKind.Str:
      case ColKind.StrNull:
        if (typeof v !== "string") throw new PushReject(`字符串字段应为字符串: ${typeof v}`);
        return v;
      case ColKind.Enc:
      case ColKind.EncNull:
        if (typeof v !== "string") throw new PushReject(`加密字段应为字符串: ${typeof v}`);
        return Buffer.from(sealField(this.encKey, Buffer.from(v, "utf8")));
      case ColKind.Json:
      case ColKind.JsonNull:
        return JSON.stringify(v);
      case ColKind.Int:
      case ColKind.IntNull:
        if (typeof v !== "number" || !Number.isInteger(v)) {
          throw new PushReject(`整数字段类型异常: ${typeof v}`);
        }
        return v;
      case ColKind.Bool:
      case ColKind.BoolNull:
        if (typeof v !== "boolean") throw new PushReject(`布尔字段应为布尔: ${typeof v}`);
        return v ? 1 : 0;
    }
  }

  colByName(e: Entity, name: string): Col | undefined {
    return e.cols.find((c) => c.name === name);
  }

  /** 按实体元数据把当前行转为 wire map（供 pull 与 conflict 响应）。 */
  async scanEntityRow(
    q: Conn,
    e: Entity,
    idBytes: Buffer,
  ): Promise<Record<string, unknown> | null> {
    const [rows] = await q.query<RowDataPacket[]>(
      `SELECT ${selectColumns(e)} FROM ${e.table} WHERE id = ?`,
      [idBytes],
    );
    if (rows.length === 0) return null;
    return this.rowToWire(e, rows[0]!);
  }

  rowToWire(e: Entity, r: RowDataPacket): Record<string, unknown> {
    const m: Record<string, unknown> = {};
    m["id"] = this.bytesToUuid(r["id"] as Buffer);
    m["vault_id"] = this.bytesToUuid(r["vault_id"] as Buffer);
    for (const c of e.cols) {
      m[c.name] = this.decodeCell(c.kind, r[c.name]);
    }
    m["rev"] = Number(r["rev"]);
    for (const t of ["created_at", "updated_at", "deleted_at"] as const) {
      const d = r[t] as Date | string | null;
      m[t] = d ? new Date(d).toISOString() : null;
    }
    return m;
  }
}

export type { Entity };

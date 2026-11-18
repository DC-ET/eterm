// 用户 / 设备 / Vault / 审计 存取（与 Go 版语义一致）。

import { type RowDataPacket } from "mysql2/promise";
import type { Db } from "./db.ts";
import { v7 as uuidv7 } from "uuid";

export interface UserRow {
  id: string;
  username: string;
  pwdHash: string;
  failedCount: number;
  lockedUntil: Date | null;
}

export interface DeviceRow {
  id: string;
  userId: string;
  name: string;
  platform: string;
  createdAt: Date;
  lastSeenAt: Date | null;
  revokedAt: Date | null;
}

export async function createUser(db: Db, username: string, pwdHash: string): Promise<string> {
  const id = uuidv7();
  await db.pool.query(`INSERT INTO users (id, username, pwd_hash, created_at) VALUES (?, ?, ?, UTC_TIMESTAMP(3))`, [
    db.uuidToBytes(id),
    username,
    pwdHash,
  ]);
  return id;
}

export async function getUserByUsername(db: Db, username: string): Promise<UserRow | null> {
  const [rows] = await db.pool.query<RowDataPacket[]>(
    `SELECT id, username, pwd_hash, failed_count, locked_until, created_at FROM users WHERE username = ?`,
    [username],
  );
  if (rows.length === 0) return null;
  const r = rows[0]!;
  return {
    id: db.bytesToUuid(r["id"] as Buffer),
    username: r["username"] as string,
    pwdHash: r["pwd_hash"] as string,
    failedCount: Number(r["failed_count"]),
    lockedUntil: (r["locked_until"] as Date | null) ?? null,
  };
}

export async function getUserById(db: Db, userId: string): Promise<UserRow | null> {
  const [rows] = await db.pool.query<RowDataPacket[]>(
    `SELECT id, username, pwd_hash, failed_count, locked_until, created_at FROM users WHERE id = ?`,
    [db.uuidToBytes(userId)],
  );
  if (rows.length === 0) return null;
  const r = rows[0]!;
  return {
    id: db.bytesToUuid(r["id"] as Buffer),
    username: r["username"] as string,
    pwdHash: r["pwd_hash"] as string,
    failedCount: Number(r["failed_count"]),
    lockedUntil: (r["locked_until"] as Date | null) ?? null,
  };
}

/** 更新密码哈希；顺带清失败计数与锁定（改密本身已验证旧密码）。 */
export async function updatePassword(db: Db, userId: string, pwdHash: string): Promise<void> {
  await db.pool.query(
    `UPDATE users SET pwd_hash = ?, failed_count = 0, locked_until = NULL WHERE id = ?`,
    [pwdHash, db.uuidToBytes(userId)],
  );
}

/** 失败计数 +1；达到阈值则锁定，返回锁定截止时间。 */
export async function registerLoginFailure(
  db: Db,
  userId: string,
  maxFails: number,
  lockForSecs: number,
): Promise<{ locked: boolean; until: Date | null }> {
  const idB = db.uuidToBytes(userId);
  await db.pool.query(`UPDATE users SET failed_count = failed_count + 1 WHERE id = ?`, [idB]);
  const [rows] = await db.pool.query<RowDataPacket[]>(
    `SELECT failed_count FROM users WHERE id = ?`,
    [idB],
  );
  const cnt = Number(rows[0]!["failed_count"]);
  if (cnt >= maxFails) {
    const until = new Date(Date.now() + lockForSecs * 1000);
    await db.pool.query(`UPDATE users SET locked_until = ? WHERE id = ?`, [until, idB]);
    return { locked: true, until };
  }
  return { locked: false, until: null };
}

export async function resetLoginFailure(db: Db, userId: string): Promise<void> {
  await db.pool.query(`UPDATE users SET failed_count = 0, locked_until = NULL WHERE id = ?`, [
    db.uuidToBytes(userId),
  ]);
}

export async function createPersonalVault(db: Db, ownerId: string, name: string): Promise<string> {
  const id = uuidv7();
  await db.pool.query(
    `INSERT INTO vaults (id, name, scope, owner_id, rev, created_at, updated_at) VALUES (?, ?, 'personal', ?, 0, UTC_TIMESTAMP(3), UTC_TIMESTAMP(3))`,
    [db.uuidToBytes(id), name, db.uuidToBytes(ownerId)],
  );
  return id;
}

export async function firstVaultOfUser(db: Db, userId: string): Promise<string> {
  const [rows] = await db.pool.query<RowDataPacket[]>(
    `SELECT id FROM vaults WHERE owner_id = ? AND deleted_at IS NULL ORDER BY created_at ASC LIMIT 1`,
    [db.uuidToBytes(userId)],
  );
  if (rows.length === 0) throw new Error("用户无可用 vault");
  return db.bytesToUuid(rows[0]!["id"] as Buffer);
}

/** 设备注册：同 (user, name, platform) 复用已有行（重置 token 与吊销状态）。 */
export async function upsertDevice(
  db: Db,
  userId: string,
  name: string,
  platform: string,
  tokenHash: Buffer,
): Promise<string> {
  const uidB = db.uuidToBytes(userId);
  const [existing] = await db.pool.query<RowDataPacket[]>(
    `SELECT id FROM devices WHERE user_id = ? AND name = ? AND platform = ? LIMIT 1`,
    [uidB, name, platform],
  );
  if (existing.length > 0) {
    const id = db.bytesToUuid(existing[0]!["id"] as Buffer);
    await db.pool.query(
      `UPDATE devices SET token_hash = ?, revoked_at = NULL, last_seen_at = UTC_TIMESTAMP(3) WHERE id = ?`,
      [tokenHash, db.uuidToBytes(id)],
    );
    return id;
  }
  const id = uuidv7();
  await db.pool.query(
    `INSERT INTO devices (id, user_id, name, platform, token_hash, created_at) VALUES (?, ?, ?, ?, ?, UTC_TIMESTAMP(3))`,
    [db.uuidToBytes(id), uidB, name, platform, tokenHash],
  );
  return id;
}

export async function deviceByTokenHash(
  db: Db,
  tokenHash: Buffer,
): Promise<{ device: DeviceRow; username: string } | null> {
  const [rows] = await db.pool.query<RowDataPacket[]>(
    `SELECT d.id, d.user_id, d.name, d.platform, d.created_at, d.last_seen_at, d.revoked_at, u.username
     FROM devices d JOIN users u ON u.id = d.user_id WHERE d.token_hash = ?`,
    [tokenHash],
  );
  if (rows.length === 0) return null;
  const r = rows[0]!;
  return {
    device: {
      id: db.bytesToUuid(r["id"] as Buffer),
      userId: db.bytesToUuid(r["user_id"] as Buffer),
      name: r["name"] as string,
      platform: r["platform"] as string,
      createdAt: new Date(r["created_at"] as Date),
      lastSeenAt: (r["last_seen_at"] as Date | null) ?? null,
      revokedAt: (r["revoked_at"] as Date | null) ?? null,
    },
    username: r["username"] as string,
  };
}

export async function listDevices(db: Db, userId: string): Promise<DeviceRow[]> {
  const [rows] = await db.pool.query<RowDataPacket[]>(
    `SELECT id, user_id, name, platform, created_at, last_seen_at, revoked_at FROM devices WHERE user_id = ? ORDER BY created_at`,
    [db.uuidToBytes(userId)],
  );
  return rows.map((r) => ({
    id: db.bytesToUuid(r["id"] as Buffer),
    userId: db.bytesToUuid(r["user_id"] as Buffer),
    name: r["name"] as string,
    platform: r["platform"] as string,
    createdAt: new Date(r["created_at"] as Date),
    lastSeenAt: (r["last_seen_at"] as Date | null) ?? null,
    revokedAt: (r["revoked_at"] as Date | null) ?? null,
  }));
}

/** 吊销指定设备（须属于该用户），返回是否命中。 */
export async function revokeDevice(
  db: Db,
  userId: string,
  deviceId: string,
): Promise<boolean> {
  const [res] = await db.pool.query(
    `UPDATE devices SET revoked_at = UTC_TIMESTAMP(3) WHERE id = ? AND user_id = ? AND revoked_at IS NULL`,
    [db.uuidToBytes(deviceId), db.uuidToBytes(userId)],
  );
  return Number((res as { affectedRows: number }).affectedRows) > 0;
}

export async function touchDevice(db: Db, deviceId: string): Promise<void> {
  await db.pool.query(`UPDATE devices SET last_seen_at = UTC_TIMESTAMP(3) WHERE id = ?`, [
    db.uuidToBytes(deviceId),
  ]);
}

export async function audit(
  db: Db,
  userId: string | null,
  deviceId: string | null,
  action: string,
  targetType: string | null,
  targetId: string | null,
  detail: Record<string, unknown> | null,
  ip: string | null,
): Promise<void> {
  await db.pool.query(
    `INSERT INTO audit_events (ts, actor_user, actor_device, action, target_type, target_id, detail_json, ip)
     VALUES (UTC_TIMESTAMP(3), ?, ?, ?, ?, ?, ?, ?)`,
    [
      userId ? db.uuidToBytes(userId) : null,
      deviceId ? db.uuidToBytes(deviceId) : null,
      action,
      targetType,
      targetId ? db.uuidToBytes(targetId) : null,
      detail ? JSON.stringify(detail) : null,
      ip,
    ],
  );
}

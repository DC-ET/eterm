// 测试辅助：随机命名测试库（并行隔离）+ 迁移 + 清理；未设 ETERM_TEST_DSN 则跳过。

import { createConnection } from "mysql2/promise";
import { randomBytes } from "node:crypto";
import { parseGoDsn } from "../src/config.ts";
import { Db } from "../src/store/db.ts";
import { runMigrations } from "../src/store/migrate.ts";
import * as userstore from "../src/store/userstore.ts";
import { hashPassword } from "../src/auth/argon.ts";
import { v7 as uuidv7 } from "uuid";

export const TEST_KEY = Buffer.from("0123456789abcdef0123456789abcdef", "utf8"); // 32B

export interface TestFixture {
  db: Db;
  dbName: string;
  vaultId: string;
  adminUserId: string;
  cleanup: () => Promise<void>;
}

export async function newTestFixture(
  username = "tester",
  withVault = true,
): Promise<TestFixture> {
  const dsn = process.env.ETERM_TEST_DSN;
  if (!dsn) throw new Error("ETERM_TEST_DSN 未设置");
  const cfg = parseGoDsn(dsn);
  const dbName = `eterm_test_${randomBytes(8).toString("hex")}`;

  const admin = await createConnection({
    host: cfg.host,
    port: cfg.port,
    user: cfg.user,
    password: cfg.password,
    multipleStatements: true,
  });
  await admin.query(
    `CREATE DATABASE \`${dbName}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci`,
  );
  await admin.end();

  await runMigrations({ ...cfg, database: dbName });

  const db = new Db({ ...cfg, database: dbName }, TEST_KEY);
  const adminUserId = await userstore.createUser(db, username, "fake-hash");
  const vaultId = withVault
    ? await userstore.createPersonalVault(db, adminUserId, `${username}-personal`)
    : "";

  const cleanup = async (): Promise<void> => {
    await db.close();
    const a = await createConnection({
      host: cfg.host,
      port: cfg.port,
      user: cfg.user,
      password: cfg.password,
    });
    await a.query(`DROP DATABASE IF EXISTS \`${dbName}\``);
    await a.end();
  };
  return { db, dbName, vaultId, adminUserId, cleanup };
}

/** 与 Go 版 fixture 对齐：以设备身份直接 push 单项。 */
export async function pushOne(
  db: Db,
  vaultId: string,
  deviceId: string,
  entityType: string,
  entityId: string,
  baseRev: number,
  op: string,
  data?: Record<string, unknown>,
): Promise<{ status: string; rev?: number; serverData?: Record<string, unknown>; reason?: string }> {
  const { pushItem } = await import("../src/store/syncstore.ts");
  return pushItem(
    db,
    db.uuidToBytes(vaultId),
    db.uuidToBytes(deviceId),
    { entityType, entityId, baseRev, op, data },
  );
}

export function hostData(label: string): Record<string, unknown> {
  return {
    label,
    hostname: `10.0.0.${label}`,
    tags: ["prod", "db"],
    updated_at: "2026-01-01T00:00:00Z",
  };
}

export function newDevice(): string {
  return uuidv7();
}

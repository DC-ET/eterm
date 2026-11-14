// 迁移运行器：执行 migrations/*.sql（内嵌目录），跟踪于 schema_migrations 表。
// DDL 与 Go 版 00001 完全一致；MySQL multipleStatements 仅在迁移连接上启用。

import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createConnection } from "mysql2/promise";
import type { DbConfig } from "../config.ts";

const MIGRATIONS_DIR = join(dirname(fileURLToPath(import.meta.url)), "../../migrations");

export async function runMigrations(cfg: DbConfig): Promise<void> {
  const conn = await createConnection({
    host: cfg.host,
    port: cfg.port,
    user: cfg.user,
    password: cfg.password,
    database: cfg.database,
    multipleStatements: true, // 迁移文件为多语句脚本（仅限迁移连接）
    timezone: "Z",
  });
  try {
    await conn.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
      version INT PRIMARY KEY,
      applied_at DATETIME(3) NOT NULL
    ) ENGINE=InnoDB`);

    // 兼容 Go/goose 时代的库：schema 已存在但无本跟踪表时，
    // 读取 goose_db_version 的最大版本作为基线收编，避免重放 DDL。
    const [gooseTables] = await conn.query(`SHOW TABLES LIKE 'goose_db_version'`);
    if ((gooseTables as unknown[]).length > 0) {
      const [grows] = await conn.query(`SELECT COALESCE(MAX(version_id), 0) AS v FROM goose_db_version`);
      const baseline = Number((grows as { v: number }[])[0]!.v);
      const files0 = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith(".sql")).sort();
      for (const file of files0) {
        const version = Number(file.split("_")[0]);
        if (version <= baseline) {
          await conn.query(
            `INSERT IGNORE INTO schema_migrations (version, applied_at) VALUES (?, UTC_TIMESTAMP(3))`,
            [version],
          );
        }
      }
      console.log(`已收编 goose 基线: version ≤ ${baseline}`);
    }

    const [rows] = await conn.query(`SELECT version FROM schema_migrations`);
    const applied = new Set((rows as { version: number }[]).map((r) => Number(r.version)));

    const files = readdirSync(MIGRATIONS_DIR)
      .filter((f) => f.endsWith(".sql"))
      .sort();
    for (const file of files) {
      const version = Number(file.split("_")[0]);
      if (applied.has(version)) continue;
      const sql = readFileSync(join(MIGRATIONS_DIR, file), "utf8")
        // 去掉 goose 注解段（历史格式沿用；Down 段不执行）
        .replace(/-- \+goose Down[\s\S]*$/, "-- +goose Down (skipped)");
      console.log(`applying migration ${file} ...`);
      await conn.query(sql);
      await conn.query(`INSERT INTO schema_migrations (version, applied_at) VALUES (?, UTC_TIMESTAMP(3))`, [version]);
    }
    console.log("迁移完成");
  } finally {
    await conn.end();
  }
}

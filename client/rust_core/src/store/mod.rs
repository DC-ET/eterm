//! 本地库（rusqlite）：离线 working set。
//! 表结构与服务端 §3.2 同构，另加客户端私有表 sync_state / outbox（技术方案 §4.2）。
//! 敏感字段以本地库主密钥（LKMK，来自 OS 钥匙串）经 util::field 加密落盘。

use rusqlite::Connection;

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("sqlite: {0}")]
    Sqlite(#[from] rusqlite::Error),
}

/// 打开（或初始化）本地库。M0 骨架：建 sync_state / outbox 两张私有表。
pub fn open(conn: &Connection) -> Result<(), StoreError> {
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA foreign_keys = ON;
         CREATE TABLE IF NOT EXISTS sync_state (
             entity_type TEXT PRIMARY KEY,
             dirty       INTEGER NOT NULL DEFAULT 0,
             last_error  TEXT,
             updated_at  TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS outbox (
             id           INTEGER PRIMARY KEY AUTOINCREMENT,
             entity_type  TEXT NOT NULL,
             entity_id    TEXT NOT NULL,
             op           TEXT NOT NULL CHECK (op IN ('upsert','delete')),
             payload_json TEXT NOT NULL,
             attempts     INTEGER NOT NULL DEFAULT 0,
             next_retry_at TEXT NOT NULL
         );",
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;

    #[test]
    fn init_creates_private_tables() {
        let conn = Connection::open_in_memory().unwrap();
        open(&conn).unwrap();
        let n: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('sync_state','outbox')",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(n, 2);
    }
}

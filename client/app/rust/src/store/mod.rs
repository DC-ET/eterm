//! 本地库（rusqlite）：离线 working set（技术方案 §4.2）。
//! entities 缓存中枢折叠结果（data_json 以 LKMK 密文落盘）；kv 存会话与同步游标
//! （token 以 LKMK 密文落盘）。M1 由 Dart 驱动 HTTP，Rust 只负责缓存/加密/游标。

use std::sync::Mutex;

use rusqlite::Connection;
use serde::{Deserialize, Serialize};

use crate::util::{open_field, seal_field};

/// 全局连接（init 在应用启动时执行一次）。
static DB: Mutex<Option<Connection>> = Mutex::new(None);
static LKMK: Mutex<Option<Vec<u8>>> = Mutex::new(None);

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error("sqlite: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("store: {0}")]
    Other(String),
}

/// 打开/初始化本地库（幂等）。
pub fn open(db_path: &str) -> Result<(), StoreError> {
    let conn = Connection::open(db_path)?;
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         CREATE TABLE IF NOT EXISTS entities (
             entity_type TEXT NOT NULL,
             entity_id   TEXT NOT NULL,
             rev         INTEGER NOT NULL,
             data_enc    TEXT NOT NULL,
             deleted     INTEGER NOT NULL DEFAULT 0,
             PRIMARY KEY (entity_type, entity_id)
         );
         CREATE TABLE IF NOT EXISTS kv (
             k TEXT PRIMARY KEY,
             v TEXT NOT NULL
         );",
    )?;
    *DB.lock().unwrap() = Some(conn);
    Ok(())
}

/// 确保 LKMK 就绪（macOS 钥匙串取/建）。与 open() 分离：
/// 单测不触钥匙串（security-framework 首次访问会弹 GUI 授权框，阻塞无头进程）。
pub fn ensure_lkmk() -> Result<(), StoreError> {
    if LKMK.lock().unwrap().is_none() {
        let key = crate::util::keystore::load_or_create_lkmk().map_err(StoreError::Other)?;
        *LKMK.lock().unwrap() = Some(key);
    }
    Ok(())
}

/// 测试注入 LKMK（钥匙串未就绪的环境）。
#[cfg(test)]
pub fn set_lkmk_for_test(key: Vec<u8>) {
    *LKMK.lock().unwrap() = Some(key);
}

fn with_db<T>(f: impl FnOnce(&Connection) -> Result<T, StoreError>) -> Result<T, StoreError> {
    let guard = DB.lock().unwrap();
    let conn = guard.as_ref().ok_or_else(|| StoreError::Other("本地库未初始化".into()))?;
    f(conn)
}

fn seal(plaintext: &str) -> Result<String, StoreError> {
    let key = LKMK.lock().unwrap().clone().ok_or_else(|| StoreError::Other("LKMK 未就绪".into()))?;
    seal_field(&key, plaintext.as_bytes()).map_err(|e| StoreError::Other(e.to_string()))
}

fn unseal(sealed: &str) -> Result<String, StoreError> {
    let key = LKMK.lock().unwrap().clone().ok_or_else(|| StoreError::Other("LKMK 未就绪".into()))?;
    let bytes = open_field(&key, sealed).map_err(|e| StoreError::Other(e.to_string()))?;
    String::from_utf8(bytes).map_err(|e| StoreError::Other(e.to_string()))
}

// ---------- 会话（token 密文落盘） ----------

pub fn save_session(server: &str, token: &str) -> Result<(), StoreError> {
    let sealed = seal(token)?;
    with_db(|c| {
        c.execute(
            "INSERT INTO kv(k,v) VALUES('server',?1) ON CONFLICT(k) DO UPDATE SET v=?1",
            [server],
        )?;
        c.execute(
            "INSERT INTO kv(k,v) VALUES('token',?1) ON CONFLICT(k) DO UPDATE SET v=?1",
            [sealed],
        )?;
        Ok(())
    })
}

/// 恢复会话；(server, token)。无会话返回 Ok(None)。
pub fn restore_session() -> Result<Option<(String, String)>, StoreError> {
    with_db(|c| {
        let server: Option<String> = c
            .query_row("SELECT v FROM kv WHERE k='server'", [], |r| r.get(0))
            .ok();
        let token_enc: Option<String> = c
            .query_row("SELECT v FROM kv WHERE k='token'", [], |r| r.get(0))
            .ok();
        match (server, token_enc) {
            (Some(s), Some(t)) => Ok(Some((s, unseal(&t)?))),
            _ => Ok(None),
        }
    })
}

pub fn clear_session() -> Result<(), StoreError> {
    with_db(|c| {
        c.execute("DELETE FROM kv WHERE k IN ('server','token')", [])?;
        Ok(())
    })
}

// ---------- 实体缓存（中枢折叠结果的镜像） ----------

/// pull 的单条变更（wire 形态，对齐服务端 PullChange）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WireChange {
    #[serde(rename = "entity_type")]
    pub entity_type: String,
    #[serde(rename = "entity_id")]
    pub entity_id: String,
    pub op: String, // upsert | delete
    #[serde(default)]
    pub data: Option<serde_json::Value>,
}

/// 应用一批变更（upsert 覆盖 / delete 置墓碑）并推进游标。
pub fn apply_changes(changes: &[WireChange], cursor: u64) -> Result<(), StoreError> {
    with_db(|c| {
        for ch in changes {
            let deleted = if ch.op == "delete" { 1 } else { 0 };
            let rev: i64 = ch
                .data
                .as_ref()
                .and_then(|d| d.get("rev"))
                .and_then(|v| v.as_i64())
                .unwrap_or(0);
            let data_enc = match &ch.data {
                Some(d) => seal(&d.to_string())?,
                None => String::new(),
            };
            c.execute(
                "INSERT INTO entities(entity_type, entity_id, rev, data_enc, deleted)
                 VALUES(?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(entity_type, entity_id) DO UPDATE SET
                   rev=?3, data_enc=?4, deleted=?5",
                rusqlite::params![ch.entity_type, ch.entity_id, rev, data_enc, deleted],
            )?;
        }
        c.execute(
            "INSERT INTO kv(k,v) VALUES('cursor',?1) ON CONFLICT(k) DO UPDATE SET v=?1",
            [cursor.to_string()],
        )?;
        Ok(())
    })
}

/// 读取游标。
pub fn cursor() -> Result<u64, StoreError> {
    with_db(cursor_inner)
}

fn cursor_inner(c: &Connection) -> Result<u64, StoreError> {
    let v: Option<String> = c
        .query_row("SELECT v FROM kv WHERE k='cursor'", [], |r| r.get(0))
        .ok();
    Ok(v.and_then(|s| s.parse().ok()).unwrap_or(0))
}

/// 快照：全部未删除实体（解密后的 wire data）+ 游标，供 Dart 折叠视图。
pub fn snapshot_json() -> Result<String, StoreError> {
    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    struct Snap {
        cursor: u64,
        entities: std::collections::BTreeMap<String, serde_json::Value>,
    }
    with_db(|c| {
        let mut stmt = c.prepare(
            "SELECT entity_type, entity_id, data_enc FROM entities WHERE deleted=0",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })?;
        let mut entities = std::collections::BTreeMap::new();
        for row in rows {
            let (t, id, enc) = row?;
            let data: serde_json::Value = serde_json::from_str(&unseal(&enc)?)
                .map_err(|e| StoreError::Other(e.to_string()))?;
            entities.insert(format!("{t}/{id}"), data);
        }
        let cur = cursor_inner(c)?;
        serde_json::to_string(&Snap { cursor: cur, entities })
            .map_err(|e| StoreError::Other(e.to_string()))
    })
}

/// 清空缓存（登出时调用；会话 kv 由 clear_session 单独处理）。
pub fn clear_entities() -> Result<(), StoreError> {
    with_db(|c| {
        c.execute("DELETE FROM entities", [])?;
        c.execute("DELETE FROM kv WHERE k='cursor'", [])?;
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fold_and_snapshot() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("t.db");
        open(path.to_str().unwrap()).unwrap();
        // 单测不触钥匙串：直接注入确定性 LKMK
        set_lkmk_for_test(vec![7u8; 32]);
        let changes = vec![
            WireChange {
                entity_type: "host".into(),
                entity_id: "h1".into(),
                op: "upsert".into(),
                data: Some(serde_json::json!({"id": "h1", "label": "web", "rev": 3})),
            },
            WireChange {
                entity_type: "identity".into(),
                entity_id: "i1".into(),
                op: "upsert".into(),
                data: Some(serde_json::json!({"id": "i1", "password_enc": "pw"})),
            },
        ];
        apply_changes(&changes, 42).unwrap();
        assert_eq!(cursor().unwrap(), 42);
        let snap = snapshot_json().unwrap();
        assert!(snap.contains("\"web\""));
        assert!(snap.contains("pw"));
        // 墓碑
        let del = vec![WireChange {
            entity_type: "host".into(),
            entity_id: "h1".into(),
            op: "delete".into(),
            data: None,
        }];
        apply_changes(&del, 43).unwrap();
        let snap = snapshot_json().unwrap();
        assert!(!snap.contains("\"web\""));
        assert!(snap.contains("pw"));
    }
}

// ---------- 通用 kv（非敏感项：用户名等；敏感项走 save_session 密文） ----------

pub fn kv_put(key: &str, value: &str) -> Result<(), StoreError> {
    with_db(|c| {
        c.execute(
            "INSERT INTO kv(k,v) VALUES(?1,?2) ON CONFLICT(k) DO UPDATE SET v=?2",
            [key, value],
        )?;
        Ok(())
    })
}

pub fn kv_get(key: &str) -> Result<Option<String>, StoreError> {
    with_db(|c| {
        Ok(c.query_row("SELECT v FROM kv WHERE k=?1", [key], |r| r.get(0)).ok())
    })
}

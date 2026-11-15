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
         );
         CREATE TABLE IF NOT EXISTS events (
             id INTEGER PRIMARY KEY AUTOINCREMENT,
             ts TEXT NOT NULL,
             kind TEXT NOT NULL,
             detail TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS known_hosts (
             host_key    TEXT PRIMARY KEY, -- host:port
             fingerprint TEXT NOT NULL,    -- SHA256:base64(nopad)（OpenSSH 现代格式）
             key_type    TEXT NOT NULL,
             first_seen  TEXT NOT NULL
         );",
    )?;
    *DB.lock().unwrap() = Some(conn);
    Ok(())
}

/// 确保 LKMK 就绪（macOS 钥匙串取/建；Android 沙箱文件兜底）。与 open() 分离：
/// 单测不触钥匙串（security-framework 首次访问会弹 GUI 授权框，阻塞无头进程）。
pub fn ensure_lkmk(data_dir: &str) -> Result<(), StoreError> {
    if LKMK.lock().unwrap().is_none() {
        let key =
            crate::util::keystore::load_or_create_lkmk(data_dir).map_err(StoreError::Other)?;
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

// ---------- known_hosts（TOFU 主机信任，设备级；登出不清理） ----------

/// 已信任主机键（Known Hosts 页与 SSH 校验共用）。
#[derive(Debug, Clone, serde::Serialize)]
pub struct KnownHost {
    pub host: String,        // "host:port"
    pub fingerprint: String, // SHA256:base64(nopad)
    pub key_type: String,    // ssh-ed25519 / rsa-sha2-512 / ...
    pub first_seen: String,  // RFC3339 UTC
}

/// 列出全部已信任主机（按 first_seen 倒序）。
pub fn known_hosts_list() -> Result<Vec<KnownHost>, StoreError> {
    with_db(|c| {
        let mut stmt = c.prepare(
            "SELECT host_key, fingerprint, key_type, first_seen
             FROM known_hosts ORDER BY first_seen DESC",
        )?;
        let rows = stmt
            .query_map([], |r| {
                Ok(KnownHost {
                    host: r.get(0)?,
                    fingerprint: r.get(1)?,
                    key_type: r.get(2)?,
                    first_seen: r.get(3)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    })
}

/// 取已记录指纹；未记录返回 None（TOFU 首次）。
pub fn known_host_get(host_key: &str) -> Result<Option<String>, StoreError> {
    with_db(|c| {
        let mut stmt = c
            .prepare("SELECT fingerprint FROM known_hosts WHERE host_key = ?1")?;
        let mut rows = stmt.query_map([host_key], |r| r.get::<_, String>(0))?;
        Ok(rows.next().transpose()?)
    })
}

/// 记录/更新主机指纹（TOFU 首次信任）。
pub fn known_host_put(
    host_key: &str,
    fingerprint: &str,
    key_type: &str,
    first_seen: &str,
) -> Result<(), StoreError> {
    with_db(|c| {
        c.execute(
            "INSERT INTO known_hosts (host_key, fingerprint, key_type, first_seen)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(host_key) DO UPDATE SET
               fingerprint = excluded.fingerprint,
               key_type = excluded.key_type",
            rusqlite::params![host_key, fingerprint, key_type, first_seen],
        )?;
        Ok(())
    })
}

/// 移除主机信任（Known Hosts 页删除；下次连接重新 TOFU）。
pub fn known_host_remove(host_key: &str) -> Result<(), StoreError> {
    with_db(|c| {
        c.execute("DELETE FROM known_hosts WHERE host_key = ?1", [host_key])?;
        Ok(())
    })
}

// ---------- 本地事件日志（Logs 页；连接/主机/密钥动作，设备级） ----------

/// RFC3339 UTC（展示用途）。
pub fn super_utc_now_rfc3339() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let days = secs / 86_400;
    let rem = secs % 86_400;
    let (h, m, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let mut y = 1970i64;
    let mut d = days as i64;
    loop {
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
        let yl = if leap { 366 } else { 365 };
        if d < yl { break; }
        d -= yl;
        y += 1;
    }
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let ml = [31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let mut mo = 1;
    while d >= ml[(mo - 1) as usize] { d -= ml[(mo - 1) as usize]; mo += 1; }
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{m:02}:{s:02}Z")
}

/// 一条本地事件（时间倒序展示）。
#[derive(Debug, Clone, serde::Serialize)]
pub struct EventRow {
    pub id: i64,
    pub ts: String,
    pub kind: String,  // connect_ok | connect_fail | disconnect | host_add | host_edit | host_delete | key_delete
    pub detail: String,
}

/// 追加事件（非敏感：只存主机名与动作，不存凭据）。
pub fn log_event(kind: &str, detail: &str) -> Result<(), StoreError> {
    let ts = super_utc_now_rfc3339();
    with_db(|c| {
        c.execute(
            "INSERT INTO events (ts, kind, detail) VALUES (?1, ?2, ?3)",
            rusqlite::params![ts, kind, detail],
        )?;
        // 上限 500 条：超出删最旧
        c.execute(
            "DELETE FROM events WHERE id NOT IN (SELECT id FROM events ORDER BY id DESC LIMIT 500)",
            [],
        )?;
        Ok(())
    })
}

/// 事件列表（新→旧，最多 500）。
pub fn events_list() -> Result<Vec<EventRow>, StoreError> {
    with_db(|c| {
        let mut stmt = c.prepare("SELECT id, ts, kind, detail FROM events ORDER BY id DESC")?;
        let rows = stmt
            .query_map([], |r| {
                Ok(EventRow {
                    id: r.get(0)?,
                    ts: r.get(1)?,
                    kind: r.get(2)?,
                    detail: r.get(3)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    })
}

/// 清空事件。
pub fn events_clear() -> Result<(), StoreError> {
    with_db(|c| {
        c.execute("DELETE FROM events", [])?;
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

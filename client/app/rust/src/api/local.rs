//! 本地库 FFI 面（M1）：初始化（sqlite + LKMK）、会话持久化、实体缓存读写。
//! Dart 侧负责 HTTP 与视图模型；Rust 负责落盘、加密与同步游标。

use crate::store;
use crate::store::WireChange;

/// 应用启动时调用一次：data_dir 为平台应用支持目录（Dart 侧 path_provider 提供）。
/// 建库 data_dir/eterm.db 并确保 LKMK 就绪。
#[flutter_rust_bridge::frb(sync)]
pub fn init_core(data_dir: String) -> Result<(), String> {
    std::fs::create_dir_all(&data_dir).map_err(|e| e.to_string())?;
    let db_path = format!("{data_dir}/eterm.db");
    store::open(&db_path).map_err(|e| e.to_string())?;
    store::ensure_lkmk(&data_dir).map_err(|e| e.to_string())
}

/// 保存会话（token 以 LKMK 密文落盘）。
#[flutter_rust_bridge::frb(sync)]
pub fn save_session(server: String, token: String) -> Result<(), String> {
    store::save_session(&server, &token).map_err(|e| e.to_string())
}

/// 恢复会话：(server, token)；无会话返回空。
#[flutter_rust_bridge::frb(sync)]
pub fn restore_session() -> Result<Vec<String>, String> {
    Ok(store::restore_session()
        .map_err(|e| e.to_string())?
        .map(|(s, t)| vec![s, t])
        .unwrap_or_default())
}

/// 登出：清会话 + 清实体缓存。
#[flutter_rust_bridge::frb(sync)]
pub fn clear_local() -> Result<(), String> {
    store::clear_session().map_err(|e| e.to_string())?;
    store::clear_entities().map_err(|e| e.to_string())
}

/// 应用一批 pull 变更并推进游标（changes 为 wire JSON 数组字符串）。
#[flutter_rust_bridge::frb(sync)]
pub fn store_apply(changes_json: String, cursor: u64) -> Result<(), String> {
    let changes: Vec<WireChange> =
        serde_json::from_str(&changes_json).map_err(|e| e.to_string())?;
    store::apply_changes(&changes, cursor).map_err(|e| e.to_string())
}

/// 全量快照 JSON：{"cursor": N, "entities": {"type/id": {...}}}（已解密）。
#[flutter_rust_bridge::frb(sync)]
pub fn store_load() -> Result<String, String> {
    store::snapshot_json().map_err(|e| e.to_string())
}

/// 当前同步游标。
#[flutter_rust_bridge::frb(sync)]
pub fn store_cursor() -> Result<u64, String> {
    store::cursor().map_err(|e| e.to_string())
}

/// 通用 kv 写（非敏感项；token 走 save_session）。
#[flutter_rust_bridge::frb(sync)]
pub fn kv_put(key: String, value: String) -> Result<(), String> {
    store::kv_put(&key, &value).map_err(|e| e.to_string())
}

/// 通用 kv 读；不存在返回空串。
#[flutter_rust_bridge::frb(sync)]
pub fn kv_get(key: String) -> Result<String, String> {
    Ok(store::kv_get(&key).map_err(|e| e.to_string())?.unwrap_or_default())
}

//! 同步引擎骨架（技术方案 §3.4 状态机）。HTTP/WS 实现随 spike S3（frb 流式边界）落地。

use serde::{Deserialize, Serialize};

/// 服务端 pull 的单条变更（wire 形态，与服务端 PullChange 对齐）。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Change {
    #[serde(rename = "entity_type")]
    pub entity_type: String,
    #[serde(rename = "entity_id")]
    pub entity_id: String,
    pub op: String, // upsert | delete
    pub rev: u64,
    pub ts: String,
    #[serde(default)]
    pub data: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PullResponse {
    pub cursor: u64,
    pub has_more: bool,
    pub changes: Vec<Change>,
}

/// push 单项结果状态。
pub const STATUS_OK: &str = "ok";
pub const STATUS_CONFLICT: &str = "conflict";
pub const STATUS_REJECTED: &str = "rejected";

/// 同步引擎运行状态（供 UI 投影）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SyncPhase {
    Idle,
    Pulling,
    Pushing,
    Backoff,
    Offline,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_pull_response() {
        let j = r#"{"cursor":42,"has_more":false,"changes":[
            {"entity_type":"host","entity_id":"0190-aa","op":"upsert","rev":42,"ts":"2026-01-01T00:00:00.000Z","data":{"label":"x"}}
        ]}"#;
        let p: PullResponse = serde_json::from_str(j).unwrap();
        assert_eq!(p.cursor, 42);
        assert_eq!(p.changes[0].entity_type, "host");
        assert_eq!(p.changes[0].data.as_ref().unwrap()["label"], "x");
    }
}

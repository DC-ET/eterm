//! frb 导出门面（技术方案 §4.4）。M0 骨架：接口占位，flutter_rust_bridge 集成在 spike S3 落地。
//! 约束：FFI 边界不 panic；错误统一 EtermError。

#[derive(Debug, thiserror::Error)]
pub enum EtermError {
    #[error("store: {0}")]
    Store(String),
    #[error("sync: {0}")]
    Sync(String),
    #[error("ssh: {0}")]
    Ssh(String),
}

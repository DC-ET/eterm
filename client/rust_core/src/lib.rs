//! eterm 客户端核心（技术方案 §4.2）：本地库、同步引擎、SSH/SFTP/keygen。
//! 模块依赖单向：api → {sync, ssh, sftp, keygen} → store。
//! 当前为 M0 骨架：字段加密（与服务端 v1 格式同构）与本地库可用，
//! russh/frb 集成随 spike S2/S3 落地。

pub mod api;
pub mod keygen;
pub mod sftp;
pub mod ssh;
pub mod store;
pub mod sync;
pub mod util;

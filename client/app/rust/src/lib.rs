//! eterm 客户端核心：api（frb 导出面：ssh 会话 / local 本地库）→ store（本地库）
//! → util（LKMK 与字段加密）。wire 类型以 store::WireChange 为准。
//! SSH/SFTP/keygen 的独立模块化拆分待对应功能落地时再引入。

mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */

pub mod api;
pub mod store;
pub mod util;

//! frb 约定钩子（模板必需）。业务 API 见 ssh.rs / local.rs。

/// frb 初始化钩子（flutter_rust_bridge 模板约定）。
#[flutter_rust_bridge::frb(init)]
pub fn init_app() {}

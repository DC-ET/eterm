//! frb 导出面（S3 spike 首批）：基础调用、字段加解密（真实核心路径）、流式回显。
//! 约束：FFI 边界不 panic；错误以可序列化形态返回。

use crate::frb_generated::StreamSink;
use crate::util::{open_field as core_open, seal_field as core_seal};

/// 保留模板的初始化钩子（frb 约定）。
#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    // Default utilities - feel free to customize
}

#[flutter_rust_bridge::frb(sync)]
pub fn ping(msg: String) -> String {
    format!("pong: {msg}")
}

/// 服务端/本地库同构的 v1 字段加密（util::field 的 FFI 面）。
pub fn seal_field(key: Vec<u8>, plaintext: Vec<u8>) -> Result<String, String> {
    core_seal(&key, &plaintext).map_err(|e| e.to_string())
}

pub fn open_field(key: Vec<u8>, sealed: String) -> Result<Vec<u8>, String> {
    core_open(&key, &sealed).map_err(|e| e.to_string())
}

/// 流式回显：count 帧，每帧 size 字节（帧首字节为序号），用于 Dart 侧测量流延迟与吞吐。
/// frb v2 的 Rust→Dart 流采用 StreamSink 参数模式（Dart 侧表现为返回 Stream）。
pub fn stream_echo(count: u32, size: usize, sink: StreamSink<Vec<u8>>) -> Result<(), String> {
    let size = size.max(1);
    for i in 0..count {
        let mut v = vec![0u8; size];
        v[0] = (i & 0xFF) as u8;
        sink.add(v).map_err(|e| e.to_string())?;
    }
    Ok(())
}

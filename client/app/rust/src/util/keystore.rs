//! 本地主密钥（LKMK）存取：统一走应用沙箱内文件（0600）。
//!
//! 为什么不用 macOS login keychain：debug 构建每次 ad-hoc 签名变化，
//! 钥匙串 ACL 随之失配，SecItemCopyMatching 会在主线程同步弹出
//! "eterm 想要访问钥匙串" 授权框并阻塞（frb 非异步调用跑在 UI 线程），
//! 首帧无法提交 → 应用黑屏且弹窗藏在 SecurityAgent 里难以察觉。
//! LKMK 保护的是 app support 目录下 sqlite 的字段加密；0600 文件
//! （用户目录、沙箱路径）威胁模型足够。正式签名发布如需钥匙串可再引入。

use std::path::Path;

/// 取（或首次生成）LKMK。data_dir 为应用沙箱目录。
pub fn load_or_create_lkmk(data_dir: &str) -> Result<Vec<u8>, String> {
    let path = Path::new(data_dir).join("lkmk.bin");
    if path.exists() {
        return std::fs::read(&path).map_err(|e| format!("读取 LKMK 失败: {e}"));
    }
    let key: [u8; 32] = rand::random();
    std::fs::write(&path, key).map_err(|e| format!("写入 LKMK 失败: {e}"))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(key.to_vec())
}

//! 本地主密钥（LKMK）存取：macOS 存钥匙串（generic password）；
//! Android 走应用沙箱内文件兜底（OS 私有目录其他应用不可读；Keystore 硬件绑定
//! 随移动端深入落地）。首次调用生成 32 字节随机密钥并写入，后续原样读回。

/// 取（或首次生成）LKMK。data_dir 供 Android 文件兜底使用（macOS 忽略）。
pub fn load_or_create_lkmk(data_dir: &str) -> Result<Vec<u8>, String> {
    #[cfg(target_os = "macos")]
    {
        const SERVICE: &str = "eterm";
        const ACCOUNT: &str = "lkmk-v1";
        match security_framework::passwords::get_generic_password(SERVICE, ACCOUNT) {
            Ok(v) if v.len() == 32 => Ok(v),
            Ok(_) => Err("钥匙串中的 LKMK 长度异常".to_string()),
            Err(_) => {
                let key: [u8; 32] = rand::random();
                security_framework::passwords::set_generic_password(SERVICE, ACCOUNT, &key)
                    .map_err(|e| format!("写入钥匙串失败: {e}"))?;
                Ok(key.to_vec())
            }
        }
    }
    #[cfg(target_os = "android")]
    {
        let path = std::path::Path::new(data_dir).join("lkmk.bin");
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
    #[cfg(not(any(target_os = "macos", target_os = "android")))]
    {
        let _ = data_dir;
        Err("当前平台 LKMK 存取未实现".to_string())
    }
}

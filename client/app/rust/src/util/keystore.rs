//! 本地主密钥（LKMK）存取：macOS 存钥匙串（generic password）；
//! 其他平台 M1 返回错误（Android 走平台沙箱目录文件兜底，随 Android 客户端落地）。
//! 首次调用生成 32 字节随机密钥并写入，后续原样读回。

/// 取（或首次生成）LKMK。
pub fn load_or_create_lkmk() -> Result<Vec<u8>, String> {
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
    #[cfg(not(target_os = "macos"))]
    {
        Err("当前平台钥匙串存取未实现（Android 兜底随移动端落地）")
    }
}

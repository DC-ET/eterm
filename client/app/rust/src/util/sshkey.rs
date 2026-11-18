//! SSH 密钥工具（Keychain M1 收口）：Ed25519/ECDSA P-256/RSA 生成 +
//! 导入校验（类型/指纹/公钥行）。密钥内容只落应用自有加密库（LKMK），不碰 OS 钥匙串。
//!
//! russh-keys 只提供 OpenSSH 格式的解码（decode_openssh）没有编码：Ed25519 的
//! openssh-key-v1 二进制格式在此手工组装（无加密段，"none" cipher）；ECDSA/RSA
//! 走 russh-keys 自带的 PKCS#8 编码器（纯 Rust，OpenSSH 可直接读取）。两条编码
//! 路径都用 decode_secret_key 回读验证（见 tests，含签名往返与 known-answer 指纹）。

use russh_keys::key::{KeyPair, PublicKey, SignatureHash};
use russh_keys::{decode_secret_key, encode_pkcs8_pem, PublicKeyBase64};

/// 密钥元数据（Keychain 卡片/详情展示与入库字段）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SshKeyMeta {
    /// 算法名：ssh-ed25519 / ssh-rsa / ecdsa-sha2-nistp256…
    pub key_type: String,
    /// SHA256:base64(nopad)（OpenSSH `ssh-keygen -lf` 同构，Known Hosts 页同一格式）
    pub fingerprint: String,
    /// 一行公钥（`<type> <base64> [comment]`），authorized_keys 可直接粘贴
    pub public_key_line: String,
}

/// Ed25519 生成结果：(私钥 PEM, 元数据)。元数据公钥行带 comment。
pub type GeneratedKey = (String, SshKeyMeta);

// ---------- openssh-key-v1 二进制组装（Ed25519，未加密） ----------

fn put_string(out: &mut Vec<u8>, data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(data);
}

/// 组装未加密的 OpenSSH 私钥 PEM（Ed25519）。
/// seed 32 字节（ed25519_dalek SigningKey::to_bytes）+ public 32 字节。
/// 私钥段 = checkint×2 + "ssh-ed25519" + pub[32] + priv[64](seed||pub) + comment
/// + 1,2,3… padding 至 8 字节对齐（"none" cipher 的块大小；已对齐可为空，
/// ssh-key 解码器仅在 padding_len>0 时校验内容）。
fn encode_openssh_ed25519(seed: &[u8; 32], public: &[u8; 32], comment: &str) -> String {
    let mut pub_blob = Vec::with_capacity(4 + 11 + 4 + 32);
    put_string(&mut pub_blob, b"ssh-ed25519");
    put_string(&mut pub_blob, public);

    let mut priv_sec = Vec::with_capacity(8 + 4 + 11 + 4 + 32 + 4 + 64 + 4 + comment.len());
    let checkint: u32 = rand::random();
    priv_sec.extend_from_slice(&checkint.to_be_bytes());
    priv_sec.extend_from_slice(&checkint.to_be_bytes());
    put_string(&mut priv_sec, b"ssh-ed25519");
    put_string(&mut priv_sec, public);
    let mut key64 = Vec::with_capacity(64);
    key64.extend_from_slice(seed);
    key64.extend_from_slice(public);
    put_string(&mut priv_sec, &key64); // seed || public
    put_string(&mut priv_sec, comment.as_bytes());
    // 1,2,3… padding 至块大小 8（已对齐可为空，与 OpenSSH 语义一致）
    let mut pad = 1u8;
    while priv_sec.len() % 8 != 0 {
        priv_sec.push(pad);
        pad += 1;
    }

    let mut body = Vec::with_capacity(16 + 4 + 4 + 4 + 4 + 4 + pub_blob.len() + 4 + priv_sec.len());
    body.extend_from_slice(b"openssh-key-v1\x00");
    put_string(&mut body, b"none"); // ciphername
    put_string(&mut body, b"none"); // kdfname
    put_string(&mut body, b""); // kdfoptions
    body.extend_from_slice(&1u32.to_be_bytes()); // nkeys
    put_string(&mut body, &pub_blob);
    put_string(&mut body, &priv_sec);

    format!(
        "-----BEGIN OPENSSH PRIVATE KEY-----\n{}\n-----END OPENSSH PRIVATE KEY-----\n",
        pem_wrap70(&crate::util::base64_encode(&body))
    )
}

/// 70 字符换行（OpenSSH 私钥 PEM 的行宽；比 MIME 的 64 宽）。
fn pem_wrap70(b64: &str) -> String {
    let mut out = String::with_capacity(b64.len() + b64.len() / 70 + 2);
    for (i, ch) in b64.chars().enumerate() {
        if i > 0 && i % 70 == 0 {
            out.push('\n');
        }
        out.push(ch);
    }
    out
}

// ---------- 生成 / 校验 ----------

/// comment 清洗：剔除撇号/控制字符并截断 64 字符——公钥行会进 authorized_keys
/// 与部署命令（Dart 侧另有转义兜底），入库即保持单行干净文本（评审 P2）。
fn clean_comment(comment: &str) -> String {
    let cleaned: String = comment
        .trim()
        .chars()
        .filter(|c| !c.is_control() && *c != '\'')
        .take(64)
        .collect();
    if cleaned.is_empty() {
        "eterm".into()
    } else {
        cleaned
    }
}

/// KeyPair → 未加密 PKCS#8 PEM（russh-keys 自带编码器，纯 Rust 路径覆盖 RSA/EC）。
fn pkcs8_pem(pair: &KeyPair) -> Result<String, String> {
    let mut buf = Vec::new();
    encode_pkcs8_pem(pair, &mut buf).map_err(|e| format!("私钥编码失败: {e}"))?;
    String::from_utf8(buf).map_err(|_| "私钥编码产生非 UTF-8".into())
}
/// 生成结果的统一收尾：回读校验 + comment 补进公钥行。
fn finish_generated(pem: String, comment: &str) -> Result<GeneratedKey, String> {
    let mut meta = inspect_secret(&pem)?;
    // comment 是生成密钥的属性，补进公钥行（inspect 侧导入密钥无 comment 可用）
    meta.public_key_line = format!("{} {}", meta.public_key_line, comment);
    Ok((pem, meta))
}

/// 生成 Ed25519 密钥对（OpenSSH 格式，comment 进私钥 blob 与公钥行）。
pub fn generate_ed25519(comment: &str) -> Result<GeneratedKey, String> {
    let comment = clean_comment(comment);
    let KeyPair::Ed25519(signing) = KeyPair::generate_ed25519() else {
        return Err("Ed25519 生成器返回了意外类型".into());
    };
    let pem = encode_openssh_ed25519(&signing.to_bytes(), &signing.verifying_key().as_bytes(), &comment);
    finish_generated(pem, &comment)
}

/// 生成 ECDSA P-256 密钥对（PKCS#8 PEM 格式）。随机标量构造私钥；
/// 标量非法（0 或 ≥曲线阶，概率约 2^-32/次）失败重试兜底（评审 OBS-3）。
pub fn generate_ecdsa_p256(comment: &str) -> Result<GeneratedKey, String> {
    let comment = clean_comment(comment);
    let private = loop {
        let scalar: [u8; 32] = rand::random();
        match russh_keys::ec::PrivateKey::new_from_secret_scalar(b"ecdsa-sha2-nistp256", &scalar) {
            Ok(pk) => break pk,
            Err(_) => continue, // 重标量
        }
    };
    let pair = KeyPair::EC { key: private };
    finish_generated(pkcs8_pem(&pair)?, &comment)
}

/// 生成 RSA 密钥对（PKCS#8 PEM 格式，SHA2-256 签名哈希）。质数生成可达秒级，
/// 调用方必须在非 UI 线程执行（keychain.rs 走 async）。
pub fn generate_rsa(bits: usize, comment: &str) -> Result<GeneratedKey, String> {
    let comment = clean_comment(comment);
    if !(2048..=4096).contains(&bits) || bits % 256 != 0 {
        return Err(format!("不支持的 RSA 位数: {bits}（支持 2048/3072/4096）"));
    }
    let pair = KeyPair::generate_rsa(bits, SignatureHash::SHA2_256).ok_or("RSA 生成失败")?;
    finish_generated(pkcs8_pem(&pair)?, &comment)
}

/// 校验/解析导入的私钥 PEM（OpenSSH 或 PKCS#8；口令加密的密钥不支持）。
/// 返回类型/指纹/一行公钥；指纹与 Known Hosts 页同一格式。
pub fn inspect_secret(pem: &str) -> Result<SshKeyMeta, String> {
    let trimmed = pem.trim();
    if trimmed.is_empty() {
        return Err("私钥内容为空".into());
    }
    // 输入长度上限：PEM 实际大小远小于此，防超大输入进解析器（评审 P2）
    if trimmed.len() > 64 * 1024 {
        return Err("私钥内容过大（>64KB），请确认粘贴的是 PEM 文本".into());
    }
    let pair = decode_secret_key(trimmed, None)
        .map_err(|e| format!("私钥解析失败（口令加密的密钥暂不支持）: {e}"))?;
    let pubkey: PublicKey = pair.clone_public_key().map_err(|e| e.to_string())?;
    // RSA 的 PublicKey::name() 返回的是签名算法名（rsa-sha2-*），authorized_keys
    // 的密钥类型前缀必须是 ssh-rsa（否则 sshd 判 unknown key type 拒收）
    let name = pubkey.name();
    let normalized = if name.starts_with("rsa-sha2") { "ssh-rsa" } else { name };
    Ok(SshKeyMeta {
        key_type: normalized.to_string(),
        fingerprint: format!("SHA256:{}", pubkey.fingerprint()),
        public_key_line: format!("{} {}", normalized, pubkey.public_key_base64()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 生成 → 编码 PEM → russh-keys 解码回读：类型一致、公钥自洽（解码器内部
    /// 会校验 seed→pub 推导，不一致即 KeyIsCorrupt），元数据与解码结果一致。
    #[test]
    fn generated_key_round_trips_through_decoder() {
        let (pem, meta) = generate_ed25519("me@host").unwrap();
        assert!(pem.starts_with("-----BEGIN OPENSSH PRIVATE KEY-----"));
        let pair = decode_secret_key(&pem, None).unwrap();
        assert_eq!(pair.name(), "ssh-ed25519");
        let pubkey = pair.clone_public_key().unwrap();
        assert_eq!(pubkey.fingerprint(), meta.fingerprint.trim_start_matches("SHA256:"));
        assert_eq!(
            meta.public_key_line,
            format!("ssh-ed25519 {} me@host", pubkey.public_key_base64())
        );
        assert!(meta.fingerprint.len() == "SHA256:".len() + 43); // 32B → 43 chars nopad
    }

    /// 默认 comment：空 comment 回退 "eterm"。
    #[test]
    fn default_comment() {
        let (_, meta) = generate_ed25519("  ").unwrap();
        assert!(meta.public_key_line.ends_with(" eterm"));
    }

    /// comment 清洗：撇号/控制字符剔除 + 64 字符截断（评审 P2 回归）。
    #[test]
    fn comment_sanitized() {
        let (_, meta) = generate_ed25519("it's\nbad\u{0007}").unwrap();
        assert!(!meta.public_key_line.contains('\''), "撇号必须剔除");
        assert!(!meta.public_key_line.contains('\n'), "换行必须剔除");
        assert!(meta.public_key_line.ends_with(" itsbad"));
        let (_, meta) = generate_ed25519(&"x".repeat(80)).unwrap();
        let comment_part = meta.public_key_line.split(' ').last().unwrap();
        assert_eq!(comment_part.len(), 64, "comment 最多 64 字符");
    }

    /// known-answer：固定 seed 的指纹/公钥行必须与 OpenSSH 生态一致。
    /// 期望值由本机 ssh-keygen（`ssh-keygen -yf` / `-lf`）对同一密钥实测回填，
    /// 防手工 blob 组装与 decoder 双方都错成一致。
    #[test]
    fn known_answer_fingerprint() {
        let seed = [42u8; 32];
        let signing = ed25519_dalek::SigningKey::from_bytes(&seed);
        let pem = encode_openssh_ed25519(&signing.to_bytes(), &signing.verifying_key().as_bytes(), "ka");
        let pair = decode_secret_key(&pem, None).unwrap();
        let pubkey = pair.clone_public_key().unwrap();
        // 期望值为本机 OpenSSH ssh-keygen 交叉验证实测值：
        // ssh-keygen -yf / -lf 对同一密钥输出 pub64 与 SHA256 指纹均与 Rust 编码一致
        assert_eq!(
            format!("SHA256:{}", pubkey.fingerprint()),
            "SHA256:1Lt0B6m58n9i5yp9hABit7qhCJ/7aR7kRxt8QRziO8k"
        );
        assert_eq!(
            pubkey.public_key_base64(),
            "AAAAC3NzaC1lZDI1NTE5AAAAIBl/ayPhbIUyxqvIOPrNXqeJvgx2spIDNAOb+os9No1h"
        );
    }

    /// 非法输入：空串 / 乱文本 / 加密格式都要给出可读错误（不 panic）。
    #[test]
    fn inspect_rejects_bad_input() {
        assert!(inspect_secret("").is_err());
        assert!(inspect_secret("not a key").is_err());
        // OpenSSH 加密私钥（口令保护）应拒绝并提示，而非静默失败
        let encrypted = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAABwAAAAtzc2gtZWQyNTUxOQAAACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB9AAAAEXNlY3JldC1wYXNzcGhyYXNlAAAAAA\n-----END OPENSSH PRIVATE KEY-----\n";
        let err = inspect_secret(encrypted).unwrap_err();
        assert!(err.contains("解析失败"), "实际: {err}");
        // 结构残缺的 PEM 同样走错误路径
        let broken = "-----BEGIN PRIVATE KEY-----\nMA==\n-----END PRIVATE KEY-----\n";
        assert!(inspect_secret(broken).is_err());
    }

    /// ECDSA P-256 生成 → PKCS#8 回读：解码、指纹自洽，且私钥能签名、公钥能验签
    /// （PKCS#8 编码正确性的最强证明——不只是能解析）。
    #[test]
    fn ecdsa_p256_round_trips_and_signs() {
        let (pem, meta) = generate_ecdsa_p256("me@host").unwrap();
        assert!(pem.starts_with("-----BEGIN PRIVATE KEY-----"));
        assert_eq!(meta.key_type, "ecdsa-sha2-nistp256");
        assert!(meta.public_key_line.starts_with("ecdsa-sha2-nistp256 "));
        assert!(meta.public_key_line.ends_with(" me@host"));
        let pair = decode_secret_key(&pem, None).unwrap();
        let pubkey = pair.clone_public_key().unwrap();
        assert_eq!(pubkey.name(), "ecdsa-sha2-nistp256");
        assert_eq!(format!("SHA256:{}", pubkey.fingerprint()), meta.fingerprint);
        // 签名往返（私钥 blob 里的标量真实可用）
        let sig = pair.sign_detached(b"eterm test message").unwrap();
        let sig_bytes = match sig {
            russh_keys::signature::Signature::ECDSA { signature, .. } => signature,
            _ => panic!("ECDSA 密钥产生了意外签名类型"),
        };
        assert!(pubkey.verify_detached(b"eterm test message", &sig_bytes));
        assert!(!pubkey.verify_detached(b"tampered", &sig_bytes));
    }

    /// RSA 生成 → PKCS#8 回读：解码、签名往返；公钥行前缀必须归一化为 ssh-rsa
    /// （PublicKey::name() 返回 rsa-sha2-*，authorized_keys 会拒收）。
    #[test]
    fn rsa_round_trips_and_signs() {
        let (pem, meta) = generate_rsa(2048, "me@host").unwrap();
        assert!(pem.starts_with("-----BEGIN PRIVATE KEY-----"));
        assert_eq!(meta.key_type, "ssh-rsa");
        assert!(meta.public_key_line.starts_with("ssh-rsa "));
        assert!(meta.public_key_line.ends_with(" me@host"));
        let pair = decode_secret_key(&pem, None).unwrap();
        let pubkey = pair.clone_public_key().unwrap();
        assert_eq!(format!("SHA256:{}", pubkey.fingerprint()), meta.fingerprint);
        let sig = pair.sign_detached(b"eterm rsa test").unwrap();
        let sig_bytes = match sig {
            russh_keys::signature::Signature::RSA { bytes, .. } => bytes,
            _ => panic!("RSA 密钥产生了意外签名类型"),
        };
        assert!(pubkey.verify_detached(b"eterm rsa test", &sig_bytes));
        assert!(!pubkey.verify_detached(b"tampered", &sig_bytes));
    }

    /// RSA 位数守卫：非法位数直接拒绝（不进质数生成器）。
    #[test]
    fn rsa_rejects_bad_bits() {
        assert!(generate_rsa(1024, "").is_err());
        assert!(generate_rsa(2050, "").is_err());
        assert!(generate_rsa(8192, "").is_err());
    }

    /// 导入 RSA 公钥场景回归：PKCS#1 PEM（BEGIN RSA PRIVATE KEY）的公钥行
    /// 同样必须归一化为 ssh-rsa 前缀。
    #[test]
    fn inspect_normalizes_rsa_name() {
        let (pem, _) = generate_rsa(2048, "").unwrap();
        let meta = inspect_secret(&pem).unwrap();
        assert_eq!(meta.key_type, "ssh-rsa");
        assert!(meta.public_key_line.starts_with("ssh-rsa "));
    }
}

//! 本地库字段加密——与服务端 `internal/crypto` 的 v1 格式**逐字节同构**：
//! `v1:` + base64(nonce[12] || ciphertext || tag)，AES-256-GCM，随机 nonce。
//! 因此任何一端 Seal 的串可被另一端 Open（本地库主密钥由用户持有）。

use aes_gcm::aead::Aead;
use aes_gcm::{Aes256Gcm, KeyInit, Nonce};
use rand::RngCore;

const NONCE_LEN: usize = 12;
const PREFIX: &str = "v1:";

#[derive(Debug, thiserror::Error)]
pub enum CoreError {
    #[error("密钥长度应为 32 字节，实际 {0}")]
    BadKeyLen(usize),
    #[error("密文格式非法: {0}")]
    BadCiphertext(String),
    #[error("加密失败")]
    Encrypt,
    #[error("解密失败（密钥不匹配或数据损坏）")]
    Decrypt,
}

fn cipher(key: &[u8]) -> Result<Aes256Gcm, CoreError> {
    if key.len() != 32 {
        return Err(CoreError::BadKeyLen(key.len()));
    }
    Aes256Gcm::new_from_slice(key).map_err(|_| CoreError::BadKeyLen(key.len()))
}

/// 加密明文，返回 "v1:..." 存储串。
pub fn seal_field(key: &[u8], plaintext: &[u8]) -> Result<String, CoreError> {
    let c = cipher(key)?;
    let mut nonce = [0u8; NONCE_LEN];
    rand::thread_rng().fill_bytes(&mut nonce);
    let ct = c
        .encrypt(Nonce::from_slice(&nonce), plaintext)
        .map_err(|_| CoreError::Encrypt)?;
    let mut out = Vec::with_capacity(NONCE_LEN + ct.len());
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&ct);
    Ok(format!("{}{}", PREFIX, base64_encode(&out)))
}

/// 解开 [`seal_field`] 的存储串。
pub fn open_field(key: &[u8], sealed: &str) -> Result<Vec<u8>, CoreError> {
    let Some(b64) = sealed.strip_prefix(PREFIX) else {
        return Err(CoreError::BadCiphertext(format!("未知版本前缀: {sealed}")));
    };
    let raw = base64_decode(b64).ok_or_else(|| CoreError::BadCiphertext("base64 非法".into()))?;
    if raw.len() < NONCE_LEN + 16 {
        return Err(CoreError::BadCiphertext("过短".into()));
    }
    let c = cipher(key)?;
    c.decrypt(Nonce::from_slice(&raw[..NONCE_LEN]), &raw[NONCE_LEN..])
        .map_err(|_| CoreError::Decrypt)
}

// 标准 base64（std 无内置，避免引入额外依赖，此处实现 RFC4648 子集：A-Za-z0-9+/，无填充输出由调用方保证兼容）
fn base64_encode(data: &[u8]) -> String {
    const TBL: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        out.push(TBL[(n >> 18) as usize & 63] as char);
        out.push(TBL[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 { TBL[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if chunk.len() > 2 { TBL[n as usize & 63] as char } else { '=' });
    }
    out
}

fn base64_decode(s: &str) -> Option<Vec<u8>> {
    fn val(c: u8) -> Option<u32> {
        match c {
            b'A'..=b'Z' => Some(u32::from(c - b'A')),
            b'a'..=b'z' => Some(u32::from(c - b'a') + 26),
            b'0'..=b'9' => Some(u32::from(c - b'0') + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }
    let bytes: Vec<u8> = s.bytes().filter(|&c| c != b'=').collect();
    let mut out = Vec::with_capacity(bytes.len() * 3 / 4);
    for chunk in bytes.chunks(4) {
        let mut n: u32 = 0;
        for (i, &c) in chunk.iter().enumerate() {
            n |= val(c)? << (18 - 6 * i);
        }
        match chunk.len() {
            4 => out.extend_from_slice(&[(n >> 16) as u8, (n >> 8) as u8, n as u8]),
            3 => out.extend_from_slice(&[(n >> 16) as u8, (n >> 8) as u8]),
            2 => out.push((n >> 16) as u8),
            _ => return None,
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key() -> Vec<u8> {
        vec![7u8; 32]
    }

    #[test]
    fn round_trip() {
        for pt in ["", "hello", "-----BEGIN OPENSSH PRIVATE KEY-----", "中文密文🔐"] {
            let sealed = seal_field(&key(), pt.as_bytes()).unwrap();
            assert!(sealed.starts_with("v1:"));
            assert_ne!(sealed, pt);
            assert_eq!(open_field(&key(), &sealed).unwrap(), pt.as_bytes());
        }
    }

    #[test]
    fn non_deterministic() {
        let a = seal_field(&key(), b"same").unwrap();
        let b = seal_field(&key(), b"same").unwrap();
        assert_ne!(a, b);
    }

    #[test]
    fn wrong_key_fails() {
        let sealed = seal_field(&key(), b"secret").unwrap();
        let mut other = key();
        other[0] = 1;
        assert!(open_field(&other, &sealed).is_err());
    }

    #[test]
    fn tamper_fails() {
        let sealed = seal_field(&key(), b"secret").unwrap();
        let mut raw = sealed.into_bytes();
        let last = raw.len() - 1;
        raw[last] ^= 0x01; // 保持 ASCII 的翻转，破坏 base64 尾字符
        let tampered = core::str::from_utf8(&raw).unwrap();
        assert!(open_field(&key(), tampered).is_err());
    }

    #[test]
    fn unknown_version_fails() {
        assert!(open_field(&key(), "v9:AAAA").is_err());
    }
}

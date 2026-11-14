// 敏感字段静态加密——与 Go 版（已归档）及未来任何实现的 v1 格式逐字节同构：
// `v1:` + base64(nonce[12] || ciphertext || tag)，AES-256-GCM，每字段随机 nonce。
// v 前缀即密钥版本位，为轮换预留；当前仅 v1。

import {
  createCipheriv,
  createDecipheriv,
  randomBytes,
} from "node:crypto";

const PREFIX_V1 = "v1:";
const NONCE_LEN = 12;
const TAG_LEN = 16;

export class CryptoError extends Error {}

export function sealField(key: Buffer, plaintext: Buffer): string {
  if (key.length !== 32) {
    throw new CryptoError(`主密钥应为 32 字节（AES-256），实际 ${key.length}`);
  }
  const nonce = randomBytes(NONCE_LEN);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  const ct = Buffer.concat([cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
  return PREFIX_V1 + Buffer.concat([nonce, ct]).toString("base64");
}

export function openField(key: Buffer, sealed: string): Buffer {
  if (!sealed.startsWith(PREFIX_V1)) {
    throw new CryptoError(`未知密文版本前缀: ${sealed.slice(0, 3)}`);
  }
  let raw: Buffer;
  try {
    raw = Buffer.from(sealed.slice(PREFIX_V1.length), "base64");
  } catch {
    throw new CryptoError("密文 base64 非法");
  }
  if (raw.length < NONCE_LEN + TAG_LEN) {
    throw new CryptoError("密文过短");
  }
  if (key.length !== 32) {
    throw new CryptoError(`主密钥应为 32 字节（AES-256），实际 ${key.length}`);
  }
  const nonce = raw.subarray(0, NONCE_LEN);
  const data = raw.subarray(NONCE_LEN, raw.length - TAG_LEN);
  const tag = raw.subarray(raw.length - TAG_LEN);
  const decipher = createDecipheriv("aes-256-gcm", key, nonce);
  decipher.setAuthTag(tag);
  try {
    return Buffer.concat([decipher.update(data), decipher.final()]);
  } catch {
    throw new CryptoError("解密失败（密钥不匹配或数据损坏）");
  }
}

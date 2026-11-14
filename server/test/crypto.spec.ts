// 字段加密单测（与 Go 版矩阵对齐）。

import { describe, expect, it } from "vitest";
import { openField, sealField, CryptoError } from "../src/crypto/field.ts";

const key = Buffer.alloc(32, 7);

describe("field crypto", () => {
  it("roundtrip", () => {
    for (const pt of ["", "hello", "-----BEGIN OPENSSH PRIVATE KEY-----", "中文密文🔐"]) {
      const sealed = sealField(key, Buffer.from(pt, "utf8"));
      expect(sealed.startsWith("v1:")).toBe(true);
      expect(sealed).not.toBe(pt);
      expect(openField(key, sealed).toString("utf8")).toBe(pt);
    }
  });

  it("non-deterministic（随机 nonce）", () => {
    const a = sealField(key, Buffer.from("same"));
    const b = sealField(key, Buffer.from("same"));
    expect(a).not.toBe(b);
  });

  it("wrong key fails", () => {
    const sealed = sealField(key, Buffer.from("secret"));
    const other = Buffer.alloc(32, 9);
    expect(() => openField(other, sealed)).toThrow(CryptoError);
  });

  it("tamper fails", () => {
    const sealed = sealField(key, Buffer.from("secret"));
    const raw = Buffer.from(sealed.slice(3), "base64");
    raw[raw.length - 1] ^= 0x01; // 破坏 tag 区域
    const tampered = "v1:" + raw.toString("base64");
    expect(() => openField(key, tampered)).toThrow(CryptoError);
  });

  it("unknown version fails", () => {
    expect(() => openField(key, "v9:AAAA")).toThrow(CryptoError);
  });

  it("bad key length fails", () => {
    expect(() => sealField(Buffer.alloc(16), Buffer.from("x"))).toThrow(CryptoError);
  });
});

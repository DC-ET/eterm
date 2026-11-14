// 口令哈希单测。

import { describe, expect, it } from "vitest";
import { hashPassword, verifyPassword } from "../src/auth/argon.ts";

describe("argon2id", () => {
  it("roundtrip + pepper 敏感", async () => {
    const h = await hashPassword("s3cret-密码!", "pepper-xyz");
    expect(h.startsWith("$argon2id$v=19$m=65536,t=2,p=4$")).toBe(true);
    expect(await verifyPassword("s3cret-密码!", "pepper-xyz", h)).toBe(true);
    expect(await verifyPassword("wrong", "pepper-xyz", h)).toBe(false);
    expect(await verifyPassword("s3cret-密码!", "other-pepper", h)).toBe(false);
  });

  it("non-deterministic（随机盐）", async () => {
    const a = await hashPassword("same", "p");
    const b = await hashPassword("same", "p");
    expect(a).not.toBe(b);
  });

  it("malformed → false（对外语义）", async () => {
    expect(await verifyPassword("p", "p", "")).toBe(false);
    expect(await verifyPassword("p", "p", "$bcrypt$x$y$z$w")).toBe(false);
  });
});

// 代码评审 bug 验证用例（docs/code-review/2026-11-15-逻辑bug评审.md）。
// 每个用例按"契约期望的正确行为"断言；因对应 bug 未修复，用 it.fails 标记为预期失败
// （vitest 语义：用例当前确实失败 → 套件绿色；bug 修复后断言通过 → it.fails 变红，
//  此时应摘除 .fails 标记转常规回归测试）。取证输出见评审文档"复现记录"。
// 运行：ETERM_TEST_DSN='root@tcp(127.0.0.1:3306)/mysql?parseTime=true' npx vitest run test/code-review-bugs.spec.ts

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { v7 as uuidv7 } from "uuid";
import { SyncEngine } from "../src/syncengine.ts";
import { Hub } from "../src/hub.ts";
import { newTestFixture, pushOne, hostData, newDevice, type TestFixture } from "./helpers.ts";
import * as userstore from "../src/store/userstore.ts";

let a: TestFixture; // 主库：同库内建两个 vault（受害者 userA / 攻击者 userB）
let vaultB = ""; // 攻击者 vault
let engA: SyncEngine;
// 未设 ETERM_TEST_DSN 则跳过（见 helpers 注释）
const hasDb = !!process.env.ETERM_TEST_DSN;

beforeEach(async () => {
  if (!hasDb) return;
  a = await newTestFixture("userA");
  const attackerId = await userstore.createUser(a.db, "userB", "fake-hash");
  vaultB = await userstore.createPersonalVault(a.db, attackerId, "userB-personal");
  engA = new SyncEngine(a.db, new Hub());
});

afterEach(async () => {
  if (!hasDb) return;
  await a.cleanup();
});

describe.runIf(hasDb)("code review bug verification", () => {
  it("BUG-1a: push 跨 vault 读 —— 他 vault 实体冲突响应泄露明文 server_data", async () => {
    const devA = newDevice();
    const iid = uuidv7();
    const r1 = await pushOne(a.db, a.vaultId, devA, "identity", iid, 0, "upsert", {
      label: "root",
      username: "root",
      password_enc: "TOPSECRET-pw",
    });
    expect(r1.status).toBe("ok");

    // userB 对 userA 的实体 id 发起 upsert（base_rev=0）。
    // 正确行为：push 必须校验实体归属 vault，对外 vault 实体应按"不存在"拒绝。
    const r2 = await pushOne(a.db, vaultB, newDevice(), "identity", iid, 0, "upsert", {
      label: "evil",
      username: "evil",
    });
    console.log("BUG-1a 实际返回:", JSON.stringify(r2));
    expect(r2.status).toBe("rejected");
  });

  it("BUG-1b: push 跨 vault 写/删 —— 可直接删除他 vault 实体", async () => {
    const devA = newDevice();
    const hid = uuidv7();
    const r1 = await pushOne(a.db, a.vaultId, devA, "host", hid, 0, "upsert", hostData("1"));
    expect(r1.status).toBe("ok");

    // userB 无任何 base_rev 依据却可删除 userA 的主机（且 victim 的 changes 无记录）。
    // 正确行为：删除也应受 vault 归属约束（rejected / entity_not_found）。
    const r2 = await pushOne(a.db, vaultB, newDevice(), "host", hid, 0, "delete");
    console.log("BUG-1b 跨 vault delete 实际返回:", JSON.stringify(r2));
    const victimPull = await engA.pull(a.db.uuidToBytes(a.vaultId), 0, 100);
    console.log("BUG-1b victim vault changes:", JSON.stringify(victimPull.changes.map((c) => c.op)));
    expect(r2.status).toBe("rejected");
  });

  it("BUG-2: op=delete 不校验 base_rev —— 陈旧删除静默覆盖并发更新", async () => {
    const dev1 = newDevice();
    const dev2 = newDevice();
    const hid = uuidv7();
    const r1 = await pushOne(a.db, a.vaultId, dev1, "host", hid, 0, "upsert", hostData("1"));
    expect(r1.status).toBe("ok");

    // 设备2 基于 rev1 更新（产生 rev2）
    const r2 = await pushOne(a.db, a.vaultId, dev2, "host", hid, r1.rev!, "upsert", hostData("2"));
    expect(r2.status).toBe("ok");
    expect(r2.rev!).toBeGreaterThan(r1.rev!);

    // 设备1 仍持陈旧 base_rev=r1.rev 发删除：技术方案 §3.3
    // "base_rev 校验：客户端所见版本 / 版本不符 → conflict"；与复活路径（deleted 行 upsert 校验 base_rev）不对称。
    const r3 = await pushOne(a.db, a.vaultId, dev1, "host", hid, r1.rev!, "delete");
    console.log("BUG-2 陈旧 base_rev 删除实际返回:", JSON.stringify(r3));
    const pull = await engA.pull(a.db.uuidToBytes(a.vaultId), 0, 100);
    console.log("BUG-2 changes 序列:", JSON.stringify(pull.changes.map((c) => ({ op: c.op, rev: c.rev }))));
    expect(r3.status).toBe("conflict");
  });

  it("BUG-3: ssh_key 墓碑复活绕过密钥内容不可变校验", async () => {
    const devA = newDevice();
    const kid = uuidv7();
    const keyBody = (pem: string) => ({
      label: "k",
      key_type: "ed25519",
      private_enc: pem,
      public_key: "pub",
      fingerprint: "fp",
      origin: "imported",
      key_version: 1,
    });
    const r1 = await pushOne(a.db, a.vaultId, devA, "ssh_key", kid, 0, "upsert", keyBody("KEY-ORIGINAL"));
    expect(r1.status).toBe("ok");

    // 墓碑下线
    const r2 = await pushOne(a.db, a.vaultId, devA, "ssh_key", kid, r1.rev!, "delete");
    expect(r2.status).toBe("ok");

    // 复活并夹带新密钥内容：PRD/技术方案规定私钥内容不可变（换内容=新行新 id）。
    // 存活行走 checkKeyImmutability 会拒绝；墓碑复活路径漏检。
    const r3 = await pushOne(a.db, a.vaultId, devA, "ssh_key", kid, r2.rev!, "upsert", keyBody("KEY-REPLACED"));
    console.log("BUG-3 复活实际返回:", JSON.stringify(r3));
    if (r3.status === "ok") {
      const pull = await engA.pull(a.db.uuidToBytes(a.vaultId), 0, 100);
      const last = pull.changes.filter((c) => c.entity_type === "ssh_key").at(-1);
      console.log("BUG-3 复活后 private_enc =", JSON.stringify((last?.data as Record<string, unknown>)?.["private_enc"]));
    }
    expect(r3.status).toBe("rejected");
  });
});

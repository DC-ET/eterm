// 同步协议集成测试（对照 Go 版 syncengine 测试矩阵）。

import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { v7 as uuidv7 } from "uuid";
import { SyncEngine } from "../src/syncengine.ts";
import { Hub } from "../src/hub.ts";
import { newTestFixture, pushOne, hostData, newDevice, type TestFixture } from "./helpers.ts";

// 与 Go 版一致：每个用例独立数据库（随机命名 + 迁移 + 清理）
let f: TestFixture;
let eng: SyncEngine;

beforeEach(async () => {
  f = await newTestFixture();
  eng = new SyncEngine(f.db, new Hub());
});

afterEach(async () => {
  await f.cleanup();
});

describe("sync protocol", () => {
  it("push/pull 往返 + 加密字段", async () => {
    const dev = newDevice();
    const id = uuidv7();
    const r1 = await pushOne(f.db, f.vaultId, dev, "host", id, 0, "upsert", hostData("1"));
    expect(r1.status).toBe("ok");
    expect((r1.rev ?? 0) > 0).toBe(true);

    const iid = uuidv7();
    const r2 = await pushOne(f.db, f.vaultId, dev, "identity", iid, 0, "upsert", {
      label: "root",
      username: "root",
      password_enc: "s3cret-中文🔐",
    });
    expect(r2.status).toBe("ok");

    const resp = await eng.pull(f.db.uuidToBytes(f.vaultId), 0, 100);
    expect(resp.changes).toHaveLength(2);
    const identity = resp.changes.find((c) => c.entity_type === "identity")!;
    expect((identity.data as Record<string, unknown>)["password_enc"]).toBe("s3cret-中文🔐");

    const again = await eng.pull(f.db.uuidToBytes(f.vaultId), resp.cursor, 100);
    expect(again.changes).toHaveLength(0);
  });

  it("conflict 附服务端数据，base_rev 匹配后可重推", async () => {
    const dev = newDevice();
    const id = uuidv7();
    const r1 = await pushOne(f.db, f.vaultId, dev, "host", id, 0, "upsert", hostData("1"));
    const r2 = await pushOne(f.db, f.vaultId, dev, "host", id, 0, "upsert", hostData("2"));
    expect(r1.status).toBe("ok");
    expect(r2.status).toBe("conflict");
    expect(r2.rev).toBe(r1.rev);
    expect((r2.serverData as Record<string, unknown>)["hostname"]).toBe("10.0.0.1");

    const r3 = await pushOne(f.db, f.vaultId, dev, "host", id, r2.rev!, "upsert", hostData("2"));
    expect(r3.status).toBe("ok");
    expect((r3.rev ?? 0) > (r2.rev ?? 0)).toBe(true);
  });

  it("tombstone → 幂等 → 复活", async () => {
    const dev = newDevice();
    const id = uuidv7();
    const r1 = await pushOne(f.db, f.vaultId, dev, "host", id, 0, "upsert", hostData("9"));
    const r2 = await pushOne(f.db, f.vaultId, dev, "host", id, r1.rev!, "delete");
    expect(r2.status).toBe("ok");

    const resp = await eng.pull(f.db.uuidToBytes(f.vaultId), 0, 100);
    expect(resp.changes.at(-1)!.op).toBe("delete");
    expect(resp.changes.at(-1)!.data).toBeUndefined();

    const r3 = await pushOne(f.db, f.vaultId, dev, "host", id, r2.rev!, "delete");
    expect(r3.status).toBe("ok");
    expect(r3.rev).toBe(r2.rev);

    const r4 = await pushOne(f.db, f.vaultId, dev, "host", id, r2.rev!, "upsert", hostData("9"));
    expect(r4.status).toBe("ok");
    const resp2 = await eng.pull(f.db.uuidToBytes(f.vaultId), r2.rev!, 100);
    expect(resp2.changes).toHaveLength(1);
    expect(resp2.changes[0]!.op).toBe("upsert");
  });

  it("双客户端收敛（A 推 3 台 → B 追平 → B 改 → A 增量 → A 删 → B 收 tombstone）", async () => {
    const devA = newDevice();
    const devB = newDevice();
    let cursorA = 0;
    let cursorB = 0;
    const vB = f.db.uuidToBytes(f.vaultId);

    const ids = [uuidv7(), uuidv7(), uuidv7()];
    for (let i = 0; i < ids.length; i++) {
      const r = await pushOne(f.db, f.vaultId, devA, "host", ids[i]!, 0, "upsert", hostData(String(i + 1)));
      expect(r.status).toBe("ok");
    }
    const respB = await eng.pull(vB, cursorB, 200);
    cursorB = respB.cursor;
    expect(respB.changes).toHaveLength(3);

    const bTarget = respB.changes.find((c) => c.entity_id === ids[0])!;
    const rB = await pushOne(f.db, f.vaultId, devB, "host", ids[0]!, bTarget.rev, "upsert", hostData("100"));
    expect(rB.status).toBe("ok");

    const respA = await eng.pull(vB, cursorA, 200);
    expect(respA.changes).toHaveLength(4);
    const sawB = respA.changes.some((c) => c.entity_id === ids[0] && (c.data as Record<string, unknown>)["hostname"] === "10.0.0.100");
    expect(sawB).toBe(true);
    cursorA = respA.cursor;

    const aDelTarget = respA.changes.find((c) => c.entity_id === ids[1])!;
    const rDel = await pushOne(f.db, f.vaultId, devA, "host", ids[1]!, aDelTarget.rev, "delete");
    expect(rDel.status).toBe("ok");

    const respB2 = await eng.pull(vB, cursorB, 200);
    expect(respB2.changes).toHaveLength(2);
    expect(respB2.changes[0]!.op).toBe("upsert");
    expect(respB2.changes[1]!.op).toBe("delete");
  });

  it("ssh_key 内容不可变（同内容可重推，变内容拒绝）", async () => {
    const dev = newDevice();
    const id = uuidv7();
    const kd = (priv: string): Record<string, unknown> => ({
      label: "k1",
      key_type: "ed25519",
      private_enc: priv,
      public_key: "ssh-ed25519 AAAA",
      fingerprint: "SHA256:abc",
      origin: "generated",
      key_version: 1,
    });
    const r1 = await pushOne(f.db, f.vaultId, dev, "ssh_key", id, 0, "upsert", kd("PRIV-1"));
    expect(r1.status).toBe("ok");
    const r2 = await pushOne(f.db, f.vaultId, dev, "ssh_key", id, r1.rev!, "upsert", kd("PRIV-1"));
    expect(r2.status).toBe("ok");
    const r3 = await pushOne(f.db, f.vaultId, dev, "ssh_key", id, r2.rev!, "upsert", kd("PRIV-2"));
    expect(r3.status).toBe("rejected");
  });

  it("校验拒绝（缺 hostname / 非法 kind / 端口越界 / 未知类型）", async () => {
    const dev = newDevice();
    expect(
      (await pushOne(f.db, f.vaultId, dev, "host", uuidv7(), 0, "upsert", { label: "x" })).status,
    ).toBe("rejected");
    expect(
      (
        await pushOne(f.db, f.vaultId, dev, "port_rule", uuidv7(), 0, "upsert", {
          host_id: uuidv7(),
          label: "p",
          kind: "bogus",
          bind_addr: "127.0.0.1",
          enabled: true,
        })
      ).status,
    ).toBe("rejected");
    expect(
      (
        await pushOne(f.db, f.vaultId, dev, "port_rule", uuidv7(), 0, "upsert", {
          host_id: uuidv7(),
          label: "p",
          kind: "local",
          bind_addr: "127.0.0.1",
          local_port: 70000,
          enabled: true,
        })
      ).status,
    ).toBe("rejected");
    expect(
      (await pushOne(f.db, f.vaultId, dev, "no_such_type", uuidv7(), 0, "upsert", {})).status,
    ).toBe("rejected");
  });
});

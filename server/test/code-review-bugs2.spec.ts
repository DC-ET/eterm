// 代码评审 bug 回归用例（docs/code-review/2026-11-27-逻辑bug评审.md，第二轮）。
// 覆盖：BUG-1（WS 通知 vault 隔离，正/反例）、BUG-2（同 vault push 串行化 →
// pull 游标不再越过未提交事务的 id 空洞）。修复已入库，断言「契约期望的正确行为」。
// 运行：ETERM_TEST_DSN='root@tcp(127.0.0.1:3306)/mysql?parseTime=true' npx vitest run test/code-review-bugs2.spec.ts

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import WebSocket from "ws";
import { buildApp } from "../src/api/app.ts";
import { Hub } from "../src/hub.ts";
import { AuthService } from "../src/auth/service.ts";
import { SyncEngine } from "../src/syncengine.ts";
import { hashPassword } from "../src/auth/argon.ts";
import * as userstore from "../src/store/userstore.ts";
import { newTestFixture, pushOne, hostData, newDevice, type TestFixture } from "./helpers.ts";
import { v7 as uuidv7 } from "uuid";

let f: TestFixture;
let app: ReturnType<typeof buildApp>;
let wsPort = 0; // beforeAll 监听后记录（WS 用例共用）
const PEPPER = "review2-pepper";
// 未设 ETERM_TEST_DSN 则跳过（见 helpers 注释）
const hasDb = !!process.env.ETERM_TEST_DSN;

beforeAll(async () => {
  if (!hasDb) return;
  // fixture 用户口令是占位串不能真登录：另建 carol/bob 两个真实口令用户
  f = await newTestFixture("carol-owner", true);
  const carolId = await userstore.createUser(f.db, "carol", await hashPassword("carol-password", PEPPER));
  await userstore.createPersonalVault(f.db, carolId, "carol-personal");
  const bobId = await userstore.createUser(f.db, "bob", await hashPassword("bob-password", PEPPER));
  await userstore.createPersonalVault(f.db, bobId, "bob-personal");
  const hub = new Hub();
  app = buildApp(
    {
      db: f.db,
      auth: new AuthService(f.db, PEPPER),
      engine: new SyncEngine(f.db, hub),
      hub,
    },
    { ipWhitelist: [], trustedProxy: "127.0.0.1" },
  );
  // 真实监听一次（WS 用例共用；多测试共享同一 app 实例）
  await app.listen({ port: 0, host: "127.0.0.1" });
  const addr = app.server.address();
  wsPort = typeof addr === "object" && addr ? addr.port : 0;
});

afterAll(async () => {
  if (f) await f.cleanup();
  if (app) await app.close();
});

function doReq(method: string, url: string, tok: string, body?: unknown) {
  return app.inject({
    method,
    url,
    ...(tok ? { headers: { authorization: `Bearer ${tok}` } } : {}),
    ...(body !== undefined ? { payload: body } : {}),
  });
}

async function login(username: string, password: string, device: string) {
  const r = await doReq("POST", "/api/v1/auth/login", "", {
    username,
    password,
    device_name: device,
    platform: "macos",
  });
  expect(r.statusCode).toBe(200);
  return r.json()["token"] as string;
}

describe.runIf(hasDb)("code review round 2 regressions", () => {
  it("BUG-1 反例：他 vault 的 push 不得通知本 vault 的在线客户端", async () => {
    const tokCarol = await login("carol", "carol-password", "rev2-carol");
    const tokBob = await login("bob", "bob-password", "rev2-bob");

    const frames: string[] = [];
    const ws = new WebSocket(`ws://127.0.0.1:${wsPort}/api/v1/ws?token=${tokCarol}`);
    await new Promise<void>((resolve, reject) => {
      ws.once("open", () => resolve());
      ws.once("error", (e) => reject(e));
    });
    ws.on("message", (d) => frames.push(String(d)));
    await new Promise((r) => setTimeout(r, 150)); // 订阅注册窗口

    // bob 在自己的 vault 里 push 一台主机
    const r = await doReq("POST", "/api/v1/sync/push", tokBob, {
      changes: [
        {
          entity_type: "host",
          entity_id: uuidv7(),
          base_rev: 0,
          op: "upsert",
          data: { label: "bob-host", hostname: "bob.lan", tags: [] },
        },
      ],
    });
    expect(r.statusCode).toBe(200);
    expect(r.json()["results"][0]["status"]).toBe("ok");

    // 2.5s 内 carol 的 WS 不得收到任何帧（bob 的变更属于另一个 vault）
    await new Promise((r) => setTimeout(r, 2500));
    ws.close();
    expect(frames).toHaveLength(0);
  });

  it("BUG-1 正例：本 vault 的 push 必须通知到本 vault 的在线客户端", async () => {
    const tokCarol = await login("carol", "carol-password", "rev2-carol-2");
    const frames: string[] = [];
    const ws = new WebSocket(`ws://127.0.0.1:${wsPort}/api/v1/ws?token=${tokCarol}`);
    await new Promise<void>((resolve, reject) => {
      ws.once("open", () => resolve());
      ws.once("error", (e) => reject(e));
    });
    ws.on("message", (d) => frames.push(String(d)));
    await new Promise((r) => setTimeout(r, 150));

    // carol 在自己的 vault 里 push 一台主机
    const r = await doReq("POST", "/api/v1/sync/push", tokCarol, {
      changes: [
        {
          entity_type: "host",
          entity_id: uuidv7(),
          base_rev: 0,
          op: "upsert",
          data: { label: "carol-host", hostname: "carol.lan", tags: [] },
        },
      ],
    });
    expect(r.json()["results"][0]["status"]).toBe("ok");

    const frame = await new Promise<string>((resolve, reject) => {
      ws.once("message", (d) => resolve(String(d)));
      setTimeout(() => reject(new Error("5s 内未收到本 vault 广播帧")), 5000);
    });
    ws.close();
    const parsed = JSON.parse(frame);
    expect(parsed["type"]).toBe("change");
    expect(typeof parsed["rev"]).toBe("number");
  });

  it("BUG-2：同 vault push 事务持有 vault 行锁 → 并发 push 被串行化，游标空洞不可能形成", async () => {
    const eng = new SyncEngine(f.db, new Hub());
    const vault = f.vaultId;

    // 变更 1：host H 落库（已提交）
    const hid = uuidv7();
    const r1 = await pushOne(f.db, vault, newDevice(), "host", hid, 0, "upsert", hostData("H1"));
    expect(r1.status).toBe("ok");

    // 模拟一台设备进行中的 push 事务：修复后的 pushItem 在事务开头锁 vault 行，
    // 随后写 changes/实体行——此处以相同写集复刻其「进行中」状态（未提交）。
    const conn = await f.db.pool.getConnection();
    await conn.beginTransaction();
    await conn.query(`SELECT rev FROM vaults WHERE id = ? FOR UPDATE`, [
      f.db.uuidToBytes(vault),
    ]);
    const [c2] = await conn.query(
      `INSERT INTO changes (entity_type, entity_id, vault_id, actor_device, ts)
       VALUES ('host', ?, ?, ?, UTC_TIMESTAMP(3))`,
      [f.db.uuidToBytes(hid), f.db.uuidToBytes(vault), f.db.uuidToBytes(newDevice())],
    );
    const inFlightId = Number((c2 as { insertId: number }).insertId);
    await conn.query(`UPDATE hosts SET rev = ?, label = 'H2-in-flight' WHERE id = ?`, [
      inFlightId,
      f.db.uuidToBytes(hid),
    ]);

    // 事务悬挂期间：并发 push（J）必须被 vault 行锁挡住（旧代码无锁，会立即完成
    // 并提交更晚的 id——正是游标空洞的成因）
    let jDone = false;
    const jid = uuidv7();
    const jp = pushOne(f.db, vault, newDevice(), "host", jid, 0, "upsert", hostData("J3")).then(
      (r) => {
        jDone = true;
        return r;
      },
    );
    await new Promise((r) => setTimeout(r, 600));
    expect(jDone).toBe(false); // 串行化生效：J 等待 vault 锁

    // 悬挂期间 pull：只见已提交的变更 1（快照隔离，正常）
    const mid = await eng.pull(f.db.uuidToBytes(vault), 0, 100);
    expect(mid.changes.map((c) => c.rev)).toEqual([r1.rev]);

    // 提交悬挂事务（合法完成的 push），随后 J 获得锁并完成
    await conn.commit();
    conn.release();
    const rj = await jp;
    expect(rj.status).toBe("ok");

    // 从悬挂期间的游标续拉：H 的更新（in-flight change）与 J 必须都可见——无空洞
    const tail = await eng.pull(f.db.uuidToBytes(vault), mid.cursor, 100);
    const revs = tail.changes.map((c) => c.rev);
    expect(revs).toContain(inFlightId);
    expect(revs).toContain(rj.rev!);
    const hChange = tail.changes.find((c) => c.entity_id === hid);
    expect((hChange?.data ?? {})["label"]).toBe("H2-in-flight");
  });
});

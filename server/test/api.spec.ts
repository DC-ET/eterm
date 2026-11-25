// HTTP 端到端测试（对照 Go 版 api 测试矩阵）：登录/鉴权/同步/设备/WS 广播/限流。
// 注意：登录限流为进程内共享状态，rate-limit 用例放在最后执行。

import { afterAll, beforeAll, describe, expect, it } from "vitest";
import WebSocket from "ws";
import { buildApp } from "../src/api/app.ts";
import { Hub } from "../src/hub.ts";
import { AuthService } from "../src/auth/service.ts";
import { SyncEngine } from "../src/syncengine.ts";
import { hashPassword } from "../src/auth/argon.ts";
import * as userstore from "../src/store/userstore.ts";
import { newTestFixture, type TestFixture } from "./helpers.ts";
import { v7 as uuidv7 } from "uuid";

let f: TestFixture;
let app: ReturnType<typeof buildApp>;
let token = "";
const PEPPER = "test-pepper";
// 未设 ETERM_TEST_DSN 则跳过（见 helpers 注释）
const hasDb = !!process.env.ETERM_TEST_DSN;

beforeAll(async () => {
  if (!hasDb) return;
  f = await newTestFixture("alice-owner", true);
  const hash = await hashPassword("alice-password", PEPPER);
  const aliceId = await userstore.createUser(f.db, "alice", hash);
  await userstore.createPersonalVault(f.db, aliceId, "alice-personal");
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

describe.runIf(hasDb)("auth & sync flow", () => {
  it("未认证 401", async () => {
    const r = await doReq("GET", "/api/v1/me", "");
    expect(r.statusCode).toBe(401);
  });

  it("登录失败 401（防枚举）", async () => {
    const r = await doReq("POST", "/api/v1/auth/login", "", {
      username: "ghost",
      password: "x",
      device_name: "d",
      platform: "macos",
    });
    expect(r.statusCode).toBe(401);
    expect(r.json()).toEqual({ error: "bad_credentials" });
  });

  it("登录成功 + /me", async () => {
    const r = await doReq("POST", "/api/v1/auth/login", "", {
      username: "alice",
      password: "alice-password",
      device_name: "test-mac",
      platform: "macos",
    });
    expect(r.statusCode).toBe(200);
    const j = r.json();
    expect(j.token).toBeTruthy();
    expect(j.vault_id).toBeTruthy();
    token = j.token;

    const me = await doReq("GET", "/api/v1/me", token);
    expect(me.statusCode).toBe(200);
    expect(me.json()["vault_id"]).toBeTruthy();
  });

  it("push/pull/conflict", async () => {
    const hostId = uuidv7();
    const mk = () => ({
      changes: [
        {
          entity_type: "host",
          entity_id: hostId,
          base_rev: 0,
          op: "upsert",
          data: { label: "web1", hostname: "web1.lan", tags: ["web"] },
        },
      ],
    });
    let r = await doReq("POST", "/api/v1/sync/push", token, mk());
    expect(r.statusCode).toBe(200);
    expect(r.json()["results"][0]["status"]).toBe("ok");

    const pl = await doReq("GET", "/api/v1/sync/pull?cursor=0", token);
    expect(pl.json()["changes"]).toHaveLength(1);

    r = await doReq("POST", "/api/v1/sync/push", token, mk());
    expect(r.json()["results"][0]["status"]).toBe("conflict");
    expect(r.json()["results"][0]["server_data"]["hostname"]).toBe("web1.lan");
  });

  it("设备列表 + logout 失效 + 同名设备复用", async () => {
    const dl = await doReq("GET", "/api/v1/devices", token);
    expect(dl.json()["devices"]).toHaveLength(1);

    expect((await doReq("POST", "/api/v1/auth/logout", token)).statusCode).toBe(200);
    expect((await doReq("GET", "/api/v1/me", token)).statusCode).toBe(401);

    const r = await doReq("POST", "/api/v1/auth/login", "", {
      username: "alice",
      password: "alice-password",
      device_name: "test-mac",
      platform: "macos",
    });
    token = r.json()["token"];
    const dl2 = await doReq("GET", "/api/v1/devices", token);
    expect(dl2.json()["devices"]).toHaveLength(1);
  });
});

describe.runIf(hasDb)("ws broadcast", () => {
  it("推送后收到广播帧", async () => {
    const login = await doReq("POST", "/api/v1/auth/login", "", {
      username: "alice",
      password: "alice-password",
      device_name: "ws-dev",
      platform: "macos",
    });
    const tok = login.json()["token"];

    await app.listen({ port: 0, host: "127.0.0.1" });
    const addr = app.server.address();
    const port = typeof addr === "object" && addr ? addr.port : 0;
    console.log("WS_DEBUG listening on", port);

    const ws = new WebSocket(`ws://127.0.0.1:${port}/api/v1/ws?token=${tok}`);
    await new Promise<void>((resolve, reject) => {
      ws.once("open", () => {
        console.log("WS_DEBUG open");
        resolve();
      });
      ws.once("error", (e) => {
        console.log("WS_DEBUG error", (e as Error).message);
        reject(e);
      });
      ws.once("unexpected-response", (_req, res) => {
        console.log("WS_DEBUG unexpected-response", (res as { statusCode?: number }).statusCode);
        reject(new Error("unexpected response"));
      });
    });
    await new Promise((r) => setTimeout(r, 100)); // 订阅注册窗口

    const framePromise = new Promise<string>((resolve, reject) => {
      ws.once("message", (d) => resolve(String(d)));
      setTimeout(() => reject(new Error("5s 内未收到广播帧")), 4000);
    });

    console.log("WS_DEBUG pushing");
    await doReq("POST", "/api/v1/sync/push", tok, {
      changes: [
        {
          entity_type: "host",
          entity_id: uuidv7(),
          base_rev: 0,
          op: "upsert",
          data: { label: "db1", hostname: "db1.lan", tags: [] },
        },
      ],
    });

    const frame = JSON.parse(await framePromise);
    expect(frame["type"]).toBe("change");
    expect(typeof frame["rev"]).toBe("number");
    ws.close();
    // app.close 交给 afterAll 统一执行（共享实例，勿在此关闭）
  });

  // 放在依赖 alice-password 的用例之后：结束时把密码改回去，token 一并刷新
  it("修改密码：401/400 校验 + 成功后旧密码失效", async () => {
    // 未认证
    let r = await doReq("POST", "/api/v1/auth/password", "", {
      old_password: "x",
      new_password: "y".repeat(8),
    });
    expect(r.statusCode).toBe(401);

    // 旧密码错误
    r = await doReq("POST", "/api/v1/auth/password", token, {
      old_password: "wrong-old",
      new_password: "alice-new-password",
    });
    expect(r.statusCode).toBe(401);
    expect(r.json()).toEqual({ error: "bad_credentials" });

    // 新密码过短
    r = await doReq("POST", "/api/v1/auth/password", token, {
      old_password: "alice-password",
      new_password: "short",
    });
    expect(r.statusCode).toBe(400);
    expect(r.json()).toEqual({ error: "weak_password" });

    // 成功修改 → 旧密码登录失败、新密码登录成功
    r = await doReq("POST", "/api/v1/auth/password", token, {
      old_password: "alice-password",
      new_password: "alice-temp-password",
    });
    expect(r.statusCode).toBe(200);

    r = await doReq("POST", "/api/v1/auth/login", "", {
      username: "alice",
      password: "alice-password",
      device_name: "pw-test",
      platform: "macos",
    });
    expect(r.statusCode).toBe(401);

    r = await doReq("POST", "/api/v1/auth/login", "", {
      username: "alice",
      password: "alice-temp-password",
      device_name: "pw-test",
      platform: "macos",
    });
    expect(r.statusCode).toBe(200);

    // 改回原密码，保证 rate-limit 用例之前的状态一致
    token = r.json()["token"];
    r = await doReq("POST", "/api/v1/auth/password", token, {
      old_password: "alice-temp-password",
      new_password: "alice-password",
    });
    expect(r.statusCode).toBe(200);
  });
});

describe.runIf(hasDb)("login rate limit", () => {
  it("连续登录触发 429", async () => {
    let last = 0;
    for (let i = 0; i < 12; i++) {
      const r = await doReq("POST", "/api/v1/auth/login", "", {
        username: "nobody",
        password: "x",
        device_name: "d",
        platform: "macos",
      });
      last = r.statusCode;
    }
    expect(last).toBe(429);
  });
});

// Fastify 应用：路由、中间件（认证/限流/IP 白名单/真实 IP）、WS 通知（技术方案 §3.3/§3.5）。
// 响应形状与错误码与 Go 版逐项对齐（客户端契约）。

import { readFileSync } from "node:fs";
import Fastify, { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import fastifyWebsocket from "@fastify/websocket";
import type { Db } from "../store/db.ts";
import type { Hub } from "../hub.ts";
import type { SyncEngine } from "../syncengine.ts";
import { parseCursor } from "../syncengine.ts";
import * as userstore from "../store/userstore.ts";
import {
  BadCredentialsError,
  DeviceNameError,
  LockedError,
  NoVaultError,
  WeakPasswordError,
  sha256,
} from "../auth/service.ts";

export const VERSION = "0.1.0-ts";

export interface UserCtx {
  userId: string;
  deviceId: string;
  username: string;
  vaultId: string;
}

interface Deps {
  db: Db;
  auth: AuthServiceLike;
  engine: SyncEngine;
  hub: Hub;
}

interface AuthServiceLike {
  login(
    username: string,
    password: string,
    deviceName: string,
    platform: string,
    ip: string | null,
  ): Promise<{ token: string; deviceId: string; userId: string; username: string; vaultId: string }>;
  changePassword(userId: string, oldPassword: string, newPassword: string, ip: string | null): Promise<void>;
}

type Loc = FastifyRequest & { userCtx?: UserCtx; clientIp?: string };

// ---------- 中间件：真实 IP / 白名单 / 限流 ----------

/** 与 Go 版一致：仅信任指定反代（默认 127.0.0.1）的 X-Forwarded-For 首段。 */
function realIp(req: FastifyRequest, trustedProxy: string): string {
  const remote = (req.socket.remoteAddress ?? "").replace(/^::ffff:/, "");
  if (remote === trustedProxy) {
    const xff = (req.headers["x-forwarded-for"] as string | undefined)?.split(",")[0]?.trim();
    if (xff) return xff;
  }
  return remote;
}

function ipv4ToNum(ip: string): number | null {
  const parts = ip.split(".");
  if (parts.length !== 4) return null;
  let n = 0;
  for (const p of parts) {
    const v = Number(p);
    if (!Number.isInteger(v) || v < 0 || v > 255) return null;
    n = ((n << 8) | v) >>> 0;
  }
  return n;
}

function cidrMatch(ip: string, cidrs: string[]): boolean {
  const ipNum = ipv4ToNum(ip);
  if (ipNum === null) return false;
  for (const c of cidrs) {
    const [base, bitsStr] = c.split("/");
    const bits = bitsStr === undefined ? 32 : Number(bitsStr);
    const baseNum = ipv4ToNum(base!);
    if (baseNum === null) continue;
    const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
    if ((ipNum & mask) === (baseNum & mask)) return true;
  }
  return false;
}

// 登录限流：每 IP 容量 10、每分钟回填 10（与 Go 版一致）
const buckets = new Map<string, { tokens: number; last: number }>();

function rateLimitLogin(ip: string | null): boolean {
  if (!ip) return true;
  const now = Date.now();
  let b = buckets.get(ip);
  if (!b) {
    b = { tokens: 10, last: now };
    buckets.set(ip, b);
  }
  b.tokens = Math.min(10, b.tokens + ((now - b.last) / 60000) * 10);
  b.last = now;
  if (b.tokens < 1) return false;
  b.tokens -= 1;
  return true;
}

// last_seen 节流：每设备 24h 一次
const lastSeen = new Map<string, number>();

// ---------- 应用工厂 ----------

export function buildApp(
  deps: Deps,
  opts: { ipWhitelist: string[]; trustedProxy: string; tlsCert?: string; tlsKey?: string },
): FastifyInstance {
  const app = Fastify({
    trustProxy: opts.trustedProxy,
    logger: false,
    ...(opts.tlsCert && opts.tlsKey
      ? {
          https: {
            cert: readFileSync(opts.tlsCert),
            key: readFileSync(opts.tlsKey),
          },
        }
      : {}),
  });
  void app.register(fastifyWebsocket);

  // WS 路由必须在 fastifyWebsocket 的插件作用域内注册（websocket 选项才生效）
  void app.register(async function (f) {
    f.get("/api/v1/ws", { websocket: true }, wsHandler(deps, authCtx));
  });

  // 真实 IP 注入
  app.addHook("onRequest", (req: Loc, _reply, done) => {
    req.clientIp = realIp(req, opts.trustedProxy);
    done();
  });

  // 请求日志（对齐 Go 版 http 行；healthz 除外）
  const startAt = new WeakMap<FastifyRequest, number>();
  app.addHook("onRequest", (req, _reply, done) => {
    startAt.set(req, Date.now());
    done();
  });
  app.addHook("onResponse", (req, reply, done) => {
    if (req.url !== "/healthz") {
      const start = startAt.get(req) ?? Date.now();
      console.log(
        `INFO http ${req.method} ${req.url} ip=${(req as Loc).clientIp ?? ""} dur=${Math.max(0, Date.now() - start)}ms`,
      );
    }
    done();
  });

  // 未映射错误 → 500（对齐 Go 版 recover；打印原因便于排查）
  app.setErrorHandler((err: Error, _req, reply) => {
    console.error("HTTP error:", err.message);
    void reply.code(500).send({ error: "internal" });
  });

  // IP 白名单（空 = 不启用）
  if (opts.ipWhitelist.length > 0) {
    app.addHook("onRequest", (req: Loc, reply, done) => {
      if (!cidrMatch(req.clientIp ?? "", opts.ipWhitelist)) {
        void reply.code(403).send({ error: "forbidden_ip" });
        return;
      }
      done();
    });
  }

  // ---------- 认证 ----------

  /** 解析 Bearer/query token → 设备与 vault。无 reply 副作用（WS 也复用）。 */
  async function authCtx(req: FastifyRequest): Promise<UserCtx | null> {
    const auth = req.headers["authorization"];
    const token =
      typeof auth === "string" && auth.startsWith("Bearer ")
        ? auth.slice(7).trim()
        : ((req.query as Record<string, string | undefined>)?.["token"] ?? "");
    if (!token) return null;
    const found = await userstore.deviceByTokenHash(deps.db, sha256(token));
    if (!found || found.device.revokedAt) return null;
    let vaultId: string;
    try {
      vaultId = await userstore.firstVaultOfUser(deps.db, found.device.userId);
    } catch {
      return null;
    }
    const now = Date.now();
    const last = lastSeen.get(found.device.id) ?? 0;
    if (now - last > 24 * 3600 * 1000) {
      lastSeen.set(found.device.id, now);
      void userstore.touchDevice(deps.db, found.device.id).catch(() => {});
    }
    return {
      userId: found.device.userId,
      deviceId: found.device.id,
      username: found.username,
      vaultId,
    };
  }

  async function authed(req: FastifyRequest, reply: FastifyReply): Promise<UserCtx | null> {
    const ctx = await authCtx(req);
    if (!ctx) void reply.code(401).send({ error: "unauthorized" });
    return ctx;
  }

  // ---------- 路由 ----------

  app.get("/healthz", async () => ({ status: "ok", version: VERSION }));

  app.post("/api/v1/auth/login", async (req, reply) => {
    const ip = (req as Loc).clientIp ?? null;
    if (!rateLimitLogin(ip)) return reply.code(429).send({ error: "rate_limited" });
    const body = req.body as
      | { username?: string; password?: string; device_name?: string; platform?: string }
      | undefined;
    if (!body) return reply.code(400).send({ error: "bad_json" });
    try {
      const res = await deps.auth.login(
        body.username ?? "",
        body.password ?? "",
        body.device_name ?? "",
        body.platform ?? "",
        ip,
      );
      return {
        token: res.token,
        device_id: res.deviceId,
        user: { id: res.userId, username: res.username },
        vault_id: res.vaultId,
      };
    } catch (e) {
      if (e instanceof BadCredentialsError) return reply.code(401).send({ error: "bad_credentials" });
      if (e instanceof DeviceNameError) {
        return reply.code(400).send({ error: "device_name_and_platform_required" });
      }
      if (e instanceof NoVaultError) return reply.code(403).send({ error: "no_vault" });
      if (e instanceof LockedError) {
        return reply
          .code(423)
          .send({ error: "locked", retry_after: Math.floor(e.until.getTime() / 1000) });
      }
      throw e;
    }
  });

  app.post("/api/v1/auth/password", async (req, reply) => {
    const ctx = await authed(req, reply);
    if (!ctx) return;
    const body = req.body as { old_password?: string; new_password?: string } | undefined;
    if (
      !body ||
      typeof body.old_password !== "string" ||
      typeof body.new_password !== "string"
    ) {
      return reply.code(400).send({ error: "bad_json" });
    }
    try {
      await deps.auth.changePassword(
        ctx.userId,
        body.old_password,
        body.new_password,
        (req as Loc).clientIp ?? null,
      );
      return { ok: true };
    } catch (e) {
      if (e instanceof BadCredentialsError) return reply.code(401).send({ error: "bad_credentials" });
      if (e instanceof WeakPasswordError) return reply.code(400).send({ error: "weak_password" });
      throw e;
    }
  });

  app.post("/api/v1/auth/logout", async (req, reply) => {    const ctx = await authed(req, reply);
    if (!ctx) return;
    const hit = await userstore.revokeDevice(deps.db, ctx.userId, ctx.deviceId);
    if (hit) {
      await userstore.audit(
        deps.db,
        ctx.userId,
        ctx.deviceId,
        "auth.logout",
        "device",
        ctx.deviceId,
        null,
        (req as Loc).clientIp ?? null,
      );
    }
    return { ok: hit };
  });

  app.get("/api/v1/me", async (req, reply) => {
    const ctx = await authed(req, reply);
    if (!ctx) return;
    return {
      user: { id: ctx.userId, username: ctx.username },
      device: { id: ctx.deviceId },
      vault_id: ctx.vaultId,
    };
  });

  app.get("/api/v1/devices", async (req, reply) => {
    const ctx = await authed(req, reply);
    if (!ctx) return;
    const devs = await userstore.listDevices(deps.db, ctx.userId);
    return {
      devices: devs.map((d) => ({
        id: d.id,
        name: d.name,
        platform: d.platform,
        created_at: d.createdAt,
        ...(d.lastSeenAt ? { last_seen_at: d.lastSeenAt } : {}),
        ...(d.revokedAt ? { revoked_at: d.revokedAt } : {}),
      })),
    };
  });

  app.delete("/api/v1/devices/:id", async (req, reply) => {
    const ctx = await authed(req, reply);
    if (!ctx) return;
    const id = (req.params as { id: string }).id;
    const hit = await userstore.revokeDevice(deps.db, ctx.userId, id);
    if (hit) {
      await userstore.audit(
        deps.db,
        ctx.userId,
        ctx.deviceId,
        "device.revoke",
        "device",
        id,
        null,
        (req as Loc).clientIp ?? null,
      );
    }
    return { ok: hit };
  });

  app.get("/api/v1/sync/pull", async (req, reply) => {
    const ctx = await authed(req, reply);
    if (!ctx) return;
    const q = req.query as Record<string, string | undefined>;
    let cursor: number;
    try {
      cursor = parseCursor(q.cursor);
    } catch (e) {
      return reply.code(400).send({ error: (e as Error).message });
    }
    let limit = 200;
    if (q.limit) {
      const n = Number(q.limit);
      if (Number.isInteger(n) && n > 0 && n <= 1000) limit = n;
    }
    return deps.engine.pull(deps.db.uuidToBytes(ctx.vaultId), cursor, limit);
  });

  app.post("/api/v1/sync/push", async (req, reply) => {
    const ctx = await authed(req, reply);
    if (!ctx) return;
    const body = req.body as
      | {
          changes?: Array<{
            entity_type?: string;
            entity_id?: string;
            base_rev?: number;
            op?: string;
            data?: Record<string, unknown>;
          }>;
        }
      | undefined;
    if (!body?.changes) return reply.code(400).send({ error: "bad_json" });
    if (body.changes.length === 0) return reply.code(400).send({ error: "empty_changes" });
    if (body.changes.length > 500) return reply.code(400).send({ error: "too_many_changes" });
    const items = body.changes.map((c) => ({
      entityType: c.entity_type ?? "",
      entityId: c.entity_id ?? "",
      baseRev: Number(c.base_rev ?? 0),
      op: c.op ?? "",
      data: c.data,
    }));
    const results = await deps.engine.push(
      deps.db.uuidToBytes(ctx.vaultId),
      deps.db.uuidToBytes(ctx.deviceId),
      items,
    );
    void userstore.audit(
      deps.db,
      ctx.userId,
      ctx.deviceId,
      "sync.push",
      "",
      null,
      { count: items.length },
      (req as Loc).clientIp ?? null,
    );
    return { results };
  });

  return app;
}

/** WS 通知通道处理器：握手后订阅 hub，广播帧 {"type":"change","rev":N}。 */
function wsHandler(deps: Deps, authCtx: (req: FastifyRequest) => Promise<UserCtx | null>) {
  return (conn: unknown, req: FastifyRequest): void => {
    void (async () => {
      // @fastify/websocket 各版本第一参数形态不同：裸 WebSocket 或 { socket } 包装
      type WsLike = {
        send: (d: string) => void;
        ping: () => void;
        close: (c?: number, r?: string) => void;
        on: (ev: string, fn: () => void) => void;
      };
      const connAny = conn as { socket?: WsLike };
      const socket: WsLike = (connAny.socket ?? conn) as WsLike;
      const ctx = await authCtx(req);
      if (!ctx) {
        socket.close(1008, "unauthorized");
        return;
      }
      const unsub = deps.hub.subscribe((rev) => {
        try {
          socket.send(JSON.stringify({ type: "change", rev }));
        } catch {
          socket.close();
        }
      });
      const ping = setInterval(() => {
        try {
          socket.ping();
        } catch {
          /* closed */
        }
      }, 30000);
      socket.on("close", () => {
        clearInterval(ping);
        unsub();
      });
      socket.on("error", () => socket.close());
      socket.on("message", () => {
        /* 仅消费 */
      });
    })();
  };
}

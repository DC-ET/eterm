// eterm 中枢服务端入口。子命令：serve / migrate / create-user。

import { createInterface } from "node:readline";
import { ConfigError, loadConfig, parseListen } from "./config.ts";
import { Db } from "./store/db.ts";
import { runMigrations } from "./store/migrate.ts";
import { Hub } from "./hub.ts";
import { SyncEngine } from "./syncengine.ts";
import { AuthService } from "./auth/service.ts";
import { hashPassword } from "./auth/argon.ts";
import { buildApp } from "./api/app.ts";
import * as userstore from "./store/userstore.ts";

export const VERSION = "0.1.0-ts";

function usage(): void {
  console.log(`eterm — 主机与凭据数据中枢

用法:
  eterm serve          启动服务（默认 127.0.0.1:8080；配置 TLS 证书后直接对外 HTTPS）
  eterm migrate        执行数据库迁移
  eterm create-user [--stdin-password]
                       交互式创建管理员与其个人 vault；
                       --stdin-password 从 stdin 读两行（用户名/口令），供自动化部署
  eterm version        显示版本

必填环境变量:
  ETERM_DB_DSN         MySQL DSN，如 eterm:pw@tcp(127.0.0.1:3306)/eterm?parseTime=true
  ETERM_MASTER_KEY     base64 的 64 字节主密钥（serve 必填）
  ETERM_PEPPER         口令 pepper（serve/create-user 必填）
可选:
  ETERM_LISTEN         监听地址，默认 127.0.0.1:8080
  ETERM_TLS_CERT/ETERM_TLS_KEY   TLS 证书与私钥路径（同时设置则启用 HTTPS）
  ETERM_IP_WHITELIST   逗号分隔 CIDR 白名单，空=不启用
  ETERM_TLS_TRUSTED_PROXY  受信反代地址，默认 127.0.0.1`);
}

async function main(): Promise<void> {
  const cmd = process.argv[2] ?? "serve";
  switch (cmd) {
    case "serve":
      return runServe();
    case "migrate":
      return runMigrate();
    case "create-user":
      return runCreateUser();
    case "version":
    case "--version":
    case "-v":
      console.log("eterm", VERSION);
      return;
    default:
      usage();
      process.exit(2);
  }
}

// ---- serve ----

async function runServe(): Promise<void> {
  const cfg = loadConfig({ requireMasterKey: true });
  const db = new Db(cfg.db, cfg.masterKey);
  await runMigrations(cfg.db);
  console.log("数据库就绪");

  const hub = new Hub();
  const engine = new SyncEngine(db, hub);
  const auth = new AuthService(db, cfg.pepper);
  const app = buildApp(
    { db, auth, engine, hub },
    {
      ipWhitelist: cfg.ipWhitelist,
      trustedProxy: cfg.trustedProxy,
      tlsCert: cfg.tlsCert,
      tlsKey: cfg.tlsKey,
    },
  );

  const { host, port } = parseListen(cfg.listen);
  const scheme = cfg.tlsCert && cfg.tlsKey ? "https" : "http";
  console.log(`eterm serve 启动 listen=${cfg.listen} version=${VERSION} scheme=${scheme} ip_whitelist=${cfg.ipWhitelist.length}`);

  await app.listen({ host, port });

  const shutdown = async (): Promise<void> => {
    console.log("收到退出信号，优雅关闭…");
    try {
      await app.close();
      await db.close();
    } finally {
      process.exit(0);
    }
  };
  process.on("SIGINT", () => void shutdown());
  process.on("SIGTERM", () => void shutdown());
}

// ---- migrate ----

async function runMigrate(): Promise<void> {
  const cfg = loadConfig({ requireMasterKey: false });
  await runMigrations(cfg.db);
}

// ---- create-user ----

async function runCreateUser(): Promise<void> {
  const interactive = !process.argv.slice(3).includes("--stdin-password");
  const cfg = loadConfig({ requireMasterKey: false });

  let username: string;
  let pw1: string;
  if (interactive) {
    username = (await prompt("用户名: ")).trim();
    if (!username) throw new Error("用户名不能为空");
    pw1 = await promptPassword("设置口令（至少 8 位）: ");
    const pw2 = await promptPassword("确认口令: ");
    if (pw1 !== pw2) throw new Error("两次口令不一致");
  } else {
    const lines = await readTwoLines();
    username = lines[0]!.trim();
    pw1 = lines[1]!.trim();
    if (!username) throw new Error("stdin 第一行必须是用户名");
  }
  if (pw1.length < 8) throw new Error("口令过短（至少 8 位）");

  const adminDb = await openPlainDb(cfg.db);
  try {
    if (await userstore.getUserByUsername(adminDb, username)) {
      throw new Error(`用户 ${JSON.stringify(username)} 已存在`);
    }
    const hash = await hashPassword(pw1, cfg.pepper);
    const userId = await userstore.createUser(adminDb, username, hash);
    const vaultId = await userstore.createPersonalVault(adminDb, userId, `${username}-personal`);
    console.log(`✔ 用户已创建: ${username} (${userId})`);
    console.log(`✔ 个人 vault: ${vaultId}`);
  } finally {
    await adminDb.close();
  }
}

async function openPlainDb(cfgDb: {
  host: string;
  port: number;
  user: string;
  password: string;
  database: string;
}): Promise<Db> {
  const db = new Db(cfgDb, Buffer.alloc(0));
  return db;
}

// ---- IO helpers ----

function prompt(question: string): Promise<string> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(question, (a) => {
      rl.close();
      resolve(a);
    });
  });
}

function promptPassword(question: string): Promise<string> {
  // 静默读取：prompt 照常输出，输入内容不回显（无 TTY 时退化为普通读取）
  const muted = new (class extends require("node:stream").Writable() {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    constructor() { super(); }
    _write(_chunk: unknown, _enc: unknown, cb: (e?: Error | null) => void): void {
      cb(null);
    }
  })();
  process.stdout.write(question);
  const rl = createInterface({ input: process.stdin, output: muted as never, terminal: true });
  return new Promise((resolve) => {
    rl.question("", (a) => {
      process.stdout.write("\n");
      rl.close();
      resolve(a);
    });
  });
}

function readTwoLines(): Promise<[string, string]> {
  const rl = createInterface({ input: process.stdin });
  const lines: string[] = [];
  return new Promise((resolve, reject) => {
    rl.on("line", (l) => {
      lines.push(l);
      if (lines.length >= 2) {
        rl.close();
        resolve([lines[0]!, lines[1]!]);
      }
    });
    rl.on("close", () => {
      if (lines.length < 2) reject(new Error("stdin 需要两行：用户名/口令"));
    });
  });
}

main().catch((e) => {
  if (e instanceof ConfigError) {
    console.error("ERROR", e.message);
  } else {
    console.error("退出", "err=", e);
  }
  process.exit(1);
});

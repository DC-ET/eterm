// 配置加载：全部来自环境变量（与 Go 版同名，部署环境无缝切换）。
// DSN 沿用 Go 风格 `user:pass@tcp(host:port)/db?params`，此处解析为 mysql2 配置。

export interface DbConfig {
  host: string;
  port: number;
  user: string;
  password: string;
  database: string;
}

export class ConfigError extends Error {}

export interface Config {
  masterKey: Buffer;
  pepper: string;
  db: DbConfig;
  listen: string;
  ipWhitelist: string[];
  trustedProxy: string;
  tlsCert?: string;
  tlsKey?: string;
}

export function parseGoDsn(dsn: string): DbConfig & { params: URLSearchParams } {
  // 密码可缺省（root 免密本地开发）：user@tcp(...) 与 user:pass@tcp(...) 均可
  const m = /^(?:([^:@]*)(?::([^@]*))?@)?tcp\(([^)]+)\)\/([^?]+)(\?.*)?$/.exec(dsn);
  if (!m) {
    throw new ConfigError("ETERM_DB_DSN 格式非法，应为 user:pass@tcp(host:port)/db?params");
  }
  const [, user = "", password = "", hostport, database, qs] = m;
  const lastColon = hostport.lastIndexOf(":");
  const host = lastColon === -1 ? hostport : hostport.slice(0, lastColon);
  const port = lastColon === -1 ? 3306 : Number(hostport.slice(lastColon + 1));
  if (!user || !host || !database || Number.isNaN(port)) {
    throw new ConfigError("ETERM_DB_DSN 解析失败");
  }
  return {
    host,
    port,
    user,
    password,
    database,
    params: new URLSearchParams(qs ?? ""),
  };
}

function required(name: string): string {
  const v = process.env[name]?.trim();
  if (!v) throw new ConfigError(`缺少必填环境变量 ${name}`);
  return v;
}

export function loadConfig(opts: { requireMasterKey: boolean }): Config {
  const errs: string[] = [];
  const pepper = process.env.ETERM_PEPPER?.trim() ?? "";
  const dsnRaw = process.env.ETERM_DB_DSN?.trim() ?? "";

  let masterKey: Buffer = Buffer.alloc(0);
  if (opts.requireMasterKey) {
    const mk = process.env.ETERM_MASTER_KEY?.trim() ?? "";
    if (!mk) errs.push("缺少必填环境变量 ETERM_MASTER_KEY");
    else {
      masterKey = Buffer.from(mk, "base64");
      if (masterKey.length !== 64) {
        errs.push(`ETERM_MASTER_KEY 解码后应为 64 字节，实际 ${masterKey.length}`);
      }
    }
  }
  if (!pepper) errs.push("缺少必填环境变量 ETERM_PEPPER");
  if (!dsnRaw) errs.push("缺少必填环境变量 ETERM_DB_DSN");
  if (errs.length) throw new ConfigError(errs.join("; "));

  // 主密钥供字段加密（AES-256 取前 32B；64B 与 Go 版格式对齐，预留轮换空间）
  const aesKey = opts.requireMasterKey ? masterKey.subarray(0, 32) : Buffer.alloc(0);

  return {
    masterKey: aesKey,
    pepper,
    db: parseGoDsn(dsnRaw),
    listen: process.env.ETERM_LISTEN?.trim() || "127.0.0.1:8080",
    ipWhitelist: (process.env.ETERM_IP_WHITELIST?.trim() || "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean),
    trustedProxy: process.env.ETERM_TLS_TRUSTED_PROXY?.trim() || "127.0.0.1",
    tlsCert: process.env.ETERM_TLS_CERT?.trim() || undefined,
    tlsKey: process.env.ETERM_TLS_KEY?.trim() || undefined,
  };
}

export function parseListen(listen: string): { host: string; port: number } {
  const i = listen.lastIndexOf(":");
  if (i === -1) throw new ConfigError(`ETERM_LISTEN 非法: ${listen}`);
  return { host: listen.slice(0, i), port: Number(listen.slice(i + 1)) };
}

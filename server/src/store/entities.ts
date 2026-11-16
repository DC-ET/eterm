// 同步实体元数据——与 Go 版逐列对齐（wire 名即列名，changes.entity_type ENUM 一致）。
// 驱动 pull 解码与 push 编码/校验（技术方案 §3.2/§3.3）。

export const enum ColKind {
  Uuid,
  UuidNull,
  Str,
  StrNull,
  Enc,
  EncNull,
  Json,
  JsonNull,
  Int,
  IntNull,
  Bool,
  BoolNull,
}

export interface Col {
  name: string;
  kind: ColKind;
  notNull: boolean;
}

export interface Entity {
  type: string;
  table: string;
  cols: Col[];
  validate: (m: Record<string, unknown>) => void;
}

export class ValidationError extends Error {}

function reqStr(m: Record<string, unknown>, keys: string[]): void {
  for (const k of keys) {
    const v = m[k];
    if (v === undefined || v === null) throw new ValidationError(`缺少必填字段 ${k}`);
    if (typeof v !== "string") throw new ValidationError(`字段 ${k} 应为字符串`);
  }
}

function limitLen(m: Record<string, unknown>, key: string, max: number): void {
  const v = m[key];
  if (typeof v === "string" && Buffer.byteLength(v) > max) {
    throw new ValidationError(`字段 ${key} 超长（>${max} 字节）`);
  }
}

export const ENTITIES: Record<string, Entity> = {};
function register(e: Entity): void {
  if (ENTITIES[e.type]) throw new Error("duplicate entity type " + e.type);
  ENTITIES[e.type] = e;
}

export function getEntity(t: string): Entity | undefined {
  return ENTITIES[t];
}

export function selectColumns(e: Entity): string {
  const names = ["id", "vault_id", ...e.cols.map((c) => c.name), "rev", "created_at", "updated_at", "deleted_at"];
  return names.join(", ");
}

register({
  type: "host_group",
  table: "host_groups",
  cols: [
    { name: "parent_id", kind: ColKind.UuidNull, notNull: false },
    { name: "label", kind: ColKind.Str, notNull: true },
    { name: "settings_json", kind: ColKind.JsonNull, notNull: false },
    { name: "sort", kind: ColKind.Int, notNull: true },
  ],
  validate: (m) => reqStr(m, ["label"]),
});

register({
  type: "host",
  table: "hosts",
  cols: [
    { name: "group_id", kind: ColKind.UuidNull, notNull: false },
    { name: "label", kind: ColKind.Str, notNull: true },
    { name: "hostname", kind: ColKind.Str, notNull: true },
    { name: "tags", kind: ColKind.Json, notNull: true },
    { name: "icon", kind: ColKind.StrNull, notNull: false },
    { name: "notes", kind: ColKind.StrNull, notNull: false },
    { name: "settings_json", kind: ColKind.JsonNull, notNull: false },
  ],
  validate: (m) => {
    reqStr(m, ["label", "hostname"]);
    limitLen(m, "hostname", 255);
  },
});

register({
  type: "host_protocol",
  table: "host_protocols",
  cols: [
    { name: "host_id", kind: ColKind.Uuid, notNull: true },
    { name: "kind", kind: ColKind.Str, notNull: true },
    { name: "config_json", kind: ColKind.Json, notNull: true },
    { name: "sort", kind: ColKind.Int, notNull: true },
  ],
  validate: (m) => {
    reqStr(m, ["kind"]);
    if (!["ssh", "sftp", "telnet", "serial"].includes(m["kind"] as string)) {
      throw new ValidationError("kind 必须为 ssh|sftp|telnet|serial");
    }
  },
});

register({
  type: "identity",
  table: "identities",
  cols: [
    { name: "label", kind: ColKind.Str, notNull: true },
    { name: "username", kind: ColKind.Str, notNull: true },
    { name: "password_enc", kind: ColKind.EncNull, notNull: false },
    { name: "key_id", kind: ColKind.UuidNull, notNull: false },
  ],
  validate: (m) => reqStr(m, ["label", "username"]),
});

register({
  type: "ssh_key",
  table: "ssh_keys",
  cols: [
    { name: "label", kind: ColKind.Str, notNull: true },
    { name: "key_type", kind: ColKind.Str, notNull: true },
    { name: "private_enc", kind: ColKind.Enc, notNull: true },
    { name: "cert_enc", kind: ColKind.EncNull, notNull: false },
    { name: "passphrase_enc", kind: ColKind.EncNull, notNull: false },
    { name: "public_key", kind: ColKind.Str, notNull: true },
    { name: "fingerprint", kind: ColKind.Str, notNull: true },
    { name: "origin", kind: ColKind.Str, notNull: true },
    { name: "key_version", kind: ColKind.Int, notNull: true },
    { name: "superseded_by", kind: ColKind.UuidNull, notNull: false },
  ],
  validate: (m) => {
    reqStr(m, ["label", "key_type", "private_enc", "public_key", "fingerprint", "origin"]);
    if (!["generated", "imported", "fido2", "biometric"].includes(m["origin"] as string)) {
      throw new ValidationError("origin 必须为 generated|imported|fido2|biometric");
    }
  },
});

register({
  type: "known_host",
  table: "known_hosts",
  cols: [
    { name: "hostname", kind: ColKind.Str, notNull: true },
    { name: "key_type", kind: ColKind.Str, notNull: true },
    { name: "key_enc", kind: ColKind.Enc, notNull: true },
    { name: "comment", kind: ColKind.StrNull, notNull: false },
  ],
  validate: (m) => reqStr(m, ["hostname", "key_type", "key_enc"]),
});

register({
  type: "port_rule",
  table: "port_rules",
  cols: [
    { name: "host_id", kind: ColKind.Uuid, notNull: true },
    { name: "label", kind: ColKind.Str, notNull: true },
    { name: "kind", kind: ColKind.Str, notNull: true },
    { name: "bind_addr", kind: ColKind.Str, notNull: true },
    { name: "local_port", kind: ColKind.IntNull, notNull: false },
    { name: "remote_host", kind: ColKind.StrNull, notNull: false },
    { name: "remote_port", kind: ColKind.IntNull, notNull: false },
    { name: "enabled", kind: ColKind.Bool, notNull: true },
  ],
  validate: (m) => {
    reqStr(m, ["label", "kind", "bind_addr"]);
    if (!["local", "remote", "dynamic"].includes(m["kind"] as string)) {
      throw new ValidationError("kind 必须为 local|remote|dynamic");
    }
    for (const p of ["local_port", "remote_port"]) {
      const v = m[p];
      if (v !== undefined && v !== null) {
        if (typeof v !== "number" || !Number.isInteger(v)) {
          throw new ValidationError(`字段 ${p} 应为整数`);
        }
        if (v < 1 || v > 65535) throw new ValidationError(`字段 ${p} 应在 1-65535`);
      }
    }
  },
});

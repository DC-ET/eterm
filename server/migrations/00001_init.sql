-- +goose Up
-- eterm 初始 schema（对应 docs/plan/eterm-技术方案.md §3.2）

CREATE TABLE users (
  id            BINARY(16) PRIMARY KEY,
  username      VARCHAR(64) NOT NULL UNIQUE,
  pwd_hash      VARCHAR(255) NOT NULL,
  failed_count  INT NOT NULL DEFAULT 0,
  locked_until  DATETIME(3) NULL,
  created_at    DATETIME(3) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE devices (
  id           BINARY(16) PRIMARY KEY,
  user_id      BINARY(16) NOT NULL,
  name         VARCHAR(64) NOT NULL,
  platform     VARCHAR(32) NOT NULL,
  token_hash   BINARY(32) NOT NULL UNIQUE,
  created_at   DATETIME(3) NOT NULL,
  last_seen_at DATETIME(3) NULL,
  revoked_at   DATETIME(3) NULL,
  INDEX idx_devices_user (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE vaults (
  id         BINARY(16) PRIMARY KEY,
  name       VARCHAR(128) NOT NULL,
  scope      ENUM('personal','team') NOT NULL DEFAULT 'personal',
  owner_id   BINARY(16) NOT NULL,
  rev        BIGINT NOT NULL DEFAULT 0,
  created_at DATETIME(3) NOT NULL,
  updated_at DATETIME(3) NOT NULL,
  deleted_at DATETIME(3) NULL,
  INDEX idx_vaults_owner (owner_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE host_groups (
  id BINARY(16) PRIMARY KEY,
  vault_id BINARY(16) NOT NULL,
  parent_id BINARY(16) NULL,
  label VARCHAR(128) NOT NULL,
  settings_json JSON NULL,
  sort INT NOT NULL DEFAULT 0,
  rev BIGINT NOT NULL DEFAULT 0,
  created_at DATETIME(3) NOT NULL,
  updated_at DATETIME(3) NOT NULL,
  deleted_at DATETIME(3) NULL,
  INDEX idx_hg_vault (vault_id),
  INDEX idx_hg_parent (parent_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE hosts (
  id BINARY(16) PRIMARY KEY,
  vault_id BINARY(16) NOT NULL,
  group_id BINARY(16) NULL,
  label VARCHAR(128) NOT NULL,
  hostname VARCHAR(255) NOT NULL,
  tags JSON NOT NULL,
  icon VARCHAR(64) NULL,
  notes TEXT NULL,
  settings_json JSON NULL,
  rev BIGINT NOT NULL DEFAULT 0,
  created_at DATETIME(3) NOT NULL,
  updated_at DATETIME(3) NOT NULL,
  deleted_at DATETIME(3) NULL,
  INDEX idx_hosts_vault_group (vault_id, group_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE host_protocols (
  id BINARY(16) PRIMARY KEY,
  vault_id BINARY(16) NOT NULL,
  host_id BINARY(16) NOT NULL,
  kind ENUM('ssh','sftp','telnet','serial') NOT NULL,
  config_json JSON NOT NULL,
  sort INT NOT NULL DEFAULT 0,
  rev BIGINT NOT NULL DEFAULT 0,
  created_at DATETIME(3) NOT NULL,
  updated_at DATETIME(3) NOT NULL,
  deleted_at DATETIME(3) NULL,
  INDEX idx_hp_host (host_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE identities (
  id BINARY(16) PRIMARY KEY,
  vault_id BINARY(16) NOT NULL,
  label VARCHAR(128) NOT NULL,
  username VARCHAR(128) NOT NULL,
  password_enc VARBINARY(1024) NULL,
  key_id BINARY(16) NULL,
  rev BIGINT NOT NULL DEFAULT 0,
  created_at DATETIME(3) NOT NULL,
  updated_at DATETIME(3) NOT NULL,
  deleted_at DATETIME(3) NULL,
  INDEX idx_id_vault (vault_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE ssh_keys (
  id BINARY(16) PRIMARY KEY,
  vault_id BINARY(16) NOT NULL,
  label VARCHAR(128) NOT NULL,
  key_type VARCHAR(32) NOT NULL,
  private_enc VARBINARY(16384) NOT NULL,
  cert_enc VARBINARY(16384) NULL,
  passphrase_enc VARBINARY(1024) NULL,
  public_key TEXT NOT NULL,
  fingerprint VARCHAR(128) NOT NULL,
  origin ENUM('generated','imported','fido2','biometric') NOT NULL,
  key_version INT NOT NULL DEFAULT 1,
  superseded_by BINARY(16) NULL,
  rev BIGINT NOT NULL DEFAULT 0,
  created_at DATETIME(3) NOT NULL,
  updated_at DATETIME(3) NOT NULL,
  deleted_at DATETIME(3) NULL,
  INDEX idx_sk_vault (vault_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE known_hosts (
  id BINARY(16) PRIMARY KEY,
  vault_id BINARY(16) NOT NULL,
  hostname VARCHAR(255) NOT NULL,
  key_type VARCHAR(32) NOT NULL,
  key_enc VARBINARY(2048) NOT NULL,
  comment VARCHAR(255) NULL,
  rev BIGINT NOT NULL DEFAULT 0,
  created_at DATETIME(3) NOT NULL,
  updated_at DATETIME(3) NOT NULL,
  deleted_at DATETIME(3) NULL,
  INDEX idx_kh_vault (vault_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE port_rules (
  id BINARY(16) PRIMARY KEY,
  vault_id BINARY(16) NOT NULL,
  host_id BINARY(16) NOT NULL,
  label VARCHAR(128) NOT NULL,
  kind ENUM('local','remote','dynamic') NOT NULL,
  bind_addr VARCHAR(64) NOT NULL DEFAULT '127.0.0.1',
  local_port SMALLINT UNSIGNED NULL,
  remote_host VARCHAR(255) NULL,
  remote_port SMALLINT UNSIGNED NULL,
  enabled BOOLEAN NOT NULL DEFAULT FALSE,
  rev BIGINT NOT NULL DEFAULT 0,
  created_at DATETIME(3) NOT NULL,
  updated_at DATETIME(3) NOT NULL,
  deleted_at DATETIME(3) NULL,
  INDEX idx_pr_host (host_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Snippets 需求已移除（2026-11）：实体注册已删（server/src/store/entities.ts），
-- 不再参与同步。两表保留不删——生产库与新建库 schema 保持一致，省一次破坏性迁移；
-- changes.entity_type ENUM 中的 snippet 值同为保留兼容，服务端不会再写入。
CREATE TABLE snippet_packages (
  id BINARY(16) PRIMARY KEY,
  vault_id BINARY(16) NOT NULL,
  label VARCHAR(128) NOT NULL,
  sort INT NOT NULL DEFAULT 0,
  rev BIGINT NOT NULL DEFAULT 0,
  created_at DATETIME(3) NOT NULL,
  updated_at DATETIME(3) NOT NULL,
  deleted_at DATETIME(3) NULL,
  INDEX idx_sp_vault (vault_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE snippets (
  id BINARY(16) PRIMARY KEY,
  vault_id BINARY(16) NOT NULL,
  package_id BINARY(16) NULL,
  description VARCHAR(255) NOT NULL,
  script MEDIUMTEXT NOT NULL,
  target_host_ids JSON NOT NULL,
  vars_json JSON NULL,
  rev BIGINT NOT NULL DEFAULT 0,
  created_at DATETIME(3) NOT NULL,
  updated_at DATETIME(3) NOT NULL,
  deleted_at DATETIME(3) NULL,
  INDEX idx_sn_vault (vault_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE changes (
  id           BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  entity_type  ENUM('host_group','host','host_protocol','identity','ssh_key',
                    'known_host','port_rule','snippet','snippet_package') NOT NULL,
  entity_id    BINARY(16) NOT NULL,
  vault_id     BINARY(16) NOT NULL,
  actor_device BINARY(16) NULL,
  ts           DATETIME(3) NOT NULL,
  INDEX idx_changes_cursor (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE audit_events (
  id           BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  ts           DATETIME(3) NOT NULL,
  actor_user   BINARY(16) NOT NULL,
  actor_device BINARY(16) NULL,
  action       VARCHAR(64) NOT NULL,
  target_type  VARCHAR(64) NULL,
  target_id    BINARY(16) NULL,
  detail_json  JSON NULL,
  ip           VARCHAR(45) NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- +goose Down
DROP TABLE IF EXISTS audit_events;
DROP TABLE IF EXISTS changes;
DROP TABLE IF EXISTS snippets;
DROP TABLE IF EXISTS snippet_packages;
DROP TABLE IF EXISTS port_rules;
DROP TABLE IF EXISTS known_hosts;
DROP TABLE IF EXISTS ssh_keys;
DROP TABLE IF EXISTS identities;
DROP TABLE IF EXISTS host_protocols;
DROP TABLE IF EXISTS hosts;
DROP TABLE IF EXISTS host_groups;
DROP TABLE IF EXISTS vaults;
DROP TABLE IF EXISTS devices;
DROP TABLE IF EXISTS users;

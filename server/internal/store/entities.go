package store

import (
	"fmt"
	"strings"
)

// ColKind 声明列的语义类型，驱动 pull 解码与 push 编码（技术方案 §3.2/§3.3）。
type ColKind uint8

const (
	KUUID  ColKind = iota // BINARY(16) NOT NULL
	KUUIDN                // BINARY(16) NULL
	KStr                  // VARCHAR/TEXT NOT NULL
	KStrN
	KEnc   // VARBINARY，落库前 Seal，读出后 Open
	KEncN
	KJSON  // JSON NOT NULL
	KJSONN // JSON NULL
	KInt
	KIntN
	KBool  // BOOLEAN(TINYINT(1)) NOT NULL
	KBoolN
)

// Col 实体业务列（不含 id/vault_id/rev/created_at/updated_at/deleted_at 公共列）。
type Col struct {
	Name    string
	Kind    ColKind
	NotNull bool
}

// Entity 同步实体元数据。wire 名与 changes.entity_type ENUM 一致。
type Entity struct {
	Type     string
	Table    string
	Cols     []Col
	Validate func(m map[string]any) error
}

// 服务端管理的公共列（pull 输出包含；push 输入中忽略）。
const ServerCols = "id, vault_id, rev, created_at, updated_at, deleted_at"

var registry = map[string]*Entity{}

func mustRegister(e *Entity) {
	if _, dup := registry[e.Type]; dup {
		panic("duplicate entity type " + e.Type)
	}
	registry[e.Type] = e
}

// GetEntity 按 wire 名取实体定义。
func GetEntity(t string) (*Entity, bool) {
	e, ok := registry[t]
	return e, ok
}

// Entities 返回全部实体定义。
func Entities() map[string]*Entity { return registry }

func reqStr(m map[string]any, keys ...string) error {
	for _, k := range keys {
		v, ok := m[k]
		if !ok || v == nil {
			return fmt.Errorf("缺少必填字段 %s", k)
		}
		if _, isStr := v.(string); !isStr {
			return fmt.Errorf("字段 %s 应为字符串", k)
		}
	}
	return nil
}

func limitLen(m map[string]any, key string, max int) error {
	if v, ok := m[key].(string); ok && len(v) > max {
		return fmt.Errorf("字段 %s 超长（>%d 字节）", key, max)
	}
	return nil
}

func init() {
	mustRegister(&Entity{Type: "host_group", Table: "host_groups", Cols: []Col{
		{Name: "parent_id", Kind: KUUIDN},
		{Name: "label", Kind: KStr, NotNull: true},
		{Name: "settings_json", Kind: KJSONN},
		{Name: "sort", Kind: KInt, NotNull: true},
	}, Validate: func(m map[string]any) error { return reqStr(m, "label") }})

	mustRegister(&Entity{Type: "host", Table: "hosts", Cols: []Col{
		{Name: "group_id", Kind: KUUIDN},
		{Name: "label", Kind: KStr, NotNull: true},
		{Name: "hostname", Kind: KStr, NotNull: true},
		{Name: "tags", Kind: KJSON, NotNull: true},
		{Name: "icon", Kind: KStrN},
		{Name: "notes", Kind: KStrN},
		{Name: "settings_json", Kind: KJSONN},
	}, Validate: func(m map[string]any) error {
		if err := reqStr(m, "label", "hostname"); err != nil {
			return err
		}
		return limitLen(m, "hostname", 255)
	}})

	mustRegister(&Entity{Type: "host_protocol", Table: "host_protocols", Cols: []Col{
		{Name: "host_id", Kind: KUUID, NotNull: true},
		{Name: "kind", Kind: KStr, NotNull: true},
		{Name: "config_json", Kind: KJSON, NotNull: true},
		{Name: "sort", Kind: KInt, NotNull: true},
	}, Validate: func(m map[string]any) error {
		if err := reqStr(m, "kind"); err != nil {
			return err
		}
		switch m["kind"] {
		case "ssh", "sftp", "telnet", "serial":
			return nil
		}
		return fmt.Errorf("kind 必须为 ssh|sftp|telnet|serial")
	}})

	mustRegister(&Entity{Type: "identity", Table: "identities", Cols: []Col{
		{Name: "label", Kind: KStr, NotNull: true},
		{Name: "username", Kind: KStr, NotNull: true},
		{Name: "password_enc", Kind: KEncN},
		{Name: "key_id", Kind: KUUIDN},
	}, Validate: func(m map[string]any) error { return reqStr(m, "label", "username") }})

	mustRegister(&Entity{Type: "ssh_key", Table: "ssh_keys", Cols: []Col{
		{Name: "label", Kind: KStr, NotNull: true},
		{Name: "key_type", Kind: KStr, NotNull: true},
		{Name: "private_enc", Kind: KEnc, NotNull: true},
		{Name: "cert_enc", Kind: KEncN},
		{Name: "passphrase_enc", Kind: KEncN},
		{Name: "public_key", Kind: KStr, NotNull: true},
		{Name: "fingerprint", Kind: KStr, NotNull: true},
		{Name: "origin", Kind: KStr, NotNull: true},
		{Name: "key_version", Kind: KInt, NotNull: true},
		{Name: "superseded_by", Kind: KUUIDN},
	}, Validate: func(m map[string]any) error {
		if err := reqStr(m, "label", "key_type", "private_enc", "public_key", "fingerprint", "origin"); err != nil {
			return err
		}
		switch m["origin"] {
		case "generated", "imported", "fido2", "biometric":
		default:
			return fmt.Errorf("origin 必须为 generated|imported|fido2|biometric")
		}
		// 密钥内容不可变版本化：新内容应生成新实体（新 id），本实体只允许改指针/元数据。
		return nil
	}})

	mustRegister(&Entity{Type: "known_host", Table: "known_hosts", Cols: []Col{
		{Name: "hostname", Kind: KStr, NotNull: true},
		{Name: "key_type", Kind: KStr, NotNull: true},
		{Name: "key_enc", Kind: KEnc, NotNull: true},
		{Name: "comment", Kind: KStrN},
	}, Validate: func(m map[string]any) error { return reqStr(m, "hostname", "key_type", "key_enc") }})

	mustRegister(&Entity{Type: "port_rule", Table: "port_rules", Cols: []Col{
		{Name: "host_id", Kind: KUUID, NotNull: true},
		{Name: "label", Kind: KStr, NotNull: true},
		{Name: "kind", Kind: KStr, NotNull: true},
		{Name: "bind_addr", Kind: KStr, NotNull: true},
		{Name: "local_port", Kind: KIntN},
		{Name: "remote_host", Kind: KStrN},
		{Name: "remote_port", Kind: KIntN},
		{Name: "enabled", Kind: KBool, NotNull: true},
	}, Validate: func(m map[string]any) error {
		if err := reqStr(m, "label", "kind", "bind_addr"); err != nil {
			return err
		}
		switch m["kind"] {
		case "local", "remote", "dynamic":
		default:
			return fmt.Errorf("kind 必须为 local|remote|dynamic")
		}
		for _, p := range []string{"local_port", "remote_port"} {
			if v, ok := m[p]; ok && v != nil {
				n, ok := v.(int64)
				if !ok {
					return fmt.Errorf("字段 %s 应为整数", p)
				}
				if n < 1 || n > 65535 {
					return fmt.Errorf("字段 %s 应在 1-65535", p)
				}
			}
		}
		return nil
	}})

	mustRegister(&Entity{Type: "snippet", Table: "snippets", Cols: []Col{
		{Name: "package_id", Kind: KUUIDN},
		{Name: "description", Kind: KStr, NotNull: true},
		{Name: "script", Kind: KStr, NotNull: true},
		{Name: "target_host_ids", Kind: KJSON, NotNull: true},
		{Name: "vars_json", Kind: KJSONN},
	}, Validate: func(m map[string]any) error {
		if err := reqStr(m, "description", "script"); err != nil {
			return err
		}
		return limitLen(m, "script", 64*1024)
	}})

	mustRegister(&Entity{Type: "snippet_package", Table: "snippet_packages", Cols: []Col{
		{Name: "label", Kind: KStr, NotNull: true},
		{Name: "sort", Kind: KInt, NotNull: true},
	}, Validate: func(m map[string]any) error { return reqStr(m, "label") }})
}

// selectColumns 返回 pull 查询的完整列清单（公共列 + 业务列）。
func (e *Entity) selectColumns() string {
	names := make([]string, 0, len(e.Cols)+6)
	names = append(names, "id", "vault_id")
	for _, c := range e.Cols {
		names = append(names, c.Name)
	}
	names = append(names, "rev", "created_at", "updated_at", "deleted_at")
	return strings.Join(names, ", ")
}

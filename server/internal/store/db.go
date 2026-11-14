// Package store 封装 MySQL 访问：同步实体存取、用户/设备、变更表。
package store

import (
	"database/sql"
	"fmt"
	"time"

	"github.com/google/uuid"
	_ "github.com/go-sql-driver/mysql"
)

// Store 持有连接与主密钥（字段加解密用）。
type Store struct {
	DB        *sql.DB
	MasterKey []byte
}

// Open 建立连接并 ping 验证。
func Open(dsn string, masterKey []byte) (*Store, error) {
	db, err := sql.Open("mysql", dsn)
	if err != nil {
		return nil, fmt.Errorf("打开数据库失败: %w", err)
	}
	db.SetMaxOpenConns(20)
	db.SetMaxIdleConns(10)
	db.SetConnMaxLifetime(30 * time.Minute)
	if err := db.Ping(); err != nil {
		return nil, fmt.Errorf("数据库连接失败: %w", err)
	}
	return &Store{DB: db, MasterKey: masterKey}, nil
}

func (s *Store) Close() error { return s.DB.Close() }

// ---------- UUID 工具 ----------

// NewUUID 生成 UUIDv7（时间有序；客户端离线生成实体 id，本函数服务端兜底用）。
func NewUUID() uuid.UUID { u, _ := uuid.NewV7(); return u }

func parseUUID(s string) ([]byte, error) {
	u, err := uuid.Parse(s)
	if err != nil {
		return nil, fmt.Errorf("非法 UUID %q: %w", s, err)
	}
	return u[:], nil
}

func uuidStr(b []byte) string {
	var u uuid.UUID
	copy(u[:], b)
	return u.String()
}

// ---------- 编解码：按列语义在 DB 值与 wire(JSON) 值间转换 ----------

// decodeCell DB → wire。enc 列读出即 Open（明文仅存在于响应构造瞬间）。
func (s *Store) decodeCell(k ColKind, v any) (any, error) {
	if v == nil {
		return nil, nil
	}
	switch k {
	case KUUID, KUUIDN:
		b, ok := v.([]byte)
		if !ok || len(b) != 16 {
			return nil, fmt.Errorf("uuid 列值异常: %T", v)
		}
		return uuidStr(b), nil
	case KStr, KStrN:
		switch t := v.(type) {
		case []byte:
			return string(t), nil
		case string:
			return t, nil
		}
		return nil, fmt.Errorf("字符串列值异常: %T", v)
	case KEnc, KEncN:
		b, ok := v.([]byte)
		if !ok {
			return nil, fmt.Errorf("加密列值异常: %T", v)
		}
		pt, err := OpenField(s.MasterKey, b)
		if err != nil {
			return nil, fmt.Errorf("解密字段失败: %w", err)
		}
		return string(pt), nil
	case KJSON, KJSONN:
		b, ok := v.([]byte)
		if !ok {
			if raw, isRaw := v.(jsonRaw); isRaw {
				return raw, nil
			}
			return nil, fmt.Errorf("JSON 列值异常: %T", v)
		}
		return jsonRaw(b), nil
	case KInt, KIntN:
		switch t := v.(type) {
		case int64:
			return t, nil
		case []byte: // text 协议兜底
			var n int64
			_, err := fmt.Sscanf(string(t), "%d", &n)
			return n, err
		}
		return nil, fmt.Errorf("整数列值异常: %T", v)
	case KBool, KBoolN:
		switch t := v.(type) {
		case int64:
			return t != 0, nil
		case []byte:
			return string(t) == "1" || string(t) == "true", nil
		}
		return nil, fmt.Errorf("布尔列值异常: %T", v)
	}
	return nil, fmt.Errorf("未知列类型 %d", k)
}

// encodeCell wire → DB。enc 列写入前 Seal。
func (s *Store) encodeCell(k ColKind, v any) (any, error) {
	if v == nil {
		return nil, nil
	}
	switch k {
	case KUUID, KUUIDN:
		s, ok := v.(string)
		if !ok {
			return nil, fmt.Errorf("uuid 字段应为字符串: %T", v)
		}
		return parseUUID(s)
	case KStr, KStrN:
		str, ok := v.(string)
		if !ok {
			return nil, fmt.Errorf("字符串字段应为字符串: %T", v)
		}
		return str, nil
	case KEnc, KEncN:
		str, ok := v.(string)
		if !ok {
			return nil, fmt.Errorf("加密字段应为字符串: %T", v)
		}
		return SealField(s.MasterKey, []byte(str))
	case KJSON, KJSONN:
		switch t := v.(type) {
		case jsonRaw:
			return []byte(t), nil
		default:
			return jsonMarshal(v)
		}
	case KInt, KIntN:
		switch t := v.(type) {
		case int64:
			return t, nil
		case jsonNumber:
			return t.Int64()
		}
		return nil, fmt.Errorf("整数字段类型异常: %T", v)
	case KBool, KBoolN:
		b, ok := v.(bool)
		if !ok {
			return nil, fmt.Errorf("布尔字段应为布尔: %T", v)
		}
		if b {
			return int64(1), nil
		}
		return int64(0), nil
	}
	return nil, fmt.Errorf("未知列类型 %d", k)
}

package store

import (
	"bytes"
	"encoding/base64"
	"encoding/json"

	"eterm/server/internal/crypto"
)

// jsonRaw 承载 JSON 列原始字节，json.Marshal 时原样内嵌（避免 []byte 被 base64）。
type jsonRaw []byte

func (r jsonRaw) MarshalJSON() ([]byte, error) {
	if len(r) == 0 {
		return []byte("null"), nil
	}
	return r, nil
}

func (r *jsonRaw) UnmarshalJSON(b []byte) error { *r = append((*r)[:0], b...); return nil }

// jsonNumber 对应解码端 UseNumber() 产生的 json.Number（此处用别名避免直接依赖解析器细节）。
type jsonNumber = json.Number

func jsonMarshal(v any) ([]byte, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	// 拒绝被误编码成字符串/number 的复杂结构（由调用方校验保证，这里仅防御空值）
	if bytes.Equal(b, []byte("null")) {
		return nil, nil
	}
	return b, nil
}

// SealField/OpenField 对 crypto 的薄封装（带 base64 与版本语义，供 encodeCell/decodeCell 使用）。
func SealField(key, plaintext []byte) ([]byte, error) {
	s, err := crypto.Seal(key, plaintext)
	if err != nil {
		return nil, err
	}
	return []byte(s), nil
}

func OpenField(key []byte, stored []byte) ([]byte, error) {
	return crypto.Open(key, string(stored))
}

// encodeB64 供调试与测试使用。
func encodeB64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

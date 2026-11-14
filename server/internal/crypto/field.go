// Package crypto 实现敏感字段静态加密（技术方案 §3.6）。
// 格式：v{n}:base64(nonce[12] || ciphertext || tag)，AES-256-GCM，每字段随机 nonce。
// v 前缀即密钥版本位，为未来轮换预留；当前仅 v1。
package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

const (
	prefixV1 = "v1:"
	nonceLen = 12
)

// Seal 加密明文，返回 "v1:..." 存储串。
func Seal(key, plaintext []byte) (string, error) {
	gcm, err := newGCM(key)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, nonceLen)
	if _, err := rand.Read(nonce); err != nil {
		return "", fmt.Errorf("生成 nonce 失败: %w", err)
	}
	ct := gcm.Seal(nil, nonce, plaintext, nil)
	out := make([]byte, 0, len(nonce)+len(ct))
	out = append(out, nonce...)
	out = append(out, ct...)
	return prefixV1 + base64.StdEncoding.EncodeToString(out), nil
}

// Open 解开 Seal 产生的存储串；未知版本返回错误。
func Open(key []byte, sealed string) ([]byte, error) {
	if !strings.HasPrefix(sealed, prefixV1) {
		return nil, fmt.Errorf("未知密文版本前缀: %q", prefixOf(sealed))
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(sealed, prefixV1))
	if err != nil {
		return nil, fmt.Errorf("密文 base64 非法: %w", err)
	}
	if len(raw) < nonceLen+16 {
		return nil, errors.New("密文过短")
	}
	gcm, err := newGCM(key)
	if err != nil {
		return nil, err
	}
	pt, err := gcm.Open(nil, raw[:nonceLen], raw[nonceLen:], nil)
	if err != nil {
		return nil, fmt.Errorf("解密失败（密钥不匹配或数据损坏）: %w", err)
	}
	return pt, nil
}

func newGCM(key []byte) (cipher.AEAD, error) {
	if len(key) != 32 {
		return nil, fmt.Errorf("主密钥应为 32 字节（AES-256），实际 %d", len(key))
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func prefixOf(s string) string {
	if i := strings.Index(s, ":"); i > 0 {
		if _, err := strconv.Atoi(s[1:i]); err == nil {
			return s[:i+1]
		}
	}
	return s
}

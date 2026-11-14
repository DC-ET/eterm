// Package config 加载服务端配置（技术方案 §3.7）。
// 全部来自环境变量；必填项缺失即返回错误，拒绝启动。
package config

import (
	"encoding/base64"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strings"
)

type Config struct {
	MasterKey    []byte // 64B，ETERM_MASTER_KEY（base64）
	Pepper       string
	DBDSN        string
	Listen       string // 默认 127.0.0.1:8080，公网暴露交给反代
	IPWhitelist  []string
	TrustedProxy string // 默认 127.0.0.1
}

// Load 读取并校验配置；DSN 会强制补上 parseTime/multiStatements/loc 参数。
func Load() (*Config, error) {
	var errs []error

	mk, err := requiredB64("ETERM_MASTER_KEY", 64)
	if err != nil {
		errs = append(errs, err)
	}
	pepper, err := required("ETERM_PEPPER")
	if err != nil {
		errs = append(errs, err)
	}
	dsn, err := required("ETERM_DB_DSN")
	if err != nil {
		errs = append(errs, err)
	}
	if len(errs) > 0 {
		return nil, errors.Join(errs...)
	}

	cfg := &Config{
		MasterKey:    mk,
		Pepper:       pepper,
		DBDSN:        NormalizeDSN(dsn),
		Listen:       getenv("ETERM_LISTEN", "127.0.0.1:8080"),
		TrustedProxy: getenv("ETERM_TLS_TRUSTED_PROXY", "127.0.0.1"),
	}
	if wl := os.Getenv("ETERM_IP_WHITELIST"); strings.TrimSpace(wl) != "" {
		for _, c := range strings.Split(wl, ",") {
			cfg.IPWhitelist = append(cfg.IPWhitelist, strings.TrimSpace(c))
		}
	}
	return cfg, nil
}

func required(name string) (string, error) {
	v := strings.TrimSpace(os.Getenv(name))
	if v == "" {
		return "", fmt.Errorf("缺少必填环境变量 %s", name)
	}
	return v, nil
}

func requiredB64(name string, wantLen int) ([]byte, error) {
	s, err := required(name)
	if err != nil {
		return nil, err
	}
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return nil, fmt.Errorf("%s 不是合法 base64: %w", name, err)
	}
	if len(b) != wantLen {
		return nil, fmt.Errorf("%s 解码后应为 %d 字节，实际 %d", name, wantLen, len(b))
	}
	return b, nil
}

func getenv(k, def string) string {
	if v := strings.TrimSpace(os.Getenv(k)); v != "" {
		return v
	}
	return def
}

// NormalizeDSN 确保驱动参数满足迁移与时间扫描需求（migrate/create-user 子命令也使用）。
func NormalizeDSN(dsn string) string {
	fixes := map[string]string{
		"parseTime":       "true",
		"multiStatements": "true",
		"loc":             "UTC",
	}
	sep := "?"
	if strings.Contains(dsn, "?") {
		sep = "&"
	}
	var sb strings.Builder
	sb.WriteString(dsn)
	for k, v := range fixes {
		if !strings.Contains(dsn, k+"=") {
			sb.WriteString(sep)
			sb.WriteString(k)
			sb.WriteString("=")
			sb.WriteString(url.QueryEscape(v))
			sep = "&"
		}
	}
	return sb.String()
}

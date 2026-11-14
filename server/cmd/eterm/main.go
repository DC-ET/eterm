// eterm 中枢服务端。子命令：serve / migrate / create-user。
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"golang.org/x/term"

	"eterm/server/internal/api"
	"eterm/server/internal/auth"
	"eterm/server/internal/config"
	"eterm/server/internal/hub"
	"eterm/server/internal/syncengine"
	"eterm/server/internal/store"
	"eterm/server/migrations"
)

const version = "0.1.0-dev"

func main() {
	cmd := "serve"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	var err error
	switch cmd {
	case "serve":
		err = runServe()
	case "migrate":
		err = runMigrate()
	case "create-user":
		err = runCreateUser()
	case "version", "--version", "-v":
		fmt.Println("eterm", version)
		return
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		slog.Error("退出", "err", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Println(`eterm — 主机与凭据数据中枢

用法:
  eterm serve          启动 HTTP 服务（默认 127.0.0.1:8080，公网暴露交给反代）
  eterm migrate        执行数据库迁移
  eterm create-user    交互式创建管理员与其个人 vault
  eterm version        显示版本

必填环境变量:
  ETERM_DB_DSN         MySQL DSN，如 root@tcp(127.0.0.1:3306)/eterm?parseTime=true
  ETERM_MASTER_KEY     base64 的 64 字节主密钥（serve 必填）
  ETERM_PEPPER         口令 pepper（serve/create-user 必填）
可选:
  ETERM_LISTEN         监听地址，默认 127.0.0.1:8080
  ETERM_IP_WHITELIST   逗号分隔 CIDR 白名单，空=不启用
  ETERM_TLS_TRUSTED_PROXY  受信反代地址，默认 127.0.0.1`)
}

// ---- serve ----

func runServe() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	st, err := store.Open(cfg.DBDSN, cfg.MasterKey)
	if err != nil {
		return err
	}
	defer st.Close()

	if err := migrations.Up(st.DB); err != nil {
		return fmt.Errorf("迁移失败: %w", err)
	}
	slog.Info("数据库就绪")

	h := hub.New()
	engine := &syncengine.Engine{Store: st, Hub: h}
	authSvc := &auth.Service{Store: st, Pepper: cfg.Pepper}
	wl, err := api.IPWhitelist(cfg.IPWhitelist)
	if err != nil {
		return fmt.Errorf("ETERM_IP_WHITELIST 非法: %w", err)
	}

	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           api.NewRouter(api.Deps{Store: st, Auth: authSvc, Engine: engine, Hub: h, Version: version}, wl, cfg.TrustedProxy),
		ReadHeaderTimeout: 10 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		slog.Info("收到退出信号，优雅关闭…")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	slog.Info("eterm serve 启动", "listen", cfg.Listen, "version", version,
		"ip_whitelist", len(cfg.IPWhitelist))
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

// ---- migrate ----

func runMigrate() error {
	st, err := openPlain()
	if err != nil {
		return err
	}
	defer st.Close()
	if err := migrations.Up(st.DB); err != nil {
		return err
	}
	slog.Info("迁移完成")
	return nil
}

// ---- create-user ----

func runCreateUser() error {
	pepper := strings.TrimSpace(os.Getenv("ETERM_PEPPER"))
	if pepper == "" {
		return errors.New("缺少必填环境变量 ETERM_PEPPER")
	}
	st, err := openPlain()
	if err != nil {
		return err
	}
	defer st.Close()

	username, err := promptLine("用户名: ")
	if err != nil {
		return err
	}
	username = strings.TrimSpace(username)
	if username == "" {
		return errors.New("用户名不能为空")
	}
	if existing, err := st.GetUserByUsername(context.Background(), username); err != nil {
		return err
	} else if existing != nil {
		return fmt.Errorf("用户 %q 已存在", username)
	}

	pw1, err := promptPassword("设置口令（至少 8 位）: ")
	if err != nil {
		return err
	}
	pw2, err := promptPassword("确认口令: ")
	if err != nil {
		return err
	}
	if pw1 != pw2 {
		return errors.New("两次口令不一致")
	}
	if len(pw1) < 8 {
		return errors.New("口令过短（至少 8 位）")
	}

	hash, err := auth.HashPassword(pw1, pepper)
	if err != nil {
		return err
	}
	ctx := context.Background()
	userID, err := st.CreateUser(ctx, username, hash)
	if err != nil {
		return err
	}
	vaultID, err := st.CreatePersonalVault(ctx, userID, username+"-personal")
	if err != nil {
		return err
	}
	fmt.Printf("✔ 用户已创建: %s (%s)\n✔ 个人 vault: %s\n", username, userID, vaultID)
	return nil
}

// openPlain 打开无需主密钥的连接（迁移、建号场景）。
func openPlain() (*store.Store, error) {
	dsn := strings.TrimSpace(os.Getenv("ETERM_DB_DSN"))
	if dsn == "" {
		return nil, errors.New("缺少必填环境变量 ETERM_DB_DSN")
	}
	return store.Open(config.NormalizeDSN(dsn), nil)
}

func promptLine(prompt string) (string, error) {
	fmt.Print(prompt)
	var line string
	if _, err := fmt.Scanln(&line); err != nil && err.Error() != "unexpected newline" {
		// 允许空行
		return line, nil
	}
	return line, nil
}

func promptPassword(prompt string) (string, error) {
	fmt.Print(prompt)
	b, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Println()
	if err != nil {
		return "", err
	}
	return string(b), nil
}

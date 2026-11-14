// eterm 中枢服务端。子命令：serve / migrate / create-user。
package main

import (
	"bufio"
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

	// TLS：设置 ETERM_TLS_CERT/ETERM_TLS_KEY 即启用（自签场景见 deploy/；
	// 有域名时建议改走 Caddy/Let's Encrypt 反代）。
	tlsCert := strings.TrimSpace(os.Getenv("ETERM_TLS_CERT"))
	tlsKey := os.Getenv("ETERM_TLS_KEY")
	scheme := "http"
	if tlsCert != "" && tlsKey != "" {
		scheme = "https"
	}

	slog.Info("eterm serve 启动", "listen", cfg.Listen, "version", version,
		"scheme", scheme, "ip_whitelist", len(cfg.IPWhitelist))

	var serveErr error
	if scheme == "https" {
		serveErr = srv.ListenAndServeTLS(tlsCert, tlsKey)
	} else {
		serveErr = srv.ListenAndServe()
	}
	if serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
		return serveErr
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
	// 非交互模式：eterm create-user --stdin-password < pwfile（供自动化部署）
	interactive := true
	args := os.Args[2:]
	for _, a := range args {
		if a == "--stdin-password" {
			interactive = false
		}
	}

	pepper := strings.TrimSpace(os.Getenv("ETERM_PEPPER"))
	if pepper == "" {
		return errors.New("缺少必填环境变量 ETERM_PEPPER")
	}
	st, err := openPlain()
	if err != nil {
		return err
	}
	defer st.Close()

	var username, pw1 string
	if interactive {
		username, err = promptLine("用户名: ")
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
		pw1, err = promptPassword("设置口令（至少 8 位）: ")
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
	} else {
		var nameB, pwB []byte
		nameB, pwB, err = readNameAndPasswordFromStdin()
		if err != nil {
			return err
		}
		username = strings.TrimSpace(string(nameB))
		pw1 = strings.TrimSpace(string(pwB))
		if username == "" {
			return errors.New("stdin 第一行必须是用户名")
		}
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

// readNameAndPasswordFromStdin 非交互建号：stdin 两行——第一行用户名、第二行口令。
func readNameAndPasswordFromStdin() ([]byte, []byte, error) {
	reader := bufio.NewReader(os.Stdin)
	name, err := reader.ReadString('\n')
	if err != nil && name == "" {
		return nil, nil, errors.New("stdin 为空")
	}
	pw, err := reader.ReadString('\n')
	if err != nil && pw == "" {
		return nil, nil, errors.New("stdin 缺少口令行")
	}
	return []byte(name), []byte(pw), nil
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

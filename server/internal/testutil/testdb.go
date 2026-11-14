// Package testutil 集成测试辅助：每个用例派生独立数据库，消除并行包测试的清库竞争。
package testutil

import (
	"database/sql"
	"fmt"
	"math/rand"
	"os"
	"testing"

	"github.com/go-sql-driver/mysql"
)

// NewDB 基于 ETERM_TEST_DSN 创建随机命名的测试库并执行 migrate；测试结束删除。
// 未设置 ETERM_TEST_DSN 时 skip。
func NewDB(t *testing.T, migrate func(*sql.DB) error) *sql.DB {
	t.Helper()
	base := os.Getenv("ETERM_TEST_DSN")
	if base == "" {
		t.Skip("ETERM_TEST_DSN 未设置，跳过集成测试")
	}
	cfg, err := mysql.ParseDSN(base)
	if err != nil {
		t.Fatalf("ETERM_TEST_DSN 非法: %v", err)
	}
	dbName := fmt.Sprintf("eterm_test_%016x", rand.Uint64())

	adminCfg := *cfg
	adminCfg.DBName = ""
	admin, err := sql.Open("mysql", adminCfg.FormatDSN())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := admin.ExecContext(t.Context(),
		fmt.Sprintf("CREATE DATABASE `%s` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci", dbName)); err != nil {
		t.Fatalf("创建测试库失败: %v", err)
	}

	cfg.DBName = dbName
	db, err := sql.Open("mysql", cfg.FormatDSN())
	if err != nil {
		t.Fatal(err)
	}
	if err := migrate(db); err != nil {
		t.Fatalf("迁移失败: %v", err)
	}
	t.Cleanup(func() {
		_ = db.Close()
		_, _ = admin.Exec(fmt.Sprintf("DROP DATABASE IF EXISTS `%s`", dbName))
		_ = admin.Close()
	})
	return db
}

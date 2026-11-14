// Package migrations 内嵌迁移 SQL，供 serve 启动与 migrate 子命令执行。
package migrations

import (
	"database/sql"
	"embed"

	"github.com/pressly/goose/v3"
)

//go:embed *.sql
var fs embed.FS

// Up 执行全部未应用迁移。MySQL DSN 需带 multiStatements=true（见 config.NormalizeDSN）。
func Up(db *sql.DB) error {
	goose.SetBaseFS(fs)
	if err := goose.SetDialect("mysql"); err != nil {
		return err
	}
	return goose.Up(db, ".")
}

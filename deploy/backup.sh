#!/usr/bin/env bash
# eterm 数据库每日备份（mysqldump 单事务快照）。crontab 示例：
#   30 3 * * * /opt/eterm/deploy/backup.sh >> /var/log/eterm-backup.log 2>&1
# 注意：主密钥不在备份内，需在密码管理器单独保管；两者分离保管（技术方案 §3.6）。
set -euo pipefail

DB_NAME="eterm"
MYSQL_USER="eterm"
MYSQL_PASS="${MYSQL_PASS:?需设置 MYSQL_PASS 环境变量}"
BACKUP_DIR="/var/backups/eterm"
KEEP_DAYS=14

mkdir -p "$BACKUP_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$BACKUP_DIR/$DB_NAME-$STAMP.sql.gz"

mysqldump --single-transaction --set-gtid-purged=OFF \
  -u"$MYSQL_USER" -p"$MYSQL_PASS" "$DB_NAME" | gzip -9 > "$OUT"
chmod 600 "$OUT"

find "$BACKUP_DIR" -name "$DB_NAME-*.sql.gz" -mtime +"$KEEP_DAYS" -delete
echo "backup ok: $OUT"

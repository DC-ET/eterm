#!/usr/bin/env bash
# eterm 服务端发布：备份 → rsync 源码 → 改属主 → 重启 → 探针验证。
# 约定见 docs/eterm-发布流程.md「服务端部署」。发布前先在 server/ 下跑
# typecheck 与（配本地 MySQL 的）npm test。
set -euo pipefail
cd "$(dirname "$0")/.." # server/

SERVER=root@YOUR_SERVER_IP
KEY="${ETERM_SSH_KEY:-$HOME/Downloads/your-server.pem}"
SSH="ssh -i $KEY -o BatchMode=yes -o ConnectTimeout=10"
# -e 的值含空格，必须整体作为一个参数：用数组，别用字符串（否则 rsync 会把
# 展开后的 -i/-o 当成自己的选项）
RSYNC=(rsync -rlptD --delete -e "ssh -i $KEY -o BatchMode=yes -o ConnectTimeout=10")
DATE=$(date +%Y%m%d)
BACKUP="/opt/eterm-src-backup-${DATE}.tgz"

echo "== 1/5 备份生产源码 → ${BACKUP} =="
$SSH "$SERVER" "tar czf $BACKUP -C /opt/eterm src migrations"

echo "== 2/5 rsync src + migrations =="
"${RSYNC[@]}" src/        "$SERVER:/opt/eterm/src/"
"${RSYNC[@]}" migrations/ "$SERVER:/opt/eterm/migrations/"

echo "== 3/5 属主 eterm:eterm + 重启 =="
$SSH "$SERVER" 'chown -R eterm:eterm /opt/eterm/src /opt/eterm/migrations \
  && find /opt/eterm/src -type f -exec chmod 644 {} \; \
  && chmod 644 /opt/eterm/migrations/*.sql \
  && systemctl restart eterm && sleep 4 && systemctl is-active eterm'

echo "== 4/5 healthz =="
curl -s -m 10 https://hub.example.com/healthz && echo

echo "== 5/5 改密码路由探针（期望 401；404 = 旧代码仍在跑）=="
CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST \
  https://hub.example.com/api/v1/auth/password \
  -H 'Content-Type: application/json' \
  -d '{"old_password":"x","new_password":"y"}')
echo "HTTP ${CODE}"
if [[ "$CODE" != "401" ]]; then
  echo "❌ 探针失败：预期 401，实际 ${CODE}。回滚：ssh ${SERVER} 'cd /opt/eterm && tar xzf ${BACKUP} && chown -R eterm:eterm src migrations && systemctl restart eterm'"
  exit 1
fi

echo "✅ 发布完成。启动日志：ssh ${SERVER} 'journalctl -u eterm --since \"3 min ago\"'"

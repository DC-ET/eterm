.PHONY: typecheck test run migrate create-user

# ---- server（Node 22 + TypeScript + Fastify；见 server/package.json）----
# 集成/本地开发需要：ETERM_DB_DSN、ETERM_PEPPER、ETERM_MASTER_KEY（样例见 deploy/eterm.env.example）

typecheck: ## 服务端类型检查
	cd server && npm run typecheck

test: ## 跑服务端测试（vitest）
	cd server && npm test

run: ## 本地启动（开发；临时生成密钥）
	cd server && ETERM_MASTER_KEY=$$(openssl rand -base64 64 | tr -d '\n') \
		ETERM_PEPPER=$$(openssl rand -hex 32) \
		ETERM_DB_DSN='root@tcp(127.0.0.1:3306)/eterm?parseTime=true&multiStatements=true&loc=UTC' \
		npm run dev

migrate: ## 对开发库执行迁移
	cd server && ETERM_DB_DSN='root@tcp(127.0.0.1:3306)/eterm?parseTime=true&multiStatements=true&loc=UTC' \
		npm run migrate

create-user: ## 创建用户（交互式）
	cd server && ETERM_DB_DSN='root@tcp(127.0.0.1:3306)/eterm?parseTime=true&multiStatements=true&loc=UTC' \
		npm run create-user

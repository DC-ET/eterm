.PHONY: build test vet tidy run migrate clean

# ---- server ----
SERVER_BIN := server/bin/eterm

build: ## 构建服务端二进制
	cd server && go build -o bin/eterm ./cmd/eterm

vet:
	cd server && go vet ./...

test: ## 跑服务端测试（集成测试需本地 MySQL）
	cd server && ETERM_TEST_DSN='root@tcp(127.0.0.1:3306)/eterm_test?parseTime=true&multiStatements=true&loc=UTC' go test ./... -count=1

tidy:
	cd server && go mod tidy

run: ## 本地启动（开发）
	cd server && ETERM_MASTER_KEY=$$(openssl rand -base64 64 | tr -d '\n') \
		ETERM_PEPPER=$$(openssl rand -hex 32) \
		ETERM_DB_DSN='root@tcp(127.0.0.1:3306)/eterm?parseTime=true&multiStatements=true&loc=UTC' \
		go run ./cmd/eterm serve

migrate: ## 对开发库执行迁移
	cd server && ETERM_DB_DSN='root@tcp(127.0.0.1:3306)/eterm?parseTime=true&multiStatements=true&loc=UTC' \
		go run ./cmd/eterm migrate

clean:
	rm -rf server/bin

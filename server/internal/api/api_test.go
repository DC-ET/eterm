package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"

	"eterm/server/internal/auth"
	"eterm/server/internal/hub"
	"eterm/server/internal/store"
	"eterm/server/internal/syncengine"
	"eterm/server/internal/testutil"
	"eterm/server/migrations"
)

var apiTestKey = []byte("0123456789abcdef0123456789abcdef")

type apiFixture struct {
	ts  *httptest.Server
	st  *store.Store
	hub *hub.Hub
}

func newAPIFixture(t *testing.T) *apiFixture {
	t.Helper()
	db := testutil.NewDB(t, migrations.Up)
	st := &store.Store{DB: db, MasterKey: apiTestKey}
	ctx := context.Background()
	hash, err := auth.HashPassword("alice-password", "test-pepper")
	if err != nil {
		t.Fatal(err)
	}
	userID, err := st.CreateUser(ctx, "alice", hash)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.CreatePersonalVault(ctx, userID, "alice-personal"); err != nil {
		t.Fatal(err)
	}
	h := hub.New()
	d := Deps{
		Store:   st,
		Auth:    &auth.Service{Store: st, Pepper: "test-pepper"},
		Engine:  &syncengine.Engine{Store: st, Hub: h},
		Hub:     h,
		Version: "test",
	}
	wl, err := IPWhitelist(nil)
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(NewRouter(d, wl, "127.0.0.1"))
	t.Cleanup(ts.Close)
	return &apiFixture{ts: ts, st: st, hub: h}
}

func (f *apiFixture) login(t *testing.T) string {
	t.Helper()
	body, _ := json.Marshal(map[string]any{
		"username": "alice", "password": "alice-password",
		"device_name": "test-mac", "platform": "macos",
	})
	resp, err := http.Post(f.ts.URL+"/api/v1/auth/login", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("login 应 200，实际 %d", resp.StatusCode)
	}
	var out struct {
		Token string `json:"token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	if out.Token == "" {
		t.Fatal("token 不应为空")
	}
	return out.Token
}

func (f *apiFixture) do(t *testing.T, method, path, token string, body any) (int, map[string]any) {
	t.Helper()
	var rd *bytes.Reader = bytes.NewReader(nil)
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, _ := http.NewRequest(method, f.ts.URL+path, rd)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func TestHTTPAuthAndSyncFlow(t *testing.T) {
	f := newAPIFixture(t)

	// 未认证 401
	if code, _ := f.do(t, "GET", "/api/v1/me", "", nil); code != http.StatusUnauthorized {
		t.Fatalf("未认证应 401: %d", code)
	}

	token := f.login(t)

	// /me
	code, me := f.do(t, "GET", "/api/v1/me", token, nil)
	if code != 200 || me["vault_id"] == nil {
		t.Fatalf("/me 异常: %d %v", code, me)
	}

	// push 一台主机
	hostID := uuid.NewString()
	code, pr := f.do(t, "POST", "/api/v1/sync/push", token, map[string]any{
		"changes": []map[string]any{{
			"entity_type": "host", "entity_id": hostID, "base_rev": 0, "op": "upsert",
			"data": map[string]any{"label": "web1", "hostname": "web1.lan", "tags": []string{"web"}},
		}},
	})
	if code != 200 {
		t.Fatalf("push 应 200: %d %v", code, pr)
	}
	results := pr["results"].([]any)
	if results[0].(map[string]any)["status"] != "ok" {
		t.Fatalf("push 结果应 ok: %v", results)
	}

	// pull 能看到
	code, pl := f.do(t, "GET", "/api/v1/sync/pull?cursor=0", token, nil)
	if code != 200 {
		t.Fatalf("pull 应 200: %d", code)
	}
	changes := pl["changes"].([]any)
	if len(changes) != 1 {
		t.Fatalf("应拉到 1 条: %v", changes)
	}

	// 重复 base_rev=0 → conflict
	code, pr2 := f.do(t, "POST", "/api/v1/sync/push", token, map[string]any{
		"changes": []map[string]any{{
			"entity_type": "host", "entity_id": hostID, "base_rev": 0, "op": "upsert",
			"data": map[string]any{"label": "web1", "hostname": "web1.lan", "tags": []string{"web"}},
		}},
	})
	if code != 200 || pr2["results"].([]any)[0].(map[string]any)["status"] != "conflict" {
		t.Fatalf("重复 push 应 conflict: %d %v", code, pr2)
	}

	// 设备列表
	code, dl := f.do(t, "GET", "/api/v1/devices", token, nil)
	if code != 200 || len(dl["devices"].([]any)) != 1 {
		t.Fatalf("设备列表异常: %d %v", code, dl)
	}

	// logout 后 token 失效
	if code, _ := f.do(t, "POST", "/api/v1/auth/logout", token, nil); code != 200 {
		t.Fatal("logout 应 200")
	}
	if code, _ := f.do(t, "GET", "/api/v1/me", token, nil); code != http.StatusUnauthorized {
		t.Fatalf("logout 后应 401: %d", code)
	}
	// 同名设备重登录复用（仍是 1 台设备）
	token2 := f.login(t)
	_, dl2 := f.do(t, "GET", "/api/v1/devices", token2, nil)
	if n := len(dl2["devices"].([]any)); n != 1 {
		t.Fatalf("设备应复用仍为 1 台，实际 %d", n)
	}
}

func TestWSBroadcast(t *testing.T) {
	f := newAPIFixture(t)
	token := f.login(t)

	wsURL := "ws" + f.ts.URL[len("http"):] + "/api/v1/ws?token=" + token
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("WS 连接失败: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "bye")

	readCtx, rcancel := context.WithTimeout(ctx, 5*time.Second)
	defer rcancel()

	// 确认订阅完成后再 push（给 hub 一点时间注册）
	time.Sleep(100 * time.Millisecond)

	hostID := uuid.NewString()
	f.do(t, "POST", "/api/v1/sync/push", token, map[string]any{
		"changes": []map[string]any{{
			"entity_type": "host", "entity_id": hostID, "base_rev": 0, "op": "upsert",
			"data": map[string]any{"label": "db1", "hostname": "db1.lan", "tags": []string{}},
		}},
	})

	_, frame, err := conn.Read(readCtx)
	if err != nil {
		t.Fatalf("应收到广播帧: %v", err)
	}
	var msg map[string]any
	if err := json.Unmarshal(frame, &msg); err != nil {
		t.Fatalf("帧应为 JSON: %v", err)
	}
	if msg["type"] != "change" || msg["rev"] == nil {
		t.Fatalf("帧内容异常: %v", msg)
	}
}

func TestRateLimitLogin(t *testing.T) {
	f := newAPIFixture(t)
	body, _ := json.Marshal(map[string]any{
		"username": "nobody", "password": "x", "device_name": "d", "platform": "macos",
	})
	last := 0
	for i := 0; i < 12; i++ {
		resp, err := http.Post(f.ts.URL+"/api/v1/auth/login", "application/json", bytes.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		last = resp.StatusCode
	}
	if last != http.StatusTooManyRequests {
		t.Fatalf("连续登录后应触发限流 429，实际 %d", last)
	}
}

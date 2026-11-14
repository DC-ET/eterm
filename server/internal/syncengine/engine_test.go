package syncengine

import (
	"context"
	"fmt"
	"testing"

	"github.com/google/uuid"

	"eterm/server/internal/hub"
	"eterm/server/internal/store"
	"eterm/server/internal/testutil"
	"eterm/server/migrations"
)

// 集成测试：需要本地 MySQL。ETERM_TEST_DSN 未设置时跳过（Makefile test 目标已注入）。

var testKey = []byte("0123456789abcdef0123456789abcdef") // 32B 测试主密钥

type fixture struct {
	st      *store.Store
	eng     *Engine
	vaultID uuid.UUID
}

var dropTables = []string{
	"audit_events", "changes", "snippets", "snippet_packages", "port_rules",
	"known_hosts", "ssh_keys", "identities", "host_protocols", "hosts",
	"host_groups", "vaults", "devices", "users", "goose_db_version",
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	db := testutil.NewDB(t, migrations.Up)
	st := &store.Store{DB: db, MasterKey: testKey}
	ctx := context.Background()
	userID, err := st.CreateUser(ctx, "tester", "fake-hash")
	if err != nil {
		t.Fatal(err)
	}
	vaultID, err := st.CreatePersonalVault(ctx, userID, "test-vault")
	if err != nil {
		t.Fatal(err)
	}
	return &fixture{st: st, eng: &Engine{Store: st, Hub: hub.New()}, vaultID: vaultID}
}

func (f *fixture) push(t *testing.T, device uuid.UUID, etype, id string, baseRev uint64, op string, data map[string]any) PushResult {
	t.Helper()
	return f.eng.Push(context.Background(), f.vaultID[:], device[:], []store.PushItem{{
		EntityType: etype, EntityID: id, BaseRev: baseRev, Op: op, Data: data,
	}})[0]
}

func hostData(label string) map[string]any {
	return map[string]any{
		"label": label, "hostname": "10.0.0." + label,
		"tags": []any{"prod", "db"}, "updated_at": "2026-01-01T00:00:00Z",
	}
}

func TestPushPullRoundTripWithEncryption(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	dev := uuid.New()

	// 建主机
	id := uuid.NewString()
	r := f.push(t, dev, "host", id, 0, "upsert", hostData("1"))
	if r.Status != "ok" || r.Rev == 0 {
		t.Fatalf("push host 应 ok: %+v", r)
	}

	// 建 identity（含加密字段）
	iid := uuid.NewString()
	r = f.push(t, dev, "identity", iid, 0, "upsert", map[string]any{
		"label": "root", "username": "root", "password_enc": "s3cret-中文🔐",
	})
	if r.Status != "ok" {
		t.Fatalf("push identity 应 ok: %+v", r)
	}

	// 全量 pull
	resp, err := f.eng.Pull(ctx, f.vaultID[:], 0, 100)
	if err != nil {
		t.Fatal(err)
	}
	if len(resp.Changes) != 2 {
		t.Fatalf("应拉到 2 条变更，实际 %d", len(resp.Changes))
	}
	var gotPwd string
	for _, c := range resp.Changes {
		if c.EntityType == "identity" {
			gotPwd, _ = c.Data["password_enc"].(string)
		}
	}
	if gotPwd != "s3cret-中文🔐" {
		t.Fatalf("加密字段应解密往返一致，实际 %q", gotPwd)
	}

	// cursor 前进后无新变更
	resp, err = f.eng.Pull(ctx, f.vaultID[:], resp.Cursor, 100)
	if err != nil || len(resp.Changes) != 0 {
		t.Fatalf("追平后应无变更: n=%d err=%v cursor=%d", len(resp.Changes), err, resp.Cursor)
	}
}

func TestConflictAndResolve(t *testing.T) {
	f := newFixture(t)
	dev := uuid.New()
	id := uuid.NewString()

	r1 := f.push(t, dev, "host", id, 0, "upsert", hostData("1"))
	r2 := f.push(t, dev, "host", id, 0, "upsert", hostData("2"))
	if r1.Status != "ok" {
		t.Fatalf("首次 push 应 ok: %+v", r1)
	}
	if r2.Status != "conflict" || r2.Rev != r1.Rev || r2.ServerData == nil {
		t.Fatalf("base_rev=0 重复 push 应 conflict 并带服务端数据: %+v", r2)
	}
	if r2.ServerData["hostname"] != "10.0.0.1" {
		t.Fatalf("server_data 应为服务端当前行: %+v", r2.ServerData)
	}

	// 带正确 base_rev 重推 → ok
	r3 := f.push(t, dev, "host", id, r2.Rev, "upsert", hostData("2"))
	if r3.Status != "ok" || r3.Rev <= r2.Rev {
		t.Fatalf("base_rev 匹配后应 ok: %+v", r3)
	}
}

func TestTombstoneAndResurrect(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	dev := uuid.New()
	id := uuid.NewString()

	r1 := f.push(t, dev, "host", id, 0, "upsert", hostData("9"))
	r2 := f.push(t, dev, "host", id, r1.Rev, "delete", nil)
	if r2.Status != "ok" {
		t.Fatalf("delete 应 ok: %+v", r2)
	}
	resp, _ := f.eng.Pull(ctx, f.vaultID[:], 0, 100)
	if len(resp.Changes) != 2 || resp.Changes[1].Op != "delete" {
		t.Fatalf("应拉到 tombstone: %+v", resp.Changes)
	}
	if resp.Changes[1].Data != nil {
		t.Fatalf("tombstone 不应携带 data")
	}

	// 重复 delete 幂等
	r3 := f.push(t, dev, "host", id, r2.Rev, "delete", nil)
	if r3.Status != "ok" || r3.Rev != r2.Rev {
		t.Fatalf("重复 delete 应幂等: %+v", r3)
	}

	// 复活：base_rev 匹配
	r4 := f.push(t, dev, "host", id, r2.Rev, "upsert", hostData("9"))
	if r4.Status != "ok" {
		t.Fatalf("复活应 ok: %+v", r4)
	}
	resp, _ = f.eng.Pull(ctx, f.vaultID[:], r2.Rev, 100)
	if len(resp.Changes) != 1 || resp.Changes[0].Op != "upsert" {
		t.Fatalf("复活应作为 upsert 传播: %+v", resp.Changes)
	}
}

func TestTwoClientConvergence(t *testing.T) {
	f := newFixture(t)
	ctx := context.Background()
	devA, devB := uuid.New(), uuid.New()
	cursorA, cursorB := uint64(0), uint64(0)

	// A 建 3 台主机
	ids := []string{uuid.NewString(), uuid.NewString(), uuid.NewString()}
	for i, id := range ids {
		if r := f.push(t, devA, "host", id, 0, "upsert", hostData(fmt.Sprint(i+1))); r.Status != "ok" {
			t.Fatalf("A push: %+v", r)
		}
	}
	// B 追平
	respB, _ := f.eng.Pull(ctx, f.vaultID[:], cursorB, 200)
	cursorB = respB.Cursor
	if len(respB.Changes) != 3 {
		t.Fatalf("B 应看到 3 条: %d", len(respB.Changes))
	}
	// B 改其中一台
	if r := f.push(t, devB, "host", ids[0], revOf(t, respB, ids[0]), "upsert", hostData("100")); r.Status != "ok" {
		t.Fatalf("B push: %+v", r)
	}
	// A 增量拉到 B 的修改
	respA, _ := f.eng.Pull(ctx, f.vaultID[:], cursorA, 200)
	if len(respA.Changes) != 4 { // 3 条 A 自己的 + 1 条 B 的
		t.Fatalf("A 应拉到 4 条: %d", len(respA.Changes))
	}
	var sawB bool
	for _, c := range respA.Changes {
		if c.EntityID == ids[0] && c.Data["hostname"] == "10.0.0.100" {
			sawB = true
		}
	}
	if !sawB {
		t.Fatal("A 应看到 B 的修改内容")
	}

	// A 删除 → B 收 tombstone
	if r := f.push(t, devA, "host", ids[1], revOf(t, respA, ids[1]), "delete", nil); r.Status != "ok" {
		t.Fatalf("A delete: %+v", r)
	}
	respB2, _ := f.eng.Pull(ctx, f.vaultID[:], cursorB, 200)
	if len(respB2.Changes) != 2 || respB2.Changes[0].Op != "upsert" || respB2.Changes[1].Op != "delete" {
		t.Fatalf("B 增量应为 upsert+delete: %+v", respB2.Changes)
	}
}

func TestKeyContentImmutable(t *testing.T) {
	f := newFixture(t)
	dev := uuid.New()
	id := uuid.NewString()
	kd := func(priv string) map[string]any {
		return map[string]any{
			"label": "k1", "key_type": "ed25519", "private_enc": priv,
			"public_key": "ssh-ed25519 AAAA", "fingerprint": "SHA256:abc",
			"origin": "generated", "key_version": int64(1),
		}
	}
	r1 := f.push(t, dev, "ssh_key", id, 0, "upsert", kd("PRIV-1"))
	if r1.Status != "ok" {
		t.Fatalf("建密钥应 ok: %+v", r1)
	}
	// 相同内容重推（map 全量式更新常态）→ 允许
	r2 := f.push(t, dev, "ssh_key", id, r1.Rev, "upsert", kd("PRIV-1"))
	if r2.Status != "ok" {
		t.Fatalf("相同内容更新应 ok: %+v", r2)
	}
	// 内容变化 → 拒绝
	r3 := f.push(t, dev, "ssh_key", id, r2.Rev, "upsert", kd("PRIV-2"))
	if r3.Status != "rejected" {
		t.Fatalf("密钥内容变化应拒绝: %+v", r3)
	}
}

func TestValidationRejects(t *testing.T) {
	f := newFixture(t)
	dev := uuid.New()
	if r := f.push(t, dev, "host", uuid.NewString(), 0, "upsert", map[string]any{"label": "x"}); r.Status != "rejected" {
		t.Fatalf("缺 hostname 应拒绝: %+v", r)
	}
	if r := f.push(t, dev, "port_rule", uuid.NewString(), 0, "upsert", map[string]any{
		"host_id": uuid.NewString(), "label": "p", "kind": "bogus", "bind_addr": "127.0.0.1", "enabled": true,
	}); r.Status != "rejected" {
		t.Fatalf("非法 kind 应拒绝: %+v", r)
	}
	if r := f.push(t, dev, "port_rule", uuid.NewString(), 0, "upsert", map[string]any{
		"host_id": uuid.NewString(), "label": "p", "kind": "local", "bind_addr": "127.0.0.1",
		"local_port": int64(70000), "enabled": true,
	}); r.Status != "rejected" {
		t.Fatalf("端口越界应拒绝: %+v", r)
	}
	if r := f.push(t, dev, "no_such_type", uuid.NewString(), 0, "upsert", nil); r.Status != "rejected" {
		t.Fatalf("未知类型应拒绝: %+v", r)
	}
}

func revOf(t *testing.T, resp *PullResponse, entityID string) uint64 {
	t.Helper()
	for _, c := range resp.Changes {
		if c.EntityID == entityID {
			return c.Rev
		}
	}
	t.Fatalf("变更中未找到实体 %s", entityID)
	return 0
}

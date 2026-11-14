package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

// querier 让同一套代码工作在 *sql.DB 与 *sql.Tx 上。
type querier interface {
	QueryContext(ctx context.Context, q string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, q string, args ...any) *sql.Row
	ExecContext(ctx context.Context, q string, args ...any) (sql.Result, error)
}

// ChangeRow pull 结果行。
type ChangeRow struct {
	ID         uint64
	EntityType string
	EntityID   string
	TS         time.Time
	Op         string // upsert | delete
	Data       map[string]any
}

// PushItem push 单项输入。
type PushItem struct {
	EntityType string
	EntityID   string
	BaseRev    uint64
	Op         string // upsert | delete
	Data       map[string]any
}

// PushResult push 单项结果。
type PushResult struct {
	Status     string         // ok | conflict | rejected
	Rev        uint64
	ServerData map[string]any
	Reason     string
}

// FetchChanges 从 cursor 起按序拉取 vault 内变更；返回变更、新 cursor、是否还有更多。
// 实体行整体缺失（理论上不应发生）时跳过该条，但 cursor 照常前进。
func (s *Store) FetchChanges(ctx context.Context, vaultID []byte, cursor uint64, limit int) ([]ChangeRow, uint64, bool, error) {
	if limit <= 0 || limit > 1000 {
		limit = 200
	}
	rows, err := s.DB.QueryContext(ctx,
		`SELECT id, entity_type, entity_id, ts FROM changes WHERE id > ? AND vault_id = ? ORDER BY id ASC LIMIT ?`,
		cursor, vaultID, limit+1)
	if err != nil {
		return nil, cursor, false, fmt.Errorf("查询 changes 失败: %w", err)
	}
	defer rows.Close()

	type entry struct {
		id       uint64
		etype    string
		entityID []byte
		ts       time.Time
	}
	var entries []entry
	for rows.Next() {
		var e entry
		var et, eid []byte
		if err := rows.Scan(&e.id, &et, &eid, &e.ts); err != nil {
			return nil, cursor, false, err
		}
		e.etype, e.entityID = string(et), append([]byte(nil), eid...)
		entries = append(entries, e)
	}
	if err := rows.Err(); err != nil {
		return nil, cursor, false, err
	}
	hasMore := len(entries) > limit
	if hasMore {
		entries = entries[:limit]
	}
	if len(entries) == 0 {
		return nil, cursor, false, nil
	}

	// 按类型批量取当前实体行
	type idx struct{ i int; ent *Entity }
	loaded := make([]*ChangeRow, len(entries))
	pending := map[string][]idx{}
	for i, e := range entries {
		ent, ok := GetEntity(e.etype)
		if !ok {
			return nil, cursor, false, fmt.Errorf("changes 中存在未知实体类型 %q", e.etype)
		}
		pending[e.etype] = append(pending[e.etype], idx{i, ent})
	}
	for et, list := range pending {
		ent := list[0].ent
		ids := make([]string, 0, len(list))
		byteIDs := make([][]byte, 0, len(list))
		for _, it := range list {
			ids = append(ids, uuidStr(entries[it.i].entityID))
			byteIDs = append(byteIDs, entries[it.i].entityID)
		}
		q := fmt.Sprintf("SELECT %s FROM %s WHERE id IN (%s)",
			ent.selectColumns(), ent.Table, strings.TrimSuffix(strings.Repeat("?,", len(byteIDs)), ","))
		args := make([]any, len(byteIDs))
		for i, b := range byteIDs {
			args[i] = b
		}
		rws, err := s.DB.QueryContext(ctx, q, args...)
		if err != nil {
			return nil, cursor, false, fmt.Errorf("加载 %s 实体失败: %w", et, err)
		}
		rowByID := map[string]map[string]any{}
		for rws.Next() {
			m, err := scanEntityRow(s, rws, ent)
			if err != nil {
				rws.Close()
				return nil, cursor, false, err
			}
			rowByID[m["id"].(string)] = m
		}
		rws.Close()
		if err := rws.Err(); err != nil {
			return nil, cursor, false, err
		}
		for _, it := range list {
			e := entries[it.i]
			idStr := uuidStr(e.entityID)
			if m, ok := rowByID[idStr]; ok {
				op := "upsert"
				if m["deleted_at"] != nil {
					op = "delete"
				}
				data := m
				if op == "delete" {
					data = nil
				}
				loaded[it.i] = &ChangeRow{ID: e.id, EntityType: et, EntityID: idStr, TS: e.ts, Op: op, Data: data}
			}
			// 缺行：跳过（loaded 保持 nil）
		}
	}

	out := make([]ChangeRow, 0, len(loaded))
	for _, r := range loaded {
		if r != nil {
			out = append(out, *r)
		}
	}
	newCursor := entries[len(entries)-1].id
	return out, newCursor, hasMore, nil
}

// scanEntityRow 按实体元数据把当前行转为 wire map。
func scanEntityRow(s *Store, rows *sql.Rows, ent *Entity) (map[string]any, error) {
	allCols := strings.Split(ent.selectColumns(), ", ")
	dests := make([]any, len(allCols))
	vals := make([]any, len(allCols))
	for i := range dests {
		dests[i] = new(any)
		vals[i] = dests[i]
	}
	if err := rows.Scan(vals...); err != nil {
		return nil, fmt.Errorf("扫描 %s 行失败: %w", ent.Type, err)
	}
	m := make(map[string]any, len(allCols))
	for i, name := range allCols {
		v := *dests[i].(*any)
		var out any
		var err error
		switch name {
		case "rev":
			out, err = toInt(v)
		case "created_at", "updated_at", "deleted_at":
			if t, ok := v.(time.Time); ok {
				out = t.UTC().Format(time.RFC3339Nano)
			} else if v != nil {
				err = fmt.Errorf("时间列 %s 类型异常: %T", name, v)
			}
		default:
			var kind ColKind
			if name == "id" || name == "vault_id" {
				kind = KUUID
			} else {
				found := false
				for _, c := range ent.Cols {
					if c.Name == name {
						kind, found = c.Kind, true
						break
					}
				}
				if !found {
					err = fmt.Errorf("未知列 %s", name)
					break
				}
			}
			if err == nil {
				out, err = s.decodeCell(kind, v)
			}
		}
		if err != nil {
			return nil, err
		}
		m[name] = out
	}
	return m, nil
}

func toInt(v any) (int64, error) {
	switch t := v.(type) {
	case int64:
		return t, nil
	case []byte:
		var n int64
		_, err := fmt.Sscanf(string(t), "%d", &n)
		return n, err
	case nil:
		return 0, nil
	}
	return 0, fmt.Errorf("整数列类型异常: %T", v)
}

// PushItem 处理单个 push 项（独立事务）。SSH 密钥内容按"不可变版本化"校验。
func (s *Store) PushItem(ctx context.Context, vaultID, deviceID []byte, item PushItem) PushResult {
	ent, ok := GetEntity(item.EntityType)
	if !ok {
		return PushResult{Status: "rejected", Reason: "未知实体类型 " + item.EntityType}
	}
	if item.Op != "upsert" && item.Op != "delete" {
		return PushResult{Status: "rejected", Reason: "op 必须为 upsert|delete"}
	}
	entityID, err := parseUUID(item.EntityID)
	if err != nil {
		return PushResult{Status: "rejected", Reason: err.Error()}
	}
	if item.Op == "upsert" {
		if err := ent.Validate(item.Data); err != nil {
			return PushResult{Status: "rejected", Reason: err.Error()}
		}
	}

	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return PushResult{Status: "rejected", Reason: "开启事务失败: " + err.Error()}
	}
	defer tx.Rollback()

	var curRev int64
	var deletedAt sql.NullTime
	err = tx.QueryRowContext(ctx,
		fmt.Sprintf("SELECT rev, deleted_at FROM %s WHERE id = ? FOR UPDATE", ent.Table),
		entityID).Scan(&curRev, &deletedAt)
	rowExists := !errors.Is(err, sql.ErrNoRows)
	if err != nil && rowExists {
		return pushErr(err)
	}

	switch {
	case !rowExists:
		if item.Op == "delete" {
			return PushResult{Status: "rejected", Reason: "entity_not_found"}
		}
		if item.BaseRev != 0 {
			return PushResult{Status: "rejected", Reason: "entity_not_found（base_rev>0 但实体不存在）"}
		}
		if err := s.insertEntity(ctx, tx, ent, entityID, vaultID, item.Data); err != nil {
			return pushErr(err)
		}
		rev, err := s.allocRev(ctx, tx, ent, entityID, vaultID, deviceID)
		if err != nil {
			return pushErr(err)
		}
		if err := tx.Commit(); err != nil {
			return pushErr(err)
		}
		return PushResult{Status: "ok", Rev: rev}

	case deletedAt.Valid:
		if item.Op == "delete" {
			// 幂等：已是 tombstone
			if err := tx.Commit(); err != nil {
				return pushErr(err)
			}
			return PushResult{Status: "ok", Rev: uint64(curRev)}
		}
		if uint64(curRev) != item.BaseRev {
			return s.conflictResult(ctx, tx, ent, entityID, uint64(curRev))
		}
		// 复活
		if err := s.updateEntity(ctx, tx, ent, entityID, item.Data, true); err != nil {
			return pushErr(err)
		}
		rev, err := s.allocRev(ctx, tx, ent, entityID, vaultID, deviceID)
		if err != nil {
			return pushErr(err)
		}
		if err := tx.Commit(); err != nil {
			return pushErr(err)
		}
		return PushResult{Status: "ok", Rev: rev}

	default: // 存活行
		if item.Op == "delete" {
			if _, err := tx.ExecContext(ctx,
				fmt.Sprintf("UPDATE %s SET deleted_at = ? WHERE id = ?", ent.Table),
				time.Now().UTC(), entityID); err != nil {
				return pushErr(err)
			}
			rev, err := s.allocRev(ctx, tx, ent, entityID, vaultID, deviceID)
			if err != nil {
				return pushErr(err)
			}
			if err := tx.Commit(); err != nil {
				return pushErr(err)
			}
			return PushResult{Status: "ok", Rev: rev}
		}
		if uint64(curRev) != item.BaseRev {
			return s.conflictResult(ctx, tx, ent, entityID, uint64(curRev))
		}
		if err := s.checkKeyImmutability(ctx, tx, ent, entityID, item.Data); err != nil {
			return PushResult{Status: "rejected", Reason: err.Error()}
		}
		if err := s.updateEntity(ctx, tx, ent, entityID, item.Data, false); err != nil {
			return pushErr(err)
		}
		rev, err := s.allocRev(ctx, tx, ent, entityID, vaultID, deviceID)
		if err != nil {
			return pushErr(err)
		}
		if err := tx.Commit(); err != nil {
			return pushErr(err)
		}
		return PushResult{Status: "ok", Rev: rev}
	}
}

// checkKeyImmutability ssh_key 实体：禁止覆盖密钥内容（应新建版本行）。
func (s *Store) checkKeyImmutability(ctx context.Context, tx *sql.Tx, ent *Entity, entityID []byte, data map[string]any) error {
	if ent.Type != "ssh_key" {
		return nil
	}
	encCols := []string{"private_enc", "cert_enc", "passphrase_enc"}
	for _, col := range encCols {
		newV, incoming := data[col]
		if !incoming || newV == nil {
			continue
		}
		var stored []byte
		if err := tx.QueryRowContext(ctx,
			fmt.Sprintf("SELECT %s FROM ssh_keys WHERE id = ?", col), entityID).Scan(&stored); err != nil {
			return err
		}
		newSealed, err := s.encodeCell(KEnc, newV)
		if err != nil {
			return err
		}
		newPlain, err := OpenField(s.MasterKey, newSealed.([]byte))
		if err != nil {
			return err
		}
		oldPlain, err := OpenField(s.MasterKey, stored)
		if err != nil {
			return fmt.Errorf("读取原密钥内容失败: %w", err)
		}
		if !bytesEqual(newPlain, oldPlain) {
			return fmt.Errorf("密钥内容不可变：请创建新版本密钥（新 id）并通过 superseded_by 指向")
		}
	}
	return nil
}

// insertEntity 新建行（rev=0，由 allocRev 回填）。
func (s *Store) insertEntity(ctx context.Context, tx *sql.Tx, ent *Entity, entityID, vaultID []byte, data map[string]any) error {
	now := time.Now().UTC()
	updatedAt := parseUpdatedAt(data, now)

	cols := []string{"id", "vault_id"}
	args := []any{entityID, vaultID}
	for _, c := range ent.Cols {
		v, present := data[c.Name]
		if !present || v == nil {
			if c.NotNull {
				return fmt.Errorf("缺少必填字段 %s", c.Name)
			}
			cols, args = append(cols, c.Name), append(args, nil)
			continue
		}
		enc, err := s.encodeCell(c.Kind, v)
		if err != nil {
			return fmt.Errorf("字段 %s: %w", c.Name, err)
		}
		cols, args = append(cols, c.Name), append(args, enc)
	}
	cols = append(cols, "created_at", "updated_at", "rev")
	args = append(args, now, updatedAt, 0)

	q := fmt.Sprintf("INSERT INTO %s (%s) VALUES (%s)", ent.Table,
		strings.Join(cols, ", "), strings.TrimSuffix(strings.Repeat("?,", len(cols)), ","))
	_, err := tx.ExecContext(ctx, q, args...)
	if err != nil {
		return fmt.Errorf("插入 %s 失败: %w", ent.Type, err)
	}
	return nil
}

// updateEntity 按提交的数据键做部分更新（仅出现过的键）；resurrect 时清除 deleted_at。
func (s *Store) updateEntity(ctx context.Context, tx *sql.Tx, ent *Entity, entityID []byte, data map[string]any, resurrect bool) error {
	now := time.Now().UTC()
	updatedAt := parseUpdatedAt(data, now)

	sets := []string{"updated_at = ?"}
	args := []any{updatedAt}
	for _, c := range ent.Cols {
		v, present := data[c.Name]
		if !present {
			continue
		}
		enc, err := s.encodeCell(c.Kind, v)
		if err != nil {
			return fmt.Errorf("字段 %s: %w", c.Name, err)
		}
		sets, args = append(sets, c.Name+" = ?"), append(args, enc)
	}
	if resurrect {
		sets = append(sets, "deleted_at = NULL")
	}
	args = append(args, entityID)
	q := fmt.Sprintf("UPDATE %s SET %s WHERE id = ?", ent.Table, strings.Join(sets, ", "))
	if _, err := tx.ExecContext(ctx, q, args...); err != nil {
		return fmt.Errorf("更新 %s 失败: %w", ent.Type, err)
	}
	return nil
}

// allocRev 写入 changes 取全局 rev，并回填实体行。
func (s *Store) allocRev(ctx context.Context, tx *sql.Tx, ent *Entity, entityID, vaultID, deviceID []byte) (uint64, error) {
	res, err := tx.ExecContext(ctx,
		`INSERT INTO changes (entity_type, entity_id, vault_id, actor_device, ts) VALUES (?, ?, ?, ?, ?)`,
		ent.Type, entityID, vaultID, deviceID, time.Now().UTC())
	if err != nil {
		return 0, fmt.Errorf("写入 changes 失败: %w", err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		return 0, err
	}
	if _, err := tx.ExecContext(ctx,
		fmt.Sprintf("UPDATE %s SET rev = ? WHERE id = ?", ent.Table), id, entityID); err != nil {
		return 0, fmt.Errorf("回填 rev 失败: %w", err)
	}
	return uint64(id), nil
}

func (s *Store) conflictResult(ctx context.Context, tx *sql.Tx, ent *Entity, entityID []byte, curRev uint64) PushResult {
	// 冲突：附带服务端当前数据供客户端 LWW 合并
	row, err := s.loadEntityRow(ctx, tx, ent, entityID)
	if err != nil {
		return pushErr(err)
	}
	tx.Rollback() //nolint:errcheck // 只读冲突响应
	return PushResult{Status: "conflict", Rev: curRev, ServerData: row}
}

func (s *Store) loadEntityRow(ctx context.Context, q querier, ent *Entity, entityID []byte) (map[string]any, error) {
	rows, err := q.QueryContext(ctx,
		fmt.Sprintf("SELECT %s FROM %s WHERE id = ?", ent.selectColumns(), ent.Table), entityID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	if !rows.Next() {
		return nil, rows.Err()
	}
	return scanEntityRow(s, rows, ent)
}

func pushErr(err error) PushResult {
	return PushResult{Status: "rejected", Reason: err.Error()}
}

func parseUpdatedAt(data map[string]any, def time.Time) time.Time {
	if s, ok := data["updated_at"].(string); ok {
		if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
			return t.UTC()
		}
	}
	return def
}

func bytesEqual(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

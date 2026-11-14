package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

// UserRow 用户行。
type UserRow struct {
	ID          uuid.UUID
	Username    string
	PwdHash     string
	FailedCount int
	LockedUntil sql.NullTime
	CreatedAt   time.Time
}

// DeviceRow 设备行。
type DeviceRow struct {
	ID         uuid.UUID
	UserID     uuid.UUID
	Name       string
	Platform   string
	CreatedAt  time.Time
	LastSeenAt sql.NullTime
	RevokedAt  sql.NullTime
}

// CreateUser 创建用户（口令哈希由 auth 层生成）。
func (s *Store) CreateUser(ctx context.Context, username, pwdHash string) (uuid.UUID, error) {
	id := NewUUID()
	_, err := s.DB.ExecContext(ctx,
		`INSERT INTO users (id, username, pwd_hash, created_at) VALUES (?, ?, ?, ?)`,
		id[:], username, pwdHash, time.Now().UTC())
	if err != nil {
		return uuid.Nil, fmt.Errorf("创建用户失败: %w", err)
	}
	return id, nil
}

func (s *Store) GetUserByUsername(ctx context.Context, username string) (*UserRow, error) {
	var u UserRow
	var id []byte
	err := s.DB.QueryRowContext(ctx,
		`SELECT id, username, pwd_hash, failed_count, locked_until, created_at FROM users WHERE username = ?`,
		username).Scan(&id, &u.Username, &u.PwdHash, &u.FailedCount, &u.LockedUntil, &u.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	copy(u.ID[:], id)
	return &u, nil
}

// RegisterLoginFailure 失败计数 +1；达到阈值则锁定，返回锁定截止时间。
func (s *Store) RegisterLoginFailure(ctx context.Context, userID uuid.UUID, maxFails int, lockFor time.Duration) (locked bool, until time.Time, err error) {
	now := time.Now().UTC()
	res, err := s.DB.ExecContext(ctx,
		`UPDATE users SET failed_count = failed_count + 1 WHERE id = ?`, userID[:])
	if err != nil {
		return false, time.Time{}, err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return false, time.Time{}, nil
	}
	var cnt int
	if err := s.DB.QueryRowContext(ctx,
		`SELECT failed_count FROM users WHERE id = ?`, userID[:]).Scan(&cnt); err != nil {
		return false, time.Time{}, err
	}
	if cnt >= maxFails {
		until = now.Add(lockFor)
		_, err = s.DB.ExecContext(ctx,
			`UPDATE users SET locked_until = ? WHERE id = ?`, until, userID[:])
		return true, until, err
	}
	return false, time.Time{}, nil
}

func (s *Store) ResetLoginFailure(ctx context.Context, userID uuid.UUID) error {
	_, err := s.DB.ExecContext(ctx,
		`UPDATE users SET failed_count = 0, locked_until = NULL WHERE id = ?`, userID[:])
	return err
}

// CreatePersonalVault 为用户建首个个人 Vault。
func (s *Store) CreatePersonalVault(ctx context.Context, ownerID uuid.UUID, name string) (uuid.UUID, error) {
	id := NewUUID()
	now := time.Now().UTC()
	_, err := s.DB.ExecContext(ctx,
		`INSERT INTO vaults (id, name, scope, owner_id, rev, created_at, updated_at) VALUES (?, ?, 'personal', ?, 0, ?, ?)`,
		id[:], name, ownerID[:], now, now)
	if err != nil {
		return uuid.Nil, fmt.Errorf("创建 vault 失败: %w", err)
	}
	return id, nil
}

// FirstVaultOfUser MVP：取用户首个未删除 vault。
func (s *Store) FirstVaultOfUser(ctx context.Context, userID uuid.UUID) (uuid.UUID, error) {
	var id []byte
	err := s.DB.QueryRowContext(ctx,
		`SELECT id FROM vaults WHERE owner_id = ? AND deleted_at IS NULL ORDER BY created_at ASC LIMIT 1`,
		userID[:]).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return uuid.Nil, fmt.Errorf("用户无可用 vault")
	}
	if err != nil {
		return uuid.Nil, err
	}
	var u uuid.UUID
	copy(u[:], id)
	return u, nil
}

// UpsertDevice 设备注册：同 (user, name, platform) 复用已有行（重置 token 与吊销状态）。
func (s *Store) UpsertDevice(ctx context.Context, userID uuid.UUID, name, platform string, tokenHash []byte) (uuid.UUID, error) {
	var existing []byte
	err := s.DB.QueryRowContext(ctx,
		`SELECT id FROM devices WHERE user_id = ? AND name = ? AND platform = ? LIMIT 1`,
		userID[:], name, platform).Scan(&existing)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		id := NewUUID()
		_, err := s.DB.ExecContext(ctx,
			`INSERT INTO devices (id, user_id, name, platform, token_hash, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
			id[:], userID[:], name, platform, tokenHash, time.Now().UTC())
		if err != nil {
			return uuid.Nil, fmt.Errorf("注册设备失败: %w", err)
		}
		return id, nil
	case err != nil:
		return uuid.Nil, err
	default:
		_, err := s.DB.ExecContext(ctx,
			`UPDATE devices SET token_hash = ?, revoked_at = NULL, last_seen_at = ? WHERE id = ?`,
			tokenHash, time.Now().UTC(), existing)
		var u uuid.UUID
		copy(u[:], existing)
		return u, err
	}
}

// DeviceByTokenHash Bearer token 认证查找（JOIN 用户名）。
func (s *Store) DeviceByTokenHash(ctx context.Context, tokenHash []byte) (*DeviceRow, string, error) {
	var d DeviceRow
	var id, uid []byte
	var username string
	err := s.DB.QueryRowContext(ctx,
		`SELECT d.id, d.user_id, d.name, d.platform, d.created_at, d.last_seen_at, d.revoked_at, u.username
		 FROM devices d JOIN users u ON u.id = d.user_id WHERE d.token_hash = ?`,
		tokenHash).Scan(&id, &uid, &d.Name, &d.Platform, &d.CreatedAt, &d.LastSeenAt, &d.RevokedAt, &username)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, "", nil
	}
	if err != nil {
		return nil, "", err
	}
	copy(d.ID[:], id)
	copy(d.UserID[:], uid)
	return &d, username, nil
}

// ListDevices 列出用户全部设备（含已吊销）。
func (s *Store) ListDevices(ctx context.Context, userID uuid.UUID) ([]DeviceRow, error) {
	rows, err := s.DB.QueryContext(ctx,
		`SELECT id, user_id, name, platform, created_at, last_seen_at, revoked_at FROM devices WHERE user_id = ? ORDER BY created_at`,
		userID[:])
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []DeviceRow
	for rows.Next() {
		var d DeviceRow
		var id, uid []byte
		if err := rows.Scan(&id, &uid, &d.Name, &d.Platform, &d.CreatedAt, &d.LastSeenAt, &d.RevokedAt); err != nil {
			return nil, err
		}
		copy(d.ID[:], id)
		copy(d.UserID[:], uid)
		out = append(out, d)
	}
	return out, rows.Err()
}

// RevokeDevice 吊销指定设备（须属于该用户），返回是否命中。
func (s *Store) RevokeDevice(ctx context.Context, userID, deviceID uuid.UUID) (bool, error) {
	res, err := s.DB.ExecContext(ctx,
		`UPDATE devices SET revoked_at = ? WHERE id = ? AND user_id = ? AND revoked_at IS NULL`,
		time.Now().UTC(), deviceID[:], userID[:])
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

// TouchDevice 更新 last_seen_at。
func (s *Store) TouchDevice(ctx context.Context, deviceID uuid.UUID) error {
	_, err := s.DB.ExecContext(ctx,
		`UPDATE devices SET last_seen_at = ? WHERE id = ?`, time.Now().UTC(), deviceID[:])
	return err
}

// Audit 写审计事件（append-only）。
func (s *Store) Audit(ctx context.Context, userID, deviceID uuid.UUID, action, targetType string, targetID uuid.UUID, detail map[string]any, ip string) {
	detailJSON := mapToJSON(detail)
	var dev, tid any
	if deviceID != uuid.Nil {
		dev = deviceID[:]
	}
	if targetID != uuid.Nil {
		tid = targetID[:]
	}
	_, _ = s.DB.ExecContext(ctx,
		`INSERT INTO audit_events (ts, actor_user, actor_device, action, target_type, target_id, detail_json, ip)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		time.Now().UTC(), userID[:], dev, action, nullStr(targetType), tid, detailJSON, nullStr(ip))
}

func nullStr(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func mapToJSON(m map[string]any) any {
	if len(m) == 0 {
		return nil
	}
	b, err := jsonMarshal(m)
	if err != nil {
		return nil
	}
	return b
}

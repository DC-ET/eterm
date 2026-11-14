package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"

	"eterm/server/internal/store"
)

const (
	maxFailedLogins = 5
	lockDuration    = 15 * time.Minute
)

var (
	ErrBadCreds      = errors.New("用户名或口令错误")
	ErrLocked        = errors.New("账户已锁定")
	ErrNoVault       = errors.New("用户无可用 vault")
	ErrDeviceName    = errors.New("device_name 与 platform 必填")
)

// LoginResult 登录成功返回。
type LoginResult struct {
	Token    string
	DeviceID uuid.UUID
	UserID   uuid.UUID
	Username string
	VaultID  uuid.UUID
}

type LockedError struct{ Until time.Time }

func (e *LockedError) Error() string {
	return fmt.Sprintf("账户已锁定，%s 后重试", e.Until.Format(time.RFC3339))
}

// Service 登录与设备 token。
type Service struct {
	Store  *store.Store
	Pepper string
}

// Login 校验口令、处理失败锁定、注册/复用设备并签发 token。
func (s *Service) Login(ctx context.Context, username, password, deviceName, platform, ip string) (*LoginResult, error) {
	if deviceName == "" || platform == "" {
		return nil, ErrDeviceName
	}
	u, err := s.Store.GetUserByUsername(ctx, username)
	if err != nil {
		return nil, err
	}
	if u == nil {
		return nil, ErrBadCreds // 不区分用户不存在，防枚举
	}
	if u.LockedUntil.Valid && u.LockedUntil.Time.After(time.Now().UTC()) {
		return nil, &LockedError{Until: u.LockedUntil.Time.UTC()}
	}
	ok, err := VerifyPassword(password, s.Pepper, u.PwdHash)
	if err != nil {
		return nil, err
	}
	if !ok {
		s.Store.Audit(ctx, u.ID, uuid.Nil, "auth.login.fail", "", uuid.Nil, nil, ip)
		locked, until, err := s.Store.RegisterLoginFailure(ctx, u.ID, maxFailedLogins, lockDuration)
		if err != nil {
			return nil, err
		}
		if locked {
			s.Store.Audit(ctx, u.ID, uuid.Nil, "auth.lockout", "", uuid.Nil, nil, ip)
			return nil, &LockedError{Until: until}
		}
		return nil, ErrBadCreds
	}
	if err := s.Store.ResetLoginFailure(ctx, u.ID); err != nil {
		return nil, err
	}

	token, err := newToken()
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256([]byte(token))
	deviceID, err := s.Store.UpsertDevice(ctx, u.ID, deviceName, platform, sum[:])
	if err != nil {
		return nil, err
	}
	vaultID, err := s.Store.FirstVaultOfUser(ctx, u.ID)
	if err != nil {
		return nil, ErrNoVault
	}
	s.Store.Audit(ctx, u.ID, deviceID, "auth.login.ok", "device", deviceID,
		map[string]any{"device_name": deviceName, "platform": platform}, ip)

	return &LoginResult{
		Token:    token,
		DeviceID: deviceID,
		UserID:   u.ID,
		Username: u.Username,
		VaultID:  vaultID,
	}, nil
}

// newToken 生成 32B 高熵 token（base64url，无填充）。
func newToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", fmt.Errorf("生成 token 失败: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// HashToken 服务端仅存 SHA-256。
func HashToken(token string) []byte {
	sum := sha256.Sum256([]byte(token))
	return sum[:]
}

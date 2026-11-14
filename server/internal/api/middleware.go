package api

import (
	"context"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"

	"eterm/server/internal/store"
)

type ctxKey int

const (
	ctxUser ctxKey = iota
	ctxDevice
	ctxVault
	ctxUsername
	ctxIP
)

// userCtx 认证中间件注入的身份信息。
type userCtx struct {
	UserID   uuid.UUID
	DeviceID uuid.UUID
	Username string
	VaultID  uuid.UUID
}

func userFrom(ctx context.Context) userCtx {
	u, _ := ctx.Value(ctxUser).(userCtx)
	return u
}

// RealIP 信任配置的反向代理（默认仅 127.0.0.1），取 X-Forwarded-For 首个地址。
func RealIP(trustedProxy string) func(http.Handler) http.Handler {
	trusted := net.ParseIP(trustedProxy) != nil
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			host, _, err := net.SplitHostPort(r.RemoteAddr)
			if err != nil {
				host = r.RemoteAddr
			}
			ip := host
			if trusted && host == trustedProxy {
				if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
					if first := strings.TrimSpace(strings.Split(xff, ",")[0]); first != "" {
						ip = first
					}
				}
			}
			ctx := context.WithValue(r.Context(), ctxIP, ip)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

func ipFrom(ctx context.Context) string {
	ip, _ := ctx.Value(ctxIP).(string)
	return ip
}

// IPWhitelist CIDR 白名单；列表为空则放行所有。
func IPWhitelist(cidrs []string) (func(http.Handler) http.Handler, error) {
	var nets []*net.IPNet
	for _, c := range cidrs {
		if !strings.Contains(c, "/") {
			c += "/32"
		}
		_, n, err := net.ParseCIDR(c)
		if err != nil {
			return nil, err
		}
		nets = append(nets, n)
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if len(nets) > 0 {
				ip := net.ParseIP(ipFrom(r.Context()))
				allowed := false
				for _, n := range nets {
					if ip != nil && n.Contains(ip) {
						allowed = true
						break
					}
				}
				if !allowed {
					http.Error(w, `{"error":"forbidden_ip"}`, http.StatusForbidden)
					return
				}
			}
			next.ServeHTTP(w, r)
		})
	}, nil
}

// BearerAuth 校验 Bearer token（或 ?token=，供 WS），注入身份与 vault。

var lastSeen = struct {
	sync.Mutex
	m map[uuid.UUID]time.Time
}{m: map[uuid.UUID]time.Time{}}

func BearerAuth(st *store.Store) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			tok := bearerToken(r)
			if tok == "" {
				http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
				return
			}
			dev, username, err := st.DeviceByTokenHash(r.Context(), sha256Sum(tok))
			if err != nil {
				slog.Error("token 查询失败", "err", err)
				http.Error(w, `{"error":"internal"}`, http.StatusInternalServerError)
				return
			}
			if dev == nil || !dev.RevokedAt.Time.IsZero() {
				http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
				return
			}
			vaultID, err := st.FirstVaultOfUser(r.Context(), dev.UserID)
			if err != nil {
				slog.Error("vault 查询失败", "err", err)
				http.Error(w, `{"error":"no_vault"}`, http.StatusForbidden)
				return
			}
			// last_seen_at 节流：每设备 24h 一次
			lastSeen.Lock()
			last, ok := lastSeen.m[dev.ID]
			if !ok || time.Since(last) > 24*time.Hour {
				lastSeen.m[dev.ID] = time.Now()
				lastSeen.Unlock()
				_ = st.TouchDevice(r.Context(), dev.ID)
			} else {
				lastSeen.Unlock()
			}
			uc := userCtx{UserID: dev.UserID, DeviceID: dev.ID, Username: username, VaultID: vaultID}
			ctx := context.WithValue(r.Context(), ctxUser, uc)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

func bearerToken(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if strings.HasPrefix(h, "Bearer ") {
		return strings.TrimSpace(strings.TrimPrefix(h, "Bearer "))
	}
	return r.URL.Query().Get("token")
}

// RateLimitLogin 简易令牌桶：每 IP 容量 10、每分钟回填 10。
func RateLimitLogin(next http.Handler) http.Handler {
	type bucket struct {
		tokens float64
		last   time.Time
	}
	var (
		mu      sync.Mutex
		buckets = map[string]*bucket{}
	)
	refill := 10.0 / 60.0
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip := ipFrom(r.Context())
		mu.Lock()
		b, ok := buckets[ip]
		now := time.Now()
		if !ok {
			b = &bucket{tokens: 10, last: now}
			buckets[ip] = b
		}
		b.tokens += now.Sub(b.last).Minutes() * refill
		if b.tokens > 10 {
			b.tokens = 10
		}
		b.last = now
		if b.tokens < 1 {
			mu.Unlock()
			http.Error(w, `{"error":"rate_limited"}`, http.StatusTooManyRequests)
			return
		}
		b.tokens--
		mu.Unlock()
		next.ServeHTTP(w, r)
	})
}

// Logger 请求日志。
func Logger(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		if r.URL.Path == "/healthz" {
			return
		}
		slog.Info("http", "method", r.Method, "path", r.URL.Path, "ip", ipFrom(r.Context()), "dur", time.Since(start).Round(time.Millisecond))
	})
}

// Recover panic 兜底。
func Recover(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if p := recover(); p != nil {
				slog.Error("panic", "err", p, "path", r.URL.Path)
				http.Error(w, `{"error":"internal"}`, http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func sha256Bytes(s string) []byte {
	sum := sha256Sum(s)
	return sum
}
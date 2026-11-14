// Package api HTTP 层：路由、中间件、handlers（技术方案 §3.3/§3.5）。
package api

import (
	"crypto/sha256"
	"net/http"

	"github.com/go-chi/chi/v5"

	"eterm/server/internal/auth"
	"eterm/server/internal/hub"
	"eterm/server/internal/syncengine"
	"eterm/server/internal/store"
)

// Deps 路由依赖。
type Deps struct {
	Store   *store.Store
	Auth    *auth.Service
	Engine  *syncengine.Engine
	Hub     *hub.Hub
	Version string
}

// NewRouter 组装全部路由与中间件。
func NewRouter(d Deps, ipWhitelist func(http.Handler) http.Handler, trustedProxy string) http.Handler {
	r := chi.NewRouter()
	r.Use(Recover)
	r.Use(Logger)
	r.Use(RealIP(trustedProxy))
	r.Use(ipWhitelist)

	r.Get("/healthz", handleHealth(d.Version))

	r.Route("/api/v1", func(r chi.Router) {
		// 公开
		r.With(RateLimitLogin).Post("/auth/login", handleLogin(d))

		// 认证区
		r.Group(func(r chi.Router) {
			r.Use(BearerAuth(d.Store))
			r.Post("/auth/logout", handleLogout(d))
			r.Get("/me", handleMe())
			r.Get("/devices", handleListDevices(d))
			r.Delete("/devices/{id}", handleRevokeDevice(d))
			r.Get("/sync/pull", handlePull(d))
			r.Post("/sync/push", handlePush(d))
			r.Get("/ws", handleWS(d))
		})
	})
	return r
}

func handleHealth(version string) http.HandlerFunc {
	return func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "version": version})
	}
}

func sha256Sum(s string) []byte {
	sum := sha256.Sum256([]byte(s))
	return sum[:]
}

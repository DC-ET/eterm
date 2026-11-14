package api

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"

	"eterm/server/internal/auth"
)

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

// ---- auth ----

type loginReq struct {
	Username   string `json:"username"`
	Password   string `json:"password"`
	DeviceName string `json:"device_name"`
	Platform   string `json:"platform"`
}

func handleLogin(d Deps) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req loginReq
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeErr(w, http.StatusBadRequest, "bad_json")
			return
		}
		res, err := d.Auth.Login(r.Context(), req.Username, req.Password, req.DeviceName, req.Platform, ipFrom(r.Context()))
		switch {
		case err == nil:
		case errors.Is(err, auth.ErrBadCreds):
			writeErr(w, http.StatusUnauthorized, "bad_credentials")
			return
		case errors.Is(err, auth.ErrDeviceName):
			writeErr(w, http.StatusBadRequest, "device_name_and_platform_required")
			return
		case errors.Is(err, auth.ErrNoVault):
			writeErr(w, http.StatusForbidden, "no_vault")
			return
		default:
			var le *auth.LockedError
			if errors.As(err, &le) {
				writeJSON(w, http.StatusLocked, map[string]any{"error": "locked", "retry_after": le.Until.Unix()})
				return
			}
			slogError("登录处理失败", err)
			writeErr(w, http.StatusInternalServerError, "internal")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"token":     res.Token,
			"device_id": res.DeviceID,
			"user":      map[string]any{"id": res.UserID, "username": res.Username},
			"vault_id":  res.VaultID,
		})
	}
}

func handleLogout(d Deps) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		u := userFrom(r.Context())
		ok, err := d.Store.RevokeDevice(r.Context(), u.UserID, u.DeviceID)
		if err != nil {
			slogError("吊销设备失败", err)
			writeErr(w, http.StatusInternalServerError, "internal")
			return
		}
		if ok {
			d.Store.Audit(r.Context(), u.UserID, u.DeviceID, "auth.logout", "device", u.DeviceID, nil, ipFrom(r.Context()))
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": ok})
	}
}

func handleMe() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		u := userFrom(r.Context())
		writeJSON(w, http.StatusOK, map[string]any{
			"user":     map[string]any{"id": u.UserID, "username": u.Username},
			"device":   map[string]any{"id": u.DeviceID},
			"vault_id": u.VaultID,
		})
	}
}

// ---- devices ----

func handleListDevices(d Deps) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		u := userFrom(r.Context())
		devs, err := d.Store.ListDevices(r.Context(), u.UserID)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "internal")
			return
		}
		out := make([]map[string]any, 0, len(devs))
		for _, dv := range devs {
			m := map[string]any{
				"id": dv.ID, "name": dv.Name, "platform": dv.Platform,
				"created_at": dv.CreatedAt.UTC(),
			}
			if dv.LastSeenAt.Valid {
				m["last_seen_at"] = dv.LastSeenAt.Time.UTC()
			}
			if dv.RevokedAt.Valid {
				m["revoked_at"] = dv.RevokedAt.Time.UTC()
			}
			out = append(out, m)
		}
		writeJSON(w, http.StatusOK, map[string]any{"devices": out})
	}
}

func handleRevokeDevice(d Deps) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		u := userFrom(r.Context())
		id, err := uuid.Parse(chi.URLParam(r, "id"))
		if err != nil {
			writeErr(w, http.StatusBadRequest, "bad_device_id")
			return
		}
		ok, err := d.Store.RevokeDevice(r.Context(), u.UserID, id)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, "internal")
			return
		}
		if ok {
			d.Store.Audit(r.Context(), u.UserID, u.DeviceID, "device.revoke", "device", id, nil, ipFrom(r.Context()))
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": ok})
	}
}

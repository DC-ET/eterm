package api

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"

	"github.com/google/uuid"

	"eterm/server/internal/store"
	"eterm/server/internal/syncengine"
)

func slogError(msg string, err error) { slog.Error(msg, "err", err) }

// ---- sync ----

func handlePull(d Deps) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		u := userFrom(r.Context())
		cursor, err := syncengine.ParseCursor(r.URL.Query().Get("cursor"))
		if err != nil {
			writeErr(w, http.StatusBadRequest, err.Error())
			return
		}
		limit := 200
		if l := r.URL.Query().Get("limit"); l != "" {
			if n, err := strconv.Atoi(l); err == nil && n > 0 && n <= 1000 {
				limit = n
			}
		}
		resp, err := d.Engine.Pull(r.Context(), u.VaultID[:], cursor, limit)
		if err != nil {
			slogError("pull 失败", err)
			writeErr(w, http.StatusInternalServerError, "internal")
			return
		}
		writeJSON(w, http.StatusOK, resp)
	}
}

type pushItemWire struct {
	EntityType string         `json:"entity_type"`
	EntityID   string         `json:"entity_id"`
	BaseRev    uint64         `json:"base_rev"`
	Op         string         `json:"op"`
	Data       map[string]any `json:"data"`
}

type pushReq struct {
	Changes []pushItemWire `json:"changes"`
}

func handlePush(d Deps) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		u := userFrom(r.Context())
		dec := json.NewDecoder(r.Body)
		dec.UseNumber()
		var req pushReq
		if err := dec.Decode(&req); err != nil {
			writeErr(w, http.StatusBadRequest, "bad_json")
			return
		}
		if len(req.Changes) == 0 {
			writeErr(w, http.StatusBadRequest, "empty_changes")
			return
		}
		if len(req.Changes) > 500 {
			writeErr(w, http.StatusBadRequest, "too_many_changes")
			return
		}
		items := make([]store.PushItem, len(req.Changes))
		for i, c := range req.Changes {
			items[i] = store.PushItem{
				EntityType: c.EntityType,
				EntityID:   c.EntityID,
				BaseRev:    c.BaseRev,
				Op:         c.Op,
				Data:       normalizeData(c.Data),
			}
		}
		results := d.Engine.Push(r.Context(), u.VaultID[:], u.DeviceID[:], items)
		d.Store.Audit(r.Context(), u.UserID, u.DeviceID, "sync.push", "", uuid.Nil,
			map[string]any{"count": len(items)}, ipFrom(r.Context()))
		writeJSON(w, http.StatusOK, map[string]any{"results": results})
	}
}

// normalizeData 把解码端产生的 map[string]any 中的嵌套值收敛为可编码形态：
// json.Number → 保留（encodeCell 处理）；其余原样。
func normalizeData(m map[string]any) map[string]any {
	if m == nil {
		return nil
	}
	out := make(map[string]any, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

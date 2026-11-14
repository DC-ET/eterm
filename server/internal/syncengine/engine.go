// Package syncengine 实现 pull/push 业务编排（技术方案 §3.3/§3.4）。
package syncengine

import (
	"context"
	"fmt"

	"eterm/server/internal/hub"
	"eterm/server/internal/store"
)

// PullChange 单条变更（wire 形态）。
type PullChange struct {
	EntityType string         `json:"entity_type"`
	EntityID   string         `json:"entity_id"`
	Op         string         `json:"op"`
	Rev        uint64         `json:"rev"`
	TS         string         `json:"ts"`
	Data       map[string]any `json:"data,omitempty"`
}

// PullResponse GET /sync/pull 响应。
type PullResponse struct {
	Cursor  uint64       `json:"cursor"`
	HasMore bool         `json:"has_more"`
	Changes []PullChange `json:"changes"`
}

// Engine 同步引擎。
type Engine struct {
	Store *store.Store
	Hub   *hub.Hub
}

// Pull 增量拉取。
func (e *Engine) Pull(ctx context.Context, vaultID []byte, cursor uint64, limit int) (*PullResponse, error) {
	rows, newCursor, hasMore, err := e.Store.FetchChanges(ctx, vaultID, cursor, limit)
	if err != nil {
		return nil, err
	}
	resp := &PullResponse{Cursor: newCursor, HasMore: hasMore, Changes: make([]PullChange, 0, len(rows))}
	for _, r := range rows {
		resp.Changes = append(resp.Changes, PullChange{
			EntityType: r.EntityType,
			EntityID:   r.EntityID,
			Op:         r.Op,
			Rev:        r.ID,
			TS:         r.TS.UTC().Format("2006-01-02T15:04:05.000Z07:00"),
			Data:       r.Data,
		})
	}
	return resp, nil
}

// PushResult push 单项结果（wire 形态）。
type PushResult struct {
	Status     string         `json:"status"`
	Rev        uint64         `json:"rev,omitempty"`
	ServerData map[string]any `json:"server_data,omitempty"`
	Reason     string         `json:"reason,omitempty"`
}

// Push 批量推送：逐条独立事务；任一成功即广播最新 rev。
func (e *Engine) Push(ctx context.Context, vaultID, deviceID []byte, items []store.PushItem) []PushResult {
	results := make([]PushResult, len(items))
	var maxRev uint64
	anyOK := false
	for i, it := range items {
		r := e.Store.PushItem(ctx, vaultID, deviceID, it)
		results[i] = PushResult{Status: r.Status, Rev: r.Rev, ServerData: r.ServerData, Reason: r.Reason}
		if r.Status == "ok" {
			anyOK = true
			if r.Rev > maxRev {
				maxRev = r.Rev
			}
		}
	}
	if anyOK {
		e.Hub.Broadcast(maxRev)
	}
	return results
}

// ValidateCursor 校验 query 参数。
func ParseCursor(s string) (uint64, error) {
	if s == "" {
		return 0, nil
	}
	var v uint64
	if _, err := fmt.Sscanf(s, "%d", &v); err != nil {
		return 0, fmt.Errorf("cursor 必须为非负整数")
	}
	return v, nil
}

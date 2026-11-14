// Package hub 进程内 WS 订阅者广播：push 成功后通知各端拉取增量。
package hub

import "sync"

// Hub 保存订阅通道；Broadcast 满即丢弃（客户端靠 pull 补齐，通知只是加速器）。
type Hub struct {
	mu   sync.Mutex
	subs map[chan uint64]struct{}
}

func New() *Hub {
	return &Hub{subs: make(map[chan uint64]struct{})}
}

func (h *Hub) Subscribe() chan uint64 {
	ch := make(chan uint64, 16)
	h.mu.Lock()
	h.subs[ch] = struct{}{}
	h.mu.Unlock()
	return ch
}

func (h *Hub) Unsubscribe(ch chan uint64) {
	h.mu.Lock()
	delete(h.subs, ch)
	h.mu.Unlock()
}

func (h *Hub) Broadcast(rev uint64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs {
		select {
		case ch <- rev:
		default: // 订阅端积压：丢弃，客户端仍会周期性/重连时对账
		}
	}
}

// Count 订阅数（健康检查/测试用）。
func (h *Hub) Count() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.subs)
}

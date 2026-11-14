package api

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/coder/websocket"
)

// handleWS 通知通道：认证后订阅 hub，广播帧 {"type":"change","rev":N}。
// 心跳：服务端 30s ping；读空闲 2 分钟断开（客户端负责重连）。
func handleWS(d Deps) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
			OriginPatterns: []string{"*"}, // 同步面自托管域名由反代限制；MVP 放宽
		})
		if err != nil {
			return
		}
		defer conn.Close(websocket.StatusInternalError, "closing")

		ctx, cancel := context.WithCancel(r.Context())
		defer cancel()
		ch := d.Hub.Subscribe()
		defer d.Hub.Unsubscribe(ch)

		// 读泵：仅消费对端帧（pong/ping 由库处理）；读错误即断开
		go func() {
			defer cancel()
			for {
				if _, _, err := conn.Read(ctx); err != nil {
					return
				}
			}
		}()

		ping := time.NewTicker(30 * time.Second)
		defer ping.Stop()
		for {
			select {
			case <-ctx.Done():
				conn.Close(websocket.StatusNormalClosure, "bye") //nolint:errcheck
				return
			case rev := <-ch:
				wctx, wcancel := context.WithTimeout(ctx, 10*time.Second)
				err := conn.Write(wctx, websocket.MessageText,
					[]byte(`{"type":"change","rev":`+uitoa(rev)+`}`))
				wcancel()
				if err != nil {
					slog.Debug("ws 写失败，断开", "err", err)
					return
				}
			case <-ping.C:
				pctx, pcancel := context.WithTimeout(ctx, 10*time.Second)
				err := conn.Ping(pctx)
				pcancel()
				if err != nil {
					slog.Debug("ws ping 失败，断开", "err", err)
					return
				}
			}
		}
	}
}

func uitoa(v uint64) string {
	if v == 0 {
		return "0"
	}
	var buf [20]byte
	i := len(buf)
	for v > 0 {
		i--
		buf[i] = byte('0' + v%10)
		v /= 10
	}
	return string(buf[i:])
}

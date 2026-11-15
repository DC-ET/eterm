// WS 实时同步（M2）：中枢 push 广播 {type:"change", rev} → 去抖触发增量拉取。
// 对账模型：WS 只当"有变更"信号，数据一律走 pull（丢消息也能对齐）。
// 断线指数退避重连（1s 起步、上限 60s）；登录启动，登出停止。

import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

class Realtime {
  WebSocketChannel? _ws;
  StreamSubscription? _sub;
  Timer? _retry;
  Timer? _debounce;
  String? _server;
  String? _token;
  int _backoff = 0;
  bool _stopped = true;

  /// 收到变更信号后触发的回调（一般 = AppState.refresh）。
  void Function()? onPoke;

  void start(String server, String token, {required void Function() poke}) {
    stop();
    _server = server;
    _token = token;
    onPoke = poke;
    _stopped = false;
    _backoff = 0;
    _connect();
  }

  void stop() {
    _stopped = true;
    _retry?.cancel();
    _retry = null;
    _debounce?.cancel();
    _debounce = null;
    _sub?.cancel();
    _sub = null;
    try {
      _ws?.sink.close();
    } catch (_) {}
    _ws = null;
  }

  void _connect() {
    if (_stopped || _server == null || _token == null) return;
    final base = Uri.parse(_server!);
    final wsUri = base.replace(
      scheme: base.scheme == 'http' ? 'ws' : 'wss',
      path: '/api/v1/ws',
      queryParameters: {'token': _token},
    );
    try {
      final ws = WebSocketChannel.connect(wsUri);
      _ws = ws;
      _sub = ws.stream.listen(
        (msg) {
          // 连接建立后重置退避
          _backoff = 0;
          final s = msg.toString();
          if (s.contains('"change"')) _poke();
        },
        onDone: _scheduleRetry,
        onError: (_) => _scheduleRetry,
      );
    } catch (_) {
      _scheduleRetry();
    }
  }

  /// 连续多条变更合并：800ms 内只拉一次。
  void _poke() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), () {
      onPoke?.call();
    });
  }

  void _scheduleRetry() {
    if (_stopped) return;
    _sub = null;
    _ws = null;
    _retry?.cancel();
    final secs = _backoff >= 6 ? 60 : (1 << _backoff);
    _backoff = (_backoff + 1).clamp(0, 6);
    _retry = Timer(Duration(seconds: secs), _connect);
  }
}

/// 应用级单例（登录启动 / 登出停止）。
final realtime = Realtime();

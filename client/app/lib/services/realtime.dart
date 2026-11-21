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

  /// 回前台探测（D13①，方案 §4.2）：挂起归来后本地状态陈旧——socket 实际
  /// 已死时 onDone/onError 要到解冻后才送达，正常路径会吃满累积退避（≤60s）。
  /// 本探测不等退避：看着已断（无连接/已收到关闭）立即重连；看着存活则
  /// 清零退避，让解冻后随即到达的 onDone 在 1s 内完成重连。
  ///
  /// 实现偏离说明（review P2#5）：方案要求「发一条真实网络动作判活」，此处
  /// 为被动判活（查连接状态 + 清退避）——主动 WS 文本探测有协议风险（中枢
  /// 对未知消息帧的行为未约定，可能被当协议错误断链），伴随的 app.refresh
  /// 走独立 HTTP 连接对 WS 死活无信号。半开 socket 场景依赖解冻后事件送达
  /// + 清零后的快速重连兜底，真机核验项 #10 验证。
  void probe() {
    if (_stopped) return;
    _retry?.cancel();
    _retry = null;
    _backoff = 0;
    final ws = _ws;
    if (ws == null || ws.closeCode != null) {
      _sub?.cancel();
      _sub = null;
      _ws = null;
      try {
        ws?.sink.close(); // 已关闭的 channel 也显式断 sink（review P3 卫生）
      } catch (_) {}
      _connect();
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

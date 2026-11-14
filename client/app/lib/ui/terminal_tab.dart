// 终端标签页（满幅浅色）：xterm 浅色主题 + Rust SSH 会话。
// 增量 UTF-8 解码（多字节不跨帧撕裂）；关闭标签即断开会话（dispose）。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:eterm/src/rust/api/ssh.dart' as ssh;
import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart';

import '../services/app_state.dart';
import 'theme.dart';

class TerminalTabView extends StatefulWidget {
  const TerminalTabView({
    super.key,
    required this.host,
    required this.terminal,
    required this.authKind,
    required this.secret,
  });

  final HostView host;
  final Terminal terminal;
  final String authKind; // password | key
  final String secret;

  @override
  State<TerminalTabView> createState() => _TerminalTabViewState();
}

class _TerminalTabViewState extends State<TerminalTabView> {
  final _bytes = StreamController<List<int>>();
  BigInt? _sessionId;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _term.onOutput = _onOutput;
    _term.onResize = (width, height, _, _) {
      final id = _sessionId;
      if (id != null && !_closed) ssh.sshResize(id: id, cols: width, rows: height);
    };
    _bytes.stream.transform(utf8.decoder).listen(_term.write);
    _connect();
  }

  Terminal get _term => widget.terminal;

  @override
  void dispose() {
    final id = _sessionId;
    if (id != null && !_closed) ssh.sshClose(id: id);
    _bytes.close();
    super.dispose();
  }

  void _onOutput(String data) {
    final id = _sessionId;
    if (id == null || _closed) return;
    ssh.sshWrite(id: id, data: Uint8List.fromList(utf8.encode(data)));
  }

  Future<void> _connect() async {
    final h = widget.host;
    try {
      final id = ssh.sshConnect(
        host: h.hostname,
        port: h.port,
        user: h.username,
        authKind: widget.authKind,
        secret: widget.secret,
        cols: 80,
        rows: 24,
      );
      _sessionId = id;
      await for (final ev in ssh.sshEvents(id: id)) {
        switch (ev) {
          case ssh.SshEvent_Data():
            _bytes.add(ev.bytes);
          case ssh.SshEvent_Closed():
            _closed = true;
            _bytes.add(utf8.encode('\r\n\x1b[31m[连接关闭] ${ev.reason}\x1b[0m\r\n'));
            return;
        }
      }
    } catch (e) {
      _closed = true;
      _bytes.add(utf8.encode('\r\n\x1b[31m[错误] $e\x1b[0m\r\n'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Et.termBg,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: TerminalView(
        _term,
        autofocus: true,
        theme: termLightTheme,
        keyboardAppearance: Brightness.light,
        padding: const EdgeInsets.only(left: 10, top: 8),
        textStyle: const TerminalStyle(fontSize: 13.5),
      ),
    );
  }
}

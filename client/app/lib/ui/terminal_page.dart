// 终端页（M0 骨架）：xterm 渲染 + Rust SSH 会话（vendored xterm.dart 含 CJK/DEL 修复补丁）。
// 字节流经增量 UTF-8 解码（多字节不跨帧撕裂）写入终端；输出回调直写会话。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:eterm/src/rust/api/ssh.dart' as ssh;
import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart';

import '../services/app_state.dart';

class TerminalPage extends StatefulWidget {
  const TerminalPage({
    super.key,
    required this.host,
    required this.authKind,
    required this.secret,
  });

  final HostView host;
  final String authKind;
  final String secret;

  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  late final Terminal _term;
  final _bytes = StreamController<List<int>>();
  BigInt? _sessionId;
  bool _closed = false;
  String? _failReason;

  @override
  void initState() {
    super.initState();
    _term = Terminal(maxLines: 20000);
    _term.onOutput = _onOutput;
    _term.onResize = (width, height, _, _) {
      final id = _sessionId;
      if (id != null && !_closed) ssh.sshResize(id: id, cols: width, rows: height);
    };
    _bytes.stream.transform(utf8.decoder).listen((s) => _term.write(s));
    _connect();
  }

  @override
  void dispose() {
    final id = _sessionId;
    if (id != null && !_closed) {
      ssh.sshClose(id: id);
    }
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
            setState(() => _failReason = ev.reason);
            return;
        }
      }
    } catch (e) {
      _closed = true;
      _bytes.add(utf8.encode('\r\n\x1b[31m[错误] $e\x1b[0m\r\n'));
      if (mounted) setState(() => _failReason = 'FFI 错误: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = '${widget.host.label} — ${widget.host.username}@'
        '${widget.host.hostname}:${widget.host.port}';
    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(fontSize: 14)),
        actions: [
          if (_failReason != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text('已断开',
                    style: TextStyle(color: Colors.redAccent.shade200)),
              ),
            ),
        ],
      ),
      body: TerminalView(
        _term,
        autofocus: true,
      ),
    );
  }
}

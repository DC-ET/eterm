// 终端标签页（满幅浅色）：xterm 浅色主题 + Rust SSH 会话。
// 连接中提示、断开后重连按钮、移动端软键盘弹出按钮。
// 字节流经增量 UTF-8 解码（多字节不跨帧撕裂）写入终端；输出回调直写会话。

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:eterm/src/rust/api/ssh.dart' as ssh;
import 'package:flutter/services.dart';
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

enum _TermPhase { connecting, live, closed }

class _TerminalTabViewState extends State<TerminalTabView> {
  final _bytes = StreamController<List<int>>();
  final _focus = FocusNode();
  BigInt? _sessionId;
  _TermPhase _phase = _TermPhase.connecting;
  String? _reason;

  Terminal get _term => widget.terminal;

  @override
  void initState() {
    super.initState();
    _term.onOutput = _onOutput;
    _term.onResize = (width, height, _, _) {
      final id = _sessionId;
      if (id != null && _phase == _TermPhase.live) {
        ssh.sshResize(id: id, cols: width, rows: height);
      }
    };
    _bytes.stream.transform(utf8.decoder).listen(_term.write);
    _connect();
  }

  @override
  void dispose() {
    final id = _sessionId;
    if (id != null && _phase != _TermPhase.closed) ssh.sshClose(id: id);
    _bytes.close();
    _focus.dispose();
    super.dispose();
  }

  void _onOutput(String data) {
    final id = _sessionId;
    if (id == null || _phase != _TermPhase.live) return;
    ssh.sshWrite(id: id, data: Uint8List.fromList(utf8.encode(data)));
  }

  Future<void> _connect() async {
    final h = widget.host;
    setState(() {
      _phase = _TermPhase.connecting;
      _reason = null;
    });
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
            if (_phase == _TermPhase.connecting) {
              setState(() => _phase = _TermPhase.live);
            }
            _bytes.add(ev.bytes);
          case ssh.SshEvent_Closed():
            _bytes
                .add(utf8.encode('\r\n\x1b[31m[连接关闭] ${ev.reason}\x1b[0m\r\n'));
            setState(() {
              _phase = _TermPhase.closed;
              _reason = ev.reason;
            });
            return;
        }
      }
      // 流意外结束（无 Closed 事件）
      setState(() {
        _phase = _TermPhase.closed;
        _reason = '会话流结束';
      });
    } catch (e) {
      _bytes.add(utf8.encode('\r\n\x1b[31m[错误] $e\x1b[0m\r\n'));
      setState(() {
        _phase = _TermPhase.closed;
        _reason = 'FFI 错误: $e';
      });
    }
  }

  void _showKeyboard() {
    _focus.requestFocus();
    SystemChannels.textInput.invokeMethod('TextInput.show');
  }

  @override
  Widget build(BuildContext context) {
    final isTouch = Platform.isAndroid || Platform.isIOS;
    return Container(
      color: Et.termBg,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Stack(
        children: [
          TerminalView(
            _term,
            autofocus: true,
            focusNode: _focus,
            theme: termLightTheme,
            keyboardAppearance: Brightness.light,
            padding: const EdgeInsets.only(left: 10, top: 8),
            textStyle: const TerminalStyle(fontSize: 13.5),
          ),
          if (_phase == _TermPhase.connecting)
            const Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                          width: 22,
                          height: 22,
                          child:
                              CircularProgressIndicator(strokeWidth: 2.4)),
                      SizedBox(height: 10),
                      Text('连接中…',
                          style: TextStyle(
                              fontSize: 13, color: Et.textSecondary)),
                    ],
                  ),
                ),
              ),
            ),
          if (_phase == _TermPhase.closed)
            Positioned(
              left: 0,
              right: 0,
              bottom: 14,
              child: Center(
                child: Tooltip(
                  message: _reason ?? '重新连接',
                  child: FilledButton.icon(
                    onPressed: () {
                      setState(() => _phase = _TermPhase.connecting);
                      _connect();
                    },
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重新连接'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Et.primaryBtn,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(9)),
                      minimumSize: const Size(0, 40),
                    ),
                  ),
                ),
              ),
            ),
          if (isTouch)
            Positioned(
              right: 10,
              bottom: 10,
              child: IconButton.filledTonal(
                onPressed: _showKeyboard,
                icon: const Icon(Icons.keyboard, size: 22),
                tooltip: '弹出键盘',
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFFF1F2F5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

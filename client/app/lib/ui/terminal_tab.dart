// 终端标签页（满幅浅色）：xterm 浅色主题 + Rust SSH 会话。
// 连接中提示、断开后重连按钮、移动端软键盘弹出按钮 + 辅助键条
// （ESC/Ctrl 粘滞/Tab/方向键——触屏无物理修饰键，直接向会话写转义序列）。
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

/// 终端等宽字体（各平台原生等宽族；xterm 默认字体在 Android 偏模糊）
final _monoFont = Platform.isWindows
    ? 'Consolas'
    : Platform.isMacOS
        ? 'Menlo'
        : 'monospace';

/// 键条按压触觉反馈
void _haptic() => HapticFeedback.selectionClick();

class _TerminalTabViewState extends State<TerminalTabView> {
  final _bytes = StreamController<List<int>>();
  final _focus = FocusNode();
  BigInt? _sessionId;
  _TermPhase _phase = _TermPhase.connecting;
  String? _reason;
  bool _ctrlArmed = false; // 辅助键条：Ctrl 粘滞（下一个可组合字符发送控制码）

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

  /// 软键盘输出的字符 → 会话。Ctrl 粘滞时把可组合字符折叠成控制码
  /// （Ctrl+C = 0x03 等；可组合范围 0x40-0x5f / 0x61-0x7a）。
  void _onOutput(String data) {
    final id = _sessionId;
    if (id == null || _phase != _TermPhase.live) return;
    if (_ctrlArmed && data.length == 1) {
      final c = data.codeUnitAt(0);
      final combinable = (c >= 0x40 && c <= 0x5f) || (c >= 0x61 && c <= 0x7a);
      setState(() => _ctrlArmed = false); // 无论是否组合都消费掉粘滞
      if (combinable) {
        ssh.sshWrite(
            id: id, data: Uint8List.fromList([c & 0x1f]));
        return;
      }
    }
    ssh.sshWrite(id: id, data: Uint8List.fromList(utf8.encode(data)));
  }

  void _sendSeq(String seq) {
    final id = _sessionId;
    if (id == null || _phase != _TermPhase.live) return;
    ssh.sshWrite(id: id, data: Uint8List.fromList(utf8.encode(seq)));
    _focus.requestFocus();
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

  /// 键条 paste：剪贴板文本直写会话（不经终端输入法）。
  Future<void> _pasteClipboard() async {
    final text = await Clipboard.getData('text/plain');
    final t = text?.text;
    final id = _sessionId;
    if (t != null && t.isNotEmpty && id != null && _phase == _TermPhase.live) {
      ssh.sshWrite(id: id, data: Uint8List.fromList(utf8.encode(t)));
    }
    _showKeyboard();
  }

  @override
  Widget build(BuildContext context) {
    final isTouch = Platform.isAndroid || Platform.isIOS;
    return Container(
      color: Et.titleBar, // 状态栏区与标题栏同色，视觉连续
      child: SafeArea(
        bottom: false,
        child: Container(
      color: Et.termBg,
      padding: const EdgeInsets.fromLTRB(8, 6, 0, 0),
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                TerminalView(
                  _term,
                  autofocus: true,
                  focusNode: _focus,
                  theme: termLightTheme,
                  keyboardAppearance: Brightness.light,
                  padding: const EdgeInsets.only(left: 10, top: 8),
                  textStyle: TerminalStyle(
                      fontSize: 13.5, fontFamily: _monoFont),
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
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.4)),
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
              ],
            ),
          ),
          if (isTouch)
            _ExtraKeysBar(
              ctrlArmed: _ctrlArmed,
              onSeq: _sendSeq,
              onToggleCtrl: () => setState(() => _ctrlArmed = !_ctrlArmed),
              onKeyboard: _showKeyboard,
              onPaste: _pasteClipboard,
            ),
        ],
      ),
        ),
      ),
    );
  }
}

/// 移动端辅助键条（Termius extra keys 风格）：横向滚动、无边框淡底。
/// 键序对齐参考稿：tab / ctrl（粘滞）/ ↑ ↓ ← → / ESC / : / paste / * / =
/// 桌面端不显示（有物理键盘）。
class _ExtraKeysBar extends StatelessWidget {
  const _ExtraKeysBar({
    required this.ctrlArmed,
    required this.onSeq,
    required this.onToggleCtrl,
    required this.onKeyboard,
    required this.onPaste,
  });

  final bool ctrlArmed;
  final void Function(String seq) onSeq;
  final VoidCallback onToggleCtrl;
  final VoidCallback onKeyboard;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: const BoxDecoration(
        color: Et.mBg,
        border: Border(top: BorderSide(color: Et.cardBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  _key('tab', onTap: () => onSeq('\t')),
                  _key('ctrl', onTap: onToggleCtrl, active: ctrlArmed),
                  _key('↑', onTap: () => onSeq('\x1b[A'), fontSize: 15),
                  _key('↓', onTap: () => onSeq('\x1b[B'), fontSize: 15),
                  _key('←', onTap: () => onSeq('\x1b[D'), fontSize: 15),
                  _key('→', onTap: () => onSeq('\x1b[C'), fontSize: 15),
                  _key('esc', onTap: () => onSeq('\x1b')),
                  _key(':', onTap: () => onSeq(':')),
                  _key('paste', onTap: onPaste),
                  _key('*', onTap: () => onSeq('*')),
                  _key('=', onTap: () => onSeq('=')),
                  _key('-', onTap: () => onSeq('-')),
                  _key('/', onTap: () => onSeq('/')),
                ],
              ),
            ),
          ),
          IconButton(
            onPressed: onKeyboard,
            icon: const Icon(Icons.keyboard, size: 20),
            tooltip: '弹出键盘',
            color: Et.textSecondary,
          ),
        ],
      ),
    );
  }

  Widget _key(String label,
          {required VoidCallback onTap, bool active = false, double fontSize = 13}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
        child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            alignment: Alignment.center,
            child: Text(label,
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w600,
                  color: active ? Et.tileGroup : Et.textPrimary,
                )),
          ),
        ),
      );
}

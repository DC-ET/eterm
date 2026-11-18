// 终端标签页（满幅浅色）：xterm 浅色主题 + Rust SSH 会话。
// 连接中提示、断开后重连按钮、移动端软键盘弹出按钮 + 辅助键条
// （ESC/Ctrl 粘滞/Tab/方向键——触屏无物理修饰键，直接向会话写转义序列；
// 长按键条任意键或右侧重排按钮可自定义键序，kv 持久化）。
// 移动手势（PRD F3.2）：双击=Tab；长按拖动=方向键（越快越密）+ 静止长按=粘贴菜单；
// 双指捏合=改字号（kv 持久化）。字节流经增量 UTF-8 解码（多字节不跨帧撕裂）写入终端。

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:eterm/src/rust/api/local.dart' as local;
import 'package:eterm/src/rust/api/ssh.dart' as ssh;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart';

import '../services/app_state.dart';
import 'terminal_gestures.dart';
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

class _TerminalTabViewState extends State<TerminalTabView> {
  final _bytes = StreamController<List<int>>();
  final _focus = FocusNode();
  StreamSubscription<ssh.SshEvent>? _sub;
  BigInt? _sessionId;
  _TermPhase _phase = _TermPhase.connecting;
  String? _reason;
  bool _ctrlArmed = false; // 辅助键条：Ctrl 粘滞（下一个可组合字符发送控制码）

  // 移动手势状态（PRD F3.2）
  ArrowGestureTracker? _arrow; // 长按拖动方向键追踪器
  Timer? _menuTimer; // 静止长按 → 粘贴菜单的延迟
  double? _pinchStartFont; // 捏合起始字号

  Terminal get _term => widget.terminal;

  @override
  void initState() {
    super.initState();
    TerminalPrefs.load(); // 字号/键序偏好（幂等，多标签共享）
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
    _sub?.cancel(); // 先断事件流：Closed 事件不得在 dispose 后抵达
    final id = _sessionId;
    if (id != null && _phase != _TermPhase.closed) {
      try {
        ssh.sshClose(id: id);
      } catch (_) {} // 会话可能已被远端关闭并从注册表移除（close 幂等防御）
    }
    _bytes.close();
    _menuTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  /// 输出通道：dispose 后（_bytes 已 close）静默丢弃，杜绝 StateError。
  void _pushBytes(List<int> bytes) {
    if (!_bytes.isClosed) _bytes.add(bytes);
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
    try {
      ssh.sshWrite(id: id, data: Uint8List.fromList(utf8.encode(seq)));
    } catch (_) {} // 会话消失瞬间（Closed 未送达）同步 FFI 异常防御
    _focus.requestFocus();
  }

  Future<void> _connect() async {
    final h = widget.host;
    _sub?.cancel(); // 重连：先断旧订阅
    _sub = null;
    if (mounted) {
      setState(() {
        _phase = _TermPhase.connecting;
        _reason = null;
      });
    }
    void fail(String reason) {
      _pushBytes(utf8.encode('\r\n\x1b[31m[错误] $reason\x1b[0m\r\n'));
      try {
        local.logEvent(kind: 'connect_fail', detail: '${h.label}（$h.hostname）: $reason');
      } catch (_) {}
      if (mounted) {
        setState(() {
          _phase = _TermPhase.closed;
          _reason = reason;
        });
      }
    }

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
      _sub = ssh.sshEvents(id: id).listen((ev) {
        switch (ev) {
          case ssh.SshEvent_Data():
            if (_phase == _TermPhase.connecting && mounted) {
              setState(() => _phase = _TermPhase.live);
              try {
                local.logEvent(kind: 'connect_ok', detail: '${widget.host.label}（${widget.host.hostname}）');
              } catch (_) {}
            }
            _pushBytes(ev.bytes);
          case ssh.SshEvent_Closed():
            _pushBytes(
                utf8.encode('\r\n\x1b[31m[连接关闭] ${ev.reason}\x1b[0m\r\n'));
            try {
              local.logEvent(
                  kind: 'disconnect',
                  detail: '${widget.host.label}（${widget.host.hostname}）: ${ev.reason}');
            } catch (_) {}
            if (mounted) {
              setState(() {
                _phase = _TermPhase.closed;
                _reason = ev.reason;
              });
            }
        }
      }, onError: (Object e) {
        fail('FFI 错误: $e');
      }, onDone: () {
        // 流结束但未收到 Closed（理论上不应发生）；正常关闭时 Closed 先达，
        // 此处已 closed，不得覆盖真实原因
        if (_phase != _TermPhase.closed) fail('会话流结束');
      });
    } catch (e) {
      fail('FFI 错误: $e');
    }
  }

  void _showKeyboard() {
    _focus.requestFocus();
    SystemChannels.textInput.invokeMethod('TextInput.show');
  }

  /// 剪贴板文本直写会话（不经终端输入法）。
  Future<void> _writeClipboardToSession() async {
    final text = await Clipboard.getData('text/plain');
    final t = text?.text;
    final id = _sessionId;
    if (t != null && t.isNotEmpty && id != null && _phase == _TermPhase.live) {
      ssh.sshWrite(id: id, data: Uint8List.fromList(utf8.encode(t)));
    }
  }

  Future<void> _pasteClipboard() async {
    await _writeClipboardToSession();
    _showKeyboard();
  }

  // ---------- 移动手势（触屏 only；桌面不动 xterm 默认选择行为） ----------

  /// 双击 → Tab（Termius 语义；叉子已把默认双击选词替换为本回调）。
  void _onDoubleTap(TapDownDetails _) {
    HapticFeedback.selectionClick();
    _sendSeq('\t');
  }

  /// 长按开始：先起追踪器，350ms 内未拖动则弹粘贴菜单（拖动即取消菜单）。
  void _onLongPressStart(LongPressStartDetails d) {
    _arrow = ArrowGestureTracker();
    _menuTimer?.cancel();
    _menuTimer = Timer(const Duration(milliseconds: 350), () {
      _menuTimer = null;
      if (!mounted || _arrow == null) return;
      _arrow = null; // 菜单接管，此后移动不再发方向键
      HapticFeedback.mediumImpact();
      _showPasteMenu();
    });
  }

  /// 长按拖动 → 方向键（连续发送，速度分档）。
  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails d) {
    _menuTimer?.cancel();
    _menuTimer = null;
    final tracker = _arrow;
    if (tracker == null) return;
    final dirs = tracker.update(
      d.localPosition,
      DateTime.now().microsecondsSinceEpoch,
    );
    for (final dir in dirs) {
      HapticFeedback.selectionClick();
      _sendSeq(switch (dir) {
        ArrowDir.up => '\x1b[A',
        ArrowDir.down => '\x1b[B',
        ArrowDir.right => '\x1b[C',
        ArrowDir.left => '\x1b[D',
      });
    }
  }

  void _onLongPressEnd() {
    _menuTimer?.cancel();
    _menuTimer = null;
    _arrow = null;
  }

  void _onLongPressCancel() => _onLongPressEnd();

  /// 静止长按粘贴菜单（Termius 式）。
  void _showPasteMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Et.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            ListTile(
              leading: Icon(Icons.content_paste, color: Et.primaryBtn),
              title: Text('粘贴到终端',
                  style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: Et.textPrimary)),
              onTap: () {
                Navigator.pop(sheetCtx);
                _writeClipboardToSession();
              },
            ),
            ListTile(
              leading: Icon(Icons.swap_vert, color: Et.primaryBtn),
              title: Text('重排键条',
                  style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: Et.textPrimary)),
              onTap: () {
                Navigator.pop(sheetCtx);
                _showExtraKeysOrderSheet();
              },
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  // ---------- 键条 ----------

  /// 键条按键 id 分发（id 来自 TerminalPrefs.extraKeys）。
  void _onExtraKey(String id) {
    switch (id) {
      case 'tab':
        _sendSeq('\t');
      case 'ctrl':
        setState(() => _ctrlArmed = !_ctrlArmed);
      case 'up':
        _sendSeq('\x1b[A');
      case 'down':
        _sendSeq('\x1b[B');
      case 'left':
        _sendSeq('\x1b[D');
      case 'right':
        _sendSeq('\x1b[C');
      case 'esc':
        _sendSeq('\x1b');
      case 'colon':
        _sendSeq(':');
      case 'paste':
        _pasteClipboard();
      case 'times':
        _sendSeq('*');
      case 'equals':
        _sendSeq('=');
      case 'minus':
        _sendSeq('-');
      case 'slash':
        _sendSeq('/');
    }
  }

  Future<void> _showExtraKeysOrderSheet() async {
    await showExtraKeysOrderSheet(context);
  }

  @override
  Widget build(BuildContext context) {
    final isTouch = Platform.isAndroid || Platform.isIOS;
    return Container(
      color: Et.titleBar, // 状态栏区与标题栏同色，视觉连续
      child: SafeArea(
        bottom: false,
        child: Container(
      color: Et.termTheme.background,
      padding: const EdgeInsets.fromLTRB(8, 6, 0, 0),
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                // 双指捏合改字号（触屏 only）：单指行为完全让给终端内部手势
                ValueListenableBuilder<double>(
                  valueListenable: TerminalPrefs.fontSize,
                  builder: (context, fontSize, _) {
                    Widget view = TerminalView(
                      _term,
                      autofocus: true,
                      focusNode: _focus,
                      theme: Et.termTheme,
                      keyboardAppearance: Et.brightness,
                      padding: const EdgeInsets.only(left: 10, top: 8),
                      textStyle: TerminalStyle(
                          fontSize: fontSize, fontFamily: _monoFont),
                      // 移动手势（F3.2）：双击=Tab；长按=方向键拖动/粘贴菜单。
                      // 桌面不传：保留 xterm 默认（双击选词、长按选词）。
                      onDoubleTap: isTouch ? _onDoubleTap : null,
                      onLongPressStart:
                          isTouch ? _onLongPressStart : null,
                      onLongPressMoveUpdate:
                          isTouch ? _onLongPressMoveUpdate : null,
                      onLongPressEnd: isTouch ? _onLongPressEnd : null,
                      onLongPressCancel:
                          isTouch ? _onLongPressCancel : null,
                    );
                    if (isTouch) {
                      view = RawGestureDetector(
                        gestures: {
                          PinchRecognizer:
                              GestureRecognizerFactoryWithHandlers<
                                  PinchRecognizer>(
                            () => PinchRecognizer(debugOwner: this),
                            (instance) {
                              instance.onStart = (d) {
                                _pinchStartFont = TerminalPrefs.fontSize.value;
                              };
                              instance.onUpdate = (d) {
                                final base = _pinchStartFont;
                                if (base != null) {
                                  // 捏合过程只更新 notifier；落盘在 onEnd 一次性写
                                  // （每帧同步 FFI 跑 UI 线程，评审 BUG-3）
                                  TerminalPrefs.setFontSize(base * d.scale,
                                      persist: false);
                                }
                              };
                              instance.onEnd = (d) {
                                TerminalPrefs.persistFontSize();
                                _pinchStartFont = null;
                              };
                            },
                          ),
                        },
                        child: view,
                      );
                    }
                    return view;
                  },
                ),
                if (_phase == _TermPhase.connecting)
                  Positioned.fill(
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
                            foregroundColor: Et.primaryBtnText,
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
            ValueListenableBuilder<List<String>>(
              valueListenable: TerminalPrefs.extraKeys,
              builder: (context, order, _) => _ExtraKeysBar(
                order: order,
                ctrlArmed: _ctrlArmed,
                activeId: _ctrlArmed ? 'ctrl' : null,
                onKeyTap: _onExtraKey,
                onReorder: _showExtraKeysOrderSheet,
                onKeyboard: _showKeyboard,
              ),
            ),
        ],
      ),
        ),
      ),
    );
  }
}

/// 键条重排面板入口（终端键条与设置页共用）。
Future<void> showExtraKeysOrderSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Et.card,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    builder: (_) => const _ExtraKeysOrderSheet(),
  );
}

/// 键条键定义（id → 展示；行为分发在 _onExtraKey，顺序可在键条/菜单里重排）。
const Map<String, (String, double)> _kExtraKeyDefs = {
  'tab': ('tab', 13),
  'ctrl': ('ctrl', 13),
  'up': ('↑', 15),
  'down': ('↓', 15),
  'left': ('←', 15),
  'right': ('→', 15),
  'esc': ('esc', 13),
  'colon': (':', 14),
  'paste': ('paste', 13),
  'times': ('*', 14),
  'equals': ('=', 14),
  'minus': ('-', 14),
  'slash': ('/', 14),
};

/// 移动端辅助键条（Termius extra keys 风格）：横向滚动、无边框淡底、
/// 键序可重排（长按任意键或右侧重排按钮 → 重排面板，kv 持久化）。
/// 桌面端不显示（有物理键盘）。
class _ExtraKeysBar extends StatelessWidget {
  const _ExtraKeysBar({
    required this.order,
    required this.ctrlArmed,
    required this.activeId,
    required this.onKeyTap,
    required this.onReorder,
    required this.onKeyboard,
  });

  final List<String> order; // 键序（TerminalPrefs 持久化）
  final bool ctrlArmed;
  final String? activeId; // 高亮的键（ctrl 粘滞）
  final void Function(String id) onKeyTap;
  final VoidCallback onReorder;
  final VoidCallback onKeyboard;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
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
                  for (final id in order)
                    if (_kExtraKeyDefs.containsKey(id))
                      _key(id, _kExtraKeyDefs[id]!),
                ],
              ),
            ),
          ),
          IconButton(
            onPressed: onReorder,
            icon: const Icon(Icons.swap_vert, size: 19),
            tooltip: '重排键条（长按键也可）',
            color: Et.textSecondary,
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

  Widget _key(String id, (String, double) def) {
    final (label, fontSize) = def;
    final active = activeId == id;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          onKeyTap(id);
        },
        onLongPress: onReorder, // 长按任意键进入重排
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
}

/// 键条重排面板：拖动排序 + 重置默认 + 完成（TerminalPrefs.setExtraKeys 持久化）。
class _ExtraKeysOrderSheet extends StatefulWidget {
  const _ExtraKeysOrderSheet();

  @override
  State<_ExtraKeysOrderSheet> createState() => _ExtraKeysOrderSheetState();
}

class _ExtraKeysOrderSheetState extends State<_ExtraKeysOrderSheet> {
  late List<String> _order = List.of(TerminalPrefs.extraKeys.value);

  /// onReorderItem 的 newIndex 已按"移除项"语义调整，直接插入即可。
  void _onReorderItem(int oldIndex, int newIndex) {
    setState(() {
      final moved = _order.removeAt(oldIndex);
      _order.insert(newIndex, moved);
    });
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: 460,
        child: Column(
          children: [
            const SizedBox(height: 12),
            Row(
              children: [
                const SizedBox(width: 18),
                Text('重排键条',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Et.textPrimary)),
                const Spacer(),
                TextButton(
                  onPressed: () =>
                      setState(() => _order = List.of(TerminalPrefs.defaultExtraKeys)),
                  child: Text('重置默认',
                      style: TextStyle(color: Et.textSecondary)),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    TerminalPrefs.setExtraKeys(_order);
                    Navigator.pop(context);
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: Et.primaryBtn,
                    foregroundColor: Et.primaryBtnText,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9)),
                  ),
                  child: const Text('完成'),
                ),
                const SizedBox(width: 14),
              ],
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(18, 4, 18, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('按住右侧手柄上下拖动调整顺序，保存后所有终端生效。',
                    style:
                        TextStyle(fontSize: 12, color: Et.textSecondary)),
              ),
            ),
            Expanded(
              child: ReorderableListView(
                buildDefaultDragHandles: true,
                onReorderItem: _onReorderItem,
                children: [
                  for (final id in _order)
                    ListTile(
                      key: ValueKey(id),
                      leading: Text(_kExtraKeyDefs[id]!.$1,
                          style: TextStyle(
                              fontSize: _kExtraKeyDefs[id]!.$2,
                              fontWeight: FontWeight.w600,
                              color: Et.textPrimary)),
                      title: Text(_keyDesc(id),
                          style: TextStyle(
                              fontSize: 13, color: Et.textSecondary)),
                      trailing: Icon(Icons.drag_handle,
                          size: 18, color: Et.textSecondary),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _keyDesc(String id) => switch (id) {
        'tab' => 'Tab 补全',
        'ctrl' => 'Ctrl 粘滞（组合键）',
        'up' => '方向键 上',
        'down' => '方向键 下',
        'left' => '方向键 左',
        'right' => '方向键 右',
        'esc' => 'ESC',
        'colon' => '冒号 :（vim 命令行）',
        'paste' => '粘贴剪贴板',
        'times' => '星号 *',
        'equals' => '等号 =',
        'minus' => '减号 -',
        'slash' => '斜杠 /',
        _ => id,
      };
}

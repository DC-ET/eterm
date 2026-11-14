// Spike S1（技术方案 §8）：Flutter/xterm.dart 终端中文 IME 验证。
// 纯本地回显（无 SSH）。回显环模拟 pty 行 discipline：
//   - 退格：客户端模拟器不解释 DEL（上游曾把 DEL 当可打印字符画出方块，
//     已在 vendor 包修复为忽略），擦除由 echo "\b \b" 完成——与真实 sshd 的
//     pty 行为一致；
//   - 回车：CR → CRLF。
// 使用的 xterm 为 ../third_party/xterm（vendor fork）：
//   1. 宽字符感知的水平光标移动（跨汉字一步，不再"拆成两半"）
//   2. DEL(0x7F) 忽略
// 回归测试见 third_party/xterm/test/cjk_cursor_test.dart（118 项全绿）。

import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart';

void main() => runApp(const SpikeApp());

class SpikeApp extends StatefulWidget {
  const SpikeApp({super.key});

  @override
  State<SpikeApp> createState() => _SpikeAppState();
}

class _SpikeAppState extends State<SpikeApp> {
  final terminal = Terminal(maxLines: 5000);
  final List<String> _events = [];

  @override
  void initState() {
    super.initState();
    terminal.onOutput = (data) {
      terminal.write(_disciplineEcho(data));
      setState(() {
        _events.insert(0, _escape(data));
        if (_events.length > 8) {
          _events.removeLast();
        }
      });
    };
    terminal.write(
        'eterm Spike S1 — IME 验证终端（本地回显 v2）\r\n'
        '已修复：退格擦除（\\b \\b）、宽字符光标吸附（跨汉字一步）、DEL 不再画方块\r\n'
        '验证项：\r\n'
        '  1. 拼音连续输入，候选窗口跟随，选字上屏不重复\r\n'
        '  2. 退格：逐字删除，含已上屏汉字（跨一个汉字一步）\r\n'
        '  3. 中/日/英混输后，←/→ 移动光标不把汉字拆成两半\r\n'
        '  4. 长按方向键连续移动（TerminalView 内建）\r\n\r\n'
        '>>> ');
  }

  /// 模拟 pty 行 discipline 的 echo。
  static String _disciplineEcho(String data) {
    final sb = StringBuffer();
    for (final cu in data.codeUnits) {
      if (cu == 0x7F) {
        sb.write('\b \b');
      } else if (cu == 0x0D) {
        sb.write('\r\n');
      } else {
        sb.writeCharCode(cu);
      }
    }
    return sb.toString();
  }

  static String _escape(String s) => s.codeUnits
      .map((c) => c >= 0x20 && c < 0x7F ? String.fromCharCode(c) : '\\u${c.toRadixString(16)}')
      .join();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'eterm Spike S1 · IME',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        body: Column(
          children: [
            Expanded(flex: 5, child: TerminalView(terminal)),
            Container(
              padding: const EdgeInsets.all(8),
              color: Colors.blueGrey.shade900,
              width: double.infinity,
              child: SizedBox(
                height: 110,
                child: ListView(
                  children: [
                    Text('onOutput 事件（最新在上）',
                        style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade200)),
                    for (final e in _events)
                      Text(e,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

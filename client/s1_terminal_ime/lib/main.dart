// Spike S1（技术方案 §8）：Flutter/xterm.dart 终端中文 IME 验证。
// 纯本地回显（无 SSH）：验证 composing 输入、候选上屏、退格、中日韩混输。
// 通过标准见 PRD/技术方案；人工在窗口内输入并观察。

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
  String lastEvent = '-';

  @override
  void initState() {
    super.initState();
    // 回显环：模拟 pty echo，让键入的字符（含 CJK 提交）出现在终端
    terminal.onOutput = (data) {
      terminal.write(data);
      setState(() => lastEvent = _escape(data));
    };
    terminal.write(
        'eterm Spike S1 — IME 验证终端（本地回显）\r\n'
        '验证项：\r\n'
        '  1. 拼音连续输入，候选窗口跟随，选字上屏不重复\r\n'
        '  2. composing 期间按退格：删除拼音字母而非吞掉已上屏汉字\r\n'
        '  3. 中/日/英混输后光标位置正确\r\n'
        '  4. 长按方向键连续移动（TerminalView 内建）\r\n\r\n'
        '>>> ');
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
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: Colors.blueGrey.shade900,
              width: double.infinity,
              child: Text('最后一次 onOutput: $lastEvent',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ),
            Expanded(child: TerminalView(terminal)),
          ],
        ),
      ),
    );
  }
}

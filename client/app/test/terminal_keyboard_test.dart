// 桌面终端键盘路径回归（Windows 化验收配套）：xterm fork 的 Focus/onKeyEvent
// → Terminal.onOutput 链路，用 Flutter 框架级 KeyEvent 注入（sendKeyEvent）——
// 真实键盘同路径；Win32 合成注入（UI 自动化）对 canvas 不可靠，不作为依据。
// 背景：Windows 首验时终端「命令无输出」实为注入伪影，数据链路字节级验证通畅
// （MOTD/提示符/回车响应均正确渲染）；本测试锁定键盘输入路径不回归。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

Widget _host(Terminal terminal) => MaterialApp(
      home: Scaffold(
        body: TerminalView(terminal, autofocus: true),
      ),
    );

void main() {
  // 说明：字符键（l/s 等）在 xterm fork 桌面端走 IME/TextInput 路径
  // （custom_text_edit.dart），框架级 sendKeyEvent 不覆盖它；该路径平台无关
  // （mac 端日常使用即验证），且端到端数据链路已在 Windows 真机字节级验证
  // （MOTD/提示符/回车响应渲染正确）。此处锁定控制键与缓冲两条平台敏感路径。
  testWidgets('Ctrl 组合键折叠为控制码：Ctrl+C → 0x03', (tester) async {
    final outputs = <String>[];
    final terminal = Terminal(onOutput: outputs.add);
    await tester.pumpWidget(_host(terminal));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(outputs.join(), contains('\x03'),
        reason: 'Ctrl+C 应发送 ETX 控制码（中断信号）');
  });

  testWidgets('Enter 发送回车（CR）', (tester) async {
    final outputs = <String>[];
    final terminal = Terminal(onOutput: outputs.add);
    await tester.pumpWidget(_host(terminal));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(outputs.join(), contains('\r'), reason: 'Enter 应发送回车（CR）');
  });

  testWidgets('Terminal.write 渲染缓冲：文本与换行落格', (tester) async {
    final terminal = Terminal();
    await tester.pumpWidget(_host(terminal));
    await tester.pumpAndSettle();

    terminal.write('eterm-win');
    await tester.pump();
    expect(terminal.buffer.currentLine.toString(), contains('eterm-win'),
        reason: 'write 数据应进入终端缓冲（渲染输入侧）');
  });
}

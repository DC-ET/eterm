// eterm patch 回归测试：宽字符感知的水平光标移动。
// 背景：CJK 宽字符占 2 格，主流终端（xterm/VTE）跨宽字符光标按 1 步计，
// 且向后落在续格时吸附到宽字符起点。上游 moveCursorX 为裸 cell 加法，
// 会把一个汉字"拆成两步"。

import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('write wide char advances cursor by 2 cells', () {
    final t = Terminal();
    t.write('你');
    expect(t.buffer.cursorX, 2);
  });

  test('backward over wide char snaps to its start (1 press per char)', () {
    final t = Terminal();
    t.write('你好'); // cursorX == 4
    t.write('\x1b[D'); // ← 一步落到 好 的起点
    expect(t.buffer.cursorX, 2);
    t.write('\x1b[D'); // ← 一步落到 你 的起点
    expect(t.buffer.cursorX, 0);
    t.write('\x1b[D'); // 边界：停在 0
    expect(t.buffer.cursorX, 0);
  });

  test('forward over wide char crosses both cells (1 press per char)', () {
    final t = Terminal();
    t.write('你好');
    t.write('\x1b[D\x1b[D'); // 回到 0
    t.write('\x1b[C'); // → 一步跨过 你
    expect(t.buffer.cursorX, 2);
    t.write('\x1b[C'); // → 一步跨过 好
    expect(t.buffer.cursorX, 4);
  });

  test('narrow chars still move 1 cell per step', () {
    final t = Terminal();
    t.write('abc');
    t.write('\x1b[D');
    expect(t.buffer.cursorX, 2);
  });

  test('DEL (0x7F) written to emulator is inert (xterm.js semantics)', () {
    // 客户端模拟器不解释 DEL；擦除由 pty echo（\b \b）完成。
    // 上游把 DEL 当可打印字符写出（=退格时屏幕上多出方块），此处修复并固化。
    final t = Terminal();
    t.write('ab');
    t.write('\x7F');
    expect(t.buffer.cursorX, 2);
    expect(t.buffer.currentLine.toString(), contains('ab'));
  });
}

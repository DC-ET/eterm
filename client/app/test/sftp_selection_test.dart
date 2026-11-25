// SFTP 多选：点击语义（替换/切换/连选）与拖拽载荷解析。
// 纯逻辑，不依赖 UI 或 Rust FFI。

import 'package:eterm/ui/sftp_selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const ordered = ['a.txt', 'b.txt', 'c.txt', 'd.txt'];

  test('修饰键 → 点击语义：Shift 优先，触摸端点轻即切换', () {
    expect(
      sftpSelectModeFor(shift: true, toggleKey: false, touch: false),
      SftpSelectMode.range,
    );
    expect(
      sftpSelectModeFor(shift: true, toggleKey: true, touch: false),
      SftpSelectMode.range,
    );
    expect(
      sftpSelectModeFor(shift: false, toggleKey: true, touch: false),
      SftpSelectMode.toggle,
    );
    expect(
      sftpSelectModeFor(shift: false, toggleKey: false, touch: false),
      SftpSelectMode.replace,
    );
    expect(
      sftpSelectModeFor(shift: false, toggleKey: false, touch: true),
      SftpSelectMode.toggle,
    );
  });

  test('桌面单击替换选区', () {
    final sel = const SftpSelection(
      names: {'a.txt', 'b.txt'},
      anchor: 'a.txt',
    ).tap(name: 'c.txt', ordered: ordered, mode: SftpSelectMode.replace);
    expect(sel.names, {'c.txt'});
    expect(sel.anchor, 'c.txt');
  });

  test('Ctrl/⌘ 单击累加与取消，锚点跟随最后点击行', () {
    var sel = SftpSelection.empty.tap(
      name: 'a.txt',
      ordered: ordered,
      mode: SftpSelectMode.toggle,
    );
    expect(sel.names, {'a.txt'});
    sel = sel.tap(name: 'c.txt', ordered: ordered, mode: SftpSelectMode.toggle);
    expect(sel.names, {'a.txt', 'c.txt'});
    expect(sel.anchor, 'c.txt');
    sel = sel.tap(name: 'a.txt', ordered: ordered, mode: SftpSelectMode.toggle);
    expect(sel.names, {'c.txt'});
  });

  test('Shift 连选：正反方向都取锚点到点击行的闭区间', () {
    const base = SftpSelection(names: {'b.txt'}, anchor: 'b.txt');
    expect(
      base
          .tap(name: 'd.txt', ordered: ordered, mode: SftpSelectMode.range)
          .names,
      {'b.txt', 'c.txt', 'd.txt'},
    );
    expect(
      base
          .tap(name: 'a.txt', ordered: ordered, mode: SftpSelectMode.range)
          .names,
      {'a.txt', 'b.txt'},
    );
  });

  test('Shift 连续点击保持原锚点（可继续扩缩范围）', () {
    const base = SftpSelection(names: {'b.txt'}, anchor: 'b.txt');
    final sel = base
        .tap(name: 'c.txt', ordered: ordered, mode: SftpSelectMode.range)
        .tap(name: 'd.txt', ordered: ordered, mode: SftpSelectMode.range);
    expect(sel.names, {'b.txt', 'c.txt', 'd.txt'});
    expect(sel.anchor, 'b.txt');
  });

  test('Shift 连选：锚点不在列表时退化为单选', () {
    final sel = SftpSelection.empty.tap(
      name: 'c.txt',
      ordered: ordered,
      mode: SftpSelectMode.range,
    );
    expect(sel.names, {'c.txt'});
    expect(sel.anchor, 'c.txt');
  });

  test('拖拽载荷：选区内行拖整个选区（按列表顺序），选区外行只拖自己', () {
    const sel = SftpSelection(names: {'d.txt', 'b.txt'}, anchor: 'b.txt');
    expect(sel.dragNames('b.txt', ordered), ['b.txt', 'd.txt']);
    expect(sel.dragNames('a.txt', ordered), ['a.txt']);
  });
}

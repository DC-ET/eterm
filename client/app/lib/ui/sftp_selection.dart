// SFTP 列表多选模型（按目录内唯一名保存）。
//
// 点击语义与 Finder / 资源管理器一致：
//   桌面单击        替换选区（只选该行）
//   Ctrl/⌘ 单击     切换该行（累加/取消）
//   Shift 单击      从锚点到该行连选（方向不限）
//   手机轻点        切换该行（触摸端没有修饰键，轻点即多选入口）
// 选区在切目录/刷新列表时整体清空（见 sftp_page 各导航函数），
// 因此这里不需要保留"已不在当前目录"的名字。

import 'package:flutter/foundation.dart';

/// 点击语义（由修饰键 / 平台决定）。
enum SftpSelectMode { replace, toggle, range }

/// 修饰键 → 点击语义。触摸端点轻即切换（多选入口）。
SftpSelectMode sftpSelectModeFor({
  required bool shift,
  required bool toggleKey,
  required bool touch,
}) {
  if (shift) return SftpSelectMode.range;
  if (toggleKey) return SftpSelectMode.toggle;
  return touch ? SftpSelectMode.toggle : SftpSelectMode.replace;
}

/// 不可变选区快照：[names] 为选中条目名，[anchor] 为 Shift 连选的锚点。
///
/// 所有变换方法返回新实例，UI 侧只做整体替换，避免半更新状态。
@immutable
class SftpSelection {
  const SftpSelection({this.names = const <String>{}, this.anchor});

  static const empty = SftpSelection();

  final Set<String> names;
  final String? anchor;

  bool get isEmpty => names.isEmpty;
  int get length => names.length;
  bool contains(String name) => names.contains(name);

  /// 点击某行后的新选区。[ordered] 为列表当前展示顺序（连选需要）。
  SftpSelection tap({
    required String name,
    required List<String> ordered,
    required SftpSelectMode mode,
  }) {
    switch (mode) {
      case SftpSelectMode.replace:
        return SftpSelection(names: {name}, anchor: name);
      case SftpSelectMode.toggle:
        final next = {...names};
        if (!next.remove(name)) next.add(name);
        return SftpSelection(names: next, anchor: name);
      case SftpSelectMode.range:
        final from = anchor == null ? -1 : ordered.indexOf(anchor!);
        final to = ordered.indexOf(name);
        // 锚点已不在列表（如右键换过选区）或列表未含该行：退化为单选
        if (from < 0 || to < 0) {
          return SftpSelection(names: {name}, anchor: name);
        }
        final lo = from <= to ? from : to;
        final hi = from <= to ? to : from;
        return SftpSelection(
          names: ordered.sublist(lo, hi + 1).toSet(),
          // 锚点保持不动：连续 Shift 点击可以继续以原锚点扩缩范围
          anchor: anchor,
        );
    }
  }

  /// 起拖行 → 实际拖动的条目名：行在选区内则拖整个选区，否则只拖该行。
  /// 结果按列表展示顺序返回（传输入队顺序与界面一致）。
  List<String> dragNames(String anchorName, List<String> ordered) {
    final picked = contains(anchorName) ? names : {anchorName};
    return [
      for (final n in ordered)
        if (picked.contains(n)) n,
    ];
  }
}

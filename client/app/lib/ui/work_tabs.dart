// 工作区标签（终端 / SFTP）共享模型。
//
// 设计要点（方案 §4.1 / §2.1.1）：
// - key 必须是 GlobalKey：IndexedStack 会把 child 包进无 key 的 offstage 容器，
//   内层 UniqueKey 无法跨“删除元素导致的位置移位”保 State，关中间/左侧标签会
//   重建右侧所有标签（终端重连；SFTP 丢浏览/队列）。
// - 标签只持有身份/规格/状态，不持有 socket；会话与队列仍归各页 State。
// - status 单一 notifier（phase + 传输计数），pill 只订阅它，避免 Shell 全量重建。

import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart';

import '../services/app_state.dart';

/// 工作区标签阶段（终端 3 态映射；SFTP 多远端侧聚合，允许 degraded）。
enum WorkTabPhase { connecting, live, degraded, closed }

enum WorkTabKind { terminal, sftp }

/// 标签状态快照。值相等：计数/阶段没变时不触发 pill 重建。
@immutable
class WorkTabStatus {
  const WorkTabStatus({
    this.phase = WorkTabPhase.connecting,
    this.activeTransfers = 0,
    this.failedTransfers = 0,
  });

  final WorkTabPhase phase;
  final int activeTransfers; // queued + running
  final int failedTransfers; // 失败待重试

  WorkTabStatus copyWith({
    WorkTabPhase? phase,
    int? activeTransfers,
    int? failedTransfers,
  }) => WorkTabStatus(
    phase: phase ?? this.phase,
    activeTransfers: activeTransfers ?? this.activeTransfers,
    failedTransfers: failedTransfers ?? this.failedTransfers,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkTabStatus &&
          other.phase == phase &&
          other.activeTransfers == activeTransfers &&
          other.failedTransfers == failedTransfers;

  @override
  int get hashCode => Object.hash(phase, activeTransfers, failedTransfers);
}

/// 一侧的规格：host == null 表示本机工作区。
///
/// 从 sftp_page.dart 迁到此处，避免 work_tabs ↔ sftp_page 循环依赖
/// （方案 D18）。
class SftpSideSpec {
  const SftpSideSpec({this.host, this.authKind, this.secret});
  final HostView? host;
  final String? authKind; // password | key
  final String? secret;
}

sealed class WorkTab {
  WorkTab({
    required this.key,
    required this.label,
    required this.kind,
    WorkTabPhase initialPhase = WorkTabPhase.connecting,
  }) : status = ValueNotifier(WorkTabStatus(phase: initialPhase));

  /// 标签内容 widget 的 key（TerminalTabView / SftpWorkspace）。
  /// 必须 GlobalKey；一个标签一个，标签关闭随 widget 销毁。
  final GlobalKey key;
  final String label;
  final WorkTabKind kind;

  /// notifier 不手动 dispose：与现有 TerminalTabView phase 同口径——widget
  /// 帧末才销毁，期间异步事件可能回写，手动 dispose 会 use-after-dispose。
  final ValueNotifier<WorkTabStatus> status;
}

class TerminalWorkTab extends WorkTab {
  TerminalWorkTab({
    required super.key,
    required this.host,
    required this.authKind,
    required this.secret,
  }) : super(
         label: host.label,
         kind: WorkTabKind.terminal,
       );

  final HostView host;
  final String authKind; // password | key
  final String secret;
  final Terminal terminal = Terminal(maxLines: 20000);
}

class SftpWorkTab extends WorkTab {
  SftpWorkTab({
    required super.key,
    required this.left,
    required this.right,
  }) : dedupeKey = sftpPairKey(left, right),
       super(
         label: '${left.host?.label ?? '本机'} ⇄ ${right.host?.label ?? '本机'}',
         kind: WorkTabKind.sftp,
       );

  final SftpSideSpec left;
  final SftpSideSpec right;
  final String dedupeKey;
}

/// 无序端点对：A⇄B 与 B⇄A 视为同一标签；本机归一为 local。
String sftpPairKey(SftpSideSpec a, SftpSideSpec b) {
  final x = a.host?.id ?? 'local';
  final y = b.host?.id ?? 'local';
  return x.compareTo(y) <= 0 ? '$x|$y' : '$y|$x';
}

/// SFTP 阶段聚合（只统计远端侧；优先级 closed > degraded > live > connecting）。
WorkTabPhase aggregateSftpPhase({
  required int total,
  required int live,
  required int failed,
}) {
  if (total <= 0) return WorkTabPhase.live;
  if (failed == total) return WorkTabPhase.closed;
  if (failed > 0) return WorkTabPhase.degraded;
  if (live == total) return WorkTabPhase.live;
  return WorkTabPhase.connecting;
}
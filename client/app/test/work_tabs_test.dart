// WorkTab 模型单测：无序端点去重键、SFTP 阶段聚合、状态值相等（避免无谓重建）。

import 'package:eterm/services/app_state.dart';
import 'package:eterm/ui/work_tabs.dart';
import 'package:flutter_test/flutter_test.dart';

HostView _host(String id) => HostView(
  id: id,
  label: id,
  hostname: '$id.example.com',
  port: 22,
  username: 'u',
);

void main() {
  test('sftpPairKey：无序（A⇄B == B⇄A），本机归一 local', () {
    final a = SftpSideSpec(host: _host('a'));
    final b = SftpSideSpec(host: _host('b'));
    const local = SftpSideSpec();
    expect(sftpPairKey(a, b), sftpPairKey(b, a));
    expect(sftpPairKey(a, local), sftpPairKey(local, a));
    expect(sftpPairKey(a, local), 'a|local');
    expect(sftpPairKey(local, local), 'local|local');
    expect(sftpPairKey(a, b), isNot(sftpPairKey(a, local)));
  });

  test('aggregateSftpPhase：closed > degraded > live > connecting 优先级', () {
    expect(aggregateSftpPhase(total: 1, live: 0, failed: 0),
        WorkTabPhase.connecting);
    expect(aggregateSftpPhase(total: 2, live: 1, failed: 0),
        WorkTabPhase.connecting);
    expect(aggregateSftpPhase(total: 2, live: 2, failed: 0),
        WorkTabPhase.live);
    expect(aggregateSftpPhase(total: 2, live: 1, failed: 1),
        WorkTabPhase.degraded);
    expect(aggregateSftpPhase(total: 2, live: 0, failed: 2),
        WorkTabPhase.closed);
    // 无远端（纯本机）不阻塞标签
    expect(aggregateSftpPhase(total: 0, live: 0, failed: 0),
        WorkTabPhase.live);
  });

  test('WorkTabStatus：同值相等（notifier 不重复通知）、copyWith 生效', () {
    const a = WorkTabStatus(
      phase: WorkTabPhase.live,
      activeTransfers: 2,
      failedTransfers: 1,
    );
    const b = WorkTabStatus(
      phase: WorkTabPhase.live,
      activeTransfers: 2,
      failedTransfers: 1,
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a.copyWith(phase: WorkTabPhase.closed).phase, WorkTabPhase.closed);
    expect(a.copyWith(activeTransfers: 0).activeTransfers, 0);
    expect(
      a == const WorkTabStatus(phase: WorkTabPhase.live),
      isFalse,
      reason: '计数不同必须触发 pill 更新',
    );
  });
}

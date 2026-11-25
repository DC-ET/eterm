// 「最近访问」回归：设备本地记录（kv）→ Hosts 页按访问时间倒序展示、最多 10 个，
// 搜索/分组过滤时让位；打开终端/SFTP 的入口（shell）都会记录访问。

import 'package:eterm/services/api_client.dart';
import 'package:eterm/services/app_state.dart';
import 'package:eterm/ui/hosts_page.dart';
import 'package:eterm/ui/shell.dart';
import 'package:eterm/ui/ui_utils.dart';
import 'package:eterm/ui/work_tabs.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// 生成 n 台主机（h0..h{n-1}）+ 对应 identity/protocol。
Map<String, Map<String, dynamic>> _hostEntities(int n) {
  final out = <String, Map<String, dynamic>>{};
  for (var i = 0; i < n; i++) {
    final id = 'h$i';
    out['host/$id'] = {
      'id': id,
      'label': id,
      'hostname': '$id.example.com',
      'tags': <String>[],
      'group_id': null,
    };
    out['identity/i$i'] = {
      'id': 'i$i',
      'label': 'u',
      'username': 'u',
      'password_enc': 'pw',
      'key_id': null,
    };
    out['host_protocol/$id-p'] = {
      'id': '$id-p',
      'host_id': id,
      'kind': 'ssh',
      'config_json': {'port': 22, 'username': 'u', 'identity_id': 'i$i'},
      'sort': 0,
    };
  }
  return out;
}

/// pumpAndSettle + 清扫与断言无关的渲染/FFI 噪声。
Future<void> _pumpClean(WidgetTester tester) async {
  await tester.pumpAndSettle();
  while (tester.takeException() != null) {}
}

Widget _hostsPage(AppState app) => MaterialApp(
  home: Scaffold(
    body: HostsPage(
      app: app,
      onOpenTerminal: (_) {},
      openHostIds: const {},
      onOpenSettings: () {},
      onOpenSftp: (_) {},
    ),
  ),
);

void main() {
  group('AppState 最近访问', () {
    test('按访问时间倒序、最多 10 台，重新访问会置顶', () {
      final app = AppState(api: ApiClient(baseUrl: 'http://127.0.0.1:1'));
      app.debugSetEntities(_hostEntities(12));
      final base = DateTime(2026, 11, 25, 10);

      // 依次访问 h0..h11（h11 最新）
      for (var i = 0; i < 12; i++) {
        app.markHostVisited('h$i', at: base.add(Duration(minutes: i)));
      }
      var recents = app.recentHosts;
      expect(recents.length, AppState.recentHostsLimit);
      expect(recents.first.id, 'h11', reason: '最近访问的排最前');
      expect(recents.last.id, 'h2', reason: '只保留最近 10 台（h0/h1 被挤出）');

      // 再访问一次 h0 → 置顶
      app.markHostVisited('h0', at: base.add(const Duration(hours: 2)));
      recents = app.recentHosts;
      expect(recents.first.id, 'h0');
      expect(recents.length, 10, reason: '总数仍不超过 10');
      expect(
        recents.map((h) => h.id).toSet().contains('h1'),
        isFalse,
        reason: '最久未访问的 h1 被挤出',
      );
    });

    test('已删除主机不展示（只认当前同步下来的 hosts）', () {
      final app = AppState(api: ApiClient(baseUrl: 'http://127.0.0.1:1'));
      app.debugSetEntities(_hostEntities(3));
      final base = DateTime(2026, 11, 25, 10);
      for (var i = 0; i < 3; i++) {
        app.markHostVisited('h$i', at: base.add(Duration(minutes: i)));
      }
      expect(app.recentHosts.map((h) => h.id), ['h2', 'h1', 'h0']);

      // h2 从中枢删除（快照里没有它）
      final entities = _hostEntities(3)
        ..remove('host/h2')
        ..remove('identity/i2')
        ..remove('host_protocol/h2-p');
      app.debugSetEntities(entities);
      expect(app.recentHosts.map((h) => h.id), ['h1', 'h0']);
    });

    test('recentVisitedAt 返回访问时刻；markHostVisited 派发通知', () {
      final app = AppState(api: ApiClient(baseUrl: 'http://127.0.0.1:1'));
      app.debugSetEntities(_hostEntities(1));
      var notified = 0;
      app.addListener(() => notified++);

      final at = DateTime(2026, 11, 25, 9, 30);
      app.markHostVisited('h0', at: at);
      expect(app.recentVisitedAt('h0'), at);
      expect(app.recentVisitedAt('nope'), isNull);
      expect(notified, greaterThan(0), reason: 'Hosts 页依赖通知即时刷新');
    });
  });

  group('fmtRelativeTime', () {
    final now = DateTime(2026, 11, 25, 12);
    test('刚刚 / 分钟 / 小时 / 昨天 / 天 / 日期', () {
      expect(
        fmtRelativeTime(now.subtract(const Duration(seconds: 20)), now: now),
        '刚刚',
      );
      expect(
        fmtRelativeTime(now.subtract(const Duration(minutes: 5)), now: now),
        '5 分钟前',
      );
      expect(
        fmtRelativeTime(now.subtract(const Duration(hours: 3)), now: now),
        '3 小时前',
      );
      expect(
        fmtRelativeTime(now.subtract(const Duration(days: 1)), now: now),
        '昨天',
      );
      expect(
        fmtRelativeTime(now.subtract(const Duration(days: 3)), now: now),
        '3 天前',
      );
      expect(
        fmtRelativeTime(DateTime(2026, 10, 1, 8, 30), now: now),
        '2026-10-01',
      );
    });

    test('时钟回拨（未来时间）按"刚刚"，不出现负数', () {
      expect(
        fmtRelativeTime(now.add(const Duration(minutes: 10)), now: now),
        '刚刚',
      );
    });
  });

  testWidgets('桌面：最近访问模块按时间排序展示，搜索时隐藏', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final app = AppState(api: ApiClient(baseUrl: 'http://127.0.0.1:1'));
    app.debugSetEntities(_hostEntities(4));
    final base = DateTime(2026, 11, 25, 10);
    // h0 最旧 … h3 最新
    for (var i = 0; i < 4; i++) {
      app.markHostVisited('h$i', at: base.add(Duration(minutes: i)));
    }

    await tester.pumpWidget(_hostsPage(app));
    await _pumpClean(tester);

    expect(find.text('最近访问'), findsOneWidget);
    final x3 = tester
        .getTopLeft(find.byKey(const ValueKey('recent-host-h3')))
        .dx;
    final x2 = tester
        .getTopLeft(find.byKey(const ValueKey('recent-host-h2')))
        .dx;
    expect(x3, lessThan(x2), reason: '最近访问的 h3 应排在 h2 左边');

    // 搜索过滤态：最近访问模块让位（避免与匹配结果重复）
    await tester.enterText(find.byType(TextField).first, 'h1');
    await _pumpClean(tester);
    expect(find.text('最近访问'), findsNothing);
    expect(find.byKey(const ValueKey('recent-host-h3')), findsNothing);
  });

  testWidgets('手机（<720）：最近访问横向条可挂载', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final app = AppState(api: ApiClient(baseUrl: 'http://127.0.0.1:1'));
    app.debugSetEntities(_hostEntities(2));
    app.markHostVisited('h1', at: DateTime(2026, 11, 25, 11));
    app.markHostVisited('h0', at: DateTime(2026, 11, 25, 10));

    await tester.pumpWidget(_hostsPage(app));
    await _pumpClean(tester);

    expect(find.text('最近访问'), findsOneWidget);
    expect(find.byKey(const ValueKey('recent-host-h1')), findsOneWidget);
    expect(find.byKey(const ValueKey('recent-host-h0')), findsOneWidget);
  });

  testWidgets('shell 打开 SFTP 工作区即记录端点主机的最近访问', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final app = AppState(api: ApiClient(baseUrl: 'http://127.0.0.1:1'));
    app.debugSetEntities(_hostEntities(2));
    await tester.pumpWidget(
      MaterialApp(
        home: ShellPage(api: app.api, app: app, username: 'tester'),
      ),
    );
    await _pumpClean(tester);

    final shell = tester.state(find.byType(ShellPage)) as dynamic;
    shell.openSftp(
      left: SftpSideSpec(
        host: app.hosts.firstWhere((h) => h.id == 'h1'),
        authKind: 'password',
        secret: 'pw',
      ),
      right: const SftpSideSpec(), // 本机侧不记录
    );
    await _pumpClean(tester);

    expect(app.recentHosts.map((h) => h.id), ['h1']);
  });
}

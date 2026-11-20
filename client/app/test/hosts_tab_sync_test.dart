// 回归：切回 Hosts 标签不再闪浏览器式加载条 + 进度条槽位不顶动内容。
// 背景：shell 的 nav 内容槽一次只放一个页面，切页会把 HostsPage 整个卸载重装，
// 其 initState 里的 refresh() 于是每次切回都发一次非静默同步 → 顶部 2px
// LinearProgressIndicator 闪现，且插入 Column 时把下方内容顶下去（画面跳一下）。

import 'package:eterm/services/api_client.dart';
import 'package:eterm/services/app_state.dart';
import 'package:eterm/ui/hosts_page.dart';
import 'package:eterm/ui/settings_page.dart';
import 'package:eterm/ui/shell.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Map<String, dynamic>> _hostEntities(
        String id, String label, String identityId) =>
    {
      'host/$id': {
        'id': id,
        'label': label,
        'hostname': '$id.example.com',
        'tags': <String>[],
        'group_id': null,
      },
      'identity/$identityId': {
        'id': identityId,
        'label': 'u',
        'username': 'u',
        'password_enc': 'pw',
        'key_id': null,
      },
      'host_protocol/$id-p': {
        'id': '$id-p',
        'host_id': id,
        'kind': 'ssh',
        'config_json': {'port': 22, 'username': 'u', 'identity_id': identityId},
        'sort': 0,
      },
    };

/// pumpAndSettle + 清扫与被测逻辑无关的渲染噪声（同 code_review_bugs_test）。
Future<void> _pumpClean(WidgetTester tester) async {
  await tester.pumpAndSettle();
  while (tester.takeException() != null) {}
}

/// 固定帧推进 + 清异常。有 LinearProgressIndicator 在场时 pumpAndSettle 会因
/// 其无限动画一直不收敛，故不能用 _pumpClean。
Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    while (tester.takeException() != null) {}
  }
}

void main() {
  test('refresh(silent) 不翻 loading，失败仍会派发', () async {
    // 测试环境无 Rust FFI：storeCursor 抛错 → 走 catch/finally，同步快速收敛
    final app = AppState(api: ApiClient(baseUrl: 'http://127.0.0.1:1'));
    var notified = 0;
    app.addListener(() => notified++);

    final f = app.refresh(silent: true);
    expect(app.loading, isFalse, reason: '静默同步不得置位 loading（否则闪加载条）');
    await f;

    expect(app.loading, isFalse);
    expect(app.syncedOnce, isTrue);
    expect(notified, greaterThan(0), reason: 'finally 必须派发，失败横幅才能显示');
    expect(app.error, isNotNull, reason: '同步失败应记录错误');
  });

  test('refresh() 非静默仍会翻 loading 并回落', () async {
    final app = AppState(api: ApiClient(baseUrl: 'http://127.0.0.1:1'));

    final f = app.refresh();
    expect(app.loading, isTrue, reason: '冷启动首屏需要同步指示');
    await f;
    expect(app.loading, isFalse);
  });

  testWidgets('切走再切回 Hosts 标签：不置位 loading、不出现加载条', (tester) async {
    tester.view.physicalSize = const Size(1280, 800); // 桌面布局（带标题栏）
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final app = AppState(api: ApiClient(baseUrl: 'http://127.0.0.1:1'));
    app.debugSetEntities(_hostEntities('h1', 'alpha', 'i1'));

    await tester.pumpWidget(
      MaterialApp(home: ShellPage(api: app.api, app: app, username: 'tester')),
    );
    // 等冷启动那次非静默同步收敛（syncedOnce 置位）
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      while (tester.takeException() != null) {}
    }
    expect(app.syncedOnce, isTrue);
    expect(app.loading, isFalse);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    final shell = tester.state(find.byType(ShellPage)) as dynamic;

    // 切到 Settings 再切回 Hosts：HostsPage 被卸载重装，initState 再次 refresh
    shell.setState(() => shell.navIndex = 6);
    await _pumpClean(tester);
    expect(find.byType(SettingsPage), findsOneWidget);

    shell.setState(() => shell.navIndex = 0);
    await _pumpClean(tester);
    expect(find.byType(HostsPage), findsOneWidget);

    expect(app.loading, isFalse,
        reason: '已同步过一次，切回 Hosts 必须静默对账，不得闪加载条');
    expect(find.byType(LinearProgressIndicator), findsNothing,
        reason: '静默同步期间不应渲染顶部加载条');
  });

  testWidgets('进度条 2px 槽位常驻：加载中出现/消失不顶动内容', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final app = AppState(api: ApiClient(baseUrl: 'http://127.0.0.1:1'));
    app.debugSetEntities(_hostEntities('h1', 'alpha', 'i1'));

    await tester.pumpWidget(
      MaterialApp(home: ShellPage(api: app.api, app: app, username: 'tester')),
    );
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      while (tester.takeException() != null) {}
    }

    final body = find.byType(IndexedStack);
    final idle = tester.getTopLeft(body);

    // 手动把 loading 置起来（等价于一次非静默同步进行中）
    app.loading = true;
    app.notifyListeners();
    await _pumpFrames(tester);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    final busy = tester.getTopLeft(body);
    expect(busy, idle,
        reason: '进度条必须占常驻槽位，出现时不得把下方内容顶下去');

    app.loading = false;
    app.notifyListeners();
    await _pumpFrames(tester);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.getTopLeft(body), idle, reason: '同步结束后内容应回到原位');
  });
}

// 代码评审 bug 回归用例（docs/code-review/2026-11-15-逻辑bug评审.md）。
// BUG-D1（手机底栏缺 Known Hosts 入口）/ BUG-D2（closeTab 左侧标签错位）
// 均已修复；本文件作为回归测试常驻运行。
// 注：测试环境无 Rust FFI，HostsPage.initState→refresh 的网络/环境异常与被测逻辑无关，
// 用例内逐帧 pump + takeException 清扫（同时缓解 initState 内同步 notifyListeners 的
// 首帧 build 中断，见评审文档"附加观察"1）。

import 'package:eterm/services/api_client.dart';
import 'package:eterm/services/app_state.dart';
import 'package:eterm/ui/shell.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一台带 SSH 凭据的主机三件套（host + identity + host_protocol）。
Map<String, Map<String, dynamic>> _hostEntities(String id, String label, String identityId) => {
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

/// pumpAndSettle + 清扫与被测逻辑无关的渲染噪声
/// （测试环境 Ahem 字体下中文文案会触发 RenderFlex overflow 等布局断言）。
Future<void> _pumpClean(WidgetTester tester) async {
  await tester.pumpAndSettle();
  while (tester.takeException() != null) {}
}

void main() {
  testWidgets(
    'BUG-D1 回归: 手机底栏含 Known Hosts 入口且可进入该页',
    (tester) async {
      tester.view.physicalSize = const Size(500, 800); // 手机竖屏
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final app = AppState(api: ApiClient(baseUrl: 'http://127.0.0.1:1'));
      app.debugSetEntities(_hostEntities('h1', 'alpha', 'i1'));
      await tester.pumpWidget(
        MaterialApp(home: ShellPage(api: app.api, app: app, username: 'tester')),
      );
      final shell = tester.state(find.byType(ShellPage)) as dynamic;
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        while (tester.takeException() != null) {}
      }

      final bar = find.byType(NavigationBar);
      expect(bar, findsOneWidget, reason: 'compact 布局应有底部导航');
      final labels = tester
          .widget<NavigationBar>(bar)
          .destinations
          .cast<NavigationDestination>()
          .map((d) => d.label)
          .toList();
      debugPrint('BUG-D1 回归: 手机底栏入口 = $labels');

      // 底栏必须含 Known Hosts 入口（F4.4，PRD P0）
      expect(find.text('Known Hosts'), findsOneWidget,
          reason: '手机底栏必须包含 Known Hosts 入口，否则 compact 布局不可达');

      // 点入后路由切到侧栏 navIndex 3（KnownHostsPage）。
      // 页面实体渲染依赖本地库 FFI，测试环境（无 Rust）下 KnownHostsPage.initState 的
      // 错误路径会在 mount 中 setState（见评审"附加观察"1），故此处断言路由接线。
      await tester.tap(find.text('Known Hosts'));
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        while (tester.takeException() != null) {}
      }
      expect(shell.navIndex, 3, reason: '点入 Known Hosts 底栏项应切到 Known Hosts 页');
    },
  );

  testWidgets(
    'BUG-D2 回归: 关闭当前查看标签左侧的标签后仍查看同一会话',
    (tester) async {
      tester.view.physicalSize = const Size(900, 700); // 桌面布局（带标题栏标签）
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final app = AppState(api: ApiClient(baseUrl: 'http://127.0.0.1:1'));
      final entities = <String, Map<String, dynamic>>{};
      entities.addAll(_hostEntities('h1', 'alpha', 'i1'));
      entities.addAll(_hostEntities('h2', 'beta', 'i2'));
      entities.addAll(_hostEntities('h3', 'gamma', 'i3'));
      app.debugSetEntities(entities);

      await tester.pumpWidget(
        MaterialApp(home: ShellPage(api: app.api, app: app, username: 'tester')),
      );
      await _pumpClean(tester);

      final shell = tester.state(find.byType(ShellPage)) as dynamic;
      final hosts = app.hosts;
      shell.openTerminal(hosts[0]); // alpha → activeTab=0
      await _pumpClean(tester);
      shell.openTerminal(hosts[1]); // beta → activeTab=1
      await _pumpClean(tester);
      shell.openTerminal(hosts[2]); // gamma → activeTab=2
      await _pumpClean(tester);
      expect(shell.activeTab, 2);

      // 切到中间标签 beta（与点标题栏 pill 等价：onSelectTab(1) → activeTab=1）
      shell.setState(() {
        shell.activeTab = 1;
      });
      await _pumpClean(tester);
      expect(shell.activeTab, 1);

      // 关闭位于当前查看标签（beta）左侧的 alpha：激活索引应左移一位，仍显示 beta 会话
      shell.closeTab(0);
      await _pumpClean(tester);
      debugPrint('BUG-D2 回归: closeTab(0) 后 activeTab = ${shell.activeTab}（期望 0，即仍查看 beta）');
      expect(shell.activeTab, 0, reason: '关闭左侧标签后应保持查看原会话（beta），不得跳到 gamma');
    },
  );
}

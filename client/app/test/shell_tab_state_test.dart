// M0 回归：关闭中间/左侧终端标签后，其余标签的 State 必须原样保留。
// 背景：IndexedStack 会把 child 包进无 key 的 offstage 容器，内层 UniqueKey
// 无法跨位置移位保 State；必须 GlobalKey（方案 §2.1.1 / D12）。
// 测试环境无 Rust FFI，TerminalTabView 连接会进入 failed 态；这不影响 State
// identity 断言（正是我们要保活的对象）。

import 'package:eterm/services/api_client.dart';
import 'package:eterm/services/app_state.dart';
import 'package:eterm/ui/shell.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Map<String, dynamic>> _hostEntities(
  String id,
  String label,
  String identityId,
) => {
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

Future<void> _pumpClean(WidgetTester tester) async {
  await tester.pumpAndSettle();
  while (tester.takeException() != null) {}
}

void main() {
  testWidgets('关中间/左侧标签后其余终端 State identity 不变', (tester) async {
    tester.view.physicalSize = const Size(900, 700); // 桌面布局（标题栏标签）
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
    shell.openTerminal(hosts[0]);
    await _pumpClean(tester);
    shell.openTerminal(hosts[1]);
    await _pumpClean(tester);
    shell.openTerminal(hosts[2]);
    await _pumpClean(tester);

    final tabs = shell.tabs as List<dynamic>;
    expect(tabs.length, 3);
    final k0 = tabs[0].key as GlobalKey;
    final k2 = tabs[2].key as GlobalKey;

    final s0 = tester.state(find.byKey(k0, skipOffstage: false));
    final s2 = tester.state(find.byKey(k2, skipOffstage: false));

    // 关中间 beta：gamma 的 State 必须还是同一个（UniqueKey 会在这里失败）
    shell.closeTab(1);
    await _pumpClean(tester);
    expect(
      identical(tester.state(find.byKey(k0, skipOffstage: false)), s0),
      isTrue,
      reason: 'alpha 在关闭右侧标签后不应重建',
    );
    expect(
      identical(tester.state(find.byKey(k2, skipOffstage: false)), s2),
      isTrue,
      reason: 'gamma 在关闭左侧标签后不应重建（P0）',
    );

    // 再关最左 alpha：gamma 仍必须保活
    shell.closeTab(0);
    await _pumpClean(tester);
    expect(
      identical(tester.state(find.byKey(k2, skipOffstage: false)), s2),
      isTrue,
      reason: 'gamma 在关闭左侧标签后不应重建（P0）',
    );
  });
}
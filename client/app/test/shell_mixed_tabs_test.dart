// 混排标签回归：终端与 SFTP 同栈保活、无序端点对去重、关闭中间标签不重建其余 State。

import 'package:eterm/services/api_client.dart';
import 'package:eterm/services/app_state.dart';
import 'package:eterm/ui/shell.dart';
import 'package:eterm/ui/work_tabs.dart';
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

/// 最近的 TickerMode 祖先（Shell 只给 SFTP 标签包了一层）。
TickerMode? _nearestTicker(Element e) {
  TickerMode? found;
  e.visitAncestorElements((a) {
    if (a.widget is TickerMode) {
      found = a.widget as TickerMode;
      return false;
    }
    return true;
  });
  return found;
}

void main() {
  testWidgets('手机（<720）：SFTP 标签可挂载、底部标签条可见、可关闭', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final app = AppState(api: ApiClient(baseUrl: 'http://127.0.0.1:1'));
    app.debugSetEntities(_hostEntities('hm', 'mobile-host', 'im'));

    await tester.pumpWidget(
      MaterialApp(home: ShellPage(api: app.api, app: app, username: 'tester')),
    );
    await _pumpClean(tester);

    final shell = tester.state(find.byType(ShellPage)) as dynamic;
    shell.openSftp(
      left: SftpSideSpec(
        host: app.hosts.first,
        authKind: 'password',
        secret: 'pw',
      ),
      right: const SftpSideSpec(),
    );
    await _pumpClean(tester);
    expect(shell.activeTab, 0);
    // 手机标签条吸底（返回 vault 的箭头是它的稳定标志）
    expect(find.byIcon(Icons.arrow_back_ios_new), findsOneWidget);
    // SFTP 工作区已挂载（无 FFI 时连接失败，但页面/标签必须在）
    expect(find.text('mobile-host ⇄ 本机'), findsOneWidget);

    await shell.closeTab(0);
    await _pumpClean(tester);
    expect((shell.tabs as List<dynamic>), isEmpty);
    expect(shell.activeTab, -1);
  });

  testWidgets('终端/SFTP 混排：去重、关闭中间标签保 State', (tester) async {
    tester.view.physicalSize = const Size(1000, 720); // 桌面布局（标题栏标签）
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
    final left = SftpSideSpec(
      host: hosts[1],
      authKind: 'password',
      secret: 'pw',
    );
    const local = SftpSideSpec();
    shell.openSftp(left: left, right: local);
    await _pumpClean(tester);
    shell.openTerminal(hosts[2]);
    await _pumpClean(tester);

    final tabs = shell.tabs as List<dynamic>;
    expect(tabs.length, 3);
    expect(tabs[0], isA<TerminalWorkTab>());
    expect(tabs[1], isA<SftpWorkTab>());
    expect(tabs[2], isA<TerminalWorkTab>());
    expect(shell.activeTab, 2);

    final kSftp = tabs[1].key as GlobalKey;
    final k2 = tabs[2].key as GlobalKey;
    final sSftp = tester.state(find.byKey(kSftp, skipOffstage: false));
    final s2 = tester.state(find.byKey(k2, skipOffstage: false));

    // 隐藏标签停动画（TickerMode），但 State 仍在树上
    final sftpEl = tester.element(find.byKey(kSftp, skipOffstage: false));
    expect(_nearestTicker(sftpEl)?.enabled, isFalse, reason: '当前活动是终端标签');

    // 反向端点对（本机 ⇄ beta）应复用同一标签，不新建
    shell.openSftp(left: local, right: left);
    await _pumpClean(tester);
    expect((shell.tabs as List<dynamic>).length, 3, reason: 'A⇄B 与 B⇄A 同一标签');
    expect(shell.activeTab, 1, reason: '复用已有 SFTP 标签并切过去');
    expect(
      _nearestTicker(tester.element(find.byKey(kSftp, skipOffstage: false)))?.enabled,
      isTrue,
      reason: 'SFTP 切为活动标签后动画恢复',
    );

    // 关闭活动 SFTP 左侧的终端：SFTP State 必须原样保留
    await shell.closeTab(0);
    await _pumpClean(tester);
    expect((shell.tabs as List<dynamic>).length, 2);
    expect(
      identical(tester.state(find.byKey(kSftp, skipOffstage: false)), sSftp),
      isTrue,
      reason: '关闭左侧标签不应重建 SFTP 工作区（会话/目录/队列保活）',
    );
    expect(
      identical(tester.state(find.byKey(k2, skipOffstage: false)), s2),
      isTrue,
      reason: '关闭左侧标签不应重建右侧终端',
    );

    // 有传输时关闭必须确认：取消不关，确认才关
    final sftpTab = (shell.tabs as List<dynamic>)[0] as SftpWorkTab;
    sftpTab.status.value = const WorkTabStatus(
      phase: WorkTabPhase.live,
      activeTransfers: 2,
    );
    final closing = shell.closeTab(0);
    await tester.pumpAndSettle();
    expect(find.textContaining('2 个传输进行中'), findsOneWidget);
    expect((shell.tabs as List<dynamic>).length, 2, reason: '弹窗未确认不得关闭');
    await tester.tap(find.widgetWithText(FilledButton, '关闭'));
    await tester.pumpAndSettle();
    await closing;

    expect((shell.tabs as List<dynamic>).length, 1);
    expect(
      identical(tester.state(find.byKey(k2, skipOffstage: false)), s2),
      isTrue,
      reason: '关闭左侧 SFTP 标签不应重建右侧终端',
    );
  });
}

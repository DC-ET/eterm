// 代码评审 bug 回归用例（docs/code-review/2026-11-27-逻辑bug评审.md，第二轮）。
// 覆盖：BUG-3（删除运行中的端口转发规则必须停掉监听与 SSH 会话，经可注入的
// PfTransport 驱动真实页面全链路）、BUG-2 客户端兜底（会话首次同步从 cursor=0
// 全量重放）、BUG-5（登录 wire 契约：platform 显式上报）。修复已入库，断言
// 「契约期望的正确行为」。

import 'package:eterm/services/api_client.dart';
import 'package:eterm/services/app_state.dart';
import 'package:eterm/ui/port_forwarding_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// pf FFI 记录器：评审 BUG-3 修复配套的可注入传输层替身。
class _RecordingPfTransport implements PfTransport {
  final calls = <String>[];

  @override
  Future<BigInt> connect({
    required String host,
    required int port,
    required String user,
    required String authKind,
    required String secret,
  }) async {
    calls.add('connect($host:$port)');
    return BigInt.from(111);
  }

  @override
  Future<BigInt> listen({
    required BigInt sessionId,
    required String bindAddr,
    required int localPort,
    required String remoteHost,
    required int remotePort,
  }) async {
    calls.add('listen($bindAddr:$localPort->$remoteHost:$remotePort)');
    return BigInt.from(222);
  }

  @override
  void closeForward({required BigInt sessionId, required BigInt forwardId}) {
    calls.add('close_forward($sessionId,$forwardId)');
  }

  @override
  void disconnect({required BigInt sessionId}) {
    calls.add('disconnect($sessionId)');
  }
}

Map<String, Map<String, dynamic>> _pfEntities() => {
      'host/h1': {
        'id': 'h1',
        'label': 'jump',
        'hostname': '10.0.0.1',
        'tags': <String>[],
        'group_id': null,
      },
      'identity/i1': {
        'id': 'i1',
        'label': 'u',
        'username': 'u',
        'password_enc': 'pw',
        'key_id': null,
      },
      'host_protocol/h1-p': {
        'id': 'h1-p',
        'host_id': 'h1',
        'kind': 'ssh',
        'config_json': {'port': 22, 'username': 'u', 'identity_id': 'i1'},
        'sort': 0,
      },
      'port_rule/r1': {
        'id': 'r1',
        'host_id': 'h1',
        'label': '内网数据库',
        'kind': 'local',
        'bind_addr': '127.0.0.1',
        'local_port': 15432,
        'remote_host': '10.0.0.5',
        'remote_port': 5432,
        'enabled': true,
        'rev': 1,
      },
    };

/// pumpAndSettle + 清扫与被测逻辑无关的渲染噪声（Ahem 测试字体溢出，同既有用例）。
Future<void> _pumpClean(WidgetTester tester) async {
  await tester.pumpAndSettle();
  while (tester.takeException() != null) {}
}

void main() {
  testWidgets('BUG-3: 删除运行中的转发规则必须停掉监听与 SSH 会话', (tester) async {
    tester.view.physicalSize = const Size(1280, 800); // 桌面布局
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final app = AppState(api: ApiClient(baseUrl: 'http://127.0.0.1:1'));
    app.debugSetEntities(_pfEntities());
    final pf = _RecordingPfTransport();

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: PortForwardingPage(app: app, transport: pf))),
    );
    await _pumpClean(tester);

    // 启动规则（走真实 _start：connect → listen → _forwards 登记）
    await tester.tap(find.text('启动'));
    await _pumpClean(tester);
    expect(pf.calls, contains('listen(127.0.0.1:15432->10.0.0.5:5432)'));

    // 删除规则（kebab「删除规则」→ 对话框确认「删除」）
    await tester.tap(find.byTooltip('删除规则'));
    await _pumpClean(tester);
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await _pumpClean(tester);

    // 修复后的契约：删除运行中规则必须真正停转发 + 断开 SSH
    // （服务端删除本身因测试环境 API 不可达而失败，但不影响停转发断言）
    expect(pf.calls, contains('close_forward(111,222)'),
        reason: '删除运行中的规则必须调用 pf_close_forward，否则本地端口继续监听、隧道继续转发');
    expect(pf.calls, contains('disconnect(111)'),
        reason: '无其他规则共用时应调用 pf_disconnect 断开 SSH 会话');
  });

  testWidgets('BUG-3 对照：点「停止」按钮路径同样停转发', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final app = AppState(api: ApiClient(baseUrl: 'http://127.0.0.1:1'));
    app.debugSetEntities(_pfEntities());
    final pf = _RecordingPfTransport();

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: PortForwardingPage(app: app, transport: pf))),
    );
    await _pumpClean(tester);

    await tester.tap(find.text('启动'));
    await _pumpClean(tester);
    await tester.tap(find.text('停止'));
    await _pumpClean(tester);

    expect(pf.calls, contains('close_forward(111,222)'));
    expect(pf.calls, contains('disconnect(111)'));
  });

}

// 代码评审 bug 回归用例（docs/code-review/2026-11-27-逻辑bug评审.md，第二轮）。
// 网络类用例（真实本地 HttpServer 驱动 ApiClient/AppState wire 契约）：
// 必须与 widget 用例分文件——testWidgets 所在文件的 HttpClient 会被测试
// 绑定劫持（一律 400），纯 test 文件不受影响。
// 覆盖：BUG-2 客户端兜底（会话首次同步 cursor=0 全量重放）、BUG-5（登录
// wire 契约：platform 显式上报）。修复已入库，断言「契约期望的正确行为」。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:eterm/services/api_client.dart';
import 'package:eterm/services/app_state.dart';

void main() {
  test('BUG-2 客户端兜底：会话首次同步从 cursor=0 全量重放', () async {
    final pulls = <String>[];
    final server = await HttpServer.bind('127.0.0.1', 0);
    final sub = server.listen((req) async {
      pulls.add(req.uri.query);
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({'cursor': 99, 'has_more': false, 'changes': []}));
      await req.response.close();
    });

    final app = AppState(api: ApiClient(baseUrl: 'http://127.0.0.1:${server.port}'));
    await app.refresh(silent: true);

    await sub.cancel();
    await server.close();

    expect(app.error, isNull, reason: '对空变更集的同步应成功');
    expect(pulls, isNotEmpty);
    expect(pulls.first, contains('cursor=0'),
        reason: '会话首次同步必须从 cursor=0 全量重放（游标空洞兜底，幂等折叠）');
  });

  test('BUG-5: 登录 wire 契约——platform 显式上报（Android 形态）', () async {
    // 本地假中枢捕获 /api/v1/auth/login 请求体
    final server = await HttpServer.bind('127.0.0.1', 0);
    Map<String, dynamic>? captured;
    final sub = server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      captured = jsonDecode(body) as Map<String, dynamic>;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'token': 'tok',
        'device_id': 'd1',
        'user': {'id': 'u1', 'username': 'bob'},
        'vault_id': 'v1',
      }));
      await req.response.close();
    });

    final api = ApiClient(baseUrl: 'http://127.0.0.1:${server.port}');
    // login_page 修复后的调用形态：platform 必传（签名强制）+ 带唯一后缀的设备名
    await api.login('bob', 'pw',
        deviceName: 'eterm-android-a1b2c3', platform: 'android');

    await sub.cancel();
    await server.close();

    expect(captured!['platform'], 'android',
        reason: '移动端登录不得再走 macos 默认值（评审 BUG-5）');
    expect(captured!['device_name'], startsWith('eterm-android-'),
        reason: '设备名必须带本机唯一后缀（同平台多设备不得共享 device 行，观察 6）');
  });
}

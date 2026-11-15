// Snippets（M2）视图逻辑回归：script 实体折叠 + 排序；非 snippet 实体不混入。

import 'package:eterm/services/api_client.dart';
import 'package:eterm/services/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('snippets 视图：仅折叠含 script 键的实体，名称不区分大小写排序', () {
    final app = AppState(api: ApiClient(baseUrl: 'http://127.0.0.1:1'));
    app.debugSetEntities({
      'snippet/s2': {
        'id': 's2',
        'description': '查看磁盘',
        'script': 'df -h',
        'package_id': null,
        'target_host_ids': <String>[],
        'vars_json': null,
        'rev': 3,
      },
      'snippet/s1': {
        'id': 's1',
        'description': 'cleanup',
        'script': 'rm -rf /tmp/x',
        'package_id': null,
        'target_host_ids': <String>[],
        'vars_json': null,
        'rev': 1,
      },
      // 非 snippet 实体不得混入
      'host/h1': {'id': 'h1', 'label': 'alpha', 'hostname': 'a.example.com'},
    });
    final list = app.snippets;
    expect(list.length, 2, reason: '只有 snippet 实体进入视图');
    expect(list.map((s) => s.description).toList(), ['cleanup', '查看磁盘'],
        reason: '不区分大小写字典序');
    expect(list[0].script, 'rm -rf /tmp/x');
  });

  test('snippets 视图：空 vault 返回空列表', () {
    final app = AppState(api: ApiClient(baseUrl: 'http://127.0.0.1:1'));
    app.debugSetEntities({});
    expect(app.snippets, isEmpty);
  });
}

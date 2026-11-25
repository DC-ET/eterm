// 回归：编辑页 initState 的首次加载不能被「phase == loading 防重入」挡掉。
// 无 Rust FFI 时 stat 立即失败，页面必须落到 failed（显示重试），而不是永远
// 停在 loading 转圈。

import 'package:eterm/ui/sftp_edit_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('首次进入会发起加载，失败后显示重试而不是卡 loading', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SftpEditPage(
          hostLabel: 'h',
          sessionId: () => BigInt.one,
          remotePath: '/tmp/a.txt',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    while (tester.takeException() != null) {}

    expect(find.text('重试'), findsOneWidget);
    expect(find.text('读取中…'), findsNothing, reason: '首次加载必须真正执行');
  });
}

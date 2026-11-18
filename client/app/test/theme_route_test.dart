// 复现 app 实况：home(_Boot) → pushReplacement(MaterialPageRoute) 后切主题，
// 验证 pushed 路由是否随根 ListenableBuilder → MaterialApp 重建而重建。
import 'package:eterm/ui/theme.dart';
import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

class _Probe extends StatelessWidget {
  const _Probe({this.tag = 'home'});
  final String tag;
  @override
  Widget build(BuildContext context) {
    // ignore: avoid_print
    print('PROBE build: $tag');
    return mui.Text(mui.Theme.of(context).brightness.toString());
  }
}

void main() {
  testWidgets('pushed 路由随主题切换重建', (tester) async {
    final c = ThemeController.instance;
    await tester.pumpWidget(
      ListenableBuilder(
        listenable: c,
        builder: (context, _) => mui.MaterialApp(
          theme: buildM3Theme(kLightPalette),
          darkTheme: buildM3Theme(kDarkPalette),
          themeMode: c.materialMode,
          home: _Probe(),
        ),
      ),
    );
    expect(find.text('Brightness.light'), findsOneWidget);

    // 模拟 _Boot:pushReplacement → ShellPage
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.pushReplacement(MaterialPageRoute(builder: (_) => const _Probe(tag: 'pushed')));
    await tester.pumpAndSettle();

    // 切深色：pushed 路由必须重建出 dark
    await c.setMode(AppThemeMode.dark);
    await tester.pumpAndSettle();
    expect(find.text('Brightness.dark'), findsOneWidget);
  });
}

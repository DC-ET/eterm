// 主题切换级联的 widget 测试：复刻 main.dart 结构（ListenableBuilder →
// material_ui.MaterialApp），notify 后应切换到 darkTheme。
import 'package:eterm/ui/theme.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

class _Probe extends StatelessWidget {
  const _Probe();
  @override
  Widget build(BuildContext context) =>
      mui.Text(mui.Theme.of(context).brightness.toString());
}

void main() {
  // 控制器 load() 读 kv 失败（无 FFI）→ system；测试直接 setMode。
  testWidgets('setMode(dark) 后 MaterialApp 切到 darkTheme', (tester) async {
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

    await c.setMode(AppThemeMode.dark);
    await tester.pumpAndSettle();
    expect(find.text('Brightness.dark'), findsOneWidget);

    await c.setMode(AppThemeMode.light);
    await tester.pumpAndSettle();
    expect(find.text('Brightness.light'), findsOneWidget);
  });

  testWidgets('Et 静态令牌随模式切换', (tester) async {
    final c = ThemeController.instance;
    await c.setMode(AppThemeMode.dark);
    expect(Et.palette, same(kDarkPalette));
    expect(Et.card, kDarkPalette.card);
    await c.setMode(AppThemeMode.light);
    expect(Et.palette, same(kLightPalette));
  });
}

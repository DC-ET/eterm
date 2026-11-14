// eterm 客户端（M0.5）：Termius 式桌面壳——自绘标题栏、侧边导航、浅色主题。
// Rust 侧经 frb 提供 SSH 会话与字段加解密（crate rust_lib_eterm）。

import 'package:eterm/src/rust/frb_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

import 'ui/login_page.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  await windowManager.ensureInitialized();
  const opts = WindowOptions(
    size: Size(1280, 800),
    minimumSize: Size(960, 640),
    titleBarStyle: TitleBarStyle.hidden, // macOS：交通灯保留、标题栏自绘
    windowButtonVisibility: true,
  );
  await windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  runApp(const EtermApp());
}

class EtermApp extends StatelessWidget {
  const EtermApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'eterm',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Et.accent,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: Et.contentBg,
        fontFamilyFallback: const ['PingFang SC', 'Helvetica Neue'],
      ),
      home: const LoginPage(),
    );
  }
}

// eterm 客户端（M0 骨架）：登录 → Host 列表 → 终端。
// Rust 侧经 frb 提供 SSH 会话与字段加解密（crate rust_lib_eterm）。

import 'package:eterm/src/rust/frb_generated.dart';
import 'package:material_ui/material_ui.dart';

import 'ui/login_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const EtermApp());
}

class EtermApp extends StatelessWidget {
  const EtermApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'eterm',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const LoginPage(),
    );
  }
}

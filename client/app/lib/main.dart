// eterm 客户端（M1）：Termius 式桌面壳 + 本地 working set。
// 启动流程：frb 初始化 → init_core（sqlite+钥匙串）→ 恢复会话 →
//   有会话：/me 探活（离线也放行，靠本地快照渲染）→ ShellPage；
//   无会话/探活 401：登录页。
// Rust 侧经 frb 提供 SSH 会话、字段加解密与本地库（crate rust_lib_eterm）。

import 'dart:io' show Platform;

import 'package:eterm/src/rust/api/local.dart' as local;
import 'package:eterm/src/rust/frb_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
// 0.7.0 重写为 nativeapi；旧 API（windowManager/WindowOptions）在 legacy.dart
import 'package:window_manager/legacy.dart';

import 'services/api_client.dart';
import 'services/app_state.dart';
import 'ui/login_page.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  // 窗口管理仅桌面端（window_manager 无 Android 实现，移动端跳过）
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
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
  }
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
      home: const _Boot(),
    );
  }
}

/// 启动引导页：初始化本地库并恢复会话，决定进登录页还是主壳。
class _Boot extends StatefulWidget {
  const _Boot();

  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> {
  String? _note;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final dir = await getApplicationSupportDirectory();
      local.initCore(dataDir: dir.path);
    } catch (e) {
      setState(() => _note = '本地库初始化失败: $e');
    }
    if (!mounted) return;
    List<String> sess;
    try {
      sess = local.restoreSession(); // [server, token, username]
    } catch (_) {
      local.clearLocal(); // 本地密文损坏（如密钥更替）：弃本地快照重新登录
      sess = const [];
    }
    if (sess.length < 2) {
      _go(const LoginPage());
      return;
    }
    final api = ApiClient(baseUrl: sess[0])..token = sess[1];
    final app = AppState(api: api);
    await app.bootstrap(); // 本地快照（离线可见）
    var username = sess.length >= 3 && sess[2].isNotEmpty ? sess[2] : '';
    try {
      username = await api.me(); // 在线则校验 token 并取最新用户名
      local.kvPut(key: 'username', value: username);
    } on ApiException catch (e) {
      if (e.status == 401) {
        local.clearLocal();
        _go(const LoginPage());
        return;
      }
      // 网络不可达：离线进入（本地快照渲染）
      if (mounted) setState(() => _note = '离线模式');
    } catch (_) {
      // 离线进入
    }
    if (!mounted) return;
    _go(ShellPage(api: api, app: app, username: username));
  }

  void _go(Widget page) {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Et.contentBg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('eterm',
                style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: Et.textPrimary)),
            const SizedBox(height: 12),
            if (_note != null)
              Text(_note!,
                  style: const TextStyle(fontSize: 12, color: Et.textSecondary))
            else
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
      ),
    );
  }
}

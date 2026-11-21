// eterm 客户端（M1）：Termius 式桌面壳 + 本地 working set。
// 启动流程：frb 初始化 → init_core（sqlite+钥匙串）→ 恢复会话 →
//   有会话：/me 探活（离线也放行，靠本地快照渲染）→ ShellPage；
//   无会话/探活 401：登录页。
// Rust 侧经 frb 提供 SSH 会话、字段加解密与本地库（crate rust_lib_eterm）。

import 'dart:async';
import 'dart:io' show Platform;

import 'package:eterm/src/rust/api/local.dart' as local;
import 'package:eterm/src/rust/frb_generated.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
// 0.7.0 重写为 nativeapi；旧 API（windowManager/WindowOptions）在 legacy.dart
import 'package:window_manager/legacy.dart';

import 'services/api_client.dart';
import 'services/realtime.dart';
import 'services/app_state.dart';
import 'ui/login_page.dart';
import 'ui/settings_page.dart' show startupSilentUpdateCheck;
import 'ui/shell.dart';
import 'ui/terminal_gestures.dart';
import 'ui/theme.dart';
import 'ui/ui_utils.dart' show updateRootNavigatorKey;

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
    // 监听主题控制器：切换外观时整体重建（Et 静态令牌 + Material 主题同源生效）
    return ListenableBuilder(
      listenable: ThemeController.instance,
      builder: (context, _) {
        return MaterialApp(
          title: 'Eterm',
          debugShowCheckedModeBanner: false,
          // 根导航 Key：更新链路在无页面上下文处出 SnackBar/弹层（自动更新方案 §5.2）
          navigatorKey: updateRootNavigatorKey,
          theme: buildM3Theme(kLightPalette),
          darkTheme: buildM3Theme(kDarkPalette),
          themeMode: ThemeController.instance.materialMode,
          // 勿加 const：根重建（主题切换）时 const 实例 identical，子树会被跳过
          home: _Boot(),
        );
      },
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
  bool _fatal = false; // 本地库初始化失败：不可恢复，需用户重试

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final dir = await getApplicationSupportDirectory();
      local.initCore(dataDir: dir.path);
      // 外观偏好（浅/深/跟随系统）：kv 依赖 init_core，须在其后恢复
      ThemeController.instance.load();
      // 终端本地偏好（字号/键序）：启动即恢复（复审必修 B）——
      // SFTP 编辑器与设置页滑杆不经过终端标签也要读到持久值
      TerminalPrefs.load();
    } catch (e) {
      // DB 不可用时恢复链必然级联失败（restore/clear 都要开库）——终止并给出重试
      if (!mounted) return;
      setState(() {
        _fatal = true;
        _note = '本地库初始化失败: $e';
      });
      return;
    }
    if (!mounted) return;
    List<String> sess;
    try {
      sess = local.restoreSession(); // [server, token]
    } catch (_) {
      try {
        local.clearLocal(); // 本地密文损坏（如密钥更替）：弃本地快照重新登录
      } catch (_) {}
      sess = const [];
    }
    if (sess.length < 2) {
      _go(const LoginPage());
      return;
    }
    final api = ApiClient(baseUrl: sess[0])..token = sess[1];
    final app = AppState(api: api);
    realtime.start(sess[0], sess[1],
        poke: () => app.refresh(silent: true)); // WS 实时同步（后台对账，不闪加载条）
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
    // 启动静默检查更新（仅 Android/Windows、24h 节流；发现新版出非模态 SnackBar，
    // 自动更新方案 §5.2）。火后不管：检查失败/无更新零打扰。
    unawaited(startupSilentUpdateCheck());
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
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Image.asset('assets/icon/icon-1024.png',
                  width: 72, height: 72, fit: BoxFit.cover),
            ),
            const SizedBox(height: 14),
            Text('Eterm',
                style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: Et.textPrimary)),
            const SizedBox(height: 12),
            if (_note != null) ...[
              Text(_note!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Et.textSecondary)),
              if (_fatal) ...[
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: () {
                    setState(() {
                      _fatal = false;
                      _note = null;
                    });
                    _boot();
                  },
                  icon: const Icon(Icons.refresh, size: 17),
                  label: const Text('重试'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Et.primaryBtn,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9)),
                    minimumSize: const Size(0, 38),
                  ),
                ),
              ],
            ] else
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

// 设置页（任务清单 #3/#5）：账户（修改密码/退出登录）、外观（浅色/深色/跟随系统）、
// 终端字号、辅助键条重排、关于与检查更新。主题切换经 ThemeController（全局重建，Et 令牌 +
// Material 同源）；字号即改即存。登录信息不再放侧栏/标题栏，统一收敛在此。
// 检查更新：Android/Windows 走 Dart 状态机（app_update.dart），macOS 经 MethodChannel
// 触发 Sparkle 标准界面（自动更新方案 §5.2/§7.5）。

import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/services.dart' show MethodChannel;
import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/api_client.dart';
import '../services/app_state.dart';
import '../services/app_update.dart';
import 'terminal_gestures.dart';
import 'terminal_tab.dart';
import 'theme.dart';
import 'ui_utils.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.app,
    required this.username,
    required this.onLogout,
  });

  final AppState app;
  final String username;
  final VoidCallback onLogout;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String _version = ''; // pubspec version（关于卡展示）
  bool _checking = false; // 手动检查中：行内 spinner（自动更新方案 §5.2 状态机）

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _version = info.version);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    Theme.of(context); // 主题切换时随 inherited 重建（Et 静态令牌不感知）
    final compact = MediaQuery.sizeOf(context).width < 720;
    return ListView(
      padding: EdgeInsets.fromLTRB(
          compact ? 16 : 24, compact ? 8 : 18, compact ? 16 : 24, 24),
      children: [
        if (!compact)
          Text('Settings',
              style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  color: Et.textPrimary)),
        if (!compact) const SizedBox(height: 12),
        _sectionTitle('账户'),
        _card(
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: Et.tileHost,
                      borderRadius: BorderRadius.circular(21),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      widget.username.isEmpty
                          ? '?'
                          : widget.username.characters.first.toUpperCase(),
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: Et.primaryBtnText),
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.username,
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: Et.textPrimary)),
                        SizedBox(height: 2),
                        Text('中枢账号 · 凭据与主机随此账号同步',
                            style: TextStyle(
                                fontSize: 12.5, color: Et.textSecondary)),
                      ],
                    ),
                  ),
                ],
              ),
              Divider(height: 24, color: Et.cardBorder),
              _navRow(
                icon: Icons.lock_outline,
                title: '修改密码',
                // 明示语义（评审观察 4）：改密不吊销其他已登录设备（服务端成文设计）
                subtitle: '验证原密码后设置新密码（不影响其他已登录设备）',
                onTap: _changePassword,
              ),
              _navRow(
                icon: Icons.logout,
                title: '退出登录',
                subtitle: '清除本机缓存并返回登录页',
                onTap: _confirmLogout,
                destructive: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _sectionTitle('外观'),
        // 勿加 const：主题重建时 const 实例会被 Flutter 跳过
        _card(child: _ThemeModePicker()),
        const SizedBox(height: 20),
        _sectionTitle('终端'),
        _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FontSizeSlider(),
              // 辅助键条重排是触屏功能：桌面隐藏（评审 P2；iOS 同为触屏，P7 扩闸）
              if (Platform.isAndroid || Platform.isIOS) ...[
                Divider(height: 24, color: Et.cardBorder),
                _navRow(
                  icon: Icons.swap_vert,
                  title: '重排辅助键条',
                  subtitle: '自定义终端键条按键顺序',
                  onTap: () => showExtraKeysOrderSheet(context),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        _sectionTitle('关于'),
        _card(
          child: Column(
            children: [
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.asset('assets/icon/icon-1024.png',
                        width: 44, height: 44, fit: BoxFit.cover),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_version.isEmpty ? 'Eterm' : 'Eterm v$_version',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: Et.textPrimary)),
                        const SizedBox(height: 2),
                        Text('服务器信息与密钥的统一中枢 · 数据面直连目标主机',
                            style: TextStyle(
                                fontSize: 12.5, color: Et.textSecondary)),
                      ],
                    ),
                  ),
                ],
              ),
              // iOS：应用内更新被平台禁止，更新体验由 TestFlight 承担（D5/§4.8）
              if (!Platform.isIOS) ...[
                Divider(height: 24, color: Et.cardBorder),
                _updateRow(),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ---------- 检查更新 ----------

  Widget _updateRow() {
    return InkWell(
      onTap: _checking ? null : _startManualCheck,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(Icons.system_update_alt,
                size: 20, color: Et.textSecondary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('检查更新',
                      style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: Et.textPrimary)),
                  const SizedBox(height: 2),
                  Text(_checking ? '正在检查…' : '新版本自动提示 · 也可在此手动检查',
                      style: TextStyle(
                          fontSize: 12.5, color: Et.textSecondary)),
                ],
              ),
            ),
            if (_checking)
              const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
            else
              Icon(Icons.chevron_right, size: 20, color: Et.textSecondary),
          ],
        ),
      ),
    );
  }

  Future<void> _startManualCheck() async {
    // macOS：Dart 只负责触发，检查/下载/安装 UI 由 Sparkle 标准更新器接管（方案 §7.5）
    if (Platform.isMacOS) {
      try {
        await const MethodChannel('eterm/update').invokeMethod('checkForUpdates');
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('检查更新失败')));
        }
      }
      return;
    }
    if (_checking) return;
    setState(() => _checking = true);
    final r = await AppUpdate.instance.check(respectThrottle: false);
    if (!mounted) return;
    setState(() => _checking = false);
    switch (r.status) {
      case UpdateCheckStatus.failed:
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('检查更新失败')));
      case UpdateCheckStatus.upToDate:
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                _version.isEmpty ? '已是最新版本' : '已是最新版本 v$_version')));
      case UpdateCheckStatus.newer:
        showUpdateInstallDialog(context, r.info!);
    }
  }

  // ---------- 修改密码 ----------

  Future<void> _changePassword() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _ChangePasswordDialog(app: widget.app),
    );
    if (ok == true && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('密码已更新')));
    }
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Et.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('退出登录',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary)),
        content: Text('将清除本机缓存并返回登录页，主机与凭据保留在中枢。',
            style: TextStyle(
                fontSize: 13.5, height: 1.5, color: Et.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child:
                  Text('取消', style: TextStyle(color: Et.textSecondary))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(
                  backgroundColor: Et.danger,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9))),
              child: const Text('退出')),
        ],
      ),
    );
    if (ok == true) widget.onLogout();
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 0, 0, 8),
        child: Text(t,
            style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: Et.textSecondary,
                letterSpacing: 0.3)),
      );

  Widget _card({required Widget child}) => Material(
        color: Et.card,
        borderRadius: BorderRadius.circular(Et.cardRadius),
        child: InkWell(
          borderRadius: BorderRadius.circular(Et.cardRadius),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Et.cardRadius),
              border: Border.all(color: Et.cardBorder),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: child,
          ),
        ),
      );

  Widget _navRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool destructive = false,
  }) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(icon,
                  size: 20, color: destructive ? Et.danger : Et.textSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color:
                                destructive ? Et.danger : Et.textPrimary)),
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 12.5, color: Et.textSecondary)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, size: 20, color: Et.textSecondary),
            ],
          ),
        ),
      );
}

// ---------- 修改密码对话框 ----------
// obscureText 与 maxLines 必须同时为 1（material_ui 断言，任务清单 #10 同源）。

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog({required this.app});
  final AppState app;

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscureOld = true;
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_old.text.isEmpty) {
      setState(() => _error = '请填写原密码');
      return;
    }
    if (_new.text.length < 8) {
      setState(() => _error = '新密码至少 8 位');
      return;
    }
    if (_new.text != _confirm.text) {
      setState(() => _error = '两次输入的新密码不一致');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.app.api.changePassword(_old.text, _new.text);
      if (!mounted) return;
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = switch (e.status) {
          401 => '原密码错误',
          400 => '新密码至少 8 位',
          _ => '修改失败: ${e.error}',
        };
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Et.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('修改密码',
          style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: Et.textPrimary)),
      content: SizedBox(
        width: dialogWidth(320, context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _field(_old, '原密码',
                obscure: _obscureOld,
                onToggle: () => setState(() => _obscureOld = !_obscureOld)),
            const SizedBox(height: 12),
            _field(_new, '新密码（至少 8 位）',
                obscure: _obscureNew,
                onToggle: () => setState(() => _obscureNew = !_obscureNew)),
            const SizedBox(height: 12),
            _field(_confirm, '确认新密码',
                obscure: _obscureConfirm,
                onToggle: () =>
                    setState(() => _obscureConfirm = !_obscureConfirm)),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(fontSize: 13, color: Et.danger)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: Text('取消', style: TextStyle(color: Et.textSecondary))),
        FilledButton(
          onPressed: _busy ? null : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: Et.primaryBtn,
            foregroundColor: Et.primaryBtnText,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
            minimumSize: const Size(0, 42),
          ),
          child: _busy
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('确认修改'),
        ),
      ],
    );
  }

  Widget _field(
    TextEditingController c,
    String label, {
    required bool obscure,
    required VoidCallback onToggle,
  }) =>
      TextFormField(
        controller: c,
        obscureText: obscure,
        maxLines: 1, // obscure 与多行互斥（material_ui 断言）
        autocorrect: false,
        style: TextStyle(fontSize: 14, color: Et.textPrimary),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(fontSize: 13, color: Et.textSecondary),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          suffixIcon: IconButton(
            icon: Icon(obscure ? Icons.visibility_off : Icons.visibility,
                size: 18, color: Et.textSecondary),
            onPressed: onToggle,
          ),
          suffixIconConstraints:
              const BoxConstraints(minWidth: 0, minHeight: 0),
        ),
      );
}

// ---------- 外观选择 ----------

class _ThemeModePicker extends StatelessWidget {
  const _ThemeModePicker();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeController.instance,
      builder: (context, _) {
        final mode = ThemeController.instance.mode;
        return SegmentedButton<AppThemeMode>(
          segments: const [
            ButtonSegment(
                value: AppThemeMode.light,
                icon: Icon(Icons.light_mode_outlined, size: 18),
                label: Text('浅色')),
            ButtonSegment(
                value: AppThemeMode.dark,
                icon: Icon(Icons.dark_mode_outlined, size: 18),
                label: Text('深色')),
            ButtonSegment(
                value: AppThemeMode.system,
                icon: Icon(Icons.brightness_auto_outlined, size: 18),
                label: Text('跟随系统')),
          ],
          selected: {mode},
          showSelectedIcon: false,
          onSelectionChanged: (s) =>
              ThemeController.instance.setMode(s.first),
        );
      },
    );
  }
}

// ---------- 终端字号 ----------

class _FontSizeSlider extends StatelessWidget {
  const _FontSizeSlider();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: TerminalPrefs.fontSize,
      builder: (context, value, _) {
        final isDefault =
            (value - TerminalPrefs.defaultFontSize).abs() < 0.05;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('终端字体大小',
                    style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: Et.textPrimary)),
                const Spacer(),
                Text(value.toStringAsFixed(1),
                    style: TextStyle(
                        fontSize: 13,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: FontWeight.w600,
                        color: Et.textSecondary)),
                if (!isDefault) ...[
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () => TerminalPrefs.setFontSize(
                        TerminalPrefs.defaultFontSize),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      child: Text('重置默认',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Et.accent)),
                    ),
                  ),
                ],
              ],
            ),
            Slider(
              value: value,
              min: TerminalPrefs.minFontSize,
              max: TerminalPrefs.maxFontSize,
              divisions:
                  ((TerminalPrefs.maxFontSize - TerminalPrefs.minFontSize) * 2)
                      .round(),
              label: value.toStringAsFixed(1),
              activeColor: Et.accent,
              onChanged: (v) => TerminalPrefs.setFontSize(v, persist: false),
              onChangeEnd: (v) => TerminalPrefs.persistFontSize(),
            ),
            // 等宽预览：所见即所得（终端同字体族）
            Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Et.termTheme.background,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Et.cardBorder),
              ),
              child: Text(
                'root@k7:~\$ ssh admin@10.0.0.12   █',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Menlo',
                  fontSize: value,
                  height: 1.4,
                  color: Et.termTheme.foreground,
                ),
              ),
            ),
            const SizedBox(height: 6),
            // 捏合是触屏手势，桌面不显示（评审 P2；iOS 同为触屏，P7 扩闸）
            if (Platform.isAndroid || Platform.isIOS)
              Text('双指捏合终端画面也可调整；所有终端标签即时生效。',
                  style: TextStyle(fontSize: 12, color: Et.textSecondary)),
          ],
        );
      },
    );
  }
}

// ---------- 检查更新流程（Android/Windows Dart 状态机，自动更新方案 §5.2/§5.3） ----------

/// 启动静默检查（_Boot 进入主壳后调用）：仅 Android/Windows、24h 节流；
/// 发现新版本用非模态 SnackBar（更新 action 打开同一安装对话框），其余一律静默。
Future<void> startupSilentUpdateCheck() async {
  if (!AppUpdate.instance.isSupported) return;
  final r = await AppUpdate.instance.check(); // respectThrottle 默认 true
  if (r.status != UpdateCheckStatus.newer || r.info == null) return;
  // 让主壳先落位，SnackBar 不叠在引导页上
  await Future<void>.delayed(const Duration(seconds: 2));
  final ctx = updateRootNavigatorKey.currentContext;
  if (ctx == null || !ctx.mounted) return;
  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
    content: Text('发现新版本 v${r.info!.version}'),
    action: SnackBarAction(
        label: '更新', onPressed: () => showUpdateInstallDialog(ctx, r.info!)),
  ));
}

/// 「下载并安装」对话框是否已开着（启动 SnackBar action 与手动入口防双开，评审 P3-9）。
bool _updateDialogOpen = false;

/// 打开「下载并安装」对话框（启动 SnackBar action 复用同一入口）。
/// 同时挂上 Android 原生安装结果回传：session commit 后对话框可能已关闭，
/// 经根导航 Key 出 SnackBar（自动更新方案 §6.2 Receiver）。
void showUpdateInstallDialog(BuildContext context, UpdateInfo info) {
  if (_updateDialogOpen) return;
  _updateDialogOpen = true;
  AppUpdate.onAndroidInstallStatus = (code, message) {
    // PackageInstaller 状态码：0=SUCCESS 3=ABORTED（用户主动取消，评审 P3-7）
    final text = switch (code) {
      0 => '更新安装完成',
      3 => '安装已取消',
      _ => '安装失败: $message',
    };
    if (code == 0) {
      // 安装成功清理 update 目录（方案 §12：防旧包累积）
      unawaited(AppUpdate.instance.cleanupAfterInstall());
    }
    final ctx = updateRootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    ScaffoldMessenger.of(ctx)
        .showSnackBar(SnackBar(content: Text(text)));
  };
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateInstallDialog(info: info),
  );
}

enum _UpdatePhase { confirm, downloading, installing, needPermission }

class _UpdateInstallDialog extends StatefulWidget {
  const _UpdateInstallDialog({required this.info});
  final UpdateInfo info;

  @override
  State<_UpdateInstallDialog> createState() => _UpdateInstallDialogState();
}

class _UpdateInstallDialogState extends State<_UpdateInstallDialog> {
  _UpdatePhase _phase = _UpdatePhase.confirm;
  double? _progress; // 0..1；总长未知时 null → 不确定进度
  String? _localPath; // 下载成功后的本地包路径（needPermission 重试安装用）
  bool _busy = false; // 防重：确认/重试双击触发两个 session（评审 P3-8）
  ScaffoldMessengerState? _messenger;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 先抓住 messenger：pop 之后仍要出 SnackBar（下载失败/已提交安装）
    _messenger ??= ScaffoldMessenger.of(context);
  }

  @override
  void dispose() {
    _updateDialogOpen = false;
    super.dispose();
  }

  void _cancel() {
    AppUpdate.instance.cancelDownload();
    Navigator.pop(context);
  }

  Future<void> _confirm() async {
    setState(() {
      _phase = _UpdatePhase.downloading;
      _busy = true;
    });
    try {
      _localPath = await AppUpdate.instance
          .download(widget.info, onProgress: (received, total) {
        if (!mounted) return;
        setState(() => _progress =
            (total != null && total > 0) ? (received / total).clamp(0.0, 1.0) : null);
      });
    } on UpdateCancelledException {
      return; // 用户已点取消（返回键拦截/取消按钮），对话框关闭由 pop 路径负责
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      _messenger?.showSnackBar(SnackBar(content: Text('下载更新失败: $e')));
      return;
    }
    if (!mounted) return;
    // build 5 线上实踩：_busy 是「确认/下载按钮防重」用的，下载完成后没释放就进
    // _install，被 _install 开头的 _busy 守卫原路 return → 对话框永远停在 100%。
    // 下载结束必须解锁；_install 会重新上锁并切到 installing。
    _busy = false;
    await _install();
  }

  Future<void> _install() async {
    final path = _localPath;
    if (path == null || _busy || !mounted) return;
    setState(() {
      _busy = true;
      // 76MB 拷进 PackageInstaller session 可能要数秒，不能再显示「下载中 100%」
      _phase = _UpdatePhase.installing;
    });
    final UpdateInstallAck ack;
    try {
      ack = await AppUpdate.instance.install(path);
    } catch (e) {
      // 平台异常（bad_args/文件被占用等）：明确报错收场，不留悬挂对话框
      if (!mounted) return;
      Navigator.pop(context);
      _messenger?.showSnackBar(SnackBar(content: Text('安装失败: $e')));
      return;
    }
    if (!mounted) return;
    switch (ack) {
      case UpdateInstallAck.needPermission:
        setState(() {
          _phase = _UpdatePhase.needPermission;
          _busy = false; // 授权回来重试时按钮要可用
        });
      case UpdateInstallAck.started:
        Navigator.pop(context);
        _messenger?.showSnackBar(
            const SnackBar(content: Text('已提交系统安装，请在弹窗中确认')));
      case UpdateInstallAck.error:
        Navigator.pop(context);
        _messenger?.showSnackBar(const SnackBar(content: Text('安装失败')));
    }
  }

  /// 主按钮（确认/重试）可用性：下载中禁用，busy 期间禁用（评审 P3-8）。
  VoidCallback? _primaryAction() {
    switch (_phase) {
      case _UpdatePhase.confirm:
        return _busy ? null : _confirm;
      case _UpdatePhase.downloading:
      case _UpdatePhase.installing:
        return null;
      case _UpdatePhase.needPermission:
        return (!_busy && _localPath != null) ? _install : null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 下载中拦截系统返回键/手势：先取消下载（暂存即删）再收场，
      // 防止孤儿下载 + 后续并发写同一 part 文件（评审 P1-2）
      canPop: _phase != _UpdatePhase.downloading,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          AppUpdate.instance.cancelDownload();
          Navigator.pop(context);
        }
      },
      child: AlertDialog(
      backgroundColor: Et.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
          switch (_phase) {
            _UpdatePhase.confirm => '发现新版本',
            _UpdatePhase.downloading => '正在下载更新',
            _UpdatePhase.installing => '正在安装更新',
            _UpdatePhase.needPermission => '需要安装权限',
          },
          style: TextStyle(
              fontSize: 17, fontWeight: FontWeight.w700, color: Et.textPrimary)),
      content: SizedBox(
        width: dialogWidth(320, context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_phase == _UpdatePhase.confirm) ...[
              Text('v${widget.info.version}（build ${widget.info.build}）',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Et.textPrimary)),
              if (widget.info.notes.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(widget.info.notes,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13.5,
                        height: 1.5,
                        color: Et.textSecondary)),
              ],
              if (widget.info.size > 0) ...[
                const SizedBox(height: 8),
                Text(
                    '安装包大小 ${(widget.info.size / 1048576).toStringAsFixed(1)} MB',
                    style: TextStyle(
                        fontSize: 12.5, color: Et.textSecondary)),
              ],
              if (Platform.isWindows) ...[
                const SizedBox(height: 8),
                Text('安装时应用会自动退出，装完自动重启。',
                    style: TextStyle(
                        fontSize: 12.5, color: Et.textSecondary)),
              ],
            ] else if (_phase == _UpdatePhase.downloading) ...[
              LinearProgressIndicator(
                value: _progress,
                color: Et.accent,
                backgroundColor: Et.cardBorder,
              ),
              const SizedBox(height: 10),
              Text(
                  _progress == null
                      ? '下载中…'
                      : '下载中 ${(_progress! * 100).toStringAsFixed(0)}%',
                  style: TextStyle(
                      fontSize: 13, color: Et.textSecondary)),
            ] else if (_phase == _UpdatePhase.installing) ...[
              LinearProgressIndicator(
                value: null,
                color: Et.accent,
                backgroundColor: Et.cardBorder,
              ),
              const SizedBox(height: 10),
              Text('下载完成，正在校验并提交系统安装…',
                  style: TextStyle(
                      fontSize: 13, color: Et.textSecondary)),
            ] else ...[
              Text(
                  '系统需要「安装未知应用」授权：请在设置中选择 Eterm → 允许安装未知应用，'
                  '然后回来重试。',
                  style: TextStyle(
                      fontSize: 13.5,
                      height: 1.5,
                      color: Et.textSecondary)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            // 安装阶段已提交，无法取消；禁用按钮避免误以为点掉就中止（返回键仍可关弹窗）
            onPressed: _phase == _UpdatePhase.installing
                ? null
                : () {
                    if (_phase == _UpdatePhase.downloading) {
                      _cancel(); // 取消下载并关对话框（暂存文件即删）
                    } else {
                      Navigator.pop(context);
                    }
                  },
            child: Text(
                switch (_phase) {
                  _UpdatePhase.downloading => '取消下载',
                  _UpdatePhase.installing => '安装中…',
                  _ => '取消',
                },
                style: TextStyle(color: Et.textSecondary))),
        FilledButton(
          onPressed: _primaryAction(),
          style: FilledButton.styleFrom(
            backgroundColor: Et.primaryBtn,
            foregroundColor: Et.primaryBtnText,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
            minimumSize: const Size(0, 42),
          ),
          child: Text(switch (_phase) {
            _UpdatePhase.confirm =>
              Platform.isWindows ? '退出并安装' : '下载并安装',
            _UpdatePhase.downloading => '下载中…',
            _UpdatePhase.installing => '安装中…',
            _UpdatePhase.needPermission => '已授权，重试',
          }),
        ),
      ],
      ),
    );
  }
}

// 设置页（任务清单 #3/#5）：账户（修改密码/退出登录）、外观（浅色/深色/跟随系统）、
// 终端字号、辅助键条重排、关于。主题切换经 ThemeController（全局重建，Et 令牌 +
// Material 同源）；字号即改即存。登录信息不再放侧栏/标题栏，统一收敛在此。

import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/api_client.dart';
import '../services/app_state.dart';
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
                subtitle: '验证原密码后设置新密码',
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
              // 辅助键条重排是触屏功能：桌面隐藏（评审 P2）
              if (Platform.isAndroid) ...[
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
          child: Row(
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
        ),
      ],
    );
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
            // 捏合是触屏手势，桌面不显示（评审 P2）
            if (Platform.isAndroid)
              Text('双指捏合终端画面也可调整；所有终端标签即时生效。',
                  style: TextStyle(fontSize: 12, color: Et.textSecondary)),
          ],
        );
      },
    );
  }
}

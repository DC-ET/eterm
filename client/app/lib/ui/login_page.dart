// 登录页（Termius 式浅色）：白卡片 + 橙色主按钮。
// token 保存在内存（M0 重启需重登）；OS 钥匙串持久化随 M1 落地。

import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';

import 'package:eterm/src/rust/api/local.dart' as local;

import '../services/api_client.dart';
import '../services/realtime.dart';
import '../services/app_state.dart';
import 'shell.dart';
import 'theme.dart';
import 'ui_utils.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _form = GlobalKey<FormState>();
  final _server = TextEditingController(text: 'https://eterm.etarch.cn');
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _passwordVisible = false;
  String? _error;

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = ApiClient(
        baseUrl: _server.text.trim().replaceAll(RegExp(r'/+$'), ''),
      );
      final result = await api.login(
        _username.text.trim(),
        _password.text,
        deviceName: Platform.isMacOS ? 'eterm-mac' : 'eterm-mobile',
      );
      if (!mounted) return;
      // 会话持久化：token 密文落本地库（LKMK 钥匙串保护），重启免登录
      final server = _server.text.trim().replaceAll(RegExp(r'/+$'), '');
      local.saveSession(server: server, token: result.token);
      local.kvPut(key: 'username', value: result.username);
      final app = AppState(api: api);
      realtime.start(server, result.token, poke: app.refresh); // WS 实时同步
      await app.bootstrap();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => ShellPage(
          api: api,
          app: app,
          username: result.username,
        ),
      ));
    } on ApiException catch (e) {
      setState(() => _error = switch (e.status) {
            401 => '用户名或密码错误',
            423 => '已连续失败 5 次，账号锁定 15 分钟',
            429 => '尝试过于频繁，请稍后再试',
            403 => '该账号没有个人库（no_vault）',
            _ => '登录失败: ${e.error}',
          });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Theme.of(context); // 主题切换时随 inherited 重建
    return Scaffold(
      backgroundColor: Et.contentBg,
      body: SafeArea(
        child: Center(
        child: Container(
          // 手机窄屏不溢出（评审 P0：固定 400 在 360dp 超出可用宽）
          width: dialogWidth(400, context),
          margin: const EdgeInsets.symmetric(horizontal: 12),
          padding: const EdgeInsets.all(34),
          decoration: BoxDecoration(
            color: Et.card,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Et.cardBorder),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(Et.brightness == Brightness.dark ? 60 : 14),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.asset('assets/icon/icon-1024.png',
                          width: 46, height: 46, fit: BoxFit.cover),
                    ),
                    const SizedBox(width: 12),
                    Text('eterm',
                        style: TextStyle(
                            fontSize: 25,
                            fontWeight: FontWeight.w800,
                            color: Et.textPrimary,
                            letterSpacing: -0.5)),
                  ],
                ),
                const SizedBox(height: 6),
                Text('服务器信息与密钥的统一中枢',
                    style:
                        TextStyle(fontSize: 13, color: Et.textSecondary)),
                const SizedBox(height: 26),
                _field(_server, '服务器地址',
                    textInputAction: TextInputAction.next,
                    validator: (v) {
                      final parsed = Uri.tryParse(v?.trim() ?? '');
                      if (parsed == null ||
                          parsed.scheme != 'https' ||
                          parsed.host.isEmpty) {
                        return '需 https:// 开头的有效服务器地址（明文 http 不安全）';
                      }
                      return null;
                    }),
                const SizedBox(height: 14),
                _field(_username, '用户名',
                    textInputAction: TextInputAction.next),
                const SizedBox(height: 14),
                _field(
                  _password,
                  '密码',
                  obscure: !_passwordVisible,
                  // 回车直接提交（评审 P1：此前桌面键盘无提交链）
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  suffix: IconButton(
                    icon: Icon(
                        _passwordVisible
                            ? Icons.visibility_off
                            : Icons.visibility,
                        size: 18,
                        color: Et.textSecondary),
                    onPressed: () =>
                        setState(() => _passwordVisible = !_passwordVisible),
                  ),
                ),
                const SizedBox(height: 22),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: Et.accent,
                    foregroundColor: Et.primaryBtnText,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    minimumSize: const Size(0, 46),
                  ),
                  child: _busy
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('登录',
                          style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!,
                      style: TextStyle(
                          fontSize: 13, color: Et.danger)),
                ],
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _field(
    TextEditingController c,
    String label, {
    bool obscure = false,
    String? Function(String?)? validator,
    Widget? suffix,
    TextInputAction? textInputAction,
    void Function(String)? onSubmitted,
  }) =>
      TextFormField(
        controller: c,
        obscureText: obscure,
        autocorrect: false,
        textInputAction: textInputAction,
        onFieldSubmitted: onSubmitted,
        validator: validator ?? (v) => (v == null || v.trim().isEmpty) ? '必填' : null,
        style: TextStyle(fontSize: 14, color: Et.textPrimary),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(fontSize: 13, color: Et.textSecondary),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          suffixIcon: suffix,
          suffixIconConstraints:
              const BoxConstraints(minWidth: 0, minHeight: 0),
        ),
      );
}

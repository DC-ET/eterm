// 登录页（Termius 式浅色）：白卡片 + 橙色主按钮。
// token 保存在内存（M0 重启需重登）；OS 钥匙串持久化随 M1 落地。

import 'dart:io' show Platform;

import 'package:material_ui/material_ui.dart';

import 'package:eterm/src/rust/api/local.dart' as local;

import '../services/api_client.dart';
import '../services/app_state.dart';
import 'shell.dart';
import 'theme.dart';

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
            401 => '用户名或口令错误',
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
    return Scaffold(
      backgroundColor: Et.contentBg,
      body: Center(
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(34),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Et.cardBorder),
          ),
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Row(
                  children: [
                    Text('eterm',
                        style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                            color: Et.textPrimary,
                            letterSpacing: -0.5)),
                    SizedBox(width: 4),
                    Icon(Icons.terminal, size: 22, color: Et.accent),
                  ],
                ),
                const SizedBox(height: 4),
                const Text('服务器信息与密钥的统一中枢',
                    style:
                        TextStyle(fontSize: 13, color: Et.textSecondary)),
                const SizedBox(height: 26),
                _field(_server, '服务器地址',
                    validator: (v) =>
                        (v == null || !v.startsWith('http')) ? '需以 http(s):// 开头' : null),
                const SizedBox(height: 14),
                _field(_username, '用户名'),
                const SizedBox(height: 14),
                _field(
                  _password,
                  '口令',
                  obscure: !_passwordVisible,
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
                    foregroundColor: Colors.white,
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
                      style: const TextStyle(
                          fontSize: 13, color: Color(0xFFD1242F))),
                ],
              ],
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
  }) =>
      TextFormField(
        controller: c,
        obscureText: obscure,
        autocorrect: false,
        validator: validator ?? (v) => (v == null || v.trim().isEmpty) ? '必填' : null,
        style: const TextStyle(fontSize: 14, color: Et.textPrimary),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(fontSize: 13, color: Et.textSecondary),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          suffixIcon: suffix,
          suffixIconConstraints:
              const BoxConstraints(minWidth: 0, minHeight: 0),
        ),
      );
}

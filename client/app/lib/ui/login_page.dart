// 登录页（M0 骨架）：服务器地址 / 用户名 / 口令 → /api/v1/auth/login。
// token 保存在内存（M0 重启需重登）；OS 钥匙串持久化随 M1 落地。

import 'package:material_ui/material_ui.dart';

import '../services/api_client.dart';
import '../services/app_state.dart';
import 'home_page.dart';

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
        deviceName: 'eterm-mac',
      );
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => HomePage(
          api: api,
          app: AppState(api: api),
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
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('eterm',
                    style: TextStyle(fontSize: 32, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('服务器信息与密钥的统一中枢',
                    style: TextStyle(color: Colors.grey.shade500)),
                const SizedBox(height: 32),
                TextFormField(
                  controller: _server,
                  decoration: const InputDecoration(
                      labelText: '服务器地址', border: OutlineInputBorder()),
                  validator: (v) =>
                      (v == null || !v.startsWith('http')) ? '需以 http(s):// 开头' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _username,
                  autocorrect: false,
                  decoration: const InputDecoration(
                      labelText: '用户名', border: OutlineInputBorder()),
                  validator: (v) => (v == null || v.trim().isEmpty) ? '必填' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _password,
                  obscureText: true,
                  onFieldSubmitted: (_) => _busy ? null : _submit(),
                  decoration: const InputDecoration(
                      labelText: '口令', border: OutlineInputBorder()),
                  validator: (v) => (v == null || v.isEmpty) ? '必填' : null,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: _busy
                        ? const SizedBox(
                            height: 18, width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('登录'),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

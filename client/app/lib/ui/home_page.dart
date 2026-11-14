// Host 列表页（M0 骨架）：全量 pull 折叠展示；WS 变更通知 → 重拉；
// 添加主机（host + host_protocol + identity push）；点击进入终端页。

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../services/api_client.dart';
import '../services/app_state.dart';
import 'login_page.dart';
import 'terminal_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.api,
    required this.app,
    required this.username,
  });

  final ApiClient api;
  final AppState app;
  final String username;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  StreamSubscription<Map<String, dynamic>>? _feed;
  Timer? _reconnect;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    widget.app.refresh();
    _listen();
  }

  void _listen() {
    _feed?.cancel();
    _feed = widget.api.changeFeed().listen((frame) {
      if (frame['type'] != 'change') return;

      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 300), () {

        widget.app.refresh();
      });
    }, onDone: () {
      // 断线重连（服务端重启/网络抖动）
      _reconnect?.cancel();
      _reconnect = Timer(const Duration(seconds: 3), _listen);
    }, onError: (_) {
      _reconnect?.cancel();
      _reconnect = Timer(const Duration(seconds: 3), _listen);
    });
  }

  @override
  void dispose() {
    _feed?.cancel();
    _debounce?.cancel();
    _reconnect?.cancel();
    widget.app.dispose();
    super.dispose();
  }

  Future<void> _logout() async {
    try {
      await widget.api.logout();
    } catch (_) {}
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginPage()));
  }

  Future<void> _addHost() async {
    final created = await showDialog<_AddHostResult>(
      context: context,
      builder: (_) => const _AddHostDialog(),
    );
    if (created == null) return;
    try {
      await widget.app.addHost(
        label: created.label,
        hostname: created.hostname,
        port: created.port,
        username: created.username,
        usePassword: created.usePassword,
        secret: created.secret,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('添加失败: ${e.error}')));
    }
  }

  void _open(HostView h) {
    final cred = widget.app.credentialFor(h);
    if (cred == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('该主机没有可用凭据')));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TerminalPage(
        host: h,
        authKind: cred.authKind,
        secret: cred.secret,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: Text('eterm · ${widget.username}'),
          actions: [
            if (widget.app.loading)
              const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox(
                    height: 18, width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            IconButton(icon: const Icon(Icons.add), tooltip: '添加主机',
                onPressed: _addHost),
            IconButton(icon: const Icon(Icons.logout), tooltip: '退出登录',
                onPressed: _logout),
          ],
        ),
        body: widget.app.error != null
            ? Center(child: Text('同步失败: ${widget.app.error}'))
            : widget.app.hosts.isEmpty
                ? const Center(child: Text('还没有主机，点右上角 + 添加'))
                : ListView(
                    padding: const EdgeInsets.all(8),
                    children: [
                      for (final h in widget.app.hosts)
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.dns),
                            title: Text(h.label),
                            subtitle: Text('${h.username}@${h.hostname}:${h.port}'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _open(h),
                          ),
                        ),
                    ],
                  ),
      ),
    );
  }
}

class _AddHostResult {
  _AddHostResult({
    required this.label,
    required this.hostname,
    required this.port,
    required this.username,
    required this.usePassword,
    required this.secret,
  });
  final String label;
  final String hostname;
  final int port;
  final String username;
  final bool usePassword;
  final String secret;
}

class _AddHostDialog extends StatefulWidget {
  const _AddHostDialog();

  @override
  State<_AddHostDialog> createState() => _AddHostDialogState();
}

class _AddHostDialogState extends State<_AddHostDialog> {
  final _form = GlobalKey<FormState>();
  final _label = TextEditingController();
  final _hostname = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _username = TextEditingController();
  final _secret = TextEditingController();
  bool _usePassword = true;

  @override
  void dispose() {
    _label.dispose();
    _hostname.dispose();
    _port.dispose();
    _username.dispose();
    _secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加主机'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _label,
                decoration: const InputDecoration(labelText: '名称',
                    border: OutlineInputBorder()),
                validator: (v) => (v == null || v.trim().isEmpty) ? '必填' : null,
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextFormField(
                    controller: _hostname,
                    decoration: const InputDecoration(labelText: '主机名/IP',
                        border: OutlineInputBorder()),
                    validator: (v) => (v == null || v.trim().isEmpty) ? '必填' : null,
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 90,
                  child: TextFormField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '端口',
                        border: OutlineInputBorder()),
                    validator: (v) {
                      final p = int.tryParse(v ?? '');
                      return (p == null || p < 1 || p > 65535) ? '1-65535' : null;
                    },
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              TextFormField(
                controller: _username,
                decoration: const InputDecoration(labelText: '用户名',
                    border: OutlineInputBorder()),
                validator: (v) => (v == null || v.trim().isEmpty) ? '必填' : null,
              ),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('口令')),
                  ButtonSegment(value: false, label: Text('私钥')),
                ],
                selected: {_usePassword},
                onSelectionChanged: (s) =>
                    setState(() => _usePassword = s.first),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _secret,
                obscureText: _usePassword,
                autocorrect: false,
                minLines: _usePassword ? 1 : 4,
                maxLines: _usePassword ? 1 : 8,
                decoration: InputDecoration(
                  labelText: _usePassword ? '口令' : '私钥（OpenSSH PEM，会话内有效）',
                  border: const OutlineInputBorder(),
                ),
                validator: (v) => (v == null || v.isEmpty) ? '必填' : null,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消')),
        FilledButton(
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            Navigator.pop(context, _AddHostResult(
              label: _label.text.trim(),
              hostname: _hostname.text.trim(),
              port: int.parse(_port.text.trim()),
              username: _username.text.trim(),
              usePassword: _usePassword,
              secret: _secret.text,
            ));
          },
          child: const Text('保存并同步'),
        ),
      ],
    );
  }
}

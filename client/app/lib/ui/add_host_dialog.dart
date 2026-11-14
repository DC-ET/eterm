// 添加主机对话框（Termius 式浅色；内容可滚动——修复多行域撑破对话框的 overflow）。

import 'package:material_ui/material_ui.dart';

import '../services/api_client.dart';
import '../services/app_state.dart';
import 'theme.dart';

class AddHostDialog extends StatefulWidget {
  const AddHostDialog({super.key, required this.app});

  final AppState app;

  @override
  State<AddHostDialog> createState() => _AddHostDialogState();
}

class _AddHostDialogState extends State<AddHostDialog> {
  final _form = GlobalKey<FormState>();
  final _label = TextEditingController();
  final _hostname = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _username = TextEditingController();
  final _secret = TextEditingController();
  final _newGroup = TextEditingController();
  bool _usePassword = true;
  String? _groupId; // null = 未分组
  bool _newGroupMode = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _hostname.dispose();
    _port.dispose();
    _username.dispose();
    _secret.dispose();
    _newGroup.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.app.addHost(
        label: _label.text.trim(),
        hostname: _hostname.text.trim(),
        port: int.parse(_port.text.trim()),
        username: _username.text.trim(),
        usePassword: _usePassword,
        secret: _secret.text,
        groupId: _newGroupMode ? null : _groupId,
        newGroupName: _newGroupMode ? _newGroup.text : null,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      setState(() => _error = e.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = widget.app.groups;
    return AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 18),
      title: const Text('新建主机',
          style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Et.textPrimary)),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _field(_label, '名称'),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _field(_hostname, '主机名 / IP'),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 88,
                      child: _field(_port, '端口',
                          keyboardType: TextInputType.number,
                          validator: (v) {
                            final p = int.tryParse(v ?? '');
                            return (p == null || p < 1 || p > 65535)
                                ? '1-65535'
                                : null;
                          }),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _field(_username, '用户名'),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _groupId ?? '',
                        decoration: _dec('分组'),
                        items: [
                          const DropdownMenuItem(
                              value: '', child: Text('未分组')),
                          ...groups.map((g) => DropdownMenuItem(
                                value: g.id,
                                child: Text(g.label,
                                    overflow: TextOverflow.ellipsis),
                              )),
                          const DropdownMenuItem(
                              value: '__new__', child: Text('＋ 新建分组…')),
                        ],
                        onChanged: (v) => setState(() {
                          if (v == '__new__') {
                            _newGroupMode = true;
                            _groupId = null;
                          } else {
                            _newGroupMode = false;
                            _groupId = (v == null || v.isEmpty) ? null : v;
                          }
                        }),
                      ),
                    ),
                    if (_newGroupMode)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(left: 10),
                          child: _field(_newGroup, '新分组名'),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('口令')),
                    ButtonSegment(value: false, label: Text('私钥')),
                  ],
                  selected: {_usePassword},
                  style: SegmentedButton.styleFrom(
                    selectedBackgroundColor: Et.primaryBtn,
                    selectedForegroundColor: Colors.white,
                    backgroundColor: const Color(0xFFF1F2F5),
                    foregroundColor: Et.textPrimary,
                  ),
                  showSelectedIcon: false,
                  onSelectionChanged: (s) =>
                      setState(() => _usePassword = s.first),
                ),
                const SizedBox(height: 12),
                _field(
                  _secret,
                  _usePassword ? '口令' : '私钥（OpenSSH PEM，会话内有效）',
                  obscure: _usePassword,
                  minLines: _usePassword ? 1 : 4,
                  maxLines: _usePassword ? 1 : 6,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text('添加失败: $_error',
                      style: const TextStyle(
                          fontSize: 12.5, color: Color(0xFFD1242F))),
                ],
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消',
              style: TextStyle(color: Et.textSecondary)),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          style: FilledButton.styleFrom(
            backgroundColor: Et.primaryBtn,
            foregroundColor: Colors.white,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
            minimumSize: const Size(0, 42),
          ),
          child: _busy
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Text('保存并同步'),
        ),
      ],
    );
  }

  InputDecoration _dec(String label) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(fontSize: 13, color: Et.textSecondary),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      );

  Widget _field(
    TextEditingController c,
    String label, {
    bool obscure = false,
    int minLines = 1,
    int maxLines = 1,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) =>
      TextFormField(
        controller: c,
        obscureText: obscure,
        autocorrect: false,
        minLines: minLines,
        maxLines: maxLines,
        keyboardType: keyboardType,
        validator: validator ?? (v) => (v == null || v.trim().isEmpty) ? '必填' : null,
        style: const TextStyle(fontSize: 14, color: Et.textPrimary),
        decoration: _dec(label),
      );
}

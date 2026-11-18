// 新建/编辑主机对话框（Termius 式浅色；内容可滚动——修复多行域撑破对话框）。
// 编辑模式：预填 + 认证方式只读；口令留空保持不变；私钥替换会新建 ssh_key 实体。
// 凭据域带粘贴按钮；口令带可见性切换。

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../services/api_client.dart';
import '../services/app_state.dart';
import 'theme.dart';

class AddHostDialog extends StatefulWidget {
  const AddHostDialog({super.key, required this.app}) : editHost = null;

  const AddHostDialog.edit({
    super.key,
    required this.app,
    required HostView this.editHost,
  });

  final AppState app;
  final HostView? editHost;

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
  // 私钥来源：true = 从 Keychain 复用已有密钥（identity.key_id 引用），
  // false = 粘贴新 PEM（新建 ssh_key 实体）。Keychain 为空时不显示切换。
  bool _keyFromVault = false;
  String? _vaultKeyId;
  String? _groupId; // null = 未分组
  bool _newGroupMode = false;
  bool _busy = false;
  bool _secretVisible = false;
  String? _error;

  bool get _isEdit => widget.editHost != null;

  @override
  void initState() {
    super.initState();
    final h = widget.editHost;
    if (h != null) {
      _label.text = h.label;
      _hostname.text = h.hostname;
      _port.text = '${h.port}';
      _username.text = h.username;
      _groupId = h.groupId;
      final cred = widget.app.credentialFor(h);
      _usePassword = cred?.authKind == 'password';
      if (!_usePassword) {
        // 编辑私钥主机：默认指向当前密钥（Keychain 下拉可换绑其他已有密钥）
        _vaultKeyId = widget.app.keyIdOfIdentity(h.identityId);
        _keyFromVault = _vaultKeyId != null &&
            widget.app.keys.any((k) => k.id == _vaultKeyId);
      }
    }
  }

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

  Future<void> _pasteSecret() async {
    final text = await Clipboard.getData(Clipboard.kTextPlain);
    if (text?.text != null && text!.text!.isNotEmpty) {
      setState(() => _secret.text = text.text!);
    }
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_isEdit) {
        final h = widget.editHost!;
        await widget.app.editHost(
          host: h,
          label: _label.text.trim(),
          hostname: _hostname.text.trim(),
          port: int.parse(_port.text.trim()),
          username: _username.text.trim(),
          groupId: _newGroupMode ? null : _groupId,
          newGroupName: _newGroupMode ? _newGroup.text : null,
          password: _usePassword ? _secret.text : null,
          replaceKeyPem: !_usePassword && !_keyFromVault ? _secret.text : null,
          replaceWithKeyId:
              !_usePassword && _keyFromVault ? _vaultKeyId : null,
        );
      } else {
        await widget.app.addHost(
          label: _label.text.trim(),
          hostname: _hostname.text.trim(),
          port: int.parse(_port.text.trim()),
          username: _username.text.trim(),
          usePassword: _usePassword,
          secret: (!_usePassword && _keyFromVault) ? '' : _secret.text,
          existingKeyId: (!_usePassword && _keyFromVault) ? _vaultKeyId : null,
          groupId: _newGroupMode ? null : _groupId,
          newGroupName: _newGroupMode ? _newGroup.text : null,
        );
      }
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
      backgroundColor: Et.card,
      surfaceTintColor: Et.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 18),
      title: Text(_isEdit ? '编辑主机' : '新建主机',
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
                    Expanded(child: _field(_hostname, '主机名 / IP')),
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
                        // 悬空 groupId（分组在其他设备被删）回退"未分组"，防断言崩溃
                        initialValue: _newGroupMode
                            ? '__new__'
                            : (_groupId != null &&
                                    groups.any((g) => g.id == _groupId)
                                ? _groupId!
                                : ''),
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
                _authSegment(),
                const SizedBox(height: 12),
                if (_usePassword)
                  _field(
                    _secret,
                    _secretLabel,
                    obscure: !_secretVisible,
                    validator: _secretValidator,
                    suffix: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 粘贴按钮（不依赖系统 Cmd+V 行为，安卓/桌面都可靠）
                        IconButton(
                          icon: Icon(Icons.content_paste,
                              size: 17, color: Et.textSecondary),
                          tooltip: '粘贴',
                          onPressed: _pasteSecret,
                        ),
                        IconButton(
                          icon: Icon(
                              _secretVisible
                                  ? Icons.visibility_off
                                  : Icons.visibility,
                              size: 17,
                              color: Et.textSecondary),
                          tooltip: _secretVisible ? '隐藏' : '显示',
                          onPressed: () =>
                              setState(() => _secretVisible = !_secretVisible),
                        ),
                      ],
                    ),
                  )
                else ...[
                  // 私钥来源：Keychain 可选时提供切换（粘贴新 PEM / 复用已有密钥）
                  if (widget.app.keys.isNotEmpty) _keySourceSegment(),
                  if (_keyFromVault)
                    _vaultKeyDropdown()
                  else
                    _field(
                      _secret,
                      _secretLabel,
                      minLines: 4,
                      maxLines: 6,
                      validator: _secretValidator,
                      suffix: IconButton(
                        icon: Icon(Icons.content_paste,
                            size: 17, color: Et.textSecondary),
                        tooltip: '粘贴',
                        onPressed: _pasteSecret,
                      ),
                    ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text('保存失败: $_error',
                      style: TextStyle(
                          fontSize: 12.5, color: Et.danger)),
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
            child:
                Text('取消', style: TextStyle(color: Et.textSecondary))),
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
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : Text(_isEdit ? '保存修改' : '保存并同步'),
        ),
      ],
    );
  }

  /// 认证方式分段：选中态始终清晰显示；编辑模式只读（切换=删除重建，避免凭据歧义）
  Widget _authSegment() {
    Widget seg(bool value, String label) {
      final sel = _usePassword == value;
      final radius = value
          ? const BorderRadius.horizontal(left: Radius.circular(20))
          : const BorderRadius.horizontal(right: Radius.circular(20));
      return Expanded(
        child: GestureDetector(
          // 编辑模式只读（切换=删除重建，避免凭据歧义）；新建模式切回口令时
          // 清空私域输入：先粘 PEM 再切口令会把 PEM 当口令保存（评审 P2）
          onTap: _isEdit || value == _usePassword
              ? null
              : () => setState(() {
                    _usePassword = value;
                    if (value) _secret.clear();
                  }),
          child: Container(
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: sel ? Et.primaryBtn : const Color(0xFFF1F2F5),
              borderRadius: radius,
            ),
            child: Text(label,
                style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: sel ? Colors.white : Et.textSecondary)),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Row(children: [seg(true, '口令'), seg(false, '私钥')]),
    );
  }

  /// 私钥来源分段：粘贴新 PEM / 从 Keychain 选择
  /// （Keychain 为空时不显示，Keychain 里复用已有密钥免去重传）。
  Widget _keySourceSegment() {
    Widget seg(bool vault, String label) {
      final sel = _keyFromVault == vault;
      final radius = vault
          ? const BorderRadius.horizontal(right: Radius.circular(16))
          : const BorderRadius.horizontal(left: Radius.circular(16));
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _keyFromVault = vault),
          child: Container(
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: sel ? Et.primaryBtn : const Color(0xFFF1F2F5),
              borderRadius: radius,
            ),
            child: Text(label,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: sel ? Colors.white : Et.textSecondary)),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Row(
            children: [seg(false, '粘贴新 PEM'), seg(true, '从 Keychain 选择')]),
      ),
    );
  }

  /// Keychain 密钥下拉（编辑模式预选当前密钥）。
  Widget _vaultKeyDropdown() {
    final keys = widget.app.keys;
    final valid = _vaultKeyId != null && keys.any((k) => k.id == _vaultKeyId);
    return DropdownButtonFormField<String>(
      // 未选中必须是 null（空串不在 items 里，DropdownButtonFormField 会断言失败）
      initialValue: valid ? _vaultKeyId! : null,
      decoration: _dec('从 Keychain 选择密钥'),
      items: [
        for (final k in keys)
          DropdownMenuItem(
            value: k.id,
            child: Text('${k.label}（${_fpTail(k.fingerprint)}）',
                overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (v) =>
          setState(() => _vaultKeyId = (v == null || v.isEmpty) ? null : v),
      validator: (v) => (v == null || v.isEmpty) ? '请选择要使用的密钥' : null,
    );
  }

  String _fpTail(String fp) {
    final body = fp.startsWith('SHA256:') ? fp.substring(7) : fp;
    return body.length <= 8 ? fp : '…${body.substring(body.length - 8)}';
  }

  String get _secretLabel {
    if (_isEdit) {
      return _usePassword ? '口令（留空保持不变）' : '私钥（粘贴新 PEM 可替换；留空不变）';
    }
    return _usePassword ? '口令' : '私钥（OpenSSH PEM）';
  }

  /// 编辑且已有凭据：允许留空（保持现有凭据）。注意必须返回恒通过的
  /// 校验器而非 null——null 会被 _field 的 `??` 替换回默认必填校验。
  String? Function(String?)? get _secretValidator {
    if (_isEdit && widget.app.credentialFor(widget.editHost!).available) {
      return _noValidate;
    }
    return (v) => (v == null || v.isEmpty) ? '必填' : null;
  }

  static String? _noValidate(String? _) => null;

  InputDecoration _dec(String label) => InputDecoration(
        labelText: label,
        labelStyle: TextStyle(fontSize: 13, color: Et.textSecondary),
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
    Widget? suffix,
  }) =>
      TextFormField(
        controller: c,
        obscureText: obscure,
        autocorrect: false,
        minLines: minLines,
        maxLines: maxLines,
        keyboardType: keyboardType,
        validator:
            validator ?? (v) => (v == null || v.trim().isEmpty) ? '必填' : null,
        style: TextStyle(fontSize: 14, color: Et.textPrimary),
        decoration: _dec(label).copyWith(
          suffixIcon: suffix,
          suffixIconConstraints:
              const BoxConstraints(minWidth: 0, minHeight: 0),
        ),
      );
}

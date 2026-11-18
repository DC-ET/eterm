// Keychain 页（M1 收口）：密钥 + Identity 统一管理。
// 密钥：生成（Ed25519/ECDSA P-256/RSA，Rust core）/ 导入（粘贴或文件，Rust 校验
// 类型/指纹/公钥行）/ 详情（指纹、公钥行复制、部署公钥到目标机 authorized_keys）/
// 导出私钥（复制）/ 改名 / 删除（仅未被引用）。
// Identity（F4.1：用户名+密码/Key 凭据组合）：列表 / 编辑（一处改全局生效）/
// 删除（仅未被主机引用）。
// 密钥内容只落应用自有加密库（LKMK 密文），不走 OS 钥匙串。
// 主机认证从「编辑 → 认证」可复用 Keychain 中的已有密钥（identity.key_id 引用）。

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../services/api_client.dart';
import '../services/app_state.dart';
import 'theme.dart';

class KeychainPage extends StatefulWidget {
  const KeychainPage({super.key, required this.app});

  final AppState app;

  @override
  State<KeychainPage> createState() => _KeychainPageState();
}

class _KeychainPageState extends State<KeychainPage> {
  int _section = 0; // 0 = 密钥，1 = Identity

  Future<void> _confirmDelete(KeyView k) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Et.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('删除密钥',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary)),
        content: Text(
            '将从 vault 中删除密钥「${k.label}」（${k.keyType}）。此操作会同步到所有设备。',
            style: TextStyle(
                fontSize: 13.5, height: 1.5, color: Et.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child:
                  Text('取消', style: TextStyle(color: Et.textSecondary))),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
                backgroundColor: Et.danger,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9))),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => widget.app.deleteKey(k), success: '密钥已删除并同步');
  }

  Future<void> _confirmDeleteIdentity(IdentityView v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Et.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('删除凭据',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary)),
        content: Text(
            '将从 vault 中删除凭据「${v.label}」（${v.username}）。此操作会同步到所有设备。',
            style: TextStyle(
                fontSize: 13.5, height: 1.5, color: Et.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child:
                  Text('取消', style: TextStyle(color: Et.textSecondary))),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
                backgroundColor: Et.danger,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9))),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() => widget.app.deleteIdentity(v), success: '凭据已删除并同步');
  }

  void _openIdentityEdit(IdentityView v) {
    // barrierDismissible=false：busy 提交中被误关会吞掉成功/失败反馈（评审 BUG-7）
    showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _IdentityEditDialog(app: widget.app, item: v),
    ).then((ok) async {
      if (ok == true) await _run(null, success: '凭据已更新并同步');
    });
  }

  void _openGenerate() {
    showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _GenerateKeyDialog(app: widget.app),
    ).then((ok) async {
      if (ok == true) await _run(null, success: '密钥已生成并同步');
    });
  }

  void _openImport() {
    showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ImportKeyDialog(app: widget.app),
    ).then((ok) async {
      if (ok == true) await _run(null, success: '密钥已导入并同步');
    });
  }

  void _openDetail(KeyView k) {
    showDialog<void>(
      context: context,
      builder: (_) => _KeyDetailDialog(app: widget.app, item: k, onDelete: _confirmDelete),
    );
  }

  /// 统一收尾：执行动作（可为 null，对话框内已完成）并弹结果提示。
  Future<void> _run(Future<void> Function()? action, {required String success}) async {
    if (action != null) {
      try {
        await action();
      } on ApiException catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('操作失败: ${e.error}')));
        }
        return;
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(success)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    return Container(
      color: Et.contentBg,
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 说明条（桌面附带工具栏按钮；手机仅说明）
              Padding(
                padding: EdgeInsets.fromLTRB(
                    compact ? 14 : 20, 14, compact ? 14 : 20, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.key_outlined,
                        size: 17, color: Et.textSecondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '密钥与凭据（Identity）存储在应用自有加密库中并同步到你的所有设备'
                        '（不经系统钥匙串）；主机认证时直接选用，公钥可一键部署到目标机。',
                        style: TextStyle(
                            fontSize: 12.5,
                            height: 1.45,
                            color: Et.textSecondary),
                      ),
                    ),
                    if (!compact && _section == 0) ...[
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: _openGenerate,
                        icon: const Icon(Icons.auto_awesome, size: 16),
                        label: const Text('生成密钥'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Et.primaryBtn,
                          foregroundColor: Et.primaryBtnText,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(9)),
                          minimumSize: const Size(0, 38),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _openImport,
                        icon: const Icon(Icons.download, size: 16),
                        label: const Text('导入密钥'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Et.textPrimary,
                          side: BorderSide(color: Et.cardBorder),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(9)),
                          minimumSize: const Size(0, 38),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // 分区切换：密钥 / Identity（凭据组合）
              Padding(
                padding:
                    EdgeInsets.fromLTRB(compact ? 14 : 20, 2, compact ? 14 : 20, 8),
                child: _SectionToggle(
                  section: _section,
                  onSelect: (i) => setState(() => _section = i),
                ),
              ),
              Expanded(
                child: ListenableBuilder(
                  listenable: widget.app,
                  builder: (context, _) {
                    if (widget.app.error == 'unauthorized') {
                      return const SizedBox.shrink();
                    }
                    if (_section == 1) {
                      final identities = widget.app.identities;
                      if (identities.isEmpty) return _identityEmptyState;
                      return ListView(
                        padding: EdgeInsets.fromLTRB(
                            compact ? 14 : 20, 4, compact ? 14 : 20, 20),
                        children: [
                          for (final v in identities)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: _IdentityCard(
                                item: v,
                                keyMissing: widget.app.identityKeyMissing(v),
                                onTap: () => _openIdentityEdit(v),
                                onDelete: v.usedBy.isEmpty
                                    ? () => _confirmDeleteIdentity(v)
                                    : null,
                              ),
                            ),
                        ],
                      );
                    }
                    final keys = widget.app.keys;
                    if (keys.isEmpty) return _emptyState;
                    return ListView(
                      padding: EdgeInsets.fromLTRB(
                          compact ? 14 : 20, 4, compact ? 14 : 20, 20),
                      children: [
                        for (final k in keys)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _KeyCard(
                              item: k,
                              onTap: () => _openDetail(k),
                              onDelete:
                                  k.usedBy.isEmpty ? () => _confirmDelete(k) : null,
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
          // 手机：FAB 弹出生成/导入菜单（仅密钥分区；凭据经主机编辑创建/修改）
          if (compact && _section == 0)
            Positioned(
              right: 18,
              bottom: 18,
              child: FloatingActionButton(
                heroTag: 'keychain-add',
                backgroundColor: Et.primaryBtn,
                foregroundColor: Et.primaryBtnText,
                elevation: 2,
                onPressed: _showMobileMenu,
                child: const Icon(Icons.add, size: 26),
              ),
            ),
        ],
      ),
    );
  }

  void _showMobileMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Et.card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            ListTile(
              leading: Icon(Icons.auto_awesome, color: Et.primaryBtn),
              title: Text('生成新密钥',
                  style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: Et.textPrimary)),
              subtitle: Text('在设备上生成 Ed25519 / ECDSA / RSA 密钥对',
                  style: TextStyle(fontSize: 12, color: Et.textSecondary)),
              onTap: () {
                Navigator.pop(sheetCtx);
                _openGenerate();
              },
            ),
            ListTile(
              leading: Icon(Icons.download, color: Et.primaryBtn),
              title: Text('导入密钥',
                  style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: Et.textPrimary)),
              subtitle: Text('粘贴 OpenSSH PEM 或选择文件',
                  style: TextStyle(fontSize: 12, color: Et.textSecondary)),
              onTap: () {
                Navigator.pop(sheetCtx);
                _openImport();
              },
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget get _emptyState => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Et.card,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Et.cardBorder),
              ),
              child: Icon(Icons.key_outlined,
                  size: 30, color: Et.textSecondary),
            ),
            const SizedBox(height: 14),
            Text('还没有密钥',
                style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    color: Et.textPrimary)),
            const SizedBox(height: 5),
            Text('生成或导入密钥，主机认证时可直接选用',
                style: TextStyle(fontSize: 13, color: Et.textSecondary)),
          ],
        ),
      );

  Widget get _identityEmptyState => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Et.card,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Et.cardBorder),
              ),
              child: Icon(Icons.badge_outlined,
                  size: 30, color: Et.textSecondary),
            ),
            const SizedBox(height: 14),
            Text('还没有凭据（Identity）',
                style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    color: Et.textPrimary)),
            const SizedBox(height: 5),
            Text('添加主机时自动创建；这里可查看与修改已有凭据',
                style: TextStyle(fontSize: 13, color: Et.textSecondary)),
          ],
        ),
      );
}

// ---------- 分区切换（密钥 / Identity） ----------

class _SectionToggle extends StatelessWidget {
  const _SectionToggle({required this.section, required this.onSelect});

  final int section; // 0 = 密钥，1 = Identity
  final void Function(int) onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF1F4),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _tab(0, '密钥', Icons.key),
          const SizedBox(width: 3),
          _tab(1, 'Identity（凭据）', Icons.badge_outlined),
        ],
      ),
    );
  }

  Widget _tab(int i, String label, IconData icon) {
    final active = section == i;
    return Expanded(
      child: Material(
        color: active ? Et.card : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          borderRadius: BorderRadius.circular(7),
          onTap: () => onSelect(i),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon,
                    size: 14,
                    color: active ? Et.textPrimary : Et.textSecondary),
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                        color: active ? Et.textPrimary : Et.textSecondary)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------- Identity 卡片 ----------

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({
    required this.item,
    required this.keyMissing,
    required this.onTap,
    required this.onDelete,
  });

  final IdentityView item;
  final bool keyMissing; // 引用的密钥已不存在（他端并发删除）
  final VoidCallback onTap;
  final VoidCallback? onDelete; // null = 被主机引用，不可删

  @override
  Widget build(BuildContext context) {
    final usedBy = item.usedBy.isEmpty
        ? '未被使用'
        : '被 ${item.usedBy.length} 台主机使用：${item.usedBy.join("、")}';
    return Material(
      color: Et.card,
      borderRadius: BorderRadius.circular(Et.cardRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(Et.cardRadius),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Et.cardRadius),
            border: Border.all(color: Et.cardBorder),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFF5A4FCF),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.badge_outlined,
                    color: Colors.white, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${item.label}（${item.username}）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Et.textPrimary)),
                    const SizedBox(height: 3),
                    Text(keyMissing ? '引用的密钥已不存在，请重新选择' : usedBy,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            color: keyMissing
                                ? Et.danger
                                : item.usedBy.isEmpty
                                    ? Et.textSecondary
                                    : const Color(0xFF2DA44E))),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 认证方式徽标
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F2F5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(item.authKindText,
                    style: TextStyle(
                        fontSize: 11, color: Et.textSecondary)),
              ),
              if (onDelete != null)
                IconButton(
                  icon: Icon(Icons.delete_outline,
                      size: 18, color: Et.textSecondary),
                  tooltip: '删除凭据',
                  onPressed: onDelete,
                )
              else
                const SizedBox(width: 44), // 与删除按钮等宽占位，卡片对齐
            ],
          ),
        ),
      ),
    );
  }
}

// ---------- Identity 编辑对话框 ----------

class _IdentityEditDialog extends StatefulWidget {
  const _IdentityEditDialog({required this.app, required this.item});

  final AppState app;
  final IdentityView item;

  @override
  State<_IdentityEditDialog> createState() => _IdentityEditDialogState();
}

class _IdentityEditDialogState extends State<_IdentityEditDialog> {
  late bool _usePassword = widget.item.hasPassword;
  late final _username = TextEditingController(text: widget.item.username);
  final _password = TextEditingController();
  // 引用的密钥已被他端删除（keyMissing）时 keyId 不在 items 里，直接喂给
  // DropdownButtonFormField 会触发"value 必须匹配唯一 item"断言（评审 BUG-5）：
  // 回退 null 并由提示文案告知重新选择。
  late String? _keyId = widget.app.keys.any((k) => k.id == widget.item.keyId)
      ? widget.item.keyId
      : null;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.app.updateIdentity(
        identity: widget.item,
        username: _username.text,
        usePassword: _usePassword,
        password: _password.text,
        keyId: _keyId,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.error);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final keys = widget.app.keys;
    return _DialogShell(
      title: '编辑凭据',
      width: 420,
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
              ? SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Et.primaryBtnText))
              : const Text('保存并同步'),
        ),
      ],
      children: [
        TextFormField(
          controller: _username,
          autocorrect: false,
          style: TextStyle(fontSize: 14, color: Et.textPrimary),
          decoration: _dec('用户名'),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _AuthKindOption(
                label: '密码认证',
                icon: Icons.password,
                selected: _usePassword,
                onTap: () => setState(() => _usePassword = true),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _AuthKindOption(
                label: '密钥认证',
                icon: Icons.key,
                selected: !_usePassword,
                onTap: () => setState(() => _usePassword = false),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_usePassword)
          TextFormField(
            controller: _password,
            obscureText: true,
            autocorrect: false,
            style: TextStyle(fontSize: 14, color: Et.textPrimary),
            decoration: _dec(widget.item.hasPassword ? '新密码（留空保留原密码）' : '密码'),
          )
        else ...[
          DropdownButtonFormField<String>(
            initialValue: _keyId,
            dropdownColor: Et.card,
            style: TextStyle(fontSize: 14, color: Et.textPrimary),
            decoration: _dec('选择 Keychain 密钥'),
            items: [
              for (final k in keys)
                DropdownMenuItem(
                    value: k.id,
                    child: Text('${k.label}（${k.keyType}）',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 14, color: Et.textPrimary))),
            ],
            onChanged: (v) => setState(() => _keyId = v),
          ),
          if (widget.app.identityKeyMissing(widget.item)) ...[
            const SizedBox(height: 6),
            Text('原密钥已不存在（可能在其他设备上被删除），请重新选择。',
                style: TextStyle(fontSize: 12, color: Et.danger)),
          ],
        ],
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text('保存失败: $_error',
              style:
                  TextStyle(fontSize: 12.5, color: Et.danger)),
        ],
        const SizedBox(height: 16),
      ],
    );
  }
}

/// 认证方式选择块（密码/密钥二选一）。
class _AuthKindOption extends StatelessWidget {
  const _AuthKindOption({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Et.mSelected : Et.card,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: onTap,
        child: Container(
          height: 42,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
                color: selected ? const Color(0xFF2C63D9) : Et.cardBorder),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 16,
                  color: selected ? const Color(0xFF2C63D9) : Et.textSecondary),
              const SizedBox(width: 7),
              Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w500,
                      color:
                          selected ? Et.textPrimary : Et.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------- 密钥卡片 ----------

class _KeyCard extends StatelessWidget {
  const _KeyCard({required this.item, required this.onTap, required this.onDelete});

  final KeyView item;
  final VoidCallback onTap;
  final VoidCallback? onDelete; // null = 引用中，不可删

  @override
  Widget build(BuildContext context) {
    final usedBy = item.usedBy.isEmpty
        ? '未被使用'
        : '被 ${item.usedBy.length} 台主机使用：${item.usedBy.join("、")}';
    return Material(
      color: Et.card,
      borderRadius: BorderRadius.circular(Et.cardRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(Et.cardRadius),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Et.cardRadius),
            border: Border.all(color: Et.cardBorder),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              const _IconTile(),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Et.textPrimary)),
                    const SizedBox(height: 3),
                    Text(usedBy,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            color: item.usedBy.isEmpty
                                ? Et.textSecondary
                                : const Color(0xFF2DA44E))),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 类型徽标
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F2F5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(item.keyType,
                    style: TextStyle(
                        fontSize: 11, color: Et.textSecondary)),
              ),
              if (onDelete != null)
                IconButton(
                  icon: Icon(Icons.delete_outline,
                      size: 18, color: Et.textSecondary),
                  tooltip: '删除密钥',
                  onPressed: onDelete,
                )
              else
                const SizedBox(width: 44), // 与删除按钮等宽占位，卡片对齐
            ],
          ),
        ),
      ),
    );
  }
}

class _IconTile extends StatelessWidget {
  const _IconTile();

  @override
  Widget build(BuildContext context) => Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFF2C63D9),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.key, color: Colors.white, size: 22),
      );
}

// ---------- 对话框公共壳 ----------

class _DialogShell extends StatelessWidget {
  const _DialogShell({required this.title, required this.width, required this.children, this.actions});

  final String title;
  final double width;
  final List<Widget> children;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Et.card,
      surfaceTintColor: Et.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 18),
      title: Text(title,
          style: TextStyle(
              fontSize: 18, fontWeight: FontWeight.w700, color: Et.textPrimary)),
      content: SizedBox(
        width: width,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
      actions: actions,
    );
  }
}

InputDecoration _dec(String label) => InputDecoration(
      labelText: label,
      labelStyle: TextStyle(fontSize: 13, color: Et.textSecondary),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    );

// ---------- 生成密钥对话框 ----------

class _GenerateKeyDialog extends StatefulWidget {
  const _GenerateKeyDialog({required this.app});

  final AppState app;

  @override
  State<_GenerateKeyDialog> createState() => _GenerateKeyDialogState();
}

class _GenerateKeyDialogState extends State<_GenerateKeyDialog> {
  final _label = TextEditingController();
  final _comment = TextEditingController();
  String _algorithm = 'ed25519';
  bool _busy = false;
  String? _error;

  /// 算法选项：value → 展示文案（PRD F4.2：Ed25519 / ECDSA / RSA）。
  static const _algorithms = [
    ('ed25519', 'Ed25519（推荐，快且安全）'),
    ('ecdsa-p256', 'ECDSA P-256'),
    ('rsa-2048', 'RSA 2048（兼容旧系统）'),
    ('rsa-3072', 'RSA 3072'),
    ('rsa-4096', 'RSA 4096（生成较慢）'),
  ];

  @override
  void dispose() {
    _label.dispose();
    _comment.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final label = _label.text.trim();
    if (label.isEmpty) {
      setState(() => _error = '请填写密钥名称');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.app.generateKey(
        label: label,
        comment: _comment.text.trim(),
        algorithm: _algorithm,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.error);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _DialogShell(
      title: '生成新密钥',
      width: 420,
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
              ? SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Et.primaryBtnText))
              : const Text('生成并同步'),
        ),
      ],
      children: [
        TextFormField(
          controller: _label,
          autofocus: true,
          autocorrect: false,
          style: TextStyle(fontSize: 14, color: Et.textPrimary),
          decoration: _dec('名称'),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _algorithm,
          dropdownColor: Et.card,
          style: TextStyle(fontSize: 14, color: Et.textPrimary),
          decoration: _dec('算法'),
          items: [
            for (final (value, label) in _algorithms)
              DropdownMenuItem(
                  value: value,
                  child: Text(label,
                      style: TextStyle(
                          fontSize: 14, color: Et.textPrimary))),
          ],
          onChanged: _busy ? null : (v) => setState(() => _algorithm = v!),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _comment,
          autocorrect: false,
          style: TextStyle(fontSize: 14, color: Et.textPrimary),
          decoration: _dec('备注（可选，如 user@host）'),
        ),
        const SizedBox(height: 8),
        Text(
          _algorithm == 'ed25519'
              ? 'OpenSSH 格式 · 生成后自动同步到所有设备'
              : 'PKCS#8 格式 · ${_algorithm.startsWith("rsa") ? "生成需要数秒" : "生成后"}自动同步到所有设备',
          style: TextStyle(fontSize: 12, color: Et.textSecondary),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text('生成失败: $_error',
              style:
                  TextStyle(fontSize: 12.5, color: Et.danger)),
        ],
        const SizedBox(height: 16),
      ],
    );
  }
}

// ---------- 导入密钥对话框 ----------

class _ImportKeyDialog extends StatefulWidget {
  const _ImportKeyDialog({required this.app});

  final AppState app;

  @override
  State<_ImportKeyDialog> createState() => _ImportKeyDialogState();
}

class _ImportKeyDialogState extends State<_ImportKeyDialog> {
  final _label = TextEditingController();
  final _pem = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    _pem.dispose();
    super.dispose();
  }

  Future<void> _pastePem() async {
    final text = await Clipboard.getData(Clipboard.kTextPlain);
    if (text?.text != null && text!.text!.trim().isNotEmpty) {
      setState(() => _pem.text = text.text!);
    }
  }

  Future<void> _pickFile() async {
    try {
      final f = await openFile();
      if (f == null) return;
      final text = await f.readAsString();
      if (text.trim().isNotEmpty && mounted) setState(() => _pem.text = text);
    } catch (e) {
      if (mounted) setState(() => _error = '读取文件失败: $e');
    }
  }

  Future<void> _submit() async {
    final label = _label.text.trim();
    if (label.isEmpty) {
      setState(() => _error = '请填写密钥名称');
      return;
    }
    if (_pem.text.trim().isEmpty) {
      setState(() => _error = '请粘贴私钥内容或选择文件');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.app.importKey(label: label, pem: _pem.text);
      if (!mounted) return;
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.error);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _DialogShell(
      title: '导入密钥',
      width: 480,
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
              ? SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Et.primaryBtnText))
              : const Text('导入并同步'),
        ),
      ],
      children: [
        TextFormField(
          controller: _label,
          autocorrect: false,
          style: TextStyle(fontSize: 14, color: Et.textPrimary),
          decoration: _dec('名称'),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _pem,
          autocorrect: false,
          obscureText: _obscure,
          minLines: 5,
          maxLines: 8,
          style: TextStyle(fontSize: 12.5, color: Et.textPrimary),
          decoration: _dec('私钥（OpenSSH / PKCS#8 PEM）').copyWith(
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(Icons.content_paste,
                      size: 17, color: Et.textSecondary),
                  tooltip: '粘贴',
                  onPressed: _pastePem,
                ),
                IconButton(
                  icon: Icon(Icons.folder_open,
                      size: 17, color: Et.textSecondary),
                  tooltip: '选择文件',
                  onPressed: _pickFile,
                ),
                IconButton(
                  icon: Icon(_obscure ? Icons.visibility_off : Icons.visibility,
                      size: 17, color: Et.textSecondary),
                  tooltip: _obscure ? '显示' : '隐藏',
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ],
            ),
            suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
          ),
        ),
        const SizedBox(height: 8),
        Text('带密码（passphrase）加密的私钥暂不支持；导入时会校验并提取类型与指纹',
            style: TextStyle(fontSize: 12, color: Et.textSecondary)),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text('导入失败: $_error',
              style:
                  TextStyle(fontSize: 12.5, color: Et.danger)),
        ],
        const SizedBox(height: 16),
      ],
    );
  }
}

// ---------- 密钥详情对话框 ----------

class _KeyDetailDialog extends StatefulWidget {
  const _KeyDetailDialog({
    required this.app,
    required this.item,
    required this.onDelete,
  });

  final AppState app;
  final KeyView item;
  final Future<void> Function(KeyView) onDelete;

  @override
  State<_KeyDetailDialog> createState() => _KeyDetailDialogState();
}

class _KeyDetailDialogState extends State<_KeyDetailDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action,
      {required String success}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(success)));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.error);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copy(String text, String tip) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tip)));
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: widget.item.label);
    final newLabel = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Et.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('重命名密钥',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary)),
        content: TextField(
          controller: controller,
          autofocus: true,
          autocorrect: false,
          style: TextStyle(fontSize: 14, color: Et.textPrimary),
          decoration: _dec('名称'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('取消', style: TextStyle(color: Et.textSecondary))),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(context, controller.text.trim()),
              style: FilledButton.styleFrom(
                  backgroundColor: Et.primaryBtn,
                  foregroundColor: Et.primaryBtnText,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9))),
              child: const Text('保存')),
        ],
      ),
    );
    if (newLabel == null || newLabel.isEmpty || newLabel == widget.item.label) return;
    await _run(() => widget.app.renameKey(widget.item, newLabel),
        success: '已重命名');
  }

  Future<void> _exportPem() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Et.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('导出私钥',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary)),
        content: Text(
            '私钥全文将复制到剪贴板。剪贴板可能被其他应用读取，用完后建议覆盖或清空。',
            style: TextStyle(fontSize: 13.5, height: 1.5, color: Et.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('取消', style: TextStyle(color: Et.textSecondary))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFB35900),
                  foregroundColor: Et.primaryBtnText,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9))),
              child: const Text('复制私钥')),
        ],
      ),
    );
    if (ok != true) return;
    final pem = widget.app.privateKeyPemOf(widget.item);
    if (pem == null || pem.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('本地没有该密钥内容（可能尚未同步）')));
      }
      return;
    }
    await _copy(pem, '私钥已复制到剪贴板');
  }

  Future<void> _deploy() async {
    final host = await showDialog<HostView>(
      context: context,
      builder: (_) => _DeployHostPickerDialog(app: widget.app),
    );
    if (host == null) return;
    await _run(() => widget.app.deployPublicKey(widget.item, host),
        success: '公钥已部署到 ${host.label}');
  }

  @override
  Widget build(BuildContext context) {
    final k = widget.item;
    return _DialogShell(
      title: k.label,
      width: 520,
      actions: [
        TextButton(
            onPressed: _busy ? null : _rename,
            child: Text('重命名', style: TextStyle(color: Et.textSecondary))),
        TextButton(
            onPressed: _busy ? null : _exportPem,
            child: Text('导出私钥', style: TextStyle(color: Et.textSecondary))),
        if (k.usedBy.isEmpty)
          TextButton(
              onPressed: _busy
                  ? null
                  : () async {
                      Navigator.pop(context); // 先关详情，删除确认再叠上来
                      await widget.onDelete(k);
                    },
              style: TextButton.styleFrom(foregroundColor: Et.danger),
              child: const Text('删除')),
        FilledButton.icon(
          // 旧版密钥无公钥内容：部署必假成功，禁用（评审 P1）
          onPressed: _busy || k.publicKey.trim().isEmpty ? null : _deploy,
          icon: const Icon(Icons.upload, size: 16),
          label: const Text('部署公钥'),
          style: FilledButton.styleFrom(
            backgroundColor: Et.primaryBtn,
            foregroundColor: Et.primaryBtnText,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
            minimumSize: const Size(0, 42),
          ),
        ),
      ],
      children: [
        Row(
          children: [
            const _IconTile(),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    k.usedBy.isEmpty
                        ? '未被使用'
                        : '被 ${k.usedBy.length} 台主机使用：${k.usedBy.join("、")}',
                    style: TextStyle(
                        fontSize: 12.5,
                        color: k.usedBy.isEmpty
                            ? Et.textSecondary
                            : const Color(0xFF2DA44E)),
                  ),
                  const SizedBox(height: 4),
                  Text('来源：${k.origin == 'generated' ? '本应用生成' : '导入'}',
                      style: TextStyle(
                          fontSize: 12, color: Et.textSecondary)),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F2F5),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(k.keyType,
                  style:
                      TextStyle(fontSize: 11, color: Et.textSecondary)),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _kvRow('指纹', k.fingerprint.isEmpty ? '—' : k.fingerprint,
            k.fingerprint.isEmpty ? null : () => _copy(k.fingerprint, '指纹已复制')),
        const SizedBox(height: 10),
        _kvRow('公钥', k.publicKey.isEmpty ? '—' : k.publicKey,
            k.publicKey.isEmpty ? null : () => _copy(k.publicKey, '公钥行已复制（authorized_keys 可直接粘贴）')),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text('操作失败: $_error',
              style:
                  TextStyle(fontSize: 12.5, color: Et.danger)),
        ],
        const SizedBox(height: 18),
      ],
    );
  }

  Widget _kvRow(String label, String value, VoidCallback? onCopy) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F8FA),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Et.cardBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: Text(label,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Et.textSecondary)),
          ),
          Expanded(
            child: SelectableText(value,
                style: TextStyle(
                    fontSize: 12.5, height: 1.4, color: Et.textPrimary)),
          ),
          if (onCopy != null)
            InkWell(
              onTap: onCopy,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.copy, size: 15, color: Et.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------- 部署公钥：目标主机选择 ----------

class _DeployHostPickerDialog extends StatelessWidget {
  const _DeployHostPickerDialog({required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    final hosts = app.hosts;
    return AlertDialog(
      backgroundColor: Et.card,
      surfaceTintColor: Et.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titlePadding: const EdgeInsets.fromLTRB(24, 22, 24, 4),
      contentPadding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      actionsPadding: const EdgeInsets.fromLTRB(24, 4, 24, 14),
      title: Text('部署公钥到目标机',
          style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Et.textPrimary)),
      content: SizedBox(
        width: 420,
        height: hosts.isEmpty ? 120 : 320,
        child: hosts.isEmpty
            ? Center(
                child: Text('还没有主机',
                    style: TextStyle(fontSize: 13, color: Et.textSecondary)),
              )
            : ListView.builder(
                itemCount: hosts.length,
                itemBuilder: (context, i) {
                  final h = hosts[i];
                  final usable = app.credentialFor(h).available;
                  return ListTile(
                    enabled: usable,
                    dense: true,
                    leading: Icon(
                        usable ? Icons.dns_outlined : Icons.lock_outline,
                        size: 20,
                        color: usable ? Et.primaryBtn : Et.textSecondary),
                    title: Text(h.label,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Et.textPrimary)),
                    subtitle: Text('${h.username}@${h.hostname}:${h.port}',
                        style: TextStyle(
                            fontSize: 12, color: Et.textSecondary)),
                    trailing: usable
                        ? null
                        : Text('无凭据',
                            style: TextStyle(
                                fontSize: 11, color: Et.textSecondary)),
                    onTap:
                        usable ? () => Navigator.pop(context, h) : null,
                  );
                },
              ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消', style: TextStyle(color: Et.textSecondary))),
      ],
    );
  }
}

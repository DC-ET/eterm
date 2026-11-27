// 端口转发页（M2）：port_rule 实体管理 + local(-L) 转发运行控制。
// 规则随 vault 同步；运行状态是本机运行时状态（不入中枢）。
// Rust 数据面：pf_connect（独立 SSH 连接，TOFU 同终端）→ pf_listen 起
// TcpListener → direct-tcpip 通道双向拷贝。

import 'package:eterm/src/rust/api/portfw.dart' as pf;
import 'package:material_ui/material_ui.dart';

import '../services/api_client.dart';
import '../services/app_state.dart';
import 'theme.dart';
import 'ui_utils.dart';

/// pf FFI 传输层：生产绑定真实 Rust 绑定；测试注入记录器驱动「启动/停止/删除」
/// 全链路（评审 BUG-3 回归：删除运行中规则必须停掉监听与 SSH 会话）。
class PfTransport {
  const PfTransport();

  Future<BigInt> connect({
    required String host,
    required int port,
    required String user,
    required String authKind,
    required String secret,
  }) =>
      pf.pfConnect(
        host: host,
        port: port,
        user: user,
        authKind: authKind,
        secret: secret,
      );

  Future<BigInt> listen({
    required BigInt sessionId,
    required String bindAddr,
    required int localPort,
    required String remoteHost,
    required int remotePort,
  }) =>
      pf.pfListen(
        sessionId: sessionId,
        bindAddr: bindAddr,
        localPort: localPort,
        remoteHost: remoteHost,
        remotePort: remotePort,
      );

  void closeForward({required BigInt sessionId, required BigInt forwardId}) =>
      pf.pfCloseForward(sessionId: sessionId, forwardId: forwardId);

  void disconnect({required BigInt sessionId}) =>
      pf.pfDisconnect(sessionId: sessionId);
}

class PortForwardingPage extends StatefulWidget {
  const PortForwardingPage({super.key, required this.app, this.transport});

  final AppState app;

  /// pf FFI 传输层（默认真实绑定；测试注入替身，评审 BUG-3 回归用例）。
  @visibleForTesting
  final PfTransport? transport;

  @override
  State<PortForwardingPage> createState() => _PortForwardingPageState();
}

class _PortForwardingPageState extends State<PortForwardingPage> {
  /// 运行时状态（本机）：hostId → pf 会话；ruleId → 转发实例。
  final _sessions = <String, BigInt>{};
  final _forwards = <String, BigInt>{};
  final _busy = <String>{}; // 启动/停止中的规则

  PfTransport get _pf => widget.transport ?? const PfTransport();

  @override
  void dispose() {
    for (final s in _sessions.values) {
      try {
        _pf.disconnect(sessionId: s);
      } catch (_) {}
    }
    super.dispose();
  }

  HostView? _hostOf(PortRuleView r) {
    for (final h in widget.app.hosts) {
      if (h.id == r.hostId) return h;
    }
    return null;
  }

  Future<void> _start(PortRuleView r) async {
    if (_busy.contains(r.id) || _forwards.containsKey(r.id)) return;
    if (!r.enabled) {
      _err('规则已停用，编辑规则并勾选「启用规则」后再启动');
      return;
    }
    final host = _hostOf(r);
    if (host == null) {
      _err('找不到规则对应的主机（可能已删除）');
      return;
    }
    final cred = widget.app.credentialFor(host);
    if (cred == null) {
      _err('主机「${host.label}」没有可用凭据');
      return;
    }
    if (r.localPort == null || r.remoteHost == null || r.remotePort == null) {
      _err('规则不完整（需要本地端口与远端目标）');
      return;
    }
    setState(() => _busy.add(r.id));
    try {
      var session = _sessions[host.id];
      session ??= await _pf.connect(
        host: host.hostname,
        port: host.port,
        user: host.username,
        authKind: cred.authKind,
        secret: cred.secret,
      );
      _sessions[host.id] = session;
      final fwd = await _pf.listen(
        sessionId: session,
        bindAddr: r.bindAddr,
        localPort: r.localPort!,
        remoteHost: r.remoteHost!,
        remotePort: r.remotePort!,
      );
      if (!mounted) return;
      setState(() => _forwards[r.id] = fwd);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('转发已启动：${r.bindAddr}:${r.localPort} → ${r.remoteHost}:${r.remotePort}'),
      ));
    } catch (e) {
      _err('启动失败: $e');
    } finally {
      if (mounted) setState(() => _busy.remove(r.id));
    }
  }

  Future<void> _stop(PortRuleView r) async {
    if (_busy.contains(r.id)) return;
    final fwd = _forwards.remove(r.id);
    if (fwd == null) return;
    setState(() => _busy.add(r.id));
    try {
      final host = _hostOf(r);
      final session = host == null ? null : _sessions[host.id];
      if (host != null && session != null) {
        final hostId = host.id;
        _pf.closeForward(sessionId: session, forwardId: fwd);
        // 该会话上没有其他运行中的规则 → 一并断开 SSH
        final stillUsed = _forwards.keys.any((rid) {
          final other =
              widget.app.portRules.where((x) => x.id == rid).firstOrNull;
          return other != null && other.hostId == hostId;
        });
        if (!stillUsed) {
          _pf.disconnect(sessionId: session);
          _sessions.remove(hostId);
        }
      }
    } finally {
      if (mounted) setState(() => _busy.remove(r.id));
    }
  }

  void _err(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _showEditor([PortRuleView? existing]) async {
    final hosts = widget.app.hosts;
    if (hosts.isEmpty) {
      _err('先在 Hosts 页添加主机，再配置端口转发');
      return;
    }
    await showDialog<bool>(
      context: context,
      builder: (_) => _RuleDialog(
        app: widget.app,
        hosts: hosts,
        existing: existing,
      ),
    );
  }

  Future<void> _confirmDelete(PortRuleView r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Et.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('删除规则',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary)),
        content: Text('将从 vault 中删除规则「${r.label}」。此操作会同步到所有设备。',
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
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    // 停止运行中的转发（评审 BUG-3）：不得先 remove 再调 _stop——_stop 以 remove
    // 返回值判空早退，预摘除会让 pf_close_forward/pf_disconnect 永不执行，
    // 被删规则的监听端口与 SSH 隧道变成不可见的僵尸转发。
    if (_forwards.containsKey(r.id)) await _stop(r);
    try {
      await widget.app.deletePortRule(r);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败: ${e.error}')));
      }
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
              if (!compact)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                  child: Text('Port Forwarding',
                      style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w700,
                          color: Et.textPrimary)),
                ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                    compact ? 14 : 20, 14, compact ? 14 : 20, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.compare_arrows,
                        size: 17, color: Et.textSecondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '本地转发（-L）：监听本机端口，经 SSH 隧道转到大网/内网目标。'
                        '规则随 vault 同步，运行状态仅在本机。',
                        style: TextStyle(
                            fontSize: 12.5,
                            height: 1.45,
                            color: Et.textSecondary),
                      ),
                    ),
                    // 桌面：头部按钮（与 Keychain 同范式）；手机走 FAB（评审 P2）
                    if (!compact) ...[
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: _showEditor,
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('新建规则'),
                        style: FilledButton.styleFrom(
                          backgroundColor: Et.primaryBtn,
                          foregroundColor: Et.primaryBtnText,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(9)),
                          minimumSize: const Size(0, 38),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: ListenableBuilder(
                  listenable: widget.app,
                  builder: (context, _) {
                    if (widget.app.error == 'unauthorized') {
                      return const SizedBox.shrink();
                    }
                    final rules = widget.app.portRules;
                    if (rules.isEmpty) return _emptyState;
                    return ListView(
                      padding: EdgeInsets.fromLTRB(compact ? 14 : 20, 4,
                          compact ? 14 : 20, compact ? 84 : 20),
                      children: [
                        for (final r in rules)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _RuleCard(
                              rule: r,
                              hostLabel: _hostOf(r)?.label,
                              running: _forwards.containsKey(r.id),
                              busy: _busy.contains(r.id),
                              onStart: () => _start(r),
                              onStop: () => _stop(r),
                              onTap: () => _showEditor(r),
                              onDelete: () => _confirmDelete(r),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
          // 手机：FAB 新建（桌面已收敛到头部按钮，与 Keychain 一致）
          if (compact)
            Positioned(
              right: 18,
              bottom: 18,
              child: FloatingActionButton(
                heroTag: 'pf-add',
                backgroundColor: Et.primaryBtn,
                foregroundColor: Et.primaryBtnText,
                elevation: 2,
                onPressed: _showEditor,
                child: const Icon(Icons.add, size: 26),
              ),
            ),
        ],
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
              child: Icon(Icons.compare_arrows,
                  size: 30, color: Et.textSecondary),
            ),
            const SizedBox(height: 14),
            Text('还没有转发规则',
                style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    color: Et.textPrimary)),
            const SizedBox(height: 5),
            Text('新建一条 -L 规则，把内网服务映射到本机端口',
                style: TextStyle(fontSize: 13, color: Et.textSecondary)),
            const SizedBox(height: 14),
            // 空态直接给 CTA（评审 P2：此前手机端空态无可见入口）
            FilledButton.icon(
              onPressed: _showEditor,
              icon: const Icon(Icons.add, size: 17),
              label: const Text('新建规则'),
              style: FilledButton.styleFrom(
                backgroundColor: Et.primaryBtn,
                foregroundColor: Et.primaryBtnText,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9)),
                minimumSize: const Size(0, 38),
              ),
            ),
          ],
        ),
      );
}

class _RuleCard extends StatelessWidget {
  const _RuleCard({
    required this.rule,
    required this.hostLabel,
    required this.running,
    required this.busy,
    required this.onStart,
    required this.onStop,
    required this.onTap,
    required this.onDelete,
  });

  final PortRuleView rule;
  final String? hostLabel;
  final bool running;
  final bool busy;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final supported = rule.kind == 'local';
    final target =
        '${rule.remoteHost ?? '?'}:${rule.remotePort ?? '?'}';
    final listen = '${rule.bindAddr}:${rule.localPort ?? '?'}';
    return Material(
      color: Et.card,
      borderRadius: BorderRadius.circular(Et.cardRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(Et.cardRadius),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Et.cardRadius),
            border: Border.all(
                color: running ? const Color(0xFF2DA44E) : Et.cardBorder,
                width: running ? 1.2 : 1),
          ),
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(
            children: [
              _IconTile(running: running),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(rule.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Et.textPrimary)),
                      ),
                      const SizedBox(width: 8),
                      if (!supported)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Et.surfaceMuted,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text('暂不支持启动',
                              style: TextStyle(
                                  fontSize: 10.5,
                                  color: Et.textSecondary)),
                        ),
                      // 幽灵开关修复：enabled=false 之前无任何可见状态（评审 P1）
                      if (supported && !rule.enabled)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Et.surfaceMuted,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text('已停用',
                              style: TextStyle(
                                  fontSize: 10.5,
                                  color: Et.textSecondary)),
                        ),
                    ]),
                    const SizedBox(height: 3),
                    Text('$listen → $target（经 ${hostLabel ?? '未知主机'}）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontFamily: 'Menlo',
                            fontSize: 12,
                            color: Et.textSecondary)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 启动/停止
              SizedBox(
                height: 32,
                child: FilledButton.tonal(
                  onPressed: !supported || !rule.enabled || busy
                      ? null
                      : (running ? onStop : onStart),
                  style: FilledButton.styleFrom(
                    backgroundColor:
                        running ? Et.card : Et.primaryBtn,
                    foregroundColor:
                        running ? Et.textSecondary : Et.primaryBtnText,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9)),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  child: busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(running ? '停止' : '启动',
                          style: const TextStyle(fontSize: 13)),
                ),
              ),
              IconButton(
                icon: Icon(Icons.delete_outline,
                    size: 18, color: Et.textSecondary),
                tooltip: '删除规则',
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconTile extends StatelessWidget {
  const _IconTile({required this.running});

  final bool running;

  @override
  Widget build(BuildContext context) => Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: running ? const Color(0xFF2DA44E) : const Color(0xFF6B7280),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          running ? Icons.swap_horiz : Icons.compare_arrows,
          color: Colors.white,
          size: 22,
        ),
      );
}

/// 新建/编辑规则对话框（M2：kind 固定 local）。
class _RuleDialog extends StatefulWidget {
  const _RuleDialog({
    required this.app,
    required this.hosts,
    required this.existing,
  });

  final AppState app;
  final List<HostView> hosts;
  final PortRuleView? existing;

  @override
  State<_RuleDialog> createState() => _RuleDialogState();
}

class _RuleDialogState extends State<_RuleDialog> {
  late final TextEditingController _label =
      TextEditingController(text: widget.existing?.label ?? '');
  late final TextEditingController _bind =
      TextEditingController(text: widget.existing?.bindAddr ?? '127.0.0.1');
  late final TextEditingController _localPort = TextEditingController(
      text: widget.existing?.localPort?.toString() ?? '');
  late final TextEditingController _remoteHost = TextEditingController(
      text: widget.existing?.remoteHost ?? '');
  late final TextEditingController _remotePort = TextEditingController(
      text: widget.existing?.remotePort?.toString() ?? '');
  late String? _hostId =
      widget.existing?.hostId ?? (widget.hosts.isNotEmpty ? widget.hosts.first.id : null);
  late bool _enabled = widget.existing?.enabled ?? true;
  bool _saving = false;
  String? _error;

  final _formKey = GlobalKey<FormState>();

  Future<void> _save() async {
    if (_formKey.currentState?.validate() != true) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.app.savePortRule(
        existing: widget.existing,
        hostId: _hostId!,
        label: _label.text.trim(),
        kind: 'local',
        bindAddr: _bind.text.trim().isEmpty ? '127.0.0.1' : _bind.text.trim(),
        localPort: int.parse(_localPort.text.trim()),
        remoteHost: _remoteHost.text.trim(),
        remotePort: int.parse(_remotePort.text.trim()),
        enabled: _enabled,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      setState(() {
        _saving = false;
        _error = e.error;
      });
    } catch (e) {
      setState(() {
        _saving = false;
        _error = '$e';
      });
    }
  }

  @override
  void dispose() {
    _label.dispose();
    _bind.dispose();
    _localPort.dispose();
    _remoteHost.dispose();
    _remotePort.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Et.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(widget.existing == null ? '新建转发规则' : '编辑转发规则',
          style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: Et.textPrimary)),
      content: SizedBox(
        width: dialogWidth(420, context),
        child: Form(
          key: _formKey,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            DropdownButtonFormField<String>(
              initialValue: _hostId,
              decoration: const InputDecoration(labelText: '经哪台主机（SSH 跳板）'),
              items: [
                for (final h in widget.hosts)
                  DropdownMenuItem(
                      value: h.id,
                      child: Text('${h.label}（${h.hostname}）',
                          maxLines: 1, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => _hostId = v),
              validator: (v) => v == null ? '必选' : null,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _label,
              maxLength: 60,
              decoration: const InputDecoration(
                  labelText: '名称', hintText: '如：内网数据库', counterText: ''),
              validator: (v) => (v == null || v.trim().isEmpty) ? '必填' : null,
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                flex: 2,
                child: TextFormField(
                  controller: _bind,
                  decoration:
                      const InputDecoration(labelText: '监听地址'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextFormField(
                  controller: _localPort,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '本地端口'),
                  validator: (v) {
                    final p = int.tryParse(v ?? '');
                    if (p == null || p < 1 || p > 65535) return '1-65535';
                    return null;
                  },
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                flex: 2,
                child: TextFormField(
                  controller: _remoteHost,
                  decoration: const InputDecoration(
                      labelText: '目标地址', hintText: '从跳板看的目标，如 10.0.0.5'),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? '必填' : null,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextFormField(
                  controller: _remotePort,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '目标端口'),
                  validator: (v) {
                    final p = int.tryParse(v ?? '');
                    if (p == null || p < 1 || p > 65535) return '1-65535';
                    return null;
                  },
                ),
              ),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v),
              title: Text('启用规则',
                  style: TextStyle(fontSize: 14, color: Et.textPrimary)),
              subtitle: Text('停用后卡片会标记「已停用」且无法启动',
                  style: TextStyle(fontSize: 12, color: Et.textSecondary)),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(_error!,
                    style: TextStyle(
                        fontSize: 12.5, color: Et.danger)),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消', style: TextStyle(color: Et.textSecondary))),
        FilledButton(
          onPressed: _saving ? null : _save,
          style: FilledButton.styleFrom(
              backgroundColor: Et.primaryBtn,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9))),
          child: _saving
              ? const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('保存'),
        ),
      ],
    );
  }
}

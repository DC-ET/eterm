// Known Hosts 页（F4.4）：TOFU 主机信任列表。
// 展示本设备已记录的 SSH 服务器指纹；删除后下次连接重新首连记录。
// 桌面/移动共用单列布局（列表页天然一列，仅边距随断点变化）。

import 'package:eterm/src/rust/api/ssh.dart' as ssh;
import 'package:eterm/src/rust/store.dart' as store;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'theme.dart';
import 'ui_utils.dart';

class KnownHostsPage extends StatefulWidget {
  const KnownHostsPage({super.key});

  @override
  State<KnownHostsPage> createState() => _KnownHostsPageState();
}

class _KnownHostsPageState extends State<KnownHostsPage> {
  List<store.KnownHost>? _items; // null = 加载中

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    try {
      setState(() => _items = ssh.knownHostsList());
    } catch (e) {
      setState(() => _items = []);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('读取失败: $e')),
        );
      }
    }
  }

  Future<void> _confirmRemove(store.KnownHost item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Et.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('移除主机信任',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary)),
        content: Text(
            '将从本设备移除「${item.host}」的指纹记录。下次连接时将重新首连记录（若服务器键在此期间被替换，将无法察觉）。',
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
              child: const Text('移除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      ssh.knownHostsRemove(host: item.host);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('移除失败: $e')),
        );
      }
      return;
    }
    _reload();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已移除主机信任')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    final items = _items;
    return Container(
      color: Et.contentBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!compact)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
              child: Text('Known Hosts',
                  style: TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                      color: Et.textPrimary)),
            ),
          // 说明条：TOFU 机制一句话
          Padding(
            padding:
                EdgeInsets.fromLTRB(compact ? 14 : 20, 14, compact ? 14 : 20, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.verified_user_outlined,
                    size: 17, color: Et.textSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '首次连接的 SSH 服务器指纹会自动记录在这里；后续连接逐次比对，'
                    '不一致将被拒绝（防中间人替换）。',
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: Et.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: items == null
                ? const Center(
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2)))
                : items.isEmpty
                    ? _emptyState
                    : ListView(
                        padding: EdgeInsets.fromLTRB(
                            compact ? 14 : 20, 4, compact ? 14 : 20, 20),
                        children: [
                          for (final item in items)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: _KnownHostCard(
                                item: item,
                                onRemove: () => _confirmRemove(item),
                              ),
                            ),
                        ],
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
              child: Icon(Icons.fingerprint,
                  size: 30, color: Et.textSecondary),
            ),
            const SizedBox(height: 14),
            Text('还没有已信任的服务器',
                style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    color: Et.textPrimary)),
            const SizedBox(height: 5),
            Text('首次连接 SSH 服务器时，其指纹会自动记录到此处',
                style: TextStyle(fontSize: 13, color: Et.textSecondary)),
          ],
        ),
      );
}

class _KnownHostCard extends StatelessWidget {
  const _KnownHostCard({required this.item, required this.onRemove});

  final store.KnownHost item;
  final VoidCallback onRemove;

  Future<void> _copyFingerprint(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: item.fingerprint));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('指纹已复制')));
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Et.card,
      borderRadius: BorderRadius.circular(Et.cardRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(Et.cardRadius),
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
                    Text(item.host,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Et.textPrimary)),
                    const SizedBox(height: 3),
                    // 指纹：等宽字体（防混淆）
                    Text(item.fingerprint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            fontFamily: 'Menlo',
                            color: Et.textSecondary)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(Icons.copy, size: 15, color: Et.textSecondary),
                tooltip: '复制指纹',
                onPressed: () => _copyFingerprint(context),
              ),
              Text(fmtLocalTime(item.firstSeen),
                  style: TextStyle(
                      fontSize: 11.5, color: Et.textSecondary)),
              IconButton(
                icon: Icon(Icons.delete_outline,
                    size: 18, color: Et.textSecondary),
                tooltip: '移除信任',
                onPressed: onRemove,
              ),
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
          color: Et.titleBar,
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.fingerprint, color: Colors.white, size: 22),
      );
}

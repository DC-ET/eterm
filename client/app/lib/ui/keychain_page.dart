// Keychain 页（M1）：密钥统一管理列表。
// 展示中枢 ssh_key 实体（label/类型/指纹）+ 反向引用（使用它的主机）；
// 仅未被引用的密钥可删（引用中的删除会造成 identity 悬空连累主机）。
// 导入新密钥走主机新建/编辑的凭据域，此处不重复入口。

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
  Future<void> _confirmDelete(KeyView k) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除密钥',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary)),
        content: Text(
            '将从 vault 中删除密钥「${k.label}」（${k.keyType}）。此操作会同步到所有设备。',
            style: const TextStyle(
                fontSize: 13.5, height: 1.5, color: Et.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child:
                  const Text('取消', style: TextStyle(color: Et.textSecondary))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFD1242F),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9))),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.app.deleteKey(k);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: ${e.error}')),
        );
      }
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('密钥已删除并同步')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    return Container(
      color: Et.contentBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 说明条
          Padding(
            padding: EdgeInsets.fromLTRB(
                compact ? 14 : 20, 14, compact ? 14 : 20, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.key_outlined,
                    size: 17, color: Et.textSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '导入新密钥：在主机的「编辑 → 认证 → 私钥」粘贴 PEM 即可，密钥会同步到你的所有设备。',
                    style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: Et.textSecondary),
                  ),
                ),
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
                          onDelete: k.usedBy.isEmpty ? () => _confirmDelete(k) : null,
                        ),
                      ),
                  ],
                );
              },
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
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Et.cardBorder),
              ),
              child: const Icon(Icons.key_outlined,
                  size: 30, color: Et.textSecondary),
            ),
            const SizedBox(height: 14),
            const Text('还没有密钥',
                style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    color: Et.textPrimary)),
            const SizedBox(height: 5),
            const Text('在主机的新建/编辑里粘贴 PEM 私钥，即会收录到此处',
                style: TextStyle(fontSize: 13, color: Et.textSecondary)),
          ],
        ),
      );
}

class _KeyCard extends StatelessWidget {
  const _KeyCard({required this.item, required this.onDelete});

  final KeyView item;
  final VoidCallback? onDelete; // null = 引用中，不可删

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      item.keyType,
      if (item.fingerprint.isNotEmpty) item.fingerprint,
    ].join(' · ');
    final usedBy = item.usedBy.isEmpty
        ? '未被使用'
        : '被 ${item.usedBy.length} 台主机使用：${item.usedBy.join("、")}';
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
                    Text(item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F2F5),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(item.keyType,
                    style: const TextStyle(
                        fontSize: 11, color: Et.textSecondary)),
              ),
              if (onDelete != null)
                IconButton(
                  icon: const Icon(Icons.delete_outline,
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

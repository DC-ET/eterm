// Snippets 页（M2）：常用命令片段库，随 vault 同步到所有设备。
// 服务端 snippet 实体（description/script），wire 契约见 server/src/store/entities.ts。
// 终端内插入入口在终端附加键条（_ExtraKeysBar 的 code 键）。

import 'package:eterm/src/rust/api/local.dart' as local;
import 'package:material_ui/material_ui.dart';

import '../services/api_client.dart';
import '../services/app_state.dart';
import 'theme.dart';

class SnippetsPage extends StatefulWidget {
  const SnippetsPage({super.key, required this.app});

  final AppState app;

  @override
  State<SnippetsPage> createState() => _SnippetsPageState();
}

class _SnippetsPageState extends State<SnippetsPage> {
  /// 新建/编辑对话框。existing == null 为新建。
  Future<void> _showEditor([SnippetView? existing]) async {
    final descCtrl = TextEditingController(text: existing?.description ?? '');
    final scriptCtrl = TextEditingController(text: existing?.script ?? '');
    final formKey = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(existing == null ? '新建片段' : '编辑片段',
            style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary)),
        content: Form(
          key: formKey,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(
              controller: descCtrl,
              autofocus: existing == null,
              maxLength: 120,
              decoration: const InputDecoration(
                labelText: '名称',
                hintText: '如：查看磁盘占用',
                counterText: '',
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '必填' : null,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: scriptCtrl,
              maxLines: 6,
              maxLength: 64 * 1024,
              style: const TextStyle(
                  fontFamily: 'Menlo', fontSize: 12.5, height: 1.45),
              decoration: const InputDecoration(
                labelText: '命令',
                hintText: '支持多行脚本，插入终端后手动回车执行',
                counterText: '',
                alignLabelWithHint: true,
              ),
              validator: (v) =>
                  (v == null || v.isEmpty) ? '必填' : null,
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child:
                  const Text('取消', style: TextStyle(color: Et.textSecondary))),
          FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() != true) return;
                Navigator.pop(ctx, true);
              },
              style: FilledButton.styleFrom(
                  backgroundColor: Et.primaryBtn,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9))),
              child: const Text('保存')),
        ],
      ),
    );
    descCtrl.dispose();
    scriptCtrl.dispose();
    if (ok != true) return;
    try {
      await widget.app.saveSnippet(
        existing: existing,
        description: descCtrl.text.trim(),
        script: scriptCtrl.text,
      );
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败: ${e.error}')));
      }
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('片段已保存并同步')));
    }
  }

  Future<void> _confirmDelete(SnippetView s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除片段',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary)),
        content: Text('将从 vault 中删除片段「${s.description}」。此操作会同步到所有设备。',
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
      await widget.app.deleteSnippet(s);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败: ${e.error}')));
      }
      return;
    }
    try {
      local.logEvent(kind: 'snippet_delete', detail: s.description);
    } catch (_) {}
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('片段已删除并同步')));
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
              // 说明条
              Padding(
                padding: EdgeInsets.fromLTRB(
                    compact ? 14 : 20, 14, compact ? 14 : 20, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.code, size: 17, color: Et.textSecondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '常用命令存成片段，随 vault 同步到所有设备；连接终端后可一键插入。',
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
                    final snippets = widget.app.snippets;
                    if (snippets.isEmpty) return _emptyState;
                    return ListView(
                      padding: EdgeInsets.fromLTRB(compact ? 14 : 20, 4,
                          compact ? 14 : 20, compact ? 84 : 20),
                      children: [
                        for (final s in snippets)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _SnippetCard(
                              item: s,
                              onTap: () => _showEditor(s),
                              onDelete: () => _confirmDelete(s),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
          // 桌面：右下添加按钮（手机用底部导航回到 Hosts 页的布局约定，此页也直接给 FAB）
          Positioned(
            right: compact ? 18 : 24,
            bottom: compact ? 18 : 24,
            child: FloatingActionButton(
              heroTag: 'snippet-add',
              backgroundColor: Et.primaryBtn,
              foregroundColor: Colors.white,
              elevation: 2,
              onPressed: () => _showEditor(),
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
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Et.cardBorder),
              ),
              child: const Icon(Icons.code,
                  size: 30, color: Et.textSecondary),
            ),
            const SizedBox(height: 14),
            const Text('还没有片段',
                style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    color: Et.textPrimary)),
            const SizedBox(height: 5),
            const Text('把常用命令存成片段，终端里一键插入',
                style: TextStyle(fontSize: 13, color: Et.textSecondary)),
          ],
        ),
      );
}

class _SnippetCard extends StatelessWidget {
  const _SnippetCard({
    required this.item,
    required this.onTap,
    required this.onDelete,
  });

  final SnippetView item;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final preview = item.script.trim();
    final lines = preview.split('\n');
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
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _IconTile(),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Et.textPrimary)),
                    const SizedBox(height: 5),
                    // 命令预览：等宽字体，最多两行
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF6F7F9),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        lines.length > 2
                            ? '${lines.take(2).join('\n')}\n…'
                            : preview,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontFamily: 'Menlo',
                            fontSize: 12,
                            height: 1.5,
                            color: Et.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline,
                    size: 18, color: Et.textSecondary),
                tooltip: '删除片段',
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
  const _IconTile();

  @override
  Widget build(BuildContext context) => Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFF0E7A5F),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Icon(Icons.code, color: Colors.white, size: 22),
      );
}

// Logs 页（M1）：本设备事件时间线（连接/主机/密钥动作，本地存储，最多 500 条）。
// 跨设备审计随 M2 WS 同步设计后接入。

import 'package:eterm/src/rust/api/local.dart' as local;
import 'package:eterm/src/rust/store.dart' as store;
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  List<store.EventRow>? _items; // null = 加载中

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    try {
      setState(() => _items = local.eventsList());
    } catch (e) {
      setState(() => _items = []);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('读取失败: $e')));
      }
    }
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Et.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('清空日志',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary)),
        content: Text('将清空本设备的全部事件记录（不影响服务器与其他设备）。',
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
                  backgroundColor: Et.primaryBtn,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9))),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      local.eventsClear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('清空失败: $e')));
      }
      return;
    }
    _reload();
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
          // 说明 + 清空
          Padding(
            padding: EdgeInsets.fromLTRB(
                compact ? 14 : 20, 14, compact ? 14 : 20, 8),
            child: Row(
              children: [
                Icon(Icons.history, size: 17, color: Et.textSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '本设备事件（最多保留 500 条）：连接、主机与密钥变更。仅存本地。',
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: Et.textSecondary),
                  ),
                ),
                if (items != null && items.isNotEmpty)
                  InkWell(
                    onTap: _confirmClear,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      child: Text('清空',
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: Et.textSecondary)),
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
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 64,
                              height: 64,
                              decoration: BoxDecoration(
                                color: Et.card,
                                borderRadius: BorderRadius.circular(20),
                                border:
                                    Border.all(color: Et.cardBorder),
                              ),
                              child: Icon(Icons.history,
                                  size: 30, color: Et.textSecondary),
                            ),
                            const SizedBox(height: 14),
                            Text('还没有事件',
                                style: TextStyle(
                                    fontSize: 15.5,
                                    fontWeight: FontWeight.w600,
                                    color: Et.textPrimary)),
                            const SizedBox(height: 5),
                            Text('连接主机或修改数据后会记录在这里',
                                style: TextStyle(
                                    fontSize: 13,
                                    color: Et.textSecondary)),
                          ],
                        ),
                      )
                    : ListView(
                        padding: EdgeInsets.fromLTRB(compact ? 14 : 20, 4,
                            compact ? 14 : 20, 20),
                        children: [
                          for (final e in items)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _EventCard(item: e),
                            ),
                        ],
                      ),
          ),
        ],
      ),
    );
  }
}

class _EventCard extends StatelessWidget {
  const _EventCard({required this.item});

  final store.EventRow item;

  (IconData, Color, String) get _style {
    switch (item.kind) {
      case 'connect_ok':
        return (Icons.play_arrow_rounded, const Color(0xFF2DA44E), '连接');
      case 'connect_fail':
        return (Icons.error_outline, Et.danger, '连接失败');
      case 'disconnect':
        return (Icons.stop_rounded, const Color(0xFFC77B27), '断开');
      case 'host_add':
        return (Icons.add_circle_outline, Et.tileGroup, '新建主机');
      case 'host_edit':
        return (Icons.edit_outlined, Et.tileGroup, '编辑主机');
      case 'host_delete':
        return (Icons.delete_outline, Et.danger, '删除主机');
      case 'key_delete':
        return (Icons.key_off, Et.danger, '删除密钥');
    }
    return (Icons.circle, Et.textSecondary, item.kind);
  }

  /// UTC → 本地显示（HH:mm:ss，日期变化才带日期）
  String get _timeText {
    try {
      final t = DateTime.parse(item.ts).toLocal();
      final hh = t.hour.toString().padLeft(2, '0');
      final mm = t.minute.toString().padLeft(2, '0');
      final ss = t.second.toString().padLeft(2, '0');
      return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} $hh:$mm:$ss';
    } catch (_) {
      return item.ts;
    }
  }

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = _style;
    return Material(
      color: Et.card,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Et.cardBorder),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 9),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F2F5),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(label,
                  style: TextStyle(
                      fontSize: 11, color: Et.textSecondary)),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(item.detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13, color: Et.textPrimary)),
            ),
            const SizedBox(width: 8),
            Text(_timeText,
                style: TextStyle(
                    fontSize: 11, color: Et.textSecondary)),
          ],
        ),
      ),
    );
  }
}

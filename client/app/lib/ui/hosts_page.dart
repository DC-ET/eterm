// Hosts 页（Termius 式）：搜索 + Connect、工具栏、分组/主机卡片网格。
// 卡片：点击连接、右键/长按快捷菜单（连接/编辑/删除）；有打开终端的主机显示状态点。

import 'package:material_ui/material_ui.dart';

import '../services/api_client.dart';
import '../services/app_state.dart';
import 'add_host_dialog.dart';
import 'theme.dart';
import 'ui_utils.dart' show fmtLocalDateTime, fmtRelativeTime;

class HostsPage extends StatefulWidget {
  const HostsPage({
    super.key,
    required this.app,
    required this.onOpenTerminal,
    required this.openHostIds,
    required this.onOpenSettings,
    required this.onOpenSftp,
  });

  final AppState app;
  final void Function(HostView) onOpenTerminal;
  final Set<String> openHostIds; // 已开终端标签的主机 id
  final VoidCallback onOpenSettings; // 手机 app bar 齿轮 → 设置页（任务清单 #5）
  final void Function(HostView) onOpenSftp; // 卡片菜单 SFTP → 双侧页（shell 直达）

  @override
  State<HostsPage> createState() => _HostsPageState();
}

class _HostsPageState extends State<HostsPage> {
  final _search = TextEditingController();
  String? _groupFilter; // null = 全部
  bool _showSearch = false; // 手机 app bar 搜索展开
  bool _searchFocused = false; // 搜索框聚焦 → 外框换强调色

  @override
  void initState() {
    super.initState();
    // 增量同步：本会话还没同步过（冷启动首屏）时保留"同步中"指示；
    // 之后每次切回 Hosts 标签都静默对账。nav 内容槽只放一个页面，切页会把
    // HostsPage 整个卸载重装，若这里每次都发非静默 refresh，顶部就会闪一下
    // 浏览器式加载条，且 2px 进度条插槽把内容顶下去（画面跳一下）。
    widget.app.refresh(silent: widget.app.syncedOnce);
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<HostView> get _matched {
    final q = _search.text.trim().toLowerCase();
    var list = widget.app.hosts;
    if (_groupFilter != null) {
      list = list.where((h) => h.groupId == _groupFilter).toList();
    }
    if (q.isNotEmpty) {
      list = list
          .where((h) =>
              h.label.toLowerCase().contains(q) ||
              h.hostname.toLowerCase().contains(q) ||
              h.username.toLowerCase().contains(q))
          .toList();
    }
    return list;
  }

  /// 搜索词也应过滤分组卡（评审 P1：搜主机名时分组区原样全显）
  List<GroupView> _matchedGroups(List<GroupView> groups) {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return groups;
    return groups
        .where((grp) => grp.label.toLowerCase().contains(q))
        .toList();
  }

  /// 是否处于过滤态（搜索词或分组筛选）——空态文案随之变化
  bool get _filtering =>
      _search.text.trim().isNotEmpty || _groupFilter != null;

  void _connect(HostView h) {
    if (!widget.app.credentialFor(h).available) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该主机还没有凭据，请通过卡片菜单「编辑主机」补充')),
      );
      return;
    }
    widget.onOpenTerminal(h);
  }

  Future<void> _addHost() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => AddHostDialog(app: widget.app),
    );
    if (created == true && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('主机已保存并同步')));
    }
  }

  Future<void> _editHost(HostView h) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => AddHostDialog.edit(app: widget.app, editHost: h),
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('主机已更新并同步')));
    }
  }

  Future<void> _confirmDelete(HostView h) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Et.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('删除主机',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary)),
        content: Text('将从你的 vault 中删除「${h.label}」（${h.username}@${h.hostname}），'
            '关联的凭据一并下线。此操作会同步到所有设备。',
            style: TextStyle(fontSize: 13.5, color: Et.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('取消', style: TextStyle(color: Et.textSecondary))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: FilledButton.styleFrom(
                  backgroundColor: Et.danger,
                  shape:
                      RoundedRectangleBorder(borderRadius: BorderRadius.circular(9))),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.app.deleteHost(h);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('删除失败: ${e.error}')));
    }
  }

  void _cardMenu(HostView h, Rect anchor) {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    showMenu<String>(
      context: context,
      color: Et.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      // 锚点矩形（kebab=按钮框、右键=光标处）→ overlay 相对坐标。
      // 旧实现把「距左缘距离」当成 fromLTRB 的 right/bottom 传入，
      // 右列卡片菜单会贴屏溢出（评审 P1）
      position: RelativeRect.fromRect(anchor, Offset.zero & overlay.size),
      items: [
        PopupMenuItem(
            value: 'connect',
            height: 40,
            child: _MenuItemText('连接终端', Et.textPrimary)),
        PopupMenuItem(
            value: 'sftp',
            height: 40,
            child: _MenuItemText('SFTP 文件', Et.textPrimary)),
        PopupMenuItem(
            value: 'edit',
            height: 40,
            child: _MenuItemText('编辑主机', Et.textPrimary)),
        PopupMenuItem(
            value: 'delete',
            height: 40,
            child: _MenuItemText('删除主机', Et.danger)),
      ],
    ).then((v) {
      if (!mounted || v == null) return;
      switch (v) {
        case 'connect':
          _connect(h);
        case 'sftp':
          widget.onOpenSftp(h);
        case 'edit':
          _editHost(h);
        case 'delete':
          _confirmDelete(h);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final g = widget.app.groups;
        final h = _matched;
        final gf = _matchedGroups(g);
        final exact = h.length == 1 ? h.first : null;
        final compact = MediaQuery.sizeOf(context).width < 720; // 手机竖屏
        // 最近访问是默认视图的快捷入口：搜索/分组过滤时让位给匹配结果
        final recents =
            _filtering ? const <HostView>[] : widget.app.recentHosts;
        if (compact) {
          return _mobileHosts(context,
              groups: gf, hosts: h, recents: recents);
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 搜索行
              Row(
                children: [
                  Expanded(
                    child: Focus(
                      // canRequestFocus:false → 点空白处不会把焦点吸到包装节点，
                      // 只让 TextField 聚焦；onFocusChange 仍会经祖先链收到通知
                      canRequestFocus: false,
                      skipTraversal: true,
                      onFocusChange: (v) =>
                          setState(() => _searchFocused = v),
                      child: Container(
                        height: 40,
                        decoration: BoxDecoration(
                          color: Et.card,
                          borderRadius: BorderRadius.circular(10),
                          // 单层边框：内层 TextField 边框全部置 none（见
                          // Et.borderlessField），否则主题 enabledBorder 会补位成框中框
                          border: Border.all(
                              color: _searchFocused ? Et.accent : Et.cardBorder),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Icon(Icons.search,
                                size: 18, color: Et.textSecondary),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _search,
                                style: TextStyle(
                                    fontSize: 13.5, color: Et.textPrimary),
                                // 回车：唯一匹配直接连接
                                onSubmitted: (_) =>
                                    exact == null ? null : _connect(exact),
                                decoration: Et.borderlessField.copyWith(
                                  hintText: '查找主机或 user@hostname…（回车连接唯一匹配）',
                                  isDense: true,
                                ),
                              ),
                            ),
                            if (_search.text.isNotEmpty)
                              InkWell(
                                onTap: () {
                                  _search.clear();
                                  setState(() => _groupFilter = null);
                                },
                                child: Icon(Icons.close,
                                    size: 16, color: Et.textSecondary),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: exact == null ? null : () => _connect(exact),
                    style: FilledButton.styleFrom(
                      backgroundColor: Et.primaryBtn,
                      disabledBackgroundColor: Et.disabledBtn,
                      foregroundColor: Et.primaryBtnText,
                      disabledForegroundColor: Colors.white60,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(9)),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      minimumSize: const Size(0, 40),
                    ),
                    child: const Text('Connect'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // 工具栏行
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _addHost,
                    icon: const Icon(Icons.add, size: 17),
                    label: const Text('新建主机'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Et.primaryBtn,
                      foregroundColor: Et.primaryBtnText,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(9)),
                      minimumSize: const Size(0, 38),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_groupFilter != null)
                    InputChip(
                      label: Text(widget.app.groupName(_groupFilter) ?? '分组'),
                      onDeleted: () => setState(() => _groupFilter = null),
                      backgroundColor: Et.card,
                    ),
                  const Spacer(),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: widget.app.error == 'unauthorized'
                    ? const SizedBox.shrink() // 壳层正在跳转登录页
                    : Column(
                        children: [
                          // 同步失败不打断本地快照展示（离线可见）
                          if (widget.app.error != null)
                            _errorBanner(widget.app.error!),
                          Expanded(
                              child: _grid(
                                  groups: gf, hosts: h, recents: recents)),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------- 手机布局（Termius 式：浅色 app bar + 单列列表卡 + FAB） ----------

  Widget _mobileHosts(BuildContext context,
      {required List<GroupView> groups,
      required List<HostView> hosts,
      required List<HostView> recents}) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_groupFilter != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: InputChip(
              label: Text('分组：${widget.app.groupName(_groupFilter) ?? ''}'),
              onDeleted: () => setState(() => _groupFilter = null),
              backgroundColor: Et.card,
            ),
          ),
        Expanded(
          child: widget.app.error == 'unauthorized'
              ? const SizedBox.shrink()
              : Column(
                  children: [
                    if (widget.app.error != null)
                      _errorBanner(widget.app.error!),
                    Expanded(
                        child: _mobileList(
                            groups: groups, hosts: hosts, recents: recents)),
                  ],
                ),
        ),
      ],
    );
    return Container(
      color: Et.mBg,
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _mobileAppBar(context),
              if (_showSearch) _mobileSearch(),
              // 同桌面壳：2px 槽位常驻，进度条出现不顶动内容
              SizedBox(
                height: 2,
                child: widget.app.loading
                    ? LinearProgressIndicator(
                        minHeight: 2, color: Et.accent)
                    : null,
              ),
              Expanded(child: content),
            ],
          ),
          // FAB：新建主机
          Positioned(
            right: 18,
            bottom: 84,
            child: Material(
              color: Et.mFab,
              borderRadius: BorderRadius.circular(22),
              child: InkWell(
                onTap: _addHost,
                borderRadius: BorderRadius.circular(22),
                child: SizedBox(
                  width: 62,
                  height: 62,
                  child: Icon(Icons.add, size: 30, color: Et.mFabIcon),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mobileAppBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 2),
      child: Row(
        children: [
          Text('Hosts',
              style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w700,
                  color: Et.textPrimary)),
          const Spacer(),
          IconButton(
            onPressed: () => setState(() => _showSearch = !_showSearch),
            icon: Icon(Icons.search, size: 23, color: Et.textPrimary),
            tooltip: '搜索',
          ),
          IconButton(
            onPressed: widget.onOpenSettings,
            icon: Icon(Icons.settings_outlined,
                size: 22, color: Et.textPrimary),
            tooltip: '设置（账号/外观/退出登录）',
          ),
        ],
      ),
    );
  }

  Widget _mobileSearch() {
    final h = _matched;
    final exact = h.length == 1 ? h.first : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      child: Container(
        height: 42,
        decoration: BoxDecoration(
          color: Et.card,
          borderRadius: BorderRadius.circular(21),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Icon(Icons.search, size: 19, color: Et.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _search,
                autofocus: true,
                style: TextStyle(fontSize: 14, color: Et.textPrimary),
                onSubmitted: (_) => exact == null ? null : _connect(exact),
                decoration: Et.borderlessField.copyWith(
                  hintText: '查找主机…',
                  isDense: true,
                ),
              ),
            ),
            InkWell(
              onTap: () {
                _search.clear();
                setState(() => _showSearch = false);
              },
              child: Icon(Icons.close, size: 18, color: Et.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mobileList(
      {required List<GroupView> groups,
      required List<HostView> hosts,
      required List<HostView> recents}) {
    if (widget.app.loading && hosts.isEmpty && groups.isEmpty) {
      return const _CenterNote('同步中…');
    }
    if (hosts.isEmpty && groups.isEmpty) {
      if (_filtering) return _noMatchState(); // 过滤态空态（评审 P1）
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: Et.card,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(Icons.dns_outlined,
                  size: 30, color: Et.textSecondary),
            ),
            const SizedBox(height: 14),
            Text('还没有主机',
                style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    color: Et.textPrimary)),
            const SizedBox(height: 5),
            Text('添加你的第一台服务器开始使用',
                style: TextStyle(fontSize: 13, color: Et.textSecondary)),
          ],
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
      children: [
        if (recents.isNotEmpty) ...[
          const _SectionTitle('最近访问'),
          _recentStrip(hosts: recents, compact: true),
          const SizedBox(height: 4),
        ],
        if (_groupFilter == null && groups.isNotEmpty) ...[
          const _SectionTitle('分组'),
          for (final grp in groups)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _MobileTile(
                iconColor: Et.tileGroup,
                icon: Icons.grid_view_rounded,
                title: grp.label,
                subtitle: grp.count == 0 ? '无主机' : '${grp.count} 台主机',
                onTap: () => setState(() => _groupFilter = grp.id),
              ),
            ),
        ],
        _SectionTitle(_groupFilter == null ? '主机' : '分组主机'),
        for (final host in hosts)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _MobileTile(
              iconColor: Et.tileHost,
              icon: Icons.dns_rounded,
              title: host.label,
              subtitle: [
                host.username.isEmpty
                    ? host.hostname
                    : '${host.username}@${host.hostname}',
                if (widget.app.groupName(host.groupId) != null)
                  widget.app.groupName(host.groupId)!,
                if (!widget.app.credentialFor(host).available) '无凭据',
              ].join(' · '),
              danger: !widget.app.credentialFor(host).available,
              open: widget.openHostIds.contains(host.id),
                onTap: () => _connect(host),
              onMenu: (anchor) => _cardMenu(host, anchor),
            ),
          ),
      ],
    );
  }

  /// 搜索/分组过滤无结果：区分于「还没有主机」，提供一键清除
  Widget _noMatchState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off, size: 34, color: Et.textSecondary),
          const SizedBox(height: 12),
          Text('无匹配主机',
              style: TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w600,
                  color: Et.textPrimary)),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: () => setState(() {
              _search.clear();
              _groupFilter = null;
            }),
            style: OutlinedButton.styleFrom(
              foregroundColor: Et.textPrimary,
              side: BorderSide(color: Et.cardBorder),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(9)),
              minimumSize: const Size(0, 38),
            ),
            child: const Text('清除搜索'),
          ),
        ],
      ),
    );
  }

  /// 同步失败横幅：保留本地快照渲染，仅提示 + 重试
  Widget _errorBanner(String message) {
    final danger = Et.danger;
    final bannerBg = Et.brightness == Brightness.dark
        ? Et.danger.withAlpha(26)
        : const Color(0xFFFCEDED);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bannerBg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 16, color: danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text('同步失败，正在显示本地缓存 · $message',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, color: danger)),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: () => widget.app.refresh(),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text('重试',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: danger)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _grid(
      {required List<GroupView> groups,
      required List<HostView> hosts,
      required List<HostView> recents}) {
    if (widget.app.loading && hosts.isEmpty) {
      return const _CenterNote('同步中…');
    }
    if (hosts.isEmpty && groups.isEmpty) {
      // 过滤态空态 ≠ 真没数据：给「清除搜索」出口（评审 P1）
      if (_filtering) {
        return _noMatchState();
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('还没有主机',
                style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                    color: Et.textPrimary)),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _addHost,
              icon: const Icon(Icons.add, size: 17),
              label: const Text('新建主机'),
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
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (recents.isNotEmpty) ...[
            const _SectionTitle('最近访问'),
            _recentStrip(hosts: recents, compact: false),
          ],
          if (_groupFilter == null && groups.isNotEmpty) ...[
            const _SectionTitle('分组'),
            _cardGrid(
              count: groups.length,
              build: (i) => _GroupCard(
                group: groups[i],
                onTap: () => setState(() => _groupFilter = groups[i].id),
              ),
            ),
          ],
          _SectionTitle(_groupFilter == null ? '主机' : '分组主机'),
          _cardGrid(
            count: hosts.length,
            build: (i) {
              final h = hosts[i];
              return _HostCard(
                host: h,
                groupName: widget.app.groupName(h.groupId),
                open: widget.openHostIds.contains(h.id),
                hasCredential: widget.app.credentialFor(h).available,
                onTap: () => _connect(h),
                onMenu: (anchor) => _cardMenu(h, anchor),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 最近访问横向条（桌面/手机同源）：已按访问时间倒序，最多 10 台。
  /// 用 SingleChildScrollView（同标题栏标签模式）：10 条全量构建、横滑查看。
  Widget _recentStrip({required List<HostView> hosts, required bool compact}) {
    return SizedBox(
      height: compact ? 58 : 64,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
        child: Row(
          children: [
            for (final (i, h) in hosts.indexed) ...[
              if (i > 0) SizedBox(width: compact ? 8 : 10),
              _RecentHostChip(
                key: ValueKey('recent-host-${h.id}'),
                host: h,
                visitedAt: widget.app.recentVisitedAt(h.id),
                open: widget.openHostIds.contains(h.id),
                compact: compact,
                onTap: () => _connect(h),
                onMenu: (anchor) => _cardMenu(h, anchor),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 响应式 N 列卡片网格（Termius 三列观感）。
  Widget _cardGrid({required int count, required Widget Function(int) build}) {
    return LayoutBuilder(builder: (context, box) {
      final cols = ((box.maxWidth ~/ 320) + 1).clamp(1, 4);
      return GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisExtent: 84,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
        ),
        itemCount: count,
        itemBuilder: (_, i) => build(i),
      );
    });
  }
}

class _MenuItemText extends StatelessWidget {
  const _MenuItemText(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: TextStyle(fontSize: 13.5, color: color));
}

class _CenterNote extends StatelessWidget {
  const _CenterNote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Text(text, style: TextStyle(color: Et.textSecondary)),
      );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 12, 0, 4),
        child: Text(text,
            style: TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary)),
      );
}

class _IconTile extends StatelessWidget {
  const _IconTile({required this.color, required this.icon});
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: Colors.white, size: 24),
      );
}

class _GroupCard extends StatelessWidget {
  const _GroupCard({required this.group, required this.onTap});
  final GroupView group;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _Card(
      onTap: onTap,
      child: Row(
        children: [
          _IconTile(color: Et.tileGroup, icon: Icons.grid_view_rounded),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(group.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Et.textPrimary)),
                const SizedBox(height: 3),
                Text('${group.count} 台主机',
                    style: TextStyle(
                        fontSize: 12.5, color: Et.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HostCard extends StatelessWidget {
  const _HostCard({
    required this.host,
    required this.groupName,
    required this.open,
    required this.hasCredential,
    required this.onTap,
    required this.onMenu,
  });

  final HostView host;
  final String? groupName;
  final bool open; // 已有打开的终端标签
  final bool hasCredential;
  final VoidCallback onTap;
  final void Function(Rect anchor) onMenu;

  void _menuAt(BuildContext buttonContext) {
    final box = buttonContext.findRenderObject()! as RenderBox;
    onMenu(box.localToGlobal(Offset.zero) & box.size);
  }

  @override
  Widget build(BuildContext context) {
    // 副标题 = user@host · 分组（ssh 前缀冗余，tooltip 兜底长全文，评审 P2）
    final subtitle = [
      host.username.isEmpty
          ? host.hostname
          : '${host.username}@${host.hostname}',
      if (groupName != null) groupName,
    ].join(' · ');
    return _Card(
      onTap: onTap,
      // 右键菜单锚在光标处（评审 P1：旧实现锚整卡，点哪都弹同一个位置）
      onSecondaryTapUp: (d) => onMenu(
          Rect.fromLTWH(d.globalPosition.dx, d.globalPosition.dy, 150, 1)),
      onLongPress: () => _menuAt(context),
      child: Row(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              _IconTile(color: Et.tileHost, icon: Icons.dns_rounded),
              if (open)
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    width: 11,
                    height: 11,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2DA44E),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(host.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Et.textPrimary)),
                const SizedBox(height: 3),
                Tooltip(
                  message: hasCredential ? subtitle : '$subtitle · 无凭据',
                  waitDuration: const Duration(milliseconds: 450),
                  child: Text(hasCredential ? subtitle : '$subtitle · 无凭据',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12.5,
                          color: hasCredential
                              ? Et.textSecondary
                              : const Color(0xFFC77B27))),
                ),
              ],
            ),
          ),
          Builder(
            builder: (btnCtx) => IconButton(
              icon: Icon(Icons.more_horiz,
                  size: 18, color: Et.textSecondary),
              tooltip: '操作',
              // 菜单锚定按钮框（旧实现锚整卡底部，右列贴屏溢出）
              onPressed: () => _menuAt(btnCtx),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「最近访问」横向条里的轻量主机卡：点击连接；右键/长按同主卡片菜单；
/// 副标题显示相对访问时间（排序依据的可见化）。
class _RecentHostChip extends StatelessWidget {
  const _RecentHostChip({
    super.key,
    required this.host,
    required this.visitedAt,
    required this.open,
    required this.compact,
    required this.onTap,
    required this.onMenu,
  });

  final HostView host;
  final DateTime? visitedAt;
  final bool open;
  final bool compact;
  final VoidCallback onTap;
  final void Function(Rect anchor) onMenu;

  void _menuAt(BuildContext ctx) {
    final box = ctx.findRenderObject()! as RenderBox;
    onMenu(box.localToGlobal(Offset.zero) & box.size);
  }

  @override
  Widget build(BuildContext context) {
    final iconSize = compact ? 30.0 : 34.0;
    final radius = BorderRadius.circular(compact ? 16 : 12);
    final tile = Material(
      color: Et.card,
      borderRadius: radius,
      child: InkWell(
        onTap: onTap,
        onSecondaryTapUp: (d) => onMenu(
            Rect.fromLTWH(d.globalPosition.dx, d.globalPosition.dy, 150, 1)),
        onLongPress: () => _menuAt(context),
        borderRadius: radius,
        child: Container(
          width: compact ? 196 : 236,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: iconSize,
                    height: iconSize,
                    decoration: BoxDecoration(
                      color: Et.tileHost,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Icon(Icons.dns_rounded,
                        color: Colors.white, size: iconSize * 0.55),
                  ),
                  if (open)
                    Positioned(
                      right: -2,
                      top: -2,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2DA44E),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(host.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: compact ? 13 : 13.5,
                            fontWeight: FontWeight.w600,
                            color: Et.textPrimary)),
                    const SizedBox(height: 2),
                    Text(
                      visitedAt == null ? '' : fmtRelativeTime(visitedAt!),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: compact ? 11 : 11.5,
                          color: Et.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    // 手机长按已用于打开菜单，不再挂 Tooltip（避免手势打架）
    if (compact) return tile;
    final who = host.username.isEmpty
        ? host.hostname
        : '${host.username}@${host.hostname}';
    return Tooltip(
      message: visitedAt == null
          ? who
          : '$who\n最近访问：${fmtLocalDateTime(visitedAt!)}',
      waitDuration: const Duration(milliseconds: 450),
      child: tile,
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.child,
    required this.onTap,
    this.onSecondaryTapUp,
    this.onLongPress,
  });

  final Widget child;
  final VoidCallback onTap;
  final void Function(TapUpDetails)? onSecondaryTapUp;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Et.card,
      borderRadius: BorderRadius.circular(Et.cardRadius),
      child: InkWell(
        onTap: onTap,
        onSecondaryTapUp: onSecondaryTapUp,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(Et.cardRadius),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Et.cardRadius),
            border: Border.all(color: Et.cardBorder),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: child,
        ),
      ),
    );
  }
}

/// 手机列表卡（Termius 式）：大圆角白卡 + 48px 图标瓦片 + 名称/副标题。
/// 点击主操作（连接/进入分组），长按/⋯ 弹菜单。
class _MobileTile extends StatelessWidget {
  const _MobileTile({
    required this.iconColor,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.onMenu,
    this.danger = false,
    this.open = false,
  });

  final Color iconColor;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final void Function(Rect anchor)? onMenu;
  final bool danger; // 无凭据橙色副标题
  final bool open; // 已开终端绿点

  void _menuAt(BuildContext buttonContext) {
    final box = buttonContext.findRenderObject()! as RenderBox;
    onMenu?.call(box.localToGlobal(Offset.zero) & box.size);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Et.card,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        onLongPress: onMenu == null ? null : () => _menuAt(context),
        borderRadius: BorderRadius.circular(22),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: iconColor,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: Colors.white, size: 25),
                  ),
                  if (open)
                    Positioned(
                      right: -2,
                      top: -2,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2DA44E),
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w600,
                            color: Et.textPrimary)),
                    const SizedBox(height: 3),
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            color: danger
                                ? const Color(0xFFC77B27)
                                : Et.textSecondary)),
                  ],
                ),
              ),
              if (onMenu != null)
                IconButton(
                  icon: Icon(Icons.more_horiz,
                      size: 19, color: Et.textSecondary),
                  tooltip: '操作',
                  onPressed: () => _menuAt(context),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// 占位导航页导出（shell 用）
class PlaceholderPage extends StatelessWidget {
  const PlaceholderPage({super.key, required this.title, required this.note});
  final String title;
  final String note;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                color: Et.card,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: Et.cardBorder),
              ),
              child: Icon(Icons.construction,
                  size: 30, color: Colors.grey.shade400),
            ),
            const SizedBox(height: 16),
            Text(title,
                style: TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w700,
                    color: Et.textPrimary)),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: Text(note,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13, height: 1.5, color: Et.textSecondary)),
            ),
          ],
        ),
      );
}

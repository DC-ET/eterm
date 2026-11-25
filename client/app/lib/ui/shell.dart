// 应用壳（Termius 式）：深色自绘标题栏（Vaults 胶囊 + 终端标签 + 关闭），
// vault 视图 = 左侧导航 + 内容区；终端标签激活时满幅接管内容区（侧栏隐藏）。
// 窄屏（手机竖屏，<720）响应式：侧边导航换成底部导航栏，内容区满幅。
// IndexedStack 保持后台终端标签的会话存活。

// window_manager 0.7 的 0.5 兼容 API（WindowListener/DragToMoveArea 等）仍是
// 当前唯一可用路径（AGENTS：勿降级），弃用提示在此集中屏蔽以免污染 CI 门禁。
// ignore_for_file: deprecated_member_use

import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'package:eterm/src/rust/api/local.dart' as local;
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/legacy.dart'; // 标题栏 DragToMoveArea/WindowListener（AGENTS：0.7 旧 API 走 legacy）

import '../services/api_client.dart';
import '../services/fg_service.dart';
import '../services/realtime.dart';
import '../services/app_state.dart';
import 'hosts_page.dart';
import 'keychain_page.dart';
import 'logs_page.dart';
import 'known_hosts_page.dart';
import 'port_forwarding_page.dart';
import 'settings_page.dart';
import 'sftp_entry_page.dart';
import 'sftp_page.dart';
import 'terminal_tab.dart';
import 'login_page.dart';
import 'theme.dart';
import 'work_tabs.dart';

class ShellPage extends StatefulWidget {
  const ShellPage({
    super.key,
    required this.api,
    required this.app,
    required this.username,
  });

  final ApiClient api;
  final AppState app;
  final String username;

  @override
  State<ShellPage> createState() => _ShellPageState();
}

WorkTabPhase _workPhaseOfTerm(TermPhase p) => switch (p) {
  TermPhase.connecting => WorkTabPhase.connecting,
  TermPhase.live => WorkTabPhase.live,
  TermPhase.closed => WorkTabPhase.closed,
};

class _ShellPageState extends State<ShellPage>
    with WidgetsBindingObserver, WindowListener {
  final tabs = <WorkTab>[];
  int activeTab = -1; // -1 = vault 视图；否则 tabs 下标
  int navIndex = 0; // 侧边导航（0=Hosts）
  DateTime? _lastPausedAt; // D13 防抖：最近一次 paused
  DateTime? _lastProbeAt; // D13 防抖：最近一次回前台探测
  DateTime? _lastFocusProbeAt; // 桌面窗口聚焦探活节流（D16：≥30s）
  bool _closing = false; // 关闭确认弹窗防双击（方案 §4.5.2）

  void openTerminal(HostView h) {
    final cred = widget.app.credentialFor(h);
    if (cred == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该主机没有可用凭据（私钥仅会话内有效，请删除后重新添加）')),
      );
      return;
    }
    final existing = tabs.indexWhere(
      (t) => t is TerminalWorkTab && t.host.id == h.id,
    );
    setState(() {
      if (existing >= 0) {
        activeTab = existing; // 复用已开终端
      } else {
        tabs.add(
          TerminalWorkTab(
            key: GlobalKey(),
            host: h,
            authKind: cred.authKind,
            secret: cred.secret,
          ),
        );
        activeTab = tabs.length - 1;
      }
    });
    widget.app.markHostVisited(h.id); // Hosts 页「最近访问」按此排序
    FgService.setKeepAlive(tabs.isNotEmpty); // 前台服务保活 SSH（M1）
  }

  /// 打开 SFTP 工作区标签；同一无序端点对（A⇄B == B⇄A）复用已有标签。
  void openSftp({required SftpSideSpec left, required SftpSideSpec right}) {
    final pair = sftpPairKey(left, right);
    final existing = tabs.indexWhere(
      (t) => t is SftpWorkTab && t.dedupeKey == pair,
    );
    setState(() {
      if (existing >= 0) {
        activeTab = existing;
      } else {
        tabs.add(
          SftpWorkTab(key: GlobalKey(), left: left, right: right),
        );
        activeTab = tabs.length - 1;
      }
    });
    // 最近访问按端点算：主机侧（本机侧不算）都记一次
    for (final side in [left, right]) {
      final id = side.host?.id;
      if (id != null) widget.app.markHostVisited(id);
    }
    if (existing >= 0) {
      // 反向打开（B⇄A）：聚焦已有 A⇄B 标签，提示可直接从请求的左侧操作；
      // 不重建标签（方案 D4/P2-19）。
      final tab = tabs[existing] as SftpWorkTab;
      String sideId(SftpSideSpec s) => s.host?.id ?? 'local';
      if (sideId(tab.left) != sideId(left)) {
        final from = left.host?.label ?? '本机';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已切到现有「${tab.label}」标签，可直接从$from侧拖拽')),
        );
      }
    }
    FgService.setKeepAlive(tabs.isNotEmpty);
  }

  /// 主机卡片菜单「SFTP 文件」：host ⇄ 本机 直达工作区标签
  /// （凭据与终端同一解析链）。
  void _openSftpFor(HostView h) {
    final cred = widget.app.credentialFor(h);
    if (cred == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该主机还没有凭据，请通过卡片菜单「编辑主机」补充')),
      );
      return;
    }
    openSftp(
      left: SftpSideSpec(host: h, authKind: cred.authKind, secret: cred.secret),
      right: const SftpSideSpec(), // 本机
    );
  }

  /// 关闭标签。SFTP 标签有进行中传输时先确认（关闭会取消这些传输）。
  Future<void> closeTab(int i) async {
    if (_closing || i < 0 || i >= tabs.length) return;
    final target = tabs[i];
    if (target is SftpWorkTab) {
      final running = target.status.value.activeTransfers;
      if (running > 0) {
        _closing = true;
        bool? ok;
        try {
          ok = await _confirmCloseSftp(target.label, running);
        } finally {
          _closing = false;
        }
        if (ok != true || !mounted) return;
      }
    }
    // await 后按身份重新定位：期间标签可能被其他路径关闭/登出清栈
    final idx = tabs.indexOf(target);
    if (idx < 0) return;
    setState(() {
      tabs.removeAt(idx);
      // phase notifier 不在这里 dispose：TerminalTabView/SftpWorkspace State
      // 帧末才销毁，期间异步事件仍可能回写（use-after-dispose）。
      // ValueListenableBuilder unmount 自行解绑，无监听的 notifier 交给 GC。
      if (tabs.isEmpty) {
        activeTab = -1;
      } else if (idx < activeTab) {
        activeTab -= 1; // 评审 BUG-D2 回归：关闭左侧标签后仍查看同一会话
      } else if (activeTab >= tabs.length) {
        activeTab = tabs.length - 1;
      }
    });
    FgService.setKeepAlive(tabs.isNotEmpty);
  }

  Future<bool?> _confirmCloseSftp(String label, int running) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Et.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          '关闭 $label？',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: Et.textPrimary,
          ),
        ),
        content: Text(
          '该标签还有 $running 个传输进行中。关闭将取消传输；未完成暂存'
          '（.eterm-part）会保留，但重开标签需重新发起。',
          style: TextStyle(
            fontSize: 13.5,
            height: 1.5,
            color: Et.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: Et.textSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Et.danger),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _logout() async {
    realtime.stop();
    FgService.setKeepAlive(false);
    try {
      await widget.api.logout();
    } catch (_) {}
    local.clearLocal(); // 会话 + 本地缓存一并清理
    if (!mounted) return;
    // pushAndRemoveUntil 清空整栈：编辑页等子路由的 PopScope 拦截不会挡住
    // 清栈（pushReplacement 只换当前路由，脏编辑页会残留在最上层）。
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  /// token 失效（401）：静默回登录页。
  void _onAuthLost() {
    realtime.stop();
    FgService.setKeepAlive(false);
    local.clearLocal();
    if (!mounted) return;
    // pushAndRemoveUntil 清空整栈：编辑页等子路由的 PopScope 拦截不会挡住
    // 清栈（pushReplacement 只换当前路由，脏编辑页会残留在最上层）。
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // D13：回前台探测（移动端）
    if (Platform.isMacOS || Platform.isWindows) {
      // 桌面无 resumed（窗口聚焦是噪声），但 SFTP 无 Closed 事件：
      // 聚焦时对当前可见 SFTP 标签探活，节流 ≥30s（D16）
      windowManager.addListener(this);
    }
    widget.app.addListener(_appChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isMacOS || Platform.isWindows) {
      windowManager.removeListener(this);
    }
    widget.app.removeListener(_appChanged);
    super.dispose();
  }

  /// 桌面窗口重新聚焦：仅当前可见 SFTP 标签、节流 ≥30s 做探活（D16）。
  @override
  void onWindowFocus() {
    final now = DateTime.now();
    if (_lastFocusProbeAt != null &&
        now.difference(_lastFocusProbeAt!) < const Duration(seconds: 30)) {
      return;
    }
    _lastFocusProbeAt = now;
    sftpWorkspacesProbeVisible();
  }

  /// D13 生命周期（方案 §4.2）：回前台探测。桌面不参与——macOS 每次窗口
  /// 聚焦都触发 resumed（纯噪声）；Android 无前台服务挂起时同样受益
  /// （iOS 驱动、双端一致的改动）。paused 无动作（D4：不保活）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _lastPausedAt = DateTime.now();
      terminalTabsOnAppPaused(); // 登记 tab 挂起前存活状态（exit/失败的 closed 不参与自动重连）
      sftpWorkspacesOnAppPaused(); // SFTP 远端侧同口径：只探活挂起前 live 的
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;
    // 防抖：仅对「刚从 paused 恢复」或距上次探测 >10s 才执行，
    // 过滤 iOS 上拉通知中心 / 滑过 App 切换器产生的 inactive→resumed 抖动
    final now = DateTime.now();
    final fromPaused = _lastPausedAt != null &&
        now.difference(_lastPausedAt!) <= const Duration(seconds: 3);
    final sinceProbe = _lastProbeAt == null ||
        now.difference(_lastProbeAt!) > const Duration(seconds: 10);
    if (!fromPaused && !sinceProbe) return;
    _lastProbeAt = now;
    realtime.probe(); // ① WS 断则立即重连（不等退避）
    unawaited(widget.app.refresh(silent: true)); // ② 静默对账
    terminalTabsOnAppResume(); // ③ 终端标签逐个重连/武装窗口
    sftpWorkspacesOnAppResume(); // ④ SFTP 远端侧探活/重连（含队列 session 重绑）
  }

  void _appChanged() {
    if (widget.app.error == 'unauthorized') {
      _onAuthLost();
      return;
    }
    if (mounted) setState(() {}); // 同步 loading 状态驱动进度条
  }

  @override
  Widget build(BuildContext context) {
    // 注册 Theme 依赖：主题切换时整个壳（含各导航页）随之重建
    // （Et 是静态令牌，自身不感知 inherited；无此依赖 pushed 路由不会重绘）
    Theme.of(context);
    final compact = MediaQuery.sizeOf(context).width < 720; // 手机竖屏
    final content = switch (navIndex) {
      0 => HostsPage(
          app: widget.app,
          onOpenTerminal: openTerminal,
          openHostIds: {
            for (final t in tabs)
              if (t is TerminalWorkTab) t.host.id,
          },
          onOpenSettings: () => setState(() => navIndex = 6),
          onOpenSftp: _openSftpFor,
        ),
      1 => SftpEntryPage(
          app: widget.app,
          onOpen: (left, right) => openSftp(left: left, right: right),
        ),
      2 => KeychainPage(app: widget.app),
      3 => PortForwardingPage(app: widget.app),
      // 勿加 const：Shell 随主题重建时 const 实例会被 Flutter 跳过（identical）
      4 => KnownHostsPage(),
      5 => LogsPage(),
      6 => SettingsPage(
          app: widget.app,
          username: widget.username,
          onLogout: _logout),
      _ => _MorePage(onNavigate: (i) => setState(() => navIndex = i)),
    };
    // 手机：内容满幅 + 底部导航（仅收纳有实质功能的页；占位页留在桌面侧栏）
    final vaultView = compact
        ? Column(
            children: [
              Expanded(
                child: SafeArea(bottom: false, child: content), // 状态栏统一避让
              ),
              SafeArea(
                top: false, // 手势条避让
                child: NavigationBar(
                  selectedIndex: _compactNavIndex(navIndex),
                  onDestinationSelected: (i) =>
                      setState(() => navIndex = _compactNavTarget[i]),
                  height: 62,
                  backgroundColor: Et.mBg,
                  indicatorColor: Et.mSelected,
                  destinations: [
                    for (final (icon, label) in _compactNav)
                      NavigationDestination(
                          icon: Icon(icon, size: 21), label: label),
                  ],
                ),
              ),
            ],
          )
        : Row(
            children: [
              _Sidebar(
                navIndex: navIndex,
                onSelect: (i) => setState(() => navIndex = i),
              ),
              Expanded(child: content),
            ],
          );
    final body = IndexedStack(
      index: activeTab + 1,
      children: [
        vaultView,
        // 每个标签 child 结构对 compact 恒定（Column + Expanded）：旋转/分屏
        // 跨断点时仅属性变化，State 复用 → SSH 会话不断（P1-6）。
        // TickerMode：隐藏标签停动画（SFTP 进度条/旋转），State 仍全量存活。
        for (var i = 0; i < tabs.length; i++) _tabChild(tabs[i], i, compact),
      ],
    );
    // 顶部结构（Android 状态栏避让的正确层级）：
    // - 桌面：深色标题栏背景延伸到状态栏区（SafeArea 推内容行），图标 light
    // - 手机：无深色标题栏（账号入口在各页 app bar），浅色状态栏 dark 图标；
    //   终端视图由 TerminalTabView 自带深色状态栏区（内部 SafeArea，light 图标）
    // 手机状态栏：终端标签有深色状态栏区（light 图标）；SFTP 标签是浅色
    // 工具条 + 卡片，必须 dark 图标，否则蓝底黑字看不清（方案 §4.5）。
    final activeKind =
        activeTab >= 0 && activeTab < tabs.length ? tabs[activeTab].kind : null;
    final lightStatusIcons =
        (compact && activeKind == WorkTabKind.terminal) ||
        Et.brightness == Brightness.dark;
    return PopScope<Object?>(
      canPop: activeTab == -1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && activeTab >= 0) setState(() => activeTab = -1);
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
      value: lightStatusIcons
          ? SystemUiOverlayStyle.light // 手机终端深色区 / 深色主题
          : SystemUiOverlayStyle.dark, // 浅色列表页/SFTP / 桌面无状态栏
      child: Scaffold(
      backgroundColor: Et.contentBg,
      body: Column(
        children: [
          if (!compact) ...[
            _TitleBar(
              tabs: tabs,
              activeTab: activeTab,
              onSelectVault: () => setState(() => activeTab = -1),
              onSelectTab: (i) => setState(() => activeTab = i),
              onCloseTab: closeTab,
            ),
            // 加载条常驻 2px 槽位：同步开始/结束只切换槽位内容，不插入/移除节点，
            // 进度条出现时不会把下方内容顶下去（否则画面跟着抖一下）
            SizedBox(
              height: 2,
              child: widget.app.loading
                  ? LinearProgressIndicator(minHeight: 2, color: Et.accent)
                  : null,
            ),
          ],
          Expanded(child: body),
        ],
      ),
      ),
      ),
    );
  }

  Widget _tabChild(WorkTab tab, int index, bool compact) {
    final active = activeTab == index;
    final bar = compact
        ? _MobileTabBar(
            tabs: tabs,
            activeTab: activeTab,
            onSelectVault: () => setState(() => activeTab = -1),
            onSelectTab: (i) => setState(() => activeTab = i),
            onCloseTab: closeTab,
            onAdd: () => setState(() => activeTab = -1),
          )
        : null;
    final content = switch (tab) {
      final TerminalWorkTab t =>
        Column(
          children: [
            Expanded(
              child: TerminalTabView(
                key: t.key,
                host: t.host,
                terminal: t.terminal,
                authKind: t.authKind,
                secret: t.secret,
                // pill 状态点同步（TermPhase → 统一 WorkTabPhase）
                onPhase: (p) => t.status.value = WorkTabStatus(
                  phase: _workPhaseOfTerm(p),
                ),
              ),
            ),
            // 手机：标签条吸底（Termius 式 ←/标签/+）；终端满幅无深色标题栏
            ?bar,
          ],
        ),
      final SftpWorkTab t =>
        Column(
          children: [
            Expanded(
              child: SftpWorkspace(
                key: t.key,
                left: t.left,
                right: t.right,
                visible: active,
                status: t.status,
              ),
            ),
            ?bar,
          ],
        ),
    };
    // 隐藏标签停动画（终端光标/进度条），State 仍全量存活（方案 A.3）
    return TickerMode(enabled: active, child: content);
  }
}

// ---------- 窄屏底部导航 ----------

/// 手机底栏收纳全部实页，与侧栏 navIndex 对应：0/1/3/4。
/// 评审 BUG-D1 回归：Known Hosts（侧栏 3）必须有手机入口，否则 compact 布局不可达。
const _compactNav = [
  (Icons.dns_outlined, 'Hosts'),
  (Icons.folder_copy_outlined, 'SFTP'),
  (Icons.key_outlined, 'Keychain'),
  (Icons.apps, 'More'),
];
const _compactNavTarget = [0, 1, 2, -1]; // -1 = More 页（占位 navIndex）

int _compactNavIndex(int navIndex) {
  if (navIndex == -1) return 3; // More 页
  final i = _compactNavTarget.indexOf(navIndex);
  if (i >= 0) return i;
  return 3; // 经 More 进入的实页（navIndex 3-6）：底栏高亮 More
}

/// 标签状态点配色：green=live / 灰=连接中 / 橙=degraded / 红=closed。
Color _statusColor(WorkTabPhase phase, {required Color connecting}) =>
    switch (phase) {
      WorkTabPhase.live => const Color(0xFF2DA44E),
      WorkTabPhase.connecting => connecting,
      WorkTabPhase.degraded => const Color(0xFFC77B27),
      WorkTabPhase.closed => Et.danger,
    };

// ---------- 手机终端标签条（吸底，Termius 式） ----------

class _MobileTabBar extends StatelessWidget {
  const _MobileTabBar({
    required this.tabs,
    required this.activeTab,
    required this.onSelectVault,
    required this.onSelectTab,
    required this.onCloseTab,
    required this.onAdd,
  });

  final List<WorkTab> tabs;
  final int activeTab;
  final VoidCallback onSelectVault;
  final void Function(int) onSelectTab;
  final void Function(int) onCloseTab;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    // 手势条避让：键盘弹出时归零（标签条贴键盘，不留空隙）
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom > 0
        ? 0.0
        : MediaQuery.paddingOf(context).bottom;
    return Container(
      height: 52 + bottomInset,
      padding: EdgeInsets.only(bottom: bottomInset),
      color: Et.mBg,
      child: Row(
        children: [
          // 返回 vault 列表
          IconButton(
            onPressed: onSelectVault,
            icon: const Icon(Icons.arrow_back_ios_new, size: 19),
            color: Et.textPrimary,
            tooltip: '返回列表',
          ),
          // 标签 pills（横向滚动）
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < tabs.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _pill(context, i),
                    ),
                ],
              ),
            ),
          ),
          IconButton(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 24),
            color: Et.textPrimary,
            tooltip: '新建连接',
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _pill(BuildContext context, int i) {
    final active = activeTab == i;
    return InkWell(
      onTap: () => onSelectTab(i),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: 36,
        padding: const EdgeInsets.fromLTRB(14, 0, 6, 0),
        decoration: BoxDecoration(
          color: active
                  ? Et.mSelected
                  : (Et.brightness == Brightness.dark
                      ? Colors.white.withAlpha(24)
                      : Colors.white.withAlpha(160)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 会话/传输状态点 + 传输计数（标签保活的核心可感知信息）
            ValueListenableBuilder<WorkTabStatus>(
              valueListenable: tabs[i].status,
              builder: (context, st, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _statusColor(st.phase, connecting: Et.textSecondary),
                    ),
                  ),
                  if (st.activeTransfers > 0) ...[
                    Icon(Icons.swap_vert,
                        size: 12, color: Et.textSecondary),
                    Text('${st.activeTransfers}',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Et.textSecondary)),
                    const SizedBox(width: 3),
                  ],
                  if (st.failedTransfers > 0) ...[
                    Icon(Icons.error_outline, size: 12, color: Et.danger),
                    Text('${st.failedTransfers}',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Et.danger)),
                    const SizedBox(width: 2),
                  ],
                ],
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 170),
              child: Text(tabs[i].label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                      color: Et.textPrimary)),
            ),
            const SizedBox(width: 5),
            // 关闭按钮：命中区扩到 ~34px（评审 P1：此前约 23px，触屏难点中）
            InkWell(
              onTap: () => onCloseTab(i),
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 34,
                height: 34,
                child: Icon(Icons.close,
                    size: 15, color: Et.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------- 标题栏 ----------

class _TitleBar extends StatefulWidget {
  const _TitleBar({
    required this.tabs,
    required this.activeTab,
    required this.onSelectVault,
    required this.onSelectTab,
    required this.onCloseTab,
  });

  final List<WorkTab> tabs;
  final int activeTab;
  final VoidCallback onSelectVault;
  final void Function(int) onSelectTab;
  final void Function(int) onCloseTab;

  @override
  State<_TitleBar> createState() => _TitleBarState();
}

class _TitleBarState extends State<_TitleBar> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      // Windows 三钮的 maximize/restore 图标切换需监听窗口状态；监听局部化在
      // 标题栏内，不改 shell 全局结构（AGENTS.md 有 IndexedStack 重建断连前科）。
      windowManager.addListener(this);
      windowManager.isMaximized().then((v) {
        if (mounted && v != _maximized) setState(() => _maximized = v);
      });
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _maximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _maximized = false);
  }

  // legacy API（0.5.x 兼容层）没有 toggleMaximize，用 isMaximized 分支。
  Future<void> _toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 深色背景延伸到状态栏区（SafeArea 把内容行推到状态栏下方），视觉连续。
    // 双击标题栏 = 切换最大化：DragToMoveArea 内建（nativeapi 原生
    // SC_MAXIMIZE/SC_RESTORE），macOS/Windows 同源，勿再自建手势——
    // 原始 Listener 直判会与内建双击同时触发，两次切换互相抵消/竞态。
    return Container(
      color: Et.titleBar,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 52,
          child: DragToMoveArea(child: _titleBarRow()),
        ),
      ),
    );
  }

  Widget _titleBarRow() {
    final isMac = Platform.isMacOS;
    final isWin = Platform.isWindows;
    return Row(
      children: [
        SizedBox(width: isMac ? 78 : 12), // mac：交通灯让位区；win：呼吸边
        _VaultPill(onSelectVault: widget.onSelectVault),
        const SizedBox(width: 10),
        // 标签区：多了横向滚动，不挤溢通知钮
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < widget.tabs.length; i++)
                  _TermTabPill(
                    label: widget.tabs[i].label,
                    kind: widget.tabs[i].kind,
                    active: widget.activeTab == i,
                    status: widget.tabs[i].status,
                    onTap: () => widget.onSelectTab(i),
                    onClose: () => widget.onCloseTab(i),
                    maxLabelWidth: 160,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 8),
        if (isWin) _WindowControls(maximized: _maximized, onToggleMaximize: _toggleMaximize),
      ],
    );
  }
}

/// Windows 窗口控制三钮（min/max/close）。热区按 Windows 惯例 46×全高；
/// close 悬停红底白图标，其余悬停浅灰（标题栏文字色低透明，与 macOS 同源取色）。
class _WindowControls extends StatelessWidget {
  const _WindowControls({required this.maximized, required this.onToggleMaximize});

  final bool maximized;
  final VoidCallback onToggleMaximize;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _WindowButton(icon: Icons.minimize, onTap: windowManager.minimize),
        _WindowButton(
          icon: maximized ? Icons.filter_none : Icons.crop_square,
          onTap: onToggleMaximize,
        ),
        _WindowButton(icon: Icons.close, isClose: true, onTap: windowManager.close),
      ],
    );
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.icon,
    required this.onTap,
    this.isClose = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool isClose;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;

  // Windows 标准 caption close 悬停红（与应用 danger 令牌区分：这是系统惯例色）
  static const _closeHoverRed = Color(0xFFE81123);

  @override
  Widget build(BuildContext context) {
    final hoverBg =
        widget.isClose ? _closeHoverRed : Et.titleBarText.withValues(alpha: 0.14);
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          width: 46, // Windows 惯例热区宽，全高（52px 行内）——比方案草案 46×32 更贴系统惯例
          height: double.infinity,
          color: _hover ? hoverBg : Colors.transparent,
          alignment: Alignment.center,
          child: Icon(
            widget.icon,
            size: 16,
            color: widget.isClose && _hover ? Colors.white : Et.titleBarText,
          ),
        ),
      ),
    );
  }
}

class _VaultPill extends StatelessWidget {
  const _VaultPill({required this.onSelectVault});
  final VoidCallback onSelectVault;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: Et.titleBarPill,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onSelectVault,
          borderRadius: BorderRadius.circular(9),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.dns, size: 16, color: Et.titleBarText),
                SizedBox(width: 7),
                Text('Vaults',
                    style: TextStyle(
                        color: Et.titleBarText,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TermTabPill extends StatelessWidget {
  const _TermTabPill({
    required this.label,
    required this.active,
    required this.onTap,
    required this.onClose,
    this.kind = WorkTabKind.terminal,
    this.status,
    this.maxLabelWidth = 160,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final WorkTabKind kind;
  final ValueNotifier<WorkTabStatus>? status; // 会话状态点（null 不显示）
  final double maxLabelWidth;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: active ? Et.titleBarTabActive : Colors.transparent,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  kind == WorkTabKind.sftp
                      ? Icons.folder_copy_outlined
                      : Icons.terminal,
                  size: 15,
                  color: Et.titleBarText.withAlpha(active ? 255 : 130),
                ),
                const SizedBox(width: 7),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxLabelWidth),
                  child: Text(label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: Et.titleBarText.withAlpha(active ? 255 : 150),
                          fontSize: 13)),
                ),
                if (status != null) ...[
                  const SizedBox(width: 6),
                  // 状态点 + 传输计数（断连/失败/传输中都可感知）
                  ValueListenableBuilder<WorkTabStatus>(
                    valueListenable: status!,
                    builder: (context, st, _) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _statusColor(
                              st.phase,
                              connecting: Et.titleBarText.withAlpha(150),
                            ),
                          ),
                        ),
                        if (st.activeTransfers > 0) ...[
                          const SizedBox(width: 4),
                          Icon(Icons.swap_vert,
                              size: 12, color: Et.titleBarText.withAlpha(180)),
                          Text('${st.activeTransfers}',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Et.titleBarText.withAlpha(180))),
                          const SizedBox(width: 3),
                        ],
                        if (st.failedTransfers > 0) ...[
                          Icon(Icons.error_outline,
                              size: 12, color: Et.danger),
                          Text('${st.failedTransfers}',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Et.danger)),
                          const SizedBox(width: 2),
                        ],
                      ],
                    ),
                  ),
                ],
                const SizedBox(width: 6),
                // 关闭按钮：命中区扩到 ~26px（评审 P1）
                InkWell(
                  onTap: onClose,
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: Center(
                      child: Icon(Icons.close,
                          size: 14, color: Et.titleBarText.withAlpha(140)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------- 侧边导航 ----------

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.navIndex,
    required this.onSelect,
  });

  final int navIndex;
  final void Function(int) onSelect;

  static const _items = [
    (Icons.dns_outlined, 'Hosts'),
    (Icons.folder_copy_outlined, 'SFTP'),
    (Icons.key_outlined, 'Keychain'),
    (Icons.compare_arrows, 'Port Forwarding'),
    (Icons.fingerprint, 'Known Hosts'),
    (Icons.history, 'Logs'),
    (Icons.settings_outlined, 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 224,
      color: Et.sidebarBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 品牌行
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset('assets/icon/icon-1024.png',
                      width: 24, height: 24, fit: BoxFit.cover),
                ),
                const SizedBox(width: 9),
                Text('Eterm',
                    style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        color: Et.textPrimary,
                        letterSpacing: 0.2)),
              ],
            ),
          ),
          for (final (i, (icon, label)) in _items.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              child: Material(
                color: navIndex == i ? Et.sidebarSelected : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
                child: InkWell(
                  borderRadius: BorderRadius.circular(9),
                  onTap: () => onSelect(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 11),
                    child: Row(
                      children: [
                        Icon(icon,
                            size: 18,
                            color: navIndex == i
                                ? Et.textPrimary
                                : Et.textSecondary),
                        const SizedBox(width: 11),
                        Text(label,
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: navIndex == i
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: navIndex == i
                                    ? Et.textPrimary
                                    : Et.textSecondary)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text('Eterm',
                style: TextStyle(
                    fontSize: 11.5, color: Et.textSecondary)),
          ),
        ],
      ),
    );
  }
}


// ---------- 手机「更多」页（Port Forwarding / Known Hosts / Logs / Settings 入口） ----------

class _MorePage extends StatelessWidget {
  const _MorePage({required this.onNavigate});

  final void Function(int) onNavigate;

  @override
  Widget build(BuildContext context) {
    Theme.of(context); // 主题切换时随 inherited 重建
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Text('More',
            style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w700,
                color: Et.textPrimary)),
        const SizedBox(height: 12),
        _row(context, Icons.compare_arrows, 'Port Forwarding', '本地 -L 端口转发规则',
            () => onNavigate(3)),
        _row(context, Icons.fingerprint, 'Known Hosts', 'TOFU 主机指纹记录',
            () => onNavigate(4)),
        _row(context, Icons.history, 'Logs', '连接与同步事件',
            () => onNavigate(5)),
        _row(context, Icons.settings_outlined, 'Settings', '账号 / 外观 / 终端字号',
            () => onNavigate(6)),
      ],
    );
  }

  Widget _row(BuildContext context, IconData icon, String title, String sub,
      VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Et.card,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Et.sidebarSelected,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: Et.textPrimary, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w600,
                              color: Et.textPrimary)),
                      const SizedBox(height: 3),
                      Text(sub,
                          style: TextStyle(
                              fontSize: 13, color: Et.textSecondary)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 20, color: Et.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

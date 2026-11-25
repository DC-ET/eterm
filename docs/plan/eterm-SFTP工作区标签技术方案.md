# eterm · SFTP 工作区标签（Keepalive Tab）技术方案

> 版本：v1.3 ｜ 日期：2026-11-25 ｜ 状态：**已实施（M0–M4 完成；代码评审 P0/P1 已闭合）**
> 关联：[eterm-技术方案.md](eterm-技术方案.md)、[eterm-iOS客户端技术方案.md](eterm-iOS客户端技术方案.md)（生命周期先例，下称 iOS 方案 D13）、[eterm-Windows客户端技术方案.md](eterm-Windows客户端技术方案.md)、[AGENTS.md](../../AGENTS.md)（多端一致性 / IndexedStack 断连前科）
> 一句话结论：**把 SFTP 从「Navigator 推入的全屏路由」改造成 Shell 的第一类工作区标签，与终端标签同处一个 `IndexedStack` 常驻保活**。切换标签只换显示下标，不销毁页面 State，因此两侧 SFTP 会话、当前目录、浏览/选区状态、传输队列全部原地存活；终端与 SFTP 可随时互相切换、协同工作。改动集中在 Dart UI 壳层（标签抽象 + SFTP 页拆壳 + 移动端生命周期重连），**Rust 数据面、同步协议、服务端零改动**。
> 行号说明：本文代码位置以 2026-11-25 的 `main`（`add28f3`）为基准，实施时可能漂移，以符号名为准。

> **v1.1 评审修订摘要（首轮子代理评审结论：有阻塞问题）**
>
> - **P0（已复验并改设计）**：原方案「IndexedStack + 内层 `UniqueKey` 保 State」不成立。Flutter 3.50 的 `IndexedStack` 会把 child 包进无 key 的 offstage 容器，元素按**位置**匹配；实测 `[A,B,C]` 关闭中间 B 后，C 的 State 被 dispose 重建。现有终端标签同样中招（终端缓冲区因挂在 `_TerminalTab` 上得以保留，但 SSH 会重连；SFTP 则会丢全部浏览/队列状态）。v1.1 改为 **`GlobalKey`（或 keyed Stack）**，并把「标签容器保活修复」提为 **M0 前置里程碑**（终端先行修复 + 回归测试）。
> - **P1（已并入）**：移动端 SFTP 标签状态栏避让/图标色；回前台探活加超时并并行；重连后队列任务的 session id 重绑；connect/resume 的 in-flight 序号与 mounted 守卫；State 保活的自动化测试。
> - **P2（已收口）**：拆壳与队列 UI 归属、`SftpSideSpec` 依赖方向、async close 的索引安全、状态徽标漏计、失败传输可见性、`_list` 失败语义、编辑页 session 失效、隐藏标签 SnackBar、FGS 启动点与文案、桌面状态假绿、隐藏标签 TickerMode、同主机双连语义、去重方向提示等，逐项处置见 **§10 评审记录**。
>
> **v1.2 二次复审收口**：P0-1 经复核确认闭合，无新增 P0。补：① 重连 `sftpConnect` 失败的 catch/publish（不再停在 connecting spinner）；② logout 改用 `pushAndRemoveUntil`（脏编辑页 `PopScope` 会让 `popUntil` 死循环）；③ `_list/_lsLocal` 的 SnackBar 统一收口到 `visible` 门控；④ rebind 提前到列目录之前并在 rebind 内 `_pump`；⑤ 探活超时遇 running 传输改用临时 `_probeSuspect`（不新增 `_SidePhase.degraded`，不新建连接）；⑥ 取消“按暂停时长杀 running 任务”，只在重连/探活失败时 fail；⑦ 补 D16 桌面聚焦探活矩阵与核验项。M0/M1 可先行，M3 前完成 ①②④⑤⑥，M4 前完成 ②⑦。

---

## 1. 背景、目标与非目标

### 1.1 用户痛点（现状）

目前 SFTP 与终端是两条互斥的交互路径：

1. 终端标签由 Shell 持有（`client/app/lib/ui/shell.dart:48-60`），`IndexedStack` 保活（`shell.dart:250-282`），切标签不重建页面 State。
2. SFTP 是 **push 出来的全屏路由**：
   - Hosts 卡片菜单「SFTP 文件」→ `Navigator.push(SftpDualPage(...))`（`shell.dart:87-101`）；
   - 侧栏「SFTP」入口页 → 「打开 SFTP」→ 同样 push（`client/app/lib/ui/sftp_entry_page.dart:376-385`）。
3. `SftpDualPage` 在 `initState` 建立两侧会话，在 `dispose` 里 `shutdown()` 传输队列并 `sftp_disconnect` 两侧（`client/app/lib/ui/sftp_page.dart:134-160`）。
4. 用户想回终端只能按返回键**弹出路由** → SFTP 页销毁 → 会话断开、浏览目录/选区/传输队列全部丢失；再看文件只能重新配置端点、重新连接。

这不是「连接慢」的问题，而是**页面生命周期绑定了数据面生命周期**：路由在栈顶时 SFTP 活着，路由被 pop 就死。终端已经用「标签常驻 + IndexedStack」解决了同一问题，SFTP 需要对齐。

> **评审发现（P0）**：现有终端标签的保活也有一个潜伏缺陷——关掉非末尾标签时，右侧标签的 State 会被重建（终端会重连）。详见 §2.1.1。本方案必须先修这个容器问题，否则 SFTP 标签同样保不住。

### 1.2 目标

| # | 目标 | 可验收口径 |
|---|---|---|
| G1 | SFTP 成为与终端同级的**工作区标签** | 桌面标题栏 / 手机底部标签条同时显示终端与 SFTP 标签，点选即切换 |
| G2 | 切换标签**不重建、不断连** | 来回切换后 SFTP 两侧 session id 不变、当前目录/滚动/选区/队列保留 |
| G3 | 标签增删不误伤**其它**标签 | 关闭中间/左侧任意标签后，其余标签的 State identity 不变、会话不断（含终端） |
| G4 | SFTP 传输在**后台标签继续跑** | 切到终端标签期间，上传/下载完成、目标侧自动刷新照常发生 |
| G5 | 多标签协同 | 终端 ⇄ SFTP 任意混排；同一对端点再次打开聚焦已有标签（不做重复连接） |
| G6 | 关闭语义明确 | 标签可单独关闭；有进行中传输时先确认，确认后取消队列并断开两侧 |
| G7 | 四端一致 | macOS / Windows 桌面 + Android / iPhone 同一套 Dart 行为；移动端前后台语义与终端标签对齐 |

### 1.3 非目标（本方案不做）

- **不做独立窗口**（macOS/Windows 多窗口并存 SFTP 与终端）——工作区标签已满足协同诉求，多窗口涉及窗口管理/多 Engine，成本与风险不成比例。
- **不做跨进程/重启恢复**：标签仅会话内存在，与终端标签一致；重启后不恢复 SFTP 标签。
- **不做「关标签后传输继续」的全局队列**：队列仍归标签所有；关标签 = 取消传输。若后续确有需求，再单独立项（需要把队列提升为应用级服务并重新设计归属）。
- **不做同一端点对的多标签**：v1 按端点对去重（同终端按 host 去重）；不同端点对可任意多开。
- **不做标签拖拽排序 / 重命名 / 分屏**。
- **不改 Rust / 中枢 / wire 协议**：复用现有 `sftp_*` FFI 与 SSH keepalive。

### 1.4 成功标准（一句话）

> 用户打开终端与 SFTP 后，可以像切换多个终端一样在两者间来回切换：终端输出不断、SFTP 目录不丢、传输继续跑；关闭任意标签都不会影响其它标签；只有显式关闭标签才会释放连接。

---

## 2. 现状盘点（代码证据）

### 2.1 终端标签的保活机制（含潜伏缺陷）

| 机制 | 位置 | 说明 |
|---|---|---|
| 标签数据由 Shell 持有 | `shell.dart:48-60` | `_TerminalTab` 持有 `host/凭据/Terminal/phase`；`tabs` 列表 + `activeTab` 下标 |
| 所有标签同时挂载 | `shell.dart:250-282` | `IndexedStack(index: activeTab + 1, children: [vault, ...tabs])`，只切显示，不卸载 |
| Key 使用 | `shell.dart:49, 261` | ⚠️ 现状用 `UniqueKey` 绑内层 `TerminalTabView`。它只能防同位置的 widget 更新，**防不了 IndexedStack 位置移位**（见 §2.1.1） |
| 会话在页面 State 内 | `terminal_tab.dart:75-130` | `russh` 会话、事件订阅、重连逻辑都在 `_TerminalTabViewState`，页面常驻即会话常驻；终端缓冲区在 `_TerminalTab.terminal`，State 重建不丢屏但会重连 |
| 移动端生命周期 | `terminal_tab.dart:48-66` + `shell.dart:156-180` | 退后台登记存活状态；回前台探活/自动重连（iOS 方案 D13） |
| Android 前台服务 | `fg_service.dart` + `shell.dart:83,117` | 有终端标签时启停常驻通知，防进程冻结 |

#### 2.1.1 P0：IndexedStack 的内层 UniqueKey 不能跨位置保 State（实测）

**框架行为**：Flutter 3.50 的 `IndexedStack.build` 会把每个 child 包进无 key 的 offstage/visibility 容器；`Element.updateChildren` 对无 key 的直接 child 按**位置**匹配。`UniqueKey` 绑在更内层的 `TerminalTabView` 上，到不了这一层匹配。

**实测（Flutter 3.50.0，最小 widget 测试）**：

| 场景 | 关闭中间 B 后 C 的 State |
|---|---|
| 内层 `UniqueKey`（现状） | **被 dispose 并重建**（`identical(c0, c1) == false`） |
| 内层 `GlobalKey` | 保留（`identical(c0, c1) == true`） |

**影响**：

- 现有终端标签：关中间/左侧标签，右侧终端 `TerminalTabView` 全部重建 → SSH 重连（缓冲区因在 `_TerminalTab` 上而保留，所以不易被察觉）。
- 若 SFTP 沿用 `UniqueKey`：关任意非末尾标签，右侧 SFTP 标签的会话、当前目录、选区、**传输队列**全部丢失——正是本方案要消除的痛点。
- 现有回归用例 `test/code_review_bugs_test.dart:116-137` 只断言 `activeTab` 下标，测不出 State 重建。

**修复**（M0 前置）：

1. 每个标签的 `WorkTab.key` 使用 **`GlobalKey`**，绑在标签内容 widget（`TerminalTabView` / `SftpWorkspace`）上；实测可跨位置重挂载保 State。GlobalKey 全局唯一，一个标签一个，关闭即随 widget 销毁。
2. 备选：把 `IndexedStack` 换成 `Stack + KeyedSubtree(key: tab.key) + Offstage/Visibility.maintain`，把 key 放到直接 child 层；需自行补焦点隔离、语义隐藏与 `TickerMode`，代码量更大。v1.1 选 GlobalKey。
3. **必须补回归测试**：开 3 个标签，记录各 `TerminalTabView`/`SftpWorkspace` 的 State identity，关中间/左侧后断言其余 identity 不变（§7.1）。

### 2.2 SFTP 为什么互斥

| 现状 | 位置 | 后果 |
|---|---|---|
| SFTP 是 push 路由 | `shell.dart:95-100`、`sftp_entry_page.dart:380-383` | 路由覆盖 Shell；终端标签仍在后台存活，但无法切换（路由栈顶） |
| 返回键 = pop 路由 | 无 `PopScope`（对比 Shell 的 `shell.dart:287-291`） | pop → `dispose` → 会话与队列全部释放 |
| 页内 State 独占数据面 | `sftp_page.dart:119-160` | 两个远端会话、本地浏览状态、`SftpTransferQueue`、自动刷新登记都在 `_SftpDualPageState` |
| 页内自带 Scaffold/AppBar/Back | `sftp_page.dart:1525-1615` | 作为标签嵌入时会出现「返回键/双标题/双进度条」语义冲突，必须拆壳 |

### 2.3 SFTP 页内部状态盘点（迁移时必须原样保留）

`_SftpDualPageState`（`sftp_page.dart:119-160`）持有的状态：

- `_l/_r` 两侧 `_Side`：`phase`、`sessionId`、远端 `rpath/rentries`、本地 `lpath/lroot/lentries`、选区 `selection`、`listSeq/localListSeq`；
- `SftpTransferQueue _queue`：任务列表、并发 2、取消/重试/续传；
- `_autoRefresh`：任务完成后按「目标侧 + 目标目录」刷新；
- `_busy`、`_activeSide`（手机单栏）；
- 每个子组件（`_FileRow/_QueueRow` 等）无独立生命周期。

结论：**只要 State 不销毁，上述全部自动保留**；本方案的核心就是让该 State 成为 IndexedStack 的常驻 child，而不是路由页。

### 2.4 可直接复用的能力

| 能力 | 现状 | 复用方式 |
|---|---|---|
| SSH/SFTP keepalive | `rust/src/api/ssh.rs:96-97`（15s × 3）；`sftp_connect` 复用 `connect_and_auth`（`rust/src/api/sftp.rs:129-145`，注释 `:37` 说明 Handle 留在保活任务） | **不改**：SFTP 会话已有链路保活 |
| 移动端生命周期先例 | `shell.dart:156-180` + `terminal_tab.dart:48-66` | 新增 SFTP 注册表与 `sftpTabsOnAppPaused/Resume`，同一生命周期入口调用 |
| 标签状态点 | `shell.dart:699-783`（桌面 pill）、`:410-472`（手机 pill） | 泛化为工作区标签 pill，增加 SFTP 图标/状态/传输徽标 |
| 传输队列 UI | `sftp_page.dart:1572-1615`（AppBar 队列按钮 + 3px 进度条） | 拆壳后归 SFTP 工作区内部所有（见 §4.3） |
| Android 前台服务 | `fg_service.dart` | 保活条件从「终端标签非空」改为「工作区标签非空」，并同步 Kotlin 文案 |

### 2.5 约束与已知坑

1. **IndexedStack 位置移位（P0，见 §2.1.1）**：内层 `UniqueKey` 不能跨位置保 State；必须 `GlobalKey` 或 keyed Stack。这是本方案的**前置修复**，不是可选项。
2. **跨 720 断点的子树结构变化（已知 P1）**：终端已用「`Column + Expanded` 恒定结构」缓解（`shell.dart:254-280`）；SFTP 标签必须沿用同一稳定结构，手机标签条仅作为 `if (compact)` 尾部 child，不改变首 child 类型。
3. **移动端状态栏**：Shell 现状在「有标签激活时」统一用浅色图标（`shell.dart:292-295`），这是为终端深色状态栏设计的；SFTP 标签是浅色内容，必须按标签类型切换图标色并做顶部 SafeArea（§4.3.3）。
4. **移动端后台不可保活（iOS）**：与终端 iOS 方案 D4 同口径——退后台进程挂起、socket 冻结；恢复必须依赖回前台探活/重连，不能宣称「后台一直活着」。
5. **SFTP 无断线事件流**：终端有 `SshEvent` 的 Closed；SFTP 只有操作报错。状态点存在「假绿」风险，需要操作失败探活 + 回前台/桌面聚焦探活（§4.6.4）。
6. **多端一致**：共享 Dart 改动必须四端验证；Windows 构建须 Windows 机执行（AGENTS.md）。
7. **传输队列归属**：队列在隐藏标签里继续跑，但标签销毁即取消；不能留下「无主队列」。

---

## 3. 总体方案

### 3.1 结构对比

**现在**

```
Shell（Scaffold）
├─ 桌面 TitleBar / 手机 MobileTabBar   ← 只有终端标签
└─ IndexedStack(index = activeTab + 1)
   ├─ [0] vaultView（Hosts/SFTP入口/…）
   ├─ [1] TerminalTabView(terminal A)   ← 常驻（关左侧标签时可能被重建）
   └─ [2] TerminalTabView(terminal B)   ← 常驻

Navigator.push(SftpDualPage)             ← 覆盖 Shell
└─ SftpDualPage(Scaffold + AppBar + Back)
   └─ 会话 / 队列 随 dispose 销毁
```

**方案**

```
Shell（Scaffold）
├─ 桌面 TitleBar / 手机 MobileTabBar   ← 终端 + SFTP 混合标签
└─ IndexedStack(index = activeTab + 1)
   ├─ [0] vaultView（Hosts/SFTP入口/…）
   ├─ [1] TickerMode(Column(Expanded(TerminalTabView)))  ← GlobalKey 保活
   ├─ [2] TickerMode(Column(Expanded(SftpWorkspace)))     ← GlobalKey 保活（本方案核心）
   └─ [3] TickerMode(Column(Expanded(SftpWorkspace)))     ← 可多开（不同端点对）

Navigator.push(SftpEditPage)              ← 仍为覆盖 Shell 的编辑路由（所属 TAB 在下方保活）
```

### 3.2 关键设计点

| # | 设计点 | 一句话 |
|---|---|---|
| 1 | 统一工作区标签模型 | `WorkTab` 抽象 + 单一有序列表 + `activeTab`，终端/SFTP 混排 |
| 2 | State 归属不变 | 会话/队列仍归 `SftpWorkspace` 的 State；IndexedStack 保活，标签对象只存规格与状态 notifier |
| 3 | 页面拆壳 | `SftpWorkspace` 嵌入模式无 Scaffold/AppBar/Back；非嵌入模式自带 Scaffold（兼容旧路由入口），队列 UI 始终在 workspace 内部 |
| 4 | 状态回传 | 工作区把「阶段 + 进行中传输数 + 失败传输数」写入单一 `WorkTabStatus` notifier，pill 订阅，不触发 Shell 全量 setState |
| 5 | 打开/去重 | 同一无序端点对只留一个标签；再次打开聚焦已有（反向时提示） |
| 6 | 关闭确认 | 有非终态传输时确认；确认后取消队列、断开两侧、销毁 State |
| 7 | 移动端恢复 | 回前台对「挂起时 live」的远端侧做带超时的 realpath 探活；失败自动重连、重绑队列 session、保留目录 |
| 8 | 保活关键 | 标签 key 用 **GlobalKey**（P0 修复），child 结构跨断点恒定，隐藏标签 `TickerMode(enabled:false)` |
| 9 | 前台服务 | Android 有任意工作区标签即保活；通知渠道/文案泛化 |

### 3.3 为什么不选其它方案

| 备选 | 不选原因 |
|---|---|
| 把 SFTP 做成可伸缩的浮层/侧边抽屉 | 双栏 SFTP 需要宽度；浮层遮挡终端，移动端更不可用；仍要自己管理显隐与生命周期，收益不如标签 |
| SFTP 独立窗口（多窗口） | 需要多 Engine / 窗口状态同步，macOS/Windows 双端实现成本高，超出本次诉求 |
| 关掉 SFTP 页时不断开（降级为后台服务） | 页面销毁后没有 UI 宿主，队列/自动刷新/错误提示都无处安放；等于重做应用级传输服务 |
| 仅把终端改成可从 SFTP 内嵌打开 | 只是把互斥方向反过来，仍不能同时看终端和文件操作；且不满足「多个 Tab 都存活」 |
| 每次切换重建 SFTP、靠重连恢复 | 与 G2 直接冲突；重连会丢失浏览位置/队列，体验比现状更差 |
| 继续用 `UniqueKey` 保活 | 实测关中间/左侧标签会重建右侧 State（§2.1.1），不成立 |

---

## 4. 详细设计

### 4.1 统一工作区标签模型

建议新增 `client/app/lib/ui/work_tabs.dart`（共享模型：可依赖 Flutter/xterm 与 `HostView`/`Terminal`，但**不得 import `sftp_page.dart`**，避免循环依赖）：

```dart
enum WorkTabPhase { connecting, live, degraded, closed }

enum WorkTabKind { terminal, sftp }

@immutable
class WorkTabStatus {
  const WorkTabStatus({
    this.phase = WorkTabPhase.connecting,
    this.activeTransfers = 0,   // 非终态任务（queued + running）
    this.failedTransfers = 0,   // 失败待重试
  });
  final WorkTabPhase phase;
  final int activeTransfers;
  final int failedTransfers;

  WorkTabStatus copyWith({...});
  @override bool operator ==(Object other) => ...; // 值相等
  @override int get hashCode => ...;
}

sealed class WorkTab {
  WorkTab({required this.key, required this.label, required this.kind,
      WorkTabPhase initialPhase = WorkTabPhase.connecting})
      : status = ValueNotifier(WorkTabStatus(phase: initialPhase));
  final GlobalKey key;            // P0 修复：必须 GlobalKey（§2.1.1）
  final String label;
  final WorkTabKind kind;
  final ValueNotifier<WorkTabStatus> status;
}

class TerminalWorkTab extends WorkTab {
  final HostView host;
  final String authKind;
  final String secret;
  final Terminal terminal = Terminal(maxLines: 20000);
}

class SftpWorkTab extends WorkTab {
  final SftpSideSpec left;        // 类型移到 work_tabs.dart 或 sftp_spec.dart
  final SftpSideSpec right;
  final String dedupeKey;         // 无序端点对
}
```

要点：

- **`GlobalKey` 而非 `UniqueKey`**：见 §2.1.1；一个标签一个 key，标签关闭时随内容 widget 销毁。不要把同一个 GlobalKey 同时给两个 widget（会直接抛 duplicate key）。
- **状态单一 notifier**：phase + 传输计数合并为 `WorkTabStatus`，桌面/手机 pill 共用一个 builder；notifier 不手动 dispose（与现有 `_TerminalTab.phase` 同口径：State 帧末才销毁，期间事件可能回写，手动 dispose 会 use-after-dispose；交给 GC）。
- **`SftpSideSpec` 依赖方向**：当前定义在 `sftp_page.dart:31-36`，若 `work_tabs.dart` 直接 import 会反向依赖 Flutter/FFI。把 `SftpSideSpec` 移到 `work_tabs.dart`（或独立 `sftp_spec.dart`），`sftp_page.dart` 改为 import。
- **`activeTab` 仍留在 `_ShellPageState`**：现有 `shell.activeTab` / `openTerminal` / `closeTab` 的测试钩子（`test/code_review_bugs_test.dart:116-137`）保持可用。
- **阶段聚合**（只看远端侧；本机侧不参与）：
  1. `failed == total` → `closed`；
  2. `failed > 0` → `degraded`（哪怕其余侧还在 connecting）；
  3. `live == total` → `live`；
  4. 否则 `connecting`。
  - 本机侧 `localPending`（桌面尚未选目录）不算失败，不影响聚合。

### 4.2 Shell 改造

#### 4.2.1 桌面标题栏（`_TitleBar` / `_TermTabPill`）

- pill 增加 `WorkTabKind` 图标：终端 `Icons.terminal`，SFTP `Icons.folder_copy_outlined`。
- 文案：SFTP 默认 `'${left.label} ⇄ ${right.label}'`（如 `k7 ⇄ 本机`），超长截断（沿用 `maxWidth: 160`）。
- 状态点：`live` 绿 / `connecting` 灰 / `degraded` 琥珀 / `closed` 红。
- 传输徽标：`activeTransfers > 0` 显示进行中计数（accent）；`failedTransfers > 0` 显示失败计数（danger），避免隐藏标签失败无感知。
- 关闭按钮保持 26×26 命中区。

#### 4.2.2 手机底部标签条（`_MobileTabBar`）

- 手机沿用现有**吸底**标签条（与终端一致；顶部留给内容与 SafeArea，避免与状态栏/键盘冲突），因此「顶部 Tab」在桌面是标题栏横排标签，在手机是终端同款底部标签条，交互位置不同、模型一致。
- 复用同一套 pill 渲染（抽公共 widget，避免桌面/手机两份 switch）。
- 左「返回列表」保持 `activeTab = -1`（vault），**不关闭标签**；「+」仍回 vault。

#### 4.2.3 IndexedStack 结构与保活（P0 修复）

```dart
final body = IndexedStack(
  index: activeTab + 1,
  children: [
    vaultView,
    for (final (i, t) in tabs.indexed)
      TickerMode( // 隐藏标签停动画（spinner / 不确定进度条）
        enabled: activeTab == i,
        child: Column( // 结构跨断点恒定：只切 if (compact) 尾 child，不换类型
          children: [
            Expanded(
              child: switch (t) {
                TerminalWorkTab() => TerminalTabView(
                    key: t.key, // GlobalKey
                    host: t.host, terminal: t.terminal,
                    authKind: t.authKind, secret: t.secret,
                    onPhase: (p) => t.status.value = t.status.value.copyWith(
                      phase: mapTermPhase(p),
                    ),
                  ),
                SftpWorkTab() => SftpWorkspace(
                    key: t.key, // GlobalKey
                    left: t.left, right: t.right,
                    status: t.status,
                    visible: activeTab == i,
                  ),
              },
            ),
            if (compact) _MobileTabBar(/* 混合标签列表 */),
          ],
        ),
      ),
  ],
);
```

- **必须**使用 GlobalKey（§2.1.1）；`UniqueKey` 会在关中间/左侧标签时重建右侧 State。
- **禁止**把 `if (compact)` 写在 `Expanded` 外层改变 child 类型，或在 desktop/compact 返回不同 widget 类型（已知 P1）。
- `TickerMode` 只切 `enabled` 属性，不改变结构；隐藏标签的 spinner/不确定进度条不再耗电。
- vault 页（Hosts/SFTP 入口）继续常驻 index 0；打开标签不销毁 vault。
- 标签增删时 Flutter 通过 GlobalKey 重挂载/销毁正确 State（M0 有回归测试）。

### 4.3 SFTP 页面拆壳：`SftpWorkspace`（嵌入 / 路由双模）

拆分目标：**数据面 State 不搬家，只把「路由外壳」与「工作区内容」分离**；队列 UI 始终归 workspace，避免外层拿不到 `_queue`。

| 模式 | 组件 | 外壳 | 使用方 |
|---|---|---|---|
| 嵌入（`embedded: true`） | `SftpWorkspace` | 无 Scaffold/AppBar/Back；`ColoredBox` + 顶部工具行 + 内容 | Shell 标签 |
| 路由（`embedded: false`） | `SftpWorkspace` 自身渲染 `Scaffold + AppBar`（标题/返回），body 复用同一内容 | 是 | M1 的旧 `SftpDualPage` 薄包装（5 行，无 queue 访问） |

具体改动：

1. 把 `_SftpDualPageState` 的构建体拆成 `SftpWorkspace` 的 State（仍在本文件，避免大搬迁）；`SftpDualPage` 变为 `SftpWorkspace(embedded: false)` 的薄壳（或 M2 后两个入口都走标签，可删除）。
2. `SftpWorkspace` 构造参数新增：
   - `ValueNotifier<WorkTabStatus>? status`（标签侧传入，workspace 写入）；
   - `bool visible = true`（隐藏标签用于抑制 SnackBar）；
   - `bool embedded = true`。
3. **队列入口与进度条**（现状在 AppBar，`sftp_page.dart:1572-1615`）：
   - 嵌入模式：双侧面板上方一行 slim 工具条（约 36 高）：右侧队列按钮（Badge 进行中/失败数）+ 最顶部固定 3px 进度条槽位；
   - 手机：并入 `SegmentedButton` 所在行右侧，节省纵向空间；
   - 路由模式：同一组件放进 AppBar，避免重复实现。
4. **返回键/标题**：嵌入模式无 AppBar；桌面标题栏承载标题/关闭，手机底部标签条承载。
5. **SnackBar**：workspace 持有 `visible`；隐藏时只更新状态、不弹全局 SnackBar（失败由 pill 红徽标与队列表示）；可见时行为不变。见 §4.8。
6. **编辑页**：`SftpEditPage` 仍由 workspace 内 `Navigator.push`（`sftp_page.dart:1110-1127`），覆盖 Shell；所属标签在其下方保活；编辑页 session 失效处理见 §4.9。

#### 4.3.3 移动端状态栏与 SafeArea（评审 P1-1）

现状 `SftpDualPage` 由 `Scaffold + AppBar` 隐式消费顶部安全区并设置图标色；去掉 AppBar 后必须显式处理：

- `SftpWorkspace` 嵌入模式外层：`ColoredBox(color: Et.contentBg)` 包 `SafeArea(top: true, bottom: false, child: 内容)`，背景延伸到状态栏下；
- Shell 的状态栏图标色改为按**活动标签类型**分支：

```dart
final activeKind = activeTab >= 0 ? tabs[activeTab].kind : null;
final lightIcons =
    (compact && activeKind == WorkTabKind.terminal) || // 终端深色顶栏
    (Et.brightness == Brightness.dark);                 // 深色主题
// SFTP 浅色内容 → dark 图标；vault → 现有逻辑
```

- 验收矩阵增加「浅色主题 + SFTP 标签状态栏截图」（§7.2）。
- 路由模式由 AppBar 自动处理，无需特判。

### 4.4 状态回传与标签 UI

```dart
// SftpWorkspace 内部：单一状态 notifier
void _publishStatus() {
  final remote = [if (!_l.isLocal) _l.phase, if (!_r.isLocal) _r.phase];
  final phase = aggregateSftpPhase(
    total: remote.length,
    live: remote.where((p) => p == _SidePhase.live).length,
    failed: remote.where((p) => p == _SidePhase.failed).length,
  );
  final status = WorkTabStatus(
    phase: phase,
    activeTransfers: _queue.jobs.where((j) => !j.isTerminal).length,
    failedTransfers: _queue.jobs.where((j) => j.state == SftpJobState.failed).length,
  );
  if (widget.status?.value != status) widget.status?.value = status;
}
```

- **触发点**：
  - 每侧 `_connect/_reconnect` 阶段变更后（`setState` 后调 `_publishStatus`）；
  - 队列监听**单独**注册 `_queue.addListener(_publishStatus)`，或放在 `_onQueueChanged` 的**最前面**（注意现状 `sftp_page.dart:846-847` 有 `if (_autoRefresh.isEmpty) return;`，若把 publish 放在早退之后，首个任务入队（`_registerAutoRefresh` 在 enqueue 之后）时徽标会漏计）。
- **失败传输**：`failedTransfers` 进 pill（红徽标）；隐藏标签也有可见信号，不只靠打开队列弹窗。
- **终端侧**：`TerminalWorkTab.status.phase` 由 `onPhase` 写入，`active/failed` 恒 0；为统一 pill，把 `TermPhase` 映射到 `WorkTabPhase`（TermPhase 本身不动）。
- pill 的 `ValueListenableBuilder<WorkTabStatus>` 只订阅一个 notifier，减少样板。

### 4.5 打开、去重与关闭语义

#### 4.5.1 打开

```dart
int openSftp(SftpSideSpec left, SftpSideSpec right) {
  final key = sftpPairKey(left, right);          // 无序、local 归一为 'local'
  final existing = tabs.indexWhere(
    (t) => t is SftpWorkTab && t.dedupeKey == key,
  );
  if (existing >= 0) {
    // 若请求左右与现有标签相反，提示方向可反向拖拽（不重建标签）
    return existing;
  }
  tabs.add(SftpWorkTab(...));                     // GlobalKey 在此创建
  FgService.setKeepAlive(true);                   // 仅 SFTP 标签也要保活（评审 P2-13）
  return tabs.length - 1;
}
```

- 去重键：`{leftId,rightId}` 排序后拼接；本机侧统一为 `local`。A⇄B 与 B⇄A 视为同一个标签；聚焦时若左右相反，用 SnackBar 提示「已切到现有 A ⇄ B 标签，可直接从 B 侧拖拽」。
- **去重只看端点、不比较凭据**：与终端标签复用口径一致（编辑主机凭据不影响已开标签；旧凭据失效需关闭重开）；聚焦失败中的已有标签不自动重连，由用户点重试。
- 入口：
  - Hosts 卡片「SFTP 文件」：`openSftp(host⇄本机)`（替换 `_openSftpFor` 的 push）；
  - SFTP 入口页「打开 SFTP」：新增 `onOpen` 回调，由 Shell 传入 `openSftp(leftSpec, rightSpec)`；
  - 打开后 `setState(activeTab = index)`；vault 页保持原状。
- 不做同一端点对多标签；不同端点对可多开。
- **`openHostIds` / `openTerminal` 适配**：`shell.dart:74` 的 `t.host.id` 与 `:200` 的 `openHostIds` 在 `List<WorkTab>` 下必须只筛 `TerminalWorkTab`（Hosts 页的“已打开”语义仍指终端）；SFTP 标签不改变该指示（可选后续加文件夹角标）。

#### 4.5.2 标签切换

- 只改 `activeTab`，IndexedStack 换显示下标；**不触发任何 connect/disconnect**。
- Android 返回键（`PopScope`，`shell.dart:287-291`）：任意标签激活时返回到 vault（`activeTab = -1`），标签继续存活；不关闭、不断连。
- iOS 无返回键；标签切换只靠标题栏/底栏。

#### 4.5.3 关闭（async 安全）

```dart
bool _closing = false; // Shell 级防双击

Future<void> closeTab(int i) async {
  if (_closing) return;
  final target = (i >= 0 && i < tabs.length) ? tabs[i] : null;
  if (target == null) return;
  if (target is SftpWorkTab && target.status.value.activeTransfers > 0) {
    _closing = true;
    final ok = await _confirmCloseSftp(target); // 取消 / 关闭并取消传输
    _closing = false;
    if (ok != true || !mounted) return;
  }
  if (!mounted) return;
  final idx = tabs.indexOf(target);             // await 后按身份重新定位
  if (idx < 0) return;                          // 期间已被关闭/登出
  setState(() {
    tabs.removeAt(idx);
    // 现有 activeTab 修正逻辑保持不变（BUG-D2 语义）
    if (tabs.isEmpty) {
      activeTab = -1;
    } else if (idx < activeTab) {
      activeTab -= 1;
    } else if (activeTab >= tabs.length) {
      activeTab = tabs.length - 1;
    }
  });
  FgService.setKeepAlive(tabs.isNotEmpty);
}
```

- 关闭确认文案：`「有 N 个传输进行中，关闭标签将取消传输（未完成暂存保留，但需重新发起）」`。
- 确认后：标签移出 IndexedStack → `SftpWorkspace.dispose` → `_queue.shutdown()` + `sftp_disconnect` 两侧（现有逻辑原样生效）。
- **`.eterm-part` 文案必须如实**：重开标签后新任务 `resume=false` 会截断/清理暂存（Rust `sftp.rs` 的 download/upload/copy 实现），只有**同一队列内 retry** 才能续传；不要暗示「重开自动续」。
- 关闭最后一个标签：`activeTab = -1`，FGS 停止。
- 关闭左侧标签的 activeIndex 修正复用现有逻辑（BUG-D2 回归用例继续绿），并用 M0 的 State identity 测试保证右侧不重建。

### 4.6 连接与生命周期（移动端恢复 / 桌面策略）

#### 4.6.1 注册表

在 sftp workspace 文件内仿照终端：

```dart
final Set<_SftpWorkspaceState> _activeSftpWorkspaces = {};

void sftpTabsOnAppPaused() {
  for (final s in _activeSftpWorkspaces) s._onAppPaused();
}

void sftpTabsOnAppResume() {
  for (final s in _activeSftpWorkspaces) s._onAppResume();
}
```

`_SftpWorkspaceState.initState` 注册、`dispose` 注销；Shell 的 `didChangeAppLifecycleState`（`shell.dart:156-180`）在现有终端调用旁增加这两行。

#### 4.6.2 paused

- 对每个远端侧记录 `_liveAtPause = (phase == live)`；
- 不做任何主动断开（Android FGS 下连接可继续；iOS 由系统冻结）；
- 不取消队列（传输若被系统掐断，流错误会让队列标 failed）。

#### 4.6.3 resumed（仅移动端，Shell 已有平台闸）

**每侧独立、并行、带超时**：

```
对每个远端侧（独立 Future，互不阻塞）：
  若 !mounted / phase != live / !liveAtPause → 跳过
  try:
    probe = await sftpRealpath(id, '.').timeout(6s)
    成功 → 会话仍活，_probeSuspect=false，结束
  catch:
    若队列有该侧 running 任务：
      不立刻重连（可能只是通道忙/大传输）：
        _probeSuspect = true（仅让 pill 聚合为 degraded，不改 _SidePhase）
        保留旧 sessionId 与连接所有权；不新建连接（防双连接）
      等任务流报错或用户显式重试；用户可先取消任务再重试
    否则 → reconnect：
      1) 记下 oldId / 原 rpath
      2) phase=connecting，sessionId=null，_probeSuspect=false，_publishStatus()
      3) sftpDisconnect(oldId)（幂等）
      4) try: newId = sftpConnect(...) + sftpRealpath('.')
         catch: phase=failed + reason；_publishStatus()；return
      5) 成功：phase=live；_publishStatus()
         _queue.failJobsForSession(oldId) + rebindSession(oldId, newId)（内部 _pump）
         （running 标 failed；queued/failed 立即重绑到新 id，重试不会拿旧 id）
         ok = await _listOrThrow(原 rpath)
         if (!ok) { s.rpath = await sftpRealpath(newId,'.'); await _listOrThrow(s.rpath); SnackBar 提示 }
      6) 每个 await 后检查 mounted && seq == s.connectSeq；被取代的 newId 立即 disconnect
```

- **超时**：探活 6s；否则 iOS 解冻后的黑洞连接会让恢复流程永久挂起。`_resuming` 不再作为全局布尔——用每侧 `connectSeq` 操作令牌，避免吞掉下一次 resumed。
- **`_probeSuspect`**：`_SidePhase` 不新增 `degraded`（避免扩散到现有 UI switch）；它是 workspace 内的临时标记，`_publishStatus` 聚合时把该侧视为 degraded。旧连接与 `sessionId` 保持不动（所有权清晰），用户可取消任务后手动重试；后续操作成功或探活成功即清除。
- **连接竞态（P1-4）**：`_connect`/`_reconnect` 增加每侧 `connectSeq`（与现有 `listSeq` 同款）：每次发起自增，所有 `await` 后校验 `mounted && seq == s.connectSeq`；被新操作取代的 `sftpConnect` 结果立即 `sftpDisconnect`，防孤儿连接。手动重试按钮在 `phase == connecting` 时不可见/禁用。
- **队列重绑（P1-3）**：`SftpTransferJob.sessionFrom/sessionTo` 改为可变，或新增 `SftpTransferQueue.rebindSession(oldId, newId)` + `failJobsForSession(oldId, reason)`：
  - running（旧会话上的）→ 标 failed，释放并发槽；`resume=true`（retry 时才置，保证续传）；
  - queued（尚未启动）→ 直接改绑新 id；
  - 已有 failed → 改绑新 id，用户点重试可用；
  - `rebindSession` 末尾调用 `_pump()`，否则 fail 释放的槽不会补位；
  - `tarDownload` 走 `specFrom` 独立建连，不受影响。
- **不自动重试传输**：恢复后 failed 任务留给用户点重试（避免自动覆盖/重复写），但 session 已重绑，重试必成功。
- **running 任务防堵槽**：`SftpTransferJob` 增加 `lastProgressAt`。**仅在所属侧已重连或探活失败时**把 running 标 failed（不能按“暂停时长”直接判死——iOS 挂起 30s 后 `lastProgressAt` 必然陈旧，会误杀仍活着的传输）。若探活成功但流长时间无进度（建议 ≥2 分钟）且再次探活失败，才标 failed 释放槽；Android FGS 正常保活时通常不会触发。
- **`_list` 失败语义（P2-6）**：现状 `_list` catch 后设 `rentries=[]` + SnackBar，不返回结果，无法判断“目录不存在”还是“连接失败”。拆出 `Future<bool> _listOrThrow(s)`（或让 `_list` 返回 bool）；重连时用它决定“保留原目录 / 回 home”，回 home 分支必须同步 `s.rpath`。注意 `_list` 会清选区（现状语义），回 home 后选区清空是预期。
- **`sessionId` 清理（P2-7）**：重连开始/失败时置空，避免 `_canTransfer`/菜单依据旧 id 显示“可传”但任务必失败。
- **编辑页（P2-8）**：`SftpEditPage` 不再持有固定 `sessionId`，改为 `BigInt Function() sessionIdProvider`（或 `ValueListenable<BigInt?>`）；保存/stat 用当前 id；若所属侧重连，页面显示「连接已重连，将使用新会话保存」；若侧断开，保存给出明确错误。

#### 4.6.4 前台网络抖动与桌面假绿

- **操作失败探活**：任何 SFTP 操作失败时，用 3s 超时 `sftpRealpath('.')` 判断；失败则把该侧标 `failed`，避免状态点长期假绿。目录不存在（realpath 成功）不误判为断连。
- **桌面聚焦探活（D16）**：桌面无 resumed（窗口聚焦是噪声，终端 iOS 方案 D13 同口径），但 SFTP 无 Closed 事件。v1 在 `shell.dart` 桌面路径挂 `windowManager` 的 focus 监听，**仅对当前活动 SFTP 标签**、节流 ≥30s、6s 超时地探活其 live 侧；失败标 failed。非活动标签不做周期探活（省 RTT）。
- **状态点语义**：pill 的绿点表示“最近一次操作/探活正常”，不是实时 socket 监控；文档和 tooltip 需说明（避免承诺实时性）。
- 不新增后台心跳线程：Rust 侧 SSH keepalive（15s×3）已覆盖静默断链检测。

### 4.7 Android 前台服务

- `openTerminal` / `openSftp` / `closeTab` 统一按 `tabs.isNotEmpty` 调用 `FgService.setKeepAlive(...)`；**仅 SFTP 标签时也必须启动**（评审 P2-13）。
- `TerminalForegroundService.kt`：
  - 通知渠道名 `"终端连接"`（`:48`）、通知标题/正文 `"终端连接保持中"`（`:61`）泛化为「会话连接 / 会话保持中」；
  - 类名与注释可保留（或后续重命名为 `SessionForegroundService`，涉及 Manifest 注册，不在本期强制）。
- iOS 无等价物：不声称后台传输可用；退后台按 §4.6 恢复。
- FGS 是「尽力保活」：极端内存压力/Doze 仍可能冻结；恢复路径必须能自愈。

### 4.8 传输队列与隐藏标签

- 队列继续每标签一个（并发 2），切标签不影响执行；任务完成自动刷新目标侧（现有 `_onQueueChanged` 逻辑不变）。
- **TickerMode**：隐藏标签 `TickerMode(enabled:false)`，停掉 spinner/不确定进度条动画（IndexedStack 只停绘制不停 ticker）。
- **状态发布**：见 §4.4，独立于 `_autoRefresh` 早退，进行中/失败计数不漏。
- **SnackBar 策略（D17）**：workspace 持有 `visible`；隐藏时 `_toast/_err` 只做状态变更（`_busy`、phase），不弹全局 SnackBar——避免用户在终端里被“读取目录失败”打断；**`_list`/`_lsLocal` catch 里的直接 `ScaffoldMessenger.showSnackBar` 也要收口到同一 `_snack`（带 visible 判断）**。失败传输由 pill 红徽标 + 队列弹窗呈现；可见时行为不变。
- 资源上限：v1 按端点对去重已能限制重复连接；不设硬上限（标签条横向滚动）。若后续出现大量标签导致内存/句柄压力，再加软上限（如 8 个 SFTP 标签提示）。
- 关闭标签时 `shutdown()` 是异步的：页面 State 先 dispose，队列内部 `_disposed` 标志保证迟到事件不再 notify（现有实现），无需新增保护。

### 4.9 与编辑页 / 弹层的关系

- `SftpEditPage`、重命名/删除/冲突/队列弹窗全部是 root Navigator 上的路由/弹层，覆盖 Shell；标签在其下方保活。
- 因为弹层是模态的，用户无法在弹层打开时切换标签，故不存在「编辑页属于已关闭标签」的悬空场景。
- **session 失效**：编辑页改用动态 session id（§4.6.3），重连后保存可继续；若侧断开，保存给出明确错误，内容保留在编辑框，用户可复制。
- 编辑页返回后刷新所属标签目录；若期间 App 被挂起，恢复逻辑只处理连接，不关闭编辑页。
- **logout/401（P2-16）**：现有 `pushReplacement` 在栈顶为编辑页/弹层时替换的是栈顶路由，Shell 仍在栈底，标签不会立即 dispose。M4 **必须用 root navigator 的 `pushAndRemoveUntil(LoginPage, (r) => false)`（或 `removeRoute`）**，不能把 `popUntil(isFirst)` 作为首选：`SftpEditPage` 脏编辑时 `PopScope` 会让 `Navigator.pop()` 不移除路由（`sftp_edit_page.dart:220-222`），`popUntil` 会对同一路由反复 pop、死循环/重复弹确认，401 清理永远完不成。验收矩阵 #19 用「脏编辑页打开时 401」。

### 4.10 错误与边界矩阵

| 场景 | 期望行为 |
|---|---|
| 打开 SFTP 时某侧连接失败 | 标签照常创建并激活；该侧显示失败原因 + 重试；另一侧可正常用；pill = `degraded`/`closed` |
| 两侧远端，一侧断线 | 该侧面板失败可重试；pill = `degraded`；传输中任务失败可在队列重试 |
| 切到终端再切回 | 不重连、不重建；目录/滚动/选区/队列保留 |
| 关闭中间/左侧标签 | 其余标签 State identity 不变、连接不断（M0 回归） |
| 打开同端点对 | 聚焦已有标签，不新建连接；左右相反时提示 |
| 关闭有传输的标签 | 确认后取消队列 + 断开；`.eterm-part` 保留但需重新发起 |
| 关闭非活动标签 | 仅销毁该标签 State；不影响当前标签/连接 |
| 关最后一个标签 | 回 vault；Android FGS 停止 |
| Android 返回键（标签激活） | 回 vault，标签保活（不关闭） |
| 手机上滑关 App / iOS 挂起 | 传输可能失败；回前台探活/重连；失败任务在重绑 session 后可重试 |
| 桌面断网后恢复 | 操作失败触发一次 realpath 探活 → 标 failed；活跃 SFTP 标签窗口聚焦时节流探活；用户重试 |
| 同一主机被两侧选中 | **允许**：两侧是两个独立会话（sessionId 不同），可浏览/互传；若要禁止，入口页另加校验（本期不做） |
| 登录失效 / logout | 先清栈再进登录页；所有标签 State dispose → 会话全部断开（M4 修正） |
| 主题切换 | Shell 重建但 IndexedStack 子 State 保留（现有 `Theme.of(context)` 依赖）；SFTP 不受影响 |
| 隐藏标签后台刷新失败 | 不弹全局 SnackBar；该侧 phase/失败徽标更新，切回可见时再提示 |

---

## 5. 决策记录

> 编号仅本文范围；引用 iOS 方案的 D13 时会写明「iOS 方案 D13」。

| # | 决策点 | 建议方案 | 一句话理由 | 备选/不选 |
|---|---|---|---|---|
| D1 | 总体路线 | SFTP 升级为 Shell 工作区标签，与终端同列同 IndexedStack 保活 | 复用终端已验证的保活骨架，改动集中、风险可控 | 独立窗口/浮层：成本高、收益低（§3.3） |
| D2 | 标签模型 | 统一 `WorkTab`（sealed）+ 单一有序列表 + `activeTab`；终端行为不变 | 混排、统一渲染、统一关闭逻辑 | 两套标签列表：排序/激活/关闭会分裂 |
| D3 | 数据面归属 | 会话/队列继续归 `SftpWorkspace` State；标签只存 spec + 状态 notifier | 与终端同构；避免把 socket 生命周期散到 Shell | 把会话提升到 Shell/单例：大改且收益低 |
| D4 | 标签复用 | 同一**无序端点对**只留一个 SFTP 标签，再次打开聚焦已有（反向提示） | 防重复连接/资源膨胀；方向由拖拽源决定 | 允许同对多开：连接翻倍、易混淆（后续可放开） |
| D5 | 关闭语义 | 有非终态传输先确认；确认后取消队列、断开两侧；`.eterm-part` 保留但需重新发起 | 避免误关丢传输；又不做无主队列 | 静默取消：危险；关标签后继续传：需应用级队列 |
| D6 | 页面形态 | `SftpWorkspace` 嵌入模式无 Scaffold；路由模式由 workspace 自身渲染 Scaffold/AppBar；队列 UI 始终在 workspace 内 | 标签内不能有返回键/双标题；外层不需要访问 `_queue` | 外层包装持有 AppBar：拿不到队列，跨层耦合 |
| D7 | 状态模型 | `WorkTabStatus {phase, activeTransfers, failedTransfers}`；阶段含 `degraded` | 部分失败/失败传输需要可见信号，绿色假活会误导 | 只用三态：一侧失败无法准确表达 |
| D8 | 移动端恢复 | 回前台对「挂起时 live」侧做 6s 超时 realpath 探活；失败自动重连、重绑队列 session、保目录 | 与 iOS 方案 D13 同口径；iOS 无后台保活只能恢复 | 不探活：状态假活；自动重试传输：有覆盖风险 |
| D9 | 前台服务 | Android 有任意工作区标签即保活；通知文案泛化 | SFTP-only 场景也要防进程冻结 | 只认终端：仅 SFTP 时后台传输会被掐 |
| D10 | 持久化 | 标签仅会话内存在，不跨重启恢复 | 与终端一致；恢复需要序列化凭据/spec，安全面变大 | 重启恢复：一期不做 |
| D11 | 编辑页 | 保持 push 路由覆盖 Shell；session id 动态解析 | 编辑是全屏任务，返回即回标签；避免重连后保存必失败 | 编辑也做成标签：与文件面板状态耦合复杂 |
| D12 | 保活 Key | 标签内容使用 **GlobalKey**（或 keyed Stack），不用 UniqueKey | 实测 UniqueKey 跨 IndexedStack 位置移位会重建 State（§2.1.1） | UniqueKey：P0；keyed Stack：可行但改动更大 |
| D13 | 传输可见性 | 工作区内进度条 + pill 进行中/失败徽标；隐藏标签不抢视觉 | 后台传输可感知但不打扰当前工作 | 全局悬浮进度条：跨端布局复杂 |
| D14 | 数据面/协议 | Rust/中枢/协议零改动，复用现有 SFTP FFI 与 SSH keepalive | 现有能力已够；改造纯 UI 层 | 新增 `sftp_ping` 等接口：无必要 |
| D15 | 资源上限 | v1 不设硬上限，靠端点对去重；后续可加软上限 | 个人自托管场景标签量有限，先保体验 | 立即限制：无数据支撑 |
| D16 | 桌面状态刷新 | 活跃 SFTP 标签在窗口聚焦时做节流（≥30s）探活；操作失败也探活 | SFTP 无事件流，避免 pill 长期假绿 | 定时轮询：无谓 RTT/耗电 |
| D17 | 隐藏标签提示 | 隐藏时只更新状态与 pill 徽标，不弹全局 SnackBar | 不打断当前终端工作；失败仍有徽标可见 | 全部全局弹：会干扰其它标签 |
| D18 | 依赖方向 | `SftpSideSpec` 移到 `work_tabs.dart`（或 `sftp_spec.dart`），`sftp_page` 反向 import | 避免 work_tabs ↔ sftp_page 循环依赖 | 让 work_tabs import sftp_page：牵进 Flutter/FFI |

---

## 6. 实施计划

> 估算：约 **5–7 人日开发 + 2–3 人日四端回归**（含 P0 修复、竞态处理与手工矩阵；不含评审往返）。按里程碑逐步落地，每步可独立构建/回归。

### M0：标签容器保活修复（P0 前置，终端先行）

- `_TerminalTab` 的 key 改 `GlobalKey`（M0 时 `WorkTab` 尚未引入；M2 再把 `WorkTab.key` 定义为 GlobalKey）；
- 补 State identity 回归测试：3 个终端标签，关中间/左侧，断言其余 `TerminalTabView` State identity 不变、`activeTab` 语义不变；
- 更新 AGENTS.md：新增「IndexedStack 删元素位置移位会重建 State；标签内容必须 GlobalKey（或 keyed Stack）」陷阱；
- 验收：现有终端开关/切换/重连行为不回退；analyze/test/四端构建（本机三端，Windows 待 Windows 机）。

### M1：SFTP 拆壳（无行为变化）

- 提取 `SftpWorkspace`（State 不搬家），支持 `embedded:true/false`；路由模式由 workspace 自带 Scaffold/AppBar；
- 队列按钮/进度条归 workspace；嵌入模式加 SafeArea/状态栏图标色分支；
- `SftpDualPage` 退化为 5 行薄壳（`SftpWorkspace(embedded:false)`），现有 push 入口继续可用；
- 验证：现有 SFTP 功能、单测、三端构建全绿（route 模式与嵌入模式都做冒烟）。

### M2：统一标签模型 + SFTP 标签接入

- 新增 `work_tabs.dart`（`WorkTab`/`WorkTabStatus`/`sftpPairKey`/阶段聚合；`SftpSideSpec` 迁入）；
- Shell `tabs` 改 `List<WorkTab>`；IndexedStack 换 GlobalKey + TickerMode；桌面/手机 pill 泛化；
- `openSftp`（去重/聚焦/反向提示/FGS）+ 入口改造（Hosts 菜单、SFTP 入口页回调）；
- 关闭确认（有传输）+ async 索引安全；`openHostIds` 只筛终端；
- 验证：混合标签切换不断连；传输在终端前台继续；关闭中间标签不影响其余 State；同端点对聚焦。

### M3：生命周期恢复与连接健壮性

- SFTP 注册表 + `sftpTabsOnAppPaused/Resume`；Shell 生命周期入口接上；
- 探活 6s 超时 + 每侧并行 + `connectSeq`/mounted 守卫 + 孤儿连接回收；
- `_queue.rebindSession/failJobsForSession`；`_listOrThrow`；sessionId 清理；编辑页动态 session；
- 桌面活动标签聚焦探活（节流 30s）；操作失败探活标 failed；
- Android FGS 启动点 + Kotlin 文案泛化；
- 验证：Android/iOS 后台 30s+ 恢复；传输失败→重试成功；编辑页跨重连可保存。

### M4：测试、四端回归与文档

- 纯逻辑单测：`sftpPairKey`、`aggregateSftpPhase`（含 failed+connecting 优先级）、`WorkTabStatus` 相等、close 索引、队列 rebind；
- Widget 测试：State identity（M0）、pill 4 状态/徽标、混合标签关闭、隐藏标签 TickerMode；
- 四端构建：`flutter analyze` 0 error、`flutter test` 全绿、macOS/Android/iOS 本机构建、Windows 由 Windows 机构建；
- 手工矩阵（§7.2）+ 核验项（§7.3）；
- logout/401 清栈修正；AGENTS.md 与发布说明更新（SFTP 标签 + FGS 语义）。

### 改动文件清单（预估）

| 文件 | 改动 |
|---|---|
| `client/app/lib/ui/work_tabs.dart` | 新增：标签模型/状态/阶段聚合/去重键/`SftpSideSpec`（共享模型，不得 import sftp_page） |
| `client/app/lib/ui/shell.dart` | GlobalKey+TickerMode、混排 pill、IndexedStack 包装、openSftp、async close、生命周期、FGS、状态栏分支、openHostIds 过滤、logout 清栈 |
| `client/app/lib/ui/sftp_page.dart` | `SftpWorkspace`（嵌入/路由双模）、队列 UI 内嵌、SafeArea、状态发布、paused/resumed、探活/重连/队列重绑、动态 session、可见性抑制 SnackBar |
| `client/app/lib/ui/sftp_edit_page.dart` | session id 改为动态解析/失效提示 |
| `client/app/lib/services/sftp_transfer_queue.dart` | `sessionFrom/sessionTo` 可变 + `rebindSession/failJobsForSession` + `lastProgressAt`（防堵槽） |
| `client/app/lib/ui/sftp_entry_page.dart` | 「打开 SFTP」改为回调开标签 |
| `client/app/lib/ui/hosts_page.dart` | 无需改动（仍走 `onOpenSftp` 回调），语义变为开标签 |
| `client/app/lib/services/fg_service.dart` | 注释语义泛化（逻辑不变） |
| `client/app/android/app/src/main/kotlin/dev/eterm/eterm/TerminalForegroundService.kt` | 通知渠道/标题/正文「会话保持中」 |
| `client/app/test/*` | 新增 State identity/标签逻辑/阶段聚合/rebind 用例；回归既有用例 |
| `AGENTS.md` | 新增保活 Key 陷阱、SFTP 标签/FGS 语义 |
| `docs/plan/eterm-SFTP工作区标签技术方案.md` | 本文 |

> Rust（`client/app/rust/`）、服务端（`server/`）、wire 协议、发布脚本：**零改动**。

---

## 7. 测试与验收

### 7.1 自动化

| 层 | 用例 | 断言 |
|---|---|---|
| 单元 | `sftpPairKey(A,B) == sftpPairKey(B,A)`；local 归一 | 同对端点必去重 |
| 单元 | 阶段聚合：全 live / 一侧失败 / 全失败 / 失败+connecting / 单远端 | 优先级 `closed > degraded > live > connecting` 精确 |
| 单元 | `WorkTabStatus` 值相等（copyWith 后计数变化才 notify） | pill 不因无关字段重建 |
| 单元 | 混合标签关闭：关活动左侧/右侧/最后/非活动 | activeIndex 仍指向原会话；最后回 -1 |
| 单元 | `rebindSession`：running 标 failed、queued/failed 改绑、tar 不受影响 | 重试使用新 id |
| Widget | **State identity（P0）**：3 个终端标签关中间/左侧，其余 `TerminalTabView` State identical；混合 SFTP 同理 | 这是 M0/M2 的准入用例 |
| Widget | 混合标签条渲染（无 FFI 时连接失败也可挂载） | 标签数量/顺序/图标/状态/徽标；关闭回调 |
| Widget | 隐藏标签 `TickerMode(enabled:false)` | 动画不再推进 |
| 回归 | 现有 `code_review_bugs_test.dart` / `hosts_tab_sync_test.dart` / 主题路由测试 | 全绿 |

> 说明：`SftpWorkspace` 连接依赖 Rust FFI；真实挂载时 `_connect` 会 catch 成 failed，足以构造 State 做 identity 测试。无需新增 fake builder seam（评审建议采用方式）。

### 7.2 手工矩阵（四端）

| # | 场景 | macOS | Windows | Android | iOS |
|---|---|---|---|---|---|
| 1 | 终端 + SFTP + vault 三者来回切换 | ✓ | ✓ | ✓ | ✓ |
| 2 | 切换后 session id 不变、目录/选区/滚动保留 | ✓ | ✓ | ✓ | ✓ |
| 3 | 关闭中间/左侧标签后，其余标签 session id 不变（终端与 SFTP） | ✓ | ✓ | ✓ | ✓ |
| 4 | 终端标签前台时 SFTP 传输完成 + 目标刷新 | ✓ | ✓ | ✓ | ✓ |
| 5 | 同端点对再次打开 → 聚焦已有；反向时提示 | ✓ | ✓ | ✓ | ✓ |
| 6 | 不同端点对多开 SFTP | ✓ | ✓ | ✓ | ✓ |
| 7 | 关闭活动/非活动/最后一个标签；activeIndex 正确 | ✓ | ✓ | ✓ | ✓ |
| 8 | 有传输时关闭确认；取消/确认两条路径 | ✓ | ✓ | ✓ | ✓ |
| 9 | 浅色主题 SFTP 标签状态栏图标可见（SafeArea） | — | — | ✓ | ✓ |
| 10 | Android 返回键：回 vault 不关标签 | — | — | ✓ | — |
| 11 | 仅 SFTP 标签时 Android FGS 启动/停止、通知文案 | — | — | ✓ | — |
| 12 | 退后台 >30s 回前台：终端重连 + SFTP 探活/重连/目录保留；重连失败仍显示重试 | — | — | ✓ | ✓ |
| 13 | 挂起时传输 running：恢复后仅在重连/探活失败时标 failed 并重绑，点重试成功续传；不按暂停时长误杀 | — | — | ✓ | ✓ |
| 14 | 恢复时编辑页打开：保存使用新 session 或明确提示 | ✓ | ✓ | ✓ | ✓ |
| 15 | 隐藏标签目录刷新失败：不弹全局 SnackBar，pill 状态更新 | ✓ | ✓ | ✓ | ✓ |
| 16 | 同主机两侧选中：允许多会话互传（或入口提示） | ✓ | ✓ | ✓ | ✓ |
| 17 | 主题切换、窗口最大化/还原 | ✓ | ✓ | — | — |
| 18 | 手机旋转（Android）/ iOS 锁竖屏 | — | — | ✓ | ✓ |
| 19 | logout/401：所有标签连接释放（含脏编辑页/弹层打开时，pushAndRemoveUntil 不被 PopScope 卡住） | ✓ | ✓ | ✓ | ✓ |
| 20 | 桌面断网 → 聚焦活跃 SFTP 标签 → pill 转 failed（D16 节流探活）；操作失败也能转 failed | ✓ | ✓ | — | — |

### 7.3 核验项（实施后逐项打勾）

1. `flutter analyze` 0 error；`flutter test` 全绿；`cargo test --lib` 不变（Rust 未改）。
2. macOS debug / Android debug（`JAVA_HOME` 钉 JDK17）/ iOS 模拟器构建通过；Windows 在 Windows 机通过。
3. **关中间/左侧标签**：右侧标签 State identity 不变（自动化用例），切换标签时 `sftp_connect`/`ssh_connect` 零新增。
4. 跨 720 断点（如可达）或手机旋转：终端与 SFTP 的 State 均不重建。
5. 隐藏标签的队列仍执行；pill 进行中/失败徽标正确增减。
6. 关闭确认只在有非终态任务时出现；确认后 Rust 取消生效。
7. Android FGS：仅 SFTP 标签也启动；关最后标签停止；通知文案无「终端」误导。
8. iOS 回前台重连后原目录保留；目录被删回 home 且有提示；探活超时不会卡死后续恢复；**重连失败显示 failed + 原因 + 重试按钮（不能停在 connecting spinner）**。
9. 重连后队列 failed 任务点重试成功（session 已重绑），不出现「会话不存在」；失败释放的并发槽能继续启动 queued 任务。
10. 探活/重连不打断其它标签操作；`connectSeq` 防重入/孤儿连接生效。
11. 现有终端 iOS 方案 D13 行为（paused 登记、resumed 重连、60s 窗口）零回归。
12. 浅色主题 SFTP 标签状态栏图标可见且内容不被刘海/状态栏遮挡。
13. 桌面断网后聚焦活跃 SFTP 标签，D16 探活把 pill 从绿转 failed；恢复网络后操作/再次探活可回绿。

---

## 8. 风险与回滚

| 风险 | 概率/影响 | 缓解 |
|---|---|---|
| **IndexedStack 位置移位重建 State（P0）** | 高 / 高 | M0 改 GlobalKey + State identity 回归测试；AGENTS.md 记录；SFTP 接入前先验收 |
| GlobalKey 重复使用导致 duplicate key 崩溃 | 低 / 高 | 一个标签一个 key，由标签生命周期创建/销毁；不允许复制标签复用同一 key |
| Shell 标签重构破坏终端开关/关闭索引（BUG-D2 类） | 中 / 高 | 保留现有测试钩子；纯逻辑单测；混合标签回归；M2 独立验收 |
| 探活超时/重连竞态导致双连接或孤儿连接 | 中 / 高 | 每侧 `connectSeq` + mounted 校验；被取代连接立即 disconnect；手动重试在 connecting 期间禁用 |
| 重连后队列 session 失效 | 中 / 高 | `rebindSession/failJobsForSession`；手工矩阵 #13 |
| 隐藏 SFTP 标签耗电 | 低 / 中 | TickerMode 停动画；状态只在计数变化时 notify；不周期轮询（仅聚焦/恢复探活） |
| 隐藏标签 SnackBar 干扰当前操作 | 中 / 低 | `visible` 抑制 + pill 失败徽标 |
| 多标签连接/句柄膨胀 | 低 / 中 | 端点对去重；文档提示；后续可加软上限 |
| 后台传输被系统掐断 → 用户以为丢数据 | 中 / 中 | 队列 failed 可见可重试；`.eterm-part` 保留；文案如实说明“需重新发起” |
| 关闭标签与异步 connect/transfer 回调竞态 | 低 / 中 | 现有 `mounted`/`_disposed` 防御 + `connectSeq`/close 防抖；dispose 顺序：先取消订阅/队列，再断会话 |
| 桌面状态点假绿 | 中 / 低 | 操作失败探活 + 活跃标签聚焦探活（节流）；文档说明非实时 |
| Android FGS 文案/权限回归 | 低 / 低 | 只改字符串；`fg_service` 逻辑不变；权限拒绝路径保持静默 |

**回滚**：纯 Dart UI 改动，无数据迁移/协议变更。回滚 = 还原对应提交；已打开的标签随进程退出消失。M0（GlobalKey 修复）可独立保留（它修复的是既有终端缺陷）；回滚 M1+ 不影响现有 SFTP 入口。

---

## 9. 待评审确认点

以下为本方案已给建议、但建议评审时明确拍板的点（默认按建议执行）：

1. **D12 保活 Key**：接受 `GlobalKey`（最小改动）还是换成 `Stack + KeyedSubtree`（更彻底但需自补焦点/语义/Ticker）？
2. **D5 关闭即取消传输**：是否接受？（替代方案是把队列提升为应用级服务，工作量显著增加）
3. **D4 去重方向**：A⇄B 与 B⇄A 视为同一标签并提示反向拖拽，是否接受？还是只对同序去重？
4. **D6 路由包装**：M1 保留 5 行 `SftpDualPage` 薄壳（workspace 自带 Scaffold），还是 M2 直接删除？
5. **D16 桌面探活**：接受「仅活跃 SFTP 标签 + 窗口聚焦节流探活」，还是只做操作失败探活并明确状态点非实时？
6. **D17 隐藏标签提示**：接受「隐藏时不弹全局 SnackBar，仅 pill 徽标」，还是所有后台失败都全局提示？

---

## 10. 首轮评审记录与处置

> 评审方式：子代理只读评审（对照代码），并在仓库外 `/tmp` 用 Flutter 3.50.0 做了 IndexedStack Key 对照实验；方案复核时另在仓库内用临时 widget 测试复验（测试文件已删除，仓库无残留）。评审结论：**有阻塞问题**。

| 编号 | 评审发现 | 处置 |
|---|---|---|
| **P0-1** | IndexedStack 内层 `UniqueKey` 不能跨位置保 State；关中间/左侧标签会重建右侧所有标签；现有终端标签同样中招；方案原「UniqueKey 防错配」不成立 | **已复验**（UniqueKey 丢 / GlobalKey 保），v1.1 改 `GlobalKey`；新增 M0 前置修复 + State identity 回归测试；§2.1.1/§4.2.3/D12/§7.1 全量修订 |
| P1-1 | 去掉 AppBar 后移动端 SFTP 无状态栏避让/图标色 | 新增 §4.3.3：SafeArea + Shell 按标签类型分支状态栏样式；矩阵 #9 |
| P1-2 | 回前台 `sftpRealpath` 无超时，`_resuming` 会挡后续恢复 | 探活 6s 超时、每侧并行、每侧 `connectSeq` 而非全局 `_resuming`；§4.6.3 |
| P1-3 | 重连后队列任务 `sessionFrom/sessionTo` 是 final 旧值，重试必失败 | 新增 `rebindSession/failJobsForSession`；字段可变；§4.6.3/§6 文件清单/矩阵 #13 |
| P1-4 | resume 与手动重试/关标签无互斥，可能双连接/泄漏/写已 dispose State | 每侧 `connectSeq` + 所有 await 后 `mounted/seq` 校验 + 被取代连接回收；§4.6.3 |
| P1-5 | 测试未覆盖「State 不重建」核心承诺，且无注入 seam | 改为真实挂载 + `tester.state` identity 断言；§7.1 |
| P2-1 | `SftpDualPage` 薄包装与「workspace 无 Scaffold」矛盾，包装拿不到 queue | 改为 workspace 双模（路由模式自带 Scaffold），队列 UI 始终在 workspace 内；§4.3/D6 |
| P2-2 | `work_tabs.dart` 引 `SftpSideSpec` 会循环依赖 | `SftpSideSpec` 迁入 `work_tabs.dart`（或 `sftp_spec.dart`）；§4.1/D18 |
| P2-3 | async close 按 index 不安全 | 按标签身份重新定位 + mounted + `_closing` 防抖；§4.5.3 |
| P2-4 | 状态徽标放在 `_onQueueChanged` 会被 `_autoRefresh` 早退漏计 | 独立监听或在早退前发布；§4.4 |
| P2-5 | 失败传输在隐藏标签无可见信号 | 状态增加 failedTransfers + pill 红徽标；§4.4/§4.8 |
| P2-6 | `_list` catch 不返回失败，无法实现“保目录/回 home” | 拆 `_listOrThrow`/返回 bool；§4.6.3 |
| P2-7 | 重连失败后 `sessionId` 仍旧值，UI 显示可传但必失败 | 重连开始/失败置空；§4.6.3 |
| P2-8 | 编辑页固定 sessionId，重连后保存失败 | 编辑页改动态 session provider + 失效提示；§4.9 |
| P2-9 | 隐藏标签后台刷新失败会全局 SnackBar | `visible` 抑制 + pill 状态；§4.8/D17 |
| P2-10 | 4.6.3 说并行，A.2 是顺序 for-await | A.2 改为每侧独立 Future + catch；附录 A.2 |
| P2-11 | 阶段聚合文字与伪代码不一致 | 统一优先级 `closed > degraded > live > connecting`；§4.1/A.1 |
| P2-12 | WorkTab 伪代码字段未初始化/不可编译 | v1.1 补 final/初值/GlobalKey；§4.1 |
| P2-13 | `openSftp` 未启动 FGS；Kotlin 渠道/文案仍终端专用 | openSftp/closeTab 统一调用；Kotlin 文案泛化；§4.5/§4.7 |
| P2-14 | 桌面无事件流，pill 长期假绿 | 操作失败探活 + 活跃标签聚焦节流探活；§4.6.4/D16 |
| P2-15 | 隐藏 child 无 TickerMode，spinner 持续动画 | 标签 child 外层 TickerMode(enabled: 可见)；§4.2.3/§4.8 |
| P2-16 | logout/401 在弹层/编辑页打开时可能只替换栈顶 | M4 先清栈再进登录页；§4.9/矩阵 #19 |
| P2-17 | 同主机两侧“同会话”判断不成立（实际两条连接） | 明确允许两个独立会话；矩阵 #16 |
| P2-18 | `openHostIds`/`openTerminal` 在 List<WorkTab> 下适配漏写 | M2 显式只筛 TerminalWorkTab；§4.5.1 |
| P2-19 | 反向端点对聚焦与用户选择方向不一致 | 聚焦时提示可反向拖拽；§4.5.1/D4 |
| P2-20 | 工期/风险表低估 | 估算上调 5–7 + 2–3；风险表增加 P0/竞态项；§6/§8 |
| 可简化 | 删包装/keyed Stack/真实挂载测试/合并 notifier | 采纳：workspace 双模、真实挂载测试、单一 `WorkTabStatus`；包装保留为 5 行薄壳以便 M1 独立验收 |

### 10.1 二次复审（P0 复核 + 收口）

> 二次复审结论：**P0 已闭合，无新增 P0；需修订（2 个 P1 + 若干 P2）。架构可进入实现，M0/M1 可先行。**

| 编号 | 复审发现 | v1.2 处置 |
|---|---|---|
| P1-1 | A.2 `_reconnect` 的 `sftpConnect` 外无 try/catch：失败会停在 connecting spinner，无重试按钮 | A.2 补 catch → `phase=failed + reason + _publishStatus()`；矩阵 #12/#13、核验 #8 覆盖 |
| P1-2 | logout 用 `popUntil(isFirst)` 会被脏编辑页 `PopScope` 卡死（pop 不移除路由 → 死循环/重复弹窗） | §4.9/M4/matrix #19 改为 root navigator `pushAndRemoveUntil(LoginPage, (r) => false)`，不用 popUntil |
| P2-1 | `_list/_lsLocal` catch 直接 `ScaffoldMessenger.showSnackBar`，隐藏标签仍全局弹 | §4.8 统一收口到 `_snack`（带 `visible` 判断） |
| P2-2 | rebind 在 `_listOrThrow` 之后；`failJobsForSession` 后无 `_pump`，queued 停住 | A.2 改为连上即 rebind、再列目录；A.4 的 `rebindSession` 内 `_pump()`；回 home 同步 `s.rpath` |
| P2-3 | `_markDegraded` 未定义、`_SidePhase` 无 degraded，session 归属不清 | 改用 workspace 临时 `_probeSuspect`：不改 `_SidePhase`、不新建连接、保留旧 sessionId；聚合时显示 degraded |
| P2-4 | “30s 无进度”会误杀 iOS 恢复后仍活着的传输 | 取消按暂停时长判死；仅在所属侧已重连/探活失败时 fail；探活成功但长期无进度再二次探活失败才 fail |
| P2-5 | D16 桌面聚焦探活缺矩阵/核验项 | 新增矩阵 #20、核验 #13 |
| P2-6 | `_reconnect` 阶段未发状态，pill 重连期间仍绿 | A.2 在 connecting/failed/live 三处均 `_publishStatus()` |
| P3 | M0 文案含尚未引入的 `WorkTab`；`work_tabs.dart` 称“纯 Dart”不准确；`_resuming` 命名残留；resume 注释易误解 | 已分别改为“M0 只改 `_TerminalTab`”、“不 import sftp_page”、统一 `connectSeq`、明确 `resume` 由 `retry()` 置 true |

---

## 附录 A：关键伪代码

### A.1 阶段聚合（优先级：closed > degraded > live > connecting）

```dart
/// 只统计远端侧（本机侧不参与）；total 为远端侧数量（1 或 2）。
WorkTabPhase aggregateSftpPhase({
  required int total,
  required int live,
  required int failed,
}) {
  if (total <= 0) return WorkTabPhase.live;      // 双本机不会出现（入口拦截）
  if (failed == total) return WorkTabPhase.closed;
  if (failed > 0) return WorkTabPhase.degraded;   // 失败+connecting 也算 degraded
  if (live == total) return WorkTabPhase.live;
  return WorkTabPhase.connecting;
}
```

### A.2 移动端恢复（每侧独立、超时、seq 守卫）

```dart
void _onAppResume() {
  if (!mounted) return;
  for (final s in _sides.where((s) => !s.isLocal)) {
    if (!s.liveAtPause || s.phase != _SidePhase.live) continue;
    unawaited(_probeOrReconnect(s));
  }
}

Future<void> _probeOrReconnect(_Side s) async {
  final oldId = s.sessionId;
  if (oldId == null) return;
  final seq = ++s.connectSeq;
  try {
    await sftp.sftpRealpath(id: oldId, path: '.').timeout(_probeTimeout);
    _setProbeSuspect(s, false);
    return; // 会话仍活
  } catch (_) {
    if (!mounted || seq != s.connectSeq) return;
    if (_queue.hasRunningForSession(oldId)) {
      // 通道忙/大传输：不改 phase、不新建连接，只让 pill 显示降级；
      // 等流报错，或用户先取消任务再手动重试
      _setProbeSuspect(s, true);
      return;
    }
    await _reconnect(s, seq);
  }
}

Future<void> _reconnect(_Side s, int seq) async {
  final oldId = s.sessionId;
  final rpath = s.rpath;
  setState(() {
    s.phase = _SidePhase.connecting;
    s.sessionId = null; // 防 UI 依据旧 id 发操作
  });
  _publishStatus();
  if (oldId != null) sftp.sftpDisconnect(id: oldId);

  BigInt? newId;
  try {
    newId = await sftp.sftpConnect(...);
    await sftp.sftpRealpath(id: newId, path: '.');
  } catch (e) {
    if (newId != null) sftp.sftpDisconnect(id: newId); // 避免半开连接泄漏
    if (!mounted || seq != s.connectSeq) return;
    setState(() {
      s.phase = _SidePhase.failed;
      s.reason = '$e';
      s.rentries = []; // 与现有连接失败 UI/重试按钮同源
    });
    _publishStatus();
    return;
  }
  if (!mounted || seq != s.connectSeq) {
    sftp.sftpDisconnect(id: newId); // 被取代：回收孤儿连接
    return;
  }
  final liveId = newId!;
  setState(() {
    s.sessionId = liveId;
    s.phase = _SidePhase.live;
    s.reason = null;
  });
  // 先重绑再列目录：用户重试不会拿到旧 id；rebindSession 内部 _pump 释放并发槽
  _queue.failJobsForSession(oldId, '连接已重连，请重试');
  _queue.rebindSession(oldId, liveId);
  _publishStatus();

  final ok = await _listOrThrow(s, rpath);
  if (!mounted || seq != s.connectSeq) return;
  if (!ok) {
    final home = await sftp.sftpRealpath(id: liveId, path: '.');
    if (!mounted || seq != s.connectSeq) return;
    s.rpath = home.isEmpty ? '/' : home; // 回 home 必须同步路径
    await _listOrThrow(s, s.rpath);
    _snack('原目录不可达，已回到 home'); // _snack 内部按 visible 决定是否弹
  }
}
```

### A.3 标签子结构（GlobalKey + 稳定结构 + TickerMode）

```dart
for (final (i, t) in tabs.indexed)
  TickerMode(
    enabled: activeTab == i,
    child: Column( // 类型恒定
      children: [
        Expanded(
          child: switch (t) {
            TerminalWorkTab() => TerminalTabView(key: t.key, ...),
            SftpWorkTab() => SftpWorkspace(key: t.key, ...),
          },
        ),
        if (compact) _MobileTabBar(...), // 仅数量变化，不换首 child 类型
      ],
    ),
  )
```

### A.4 队列 session 重绑

```dart
// SftpTransferQueue
void failJobsForSession(BigInt? oldId, String reason) {
  for (final j in jobs) {
    if (j.state != SftpJobState.running) continue;   // queued 由 rebind 处理
    if (j.sessionFrom == oldId || j.sessionTo == oldId) {
      j.state = SftpJobState.failed;
      j.error = reason;
      // 这里不置 resume：job.resume 在 retry() 时才刷成 true（续传语义不变）
    }
  }
  _notify();
}

void rebindSession(BigInt? oldId, BigInt newId) {
  if (oldId == null) return;
  for (final j in jobs) {
    if (j.sessionFrom == oldId) j.sessionFrom = newId;
    if (j.sessionTo == oldId) j.sessionTo = newId;
  }
  _notify();
  _pump(); // fail 释放的并发槽必须补位，否则 queued 永远不启动
}
```

> **v1.3 实现补丁（代码评审 P0/P1 收口）**：
> - 新增 `beginRebind(oldId)` / `endRebind(oldId)` 重绑窗口：`sftpDisconnect(oldId)` 之前挂起，`_pump` 跳过挂在 held 会话上的 queued；否则旧流 `onError` 触发的 `_pump` 会把排队任务启动在死会话上（P0-1）。
> - `failJobsForSession` 对 running 任务真正 `_transport.cancel` + 取消订阅（避免重试后旧 writer 并发写同一 `.eterm-part`）；调用方在判死时先 `sftpDisconnect`，dispose 同时清理 `staleSessionId`（P0-2）。
> - tarDownload 按 `kind` 排除，**不能**用 `specFrom != null` 判断：download/copy/copyDir 入队时同样带 `specFrom`（transport 只在 tar 分支使用它）。
> - 探活超时且该会话有 running 传输时只置 `probeSuspect=degraded`，不重连/不杀任务；桌面聚焦路径只判死标 failed，不自动重连（P1-2/P1-3）。
> - `_list` 被更新列举取代时返回 true，不触发“回 home”误覆盖用户导航（P1-4）。

---

## 附录 B：术语

| 术语 | 含义 |
|---|---|
| 工作区标签（WorkTab） | Shell 内与终端并列的常驻标签，本方案新增 SFTP 类型 |
| IndexedStack 保活 | 所有标签 child 同时挂载，仅切换显示下标；切换不触发 dispose。**注意：删元素位置移位会重建 State，必须 GlobalKey（§2.1.1）** |
| 端点对（pair） | SFTP 两侧 `(left, right)`；`local` 表示本机；去重按无序对 |
| 降级（degraded） | 多远端侧中部分失败、仍有可用侧 |
| 探活（probe） | 对已有会话发一次轻量请求（`sftp_realpath(".")`，带超时）判断连接是否仍活 |
| 队列重绑 | 重连拿到新 session id 后，把队列任务的旧 id 改为新 id，使重试可用 |
| P0（本项目） | 本轮评审发现：IndexedStack 内层 UniqueKey 跨位置丢 State（§2.1.1），非安全等级 P0 |

---

## 11. 实施记录（v1.3）

### 11.1 里程碑

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M0 | `_TerminalTab.key` → `GlobalKey`；新增 `shell_tab_state_test.dart` 锁住「关中间/左侧标签不重建右侧 State」 | ✅ |
| M1 | `SftpDualPage` 拆出 `SftpWorkspace`（embedded/route 双模）；队列入口/进度条内嵌；SafeArea/隐藏标签 SnackBar 门控 | ✅ |
| M2 | `work_tabs.dart`（WorkTab/TerminalWorkTab/SftpWorkTab/WorkTabStatus/聚合/去重键）；Shell 混排 + TickerMode + 单向去重 + 反向提示 + 关闭确认 + 双徽标 + FGS + 入口回回调 | ✅ |
| M3 | 回前台/桌面聚焦探活（6s 超时、connectSeq、probing 去重）；队列 held/rebind/cancel；`_list` 三态语义；编辑页动态 session；Android 通知文案 | ✅ |
| M4 | 单测/Widget 测试（WorkTab、混排标签、队列重绑窗口、编辑页首次加载、手机布局）；logout/401 `pushAndRemoveUntil`；四端构建自测 | ✅ |

### 11.2 验证结果（2026-11-25）

- `flutter analyze`：0 error / 0 warning（21 条既有 info：deprecated `window_manager` legacy / `flutter/material.dart` 测试导入等）。
- `flutter test`：**98 绿**（含新增 WorkTab 3、混排 2、State identity 1、队列重绑 5、编辑页 1）。
- `cd rust && cargo test --lib`：22 绿（Rust 未改）。
- `flutter build macos --debug`、`JAVA_HOME=<JDK17> flutter build apk --debug`、`flutter build ios --simulator --debug`：全部通过。
- Windows：按规范须 Windows 机构建，本机未跑；Dart/Rust 未用平台专属 API（`window_manager` 分支沿用既有 macOS/Windows 同源代码）。
- server：`npm run typecheck` 通过；`npm test` 无 `ETERM_TEST_DSN` 时按 helpers 约定跳过集成用例（9 单测绿），本机 MySQL 下 27 绿。

### 11.3 代码评审（实现轮）与处置

| 编号 | 发现 | 处置 |
|---|---|---|
| P0-1 | 重连窗口内旧流 `onError` 触发 `_pump`，把 queued 启动在已断开旧会话 | 新增 `beginRebind/endRebind` held 窗口；`_pump` 跳过 held；失败路径 `failJobsForSession(includeQueued)` + `endRebind`；新增回归测试 |
| P0-2 | `failJobsForSession` 只改状态：旧 writer 未取消、旧会话未断开，重试有双写暂存风险 + 会话泄漏 | running 任务 `_transport.cancel` + 取消订阅；判死路径先 `sftpDisconnect`；dispose 清理 `staleSessionId`；测试断言 cancel |
| P1-1 | tarDownload 被误判/重绑（实现初版用 `specFrom != null` 识别，实际所有远端源任务都带 specFrom） | 改按 `kind == tarDownload` 排除；测试断言 tar 保持 running 且不重绑 |
| P1-2 | 有 running 传输时探活超时直接拔会话 | 有 running 只置 degraded；桌面聚焦只标 failed 不自动重连；移动端恢复才自动重连 |
| P1-3 | 目录列举失败 + 3s 探活超时即清 session/fail 全部任务 | 超时提到 6s；有 running 传输时只降级；确认死亡才断连/清 session/fail |
| P1-4 | `_list` 被取代时 catch 返回 false，重连回 home 会覆盖用户刚导航的目录 | superseded 返回 true，只有当前列举失败才算失败 |
| P1-5 | 缺重连窗口/取消/编辑页首次加载/SFTP State identity 回归 | 已补 4 类测试 |
| P1-A（复核新增） | `rebindSession` 跳过 canceled，导致已取消任务重连后重试仍用死会话 | 只跳过 done；canceled 与 failed 一样重绑；补测试 |
| P1-B（复核新增） | 探活超时有 running 时只置 degraded：未 hold queued，running 报错后 `_pump` 仍会拿死会话启动；且无后续探活 | degraded 分支 `beginRebind` + 记录 reconnect 模式；`_onQueueChanged` 在 running settle 后自动再探：成功 `endRebind` 放行，失败重连/判死 |
| P1-C（复核） | `_probeAfterListError` 的 running 分支同样需 hold + 后续再探 | 同 P1-B 处理 |
| P1-D（复核新增） | `_list` 成功清 `probeSuspect` 但未释放 hold，该侧 queued 永久卡住 | 列表成功若此前 suspect：`probeAutoReconnect=false` + `endRebind(id)`；补 endRebind 放行测试 |
| P2-1…P2-15 | closing try/finally、双徽标并存、隐藏提示切回补发、手机工具栏合并、入口双本机拦截、注释章节号、AGENTS/`fg_service` 文案、server 测试拆分提交 | 已逐项处理（P2-11 `?bar` lint 与 P2-12 测试异常吞掉保留现状：前者纯 lint，后者为既有 Ahem 字体溢出噪声） |

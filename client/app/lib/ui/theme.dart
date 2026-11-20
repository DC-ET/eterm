// eterm 设计令牌与主题（沉稳墨蓝设计语言）：
// - AppPalette：浅/深两套不可变令牌（配色统一、克制：墨色骨架 + 深青强调 + 黄铜点缀）
// - Et：全局静态令牌访问（调用点写法不变），由 ThemeController 在浅/深间切换
// - 主题模式（浅色/深色/跟随系统）经 Rust kv 持久化；Material 主题同源生成

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:eterm/src/rust/api/local.dart' as local;
import 'package:xterm/xterm.dart';

/// 外观模式（设置页可选；kv 持久化键 ui.theme_mode）。
enum AppThemeMode { light, dark, system }

/// 一套完整的界面令牌（不可变；浅色/深色各一个 const 实例）。
class AppPalette {
  const AppPalette({
    required this.titleBar,
    required this.titleBarText,
    required this.titleBarPill,
    required this.titleBarTabActive,
    required this.contentBg,
    required this.sidebarBg,
    required this.sidebarSelected,
    required this.card,
    required this.cardBorder,
    required this.cardRadius,
    required this.tileGroup,
    required this.tileHost,
    required this.textPrimary,
    required this.textSecondary,
    required this.primaryBtn,
    required this.primaryBtnText,
    required this.accent,
    required this.danger,
    required this.surfaceMuted,
    required this.disabledBtn,
    required this.mBg,
    required this.mSelected,
    required this.mFab,
    required this.mFabIcon,
    required this.brightness,
    required this.terminal,
  });

  // 桌面标题栏（墨色，深浅模式各自加深）
  final Color titleBar;
  final Color titleBarText;
  final Color titleBarPill;
  final Color titleBarTabActive;

  // 内容区 / 侧栏
  final Color contentBg;
  final Color sidebarBg;
  final Color sidebarSelected;

  // 卡片
  final Color card;
  final Color cardBorder;
  final double cardRadius;

  // 图标瓦片（克制双色：石板蓝=分组，深青=主机）
  final Color tileGroup;
  final Color tileHost;

  // 文本
  final Color textPrimary;
  final Color textSecondary;

  // 主按钮（墨色实心）/ 强调（深青）/ 危险
  final Color primaryBtn;
  final Color primaryBtnText;
  final Color accent;
  final Color danger;

  // 弱表面（分段控件底/徽标底/kv 行底）与禁用按钮底（深浅各自成套，禁硬编码）
  final Color surfaceMuted;
  final Color disabledBtn;

  // 移动端
  final Color mBg;
  final Color mSelected;
  final Color mFab;
  final Color mFabIcon;

  /// 内容表面亮度（状态栏图标方向等用）。
  final Brightness brightness;

  /// 终端配色（随主题走：深色界面配深色终端）。
  final TerminalTheme terminal;
}

/// 浅色（默认）：冷调纸面 + 墨色骨架 + 深青强调。
const kLightPalette = AppPalette(
  titleBar: Color(0xFF1F2530),
  titleBarText: Color(0xFFE9EBF0),
  titleBarPill: Color(0xFF2D3543),
  titleBarTabActive: Color(0xFF374050),
  contentBg: Color(0xFFF2F3F6),
  sidebarBg: Color(0xFFF9FAFB),
  sidebarSelected: Color(0xFFE9EBEF),
  card: Color(0xFFFFFFFF),
  cardBorder: Color(0xFFE5E7EC),
  cardRadius: 14.0,
  tileGroup: Color(0xFF46618C),
  tileHost: Color(0xFF2F6D5C),
  textPrimary: Color(0xFF1C222E),
  textSecondary: Color(0xFF78808F),
  primaryBtn: Color(0xFF232A36),
  primaryBtnText: Color(0xFFFFFFFF),
  accent: Color(0xFF2F6D5C),
  danger: Color(0xFFC73E33),
  surfaceMuted: Color(0xFFF1F2F5),
  disabledBtn: Color(0xFFC9CBD3),
  mBg: Color(0xFFF2F3F6),
  mSelected: Color(0xFFD8E1DE),
  mFab: Color(0xFF232A36),
  mFabIcon: Color(0xFFFFFFFF),
  brightness: Brightness.light,
  terminal: termLightTheme,
);

/// 深色：墨夜骨架 + 提亮深青强调（主按钮/瓦片同色相微提亮，调用点零分支）。
const kDarkPalette = AppPalette(
  titleBar: Color(0xFF12161D),
  titleBarText: Color(0xFFD9DDE5),
  titleBarPill: Color(0xFF20262F),
  titleBarTabActive: Color(0xFF2A323E),
  contentBg: Color(0xFF15181E),
  sidebarBg: Color(0xFF191D24),
  sidebarSelected: Color(0xFF242A34),
  card: Color(0xFF1E222B),
  cardBorder: Color(0xFF2A313C),
  cardRadius: 14.0,
  tileGroup: Color(0xFF5574AB),
  tileHost: Color(0xFF38796A),
  textPrimary: Color(0xFFE3E6EC),
  textSecondary: Color(0xFF8A92A1),
  primaryBtn: Color(0xFF2C3440),
  primaryBtnText: Color(0xFFF2F3F6),
  accent: Color(0xFF3F8B78),
  danger: Color(0xFFD45A4E),
  surfaceMuted: Color(0xFF262D38),
  disabledBtn: Color(0xFF39414E),
  mBg: Color(0xFF15181E),
  mSelected: Color(0xFF28323A),
  mFab: Color(0xFFE3E6EC),
  mFabIcon: Color(0xFF161A21),
  brightness: Brightness.dark,
  terminal: termDarkTheme,
);

/// 全局令牌访问：调用点保持 `Et.xxx` 写法不变，值由 ThemeController 切换。
abstract final class Et {
  static AppPalette palette = kLightPalette;

  static Color get titleBar => palette.titleBar;
  static Color get titleBarText => palette.titleBarText;
  static Color get titleBarPill => palette.titleBarPill;
  static Color get titleBarTabActive => palette.titleBarTabActive;
  static Color get contentBg => palette.contentBg;
  static Color get sidebarBg => palette.sidebarBg;
  static Color get sidebarSelected => palette.sidebarSelected;
  static Color get card => palette.card;
  static Color get cardBorder => palette.cardBorder;
  static double get cardRadius => palette.cardRadius;
  static Color get tileGroup => palette.tileGroup;
  static Color get tileHost => palette.tileHost;
  static Color get textPrimary => palette.textPrimary;
  static Color get textSecondary => palette.textSecondary;
  static Color get primaryBtn => palette.primaryBtn;
  static Color get primaryBtnText => palette.primaryBtnText;
  static Color get accent => palette.accent;
  static Color get danger => palette.danger;
  static Color get surfaceMuted => palette.surfaceMuted;
  static Color get disabledBtn => palette.disabledBtn;
  static Color get mBg => palette.mBg;
  static Color get mSelected => palette.mSelected;
  static Color get mFab => palette.mFab;
  static Color get mFabIcon => palette.mFabIcon;
  static Brightness get brightness => palette.brightness;
  static TerminalTheme get termTheme => palette.terminal;

  /// 无边框输入装饰：外层容器已画圆角边框（搜索框等）时使用。
  /// ⚠️ 只写 `border: InputBorder.none` 不够——`InputDecoration.applyDefaults`
  /// 会用 `inputDecorationTheme` 的 enabledBorder/focusedBorder 补位，
  /// TextField 会在容器里再画一层内框（框中框，已踩坑）。各状态边框必须全部显式置 none。
  static const borderlessField = InputDecoration(
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    disabledBorder: InputBorder.none,
    errorBorder: InputBorder.none,
    focusedErrorBorder: InputBorder.none,
  );
}

/// 浅色终端配色（ANSI 全套，纸面终端）。
const termLightTheme = TerminalTheme(
  cursor: Color(0xFF1F2328),
  selection: Color(0xFFADD6FF),
  foreground: Color(0xFF1F2328),
  background: Color(0xFFFFFFFF),
  black: Color(0xFF1F2328),
  white: Color(0xFFD0D4DA),
  red: Color(0xFFC73E33),
  green: Color(0xFF1A7F37),
  yellow: Color(0xFF9A6700),
  blue: Color(0xFF0969DA),
  magenta: Color(0xFF8250DF),
  cyan: Color(0xFF1B7C83),
  brightBlack: Color(0xFF6E7781),
  brightRed: Color(0xFFE5534B),
  brightGreen: Color(0xFF2DA44E),
  brightYellow: Color(0xFFBF8700),
  brightBlue: Color(0xFF4093E8),
  brightMagenta: Color(0xFFA475F9),
  brightCyan: Color(0xFF3192AA),
  brightWhite: Color(0xFFF6F8FA),
  searchHitBackground: Color(0xFFFFEA8A),
  searchHitBackgroundCurrent: Color(0xFFFFC53D),
  searchHitForeground: Color(0xFF1F2328),
);

/// 深色终端配色（墨夜终端，One Dark 气质）。
const termDarkTheme = TerminalTheme(
  cursor: Color(0xFFD5DAE3),
  selection: Color(0xFF33455C),
  foreground: Color(0xFFD5DAE3),
  background: Color(0xFF12151B),
  black: Color(0xFF12151B),
  white: Color(0xFFDCDFE4),
  red: Color(0xFFE06C75),
  green: Color(0xFF98C379),
  yellow: Color(0xFFE5C07B),
  blue: Color(0xFF61AFEF),
  magenta: Color(0xFFC678DD),
  cyan: Color(0xFF56B6C2),
  brightBlack: Color(0xFF6B7382),
  brightRed: Color(0xFFEF858D),
  brightGreen: Color(0xFFABD39A),
  brightYellow: Color(0xFFEDD08F),
  brightBlue: Color(0xFF85C1F5),
  brightMagenta: Color(0xFFD69ADF),
  brightCyan: Color(0xFF7BC6D2),
  brightWhite: Color(0xFFF2F4F8),
  searchHitBackground: Color(0xFF51421F),
  searchHitBackgroundCurrent: Color(0xFF7A5B22),
  searchHitForeground: Color(0xFFE3E6EC),
);

/// 主题控制器：模式切换 + 系统亮度跟随 + kv 持久化 + Et 静态令牌同步。
class ThemeController extends ChangeNotifier with WidgetsBindingObserver {
  ThemeController._() {
    WidgetsBinding.instance.addObserver(this);
  }

  static final ThemeController instance = ThemeController._();

  static const _kvKey = 'ui.theme_mode';

  AppThemeMode _mode = AppThemeMode.system;

  /// 启动时调用：读持久化并落到 Et（同步 kv，毫秒级）。
  void load() {
    try {
      final raw = local.kvGet(key: _kvKey);
      _mode = switch (raw) {
        'light' => AppThemeMode.light,
        'dark' => AppThemeMode.dark,
        'system' => AppThemeMode.system,
        _ => AppThemeMode.system,
      };
    } catch (_) {}
    _apply(notify: false);
  }

  AppThemeMode get mode => _mode;

  Brightness get _platformBrightness =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness;

  /// 当前生效亮度（模式解析后）。
  Brightness get resolvedBrightness => switch (_mode) {
        AppThemeMode.light => Brightness.light,
        AppThemeMode.dark => Brightness.dark,
        AppThemeMode.system => _platformBrightness,
      };

  ThemeMode get materialMode => switch (_mode) {
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
        AppThemeMode.system => ThemeMode.system,
      };

  Future<void> setMode(AppThemeMode m) async {
    if (m == _mode) return;
    _mode = m;
    try {
      local.kvPut(key: _kvKey, value: m.name);
    } catch (_) {}
    _apply();
  }

  void _apply({bool notify = true}) {
    final b = resolvedBrightness;
    Et.palette = b == Brightness.dark ? kDarkPalette : kLightPalette;
    if (notify) notifyListeners();
  }

  @override
  void didChangePlatformBrightness() {
    if (_mode == AppThemeMode.system) _apply();
  }
}

/// Material 3 主题（与 AppPalette 同源；浅/深共用一套生成规则）。
ThemeData buildM3Theme(AppPalette p) {
  final scheme = ColorScheme.fromSeed(
    seedColor: p.accent,
    brightness: p.brightness,
  ).copyWith(primary: p.accent, secondary: p.accent);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.contentBg,
    fontFamilyFallback: const ['PingFang SC', 'Helvetica Neue'],
    appBarTheme: AppBarTheme(
      backgroundColor: p.card,
      surfaceTintColor: p.card,
      foregroundColor: p.textPrimary,
      elevation: 0.5,
      systemOverlayStyle: p.brightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.titleBar,
      contentTextStyle: TextStyle(
          fontSize: 13.5,
          color: p.brightness == Brightness.dark ? p.textPrimary : p.titleBarText),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
    ),
    inputDecorationTheme: InputDecorationTheme(
      labelStyle: TextStyle(fontSize: 13, color: p.textSecondary),
      hintStyle: TextStyle(fontSize: 13.5, color: p.textSecondary),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.cardBorder)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.accent, width: 1.6)),
    ),
    dividerTheme: DividerThemeData(color: p.cardBorder, thickness: 1),
    popupMenuTheme: PopupMenuThemeData(
      color: p.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      textStyle: TextStyle(fontSize: 13.5, color: p.textPrimary),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: p.textPrimary),
    ),
  );
}

// eterm 视觉令牌（对齐 Termius 参考稿）：深色自绘标题栏 + 浅色内容区。

import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart';

/// 应用内调色板（Termius 式）。
abstract final class Et {
  // 标题栏
  static const titleBar = Color(0xFF232937);
  static const titleBarText = Color(0xFFE8EAF0);
  static const titleBarPill = Color(0xFF333A4B);
  static const titleBarTabActive = Color(0xFF3A4152);

  // 内容区
  static const contentBg = Color(0xFFF0F1F4);
  static const sidebarBg = Color(0xFFF8F8FA);
  static const sidebarSelected = Color(0xFFE9EAEE);

  // 卡片
  static const card = Colors.white;
  static const cardBorder = Color(0xFFE5E7EB);
  static const cardRadius = 14.0;

  // 图标瓦片
  static const tileGroup = Color(0xFF2C63D9);
  static const tileHost = Color(0xFFF05423);

  // 文本
  static const textPrimary = Color(0xFF20242F);
  static const textSecondary = Color(0xFF8A8F9C);

  // 主按钮 / 强调
  static const primaryBtn = Color(0xFF232937);
  static const accent = Color(0xFFF05423);

  // 终端浅色主题
  static const termBg = Color(0xFFFFFFFF);
  static const termFg = Color(0xFF1F2328);
}

/// 浅色终端配色（ANSI 全套，对齐 Termius 浅色终端）。
const termLightTheme = TerminalTheme(
  cursor: Et.termFg,
  selection: Color(0xFFADD6FF),
  foreground: Et.termFg,
  background: Et.termBg,
  black: Color(0xFF1F2328),
  white: Color(0xFFD0D4DA),
  red: Color(0xFFD1242F),
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
  searchHitForeground: Et.termFg,
);

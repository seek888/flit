import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'host_platform.dart';

/// 全局视觉常量(GitHub Dark 调色板)。
/// 页面与组件统一从这里取色, 禁止再散落硬编码色值。
class AppColors {
  AppColors._();

  static const bg = Color(0xFF10141C); // 页面/终端底色
  static const surface = Color(0xFF191F2A); // 卡片/栏
  static const border = Color(0xFF303A49);
  static const divider = Color(0xFF21262D);

  static const accent = Color(0xFF58A6FF); // 蓝: 主操作/选中
  static const success = Color(0xFF3FB950); // 绿: 完成
  static const danger = Color(0xFFF85149); // 红: 失败
  static const warn = Color(0xFFD29922); // 黄: 注意/未就绪

  static const textPrimary = Color(0xFFE2E8F0);
  static const textSecondary = Color(0xFF8B949E);
  static const textFaint = Color(0xFF8592A6);
  static const textDisabled = Color(0xFF484F58);

  static const primaryButton = Color(0xFF387CE8);

  // ---------- 桌面交互态（悬停/选中） ----------
  // Android 没有鼠标，这些色只在桌面分支（HoverRow / 菜单）里使用。
  static const hover = Color(0xFF202733); // 悬停底色，比 surface 略亮
  static const selected = Color(0xFF2B3A50); // 选中行底色
  static const hoverStrong = Color(0xFF2E3846); // 强悬停（可拖拽的分隔条等）

  /// 代码编辑/终端共用的 monospace 文字样式
  static const mono = TextStyle(
    fontFamily: 'monospace',
    fontSize: 13,
    height: 1.4,
    color: textPrimary,
  );
}

/// 代码高亮配色(highlight 风格 theme): 内置 dark/light 两套,
/// 编辑器设置里切换(CodeTheme.current)。覆盖编辑面/行号槽/诊断盒全部用色。
class CodeTheme {
  const CodeTheme({
    required this.background,
    required this.plain,
    required this.keyword,
    required this.string,
    required this.comment,
    required this.number,
    required this.clazz,
    required this.annotation,
    required this.gutterBackground,
    required this.gutterText,
    required this.gutterActive,
    required this.cursor,
    required this.diagBoxBackground,
  });

  final Color background; // 编辑区底色
  final Color plain; // 普通文本
  final Color keyword; // 关键字
  final Color string; // 字符串
  final Color comment; // 注释
  final Color number; // 数字
  final Color clazz; // 类型/类名
  final Color annotation; // 注解 @xxx
  final Color gutterBackground; // 行号槽底色
  final Color gutterText; // 行号
  final Color gutterActive; // 光标行行号
  final Color cursor; // 光标
  final Color diagBoxBackground; // 行内诊断消息盒底色

  /// 当前主题(编辑器设置切换; 默认 dark)
  static CodeTheme current = dark;

  static const dark = CodeTheme(
    background: Color(0xFF10141C),
    plain: Color(0xFFE2E8F0),
    keyword: Color(0xFFFF7B72),
    string: Color(0xFFA5D6FF),
    comment: Color(0xFF8B949E),
    number: Color(0xFF79C0FF),
    clazz: Color(0xFFFFA657),
    annotation: Color(0xFFD2A8FF),
    gutterBackground: Color(0xFF191F2A),
    gutterText: Color(0xFF484F58),
    gutterActive: Color(0xFF58A6FF),
    cursor: Color(0xFF58A6FF),
    diagBoxBackground: Color(0xF2161B22),
  );

  static const light = CodeTheme(
    background: Color(0xFFFFFFFF),
    plain: Color(0xFF1F2328),
    keyword: Color(0xFFCF222E),
    string: Color(0xFF0A3069),
    comment: Color(0xFF6E7781),
    number: Color(0xFF0550AE),
    clazz: Color(0xFF953800),
    annotation: Color(0xFF8250DF),
    gutterBackground: Color(0xFFF6F8FA),
    gutterText: Color(0xFF8C959F),
    gutterActive: Color(0xFF0969DA),
    cursor: Color(0xFF0969DA),
    diagBoxBackground: Color(0xF2FFFFFF),
  );
}

/// 输入法工具: 单行/多行代码区共用
class AppInputFormatters {
  AppInputFormatters._();

  /// 代码区常用过滤(留空: 缩进与括号由 CodeInputFormatter 处理)
  static List<TextInputFormatter> code() => const [];
}

ThemeData flitTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.dark,
    surface: AppColors.surface,
    primary: AppColors.accent,
    onPrimary: AppColors.bg,
  );
  final typography = ThemeData.dark().textTheme.apply(
    bodyColor: AppColors.textPrimary,
    displayColor: AppColors.textPrimary,
  );
  final theme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    textTheme: typography,
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      systemOverlayStyle: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      titleTextStyle: typography.titleLarge!.copyWith(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primaryButton,
        foregroundColor: Colors.white,
        minimumSize: const Size(44, 46),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.all(16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      // 暗色下无边框输入框与卡片底色融为一体, 全局给可见描边
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.divider),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.4),
      ),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      titleTextStyle: typography.bodyMedium!.copyWith(fontSize: 14),
      subtitleTextStyle: typography.bodySmall!.copyWith(
        fontSize: 12,
        height: 1.5,
        color: AppColors.textSecondary,
      ),
      iconColor: AppColors.textSecondary,
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.divider,
      thickness: 1,
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(44, 44)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.bg,
      // 系统手柄有 48px 最小触达高度(SizedBox 压不下去), 太空;
      // 各 sheet 顶部放紧凑的 SheetHandle 替代。
      showDragHandle: false,
      modalBackgroundColor: AppColors.bg,
    ),
    popupMenuTheme: const PopupMenuThemeData(color: AppColors.surface),
  );
  if (!isDesktopPlatform) return theme;
  return _desktopTheme(theme, typography);
}

/// 桌面紧凑主题：Windows 观感（Segoe UI、更小密度、细滚动条、紧凑菜单/对话框）。
///
/// Android 分支在 [flitTheme] 里原样返回，不做任何覆盖。
ThemeData _desktopTheme(ThemeData base, TextTheme typography) {
  final seeded = typography.apply(
    fontFamily: isWindowsPlatform ? 'Segoe UI' : null,
  );
  final desktopTypography = seeded.copyWith(
    bodyMedium: seeded.bodyMedium?.copyWith(fontSize: 13),
    bodySmall: seeded.bodySmall?.copyWith(fontSize: 12),
    titleLarge: seeded.titleLarge?.copyWith(fontSize: 16),
    labelLarge: seeded.labelLarge?.copyWith(fontSize: 12),
  );
  return base.copyWith(
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    textTheme: desktopTypography,
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primaryButton,
        foregroundColor: Colors.white,
        minimumSize: const Size(32, 34),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        textStyle: const TextStyle(fontSize: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(32, 32),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      hintStyle: const TextStyle(fontSize: 13, color: AppColors.textFaint),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.divider),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.4),
      ),
    ),
    listTileTheme: ListTileThemeData(
      dense: true,
      visualDensity: VisualDensity.compact,
      minTileHeight: 30,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      titleTextStyle: seeded.bodyMedium!.copyWith(fontSize: 13),
      subtitleTextStyle: seeded.bodySmall!.copyWith(
        fontSize: 12,
        height: 1.4,
        color: AppColors.textSecondary,
      ),
      iconColor: AppColors.textSecondary,
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.resolveWith<double?>(
        (states) => states.contains(WidgetState.hovered) ? 12 : 8,
      ),
      radius: const Radius.circular(4),
      interactive: true,
      trackVisibility: const WidgetStatePropertyAll<bool>(false),
      thumbColor: WidgetStateProperty.resolveWith<Color?>(
        (states) => states.contains(WidgetState.hovered)
            ? AppColors.textSecondary
            : AppColors.border,
      ),
      crossAxisMargin: 2,
      minThumbLength: 24,
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      textStyle: const TextStyle(fontSize: 12, color: AppColors.textPrimary),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.border),
      ),
    ),
    menuBarTheme: const MenuBarThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll<Color>(Colors.transparent),
        elevation: WidgetStatePropertyAll<double>(0),
        padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(EdgeInsets.zero),
        minimumSize: WidgetStatePropertyAll<Size>(Size(0, 30)),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        ),
      ),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll<Color>(AppColors.surface),
        elevation: const WidgetStatePropertyAll<double>(8),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
          EdgeInsets.symmetric(vertical: 4),
        ),
        minimumSize: const WidgetStatePropertyAll<Size>(Size(180, 28)),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: const BorderSide(color: AppColors.border),
          ),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: AppColors.border),
      ),
      constraints: const BoxConstraints(maxWidth: 560),
      titleTextStyle: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
      contentTextStyle: const TextStyle(
        fontSize: 13,
        height: 1.5,
        color: AppColors.textSecondary,
      ),
    ),
  );
}

class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.clipBehavior = Clip.none,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Clip clipBehavior;
  @override
  Widget build(BuildContext context) => Material(
    color: AppColors.surface,
    borderRadius: BorderRadius.circular(16),
    clipBehavior: clipBehavior,
    child: Padding(padding: padding, child: child),
  );
}

/// 底部弹层手柄: 系统 DragHandle 有 48px 最小触达高度(padding 太大),
/// 换成紧凑自绘条, 放在 sheet 内容第一行。
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        width: 32,
        height: 4,
        decoration: BoxDecoration(
          color: AppColors.border,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    ),
  );
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 24, 4, 12),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        color: AppColors.textSecondary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

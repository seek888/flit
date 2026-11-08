import 'package:flit/l10n/strings.dart';
import '../../services/shell.dart';
import 'installed_toolchain.dart';
import 'toolchain_catalog.dart';

/// 管理对象是安装目录里的组件，而非 Release 里的压缩包。
/// SDK 整包仅用于初始化；ADB 和 sdkmanager 共用固定目录，不伪装成多版本组件。
class ToolchainComponent {
  const ToolchainComponent(this.id, this.title, {this.shared = false});

  final String id;
  final String title;
  String get description => switch (id) {
    'flutter-sdk' => strings.keepMultipleVersionsAndChooseTheActive,
    'platforms' => strings.matchesTheProjectCompilesdkMultipleApiVersions,
    'build-tools' => strings.androidPackagingToolsInstallAndKeepVersions,
    'ndk' => strings.nativeCompilerToolsTheProjectSelectsThe,
    'cmake' => strings.nativeBuildToolsTheProjectSelectsThe,
    'platform-tools' => strings.adbAndOtherSharedDeviceToolsInstalling,
    _ => strings.sdkmanagerAndOtherSharedSdkManagementTools,
  };
  final bool shared;

  static final all = [
    ToolchainComponent('flutter-sdk', 'Flutter SDK'),
    ToolchainComponent('platforms', 'Android Platforms'),
    ToolchainComponent('build-tools', 'Build Tools'),
    ToolchainComponent('ndk', 'Android NDK'),
    ToolchainComponent('cmake', 'CMake / Ninja'),
    ToolchainComponent('platform-tools', 'Platform Tools', shared: true),
    ToolchainComponent('cmdline-tools', 'Command-line Tools', shared: true),
  ];

  /// 组件管理页展示的条目。
  ///
  /// 桌面端由 sdkmanager 统一管理 SDK：`platform-tools` / `cmdline-tools`
  /// 是「Android 工具链」阶段的产物，不作为可切换版本单独列出。
  static List<ToolchainComponent> get visible => isDesktopPlatform
      ? all.where((component) => !component.shared).toList(growable: false)
      : all;

  List<InstalledToolchain> installed(List<InstalledToolchain> tools) =>
      tools.where((tool) => tool.component == id).toList();

  String versionLabel(CatalogEntry entry) => switch (id) {
    'platforms' => 'API ${entry.tag.replaceFirst('platform-', '')}',
    'build-tools' => entry.tag.replaceFirst('sdk-', ''),
    'flutter-sdk' => entry.tag.replaceFirst('flutter-', ''),
    'ndk' => entry.tag.replaceFirst('ndk-', ''),
    'cmake' => entry.tag.replaceFirst('cmake-', ''),
    _ => strings.companionToolsP(entry.tag),
  };

  /// tag 只描述发布族。特别是 sdk-36.0.0 不能当作 ADB/sdkmanager 的版本，
  /// NDK 的 r 标签也不能用于项目要求的完整 Pkg.Revision 验证。
  String? releaseTag(InstalledToolchain tool) => switch (id) {
    'platforms' => 'platform-${tool.version.replaceFirst('android-', '')}',
    'build-tools' => 'sdk-${tool.version}',
    'flutter-sdk' => 'flutter-${tool.version}',
    'cmake' => 'cmake-${tool.version}',
    // NDK 目录使用完整 revision，展示层不凭 r 标签猜测两个安装包相同。
    _ => null,
  };

  List<CatalogEntry> downloads(
    ToolchainCatalog catalog,
    Map<String, List<CatalogEntry>> versions,
    List<InstalledToolchain> local,
  ) {
    final entries = versions[id] ?? const [];
    if (shared) {
      return entries
          .where(
            (e) =>
                e.tag == catalog.sources[id]?.defaultTag &&
                !local.any((t) => matches(t, e)),
          )
          .toList();
    }
    return entries.where((e) => !local.any((t) => matches(t, e))).toList();
  }

  bool matches(InstalledToolchain tool, CatalogEntry entry) =>
      releaseTag(tool) == entry.tag ||
      (tool.archiveSha256 != null && tool.archiveSha256 == entry.sha256);
}

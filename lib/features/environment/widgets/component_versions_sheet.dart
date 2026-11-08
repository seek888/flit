import 'package:flit/l10n/strings.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../environment_controller.dart';
import '../installed_toolchain.dart';
import '../toolchain_catalog.dart';
import '../toolchain_component.dart';
import 'installed_toolchain_tile.dart';

/// 本地列表始终可见；远程失败只影响下载。目录缓存由应用级 catalog 管理，
/// 弹层只保存加载显示状态，安装/切换/删除前关闭弹层以展示终端输出。
class ComponentVersionsSheet extends StatefulWidget {
  const ComponentVersionsSheet({
    super.key,
    required this.component,
    required this.environment,
    required this.catalog,
    required this.onInstall,
    required this.onChange,
  });

  final ToolchainComponent component;
  final EnvironmentController environment;
  final ToolchainCatalog catalog;
  final Future<void> Function(CatalogEntry entry) onInstall;
  final Future<void> Function(InstalledToolchain tool, {bool delete}) onChange;

  @override
  State<ComponentVersionsSheet> createState() => _ComponentVersionsSheetState();
}

class _ComponentVersionsSheetState extends State<ComponentVersionsSheet> {
  Map<String, List<CatalogEntry>> _versions = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _versions = widget.catalog.lastGood;
    unawaited(_load());
  }

  Future<void> _load({bool refresh = false}) async {
    setState(() => _loading = true);
    try {
      final versions = await widget.catalog.collect(forceRefresh: refresh);
      if (!mounted) return;
      setState(() {
        _versions = versions;
        _error = widget.catalog.errors[widget.component.id];
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _blocked =>
      widget.environment.busy ||
      !widget.environment.installedLoaded ||
      widget.environment.installedError != null;

  Future<void> _install(CatalogEntry entry) async {
    if (_blocked) return;
    final local = widget.component.installed(widget.environment.installed);
    if (widget.component.shared && local.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(context.strings.replaceP(widget.component.title)),
          content: Text(
            context.strings.installTheCompanionToolsFromPReplacing(entry.tag),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(context.strings.cancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(context.strings.replace),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || _blocked) return;
    }
    if (!mounted) return;
    Navigator.pop(context);
    await widget.onInstall(entry);
  }

  Future<void> _change(InstalledToolchain tool, {bool delete = false}) async {
    if (!mounted || _blocked) return;
    Navigator.pop(context);
    await widget.onChange(tool, delete: delete);
  }

  VoidCallback? _repairFor(
    InstalledToolchain tool,
    List<CatalogEntry> entries,
  ) {
    final entry = entries
        .where((e) => widget.component.matches(tool, e))
        .firstOrNull;
    return entry == null ? null : () => _install(entry);
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Text(
      text,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
  );

  Widget _notice(String text, {bool error = false}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        color: error ? AppColors.danger : AppColors.textSecondary,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.environment,
    builder: (context, _) {
      final env = widget.environment;
      final component = widget.component;
      final local = component.installed(env.installed);
      final entries = _versions[component.id] ?? const [];
      final downloads = component.downloads(widget.catalog, _versions, local);
      return FractionallySizedBox(
        heightFactor: .85,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              const SheetHandle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        component.title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: context.strings.refreshAvailableVersions,
                      onPressed: _loading ? null : () => _load(refresh: true),
                      icon: const Icon(Icons.refresh, size: 20),
                    ),
                    IconButton(
                      tooltip: context.strings.close,
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 20),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    _notice(component.description),
                    _heading(context.strings.localVersions),
                    if (env.installedError != null)
                      _notice(env.installedError!, error: true),
                    if (env.checking || !env.installedLoaded)
                      _notice(
                        env.installedError == null
                            ? context.strings.checkingLocalComponents
                            : context.strings.installationStatusUnconfirmed,
                      )
                    else if (local.isEmpty && env.installedError == null)
                      _notice(context.strings.notInstalled),
                    for (final tool in local)
                      InstalledToolchainTile(
                        tool: tool,
                        busy: _blocked,
                        onChange: _change,
                        onRepair: _repairFor(tool, entries),
                      ),
                    _heading(
                      component.shared
                          ? context.strings.companionTools
                          : context.strings.availableVersions,
                    ),
                    if (_loading) const LinearProgressIndicator(minHeight: 2),
                    if (_error != null)
                      _notice(
                        context.strings.failedToFetchVersionsPP(
                          entries.isEmpty
                              ? context.strings.refreshVersionsLater
                              : context.strings.showingPreviousCatalog,
                          _error,
                        ),
                        error: true,
                      ),
                    if (!_loading && _error == null && downloads.isEmpty)
                      _notice(
                        entries.isEmpty ||
                                (component.shared &&
                                    !entries.any(
                                      (e) =>
                                          e.tag ==
                                          widget
                                              .catalog
                                              .sources[component.id]
                                              ?.defaultTag,
                                    ))
                            ? context
                                  .strings
                                  .noDownloadableCompanionVersionsInTheRepository
                            : context
                                  .strings
                                  .allCatalogVersionsAreInstalledUseThe,
                      ),
                    if (component.id == 'ndk' &&
                        local.isNotEmpty &&
                        downloads.isNotEmpty)
                      _notice(
                        context.strings.installingTheSameNdkVersionKeepsThe,
                      ),
                    for (final entry in downloads)
                      ListTile(
                        dense: true,
                        title: Text(
                          component.versionLabel(entry),
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(
                          '${_formatSize(entry.size)}${component.shared && local.isNotEmpty ? context.strings.replaceSharedToolsSuffix : ''}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        trailing: const Icon(Icons.download_outlined, size: 20),
                        onTap: _blocked ? null : () => _install(entry),
                      ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  static String _formatSize(int bytes) => bytes <= 0
      ? '—'
      : bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(0)} KB'
      : bytes < 1024 * 1024 * 1024
      ? '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB'
      : '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
}

import 'package:flit/l10n/strings.dart';
import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../environment_controller.dart';
import '../installed_toolchain.dart';
import '../toolchain_catalog.dart';
import '../toolchain_component.dart';
import 'component_versions_sheet.dart';

/// 固定的组件入口只读取本地状态；滚动、重建、进入环境页均不请求版本目录。
class ToolchainComponentsSection extends StatelessWidget {
  const ToolchainComponentsSection({
    super.key,
    required this.environment,
    required this.catalog,
    required this.onInstall,
    required this.onChange,
  });

  final EnvironmentController environment;
  final ToolchainCatalog catalog;
  final Future<void> Function(CatalogEntry entry) onInstall;
  final Future<void> Function(InstalledToolchain tool, {bool delete}) onChange;

  @override
  Widget build(BuildContext context) {
    final env = environment;
    final initialized = env.stages['bootstrap']?.state == 'DONE';
    final known = env.installedLoaded && env.installedError == null;
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              context.strings.componentManager,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              env.installedError ??
                  (initialized
                      ? context
                            .strings
                            .manageInstalledVersionsDownloadsAndRepairsBy
                      : context.strings.setUpTheBaseEnvironmentFirstThen),
              style: TextStyle(
                fontSize: 12,
                color: env.installedError == null
                    ? AppColors.textSecondary
                    : AppColors.danger,
              ),
            ),
          ),
          for (final component in ToolchainComponent.visible)
            Builder(
              builder: (context) {
                final local = component.installed(env.installed);
                final damaged = local.where((t) => !t.complete).length;
                final active = local.where((t) => t.active).firstOrNull;
                final installedSummary = local.length == 1
                    ? '${damaged == 0 ? context.strings.installed : context.strings.needsRepair} · ${local.single.displayVersion}${active == null ? '' : context.strings.currentSuffix}'
                    : context.strings.pVersionsPP(
                        local.length,
                        active == null
                            ? ''
                            : context.strings.currentVersionSuffix(
                                active.version,
                              ),
                        damaged == 0
                            ? ''
                            : context.strings.repairCountSuffix(damaged),
                      );
                final status = !initialized
                    ? context.strings.availableAfterSetup
                    : env.checking
                    ? context.strings.checking372
                    : !known
                    ? context.strings.installationStatusUnconfirmed
                    : local.isEmpty
                    ? context.strings.notInstalled
                    : installedSummary;
                return ListTile(
                  dense: true,
                  leading: Icon(
                    damaged > 0
                        ? Icons.error_outline
                        : known && local.isNotEmpty
                        ? Icons.check_circle_outline
                        : Icons.inventory_2_outlined,
                    size: 20,
                    color: !known
                        ? AppColors.textSecondary
                        : damaged > 0
                        ? AppColors.danger
                        : local.isNotEmpty
                        ? AppColors.success
                        : AppColors.textSecondary,
                  ),
                  title: Text(
                    component.title,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    status,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: !initialized
                      ? null
                      : () => showModalBottomSheet<void>(
                          context: context,
                          isScrollControlled: true,
                          useSafeArea: true,
                          builder: (_) => ComponentVersionsSheet(
                            component: component,
                            environment: env,
                            catalog: catalog,
                            onInstall: onInstall,
                            onChange: onChange,
                          ),
                        ),
                );
              },
            ),
        ],
      ),
    );
  }
}

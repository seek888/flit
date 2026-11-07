import 'package:flit/l10n/strings.dart';
import 'package:flit_device/flit_device.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../git/github_account.dart';
import '../git/github_account_tile.dart';
import '../../core/host_platform.dart';
import '../../core/page_layout.dart';
import '../../core/theme.dart';
import '../../services/auto_proxy.dart';
import '../environment/environment_status.dart';
import '../device/device_connect_page.dart';
import '../editor/editor_settings_page.dart';
import '../environment/environment_page.dart';
import '../terminal/terminal_settings.dart';
import 'app_versions_page.dart';
import 'env_vars_page.dart';
import 'appearance_preferences.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with WidgetsBindingObserver {
  EnvironmentStatus? _environment;
  bool _proxySaving = false;
  PermissionStatus _notificationStatus = PermissionStatus.denied;
  bool? _ignoringBattery;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _refreshPermissions();
    // 进页重探一次系统代理地址(开关状态随 AutoProxy 通知刷新)
    context.read<AutoProxy>().load().catchError(_showError);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统设置授权返回时刷新权限状态
    if (state == AppLifecycleState.resumed) _refreshPermissions();
  }

  void _showError(Object error) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.strings.failedToSaveOrLoadSettingsP(error)),
        ),
      );
    }
  }

  Future<void> _refresh() async {
    final status = await EnvironmentStatus.inspect();
    if (mounted) setState(() => _environment = status);
  }

  /// 通知与电池优化状态来自方法通道; 测试环境没有 mock, 失败时静默保持占位。
  /// 桌面端没有这两个概念, 也不读 permission_handler（Windows 恒 GRANTED 会撒谎）。
  Future<void> _refreshPermissions() async {
    if (isDesktopPlatform) return;
    try {
      final notification = await Permission.notification.status;
      final battery = await FlitDevice.isIgnoringBatteryOptimizations();
      if (mounted) {
        setState(() {
          _notificationStatus = notification;
          _ignoringBattery = battery;
        });
      }
    } catch (_) {
      /* 状态读取失败保持占位, 点按操作仍可用 */
    }
  }

  Future<void> _requestNotifications() async {
    // targetSdk 28 下系统不为通知权限的运行时请求弹授权框, 只能去系统通知设置开关
    try {
      await FlitDevice.openNotificationSettings();
    } catch (_) {
      // 个别 ROM 不认直达 intent 时退回应用详情页
      try {
        await openAppSettings();
      } catch (_) {
        _permissionError();
        return;
      }
    }
    await _refreshPermissions();
  }

  Future<void> _requestBattery() async {
    try {
      await FlitDevice.requestIgnoreBatteryOptimizations();
    } catch (_) {
      _permissionError();
      return;
    }
    await _refreshPermissions();
  }

  void _permissionError() {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.strings.unableToRequestPermissionYouCanChange),
        ),
      );
    }
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
    if (mounted && page is EnvironmentPage) _refresh();
  }

  Future<void> _setProxy(bool value) async {
    setState(() => _proxySaving = true);
    try {
      await context.read<AutoProxy>().setEnabled(value);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.strings.proxySettingsUpdatedAppliesToNewTerminals,
            ),
          ),
        );
      }
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _proxySaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final proxy = context.watch<AutoProxy>();
    final preferences = context.watch<AppearancePreferences>();
    return Scaffold(
      appBar: AppBar(title: Text(context.strings.settings)),
      body: PageList(
        children: [
          PageIntro(
            context.strings.ideSettings,
            context.strings.configureDevelopmentToolsDeviceConnectionsAndThe,
          ),
          SectionLabel(context.strings.account),
          _card([
            const GithubAccountTile(),
            // 桌面端没有 gh CLI：个人访问令牌是主登录方式（见 GithubAccount）。
            if (isDesktopPlatform) _githubTokenTile(),
          ]),
          SectionLabel(context.strings.developmentEnvironment),
          _card([
            _link(
              Icons.layers_outlined,
              context.strings.developmentEnvironment,
              _environment?.label ?? context.strings.checking,
              const EnvironmentPage(),
            ),
            _link(
              Icons.data_object,
              context.strings.environmentVariables,
              context.strings.viewToolchainPathsAndCommandEnvironmentSnapshots,
              const EnvVarsPage(),
            ),
            _link(
              Icons.phonelink_setup,
              context.strings.connectDevice,
              context.strings.wirelessDebuggingPairingAndAuthorization,
              const DeviceConnectPage(),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.swap_vert, color: AppColors.accent),
              title: Text(context.strings.useSystemProxy),
              subtitle: Text(
                proxy.address ?? context.strings.noSystemProxyDetectedItWillBe,
              ),
              value: proxy.enabled,
              onChanged: _proxySaving ? null : _setProxy,
            ),
          ]),
          // 桌面端不需要前台服务/电池优化（Windows 上 permission_handler 恒
          // GRANTED，显示出来等于撒谎），整组隐藏。
          if (!isDesktopPlatform) ...[
            SectionLabel(context.strings.backgroundAndNotifications),
            _card([
              ListTile(
                leading: const Icon(Icons.task_alt, color: AppColors.accent),
                title: Text(context.strings.foregroundService),
                subtitle: Text(context.strings.showBuildAndTaskStatusInA),
                trailing: _notificationLabel(),
                onTap: _requestNotifications,
              ),
              ListTile(
                leading: const Icon(
                  Icons.battery_saver_outlined,
                  color: AppColors.accent,
                ),
                title: Text(context.strings.backgroundExecution),
                subtitle: Text(
                  context
                      .strings
                      .ignoreBatteryOptimizationToReduceBackgroundTask,
                ),
                trailing: _batteryLabel(),
                onTap: _requestBattery,
              ),
            ]),
          ],
          SectionLabel(context.strings.editorAndTerminal),
          _card([
            _link(
              Icons.code,
              context.strings.editorSettings,
              context.strings.fontColorSchemeSoftWraps,
              const EditorSettingsPage(),
            ),
            _link(
              Icons.text_fields,
              context.strings.terminalSettings,
              context.strings.pinchToZoomFontSizeMonospaceFont,
              const TerminalSettingsPage(),
            ),
          ]),
          SectionLabel(context.strings.general),
          SurfaceCard(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.strings.language,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<String>(
                      segments: [
                        ButtonSegment(
                          value: 'system',
                          label: Text(context.strings.followSystem),
                        ),
                        const ButtonSegment(value: 'zh', label: Text('简体中文')),
                        const ButtonSegment(
                          value: 'en',
                          label: Text('English'),
                        ),
                      ],
                      selected: {preferences.language},
                      onSelectionChanged: (s) async {
                        try {
                          await preferences.setLanguage(s.first);
                        } catch (error) {
                          _showError(error);
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          SectionLabel(context.strings.aboutFlit),
          _card([
            ListTile(
              leading: const Icon(
                Icons.system_update_alt,
                color: AppColors.accent,
              ),
              title: Text(context.strings.appUpdates),
              subtitle: Text(
                context.strings.checkForUpdatesDownloadPreviousVersions,
              ),
              trailing: const Icon(
                Icons.chevron_right,
                color: AppColors.textFaint,
              ),
              onTap: () => _open(AppVersionsPage()),
            ),
            ListTile(
              title: Text(context.strings.buildCommit),
              subtitle: SelectableText(
                String.fromEnvironment(
                  'BUILD_SHA',
                  defaultValue: 'development',
                ),
                style: AppColors.mono,
              ),
            ),
            ListTile(
              title: Text(context.strings.platform),
              subtitle: Text(
                isDesktopPlatform
                    ? '${hostPlatform.name} · desktop'
                    : 'Android · arm64-v8a',
              ),
            ),
          ]),
        ],
      ),
    );
  }

  /// 桌面端：粘贴个人访问令牌登录 GitHub（写入 app 私有 gitconfig）。
  Future<void> _loginWithToken() async {
    final account = context.read<GithubAccount>();
    final token = await showGithubTokenDialog(context);
    if (token == null || !mounted) return;
    final ok = await account.loginWithToken(token);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? '已登录 GitHub${account.loginName == null ? '' : '：${account.loginName}'}'
              : account.error ?? '登录失败',
        ),
      ),
    );
  }

  Widget _githubTokenTile() => ListTile(
    leading: const Icon(Icons.vpn_key_outlined, color: AppColors.accent),
    title: const Text('个人访问令牌（PAT）登录'),
    subtitle: const Text('令牌只保存在本机应用目录，用于私有仓库克隆与推送'),
    trailing: const Icon(Icons.chevron_right, color: AppColors.textFaint),
    onTap: _loginWithToken,
  );

  Widget _link(IconData icon, String title, String subtitle, Widget page) =>
      ListTile(
        leading: Icon(icon, color: AppColors.accent),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right, color: AppColors.textFaint),
        onTap: () => _open(page),
      );

  Widget _notificationLabel() => switch (_notificationStatus) {
    PermissionStatus.granted => _stateLabel(context.strings.enabled, ok: true),
    PermissionStatus.permanentlyDenied => _stateLabel(context.strings.denied),
    _ => _stateLabel(context.strings.disabled),
  };

  Widget _batteryLabel() => switch (_ignoringBattery) {
    true => _stateLabel(context.strings.allowed, ok: true),
    false => _stateLabel(context.strings.notConfigured),
    _ => _stateLabel(context.strings.checking),
  };

  Widget _stateLabel(String text, {bool ok = false}) => Text(
    text,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(
      color: ok ? AppColors.accent : AppColors.textFaint,
    ),
  );

  Widget _card(List<Widget> children) => SurfaceCard(
    padding: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
          children[i],
        ],
      ],
    ),
  );
}

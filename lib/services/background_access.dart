import 'package:flit/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flit_device/flit_device.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../core/host_platform.dart';
import '../features/settings/appearance_preferences.dart';

/// 首次初始化前说明后台运行用途；每项设置都在对话框内直接发起。
/// 权限入口与设置页共用，拒绝后可在设置页再次调整。
class BackgroundAccess {
  static Future<void> explain(BuildContext context) async {
    // 桌面端没有前台服务/电池优化概念，也不需要通知权限：直接跳过。
    if (isDesktopPlatform) return;
    final preferences = context.read<AppearancePreferences>();
    if (preferences.backgroundNoticeShown) return;

    await showDialog<void>(
      context: context,
      builder: (_) => const _BackgroundSetupDialog(),
    );
    try {
      await preferences.update(backgroundNoticeShown: true);
    } catch (_) {
      // 保存提示偏好失败不应阻止初始化。
    }
  }
}

/// 初始化前置说明：描边按钮就地发起，结果回显在按钮上，避免"点了没反应"。
class _BackgroundSetupDialog extends StatefulWidget {
  const _BackgroundSetupDialog();

  @override
  State<_BackgroundSetupDialog> createState() => _BackgroundSetupDialogState();
}

class _BackgroundSetupDialogState extends State<_BackgroundSetupDialog>
    with WidgetsBindingObserver {
  /// null = 未知(通道不可用或检测中)，按钮保持可点
  bool? _foregroundAllowed;
  bool? _batteryAllowed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 从系统通知设置开关后返回时刷新按钮状态
    if (state == AppLifecycleState.resumed) _loadStatus();
  }

  Future<void> _loadStatus() async {
    try {
      final notification = await Permission.notification.status;
      final battery = await FlitDevice.isIgnoringBatteryOptimizations();
      if (mounted) {
        setState(() {
          _foregroundAllowed = notification.isGranted;
          _batteryAllowed = battery;
        });
      }
    } catch (_) {
      /* 测试环境没有通道 mock，保持未知态 */
    }
  }

  Future<void> _openNotificationSettings() async {
    try {
      await FlitDevice.openNotificationSettings();
    } catch (_) {
      // 个别 ROM 不认通知设置直达 intent 时, 退回应用详情页
      try {
        await openAppSettings();
      } catch (_) {
        /* 两级都失败保持原状态, 用户仍可从系统应用信息进入 */
      }
    }
  }

  Future<void> _requestBattery() async {
    try {
      final allowed = await FlitDevice.requestIgnoreBatteryOptimizations();
      if (mounted) setState(() => _batteryAllowed = allowed);
    } catch (_) {
      /* 请求失败保持原状态，可再点 */
    }
  }

  @override
  Widget build(BuildContext context) {
    final caption = Theme.of(context).textTheme.bodySmall;
    return AlertDialog(
      title: Text(context.strings.backgroundExecutionAndNotifications),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.strings.setupAndBuildsMayTakeAWhile),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _foregroundAllowed == true
                      ? null
                      : _openNotificationSettings,
                  icon: Icon(
                    _foregroundAllowed == true ? Icons.check : Icons.task_alt,
                    size: 18,
                  ),
                  label: Text(
                    _foregroundAllowed == true
                        ? context.strings.enabled
                        : context.strings.foregroundService,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _batteryAllowed == true ? null : _requestBattery,
                  icon: Icon(
                    _batteryAllowed == true
                        ? Icons.check
                        : Icons.battery_saver_outlined,
                    size: 18,
                  ),
                  label: Text(
                    _batteryAllowed == true
                        ? context.strings.allowed
                        : context.strings.backgroundExecution,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            context.strings.theForegroundServiceOnlyShowsGeneralTask,
            style: caption,
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.strings.continueAction),
        ),
      ],
    );
  }
}

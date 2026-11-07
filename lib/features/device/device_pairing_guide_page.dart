import 'package:flit/l10n/strings.dart';
import 'dart:async';

import 'package:flit_device/flit_device.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/host_platform.dart';
import '../../core/page_layout.dart';
import '../../core/theme.dart';
import '../../services/shell.dart';

/// 离线可读的通知配对教程，按 Flit 的实际流程改写 Shizuku 的使用说明。
/// 阅读不启动服务；明确开始后返回 true，由设备页先启动服务再打开系统设置。
/// 从系统设置返回时重新读取权限，不把厂商通知样式误判成可自动检测的权限。
class DevicePairingGuidePage extends StatefulWidget {
  const DevicePairingGuidePage({super.key, this.allowStart = true});
  final bool allowStart;

  @override
  State<DevicePairingGuidePage> createState() => _DevicePairingGuidePageState();
}

class _DevicePairingGuidePageState extends State<DevicePairingGuidePage>
    with WidgetsBindingObserver {
  bool? _supported;
  bool? _notifications;
  bool _checking = true;
  String? _error;
  int _revision = 0;

  @override
  void initState() {
    super.initState();
    // 桌面端没有 FlitDevice 的通知式配对通道：入口已在设备页隐藏，
    // 这里再兜底一次，避免误调 permission_handler / 原生通道。
    if (isDesktopPlatform) return;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_check());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_check());
  }

  @override
  void dispose() {
    ++_revision;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _check() async {
    final revision = ++_revision;
    setState(() => _checking = true);
    try {
      final result = await FlitDevice.pairingReadiness();
      if (result['supported'] is! bool ||
          result['notificationsEnabled'] is! bool) {
        throw StateError(strings.unableToReadNotificationStatus);
      }
      if (!mounted || revision != _revision) return;
      setState(() {
        _supported = result['supported'] as bool;
        _notifications = result['notificationsEnabled'] as bool;
        _error = null;
      });
    } catch (_) {
      if (!mounted || revision != _revision) return;
      setState(() {
        _supported = null;
        _notifications = null;
        _error = context.strings.unableToReadNotificationStatusRetry;
      });
    } finally {
      if (mounted && revision == _revision) setState(() => _checking = false);
    }
  }

  Future<void> _open(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = error is PlatformException
            ? error.message ?? context.strings.unableToOpenSystemSettings
            : context.strings.unableToOpenRetryLater,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isDesktopPlatform) {
      return Scaffold(
        appBar: AppBar(title: Text(context.strings.wirelessPairingGuide)),
        body: const PageList(
          children: [
            PageIntro(
              '桌面版不支持通知式无线配对',
              '请使用 USB 连接；需要无线调试时，在设备页的「手动连接」里直接 adb pair / adb connect。',
            ),
          ],
        ),
      );
    }
    return _buildBody(context);
  }

  Widget _buildBody(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.strings.wirelessPairingGuide)),
    body: PageList(
      children: [
        PageIntro(
          context.strings.enterThePairingCodeInTheNotification,
          context.strings.androidPhoneMustBeConnectedToWi,
        ),
        SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _checking
                    ? context.strings.checkingNotificationPermission
                    : _supported == false
                    ? context.strings.wirelessPairingIsNotSupportedOnThis
                    : _notifications == true
                    ? context.strings.pairingNotificationsEnabled
                    : _notifications == false
                    ? context.strings.allowFlitNotificationsFirst
                    : context.strings.notificationStatusUnknown,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                _supported == false
                    ? context.strings.wirelessPairingRequiresAndroidOrLaterGo
                    : context
                          .strings
                          .allowFlitNotificationsIncludingTheWirelessDebugging,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  color: AppColors.textSecondary,
                ),
              ),
              if (_checking) const LinearProgressIndicator(minHeight: 2),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => _open(FlitDevice.openNotificationSettings),
                    child: Text(context.strings.notificationSettings),
                  ),
                  TextButton(
                    onPressed: _checking ? null : _check,
                    child: Text(context.strings.checkAgain487),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          StatusNotice(_error!, error: true),
        ],
        const SizedBox(height: 12),
        StatusNotice(context.strings.xiaomiPocoSomeMiuiVersionsRequireThe),
        if (!widget.allowStart) ...[
          const SizedBox(height: 12),
          StatusNotice(
            context.strings.finishTheCurrentDeviceOperationOrInstall,
          ),
        ],
        const SizedBox(height: 20),
        _step(
          '1',
          context.strings.startPairing,
          context.strings.tapStartPairingBelowFlitStartsThe,
        ),
        _step(
          '2',
          context.strings.openThePairingCodeDialog,
          context.strings.enableWirelessDebuggingTapItsLabelTo,
          note: context.strings.enablingTheSwitchAloneIsNotEnough,
        ),
        _step(
          '3',
          context.strings.expandTheNotificationAndEnterTheDigit,
          context.strings.expandTheFlitPairingNotificationTapEnter,
          note: context.strings.theEnterPairingCodeButtonAppearsOnce,
        ),
        _step(
          '4',
          context.strings.returnToFlitToConnect,
          context.strings.returnToFlitAfterSuccessfulPairingIt,
        ),
        SurfaceCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              _help(context.strings.noNotificationInputEnteringTheCodeFails, [
                Text(context.strings.expandTheNotificationAndCheckThatEnter),
                const SizedBox(height: 10),
                Text(context.strings.someXiaomiRedmiAndPocoMiuiVersions),
                const SizedBox(height: 10),
                Text(context.strings.namesAndLocationsVaryAcrossHyperosAnd),
                const SizedBox(height: 10),
                Text(context.strings.ifThisOptionIsUnavailableKeepThe),
              ]),
              _help(
                context.strings.keepsSearchingNoResponseAfterOpeningSettings,
                [
                  Text(context.strings.enableWiFiAndWirelessDebuggingAnd),
                  const SizedBox(height: 10),
                  Text(
                    context.strings.someSystemsRestrictLocalNetworkAccessFor,
                  ),
                  TextButton(
                    onPressed: () => _open(() async {
                      await FlitDevice.requestIgnoreBatteryOptimizations();
                    }),
                    child: Text(context.strings.allowBackgroundExecution),
                  ),
                  Text(context.strings.ifNothingIsFoundToggleWirelessDebugging),
                ],
              ),
              _help(context.strings.pairedButCannotConnect, [
                Text(context.strings.pairingAndConnectionPortsDifferForManual),
                const SizedBox(height: 10),
                Text(context.strings.tapScanAndConnectOnTheDevice),
              ]),
            ],
          ),
        ),
        const SizedBox(height: 16),
        TextButton.icon(
          onPressed: () => _open(() async {
            if (!await Shell.instance.openUrl(
              'https://shizuku.rikka.app/zh-hans/guide/setup/',
            )) {
              throw StateError(strings.unableToOpenReferencePage);
            }
          }),
          icon: const Icon(Icons.open_in_new, size: 16),
          label: Text(context.strings.referenceShizukuGuide),
        ),
      ],
    ),
    bottomNavigationBar: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton.icon(
          onPressed:
              widget.allowStart &&
                  !_checking &&
                  _supported == true &&
                  _notifications == true
              ? () => Navigator.pop(context, true)
              : null,
          icon: const Icon(Icons.notifications_active_outlined, size: 18),
          label: Text(context.strings.startPairing),
        ),
      ),
    ),
  );

  Widget _step(String number, String title, String text, {String? note}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: AppColors.accent.withValues(alpha: .12),
              child: Text(
                number,
                style: const TextStyle(color: AppColors.accent, fontSize: 13),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    text,
                    style: const TextStyle(
                      fontSize: 13,
                      height: 1.6,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  if (note != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      note,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: AppColors.accent,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );

  Widget _help(String title, List<Widget> children) => ExpansionTile(
    title: Text(title, style: const TextStyle(fontSize: 13)),
    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    children: [
      DefaultTextStyle(
        style: const TextStyle(
          fontSize: 13,
          height: 1.6,
          color: AppColors.textSecondary,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    ],
  );
}

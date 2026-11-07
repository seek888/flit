import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flit_env/flit_env.dart';

import '../core/host_platform.dart';
import 'desktop_toolchain.dart';
import 'paths.dart';

/// 自动代理: 跟随系统代理(单一开关, Dart 网络与终端环境两层同用)。
/// 地址来自系统设置(Wi-Fi 代理 / clash 仅代理模式), 原生在默认网络代理
/// 变化时经 onSystemProxyChanged 实时推送 —— 不重启 app 也能即时切换;
/// 未设置时开关打开也不生效。Dart 侧 HttpClient 立即覆盖; 终端里的
/// git/curl/apt/dart pub 在下一个新会话启动时拿到(PtyLauncher 注入)。
///
/// **桌面端**：没有 flit_env 原生通道，改为在 [load]（进设置页/启动）时
/// 主动读一次系统代理：Windows 读 IE/WinINET 的注册表项或 `netsh winhttp`，
/// Linux/macOS 读 `http(s)_proxy` 环境变量；失败一律静默返回 null。
class AutoProxy extends ChangeNotifier {
  AutoProxy() {
    if (!isDesktopPlatform) FlitEnv.onSystemProxyChanged(_updateAddress);
  }

  bool enabled = false; // 用户开关(默认关, 不改变直连现状)
  String? address; // 系统代理 host:port, null = 系统未设置
  bool _loaded = false;
  File? _file;
  bool _disposed = false;

  /// 桌面端的系统代理探测是真实进程 IO：页面销毁后才回来时不能再 notify。
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// 开关打开且系统有代理时才真正生效
  bool get active => enabled && address != null;

  /// 启动时加载: 持久化开关 + 探测系统代理地址(可多次调用刷新地址)
  Future<void> load() async {
    try {
      final addr = isDesktopPlatform
          ? await readSystemProxy()
          : await FlitEnv.systemProxy();
      if (addr != address) {
        address = addr;
        applyToDart();
        _notify();
      }
    } catch (_) {
      address = null;
    }
    if (_loaded) return;
    _loaded = true;
    try {
      final home = isDesktopPlatform
          ? DesktopToolchain().home
          : (await FlitEnv.bootstrapStatus())['home'] as String? ?? '';
      if (home.isEmpty) return;
      final f = File(joinPath(home, '.flit/proxy.json'));
      _file = f;
      if (f.existsSync()) {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        enabled = j['enabled'] == true;
      }
    } catch (_) {}
    _notify();
  }

  void _updateAddress(String? addr) {
    if (addr == address) return;
    address = addr;
    applyToDart();
    _notify();
  }

  Future<void> setEnabled(bool v) async {
    enabled = v;
    applyToDart();
    _notify();
    try {
      _file?.parent.createSync(recursive: true);
      _file?.writeAsStringSync(jsonEncode({'enabled': v}));
    } catch (_) {}
  }

  /// Dart 侧: HttpOverrides 让全部 dart:io HttpClient 走代理
  void applyToDart() {
    HttpOverrides.global = active ? _ProxyOverrides(address!) : null;
  }

  /// 终端侧: PTY 环境变量(交互 bash 与流水线脚本都从这里继承)
  Map<String, String> envVars() {
    if (!active) return const {};
    final addr = 'http://$address';
    return {
      'http_proxy': addr,
      'https_proxy': addr,
      'HTTP_PROXY': addr,
      'HTTPS_PROXY': addr,
    };
  }
}

/// 读桌面操作系统的系统代理地址（`host:port`）；未设置返回 null。
Future<String?> readSystemProxy() async {
  if (hostPlatform == HostPlatform.windows) return _readWindowsProxy();
  return _readEnvironmentProxy();
}

Future<String?> _readWindowsProxy() async {
  // 1) IE/WinINET 用户设置（clash/v2ray 等大多写这里）
  try {
    final result = await Process.run('reg', [
      'query',
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
    ]);
    final output = '${result.stdout}';
    final enabled = RegExp(
      r'ProxyEnable\s+REG_DWORD\s+0x([0-9a-fA-F]+)',
    ).firstMatch(output);
    if (enabled != null && int.tryParse(enabled.group(1)!, radix: 16) != 0) {
      final server = RegExp(r'ProxyServer\s+REG_SZ\s+(\S+)').firstMatch(output);
      final normalized = parseProxyServer(server?.group(1));
      if (normalized != null) return normalized;
    }
  } catch (_) {}
  // 2) WinHTTP（系统/服务级代理，netsh 输出有中英文两种）
  try {
    final result = await Process.run('netsh', ['winhttp', 'show', 'proxy']);
    final text = '${result.stdout}${result.stderr}';
    final match = RegExp(
      r'(?:代理服务器|Proxy Server\(s\))\s*[:：]\s*(\S+)',
    ).firstMatch(text);
    final normalized = parseProxyServer(match?.group(1));
    if (normalized != null) return normalized;
  } catch (_) {}
  return null;
}

String? _readEnvironmentProxy() {
  final env = Platform.environment;
  for (final key in [
    'https_proxy',
    'HTTPS_PROXY',
    'http_proxy',
    'HTTP_PROXY',
  ]) {
    final value = env[key];
    if (value != null && value.trim().isNotEmpty) {
      return parseProxyServer(value);
    }
  }
  return null;
}

/// 把系统代理值归一成 `host:port`。
/// 支持 `127.0.0.1:7890`、`http=127.0.0.1:7890;https=...`、
/// `http://127.0.0.1:7890/`；`socks=` 之类暂不支持，返回 null 保持直连。
String? parseProxyServer(String? raw) {
  if (raw == null) return null;
  var value = raw.trim();
  if (value.isEmpty) return null;
  if (value.contains('=')) {
    String? picked;
    for (final part in value.split(';')) {
      final entry = part.trim();
      if (entry.startsWith('http=')) {
        picked = entry.substring('http='.length);
        break;
      }
      if (entry.startsWith('https=')) {
        picked ??= entry.substring('https='.length);
      }
    }
    if (picked == null) return null;
    value = picked;
  }
  value = value.replaceFirst(RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'), '');
  value = value.split('/').first.trim();
  if (value.isEmpty || !value.contains(':')) return null;
  return value;
}

class _ProxyOverrides extends HttpOverrides {
  _ProxyOverrides(this.addr);
  final String addr;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = (uri) => 'PROXY $addr';
}

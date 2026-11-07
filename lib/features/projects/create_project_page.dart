import 'package:flit/l10n/strings.dart';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/page_layout.dart';
import '../../services/console_command.dart';
import '../../services/paths.dart';
import '../../services/shell.dart';

/// 新建项目参数(页面 → 工作台的返回值)
class CreateProjectParams {
  const CreateProjectParams({
    required this.type,
    required this.name,
    required this.org,
    required this.platforms,
    required this.empty,
    required this.androidLang,
    required this.description,
    required this.projectRoot,
    this.template = 'console',
  });

  final String type; // flutter | dart
  final String name;
  final String org;
  final List<String> platforms;
  final bool empty;
  final String androidLang; // kotlin | java
  final String description;
  final String projectRoot;
  final String template; // dart create 模板(console/package/server/web)
}

/// 组装 dart create 命令(纯 Dart 项目, console 模板可 dart run)。
/// --no-pub: 像 AS 一样把"生成文件"和"解析依赖"分开——前者瞬时、不联网, 退出 0
/// 即项目已存在; pub get 交给打开工程后的「获取依赖」任务, 中断也不会留下半成品。
String buildDartCreateCommand(CreateProjectParams p) {
  return "mkdir -p ${shQuote(p.projectRoot)} && cd ${shQuote(p.projectRoot)} && "
      "dart create --no-pub --template ${shQuote(p.template)} ${shQuote(p.name)}";
}

String buildFlutterCreateCommand(CreateProjectParams p) {
  final flags = <String>[
    '--platforms=${p.platforms.join(',')}',
    '--org ${shQuote(p.org)}',
    if (p.empty) '--empty',
    if (p.platforms.contains('android') && p.androidLang == 'java') '-a java',
  ];
  final desc = p.description.trim();
  if (desc.isNotEmpty) flags.add('--description ${shQuote(desc)}');
  return "mkdir -p ${shQuote(p.projectRoot)} && cd ${shQuote(p.projectRoot)} && "
      "flutter create --no-pub ${flags.join(' ')} ${shQuote(p.name)}";
}

/// 桌面端 flutter create 的参数数组：不拼 shell，也不再有 `mkdir -p` / `cd`
/// 前缀——目标目录由调用方用 Dart 建好（桌面没有 bash）。
List<String> flutterCreateArgs(CreateProjectParams p) => <String>[
  'create',
  '--no-pub',
  '--platforms=${p.platforms.join(',')}',
  '--org',
  p.org,
  if (p.empty) '--empty',
  if (p.platforms.contains('android') && p.androidLang == 'java') ...<String>[
    '-a',
    'java',
  ],
  if (p.description.trim().isNotEmpty) ...<String>[
    '--description',
    p.description.trim(),
  ],
  p.name,
];

/// 桌面端 dart create 的参数数组（见 [flutterCreateArgs]）。
List<String> dartCreateArgs(CreateProjectParams p) => <String>[
  'create',
  '--no-pub',
  '--template',
  p.template,
  p.name,
];

/// 桌面端执行"新建项目"的命令行（参数数组 → cmd 安全的单行命令）。
///
/// 目录已由调用方建好，所以这里没有 `cd`/`mkdir -p`；工具名交给 cmd 的
/// PATHEXT 解析（flutter.bat / dart.exe 都能找到）。Android 仍用
/// [buildDartCreateCommand] / [buildFlutterCreateCommand]（bash 包装）。
String buildDesktopCreateCommand(CreateProjectParams p) {
  final tool = p.type == 'dart' ? 'dart' : 'flutter';
  final args = p.type == 'dart' ? dartCreateArgs(p) : flutterCreateArgs(p);
  return '$tool ${args.map(_cmdArgument).join(' ')}';
}

/// 参数里只有空白/引号/cmd 元字符时才需要加引号。
String _cmdArgument(String value) =>
    RegExp(r'[\s"&|<>^%!]').hasMatch(value) ? quoteForCmd(value) : value;

/// dart 保留字/系统保留名: 用作包名会直接编译炸, 提前拦
const _reservedNames = {
  'flutter', 'dart', 'test', 'example', //
  'abstract', 'as', 'assert', 'async', 'await', 'break', 'case', 'catch',
  'class', 'const', 'continue', 'default', 'do', 'dynamic', 'else', 'enum',
  'export', 'extends', 'extension', 'external', 'factory', 'false', 'final',
  'finally', 'for', 'get', 'if', 'implements', 'import', 'in', 'interface',
  'is', 'library', 'mixin', 'new', 'null', 'on', 'operator', 'part',
  'required', 'rethrow', 'return', 'sealed', 'set', 'show', 'static',
  'super', 'switch', 'sync', 'this', 'throw', 'true', 'try', 'typedef',
  'var', 'void', 'while', 'with', 'yield',
};

/// 新建项目整页表单。
/// 替代原对话框: 秒开 + 异步预检进预览卡 + 完整 flutter create 参数,
/// 滚动/键盘由页面 Scaffold 兜底, 不再有对话框溢出一类问题。
class CreateProjectPage extends StatefulWidget {
  const CreateProjectPage({
    super.key,
    this.onOpenEnvironment,
    required this.projectRoot,
  });

  /// SDK 不可用时, "配置开发环境"按钮的出口(先 pop 本页再调)
  final VoidCallback? onOpenEnvironment;

  /// 工程根($HOME/projects), 新项目在其下创建
  final String projectRoot;

  @override
  State<CreateProjectPage> createState() => _CreateProjectPageState();
}

enum _ToolCheck { checking, ok, missing, broken }

class _CreateProjectPageState extends State<CreateProjectPage> {
  final _name = TextEditingController(text: 'my_app');
  final _org = TextEditingController(text: 'com.example');
  final _description = TextEditingController();
  String _type = 'flutter';
  String _template = 'console';
  final _platforms = <String>{'android'};
  bool _empty = false;
  String _androidLang = 'kotlin';
  _ToolCheck _tool = _ToolCheck.checking;
  String _toolDetail = '';
  String? _error;
  bool _submitting = false;
  int _checkSequence = 0;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    _name.dispose();
    _org.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final sequence = ++_checkSequence;
    final tool = _type;
    setState(() {
      _tool = _ToolCheck.checking;
      _toolDetail = '';
    });
    try {
      final (status, detail) = await _runToolCheck(tool);
      if (!mounted || sequence != _checkSequence) return;
      setState(() {
        _tool = status;
        _toolDetail = detail;
      });
    } catch (error) {
      if (!mounted || sequence != _checkSequence) return;
      setState(() {
        _tool = _ToolCheck.broken;
        _toolDetail = '$error';
      });
    }
  }

  /// 预检: 桌面端直接问 Shell.hasBinary/which（`command -v` 的 shim 在
  /// Windows 上对 .bat 会拼错后缀，不可靠），再用 cmd 跑一次 --version
  /// 证明"能找到且能执行"。
  Future<(_ToolCheck, String)> _runToolCheck(String tool) async {
    if (!isDesktopPlatform) {
      final result = await Shell.instance.exec(
        '${terminalEnvSource}command -v $tool >/dev/null 2>&1 || exit 127; $tool --version',
        timeoutMs: 120000,
      );
      return (
        switch (result['exitCode']) {
          0 => _ToolCheck.ok,
          127 => _ToolCheck.missing,
          _ => _ToolCheck.broken,
        },
        (result['output'] as String? ?? '').trim(),
      );
    }
    if (!Shell.instance.hasBinary(tool)) {
      return (_ToolCheck.missing, '');
    }
    // which() 在部分平台会把 .bat 拼成 .exe；拿不到真实文件就退回工具名，
    // 交给 cmd 的 PATHEXT / PATH 解析（flutter.bat 可执行）。
    var exe = Shell.instance.which(tool) ?? tool;
    if (!File(exe).existsSync()) exe = tool;
    final result = await Shell.instance.exec(
      '${quoteForCmd(exe)} --version',
      timeoutMs: 120000,
    );
    final output = (result['output'] as String? ?? '').trim();
    return result['exitCode'] == 0
        ? (_ToolCheck.ok, output)
        : (_ToolCheck.broken, output);
  }

  String? get _nameError {
    final name = _name.text.trim();
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name)) {
      return context.strings.startWithALowercaseLetterUseOnly;
    }
    if (_reservedNames.contains(name)) {
      return context.strings.dartReservedWordsAndToolNamesCannot;
    }
    return null;
  }

  String? get _orgError =>
      _org.text.trim().isEmpty ||
          RegExp(
            r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$',
          ).hasMatch(_org.text.trim())
      ? null
      : context.strings.useAReverseDomainNameSuchAs;
  bool get _valid =>
      _nameError == null &&
      (_type == 'dart' || _orgError == null && _platforms.isNotEmpty);

  Future<void> _submit() async {
    if (_submitting || !_valid || _tool != _ToolCheck.ok) return;
    final params = CreateProjectParams(
      type: _type,
      name: _name.text.trim(),
      org: _org.text.trim().isEmpty ? 'com.example' : _org.text.trim(),
      platforms: _platforms.toList(),
      empty: _empty,
      androidLang: _androidLang,
      description: _description.text.trim(),
      projectRoot: widget.projectRoot,
      template: _template,
    );
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final target = joinPath(widget.projectRoot, params.name);
      final bool? exists;
      if (isDesktopPlatform) {
        exists =
            FileSystemEntity.typeSync(target, followLinks: false) !=
            FileSystemEntityType.notFound;
      } else {
        final path = shQuote(target);
        final result = await Shell.instance.exec(
          '[ -e $path ] || [ -L $path ]',
          timeoutMs: 15000,
        );
        exists = switch (result['exitCode']) {
          0 => true,
          1 => false,
          _ => null,
        };
      }
      if (!mounted) return;
      if (exists == true) {
        setState(
          () => _error = context.strings.projectPAlreadyExistsChooseAnotherName(
            params.name,
          ),
        );
      } else if (exists == false) {
        Navigator.pop(context, params);
      } else {
        setState(
          () => _error =
              context.strings.unableToCheckDestinationCheckTheDevelopment146,
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = context.strings.projectPreflightFailedP(error));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.strings.newProject)),
    body: PageContent(
      child: Column(
        children: [
          Expanded(
            child: AbsorbPointer(
              absorbing: _submitting,
              child: ListView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  PageIntro(
                    context.strings.projectConfiguration,
                    context.strings.chooseTheProjectTypeNameAndTarget(
                      widget.projectRoot,
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                          value: 'flutter',
                          icon: Icon(Icons.flutter_dash),
                          label: Text('Flutter'),
                        ),
                        ButtonSegment(
                          value: 'dart',
                          icon: Icon(Icons.terminal),
                          label: Text('Dart'),
                        ),
                      ],
                      selected: {_type},
                      onSelectionChanged: (values) {
                        if (values.first == _type) return;
                        setState(() {
                          _type = values.first;
                          _error = null;
                        });
                        _check();
                      },
                    ),
                  ),
                  SectionLabel(context.strings.projectDetails),
                  SurfaceCard(
                    child: Column(
                      children: [
                        TextField(
                          controller: _name,
                          autocorrect: false,
                          onChanged: (_) => setState(() => _error = null),
                          decoration: InputDecoration(
                            labelText: context.strings.projectName,
                            hintText: 'my_app',
                            helperText: context
                                .strings
                                .lowercaseLettersNumbersAndUnderscores,
                            errorText: _nameError,
                            errorMaxLines: 2,
                          ),
                        ),
                        if (_type == 'flutter') ...[
                          const SizedBox(height: 16),
                          TextField(
                            controller: _org,
                            autocorrect: false,
                            onChanged: (_) => setState(() => _error = null),
                            decoration: InputDecoration(
                              labelText: context.strings.organizationOptional,
                              hintText: 'com.example',
                              errorText: _orgError,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  SectionLabel(
                    _type == 'flutter'
                        ? context.strings.targetPlatforms
                        : context.strings.projectTemplate,
                  ),
                  SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (_type == 'flutter')
                              for (final (value, label) in const [
                                ('android', 'Android'),
                                ('web', 'Web'),
                                ('ios', 'iOS'),
                                ('windows', 'Windows'),
                                ('macos', 'macOS'),
                                ('linux', 'Linux'),
                              ])
                                FilterChip(
                                  label: Text(label),
                                  selected: _platforms.contains(value),
                                  onSelected: (selected) => setState(() {
                                    selected
                                        ? _platforms.add(value)
                                        : _platforms.remove(value);
                                  }),
                                )
                            else
                              for (final (value, label) in [
                                ('console', context.strings.consoleApplication),
                                ('package', context.strings.dartPackage),
                                ('server', context.strings.serverApplication),
                                ('web', 'Web'),
                              ])
                                ChoiceChip(
                                  label: Text(label),
                                  selected: _template == value,
                                  onSelected: (_) =>
                                      setState(() => _template = value),
                                ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _type == 'dart'
                              ? context.strings.runConsoleProjectsUsingDartRunIn
                              : _platforms.isEmpty
                              ? context.strings.selectAtLeastOnePlatform
                              : context.strings.buildAndroidAndPreviewWebOnThis,
                          style: TextStyle(
                            color: _type == 'flutter' && _platforms.isEmpty
                                ? AppColors.danger
                                : AppColors.textSecondary,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_type == 'flutter') ...[
                    const SizedBox(height: 16),
                    SurfaceCard(
                      padding: EdgeInsets.zero,
                      child: ExpansionTile(
                        title: Text(context.strings.advancedSettings),
                        childrenPadding: const EdgeInsets.fromLTRB(
                          16,
                          0,
                          16,
                          16,
                        ),
                        children: [
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(context.strings.emptyProject),
                            subtitle: Text(
                              context.strings.excludeTheCounterExample,
                            ),
                            value: _empty,
                            onChanged: (value) =>
                                setState(() => _empty = value),
                          ),
                          if (_platforms.contains('android')) ...[
                            const SizedBox(height: 12),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                context.strings.androidSourceLanguage,
                              ),
                            ),
                            const SizedBox(height: 8),
                            SegmentedButton<String>(
                              segments: const [
                                ButtonSegment(
                                  value: 'kotlin',
                                  label: Text('Kotlin'),
                                ),
                                ButtonSegment(
                                  value: 'java',
                                  label: Text('Java'),
                                ),
                              ],
                              selected: {_androidLang},
                              onSelectionChanged: (values) =>
                                  setState(() => _androidLang = values.first),
                            ),
                          ],
                          const SizedBox(height: 16),
                          TextField(
                            controller: _description,
                            decoration: InputDecoration(
                              labelText:
                                  context.strings.projectDescriptionOptional,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  SectionLabel(context.strings.projectPreflight),
                  SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              _tool == _ToolCheck.ok
                                  ? Icons.check_circle_outline
                                  : Icons.build_circle_outlined,
                              color: _tool == _ToolCheck.ok
                                  ? AppColors.success
                                  : AppColors.accent,
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                '${_type == 'dart' ? 'Dart' : 'Flutter'} · ${switch (_tool) {
                                  _ToolCheck.checking => context.strings.checking,
                                  _ToolCheck.ok => context.strings.ready,
                                  _ToolCheck.missing => context.strings.notInstalled,
                                  _ToolCheck.broken => context.strings.cannotRun,
                                }}',
                              ),
                            ),
                            IconButton(
                              tooltip: context.strings.checkAgain,
                              onPressed: _tool == _ToolCheck.checking
                                  ? null
                                  : _check,
                              icon: const Icon(Icons.refresh, size: 20),
                            ),
                          ],
                        ),
                        if (_tool == _ToolCheck.checking)
                          const LinearProgressIndicator(),
                        if (_toolDetail.isNotEmpty)
                          Text(
                            _tool == _ToolCheck.ok
                                ? _toolDetail.split('\n').first
                                : _toolDetail,
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: _tool == _ToolCheck.broken
                                  ? AppColors.danger
                                  : AppColors.textSecondary,
                            ),
                          ),
                        if (_tool == _ToolCheck.missing ||
                            _tool == _ToolCheck.broken)
                          TextButton.icon(
                            onPressed: () {
                              Navigator.pop(context);
                              widget.onOpenEnvironment?.call();
                            },
                            icon: const Icon(Icons.open_in_new, size: 16),
                            label: Text(
                              context.strings.setUpDevelopmentEnvironment,
                            ),
                          ),
                        const Divider(height: 24),
                        Text(
                          context.strings.location,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          joinPath(widget.projectRoot, _name.text.trim()),
                          style: AppColors.mono,
                        ),
                      ],
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    StatusNotice(_error!, error: true),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _valid && _tool == _ToolCheck.ok && !_submitting
                    ? _submit
                    : null,
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(context.strings.createProject),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

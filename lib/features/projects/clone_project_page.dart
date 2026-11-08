import 'package:flit/l10n/strings.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/page_layout.dart';
import '../../core/theme.dart';
import '../../services/git_process.dart';
import '../../services/paths.dart';
import '../../services/shell.dart';
import '../git/github_account.dart';
import '../git/github_account_tile.dart';

/// 克隆参数(页面 → 工作台的返回值)
class CloneProjectParams {
  const CloneProjectParams({
    required this.url,
    required this.dirName,
    required this.branch,
    required this.shallow,
    required this.targetDir,
    this.preCloned = false,
  });

  final String url;
  final String dirName;
  final String branch;
  final bool shallow;

  /// 克隆目标目录(工程根 $HOME/projects)。
  final String targetDir;

  /// 桌面端：页面里已经用 Dart + GitProcess 真正克隆完了，工程列表侧的
  /// 终端任务只需跑一个空命令（Android 仍由终端会话执行 git clone）。
  final bool preCloned;

  CloneProjectParams copyWith({bool? preCloned}) => CloneProjectParams(
    url: url,
    dirName: dirName,
    branch: branch,
    shallow: shallow,
    targetDir: targetDir,
    preCloned: preCloned ?? this.preCloned,
  );
}

/// 从 URL 推导仓库名(目标目录默认值); 支持https/git@/ssh 形态
String repoNameFromUrl(String url) {
  final segs = url.trim().split('/').where((s) => s.isNotEmpty).toList();
  if (segs.isEmpty) return '';
  var seg = segs.last;
  if (seg.endsWith('.git')) seg = seg.substring(0, seg.length - 4);
  return seg;
}

/// 组装独立任务命令，保留 git 的真实退出码。
String buildGitCloneCommand(CloneProjectParams p) {
  // 桌面端克隆已在页面里用 Dart + GitProcess 完成，这里只返回一个空命令，
  // 让工程列表的「任务→完成→刷新列表」流程照旧走一遍。
  if (p.preCloned) return 'exit 0';
  final flags = <String>[];
  final branch = p.branch.trim();
  if (branch.isNotEmpty) flags.add('--branch ${shQuote(branch)}');
  if (p.shallow) flags.add('--depth 1');
  final flagStr = flags.isEmpty ? '' : '${flags.join(' ')} ';
  final dest = shQuote(p.targetDir);
  // GIT_TERMINAL_PROMPT=0: 只读会话里没人能输用户名/令牌, 未登录的私库
  // 让 git 立刻报错(先去登录 GitHub), 而不是挂在提示符上等输入
  return "mkdir -p $dest && cd $dest && GIT_TERMINAL_PROMPT=0 "
      "GIT_SSH_COMMAND=${shQuote('ssh -o BatchMode=yes -o StrictHostKeyChecking=yes')} git clone $flagStr"
      "${shQuote(p.url.trim())} ${shQuote(p.dirName)}";
}

/// 克隆 Git 仓库整页表单。
/// 克隆是临时会话(只读): 进度实时可见、可 ✕ 中止。私有仓库靠已保存的
/// GitHub 登录凭据(gh auth setup-git)非交互克隆, 未登录会被立即拒绝。
class CloneProjectPage extends StatefulWidget {
  const CloneProjectPage({
    super.key,
    this.onOpenEnvironment,
    required this.targetDir,
  });

  /// git 不可用时, "配置开发环境"按钮的出口(先 pop 本页再调)
  final VoidCallback? onOpenEnvironment;

  /// 克隆目标目录(工程根 $HOME/projects)。
  final String targetDir;

  @override
  State<CloneProjectPage> createState() => _CloneProjectPageState();
}

enum _GitCheck { checking, ok, missing, broken }

class _CloneProjectPageState extends State<CloneProjectPage> {
  final _urlCtrl = TextEditingController();
  final _dirCtrl = TextEditingController();
  final _branchCtrl = TextEditingController();
  bool _shallow = false;

  _GitCheck _git = _GitCheck.checking;
  String _gitVersion = '';
  String _gitDetail = '';
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _runPrecheck();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _dirCtrl.dispose();
    _branchCtrl.dispose();
    super.dispose();
  }

  /// git 预检: 未装 / 在(带版本)。
  Future<void> _runPrecheck() async {
    if (isDesktopPlatform) return _runDesktopPrecheck();
    try {
      final res = await Shell.instance.exec(
        '${terminalEnvSource}command -v git >/dev/null 2>&1 || exit 127; git --version',
        timeoutMs: 30000,
      );
      if (!mounted) return;
      setState(() {
        _git = switch (res['exitCode']) {
          0 => _GitCheck.ok,
          127 => _GitCheck.missing,
          _ => _GitCheck.broken,
        };
        _gitDetail = (res['output'] as String? ?? '').trim();
        _gitVersion = _gitDetail.split('\n').first;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _git = _GitCheck.broken;
          _gitDetail = '$error';
        });
      }
    }
  }

  /// 桌面端预检：不 spawn bash，直接问 GitProcess（MinGit / PATH git）。
  Future<void> _runDesktopPrecheck() async {
    try {
      final result = await GitProcess(
        Directory.current.path,
      ).run(['--version']);
      if (!mounted) return;
      setState(() {
        _git = result.code == 0 ? _GitCheck.ok : _GitCheck.missing;
        _gitDetail = result.out.trim();
        _gitVersion = _gitDetail.split('\n').first.trim();
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _git = _GitCheck.broken;
          _gitDetail = '$error';
        });
      }
    }
  }

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

  /// 桌面端 SSH 地址自动转 HTTPS 的提示。
  String? get _sshNotice =>
      isDesktopPlatform ? GitProcess.sshNotice(_url) : null;

  String get _url => _urlCtrl.text.trim();

  /// 目标目录: 留空则使用仓库名称
  String get _dirName {
    final custom = _dirCtrl.text.trim();
    return custom.isNotEmpty ? custom : repoNameFromUrl(_url);
  }

  bool get _formValid =>
      RegExp(r'^(https?://|git@|ssh://)\S+$').hasMatch(_url) &&
      RegExp(r'^[A-Za-z0-9_][A-Za-z0-9._-]*$').hasMatch(_dirName);

  bool get _canSubmit => _formValid && _git == _GitCheck.ok && !_submitting;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    final params = CloneProjectParams(
      // 桌面端 MinGit 不含 ssh.exe：git@github.com:owner/repo.git 自动转 HTTPS。
      url: isDesktopPlatform ? GitProcess.normalizeUrl(_url) : _url,
      dirName: _dirName,
      branch: _branchCtrl.text.trim(),
      shallow: _shallow,
      targetDir: widget.targetDir,
    );
    try {
      if (isDesktopPlatform) {
        await _submitDesktop(params);
        return;
      }
      final path = shQuote('${widget.targetDir}/${params.dirName}');
      final result = await Shell.instance.exec(
        '[ -e $path ] || [ -L $path ]',
        timeoutMs: 15000,
      );
      if (!mounted) return;
      if (result['exitCode'] == 0) {
        setState(
          () => _error = context.strings
              .pAlreadyExistsChooseAnotherDirectoryName(params.dirName),
        );
      } else if (result['exitCode'] == 1) {
        Navigator.pop(context, params);
      } else {
        setState(
          () => _error =
              context.strings.unableToCheckDestinationCheckTheDevelopment,
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = context.strings.clonePreflightFailedP(error));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 桌面端克隆：Dart 建目录 + GitProcess（argv，HTTPS，GIT_TERMINAL_PROMPT=0）。
  /// 成功后带 `preCloned: true` 返回，工程列表侧只做刷新。
  Future<void> _submitDesktop(CloneProjectParams params) async {
    final destination = joinPath(widget.targetDir, params.dirName);
    final exists =
        Directory(destination).existsSync() ||
        File(destination).existsSync() ||
        Link(destination).existsSync();
    if (exists) {
      setState(
        () => _error = context.strings.pAlreadyExistsChooseAnotherDirectoryName(
          params.dirName,
        ),
      );
      return;
    }
    try {
      Directory(widget.targetDir).createSync(recursive: true);
      final result = await GitProcess(widget.targetDir).clone(
        url: params.url,
        parentDirectory: widget.targetDir,
        directory: params.dirName,
        branch: params.branch,
        shallow: params.shallow,
      );
      if (!mounted) return;
      if (result.code != 0) {
        final detail = result.out.trim();
        setState(
          () => _error = detail.isEmpty
              ? context.strings.clonePreflightFailedP(result.code)
              : detail,
        );
        return;
      }
      Navigator.pop(context, params.copyWith(preCloned: true));
    } catch (error) {
      if (mounted) {
        setState(() => _error = context.strings.clonePreflightFailedP(error));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.strings.cloneRepository)),
      body: PageContent(
        child: Column(
          children: [
            Expanded(
              child: AbsorbPointer(
                absorbing: _submitting,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  children: [
                    PageIntro(
                      context.strings.getFromVersionControl,
                      context.strings.cloneARemoteRepositoryToLocalStorage,
                    ),
                    SectionLabel(context.strings.repository),
                    SurfaceCard(
                      child: Column(
                        children: [
                          TextField(
                            controller: _urlCtrl,
                            autocorrect: false,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                            ),
                            onChanged: (_) => setState(() => _error = null),
                            decoration: InputDecoration(
                              labelText: context.strings.repositoryUrl,
                              hintText: 'https://github.com/user/repo.git',
                            ),
                          ),
                          if (_sshNotice != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                _sshNotice!,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: AppColors.warn,
                                ),
                              ),
                            ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _dirCtrl,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                            ),
                            onChanged: (_) => setState(() => _error = null),
                            decoration: InputDecoration(
                              labelText: context.strings.directoryNameOptional,
                              hintText: context
                                  .strings
                                  .leaveEmptyToUseTheRepositoryName,
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _branchCtrl,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                            ),
                            decoration: InputDecoration(
                              labelText: context.strings.branchOptional,
                              hintText: context
                                  .strings
                                  .leaveEmptyToUseTheRemoteDefault,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    SurfaceCard(
                      child: SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          context.strings.shallowClone,
                          style: TextStyle(fontSize: 14),
                        ),
                        subtitle: Text(
                          context.strings.fetchOnlyTheLatestCommitUseGit,
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        value: _shallow,
                        onChanged: (v) => setState(() => _shallow = v),
                      ),
                    ),
                    SectionLabel(context.strings.clonePreflight),
                    SurfaceCard(child: _preview()),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          _error!,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.danger,
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      context.strings.signInToGithubBeforeCloningA,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    // 第一个项目就是私库时, 这里是唯一能登录的地方
                    const GithubAccountTile(dense: true),
                    // 桌面端没有 gh CLI：PAT 登录入口（见 GithubAccount.loginWithToken）
                    if (isDesktopPlatform)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _loginWithToken,
                          icon: const Icon(Icons.vpn_key_outlined, size: 16),
                          label: const Text(
                            '使用个人访问令牌（PAT）登录',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            _bottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _preview() {
    final Widget gitRow;
    switch (_git) {
      case _GitCheck.checking:
        gitRow = _previewRow(
          'Git',
          Row(
            children: [
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text(context.strings.checking, style: _valueStyle),
            ],
          ),
        );
      case _GitCheck.ok:
        gitRow = _previewRow(
          'Git',
          Text(
            _gitVersion.isEmpty ? context.strings.ready : _gitVersion,
            style: _valueStyle,
          ),
        );
      case _GitCheck.missing || _GitCheck.broken:
        gitRow = _previewRow(
          'Git',
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _git == _GitCheck.missing
                    ? context.strings.gitNotFoundCheckItsInstallationAnd
                    : context.strings.unableToRunP(_gitDetail),
                style: const TextStyle(fontSize: 12, color: AppColors.danger),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () {
                  Navigator.pop(context);
                  widget.onOpenEnvironment?.call();
                },
                icon: const Icon(Icons.build_circle_outlined, size: 15),
                label: Text(
                  context.strings.setUpDevelopmentEnvironment,
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        gitRow,
        _previewRow(
          context.strings.location,
          Text(
            _dirName.isEmpty ? '-' : joinPath(widget.targetDir, _dirName),
            style: _valueStyle,
          ),
        ),
      ],
    );
  }

  TextStyle get _valueStyle => const TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    color: AppColors.textPrimary,
  );

  Widget _previewRow(String label, Widget value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 76,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ),
        Expanded(child: value),
      ],
    ),
  );

  Widget _bottomBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: FilledButton(
          onPressed: _canSubmit ? _submit : null,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(
                  context.strings.cloneRepository,
                  style: TextStyle(fontSize: 15),
                ),
        ),
      ),
    );
  }
}

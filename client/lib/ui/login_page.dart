import 'dart:convert';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../core/error_messages.dart';

import '../core/api_client.dart';
import '../core/crypto_service.dart';
import '../main.dart' show kBuildMarker;
import '../core/recovery_service.dart';
import '../core/session_store.dart';

/// 登录页：填服务器地址 + 账号密码。
/// 首次打开会预填本机服务端地址，方便直接开始用。
class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.store,
    required this.initial,
    required this.onLoggedIn,
  });

  final SessionStore store;
  final Session? initial;
  final Future<void> Function(Session session, ApiClient api) onLoggedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final TextEditingController _server;
  late final TextEditingController _username;
  final _password = TextEditingController();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();

  bool _busy = false;
  bool? _serverReachable;
  String? _error;
  Map<String, dynamic>? _diagnosis;

  @override
  void initState() {
    super.initState();
    _server = TextEditingController(text: widget.initial?.baseUrl ?? 'http://127.0.0.1:8080');
    _username = TextEditingController(text: widget.initial?.username ?? '');
    _checkServer();
  }

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _checkServer() async {
    final api = ApiClient(baseUrl: _server.text.trim());
    final ok = await api.health();
    final diagnosis = await api.diagnose();
    api.close();
    if (!mounted) return;
    setState(() {
      _serverReachable = ok;
      _diagnosis = diagnosis;
    });
  }

  /// 把诊断结果压成一行，贴在错误信息下面，方便截图
  String _diagnosisLine(Map<String, dynamic> d) {
    if (d['error'] != null) {
      return '诊断：请求 /healthz 失败（${d['type']}，${d['ms']}ms）：${d['error']}';
    }
    return '诊断：/healthz 返回 HTTP ${d['status']}，类型 ${d['contentType']}，'
        '${d['ms']}ms，内容开头「${d['body']}」';
  }

  Future<void> _showDiagnosis() async {
    final d = _diagnosis;
    if (d == null) {
      await _checkServer();
    }
    if (!mounted) return;
    final data = _diagnosis;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('网络诊断'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('服务器地址：${_server.text.trim()}',
                  style: Theme.of(dialogContext).textTheme.bodySmall),
              const SizedBox(height: 8),
              SelectableText(
                data == null ? '还没有诊断结果' : _diagnosisLine(data),
                style: Theme.of(dialogContext).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              const Text(
                '如果这里不是 {"status":"ok"}，说明手机拿到的不是接口数据：\n'
                '· 内容像网页 → 被 WiFi 登录页 / 代理 / VPN 劫持\n'
                '· 请求失败 → 网络不通或端口被拦\n'
                '· 有 content-type: text/html 就是最典型的代理页面',
                style: TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('关闭')),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _checkServer();
            },
            child: const Text('重新检测'),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final username = _username.text.trim();
    final password = _password.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = '请输入用户名和密码');
      (username.isEmpty ? _usernameFocus : _passwordFocus).requestFocus();
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    final baseUrl = _server.text.trim();
    final api = ApiClient(baseUrl: baseUrl);
    try {
      final result = await api.login(
        username: username,
        password: password,
        deviceName: '${defaultTargetPlatform == TargetPlatform.windows ? 'Windows' : 'Android'} 客户端',
        platform: defaultTargetPlatform == TargetPlatform.windows ? 'windows' : 'android',
      );

      // 端到端加密：密码只用来派生 KEK，真正加密数据的是一把独立的主密钥，
      // 它以「被 KEK 包裹」的形式存在服务端。这样改密码只需要重新包裹，
      // 历史数据不会解不开；新设备登录拉到包裹体、解开即得同一把主密钥。
      var salt = result.kdfSalt;
      if (salt == null || salt.isEmpty) {
        salt = CryptoService.generateSalt();
        try {
          await api.setKdfSalt(salt: salt, iterations: result.kdfIterations);
        } catch (_) {
          // 服务端已有盐（另一台设备先设过）时忽略，后续以服务端为准
        }
      }
      final kek = await CryptoService.derive(
        password: password,
        saltBase64: salt,
        iterations: result.kdfIterations,
      );

      String? wrapB64;
      String? wrapNonce;
      try {
        final remote = await api.getKeyWrap();
        wrapB64 = remote['wrap'] as String?;
        wrapNonce = remote['nonce'] as String?;
      } catch (_) {
        // 拉不到就走下面的首次包裹分支
      }

      List<int> masterBytes;
      if (wrapB64 != null && wrapB64.isNotEmpty && wrapNonce != null && wrapNonce.isNotEmpty) {
        // 老用户 / 新设备：解开包裹体，得到同一把主密钥
        masterBytes = await kek.unwrapMasterKey(
          cipher: base64Decode(wrapB64),
          nonce: base64Decode(wrapNonce),
        );
      } else {
        // 首次启用：沿用密码派生的密钥作为主密钥（兼容已加密的历史数据），
        // 并立刻包裹上传，之后密码与数据密钥就解耦了。
        masterBytes = await kek.exportKeyBytes();
        try {
          final sealedWrap = await kek.wrapMasterKey(masterBytes);
          await api.putKeyWrap(wrap: sealedWrap.cipherBase64, nonce: sealedWrap.nonceBase64);
        } catch (_) {
          // 上传失败不阻塞登录，下次登录会再试
        }
      }
      final keyB64 = base64Encode(masterBytes);

      final previous = widget.initial;
      final session = Session(
        baseUrl: baseUrl,
        accessToken: result.accessToken,
        refreshToken: result.refreshToken,
        deviceId: result.deviceId,
        username: result.username,
        lastHlc: previous?.lastHlc,
        keyB64: keyB64,
        kdfSalt: salt,
        kdfIterations: result.kdfIterations,
      );
      await widget.onLoggedIn(session, api);
    } on ApiException catch (e) {
      final diagnosis = await api.diagnose();
      api.close();
      if (!mounted) return;
      setState(() {
        _error = '${e.message}\n${_diagnosisLine(diagnosis)}';
        _diagnosis = diagnosis;
        _serverReachable = diagnosis['ok'] == true;
      });
    } catch (e) {
      final diagnosis = await api.diagnose();
      api.close();
      if (!mounted) return;
      setState(() {
        _error = '登录失败：${describeError(e)}（${e.runtimeType}）\n${_diagnosisLine(diagnosis)}';
        _diagnosis = diagnosis;
        _serverReachable = diagnosis['ok'] == true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------ 忘记密码

  Future<void> _showRecoverDialog() async {
    final usernameCtrl = TextEditingController(text: _username.text.trim());
    final wordsCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();
    String? error;
    var busy = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('用恢复短语找回'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('输入账号、16 个恢复词和新密码。\n旧密码会被覆盖，日记内容不受影响。'),
                const SizedBox(height: 12),
                TextField(
                  controller: usernameCtrl,
                  decoration: const InputDecoration(labelText: '用户名'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: wordsCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: '16 个恢复词',
                    hintText: '用空格分隔，顺序不能错',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: passwordCtrl,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '新密码（至少 8 位）'),
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!, style: TextStyle(color: Theme.of(dialogContext).colorScheme.error)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('取消')),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      final words = wordsCtrl.text
                          .split(RegExp(r'[\s,，]+'))
                          .map((w) => w.trim())
                          .where((w) => w.isNotEmpty)
                          .toList();
                      if (words.length != 16) {
                        setDialogState(() => error = '恢复短语应为 16 个词，当前 ${words.length} 个');
                        return;
                      }
                      if (passwordCtrl.text.length < 8) {
                        setDialogState(() => error = '新密码至少 8 位');
                        return;
                      }
                      setDialogState(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        final api = ApiClient(baseUrl: _server.text.trim());
                        await RecoveryService(api: api).recover(
                          username: usernameCtrl.text.trim(),
                          words: words,
                          newPassword: passwordCtrl.text,
                        );
                        api.close();
                        if (!dialogContext.mounted) return;
                        Navigator.of(dialogContext).pop();
                        if (!mounted) return;
                        setState(() {
                          _username.text = usernameCtrl.text.trim();
                          _password.text = passwordCtrl.text;
                          _error = '密码已重置，可以直接登录';
                        });
                      } catch (e) {
                        setDialogState(() {
                          busy = false;
                          error = '恢复失败：${describeError(e)}';
                        });
                      }
                    },
              child: busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('恢复并设置新密码'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('日记', style: theme.textTheme.displaySmall, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(
                  '本地优先 · 多设备同步 · 媒体原位混排',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),
                TextField(
                  controller: _server,
                  decoration: InputDecoration(
                    labelText: '服务器地址',
                    helperText: _serverReachable == null
                        ? '正在检查…'
                        : (_serverReachable! ? '服务器可连接' : '服务器无响应，请检查地址'),
                    helperStyle: TextStyle(
                      color: _serverReachable == true
                          ? Colors.green.shade600
                          : (_serverReachable == false ? theme.colorScheme.error : null),
                    ),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.refresh),
                      onPressed: _checkServer,
                      tooltip: '重新检查',
                    ),
                  ),
                  onSubmitted: (_) => _checkServer(),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _username,
                  focusNode: _usernameFocus,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: '用户名'),
                  autofillHints: const [AutofillHints.username],
                  onSubmitted: (_) => _passwordFocus.requestFocus(),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _password,
                  focusNode: _passwordFocus,
                  decoration: const InputDecoration(labelText: '密码'),
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 24),
                if (_error != null) ...[
                  SelectableText(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _showDiagnosis,
                    icon: const Icon(Icons.network_check, size: 18),
                    label: const Text('网络诊断'),
                  ),
                  const SizedBox(height: 8),
                ],
                TextButton(
                  onPressed: _busy ? null : _showRecoverDialog,
                  child: const Text('忘记密码？用恢复短语找回'),
                ),
                const SizedBox(height: 6),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                  child: _busy
                      ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('登录'),
                ),
                const SizedBox(height: 10),
                Text(
                  kBuildMarker,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

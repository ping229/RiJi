import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'core/api_client.dart';
import 'core/crypto_service.dart';
import 'core/local_store.dart';
import 'core/session_store.dart';
import 'core/sync_service.dart';
import 'dev/device_selftest.dart';
import 'dev/media_selftest.dart';
import 'ui/home_page.dart';
import 'ui/login_page.dart';

/// 构建标记：用于确认"跑起来的程序是不是刚编译的这一版"
const String kBuildMarker = 'BUILD-39-0114';

void main(List<String> args) {
  _trace('main 进入，构建标记 $kBuildMarker');
  final selftest = _parseFlag(args, '--selftest=');
  if (selftest != null) {
    WidgetsFlutterBinding.ensureInitialized();
    runMediaSelfTest(selftest).then((code) => exit(code));
    return;
  }
  // 设备诊断：摄像头/麦克风能不能用，底层报什么错
  if (args.contains('--devicetest')) {
    WidgetsFlutterBinding.ensureInitialized();
    runDeviceTest().then((code) => exit(code));
    return;
  }
  runApp(RijiApp(initialDiaryDate: _parseDiaryArg(args)));
}

/// 启动追踪：写到系统临时目录，确认代码真的跑到这里
void _trace(String message) {
  final stamp = DateTime.now().toIso8601String();
  // 同时写三个位置：exe 同目录、临时目录、用户目录。
  // 只要有一个成功就够定位问题；失败也把原因写进下一个候选。
  final targets = <String>[
    '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}riji-boot.log',
    '${Directory.systemTemp.path}${Platform.pathSeparator}riji-boot.log',
    '${Platform.environment['USERPROFILE'] ?? '.'}${Platform.pathSeparator}riji-boot.log',
  ];
  final errors = StringBuffer();
  for (final target in targets) {
    try {
      File(target).writeAsStringSync('$stamp $message\n', mode: FileMode.append, flush: true);
      return;
    } catch (e) {
      errors.write('[$target: $e] ');
    }
  }
  // 全失败时至少留在 exe 目录一个错误文件（用不同名字，避免与日志冲突）
  try {
    File('${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}riji-boot-error.txt')
        .writeAsStringSync('$stamp $message\n写入失败：$errors', flush: true);
  } catch (_) {
    // 彻底无法记录
  }
}

String? _parseFlag(List<String> args, String prefix) {
  for (final arg in args) {
    if (arg.startsWith(prefix)) return arg.substring(prefix.length);
  }
  return null;
}

/// 支持 `--diary=2026-11-03` 直接打开某一天的日记，便于做桌面快捷方式
String? _parseDiaryArg(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('--diary=')) {
      final value = arg.substring('--diary='.length);
      if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return value;
    }
  }
  return null;
}

class RijiApp extends StatefulWidget {
  const RijiApp({super.key, this.initialDiaryDate});

  final String? initialDiaryDate;

  @override
  State<RijiApp> createState() => _RijiAppState();
}

class _RijiAppState extends State<RijiApp> {
  SessionStore? _store;
  LocalStore? _local;
  SyncService? _sync;
  Session? _session;
  ApiClient? _api;
  bool _booting = true;
  String? _bootError;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final store = await SessionStore.open();
      // 先读会话，再按账号打开对应的本地缓存目录
      final saved = await store.load();
      final local = await LocalStore.open(store.dir, account: saved?.username);
      if (!mounted) return;

      if (saved != null && saved.isLoggedIn) {
        final api = ApiClient(baseUrl: saved.baseUrl)
          ..accessToken = saved.accessToken
          ..refreshToken = saved.refreshToken
          ..deviceId = saved.deviceId;
        setState(() {
          _store = store;
          _local = local;
          _sync = SyncService(api: api, store: local, crypto: _restoreCrypto(saved));
          _session = saved;
          _api = api;
          _booting = false;
        });
      } else {
        setState(() {
          _store = store;
          _local = local;
          _session = saved;
          _api = null;
          _booting = false;
        });
      }
    } catch (e, stack) {
      debugPrint('启动失败: $e\n$stack');
      if (!mounted) return;
      setState(() {
        _bootError = '$e';
        _booting = false;
      });
    }
  }

  Future<void> _onLoggedIn(Session session, ApiClient api) async {
    final local = _local ?? await LocalStore.open(_store!.dir);
    await _store!.save(session);
    setState(() {
      _local = local;
      _sync = SyncService(api: api, store: local, crypto: _restoreCrypto(session));
      _session = session;
      _api = api;
    });
  }

  Future<void> _logout() async {
    await _store!.clear();
    _api?.close();
    setState(() {
      _session = null;
      _api = null;
    });
  }

  /// 从会话里恢复主密钥；没启用加密的账号返回 null
  CryptoService? _restoreCrypto(Session? session) {
    final raw = session?.keyB64;
    if (raw == null || raw.isEmpty) return null;
    try {
      return CryptoService.fromBytes(base64Decode(raw));
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '日记',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: _booting
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : (_bootError != null
              ? Scaffold(
                  body: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline, size: 48),
                          const SizedBox(height: 16),
                          const Text('客户端启动失败'),
                          const SizedBox(height: 8),
                          SelectableText(_bootError!, textAlign: TextAlign.center),
                        ],
                      ),
                    ),
                  ),
                )
              : (_api == null || _session == null || _store == null || _local == null
                  ? LoginPage(
                      store: _store!,
                      initial: _session,
                      onLoggedIn: _onLoggedIn,
                    )
                  : HomePage(
                      api: _api!,
                      session: _session!,
                      local: _local!,
                      sync: _sync ?? SyncService(api: _api!, store: _local!),
                      initialDiaryDate: widget.initialDiaryDate,
                      onLogout: _logout,
                      onSessionChanged: (s) => _store!.save(s),
                    ))),
    );
  }
}

ThemeData buildTheme(Brightness brightness) {
  final seed = const Color(0xFF6B7F5E);
  final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: brightness == Brightness.light ? const Color(0xFFFAF8F3) : null,
    fontFamilyFallback: const ['Microsoft YaHei', 'Segoe UI', 'Noto Sans SC'],
    inputDecorationTheme: const InputDecorationTheme(
      border: OutlineInputBorder(),
      isDense: true,
    ),
  );
}

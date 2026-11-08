/// 会话持久化：登录状态、服务器地址、设备 ID、HLC 时钟状态。
///
/// 存放位置按优先级回退：应用支持目录 → %APPDATA%\RiJi → %LOCALAPPDATA%\RiJi → 可执行文件同级 data 目录。
/// 某些受限环境（企业策略、受控文件夹访问）会拒绝第一个位置，回退保证应用仍能启动。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class Session {
  Session({
    required this.baseUrl,
    this.accessToken,
    this.refreshToken,
    this.deviceId,
    this.username,
    this.lastHlc,
    this.keyB64,
    this.kdfSalt,
    this.kdfIterations = 210000,
  });

  String baseUrl;
  String? accessToken;
  String? refreshToken;
  String? deviceId;
  String? username;

  /// 上次使用的 HLC 编码，重启后继续单调递增
  String? lastHlc;

  /// 端到端加密主密钥（base64）。仅存本机，永不上传。
  String? keyB64;

  /// 密钥派生盐与迭代次数（与服务端一致）
  String? kdfSalt;
  int kdfIterations;

  bool get isLoggedIn => (accessToken ?? '').isNotEmpty;

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'deviceId': deviceId,
        'username': username,
        'lastHlc': lastHlc,
        'keyB64': keyB64,
        'kdfSalt': kdfSalt,
        'kdfIterations': kdfIterations,
      };

  static Session fromJson(Map<String, dynamic> json) => Session(
        baseUrl: json['baseUrl'] as String? ?? 'http://127.0.0.1:8080',
        accessToken: json['accessToken'] as String?,
        refreshToken: json['refreshToken'] as String?,
        deviceId: json['deviceId'] as String?,
        username: json['username'] as String?,
        lastHlc: json['lastHlc'] as String?,
        keyB64: json['keyB64'] as String?,
        kdfSalt: json['kdfSalt'] as String?,
        kdfIterations: (json['kdfIterations'] as num?)?.toInt() ?? 210000,
      );

  Session copy() => Session(
        baseUrl: baseUrl,
        accessToken: accessToken,
        refreshToken: refreshToken,
        deviceId: deviceId,
        username: username,
        lastHlc: lastHlc,
      );
}

class SessionStore {
  SessionStore._(this.dir);

  /// 实际使用的数据目录
  final Directory dir;

  File get _file => File('${dir.path}${Platform.pathSeparator}session.json');

  /// 供自检与故障排查显示会话文件位置
  String get debugPath => _file.path;

  /// 测试用：直接指定数据目录，跳过环境探测与迁移。
  /// 生产代码请用 open()，它会处理回退与迁移。
  SessionStore.at(Directory directory) : dir = directory;

  static Future<SessionStore> open() async {
    final dir = await _resolveDataDir();
    return SessionStore._(dir);
  }

  /// 启动诊断日志：写到系统临时目录，失败也不影响主流程。
  /// 数据目录选错是"用户找不到日记"级别的故障，必须能自证。
  static void _bootLog(String message) {
    final stamp = DateTime.now().toIso8601String();
    // 优先写 exe 同目录：临时目录在某些受限进程里会静默失败
    final targets = <String>[
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}riji-boot.log',
      '${Directory.systemTemp.path}${Platform.pathSeparator}riji-boot.log',
    ];
    for (final target in targets) {
      try {
        File(target).writeAsStringSync('$stamp [data] $message\n', mode: FileMode.append, flush: true);
        return;
      } catch (_) {
        // 换下一个位置
      }
    }
  }

  static Future<Directory> _resolveDataDir() async {
    // 顺序是刻意的：先选"用户能找到、路径稳定"的位置。
    // 之前把系统推荐目录放在最前面，结果在不同机器上会落到安装目录旁的 data/，
    // 用户根本找不到自己的日记。现在优先固定路径，并把最终位置显示在自检页里。
    final candidates = <Future<Directory> Function()>[
      () async {
        final base = Platform.environment['APPDATA'];
        if (base == null || base.isEmpty) throw StateError('无 APPDATA');
        return Directory('$base${Platform.pathSeparator}RiJi');
      },
      () async {
        final base = Platform.environment['LOCALAPPDATA'];
        if (base == null || base.isEmpty) throw StateError('无 LOCALAPPDATA');
        return Directory('$base${Platform.pathSeparator}RiJi');
      },
      () async => getApplicationSupportDirectory(),
      () async {
        final exeDir = File(Platform.resolvedExecutable).parent;
        return Directory('${exeDir.path}${Platform.pathSeparator}data');
      },
    ];

    Object? lastError;
    for (final candidate in candidates) {
      Directory dir;
      try {
        dir = await candidate();
      } catch (e) {
        _bootLog('候选目录无法解析：$e');
        lastError = e;
        continue;
      }
      try {
        final verified = await _verifiedWritable(dir);
        await _migrateOldData(verified);
        _bootLog('选用数据目录：${verified.path}');
        return verified;
      } catch (e) {
        _bootLog('候选目录不可用 ${dir.path}：$e');
        lastError = e;
      }
    }
    throw StateError('无法确定可写的数据目录：$lastError');
  }

  /// 旧版本可能把数据放在别的目录里。首次使用时把找到的旧数据搬过来，
  /// 避免升级后"日记不见了"。只在新目录还没有会话时执行。
  static Future<void> _migrateOldData(Directory target) async {
    final targetSession = File('${target.path}${Platform.pathSeparator}session.json');
    if (await targetSession.exists()) return;

    final legacy = <Directory>[];
    try {
      legacy.add(await getApplicationSupportDirectory());
    } catch (_) {
      // 拿不到就算了
    }
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      legacy.add(Directory('${exeDir.path}${Platform.pathSeparator}data'));
    } catch (_) {
      // 忽略
    }

    for (final dir in legacy) {
      if (dir.path == target.path) continue;
      final session = File('${dir.path}${Platform.pathSeparator}session.json');
      if (!await session.exists()) continue;
      try {
        await session.copy(targetSession.path);
        // 顺带把本地日记与媒体搬过去
        for (final name in ['diary', 'media']) {
          final from = Directory('${dir.path}${Platform.pathSeparator}$name');
          if (await from.exists()) {
            await _copyDirectory(from, Directory('${target.path}${Platform.pathSeparator}$name'));
          }
        }
        return;
      } catch (_) {
        // 迁移失败就用空目录，不阻塞启动
      }
    }
  }

  static Future<void> _copyDirectory(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final entity in from.list(recursive: true)) {
      if (entity is! File) continue;
      final relative = entity.path.substring(from.path.length + 1);
      final dest = File('${to.path}${Platform.pathSeparator}$relative');
      await dest.parent.create(recursive: true);
      await entity.copy(dest.path);
    }
  }

  /// 目录存在不代表能写：有些受限环境允许创建目录却拒绝写文件。
  /// 必须真正写一个探针文件才能确认可用。
  static Future<Directory> _verifiedWritable(Directory dir) async {
    await dir.create(recursive: true);
    final probe = File('${dir.path}${Platform.pathSeparator}.write-probe');
    await probe.writeAsString('ok', flush: true);
    await probe.delete();
    return dir;
  }

  Future<Session?> load() async {
    try {
      if (!await _file.exists()) return null;
      final raw = await _file.readAsString();
      if (raw.trim().isEmpty) return null;
      return Session.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(Session session) async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(jsonEncode(session.toJson()), flush: true);
    await tmp.rename(_file.path);
  }

  Future<void> clear() async {
    if (await _file.exists()) await _file.delete();
  }

  /// 媒体缓存目录（下载过的图片/语音/视频存在这里，避免重复下载）
  Future<Directory> mediaCacheDir() async {
    final media = Directory('${dir.path}${Platform.pathSeparator}media');
    await media.create(recursive: true);
    return media;
  }
}

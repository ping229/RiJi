/// HTTP 客户端：所有与服务端的通信都从这里走。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.code, this.message);

  final int statusCode;
  final String code;
  final String message;

  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => message;
}

class ApiClient {
  ApiClient({required String baseUrl, http.Client? httpClient})
      : baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl,
        _http = httpClient ?? http.Client();

  final String baseUrl;
  final http.Client _http;

  String? accessToken;
  String? refreshToken;
  String? deviceId;

  void close() => _http.close();

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Map<String, String> _headers({bool json = true}) {
    final headers = <String, String>{};
    if (json) headers['content-type'] = 'application/json';
    if (accessToken != null) headers['authorization'] = 'Bearer $accessToken';
    return headers;
  }

  Never _throwFrom(http.Response res) {
    Map<String, dynamic> body = const {};
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {
      // 非 JSON 响应，保留原始文本
    }
    final error = body['error'];
    if (error is Map<String, dynamic>) {
      throw ApiException(
        res.statusCode,
        error['code'] as String? ?? 'UNKNOWN',
        error['message'] as String? ?? '请求失败（${res.statusCode}）',
      );
    }
    throw ApiException(res.statusCode, 'UNKNOWN', '请求失败（${res.statusCode}）');
  }

  dynamic _decode(http.Response res) {
    if (res.statusCode >= 400) _throwFrom(res);
    if (res.bodyBytes.isEmpty) return null;
    return jsonDecode(utf8.decode(res.bodyBytes));
  }

  Future<void> _refreshIfPossible() async {
    if (refreshToken == null) return;
    final res = await _http.post(
      _uri('/api/auth/refresh'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'refreshToken': refreshToken}),
    );
    if (res.statusCode >= 400) return;
    final body = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    accessToken = body['accessToken'] as String?;
    refreshToken = body['refreshToken'] as String?;
  }

  Future<http.Response> _authedSend(Future<http.Response> Function() send) async {
    var res = await send();
    if (res.statusCode == 401 && refreshToken != null) {
      await _refreshIfPossible();
      res = await send();
    }
    return res;
  }

  Future<LoginResult> login({
    required String username,
    required String password,
    required String deviceName,
    required String platform,
  }) async {
    final res = await _http.post(
      _uri('/api/auth/login'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'password': password,
        'device': {'name': deviceName, 'platform': platform},
      }),
    );
    final body = _decode(res) as Map<String, dynamic>;
    final result = LoginResult.fromJson(body);
    accessToken = result.accessToken;
    refreshToken = result.refreshToken;
    deviceId = result.deviceId;
    return result;
  }

  /// 修改密码：服务端校验旧密码，并用新的包裹体替换旧的
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
    required String keyWrap,
    required String keyWrapNonce,
  }) async {
    final res = await _http.post(
      _uri('/api/auth/change-password'),
      headers: _headers(),
      body: jsonEncode({
        'currentPassword': currentPassword,
        'newPassword': newPassword,
        'keyWrap': keyWrap,
        'keyWrapNonce': keyWrapNonce,
      }),
    );
    _decode(res);
  }

  /// 是否已设置恢复短语
  Future<bool> hasRecovery() async {
    final res = await _authedSend(
      () => _http.get(_uri('/api/auth/recovery-wrap'), headers: _headers(json: false)),
    );
    final body = _decode(res) as Map<String, dynamic>;
    return body['hasRecovery'] as bool? ?? false;
  }

  /// 上传恢复短语对应的包裹体
  Future<void> putRecoveryWrap({
    required String wrap,
    required String nonce,
    required String proof,
  }) async {
    final res = await _authedSend(
      () => _http.put(
        _uri('/api/auth/recovery-wrap'),
        headers: _headers(),
        body: jsonEncode({'wrap': wrap, 'nonce': nonce, 'proof': proof}),
      ),
    );
    _decode(res);
  }

  /// 忘记密码：取恢复所需信息（未登录也可调用）
  Future<Map<String, dynamic>> recoverStart(String username) async {
    final res = await _http.post(
      _uri('/api/auth/recover/start'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'username': username}),
    );
    return _decode(res) as Map<String, dynamic>;
  }

  /// 忘记密码：用恢复短语证明身份并设置新密码
  Future<void> recoverComplete({
    required String username,
    required String proof,
    required String newPassword,
    required String keyWrap,
    required String keyWrapNonce,
  }) async {
    final res = await _http.post(
      _uri('/api/auth/recover/complete'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'proof': proof,
        'newPassword': newPassword,
        'keyWrap': keyWrap,
        'keyWrapNonce': keyWrapNonce,
      }),
    );
    _decode(res);
  }

  /// 拉取主密钥包裹体（服务端只有密文）
  Future<Map<String, dynamic>> getKeyWrap() async {
    final res = await _authedSend(
      () => _http.get(_uri('/api/auth/key-wrap'), headers: _headers(json: false)),
    );
    return _decode(res) as Map<String, dynamic>;
  }

  /// 上传主密钥包裹体（改密码时用新 KEK 覆盖）
  Future<void> putKeyWrap({required String wrap, required String nonce}) async {
    final res = await _authedSend(
      () => _http.put(
        _uri('/api/auth/key-wrap'),
        headers: _headers(),
        body: jsonEncode({'wrap': wrap, 'nonce': nonce}),
      ),
    );
    _decode(res);
  }

  /// 首次启用端到端加密时提交派生的盐（盐本身不是秘密）
  Future<void> setKdfSalt({required String salt, required int iterations}) async {
    final res = await _authedSend(
      () => _http.post(
        _uri('/api/auth/kdf-salt'),
        headers: _headers(),
        body: jsonEncode({'salt': salt, 'iterations': iterations}),
      ),
    );
    _decode(res);
  }

  Future<Map<String, dynamic>> me() async {
    final res = await _authedSend(
      () => _http.get(_uri('/api/auth/me'), headers: _headers(json: false)),
    );
    return _decode(res) as Map<String, dynamic>;
  }

  Future<CalendarWindow> calendar() async {
    final res = await _authedSend(
      () => _http.get(_uri('/api/calendar'), headers: _headers(json: false)),
    );
    return CalendarWindow.fromJson(_decode(res) as Map<String, dynamic>);
  }

  Future<List<DiarySummary>> listDiaries({required String from, required String to}) async {
    final res = await _authedSend(
      () => _http.get(_uri('/api/diaries', {'from': from, 'to': to}), headers: _headers(json: false)),
    );
    final body = _decode(res) as Map<String, dynamic>;
    return (body['diaries'] as List<dynamic>)
        .map((e) => DiarySummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 返回 null 表示这一天还没写过日记（服务端 404）
  Future<DiaryDetail?> getDiary(String date) async {
    final res = await _authedSend(
      () => _http.get(_uri('/api/diaries/$date'), headers: _headers(json: false)),
    );
    if (res.statusCode == 404) return null;
    final body = _decode(res) as Map<String, dynamic>;
    return DiaryDetail(
      diary: DiarySummary.fromJson(body['diary'] as Map<String, dynamic>),
      blocks: (body['blocks'] as List<dynamic>)
          .map((e) => Block.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Future<WriteResult> writeBatch({
    required String date,
    required String tzId,
    required List<Block> operations,
  }) async {
    final res = await _authedSend(
      () => _http.post(
        _uri('/api/diaries/$date/batch'),
        headers: _headers(),
        body: jsonEncode({
          'tzId': tzId,
          'clientNow': DateTime.now().toUtc().toIso8601String(),
          'deviceId': deviceId,
          'operations': operations.map((b) => b.toWire()).toList(),
        }),
      ),
    );
    return WriteResult.fromJson(_decode(res) as Map<String, dynamic>);
  }

  Future<void> deleteBlock({
    required String date,
    required String blockId,
    required Map<String, int> vv,
    required String hlc,
  }) async {
    final res = await _authedSend(
      () => _http.delete(
        _uri('/api/diaries/$date/blocks/$blockId'),
        headers: _headers(),
        body: jsonEncode({'vv': vv, 'hlc': hlc}),
      ),
    );
    _decode(res);
  }

  Future<List<Map<String, dynamic>>> blockVersions(String blockId) async {
    final res = await _authedSend(
      () => _http.get(_uri('/api/blocks/$blockId/versions'), headers: _headers(json: false)),
    );
    final body = _decode(res) as Map<String, dynamic>;
    return (body['versions'] as List<dynamic>).cast<Map<String, dynamic>>();
  }

  Future<MediaUploadResult> uploadMedia({
    required Uint8List bytes,
    required String mediaKey,
    required String mime,
    int? durationMs,
    int? width,
    int? height,
    String enc = 'none',
    String? nonce,
  }) async {
    final headers = <String, String>{
      ..._headers(json: false),
      'content-type': 'application/octet-stream',
      'x-media-key': mediaKey,
      'x-media-mime': mime,
    };
    if (enc != 'none') headers['x-media-enc'] = enc;
    if (nonce != null) headers['x-media-nonce'] = nonce;
    if (durationMs != null) headers['x-media-duration'] = '$durationMs';
    if (width != null) headers['x-media-width'] = '$width';
    if (height != null) headers['x-media-height'] = '$height';

    final res = await _authedSend(
      () => _http.post(_uri('/api/media'), headers: headers, body: bytes),
    );
    return MediaUploadResult.fromJson(_decode(res) as Map<String, dynamic>);
  }

  Future<Uint8List> downloadMedia(String mediaKey) async {
    final blob = await downloadMediaBlob(mediaKey);
    return blob.bytes;
  }

  /// 当前账号的存储用量与配额
  Future<Map<String, dynamic>> storageUsage() async {
    final res = await _authedSend(
      () => _http.get(_uri('/api/me/storage'), headers: _headers(json: false)),
    );
    return _decode(res) as Map<String, dynamic>;
  }

  /// 媒体归一化状态：none / pending / processing / done / skipped / failed
  Future<Map<String, dynamic>> mediaStatus(String mediaKey) async {
    final res = await _authedSend(
      () => _http.get(_uri('/api/media/$mediaKey/status'), headers: _headers(json: false)),
    );
    return _decode(res) as Map<String, dynamic>;
  }

  /// 下载媒体并带回加密元信息（客户端据此决定是否解密）
  Future<MediaBlob> downloadMediaBlob(String mediaKey) async {
    final res = await _authedSend(
      () => _http.get(_uri('/api/media/$mediaKey'), headers: _headers(json: false)),
    );
    if (res.statusCode >= 400) _throwFrom(res);
    return MediaBlob(
      bytes: res.bodyBytes,
      mime: res.headers['content-type'] ?? 'application/octet-stream',
      enc: res.headers['x-media-enc'] ?? 'none',
      nonce: res.headers['x-media-nonce'],
    );
  }

  /// 媒体是否已在服务端存在（避免重复上传大文件）
  Future<bool> mediaExists(String mediaKey) async {
    final res = await _authedSend(
      () => _http.head(_uri('/api/media/$mediaKey'), headers: _headers(json: false)),
    );
    return res.statusCode == 200;
  }

  Future<bool> health() async {
    try {
      final res = await _http.get(_uri('/healthz'));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

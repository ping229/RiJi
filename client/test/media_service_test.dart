import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'package:http/testing.dart';
import 'package:riji_client/core/api_client.dart';
import 'package:riji_client/core/crypto_service.dart';
import 'package:riji_client/core/local_store.dart';
import 'package:riji_client/core/media_service.dart';

void main() {
  const base = 'http://127.0.0.1:8080';

  test('媒体：未启用加密时原样上传', () async {
    String? sentMime;
    String? sentEnc;
    final client = MockClient((request) async {
      if (request.method == 'HEAD') return http.Response('', 404);
      sentMime = request.headers['x-media-mime'];
      sentEnc = request.headers['x-media-enc'];
      return http.Response('{"mediaKey":"k","bytes":3,"mime":"image/png"}', 200,
          headers: {'content-type': 'application/json'});
    });
    final api = ApiClient(baseUrl: base, httpClient: client);
    final store = MemoryStore();
    final service = MediaService(api: api, store: store);

    final bytes = Uint8List.fromList([1, 2, 3]);
    await service.upload(bytes: bytes, mime: 'image/png');
    expect(sentMime, 'image/png');
    expect(sentEnc, isNull, reason: '不加密时不应带 enc 头');
  });

  test('媒体：上传前就能算出与上传一致的媒体键（后台插入块的前提）', () async {
    String? uploadedKey;
    final client = MockClient((request) async {
      if (request.method == 'HEAD') return http.Response('', 404);
      uploadedKey = request.headers['x-media-key'];
      return http.Response('{"mediaKey":"k","bytes":3,"mime":"image/png"}', 200,
          headers: {'content-type': 'application/json'});
    });
    final api = ApiClient(baseUrl: base, httpClient: client);
    final service = MediaService(api: api, store: MemoryStore());

    final bytes = Uint8List.fromList(List<int>.generate(16, (i) => i * 7));
    final key = MediaService.keyOf(bytes);
    await service.upload(bytes: bytes, mime: 'image/png');

    expect(key, sha256.convert(bytes).toString());
    expect(uploadedKey, key, reason: '先算的键必须和真正上传时用的一致，块才能在后台传');
  });

  test('媒体：启用加密时上传的是密文，本地留的是明文', () async {
    late List<int> uploaded;
    String? encHeader;
    String? nonceHeader;
    final client = MockClient((request) async {
      if (request.method == 'HEAD') return http.Response('', 404);
      uploaded = request.bodyBytes;
      encHeader = request.headers['x-media-enc'];
      nonceHeader = request.headers['x-media-nonce'];
      return http.Response('{"mediaKey":"k","bytes":1,"mime":"image/png"}', 200,
          headers: {'content-type': 'application/json'});
    });

    final salt = CryptoService.generateSalt();
    final crypto = await CryptoService.derive(password: 'pw', saltBase64: salt);
    final api = ApiClient(baseUrl: base, httpClient: client);
    final store = MemoryStore();
    final service = MediaService(api: api, store: store, crypto: crypto);

    final plain = Uint8List.fromList(List<int>.generate(32, (i) => i));
    await service.upload(bytes: plain, mime: 'image/png');

    expect(encHeader, 'aes-256-gcm');
    expect(nonceHeader, isNotNull);
    expect(uploaded, isNot(equals(plain)), reason: '上传到服务器的必须是密文');
    expect(uploaded.length, plain.length + 16, reason: '密文 = 明文 + GCM 认证标签');

    // 本地缓存以"内容哈希"为键，且必须是明文，供播放与导出使用
    final contentHash = sha256.convert(plain).toString();
    final cached = await store.readMedia(contentHash);
    expect(cached, equals(plain), reason: '本地缓存必须是明文');
  });

  test('媒体：重启后（新实例）仍能读到本地明文，不需要重新下载', () async {
    final dir = await Directory.systemTemp.createTemp('riji_media_restart_');
    final salt = CryptoService.generateSalt();
    final crypto = await CryptoService.derive(password: 'pw', saltBase64: salt);
    final plain = Uint8List.fromList(List<int>.generate(24, (i) => i + 1));

    var downloads = 0;
    final client = MockClient((request) async {
      downloads += 1;
      return http.Response('{}', 404);
    });
    final api = ApiClient(baseUrl: base, httpClient: client);

    // 第一次：用 LocalStore（写磁盘），模拟插入图片
    final store1 = await LocalStore.open(dir);
    MediaService(api: api, store: store1, crypto: crypto);
    final key = sha256.convert(plain).toString();
    await store1.cacheMedia(key, plain);

    // 第二次：全新实例 + 新的 store（模拟重启），不应再发起下载
    final store2 = await LocalStore.open(dir);
    final service2 = MediaService(api: api, store: store2, crypto: crypto);
    final bytes = await service2.bytesFor(key);

    expect(bytes, equals(plain), reason: '重启后必须能从本地缓存读到明文');
    expect(downloads, 0, reason: '本地有缓存时不应再请求服务器');

    await dir.delete(recursive: true);
  });
  test('媒体：已存在时跳过重复上传', () async {
    var uploadCalls = 0;
    final client = MockClient((request) async {
      if (request.method == 'HEAD') return http.Response('', 200);
      uploadCalls += 1;
      return http.Response('{}', 200, headers: {'content-type': 'application/json'});
    });
    final api = ApiClient(baseUrl: base, httpClient: client);
    final service = MediaService(api: api, store: MemoryStore());

    final result = await service.upload(bytes: Uint8List.fromList([9, 9]), mime: 'image/png');
    expect(result.deduped, isTrue);
    expect(uploadCalls, 0);
  });

  test('媒体：下载后解密并缓存明文', () async {
    final salt = CryptoService.generateSalt();
    final crypto = await CryptoService.derive(password: 'pw', saltBase64: salt);
    final plain = Uint8List.fromList(List<int>.generate(16, (i) => 200 - i));
    final sealed = await crypto.seal(plain, aad: mediaAad(mediaKey: 'k1'));

    var downloads = 0;
    final client = MockClient((request) async {
      downloads += 1;
      return http.Response.bytes(sealed.cipher, 200, headers: {
        'content-type': 'image/png',
        'x-media-enc': 'aes-256-gcm',
        'x-media-nonce': sealed.nonceBase64,
      });
    });
    final api = ApiClient(baseUrl: base, httpClient: client);
    final store = MemoryStore();
    final service = MediaService(api: api, store: store, crypto: crypto);

    final fetched = await service.bytesFor('k1');
    expect(fetched, equals(plain), reason: '必须返回解密后的内容');

    // 第二次走缓存，不应再请求
    final again = await service.bytesFor('k1');
    expect(again, equals(plain));
    expect(downloads, 1, reason: '命中缓存后不应重复下载');
  });

  test('媒体：服务器返回空字节时不应破坏缓存', () async {
    final client = MockClient((request) async => http.Response.bytes([], 200));
    final api = ApiClient(baseUrl: base, httpClient: client);
    final store = MemoryStore();
    final service = MediaService(api: api, store: store);
    await expectLater(service.bytesFor('missing'), throwsA(isA<StateError>()));
    expect(await store.readMedia('missing'), isNull, reason: '空内容不应写入缓存');
  });
}

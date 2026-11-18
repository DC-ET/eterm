// 中枢 API 客户端（M0 骨架）：登录 / 同步 pull / push / WS 通知。
// 零第三方依赖（dart:io）。同步语义对齐技术方案 §3.3：cursor=changes.id，
// Enc 列由服务端静态解密后明文下发（TLS 保护传输）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ApiException implements Exception {
  ApiException(this.status, this.error);
  final int status;
  final String error;

  @override
  String toString() => 'HTTP $status: $error';
}

class LoginResult {
  LoginResult({required this.token, required this.vaultId, required this.username});
  final String token;
  final String vaultId;
  final String username;
}

class ApiClient {
  ApiClient({required this.baseUrl});
  final String baseUrl;

  String? token;
  HttpClient? _http;

  HttpClient get _client =>
      _http ??= HttpClient()..connectionTimeout = const Duration(seconds: 10);

  Map<String, String> _headers() => {
        // charset 必须显式：dart:io 无 charset 时按 latin1 编码请求体，
        // 中文标签/密码会直接抛 "Contains invalid characters"
        'content-type': 'application/json; charset=utf-8',
        if (token != null) 'authorization': 'Bearer $token',
      };

  Future<Map<String, dynamic>> _req(String method, String path, [Object? body]) async {
    try {
      final req = await _client.openUrl(method, Uri.parse('$baseUrl$path'));
      _headers().forEach(req.headers.set);
      if (body != null) req.write(jsonEncode(body));
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final json = text.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(text) as Map<String, dynamic>;
      if (res.statusCode != 200) {
        throw ApiException(res.statusCode, (json['error'] ?? text).toString());
      }
      return json;
    } on SocketException catch (e) {
      throw ApiException(0, '网络不可达: ${e.message}');
    }
  }

  /// 登录并保存认证 token。deviceName/platform 服务端必填。
  Future<LoginResult> login(
    String username,
    String password, {
    required String deviceName,
    String platform = 'macos',
  }) async {
    final j = await _req('POST', '/api/v1/auth/login', {
      'username': username,
      'password': password,
      'device_name': deviceName,
      'platform': platform,
    });
    token = j['token'] as String;
    return LoginResult(
      token: token!,
      vaultId: j['vault_id'] as String,
      username: (j['user'] as Map)['username'] as String,
    );
  }

  Future<void> logout() async {
    try {
      await _req('POST', '/api/v1/auth/logout');
    } finally {
      token = null;
    }
  }

  /// 修改中枢账号密码（需验证旧密码；成功后其余会话仍有效）。
  Future<void> changePassword(String oldPassword, String newPassword) async {
    await _req('POST', '/api/v1/auth/password', {
      'old_password': oldPassword,
      'new_password': newPassword,
    });
  }

  /// 会话探活：返回当前用户名（恢复会话时校验 token 有效性）。
  Future<String> me() async {
    final j = await _req('GET', '/api/v1/me');
    return ((j['user'] as Map)['username'] as String);
  }

  /// 增量拉取一批变更（从 since 游标），返回原始 changes（供本地库折叠）。
  /// 单批 ≤ limit；返回 (changes, newCursor, hasMore)。
  Future<(List<dynamic>, int, bool)> pullBatch(int since, {int limit = 500}) async {
    final j = await _req('GET', '/api/v1/sync/pull?cursor=$since&limit=$limit');
    return (
      (j['changes'] as List),
      j['cursor'] as int,
      j['has_more'] == true,
    );
  }

  /// 全量拉取并折叠为当前实体集（"type/id" → data；upsert 覆盖、delete 移除）。
  /// M0 骨架：每次从 cursor=0 重放（数据量小）；增量 cursor 记忆随 M1 落地。
  Future<Map<String, Map<String, dynamic>>> pullAll() async {
    var cursor = 0;
    final entities = <String, Map<String, dynamic>>{};
    while (true) {
      final j = await _req('GET', '/api/v1/sync/pull?cursor=$cursor&limit=1000');
      final changes = (j['changes'] as List).cast<Map<String, dynamic>>();
      for (final c in changes) {
        final key = '${c['entity_type']}/${c['entity_id']}';
        if (c['op'] == 'delete') {
          entities.remove(key);
        } else {
          entities[key] = (c['data'] ?? <String, dynamic>{}) as Map<String, dynamic>;
        }
      }
      cursor = j['cursor'] as int;
      if (j['has_more'] != true) break;
    }
    return entities;
  }

  /// 推送一批变更。返回每项 status（ok/conflict/rejected）。
  Future<List<Map<String, dynamic>>> push(List<Map<String, dynamic>> changes) async {
    final j = await _req('POST', '/api/v1/sync/push', {'changes': changes});
    return (j['results'] as List).cast<Map<String, dynamic>>();
  }

  /// WS 通知流（单次连接；断开后流结束，UI 侧重订阅即重连）。
  /// 帧形状：{"type":"change","rev":N}。
  Stream<Map<String, dynamic>> changeFeed() async* {
    final wsBase = baseUrl.replaceFirst('http', 'ws');
    final ws = await WebSocket.connect('$wsBase/api/v1/ws?token=$token');
    await for (final msg in ws) {
      yield jsonDecode(msg as String) as Map<String, dynamic>;
    }
  }
}

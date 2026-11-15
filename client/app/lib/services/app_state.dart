// 应用状态（M1）：本地库快照引导 + 增量 cursor 同步 + 私钥入中枢（ssh_key 实体链）。
// 凭据解析：identity.password_enc（口令）| identity.key_id → ssh_key.private_enc（私钥）。
// 私钥/口令都随中枢同步（服务端静态加密），重启与跨设备均可用。

import 'dart:convert';
import 'dart:math';

import 'package:eterm/src/rust/api/local.dart' as local;
import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// 凭据可读性（record 判空的可读写法）。
extension CredentialAvailable on ({String authKind, String secret})? {
  bool get available => this != null;
}

class GroupView {
  GroupView({required this.id, required this.label, required this.count});
  final String id;
  final String label;
  final int count;
}

class HostView {
  HostView({
    required this.id,
    required this.label,
    required this.hostname,
    required this.port,
    required this.username,
    this.identityId,
    this.groupId,
  });

  final String id;
  final String label;
  final String hostname;
  final int port;
  final String username;
  final String? identityId; // 指向 identity 实体
  final String? groupId; // 指向 host_group；null = 未分组
}

class AppState extends ChangeNotifier {
  AppState({required this.api});

  final ApiClient api;

  Map<String, Map<String, dynamic>> _entities = {};
  bool loading = false;
  String? error; // 'unauthorized' 会触发壳层回登录页

  /// 启动引导：从本地库快照加载（离线可见），随后可调 refresh() 增量同步。
  Future<void> bootstrap() async {
    try {
      final snap = jsonDecode(local.storeLoad()) as Map<String, dynamic>;
      final entities = (snap['entities'] as Map).cast<String, dynamic>();
      _entities = entities.map((k, v) => MapEntry(k, (v as Map).cast<String, dynamic>()));
      error = null;
      notifyListeners();
    } catch (_) {
      // 本地库不可用：内存空集继续（推送类操作仍可用）
    }
  }

  List<HostView> get hosts {
    final protocols = <String, Map<String, dynamic>>{}; // host_id → protocol
    for (final e in _entities.values) {
      if (e['kind'] == 'ssh') protocols[e['host_id'] as String] = e;
    }
    final list = <HostView>[];
    for (final e in _entities.values) {
      if (e.keys.contains('hostname') && e['id'] != null) {
        final hostId = e['id'] as String;
        final proto = protocols[hostId];
        final cfg = (proto?['config_json'] ?? <String, dynamic>{}) as Map<String, dynamic>;
        final identityId = cfg['identity_id'] as String?;
        if (identityId != null && !_entities.containsKey('identity/$identityId')) continue;
        list.add(HostView(
          id: hostId,
          label: (e['label'] ?? hostId).toString(),
          hostname: (e['hostname'] ?? '').toString(),
          port: (cfg['port'] as num?)?.toInt() ?? 22,
          username: (cfg['username'] ?? '') as String? ?? '',
          identityId: identityId,
          groupId: e['group_id'] as String?,
        ));
      }
    }
    list.sort((a, b) => a.label.compareTo(b.label));
    return list;
  }

  /// 分组视图（含主机计数），按 label 排序。
  List<GroupView> get groups {
    final names = <String, String>{};
    for (final e in _entities.values) {
      if (e['id'] != null && e['label'] != null && e.keys.contains('parent_id')) {
        names[e['id'] as String] = e['label'].toString();
      }
    }
    final list = names.entries
        .map((e) => GroupView(
              id: e.key,
              label: e.value,
              count: hosts.where((h) => h.groupId == e.key).length,
            ))
        .toList()
      ..sort((a, b) => a.label.compareTo(b.label));
    return list;
  }

  String? groupName(String? id) =>
      id == null ? null : _entities['host_group/$id']?['label']?.toString();

  /// 连接凭据解析：identity 口令 / ssh_key 私钥（均来自中枢，重启可用）。
  ({String authKind, String secret})? credentialFor(HostView h) {
    if (h.identityId == null) return null;
    final identity = _entities['identity/${h.identityId}'];
    if (identity == null) return null;
    final password = identity['password_enc'];
    if (password is String && password.isNotEmpty) {
      return (authKind: 'password', secret: password);
    }
    final keyId = identity['key_id'] as String?;
    if (keyId != null) {
      final key = _entities['ssh_key/$keyId'];
      final pem = key?['private_enc'];
      if (pem is String && pem.isNotEmpty) {
        return (authKind: 'key', secret: pem);
      }
    }
    return null;
  }

  /// 增量同步：从本地库游标拉取变更 → 折叠进本地库 → 重建视图。
  Future<void> refresh() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      var cursor = local.storeCursor().toInt();
      while (true) {
        final (changes, newCursor, hasMore) = await api.pullBatch(cursor);
        if (changes.isNotEmpty) {
          local.storeApply(
            changesJson: jsonEncode(changes),
            cursor: BigInt.from(newCursor),
          );
        }
        cursor = newCursor;
        if (!hasMore) break;
      }
      await bootstrap(); // 快照重建（保持单一数据源）
    } on ApiException catch (e) {
      error = e.status == 401 ? 'unauthorized' : e.error;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// 添加主机：host(+可选 group) + host_protocol(ssh)。
  /// 口令认证 → identity.password_enc；私钥认证 → ssh_key 实体 + identity.key_id。
  /// 全部走中枢（服务端静态加密），重启与跨设备可用。
  Future<void> addHost({
    required String label,
    required String hostname,
    required int port,
    required String username,
    required bool usePassword,
    required String secret,
    String? groupId,
    String? newGroupName,
  }) async {
    final hostId = _newUuid();
    final identityId = _newUuid();
    String? effectiveGroupId = groupId;
    final changes = <Map<String, dynamic>>[];
    if (groupId == null && newGroupName != null && newGroupName.trim().isNotEmpty) {
      effectiveGroupId = _newUuid();
      changes.add(_upsert('host_group', effectiveGroupId, {
        'label': newGroupName.trim(),
        'sort': 0,
      }));
    }
    changes.add(_upsert('host', hostId, {
      'label': label,
      'hostname': hostname,
      'tags': <String>[],
      'group_id': ?effectiveGroupId,
    }));
    if (usePassword) {
      changes.add(_upsert('identity', identityId, {
        'label': username,
        'username': username,
        'password_enc': secret,
        'key_id': null,
      }));
    } else {
      final keyId = _newUuid();
      changes.add(_upsert('ssh_key', keyId, {
        'label': label,
        'key_type': 'imported-pem',
        'private_enc': secret,
        'public_key': '',
        'fingerprint': '',
        'origin': 'imported',
        'key_version': 1,
      }));
      changes.add(_upsert('identity', identityId, {
        'label': username,
        'username': username,
        'key_id': keyId,
      }));
    }
    changes.add(_upsert('host_protocol', _newUuid(), {
      'host_id': hostId,
      'kind': 'ssh',
      'config_json': {'port': port, 'username': username, 'identity_id': identityId},
      'sort': 0,
    }));
    final results = await api.push(changes);
    final bad = results.where((r) => r['status'] != 'ok').toList();
    if (bad.isNotEmpty) {
      throw ApiException(200, '推送被拒: ${bad.map((r) => r['status']).join(",")}');
    }
    await refresh();
  }

  /// 删除主机：主机 + ssh 协议 + identity（+ssh_key）全部墓碑下线。
  Future<void> deleteHost(HostView h) async {
    final changes = <Map<String, dynamic>>[];
    void tomb(String type, String id) {
      final e = _entities['$type/$id'];
      if (e == null) return;
      changes.add({
        'entity_type': type,
        'entity_id': id,
        'base_rev': (e['rev'] as num?)?.toInt() ?? 0,
        'op': 'delete',
      });
    }

    tomb('host', h.id);
    for (final e in _entities.values) {
      if (e['kind'] == 'ssh' && e['host_id'] == h.id) tomb('host_protocol', e['id'] as String);
    }
    if (h.identityId != null) {
      final identityId = h.identityId!;
      final identity = _entities['identity/$identityId'];
      final keyId = identity?['key_id'] as String?;
      tomb('identity', identityId);
      if (keyId != null) tomb('ssh_key', keyId);
    }
    if (changes.isEmpty) return;
    final results = await api.push(changes);
    final bad = results.where((r) => r['status'] != 'ok').toList();
    if (bad.isNotEmpty) {
      throw ApiException(200, '删除被拒: ${bad.map((r) => r['status']).join(",")}');
    }
    await refresh();
  }

  Map<String, dynamic> _upsert(String type, String id, Map<String, dynamic> data) => {
        'entity_type': type,
        'entity_id': id,
        'base_rev': 0,
        'op': 'upsert',
        'data': data,
      };

  /// 已存实体的带 rev 更新（base_rev 必须取当前值，否则服务端判冲突）。
  Map<String, dynamic> _update(String type, String id, Map<String, dynamic> data) {
    final cur = _entities['$type/$id'];
    return {
      'entity_type': type,
      'entity_id': id,
      'base_rev': (cur?['rev'] as num?)?.toInt() ?? 0,
      'op': 'upsert',
      'data': data,
    };
  }

  /// 编辑主机：label/hostname/port/username/分组；口令可改（原样可留空），
  /// 私钥替换会新建 ssh_key 实体（服务端禁止覆盖既有密钥内容，immutable）并重指 key_id。
  Future<void> editHost({
    required HostView host,
    required String label,
    required String hostname,
    required int port,
    required String username,
    String? groupId,
    String? newGroupName,
    String? password,
    String? replaceKeyPem,
  }) async {
    final identityId = host.identityId;
    if (identityId == null) {
      throw ApiException(200, '该主机没有凭据实体，请删除后重新添加');
    }
    final identity = _entities['identity/$identityId'];
    final oldPassword = identity?['password_enc'];
    final oldKeyId = identity?['key_id'] as String?;
    final isPasswordAuth = oldPassword is String && oldPassword.isNotEmpty;

    String? effectiveGroupId = groupId;
    final changes = <Map<String, dynamic>>[];
    if (groupId == null && newGroupName != null && newGroupName.trim().isNotEmpty) {
      effectiveGroupId = _newUuid();
      changes.add(_upsert('host_group', effectiveGroupId, {
        'label': newGroupName.trim(),
        'sort': 0,
      }));
    }

    changes.add(_update('host', host.id, {
      'label': label,
      'hostname': hostname,
      'tags': _entities['host/${host.id}']?['tags'] ?? <String>[],
      'group_id': ?effectiveGroupId,
    }));

    if (isPasswordAuth) {
      changes.add(_update('identity', identityId, {
        'label': username,
        'username': username,
        'password_enc':
            (password != null && password.isNotEmpty) ? password : oldPassword,
        'key_id': null,
      }));
    } else {
      var keyId = oldKeyId;
      if (replaceKeyPem != null && replaceKeyPem.isNotEmpty) {
        keyId = _newUuid();
        changes.add(_upsert('ssh_key', keyId, {
          'label': label,
          'key_type': 'imported-pem',
          'private_enc': replaceKeyPem,
          'public_key': '',
          'fingerprint': '',
          'origin': 'imported',
          'key_version': 1,
        }));
      }
      changes.add(_update('identity', identityId, {
        'label': username,
        'username': username,
        'password_enc': null,
        'key_id': keyId,
      }));
    }

    final protocolId = _protocolIdOf(host.id);
    if (protocolId == null) {
      throw ApiException(200, '找不到该主机的 ssh 协议实体');
    }
    changes.add(_update('host_protocol', protocolId, {
      'host_id': host.id,
      'kind': 'ssh',
      'config_json': {'port': port, 'username': username, 'identity_id': identityId},
      'sort': 0,
    }));

    final results = await api.push(changes);
    final bad = results.where((r) => r['status'] != 'ok').toList();
    if (bad.isNotEmpty) {
      throw ApiException(200, '推送被拒: ${bad.map((r) => r['status']).join(",")}');
    }
    await refresh();
  }

  String? _protocolIdOf(String hostId) {
    for (final e in _entities.values) {
      if (e['kind'] == 'ssh' && e['host_id'] == hostId) return e['id'] as String?;
    }
    return null;
  }
}

String _newUuid() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 10
  final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

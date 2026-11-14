// 应用状态（M0.5）：同步折叠 → 视图模型（分组/主机卡片）、添加主机（push）。
// 私钥认证暂不持久化（ssh_key 实体与密钥管理 UI 随 M1 落地），仅会话内存。

import 'dart:math';

import 'package:flutter/foundation.dart';

import 'api_client.dart';

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
  final String? identityId; // 指向 identity 实体（口令认证）；null = 私钥（会话内存）
  final String? groupId; // 指向 host_group；null = 未分组
}

/// 口令认证的主机密钥来自 identity.password_enc（pull 时已是明文）；
/// 私钥认证的主机密钥在内存里按 host id 存放，重启即失。
class AppState extends ChangeNotifier {
  AppState({required this.api});

  final ApiClient api;

  Map<String, Map<String, dynamic>> _entities = {};
  final Map<String, String> _sessionKeys = {}; // hostId → PEM（仅私钥，内存）
  bool loading = false;
  String? error;

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
        // 口令主机必须有 identity；私钥主机走 _sessionKeys
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

  /// 连接凭据解析：identity 口令 / 会话内私钥。null = 无凭据。
  ({String authKind, String secret})? credentialFor(HostView h) {
    if (h.identityId != null) {
      final identity = _entities['identity/${h.identityId}'];
      final password = identity?['password_enc'];
      if (password is String && password.isNotEmpty) {
        return (authKind: 'password', secret: password);
      }
      return null;
    }
    final pem = _sessionKeys[h.id];
    if (pem != null) return (authKind: 'key', secret: pem);
    return null;
  }

  void rememberSessionKey(String hostId, String pem) => _sessionKeys[hostId] = pem;

  Future<void> refresh() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      _entities = await api.pullAll();
    } on ApiException catch (e) {
      error = e.error;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// 添加主机：host(+可选 group) + host_protocol(ssh)；口令认证另建 identity。
  /// 私钥认证不落库（M1），仅登记会话内存。
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
    String? identityId;
    String? effectiveGroupId = groupId;
    final changes = <Map<String, dynamic>>[];
    if (groupId == null && newGroupName != null && newGroupName.trim().isNotEmpty) {
      effectiveGroupId = _newUuid();
      changes.add({
        'entity_type': 'host_group',
        'entity_id': effectiveGroupId,
        'base_rev': 0,
        'op': 'upsert',
        'data': {'label': newGroupName.trim(), 'sort': 0},
      });
    }
    changes.add({
      'entity_type': 'host',
      'entity_id': hostId,
      'base_rev': 0,
      'op': 'upsert',
      'data': {
        'label': label,
        'hostname': hostname,
        'tags': <String>[],
        'group_id': ?effectiveGroupId,
      },
    });
    if (usePassword) {
      identityId = _newUuid();
      changes.add({
        'entity_type': 'identity',
        'entity_id': identityId,
        'base_rev': 0,
        'op': 'upsert',
        'data': {
          'label': username,
          'username': username,
          'password_enc': secret,
          'key_id': null,
        },
      });
    }
    changes.add({
      'entity_type': 'host_protocol',
      'entity_id': _newUuid(),
      'base_rev': 0,
      'op': 'upsert',
      'data': {
        'host_id': hostId,
        'kind': 'ssh',
        'config_json': {
          'port': port,
          'username': username,
          'identity_id': ?identityId,
        },
        'sort': 0,
      },
    });
    final results = await api.push(changes);
    final bad = results.where((r) => r['status'] != 'ok').toList();
    if (bad.isNotEmpty) {
      throw ApiException(200, '推送被拒: ${bad.map((r) => r['status']).join(",")}');
    }
    if (!usePassword) rememberSessionKey(hostId, secret);
    await refresh();
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

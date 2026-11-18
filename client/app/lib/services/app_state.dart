// 应用状态（M1）：本地库快照引导 + 增量 cursor 同步 + 私钥入中枢（ssh_key 实体链）。
// 凭据解析：identity.password_enc（口令）| identity.key_id → ssh_key.private_enc（私钥）。
// 私钥/口令都随中枢同步（服务端静态加密），重启与跨设备均可用。

import 'dart:convert';
import 'dart:math';

import 'package:eterm/src/rust/api/keychain.dart' as keychain;
import 'package:eterm/src/rust/api/local.dart' as local;
import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// 凭据可读性（record 判空的可读写法）。
extension CredentialAvailable on ({String authKind, String secret})? {
  bool get available => this != null;
}

/// PEM 校验结果（Rust KeyMeta 的语义视图；测试可注入替身绕过 Rust FFI）。
class KeyMetaView {
  KeyMetaView({
    required this.keyType,
    required this.fingerprint,
    required this.publicKeyLine,
  });
  final String keyType;
  final String fingerprint;
  final String publicKeyLine;
}

typedef PemInspector = KeyMetaView Function(String pem);

class GroupView {
  GroupView({required this.id, required this.label, required this.count});
  final String id;
  final String label;
  final int count;
}

class KeyView {
  KeyView({
    required this.id,
    required this.label,
    required this.keyType,
    required this.fingerprint,
    required this.publicKey,
    required this.origin,
    required this.usedBy,
  });

  final String id;
  final String label;
  final String keyType;
  final String fingerprint;
  final String publicKey; // 一行公钥（authorized_keys 可直接粘贴）
  final String origin; // generated | imported | fido2 | biometric
  final List<String> usedBy; // 使用此密钥的主机 label
}

/// Identity 视图（F4.1：用户名 + 口令/Key 的凭据组合，引用式管理）。
class IdentityView {
  IdentityView({
    required this.id,
    required this.label,
    required this.username,
    required this.hasPassword,
    required this.keyId,
    required this.keyLabel,
    required this.usedBy,
  });

  final String id;
  final String label;
  final String username;
  final bool hasPassword;
  final String? keyId;
  final String? keyLabel;
  final List<String> usedBy; // 引用此凭据的主机 label

  /// 徽标文案：口令 / 密钥名；引用的密钥已失效、或既无口令也无密钥（历史悬空
  /// 数据）时给出可排障的区分文案（评审 OBS-2）。
  String get authKindText {
    if (hasPassword) return '口令';
    if (keyLabel != null) return keyLabel!;
    return keyId != null ? '密钥（已失效）' : '无凭据';
  }
}

/// 端口转发规则（port_rule 实体；M2 仅 local -L 生效，remote/dynamic 预留）。
class PortRuleView {
  PortRuleView({
    required this.id,
    required this.hostId,
    required this.label,
    required this.kind,
    required this.bindAddr,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
    required this.enabled,
  });

  final String id;
  final String hostId;
  final String label;
  final String kind; // local | remote | dynamic
  final String bindAddr;
  final int? localPort;
  final String? remoteHost;
  final int? remotePort;
  final bool enabled;
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
  AppState({required this.api, PemInspector? inspectPem})
      : inspectPem = inspectPem ?? _defaultInspectPem;

  final ApiClient api;

  /// PEM 校验（默认走 Rust keyInspect；flutter 测试无 FFI 时注入替身）。
  final PemInspector inspectPem;

  static KeyMetaView _defaultInspectPem(String pem) {
    final m = keychain.keyInspect(pem: pem);
    return KeyMetaView(
      keyType: m.keyType,
      fingerprint: m.fingerprint,
      publicKeyLine: m.publicKeyLine,
    );
  }

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

  /// 仅供测试注入实体快照（绕过 Rust 本地库 FFI；评审验证用，见 docs/code-review）。
  @visibleForTesting
  void debugSetEntities(Map<String, Map<String, dynamic>> entities) {
    _entities = entities;
    notifyListeners();
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

  /// 密钥视图：ssh_key 实体 + 反向引用（哪些主机在用）。
  List<KeyView> get keys {
    // hostId → host label
    final hostLabel = <String, String>{};
    // identityId → keyId
    final keyOfIdentity = <String, String>{};
    for (final e in _entities.values) {
      if (e['id'] != null && e.keys.contains('hostname')) {
        hostLabel[e['id'] as String] = (e['label'] ?? e['id']).toString();
      }
      if (e['id'] != null && e.keys.contains('key_id')) {
        final kid = e['key_id'];
        if (kid is String && kid.isNotEmpty) {
          keyOfIdentity[e['id'] as String] = kid;
        }
      }
    }
    // keyId → hostId（经 protocol.config_json.identity_id）
    final hostsOfKey = <String, Set<String>>{};
    for (final e in _entities.values) {
      if (e['kind'] != 'ssh') continue;
      final cfg = (e['config_json'] ?? <String, dynamic>{}) as Map<String, dynamic>;
      final iid = cfg['identity_id'] as String?;
      final kid = iid == null ? null : keyOfIdentity[iid];
      final hid = e['host_id'] as String?;
      if (kid != null && hid != null) {
        hostsOfKey.putIfAbsent(kid, () => {}).add(hid);
      }
    }
    final list = <KeyView>[];
    for (final e in _entities.values) {
      if (e['id'] == null || !e.keys.contains('private_enc')) continue;
      final id = e['id'] as String;
      list.add(KeyView(
        id: id,
        label: (e['label'] ?? id).toString(),
        keyType: (e['key_type'] ?? 'unknown').toString(),
        fingerprint: (e['fingerprint'] ?? '').toString(),
        publicKey: (e['public_key'] ?? '').toString(),
        origin: (e['origin'] ?? 'imported').toString(),
        usedBy: (hostsOfKey[id] ?? {})
            .map((hid) => hostLabel[hid] ?? hid)
            .toList()
          ..sort(),
      ));
    }
    list.sort((a, b) => a.label.compareTo(b.label));
    return list;
  }

  /// Identity 视图：凭据组合（用户名 + 口令/Key）+ 反向引用（哪些主机在用）。
  /// Keychain 页消费（F4.1 引用式管理）；identity 编辑经 updateIdentity 一处生效。
  List<IdentityView> get identities {
    final hostLabel = <String, String>{};
    for (final e in _entities.values) {
      if (e['id'] != null && e.keys.contains('hostname')) {
        hostLabel[e['id'] as String] = (e['label'] ?? e['id']).toString();
      }
    }
    // identityId → 引用它的主机 label（经 host_protocol.config_json.identity_id）
    final hostsOfIdentity = <String, Set<String>>{};
    final keyLabels = <String, String>{};
    for (final e in _entities.values) {
      if (e['id'] != null && e.keys.contains('private_enc')) {
        keyLabels[e['id'] as String] = (e['label'] ?? e['id']).toString();
      }
      if (e['kind'] != 'ssh') continue;
      final cfg = (e['config_json'] ?? <String, dynamic>{}) as Map<String, dynamic>;
      final iid = cfg['identity_id'] as String?;
      final hid = e['host_id'] as String?;
      if (iid != null && hid != null) {
        hostsOfIdentity.putIfAbsent(iid, () => {}).add(hid);
      }
    }
    final list = <IdentityView>[];
    for (final e in _entities.values) {
      // identity 实体特征：顶层 username + key_id 列（主机/协议/密钥实体均无此组合）
      if (e['id'] == null || !e.keys.contains('username') || !e.keys.contains('key_id')) {
        continue;
      }
      final id = e['id'] as String;
      final password = e['password_enc'];
      final keyId = e['key_id'] as String?;
      list.add(IdentityView(
        id: id,
        label: (e['label'] ?? id).toString(),
        username: (e['username'] ?? '').toString(),
        hasPassword: password is String && password.isNotEmpty,
        keyId: keyId,
        keyLabel: keyId == null ? null : keyLabels[keyId],
        usedBy: (hostsOfIdentity[id] ?? {})
            .map((hid) => hostLabel[hid] ?? hid)
            .toList()
          ..sort(),
      ));
    }
    list.sort((a, b) => a.label.compareTo(b.label));
    return list;
  }

  /// Identity 引用的密钥是否存在（他端并发删除会留悬空 key_id）。
  bool identityKeyMissing(IdentityView v) =>
      v.keyId != null && !_entities.containsKey('ssh_key/${v.keyId}');

  /// 编辑 Identity：username / 认证方式（口令 ⇄ 密钥）。wire 契约：identity 的
  /// 4 个 wire 字段全部显式回传（服务端 push 部分更新语义，缺键不改列）。
  /// 口令模式：password 空 = 保留原口令；密钥模式：password_enc 显式 null 清列。
  Future<void> updateIdentity({
    required IdentityView identity,
    required String username,
    required bool usePassword,
    String? password,
    String? keyId,
  }) async {
    final e = _entities['identity/${identity.id}'];
    if (e == null) {
      throw ApiException(200, '该凭据不存在或已被删除，请刷新后重试');
    }
    final oldPassword = e['password_enc'];
    final usernameTrimmed = username.trim();
    if (usernameTrimmed.isEmpty) {
      throw ApiException(200, '用户名不能为空');
    }
    String? effectivePassword;
    String? effectiveKeyId;
    if (usePassword) {
      effectivePassword = (password != null && password.isNotEmpty)
          ? password
          : (oldPassword is String ? oldPassword : null);
      if (effectivePassword == null || effectivePassword.isEmpty) {
        throw ApiException(200, '请填写口令（原凭据没有可保留的口令）');
      }
      effectiveKeyId = null; // 口令认证必须显式清 key_id 列
    } else {
      if (keyId == null || keyId.isEmpty) {
        throw ApiException(200, '请选择 Keychain 中的密钥');
      }
      if (!_entities.containsKey('ssh_key/$keyId')) {
        throw ApiException(200, '所选密钥不存在或已被删除，请刷新后重新选择');
      }
      effectiveKeyId = keyId;
      effectivePassword = null; // 密钥认证必须显式清 password_enc 列
    }
    final results = await api.push([
      _update('identity', identity.id, {
        'label': usernameTrimmed,
        'username': usernameTrimmed,
        'password_enc': effectivePassword,
        'key_id': effectiveKeyId,
      })
    ]);
    final bad = results.where((r) => r['status'] != 'ok').toList();
    if (bad.isNotEmpty) {
      throw ApiException(200, '更新被拒: ${bad.map((r) => r['status']).join(",")}');
    }
    try {
      local.logEvent(kind: 'identity_edit', detail: '${identity.label}（$usernameTrimmed）');
    } catch (_) {}
    await refresh();
  }

  /// 删除 Identity（仅限未被任何主机引用；引用中删除会造成主机悬空无凭据）。
  Future<void> deleteIdentity(IdentityView v) async {
    if (v.usedBy.isNotEmpty) {
      throw ApiException(200, '该凭据正被使用：${v.usedBy.join("、")}。请先在这些主机的编辑里更换凭据。');
    }
    final e = _entities['identity/${v.id}'];
    if (e == null) return;
    final results = await api.push([
      {
        'entity_type': 'identity',
        'entity_id': v.id,
        'base_rev': (e['rev'] as num?)?.toInt() ?? 0,
        'op': 'delete',
      }
    ]);
    final bad = results.where((r) => r['status'] != 'ok').toList();
    if (bad.isNotEmpty) {
      throw ApiException(200, '删除被拒: ${bad.map((r) => r['status']).join(",")}');
    }
    try {
      local.logEvent(kind: 'identity_delete', detail: v.label);
    } catch (_) {}
    await refresh();
  }

  /// 删除密钥（仅限未被任何主机引用；引用中的密钥删除会造成 identity 悬空）。
  Future<void> deleteKey(KeyView k) async {
    if (k.usedBy.isNotEmpty) {
      throw ApiException(200, '该密钥正被使用：${k.usedBy.join("、")}。请先在这些主机的编辑里更换凭据。');
    }
    // 孤立 identity 直引（没有 host_protocol 连接，usedBy 反查不到）同样禁止删除
    for (final e in _entities.values) {
      final kid = e['key_id'];
      if (kid is String && kid == k.id) {
        throw ApiException(200, '该密钥仍被凭据「${e['label'] ?? e['id']}」引用，请先解除引用再删除。');
      }
    }
    final e = _entities['ssh_key/${k.id}'];
    if (e == null) return;
    final results = await api.push([
      {
        'entity_type': 'ssh_key',
        'entity_id': k.id,
        'base_rev': (e['rev'] as num?)?.toInt() ?? 0,
        'op': 'delete',
      }
    ]);
    final bad = results.where((r) => r['status'] != 'ok').toList();
    if (bad.isNotEmpty) {
      throw ApiException(200, '删除被拒: ${bad.map((r) => r['status']).join(",")}');
    }
    try {
      local.logEvent(kind: 'key_delete', detail: k.label);
    } catch (_) {}
    await refresh();
  }

  /// 导入 PEM 私钥收录 Keychain（先经 Rust 校验提取类型/指纹/公钥行，
  /// 非法 PEM 直接抛错不入库）。
  Future<void> importKey({required String label, required String pem}) async {
    final meta = inspectPem(pem);
    await _pushKeyEntity(
      label: label,
      keyType: meta.keyType,
      privateEnc: pem,
      publicKey: meta.publicKeyLine,
      fingerprint: meta.fingerprint,
      origin: 'imported',
    );
    try {
      local.logEvent(kind: 'key_import', detail: '$label（${meta.keyType}）');
    } catch (_) {}
    await refresh();
  }

  /// 生成密钥收录 Keychain（Rust 生成，async：RSA 秒级不得占 UI 线程）。
  /// algorithm ∈ ed25519 | ecdsa-p256 | rsa-2048 | rsa-3072 | rsa-4096。
  Future<void> generateKey({
    required String label,
    String comment = '',
    String algorithm = 'ed25519',
  }) async {
    final gen = await keychain.keyGenerate(algorithm: algorithm, comment: comment);
    await _pushKeyEntity(
      label: label,
      keyType: gen.keyType,
      privateEnc: gen.pem,
      publicKey: gen.publicKeyLine,
      fingerprint: gen.fingerprint,
      origin: 'generated',
    );
    try {
      local.logEvent(kind: 'key_generate', detail: '$label（${gen.keyType}）');
    } catch (_) {}
    await refresh();
  }

  Future<void> _pushKeyEntity({
    required String label,
    required String keyType,
    required String privateEnc,
    required String publicKey,
    required String fingerprint,
    required String origin,
  }) async {
    // 指纹去重：同一把密钥重复导入/生成会造成无意义的并列实体（评审 P2）
    for (final e in _entities.values) {
      if (e.keys.contains('private_enc') &&
          e['fingerprint']?.toString() == fingerprint &&
          fingerprint.isNotEmpty) {
        throw ApiException(200, '这把密钥已在 Keychain 中：「${e['label'] ?? e['id']}」');
      }
    }
    final results = await api.push([
      _upsert('ssh_key', _newUuid(), {
        'label': label,
        'key_type': keyType,
        'private_enc': privateEnc,
        'public_key': publicKey,
        'fingerprint': fingerprint,
        'origin': origin,
        'key_version': 1,
      })
    ]);
    final bad = results.where((r) => r['status'] != 'ok').toList();
    if (bad.isNotEmpty) {
      throw ApiException(200, '推送被拒: ${bad.map((r) => r['status']).join(",")}');
    }
  }

  /// 重命名密钥。wire 契约：必须显式回传全部 wire 字段（服务端 push 是部分
  /// 更新语义，缺键不改列）；private_enc 原值回传以通过密钥内容不可变校验。
  Future<void> renameKey(KeyView k, String newLabel) async {
    final e = _entities['ssh_key/${k.id}'];
    if (e == null) return;
    final results = await api.push([
      _update('ssh_key', k.id, {
        'label': newLabel,
        'key_type': (e['key_type'] ?? '').toString(),
        'private_enc': (e['private_enc'] ?? '').toString(),
        'public_key': (e['public_key'] ?? '').toString(),
        'fingerprint': (e['fingerprint'] ?? '').toString(),
        'origin': (e['origin'] ?? 'imported').toString(),
        'key_version': (e['key_version'] as num?)?.toInt() ?? 1,
      })
    ]);
    final bad = results.where((r) => r['status'] != 'ok').toList();
    if (bad.isNotEmpty) {
      throw ApiException(200, '重命名被拒: ${bad.map((r) => r['status']).join(",")}');
    }
    try {
      local.logEvent(kind: 'key_edit', detail: '${k.label} → $newLabel');
    } catch (_) {}
    await refresh();
  }

  /// 主机当前使用的密钥 id（identity.key_id；无凭据或口令认证返回 null）。
  String? keyIdOfIdentity(String? identityId) {
    if (identityId == null) return null;
    final kid = _entities['identity/$identityId']?['key_id'];
    return kid is String && kid.isNotEmpty ? kid : null;
  }

  /// 导出用：取私钥 PEM 明文（本地快照；密钥随中枢同步所以重启可用）。
  String? privateKeyPemOf(KeyView k) =>
      (_entities['ssh_key/${k.id}']?['private_enc'])?.toString();

  /// 部署公钥到目标机 ~/.ssh/authorized_keys（F4.3）：
  /// 用主机自身凭据建独立 SSH 连接执行幂等追加命令（grep -qxF 整行去重）。
  Future<void> deployPublicKey(KeyView k, HostView h) async {
    // 旧版主机新建路径建的密钥没有公钥内容：空行去重会让 grep 假成功（评审 P1）
    if (k.publicKey.trim().isEmpty) {
      throw ApiException(200, '该密钥没有公钥内容（旧版导入），无法部署；请重新导入后使用');
    }
    final cred = credentialFor(h);
    if (cred == null) {
      throw ApiException(200, '该主机没有可用凭据，无法部署公钥');
    }
    final r = await keychain.sshExecOneshot(
      host: h.hostname,
      port: h.port,
      user: h.username,
      authKind: cred.authKind,
      secret: cred.secret,
      command: deployCommandFor(k.publicKey),
    );
    if (r.exitCode != 0) {
      final detail = r.stderr.trim().isEmpty ? r.stdout.trim() : r.stderr.trim();
      throw ApiException(200, '部署失败（exit ${r.exitCode}）: $detail');
    }
    try {
      local.logEvent(kind: 'key_deploy', detail: '${k.label} → ${h.label}');
    } catch (_) {}
  }

  /// authorized_keys 幂等追加命令。公钥行拼进单引号 shell 串：换行剔除（防拆出
  /// 第二条命令），撇号按 POSIX `'\''` 转义（保真 comment 而非静默改写，评审 P2）。
  static String deployCommandFor(String publicKeyLine) {
    final line = publicKeyLine.replaceAll(RegExp('[\r\n]'), '').trim();
    final esc = line.replaceAll("'", "'\\''");
    return "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys "
        "&& chmod 600 ~/.ssh/authorized_keys "
        "&& grep -qxF '$esc' ~/.ssh/authorized_keys 2>/dev/null "
        "|| printf '%s\\n' '$esc' >> ~/.ssh/authorized_keys";
  }

  /// 端口转发规则视图（port_rule 实体：含 bind_addr 键）。
  List<PortRuleView> get portRules {
    final list = <PortRuleView>[];
    for (final e in _entities.values) {
      if (e['id'] == null || !e.keys.contains('bind_addr')) continue;
      final id = e['id'] as String;
      list.add(PortRuleView(
        id: id,
        hostId: (e['host_id'] ?? '').toString(),
        label: (e['label'] ?? id).toString(),
        kind: (e['kind'] ?? 'local').toString(),
        bindAddr: (e['bind_addr'] ?? '127.0.0.1').toString(),
        localPort: (e['local_port'] as num?)?.toInt(),
        remoteHost: e['remote_host']?.toString(),
        remotePort: (e['remote_port'] as num?)?.toInt(),
        enabled: e['enabled'] == true,
      ));
    }
    list.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return list;
  }

  /// 新建/编辑端口规则。编辑时显式发送全部 wire 字段（部分更新语义，见 AGENTS.md wire 契约）。
  Future<void> savePortRule({
    PortRuleView? existing,
    required String hostId,
    required String label,
    required String kind,
    required String bindAddr,
    required int localPort,
    required String remoteHost,
    required int remotePort,
    required bool enabled,
  }) async {
    final data = <String, dynamic>{
      'host_id': hostId,
      'label': label,
      'kind': kind,
      'bind_addr': bindAddr,
      'local_port': localPort,
      'remote_host': remoteHost,
      'remote_port': remotePort,
      'enabled': enabled,
    };
    final change = existing == null
        ? _upsert('port_rule', _newUuid(), data)
        : _update('port_rule', existing.id, data);
    final results = await api.push([change]);
    final bad = results.where((r) => r['status'] != 'ok').toList();
    if (bad.isNotEmpty) {
      throw ApiException(200, '推送被拒: ${bad.map((r) => r['status']).join(",")}');
    }
    await refresh();
  }

  /// 删除端口规则（墓碑；删除前应先在页面上停止运行中的转发）。
  Future<void> deletePortRule(PortRuleView r) async {
    final e = _entities['port_rule/${r.id}'];
    if (e == null) return;
    final results = await api.push([
      {
        'entity_type': 'port_rule',
        'entity_id': r.id,
        'base_rev': (e['rev'] as num?)?.toInt() ?? 0,
        'op': 'delete',
      }
    ]);
    final bad = results.where((r2) => r2['status'] != 'ok').toList();
    if (bad.isNotEmpty) {
      throw ApiException(200, '删除被拒: ${bad.map((r2) => r2['status']).join(",")}');
    }
    await refresh();
  }

  /// 增量同步：从本地库游标拉取变更 → 折叠进本地库 → 重建视图。
  Future<void> refresh() async {
    loading = true;
    error = null;
    // 首次状态派发让出当前事件循环再执行（评审"附加观察 1"）：调用方常在 build 栈内
    // 触发 refresh（HostsPage.initState），同步 notifyListeners 会于首帧 build 期间
    // markNeedsBuild（debug 断言 + 该帧 build 中断）。延迟后派发，状态下一帧生效。
    await Future<void>.delayed(Duration.zero);
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
    } catch (e) {
      // 本地库 FFI 等非网络错误同样降级为同步失败横幅，不得逃逸成未处理异常
      error = '$e';
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// 添加主机：host(+可选 group) + host_protocol(ssh)。
  /// 口令认证 → identity.password_enc；私钥认证 → ssh_key 实体 + identity.key_id
  /// （或从 Keychain 复用已有密钥：existingKeyId 直指 identity.key_id，不建新实体）。
  /// 全部走中枢（服务端静态加密），重启与跨设备可用。
  Future<void> addHost({
    required String label,
    required String hostname,
    required int port,
    required String username,
    required bool usePassword,
    required String secret,
    String? existingKeyId,
    String? groupId,
    String? newGroupName,
  }) async {
    // 复用 Keychain 密钥前校验其仍存在（他端并发删除竞态，评审 P2）
    if (!usePassword &&
        existingKeyId != null &&
        existingKeyId.isNotEmpty &&
        !_entities.containsKey('ssh_key/$existingKeyId')) {
      throw ApiException(200, '所选密钥不存在或已被删除，请刷新后重新选择');
    }
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
      final keyId = (existingKeyId != null && existingKeyId.isNotEmpty)
          ? existingKeyId
          : _newUuid();
      if (existingKeyId == null || existingKeyId.isEmpty) {
        changes.add(_upsert('ssh_key', keyId, {
          'label': label,
          'key_type': 'imported-pem',
          'private_enc': secret,
          'public_key': '',
          'fingerprint': '',
          'origin': 'imported',
          'key_version': 1,
        }));
      }
      changes.add(_upsert('identity', identityId, {
        'label': username,
        'username': username,
        'password_enc': null, // 显式 null：私钥认证的 identity 必清口令列
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
    try {
      local.logEvent(kind: 'host_add', detail: '$label（$hostname）');
    } catch (_) {}
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
      // Keychain 复用后一把密钥可被多台主机共享：仅当删除后无其他主机引用
      // 才下线 ssh_key，否则保留（评审 P0：删主机不得毁掉共享密钥连累他机）。
      if (keyId != null && !_keyReferencedByOtherHost(keyId, exceptHostId: h.id)) {
        tomb('ssh_key', keyId);
      }
    }
    if (changes.isEmpty) return;
    final results = await api.push(changes);
    final bad = results.where((r) => r['status'] != 'ok').toList();
    if (bad.isNotEmpty) {
      throw ApiException(200, '删除被拒: ${bad.map((r) => r['status']).join(",")}');
    }
    try {
      local.logEvent(kind: 'host_delete', detail: h.label);
    } catch (_) {}
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
  /// 私钥替换二选一：replaceKeyPem 粘贴新 PEM（新建 ssh_key 实体——服务端禁止
  /// 覆盖既有密钥内容 immutable，重指 key_id）或 replaceWithKeyId 从 Keychain
  /// 复用已有密钥（identity.key_id 直指）。
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
    String? replaceWithKeyId,
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
    if (replaceWithKeyId != null &&
        replaceWithKeyId.isNotEmpty &&
        !_entities.containsKey('ssh_key/$replaceWithKeyId')) {
      throw ApiException(200, '所选密钥不存在或已被删除，请刷新后重新选择');
    }

    // 编辑模式必须显式发送 group_id（含 null=移出分组）：`?null` 会省略键，
    // 服务端 push 是部分更新语义，缺键不改列 → 移出分组静默失败
    changes.add(_update('host', host.id, {
      'label': label,
      'hostname': hostname,
      'tags': _entities['host/${host.id}']?['tags'] ?? <String>[],
      'group_id': effectiveGroupId,
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
      if (replaceWithKeyId != null && replaceWithKeyId.isNotEmpty) {
        keyId = replaceWithKeyId;
      } else if (replaceKeyPem != null && replaceKeyPem.isNotEmpty) {
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
    try {
      local.logEvent(kind: 'host_edit', detail: '$label（$hostname）');
    } catch (_) {}
    await refresh();
  }

  String? _protocolIdOf(String hostId) {
    for (final e in _entities.values) {
      if (e['kind'] == 'ssh' && e['host_id'] == hostId) return e['id'] as String?;
    }
    return null;
  }

  /// keyId 是否仍被（除 exceptHostId 外的）其他主机经 identity 引用。
  bool _keyReferencedByOtherHost(String keyId, {required String exceptHostId}) {
    // identityId → keyId
    final keyOfIdentity = <String, String>{};
    for (final e in _entities.values) {
      if (e['id'] == null) continue;
      final kid = e['key_id'];
      if (kid is String && kid.isNotEmpty) keyOfIdentity[e['id'] as String] = kid;
    }
    for (final e in _entities.values) {
      if (e['kind'] != 'ssh') continue;
      final hid = e['host_id'] as String?;
      if (hid == null || hid == exceptHostId) continue;
      final cfg = (e['config_json'] ?? <String, dynamic>{}) as Map<String, dynamic>;
      final iid = cfg['identity_id'] as String?;
      if (iid != null && keyOfIdentity[iid] == keyId) return true;
    }
    return false;
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

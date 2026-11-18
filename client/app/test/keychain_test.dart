// Keychain 管理功能回归测试（M1 收口）。
// wire 契约重点（AGENTS.md）：编辑已有实体必须显式发字段——renameKey 回传全部
// ssh_key wire 字段且 private_enc 原样（服务端密钥内容不可变校验）；
// addHost 复用已有密钥时 identity.key_id 直指、不再新建 ssh_key 实体。
// push/pull 走本地 HttpServer 桩捕获请求体；Rust FFI（keyInspect 等）测试注入替身。

import 'dart:convert';
import 'dart:io';

import 'package:eterm/services/api_client.dart';
import 'package:eterm/services/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// 固定 Ed25519 OpenSSH 私钥（Rust known-answer 测试同一把，seed=[42;32]，
/// 指纹 SHA256:1Lt0B6m58n9i5yp9hABit7qhCJ/7aR7kRxt8QRziO8k）。
const testPem = '''-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACAZf2sj4WyFMsaryDj6zV6nib4MdrKSAzQDm/qLPTaNYQAAAIgP2B4SD9ge
EgAAAAtzc2gtZWQyNTUxOQAAACAZf2sj4WyFMsaryDj6zV6nib4MdrKSAzQDm/qLPTaNYQ
AAAEAqKioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKhl/ayPhbIUyxqvIOPrNXqeJ
vgx2spIDNAOb+os9No1hAAAAAmthAQID
-----END OPENSSH PRIVATE KEY-----''';

const testFp = 'SHA256:1Lt0B6m58n9i5yp9hABit7qhCJ/7aR7kRxt8QRziO8k';
const testPubLine = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBl/ayPhbIUyxqvIOPrNXqeJvgx2spIDNAOb+os9No1h';

KeyMetaView fakeInspect(String pem) => KeyMetaView(
      keyType: 'ssh-ed25519',
      fingerprint: testFp,
      publicKeyLine: testPubLine,
    );

/// 本地同步桩：记录 push 请求体；pull 返回空集（游标 0）。
class SyncStub {
  HttpServer? _server;
  final pushes = <List<Map<String, dynamic>>>[];

  Future<ApiClient> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((req) async {
      if (req.uri.path == '/api/v1/sync/push') {
        final body =
            jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
        pushes.add((body['changes'] as List).cast<Map<String, dynamic>>());
        req.response.statusCode = 200;
        req.response
            .write(jsonEncode({'results': [for (final _ in pushes.last) {'status': 'ok'}]}));
        await req.response.close();
        return;
      }
      // pull：空增量
      req.response.statusCode = 200;
      req.response
          .write(jsonEncode({'changes': [], 'cursor': 0, 'has_more': false}));
      await req.response.close();
    });
    return ApiClient(baseUrl: 'http://127.0.0.1:${server.port}');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
  }
}

Map<String, Map<String, dynamic>> sshKeyEntity(String id, String label) => {
      'ssh_key/$id': {
        'id': id,
        'label': label,
        'key_type': 'ssh-ed25519',
        'private_enc': testPem,
        'public_key': testPubLine,
        'fingerprint': testFp,
        'origin': 'generated',
        'key_version': 1,
        'rev': 3,
      },
    };

Map<String, Map<String, dynamic>> hostTriple(String hid, String label, String identityId) =>
    {
      'host/$hid': {
        'id': hid,
        'label': label,
        'hostname': '$hid.example.com',
        'tags': <String>[],
        'group_id': null,
      },
      'identity/$identityId': {
        'id': identityId,
        'label': 'root',
        'username': 'root',
        'password_enc': null,
        'key_id': 'k1',
      },
      'host_protocol/$hid-p': {
        'id': '$hid-p',
        'host_id': hid,
        'kind': 'ssh',
        'config_json': {'port': 22, 'username': 'root', 'identity_id': identityId},
        'sort': 0,
      },
    };

void main() {
  late SyncStub stub;

  setUp(() async {
    stub = SyncStub();
  });

  tearDown(() => stub.stop());

  test('importKey：push 完整 ssh_key wire 字段（origin=imported + Rust 校验的指纹/公钥行）',
      () async {
    final api = await stub.start();
    final app = AppState(api: api, inspectPem: fakeInspect);
    await app.importKey(label: 'ka', pem: testPem);

    expect(stub.pushes.length, greaterThanOrEqualTo(1),
        reason: 'importKey 应推送一个 ssh_key 实体');
    final change = stub.pushes.first.single;
    expect(change['entity_type'], 'ssh_key');
    expect(change['op'], 'upsert');
    final data = change['data'] as Map<String, dynamic>;
    // wire 契约：新建 upsert 必须显式带全部字段
    expect(data['label'], 'ka');
    expect(data['key_type'], 'ssh-ed25519');
    expect(data['private_enc'], testPem);
    expect(data['public_key'], testPubLine);
    expect(data['fingerprint'], testFp);
    expect(data['origin'], 'imported');
    expect(data['key_version'], 1);
  });

  test('renameKey：显式回传全部 wire 字段，private_enc 原样（不可变校验 + 部分更新语义）',
      () async {
    final api = await stub.start();
    final app = AppState(api: api, inspectPem: fakeInspect);
    app.debugSetEntities(sshKeyEntity('k1', '旧名'));
    await app.renameKey(app.keys.single, '新名');

    final change = stub.pushes.first.single;
    expect(change['entity_type'], 'ssh_key');
    expect(change['entity_id'], 'k1');
    expect(change['base_rev'], 3, reason: '编辑必须带当前 rev，否则服务端判冲突');
    expect(change['op'], 'upsert');
    final data = change['data'] as Map<String, dynamic>;
    expect(data['label'], '新名');
    // 改名只动 label，其余字段显式原样回传（缺键会被服务端当"不改"，
    // 显式回传可防服务端校验失败并保证幂等）
    expect(data['key_type'], 'ssh-ed25519');
    expect(data['private_enc'], testPem, reason: 'private_enc 必须原样回传');
    expect(data['public_key'], testPubLine);
    expect(data['fingerprint'], testFp);
    expect(data['origin'], 'generated');
    expect(data['key_version'], 1);
  });

  test('addHost 复用 Keychain 密钥：identity.key_id 直指，无 ssh_key 实体推送', () async {
    final api = await stub.start();
    final app = AppState(api: api, inspectPem: fakeInspect);
    app.debugSetEntities(sshKeyEntity('k1', 'ka'));
    await app.addHost(
      label: 'k7',
      hostname: '120.26.109.221',
      port: 22,
      username: 'root',
      usePassword: false,
      secret: '',
      existingKeyId: 'k1',
    );

    final changes = stub.pushes.first;
    final types = changes.map((c) => c['entity_type']).toList();
    expect(types.contains('ssh_key'), isFalse,
        reason: '复用已有密钥不得新建 ssh_key 实体');
    final identity = changes.firstWhere((c) => c['entity_type'] == 'identity');
    expect((identity['data'] as Map<String, dynamic>)['key_id'], 'k1');
    expect(identity['data'], containsPair('password_enc', null),
        reason: '私钥认证的 identity 必须显式发 null（区分键缺失：显式 null 才清列）');
  });

  test('addHost 粘贴 PEM：仍新建 ssh_key 实体（向后兼容）', () async {
    final api = await stub.start();
    final app = AppState(api: api, inspectPem: fakeInspect);
    await app.addHost(
      label: 'k7',
      hostname: '120.26.109.221',
      port: 22,
      username: 'root',
      usePassword: false,
      secret: testPem,
    );

    final types = stub.pushes.first.map((c) => c['entity_type']).toList();
    expect(types, containsAll(['ssh_key', 'identity', 'host', 'host_protocol']));
  });

  test('editHost 换绑 Keychain 密钥：identity.key_id 指向所选密钥', () async {
    final api = await stub.start();
    final app = AppState(api: api, inspectPem: fakeInspect);
    app.debugSetEntities({
      ...sshKeyEntity('k1', 'ka'),
      ...sshKeyEntity('k2', 'kb'),
      ...hostTriple('h1', 'k7', 'i1'),
    });
    await app.editHost(
      host: app.hosts.single,
      label: 'k7',
      hostname: 'h1.example.com',
      port: 22,
      username: 'root',
      replaceWithKeyId: 'k2',
    );

    final identityChange = stub.pushes.first
        .firstWhere((c) => c['entity_type'] == 'identity');
    final data = identityChange['data'] as Map<String, dynamic>;
    expect(data['key_id'], 'k2');
    expect(data['password_enc'], isNull);
    // base_rev 必须取当前值（乐观锁）
    expect(identityChange['base_rev'], 0,
        reason: 'hostTriple 里 identity 无 rev 字段 → base_rev 0 也可接受');
  });

  test('keys 视图：反向引用（哪些主机在用）+ publicKey/origin 字段', () async {
    final api = await stub.start();
    final app = AppState(api: api, inspectPem: fakeInspect);
    app.debugSetEntities({
      ...sshKeyEntity('k1', 'ka'),
      ...hostTriple('h1', 'k7', 'i1'),
    });
    final keys = app.keys;
    expect(keys.length, 1);
    expect(keys.single.label, 'ka');
    expect(keys.single.publicKey, testPubLine);
    expect(keys.single.origin, 'generated');
    expect(keys.single.usedBy, ['k7']);
    expect(app.keyIdOfIdentity('i1'), 'k1');
    expect(app.keyIdOfIdentity(null), isNull);
  });

  test('deployCommandFor：authorized_keys 幂等追加 + 撇号转义/换行剔除防注入', () {
    final cmd = AppState.deployCommandFor('$testPubLine ka');
    expect(cmd, contains("grep -qxF '$testPubLine ka'"));
    expect(cmd, contains("printf '%s\\n' '$testPubLine ka'"));
    expect(cmd, contains('mkdir -p ~/.ssh'));
    expect(cmd, contains('chmod 700 ~/.ssh'));
    expect(cmd, contains('chmod 600 ~/.ssh/authorized_keys'));
    // 注入防护：模板本身恰有 6 个单引号（grep 定界对 + printf 的 '%s\n' 与行两对）。
    // 行内撇号按 POSIX '\'' 转义保真（评审 P2）：每撇号 +2 引号，不得裸露。
    final evil = AppState.deployCommandFor("ssh-ed25519 AAAA it's\nrm -rf /");
    expect(evil.contains('\n'), isFalse, reason: '换行必须被剔除（不得拆出第二条命令）');
    // 6 模板定界 + 行内 1 撇号 × '\''（3 撇号字符）× grep/printf 两处 = 12
    expect("'".allMatches(evil).length, 12, reason: '撇号必须以 POSIX 转义出现');
    expect(evil.contains("'\\''"), isTrue, reason: '撇号以转义序列出现');
    expect(evil.contains("'rm -rf /'"), isFalse, reason: '清洗后不得构成独立引号段');
  });

  test('deleteHost 共享密钥保护：密钥被其他主机引用时不墓碑 ssh_key（评审 P0 回归）',
      () async {
    final api = await stub.start();
    final app = AppState(api: api, inspectPem: fakeInspect);
    // k1 经两条 identity 被 h1/h2 共享
    app.debugSetEntities({
      ...sshKeyEntity('k1', 'ka'),
      ...hostTriple('h1', 'host-a', 'i1'),
      ...hostTriple('h2', 'host-b', 'i2'),
    });
    await app.deleteHost(app.hosts.firstWhere((h) => h.id == 'h1'));

    final changes = stub.pushes.first;
    expect(changes.any((c) => c['entity_type'] == 'ssh_key'), isFalse,
        reason: '共享密钥不得随任一主机删除（否则其余主机凭据悬空）');
    expect(
        changes.any((c) =>
            c['entity_type'] == 'identity' && c['entity_id'] == 'i1'),
        isTrue,
        reason: 'identity 本身仍随主机下线');
  });

  test('deleteHost 唯一引用：主机删除连带 ssh_key 墓碑（原语义保留）', () async {
    final api = await stub.start();
    final app = AppState(api: api, inspectPem: fakeInspect);
    app.debugSetEntities(
        {...sshKeyEntity('k1', 'ka'), ...hostTriple('h1', 'host-a', 'i1')});
    await app.deleteHost(app.hosts.single);
    expect(stub.pushes.first.any((c) => c['entity_type'] == 'ssh_key'), isTrue);
  });

  test('deleteKey 孤立 identity 直引拒绝删除（评审 P2 回归）', () async {
    final api = await stub.start();
    final app = AppState(api: api, inspectPem: fakeInspect);
    // identity 存在但没有 host_protocol 连接 → usedBy 为空，仍不得删
    app.debugSetEntities({
      ...sshKeyEntity('k1', 'ka'),
      'identity/orphan': {
        'id': 'orphan',
        'label': '孤凭据',
        'username': 'u',
        'password_enc': null,
        'key_id': 'k1',
      },
    });
    await expectLater(
        app.deleteKey(app.keys.single), throwsA(isA<ApiException>()));
  });

  test('importKey 指纹去重：同一 PEM 二次导入被拒（评审 P2 回归）', () async {
    final api = await stub.start();
    final app = AppState(api: api, inspectPem: fakeInspect);
    app.debugSetEntities(sshKeyEntity('k1', 'ka'));
    await expectLater(app.importKey(label: 'dup', pem: testPem),
        throwsA(isA<ApiException>()));
    expect(stub.pushes, isEmpty, reason: '重复导入不得推送');
  });

  // ---------- Identity 管理（F4.1 引用式） ----------

  Map<String, Map<String, dynamic>> passwordIdentity(String id) => {
        'identity/$id': {
          'id': id,
          'label': 'root',
          'username': 'root',
          'password_enc': 'old-pass',
          'key_id': null,
        },
      };

  test('identities 视图：口令/密钥认证识别 + usedBy 反查主机', () async {
    final api = await stub.start();
    final app = AppState(api: api, inspectPem: fakeInspect);
    app.debugSetEntities({
      ...sshKeyEntity('k1', 'ka'),
      ...hostTriple('h1', 'host-a', 'i1'),
    });

    final ids = app.identities;
    expect(ids, hasLength(1));
    final v = ids.single;
    expect(v.id, 'i1');
    expect(v.username, 'root');
    expect(v.hasPassword, isFalse);
    expect(v.keyId, 'k1');
    expect(v.keyLabel, 'ka');
    expect(v.usedBy, ['host-a']);
    expect(v.authKindText, 'ka');
  });

  test('updateIdentity 密钥→口令：显式回传 4 字段（password_enc 写入、key_id null 清列）',
      () async {
    final api = await stub.start();
    final app = AppState(api: api, inspectPem: fakeInspect);
    app.debugSetEntities({
      ...sshKeyEntity('k1', 'ka'),
      ...hostTriple('h1', 'host-a', 'i1'),
    });
    await app.updateIdentity(
      identity: app.identities.single,
      username: 'ops',
      usePassword: true,
      password: 'new-pass',
    );

    final change = stub.pushes.first.single;
    expect(change['entity_type'], 'identity');
    expect(change['entity_id'], 'i1');
    expect(change['base_rev'], 0, reason: 'hostTriple 快照未带 rev');
    final data = change['data'] as Map<String, dynamic>;
    // wire 契约：4 个 wire 字段全部显式（部分更新语义下缺键=不改）
    expect(data['label'], 'ops');
    expect(data['username'], 'ops');
    expect(data['password_enc'], 'new-pass');
    // 显式 null 才清列：断言键存在且值为 null（isNull 对"缺键"也通过，强度不足
    // ——与上一轮 OBS-1 同一标准，评审 OBS-1 回归）
    expect(data, containsPair('key_id', null),
        reason: 'key_id 必须显式 null 清列（?null 省键陷阱）');
  });

  test('updateIdentity 口令→密钥：password_enc 显式 null 清列 + 目标密钥存在校验',
      () async {
    final api = await stub.start();
    final app = AppState(api: api, inspectPem: fakeInspect);
    app.debugSetEntities({
      ...sshKeyEntity('k1', 'ka'),
      ...sshKeyEntity('k2', 'kb'),
      ...passwordIdentity('i1'),
    });
    await app.updateIdentity(
      identity: app.identities.single,
      username: 'root',
      usePassword: false,
      keyId: 'k2',
    );

    final data = stub.pushes.first.single['data'] as Map<String, dynamic>;
    expect(data, containsPair('password_enc', null),
        reason: '切密钥认证必须显式 null 清口令列（缺键=不改的陷阱面）');
    expect(data['key_id'], 'k2');

    // 不存在的密钥 id：拒绝且不推送
    await expectLater(
        app.updateIdentity(
          identity: app.identities.single,
          username: 'root',
          usePassword: false,
          keyId: 'nope',
        ),
        throwsA(isA<ApiException>()));
  });

  test('updateIdentity 留空口令：保留原口令；无旧口令且留空 → 拒绝', () async {
    final api = await stub.start();
    final app = AppState(api: api, inspectPem: fakeInspect);
    app.debugSetEntities(passwordIdentity('i1'));
    await app.updateIdentity(
      identity: app.identities.single,
      username: 'root',
      usePassword: true,
      password: '',
    );
    expect(
        (stub.pushes.first.single['data'] as Map<String, dynamic>)['password_enc'],
        'old-pass');

    final app2 = AppState(api: api, inspectPem: fakeInspect);
    app2.debugSetEntities({
      'identity/i2': {
        'id': 'i2',
        'label': 'u2',
        'username': 'u2',
        'password_enc': null,
        'key_id': null,
      },
    });
    await expectLater(
        app2.updateIdentity(
          identity: app2.identities.single,
          username: 'u2',
          usePassword: true,
          password: '',
        ),
        throwsA(isA<ApiException>()),
        reason: '无可保留口令时留空必须报错（不得静默写成无凭据）');
  });

  test('deleteIdentity 被主机引用拒绝；未引用走墓碑（带 base_rev）', () async {
    final api = await stub.start();
    final app = AppState(api: api, inspectPem: fakeInspect);
    app.debugSetEntities({
      ...sshKeyEntity('k1', 'ka'),
      ...hostTriple('h1', 'host-a', 'i1'),
      ...passwordIdentity('i2'),
    });
    // i1 被 host-a 引用 → 拒绝且不推送
    final referenced = app.identities.firstWhere((v) => v.id == 'i1');
    await expectLater(app.deleteIdentity(referenced), throwsA(isA<ApiException>()));
    expect(stub.pushes, isEmpty);

    // i2 无引用 → 墓碑
    final free = app.identities.firstWhere((v) => v.id == 'i2');
    await app.deleteIdentity(free);
    final change = stub.pushes.first.single;
    expect(change['entity_type'], 'identity');
    expect(change['entity_id'], 'i2');
    expect(change['op'], 'delete');
    expect(change['base_rev'], 0);
  });
}

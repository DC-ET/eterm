//! Keychain FFI 面（M1 收口）：Ed25519/ECDSA/RSA 生成 / 私钥导入校验 / 一次性
//! 远程执行（部署公钥用）。密钥内容只经应用自有加密库（LKMK）落盘，不碰 OS 钥匙串。

use crate::util::sshkey::{self, SshKeyMeta};

/// 生成密钥对。algorithm ∈ ed25519 | ecdsa-p256 | rsa-2048 | rsa-3072 | rsa-4096。
/// RSA 质数生成可达秒级：async + spawn_blocking，不得跑 UI 线程（frb sync 陷阱，
/// 见 AGENTS.md）。Ed25519/ECDSA 毫秒级，同走此入口保持单一通路。
#[flutter_rust_bridge::frb]
pub async fn key_generate(algorithm: String, comment: String) -> Result<KeyGenerateResult, String> {
    let (pem, key_type, fingerprint, public_key_line) = crate::util::ssh_runtime()
        .spawn_blocking(move || {
            let (pem, meta) = match algorithm.as_str() {
                "ed25519" => sshkey::generate_ed25519(&comment),
                "ecdsa-p256" => sshkey::generate_ecdsa_p256(&comment),
                "rsa-2048" => sshkey::generate_rsa(2048, &comment),
                "rsa-3072" => sshkey::generate_rsa(3072, &comment),
                "rsa-4096" => sshkey::generate_rsa(4096, &comment),
                other => return Err(format!("不支持的算法: {other}")),
            }?;
            Ok((pem, meta.key_type, meta.fingerprint, meta.public_key_line))
        })
        .await
        .map_err(|e| format!("生成任务失败: {e}"))??;
    Ok(KeyGenerateResult {
        pem,
        key_type,
        fingerprint,
        public_key_line,
    })
}

/// 校验/解析导入的私钥 PEM（OpenSSH / PKCS#8；口令加密的密钥不支持）。
/// 返回类型 / SHA256 指纹 / 一行公钥（authorized_keys 可直接粘贴）。
#[flutter_rust_bridge::frb(sync)]
pub fn key_inspect(pem: String) -> Result<SshKeyMeta, String> {
    sshkey::inspect_secret(&pem)
}

/// 生成结果：私钥 PEM + 元数据。
pub struct KeyGenerateResult {
    pub pem: String,
    pub key_type: String,
    pub fingerprint: String,
    pub public_key_line: String,
}

/// 一次性远程执行结果。
pub struct ExecResult {
    /// 退出码；远端未回传时为 -1。
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
}

/// 一次性远程执行（部署公钥等）：连接 + 认证 + exec + 收集输出 + 断开。
/// TOFU 校验与终端/SFTP 同一套（known_hosts）。整体 20s 超时。
/// async：网络调用不得跑 UI 线程（frb sync 陷阱，见 AGENTS.md）。
#[flutter_rust_bridge::frb]
pub async fn ssh_exec_oneshot(
    host: String,
    port: u16,
    user: String,
    auth_kind: String,
    secret: String,
    command: String,
) -> Result<ExecResult, String> {
    on_runtime(move || {
        Box::pin(async move {
            let fut = exec_inner(&host, port, &user, &auth_kind, &secret, &command);
            match tokio::time::timeout(std::time::Duration::from_secs(20), fut).await {
                Ok(r) => r,
                Err(_) => Err("远程执行超时（20s）".into()),
            }
        })
    })
    .await
}

/// frb 执行器无 tokio reactor（见 portfw.rs 同名注释）。
async fn on_runtime<T, F>(f: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce() -> futures::future::BoxFuture<'static, Result<T, String>> + Send + 'static,
{
    let (tx, rx) = tokio::sync::oneshot::channel();
    crate::util::ssh_runtime().spawn(async move {
        let _ = tx.send(f().await);
    });
    rx.await.map_err(|_| "内部通道关闭".to_string())?
}

async fn exec_inner(
    host: &str,
    port: u16,
    user: &str,
    auth_kind: &str,
    secret: &str,
    command: &str,
) -> Result<ExecResult, String> {
    let conn = crate::api::ssh::connect_and_auth(host, port, user, auth_kind, secret).await?;
    let result = exec_on(conn.as_ref(), command).await;
    conn.shutdown().await;
    result
}

async fn exec_on(
    conn: &dyn crate::util::AuthedConn,
    command: &str,
) -> Result<ExecResult, String> {
    let mut ch = conn
        .open_session()
        .await
        .map_err(|e| format!("打开会话通道失败: {e}"))?;
    ch.exec(true, command)
        .await
        .map_err(|e| format!("exec 请求失败: {e}"))?;
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let mut exit_code: i32 = -1;
    loop {
        match ch.wait().await {
            Some(russh::ChannelMsg::Data { data }) => stdout.extend_from_slice(&data),
            Some(russh::ChannelMsg::ExtendedData { data, .. }) => stderr.extend_from_slice(&data),
            Some(russh::ChannelMsg::ExitStatus { exit_status }) => {
                exit_code = exit_status as i32;
            }
            // 通道关闭/EOF：exec 是短生命周期通道，Close 即输出收尾
            Some(russh::ChannelMsg::Eof) => {}
            Some(russh::ChannelMsg::Close) | None => break,
            Some(_) => {}
        }
    }
    let _ = ch.eof().await;
    Ok(ExecResult {
        exit_code,
        stdout: String::from_utf8_lossy(&stdout).into_owned(),
        stderr: String::from_utf8_lossy(&stderr).into_owned(),
    })
}

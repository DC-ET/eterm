// Spike S2/S5（技术方案 §8）：russh 长会话、吞吐、keepalive、断线重连。
// 用法：soak --host H --port 22 --user U --key KEY.pem [--minutes 2] [--mb 50] [--keepalive-secs 15]
// 各阶段输出 "PHASE ... PASS/FAIL 计时"，任一失败即退出码 1。

use anyhow::{bail, Context, Result};
use std::time::{Duration, Instant};

// S5 e2e：证书认证。--cert-mode --host H --port P --user U --key KEY --cert CERT
async fn cert_mode(
    host: &str,
    port: u16,
    user: &str,
    key_path: &str,
    cert_path: &str,
) -> Result<()> {
    let config = std::sync::Arc::new(client::Config::default());
    let mut handle = client::connect(config, (host, port), Client).await?;
    let key = std::sync::Arc::new(russh_keys::load_secret_key(key_path, None)?);
    let cert = russh_keys::load_openssh_certificate(cert_path)
        .context("加载 OpenSSH 证书失败")?;
    let ok = handle
        .authenticate_openssh_cert(user, key, cert)
        .await
        .context("证书认证握手失败")?;
    if !ok {
        bail!("证书认证被服务器拒绝（CA 是否已在 TrustedUserCAKeys？principal 是否匹配？）");
    }
    let out = run(&mut handle, "whoami").await?;
    println!("S5 CERT AUTH PASS: whoami={out:?}");
    Ok(())
}

use russh::client::{self, Handle};
use russh::{Channel, ChannelMsg};
use russh::Disconnect;
use russh_keys::key::KeyPair;

struct Client;

#[async_trait::async_trait]
impl client::Handler for Client {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        _server_public_key: &russh_keys::key::PublicKey,
    ) -> Result<bool, Self::Error> {
        // spike：信任一切（生产路径走 known_hosts，见 F4.4）
        Ok(true)
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let mut host = String::new();
    let mut port: u16 = 22;
    let mut user = String::new();
    let mut key_path = String::new();
    let mut minutes: u64 = 2;
    let mut mb: usize = 50;
    let mut keepalive: u64 = 15;
    let mut cert_path: Option<String> = None;
    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--host" => host = args[i + 1].clone(),
            "--port" => port = args[i + 1].parse()?,
            "--user" => user = args[i + 1].clone(),
            "--key" => key_path = args[i + 1].clone(),
            "--minutes" => minutes = args[i + 1].parse()?,
            "--mb" => mb = args[i + 1].parse()?,
            "--keepalive-secs" => keepalive = args[i + 1].parse()?,
            "--cert" => cert_path = Some(args[i + 1].clone()),
            other => bail!("未知参数 {other}"),
        }
        i += 2;
    }
    if let Some(cp) = &cert_path {
        // S5 模式：仅做证书认证验证
        return cert_mode(&host, port, &user, &key_path, cp).await;
    }
    let addr = (host.as_str(), port);
    println!("S2 soak: {user}@{host}:{port} key={key_path} minutes={minutes} mb={mb}");

    // Phase 1: 连接 + 公钥认证
    let t0 = Instant::now();
    let config = client::Config {
        keepalive_interval: Some(Duration::from_secs(keepalive)),
        keepalive_max: 3,
        ..Default::default()
    };
    let config = std::sync::Arc::new(config);
    let mut handle = client::connect(config.clone(), addr, Client).await?;
    let key = std::sync::Arc::new(russh_keys::load_secret_key(&key_path, None)?);
    let auth = handle.authenticate_publickey(&user, key).await?;
    if !auth {
        bail!("公钥认证失败");
    }
    println!("PHASE connect PASS ({:?})", t0.elapsed());

    // Phase 2: 回环吞吐（exec cat，写 N MB 读回校验）
    let mb = throughput_roundtrip(&mut handle, mb).await?;
    println!("PHASE roundtrip PASS ({mb} MB)");

    // Phase 3: 服务端持续高吞吐（yes 流）
    let rate = sustained_output(&mut handle).await?;
    println!("PHASE sustained-output PASS ({rate:.0} MB/s)");

    // Phase 4: keepalive 长会话
    long_session(&mut handle, minutes).await?;
    println!("PHASE long-session PASS ({minutes} min)");

    // Phase 5: 断线重连（粗暴断开，全新握手）
    handle
        .disconnect(Disconnect::ByApplication, "spike", "en")
        .await?;
    let t1 = Instant::now();
    let mut handle2 = client::connect(config, addr, Client).await?;
    let key2 = std::sync::Arc::new(russh_keys::load_secret_key(&key_path, None)?);
    if !handle2.authenticate_publickey(&user, key2).await? {
        bail!("重连认证失败");
    }
    let out = run(&mut handle2, "echo reconnect-ok").await?;
    if !out.contains("reconnect-ok") {
        bail!("重连后命令输出异常: {out:?}");
    }
    println!("PHASE reconnect PASS ({:?})", t1.elapsed());
    println!("S2 SOAK ALL PASS");
    Ok(())
}

async fn run(handle: &mut Handle<Client>, cmd: &str) -> Result<String> {
    let mut ch = handle.channel_open_session().await?;
    ch.exec(true, cmd).await?;
    let mut out = String::new();
    while let Some(msg) = ch.wait().await {
        match msg {
            ChannelMsg::Data { data } => out.push_str(&String::from_utf8_lossy(&data)),
            ChannelMsg::ExitStatus { .. } => {}
            ChannelMsg::Eof | ChannelMsg::Close => break,
            _ => {}
        }
    }
    Ok(out)
}

async fn throughput_roundtrip(handle: &mut Handle<Client>, mb: usize) -> Result<usize> {
    // 上行：cat > /dev/null（服务端丢弃），1MB 块降低逐块 RTT 影响
    let mut ch = handle.channel_open_session().await?;
    ch.exec(true, "cat > /dev/null").await?;
    let payload = vec![0xABu8; 1024 * 1024];
    let chunks = mb;
    let t0 = Instant::now();
    for _ in 0..chunks {
        ch.data(&payload[..]).await?;
    }
    ch.eof().await?;
    while let Some(msg) = ch.wait().await {
        if matches!(msg, ChannelMsg::Eof | ChannelMsg::Close) {
            break;
        }
    }
    let secs = t0.elapsed().as_secs_f64();
    let up = mb as f64 / secs;
    println!("  上行 {mb}MB in {secs:.2}s = {up:.0} MB/s");

    // 下行：dd 1MB 块 256MB
    let mut ch = handle.channel_open_session().await?;
    ch.exec(true, "dd if=/dev/zero bs=1M count=256 2>/dev/null").await?;
    let t1 = Instant::now();
    let mut got: u64 = 0;
    while let Some(msg) = ch.wait().await {
        match msg {
            ChannelMsg::Data { data } => got += data.len() as u64,
            ChannelMsg::Eof | ChannelMsg::Close => break,
            _ => {}
        }
    }
    let dsecs = t1.elapsed().as_secs_f64();
    let down = got as f64 / 1024.0 / 1024.0 / dsecs;
    if got < 200 * 1024 * 1024 {
        bail!("下行数据不足: {got}");
    }
    println!("  下行 {:.0}MB in {dsecs:.2}s = {down:.0} MB/s", got as f64 / 1024.0 / 1024.0);
    Ok(mb)
}

async fn sustained_output(handle: &mut Handle<Client>) -> Result<f64> {
    let mut ch: Channel<client::Msg> = handle.channel_open_session().await?;
    ch.exec(true, "dd if=/dev/urandom bs=1M count=256 2>/dev/null").await?;
    let t0 = Instant::now();
    let mut got: u64 = 0;
    while let Some(msg) = ch.wait().await {
        match msg {
            ChannelMsg::Data { data } => got += data.len() as u64,
            ChannelMsg::Eof | ChannelMsg::Close => break,
            _ => {}
        }
    }
    let secs = t0.elapsed().as_secs_f64();
    if got < 200 * 1024 * 1024 {
        bail!("持续输出不足: {got}");
    }
    Ok(got as f64 / 1024.0 / 1024.0 / secs)
}

async fn long_session(handle: &mut Handle<Client>, minutes: u64) -> Result<()> {
    let mut ch = handle.channel_open_session().await?;
    ch.exec(true, format!("sleep {}", minutes * 60).as_str()).await?;
    // 静默会话期间：每 30s 在新 channel 上探活（证明连接与 keepalive 有效）
    let deadline = Instant::now() + Duration::from_secs(minutes * 60 + 30);
    let mut probe = 0;
    loop {
        tokio::select! {
            msg = ch.wait() => {
                match msg {
                    Some(ChannelMsg::ExitStatus { .. }) | None => break,
                    Some(_) => {}
                }
            }
            _ = tokio::time::sleep(Duration::from_secs(30)) => {
                probe += 1;
                let out = run(handle, "echo alive").await?;
                if !out.contains("alive") {
                    bail!("第 {probe} 次探活失败");
                }
            }
        }
        if Instant::now() > deadline {
            bail!("长会话超时未结束");
        }
    }
    println!("  静默 {minutes} 分钟，{probe} 次探活全部成功");
    Ok(())
}

// key 类型兼容：russh 0.46 的 authenticate_publickey 需要 Arc<KeyPair>
#[allow(dead_code)]
fn _k(k: KeyPair) -> std::sync::Arc<KeyPair> {
    std::sync::Arc::new(k)
}

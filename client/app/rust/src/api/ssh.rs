//! SSH 会话 FFI 面（S2 spike → app crate 移植，M0 骨架）。
//! 一会话一 PTY shell；主机键校验随 F4.4 落地（当前信任一切，与 spike 一致）。
//! 结构：connect 注册会话（命令 mpsc + 事件 broadcast）→ pump 任务独占 russh Channel；
//! write/resize/close 经命令通道转发；事件未订阅前入积压队列，events() 订阅时先补发再接续。

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use crate::frb_generated::StreamSink;

/// 会话事件：数据帧 / 会话终止（含连接与认证阶段的错误文本）。
/// Clone 为 broadcast 通道要求（每个接收者一份拷贝）。
#[derive(Debug, Clone)]
pub enum SshEvent {
    Data { bytes: Vec<u8> },
    Closed { reason: String },
}

/// 泵命令：Dart → 会话任务的写/改窗/关。
enum Cmd {
    Write(Vec<u8>),
    Resize(u32, u32),
    Close,
}

struct SessionInner {
    ev_tx: Option<tokio::sync::broadcast::Sender<SshEvent>>,
    backlog: VecDeque<SshEvent>, // events() 订阅前的输出，订阅时先补发
    ended: bool,
}

struct Session {
    cmd_tx: tokio::sync::mpsc::Sender<Cmd>,
    inner: Mutex<SessionInner>,
}

static NEXT_ID: AtomicU64 = AtomicU64::new(1);
static SESSIONS: Mutex<Option<HashMap<u64, Arc<Session>>>> = Mutex::new(None);

// tokio runtime 迁至 util::ssh_runtime（api/ 之外，避开 frb 扫描；终端/SFTP/端口转发共用）
use crate::util::ssh_runtime;

fn runtime() -> &'static tokio::runtime::Runtime {
    ssh_runtime()
}

// ---------- 信任策略（F4.4：known_hosts TOFU） ----------

/// 主机键 TOFU 校验器（私有：SFTP 连接有各自的私有 handler，共用 store::tofu_decide）。
/// 不匹配拒绝时留下原因（run_inner 读取后拼进错误）。
struct HostKeyChecker {
    host_key: String, // "host:port"
    /// 不匹配拒绝时的详细信息（已知指纹 vs 服务器指纹）。
    reject_reason: std::sync::Arc<std::sync::Mutex<Option<String>>>,
}

#[async_trait::async_trait]
impl russh::client::Handler for HostKeyChecker {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        server_public_key: &russh_keys::key::PublicKey,
    ) -> Result<bool, Self::Error> {
        let fingerprint = format!("SHA256:{}", server_public_key.fingerprint());
        let key_type = server_public_key.name().to_string();
        match crate::store::tofu_decide(&self.host_key, &fingerprint, &key_type) {
            crate::store::TofuDecision::Trust => Ok(true),
            crate::store::TofuDecision::Reject(reason) => {
                // russh::Error 无可携带消息的变体，原因经 reject_reason 由 run_inner 拼进错误
                *self.reject_reason.lock().unwrap() = Some(reason);
                Ok(false)
            }
        }
    }
}

/// 当前时间的 RFC3339 UTC（秒级足够；避免引入 chrono）。
fn chrono_now_rfc3339() -> String {
    crate::util::rfc3339_from_unix(crate::util::unix_now_secs())
}

/// 建连 + 认证（终端 / SFTP / 端口转发共用入口）。
/// TOFU 校验器私有于本模块：主机键拒绝时把具体原因（含已知 vs 当前指纹）拼进错误文本。
/// 返回对象安全视图 Arc<dyn AuthedConn>（impl Trait 不能做字段类型，调用方统一以此持有）。
pub(crate) async fn connect_and_auth(
    host: &str,
    port: u16,
    user: &str,
    auth_kind: &str,
    secret: &str,
) -> Result<Arc<dyn crate::util::AuthedConn>, String> {
    let config = Arc::new(russh::client::Config {
        keepalive_interval: Some(Duration::from_secs(15)),
        keepalive_max: 3,
        ..Default::default()
    });
    let reject_reason: std::sync::Arc<std::sync::Mutex<Option<String>>> =
        std::sync::Arc::new(std::sync::Mutex::new(None));
    let checker = HostKeyChecker {
        host_key: format!("{host}:{port}"),
        reject_reason: reject_reason.clone(),
    };
    let mut handle = match russh::client::connect(config, (host, port), checker).await {
        Ok(h) => h,
        Err(e) => {
            // 主机键不匹配时优先给出 TOFU 详情（russh 报的是笼统断连）
            if let Some(reason) = reject_reason.lock().unwrap().take() {
                return Err(reason);
            }
            return Err(format!("连接失败: {e}"));
        }
    };
    match auth_kind {
        "password" => match handle.authenticate_password(user, secret).await {
            Ok(true) => {}
            Ok(false) => return Err("认证被拒绝（口令错误）".to_string()),
            Err(e) => return Err(format!("认证失败: {e}")),
        },
        "key" => {
            let key = match russh_keys::decode_secret_key(secret, None) {
                Ok(k) => Arc::new(k),
                Err(e) => return Err(format!("私钥解析失败: {e}")),
            };
            match handle.authenticate_publickey(user, key).await {
                Ok(true) => {}
                Ok(false) => return Err("认证被拒绝（公钥）".to_string()),
                Err(e) => return Err(format!("认证失败: {e}")),
            }
        }
        other => return Err(format!("未知认证方式: {other}")),
    }
    Ok(Arc::new(handle))
}

/// 已认证连接经对象安全 trait 暴露（隐藏 HostKeyChecker 类型）。
#[async_trait::async_trait]
impl crate::util::AuthedConn for russh::client::Handle<HostKeyChecker> {
    async fn open_session(&self) -> Result<russh::Channel<russh::client::Msg>, russh::Error> {
        self.channel_open_session().await
    }

    async fn open_direct(
        &self,
        host: String,
        port: u32,
        origin_addr: String,
        origin_port: u32,
    ) -> Result<russh::Channel<russh::client::Msg>, russh::Error> {
        self.channel_open_direct_tcpip(host, port, origin_addr, origin_port)
            .await
    }

    async fn shutdown(&self) {
        let _ = self
            .disconnect(russh::Disconnect::ByApplication, "eterm", "en")
            .await;
    }
}

// ---------- FFI 面 ----------

/// 建连+认证+开 PTY shell（后台执行），立即返回会话 id。
/// auth_kind：`password`（secret=口令）| `key`（secret=OpenSSH PEM 私钥文本，暂不支持口令短语）。
/// 失败不在此返回，以 `SshEvent::Closed(原因)` 送达事件流。
#[flutter_rust_bridge::frb(sync)]
pub fn ssh_connect(
    host: String,
    port: u16,
    user: String,
    auth_kind: String,
    secret: String,
    cols: u32,
    rows: u32,
) -> Result<u64, String> {
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    // 回收已结束的会话（ended 后事件留在 backlog 供补发；此前未订阅的失败
    // 会话在此处统一清理，避免无界累积）
    if let Some(m) = SESSIONS.lock().unwrap().as_mut() {
        m.retain(|_, s| !s.inner.lock().unwrap().ended);
    }
    let (cmd_tx, mut cmd_rx) = tokio::sync::mpsc::channel::<Cmd>(64);
    let (ev_tx, _) = tokio::sync::broadcast::channel::<SshEvent>(1024);
    let session = Arc::new(Session {
        cmd_tx,
        inner: Mutex::new(SessionInner {
            ev_tx: Some(ev_tx),
            backlog: VecDeque::new(),
            ended: false,
        }),
    });
    SESSIONS.lock().unwrap().get_or_insert_with(HashMap::new).insert(id, session.clone());
    runtime().spawn(async move {
        let reason =
            run_inner(&host, port, &user, &auth_kind, &secret, cols, rows, &mut cmd_rx, &session).await;
        emit(&session, SshEvent::Closed { reason });
        let mut inner = session.inner.lock().unwrap();
        inner.ended = true;
        inner.ev_tx = None; // 断开广播发送端：events() 的 recv 得 Closed → 流关闭
        // backlog 保留（含 Closed）：若 Dart 在会话结束后才订阅（快速失败场景），
        // ssh_events 会补发积压后收尾。注册表清理延迟到下次 ssh_connect 统一回收。
    });
    Ok(id)
}

/// 订阅会话事件流：先补发积压（与订阅同锁，不丢帧），再接续实时事件。
/// 会话结束（Closed 后发送端析构）流自然关闭。
#[flutter_rust_bridge::frb(sync)]
pub fn ssh_events(id: u64, sink: StreamSink<SshEvent>) -> Result<(), String> {
    let (rx, backlog) = {
        let s = SESSIONS
            .lock()
            .unwrap()
            .as_ref()
            .and_then(|m| m.get(&id))
            .cloned()
            .ok_or_else(|| "会话不存在".to_string())?;
        let mut inner = s.inner.lock().unwrap();
        if inner.ended {
            // 会话已结束（如快速失败）：补发积压事件（含 Closed）后自然收尾，
            // 让 Dart 侧拿到真实失败原因而非"会话已结束"
            let backlog: Vec<SshEvent> = inner.backlog.drain(..).collect();
            drop(inner);
            drop(s);
            for ev in backlog {
                let _ = sink.add(ev);
            }
            return Ok(());
        }
        let rx = inner
            .ev_tx
            .as_ref()
            .expect("ended=false 时 ev_tx 必在")
            .subscribe();
        let backlog: Vec<SshEvent> = inner.backlog.drain(..).collect();
        (rx, backlog)
    };
    for ev in backlog {
        let _ = sink.add(ev);
    }
    runtime().spawn(async move {
        let mut rx = rx;
        loop {
            match rx.recv().await {
                Ok(ev) => {
                    if sink.add(ev).is_err() {
                        break;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                    // 极端背压丢帧：终端流可容忍（跳过 n 帧），正常路径 1024 深度足够
                    let _ = n;
                    continue;
                }
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });
    Ok(())
}

/// 向会话写原始字节（键盘输入）。会话不存在或命令通道满时返回错误。
#[flutter_rust_bridge::frb(sync)]
pub fn ssh_write(id: u64, data: Vec<u8>) -> Result<(), String> {
    send_cmd(id, Cmd::Write(data))
}

/// 通知远端 PTY 尺寸变化（xterm onResize）。
#[flutter_rust_bridge::frb(sync)]
pub fn ssh_resize(id: u64, cols: u32, rows: u32) -> Result<(), String> {
    send_cmd(id, Cmd::Resize(cols, rows))
}

/// 关闭会话（EOF + Disconnect），并从注册表移除。
#[flutter_rust_bridge::frb(sync)]
pub fn ssh_close(id: u64) -> Result<(), String> {
    let r = send_cmd(id, Cmd::Close);
    if let Some(m) = SESSIONS.lock().unwrap().as_mut() { m.remove(&id); }
    r
}

/// 列出已信任主机（Known Hosts 页）。
#[flutter_rust_bridge::frb(sync)]
pub fn known_hosts_list() -> Result<Vec<crate::store::KnownHost>, String> {
    crate::store::known_hosts_list().map_err(|e| e.to_string())
}

/// 移除主机信任（下次连接重新 TOFU 首次记录）。
#[flutter_rust_bridge::frb(sync)]
pub fn known_hosts_remove(host: String) -> Result<(), String> {
    crate::store::known_host_remove(&host).map_err(|e| e.to_string())
}

fn send_cmd(id: u64, cmd: Cmd) -> Result<(), String> {
    let tx = SESSIONS
        .lock()
        .unwrap()
        .as_ref()
        .and_then(|m| m.get(&id))
        .ok_or_else(|| "会话不存在".to_string())?
        .cmd_tx
        .clone();
    tx.try_send(cmd).map_err(|e| format!("发送失败: {e}"))
}

/// 事件出口：有订阅者走广播，否则入积压（MOTD/banner 不丢）。
fn emit(session: &Session, ev: SshEvent) {
    let mut inner = session.inner.lock().unwrap();
    if inner.ended {
        return;
    }
    let has_subs = inner
        .ev_tx
        .as_ref()
        .map(|t| t.receiver_count() > 0)
        .unwrap_or(false);
    if !has_subs {
        inner.backlog.push_back(ev);
        if inner.backlog.len() > 4096 {
            inner.backlog.pop_front();
        }
        return;
    }
    if let Some(tx) = &inner.ev_tx {
        let _ = tx.send(ev);
    }
}

// ---------- 会话泵 ----------

async fn run_inner(
    host: &str,
    port: u16,
    user: &str,
    auth_kind: &str,
    secret: &str,
    cols: u32,
    rows: u32,
    cmd_rx: &mut tokio::sync::mpsc::Receiver<Cmd>,
    session: &Session,
) -> String {
    let conn = match connect_and_auth(host, port, user, auth_kind, secret).await {
        Ok(h) => h,
        Err(reason) => return reason,
    };
    let mut ch = match conn.open_session().await {
        Ok(c) => c,
        Err(e) => return format!("打开会话通道失败: {e}"),
    };
    if let Err(e) = ch
        .request_pty(true, "xterm-256color", cols, rows, 0, 0, &[])
        .await
    {
        return format!("PTY 请求失败: {e}");
    }
    if let Err(e) = ch.request_shell(true).await {
        return format!("shell 请求失败: {e}");
    }
    loop {
        tokio::select! {
            cmd = cmd_rx.recv() => {
                match cmd {
                    Some(Cmd::Write(b)) => { let _ = ch.data(&b[..]).await; }
                    Some(Cmd::Resize(c, r)) => { let _ = ch.window_change(c, r, 0, 0).await; }
                    Some(Cmd::Close) | None => break,
                }
            }
            msg = ch.wait() => {
                match msg {
                    Some(russh::ChannelMsg::Data { data }) => {
                        emit(session, SshEvent::Data { bytes: data.to_vec() });
                    }
                    Some(russh::ChannelMsg::ExtendedData { data, .. }) => {
                        // stderr 并入主数据流（终端语义等价，M0 不分通道）
                        emit(session, SshEvent::Data { bytes: data.to_vec() });
                    }
                    Some(russh::ChannelMsg::ExitStatus { .. }) => {}
                    Some(russh::ChannelMsg::Eof) | Some(russh::ChannelMsg::Close) | None => break,
                    Some(_) => {}
                }
            }
        }
    }
    let _ = ch.eof().await;
    conn.shutdown().await;
    "会话结束".to_string()
}

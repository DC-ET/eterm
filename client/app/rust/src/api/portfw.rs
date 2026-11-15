//! 端口转发 FFI 面（M2，local -L 优先）。
//! 模型：pf_connect 建独立 SSH 连接（同 SFTP：数据面直连目标主机，不经中枢）→
//! pf_listen 在本地起 TcpListener，accept 后逐连接开 direct-tcpip 通道双向拷贝 →
//! pf_close_forward 停单个转发 / pf_disconnect 断整个会话（连带全部转发）。
//! remote/dynamic（-R/-D）随 M3 扩展（wire 契约的 kind 枚举已预留）。

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use crate::util::ssh_runtime;

/// 本地转发实例：停机信号（drop/发送都会停 accept 循环，监听器随之析构）。
struct Forward {
    close: tokio::sync::mpsc::Sender<()>,
}

struct PfSession {
    /// 会话挂断（同 SFTP 的 kill 通道语义）。
    kill: tokio::sync::mpsc::Sender<()>,
    /// direct-tcpip 通道经它打开（对象安全视图，Arc 共享到 accept 循环）。
    handle: Arc<dyn crate::util::AuthedConn>,
    forwards: Mutex<HashMap<u64, Forward>>,
}

static NEXT_ID: AtomicU64 = AtomicU64::new(1);
static NEXT_FWD: AtomicU64 = AtomicU64::new(1);
static SESSIONS: Mutex<Option<HashMap<u64, Arc<PfSession>>>> = Mutex::new(None);

fn get(id: u64) -> Result<Arc<PfSession>, String> {
    SESSIONS
        .lock()
        .unwrap()
        .as_ref()
        .and_then(|m| m.get(&id))
        .cloned()
        .ok_or_else(|| "端口转发会话不存在".to_string())
}

/// oneshot 中转：frb 执行器无 tokio reactor（见 sftp.rs 同名注释）。
async fn on_runtime<T, F>(f: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce() -> futures::future::BoxFuture<'static, Result<T, String>> + Send + 'static,
{
    let (tx, rx) = tokio::sync::oneshot::channel();
    ssh_runtime().spawn(async move {
        let _ = tx.send(f().await);
    });
    rx.await.map_err(|_| "内部通道关闭".to_string())?
}

/// 建立转发会话（连接 + 认证完成后返回会话 id；TOFU 与终端/SFTP 同一套）。
#[flutter_rust_bridge::frb]
pub async fn pf_connect(
    host: String,
    port: u16,
    user: String,
    auth_kind: String,
    secret: String,
) -> Result<u64, String> {
    on_runtime(move || {
        Box::pin(async move {
            let handle: Arc<dyn crate::util::AuthedConn> =
                match crate::api::ssh::connect_and_auth(&host, port, &user, &auth_kind, &secret)
                    .await
                {
                    Ok(h) => h,
                    Err(reason) => return Err(reason),
                };
            let (kill_tx, mut kill_rx) = tokio::sync::mpsc::channel::<()>(1);
            let handle2 = handle.clone();
            tokio::spawn(async move {
                let _ = kill_rx.recv().await; // None（发送端 drop）= 同样断开
                handle2.shutdown().await;
            });
            let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
            SESSIONS
                .lock()
                .unwrap()
                .get_or_insert_with(HashMap::new)
                .insert(
                    id,
                    Arc::new(PfSession {
                        kill: kill_tx,
                        handle,
                        forwards: Mutex::new(HashMap::new()),
                    }),
                );
            Ok(id)
        })
    })
    .await
}

/// 起一条本地转发（local -L）：监听 bind_addr:local_port → 目标 host:remote_port。
/// 返回转发 id（pf_close_forward 用）。端口被占用等错误直接返回文本。
#[flutter_rust_bridge::frb]
pub async fn pf_listen(
    session_id: u64,
    bind_addr: String,
    local_port: u16,
    remote_host: String,
    remote_port: u16,
) -> Result<u64, String> {
    let session = get(session_id)?;
    on_runtime(move || {
        Box::pin(async move {
            let listener = tokio::net::TcpListener::bind((bind_addr.as_str(), local_port))
                .await
                .map_err(|e| format!("监听 {bind_addr}:{local_port} 失败: {e}"))?;
            let (close_tx, mut close_rx) = tokio::sync::mpsc::channel::<()>(1);
            let fwd_id = NEXT_FWD.fetch_add(1, Ordering::Relaxed);
            let handle = session.handle.clone();
            let rhost = remote_host.clone();
            tokio::spawn(async move {
                loop {
                    tokio::select! {
                        _ = close_rx.recv() => break,
                        accepted = listener.accept() => {
                            let (mut tcp, peer) = match accepted {
                                Ok(v) => v,
                                Err(_) => break, // 监听套接字异常：停转发
                            };
                            // 逐连接开 direct-tcpip；开失败只断这一条本地连接
                            match handle
                                .open_direct(
                                    rhost.clone(),
                                    remote_port as u32,
                                    peer.ip().to_string(),
                                    peer.port() as u32,
                                )
                                .await
                            {
                                Ok(ch) => {
                                    let mut ch = ch.into_stream();
                                    tokio::spawn(async move {
                                        let _ =
                                            tokio::io::copy_bidirectional(&mut tcp, &mut ch)
                                                .await;
                                    });
                                }
                                Err(_) => continue,
                            }
                        }
                    }
                }
            });
            session
                .forwards
                .lock()
                .unwrap()
                .insert(fwd_id, Forward { close: close_tx });
            Ok(fwd_id)
        })
    })
    .await
}

/// 停一条转发（监听器析构；已建立的连接自然跑到结束）。
#[flutter_rust_bridge::frb(sync)]
pub fn pf_close_forward(session_id: u64, forward_id: u64) -> Result<(), String> {
    let session = get(session_id)?;
    if let Some(fwd) = session.forwards.lock().unwrap().remove(&forward_id) {
        let _ = fwd.close.try_send(());
    }
    Ok(())
}

/// 断开整个转发会话（含全部转发），从注册表移除。幂等。
#[flutter_rust_bridge::frb(sync)]
pub fn pf_disconnect(session_id: u64) -> Result<(), String> {
    let session = SESSIONS
        .lock()
        .unwrap()
        .as_mut()
        .and_then(|m| m.remove(&session_id));
    if let Some(session) = session {
        for (_, fwd) in session.forwards.lock().unwrap().drain() {
            let _ = fwd.close.try_send(());
        }
        let _ = session.kill.try_send(());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// k7 真机端到端（默认跳过；环境变量同 sftp 测试）：
    /// ETERM_SFTP_HOST=... ETERM_SFTP_KEY=... cargo test --lib pf_ -- --test-threads=1
    /// 覆盖：pf_connect + pf_listen（-L 随机本地口）→ 经隧道 TCP 连远端 22 →
    /// 读到 SSH banner（证明 direct-tcpip 数据面通）→ 清理。
    #[test]
    fn pf_k7_roundtrip() {
        let Ok(host) = std::env::var("ETERM_SFTP_HOST") else {
            return;
        };
        let key_path = std::env::var("ETERM_SFTP_KEY").expect("ETERM_SFTP_KEY 未设置");
        let secret = std::fs::read_to_string(&key_path).expect("读取私钥失败");
        let user = std::env::var("ETERM_SFTP_USER").unwrap_or_else(|_| "root".into());

        // TOFU 首连写库（与 sftp 测试同款临时库）
        let dir = tempfile::tempdir().unwrap();
        crate::store::open(dir.path().join("t.db").to_str().unwrap()).unwrap();
        crate::store::set_lkmk_for_test(vec![7u8; 32]);

        crate::util::ssh_runtime().block_on(async {
            let id = pf_connect(host, 22, user, "key".into(), secret)
                .await
                .expect("连接失败");
            // 系统挑空闲端口（bind :0 → 读回实际端口）
            let probe = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let local_port = probe.local_addr().unwrap().port();
            drop(probe);
            let fwd = pf_listen(
                id,
                "127.0.0.1".into(),
                local_port,
                "127.0.0.1".into(),
                22,
            )
            .await
            .expect("pf_listen 失败");
            // 经隧道读远端 sshd 的版本横幅
            use std::io::Read;
            let mut tcp = std::net::TcpStream::connect(("127.0.0.1", local_port)).unwrap();
            tcp.set_read_timeout(Some(std::time::Duration::from_secs(5))).unwrap();
            let mut buf = [0u8; 64];
            let n = tcp.read(&mut buf).expect("经隧道读 banner 失败");
            let banner = String::from_utf8_lossy(&buf[..n]);
            assert!(
                banner.starts_with("SSH-"),
                "应经隧道读到 SSH banner，实际: {banner:?}"
            );
            drop(tcp);
            pf_close_forward(id, fwd);
            pf_disconnect(id);
        });
    }
}

//! SFTP 文件传输 FFI 面（M2）。
//! 独立 SSH 连接（与终端会话解耦，Termius 同款模型）：connect + auth + sftp 子系统，
//! 浏览器/传输为请求-响应式调用。主机键走同一 TOFU 校验器（与终端共用 known_hosts）。
//! 会话表：id → (russh Handle 保活 + SftpSession)；async FFI 经本 crate runtime 中转
//! （frb 执行器无 tokio reactor，russh 首个 await 即 panic，见 ssh.rs 注释）。

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use russh_sftp::client::SftpSession;

use crate::util::ssh_runtime;

/// 目录项（浏览列表行）。
pub struct SftpEntry {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    /// 修改时间（Unix 秒）。
    pub mtime: i64,
}

/// 传输进度事件（download/upload 共用；total 为 0 表示未知大小）。
pub struct SftpProgress {
    pub transferred: u64,
    pub total: u64,
    /// 当前传输的远端路径（多任务并发时 UI 区分用）。
    pub path: String,
}

struct SftpConn {
    /// 挂断信号：发送或 drop（会话从注册表移除）都会触发干净断开。
    /// russh Handle 留在保活任务里（连接内部任务随之存活，keepalive 生效）。
    kill: tokio::sync::mpsc::Sender<()>,
    sftp: SftpSession, // 内部自带多路复用，Clone 廉价
}

static NEXT_ID: AtomicU64 = AtomicU64::new(1);
static SESSIONS: Mutex<Option<HashMap<u64, Arc<SftpConn>>>> = Mutex::new(None);

fn runtime() -> &'static tokio::runtime::Runtime {
    ssh_runtime()
}

fn get(id: u64) -> Result<Arc<SftpConn>, String> {
    SESSIONS
        .lock()
        .unwrap()
        .as_ref()
        .and_then(|m| m.get(&id))
        .cloned()
        .ok_or_else(|| "SFTP 会话不存在".to_string())
}

/// 在本 crate 的 tokio runtime 上执行 f，把结果经 oneshot 送回 frb 线程。
/// （frb async 函数跑在无 reactor 执行器上，russh 调用必须中转。）
async fn on_runtime<T, F>(f: F) -> Result<T, String>
where
    T: Send + 'static,
    F: FnOnce() -> futures::future::BoxFuture<'static, Result<T, String>> + Send + 'static,
{
    let (tx, rx) = tokio::sync::oneshot::channel();
    runtime().spawn(async move {
        let _ = tx.send(f().await);
    });
    rx.await.map_err(|_| "内部通道关闭".to_string())?
}

// ---------- 连接管理 ----------

/// 建立 SFTP 会话（连接 + 认证 + sftp 子系统握手全部完成后才返回 id）。
/// 失败直接返回错误文本（与终端不同：此处无事件流，错误走返回值更直观）。
#[flutter_rust_bridge::frb]
pub async fn sftp_connect(
    host: String,
    port: u16,
    user: String,
    auth_kind: String,
    secret: String,
) -> Result<u64, String> {
    on_runtime(move || {
        Box::pin(async move {
            let conn = match crate::api::ssh::connect_and_auth(&host, port, &user, &auth_kind, &secret)
                .await
            {
                Ok(h) => h,
                Err(reason) => return Err(reason),
            };
            let mut ch = match conn.open_session().await {
                Ok(c) => c,
                Err(e) => return Err(format!("打开通道失败: {e}")),
            };
            if let Err(e) = ch.request_subsystem(true, "sftp").await {
                return Err(format!("请求 sftp 子系统失败（服务器可能未启用）: {e}"));
            }
            let sftp = match SftpSession::new(ch.into_stream()).await {
                Ok(s) => s,
                Err(e) => return Err(format!("SFTP 握手失败: {e}")),
            };
            // 连接句柄移入保活任务：kill 信号（发送或 drop）触发干净断开
            let (kill_tx, mut kill_rx) = tokio::sync::mpsc::channel::<()>(1);
            tokio::spawn(async move {
                let _ = kill_rx.recv().await; // None = 发送端先 drop（会话移除），同样断开
                conn.shutdown().await;
            });
            let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
            SESSIONS
                .lock()
                .unwrap()
                .get_or_insert_with(HashMap::new)
                .insert(id, Arc::new(SftpConn { kill: kill_tx, sftp }));
            Ok(id)
        })
    })
    .await
}

/// 断开并移除会话（幂等）。
#[flutter_rust_bridge::frb(sync)]
pub fn sftp_disconnect(id: u64) -> Result<(), String> {
    let conn = SESSIONS.lock().unwrap().as_mut().and_then(|m| m.remove(&id));
    if let Some(conn) = conn {
        // 发送挂断信号；保活任务收到后 disconnect（发送失败=任务已退出，连接已断）
        let _ = conn.kill.try_send(());
    }
    Ok(())
}

// ---------- 浏览与文件操作 ----------

/// 解析为绝对路径（连接后把 "." 解析为家目录绝对路径，供地址栏/面包屑）。
#[flutter_rust_bridge::frb]
pub async fn sftp_realpath(id: u64, path: String) -> Result<String, String> {
    let conn = get(id)?;
    on_runtime(move || {
        Box::pin(async move {
            conn.sftp
                .canonicalize(&path)
                .await
                .map_err(|e| format!("解析路径失败: {e}"))
        })
    })
    .await
}

/// 列目录（"." 与 ".." 已滤除）。失败返回错误文本（如目录不存在）。
#[flutter_rust_bridge::frb]
pub async fn sftp_list(id: u64, path: String) -> Result<Vec<SftpEntry>, String> {
    let conn = get(id)?;
    on_runtime(move || {
        Box::pin(async move {
            let items = conn
                .sftp
                .read_dir(&path)
                .await
                .map_err(|e| format!("读取目录失败: {e}"))?;
            let mut out: Vec<SftpEntry> = Vec::new();
            for it in items {
                // ReadDir 迭代器已滤除 "." 与 ".."
                let md = it.metadata();
                let mtime = md
                    .modified()
                    .ok()
                    .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                    .map(|d| d.as_secs() as i64)
                    .unwrap_or(0);
                out.push(SftpEntry {
                    is_dir: md.file_type().is_dir(),
                    size: md.len(),
                    mtime,
                    name: it.file_name(),
                });
            }
            // 目录在前、名称不区分大小写排序
            out.sort_by(|a, b| {
                b.is_dir.cmp(&a.is_dir).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
            });
            Ok(out)
        })
    })
    .await
}

#[flutter_rust_bridge::frb]
pub async fn sftp_mkdir(id: u64, path: String) -> Result<(), String> {
    let conn = get(id)?;
    on_runtime(move || {
        Box::pin(async move {
            conn.sftp.create_dir(&path).await.map_err(|e| format!("创建目录失败: {e}"))
        })
    })
    .await
}

/// 删除文件（不递归；目录用 sftp_rmdir）。
#[flutter_rust_bridge::frb]
pub async fn sftp_remove(id: u64, path: String) -> Result<(), String> {
    let conn = get(id)?;
    on_runtime(move || {
        Box::pin(async move {
            conn.sftp.remove_file(&path).await.map_err(|e| format!("删除失败: {e}"))
        })
    })
    .await
}

#[flutter_rust_bridge::frb]
pub async fn sftp_rmdir(id: u64, path: String) -> Result<(), String> {
    let conn = get(id)?;
    on_runtime(move || {
        Box::pin(async move {
            conn.sftp.remove_dir(&path).await.map_err(|e| format!("删除目录失败: {e}"))
        })
    })
    .await
}

#[flutter_rust_bridge::frb]
pub async fn sftp_rename(id: u64, from: String, to: String) -> Result<(), String> {
    let conn = get(id)?;
    on_runtime(move || {
        Box::pin(async move {
            conn.sftp.rename(&from, &to).await.map_err(|e| format!("重命名失败: {e}"))
        })
    })
    .await
}

// ---------- 传输（进度经 StreamSink 上报） ----------

const CHUNK: usize = 32 * 1024;
/// 进度上报步长（字节）：避免高频跨 FFI 通知。
const PROGRESS_STEP: u64 = 256 * 1024;

/// 下载核心（FFI 与集成测试共用；report 每 PROGRESS_STEP 回调一次，收尾补一次）。
pub(crate) async fn download_inner(
    id: u64,
    remote_path: String,
    local_path: String,
    mut report: impl FnMut(u64, u64),
) -> Result<(), String> {
    let conn = get(id)?;
    let total = conn
        .sftp
        .metadata(&remote_path)
        .await
        .map_err(|e| format!("读取文件信息失败: {e}"))?
        .len();
    let mut remote = conn
        .sftp
        .open(&remote_path)
        .await
        .map_err(|e| format!("打开远端文件失败: {e}"))?;
    let mut local = tokio::fs::File::create(&local_path)
        .await
        .map_err(|e| format!("创建本地文件失败: {e}"))?;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    report(0, total);
    let mut transferred: u64 = 0;
    let mut last_reported: u64 = 0;
    loop {
        let mut buf = vec![0u8; CHUNK];
        let n = remote
            .read(&mut buf)
            .await
            .map_err(|e| format!("读取远端失败: {e}"))?;
        if n == 0 {
            break;
        }
        local
            .write_all(&buf[..n])
            .await
            .map_err(|e| format!("写入本地失败: {e}"))?;
        transferred += n as u64;
        if transferred - last_reported >= PROGRESS_STEP {
            last_reported = transferred;
            report(transferred, total);
        }
    }
    local.flush().await.map_err(|e| format!("落盘失败: {e}"))?;
    report(transferred, total);
    Ok(())
}

/// 下载远端文件到本地路径。已存在的本地文件会被覆盖。
#[flutter_rust_bridge::frb]
pub async fn sftp_download(
    id: u64,
    remote_path: String,
    local_path: String,
    sink: crate::frb_generated::StreamSink<SftpProgress>,
) -> Result<(), String> {
    // IO 注册在本 crate runtime 上，必须回 runtime 执行（frb 执行器无 reactor）
    on_runtime(move || {
        Box::pin(download_inner(
            id,
            remote_path.clone(),
            local_path,
            move |t, total| {
                let _ = sink.add(SftpProgress {
                    transferred: t,
                    total,
                    path: remote_path.clone(),
                });
            },
        ))
    })
    .await
}

/// 上传核心（FFI 与集成测试共用）。
pub(crate) async fn upload_inner(
    id: u64,
    local_path: String,
    remote_path: String,
    mut report: impl FnMut(u64, u64),
) -> Result<(), String> {
    let conn = get(id)?;
    let mut local = tokio::fs::File::open(&local_path)
        .await
        .map_err(|e| format!("打开本地文件失败: {e}"))?;
    let total = local.metadata().await.map(|m| m.len()).unwrap_or(0);
    let mut remote = conn
        .sftp
        .create(&remote_path)
        .await
        .map_err(|e| format!("创建远端文件失败: {e}"))?;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    report(0, total);
    let mut transferred: u64 = 0;
    let mut last_reported: u64 = 0;
    loop {
        let mut buf = vec![0u8; CHUNK];
        let n = local
            .read(&mut buf)
            .await
            .map_err(|e| format!("读取本地失败: {e}"))?;
        if n == 0 {
            break;
        }
        remote
            .write_all(&buf[..n])
            .await
            .map_err(|e| format!("写入远端失败: {e}"))?;
        transferred += n as u64;
        if transferred - last_reported >= PROGRESS_STEP {
            last_reported = transferred;
            report(transferred, total);
        }
    }
    remote
        .flush()
        .await
        .map_err(|e| format!("刷新远端失败: {e}"))?;
    report(transferred, total);
    Ok(())
}

/// 上传本地文件到远端路径。已存在的远端文件会被覆盖。
#[flutter_rust_bridge::frb]
pub async fn sftp_upload(
    id: u64,
    local_path: String,
    remote_path: String,
    sink: crate::frb_generated::StreamSink<SftpProgress>,
) -> Result<(), String> {
    on_runtime(move || {
        Box::pin(upload_inner(
            id,
            local_path,
            remote_path.clone(),
            move |t, total| {
                let _ = sink.add(SftpProgress {
                    transferred: t,
                    total,
                    path: remote_path.clone(),
                });
            },
        ))
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    /// k7 真机端到端（默认跳过；设 ETERM_SFTP_HOST 才跑）：
    /// ETERM_SFTP_HOST=120.26.109.221 ETERM_SFTP_KEY=<PEM 路径> \
    ///   cargo test --lib sftp_ -- --test-threads=1
    /// （--test-threads=1：store 用全局 DB 单例，与其他测试隔离运行）
    /// 覆盖：连接 + TOFU + realpath + 列目录 + mkdir + 上传/下载回环比对 + 清理。
    #[test]
    fn sftp_k7_roundtrip() {
        let Ok(host) = std::env::var("ETERM_SFTP_HOST") else {
            return; // 未提供环境：跳过（CI/常规测试不依赖外网）
        };
        // TOFU 首连要写 known_hosts：临时库 + 确定性 LKMK（与 store 测试同款）
        let dir = tempfile::tempdir().unwrap();
        crate::store::open(dir.path().join("t.db").to_str().unwrap()).unwrap();
        crate::store::set_lkmk_for_test(vec![7u8; 32]);
        let key_path = std::env::var("ETERM_SFTP_KEY").expect("ETERM_SFTP_KEY 未设置");
        let secret = std::fs::read_to_string(&key_path).expect("读取私钥失败");
        let user = std::env::var("ETERM_SFTP_USER").unwrap_or_else(|_| "root".into());

        crate::util::ssh_runtime().block_on(async {
            let id = sftp_connect(
                host.clone(),
                22,
                user.clone(),
                "key".into(),
                secret.clone(),
            )
            .await
            .expect("连接失败");
            let real = sftp_realpath(id, ".".into()).await.expect("realpath 失败");
            assert!(real.starts_with('/'), "家目录应为绝对路径: {real}");
            let entries = sftp_list(id, "/opt".into()).await.expect("列目录失败");
            assert!(!entries.is_empty(), "/opt 不应为空");

            // 上传/下载回环：1MB 伪随机数据（多块 + 触发进度回调）
            // 幂等：先清掉上次失败运行的残留（忽略"不存在"错误）
            let dir = "/tmp/eterm-sftp-test".to_string();
            let _ = sftp_remove(id, format!("{dir}/payload.bin")).await;
            let _ = sftp_rmdir(id, dir.clone()).await;
            sftp_mkdir(id, dir.clone()).await.expect("mkdir 失败");
            let payload: Vec<u8> = (0..1024 * 1024u32).map(|i| (i % 251) as u8).collect();
            let local_src = std::env::temp_dir().join(format!("eterm-sftp-src-{id}.bin"));
            let local_dst = std::env::temp_dir().join(format!("eterm-sftp-dst-{id}.bin"));
            std::fs::write(&local_src, &payload).unwrap();
            let mut last_upload = 0u64;
            let mut last_download = 0u64;
            upload_inner(
                id,
                local_src.to_string_lossy().into_owned(),
                format!("{dir}/payload.bin"),
                |t, _| last_upload = t,
            )
            .await
            .expect("上传失败");
            assert_eq!(last_upload as usize, payload.len(), "上传进度应到达总大小");
            download_inner(
                id,
                format!("{dir}/payload.bin"),
                local_dst.to_string_lossy().into_owned(),
                |t, _| last_download = t,
            )
            .await
            .expect("下载失败");
            assert_eq!(last_download as usize, payload.len(), "下载进度应到达总大小");
            let back = std::fs::read(&local_dst).unwrap();
            assert_eq!(payload, back, "回环内容不一致");
            // 清理远端与本地
            sftp_remove(id, format!("{dir}/payload.bin"))
                .await
                .expect("清理文件失败");
            sftp_rmdir(id, dir.clone()).await.expect("清理目录失败");
            sftp_disconnect(id);
            let _ = std::fs::remove_file(&local_src);
            let _ = std::fs::remove_file(&local_dst);
        });
    }
}

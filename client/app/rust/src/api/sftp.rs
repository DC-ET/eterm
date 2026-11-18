//! SFTP 文件传输 FFI 面（M2）。
//! 独立 SSH 连接（与终端会话解耦，Termius 同款模型）：connect + auth + sftp 子系统，
//! 浏览器/传输为请求-响应式调用。主机键走同一 TOFU 校验器（与终端共用 known_hosts）。
//! 会话表：id → (russh Handle 保活 + SftpSession)；async FFI 经本 crate runtime 中转
//! （frb 执行器无 tokio reactor，russh 首个 await 即 panic，见 ssh.rs 注释）。

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use russh_sftp::client::SftpSession;
use russh_sftp::protocol::OpenFlags;

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
    /// 任务 id（Dart 入队时指定，进度/取消按此关联）。
    pub job_id: u32,
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
/// 传输任务取消旗标：Dart 入队前以 job_id 注册（经 FFI 传输函数），任务结束即移除。
/// 置位后任务在下一个分块边界停下，两侧暂存文件保留供续传。
static CANCELS: Mutex<Option<HashMap<u32, Arc<AtomicBool>>>> = Mutex::new(None);

fn register_cancel(job_id: u32) -> Arc<AtomicBool> {
    let flag = Arc::new(AtomicBool::new(false));
    CANCELS
        .lock()
        .unwrap()
        .get_or_insert_with(HashMap::new)
        .insert(job_id, flag.clone());
    flag
}

fn cleanup_cancel(job_id: u32) {
    if let Some(m) = CANCELS.lock().unwrap().as_mut() {
        m.remove(&job_id);
    }
}

/// 取消传输（幂等：任务已结束/不存在也返回 Ok，调用方无需与任务结束竞态判断）。
#[flutter_rust_bridge::frb(sync)]
pub fn sftp_transfer_cancel(job_id: u32) -> Result<(), String> {
    if let Some(flag) = CANCELS
        .lock()
        .unwrap()
        .as_ref()
        .and_then(|m| m.get(&job_id))
    {
        flag.store(true, Ordering::Relaxed);
    }
    Ok(())
}

/// 取消检查（分块循环每轮调用；错误文本含「取消」，Dart 侧按此映射任务状态）。
fn check_cancel(cancelled: &AtomicBool) -> Result<(), String> {
    if cancelled.load(Ordering::Relaxed) {
        Err("传输已取消".to_string())
    } else {
        Ok(())
    }
}

/// 断点续传起点：暂存超过总长（源文件被换短/脏数据）→ 放弃暂存从头传。
fn resume_offset(stored: u64, total: u64) -> u64 {
    if stored <= total {
        stored
    } else {
        0
    }
}

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

/// 单文件信息（None = 不存在）。供入队冲突检测与远端编辑 mtime 校验。
#[flutter_rust_bridge::frb]
pub async fn sftp_stat(id: u64, path: String) -> Result<Option<SftpEntry>, String> {
    let conn = get(id)?;
    on_runtime(move || {
        Box::pin(async move {
            match conn.sftp.metadata(&path).await {
                Ok(md) => {
                    let mtime = md
                        .modified()
                        .ok()
                        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                        .map(|d| d.as_secs() as i64)
                        .unwrap_or(0);
                    Ok(Some(SftpEntry {
                        name: path.rsplit('/').next().unwrap_or(&path).to_string(),
                        is_dir: md.file_type().is_dir(),
                        size: md.len(),
                        mtime,
                    }))
                }
                Err(russh_sftp::client::error::Error::Status(s))
                    if s.status_code == russh_sftp::protocol::StatusCode::NoSuchFile =>
                {
                    Ok(None)
                }
                Err(e) => Err(format!("读取文件信息失败: {e}")),
            }
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

// ---------- 传输（进度经 StreamSink 上报；取消/断点续传见 CANCELS 与 PART_SUFFIX） ----------

const CHUNK: usize = 32 * 1024;
/// 进度上报步长（字节）：避免高频跨 FFI 通知。
const PROGRESS_STEP: u64 = 256 * 1024;
/// 传输暂存后缀：完成前数据写 `<目标>.eterm-part`，成功后原子改名到目标。
/// 取消/失败保留暂存，重试（resume=true）从暂存长度续传。
const PART_SUFFIX: &str = ".eterm-part";

/// 下载核心（FFI 与集成测试共用；report 每 PROGRESS_STEP 回调一次，收尾补一次）。
pub(crate) async fn download_inner(
    id: u64,
    remote_path: String,
    local_path: String,
    resume: bool,
    cancelled: Arc<AtomicBool>,
    mut report: impl FnMut(u64, u64),
) -> Result<(), String> {
    check_cancel(&cancelled)?;
    let conn = get(id)?;
    let total = conn
        .sftp
        .metadata(&remote_path)
        .await
        .map_err(|e| format!("读取文件信息失败: {e}"))?
        .len();
    let part_path = format!("{local_path}{PART_SUFFIX}");
    let mut offset: u64 = 0;
    if resume {
        if let Ok(md) = tokio::fs::metadata(&part_path).await {
            offset = resume_offset(md.len(), total);
        }
    } else {
        let _ = tokio::fs::remove_file(&part_path).await; // 幂等清理上次残留
    }
    let mut remote = conn
        .sftp
        .open(&remote_path)
        .await
        .map_err(|e| format!("打开远端文件失败: {e}"))?;
    let mut local = tokio::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(offset == 0)
        .open(&part_path)
        .await
        .map_err(|e| format!("创建本地文件失败: {e}"))?;
    use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
    if offset > 0 {
        remote
            .seek(std::io::SeekFrom::Start(offset))
            .await
            .map_err(|e| format!("定位远端偏移失败: {e}"))?;
        local
            .seek(std::io::SeekFrom::Start(offset))
            .await
            .map_err(|e| format!("定位本地偏移失败: {e}"))?;
    }
    report(offset, total);
    let mut transferred: u64 = offset;
    let mut last_reported: u64 = offset;
    loop {
        check_cancel(&cancelled)?; // 取消：暂存保留，供续传
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
    tokio::fs::rename(&part_path, &local_path)
        .await
        .map_err(|e| format!("落盘改名失败: {e}"))?;
    report(transferred, total);
    Ok(())
}

/// 下载远端文件到本地路径（覆盖语义）。resume=true 从上次暂存续传。
#[flutter_rust_bridge::frb]
pub async fn sftp_download(
    id: u64,
    job_id: u32,
    remote_path: String,
    local_path: String,
    resume: bool,
    sink: crate::frb_generated::StreamSink<SftpProgress>,
) -> Result<(), String> {
    let cancelled = register_cancel(job_id);
    // IO 注册在本 crate runtime 上，必须回 runtime 执行（frb 执行器无 reactor）
    let res = on_runtime(move || {
        Box::pin(download_inner(
            id,
            remote_path.clone(),
            local_path,
            resume,
            cancelled.clone(),
            move |t, total| {
                let _ = sink.add(SftpProgress {
                    job_id,
                    transferred: t,
                    total,
                    path: remote_path.clone(),
                });
            },
        ))
    })
    .await;
    cleanup_cancel(job_id);
    res
}

/// 上传核心（FFI 与集成测试共用）。
pub(crate) async fn upload_inner(
    id: u64,
    local_path: String,
    remote_path: String,
    resume: bool,
    cancelled: Arc<AtomicBool>,
    mut report: impl FnMut(u64, u64),
) -> Result<(), String> {
    check_cancel(&cancelled)?;
    let conn = get(id)?;
    let mut local = tokio::fs::File::open(&local_path)
        .await
        .map_err(|e| format!("打开本地文件失败: {e}"))?;
    let total = local.metadata().await.map(|m| m.len()).unwrap_or(0);
    let part_path = format!("{remote_path}{PART_SUFFIX}");
    let mut offset: u64 = 0;
    if resume {
        if let Ok(md) = conn.sftp.metadata(&part_path).await {
            offset = resume_offset(md.len(), total);
        }
    } else {
        let _ = conn.sftp.remove_file(&part_path).await; // 幂等清理上次残留
    }
    let mut flags = OpenFlags::CREATE | OpenFlags::WRITE;
    if offset == 0 {
        flags |= OpenFlags::TRUNCATE; // 全新或暂存超长被弃用：从头写
    }
    let mut remote = conn
        .sftp
        .open_with_flags(&part_path, flags)
        .await
        .map_err(|e| format!("创建远端文件失败: {e}"))?;
    use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
    if offset > 0 {
        local
            .seek(std::io::SeekFrom::Start(offset))
            .await
            .map_err(|e| format!("定位本地偏移失败: {e}"))?;
        remote
            .seek(std::io::SeekFrom::Start(offset))
            .await
            .map_err(|e| format!("定位远端偏移失败: {e}"))?;
    }
    report(offset, total);
    let mut transferred: u64 = offset;
    let mut last_reported: u64 = offset;
    loop {
        check_cancel(&cancelled)?; // 取消：暂存保留，供续传
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
    // 收尾改名：SFTP rename 目标已存在会失败（OpenSSH 语义），上传=覆盖故先删旧目标。
    if conn.sftp.metadata(&remote_path).await.is_ok() {
        conn.sftp
            .remove_file(&remote_path)
            .await
            .map_err(|e| format!("清理旧目标失败: {e}"))?;
    }
    conn.sftp
        .rename(&part_path, &remote_path)
        .await
        .map_err(|e| format!("落盘改名失败: {e}"))?;
    report(total, total);
    Ok(())
}

/// 上传本地文件到远端路径（覆盖语义）。resume=true 从上次暂存续传。
#[flutter_rust_bridge::frb]
pub async fn sftp_upload(
    id: u64,
    job_id: u32,
    local_path: String,
    remote_path: String,
    resume: bool,
    sink: crate::frb_generated::StreamSink<SftpProgress>,
) -> Result<(), String> {
    let cancelled = register_cancel(job_id);
    let res = on_runtime(move || {
        Box::pin(upload_inner(
            id,
            local_path,
            remote_path.clone(),
            resume,
            cancelled.clone(),
            move |t, total| {
                let _ = sink.add(SftpProgress {
                    job_id,
                    transferred: t,
                    total,
                    path: remote_path.clone(),
                });
            },
        ))
    })
    .await;
    cleanup_cancel(job_id);
    res
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 取消旗标预置位：upload_inner 不触会话/文件即返回取消错误（无需服务器）。
    #[test]
    fn sftp_cancel_flag_short_circuits() {
        let flag = Arc::new(AtomicBool::new(true));
        let err = runtime()
            .block_on(upload_inner(
                0,
                "/nonexistent-src".into(),
                "/nonexistent-dst".into(),
                false,
                flag,
                |_, _| {},
            ))
            .unwrap_err();
        assert!(err.contains("取消"), "应为取消错误: {err}");
        // 未置位时才继续走建连链（会话不存在错误，而非取消）
        let err = runtime()
            .block_on(upload_inner(
                0,
                "/nonexistent-src".into(),
                "/nonexistent-dst".into(),
                false,
                Arc::new(AtomicBool::new(false)),
                |_, _| {},
            ))
            .unwrap_err();
        assert!(!err.contains("取消"), "不应误报取消: {err}");
    }

    #[test]
    fn sftp_resume_offset_logic() {
        assert_eq!(resume_offset(0, 100), 0);
        assert_eq!(resume_offset(50, 100), 50);
        assert_eq!(resume_offset(100, 100), 100); // 传完但未改名 → 直接收尾
        assert_eq!(resume_offset(120, 100), 0); // 源文件被换短 → 放弃暂存重传
    }

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
                false,
                Arc::new(AtomicBool::new(false)),
                |t, _| last_upload = t,
            )
            .await
            .expect("上传失败");
            assert_eq!(last_upload as usize, payload.len(), "上传进度应到达总大小");
            download_inner(
                id,
                format!("{dir}/payload.bin"),
                local_dst.to_string_lossy().into_owned(),
                false,
                Arc::new(AtomicBool::new(false)),
                |t, _| last_download = t,
            )
            .await
            .expect("下载失败");
            assert_eq!(last_download as usize, payload.len(), "下载进度应到达总大小");
            let back = std::fs::read(&local_dst).unwrap();
            assert_eq!(payload, back, "回环内容不一致");

            // stat：存在与不存在两态
            let st = sftp_stat(id, format!("{dir}/payload.bin"))
                .await
                .expect("stat 失败");
            assert_eq!(st.expect("应存在").size as usize, payload.len());
            assert!(
                sftp_stat(id, format!("{dir}/no-such-file"))
                    .await
                    .expect("stat 失败")
                    .is_none(),
                "不存在应返回 None"
            );

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

    /// k7 真机：取消 + 断点续传（上/下）+ 覆盖语义（环境同 roundtrip；默认跳过）。
    #[test]
    fn sftp_k7_resume_and_cancel() {
        let Ok(host) = std::env::var("ETERM_SFTP_HOST") else {
            return;
        };
        let dir = tempfile::tempdir().unwrap();
        crate::store::open(dir.path().join("t.db").to_str().unwrap()).unwrap();
        crate::store::set_lkmk_for_test(vec![7u8; 32]);
        let key_path = std::env::var("ETERM_SFTP_KEY").expect("ETERM_SFTP_KEY 未设置");
        let secret = std::fs::read_to_string(&key_path).expect("读取私钥失败");
        let user = std::env::var("ETERM_SFTP_USER").unwrap_or_else(|_| "root".into());

        crate::util::ssh_runtime().block_on(async {
            let id = sftp_connect(host.clone(), 22, user, "key".into(), secret)
                .await
                .expect("连接失败");
            let dir = "/tmp/eterm-sftp-test-resume".to_string();
            let target = format!("{dir}/payload.bin");
            let part = format!("{target}{PART_SUFFIX}");
            // 幂等清理上次残留
            let _ = sftp_remove(id, part.clone()).await;
            let _ = sftp_remove(id, target.clone()).await;
            let _ = sftp_rmdir(id, dir.clone()).await;
            sftp_mkdir(id, dir.clone()).await.expect("mkdir 失败");

            let payload: Vec<u8> = (0..1024 * 1024u32).map(|i| (i % 251) as u8).collect();
            let half_len = payload.len() / 2;
            let local_src = std::env::temp_dir().join(format!("eterm-sftp-full-{id}.bin"));
            let local_half = std::env::temp_dir().join(format!("eterm-sftp-half-{id}.bin"));
            let local_dst = std::env::temp_dir().join(format!("eterm-sftp-dst-{id}.bin"));
            std::fs::write(&local_src, &payload).unwrap();
            std::fs::write(&local_half, &payload[..half_len]).unwrap();
            let no_cancel = Arc::new(AtomicBool::new(false));

            // 1) 取消：旗标预置位 → 快速失败，目标与暂存都不应存在
            let err = upload_inner(
                id,
                local_src.to_string_lossy().into_owned(),
                target.clone(),
                false,
                Arc::new(AtomicBool::new(true)),
                |_, _| {},
            )
            .await
            .unwrap_err();
            assert!(err.contains("取消"), "应为取消错误: {err}");
            assert!(
                sftp_stat(id, part.clone()).await.unwrap().is_none(),
                "取消（未开始写）不应留暂存"
            );

            // 2) 断点续传-上传：人为构造半量暂存 → resume 续全量 → 内容一致
            upload_inner(
                id,
                local_half.to_string_lossy().into_owned(),
                part.clone(),
                false,
                no_cancel.clone(),
                |_, _| {},
            )
            .await
            .expect("构造远端暂存失败");
            assert_eq!(
                sftp_stat(id, part.clone()).await.unwrap().unwrap().size as usize,
                half_len
            );
            upload_inner(
                id,
                local_src.to_string_lossy().into_owned(),
                target.clone(),
                true,
                no_cancel.clone(),
                |_, _| {},
            )
            .await
            .expect("续传上传失败");
            assert!(
                sftp_stat(id, part.clone()).await.unwrap().is_none(),
                "完成后暂存应已改名到目标"
            );
            download_inner(
                id,
                target.clone(),
                local_dst.to_string_lossy().into_owned(),
                false,
                no_cancel.clone(),
                |_, _| {},
            )
            .await
            .expect("回读失败");
            assert_eq!(
                std::fs::read(&local_dst).unwrap(),
                payload,
                "续传上传内容不一致"
            );

            // 3) 覆盖语义：非 resume 传半量 → 目标被整体替换
            upload_inner(
                id,
                local_half.to_string_lossy().into_owned(),
                target.clone(),
                false,
                no_cancel.clone(),
                |_, _| {},
            )
            .await
            .expect("覆盖上传失败");
            assert_eq!(
                sftp_stat(id, target.clone()).await.unwrap().unwrap().size as usize,
                half_len,
                "覆盖后目标应为半量大小"
            );

            // 4) 断点续传-下载：本地暂存留 1/4（与远端前 1/4 字节一致）→ resume 续齐
            let quarter_len = payload.len() / 4;
            let local_part = format!("{}{PART_SUFFIX}", local_dst.to_string_lossy());
            let _ = std::fs::remove_file(&local_dst); // 清掉上一步全量回读，避免旧尾巴残留
            let _ = std::fs::remove_file(&local_part);
            std::fs::write(&local_part, &payload[..quarter_len]).unwrap();
            download_inner(
                id,
                target.clone(),
                local_dst.to_string_lossy().into_owned(),
                true,
                no_cancel.clone(),
                |_, _| {},
            )
            .await
            .expect("续传下载失败");
            assert_eq!(
                std::fs::read(&local_dst).unwrap(),
                payload[..half_len],
                "续传下载内容不一致"
            );
            assert!(!std::fs::exists(&local_part).unwrap(), "暂存应已改名");

            // 清理远端与本地
            sftp_remove(id, target).await.expect("清理文件失败");
            sftp_rmdir(id, dir).await.expect("清理目录失败");
            sftp_disconnect(id);
            for f in [local_src, local_half, local_dst] {
                let _ = std::fs::remove_file(f);
            }
        });
    }
}

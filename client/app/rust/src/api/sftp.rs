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

// ---------- 远端↔远端直传（任务清单 #8）与目录打包压缩下载（任务清单 #7） ----------

/// 远端→远端单文件直传核心：数据分块经客户端内存中转，B 侧 `<目标>.eterm-part`
/// 暂存 + 完成改名（覆盖语义）。resume=true 按 B 侧暂存长度续传。
/// report 为文件内绝对进度（offset..file_total），供聚合方换算。
pub(crate) async fn copy_file_inner(
    id_from: u64,
    path_from: String,
    id_to: u64,
    path_to: String,
    resume: bool,
    cancelled: Arc<AtomicBool>,
    report: &mut (dyn FnMut(u64, u64) + Send),
) -> Result<(), String> {
    check_cancel(&cancelled)?;
    let a = get(id_from)?;
    let b = get(id_to)?;
    let total = a
        .sftp
        .metadata(&path_from)
        .await
        .map_err(|e| format!("读取源文件信息失败: {e}"))?
        .len();
    let part_path = format!("{path_to}{PART_SUFFIX}");
    let mut offset: u64 = 0;
    if resume {
        if let Ok(md) = b.sftp.metadata(&part_path).await {
            offset = resume_offset(md.len(), total);
        }
    } else {
        let _ = b.sftp.remove_file(&part_path).await; // 幂等清理上次残留
    }
    let mut flags = OpenFlags::CREATE | OpenFlags::WRITE;
    if offset == 0 {
        flags |= OpenFlags::TRUNCATE;
    }
    let mut src = a
        .sftp
        .open(&path_from)
        .await
        .map_err(|e| format!("打开源文件失败: {e}"))?;
    let mut dst = b
        .sftp
        .open_with_flags(&part_path, flags)
        .await
        .map_err(|e| format!("创建目标文件失败: {e}"))?;
    use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
    if offset > 0 {
        src.seek(std::io::SeekFrom::Start(offset))
            .await
            .map_err(|e| format!("定位源偏移失败: {e}"))?;
        dst.seek(std::io::SeekFrom::Start(offset))
            .await
            .map_err(|e| format!("定位目标偏移失败: {e}"))?;
    }
    report(offset, total);
    let mut transferred: u64 = offset;
    let mut last_reported: u64 = offset;
    loop {
        check_cancel(&cancelled)?;
        let mut buf = vec![0u8; CHUNK];
        let n = src
            .read(&mut buf)
            .await
            .map_err(|e| format!("读取源失败: {e}"))?;
        if n == 0 {
            break;
        }
        dst.write_all(&buf[..n])
            .await
            .map_err(|e| format!("写入目标失败: {e}"))?;
        transferred += n as u64;
        if transferred - last_reported >= PROGRESS_STEP {
            last_reported = transferred;
            report(transferred, total);
        }
    }
    dst.flush().await.map_err(|e| format!("刷新目标失败: {e}"))?;
    // 收尾改名（与 upload 同语义：先删旧目标再 rename）
    if b.sftp.metadata(&path_to).await.is_ok() {
        b.sftp
            .remove_file(&path_to)
            .await
            .map_err(|e| format!("清理旧目标失败: {e}"))?;
    }
    b.sftp
        .rename(&part_path, &path_to)
        .await
        .map_err(|e| format!("落盘改名失败: {e}"))?;
    report(total, total);
    Ok(())
}

/// 远端→远端单文件直传（FFI）。
#[flutter_rust_bridge::frb]
pub async fn sftp_copy(
    id_from: u64,
    job_id: u32,
    path_from: String,
    id_to: u64,
    path_to: String,
    resume: bool,
    sink: crate::frb_generated::StreamSink<SftpProgress>,
) -> Result<(), String> {
    let cancelled = register_cancel(job_id);
    let res = on_runtime(move || {
        Box::pin(async move {
            let path_disp = path_from.clone();
            let mut report = move |t: u64, total: u64| {
                let _ = sink.add(SftpProgress {
                    job_id,
                    transferred: t,
                    total,
                    path: path_disp.clone(),
                });
            };
            copy_file_inner(
                id_from,
                path_from,
                id_to,
                path_to,
                resume,
                cancelled,
                &mut report,
            )
            .await
        })
    })
    .await;
    cleanup_cancel(job_id);
    res
}

/// 目录内容预走查（lstat 语义，杜绝链接环）。收集常规文件 (路径, 大小) 与子目录；
/// 符号链接与非常规条目（socket/FIFO/悬空链接）跳过——复制走 STAT 口径，
/// 对它们 open/metadata 会失败或挂起，整目录任务不应被坏条目拖垮。
async fn dir_stats(
    conn: &SftpSession,
    dir: &str,
    files: &mut Vec<(String, u64)>,
    dirs: &mut Vec<String>,
    cancelled: &Arc<AtomicBool>,
) -> Result<(), String> {
    check_cancel(cancelled)?;
    let items = conn
        .read_dir(dir)
        .await
        .map_err(|e| format!("读取目录失败: {e}"))?;
    for it in items {
        let md = it.metadata();
        let name = it.file_name();
        let child = if dir.ends_with('/') {
            format!("{dir}{name}")
        } else {
            format!("{dir}/{name}")
        };
        let ft = md.file_type();
        if ft.is_dir() {
            dirs.push(child.clone());
            Box::pin(dir_stats(conn, &child, files, dirs, cancelled)).await?;
        } else if ft.is_file() {
            files.push((child, md.len()));
        }
    }
    Ok(())
}

/// 远端→远端目录递归复制核心（任务清单 #8）：逐文件 copy_file_inner；
/// 目标已存在且同大小的文件跳过 → 整体重试天然具备断点续传语义。
/// report 为目录级聚合进度（transferred..total）。
pub(crate) async fn copy_dir_inner(
    id_from: u64,
    dir_from: String,
    id_to: u64,
    dir_to: String,
    cancelled: Arc<AtomicBool>,
    report: &mut (dyn FnMut(u64, u64) + Send),
) -> Result<(), String> {
    check_cancel(&cancelled)?;
    let a = get(id_from)?;
    let b = get(id_to)?;
    let mut files: Vec<(String, u64)> = Vec::new();
    let mut dirs: Vec<String> = Vec::new();
    dir_stats(&a.sftp, &dir_from, &mut files, &mut dirs, &cancelled).await?;
    let total: u64 = files.iter().map(|(_, s)| *s).sum();
    report(0, total);
    let _ = b.sftp.create_dir(&dir_to).await; // 根目标已存在属正常
    // 重建全部子目录（含空目录）：排序保证父目录先于子目录创建
    let mut sorted_dirs = dirs;
    sorted_dirs.sort();
    for d in sorted_dirs {
        check_cancel(&cancelled)?;
        let rel = d
            .strip_prefix(&dir_from)
            .unwrap_or(&d)
            .trim_start_matches('/')
            .to_string();
        let dst_dir = if dir_to.ends_with('/') {
            format!("{dir_to}{rel}")
        } else {
            format!("{dir_to}/{rel}")
        };
        let _ = b.sftp.create_dir(&dst_dir).await; // 已存在忽略
    }
    let mut transferred: u64 = 0;
    for (src, size) in files {
        check_cancel(&cancelled)?;
        let rel = src
            .strip_prefix(&dir_from)
            .unwrap_or(&src)
            .trim_start_matches('/')
            .to_string();
        let dst = if dir_to.ends_with('/') {
            format!("{dir_to}{rel}")
        } else {
            format!("{dir_to}/{rel}")
        };
        // 父目录逐级创建（已存在忽略）
        let mut acc = String::new();
        if let Some((parent, _)) = dst.rsplit_once('/') {
            for seg in parent.trim_start_matches('/').split('/') {
                if seg.is_empty() {
                    continue;
                }
                acc.push('/');
                acc.push_str(seg);
                let _ = b.sftp.create_dir(&acc).await;
            }
        }
        // 已存在且是文件、同大小 → 跳过（重试续传）；目录同名不顶替
        if let Ok(md) = b.sftp.metadata(&dst).await {
            if !md.file_type().is_dir() && md.len() == size {
                transferred += size;
                report(transferred, total);
                continue;
            }
        }
        let base = transferred;
        copy_file_inner(id_from, src, id_to, dst, false, cancelled.clone(), &mut |t, _ft| {
            report(base + t, total)
        })
        .await?;
        transferred += size;
        report(transferred, total);
    }
    Ok(())
}

/// 远端→远端目录递归复制（FFI）。
#[flutter_rust_bridge::frb]
pub async fn sftp_copy_dir(
    id_from: u64,
    job_id: u32,
    dir_from: String,
    id_to: u64,
    dir_to: String,
    sink: crate::frb_generated::StreamSink<SftpProgress>,
) -> Result<(), String> {
    let cancelled = register_cancel(job_id);
    let res = on_runtime(move || {
        Box::pin(async move {
            let dir_disp = dir_from.clone();
            let mut report = move |t: u64, total: u64| {
                let _ = sink.add(SftpProgress {
                    job_id,
                    transferred: t,
                    total,
                    path: dir_disp.clone(),
                });
            };
            copy_dir_inner(id_from, dir_from, id_to, dir_to, cancelled, &mut report).await
        })
    })
    .await;
    cleanup_cancel(job_id);
    res
}

/// 远端目录打包压缩下载核心（任务清单 #7）：独立 SSH 连接 exec
/// `tar -czf -`，流式写 `<本地>.eterm-part` → 完成改名。total 未知（0）；
/// 流式压缩不可续传，取消/失败删除暂存。report(transferred, 0)。
async fn tar_download_inner(
    conn: &dyn crate::util::AuthedConn,
    remote_dir: String,
    local_path: String,
    cancelled: Arc<AtomicBool>,
    report: &mut (dyn FnMut(u64, u64) + Send),
) -> Result<(), String> {
    check_cancel(&cancelled)?;
    // shell 单引号转义（POSIX '\''）
    let q = |s: &str| format!("'{}'", s.replace('\'', "'\\''"));
    let dir = remote_dir.trim_end_matches('/').to_string();
    if dir.is_empty() {
        // 根目录打包会扫 /proc、/sys 等虚拟文件系统（大概率卡死/非零退出），直接拒绝
        return Err("不支持打包根目录 /，请选择具体目录".to_string());
    }
    if !dir.starts_with('/') {
        // 调用链恒为 realpath 起步的绝对路径；相对路径在下方 -C 拆分下会指向
        // 错误目录（如 "foo" → tar -C / foo）。防御性拒绝（评审观察 5）。
        return Err("目录路径必须以 / 开头（绝对路径）".to_string());
    }
    let (parent, base) = dir
        .rsplit_once('/')
        .map(|(p, b)| (p.to_string(), b.to_string()))
        .unwrap_or(("/".into(), dir.clone()));
    let base = if base.is_empty() { "/".into() } else { base };
    let cmd = format!("tar -czf - -C {} {}", q(&parent), q(&base));
    let mut ch = conn
        .open_session()
        .await
        .map_err(|e| format!("打开会话通道失败: {e}"))?;
    ch.exec(true, cmd.as_str())
        .await
        .map_err(|e| format!("远端打包失败（tar 不可用？）: {e}"))?;
    let part_path = format!("{local_path}{PART_SUFFIX}");
    let mut file = tokio::fs::File::create(&part_path)
        .await
        .map_err(|e| format!("创建本地文件失败: {e}"))?;
    use tokio::io::AsyncWriteExt;
    let mut transferred: u64 = 0;
    let mut last_reported: u64 = 0;
    let mut exit_code: Option<u32> = None;
    loop {
        check_cancel(&cancelled)?;
        match ch.wait().await {
            Some(russh::ChannelMsg::Data { data }) => {
                file.write_all(&data)
                    .await
                    .map_err(|e| format!("写入本地失败: {e}"))?;
                transferred += data.len() as u64;
                if transferred - last_reported >= PROGRESS_STEP {
                    last_reported = transferred;
                    report(transferred, 0);
                }
            }
            Some(russh::ChannelMsg::Eof) => {}
            Some(russh::ChannelMsg::ExitStatus { exit_status }) => {
                exit_code = Some(exit_status);
            }
            Some(russh::ChannelMsg::Close) | None => break,
            Some(_) => {}
        }
    }
    file.flush().await.map_err(|e| format!("落盘失败: {e}"))?;
    drop(file);
    // 退出码非 0（tar 报错）或未收到（连接中断）→ 产物截断/不可信，一律失败。
    // 部分数据的包绝不 rename 成品，否则会覆盖本地同名好包、绕开 .eterm-part 语义。
    match exit_code {
        Some(0) => {}
        Some(code) => {
            let _ = tokio::fs::remove_file(&part_path).await;
            return Err(format!("远端 tar 退出码 {code}，产物不完整"));
        }
        None => {
            let _ = tokio::fs::remove_file(&part_path).await;
            return Err("远端 tar 会话异常中断，产物不完整".to_string());
        }
    }
    tokio::fs::rename(&part_path, &local_path)
        .await
        .map_err(|e| format!("落盘改名失败: {e}"))?;
    report(transferred, transferred);
    Ok(())
}

/// 远端目录打包压缩下载（FFI，任务清单 #7）：产出 `<目录名>.tar.gz`。
/// 独立连接执行（不影响浏览会话）；取消/失败不保留暂存（流式压缩无法续传）。
#[flutter_rust_bridge::frb]
pub async fn sftp_tar_download(
    host: String,
    port: u16,
    user: String,
    auth_kind: String,
    secret: String,
    job_id: u32,
    remote_dir: String,
    local_path: String,
    sink: crate::frb_generated::StreamSink<SftpProgress>,
) -> Result<(), String> {
    let cancelled = register_cancel(job_id);
    let res = on_runtime(move || {
        Box::pin(async move {
            let conn =
                match crate::api::ssh::connect_and_auth(&host, port, &user, &auth_kind, &secret)
                    .await
                {
                    Ok(c) => c,
                    Err(reason) => return Err(reason),
                };
            let part_path = format!("{local_path}{PART_SUFFIX}");
            let dir_disp = remote_dir.clone();
            let mut report = move |t: u64, total: u64| {
                let _ = sink.add(SftpProgress {
                    job_id,
                    transferred: t,
                    total,
                    path: dir_disp.clone(),
                });
            };
            let result = tar_download_inner(
                conn.as_ref(),
                remote_dir,
                local_path,
                cancelled.clone(),
                &mut report,
            )
            .await;
            if result.is_err() {
                let _ = tokio::fs::remove_file(&part_path).await; // 流式压缩：失败不保留暂存
            }
            conn.shutdown().await;
            result
        })
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
    /// ETERM_SFTP_HOST=YOUR_SERVER_IP ETERM_SFTP_KEY=<PEM 路径> \
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

    /// k7 真机：远端↔远端直传 + 目录递归复制 + 目录打包压缩下载（环境同 roundtrip；默认跳过）。
    /// 同一会话自拷（id_from == id_to）覆盖"任选两台服务器"中同主机的退化情形。
    #[test]
    fn sftp_k7_copy_and_tar() {
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
            let id_a = sftp_connect(host.clone(), 22, user.clone(), "key".into(), secret.clone())
                .await
                .expect("连接 A 失败");
            let id_b = sftp_connect(host.clone(), 22, user, "key".into(), secret.clone())
                .await
                .expect("连接 B 失败");

            let src_dir = "/tmp/eterm-sftp-copy-src".to_string();
            let dst_dir = "/tmp/eterm-sftp-copy-dst".to_string();
            // 幂等清理
            let _ = exec_rm_rf(&host, &src_dir).await;
            let _ = exec_rm_rf(&host, &dst_dir).await;
            sftp_mkdir(id_a, src_dir.clone()).await.expect("mkdir src 失败");
            sftp_mkdir(id_a, format!("{src_dir}/sub")).await.expect("mkdir sub 失败");
            sftp_mkdir(id_a, dst_dir.clone()).await.expect("mkdir dst 失败");

            // 两级目录：/f1.bin + /sub/f2.bin
            let p1: Vec<u8> = (0..512 * 1024u32).map(|i| (i % 253) as u8).collect();
            let p2: Vec<u8> = (0..256 * 1024u32).map(|i| (i % 241) as u8).collect();
            let local1 = std::env::temp_dir().join("eterm-sftp-c1.bin");
            let local2 = std::env::temp_dir().join("eterm-sftp-c2.bin");
            std::fs::write(&local1, &p1).unwrap();
            std::fs::write(&local2, &p2).unwrap();
            upload_inner(
                id_a,
                local1.to_string_lossy().into_owned(),
                format!("{src_dir}/f1.bin"),
                false,
                Arc::new(AtomicBool::new(false)),
                |_, _| {},
            )
            .await
            .expect("上传 f1 失败");
            upload_inner(
                id_a,
                local2.to_string_lossy().into_owned(),
                format!("{src_dir}/sub/f2.bin"),
                false,
                Arc::new(AtomicBool::new(false)),
                |_, _| {},
            )
            .await
            .expect("上传 f2 失败");

            // 1) 单文件直传 A→B（同主机双会话）
            copy_file_inner(
                id_a,
                format!("{src_dir}/f1.bin"),
                id_b,
                format!("{dst_dir}/f1.bin"),
                false,
                Arc::new(AtomicBool::new(false)),
                &mut |_, _| {},
            )
            .await
            .expect("直传失败");
            let st = sftp_stat(id_b, format!("{dst_dir}/f1.bin"))
                .await
                .unwrap()
                .expect("直传后目标应存在");
            assert_eq!(st.size as usize, p1.len());

            // 2) 目录递归复制 A→B
            copy_dir_inner(
                id_a,
                src_dir.clone(),
                id_b,
                dst_dir.clone(),
                Arc::new(AtomicBool::new(false)),
                &mut |_, _| {},
            )
            .await
            .expect("目录复制失败");
            let back1 = download_to_vec(id_b, format!("{dst_dir}/f1.bin")).await;
            let back2 = download_to_vec(id_b, format!("{dst_dir}/sub/f2.bin")).await;
            assert_eq!(back1, p1, "复制后 f1 内容不一致");
            assert_eq!(back2, p2, "复制后 f2 内容不一致");

            // 3) 目录打包压缩下载：tar.gz 落本地并解包校验
            let local_tar = std::env::temp_dir().join("eterm-sftp-src.tar.gz");
            let _ = std::fs::remove_file(&local_tar);
            let conn = crate::api::ssh::connect_and_auth(&host, 22, "root", "key", &secret)
                .await
                .expect("tar 连接失败");
            #[allow(clippy::needless_borrows_for_generic_args)]
            tar_download_inner(
                conn.as_ref(),
                src_dir.clone(),
                local_tar.to_string_lossy().into_owned(),
                Arc::new(AtomicBool::new(false)),
                &mut |_, _| {},
            )
            .await
            .expect("tar 下载失败");
            conn.shutdown().await;
            assert!(std::fs::metadata(&local_tar).unwrap().len() > 0, "tar 包不应为空");
            // 解包到临时目录比对
            let untar = tempfile::tempdir().unwrap();
            let st = std::process::Command::new("tar")
                .args(["-xzf", local_tar.to_str().unwrap(), "-C", untar.path().to_str().unwrap()])
                .status()
                .unwrap();
            assert!(st.success(), "解包失败");
            assert_eq!(
                std::fs::read(untar.path().join("eterm-sftp-copy-src/f1.bin")).unwrap(),
                p1,
                "tar 包内 f1 不一致"
            );
            assert_eq!(
                std::fs::read(untar.path().join("eterm-sftp-copy-src/sub/f2.bin")).unwrap(),
                p2,
                "tar 包内 f2 不一致"
            );

            // 清理
            let _ = exec_rm_rf(&host, &src_dir).await;
            let _ = exec_rm_rf(&host, &dst_dir).await;
            sftp_disconnect(id_a);
            sftp_disconnect(id_b);
            let _ = std::fs::remove_file(&local1);
            let _ = std::fs::remove_file(&local2);
            let _ = std::fs::remove_file(&local_tar);
        });
    }

    /// 经独立连接 exec rm -rf（测试清理；一条命令，输出忽略）。
    async fn exec_rm_rf(host: &str, path: &str) {
        let Ok(conn) =
            crate::api::ssh::connect_and_auth(host, 22, "root", "key", &std::fs::read_to_string(
                std::env::var("ETERM_SFTP_KEY").unwrap_or_default(),
            )
            .unwrap_or_default())
            .await
        else {
            return;
        };
        let mut ch = match conn.open_session().await {
            Ok(c) => c,
            Err(_) => return,
        };
        let cmd = format!("rm -rf '{}'", path.replace('\'', "'\\''"));
        let _ = ch.exec(true, cmd.as_str()).await;
        while let Some(msg) = ch.wait().await {
            if matches!(msg, russh::ChannelMsg::Close | russh::ChannelMsg::Eof) {
                break;
            }
        }
        conn.shutdown().await;
    }

    /// 下载远端文件内容到 Vec（测试比对用）。
    async fn download_to_vec(id: u64, path: String) -> Vec<u8> {
        let tmp = std::env::temp_dir().join(format!("eterm-sftp-vec-{}", uuid_like()));
        download_inner(
            id,
            path,
            tmp.to_string_lossy().into_owned(),
            false,
            Arc::new(AtomicBool::new(false)),
            |_, _| {},
        )
        .await
        .expect("回读失败");
        let out = std::fs::read(&tmp).unwrap();
        let _ = std::fs::remove_file(&tmp);
        out
    }

    fn uuid_like() -> u64 {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .subsec_nanos() as u64
            ^ std::process::id() as u64
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

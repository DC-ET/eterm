pub mod field;
pub mod keystore;
pub mod sshkey;

pub use field::{open_field, seal_field, CoreError};
pub(crate) use field::base64_encode;
pub use sshkey::{
    generate_ecdsa_p256, generate_ed25519, generate_rsa, inspect_secret, GeneratedKey, SshKeyMeta,
};

/// 当前 Unix 秒（时钟回拨等异常按 0 处理，与历史行为一致）。
pub fn unix_now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// Unix 秒 → RFC3339 UTC（秒级精度，无外部依赖）。
/// 评审 BUG-R1 回归：day-of-year 是 0 基，格式化前必须 +1 变成 1 基的"几号"，
/// 否则日期恒差一天且 epoch 当天会输出非法的 1970-01-00。
pub fn rfc3339_from_unix(secs: u64) -> String {
    let days = secs / 86_400;
    let rem = secs % 86_400;
    let (h, m, s) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    let mut y = 1970i64;
    let mut d = days as i64;
    loop {
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
        let yl = if leap { 366 } else { 365 };
        if d < yl { break; }
        d -= yl;
        y += 1;
    }
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let ml = [31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let mut mo = 1;
    while d >= ml[(mo - 1) as usize] { d -= ml[(mo - 1) as usize]; mo += 1; }
    d += 1; // 0 基 day-of-year → 1 基 day-of-month
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{m:02}:{s:02}Z")
}

#[cfg(test)]
mod tests {
    use super::rfc3339_from_unix;

    /// BUG-R1（docs/code-review/2026-11-15-逻辑bug评审.md）回归：
    /// 日期必须是 1 基（首版实现输出 1970-01-00 / 恒差一天）。
    /// 覆盖 epoch 起点、日界、闰日（当年/世纪前）、年界。
    #[test]
    fn rfc3339_from_unix_day_is_one_based() {
        assert_eq!(rfc3339_from_unix(0), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339_from_unix(86_399), "1970-01-01T23:59:59Z");
        assert_eq!(rfc3339_from_unix(1_794_700_800), "2026-11-15T00:00:00Z");
        assert_eq!(rfc3339_from_unix(1_709_164_800), "2024-02-29T00:00:00Z");
        assert_eq!(rfc3339_from_unix(951_782_400), "2000-02-29T00:00:00Z");
        assert_eq!(rfc3339_from_unix(1_703_980_800), "2023-12-31T00:00:00Z");
    }
}

// ---------- 共享 tokio runtime（SSH 数据面：终端 + SFTP + 端口转发） ----------

// frb::spawn 的执行器不带 tokio reactor（russh 首个 await 即 panic：
// "there is no reactor running"），russh 相关任务必须跑在自己的 runtime 上。
// OnceLock 单例，api/ssh 等模块共用（api/ 之外，避开 frb 扫描）。
static RUNTIME: std::sync::OnceLock<tokio::runtime::Runtime> = std::sync::OnceLock::new();

/// 全局 tokio runtime（multi-thread + enable_all）。
pub fn ssh_runtime() -> &'static tokio::runtime::Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("tokio runtime 初始化失败")
    })
}

// ---------- 已认证 SSH 连接的对象安全视图（终端/SFTP/端口转发共用） ----------

/// 已认证连接的全部下游需求。具体 Handler 类型（TOFU 校验器）留在 api::ssh 私有；
/// impl Trait 不能做字段类型，故经对象安全 trait 以 Arc<dyn _> 持有。
#[async_trait::async_trait]
pub trait AuthedConn: Send + Sync {
    /// 开会话通道（终端 PTY shell / SFTP 子系统的载体）。
    async fn open_session(&self) -> Result<russh::Channel<russh::client::Msg>, russh::Error>;

    /// 开 direct-tcpip 通道（local -L 转发的数据通路）。
    async fn open_direct(
        &self,
        host: String,
        port: u32,
        origin_addr: String,
        origin_port: u32,
    ) -> Result<russh::Channel<russh::client::Msg>, russh::Error>;

    /// 干净断开连接。
    async fn shutdown(&self);
}

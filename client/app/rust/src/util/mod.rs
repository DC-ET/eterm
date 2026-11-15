pub mod field;
pub mod keystore;

pub use field::{open_field, seal_field, CoreError};

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

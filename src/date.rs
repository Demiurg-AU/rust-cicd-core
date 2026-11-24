use std::error::Error as StdError;
use std::fmt;
use std::str;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[cfg(all(
    target_pointer_width = "32",
    not(target_os = "windows"),
    not(all(target_arch = "wasm32", not(target_os = "emscripten")))
))]
mod max {
    pub(super) const SECONDS: u64 = ::std::i32::MAX as u64;
    #[allow(unused)]
    pub(super) const TIMESTAMP: &'static str = "2038-01-19T03:14:07Z";
}

#[cfg(any(
    target_pointer_width = "64",
    target_os = "windows",
    all(target_arch = "wasm32", not(target_os = "emscripten")),
))]
mod max {
    pub(super) const SECONDS: u64 = 253_402_300_800 - 1; // last second of year 9999
    #[allow(unused)]
    pub(super) const TIMESTAMP: &str = "9999-12-31T23:59:59Z";
}

/// Error parsing datetime (timestamp)
#[derive(Debug, PartialEq, Clone, Copy)]
pub enum Error {
    /// Numeric component is out of range
    OutOfRange,
    /// Bad character where digit is expected
    InvalidDigit,
    /// Other formatting errors
    InvalidFormat,
}

impl StdError for Error {}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::OutOfRange => write!(f, "numeric component is out of range"),
            Error::InvalidDigit => write!(f, "bad character where digit is expected"),
            Error::InvalidFormat => write!(f, "timestamp format is invalid"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Precision {
    Smart,
    Seconds,
    Millis,
    Micros,
    Nanos,
}

/// A wrapper type that allows you to Display a SystemTime
#[derive(Debug, Clone)]
pub struct Rfc3339Timestamp(SystemTime, Precision);

#[inline]
/// Converts two digits given in ASCII to its proper decimal representation.
fn two_digits(b1: u8, b2: u8) -> Result<u64, Error> {
    let a = (b1 as char).to_digit(10).ok_or(Error::InvalidDigit)?;
    let b = (b2 as char).to_digit(10).ok_or(Error::InvalidDigit)?;
    // a, b <= 9: at most 99
    a.checked_mul(10)
        .and_then(|x| x.checked_add(b))
        .map(u64::from)
        .ok_or(Error::InvalidDigit)
}

/// Parse RFC3339 timestamp `2018-02-14T00:28:07Z`
///
/// Supported features:
/// - Any precision of fractional digits `2018-02-14T00:28:07.133Z`.
/// - The UTC timezone can be indicated with `Z` or `+00:00`.
///
/// Unsupported feature: localized timestamps. Only UTC is supported.
pub fn parse_rfc3339(s: &str) -> Result<SystemTime, Error> {
    if s.len() < "2018-02-14T00:28:07Z".len() {
        return Err(Error::InvalidFormat);
    }
    let b = s.as_bytes();
    if b.get(10) != Some(&b'T') || (b.last() != Some(&b'Z') && !s.ends_with("+00:00")) {
        return Err(Error::InvalidFormat);
    }
    parse_rfc3339_weak(s)
}

/// Days since 1970-01-01 of a date with year >= 1970; OutOfRange for an invalid month or day.
fn days_since_epoch(year: u64, month: u64, day: u64) -> Result<u64, Error> {
    let leap = is_leap_year(year);
    let (ydays, mdays): (u64, u64) = match month {
        1 => (0, 31),
        2 if leap => (31, 29),
        2 => (31, 28),
        3 => (59, 31),
        4 => (90, 30),
        5 => (120, 31),
        6 => (151, 30),
        7 => (181, 31),
        8 => (212, 31),
        9 => (243, 30),
        10 => (273, 31),
        11 => (304, 30),
        12 => (334, 31),
        _ => return Err(Error::OutOfRange),
    };
    if day > mdays || day == 0 {
        return Err(Error::OutOfRange);
    }
    let after_feb = u64::from(leap && month > 2);
    let calc = || -> Option<u64> {
        let ydays = ydays
            .checked_add(day.checked_sub(1)?)?
            .checked_add(after_feb)?;
        let py = year.checked_sub(1)?;
        let leap_years = (py.checked_sub(1968)? / 4)
            .checked_sub(py.checked_sub(1900)? / 100)?
            .checked_add(py.checked_sub(1600)? / 400)?;
        year.checked_sub(1970)?
            .checked_mul(365)?
            .checked_add(leap_years)?
            .checked_add(ydays)
    };
    calc().ok_or(Error::OutOfRange)
}

/// Parse RFC3339-like timestamp `2018-02-14 00:28:07`
///
/// Supported features:
///
/// 1. Any precision of fractional digits `2018-02-14 00:28:07.133`.
/// 2. Supports timestamp with or without either of `T`, `Z` or `+00:00`.
/// 3. Anything valid for [`parse_rfc3339`](parse_rfc3339) is valid for this function
///
/// Unsupported feature: localized timestamps. Only UTC is supported, even if
/// `Z` is not specified.
///
/// This function is intended to use for parsing human input. Whereas
/// `parse_rfc3339` is for strings generated programmatically.
pub fn parse_rfc3339_weak(s: &str) -> Result<SystemTime, Error> {
    let b = s.as_bytes();
    let head: [u8; 19] = b
        .get(..19)
        .and_then(|h| h.try_into().ok())
        .ok_or(Error::InvalidFormat)?;
    let [y0, y1, y2, y3, dash1, m0, m1, dash2, d0, d1, sep, h0, h1, colon1, mi0, mi1, colon2, s0, s1] =
        head;
    if dash1 != b'-'
        || dash2 != b'-'
        || (sep != b'T' && sep != b' ')
        || colon1 != b':'
        || colon2 != b':'
    {
        return Err(Error::InvalidFormat);
    }
    let year = two_digits(y0, y1)?
        .checked_mul(100)
        .and_then(|x| x.checked_add(two_digits(y2, y3).ok()?))
        .ok_or(Error::InvalidDigit)?;
    let month = two_digits(m0, m1)?;
    let day = two_digits(d0, d1)?;
    let hour = two_digits(h0, h1)?;
    let minute = two_digits(mi0, mi1)?;
    let mut second = two_digits(s0, s1)?;

    if year < 1970 || hour > 23 || minute > 59 || second > 60 {
        return Err(Error::OutOfRange);
    }
    // TODO(tailhook) should we check that leaps second is only on midnight ?
    if second == 60 {
        second = 59;
    }

    let days = days_since_epoch(year, month, day)?;
    // second <= 59, minute <= 59, hour <= 23
    let time = minute
        .checked_mul(60)
        .and_then(|x| x.checked_add(hour.checked_mul(3600)?))
        .and_then(|x| x.checked_add(second))
        .ok_or(Error::OutOfRange)?;

    let mut nanos: u32 = 0;
    let mut mult: u32 = 100_000_000;
    let tail = b.get(19..).unwrap_or_default();
    if tail.first() == Some(&b'.') {
        let frac = tail.get(1..).unwrap_or_default();
        let last = frac.len().checked_sub(1);
        let tz_start = frac.len().checked_sub(6);
        for (idx, &c) in frac.iter().enumerate() {
            if c == b'Z' {
                if Some(idx) == last {
                    break;
                }
                return Err(Error::InvalidDigit);
            } else if c == b'+' {
                // start of "+00:00", which must be at the end
                if Some(idx) == tz_start {
                    break;
                }
                return Err(Error::InvalidDigit);
            }

            let digit = (c as char).to_digit(10).ok_or(Error::InvalidDigit)?;
            // mult * digit <= 900_000_000 and the sum stays below 1_000_000_000
            nanos = mult
                .checked_mul(digit)
                .and_then(|x| x.checked_add(nanos))
                .ok_or(Error::OutOfRange)?;
            mult /= 10;
        }
    } else if !tail.is_empty()
        && (b.len() > 25 || (tail.first() != Some(&b'Z') && tail != b"+00:00"))
    {
        return Err(Error::InvalidFormat);
    }

    let total_seconds = days
        .checked_mul(86400)
        .and_then(|x| x.checked_add(time))
        .ok_or(Error::OutOfRange)?;
    if total_seconds > max::SECONDS {
        return Err(Error::OutOfRange);
    }

    UNIX_EPOCH
        .checked_add(Duration::new(total_seconds, nanos))
        .ok_or(Error::OutOfRange)
}

fn is_leap_year(y: u64) -> bool {
    y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
}

/// Format an RFC3339 timestamp `2018-02-14T00:28:07Z`
///
/// This function formats timestamp with smart precision: i.e. if it has no
/// fractional seconds, they aren't written at all. And up to nine digits if
/// they are.
///
/// The value is always UTC and ignores system timezone.
pub fn format_rfc3339(system_time: SystemTime) -> Rfc3339Timestamp {
    Rfc3339Timestamp(system_time, Precision::Smart)
}

/// Format an RFC3339 timestamp `2018-02-14T00:28:07Z`
///
/// This format always shows timestamp without fractional seconds.
///
/// The value is always UTC and ignores system timezone.
pub fn format_rfc3339_seconds(system_time: SystemTime) -> Rfc3339Timestamp {
    Rfc3339Timestamp(system_time, Precision::Seconds)
}

/// Format an RFC3339 timestamp `2018-02-14T00:28:07.000Z`
///
/// This format always shows milliseconds even if millisecond value is zero.
///
/// The value is always UTC and ignores system timezone.
pub fn format_rfc3339_millis(system_time: SystemTime) -> Rfc3339Timestamp {
    Rfc3339Timestamp(system_time, Precision::Millis)
}

/// Format an RFC3339 timestamp `2018-02-14T00:28:07.000000Z`
///
/// This format always shows microseconds even if microsecond value is zero.
///
/// The value is always UTC and ignores system timezone.
pub fn format_rfc3339_micros(system_time: SystemTime) -> Rfc3339Timestamp {
    Rfc3339Timestamp(system_time, Precision::Micros)
}

/// Format an RFC3339 timestamp `2018-02-14T00:28:07.000000000Z`
///
/// This format always shows nanoseconds even if nanosecond value is zero.
///
/// The value is always UTC and ignores system timezone.
pub fn format_rfc3339_nanos(system_time: SystemTime) -> Rfc3339Timestamp {
    Rfc3339Timestamp(system_time, Precision::Nanos)
}

impl Rfc3339Timestamp {
    /// Returns a reference to the [`SystemTime`][] that is being formatted.
    pub fn get_ref(&self) -> &SystemTime {
        &self.0
    }
}

/// Civil date and time of day for seconds since the epoch, for years up to 9999.
/// Returns (year, month, day of month, seconds of day); None only on arithmetic overflow.
fn civil_from_unix(secs_since_epoch: u64) -> Option<(i64, i64, i64, u64)> {
    /* 2000-03-01 (mod 400 year, immediately after feb29 */
    const LEAPOCH: i64 = 11017;
    const DAYS_PER_400Y: i64 = 365 * 400 + 97;
    const DAYS_PER_100Y: i64 = 365 * 100 + 24;
    const DAYS_PER_4Y: i64 = 365 * 4 + 1;

    let days = i64::try_from(secs_since_epoch / 86400)
        .ok()?
        .checked_sub(LEAPOCH)?;
    let secs_of_day = secs_since_epoch % 86400;

    let mut qc_cycles = days.checked_div(DAYS_PER_400Y)?;
    let mut remdays = days.checked_rem(DAYS_PER_400Y)?;

    if remdays < 0 {
        remdays = remdays.checked_add(DAYS_PER_400Y)?;
        qc_cycles = qc_cycles.checked_sub(1)?;
    }

    let c_cycles = (remdays / DAYS_PER_100Y).min(3);
    remdays = remdays.checked_sub(c_cycles.checked_mul(DAYS_PER_100Y)?)?;

    let q_cycles = (remdays / DAYS_PER_4Y).min(24);
    remdays = remdays.checked_sub(q_cycles.checked_mul(DAYS_PER_4Y)?)?;

    let remyears = (remdays / 365).min(3);
    remdays = remdays.checked_sub(remyears.checked_mul(365)?)?;

    let mut year = remyears
        .checked_add(q_cycles.checked_mul(4)?)?
        .checked_add(c_cycles.checked_mul(100)?)?
        .checked_add(qc_cycles.checked_mul(400)?)?
        .checked_add(2000)?;

    // months from March
    let months = [31, 30, 31, 30, 31, 31, 30, 31, 30, 31, 31, 29];
    let mut mon: i64 = 0;
    for mon_len in months {
        mon = mon.checked_add(1)?;
        if remdays < mon_len {
            break;
        }
        remdays = remdays.checked_sub(mon_len)?;
    }
    let mday = remdays.checked_add(1)?;
    let mon = if mon > 10 {
        year = year.checked_add(1)?;
        mon.checked_sub(10)?
    } else {
        mon.checked_add(2)?
    };
    Some((year, mon, mday, secs_of_day))
}

impl fmt::Display for Rfc3339Timestamp {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        use self::Precision::*;

        // a time before the epoch cannot be written: an error, like a year after 9999
        // (this used to panic: "all times should be after the epoch")
        let dur = self.0.duration_since(UNIX_EPOCH).map_err(|_| fmt::Error)?;
        let secs_since_epoch = dur.as_secs();
        let nanos = dur.subsec_nanos();

        if secs_since_epoch >= 253_402_300_800 {
            // year 9999
            return Err(fmt::Error);
        }

        let (year, mon, mday, secs_of_day) = civil_from_unix(secs_since_epoch).ok_or(fmt::Error)?;
        write!(
            f,
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}",
            year,
            mon,
            mday,
            secs_of_day / 3600,
            secs_of_day / 60 % 60,
            secs_of_day % 60
        )?;
        if self.1 == Seconds || nanos == 0 && self.1 == Smart {
            // no fractional part
        } else if self.1 == Millis {
            write!(f, ".{:03}", nanos / 1_000_000)?;
        } else if self.1 == Micros {
            write!(f, ".{:06}", nanos / 1_000)?;
        } else {
            write!(f, ".{:09}", nanos)?;
        }
        f.write_str("Z")
    }
}

#[cfg(test)]
mod test {
    use std::str::from_utf8;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    use rand::Rng;
    use time::format_description::well_known::Rfc3339;
    use time::UtcDateTime;

    use super::format_rfc3339_nanos;
    use super::max;
    use super::{format_rfc3339, parse_rfc3339, parse_rfc3339_weak};
    use super::{format_rfc3339_micros, format_rfc3339_millis};

    fn from_sec(sec: u64) -> (String, SystemTime) {
        let s = UtcDateTime::from_unix_timestamp(sec as i64)
            .unwrap()
            .format(&Rfc3339)
            .unwrap();
        let time = UNIX_EPOCH + Duration::new(sec, 0);
        (s, time)
    }

    #[test]
    #[cfg(all(target_pointer_width = "32", target_os = "linux"))]
    fn year_after_2038_fails_gracefully() {
        // next second
        assert_eq!(
            parse_rfc3339("2038-01-19T03:14:08Z").unwrap_err(),
            super::Error::OutOfRange
        );
        assert_eq!(
            parse_rfc3339("9999-12-31T23:59:59Z").unwrap_err(),
            super::Error::OutOfRange
        );
    }

    #[test]
    fn smoke_tests_parse() {
        assert_eq!(
            parse_rfc3339("1970-01-01T00:00:00Z").unwrap(),
            UNIX_EPOCH + Duration::new(0, 0)
        );
        assert_eq!(
            parse_rfc3339("1970-01-01T00:00:01Z").unwrap(),
            UNIX_EPOCH + Duration::new(1, 0)
        );
        assert_eq!(
            parse_rfc3339("2018-02-13T23:08:32Z").unwrap(),
            UNIX_EPOCH + Duration::new(1_518_563_312, 0)
        );
        assert_eq!(
            parse_rfc3339("2012-01-01T00:00:00Z").unwrap(),
            UNIX_EPOCH + Duration::new(1_325_376_000, 0)
        );
    }

    #[test]
    fn smoke_tests_format() {
        assert_eq!(
            format_rfc3339(UNIX_EPOCH + Duration::new(0, 0)).to_string(),
            "1970-01-01T00:00:00Z"
        );
        assert_eq!(
            format_rfc3339(UNIX_EPOCH + Duration::new(1, 0)).to_string(),
            "1970-01-01T00:00:01Z"
        );
        assert_eq!(
            format_rfc3339(UNIX_EPOCH + Duration::new(1_518_563_312, 0)).to_string(),
            "2018-02-13T23:08:32Z"
        );
        assert_eq!(
            format_rfc3339(UNIX_EPOCH + Duration::new(1_325_376_000, 0)).to_string(),
            "2012-01-01T00:00:00Z"
        );
    }

    #[test]
    fn smoke_tests_format_millis() {
        assert_eq!(
            format_rfc3339_millis(UNIX_EPOCH + Duration::new(0, 0)).to_string(),
            "1970-01-01T00:00:00.000Z"
        );
        assert_eq!(
            format_rfc3339_millis(UNIX_EPOCH + Duration::new(1_518_563_312, 123_000_000))
                .to_string(),
            "2018-02-13T23:08:32.123Z"
        );
    }

    #[test]
    fn smoke_tests_format_micros() {
        assert_eq!(
            format_rfc3339_micros(UNIX_EPOCH + Duration::new(0, 0)).to_string(),
            "1970-01-01T00:00:00.000000Z"
        );
        assert_eq!(
            format_rfc3339_micros(UNIX_EPOCH + Duration::new(1_518_563_312, 123_000_000))
                .to_string(),
            "2018-02-13T23:08:32.123000Z"
        );
        assert_eq!(
            format_rfc3339_micros(UNIX_EPOCH + Duration::new(1_518_563_312, 456_123_000))
                .to_string(),
            "2018-02-13T23:08:32.456123Z"
        );
    }

    #[test]
    fn smoke_tests_format_nanos() {
        assert_eq!(
            format_rfc3339_nanos(UNIX_EPOCH + Duration::new(0, 0)).to_string(),
            "1970-01-01T00:00:00.000000000Z"
        );
        assert_eq!(
            format_rfc3339_nanos(UNIX_EPOCH + Duration::new(1_518_563_312, 123_000_000))
                .to_string(),
            "2018-02-13T23:08:32.123000000Z"
        );
        #[cfg(not(target_os = "windows"))]
        assert_eq!(
            format_rfc3339_nanos(UNIX_EPOCH + Duration::new(1_518_563_312, 789_456_123))
                .to_string(),
            "2018-02-13T23:08:32.789456123Z"
        );
        #[cfg(target_os = "windows")] // Not sure what is up with Windows rounding?
        assert_eq!(
            format_rfc3339_nanos(UNIX_EPOCH + Duration::new(1_518_563_312, 789_456_123))
                .to_string(),
            "2018-02-13T23:08:32.789456100Z"
        );
    }

    #[test]
    fn upper_bound() {
        let max = UNIX_EPOCH + Duration::new(max::SECONDS, 0);
        assert_eq!(parse_rfc3339(max::TIMESTAMP).unwrap(), max);
        assert_eq!(format_rfc3339(max).to_string(), max::TIMESTAMP);
    }

    #[test]
    fn leap_second() {
        assert_eq!(
            parse_rfc3339("2016-12-31T23:59:60Z").unwrap(),
            UNIX_EPOCH + Duration::new(1_483_228_799, 0)
        );
    }

    #[test]
    fn first_731_days() {
        let year_start = 0; // 1970
        for day in 0..=365 * 2 {
            // scan leap year and non-leap year
            let (s, time) = from_sec(year_start + day * 86400);
            assert_eq!(parse_rfc3339(&s).unwrap(), time);
            assert_eq!(format_rfc3339(time).to_string(), s);
        }
    }

    #[test]
    fn the_731_consecutive_days() {
        let year_start = 1_325_376_000; // 2012
        for day in 0..=365 * 2 {
            // scan leap year and non-leap year
            let (s, time) = from_sec(year_start + day * 86400);
            assert_eq!(parse_rfc3339(&s).unwrap(), time);
            assert_eq!(format_rfc3339(time).to_string(), s);
        }
    }

    #[test]
    fn all_86400_seconds() {
        let day_start = 1_325_376_000;
        for second in 0..86400 {
            // scan leap year and non-leap year
            let (s, time) = from_sec(day_start + second);
            assert_eq!(parse_rfc3339(&s).unwrap(), time);
            assert_eq!(format_rfc3339(time).to_string(), s);
        }
    }

    #[test]
    fn random_past() {
        let upper = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        for _ in 0..10000 {
            let sec = rand::rng().random_range(0..upper);
            let (s, time) = from_sec(sec);
            assert_eq!(parse_rfc3339(&s).unwrap(), time);
            assert_eq!(format_rfc3339(time).to_string(), s);
        }
    }

    #[test]
    fn random_wide_range() {
        for _ in 0..100_000 {
            let sec = rand::rng().random_range(0..max::SECONDS);
            let (s, time) = from_sec(sec);
            assert_eq!(parse_rfc3339(&s).unwrap(), time);
            assert_eq!(format_rfc3339(time).to_string(), s);
        }
    }

    #[test]
    fn milliseconds() {
        assert_eq!(
            parse_rfc3339("1970-01-01T00:00:00.123Z").unwrap(),
            UNIX_EPOCH + Duration::new(0, 123_000_000)
        );
        assert_eq!(
            format_rfc3339(UNIX_EPOCH + Duration::new(0, 123_000_000)).to_string(),
            "1970-01-01T00:00:00.123000000Z"
        );
    }

    #[test]
    #[should_panic(expected = "OutOfRange")]
    fn zero_month() {
        parse_rfc3339("1970-00-01T00:00:00Z").unwrap();
    }

    #[test]
    #[should_panic(expected = "OutOfRange")]
    fn big_month() {
        parse_rfc3339("1970-32-01T00:00:00Z").unwrap();
    }

    #[test]
    #[should_panic(expected = "OutOfRange")]
    fn zero_day() {
        parse_rfc3339("1970-01-00T00:00:00Z").unwrap();
    }

    #[test]
    #[should_panic(expected = "OutOfRange")]
    fn big_day() {
        parse_rfc3339("1970-12-35T00:00:00Z").unwrap();
    }

    #[test]
    #[should_panic(expected = "OutOfRange")]
    fn big_day2() {
        parse_rfc3339("1970-02-30T00:00:00Z").unwrap();
    }

    #[test]
    #[should_panic(expected = "OutOfRange")]
    fn big_second() {
        parse_rfc3339("1970-12-30T00:00:78Z").unwrap();
    }

    #[test]
    #[should_panic(expected = "OutOfRange")]
    fn big_minute() {
        parse_rfc3339("1970-12-30T00:78:00Z").unwrap();
    }

    #[test]
    #[should_panic(expected = "OutOfRange")]
    fn big_hour() {
        parse_rfc3339("1970-12-30T24:00:00Z").unwrap();
    }

    #[test]
    fn break_data() {
        for pos in 0.."2016-12-31T23:59:60Z".len() {
            let mut s = b"2016-12-31T23:59:60Z".to_vec();
            s[pos] = b'x';
            parse_rfc3339(from_utf8(&s).unwrap()).unwrap_err();
        }
    }

    #[test]
    fn weak_smoke_tests() {
        assert_eq!(
            parse_rfc3339_weak("1970-01-01 00:00:00").unwrap(),
            UNIX_EPOCH + Duration::new(0, 0)
        );
        parse_rfc3339("1970-01-01 00:00:00").unwrap_err();

        assert_eq!(
            parse_rfc3339_weak("1970-01-01 00:00:00.000123").unwrap(),
            UNIX_EPOCH + Duration::new(0, 123_000)
        );
        parse_rfc3339("1970-01-01 00:00:00.000123").unwrap_err();

        assert_eq!(
            parse_rfc3339_weak("1970-01-01T00:00:00.000123").unwrap(),
            UNIX_EPOCH + Duration::new(0, 123_000)
        );
        parse_rfc3339("1970-01-01T00:00:00.000123").unwrap_err();

        assert_eq!(
            parse_rfc3339_weak("1970-01-01 00:00:00.000123Z").unwrap(),
            UNIX_EPOCH + Duration::new(0, 123_000)
        );
        parse_rfc3339("1970-01-01 00:00:00.000123Z").unwrap_err();

        assert_eq!(
            parse_rfc3339_weak("1970-01-01 00:00:00Z").unwrap(),
            UNIX_EPOCH + Duration::new(0, 0)
        );
        parse_rfc3339("1970-01-01 00:00:00Z").unwrap_err();
    }

    #[test]
    fn parse_offset_00() {
        assert_eq!(
            parse_rfc3339("1970-01-01T00:00:00+00:00").unwrap(),
            UNIX_EPOCH + Duration::new(0, 0)
        );
        assert_eq!(
            parse_rfc3339("1970-01-01T00:00:01+00:00").unwrap(),
            UNIX_EPOCH + Duration::new(1, 0)
        );
        assert_eq!(
            parse_rfc3339("2018-02-13T23:08:32+00:00").unwrap(),
            UNIX_EPOCH + Duration::new(1_518_563_312, 0)
        );
        assert_eq!(
            parse_rfc3339("2012-01-01T00:00:00+00:00").unwrap(),
            UNIX_EPOCH + Duration::new(1_325_376_000, 0)
        );

        // invalid
        assert_eq!(
            parse_rfc3339("2012-01-01T00:00:00 +00:00"),
            Err(super::Error::InvalidFormat)
        );
        assert_eq!(
            parse_rfc3339("2012-01-01T00:00:00+00"),
            Err(super::Error::InvalidFormat)
        );
    }

    #[test]
    fn weak_parse_offset_00() {
        assert_eq!(
            parse_rfc3339_weak("1970-01-01 00:00:00+00:00").unwrap(),
            UNIX_EPOCH + Duration::new(0, 0)
        );
        assert_eq!(
            parse_rfc3339_weak("1970-01-01 00:00:00.000123+00:00").unwrap(),
            UNIX_EPOCH + Duration::new(0, 123_000)
        );
        assert_eq!(
            parse_rfc3339_weak("1970-01-01T00:00:00.000123+00:00").unwrap(),
            UNIX_EPOCH + Duration::new(0, 123_000)
        );

        // invalid
        parse_rfc3339("2012-01-01T+00:00:00").unwrap_err();
        parse_rfc3339("1970-01-01 00:00:00.00+0123").unwrap_err();
        parse_rfc3339("1970-01-01 00:00:00.0000123+00:00").unwrap_err();
        parse_rfc3339("1970-01-01 00:00:00.0000123+00:00abcd").unwrap_err();
        parse_rfc3339("1970-01-01 00:00:00.0000123+02:00").unwrap_err();
        parse_rfc3339("1970-01-01 00:00:00.0000123+00").unwrap_err();
        parse_rfc3339("1970-01-01 00:00:00.0000123+").unwrap_err();
    }
}

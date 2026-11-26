#![no_main]
//! Experiment E-6, candidate D: humantime's RFC 3339 parser against an independent implementation (the `time`
//! crate). Every "DDDD-DD-DDTDD:DD:DDZ" with any digits. Oracle: if humantime accepts, `time` accepts with the
//! same Unix second; if `time` accepts a year >= 1970, humantime accepts. Second 60 is skipped (humantime maps a
//! leap second to :59 by design; `time` rejects it).
use libfuzzer_sys::fuzz_target;
use std::time::UNIX_EPOCH;
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

fuzz_target!(|digits: [u8; 14]| {
    let mut b = *b"0000-00-00T00:00:00Z";
    for (k, i) in [0usize, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18].into_iter().enumerate() {
        b[i] = b'0' + digits[k] % 10;
    }
    if &b[17..19] == b"60" {
        return;
    }
    let s = std::str::from_utf8(&b).expect("ASCII by construction");
    let h = humantime::parse_rfc3339(s).ok().map(|t| t.duration_since(UNIX_EPOCH).expect("after epoch").as_secs());
    let t = OffsetDateTime::parse(s, &Rfc3339).ok().map(|t| t.unix_timestamp());
    match (h, t) {
        (Some(hs), Some(ts)) => assert_eq!(i64::try_from(hs).ok(), Some(ts), "FUZZ-ORACLE vs time {s}"),
        (Some(_), None) => panic!("FUZZ-ORACLE humantime accepts, time rejects: {s}"),
        (None, Some(ts)) if ts >= 0 => panic!("FUZZ-ORACLE time accepts, humantime rejects: {s}"),
        _ => {}
    }
});

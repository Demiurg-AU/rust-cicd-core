#[macro_use]
extern crate bencher;

use bencher::Bencher;
use humantime::parse_rfc3339;
use time::format_description::well_known::Rfc3339;
use time::OffsetDateTime;

// Comparison implementation: the `time` crate (chrono was dropped: RUSTSEC-2026-0543, unmaintained).

fn rfc3339_humantime_seconds(b: &mut Bencher) {
    b.iter(|| parse_rfc3339("2018-02-13T23:08:32Z").unwrap());
}

fn time_parse_seconds(b: &mut Bencher) {
    b.iter(|| OffsetDateTime::parse("2018-02-13T23:08:32Z", &Rfc3339).unwrap());
}

fn rfc3339_humantime_millis(b: &mut Bencher) {
    b.iter(|| parse_rfc3339("2018-02-13T23:08:32.123Z").unwrap());
}

fn time_parse_millis(b: &mut Bencher) {
    b.iter(|| OffsetDateTime::parse("2018-02-13T23:08:32.123Z", &Rfc3339).unwrap());
}

fn rfc3339_humantime_nanos(b: &mut Bencher) {
    b.iter(|| parse_rfc3339("2018-02-13T23:08:32.123456983Z").unwrap());
}

fn time_parse_nanos(b: &mut Bencher) {
    b.iter(|| OffsetDateTime::parse("2018-02-13T23:08:32.123456983Z", &Rfc3339).unwrap());
}

benchmark_group!(
    benches,
    rfc3339_humantime_seconds,
    time_parse_seconds,
    rfc3339_humantime_millis,
    time_parse_millis,
    rfc3339_humantime_nanos,
    time_parse_nanos
);
benchmark_main!(benches);

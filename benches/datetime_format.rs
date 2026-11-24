#[macro_use]
extern crate bencher;

use std::io::Write;
use std::time::{Duration, UNIX_EPOCH};

use bencher::Bencher;
use humantime::format_rfc3339;

fn rfc3339_humantime_seconds(b: &mut Bencher) {
    let time = UNIX_EPOCH + Duration::new(1_483_228_799, 0);
    let mut buf = Vec::with_capacity(100);
    b.iter(|| {
        buf.clear();
        write!(&mut buf, "{}", format_rfc3339(time)).unwrap()
    });
}

// Comparison implementation: the `time` crate (chrono was dropped: RUSTSEC-2026-0543, unmaintained).
fn rfc3339_time(b: &mut Bencher) {
    use time::format_description::well_known::Rfc3339;
    use time::OffsetDateTime;

    let time = OffsetDateTime::from_unix_timestamp(1_483_228_799).unwrap();
    let mut buf = Vec::with_capacity(100);
    b.iter(|| {
        buf.clear();
        time.format_into(&mut buf, &Rfc3339).unwrap()
    });
}

benchmark_group!(benches, rfc3339_humantime_seconds, rfc3339_time);
benchmark_main!(benches);

# humantime Kani pack (3b) — not run by default

`scripts/pilot.sh pilots/humantime 3b` runs the fuzz pack (`spec/`). This Kani pack is kept apart because on the
machine of the 2026-11-21 run (2 cores, 7 GB RAM, Kani/CBMC 6.11) every attempt ran out of memory:

| harness (inputs)                                              | result                         |
|---------------------------------------------------------------|--------------------------------|
| `parse_duration` on any UTF-8 string of ≤ 3 bytes             | CBMC out of memory             |
| `parse_duration` on any UTF-8 string of ≤ 2 bytes             | CBMC out of memory             |
| `parse_rfc3339_weak` on the date-time shape, 14 symbolic digits | timeout at 900 s             |
| `parse_rfc3339_weak` on the date-time shape, 4 symbolic digits  | CBMC out of memory (~25 min) |
| `parse_rfc3339_weak` on `2000-02-DDT00:00:00Z`, 2 digits (this pack) | CBMC out of memory      |

So the Kani part of 3b is **ABSTAIN** (no verdict: the verifier did not finish), not PASS and not a found defect.
To try it with more memory: `PILOT_KANI=1 scripts/pilot.sh pilots/humantime 3b` copies this pack in as well;
canaries HK1 (day 00 underflows once the `day == 0` check is gone) and HK2 (vacuous harness) must then fail for
their reasons. Next step if it still does not fit: stub `SystemTime` construction (Kani `#[kani::stub]`).

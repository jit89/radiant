//! Goal g2: computed values. Clean oracle; every expected value is from reference/tier2.rs.
use duration::*;

#[test]
fn total_small() {
    assert_eq!(total_secs(1, 2), 3);
}

#[test]
fn bucket_negative() {
    assert_eq!(bucket(-7, 3), -1);
}

#[test]
fn width_bytes() {
    assert_eq!(label_width("go🚀"), 6);
}

#[test]
fn units_set() {
    let mut u = units();
    u.sort();
    assert_eq!(u, ["d", "h", "m", "ms", "ns", "s", "us", "w"]);
}

#[test]
fn negate_zero() {
    assert_eq!(negate(0.0).to_bits(), (-0.0f64).to_bits());
}

#[test]
fn mean_empty() {
    assert!(mean(&[]).is_nan());
}

#[test]
fn show_one() {
    assert_eq!(show(1.0), "1");
}

#[test]
fn fold_dotted_i() {
    assert_eq!(fold("İ"), "i\u{307}");
}

//! The correct implementation, written for the fixture after the Tier 2 reference.
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Duration {
    pub secs: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParseError {
    Empty,
    BadNumber,
    BadUnit(String),
}

pub trait DurationSource {
    fn get(&self, key: &str) -> Option<String>;
}

pub fn parse_duration(s: &str) -> Result<Duration, ParseError> {
    let s = s.trim();
    if s.is_empty() {
        return Err(ParseError::Empty);
    }
    let split = s.find(|c: char| !c.is_ascii_digit()).unwrap_or(s.len());
    let (num, unit) = s.split_at(split);
    let n: u64 = num.parse().map_err(|_| ParseError::BadNumber)?;
    let mult = match unit {
        "s" | "" => 1,
        "m" => 60,
        "h" => 3600,
        other => return Err(ParseError::BadUnit(other.to_string())),
    };
    Ok(Duration { secs: n * mult })
}

pub async fn load_duration(s: &str) -> Result<Duration, ParseError> {
    parse_duration(s)
}

pub fn duration_from(src: &dyn DurationSource, key: &str) -> Result<Duration, ParseError> {
    parse_duration(&src.get(key).unwrap_or_default())
}

pub fn must_parse(s: &str) -> Duration {
    if s.trim().is_empty() {
        panic!("duration must not be empty");
    }
    parse_duration(s).expect("duration must parse")
}

/// Adds two second counts; overflow is a caller bug (it panics under overflow checks).
pub fn total_secs(a: u32, b: u32) -> u32 {
    a + b
}

/// Remainder with the sign of the dividend (Rust's `%`).
pub fn bucket(offset: i64, n: i64) -> i64 {
    offset % n
}

/// Width of a label in bytes.
pub fn label_width(s: &str) -> usize {
    s.len()
}

/// The unit names, in the map's iteration order.
pub fn units() -> Vec<&'static str> {
    let m: HashMap<&'static str, u64> = [
        ("ns", 0), ("us", 0), ("ms", 0), ("s", 1),
        ("m", 60), ("h", 3600), ("d", 86400), ("w", 604800),
    ]
    .into_iter()
    .collect();
    m.keys().copied().collect()
}

pub fn negate(x: f64) -> f64 {
    -x
}

/// Mean of the values; an empty slice gives NaN (0/0).
pub fn mean(xs: &[f64]) -> f64 {
    xs.iter().sum::<f64>() / xs.len() as f64
}

pub fn show(x: f64) -> String {
    format!("{}", x)
}

pub fn fold(s: &str) -> String {
    s.to_lowercase()
}

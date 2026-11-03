//! The stub: the planned API, every body a trap (Tier 1).
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

pub fn parse_duration(_s: &str) -> Result<Duration, ParseError> {
    panic!("duration-trap")
}

pub async fn load_duration(_s: &str) -> Result<Duration, ParseError> {
    panic!("duration-trap")
}

pub fn duration_from(_src: &dyn DurationSource, _key: &str) -> Result<Duration, ParseError> {
    panic!("duration-trap")
}

pub fn must_parse(_s: &str) -> Duration {
    panic!("duration-trap")
}

pub fn total_secs(_a: u32, _b: u32) -> u32 {
    panic!("duration-trap")
}

pub fn bucket(_offset: i64, _n: i64) -> i64 {
    panic!("duration-trap")
}

pub fn label_width(_s: &str) -> usize {
    panic!("duration-trap")
}

pub fn units() -> Vec<&'static str> {
    panic!("duration-trap")
}

pub fn negate(_x: f64) -> f64 {
    panic!("duration-trap")
}

pub fn mean(_xs: &[f64]) -> f64 {
    panic!("duration-trap")
}

pub fn show(_x: f64) -> String {
    panic!("duration-trap")
}

pub fn fold(_s: &str) -> String {
    panic!("duration-trap")
}

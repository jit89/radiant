//! Tier 2 reference: std only, imports nothing from the fixture. Written before impl/lib.rs.
//! Build: rustc --edition 2024 tier2.rs (no -O: overflow checks on, as in the proof's builds).
use std::collections::HashMap;
use std::hint::black_box;

fn main() {
    let over = std::panic::catch_unwind(|| black_box(3_000_000_000u32) + black_box(2_000_000_000u32));
    println!("total_secs(3e9,2e9) = {}", match over { Ok(v) => v.to_string(), Err(_) => "panic (overflow)".into() });
    println!("total_secs(1,2) = {}", black_box(1u32) + black_box(2u32));
    println!("wrapping 3e9+2e9 = {}", 3_000_000_000u32.wrapping_add(2_000_000_000));
    println!("-7 % 3 = {}", black_box(-7i64) % black_box(3i64));
    println!("(-7).rem_euclid(3) = {}", (-7i64).rem_euclid(3));
    println!("\"go🚀\".len() = {}", "go🚀".len());
    println!("\"go🚀\".chars().count() = {}", "go🚀".chars().count());
    let m: HashMap<&str, u8> = ["ns", "us", "ms", "s", "m", "h", "d", "w"].into_iter().map(|k| (k, 0)).collect();
    println!("hashmap keys = {:?}", m.keys().collect::<Vec<_>>());
    let z = -black_box(0.0f64);
    println!("-(0.0) = {:?}, bits {:#x}, == 0.0: {}", z, z.to_bits(), z == 0.0);
    let e: [f64; 0] = [];
    let mean = e.iter().sum::<f64>() / e.len() as f64;
    println!("mean([]) = {:?}, == NAN: {}, is_nan: {}", mean, mean == f64::NAN, mean.is_nan());
    println!("Display 1.0 = {}, Debug 1.0 = {:?}", 1.0f64, 1.0f64);
    let f = "İ".to_lowercase();
    println!("\"İ\".to_lowercase() = {:?}, chars {:?}", f, f.chars().map(|c| c as u32).collect::<Vec<_>>());
}

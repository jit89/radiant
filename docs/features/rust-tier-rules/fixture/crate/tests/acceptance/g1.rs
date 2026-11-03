//! Goal g1: parsing. Clean oracle.
use duration::*;

fn panic_message(e: Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = e.downcast_ref::<&str>() {
        s.to_string()
    } else if let Some(s) = e.downcast_ref::<String>() {
        s.clone()
    } else {
        String::new()
    }
}

#[test]
fn parses_seconds() {
    assert_eq!(parse_duration("90s"), Ok(Duration { secs: 90 }));
}

#[test]
fn parses_minutes() {
    assert_eq!(parse_duration("2m"), Ok(Duration { secs: 120 }));
}

#[test]
fn rejects_empty() {
    assert_eq!(parse_duration(""), Err(ParseError::Empty));
}

#[tokio::test]
async fn loads() {
    assert_eq!(load_duration("1h").await, Ok(Duration { secs: 3600 }));
}

#[test]
fn reads_source() {
    struct Fixed;
    impl DurationSource for Fixed {
        fn get(&self, _key: &str) -> Option<String> {
            Some("5s".to_string())
        }
    }
    assert_eq!(duration_from(&Fixed, "timeout"), Ok(Duration { secs: 5 }));
}

#[test]
fn must_parse_panics_on_empty() {
    let e = std::panic::catch_unwind(|| must_parse("")).unwrap_err();
    assert_eq!(panic_message(e), "duration must not be empty");
}

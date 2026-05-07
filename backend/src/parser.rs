use chrono::{DateTime, NaiveDateTime, TimeZone, Utc};
use regex::Regex;
use std::sync::OnceLock;

#[derive(Debug, Clone)]
pub struct ParsedMessage {
    pub timestamp: DateTime<Utc>,
    pub sender: String,
    pub body: Option<String>,
    pub media_filename: Option<String>,
}

static ANDROID_RE: OnceLock<Regex> = OnceLock::new();
static IOS_RE: OnceLock<Regex> = OnceLock::new();
static MEDIA_RE: OnceLock<Regex> = OnceLock::new();

fn android_re() -> &'static Regex {
    ANDROID_RE.get_or_init(|| {
        Regex::new(r"^(\d{1,2}/\d{1,2}/\d{2,4}),\s(\d{1,2}:\d{2}(?::\d{2})?\s?[APap][Mm])\s-\s([^:]+):\s(.*)$").unwrap()
    })
}

fn ios_re() -> &'static Regex {
    IOS_RE.get_or_init(|| {
        Regex::new(r"^\[(\d{1,2}/\d{1,2}/\d{2,4}),\s(\d{1,2}:\d{2}:\d{2}\s?[APap][Mm])\]\s([^:]+):\s(.*)$").unwrap()
    })
}

fn media_re() -> &'static Regex {
    MEDIA_RE.get_or_init(|| {
        Regex::new(r"<attached:\s*(.+?)>|(.+\.(jpg|jpeg|png|webp|mp4|mov|ogg|opus|aac|pdf))").unwrap()
    })
}

pub fn parse_chat(content: &str) -> Vec<ParsedMessage> {
    let mut messages = Vec::new();
    let mut current: Option<ParsedMessage> = None;

    for line in content.lines() {
        if let Some(msg) = try_parse_line(line) {
            if let Some(prev) = current.take() {
                messages.push(prev);
            }
            current = Some(msg);
        } else if let Some(ref mut msg) = current {
            // continuation line — append to body
            if let Some(ref mut body) = msg.body {
                body.push('\n');
                body.push_str(line);
            }
        }
    }

    if let Some(msg) = current {
        messages.push(msg);
    }

    messages
}

fn try_parse_line(line: &str) -> Option<ParsedMessage> {
    if let Some(caps) = android_re().captures(line) {
        let dt_str = format!("{} {}", &caps[1], &caps[2]);
        let timestamp = parse_timestamp(&dt_str)?;
        return Some(build_message(timestamp, caps[3].trim(), &caps[4]));
    }

    if let Some(caps) = ios_re().captures(line) {
        let dt_str = format!("{} {}", &caps[1], &caps[2]);
        let timestamp = parse_timestamp(&dt_str)?;
        return Some(build_message(timestamp, caps[3].trim(), &caps[4]));
    }

    None
}

fn build_message(timestamp: DateTime<Utc>, sender: &str, text: &str) -> ParsedMessage {
    let media_filename = media_re().captures(text).map(|c| {
        c.get(1)
            .or_else(|| c.get(2))
            .map(|m| m.as_str().to_string())
            .unwrap_or_default()
    });

    let body = if media_filename.is_some() {
        None
    } else {
        Some(text.to_string())
    };

    ParsedMessage {
        timestamp,
        sender: sender.to_string(),
        body,
        media_filename,
    }
}

fn parse_timestamp(s: &str) -> Option<DateTime<Utc>> {
    let formats = [
        "%m/%d/%Y %I:%M:%S %p",
        "%m/%d/%Y %I:%M %p",
        "%d/%m/%Y %I:%M:%S %p",
        "%d/%m/%Y %I:%M %p",
        "%m/%d/%y %I:%M:%S %p",
        "%m/%d/%y %I:%M %p",
    ];

    let s = s.replace('\u{202f}', " ").replace('\u{a0}', " ");

    for fmt in &formats {
        if let Ok(ndt) = NaiveDateTime::parse_from_str(s.trim(), fmt) {
            return Some(Utc.from_utc_datetime(&ndt));
        }
    }

    None
}

//! toyparse: a small synthetic parser used as the fuzzmuster example subject.
//!
//! A record is `key=value` pairs separated by `;`, for example
//! `name=ada;lang=en`. Keys are ASCII letters and digits; values are any
//! bytes except `;`. A stream is records separated by newlines.

use std::fmt;

/// Maximum number of pairs in one record.
pub const MAX_PAIRS: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    pub pairs: Vec<(String, Vec<u8>)>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Error {
    Empty,
    MissingEquals { at: usize },
    BadKey { at: usize },
    TooManyPairs,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Error::Empty => write!(f, "empty record"),
            Error::MissingEquals { at } => write!(f, "missing '=' in pair at byte {at}"),
            Error::BadKey { at } => write!(f, "invalid key at byte {at}"),
            Error::TooManyPairs => write!(f, "more than {MAX_PAIRS} pairs"),
        }
    }
}

impl std::error::Error for Error {}

/// Parses one record.
pub fn parse_record(input: &[u8]) -> Result<Record, Error> {
    if input.is_empty() {
        return Err(Error::Empty);
    }
    let mut pairs = Vec::new();
    let mut offset = 0;
    for part in input.split(|&b| b == b';') {
        if pairs.len() == MAX_PAIRS {
            return Err(Error::TooManyPairs);
        }
        let eq = part
            .iter()
            .position(|&b| b == b'=')
            .ok_or(Error::MissingEquals { at: offset })?;
        let key = &part[..eq];
        if key.is_empty() || !key.iter().all(|b| b.is_ascii_alphanumeric()) {
            return Err(Error::BadKey { at: offset });
        }
        let key = String::from_utf8(key.to_vec()).map_err(|_| Error::BadKey { at: offset })?;
        pairs.push((key, part[eq + 1..].to_vec()));
        offset += part.len() + 1;
    }
    Ok(Record { pairs })
}

/// Parses newline-separated records; blank lines are skipped.
pub fn parse_stream(input: &[u8]) -> Result<Vec<Record>, Error> {
    input
        .split(|&b| b == b'\n')
        .filter(|line| !line.is_empty())
        .map(parse_record)
        .collect()
}

/// Renders a record back to its text form.
pub fn render_record(record: &Record) -> Vec<u8> {
    let mut out = Vec::new();
    for (i, (key, value)) in record.pairs.iter().enumerate() {
        if i > 0 {
            out.push(b';');
        }
        out.extend_from_slice(key.as_bytes());
        out.push(b'=');
        out.extend_from_slice(value);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let input = b"name=ada;lang=en";
        let record = parse_record(input).unwrap();
        assert_eq!(render_record(&record), input);
    }

    #[test]
    fn rejects_bad_key() {
        assert_eq!(parse_record(b"=x"), Err(Error::BadKey { at: 0 }));
    }
}

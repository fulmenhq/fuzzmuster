#![no_main]

use libfuzzer_sys::fuzz_target;

// A record that parses must render back to bytes that parse to the same record.
fuzz_target!(|data: &[u8]| {
    if let Ok(record) = toyparse::parse_record(data) {
        let rendered = toyparse::render_record(&record);
        assert_eq!(toyparse::parse_record(&rendered), Ok(record));
    }
});

use std::io::{self, Read};

pub const REQUEST_LIMIT: usize = 1_048_576;

// 不完全な文字は最大4バイトだけ保持し、不正な先頭・継続バイトを即座に拒否する。
#[derive(Default)]
struct Utf8Decoder {
    pending: [u8; 4],
    len: usize,
}
impl Utf8Decoder {
    fn push(&mut self, byte: u8) -> io::Result<Option<char>> {
        self.pending[self.len] = byte;
        self.len += 1;
        match std::str::from_utf8(&self.pending[..self.len]) {
            Ok(s) => {
                let ch = s.chars().next().expect("one UTF-8 character");
                self.len = 0;
                Ok(Some(ch))
            }
            Err(e) if e.error_len().is_none() => Ok(None),
            Err(e) => Err(io::Error::new(io::ErrorKind::InvalidData, e)),
        }
    }

    fn finish(&self) -> io::Result<()> {
        if self.len == 0 {
            Ok(())
        } else {
            Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Incomplete UTF-8",
            ))
        }
    }
}
pub struct Line {
    pub text: String,
    pub exceeds_limit: bool,
    pub whitespace: bool,
}
pub struct BoundedInput<R> {
    input: R,
    skip_lf: bool,
}
impl<R: Read> BoundedInput<R> {
    pub fn new(input: R) -> Self {
        Self {
            input,
            skip_lf: false,
        }
    }
    pub fn read_line(&mut self) -> io::Result<Option<Line>> {
        read_line(&mut self.input, &mut self.skip_lf)
    }
}
impl BoundedInput<io::Stdin> {
    // stdinのglobal lockは1行の受付だけで解放し、Backendへ持ち越さない。
    pub fn read_stdin_line(&mut self) -> io::Result<Option<Line>> {
        read_line(&mut self.input.lock(), &mut self.skip_lf)
    }
}
fn read_line(input: &mut impl Read, skip_lf: &mut bool) -> io::Result<Option<Line>> {
    let mut text = String::new();
    let mut decoder = Utf8Decoder::default();
    let mut byte_count: usize = 0;
    let mut units = 0;
    let mut whitespace = true;
    let mut invalid = None;
    loop {
        let mut b = [0];
        if input.read(&mut b)? == 0 {
            if byte_count == 0 {
                return Ok(None);
            }
            break;
        }
        if *skip_lf {
            *skip_lf = false;
            if b[0] == b'\n' {
                continue;
            }
        }
        if matches!(b[0], b'\r' | b'\n') {
            *skip_lf = b[0] == b'\r';
            break;
        }
        byte_count = byte_count.saturating_add(1);
        if invalid.is_none() {
            match decoder.push(b[0]) {
                Ok(Some(ch)) => {
                    whitespace &= ch.is_whitespace();
                    // 超過後も空白だけの行を見分けるが、本文は保持しない。
                    units = (units + ch.len_utf16()).min(REQUEST_LIMIT + 1);
                    if units <= REQUEST_LIMIT {
                        text.push(ch);
                    } else {
                        text.clear();
                    }
                }
                Ok(None) => {}
                Err(e) => invalid = Some(e),
            }
        }
    }
    // 旧来どおり不正UTF-8行は区切りまで消費してエラーにし、極端に長い行は超過扱いにする。
    if byte_count > REQUEST_LIMIT * 4 {
        return Ok(Some(Line {
            text: String::new(),
            exceeds_limit: true,
            whitespace: invalid.is_none() && decoder.len == 0 && whitespace,
        }));
    }
    if let Some(e) = invalid {
        return Err(e);
    }
    decoder.finish()?;
    Ok(Some(Line {
        whitespace,
        text,
        exceeds_limit: units > REQUEST_LIMIT,
    }))
}

pub fn read_to_end(mut input: impl Read) -> io::Result<String> {
    let mut text = String::new();
    let mut decoder = Utf8Decoder::default();
    let mut units = 0;
    // UTF-8の妥当性とUTF-16長を逐次検査し、不正・超過時にEOFを待たない。
    loop {
        let mut b = [0];
        if input.read(&mut b)? == 0 {
            break;
        }
        let starts_character = decoder.len == 0;
        let decoded = decoder.push(b[0])?;
        if starts_character && decoded.is_none() {
            // 先頭バイトでUTF-16長が確定するため、継続バイトも待たず超過を拒否する。
            let char_units = if b[0] >= 0xf0 { 2 } else { 1 };
            if units + char_units > REQUEST_LIMIT {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Hook input exceeds 1 MiB.",
                ));
            }
        }
        if let Some(ch) = decoded {
            units += ch.len_utf16();
            if units > REQUEST_LIMIT {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Hook input exceeds 1 MiB.",
                ));
            }
            text.push(ch);
        }
    }
    decoder.finish()?;
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn line_boundaries_keep_crlf_cr_lf_and_unterminated_final_request() {
        let mut reader = BoundedInput::new(Cursor::new(b"\r\none\r\ntwo\rthree\nfour"));
        for expected in ["", "one", "two", "three", "four"] {
            let line = reader.read_line().unwrap().unwrap();
            assert_eq!(line.text, expected);
            assert!(!line.exceeds_limit);
        }
        assert!(reader.read_line().unwrap().is_none());
    }

    #[test]
    fn utf16_limit_and_bad_utf8_keep_the_next_line_boundary() {
        let exact = "😀".repeat(REQUEST_LIMIT / 2);
        let mut reader = BoundedInput::new(Cursor::new(format!("{exact}\r\n{exact}x\r\nnext")));
        assert_eq!(reader.read_line().unwrap().unwrap().text, exact);
        assert!(reader.read_line().unwrap().unwrap().exceeds_limit);
        assert_eq!(reader.read_line().unwrap().unwrap().text, "next");
        let mut invalid = BoundedInput::new(Cursor::new([0xff, b'\n']));
        assert_eq!(
            invalid.read_line().err().unwrap().kind(),
            io::ErrorKind::InvalidData
        );
        let mut invalid = BoundedInput::new(Cursor::new([0xe3, 0x81, b'\r', b'\n', b'x']));
        assert_eq!(
            invalid.read_line().err().unwrap().kind(),
            io::ErrorKind::InvalidData
        );
        assert_eq!(invalid.read_line().unwrap().unwrap().text, "x");
    }

    #[test]
    fn oversized_unicode_whitespace_is_ignored_and_next_line_survives() {
        let spaces = "\u{3000}".repeat(REQUEST_LIMIT + 1);
        let mut reader = BoundedInput::new(Cursor::new(format!("{spaces}\r\nnext\n")));
        let line = reader.read_line().unwrap().unwrap();
        assert!(line.exceeds_limit);
        assert!(line.whitespace);
        assert!(line.text.is_empty());
        assert_eq!(reader.read_line().unwrap().unwrap().text, "next");

        let mut reader = BoundedInput::new(Cursor::new(format!(
            "{}x\nnext",
            " ".repeat(REQUEST_LIMIT + 1)
        )));
        let line = reader.read_line().unwrap().unwrap();
        assert!(line.exceeds_limit);
        assert!(!line.whitespace);
        assert!(line.text.is_empty());
        assert_eq!(reader.read_line().unwrap().unwrap().text, "next");
    }

    #[test]
    fn oversized_hook_stops_before_waiting_for_eof() {
        struct NoEof(usize);
        impl Read for NoEof {
            fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
                assert!(self.0 > 0, "oversized input requested EOF");
                self.0 -= 1;
                out[0] = b'x';
                Ok(1)
            }
        }
        assert_eq!(
            read_to_end(NoEof(REQUEST_LIMIT + 1)).err().unwrap().kind(),
            io::ErrorKind::InvalidData
        );
        let prefix = Cursor::new(vec![b'x'; REQUEST_LIMIT - 1]);
        struct FourByteStart(bool);
        impl Read for FourByteStart {
            fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
                assert!(!self.0, "oversized input requested a continuation byte");
                self.0 = true;
                out[0] = 0xf0;
                Ok(1)
            }
        }
        assert_eq!(
            read_to_end(prefix.chain(FourByteStart(false)))
                .unwrap_err()
                .kind(),
            io::ErrorKind::InvalidData
        );
        assert_eq!(
            read_to_end(Cursor::new([0xff])).err().unwrap().kind(),
            io::ErrorKind::InvalidData
        );
    }

    #[test]
    fn invalid_hook_utf8_is_rejected_without_waiting_for_eof() {
        struct NoEof(&'static [u8]);
        impl Read for NoEof {
            fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
                assert!(!self.0.is_empty(), "invalid UTF-8 requested EOF");
                out[0] = self.0[0];
                self.0 = &self.0[1..];
                Ok(1)
            }
        }
        for bytes in [&[0x80][..], &[0xe0, 0x80][..], &[0xf4, 0x90][..]] {
            assert_eq!(
                read_to_end(NoEof(bytes)).unwrap_err().kind(),
                io::ErrorKind::InvalidData
            );
        }
        assert_eq!(
            read_to_end(Cursor::new([0xe3, 0x81])).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
        assert_eq!(
            read_to_end(Cursor::new("😀".repeat(REQUEST_LIMIT / 2)))
                .unwrap()
                .encode_utf16()
                .count(),
            REQUEST_LIMIT
        );
    }
}

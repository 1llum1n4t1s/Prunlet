use std::io::{self, Read};

pub const REQUEST_LIMIT: usize = 1_048_576;
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
    let mut bytes = Vec::new();
    let mut count = 0;
    let mut whitespace = true;
    loop {
        let mut b = [0];
        if input.read(&mut b)? == 0 {
            if count == 0 {
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
        count += 1;
        whitespace &= b[0].is_ascii_whitespace();
        if bytes.len() <= REQUEST_LIMIT * 4 {
            bytes.push(b[0]);
        }
    }
    if count > REQUEST_LIMIT * 4 {
        return Ok(Some(Line {
            text: String::new(),
            exceeds_limit: true,
            whitespace,
        }));
    }
    let text =
        String::from_utf8(bytes).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    let exceeds_limit = count > REQUEST_LIMIT * 4 || text.encode_utf16().count() > REQUEST_LIMIT;
    Ok(Some(Line {
        whitespace: whitespace || (!exceeds_limit && text.chars().all(char::is_whitespace)),
        text: if exceeds_limit { String::new() } else { text },
        exceeds_limit,
    }))
}

pub fn read_to_end(mut input: impl Read) -> io::Result<String> {
    let mut bytes = Vec::new();
    let mut units = 0;
    // UTF-8の1文字だけを読み、上限超過後にEOFを待たない。
    loop {
        let mut b = [0];
        if input.read(&mut b)? == 0 {
            break;
        }
        bytes.push(b[0]);
        if b[0] & 0xc0 != 0x80 {
            units += if b[0] >= 0xf0 { 2 } else { 1 };
        }
        if units > REQUEST_LIMIT {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Hook input exceeds 1 MiB.",
            ));
        }
    }
    String::from_utf8(bytes).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
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
        assert_eq!(
            read_to_end(Cursor::new([0xff])).err().unwrap().kind(),
            io::ErrorKind::InvalidData
        );
    }
}

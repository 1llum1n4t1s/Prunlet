use super::*;

pub(super) static REDIRECTION: LazyLock<std::result::Result<Regex, regex::Error>> =
    LazyLock::new(|| Regex::new(r"\A[0-9]*[<>]"));
/// POSIXの代入語。追記代入（`a+=1`）と添字付き代入（`a[0]=1`・`a[$i]+=x`）も含める。
/// 添字に動的な要素があっても代入語であり、実行名ではない（右辺・添字の展開は字句検査で別に調べる）。
pub(super) static ASSIGNMENT: LazyLock<std::result::Result<Regex, regex::Error>> =
    LazyLock::new(|| Regex::new(r"\A[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?\+?="));
pub(super) fn compiled(
    pattern: &'static LazyLock<std::result::Result<Regex, regex::Error>>,
) -> Result<&'static Regex> {
    pattern
        .as_ref()
        .map_err(|error| anyhow::anyhow!(error.to_string()))
}
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(super) enum Mode {
    Cmd,
    PowerShell,
    Posix,
}
#[derive(Clone, Debug)]
pub(super) struct Token {
    pub(super) text: String,
    pub(super) boundary: bool,
    pub(super) quoted: bool,
    pub(super) quote_start: Option<usize>,
    pub(super) backticks: usize,
    pub(super) subexpression: bool,
    pub(super) equality: Option<usize>,
    pub(super) quoted_after_equality: bool,
    pub(super) dynamic: bool,
    /// CMD規則で、引用外かつ`^`で退避されていない`,`の位置（`text`内のbyte offset）。
    /// cmd.exeは`,`を空白相当の区切りとして読むため、`if`の条件を語に割り直すのに使う。
    pub(super) commas: Vec<usize>,
    /// 語に含まれる引用の区間数（`'a'`は1、`'a','b'`や`'a'"b"`は2）。
    pub(super) quote_segments: usize,
    /// 単一引用以外（二重引用・ヒアストリング）を含むか。PowerShellの二重引用は変数展開しうる。
    pub(super) non_single_quote: bool,
    /// 引用外（退避を含む）で語へ加えた文字数。完全な単一引用リテラルかの判定に使う。
    pub(super) bare_chars: usize,
    /// 引用外で退避文字（PowerShellの`` ` ``）を含むか。字句解析後は元の綴りを失うため、静的値として扱わない。
    pub(super) escaped: bool,
    /// POSIX規則で、語の途中に行継続（`\`＋改行）を挟んだか。退避した文字（`escaped`）とは区別し、
    /// リダイレクト演算子・コメントの判定を行継続の無い形と同じにする（bashは行継続を語の分割前に取り除く）。
    pub(super) continued: bool,
    /// POSIX規則で、語が引用外のブレース展開（`r{m,}`・`{a,b}`・`{1..3}`）を含むか。
    /// bashは展開後の最初の語を実行名にするため、実行名の位置では検査不能として扱う。
    pub(super) brace: bool,
    /// 語が引用外・非退避のリダイレクト演算子（`<`・`>`。fd番号の数字が前に付く形を含む）で始まるか。
    /// 退避・引用した`\>`・`">"`・`2">"x`はoptionの値などの通常の語で、リダイレクトとして読み飛ばさない。
    pub(super) redirect: bool,
}
impl Token {
    pub(super) fn new(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            boundary: false,
            quoted: false,
            quote_start: None,
            backticks: 0,
            subexpression: false,
            equality: None,
            quoted_after_equality: false,
            dynamic: false,
            commas: Vec::new(),
            quote_segments: 0,
            non_single_quote: false,
            bare_chars: 0,
            escaped: false,
            continued: false,
            brace: false,
            redirect: false,
        }
    }
    /// 語全体が1つの単一引用だけでできたPowerShellの静的リテラルか（`'...'`、`''`は`'`）。
    /// 二重引用・ヒアストリング・連結（`'a'$x`・`'a','b'`）は値が展開や配列になりうるため含めない。
    pub(super) fn single_quoted_literal(&self) -> bool {
        self.quoted
            && self.quote_start == Some(0)
            && self.quote_segments == 1
            && !self.non_single_quote
            && self.bare_chars == 0
    }
}

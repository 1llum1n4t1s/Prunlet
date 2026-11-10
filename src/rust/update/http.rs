//! Windowsの既定proxyと環境proxyを区別し、転送の同じdeadlineを本文まで維持する。
use crate::platform::windows::wide;
use anyhow::{Context, Result, bail, ensure};
use std::{
    cell::UnsafeCell,
    ffi::c_void,
    io::{self, Read},
    ptr,
    sync::{Arc, mpsc},
    time::Instant,
};
use url::Url;
use windows_sys::Win32::{Foundation::ERROR_IO_PENDING, Networking::WinHttp::*};

pub struct Response {
    pub length: Option<u64>,
    pub body: Box<dyn Read>,
}
#[derive(Clone)]
struct EnvironmentProxy {
    url: Url,
    credentials: Option<ProxyCredentials>,
    // .NET IdnHostと同様、scopeはURI decodeせず接続先だけに保持する。
    raw_scoped_host: Option<String>,
}
#[derive(Clone)]
enum ProxyCredentials {
    Default,
    Explicit { user: String, password: String },
}
struct Environment {
    https: Option<EnvironmentProxy>,
    bypass: Option<String>,
}

// HttpEnvironmentProxy.Windows.csと同じく、HTTP/HTTPSをALLで補完する。
// NO_PROXYだけでは環境proxyを選ばず、HTTPだけの設定でHTTPSをOSproxyへ戻さない。
fn environment_proxies() -> Result<Option<Environment>> {
    environment_proxies_from(
        |name| std::env::var(name).ok(),
        std::env::var_os("GATEWAY_INTERFACE").is_some(),
    )
}

fn environment_proxies_from(
    read: impl Fn(&str) -> Option<String>,
    gateway_present: bool,
) -> Result<Option<Environment>> {
    let parse = |name: &str| -> Result<Option<EnvironmentProxy>> {
        let Some(value) = read(name) else {
            return Ok(None);
        };
        let parsed = parse_environment_proxy(&value);
        // scoped endpointをURL型が拒否しても、設定された経路をOS/directへ差し替えない。
        let authority = value.rsplit('@').next().unwrap_or(&value);
        let scoped = authority
            .split_once('[')
            .is_some_and(|(_, host)| host.split(']').next().unwrap_or(host).contains('%'));
        ensure!(
            !scoped || parsed.is_some(),
            "Scoped proxy endpoint is invalid; configured proxy route was not bypassed"
        );
        Ok(parsed)
    };
    // 対象はHTTPSだけ。専用設定が有効なら未使用のALLを検証しない。
    let https = match parse("HTTPS_PROXY")? {
        Some(proxy) => Some(proxy),
        None => parse("ALL_PROXY")?,
    };
    // HTTPだけの有効設定も環境proxyを選択するが、HTTPS転送には使わない。
    // そのため未使用HTTP設定のscopedエラーも、この要求へ伝播させない。
    let http_active = !gateway_present
        && read("HTTP_PROXY")
            .and_then(|value| parse_environment_proxy(&value))
            .is_some();
    if !http_active && https.is_none() {
        return Ok(None);
    }
    Ok(Some(Environment {
        https,
        bypass: read("NO_PROXY"),
    }))
}

fn parse_environment_proxy(value: &str) -> Option<EnvironmentProxy> {
    if value.is_empty() {
        return None;
    }
    let (scheme, mut value, mut port) = [
        ("http://", "http", 80u16),
        ("https://", "https", 443),
        ("socks4://", "socks4", 80),
        ("socks4a://", "socks4a", 80),
        ("socks5://", "socks5", 80),
    ]
    .into_iter()
    .find_map(|(prefix, scheme, port)| {
        value
            .get(..prefix.len())
            .filter(|v| v.eq_ignore_ascii_case(prefix))
            .map(|_| (scheme, &value[prefix.len()..], port))
    })
    .unwrap_or(("http", value, 80));
    let mut credentials = None;
    if let Some((encoded, host)) = value.rsplit_once('@') {
        let userinfo = unescape_userinfo(encoded);
        if let Some((user, password)) = userinfo.split_once(':') {
            credentials = Some(if user.is_empty() && password.is_empty() {
                ProxyCredentials::Default
            } else {
                ProxyCredentials::Explicit {
                    user: user.into(),
                    password: password.into(),
                }
            });
        } else if !userinfo.is_empty() {
            credentials = Some(ProxyCredentials::Explicit {
                user: userinfo,
                password: String::new(),
            });
        }
        value = host;
    }
    let mut host = value;
    if let Some(colon) = value.rfind(':')
        && value.find(']').is_none_or(|end| colon > end)
    {
        host = &value[..colon];
        let digits = value[colon + 1..]
            .bytes()
            .take_while(u8::is_ascii_digit)
            .count();
        port = value[colon + 1..colon + 1 + digits].parse().ok()?;
    }
    let mut scoped_host = None;
    let mut raw_scoped_host = None;
    if let Some(address) = host.strip_prefix('[').and_then(|h| h.strip_suffix(']'))
        && let Some((address, scope)) = address.split_once('%')
    {
        raw_scoped_host = Some(format!("{address}%{scope}"));
        let address = address.parse::<std::net::Ipv6Addr>().ok()?;
        scoped_host = Some(format!("[{address}]"));
    }
    // URL型がscopeを表せなくても、設定を無効扱いにしてOS経路へ戻さない。
    let host = scoped_host.as_deref().unwrap_or(host);
    let mut url = Url::parse(&format!("{scheme}://{host}:{port}")).ok()?;
    if url.host_str().is_none() {
        return None;
    }
    if scheme.starts_with("socks") {
        // .NETはSOCKSでも省略portを80へ固定する。一般的な1080既定へ戻さない。
        url.set_port(Some(port)).ok()?;
        if scheme == "socks5" {
            url.set_scheme("socks5h").ok()?;
        }
    }
    Some(EnvironmentProxy {
        url,
        credentials,
        raw_scoped_host,
    })
}

fn unescape_userinfo(value: &str) -> String {
    let source = value.as_bytes();
    let mut bytes = Vec::with_capacity(source.len());
    let mut index = 0;
    while index < source.len() {
        let escaped = |index: usize| -> Option<u8> {
            if source.get(index) != Some(&b'%') {
                return None;
            }
            Some(
                ((source.get(index + 1)?.to_owned() as char).to_digit(16)? * 16
                    + (*source.get(index + 2)? as char).to_digit(16)?) as u8,
            )
        };
        if let Some(first) = escaped(index) {
            let count = match first {
                0..=0x7f => 1,
                0xc2..=0xdf => 2,
                0xe0..=0xef => 3,
                0xf0..=0xf4 => 4,
                _ => 0,
            };
            let sequence = (0..count)
                .map(|offset| escaped(index + offset * 3))
                .collect::<Option<Vec<_>>>();
            if let Some(sequence) = sequence.filter(|v| std::str::from_utf8(v).is_ok()) {
                if !sequence.is_empty() {
                    bytes.extend_from_slice(&sequence);
                    index += count * 3;
                    continue;
                }
            }
        }
        bytes.push(source[index]);
        index += 1;
    }
    // 不正escapeだけを残し、有効なUTF-8/ASCII escapeは個別にdecodeする。
    String::from_utf8(bytes).expect("Decoded scalar sequences preserve UTF-8")
}

pub fn get(url: &str, deadline: Instant) -> Result<Response> {
    get_with_redirects(url, deadline, true)
}
fn get_with_redirects(url: &str, deadline: Instant, allow_redirects: bool) -> Result<Response> {
    let target = Url::parse(url)?;
    validate_target(&target)?;
    if let Some(environment) = environment_proxies()? {
        environment_get(
            target,
            deadline,
            environment.https.as_ref(),
            environment.bypass.as_deref(),
            allow_redirects,
        )
    } else {
        // OSが実効userのPAC/WPAD/manual/bypass/failoverを処理する。設定は変更しない。
        let reader = NativeReader::open(url, deadline, allow_redirects)?;
        Ok(Response {
            length: reader.length,
            body: Box::new(reader),
        })
    }
}
fn validate_target(url: &Url) -> Result<()> {
    ensure!(
        url.scheme() == "https" && url.username().is_empty() && url.password().is_none(),
        "Published package URL must use HTTPS without credentials"
    );
    Ok(())
}
struct HopResponse {
    status: u16,
    location: Option<String>,
    length: Option<u64>,
    body: Box<dyn Read>,
}
fn environment_get(
    mut url: Url,
    deadline: Instant,
    proxy: Option<&EnvironmentProxy>,
    bypass: Option<&str>,
    allow_redirects: bool,
) -> Result<Response> {
    for redirects in 0..=50 {
        remaining(deadline)?;
        validate_target(&url)?;
        let selected = proxy.filter(|_| {
            !bypass.is_some_and(|list| bypass_match(url.host_str().unwrap_or(""), list))
        });
        if let Some(raw) = selected.and_then(|proxy| proxy.raw_scoped_host.as_deref()) {
            validate_scoped_host(raw)?;
        }
        let response = if let Some(proxy) = selected.filter(|p| p.url.scheme().starts_with("socks"))
        {
            let credentials = proxy
                .credentials
                .as_ref()
                .map(|credential| match credential {
                    ProxyCredentials::Default => super::socks::SocksCredentials {
                        username: String::new(),
                        password: String::new(),
                    },
                    ProxyCredentials::Explicit { user, password } => {
                        super::socks::SocksCredentials {
                            // .NET NetworkCredentialのdomainはSOCKS USERIDには含まれない。
                            username: user
                                .split_once('\\')
                                .map_or(user.as_str(), |(_, user)| user)
                                .into(),
                            password: password.clone(),
                        }
                    }
                });
            let result = if let Some(raw) = proxy.raw_scoped_host.as_deref() {
                super::socks::get_once_at(
                    &url,
                    &proxy.url,
                    Some(raw),
                    credentials.as_ref(),
                    deadline,
                )
            } else {
                super::socks::get_once(&url, &proxy.url, credentials.as_ref(), deadline)
            }?;
            HopResponse {
                status: result.status,
                location: result.location,
                length: result.length,
                body: result.body,
            }
        } else {
            native_environment_hop(&url, deadline, selected)?
        };
        if (200..300).contains(&response.status) {
            return Ok(Response {
                length: response.length,
                body: response.body,
            });
        }
        let next = next_redirect(
            &url,
            response.status,
            response.location.as_deref(),
            allow_redirects,
            redirects,
        )?;
        // 次のURLでbypassを再評価する前に、旧connection/driverの所有を解放する。
        drop(response.body);
        url = next;
    }
    bail!("Published package redirect limit exceeded")
}
fn require_redirect_permission(allowed: bool) -> Result<()> {
    ensure!(
        allowed,
        "Published distribution redirects are not permitted"
    );
    Ok(())
}
fn next_redirect(
    url: &Url,
    status: u16,
    location: Option<&str>,
    allowed: bool,
    redirects: usize,
) -> Result<Url> {
    ensure!(
        matches!(status, 301 | 302 | 303 | 307 | 308),
        "Published package returned HTTP {status}"
    );
    require_redirect_permission(allowed)?;
    ensure!(redirects < 50, "Published package redirect limit exceeded");
    url.join(location.context("Published package redirect has no Location")?)
        .map_err(Into::into)
}
fn native_redirect_policy(allowed: bool) -> u32 {
    if allowed {
        WINHTTP_OPTION_REDIRECT_POLICY_DISALLOW_HTTPS_TO_HTTP
    } else {
        WINHTTP_OPTION_REDIRECT_POLICY_NEVER
    }
}
fn native_environment_hop(
    url: &Url,
    deadline: Instant,
    proxy: Option<&EnvironmentProxy>,
) -> Result<HopResponse> {
    let route = proxy.map_or(Route::Direct, |proxy| {
        Route::Named(&proxy.url, proxy.raw_scoped_host.as_deref())
    });
    let mut reader = NativeReader::open_route(url.as_str(), deadline, route, false, None)?;
    if reader.status == 407
        && let Some(credentials) = proxy.and_then(|p| p.credentials.as_ref())
        && let Some(scheme) = proxy_auth_scheme(reader.request.0, credentials)?
    {
        drop(reader);
        reader = NativeReader::open_route(
            url.as_str(),
            deadline,
            route,
            false,
            Some((credentials, scheme)),
        )?;
    }
    let location = if matches!(reader.status, 301 | 302 | 303 | 307 | 308) {
        unsafe { text_header(reader.request.0, WINHTTP_QUERY_LOCATION) }?
    } else {
        None
    };
    Ok(HopResponse {
        status: reader
            .status
            .try_into()
            .context("Invalid published package status")?,
        location,
        length: reader.length,
        body: Box::new(reader),
    })
}
// .NETは完全一致と先頭dotのsuffixだけを扱い、wildcard/CIDRを展開しない。
fn bypass_match(host: &str, list: &str) -> bool {
    list.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .any(|entry| {
            if let Some(domain) = entry.strip_prefix('.') {
                host.eq_ignore_ascii_case(domain)
                    || (host.len() > domain.len()
                        && host[host.len() - domain.len()..].eq_ignore_ascii_case(domain)
                        && host.as_bytes()[host.len() - domain.len() - 1] == b'.')
            } else {
                host.eq_ignore_ascii_case(entry)
            }
        })
}
fn proxy_auth_scheme(handle: *mut c_void, credentials: &ProxyCredentials) -> Result<Option<u32>> {
    unsafe {
        let (mut supported, mut first, mut target) = (0, 0, 0);
        if WinHttpQueryAuthSchemes(handle, &mut supported, &mut first, &mut target) != 0 {
            ensure!(
                target == WINHTTP_AUTH_TARGET_PROXY,
                "Authentication challenge is not for the selected proxy"
            );
        } else {
            let error = io::Error::last_os_error();
            // CONNECTの407は通常response状態と異なり4317となるWindowsがある。
            // callerが確認した407だけを扱う。既定資格情報の利用はNTLM/Negotiateへ限定する。
            if error.raw_os_error() != Some(4317) {
                return Err(error.into());
            }
            for index in 0..16 {
                let Some(header) = text_header_at(handle, WINHTTP_QUERY_PROXY_AUTHENTICATE, index)?
                else {
                    break;
                };
                supported |= challenge_parts(&header)
                    .into_iter()
                    .filter_map(|challenge| challenge.split_whitespace().next())
                    .fold(0, |flags, scheme| {
                        flags
                            | if scheme.eq_ignore_ascii_case("Negotiate") {
                                WINHTTP_AUTH_SCHEME_NEGOTIATE
                            } else if scheme.eq_ignore_ascii_case("NTLM") {
                                WINHTTP_AUTH_SCHEME_NTLM
                            } else if scheme.eq_ignore_ascii_case("Digest") {
                                WINHTTP_AUTH_SCHEME_DIGEST
                            } else if scheme.eq_ignore_ascii_case("Basic") {
                                WINHTTP_AUTH_SCHEME_BASIC
                            } else {
                                0
                            }
                    });
            }
        }
        Ok(if supported & WINHTTP_AUTH_SCHEME_NEGOTIATE != 0 {
            Some(WINHTTP_AUTH_SCHEME_NEGOTIATE)
        } else if supported & WINHTTP_AUTH_SCHEME_NTLM != 0 {
            Some(WINHTTP_AUTH_SCHEME_NTLM)
        } else if matches!(credentials, ProxyCredentials::Explicit { .. })
            && supported & WINHTTP_AUTH_SCHEME_DIGEST != 0
        {
            Some(WINHTTP_AUTH_SCHEME_DIGEST)
        } else if matches!(credentials, ProxyCredentials::Explicit { .. })
            && supported & WINHTTP_AUTH_SCHEME_BASIC != 0
        {
            Some(WINHTTP_AUTH_SCHEME_BASIC)
        } else {
            None
        })
    }
}
fn challenge_parts(header: &str) -> Vec<&str> {
    let (mut quoted, mut escaped, mut begin) = (false, false, 0);
    let mut parts = Vec::new();
    for (index, c) in header.char_indices() {
        if escaped {
            escaped = false;
            continue;
        }
        if quoted && c == '\\' {
            escaped = true;
        } else if c == '"' {
            quoted = !quoted;
        } else if c == ',' && !quoted {
            parts.push(&header[begin..index]);
            begin = index + 1;
        }
    }
    parts.push(&header[begin..]);
    parts
}
fn validate_scoped_host(raw: &str) -> Result<()> {
    let (address, scope) = raw
        .split_once('%')
        .context("Scoped proxy requires an IPv6 address and numeric scope")?;
    ensure!(
        !raw.chars().any(char::is_control)
            && !scope.is_empty()
            && scope.bytes().all(|c| c.is_ascii_digit())
            && scope.parse::<u32>().is_ok()
            && address.parse::<std::net::Ipv6Addr>().is_ok(),
        "Scoped proxy endpoint is invalid; configured proxy route was not bypassed"
    );
    Ok(())
}
fn native_proxy_host(proxy: &Url, scoped: Option<&str>) -> Result<String> {
    if let Some(raw) = scoped {
        validate_scoped_host(raw)?;
        return Ok(raw.into());
    }
    Ok(proxy
        .host_str()
        .context("Environment proxy has no host")?
        .trim_matches(['[', ']'])
        .into())
}
fn remaining(deadline: Instant) -> io::Result<std::time::Duration> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|d| !d.is_zero())
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::TimedOut,
                "Published package network deadline expired",
            )
        })
}
struct Internet(*mut c_void);
impl Internet {
    fn new(value: *mut c_void) -> io::Result<Self> {
        if value.is_null() {
            Err(io::Error::last_os_error())
        } else {
            Ok(Self(value))
        }
    }
}
impl Drop for Internet {
    fn drop(&mut self) {
        unsafe {
            WinHttpCloseHandle(self.0);
        }
    }
}
enum Event {
    Sent,
    Headers,
    Data(Vec<u8>),
    Error(u32),
    Closed,
}
struct ContextState {
    sender: mpsc::Sender<Event>,
    buffer: UnsafeCell<Box<[u8; 131072]>>,
    _proxy_name: Option<Vec<u16>>,
}
#[cfg(test)]
static LIVE_CONTEXTS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
#[cfg(test)]
impl Drop for ContextState {
    fn drop(&mut self) {
        LIVE_CONTEXTS.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
    }
}
// 同じrequestには一度に一つだけReadDataを発行する。bufferを読むのは
// READ_COMPLETEだけで、次のReadData前にcallbackが所有Vecへコピー済みとなる。
unsafe impl Send for ContextState {}
unsafe impl Sync for ContextState {}
unsafe extern "system" fn callback(
    _handle: *mut c_void,
    context: usize,
    status: u32,
    information: *mut c_void,
    length: u32,
) {
    if context == 0 {
        return;
    }
    // HANDLE_CLOSINGより前に開始したcallback同士も、各々のArcを保持する。
    unsafe {
        Arc::increment_strong_count(context as *const ContextState);
    }
    let state = unsafe { Arc::from_raw(context as *const ContextState) };
    let event = match status {
        WINHTTP_CALLBACK_STATUS_SENDREQUEST_COMPLETE => Some(Event::Sent),
        WINHTTP_CALLBACK_STATUS_HEADERS_AVAILABLE => Some(Event::Headers),
        WINHTTP_CALLBACK_STATUS_READ_COMPLETE => {
            if length > 131072 || (length != 0 && information.is_null()) {
                Some(Event::Error(13))
            } else {
                let bytes = if length == 0 {
                    Vec::new()
                } else {
                    unsafe { std::slice::from_raw_parts(information.cast::<u8>(), length as usize) }
                        .to_vec()
                };
                Some(Event::Data(bytes))
            }
        }
        WINHTTP_CALLBACK_STATUS_REQUEST_ERROR => {
            if information.is_null()
                || length < (std::mem::size_of::<WINHTTP_ASYNC_RESULT>() as u32)
            {
                Some(Event::Error(13))
            } else {
                Some(Event::Error(unsafe {
                    (*information.cast::<WINHTTP_ASYNC_RESULT>()).dwError
                }))
            }
        }
        WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING => Some(Event::Closed),
        _ => None,
    };
    if let Some(event) = event {
        let _ = state.sender.send(event);
    }
    if status == WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING {
        // nativeに渡した一つのArcは最後のHANDLE_CLOSING callbackでのみ返す。
        // deadline/errorで呼出側が先に戻ってもcontextとnative bufferを解放しない。
        unsafe {
            drop(Arc::from_raw(context as *const ContextState));
        }
    }
}
struct NativeReader {
    // drop順序: request closeを先に発行し、その後に親handleを解放する。
    request: Internet,
    _connection: Internet,
    _session: Internet,
    state: Arc<ContextState>,
    receiver: mpsc::Receiver<Event>,
    deadline: Instant,
    length: Option<u64>,
    pending: Vec<u8>,
    offset: usize,
    eof: bool,
    status: u64,
}
#[derive(Clone, Copy)]
enum Route<'a> {
    System,
    Named(&'a Url, Option<&'a str>),
    Direct,
}
impl NativeReader {
    fn open(url: &str, deadline: Instant, allow_redirects: bool) -> Result<Self> {
        let reader = Self::open_route(url, deadline, Route::System, allow_redirects, None)?;
        ensure!(
            (200..300).contains(&reader.status),
            "Published package returned HTTP {}",
            reader.status
        );
        Ok(reader)
    }
    fn open_route(
        url: &str,
        deadline: Instant,
        route: Route<'_>,
        redirect: bool,
        default_proxy_credentials: Option<(&ProxyCredentials, u32)>,
    ) -> Result<Self> {
        unsafe {
            remaining(deadline)?;
            let use_default_credentials = default_proxy_credentials
                .as_ref()
                .is_some_and(|(credentials, _)| matches!(credentials, ProxyCredentials::Default));
            let url = Url::parse(url)?;
            ensure!(
                url.scheme() == "https" && url.username().is_empty() && url.password().is_none(),
                "Published package URL must use HTTPS without credentials"
            );
            let agent = wide(std::ffi::OsStr::new("Prunlet-Published-Updater"))?;
            let proxy_host = match route {
                Route::Named(proxy, scoped) => Some(native_proxy_host(proxy, scoped)?),
                _ => None,
            };
            let proxy_name = proxy_host
                .as_ref()
                .map(|host| {
                    wide(std::ffi::OsStr::new(&if host.contains(':') {
                        format!("[{host}]")
                    } else {
                        host.clone()
                    }))
                })
                .transpose()?;
            let access = match route {
                Route::System => WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                Route::Named(..) => WINHTTP_ACCESS_TYPE_NAMED_PROXY,
                Route::Direct => WINHTTP_ACCESS_TYPE_NO_PROXY,
            };
            let session_proxy = match route {
                Route::Named(proxy, _) => Some(wide(std::ffi::OsStr::new(&format!(
                    "{}:{}",
                    proxy_host
                        .as_ref()
                        .map(|host| if host.contains(':') {
                            format!("[{host}]")
                        } else {
                            host.clone()
                        })
                        .context("Missing proxy host")?,
                    proxy
                        .port_or_known_default()
                        .context("Missing proxy port")?
                )))?),
                _ => None,
            };
            let session = Internet::new(WinHttpOpen(
                agent.as_ptr(),
                access,
                session_proxy
                    .as_ref()
                    .map_or(ptr::null(), |name| name.as_ptr()),
                ptr::null(),
                if default_proxy_credentials.is_some() {
                    WINHTTP_FLAG_ASYNC
                } else {
                    WINHTTP_FLAG_SECURE_DEFAULTS
                },
            ))?;
            if default_proxy_credentials.is_some() {
                // SECURE_DEFAULTSがproxy認証を抑止するWinHTTPでは、同じTLS下限と
                // fallback禁止を明示する。証明書検証や信頼storeは変更しない。
                option(
                    session.0,
                    WINHTTP_OPTION_SECURE_PROTOCOLS,
                    WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2 | WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3,
                )?;
                option(
                    session.0,
                    WINHTTP_OPTION_DISABLE_SECURE_PROTOCOL_FALLBACK,
                    1,
                )?;
            }
            // これは個別I/Oの補助timeout。単一deadlineは全completionの待機と本文で別途確認する。
            ensure!(
                WinHttpSetTimeouts(session.0, 120000, 120000, 120000, 120000) != 0,
                "Cannot set published package I/O timeouts: {}",
                io::Error::last_os_error()
            );
            let host = wide(std::ffi::OsStr::new(
                url.host_str().context("Missing HTTPS host")?,
            ))?;
            let connection = Internet::new(WinHttpConnect(
                session.0,
                host.as_ptr(),
                url.port_or_known_default().context("Missing HTTPS port")?,
                0,
            ))?;
            let verb = wide(std::ffi::OsStr::new("GET"))?;
            let path = if let Some(query) = url.query() {
                format!("{}?{query}", url.path())
            } else {
                url.path().into()
            };
            let path = wide(std::ffi::OsStr::new(&path))?;
            let request = Internet::new(WinHttpOpenRequest(
                connection.0,
                verb.as_ptr(),
                path.as_ptr(),
                ptr::null(),
                ptr::null(),
                ptr::null(),
                WINHTTP_FLAG_SECURE,
            ))?;
            if let Route::Named(proxy, _) = route
                && proxy.scheme() == "https"
            {
                let entry = WINHTTP_PROXY_RESULT_ENTRY {
                    fProxy: 1,
                    fBypass: 0,
                    ProxyScheme: match proxy.scheme() {
                        "http" => WINHTTP_INTERNET_SCHEME_HTTP,
                        "https" => WINHTTP_INTERNET_SCHEME_HTTPS,
                        _ => bail!("Unsupported native proxy scheme"),
                    },
                    pwszProxy: proxy_name.as_ref().context("Missing proxy host")?.as_ptr()
                        as *mut u16,
                    ProxyPort: proxy
                        .port_or_known_default()
                        .context("Environment proxy has no port")?,
                };
                start(WinHttpSetOption(
                    request.0,
                    WINHTTP_OPTION_PROXY_RESULT_ENTRY,
                    (&entry as *const WINHTTP_PROXY_RESULT_ENTRY).cast(),
                    std::mem::size_of::<WINHTTP_PROXY_RESULT_ENTRY>() as u32,
                ))?;
            }
            option(
                request.0,
                WINHTTP_OPTION_AUTOLOGON_POLICY,
                if use_default_credentials {
                    WINHTTP_AUTOLOGON_SECURITY_LEVEL_PROXY_ONLY
                } else {
                    WINHTTP_AUTOLOGON_SECURITY_LEVEL_HIGH
                },
            )?;
            if let Some((credentials, scheme)) = default_proxy_credentials {
                ensure!(
                    matches!(route, Route::Named(..))
                        && (matches!(
                            scheme,
                            WINHTTP_AUTH_SCHEME_NEGOTIATE | WINHTTP_AUTH_SCHEME_NTLM
                        ) || matches!(credentials, ProxyCredentials::Explicit { .. })
                            && matches!(
                                scheme,
                                WINHTTP_AUTH_SCHEME_DIGEST | WINHTTP_AUTH_SCHEME_BASIC
                            )),
                    "Invalid explicit proxy authentication request"
                );
            }
            option(
                request.0,
                WINHTTP_OPTION_REDIRECT_POLICY,
                native_redirect_policy(redirect),
            )?;
            option(request.0, WINHTTP_OPTION_MAX_HTTP_AUTOMATIC_REDIRECTS, 50)?;
            let (sender, receiver) = mpsc::channel();
            let state = Arc::new(ContextState {
                sender,
                buffer: UnsafeCell::new(Box::new([0; 131072])),
                _proxy_name: proxy_name,
            });
            #[cfg(test)]
            LIVE_CONTEXTS.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let raw = Arc::into_raw(state.clone()) as usize;
            if WinHttpSetOption(
                request.0,
                WINHTTP_OPTION_CONTEXT_VALUE,
                (&raw as *const usize).cast(),
                std::mem::size_of::<usize>() as u32,
            ) == 0
            {
                let error = io::Error::last_os_error();
                drop(Arc::from_raw(raw as *const ContextState));
                return Err(error.into());
            }
            let flags = WINHTTP_CALLBACK_FLAG_SENDREQUEST_COMPLETE
                | WINHTTP_CALLBACK_FLAG_HEADERS_AVAILABLE
                | WINHTTP_CALLBACK_FLAG_READ_COMPLETE
                | WINHTTP_CALLBACK_FLAG_REQUEST_ERROR
                | WINHTTP_CALLBACK_STATUS_HANDLE_CLOSING;
            let previous = WinHttpSetStatusCallback(request.0, Some(callback), flags, 0);
            if previous.is_some_and(|p| p as usize == usize::MAX) {
                let error = io::Error::last_os_error();
                drop(Arc::from_raw(raw as *const ContextState));
                return Err(error.into());
            }
            let mut reader = Self {
                request,
                _connection: connection,
                _session: session,
                state,
                receiver,
                deadline,
                length: None,
                pending: Vec::new(),
                offset: 0,
                eof: false,
                status: 0,
            };
            let headers = wide(std::ffi::OsStr::new(
                "Accept: application/octet-stream\r\nX-GitHub-Api-Version: 2022-11-28\r\n",
            ))?;
            let mut credentials_applied = false;
            let mut completed = false;
            for _ in 0..16 {
                let exchange = (|| -> Result<()> {
                    remaining(deadline)?;
                    start(WinHttpSendRequest(
                        reader.request.0,
                        headers.as_ptr(),
                        (headers.len() - 1) as u32,
                        ptr::null(),
                        0,
                        0,
                        raw,
                    ))?;
                    match reader.wait()? {
                        Event::Sent => {}
                        _ => bail!("Unexpected published package send completion"),
                    }
                    remaining(deadline)?;
                    start(WinHttpReceiveResponse(reader.request.0, ptr::null_mut()))?;
                    match reader.wait()? {
                        Event::Headers => {}
                        _ => bail!("Unexpected published package header completion"),
                    }
                    Ok(())
                })();
                if let Err(error) = exchange {
                    // WinHTTPの認証transaction再送指示だけを、同じrequest/deadlineで扱う。
                    // 資格情報と認証先は既知proxyのままで、serverへ切り替えない。
                    if default_proxy_credentials.is_some()
                        && error
                            .chain()
                            .filter_map(|e| e.downcast_ref::<io::Error>())
                            .any(|e| e.raw_os_error() == Some(ERROR_WINHTTP_RESEND_REQUEST as i32))
                    {
                        continue;
                    }
                    return Err(error);
                }
                let status = number_header(reader.request.0, WINHTTP_QUERY_STATUS_CODE)?
                    .context("HTTP response has no status")?;
                reader.status = status;
                reader.length = number_header(reader.request.0, WINHTTP_QUERY_CONTENT_LENGTH)?;
                remaining(deadline)?;
                if !credentials_applied
                    && status == 407
                    && let Some((credentials, scheme)) = default_proxy_credentials
                    && proxy_auth_scheme(reader.request.0, credentials)? == Some(scheme)
                {
                    // autologon方針は最初から固定し、確認済み407の同requestへだけ設定する。
                    // HTTPS CONNECTの認証controlresponseはWinHTTPが処理し、origin bodyは未開始。
                    // ここへReadDataを適用して未知の失敗を無視するfallbackは設けない。
                    reader.eof = false;
                    reader.pending.clear();
                    reader.offset = 0;
                    let (user, password) = match credentials {
                        ProxyCredentials::Default => (None, None),
                        ProxyCredentials::Explicit { user, password } => (
                            Some(wide(std::ffi::OsStr::new(user))?),
                            Some(wide(std::ffi::OsStr::new(password))?),
                        ),
                    };
                    start(WinHttpSetCredentials(
                        reader.request.0,
                        WINHTTP_AUTH_TARGET_PROXY,
                        scheme,
                        user.as_ref().map_or(ptr::null(), |v| v.as_ptr()),
                        password.as_ref().map_or(ptr::null(), |v| v.as_ptr()),
                        ptr::null_mut(),
                    ))?;
                    credentials_applied = true;
                    continue;
                }
                completed = true;
                break;
            }
            ensure!(completed, "Proxy authentication transaction limit exceeded");
            Ok(reader)
        }
    }
    fn wait(&self) -> io::Result<Event> {
        match self.receiver.recv_timeout(remaining(self.deadline)?) {
            Ok(Event::Error(code)) => Err(io::Error::from_raw_os_error(code as i32)),
            Ok(Event::Closed) => Err(io::Error::new(
                io::ErrorKind::ConnectionAborted,
                "Published package native request closed",
            )),
            Ok(event) => {
                remaining(self.deadline)?;
                Ok(event)
            }
            Err(mpsc::RecvTimeoutError::Timeout) => Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "Published package network deadline expired",
            )),
            Err(mpsc::RecvTimeoutError::Disconnected) => Err(io::Error::new(
                io::ErrorKind::ConnectionAborted,
                "Published package callback channel closed",
            )),
        }
    }
}
impl Read for NativeReader {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        remaining(self.deadline)?;
        if self.offset == self.pending.len() {
            if self.eof {
                return Ok(0);
            }
            let native = unsafe { (*self.state.buffer.get()).as_mut_ptr() };
            start(unsafe {
                WinHttpReadData(self.request.0, native.cast(), 131072, ptr::null_mut())
            })?;
            match self.wait()? {
                Event::Data(bytes) => {
                    self.eof = bytes.is_empty();
                    self.pending = bytes;
                    self.offset = 0;
                }
                _ => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "Unexpected published package read completion",
                    ));
                }
            }
        }
        let count = buffer.len().min(self.pending.len() - self.offset);
        buffer[..count].copy_from_slice(&self.pending[self.offset..self.offset + count]);
        self.offset += count;
        remaining(self.deadline)?;
        Ok(count)
    }
}
fn start(result: i32) -> io::Result<()> {
    if result != 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(ERROR_IO_PENDING as i32) {
        Ok(())
    } else {
        Err(error)
    }
}
unsafe fn option(handle: *mut c_void, name: u32, value: u32) -> io::Result<()> {
    start(unsafe { WinHttpSetOption(handle, name, (&value as *const u32).cast(), 4) })
}
unsafe fn number_header(handle: *mut c_void, query: u32) -> io::Result<Option<u64>> {
    unsafe {
        let mut value = 0u32;
        let mut length = 4;
        let result = WinHttpQueryHeaders(
            handle,
            query | WINHTTP_QUERY_FLAG_NUMBER,
            ptr::null(),
            (&mut value as *mut u32).cast(),
            &mut length,
            ptr::null_mut(),
        );
        if result != 0 {
            return Ok(Some(value as u64));
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(ERROR_WINHTTP_HEADER_NOT_FOUND as i32) {
            Ok(None)
        } else {
            Err(error)
        }
    }
}
unsafe fn text_header(handle: *mut c_void, query: u32) -> io::Result<Option<String>> {
    unsafe { text_header_at(handle, query, 0) }
}
unsafe fn text_header_at(
    handle: *mut c_void,
    query: u32,
    index: u32,
) -> io::Result<Option<String>> {
    unsafe {
        let mut length = 0;
        let mut current = index;
        WinHttpQueryHeaders(
            handle,
            query,
            ptr::null(),
            ptr::null_mut(),
            &mut length,
            &mut current,
        );
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(ERROR_WINHTTP_HEADER_NOT_FOUND as i32) {
            return Ok(None);
        }
        if error.raw_os_error() != Some(122) || length == 0 || length > 65536 || length % 2 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Invalid published package response header length",
            ));
        }
        let mut buffer = vec![0u16; (length / 2) as usize];
        current = index;
        start(WinHttpQueryHeaders(
            handle,
            query,
            ptr::null(),
            buffer.as_mut_ptr().cast(),
            &mut length,
            &mut current,
        ))?;
        let length = buffer.iter().position(|c| *c == 0).unwrap_or(buffer.len());
        String::from_utf16(&buffer[..length])
            .map(Some)
            .map_err(|_| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Invalid published package response header",
                )
            })
    }
}

#[cfg(test)]
mod transport_tests {
    use super::*;
    use std::{io::Write, net::TcpListener, thread, time::Duration};
    static TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    #[test]
    fn r2_redirect_policy_stops_same_origin_and_cross_origin_before_another_hop() {
        let url = Url::parse("https://prunlet.kagayoi.com/releases/package.zip").unwrap();
        for status in [301, 302, 303, 307, 308] {
            for location in [
                "/same-host.zip",
                "https://api.github.com/package",
                "https://elsewhere.invalid/package",
            ] {
                assert!(next_redirect(&url, status, Some(location), false, 0).is_err());
                assert!(next_redirect(&url, status, Some(location), true, 0).is_ok());
            }
        }
        assert_eq!(
            native_redirect_policy(false),
            WINHTTP_OPTION_REDIRECT_POLICY_NEVER
        );
        assert_eq!(
            native_redirect_policy(true),
            WINHTTP_OPTION_REDIRECT_POLICY_DISALLOW_HTTPS_TO_HTTP
        );
    }
    #[test]
    fn environment_proxy_selection_only_rejects_selected_scoped_settings() {
        let select = |entries: &[(&str, &str)]| {
            environment_proxies_from(
                |name| {
                    entries
                        .iter()
                        .find(|(key, _)| *key == name)
                        .map(|(_, value)| (*value).into())
                },
                entries.iter().any(|(name, _)| *name == "GATEWAY_INTERFACE"),
            )
        };
        let invalid = "http://[::1%1]:notaport";
        assert!(
            select(&[("HTTP_PROXY", "http://[not-ip%1]:8080")])
                .unwrap()
                .is_none()
        );
        assert!(select(&[("HTTPS_PROXY", "http://[not-ip%1]:8080")]).is_err());
        assert!(validate_scoped_host("not-ip%1").is_err());
        assert!(
            select(&[("HTTP_PROXY", "http://[::1%named-scope]:8080")])
                .unwrap()
                .unwrap()
                .https
                .is_none()
        );
        for unused in ["ALL_PROXY", "HTTP_PROXY"] {
            let selected = select(&[("HTTPS_PROXY", "http://127.0.0.1:1234"), (unused, invalid)])
                .unwrap()
                .unwrap();
            assert_eq!(selected.https.unwrap().url.port(), Some(1234));
        }
        assert!(select(&[("ALL_PROXY", invalid)]).is_err());
        assert!(
            select(&[
                ("HTTPS_PROXY", invalid),
                ("ALL_PROXY", "http://127.0.0.1:1234")
            ])
            .is_err()
        );
        let http_only = select(&[("HTTP_PROXY", "http://127.0.0.1:1234")])
            .unwrap()
            .unwrap();
        assert!(http_only.https.is_none());
        assert!(
            select(&[
                ("HTTP_PROXY", "http://127.0.0.1:1234"),
                ("GATEWAY_INTERFACE", "CGI/1.1")
            ])
            .unwrap()
            .is_none()
        );
        assert_eq!(
            select(&[("ALL_PROXY", "http://127.0.0.1:4567")])
                .unwrap()
                .unwrap()
                .https
                .unwrap()
                .url
                .port(),
            Some(4567)
        );
    }
    #[test]
    fn non_unicode_gateway_presence_disables_http_environment_proxy() {
        if std::env::var_os("PRUNLET_NONUNICODE_CGI_CHILD").is_some() {
            assert!(std::env::var_os("GATEWAY_INTERFACE").is_some());
            assert!(std::env::var("GATEWAY_INTERFACE").is_err());
            assert!(environment_proxies().unwrap().is_none());
            return;
        }
        use std::os::windows::ffi::OsStringExt;
        let mut child = std::process::Command::new(std::env::current_exe().unwrap());
        child.args(["--exact", "update::http::transport_tests::non_unicode_gateway_presence_disables_http_environment_proxy"]);
        for name in [
            "HTTP_PROXY",
            "HTTPS_PROXY",
            "ALL_PROXY",
            "NO_PROXY",
            "GATEWAY_INTERFACE",
        ] {
            child.env_remove(name);
        }
        let result = child
            .env("HTTP_PROXY", "http://127.0.0.1:1234")
            .env(
                "GATEWAY_INTERFACE",
                std::ffi::OsString::from_wide(&[0xD800]),
            )
            .env("PRUNLET_NONUNICODE_CGI_CHILD", "1")
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "Non-Unicode CGI child check failed"
        );
    }
    #[test]
    fn scoped_proxy_endpoint_reaches_each_transport() {
        let _guard = TEST_LOCK.lock().unwrap();
        let raw = std::env::var("PRUNLET_SCOPE_FIXTURE_HOST").unwrap_or_else(|_| "::1%0".into());
        validate_scoped_host(&raw).unwrap();
        let (address, scope) = raw.split_once('%').unwrap();
        let endpoint =
            std::net::SocketAddrV6::new(address.parse().unwrap(), 0, 0, scope.parse().unwrap());
        for scheme in ["http", "https", "socks4", "socks4a", "socks5"] {
            let listener = TcpListener::bind(endpoint).unwrap();
            let port = listener.local_addr().unwrap().port();
            listener.set_nonblocking(true).unwrap();
            let server = thread::spawn(move || {
                let until = Instant::now() + Duration::from_secs(4);
                loop {
                    match listener.accept() {
                        Ok((mut stream, _)) => {
                            stream.set_nonblocking(false).unwrap();
                            stream
                                .set_read_timeout(Some(Duration::from_secs(2)))
                                .unwrap();
                            let mut bytes = [0u8; 4096];
                            let n = stream.read(&mut bytes).unwrap();
                            assert!(n > 0);
                            match scheme {
                                "http" => {
                                    assert!(bytes[..n].starts_with(b"CONNECT example.invalid:443 "))
                                }
                                "https" => assert!(n >= 3 && bytes[0] == 22 && bytes[1] == 3),
                                "socks4" | "socks4a" => assert_eq!(bytes[0], 4),
                                "socks5" => assert_eq!(bytes[0], 5),
                                _ => unreachable!(),
                            }
                            return;
                        }
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                            assert!(
                                Instant::now() < until,
                                "Scoped proxy was not contacted for {scheme}"
                            );
                            thread::sleep(Duration::from_millis(10));
                        }
                        Err(error) => panic!("Scoped fixture accept failed: {error}"),
                    }
                }
            });
            let proxy = parse_environment_proxy(&format!("{scheme}://[{raw}]:{port}")).unwrap();
            // proxyは最初のwireだけを観測して閉じる。通信成功やTLS信頼の代用にしない。
            let result = environment_get(
                Url::parse(if scheme == "socks4" {
                    "https://127.0.0.1/"
                } else {
                    "https://example.invalid/"
                })
                .unwrap(),
                Instant::now() + Duration::from_secs(2),
                Some(&proxy),
                None,
                true,
            );
            assert!(result.is_err());
            if let Err(error) = result {
                eprintln!("Scoped {scheme} fixture result: {error:#}");
            }
            server.join().unwrap();
        }
    }
    #[test]
    fn environment_proxy_parser_and_bypass_match_dotnet_contract() {
        assert_eq!(
            parse_environment_proxy("http://[::1%1]:8080")
                .unwrap()
                .raw_scoped_host
                .as_deref(),
            Some("::1%1")
        );
        assert_eq!(
            parse_environment_proxy("http://[fe80::1%253]:8080")
                .unwrap()
                .raw_scoped_host
                .as_deref(),
            Some("fe80::1%253")
        );
        let scoped = parse_environment_proxy("http://[::1%invalid]:8080").unwrap();
        assert!(
            environment_get(
                Url::parse("https://github.com/").unwrap(),
                Instant::now() + Duration::from_secs(1),
                Some(&scoped),
                None,
                true
            )
            .err()
            .expect("Scoped proxy must not fall back")
            .to_string()
            .contains("configured proxy route was not bypassed")
        );
        for value in ["http://:@proxy", "http://%3A@proxy", "http://%3a@proxy"] {
            assert!(matches!(
                parse_environment_proxy(value).unwrap().credentials,
                Some(ProxyCredentials::Default)
            ));
        }
        assert!(
            parse_environment_proxy("http://@proxy")
                .unwrap()
                .credentials
                .is_none()
        );
        assert_eq!(unescape_userinfo("a%FF%3Ab"), "a%FF:b");
        assert_eq!(unescape_userinfo("%E6%97%A5%3Avalue"), "日:value");
        let parsed = parse_environment_proxy("http://fixture%3Avalue@proxy").unwrap();
        assert!(
            matches!(parsed.credentials, Some(ProxyCredentials::Explicit { ref user, ref password }) if user == "fixture" && password == "value")
        );
        let socks = parse_environment_proxy("socks5://proxy").unwrap();
        assert_eq!(socks.url.scheme(), "socks5h");
        assert_eq!(socks.url.port(), Some(80));
        assert!(bypass_match("github.com", " github.com "));
        assert!(!bypass_match("api.github.com", "github.com"));
        assert!(bypass_match("github.com", ".github.com"));
        assert!(bypass_match("api.github.com", ".github.com"));
        assert!(!bypass_match("evilgithub.com", ".github.com"));
        assert!(!bypass_match("github.com", "*"));
        assert!(!bypass_match("127.0.0.1", "127.0.0.0/8"));
        assert!(bypass_match("127.0.0.1", "127.0.0.1"));
        assert_eq!(
            challenge_parts("Digest realm=\"a, NTLM , b\", Basic realm=\"fixture\"").len(),
            2
        );
    }
    fn read_proxy_prefix(
        mut read: impl FnMut(&mut [u8], Duration) -> io::Result<usize>,
        secure: bool,
        until: Instant,
    ) -> io::Result<Vec<u8>> {
        let mut bytes = vec![0; if secure { 3 } else { b"CONNECT ".len() }];
        let mut offset = 0;
        while offset < bytes.len() {
            let remaining = until
                .checked_duration_since(Instant::now())
                .filter(|duration| !duration.is_zero())
                .ok_or_else(|| io::Error::new(io::ErrorKind::TimedOut, "Proxy prefix deadline"))?;
            let result = read(&mut bytes[offset..], remaining);
            eprintln!(
                "Proxy observation secure={secure}: offset={offset}, read={result:?}, prefix={:02x?}",
                &bytes[..offset + result.as_ref().copied().unwrap_or(0)]
            );
            match result {
                Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
                Ok(count) => offset += count,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
            if Instant::now() >= until {
                return Err(io::ErrorKind::TimedOut.into());
            }
        }
        Ok(bytes)
    }
    fn proxy_prefix_matches(bytes: &[u8], secure: bool) -> bool {
        if secure {
            bytes.len() >= 3 && bytes[0] == 22 && bytes[1] == 3
        } else {
            bytes.starts_with(b"CONNECT ")
        }
    }
    #[test]
    fn proxy_prefix_handles_split_frames_without_accepting_plaintext_or_empty_connections() {
        for (secure, input, accepted) in [
            (false, b"CONNECT ".as_slice(), true),
            (true, b"\x16\x03\x03".as_slice(), true),
            (true, b"CONNECT ".as_slice(), false),
        ] {
            let mut input = input;
            let bytes = read_proxy_prefix(
                |buffer, _| input.read(&mut buffer[..1]),
                secure,
                Instant::now() + Duration::from_secs(2),
            )
            .unwrap();
            assert_eq!(proxy_prefix_matches(&bytes, secure), accepted);
        }
        let error = read_proxy_prefix(|_, _| Ok(0), true, Instant::now() + Duration::from_secs(2))
            .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::UnexpectedEof);
        let error = read_proxy_prefix(
            |_, _| panic!("Expired read must not start"),
            true,
            Instant::now(),
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
    }
    fn observe_proxy(secure: bool) -> (Vec<u8>, String) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        listener.set_nonblocking(true).unwrap();
        let worker = thread::spawn(move || {
            let until = Instant::now() + Duration::from_secs(3);
            loop {
                match listener.accept() {
                    Ok((mut stream, peer)) => {
                        eprintln!("Proxy observation secure={secure}: accepted {peer}");
                        // Windowsではacceptしたsocketがlistenerの非blocking設定を引き継ぐ。
                        // 読取期限を適用できるblocking modeに戻してから接頭部を待つ。
                        stream.set_nonblocking(false).unwrap();
                        return read_proxy_prefix(
                            |buffer, remaining| {
                                stream.set_read_timeout(Some(remaining))?;
                                stream.read(buffer)
                            },
                            secure,
                            Instant::now() + Duration::from_secs(2),
                        )
                        .unwrap_or_else(|error| {
                            eprintln!("Proxy observation secure={secure}: read ended {error}");
                            Vec::new()
                        });
                    }
                    Err(error)
                        if error.kind() == io::ErrorKind::WouldBlock && Instant::now() < until =>
                    {
                        thread::sleep(Duration::from_millis(5))
                    }
                    result => {
                        eprintln!("Proxy observation secure={secure}: accept ended {result:?}");
                        return Vec::new();
                    }
                }
            }
        });
        let proxy = Url::parse(&format!(
            "{}://127.0.0.1:{port}",
            if secure { "https" } else { "http" }
        ))
        .unwrap();
        let result = NativeReader::open_route(
            "https://example.invalid/",
            Instant::now() + Duration::from_secs(2),
            Route::Named(&proxy, None),
            false,
            None,
        );
        let error = result.err().map(|e| e.to_string()).unwrap_or_default();
        (worker.join().unwrap(), error)
    }
    #[test]
    fn native_proxy_entry_preserves_https_gateway_and_http_connect() {
        let _guard = TEST_LOCK.lock().unwrap();
        let (plain, plain_error) = observe_proxy(false);
        assert!(
            proxy_prefix_matches(&plain, false),
            "HTTP proxy did not receive CONNECT: {plain_error}"
        );
        let (secure, secure_error) = observe_proxy(true);
        assert!(
            proxy_prefix_matches(&secure, true),
            "HTTPS proxy did not receive TLS ClientHello: {secure_error}"
        );
    }
    #[test]
    fn native_network_deadline_closes_request_and_releases_callback_context() {
        let _guard = TEST_LOCK.lock().unwrap();
        for credentials in [
            None,
            Some((&ProxyCredentials::Default, WINHTTP_AUTH_SCHEME_NTLM)),
        ] {
            let before = LIVE_CONTEXTS.load(std::sync::atomic::Ordering::SeqCst);
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let port = listener.local_addr().unwrap().port();
            listener.set_nonblocking(true).unwrap();
            let worker = thread::spawn(move || {
                let until = Instant::now() + Duration::from_secs(2);
                while Instant::now() < until {
                    if let Ok((stream, _)) = listener.accept() {
                        thread::sleep(Duration::from_millis(400));
                        drop(stream);
                        break;
                    }
                    thread::sleep(Duration::from_millis(5));
                }
            });
            let proxy = Url::parse(&format!("http://127.0.0.1:{port}")).unwrap();
            let started = Instant::now();
            let error = NativeReader::open_route(
                "https://example.invalid/",
                started + Duration::from_millis(150),
                Route::Named(&proxy, None),
                false,
                credentials,
            )
            .err()
            .expect("A stalled proxy unexpectedly completed");
            assert!(
                error
                    .chain()
                    .filter_map(|e| e.downcast_ref::<io::Error>())
                    .any(|e| e.kind() == io::ErrorKind::TimedOut),
                "Unexpected native deadline error: {error}"
            );
            assert!(
                started.elapsed() < Duration::from_secs(1),
                "A network operation exceeded its deadline"
            );
            worker.join().unwrap();
            let until = Instant::now() + Duration::from_secs(2);
            while LIVE_CONTEXTS.load(std::sync::atomic::Ordering::SeqCst) != before
                && Instant::now() < until
            {
                thread::sleep(Duration::from_millis(5));
            }
            assert_eq!(
                LIVE_CONTEXTS.load(std::sync::atomic::Ordering::SeqCst),
                before,
                "Native callback context was not released after closing"
            );
        }
    }
    fn verify_published_asset(url: &str) {
        let _guard = TEST_LOCK.lock().unwrap();
        let mut reader = NativeReader::open_route(
            url,
            Instant::now() + Duration::from_secs(120),
            Route::System,
            true,
            None,
        )
        .unwrap();
        fn rate_header(handle: *mut c_void, name: &str) -> Option<u64> {
            let name = wide(std::ffi::OsStr::new(name)).ok()?;
            let mut bytes = 0;
            unsafe {
                WinHttpQueryHeaders(
                    handle,
                    WINHTTP_QUERY_CUSTOM,
                    name.as_ptr(),
                    ptr::null_mut(),
                    &mut bytes,
                    ptr::null_mut(),
                );
            }
            if bytes == 0 || bytes > 1024 {
                return None;
            }
            let mut buffer = vec![0u16; bytes as usize / 2 + 1];
            if unsafe {
                WinHttpQueryHeaders(
                    handle,
                    WINHTTP_QUERY_CUSTOM,
                    name.as_ptr(),
                    buffer.as_mut_ptr().cast(),
                    &mut bytes,
                    ptr::null_mut(),
                )
            } == 0
            {
                return None;
            }
            let length = buffer.iter().position(|c| *c == 0)?;
            String::from_utf16(&buffer[..length])
                .ok()?
                .trim()
                .parse()
                .ok()
        }
        assert!(
            (200..300).contains(&reader.status),
            "Published asset status {}; rate remaining {:?}; reset unix {:?}",
            reader.status,
            rate_header(reader.request.0, "X-RateLimit-Remaining"),
            rate_header(reader.request.0, "X-RateLimit-Reset")
        );
        let expected = 99690224u64;
        assert!(reader.length.is_none_or(|length| length == expected));
        use sha2::{Digest, Sha256};
        let mut digest = Sha256::new();
        let mut count = 0u64;
        let mut buffer = [0u8; 131072];
        loop {
            let n = reader.read(&mut buffer).unwrap();
            if n == 0 {
                break;
            }
            count += n as u64;
            assert!(count <= expected);
            digest.update(&buffer[..n]);
        }
        assert_eq!(count, expected);
        assert_eq!(
            hex::encode_upper(digest.finalize()),
            "ACE4A47FF8D6775FDA0A54A3850D2D07C2F5A4D0929C596BC4FAEB79B44DC1E4"
        );
    }
    #[test]
    #[ignore = "Public GitHub API transfer is run explicitly, separately from offline unit checks"]
    fn genuine_published_asset_uses_os_tls_proxy_and_authenticated_hash() {
        verify_published_asset(
            "https://api.github.com/repos/1llum1n4t1s/Prunlet/releases/assets/700561676",
        );
    }
    #[test]
    #[ignore = "Public release transfer checks the same artifact without API rate-limit access"]
    fn genuine_published_release_url_uses_os_tls_proxy_and_authenticated_hash() {
        verify_published_asset(
            "https://github.com/1llum1n4t1s/Prunlet/releases/download/v1.0.29/prunlet-update-win-x64.zip",
        );
    }
    #[test]
    #[ignore = "An explicitly launched local SOCKS relay forwards only the known public release artifact"]
    fn genuine_published_release_through_environment_proxy() {
        let _guard = TEST_LOCK.lock().unwrap();
        let environment = environment_proxies()
            .unwrap()
            .expect("Explicit fixture proxy required");
        let proxy = environment
            .https
            .expect("Explicit HTTPS fixture proxy required");
        assert!(proxy.url.scheme().starts_with("socks"));
        assert!(matches!(
            proxy.url.host_str(),
            Some("127.0.0.1" | "localhost")
        ));
        let mut response = get("https://github.com/1llum1n4t1s/Prunlet/releases/download/v1.0.29/prunlet-update-win-x64.zip", Instant::now()+Duration::from_secs(120)).unwrap();
        use sha2::{Digest, Sha256};
        let expected = 99690224u64;
        let mut count = 0u64;
        let mut digest = Sha256::new();
        let mut buffer = [0u8; 131072];
        while count <= expected {
            let read = response.body.read(&mut buffer).unwrap();
            if read == 0 {
                break;
            }
            count += read as u64;
            digest.update(&buffer[..read]);
        }
        assert_eq!(count, expected);
        assert_eq!(
            hex::encode_upper(digest.finalize()),
            "ACE4A47FF8D6775FDA0A54A3850D2D07C2F5A4D0929C596BC4FAEB79B44DC1E4"
        );
    }
    #[test]
    #[ignore = "An explicitly launched local proxy fixture supplies the challenge and safe phase report"]
    fn explicit_default_credentials_external_proxy() {
        let environment = environment_proxies()
            .unwrap()
            .expect("Explicit fixture proxy is required");
        let proxy = environment.https.expect("HTTPS fixture proxy is required");
        assert!(matches!(proxy.credentials, Some(ProxyCredentials::Default)));
        assert!(matches!(
            proxy.url.host_str(),
            Some("127.0.0.1" | "localhost")
        ));
        let error = get(
            "https://example.invalid/",
            Instant::now() + Duration::from_secs(12),
        )
        .err()
        .expect("The fixture must terminate before reaching any origin");
        if std::env::var_os("PRUNLET_FIXTURE_UNTRUSTED_TLS").is_some() {
            let codes = error
                .chain()
                .filter_map(|e| e.downcast_ref::<io::Error>())
                .filter_map(io::Error::raw_os_error)
                .collect::<Vec<_>>();
            assert!(
                proxy.url.scheme() == "https"
                    && codes.iter().any(|code| matches!(*code, 12175 | 12029)),
                "The untrusted proxy certificate did not fail with a TLS validation error; native codes {codes:?}"
            );
        } else {
            assert!(
                error.to_string().contains("HTTP 502"),
                "The authenticated fixture did not reach its terminal HTTP status: {error}"
            );
        }
    }
    #[test]
    fn proxy_only_autologon_policy_accepts_explicit_proxy_challenge() {
        let _guard = TEST_LOCK.lock().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        listener.set_nonblocking(true).unwrap();
        let worker = thread::spawn(move || {
            let until = Instant::now() + Duration::from_secs(3);
            let mut connections = 0;
            let mut requests = 0;
            let mut any_proxy_auth = false;
            let mut any_server_auth = false;
            loop {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        connections += 1;
                        // Windowsのaccept先はlistenerの非blocking設定を継承する。
                        // WouldBlockをEOFと誤認して認証途中の同一connectionを閉じない。
                        stream.set_nonblocking(false).unwrap();
                        stream
                            .set_read_timeout(Some(Duration::from_secs(2)))
                            .unwrap();
                        for _ in 0..4 {
                            let mut bytes = Vec::new();
                            let mut block = [0u8; 2048];
                            while bytes.len() < 16384 && !bytes.ends_with(b"\r\n\r\n") {
                                let n = stream.read(&mut block).unwrap_or(0);
                                if n == 0 {
                                    break;
                                }
                                bytes.extend_from_slice(&block[..n]);
                            }
                            if bytes.is_empty() {
                                break;
                            }
                            requests += 1;
                            let headers = String::from_utf8_lossy(&bytes).to_ascii_lowercase();
                            any_proxy_auth |= headers.contains("\r\nproxy-authorization:");
                            any_server_auth |= headers.contains("\r\nauthorization:");
                            let sent = headers.contains("proxy-authorization: ntlm ");
                            if sent {
                                let _=stream.write_all(b"HTTP/1.1 502 Fixture End\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                                return (
                                    true,
                                    connections,
                                    requests,
                                    any_proxy_auth,
                                    any_server_auth,
                                );
                            }
                            let _=stream.write_all(b"HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: NTLM\r\nProxy-Support: Session-Based-Authentication\r\nContent-Length: 0\r\nProxy-Connection: Keep-Alive\r\nConnection: keep-alive\r\n\r\n");
                        }
                    }
                    Err(error)
                        if error.kind() == io::ErrorKind::WouldBlock && Instant::now() < until =>
                    {
                        thread::sleep(Duration::from_millis(5))
                    }
                    _ => {
                        return (
                            false,
                            connections,
                            requests,
                            any_proxy_auth,
                            any_server_auth,
                        );
                    }
                }
            }
        });
        let proxy = Url::parse(&format!("http://127.0.0.1:{port}")).unwrap();
        let client_started = Instant::now();
        let result = NativeReader::open_route(
            "https://example.invalid/",
            Instant::now() + Duration::from_secs(3),
            Route::Named(&proxy, None),
            false,
            Some((&ProxyCredentials::Default, WINHTTP_AUTH_SCHEME_NTLM)),
        );
        let error = match result {
            Ok(reader) => format!("status {}", reader.status),
            Err(error) => error.to_string(),
        };
        let client_elapsed = client_started.elapsed().as_millis();
        let observed = worker.join().unwrap();
        assert!(
            observed.0,
            "PROXY_ONLY did not send explicit NTLM to the challenged proxy: {error}; client elapsed {client_elapsed}ms; (NTLM, connections, requests, any proxy auth, any server auth)={observed:?}"
        );
    }
    fn observe_explicit_challenge(server_challenge: bool) -> (u64, bool, bool, bool) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        listener.set_nonblocking(true).unwrap();
        let worker = thread::spawn(move || {
            let (mut challenged, mut preemptive, mut server_auth, mut basic) =
                (false, false, false, false);
            let deadline = Instant::now() + Duration::from_secs(5);
            'connections: loop {
                let mut stream = match listener.accept() {
                    Ok((stream, _)) => stream,
                    Err(error)
                        if error.kind() == io::ErrorKind::WouldBlock
                            && Instant::now() < deadline =>
                    {
                        thread::sleep(Duration::from_millis(5));
                        continue;
                    }
                    _ => break,
                };
                stream.set_nonblocking(false).unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                for _ in 0..4 {
                    let mut bytes = Vec::new();
                    let mut block = [0u8; 2048];
                    while bytes.len() < 32768 && !bytes.ends_with(b"\r\n\r\n") {
                        let count = stream.read(&mut block).unwrap_or(0);
                        if count == 0 {
                            break;
                        }
                        bytes.extend_from_slice(&block[..count]);
                    }
                    if bytes.is_empty() {
                        if server_challenge {
                            break 'connections;
                        }
                        break;
                    }
                    let headers = String::from_utf8_lossy(&bytes).to_ascii_lowercase();
                    let proxy_auth = headers.contains("\r\nproxy-authorization:");
                    server_auth |= headers.contains("\r\nauthorization:");
                    preemptive |= !challenged && proxy_auth;
                    basic |= headers.contains("\r\nproxy-authorization: basic ");
                    if basic {
                        stream.write_all(b"HTTP/1.1 502 Fixture End\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
                        break 'connections;
                    }
                    let response = if server_challenge {
                        b"HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: NTLM\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n".as_slice()
                    } else {
                        b"HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"fixture\"\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n".as_slice()
                    };
                    stream.write_all(response).unwrap();
                    challenged = true;
                }
            }
            (preemptive, server_auth, basic)
        });
        let proxy = Url::parse(&format!("http://127.0.0.1:{port}")).unwrap();
        let credentials = if server_challenge {
            ProxyCredentials::Default
        } else {
            ProxyCredentials::Explicit {
                user: "fixture-user".into(),
                password: "fixture-password".into(),
            }
        };
        let scheme = if server_challenge {
            WINHTTP_AUTH_SCHEME_NTLM
        } else {
            WINHTTP_AUTH_SCHEME_BASIC
        };
        let reader = NativeReader::open_route(
            "https://example.invalid/",
            Instant::now() + Duration::from_secs(5),
            Route::Named(&proxy, None),
            false,
            Some((&credentials, scheme)),
        )
        .unwrap();
        let status = reader.status;
        drop(reader);
        let (preemptive, server_auth, basic) = worker.join().unwrap();
        (status, preemptive, server_auth, basic)
    }
    #[test]
    fn explicit_basic_proxy_credentials_wait_for_407() {
        let _guard = TEST_LOCK.lock().unwrap();
        let (status, preemptive, server_auth, basic) = observe_explicit_challenge(false);
        assert_eq!(status, 502);
        assert!(!preemptive);
        assert!(!server_auth);
        assert!(basic);
    }
    #[test]
    fn server_401_on_connect_never_receives_default_proxy_credentials() {
        let _guard = TEST_LOCK.lock().unwrap();
        let (status, preemptive, server_auth, basic) = observe_explicit_challenge(true);
        assert_eq!(status, 401);
        assert!(!preemptive);
        assert!(!server_auth);
        assert!(!basic);
    }
}

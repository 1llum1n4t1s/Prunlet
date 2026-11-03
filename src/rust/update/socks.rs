//! SOCKS の一回の接続だけを扱う。redirect と proxy 選択は呼出側で行う。
use anyhow::{Context, Result, bail, ensure};
use bytes::Bytes;
use http_body_util::{BodyExt, Empty};
use hyper::{Request, body::Incoming, client::conn::http1, header};
use hyper_util::rt::TokioIo;
use std::{
    future::Future,
    io::{self, Read},
    net::IpAddr,
    time::Instant,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::TcpStream,
    runtime::Runtime,
    task::JoinHandle,
};
use url::Url;

pub(super) struct SocksCredentials {
    pub username: String,
    pub password: String,
}
pub(super) struct SocksResponse {
    pub status: u16,
    pub location: Option<String>,
    pub length: Option<u64>,
    pub body: Box<dyn Read>,
}

// Runtime の通常 Drop は DNS の blocking worker を無期限に待つため使わない。
struct Session {
    runtime: Option<Runtime>,
    driver: Option<JoinHandle<()>>,
}
impl Session {
    fn new() -> Result<Self> {
        Ok(Self {
            runtime: Some(
                tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()?,
            ),
            driver: None,
        })
    }
    fn run<T>(&self, deadline: Instant, future: impl Future<Output = Result<T>>) -> Result<T> {
        ensure!(Instant::now() < deadline, "SOCKS transfer deadline expired");
        self.runtime.as_ref().unwrap().block_on(async {
            tokio::time::timeout_at(tokio::time::Instant::from_std(deadline), future)
                .await
                .context("SOCKS transfer deadline expired")?
        })
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        if let Some(driver) = self.driver.take() {
            driver.abort();
        }
        if let Some(runtime) = self.runtime.take() {
            runtime.shutdown_background();
        }
    }
}

fn host(url: &Url) -> Result<&str> {
    // URL の IPv6 括弧を除き、socket・TLS・SOCKS へ実アドレスを渡す。
    let host = url.host_str().context("SOCKS URL host missing")?;
    Ok(host
        .strip_prefix('[')
        .and_then(|s| s.strip_suffix(']'))
        .unwrap_or(host))
}

pub(super) fn get_once(
    target: &Url,
    proxy: &Url,
    credentials: Option<&SocksCredentials>,
    deadline: Instant,
) -> Result<SocksResponse> {
    get_once_at(target, proxy, None, credentials, deadline)
}

pub(super) fn get_once_at(
    target: &Url,
    proxy: &Url,
    scoped_host: Option<&str>,
    credentials: Option<&SocksCredentials>,
    deadline: Instant,
) -> Result<SocksResponse> {
    ensure!(
        target.scheme() == "https" && target.username().is_empty() && target.password().is_none(),
        "SOCKS target requires HTTPS without credentials"
    );
    ensure!(
        matches!(proxy.scheme(), "socks4" | "socks4a" | "socks5" | "socks5h"),
        "Unsupported SOCKS version"
    );
    let session = Session::new()?;
    let stream = session.run(deadline, async {
        // scopeはproxyのTCP接続先だけに使い、対象の名前解決・TLS検証へ混ぜない。
        let port = proxy.port().unwrap_or(80);
        let connection = if let Some(raw) = scoped_host {
            let (address, scope) = raw
                .split_once('%')
                .context("Invalid scoped SOCKS endpoint")?;
            ensure!(
                !scope.is_empty() && scope.bytes().all(|c| c.is_ascii_digit()),
                "Invalid scoped SOCKS endpoint"
            );
            let address = std::net::SocketAddrV6::new(address.parse()?, port, 0, scope.parse()?);
            TcpStream::connect(address).await
        } else {
            TcpStream::connect((host(proxy)?, port)).await
        };
        let mut stream = connection.context("SOCKS proxy connect failed")?;
        tunnel(
            &mut stream,
            proxy.scheme(),
            host(target)?,
            target.port_or_known_default().unwrap_or(443),
            credentials,
        )
        .await?;
        let mut builder = native_tls::TlsConnector::builder();
        builder.min_protocol_version(Some(native_tls::Protocol::Tlsv12));
        // OS trust、SNI と hostname 検証を維持し、HTTP/2 ALPN は広告しない。
        let connector = tokio_native_tls::TlsConnector::from(builder.build()?);
        Ok(connector
            .connect(host(target)?, stream)
            .await
            .context("SOCKS target TLS failed")?)
    })?;
    request(session, stream, target, deadline)
}

fn request<S>(
    mut session: Session,
    stream: S,
    target: &Url,
    deadline: Instant,
) -> Result<SocksResponse>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let (mut sender, connection) = session.run(deadline, async {
        Ok(http1::handshake(TokioIo::new(stream)).await?)
    })?;
    session.driver = Some(session.runtime.as_ref().unwrap().spawn(async move {
        let _ = connection.await;
    }));
    let mut path = target.path().to_owned();
    if let Some(query) = target.query() {
        path.push('?');
        path.push_str(query);
    }
    let authority = match target.port() {
        Some(port) => format!(
            "{}:{port}",
            target.host_str().context("Target host missing")?
        ),
        None => target.host_str().context("Target host missing")?.to_owned(),
    };
    let response = session.run(deadline, async {
        let request = Request::builder()
            .uri(path)
            .header(header::HOST, authority)
            .header(header::USER_AGENT, "Prunlet-Published-Updater")
            .header(header::ACCEPT, "application/octet-stream")
            .header("X-GitHub-Api-Version", "2022-11-28")
            .body(Empty::<Bytes>::new())?;
        Ok(sender.send_request(request).await?)
    })?;
    let status = response.status().as_u16();
    let location = response
        .headers()
        .get(header::LOCATION)
        .map(|v| v.to_str().map(str::to_owned))
        .transpose()?;
    let length = response
        .headers()
        .get(header::CONTENT_LENGTH)
        .map(|v| -> Result<u64> { Ok(v.to_str()?.parse()?) })
        .transpose()?;
    Ok(SocksResponse {
        status,
        location,
        length,
        body: Box::new(Reader {
            body: Some(response.into_body()),
            pending: Bytes::new(),
            session,
            deadline,
        }),
    })
}

struct Reader {
    body: Option<Incoming>,
    pending: Bytes,
    session: Session,
    deadline: Instant,
}
impl Reader {
    fn close(&mut self) {
        self.body.take();
        self.pending = Bytes::new();
        if let Some(driver) = self.session.driver.take() {
            driver.abort();
        }
        if let Some(runtime) = self.session.runtime.take() {
            runtime.shutdown_background();
        }
    }
}
impl Drop for Reader {
    fn drop(&mut self) {
        self.close();
    }
}
impl Read for Reader {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        if out.is_empty() {
            return Ok(0);
        }
        if Instant::now() >= self.deadline {
            self.close();
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "SOCKS transfer deadline expired",
            ));
        }
        while self.pending.is_empty() {
            let Some(body) = self.body.as_mut() else {
                return Ok(0);
            };
            let frame = self
                .session
                .run(self.deadline, async { Ok(body.frame().await.transpose()?) });
            match frame {
                Ok(Some(frame)) => {
                    if let Ok(data) = frame.into_data() {
                        self.pending = data;
                    }
                }
                Ok(None) => {
                    self.close();
                    return Ok(0);
                }
                Err(error) => {
                    let kind = if Instant::now() >= self.deadline {
                        io::ErrorKind::TimedOut
                    } else {
                        io::ErrorKind::Other
                    };
                    self.close();
                    return Err(io::Error::new(kind, error));
                }
            }
        }
        let count = out.len().min(self.pending.len());
        out[..count].copy_from_slice(&self.pending.split_to(count));
        Ok(count)
    }
}

async fn tunnel<S: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut S,
    scheme: &str,
    host: &str,
    port: u16,
    credentials: Option<&SocksCredentials>,
) -> Result<()> {
    match scheme {
        "socks5" | "socks5h" => socks5(stream, host, port, credentials).await,
        "socks4" | "socks4a" => socks4(stream, scheme == "socks4a", host, port, credentials).await,
        _ => bail!("Unsupported SOCKS version"),
    }
}
fn encoded(value: &str) -> Result<&[u8]> {
    ensure!(value.len() <= 255, "SOCKS string exceeds 255 UTF-8 bytes");
    Ok(value.as_bytes())
}
async fn socks5<S: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut S,
    host: &str,
    port: u16,
    credentials: Option<&SocksCredentials>,
) -> Result<()> {
    stream
        .write_all(if credentials.is_some() {
            &[5, 2, 0, 2]
        } else {
            &[5, 1, 0]
        })
        .await?;
    let mut selection = [0; 2];
    stream.read_exact(&mut selection).await?;
    ensure!(selection[0] == 5, "Unexpected SOCKS protocol version");
    match selection[1] {
        0 => (),
        2 => {
            let credentials = credentials.context("SOCKS proxy requires credentials")?;
            let user = encoded(&credentials.username)?;
            let password = encoded(&credentials.password)?;
            let mut auth = vec![1, user.len() as u8];
            auth.extend(user);
            auth.push(password.len() as u8);
            auth.extend(password);
            stream.write_all(&auth).await?;
            stream.read_exact(&mut selection).await?;
            ensure!(selection == [1, 0], "SOCKS authentication failed");
        }
        _ => bail!("SOCKS proxy selected unsupported authentication"),
    }
    let mut request = vec![5, 1, 0];
    match host.parse::<IpAddr>() {
        Ok(IpAddr::V4(ip)) => {
            request.push(1);
            request.extend(ip.octets());
        }
        Ok(IpAddr::V6(ip)) => {
            request.push(4);
            request.extend(ip.octets());
        }
        Err(_) => {
            let host = encoded(host)?;
            request.extend([3, host.len() as u8]);
            request.extend(host);
        }
    }
    request.extend(port.to_be_bytes());
    stream.write_all(&request).await?;
    let mut reply = [0; 5];
    stream.read_exact(&mut reply).await?;
    ensure!(reply[0] == 5, "Unexpected SOCKS protocol version");
    ensure!(reply[1] == 0, "SOCKS connect refused (code {})", reply[1]);
    let remaining = match reply[3] {
        1 => 5,
        4 => 17,
        3 => reply[4] as usize + 2,
        _ => bail!("Invalid SOCKS address type"),
    };
    stream.read_exact(&mut vec![0; remaining]).await?;
    Ok(())
}
async fn socks4<S: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut S,
    remote: bool,
    host: &str,
    port: u16,
    credentials: Option<&SocksCredentials>,
) -> Result<()> {
    let address = match host.parse::<IpAddr>() {
        Ok(IpAddr::V4(ip)) => Some(ip),
        Ok(IpAddr::V6(ip)) => Some(
            ip.to_ipv4_mapped()
                .context("SOCKS4 does not support IPv6")?,
        ),
        Err(_) if remote => None,
        Err(_) => Some(
            tokio::net::lookup_host((host, port))
                .await?
                .find_map(|ip| match ip.ip() {
                    IpAddr::V4(ip) => Some(ip),
                    _ => None,
                })
                .context("SOCKS4 host has no IPv4 address")?,
        ),
    };
    let user = encoded(credentials.map_or("", |c| c.username.as_str()))?;
    ensure!(!user.contains(&0), "SOCKS4 USERID contains NUL");
    let mut request = vec![4, 1];
    request.extend(port.to_be_bytes());
    request.extend(address.map_or([0, 0, 0, 255], |ip| ip.octets()));
    request.extend(user);
    request.push(0);
    if address.is_none() {
        let host = encoded(host)?;
        ensure!(!host.contains(&0), "SOCKS4a host contains NUL");
        request.extend(host);
        request.push(0);
    }
    stream.write_all(&request).await?;
    let mut reply = [0; 8];
    stream.read_exact(&mut reply).await?;
    ensure!(reply[1] == 90, "SOCKS4 connect refused (code {})", reply[1]);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{net::TcpListener, thread, time::Duration};

    async fn pair<A: Future, B: Future>(a: A, b: B) -> (A::Output, B::Output) {
        let (mut a, mut b) = (std::pin::pin!(a), std::pin::pin!(b));
        let (mut first, mut second) = (None, None);
        std::future::poll_fn(|cx| {
            if first.is_none() {
                if let std::task::Poll::Ready(value) = a.as_mut().poll(cx) {
                    first = Some(value);
                }
            }
            if second.is_none() {
                if let std::task::Poll::Ready(value) = b.as_mut().poll(cx) {
                    second = Some(value);
                }
            }
            if first.is_some() && second.is_some() {
                std::task::Poll::Ready((first.take().unwrap(), second.take().unwrap()))
            } else {
                std::task::Poll::Pending
            }
        })
        .await
    }

    fn credentials(user: &str, password: &str) -> SocksCredentials {
        SocksCredentials {
            username: user.into(),
            password: password.into(),
        }
    }
    fn exchange(
        scheme: &str,
        host: &str,
        credentials: Option<&SocksCredentials>,
        expected: Vec<u8>,
        reply: Vec<u8>,
    ) -> Result<()> {
        let session = Session::new()?;
        session.run(Instant::now() + Duration::from_secs(2), async {
            let (mut client, mut server) = tokio::io::duplex(2048);
            let proxy = async move {
                let mut actual = vec![0; expected.len()];
                server.read_exact(&mut actual).await.unwrap();
                assert_eq!(actual, expected);
                server.write_all(&reply).await.unwrap();
            };
            let (result, ()) =
                pair(tunnel(&mut client, scheme, host, 443, credentials), proxy).await;
            result
        })
    }
    fn v4_request(address: [u8; 4], user: &[u8], domain: Option<&str>) -> Vec<u8> {
        let mut bytes = vec![4, 1, 1, 187];
        bytes.extend(address);
        bytes.extend(user);
        bytes.push(0);
        if let Some(domain) = domain {
            bytes.extend(domain.as_bytes());
            bytes.push(0);
        }
        bytes
    }
    #[test]
    fn socks4_and_4a_userid_address_and_remote_dns() {
        let creds = credentials("利用者", "ignored");
        for (scheme, target, address, domain) in [
            ("socks4", "127.0.0.1", [127, 0, 0, 1], None),
            (
                "socks4a",
                "unresolvable.invalid",
                [0, 0, 0, 255],
                Some("unresolvable.invalid"),
            ),
            ("socks4", "::ffff:127.0.0.1", [127, 0, 0, 1], None),
            ("socks4", "localhost", [127, 0, 0, 1], None),
        ] {
            exchange(
                scheme,
                target,
                Some(&creds),
                v4_request(address, creds.username.as_bytes(), domain),
                vec![0, 90, 0, 0, 0, 0, 0, 0],
            )
            .unwrap();
        }
        assert!(
            exchange(
                "socks4",
                "127.0.0.1",
                None,
                v4_request([127, 0, 0, 1], &[], None),
                vec![0, 93, 0, 0, 0, 0, 0, 0]
            )
            .is_err()
        );
    }
    #[test]
    fn socks4_rejects_nul_oversized_user_and_ipv6() {
        for (target, user) in [
            ("::1", "user"),
            ("127.0.0.1", "bad\0user"),
            ("127.0.0.1", &"x".repeat(256)),
        ] {
            let session = Session::new().unwrap();
            let result = session.run(Instant::now() + Duration::from_secs(1), async {
                let (mut client, _server) = tokio::io::duplex(2048);
                tunnel(
                    &mut client,
                    "socks4",
                    target,
                    443,
                    Some(&credentials(user, "")),
                )
                .await
            });
            assert!(result.is_err());
        }
    }
    fn five(
        target: &str,
        creds: Option<&SocksCredentials>,
        method: u8,
        auth: &[u8],
        atyp: u8,
        address: &[u8],
        reply: &[u8],
    ) -> Result<()> {
        let session = Session::new()?;
        session.run(Instant::now() + Duration::from_secs(2), async {
            let (mut client, mut server) = tokio::io::duplex(2048);
            let proxy = async move {
                let offer = if creds.is_some() {
                    vec![5, 2, 0, 2]
                } else {
                    vec![5, 1, 0]
                };
                let mut actual = vec![0; offer.len()];
                server.read_exact(&mut actual).await.unwrap();
                assert_eq!(actual, offer);
                server.write_all(&[5, method]).await.unwrap();
                if method == 2 {
                    let mut actual = vec![0; auth.len()];
                    server.read_exact(&mut actual).await.unwrap();
                    assert_eq!(actual, auth);
                    server.write_all(&[1, 0]).await.unwrap();
                }
                let mut expected = vec![5, 1, 0, atyp];
                expected.extend(address);
                expected.extend([1, 187]);
                let mut actual = vec![0; expected.len()];
                server.read_exact(&mut actual).await.unwrap();
                assert_eq!(actual, expected);
                server.write_all(reply).await.unwrap();
            };
            let (result, ()) = pair(tunnel(&mut client, "socks5", target, 443, creds), proxy).await;
            result
        })
    }
    #[test]
    fn socks5_offers_both_methods_and_sends_remote_dns_or_ip() {
        let reply = [5, 0, 0, 1, 0, 0, 0, 0, 0, 0];
        let mut domain = vec![20];
        domain.extend(b"unresolvable.invalid");
        five("unresolvable.invalid", None, 0, &[], 3, &domain, &reply).unwrap();
        five(
            "127.0.0.1",
            Some(&credentials("dummy", "secret")),
            0,
            &[],
            1,
            &[127, 0, 0, 1],
            &reply,
        )
        .unwrap();
        five(
            "127.0.0.1",
            Some(&credentials("dummy", "pw")),
            2,
            b"\x01\x05dummy\x02pw",
            1,
            &[127, 0, 0, 1],
            &reply,
        )
        .unwrap();
        five(
            "127.0.0.1",
            Some(&credentials("", "")),
            2,
            &[1, 0, 0],
            1,
            &[127, 0, 0, 1],
            &reply,
        )
        .unwrap();
        five(
            "::1",
            None,
            0,
            &[],
            4,
            &std::net::Ipv6Addr::LOCALHOST.octets(),
            &[5, 0, 0, 3, 1, b'x', 0, 0],
        )
        .unwrap();
    }
    #[test]
    fn socks5_invalid_reply_and_truncation_fail() {
        for reply in [vec![4, 0], vec![5, 255], vec![5, 2], vec![5], vec![]] {
            assert!(exchange("socks5", "127.0.0.1", None, vec![5, 1, 0], reply).is_err());
        }
        for reply in [
            vec![5, 1, 0, 1, 0],
            vec![5, 0, 0, 9, 0],
            vec![5, 0, 0, 1, 0],
        ] {
            assert!(five("127.0.0.1", None, 0, &[], 1, &[127, 0, 0, 1], &reply).is_err());
        }
    }
    #[test]
    fn socks5_rejects_invalid_auth_and_oversized_selected_credentials() {
        for (creds, auth_reply) in [
            (credentials("dummy", "pw"), [2, 0]),
            (credentials("dummy", "pw"), [1, 1]),
            (credentials(&"x".repeat(256), "pw"), [1, 0]),
        ] {
            let session = Session::new().unwrap();
            assert!(
                session
                    .run(Instant::now() + Duration::from_secs(1), async {
                        let (mut client, mut server) = tokio::io::duplex(2048);
                        let proxy = async move {
                            let mut offer = [0; 4];
                            server.read_exact(&mut offer).await.unwrap();
                            server.write_all(&[5, 2]).await.unwrap();
                            // 先に返信しても client の auth write/read 順は変わらない。
                            server.write_all(&auth_reply).await.unwrap();
                        };
                        let (result, ()) = pair(
                            tunnel(&mut client, "socks5", "127.0.0.1", 443, Some(&creds)),
                            proxy,
                        )
                        .await;
                        result
                    })
                    .is_err()
            );
        }
    }
    #[test]
    fn handshake_deadline_is_bounded() {
        let session = Session::new().unwrap();
        let start = Instant::now();
        let result = session.run(start + Duration::from_millis(30), async {
            let (mut client, _server) = tokio::io::duplex(2048);
            tunnel(&mut client, "socks5", "unresolvable.invalid", 443, None).await
        });
        assert!(result.is_err());
        drop(session);
        assert!(start.elapsed() < Duration::from_secs(2));
    }
    fn http_fixture(reply: &'static [u8], wait: bool) -> (Url, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = Url::parse(&format!(
            "https://{}/path?q=1",
            listener.local_addr().unwrap()
        ))
        .unwrap();
        let worker = thread::spawn(move || {
            use std::io::Write;
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut request = vec![];
            while !request.ends_with(b"\r\n\r\n") {
                let mut byte = [0];
                stream.read_exact(&mut byte).unwrap();
                request.push(byte[0]);
            }
            assert!(request.starts_with(b"GET /path?q=1 HTTP/1.1\r\n"));
            let headers = String::from_utf8(request).unwrap().to_ascii_lowercase();
            assert!(headers.contains("user-agent: prunlet-published-updater\r\n"));
            assert!(headers.contains("accept: application/octet-stream\r\n"));
            assert!(headers.contains("x-github-api-version: 2022-11-28\r\n"));
            stream.write_all(reply).unwrap();
            if wait {
                let mut byte = [0];
                assert_eq!(stream.read(&mut byte).unwrap_or(0), 0);
            }
        });
        (url, worker)
    }
    fn plain_request(url: &Url, deadline: Instant) -> SocksResponse {
        let session = Session::new().unwrap();
        let stream = session
            .run(deadline, async {
                Ok(TcpStream::connect((host(url)?, url.port().unwrap())).await?)
            })
            .unwrap();
        request(session, stream, url, deadline).unwrap()
    }
    #[test]
    fn hyper_body_framing_metadata_and_eof() {
        let (url, worker) = http_fixture(b"HTTP/1.1 302 Found\r\nLocation: /next\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n", false);
        let mut response = plain_request(&url, Instant::now() + Duration::from_secs(2));
        assert_eq!(response.status, 302);
        assert_eq!(response.location.as_deref(), Some("/next"));
        assert_eq!(response.length, None);
        let mut body = String::new();
        response.body.read_to_string(&mut body).unwrap();
        assert_eq!(body, "abcde");
        worker.join().unwrap();
    }
    #[test]
    fn body_deadline_and_drop_close_connection() {
        for timeout in [false, true] {
            let (url, worker) =
                http_fixture(b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\na", true);
            let mut response = plain_request(&url, Instant::now() + Duration::from_millis(200));
            assert_eq!(response.length, Some(10));
            if timeout {
                let mut body = Vec::new();
                let error = response.body.read_to_end(&mut body).unwrap_err();
                assert_eq!(error.kind(), io::ErrorKind::TimedOut);
                assert_eq!(body, b"a");
            }
            drop(response);
            worker.join().unwrap();
        }
    }
    #[test]
    fn truncated_http_body_is_not_success() {
        let (url, worker) = http_fixture(b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\na", false);
        let mut response = plain_request(&url, Instant::now() + Duration::from_secs(2));
        assert!(response.body.read_to_end(&mut Vec::new()).is_err());
        worker.join().unwrap();
    }

    #[test]
    fn runtime_drop_does_not_wait_for_blocking_dns_worker() {
        let session = Session::new().unwrap();
        let (started_tx, started_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let (finished_tx, finished_rx) = std::sync::mpsc::channel();
        session.runtime.as_ref().unwrap().spawn_blocking(move || {
            started_tx.send(()).unwrap();
            let _ = release_rx.recv();
            let _ = finished_tx.send(());
        });
        started_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let start = Instant::now();
        drop(session);
        let elapsed = start.elapsed();
        release_tx.send(()).unwrap();
        finished_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert!(elapsed < Duration::from_secs(1));
    }

    #[test]
    fn production_entry_rejects_plaintext_tls_and_closes_on_timeout() {
        for stall in [false, true] {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let proxy =
                Url::parse(&format!("socks5://{}", listener.local_addr().unwrap())).unwrap();
            let worker = thread::spawn(move || {
                use std::io::Write;
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(2)))
                    .unwrap();
                let mut offer = [0; 3];
                stream.read_exact(&mut offer).unwrap();
                assert_eq!(offer, [5, 1, 0]);
                stream.write_all(&[5, 0]).unwrap();
                let mut request = [0; 10];
                stream.read_exact(&mut request).unwrap();
                assert_eq!(request, [5, 1, 0, 1, 127, 0, 0, 1, 1, 187]);
                stream.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).unwrap();
                if !stall {
                    let _ = stream.write_all(b"HTTP/1.1 200 OK\r\n\r\n");
                }
                // TLS ClientHello を捨て、エラー/期限後の client close まで観測する。
                let mut bytes = [0; 4096];
                loop {
                    match stream.read(&mut bytes) {
                        Ok(0) => break,
                        Ok(_) => (),
                        Err(error) if error.kind() == io::ErrorKind::ConnectionReset => break,
                        Err(error) => {
                            panic!("TLS fixture did not observe connection close: {error}")
                        }
                    }
                }
            });
            let target = Url::parse("https://127.0.0.1/").unwrap();
            let result = get_once(
                &target,
                &proxy,
                None,
                Instant::now() + Duration::from_millis(300),
            );
            assert!(result.is_err());
            worker.join().unwrap();
        }
    }
}

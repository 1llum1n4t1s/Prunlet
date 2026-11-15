// 配信スクリプトのテスト専用の偽 R2 / 公開ホスト / Cloudflare API（実ネットワークへは出ない）。
// HttpClient の handler として注入し、書込みの順序・条件ヘッダー（If-None-Match / If-Match）・ETag・公開 URL の応答を記録・再現する。
// SigV4 の署名は検証しない（署名の組み立ては共有コピー R2Transfer.Core.cs の責任で、ここでは扱わない）。
using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Prunlet.Tests
{
    public sealed class FakeR2Handler : HttpMessageHandler
    {
        public sealed class Item { public byte[] Bytes = new byte[0]; public string ETag = ""; public string ContentType = ""; }
        public readonly Dictionary<string, Item> Objects = new Dictionary<string, Item>(StringComparer.Ordinal);
        // 記録: "GET key" / "HEAD key" / "PUT key create-only|if-match|unconditional" / "PUBLIC key" / "PURGE"。順序どおり。
        public readonly List<string> Log = new List<string>();
        // 公開 URL だけ別の内容を返す（照合の失敗を再現する）。
        public readonly Dictionary<string, byte[]> PublicOverrides = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        // key にこの文字列を含む PUT に、指定の status を返す（結果不明・拒否の再現）。
        public string FailPutContaining = null;
        public int FailPutStatus = 500;
        // key にこの文字列を含む認証付き GET / HEAD に、指定の status を返す（404 以外の読取り失敗を「まだ無い」と取り違えないことの再現）。
        public string FailGetContaining = null;
        public int FailGetStatus = 500;
        public string Bucket = "prunlet-updates";
        private int counter = 0;

        public void Seed(string key, byte[] bytes)
        {
            lock (Objects) { Objects[key] = new Item { Bytes = bytes, ETag = NewETag(bytes), ContentType = "application/octet-stream" }; }
        }
        public string[] Puts() { lock (Objects) { return Log.Where(entry => entry.StartsWith("PUT ")).ToArray(); } }
        private string NewETag(byte[] bytes)
        {
            counter++;
            return "\"" + Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant().Substring(0, 24) + counter.ToString("x4") + "\"";
        }
        private static HttpResponseMessage Json(string text)
        {
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(text, Encoding.UTF8, "application/json") };
        }
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            string host = request.RequestUri.Host, path = request.RequestUri.AbsolutePath;
            if (host == "api.cloudflare.com")
            {
                if (path.EndsWith("/tokens/verify")) return Json("{\"success\":true,\"result\":{\"status\":\"active\",\"id\":\"0123456789abcdef0123456789abcdef\"}}");
                if (path.EndsWith("/zones")) return Json("{\"success\":true,\"result\":[{\"id\":\"zone1\"}]}");
                if (path.EndsWith("/purge_cache")) { lock (Objects) { Log.Add("PURGE"); } return Json("{\"success\":true}"); }
                return new HttpResponseMessage(HttpStatusCode.NotFound);
            }
            if (host == "prunlet.kagayoi.com")
            {
                string publicKey = Uri.UnescapeDataString(path.TrimStart('/'));
                lock (Objects) { Log.Add("PUBLIC " + publicKey); }
                byte[] served = null;
                lock (Objects) { if (PublicOverrides.ContainsKey(publicKey)) served = PublicOverrides[publicKey]; else if (Objects.ContainsKey(publicKey)) served = Objects[publicKey].Bytes; }
                if (served == null) return new HttpResponseMessage(HttpStatusCode.NotFound);
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(served) };
            }
            if (!host.EndsWith(".r2.cloudflarestorage.com")) return new HttpResponseMessage(HttpStatusCode.BadGateway);
            string prefix = "/" + Bucket + "/";
            if (!path.StartsWith(prefix)) return new HttpResponseMessage(HttpStatusCode.NotFound);
            string key = Uri.UnescapeDataString(path.Substring(prefix.Length));
            if (request.Method == HttpMethod.Put)
            {
                byte[] body = request.Content == null ? new byte[0] : await request.Content.ReadAsByteArrayAsync();
                string mode = request.Headers.Contains("if-none-match") ? "create-only" : request.Headers.Contains("if-match") ? "if-match" : "unconditional";
                lock (Objects)
                {
                    Log.Add("PUT " + key + " " + mode);
                    if (FailPutContaining != null && key.Contains(FailPutContaining)) return new HttpResponseMessage((HttpStatusCode)FailPutStatus);
                    bool exists = Objects.ContainsKey(key);
                    if (mode == "create-only" && exists) return new HttpResponseMessage(HttpStatusCode.PreconditionFailed);
                    if (mode == "if-match")
                    {
                        string wanted = request.Headers.GetValues("if-match").First();
                        if (!exists || Objects[key].ETag != wanted) return new HttpResponseMessage(HttpStatusCode.PreconditionFailed);
                    }
                    string etag = NewETag(body);
                    Objects[key] = new Item { Bytes = body, ETag = etag, ContentType = request.Content?.Headers.ContentType?.ToString() ?? "" };
                    var ok = new HttpResponseMessage(HttpStatusCode.OK);
                    ok.Headers.ETag = new EntityTagHeaderValue(etag);
                    return ok;
                }
            }
            if (request.Method == HttpMethod.Get || request.Method == HttpMethod.Head)
            {
                Item item;
                lock (Objects) { Log.Add(request.Method.Method + " " + key); Objects.TryGetValue(key, out item); }
                if (FailGetContaining != null && key.Contains(FailGetContaining)) return new HttpResponseMessage((HttpStatusCode)FailGetStatus);
                if (item == null) return new HttpResponseMessage(HttpStatusCode.NotFound);
                var response = new HttpResponseMessage(HttpStatusCode.OK);
                response.Headers.ETag = new EntityTagHeaderValue(item.ETag);
                response.Content = request.Method == HttpMethod.Head ? new ByteArrayContent(new byte[0]) : new ByteArrayContent(item.Bytes);
                response.Content.Headers.ContentLength = item.Bytes.LongLength;
                return response;
            }
            return new HttpResponseMessage(HttpStatusCode.MethodNotAllowed);
        }
    }
}

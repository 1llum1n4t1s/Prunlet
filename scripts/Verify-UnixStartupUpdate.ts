// 公開形式のA/B/Cを隔離配置し、同じstdio登録から2回更新する。
// 配信は R2（https://prunlet.kagayoi.com）の署名付きマニフェスト。最新ポインタ latest/<runtime>.json の封筒と、
// それが指す不変キー releases/<repo>/<commit>/<runtime>/<sha256>.<ext> の配布物を、URLのSHA-256名のfixtureで差し替える。
// 封筒はテスト鍵（scripts/release-test-fixtures）で署名し、keyIdはテスト鍵のID（prunlet-release-test-1）にする。テスト鍵を信頼するのは
// 応答の置換と同じテスト専用ビルド（prunlet_linux_update_tests / prunlet_macos_race_tests）だけで、通常ビルドは本番鍵だけを信頼する。
import { createHash, createPrivateKey, generateKeyPairSync, sign, type KeyObject } from "node:crypto";
import { readFileSync } from "node:fs";
import { copyFile, chmod, mkdir, readFile, stat, symlink, unlink, writeFile } from "node:fs/promises";
import { isAbsolute, join } from "node:path";

const [root, initialExecutable, firstPackage, secondPackage] = Bun.argv.slice(2);
if (![root, initialExecutable, firstPackage, secondPackage].every((path) => path && isAbsolute(path))) {
  throw new Error("Use an unused absolute output root, an initial executable, and two update packages.");
}
await mkdir(root, { mode: 0o700 });
const fixture = join(root, "responses");
const installation = join(root, "installation");
await mkdir(fixture, { mode: 0o700 });
const executable = join(installation, "bin/prunlet");
const config = join(installation, "config.json");
const origin = "https://prunlet.kagayoi.com/";
const linux = process.platform === "linux";
const environment = { ...process.env, [linux ? "PRUNLET_LINUX_UPDATE_FIXTURE" : "PRUNLET_MACOS_UPDATE_FIXTURE"]: fixture };
const initial = JSON.parse(run([initialExecutable, linux ? "--linux-build-info" : "--macos-build-info"]));
const runtime: string = linux ? initial.runtime : "osx-arm64";
const name = linux ? `prunlet-${runtime}.tar.gz` : "prunlet-update-osx-arm64.zip";
const extension = linux ? "tar.gz" : "zip";
const sha = (bytes: string | Uint8Array) => createHash("sha256").update(bytes).digest("hex");
const testKey = createPrivateKey(readFileSync(join(import.meta.dir, "release-test-fixtures/test-signing-private.pem"), "utf8"));

function run(command: string[]) {
  const result = Bun.spawnSync(command, { env: environment });
  if (result.exitCode !== 0) throw new Error(result.stderr.toString());
  return result.stdout.toString();
}

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

async function response(url: string, body: object | Uint8Array) {
  const data = body instanceof Uint8Array ? body : JSON.stringify(body);
  await writeFile(join(fixture, sha(url)), data, { mode: 0o600 });
}

// 配信側（scripts/PrunletRelease.Common.ps1）と同じ正規形: キー順固定・compact・末尾改行なし。署名はpayloadの生バイトに
// ECDSA P-256 + SHA-256 の DER。JSON.stringify は "/" を逃がさないので、配信側の UnsafeRelaxedJsonEscaping と同じバイトになる。
function envelope(payload: object, key: KeyObject = testKey) {
  const payloadBytes = Buffer.from(JSON.stringify(payload), "utf8");
  const signature = sign("sha256", payloadBytes, { key, dsaEncoding: "der" });
  return Buffer.from(JSON.stringify({
    schema: 1, keyId: "prunlet-release-test-1", payload: payloadBytes.toString("base64"), signature: signature.toString("base64"),
  }), "utf8");
}

function payload(version: string, commit: string, digest: string, bytes: number) {
  return {
    schema: 1, product: "Prunlet", repository: "1llum1n4t1s/Prunlet", runtime, version, commit, defaultBranch: "main",
    asset: { name, key: `releases/1llum1n4t1s/prunlet/${commit}/${runtime}/${digest}.${extension}`, bytes, sha256: digest },
  };
}

// invalid: digest（マニフェストのsha256が配布物と違う）/ trailer（配布物の末尾に余分なバイト。長さ・sha256は実物どおり）/
// signature（固定公開鍵以外の鍵で署名）/ older（導入済みより古い版を名乗る。適用しない）。
async function announce(archive: string, invalid?: "digest" | "trailer" | "signature" | "older") {
  const manifest = JSON.parse(run(linux
    ? ["/usr/bin/tar", "-xOzf", archive, "manifest.json"]
    : ["/usr/bin/unzip", "-p", archive, "manifest.json"]));
  const packageBytes = await readFile(archive);
  const assetBytes = invalid === "trailer" ? Buffer.concat([packageBytes, Buffer.from([1])]) : packageBytes;
  const digest = invalid === "digest" ? "0".repeat(64) : sha(assetBytes);
  const version = invalid === "older" ? "0.0.1" : manifest.version;
  const signed = payload(version, manifest.commit, digest, assetBytes.length);
  await response(`${origin}${signed.asset.key}`, assetBytes);
  const key = invalid === "signature" ? generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey : testKey;
  await response(`${origin}latest/${runtime}.json`, envelope(signed, key));
  return manifest;
}

async function startMcp() {
  const process = Bun.spawn([executable, "--config", config, "mcp"], {
    env: environment, stdin: "pipe", stdout: "pipe", stderr: "pipe",
  });
  const deadline = setTimeout(() => process.kill(), 90_000);
  const stderr = new Response(process.stderr).text();
  const reader = process.stdout.getReader();
  let text = "";
  async function request(id: number, method: string, params: object) {
    process.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    process.stdin.flush();
    while (true) {
      const newline = text.indexOf("\n");
      if (newline >= 0) {
        const event = JSON.parse(text.slice(0, newline));
        text = text.slice(newline + 1);
        if (event.id === id) {
          if (event.error) throw new Error(JSON.stringify(event.error));
          return event.result;
        }
      } else {
        const next = await reader.read();
        if (next.done) throw new Error(`MCP ended early: ${await stderr}`);
        text += new TextDecoder().decode(next.value);
      }
    }
  }
  try {
    const initialized = await request(1, "initialize", {
      protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "update-e2e", version: "1" },
    });
    process.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n');
    const listed = await request(2, "tools/list", {});
    assert(listed.tools.length === 1 && listed.tools[0].name === "delete_files", "Unexpected MCP tool list.");
    return {
      version: initialized.serverInfo.version,
      async close() {
        process.stdin.end();
        assert(await process.exited === 0, await stderr);
        clearTimeout(deadline);
        return await stderr;
      },
    };
  } catch (error) {
    clearTimeout(deadline);
    process.kill();
    await process.exited;
    throw error;
  }
}

if (linux) {
  await mkdir(installation, { mode: 0o700 });
  await mkdir(join(installation, "bin"), { mode: 0o700 });
  await mkdir(join(installation, "recovery"), { mode: 0o700 });
  await copyFile(initialExecutable, executable);
  await chmod(executable, 0o700);
  run([executable, "--config", config, "init", "--backup-directory", join(installation, "recovery")]);
} else {
  run([initialExecutable, "--install-macos", installation]);
}
const originalConfig = sha(await readFile(config));
const originalMode = (await stat(config)).mode;
const recovery = join(installation, "recovery/fixture.txt");
await writeFile(recovery, "isolated preservation check", { mode: 0o600 });
const originalInode = (await stat(executable)).ino;
const offline = await startMcp();
assert(offline.version === initial.version && (await offline.close()).includes("deferred"),
  "Offline startup did not preserve the installed MCP.");
// 最新ポインタが導入済みと同じ版を指す（適用しない）。配布物は取得されないので値は形式だけ満たす。
await response(`${origin}latest/${runtime}.json`, envelope(payload(initial.version, initial.commit, "0".repeat(64), 1)));
const held = await startMcp();
let first;
try {
  first = await announce(firstPackage);
  const concurrent = await startMcp();
  try {
    assert(concurrent.version === initial.version && (await stat(executable)).ino === originalInode,
      "A live MCP failed to defer replacement.");
  } finally {
    await concurrent.close();
  }
} finally {
  await held.close();
}

const updated = await startMcp();
assert(updated.version === first.version, "First MCP update did not start the new binary.");
await updated.close();
const firstInode = (await stat(executable)).ino;
assert(firstInode !== originalInode, "First update overwrote the original inode.");

const second = await announce(secondPackage, "digest");
const invalid = await startMcp();
assert(invalid.version === first.version && (await stat(executable)).ino === firstInode,
  "An archive with the wrong digest was installed.");
assert((await invalid.close()).includes("deferred"), "Bad digest did not report the deferral.");
// 署名が固定公開鍵で検証できない封筒は延期し、導入済み以下の版は（署名が正しくても）適用しない。
for (const fault of (linux ? ["trailer", "signature", "older"] : ["signature", "older"]) as ("trailer" | "signature" | "older")[]) {
  await announce(secondPackage, fault);
  const rejected = await startMcp();
  assert(rejected.version === first.version && (await stat(executable)).ino === firstInode,
    `Invalid candidate installed: ${fault}`);
  const stderr = await rejected.close();
  if (fault !== "older") assert(stderr.includes("deferred"), `Missing deferral: ${fault}`);
}
await announce(secondPackage);
const stage = join(installation, "bin/.prunlet-next");
if (linux) {
  await symlink(recovery, stage);
  const linked = await startMcp();
  assert(linked.version === first.version && (await linked.close()).includes("deferred"), "A linked stage was accepted.");
  assert(await readFile(recovery, "utf8") === "isolated preservation check", "Linked stage target changed.");
  await unlink(stage);
}
await writeFile(stage, "interrupted candidate", { mode: 0o600, flag: "wx" });
const newest = await startMcp();
assert(newest.version === second.version, "Second MCP update did not start the new binary.");
await newest.close();
assert((await stat(executable)).ino !== firstInode, "Second update overwrote the previous inode.");
assert(sha(await readFile(config)) === originalConfig && (await stat(config)).mode === originalMode,
  "Configuration changed during update.");
assert(await readFile(recovery, "utf8") === "isolated preservation check", "Recovery file changed.");
if (!linux) run(["/usr/bin/codesign", "--verify", "--strict", executable]);
console.log(JSON.stringify({ passed: true, versions: [initial.version, first.version, second.version],
  checked: ["offline", "mcp-in-use", "two-inode-replacements", "wrong-digest", "interrupted-stage", "configuration", "recovery", ...(linux ? ["invalid-archive", "linked-stage"] : ["final-signature"]), "foreign-signature", "older-version"] }));

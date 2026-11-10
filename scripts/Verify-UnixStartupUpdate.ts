// 公開形式のA/B/Cを隔離配置し、同じstdio登録から2回更新する。
import { createHash } from "node:crypto";
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
const api = "https://api.github.com/repos/1llum1n4t1s/Prunlet/";
const release = "https://github.com/1llum1n4t1s/Prunlet/releases/download/";
const linux = process.platform === "linux";
const environment = { ...process.env, [linux ? "PRUNLET_LINUX_UPDATE_FIXTURE" : "PRUNLET_MACOS_UPDATE_FIXTURE"]: fixture };
const initial = JSON.parse(run([initialExecutable, linux ? "--linux-build-info" : "--macos-build-info"]));
const name = linux ? `prunlet-${initial.runtime}.tar.gz` : "prunlet-update-osx-arm64.zip";
const sha = (bytes: string | Uint8Array) => createHash("sha256").update(bytes).digest("hex");

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

async function announce(archive: string, installed: string, invalid?: "digest" | "trailer" | "ancestry") {
  const manifest = JSON.parse(run(linux
    ? ["/usr/bin/tar", "-xOzf", archive, "manifest.json"]
    : ["/usr/bin/unzip", "-p", archive, "manifest.json"]));
  const tag = `v${manifest.version}`;
  const url = `${release}${tag}/${name}`;
  const packageBytes = await readFile(archive);
  const assetBytes = invalid === "trailer" ? Buffer.concat([packageBytes, Buffer.from([1])]) : packageBytes;
  await response(url, assetBytes);
  await response(`${api}commits/${tag}`, { sha: manifest.commit });
  await response(`${api}compare/${installed}...${manifest.commit}?per_page=1`, { status: invalid === "ancestry" ? "diverged" : "ahead" });
  await response(`${api}compare/${manifest.commit}...main?per_page=1`, { status: "identical" });
  await response(`${api}releases/latest`, {
    tag_name: tag, draft: false, prerelease: false,
    assets: [{ name, state: "uploaded", size: assetBytes.length, digest: `sha256:${invalid === "digest" ? "0".repeat(64) : sha(assetBytes)}`, browser_download_url: url }],
  });
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
await response(`${api}releases/latest`, { tag_name: `v${initial.version}` });
const held = await startMcp();
let first;
try {
  first = await announce(firstPackage, initial.commit);
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

const second = await announce(secondPackage, first.commit, "digest");
const invalid = await startMcp();
assert(invalid.version === first.version && (await stat(executable)).ino === firstInode,
  "An archive with the wrong digest was installed.");
assert((await invalid.close()).includes("deferred"), "Bad digest did not report the deferral.");
if (linux) {
  for (const fault of ["trailer", "ancestry"] as const) {
    await announce(secondPackage, first.commit, fault);
    const rejected = await startMcp();
    assert(rejected.version === first.version && (await stat(executable)).ino === firstInode,
      `Invalid candidate installed: ${fault}`);
    assert((await rejected.close()).includes("deferred"), `Missing deferral: ${fault}`);
  }
}
await announce(secondPackage, first.commit);
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
  checked: ["offline", "mcp-in-use", "two-inode-replacements", "wrong-digest", "interrupted-stage", "configuration", "recovery", ...(linux ? ["invalid-archive", "diverged-release", "linked-stage"] : ["final-signature"])] }));

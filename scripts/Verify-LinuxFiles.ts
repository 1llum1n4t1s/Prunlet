// Linux実行体のCLI・stdio MCP・hookと、専用Trashでの復元を確認する。
import { link, lstat, mkdir, readFile, readdir, rename, symlink, writeFile } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import assert from "node:assert/strict";

const [executable, root, ...runner] = Bun.argv.slice(2);
assert(executable && root && isAbsolute(executable) && isAbsolute(root));
await mkdir(root, { mode: 0o700 });
const metadata = join(root, "metadata");
const config = join(root, "config.json");
const data = join(root, "xdg");
const trash = join(data, "Trash");
await mkdir(metadata, { mode: 0o700 });
const environment = { ...process.env, XDG_DATA_HOME: data };
const cases: string[] = [];

function invoke(args: string[], status: number, input?: string) {
  const result = Bun.spawnSync([...runner, executable, ...args], {
    env: environment,
    stdin: input === undefined ? "ignore" : Buffer.from(input),
    stdout: "pipe",
    stderr: "pipe",
  });
  assert.equal(result.exitCode, status, result.stderr.toString() + result.stdout.toString());
  return result.stdout.toString().trim();
}

function cli(args: string[], status = 0) {
  return JSON.parse(invoke(["--config", config, ...args], status));
}

async function restore(original: string, identity: { dev: number; ino: number }) {
  const info = join(trash, "info");
  for (const name of await readdir(info)) {
    if (!name.endsWith(".trashinfo")) continue;
    const lines = (await readFile(join(info, name), "utf8")).trimEnd().split("\n");
    assert.equal(lines[0], "[Trash Info]");
    if (decodeURIComponent(lines[1].slice("Path=".length)) !== original) continue;
    assert.match(lines[2], /^DeletionDate=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d$/);
    const payload = join(trash, "files", name.slice(0, -".trashinfo".length));
    const moved = await lstat(payload);
    assert.equal(moved.dev, identity.dev);
    assert.equal(moved.ino, identity.ino);
    await assert.rejects(lstat(original), { code: "ENOENT" });
    await rename(payload, original);
    // ゴミ箱の記録は専用fixture内に残し、他のTrashには触れない。
    return;
  }
  assert.fail(`Missing Trash info for ${original}`);
}

assert.equal(cli(["init", "--backup-directory", metadata]).status, "initialized");
const beforeConfig = await readFile(config);
const info = JSON.parse(invoke(["--linux-build-info"], 0));
assert.match(info.runtime, /^linux-(arm64|x64)$/);

const file = join(root, "空白 % file");
await writeFile(file, "original");
const fileIdentity = await lstat(file);
assert.equal(cli(["delete", "--dry-run", "--", file]).items[0].status, "would_recycle");
await assert.rejects(lstat(trash), { code: "ENOENT" });
assert.equal(await readFile(file, "utf8"), "original");
cases.push("dry-run-preserves-file-and-absent-trash");

const rejected = cli(["delete", "--", file, "relative"], 1);
assert.deepEqual(rejected.items.map((item: { status: string }) => item.status), ["failed", "failed"]);
assert.equal(await readFile(file, "utf8"), "original");
await assert.rejects(lstat(trash), { code: "ENOENT" });
assert.equal(cli(["delete", "--", config], 1).items[0].status, "failed");
assert.equal(cli(["delete", "--dry-run", "--", "/dev/shm"], 1).items[0].status, "failed");
cases.push("preflight-preserves-all-protected-and-cross-mount");

const pathsFile = join(root, "paths.json");
await writeFile(pathsFile, JSON.stringify([file]));
const moved = cli(["delete", "--paths-file", pathsFile]);
assert.equal(moved.items[0].status, "recycled");
assert.equal(Object.hasOwn(moved.items[0], "operationId"), false);
await restore(file, fileIdentity);
assert.equal(await readFile(file, "utf8"), "original");
cases.push("cli-trash-and-restore-identity-with-unicode");

const directory = join(root, "tree");
await mkdir(directory);
await writeFile(join(directory, "nested"), "child");
await symlink(file, join(directory, "link"));
const directoryIdentity = await lstat(directory);
assert.equal(cli(["delete", "--", directory], 1).items[0].status, "failed");
assert.equal(cli(["delete", "--recursive", "--", directory]).items[0].status, "recycled");
await restore(directory, directoryIdentity);
assert.equal(await readFile(join(directory, "nested"), "utf8"), "child");
assert.equal(await readFile(file, "utf8"), "original");
const linkIdentity = await lstat(join(directory, "link"));
assert.equal(cli(["delete", "--", join(directory, "link")]).items[0].status, "recycled");
await restore(join(directory, "link"), linkIdentity);
assert((await lstat(join(directory, "link"))).isSymbolicLink());
assert.equal(cli(["delete", "--", join(directory, "link", "child")], 1).items[0].status, "failed");
cases.push("directory-and-symlink-leaf-preserve-link-target");

const alias = join(root, "hardlink");
await link(file, alias);
const aliasIdentity = await lstat(alias);
assert.equal(cli(["delete", "--", alias]).items[0].status, "recycled");
assert.equal(await readFile(file, "utf8"), "original");
await restore(alias, aliasIdentity);
assert.equal((await lstat(file)).ino, (await lstat(alias)).ino);
cases.push("hardlink-surviving-alias-preserved");

const mcpTarget = join(root, "mcp-file");
await writeFile(mcpTarget, "MCP");
const mcpIdentity = await lstat(mcpTarget);
const frames = [
  { id: 1, method: "initialize", params: { protocolVersion: "2025-11-25" } },
  { method: "notifications/initialized" },
  { id: 2, method: "tools/list" },
  { id: 3, method: "tools/call", params: { name: "delete_files", arguments: { paths: [mcpTarget] } } },
].map((frame) => JSON.stringify({ jsonrpc: "2.0", ...frame })).join("\n") + "\n";
const replies = invoke(["--config", config, "mcp"], 0, frames).split("\n").map((line) => JSON.parse(line));
assert.equal(replies.find((item) => item.id === 1).result.serverInfo.version, info.version);
const tools = replies.find((item) => item.id === 2).result.tools;
assert.deepEqual(tools.map((tool: { name: string }) => tool.name), ["delete_files"]);
assert.equal(Object.hasOwn(tools[0].inputSchema.properties, "action"), false);
const result = replies.find((item) => item.id === 3).result;
assert.equal(result.isError, false);
assert.equal(result.structuredContent.items[0].status, "recycled");
await restore(mcpTarget, mcpIdentity);
cases.push("real-mcp-delete-completes-at-eof");

const hook = JSON.parse(invoke(["--config", config, "hook"], 0,
  JSON.stringify({ tool_name: "Bash", tool_input: { command: "rm -- /authorized/fixture" } })));
assert.equal(hook.hookSpecificOutput.permissionDecision, "deny");
assert.match(hook.hookSpecificOutput.permissionDecisionReason, /local Linux targets/);
assert.deepEqual(await readFile(config), beforeConfig);
assert.deepEqual(await readdir(metadata), []);
cases.push("hook-refusal-and-configuration-preservation");
console.log(JSON.stringify({ passed: cases.length, runtime: info.runtime, cases }));

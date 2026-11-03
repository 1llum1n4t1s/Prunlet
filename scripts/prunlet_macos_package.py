"""macOS専用の初回導入とビルド。Windows更新ZIPの形式・状態を流用しない。"""
import argparse
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import sys
import urllib.parse
import urllib.request
import zipfile

PRODUCTS = ("prunlet", "prunlet-maintenance", "prunlet-hook")
TARGETS = {"osx-arm64": ("aarch64-apple-darwin", 0x0100000C),
           "osx-x64": ("x86_64-apple-darwin", 0x01000007)}
REQUIRED = ("Cargo.toml", "Cargo.lock", "rust-toolchain.toml", "build.rs",
            "src/rust/main.rs", "src/rust/lib.rs", "scripts/Publish-PrunletMac.sh",
            "scripts/prunlet_macos_package.py")


class DarwinSecurity:
    """Coreと同じ空ACL・NO_INHERITを新規作成時に渡す。既存ACLは変更しない。"""
    _library = None

    @classmethod
    def library(cls):
        if sys.platform != "darwin":
            raise ValueError("Private native creation requires macOS")
        if cls._library is None:
            library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
            signatures = {
                "acl_init": ([ctypes.c_int], ctypes.c_void_p),
                "acl_free": ([ctypes.c_void_p], ctypes.c_int),
                "acl_get_fd_np": ([ctypes.c_int, ctypes.c_int], ctypes.c_void_p),
                "acl_get_flagset_np": ([ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)], ctypes.c_int),
                "acl_add_flag_np": ([ctypes.c_void_p, ctypes.c_uint], ctypes.c_int),
                "filesec_init": ([], ctypes.c_void_p),
                "filesec_free": ([ctypes.c_void_p], None),
                "filesec_set_property": ([ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p], ctypes.c_int),
                "mkdirx_np": ([ctypes.c_char_p, ctypes.c_void_p], ctypes.c_int),
                "openx_np": ([ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p], ctypes.c_int),
                "fgetattrlist": ([ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_ulong], ctypes.c_int),
                "fpathconf": ([ctypes.c_int, ctypes.c_int], ctypes.c_long),
            }
            for name, (arguments, result) in signatures.items():
                function = getattr(library, name)
                function.argtypes, function.restype = arguments, result
            cls._library = library
        return cls._library

    @staticmethod
    def check(result):
        if result != 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))

    @classmethod
    def reject_acl(cls, descriptor, ancestor=False):
        library = cls.library()
        class Attributes(ctypes.Structure):
            _fields_ = [("count", ctypes.c_ushort), ("reserved", ctypes.c_ushort),
                        ("common", ctypes.c_uint), ("volume", ctypes.c_uint),
                        ("directory", ctypes.c_uint), ("file", ctypes.c_uint), ("fork", ctypes.c_uint)]
        request = Attributes(5, 0, 0x00400000, 0, 0, 0, 0)
        buffer = ctypes.create_string_buffer(8192)
        cls.check(library.fgetattrlist(descriptor, ctypes.byref(request), buffer, len(buffer), 0))
        raw = buffer.raw
        length, offset, size = struct.unpack_from("=IiI", raw)
        if not 12 <= length <= len(raw):
            raise ValueError("Unknown extended ACL response")
        if size == 0:
            # Darwin _PC_EXTENDED_SECURITY_NP。未対応をACL無しと誤認しない。
            if library.fpathconf(descriptor, 13) != 1:
                raise ValueError("Extended ACL support cannot be established")
            ctypes.set_errno(0)
            acl = library.acl_get_fd_np(descriptor, 0x100)
            error = ctypes.get_errno()
            if acl:
                library.acl_free(acl)
                raise ValueError("Conflicting extended ACL observations")
            if error != errno.ENOENT:
                raise ValueError("Extended ACL absence cannot be established")
            return
        start = 4 + offset
        if start < 12 or size < 44 or start + size > length:
            raise ValueError("Invalid extended ACL extent")
        magic = struct.unpack_from("=I", raw, start)[0]
        count, flags = struct.unpack_from("=II", raw, start + 36)
        if magic != 0x012CC16D or flags & ~(1 << 17):
            raise ValueError("Unknown or nonempty extended ACL was preserved")
        if count in (0, 0xFFFFFFFF):
            if size != 44:
                raise ValueError("Unknown empty ACL extent")
            return
        # 祖先の既知・非継承deny ACEは権限を増やさない。allowや未知のflagsは
        # delete_child等によるprivate子の名前差替えを否定できないため拒否する。
        if not ancestor or count > 1024 or size != 44 + 24 * count:
            raise ValueError("Unknown or nonempty extended ACL was preserved")
        for index in range(count):
            entry_flags = struct.unpack_from("=I", raw, start + 44 + 24 * index + 16)[0]
            if entry_flags != 2:
                raise ValueError("Ancestor ACL grants or cannot exclude replacement access")

    @classmethod
    def verify(cls, descriptor, directory, private=True):
        info = os.fstat(descriptor)
        if directory != stat.S_ISDIR(info.st_mode) or (not directory and (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1)):
            raise ValueError("Private entry has an unexpected type or link count")
        allowed_owners = (os.geteuid(),) if private else (os.geteuid(), 0)
        forbidden_mode = 0o077 if private else 0o022
        if info.st_uid not in allowed_owners or info.st_mode & forbidden_mode:
            raise ValueError("Entry has unexpected ownership or access permissions")
        cls.reject_acl(descriptor)

    @classmethod
    def create(cls, path, mode, directory):
        library = cls.library()
        acl, security = library.acl_init(0), library.filesec_init()
        try:
            if not acl or not security:
                raise ValueError("Cannot allocate private creation ACL")
            flags = ctypes.c_void_p()
            cls.check(library.acl_get_flagset_np(acl, ctypes.byref(flags)))
            cls.check(library.acl_add_flag_np(flags, 1 << 17))
            mode_value, acl_value = ctypes.c_ushort(mode), ctypes.c_void_p(acl)
            cls.check(library.filesec_set_property(security, 4, ctypes.byref(mode_value)))
            cls.check(library.filesec_set_property(security, 5, ctypes.byref(acl_value)))
            if directory:
                cls.check(library.mkdirx_np(os.fsencode(path), security))
                descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
            else:
                descriptor = library.openx_np(os.fsencode(path), os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, security)
                if descriptor < 0:
                    error = ctypes.get_errno()
                    raise OSError(error, os.strerror(error))
            try:
                cls.verify(descriptor, directory)
                if not directory:
                    return descriptor
            except Exception:
                os.close(descriptor)
                raise
            if directory:
                os.close(descriptor)
        finally:
            if security:
                library.filesec_free(security)
            if acl:
                library.acl_free(acl)


def verify_directory(path, private=True):
    verify_ancestors(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        DarwinSecurity.verify(descriptor, True, private)
    finally:
        os.close(descriptor)


def verify_ancestors(path):
    # descriptor保持だけではDarwinのrename/delete_childを禁止できない。
    # 各名前を支配する親をrootから検証し、第三者に置換可能な祖先を使わない。
    for ancestor in reversed((path, *path.parents)):
        try:
            descriptor = os.open(ancestor, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        except FileNotFoundError:
            break
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, os.geteuid()):
                raise ValueError("Untrusted ancestor owner or type")
            # sticky親は所有者がroot/同UIDで、直下の子もroot/同UIDと確認する場合だけ
            # 他UIDによるunlink/renameを排除できる。ACLのallowは別途一律拒否する。
            if info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX:
                raise ValueError("Ancestor permits replacement by another user")
            DarwinSecurity.reject_acl(descriptor, ancestor=True)
            named = ancestor.lstat()
            if (named.st_dev, named.st_ino) != (info.st_dev, info.st_ino):
                raise ValueError("Ancestor identity changed during validation")
        finally:
            os.close(descriptor)


def checked_path(text, source=None, fresh=False):
    path = Path(text)
    if not path.is_absolute() or "\0" in str(path) or ".." in path.parts:
        raise ValueError("Paths must be absolute without parent traversal")
    path = Path(os.path.abspath(path))
    verify_ancestors(path)
    for ancestor in (path, *path.parents):
        try:
            info = ancestor.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode):
            raise ValueError(f"A path traverses a symbolic link: {ancestor}")
        if not stat.S_ISDIR(info.st_mode):
            raise ValueError(f"Expected directory path: {ancestor}")
    forbidden = [Path.home() / ".codex"]
    if os.environ.get("CODEX_HOME"):
        forbidden.append(Path(os.environ["CODEX_HOME"]).absolute())
    if source:
        forbidden.append(source)
    if any(path == root or root in path.parents for root in forbidden):
        raise ValueError("Outputs must be outside source and Codex home")
    if fresh and path.exists():
        raise ValueError(f"Choose a new directory; existing data were retained: {path}")
    return path


def mkdir_private(path):
    # 既存の権限・ACLをchmodで書き換えない。
    verify_ancestors(path)
    if not path.parent.is_dir():
        mkdir_private(path.parent)
    DarwinSecurity.create(path, 0o700, True)


def sha(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError(f"Product must be a plain single-link file: {path}")
    with path.open("rb") as source:
        digest = hashlib.sha256()
        for block in iter(lambda: source.read(131072), b""):
            digest.update(block)
        return digest.hexdigest().upper()


def write_new(path, data, mode=0o600):
    verify_ancestors(path.parent)
    descriptor = DarwinSecurity.create(path, mode, False)
    with os.fdopen(descriptor, "wb") as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())


def check_macho(path, runtime):
    with path.open("rb") as source:
        header = source.read(12)
    if len(header) != 12 or struct.unpack("<I", header[:4])[0] != 0xFEEDFACF:
        raise ValueError("Product is not a 64-bit native Mach-O executable")
    if struct.unpack("<I", header[4:8])[0] != TARGETS[runtime][1]:
        raise ValueError("Mach-O architecture differs from the requested runtime")


def rust_toolchain(source):
    # Python 3.9でも同じ限定形式を読み、追加のTOML依存を要求しない。
    path = source / "rust-toolchain.toml"
    if path.is_symlink() or not path.is_file():
        raise ValueError("Rust toolchain input must be a plain file")
    section, keys, channel = False, set(), None
    for raw in path.read_text(encoding="utf-8-sig").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line == "[toolchain]" and not section:
            section = True
            continue
        field = re.fullmatch(r"(channel|profile|components|targets)\s*=\s*(.+)", line)
        if not section or not field:
            raise ValueError("Unsupported rust-toolchain.toml syntax")
        key, value = field.groups()
        if key in keys:
            raise ValueError("Duplicate Rust toolchain field")
        keys.add(key)
        if key == "channel":
            match = re.fullmatch(r'"([1-9][0-9]*\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))"', value)
            if not match:
                raise ValueError("Rust channel must be an exact stable version")
            channel = match.group(1)
        elif key == "profile":
            if not re.fullmatch(r'"(?:minimal|default|complete)"', value):
                raise ValueError("Unsupported Rust toolchain profile")
        elif not re.fullmatch(r'\[\s*(?:"[A-Za-z0-9_-]+"\s*(?:,\s*"[A-Za-z0-9_-]+"\s*)*,?\s*)?\]', value):
            raise ValueError("Unsupported Rust toolchain list")
    if not channel:
        raise ValueError("Rust toolchain channel is missing")
    return channel


def publish(source, output_text, runtime, commit=None, target_text=None):
    source = checked_path(str(source))
    toolchain = rust_toolchain(source)
    output = checked_path(output_text, source, fresh=True)
    target = checked_path(target_text, source) if target_text else output / "cargo-target"
    if output in target.parents and target != output / "cargo-target":
        raise ValueError("Use the default target child or a separate target directory")
    for relative in REQUIRED:
        if not (source / relative).is_file():
            raise ValueError(f"Rust source is incomplete: {relative}")
    mkdir_private(output)
    publish_dir = output / "publish"
    mkdir_private(publish_dir)
    temporary = output / "temp"
    mkdir_private(temporary)
    if target.exists():
        verify_directory(target)
    else:
        mkdir_private(target)
    verify_directory(source, private=False)
    inputs = [source / name for name in REQUIRED] + list((source / "src/rust").rglob("*"))
    cargo_inputs = source / ".cargo"
    if os.path.lexists(cargo_inputs):
        if cargo_inputs.is_symlink() or not cargo_inputs.is_dir():
            raise ValueError("Cargo configuration directory must be a plain directory")
        inputs += [cargo_inputs, *cargo_inputs.rglob("*")]
    parents = {parent for path in inputs for parent in path.parents if parent == source or source in parent.parents}
    for parent in parents:
        verify_directory(parent, private=False)
    for path in inputs:
        if path.is_symlink():
            raise ValueError("Source inputs cannot be symbolic links")
        if path.is_file():
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
            try:
                DarwinSecurity.verify(descriptor, False, private=False)
            finally:
                os.close(descriptor)
        elif path.is_dir():
            verify_directory(path, private=False)
        else:
            raise ValueError("Source inputs must be plain files or directories")
    cargo = shutil.which("cargo")
    if not cargo:
        candidate = Path(os.environ.get("CARGO_HOME", str(Path.home() / ".cargo"))) / "bin/cargo"
        if candidate.is_file():
            cargo = str(candidate)
    if not cargo:
        raise ValueError(f"Rust {toolchain} and Xcode Command Line Tools are required")
    env = dict(os.environ, RUSTUP_TOOLCHAIN=toolchain, CARGO_TARGET_DIR=str(target), TMPDIR=str(temporary),
               CARGO_ENCODED_RUSTFLAGS="")
    env.pop("RUSTFLAGS", None)
    if commit:
        if not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise ValueError("Source commit must be 40 lowercase hexadecimal digits")
        env["PRUNLET_SOURCE_COMMIT"] = commit
    version = subprocess.check_output([cargo, "--version"], cwd=source, env=env, text=True)
    if not re.match(r"cargo " + re.escape(toolchain) + r"(?:\s|$)", version):
        raise ValueError(f"Rust {toolchain} is required")
    subprocess.run([cargo, "build", "--locked", "--release", "--target", TARGETS[runtime][0],
                    "--bin", "prunlet", "--bin", "prunlet-maintenance"],
                   cwd=source, env=env, check=True, stdout=sys.stderr)
    for name in PRODUCTS:
        original = target / TARGETS[runtime][0] / "release" / ("prunlet" if name == "prunlet-hook" else name)
        check_macho(original, runtime)
        write_new(publish_dir / name, original.read_bytes(), 0o700)
    hashes = {name: sha(publish_dir / name) for name in PRODUCTS}
    if hashes["prunlet"] != hashes["prunlet-hook"]:
        raise ValueError("Hook must match the CLI binary")
    result = {"runtime": runtime, "toolchain": toolchain, "cargoVersion": version.strip(),
              "executable": str(publish_dir / "prunlet"),
              "maintenanceExecutable": str(publish_dir / "prunlet-maintenance"),
              "hookExecutable": str(publish_dir / "prunlet-hook"), "sha256": hashes["prunlet"],
              "maintenanceSha256": hashes["prunlet-maintenance"], "hookSha256": hashes["prunlet-hook"]}
    return result


def download(url, maximum):
    request = urllib.request.Request(url, headers={"User-Agent": "Prunlet-macOS-Installer",
                                                  "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(request, timeout=120) as response:
        content = response.read(maximum + 1)
    if len(content) > maximum:
        raise ValueError("GitHub response exceeds its size limit")
    return content


def extract_source(archive_path, destination):
    with zipfile.ZipFile(archive_path) as archive:
        if len(archive.infolist()) > 20000:
            raise ValueError("Source archive contains too many entries")
        roots, names, total = set(), set(), 0
        for entry in archive.infolist():
            name = entry.filename
            parts = name.rstrip("/").split("/")
            if not parts or name.startswith("/") or "\\" in name or any(p in ("", ".", "..") or ":" in p or "\0" in p for p in parts):
                raise ValueError("Unsafe source archive path")
            key = name.rstrip("/").casefold()
            if key in names:
                raise ValueError("Duplicate source archive path")
            names.add(key)
            roots.add(parts[0])
            kind = stat.S_IFMT(entry.external_attr >> 16)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
                raise ValueError("Archive links and special files are forbidden")
            total += entry.file_size
            if total > 256 * 1024 * 1024:
                raise ValueError("Expanded source exceeds the installation limit")
        if len(roots) != 1:
            raise ValueError("Source archive must have exactly one root")
        mkdir_private(destination)
        archive.extractall(destination)
        source = destination / next(iter(roots))
        for relative in REQUIRED:
            if not (source / relative).is_file():
                raise ValueError(f"GitHub HEAD is not a macOS Rust source release: missing {relative}")
        return source


def install(args):
    # 初回導入のみ。既存構成・ACL・設定・旧版を推測して上書きしない。
    install_root = checked_path(args.install_directory, fresh=True)
    work = checked_path(args.work_directory, fresh=True)
    if install_root in work.parents or work in install_root.parents or install_root == work:
        raise ValueError("Install and work directories must be separate trees")
    external_backup = checked_path(args.backup_directory) if args.backup_directory else None
    if external_backup and any(external_backup == root or external_backup in root.parents or root in external_backup.parents
                               for root in (install_root, work)):
        raise ValueError("An explicit metadata directory must be separate from install and work trees")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_][A-Za-z0-9_.-]{0,99}", args.repository):
        raise ValueError("Repository must be owner/name")
    mkdir_private(work)
    repository = args.repository
    metadata = json.loads(download(f"https://api.github.com/repos/{repository}", 1024 * 1024))
    branch = metadata["default_branch"]
    if not isinstance(branch, str) or not re.fullmatch(r"[A-Za-z0-9._/-]+", branch):
        raise ValueError("GitHub default branch is invalid")
    resolved = json.loads(download(f"https://api.github.com/repos/{repository}/commits/{urllib.parse.quote(branch, safe='')}", 1024 * 1024))
    commit = resolved["sha"]
    if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("GitHub HEAD commit is invalid")
    url = f"https://codeload.github.com/{repository}/zip/{commit}"
    archive = download(url, 64 * 1024 * 1024)
    archive_path = work / "source.zip"
    write_new(archive_path, archive)
    source = extract_source(archive_path, work / "source")
    result = publish(source, str(work / "build"), args.runtime, commit)
    # native initを先に外部private領域で検証し、失敗時は導入先を作らない。
    staging = work / "configuration"
    mkdir_private(staging)
    backup = external_backup if external_backup else staging / "recovery"
    if not backup.exists():
        mkdir_private(backup)
    candidate_config = staging / "config.json"
    subprocess.run([result["executable"], "--config", str(candidate_config), "init", "--backup-directory", str(backup)], check=True, stdout=sys.stderr)
    mkdir_private(install_root)
    mkdir_private(install_root / "bin")
    if not args.backup_directory:
        backup = install_root / "recovery"
        mkdir_private(backup)
    subprocess.run([result["executable"], "--config", str(install_root / "config.json"), "init", "--backup-directory", str(backup)], check=True, stdout=sys.stderr)
    hashes = {}
    for name in PRODUCTS:
        binary = Path(result["executable"]).parent / name
        write_new(install_root / "bin" / name, binary.read_bytes(), 0o700)
        hashes[name] = sha(install_root / "bin" / name)
    provenance = {"product": "Prunlet", "schema": 1, "repository": repository, "defaultBranch": branch,
                  "commitSha": commit, "downloadUrl": url, "archiveSha256": hashlib.sha256(archive).hexdigest().upper(),
                  "runtime": args.runtime, "executableSha256": hashes["prunlet"],
                  "maintenanceExecutableSha256": hashes["prunlet-maintenance"], "hookExecutableSha256": hashes["prunlet-hook"]}
    write_new(install_root / "source-info.json", json.dumps(provenance, separators=(",", ":")).encode())
    return {"status": "installed", "installDirectory": str(install_root), "configPath": str(install_root / "config.json"),
            "commitSha": commit, "runtime": args.runtime, "workDirectory": str(work)}


def main():
    parser = argparse.ArgumentParser()
    actions = parser.add_subparsers(dest="action", required=True)
    toolchain = actions.add_parser("toolchain")
    toolchain.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parent.parent)
    build = actions.add_parser("publish")
    build.add_argument("--output-directory", required=True)
    build.add_argument("--target-directory")
    build.add_argument("--source-commit")
    setup = actions.add_parser("install")
    setup.add_argument("--install-directory", required=True)
    setup.add_argument("--work-directory", required=True)
    setup.add_argument("--backup-directory")
    setup.add_argument("--repository", default="1llum1n4t1s/Prunlet")
    for command in (build, setup):
        command.add_argument("--runtime", choices=tuple(TARGETS), required=True)
    args = parser.parse_args()
    if args.action == "toolchain":
        print(rust_toolchain(args.source_root))
        return
    if sys.platform != "darwin":
        raise ValueError("macOS native publishing and installation require macOS")
    if args.action == "publish":
        result = publish(Path(__file__).resolve().parent.parent, args.output_directory, args.runtime,
                         args.source_commit, args.target_directory)
    else:
        result = install(args)
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Prunlet macOS packaging failed: {error}", file=sys.stderr)
        sys.exit(1)

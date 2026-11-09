#!/usr/bin/env python3
"""Build all Pasta components for macOS 15, without installing a disk driver."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import platform
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
MIN_MACOS = "15.0"
VERSION = "0.2.1"
ARCH = platform.machine()
BUILD = ROOT / ".build" / ("macos15-" + ARCH)
ENGINE = BUILD / "ntfs-3g"
VENDOR = ROOT / "vendor" / "ntfs-3g-2026.9.28"
APP = ROOT / "dist" / "Pasta.app"


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def output(args):
    return subprocess.check_output([str(a) for a in args], text=True).strip()


def build(clean=False):
    if ARCH != "arm64":
        raise SystemExit("This release is built for the restored Apple Silicon Mac (arm64).")
    if not VENDOR.is_dir():
        raise SystemExit("Missing vendored NTFS-3G source.")
    try:
        sdk = output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"])
        clang = output(["/usr/bin/xcrun", "--find", "clang"])
        swift = output(["/usr/bin/xcrun", "--find", "swiftc"])
    except subprocess.CalledProcessError:
        raise SystemExit("Install Apple's Command Line Tools with xcode-select --install, then retry.")
    if clean and BUILD.exists():
        shutil.rmtree(BUILD)
    BUILD.mkdir(parents=True, exist_ok=True)
    target = ARCH + "-apple-macosx" + MIN_MACOS
    cflags = ["-O2", "-arch", ARCH, "-mmacosx-version-min=" + MIN_MACOS, "-isysroot", sdk,
              "-ffile-prefix-map=" + str(ROOT) + "=."]
    env = os.environ.copy()
    env.update(MACOSX_DEPLOYMENT_TARGET=MIN_MACOS, SDKROOT=sdk, CC=clang,
               CFLAGS=" ".join(cflags), LDFLAGS=" ".join(cflags[1:]),
               PKG_CONFIG="/usr/bin/true")
    # The toolchain, target, and source determine whether the static library is reusable.
    source_hash = hashlib.sha256()
    for path in sorted(VENDOR.rglob("*")):
        if path.is_file():
            source_hash.update(str(path.relative_to(VENDOR)).encode())
            source_hash.update(path.read_bytes())
    fingerprint = dict(target=target, sdk=sdk, clang=output([clang, "--version"]),
                       vendor_sha256=source_hash.hexdigest())
    stamp = BUILD / "engine-build.json"
    library = ENGINE / "libntfs-3g/.libs/libntfs-3g.a"
    previous = json.loads(stamp.read_text()) if stamp.is_file() else None
    if previous != fingerprint or not library.is_file():
        if ENGINE.exists():
            shutil.rmtree(ENGINE)
        shutil.copytree(VENDOR, ENGINE)
        with (BUILD / "ntfs-build.log").open("w") as log:
            run(["./configure", "--disable-ntfs-3g", "--disable-library", "--disable-plugins",
                 "--disable-mount-helper", "--disable-ldconfig", "--enable-extras"],
                cwd=ENGINE, env=env, stdout=log, stderr=subprocess.STDOUT)
            run(["/usr/bin/make", "-j4"], cwd=ENGINE, env=env, stdout=log, stderr=subprocess.STDOUT)
        stamp.write_text(json.dumps(fingerprint, indent=2))
    include = ["-DHAVE_CONFIG_H", "-I" + str(ENGINE), "-I" + str(ENGINE / "include"),
               "-I" + str(ENGINE / "include/ntfs-3g")]
    run([clang] + cflags + ["-Wno-deprecated-declarations"] + include +
        [ROOT / "Sources/import_engine.c", library, "-framework", "CoreFoundation", "-o", BUILD / "pasta-import"], env=env)
    # Probe is not built by upstream when the FUSE driver is disabled. Compile its
    # source directly against our freshly built static library, never an old binary.
    run([clang] + cflags + include + [ENGINE / "src/ntfs-3g.probe.c", library,
                                    "-framework", "CoreFoundation", "-o", BUILD / "ntfs-3g.probe"], env=env)
    if APP.exists():
        shutil.rmtree(APP)
    mac = APP / "Contents/MacOS"
    res = APP / "Contents/Resources"
    mac.mkdir(parents=True)
    res.mkdir(parents=True)
    common = [swift, "-swift-version", "5", "-O", "-target", target, "-sdk", sdk,
              "-file-prefix-map", str(ROOT) + "=.", "-debug-prefix-map", str(ROOT) + "=.",
              "-module-cache-path", BUILD / "module-cache", ROOT / "Sources/Shared.swift", ROOT / "Sources/Plan.swift"]
    run(common + [ROOT / "Sources/ImportHelper.swift", "-o", mac / "PastaImportHelper"], env=env)
    run([clang] + cflags + ["-c", ROOT / "Sources/Authorization.c", "-o", BUILD / "Authorization.o"], env=env)
    run(common + [ROOT / "Sources/App.swift", BUILD / "Authorization.o", "-import-objc-header",
                  ROOT / "Sources/Authorization.h", "-framework", "Security", "-o", mac / "Pasta"], env=env)
    for name in ("pasta-import", "ntfs-3g.probe"):
        shutil.copy2(BUILD / name, res / name)
    for name in ("PastaIcon.png", "PastaIcon.icns"):
        shutil.copy2(ROOT / "Assets" / name, res / name)
    for name in ("COPYING", "COPYING.LIB", "AUTHORS"):
        shutil.copy2(VENDOR / name, res / ("NTFS-3G-" + name))
    info = dict(CFBundleIdentifier="local.pasta.app", CFBundleName="Pasta", CFBundleDisplayName="Pasta",
                CFBundleExecutable="Pasta", CFBundlePackageType="APPL", CFBundleShortVersionString=VERSION,
                CFBundleVersion="2", CFBundleIconFile="PastaIcon", CFBundleDevelopmentRegion="zh_CN",
                CFBundleLocalizations=["zh-Hans"], LSMinimumSystemVersion=MIN_MACOS, NSHighResolutionCapable=True,
                NSDesktopFolderUsageDescription="读取你选择的文件并导入外置硬盘。",
                NSDocumentsFolderUsageDescription="读取你选择的文件并导入外置硬盘。",
                NSDownloadsFolderUsageDescription="读取你选择的文件并导入外置硬盘。",
                NSRemovableVolumesUsageDescription="把你选中的文件导入外置 NTFS 硬盘。")
    with (APP / "Contents/Info.plist").open("wb") as f:
        plistlib.dump(info, f)
    for path in (res / "pasta-import", res / "ntfs-3g.probe", mac / "PastaImportHelper", APP):
        run(["/usr/bin/codesign", "--force", "--sign", "-", path])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", APP])
    (BUILD / "build-result.json").write_text(json.dumps(dict(version=VERSION, target=target, app=str(APP),
                                                          sdk=sdk, architecture=ARCH), indent=2))
    print(APP)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clean", action="store_true")
    build(parser.parse_args().clean)

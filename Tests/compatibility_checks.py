#!/usr/bin/env python3
"""Check the finished app and compile/run its non-destructive Swift tests."""
from pathlib import Path
import json
import platform
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / ".build" / ("macos15-" + platform.machine())
APP = ROOT / "dist/Pasta.app"


def run(args):
    return subprocess.check_output([str(a) for a in args], stderr=subprocess.STDOUT, text=True)


info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
assert info["LSMinimumSystemVersion"] == "15.0"
components = [APP / "Contents/MacOS/Pasta", APP / "Contents/MacOS/PastaImportHelper",
              APP / "Contents/Resources/pasta-import", APP / "Contents/Resources/ntfs-3g.probe"]
checks = []
for binary in components:
    architecture = run(["/usr/bin/lipo", "-archs", binary]).strip()
    assert architecture == "arm64", (binary, architecture)
    load = run(["/usr/bin/otool", "-l", binary])
    minimum = re.findall(r"^\s*minos\s+(\d+\.\d+(?:\.\d+)?)\s*$", load, re.MULTILINE)
    assert minimum and all(tuple(map(int, v.split("."))) <= (15, 0, 0) for v in minimum), (binary, minimum)
    deps = [line.strip().split(" (", 1)[0] for line in run(["/usr/bin/otool", "-L", binary]).splitlines()[1:]]
    assert all(d.startswith(("/usr/lib/", "/System/Library/", "@rpath/libswift")) for d in deps), (binary, deps)
    assert not any("fuse" in d.lower() or "ntfs" in d.lower() for d in deps), (binary, deps)
    checks.append(dict(binary=binary.name, architecture=architecture, minimum_macos=minimum, dependencies=deps))
run(["/usr/bin/codesign", "--verify", "--deep", "--strict", APP])
helper = subprocess.run([str(APP / "Contents/MacOS/PastaImportHelper")], capture_output=True, text=True)
assert helper.returncode == 1 and "RESULT\tERROR\t" in helper.stdout and "授权参数无效" in helper.stdout, helper
sdk = run(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
common = ["/usr/bin/xcrun", "swiftc", "-swift-version", "5", "-target", "arm64-apple-macosx15.0",
          "-sdk", sdk, "-module-cache-path", BUILD / "module-cache", ROOT / "Sources/Shared.swift"]
for name, sources in [("rules-checks", [ROOT / "Tests/RulesTests.swift"]),
                      ("plan-checks", [ROOT / "Sources/Plan.swift", ROOT / "Tests/PlanChecks.swift"])]:
    run(common + sources + ["-o", BUILD / name])
    print(run([BUILD / name]).strip(), flush=True)
report = dict(passed=True, tested_os=platform.mac_ver()[0], version=info["CFBundleShortVersionString"],
              components=checks, code_signature_verified=True, invalid_helper_invocation_refused=True)
(BUILD / "compatibility-test-result.json").write_text(json.dumps(report, indent=2))
print("PASS: all bundled binaries target macOS 15, system-only dependencies, signature, helper guard", flush=True)

#!/usr/bin/env python3
"""Exercise the actual importer against NEW REGULAR IMAGE FILES only."""
from pathlib import Path
import hashlib, json, os, platform, plistlib, subprocess, tempfile, time

ROOT=Path(__file__).resolve().parents[1]
BUILD=ROOT/'.build'/('macos15-'+platform.machine())
UPSTREAM=BUILD/'ntfs-3g'
ENGINE=BUILD/'pasta-import'
PROBE=BUILD/'ntfs-3g.probe'
work=Path(tempfile.mkdtemp(prefix='pasta-import-test-',dir='/private/tmp'))
print('Test directory:',work,flush=True)
def run(*args,ok=True):
    p=subprocess.run(list(map(str,args)),capture_output=True,timeout=1200)
    if ok and p.returncode: raise RuntimeError(p.stdout.decode(errors='replace')+p.stderr.decode(errors='replace'))
    return p
def image(name,size):
    p=work/name
    with p.open('xb') as f: f.truncate(size)
    assert p.is_file() and not p.is_symlink() and p.parent==work
    run(UPSTREAM/'ntfsprogs/mkntfs','-F','-Q',p)
    return p
def plan(source):
    result=[]
    for p in sorted(source.rglob('*'),key=lambda p:(len(p.parts),str(p))):
        result.append(dict(source=str(p),relative=str(p.relative_to(source)),directory=p.is_dir(),size=0 if p.is_dir() else p.stat().st_size))
    dest=work/(source.name+'.plist');dest.write_bytes(plistlib.dumps(result))
    return dest
def digest(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.digest()
def target_digest(target,path):
    p=subprocess.Popen([str(UPSTREAM/'ntfsprogs/ntfscat'),str(target),path],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    h=hashlib.sha256()
    for b in iter(lambda:p.stdout.read(1024*1024),b''):h.update(b)
    err=p.stderr.read(); assert p.wait()==0,err
    return h.digest()
def invoke(target,manifest,ok=True):
    return run(ENGINE,target,os.getuid(),os.getgid(),manifest,ok=ok)

small=image('new-small.ntfs',256*1024*1024)
run(PROBE,'--readwrite',small)
old=work/'old.txt';old.write_bytes(b'Existing data must remain byte-for-byte unchanged.\n')
run(UPSTREAM/'ntfsprogs/ntfscp',small,old,'/existing.txt')
source=work/'source'
(source/'2025/中文 月份/实况').mkdir(parents=True)
(source/'2026/视频').mkdir(parents=True)
(source/'2025/中文 月份/photo.heic').write_bytes(os.urandom(8193))
(source/'2025/中文 月份/实况/live.MOV').write_bytes(os.urandom(8*1024*1024+17))
(source/'2026/视频/🍝 空格.mp4').write_bytes(os.urandom(65537))
(source/'2026/empty.txt').touch()
manifest=plan(source)
originals={p:digest(p) for p in source.rglob('*') if p.is_file()}
result=invoke(small,manifest)
assert b'VERIFIED\t4\t' in result.stdout,result.stdout
for p,h in originals.items():
    assert target_digest(small,'/'+str(p.relative_to(source)))==h
    assert digest(p)==h
assert target_digest(small,'/existing.txt')==digest(old)
print('PASS: Unicode/emoji/nested folders, empty files, byte-for-byte readback, existing/source preservation',flush=True)
# Repeating an import only verifies matching existing files; no overwrite.
invoke(small,manifest)
(source/'2026/视频/🍝 空格.mp4').write_bytes(b'changed')
conflict=invoke(small,plan(source),ok=False)
assert conflict.returncode!=0
assert target_digest(small,'/2026/视频/🍝 空格.mp4')==originals[source/'2026/视频/🍝 空格.mp4']
assert target_digest(small,'/existing.txt')==digest(old)
run(UPSTREAM/'ntfsprogs/ntfsfix','-n',small)
print('PASS: resume verification, differing existing file refused, NTFS structural check',flush=True)

invalid=work/'not-ntfs.bin';invalid.write_bytes(os.urandom(1024*1024))
before=digest(invalid);assert invoke(invalid,manifest,ok=False).returncode!=0
assert run(PROBE,'--readwrite',invalid,ok=False).returncode!=0
assert digest(invalid)==before
print('PASS: invalid filesystem refused without changes',flush=True)

large=image('new-large.ntfs',6*1024**3)
large_source=work/'large-source';(large_source/'2026').mkdir(parents=True)
video=large_source/'2026/large-video-test.mov'
with video.open('xb') as f:
    f.truncate(5*1024**3+17)
    f.seek(0);f.write(os.urandom(1024*1024))
    f.seek(4*1024**3-13);f.write(os.urandom(1024*1024))
    f.seek(-1024*1024,2);f.write(os.urandom(1024*1024))
expected=digest(video)
started=time.monotonic();invoke(large,plan(large_source))
assert target_digest(large,'/2026/large-video-test.mov')==expected
assert digest(video)==expected
run(UPSTREAM/'ntfsprogs/ntfsfix','-n',large)
print('PASS: 5 GiB + 17-byte video, >4 GiB offsets, independent SHA-256 readback; seconds:',round(time.monotonic()-started,1),flush=True)
(BUILD/'import-test-result.json').write_text(json.dumps(dict(passed=True,test_directory=str(work),large_file_bytes=video.stat().st_size,checks=['nested Unicode','emoji','empty','source preservation','existing preservation','conflict refusal','resume verification','invalid filesystem refusal','5 GiB file','independent SHA-256','NTFS structural check']),indent=2))
print('ALL PASS. Physical disks were not accessed.',flush=True)

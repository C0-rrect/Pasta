/* Local importer using the upstream NTFS-3G library. No FUSE, repair,
 * formatting, overwriting, or source deletion. GPL-2.0-or-later. */
#include "config.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <locale.h>
#include <pwd.h>
#include <grp.h>
#include <sys/stat.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CommonCrypto/CommonDigest.h>
#include "ntfs-3g/volume.h"
#include "ntfs-3g/dir.h"
#include "ntfs-3g/attrib.h"
#include "ntfs-3g/inode.h"
#include "ntfs-3g/device.h"
#include "ntfs-3g/unistr.h"
#include "ntfs-3g/logging.h"

#define CHUNK (1024 * 1024)
typedef struct { char *source, *relative; int directory; int64_t size; } Entry;
static volatile sig_atomic_t interrupted;
static uid_t owner;
static int privileged;
static uint64_t totalBytes, doneBytes, completeFiles, totalFiles;
static void stop(int s) { (void)s; interrupted = 1; }
static void fail(const char *s) { fprintf(stderr, "%s: %s\n", s, strerror(errno)); }
static char *string_value(CFTypeRef v) {
    if (!v || CFGetTypeID(v) != CFStringGetTypeID()) return NULL;
    CFIndex n = CFStringGetMaximumSizeForEncoding(CFStringGetLength(v), kCFStringEncodingUTF8) + 1;
    if (n > 32768) return NULL;
    char *s = calloc((size_t)n, 1);
    if (!s || !CFStringGetCString(v, s, n, kCFStringEncodingUTF8)) { free(s); return NULL; }
    return s;
}
static int source_open(const char *path) {
    if (privileged && seteuid(owner)) return -1;
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    int saved = errno;
    if (privileged && seteuid(0)) { if (fd >= 0) close(fd); return -1; }
    errno = saved; return fd;
}
static int valid_relative(const char *path) {
    if (!path || !*path || *path == '/' || strlen(path) > 8192) return 0;
    char *copy = strdup(path), *save = NULL, *part;
    if (!copy) return 0;
    int ok = 1, components = 0;
    for (part = strtok_r(copy, "/", &save); part; part = strtok_r(NULL, "/", &save)) {
        size_t len = strlen(part); components++;
        if (!len || !strcmp(part,".") || !strcmp(part,"..") || strpbrk(part,"<>:\"\\|?*") || part[len-1]=='.' || part[len-1]==' ') ok = 0;
        for (char *p=part; *p; p++) if ((unsigned char)*p < 32) ok = 0;
        ntfschar *u = NULL; int l = ntfs_mbstoucs(part, &u); free(u);
        if (l < 1 || l > 255) ok = 0;
    }
    if (strstr(path,"//") || path[strlen(path)-1]=='/') ok=0;
    free(copy); return ok && components;
}
static ntfs_inode *create_entry(ntfs_volume *vol, const char *path, mode_t mode) {
    char *copy = strdup(path), *base = strrchr(copy, '/');
    ntfs_inode *parent = NULL, *result = NULL;
    if (base) { *base++ = 0; parent = ntfs_pathname_to_inode(vol, NULL, copy); }
    else { base=copy; parent=ntfs_inode_open(vol, FILE_root); }
    if (!parent) { free(copy); return NULL; }
    ntfschar *u=NULL; int len=ntfs_mbstoucs(base,&u);
    if (len>0) result=ntfs_create(parent,const_cpu_to_le32(0),u,(u8)len,mode);
    int saved=errno;
    free(u); free(copy);
    if (ntfs_inode_close(parent)) { if (result) ntfs_inode_close(result); return NULL; }
    errno=saved; return result;
}
static void progress(const char *phase, const char *path) {
    // CoreFoundation handles JSON escaping in the Swift helper; emit just numbers.
    (void)path;
    printf("PROGRESS\t%s\t%llu\t%llu\t%llu\t%llu\n",phase,
           (unsigned long long)doneBytes,(unsigned long long)totalBytes,
           (unsigned long long)completeFiles,(unsigned long long)totalFiles);
    fflush(stdout);
}
static int hash_fd(int fd, int64_t size, unsigned char digest[CC_SHA256_DIGEST_LENGTH], unsigned char *buf) {
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx); int64_t at=0;
    while (at<size) {
        if (interrupted) { errno=EINTR; return -1; }
        size_t count=(size_t)((size-at)>CHUNK?CHUNK:(size-at));
        ssize_t n=pread(fd,buf,count,at);
        if (n<=0) { if (!n) errno=EIO; return -1; }
        CC_SHA256_Update(&ctx,buf,(CC_LONG)n); at+=n;
    }
    CC_SHA256_Final(digest,&ctx); return 0;
}
static int hash_ntfs(ntfs_inode *inode, int64_t size, unsigned char digest[CC_SHA256_DIGEST_LENGTH], unsigned char *buf) {
    ntfs_attr *a=ntfs_attr_open(inode,AT_DATA,AT_UNNAMED,0);
    if (!a) return -1;
    int result=-1;
    if (a->data_size!=size) { errno=EIO; goto out; }
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx); int64_t at=0;
    while (at<size) {
        if (interrupted) { errno=EINTR; goto out; }
        int64_t count=(size-at)>CHUNK?CHUNK:(size-at);
        int64_t n=ntfs_attr_pread(a,at,count,buf);
        if (n<=0) { if (!n) errno=EIO; goto out; }
        CC_SHA256_Update(&ctx,buf,(CC_LONG)n); at+=n;
    }
    CC_SHA256_Final(digest,&ctx); result=0;
out: ntfs_attr_close(a); return result;
}
static int unchanged(int fd, struct stat *before) {
    struct stat after;
    return !fstat(fd,&after) && after.st_size==before->st_size &&
        after.st_mtimespec.tv_sec==before->st_mtimespec.tv_sec && after.st_mtimespec.tv_nsec==before->st_mtimespec.tv_nsec &&
        after.st_ctimespec.tv_sec==before->st_ctimespec.tv_sec && after.st_ctimespec.tv_nsec==before->st_ctimespec.tv_nsec;
}
static int copy_file(ntfs_volume *vol, Entry *e, unsigned char *buf) {
    int result=-1, fd=source_open(e->source); ntfs_inode *inode=NULL; ntfs_attr *a=NULL;
    unsigned char sourceHash[CC_SHA256_DIGEST_LENGTH], targetHash[CC_SHA256_DIGEST_LENGTH];
    struct stat st;
    if (fd<0) return -1;
    if (fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_size!=e->size) { errno=EINVAL; goto out; }
    inode=ntfs_pathname_to_inode(vol,NULL,e->relative);
    if (inode) {
        // Existing files are read only: identical files can be resumed, conflicts stop.
        if (inode->mrec->flags & MFT_RECORD_IS_DIRECTORY) { errno=EISDIR; goto out; }
        progress("checking",e->relative);
        if (hash_fd(fd,e->size,sourceHash,buf) || hash_ntfs(inode,e->size,targetHash,buf)) goto out;
        if (memcmp(sourceHash,targetHash,sizeof(sourceHash)) || !unchanged(fd,&st)) { errno=EEXIST; goto out; }
        doneBytes+=(uint64_t)e->size; result=0; goto out;
    }
    if (errno!=ENOENT) goto out;
    inode=create_entry(vol,e->relative,S_IFREG);
    if (!inode) goto out;
    a=ntfs_attr_open(inode,AT_DATA,AT_UNNAMED,0);
    if (!a || ntfs_attr_truncate_solid(a,e->size)) goto out;
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx); int64_t at=0;
    while (at<e->size) {
        if (interrupted) { errno=EINTR; goto out; }
        size_t count=(size_t)((e->size-at)>CHUNK?CHUNK:(e->size-at));
        ssize_t n=pread(fd,buf,count,at);
        if (n<=0) { if (!n) errno=EIO; goto out; }
        int64_t written=0;
        while (written<n) {
            int64_t w=ntfs_attr_pwrite(a,at+written,n-written,buf+written);
            if (w<=0) { if (!w) errno=EIO; goto out; } written+=w;
        }
        CC_SHA256_Update(&ctx,buf,(CC_LONG)n); at+=n; doneBytes+=(uint64_t)n;
        if (at%(64*1024*1024)==0) progress("copying",e->relative);
    }
    CC_SHA256_Final(sourceHash,&ctx);
    ntfs_attr_close(a); a=NULL;
    if (!unchanged(fd,&st)) { errno=ESTALE; goto out; }
    // Preserve the source mtime. Flush metadata and storage before read-back.
    inode->last_data_change_time=cpu_to_sle64(st.st_mtimespec.tv_sec*10000000LL + st.st_mtimespec.tv_nsec/100 + NTFS_TIME_OFFSET);
    ntfs_inode_update_times(inode,0);
    if (ntfs_inode_close(inode)) { inode=NULL; goto out; } inode=NULL;
    if (vol->dev->d_ops->sync(vol->dev)) goto out;
    inode=ntfs_pathname_to_inode(vol,NULL,e->relative);
    if (!inode) goto out;
    progress("verifying",e->relative);
    if (hash_ntfs(inode,e->size,targetHash,buf) || memcmp(sourceHash,targetHash,sizeof(sourceHash))) { errno=EIO; goto out; }
    result=0;
out:
    { int saved=errno;
      if(a) ntfs_attr_close(a);
      if(inode && ntfs_inode_close(inode)) { result=-1; saved=errno; }
      close(fd); errno=saved; }
    return result;
}
int main(int argc,char **argv) {
    // The privileged Swift helper validates external-disk UUID and unmounts it.
    // Image tests use the same engine as an ordinary user, on new regular files.
    if(argc!=5) { fprintf(stderr,"usage: pasta-import target uid gid manifest.plist\n"); return 2; }
    setlocale(LC_ALL,"en_US.UTF-8"); ntfs_log_set_handler(ntfs_log_handler_stderr);
    signal(SIGTERM,stop); signal(SIGINT,stop); signal(SIGPIPE,SIG_IGN);
    char *end=NULL; unsigned long u=strtoul(argv[2],&end,10);
    if(!end || *end || u<501 || u>UINT32_MAX) return 2; owner=(uid_t)u;
    unsigned long g=strtoul(argv[3],&end,10);
    if(!end || *end || !g || g>UINT32_MAX) return 2;
    privileged=geteuid()==0;
    if(privileged) { struct passwd *p=getpwuid(owner); if(!p || p->pw_gid!=(gid_t)g || initgroups(p->pw_name,(gid_t)g) || setegid((gid_t)g)) return 2; }
    else if(getuid()!=owner || getgid()!=(gid_t)g) return 2;
    int fd=source_open(argv[4]); struct stat mst;
    if(fd<0 || fstat(fd,&mst) || !S_ISREG(mst.st_mode) || mst.st_uid!=owner || mst.st_size<=0 || mst.st_size>64*1024*1024) return 2;
    unsigned char *manifest=malloc((size_t)mst.st_size); ssize_t got=0;
    while(got<mst.st_size) { ssize_t n=read(fd,manifest+got,(size_t)(mst.st_size-got)); if(n<=0) return 2; got+=n; } close(fd);
    CFDataRef d=CFDataCreate(NULL,manifest,mst.st_size); free(manifest);
    CFPropertyListRef plan=CFPropertyListCreateWithData(NULL,d,kCFPropertyListImmutable,NULL,NULL); CFRelease(d);
    if(!plan || CFGetTypeID(plan)!=CFArrayGetTypeID()) return 2;
    CFIndex count=CFArrayGetCount((CFArrayRef)plan);
    if(count<1 || count>100000) return 2;
    Entry *entries=calloc((size_t)count,sizeof(Entry)); unsigned char *buf=malloc(CHUNK);
    if(!entries || !buf) return 2;
    for(CFIndex i=0;i<count;i++) {
        CFTypeRef r=CFArrayGetValueAtIndex((CFArrayRef)plan,i);
        if(CFGetTypeID(r)!=CFDictionaryGetTypeID()) return 2;
        entries[i].source=string_value(CFDictionaryGetValue(r,CFSTR("source")));
        entries[i].relative=string_value(CFDictionaryGetValue(r,CFSTR("relative")));
        entries[i].directory=CFDictionaryGetValue(r,CFSTR("directory"))==kCFBooleanTrue;
        CFTypeRef size=CFDictionaryGetValue(r,CFSTR("size"));
        if(!size || CFGetTypeID(size)!=CFNumberGetTypeID() || !CFNumberGetValue(size,kCFNumberSInt64Type,&entries[i].size)) return 2;
        if(!entries[i].source || entries[i].source[0]!='/' || !valid_relative(entries[i].relative) || entries[i].size<0) return 2;
        if(!entries[i].directory) { if(UINT64_MAX-totalBytes<(uint64_t)entries[i].size) return 2; totalBytes+=(uint64_t)entries[i].size; totalFiles++; }
    }
    CFRelease(plan);
    // Refuse anything already mounted, even read-only. Never enable recovery.
    unsigned long mounted=0;
    if(ntfs_check_if_mounted(argv[1],&mounted) || (mounted & NTFS_MF_MOUNTED)) { errno=EBUSY; fail("Target is mounted"); return 3; }
    ntfs_volume *vol=ntfs_mount(argv[1],NTFS_MNT_EXCLUSIVE);
    if(!vol) { fail("Cannot open NTFS safely"); return 3; }
    int result=1;
    if(NVolReadOnly(vol) || (vol->flags & VOLUME_IS_DIRTY)) { errno=EROFS; fail("Dirty/read-only NTFS refused"); goto done; }
    if(ntfs_volume_get_free_space(vol)) goto done;
    // Resume may use less space, but require enough for this fresh import.
    if((uint64_t)vol->free_clusters*(uint64_t)vol->cluster_size < totalBytes + 64*1024*1024ULL) { errno=ENOSPC; fail("Insufficient free space"); goto done; }
    progress("starting","");
    for(CFIndex i=0;i<count;i++) {
        if(interrupted) { errno=EINTR; goto done; }
        Entry *e=&entries[i];
        if(e->directory) {
            ntfs_inode *n=ntfs_pathname_to_inode(vol,NULL,e->relative);
            if(n) {
                int isdir=(n->mrec->flags & MFT_RECORD_IS_DIRECTORY)!=0;
                if(ntfs_inode_close(n) || !isdir) { errno=EEXIST; fail(e->relative); goto done; }
            } else {
                if(errno!=ENOENT || !(n=create_entry(vol,e->relative,S_IFDIR))) { fail(e->relative); goto done; }
                if(ntfs_inode_close(n)) { fail(e->relative); goto done; }
            }
        } else {
            if(copy_file(vol,e,buf)) { fail(e->relative); goto done; }
            completeFiles++; if(completeFiles%10==0 || completeFiles==totalFiles) progress("verified",e->relative);
        }
    }
    if(vol->dev->d_ops->sync(vol->dev)) { fail("Final sync failed"); goto done; }
    result=0;
done:
    if(ntfs_umount(vol,FALSE)) { fail("NTFS close failed"); result=1; }
    if(result==0) printf("VERIFIED\t%llu\t%llu\n",(unsigned long long)completeFiles,(unsigned long long)totalBytes);
    for(CFIndex i=0;i<count;i++){free(entries[i].source);free(entries[i].relative);}free(entries);free(buf);
    return result;
}

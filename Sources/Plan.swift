import Foundation
import Darwin

struct ImportEntry: Codable {
    let source: String
    let relative: String
    let directory: Bool
    let size: Int64
}
struct ImportPlan {
    let entries: [ImportEntry]
    var bytes: Int64 { entries.reduce(0) { $0 + ($1.directory ? 0 : $1.size) } }
    var files: Int { entries.filter { !$0.directory }.count }
    var roots: [String] { Array(Set(entries.map { String($0.relative.split(separator: "/")[0]) })).sorted() }
}
func validRelative(_ path: String) -> Bool {
    let parts=path.split(separator: "/", omittingEmptySubsequences: false)
    return !parts.isEmpty && parts.allSatisfy { p in
        !p.isEmpty && p != "." && p != ".." && p.utf16.count <= 255 && !p.hasSuffix(" ") && !p.hasSuffix(".") &&
        !p.unicodeScalars.contains { $0.value < 32 || "<>:\"\\|?*".unicodeScalars.contains($0) }
    }
}
func makePlan(_ roots: [URL]) throws -> ImportPlan {
    var entries: [ImportEntry]=[], destinations=Set<String>()
    let fm=FileManager.default
    func add(_ url: URL, relative: String) throws {
        let path=url.path
        guard validRelative(relative) else { throw ToolError(message:"NTFS 不支持此文件名：\(relative)") }
        let key=relative.precomposedStringWithCanonicalMapping.lowercased()
        guard destinations.insert(key).inserted else { throw ToolError(message:"目标名称重复：\(relative)") }
        var s=stat()
        guard lstat(path,&s)==0, s.st_mode & S_IFMT == S_IFDIR || s.st_mode & S_IFMT == S_IFREG else {
            throw ToolError(message:"无法导入链接或特殊文件：\(path)")
        }
        let dir=s.st_mode & S_IFMT == S_IFDIR
        guard entries.count<100000 else { throw ToolError(message:"单次导入文件数过多。") }
        entries.append(ImportEntry(source:path,relative:relative,directory:dir,size:dir ? 0:s.st_size))
        if dir {
            for child in try fm.contentsOfDirectory(at:url,includingPropertiesForKeys:nil).sorted(by:{$0.lastPathComponent<$1.lastPathComponent}) {
                if child.lastPathComponent == ".DS_Store" { continue }
                try add(child,relative:relative+"/"+child.lastPathComponent)
            }
        }
    }
    for root in roots { try add(root,relative:root.lastPathComponent) }
    return ImportPlan(entries:entries)
}

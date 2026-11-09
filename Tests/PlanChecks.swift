import Foundation

@main struct PlanChecks {
    static func main() throws {
        for bad in ["/2025", "2025/../x", "2025//x", "2025/./x", "2025/a:b", "2025/trailing.", "2025/\u{0}", "2025/" ] {
            precondition(!validRelative(bad),bad)
        }
        precondition(validRelative("2026/中文 月份/🍝 视频.mov"))
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("pasta-plan-test-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        defer{try? FileManager.default.removeItem(at:root)}
        let year=root.appendingPathComponent("2025")
        try FileManager.default.createDirectory(at:year,withIntermediateDirectories:false)
        try Data([1,2,3]).write(to:year.appendingPathComponent("视频.mov"))
        let p=try makePlan([year]);precondition(p.files==1 && p.bytes==3 && p.entries.first?.relative=="2025")
        try FileManager.default.createSymbolicLink(at:year.appendingPathComponent("link"),withDestinationURL:root)
        do{_ = try makePlan([year]);preconditionFailure("symlink accepted")}catch{}
        print("PASS: path traversal, Windows-invalid names, source symlink refusal, preservation of top-level year folders")
    }
}

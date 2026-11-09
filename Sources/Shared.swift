import Foundation
import Darwin

struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CommandResult {
    let status: Int32
    let data: Data
    var text: String { String(decoding: data, as: UTF8.self) }
}

func run(_ executable: String, _ arguments: [String]) throws -> CommandResult {
    let task = Process()
    let output = Pipe()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
    task.standardOutput = output
    task.standardError = output
    try task.run()
    let timeout = DispatchWorkItem { if task.isRunning { task.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: timeout)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    timeout.cancel()
    return CommandResult(status: task.terminationStatus, data: data)
}

func diskInfo(_ target: String) throws -> [String: Any] {
    let result = try run("/usr/sbin/diskutil", ["info", "-plist", target])
    guard result.status == 0,
          let value = try PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any]
    else { throw ToolError(message: "无法读取磁盘信息。\n" + result.text) }
    return value
}

func validDevice(_ id: String) -> Bool {
    id.range(of: "\\Adisk[0-9]+s[0-9]+\\z", options: .regularExpression) != nil
}

func validateDisk(_ info: [String: Any], id: String, uuid: String) throws {
    guard validDevice(id), info["DeviceIdentifier"] as? String == id,
          info["VolumeUUID"] as? String == uuid,
          info["Internal"] as? Bool == false,
          info["WholeDisk"] as? Bool == false,
          info["FilesystemType"] as? String == "ntfs",
          info["WritableMedia"] as? Bool == true,
          info["BusProtocol"] as? String == "USB" || info["BusProtocol"] as? String == "Thunderbolt"
    else { throw ToolError(message: "磁盘身份或格式不匹配，操作已停止。仅支持外置 USB / 雷雳 NTFS 分区。") }
}

func writerPath(_ id: String) -> String { "/Volumes/PastaWriter-" + id }

func mountedState(_ path: String) -> (mounted: Bool, writable: Bool) {
    var state = statfs()
    guard statfs(path, &state) == 0 else { return (false, false) }
    let actual = withUnsafePointer(to: &state.f_mntonname) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
    return (actual == path, actual == path && state.f_flags & UInt32(MNT_RDONLY) == 0)
}

struct Disk: Identifiable, Sendable {
    let id: String
    let uuid: String
    let name: String
    let parent: String
    let size: Int64
    let free: Int64
    let mountPath: String
    let writable: Bool
    var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .decimal) }
    var freeText: String { ByteCountFormatter.string(fromByteCount: free, countStyle: .decimal) }
}

func listDisks() throws -> [Disk] {
    let result = try run("/usr/sbin/diskutil", ["list", "-plist", "external", "physical"])
    guard result.status == 0,
          let listing = try PropertyListSerialization.propertyList(from: result.data, format: nil) as? [String: Any],
          let all = listing["AllDisks"] as? [String]
    else { throw ToolError(message: "无法列出外置磁盘。\n" + result.text) }
    return all.filter(validDevice).compactMap { id in
        guard let info = try? diskInfo("/dev/" + id),
              let uuid = info["VolumeUUID"] as? String,
              (try? validateDisk(info, id: id, uuid: uuid)) != nil else { return nil }
        let ownPath = writerPath(id)
        let ownMount = mountedState(ownPath)
        return Disk(id: id, uuid: uuid, name: info["VolumeName"] as? String ?? "NTFS 硬盘",
                    parent: info["ParentWholeDisk"] as? String ?? "",
                    size: (info["Size"] as? NSNumber)?.int64Value ?? 0,
                    free: (info["FreeSpace"] as? NSNumber)?.int64Value ?? 0,
                    mountPath: ownMount.mounted ? ownPath : info["MountPoint"] as? String ?? "",
                    writable: ownMount.mounted ? ownMount.writable : info["WritableVolume"] as? Bool ?? false)
    }
}

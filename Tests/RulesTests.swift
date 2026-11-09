import Foundation

@main
struct RulesTests {
    static func main() throws {
        let id = "disk5s2", uuid = "00000000-0000-4000-8000-000000000001"
        let disk: [String: Any] = ["DeviceIdentifier": id, "VolumeUUID": uuid,
            "Internal": false, "WholeDisk": false, "FilesystemType": "ntfs",
            "WritableMedia": true, "BusProtocol": "USB"]
        try validateDisk(disk, id: id, uuid: uuid)
        for bad in ["disk5", "disk5s2; rm -rf /", "../disk5s2", "disk5s2\n", "", "disk5s2/extra"] {
            precondition(!validDevice(bad), "Unsafe identifier accepted: \(bad)")
        }
        for (key, value) in [("Internal", true as Any), ("WholeDisk", true as Any),
                             ("FilesystemType", "apfs" as Any), ("VolumeUUID", UUID().uuidString as Any),
                             ("WritableMedia", false as Any), ("BusProtocol", "PCI-Express" as Any),
                             ("DeviceIdentifier", "disk9s2" as Any)] {
            var changed = disk
            changed[key] = value
            do { try validateDisk(changed, id: id, uuid: uuid); fatalError("Accepted unsafe disk: \(key)") }
            catch {}
        }
        precondition(!mountedState("/private/tmp/nonexistent-pasta-writer-test").mounted)
        precondition(!mountedState("/private/tmp").mounted)
        let command = try run("/usr/bin/printf", ["%s", "spaces 中文 ; $(literal)\n"])
        precondition(command.text == "spaces 中文 ; $(literal)\n")
        print("PASS: disk identity, internal-disk protection, format/media checks, argument isolation, mount detection")
    }
}

import Foundation
import Darwin

@main struct ImportHelper {
    static func finish(_ ok: Bool, _ text: String) {
        let line=text.replacingOccurrences(of:"\n",with:" · ").replacingOccurrences(of:"\r",with:"")
        print("RESULT\t\(ok ? "OK":"ERROR")\t"+line)
        fflush(stdout)
    }
    static func main() {
        do {
            let args=Array(CommandLine.arguments.dropFirst())
            guard geteuid()==0, args.count==5, validDevice(args[0]), UUID(uuidString:args[1]) != nil,
                  let uid=UInt32(args[2]),uid>=501,let gid=UInt32(args[3]),gid>0 else { throw ToolError(message:"授权参数无效。") }
            let id=args[0], uuid=args[1], manifest=args[4]
            let fd=open(manifest,O_RDONLY|O_NOFOLLOW|O_NONBLOCK)
            guard fd>=0 else { throw ToolError(message:"无法读取导入清单。") }
            let input=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            var statInfo=stat()
            guard fstat(fd,&statInfo)==0,statInfo.st_mode & S_IFMT == S_IFREG,statInfo.st_uid==uid,
                  statInfo.st_size>0,statInfo.st_size<=64*1024*1024 else { throw ToolError(message:"导入清单身份无效。") }
            let raw=try input.readToEnd() ?? Data()
            let entries=try PropertyListDecoder().decode([ImportEntry].self,from:raw)
            guard !entries.isEmpty,entries.count<=100000,entries.allSatisfy({validRelative($0.relative) && $0.source.hasPrefix("/") && $0.size>=0}) else {
                throw ToolError(message:"导入清单不合法。")
            }
            let info=try diskInfo("/dev/"+id)
            try validateDisk(info,id:id,uuid:uuid)
            guard info["WritableVolume"] as? Bool != true else { throw ToolError(message:"目标磁盘已有其他写入程序，请先关闭它。") }
            let mount=info["MountPoint"] as? String ?? ""
            guard !mount.isEmpty, !entries.contains(where:{$0.source==mount || $0.source.hasPrefix(mount+"/")}) else { throw ToolError(message:"请选择本机文件，不能把目标硬盘作为导入来源。") }
            let exe=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath()
            let res=exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
            let engine=res.appendingPathComponent("pasta-import").path
            let probe=res.appendingPathComponent("ntfs-3g.probe").path
            guard FileManager.default.isExecutableFile(atPath:engine),FileManager.default.isExecutableFile(atPath:probe) else { throw ToolError(message:"缺少导入引擎。") }
            // Freeze the validated plan in an exclusive root-owned temporary file.
            // The engine checks owner on read, so assign it to the requesting user.
            var template=Array("/private/tmp/pasta-import-plan-XXXXXX".utf8CString)
            let planFD=mkstemp(&template)
            guard planFD>=0 else { throw ToolError(message:"无法准备导入任务。") }
            let planPath=String(cString:template)
            let planFile=FileHandle(fileDescriptor:planFD,closeOnDealloc:true)
            defer { try? planFile.close(); unlink(planPath) }
            // User readability is required by the engine; root retains the pathname.
            guard fchmod(planFD,0o400)==0,fchown(planFD,uid,gid)==0 else { throw ToolError(message:"无法准备任务权限。") }
            try planFile.write(contentsOf:raw)
            try planFile.synchronize()
            let unmount=try run("/usr/sbin/diskutil",["unmount","/dev/"+id])
            guard unmount.status==0 else { throw ToolError(message:"硬盘仍被其他程序使用，请关闭 Pasta 的 Finder 窗口后重试。"+unmount.text) }
            var remountOK=false
            defer {
                if !remountOK,let current=try? diskInfo("/dev/"+id),current["VolumeUUID"] as? String==uuid {
                    _=try? run("/usr/sbin/diskutil",["mount","readOnly","/dev/"+id])
                }
            }
            try validateDisk(diskInfo("/dev/"+id),id:id,uuid:uuid)
            let check=try run(probe,["--readwrite","/dev/"+id])
            guard check.status==0 else {
                if check.status==15 {
                    throw ToolError(message:"硬盘的 NTFS 日志检查未通过。请在 Windows 完成磁盘检查并安全弹出，再接回 Mac 重试。尚未开始导入（代码 15）。")
                }
                throw ToolError(message:"NTFS 安全检查未通过（\(check.status)），未开始导入。"+check.text)
            }
            let task=Process(), output=Pipe()
            task.executableURL=URL(fileURLWithPath:engine)
            task.arguments=["/dev/"+id,String(uid),String(gid),planPath]
            task.environment=["PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LANG":"en_US.UTF-8"]
            task.standardOutput=output;task.standardError=output
            try task.run()
            var tail=Data()
            while true {
                let data=output.fileHandleForReading.availableData
                if data.isEmpty { break }
                try FileHandle.standardOutput.write(contentsOf:data)
                tail.append(data); if tail.count>16384 { tail.removeFirst(tail.count-16384) }
            }
            task.waitUntilExit()
            let resultText=String(decoding:tail,as:UTF8.self)
            let restored=try run("/usr/sbin/diskutil",["mount","readOnly","/dev/"+id])
            remountOK=restored.status==0
            guard task.terminationStatus==0,resultText.contains("VERIFIED\t") else {
                let detail=resultText.split(separator:"\n").filter{!$0.hasPrefix("PROGRESS\t")}.suffix(4).joined(separator:" · ")
                throw ToolError(message:"导入未完成。源文件与原有照片未删除；已创建的目标文件中可能有未完成文件。\(detail)")
            }
            guard remountOK else { throw ToolError(message:"文件已写入并校验，但未能重新挂载。请安全拔插后查看。") }
            finish(true,"导入完成，每个文件的 SHA-256 读回校验通过。源文件已保留。")
        } catch { finish(false,error.localizedDescription);exit(1) }
    }
}

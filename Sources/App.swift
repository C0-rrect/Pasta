import SwiftUI
import AppKit
import Darwin

@_cdecl("pasta_progress_update")
func pastaProgressUpdate(_ line: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?) {
    guard let line,let context else { return }
    let value=String(cString:line)
    let model=Unmanaged<PastaModel>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in model.updateProgress(value) }
}

@MainActor final class PastaModel: ObservableObject {
    @Published var disks:[Disk]=[]
    @Published var selectedID:String?
    @Published var roots:[URL]=[]
    @Published var plan:ImportPlan?
    @Published var busy=false
    @Published var preparing=false
    @Published var message="选择本机文件或文件夹，导入外置 NTFS 硬盘。"
    @Published var isError=false
    @Published var progress:Double=0
    @Published var detail=""
    var selected:Disk? { disks.first{$0.id==selectedID} }
    var canImport:Bool { !busy && !preparing && selected != nil && (plan?.files ?? 0)>0 }
    var hasSpace:Bool { guard let plan,let selected else {return false};return selected.free>plan.bytes+64*1024*1024 }
    func refresh() async {
        guard !busy else {return}
        do {
            disks=try await Task.detached{try listDisks().filter{!$0.mountPath.isEmpty}}.value
            if !disks.contains(where:{$0.id==selectedID}) { selectedID=disks.first(where:{$0.name=="Pasta"})?.id ?? disks.first?.id }
        } catch {message=error.localizedDescription;isError=true}
    }
    func prepare(_ chosen:[URL]) async {
        guard !busy else {return};preparing=true;plan=nil;roots=chosen;isError=false
        defer{preparing=false}
        do {
            plan=try await Task.detached{try makePlan(chosen)}.value
            message="文件将直接放在硬盘根目录，保留子目录。源文件和已有照片均保留。"
        } catch {message=error.localizedDescription;isError=true}
    }
    func choose() {
        let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=true;panel.allowsMultipleSelection=true
        panel.prompt="选择导入内容";panel.message="选择本机照片、视频或文件夹。"
        panel.begin { response in if response == .OK {Task{@MainActor in await self.prepare(panel.urls)}} }
    }
    func updateProgress(_ line:String) {
        guard busy else {return}
        let fields=line.split(separator:"\t",omittingEmptySubsequences:false)
        guard fields.count==6,let done=Int64(fields[2]),let total=Int64(fields[3]) else{return}
        progress=total>0 ? Double(done)/Double(total):0
        let copied=ByteCountFormatter.string(fromByteCount:done,countStyle:.decimal)
        let all=ByteCountFormatter.string(fromByteCount:total,countStyle:.decimal)
        detail="已写入 \(copied) / \(all) · 已校验 \(fields[4]) / \(fields[5]) 个文件"
        message=fields[1]=="verifying" || fields[1]=="checking" ? "正在读回校验，请保持硬盘连接。":"正在导入，请保持硬盘连接。"
    }
    func start() async {
        guard canImport,hasSpace,let disk=selected,let plan else{return}
        busy=true;isError=false;progress=0;detail="等待管理员授权"
        message="即将导入并逐个校验。期间硬盘会暂时从 Finder 消失，完成后自动恢复。"
        defer{busy=false}
        do {
            let taskDirectory=FileManager.default.temporaryDirectory.appendingPathComponent("pasta-import-"+UUID().uuidString,isDirectory:true)
            try FileManager.default.createDirectory(at:taskDirectory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            let manifest=taskDirectory.appendingPathComponent("plan.plist")
            let encoder=PropertyListEncoder();encoder.outputFormat = .binary
            try encoder.encode(plan.entries).write(to:manifest,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:manifest.path)
            // Retain this small manifest as an import record; no media is staged.
            guard let helper=Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("PastaImportHelper").path else {return}
            let args=[disk.id,disk.uuid,String(getuid()),String(getgid()),manifest.path]
            let context=Unmanaged.passRetained(self).toOpaque()
            let result=await Task.detached{()->String in
                var pointers=args.map{strdup($0)}+[nil]
                defer{for p in pointers{free(p)}}
                return helper.withCString{path in pointers.withUnsafeMutableBufferPointer{p in
                    guard let out=pasta_import_authorize(path,p.baseAddress!,pastaProgressUpdate,context) else{return "RESULT\tERROR\t授权失败。"}
                    defer{free(out)};return String(cString:out)
                }}
            }.value
            Unmanaged<PastaModel>.fromOpaque(context).release()
            isError = !result.hasPrefix("RESULT\tOK\t")
            message=result.split(separator:"\t",maxSplits:2,omittingEmptySubsequences:false).last.map(String.init) ?? result
            if isError {detail=""}
            if !isError {progress=1;detail="\(plan.files) 个文件已写入并校验；可在 Finder 打开硬盘。"}
            try result.write(to:taskDirectory.appendingPathComponent("result.txt"),atomically:true,encoding:.utf8)
            busy=false;await refresh()
        } catch {message=error.localizedDescription;isError=true}
    }
    func eject() async {
        guard let disk=selected,!busy else{return}
        detail=""
        do {
            let result=try await Task.detached{()->CommandResult in
                try validateDisk(diskInfo("/dev/"+disk.id),id:disk.id,uuid:disk.uuid)
                return try run("/usr/sbin/diskutil",["eject","/dev/"+disk.parent])
            }.value
            isError=result.status != 0;message=isError ? result.text:"已安全推出，可以拔下硬盘。";await refresh()
        } catch {message=error.localizedDescription;isError=true}
    }
}
@MainActor final class AppDelegate:NSObject,NSApplicationDelegate,NSWindowDelegate {
    weak var model:PastaModel?
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {model?.busy == true ? .terminateCancel:.terminateNow}
    func windowShouldClose(_ sender:NSWindow)->Bool {model?.busy != true}
}
@main struct PastaApp:App {
    @StateObject private var model=PastaModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body:some Scene {
        WindowGroup("Pasta") {
            VStack(alignment:.leading,spacing:22) {
                HStack(spacing:14) {
                    if let u=Bundle.main.url(forResource:"PastaIcon",withExtension:"png"),let icon=NSImage(contentsOf:u) {
                        Image(nsImage:icon).resizable().interpolation(.none).frame(width:64,height:64)
                    }
                    VStack(alignment:.leading,spacing:4){Text("Pasta").font(.system(size:32,weight:.bold));Text("把照片和视频带走").foregroundStyle(.secondary)}
                    Spacer();Text("自用版 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.1")").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Label("导入到",systemImage:"externaldrive")
                    Picker("",selection:$model.selectedID){ForEach(model.disks){d in Text("\(d.name) · 可用 \(d.freeText)").tag(Optional(d.id))}}.labelsHidden()
                    Button("刷新"){Task{await model.refresh()}}
                }.disabled(model.busy)
                VStack(alignment:.leading,spacing:10) {
                    HStack {Text("本机内容").font(.headline);Spacer();Button("选择文件或文件夹"){model.choose()}.disabled(model.busy || model.preparing)}
                    if model.roots.isEmpty {Text("选择要导入的照片、视频或整个文件夹。").foregroundStyle(.secondary)}
                    else {ForEach(model.roots,id:\.path){u in Label(u.lastPathComponent,systemImage:"folder").help(u.path)}}
                    if let p=model.plan {Text("\(p.files) 个文件 · \(ByteCountFormatter.string(fromByteCount:p.bytes,countStyle:.decimal))").font(.callout).foregroundStyle(.secondary)}
                    if model.preparing {ProgressView("正在统计文件…").controlSize(.small)}
                }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:14))
                Text("保留文件夹结构和源文件。已存在的同名文件只有内容完全一致时才会跳过，内容不同时停止导入。").font(.callout).foregroundStyle(.secondary)
                if model.plan != nil && model.selected != nil && !model.hasSpace {Text("可用空间不足，暂时无法开始。").foregroundStyle(.orange)}
                HStack {
                    Button(model.busy ? "正在导入…":"开始导入"){Task{await model.start()}}.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canImport || !model.hasSpace)
                    Button("打开硬盘") {if let path=model.selected?.mountPath,!path.isEmpty{NSWorkspace.shared.open(URL(fileURLWithPath:path))}}.disabled(model.busy || model.selected==nil)
                    Spacer();Button("安全推出"){Task{await model.eject()}}.disabled(model.busy || model.selected==nil)
                }
                Spacer(minLength:0)
                VStack(alignment:.leading,spacing:8) {
                    if model.busy {ProgressView(value:model.progress)}
                    Text(model.message).foregroundStyle(model.isError ? .orange:.primary).textSelection(.enabled)
                    if !model.detail.isEmpty{Text(model.detail).font(.caption).foregroundStyle(.secondary)}
                }.padding(16).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:12))
            }.padding(28).frame(minWidth:660,minHeight:560)
            .task {
                delegate.model=model
                NSApplication.shared.windows.first?.delegate=delegate
                if let u=Bundle.main.url(forResource:"PastaIcon",withExtension:"png"),let i=NSImage(contentsOf:u){NSApplication.shared.applicationIconImage=i}
                await model.refresh()
            }
        }.defaultSize(width:720,height:610)
    }
}

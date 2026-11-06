import AppKit

if CommandLine.arguments.contains("--selftest") {
    exit(SelfTest.run())
}
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    exit(SnapshotTool.run(path: CommandLine.arguments[i + 1]))
}
if let i = CommandLine.arguments.firstIndex(of: "--bench") {
    let n = i + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[i + 1]) ?? 300 : 300
    exit(SnapshotTool.bench(frames: n))
}
if let i = CommandLine.arguments.firstIndex(of: "--poses"), i + 1 < CommandLine.arguments.count {
    exit(SnapshotTool.poses(path: CommandLine.arguments[i + 1]))
}
if CommandLine.arguments.contains("--compare-backends") { exit(SnapshotTool.compareBackends()) }
if let i = CommandLine.arguments.firstIndex(of: "--crowd"), i + 1 < CommandLine.arguments.count {
    exit(SnapshotTool.crowd(path: CommandLine.arguments[i + 1]))
}
if let i = CommandLine.arguments.firstIndex(of: "--motion"), i + 1 < CommandLine.arguments.count {
    exit(SnapshotTool.motion(path: CommandLine.arguments[i + 1]))
}
if let i = CommandLine.arguments.firstIndex(of: "--face"), i + 1 < CommandLine.arguments.count {
    exit(SnapshotTool.face(path: CommandLine.arguments[i + 1]))
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

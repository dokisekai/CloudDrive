#!/usr/bin/env swift

import FileProvider

// 创建FileProviderManager实例并检查配置
let manager = NSFileProviderManager()

print("🔧 检查FileProviderManager配置...")
print("   支持的类型: \(manager.supportedTypes)")
print("   最大文件大小: \(manager.maximumItemSize)")

// 检查FileProvider扩展是否注册
print("\n🔍 检查FileProvider扩展注册状态...")

// 尝试获取已注册的扩展
print("   使用pluginkit命令检查...")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
task.arguments = ["pluginkit", "-m", "-p", "com.apple.FileProvider-nonUI"]

let pipe = Pipe()
task.standardOutput = pipe

print("\n📋 已注册的FileProvider扩展:")
do {
    try task.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    if output.isEmpty {
        print("   没有找到任何注册的FileProvider扩展")
    } else {
        print(output)
    }
    task.waitUntilExit()
} catch {
    print("   执行命令失败: \(error)")
}

print("\n🔧 尝试手动注册扩展...")
let registerTask = Process()
registerTask.executableURL = URL(fileURLWithPath: "/usr/bin/env")
registerTask.arguments = ["pluginkit", "-a", "./build/DerivedData/Build/Products/Debug/CloudDrive.app/Contents/PlugIns/CloudDriveFileProvider.appex"]

let registerPipe = Pipe()
registerTask.standardOutput = registerPipe

registerTask.standardError = registerPipe
do {
    try registerTask.run()
    let data = registerPipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    if output.isEmpty {
        print("   扩展注册成功")
    } else {
        print("   注册输出: \(output)")
    }
    registerTask.waitUntilExit()
} catch {
    print("   注册命令失败: \(error)")
}

print("\n📋 再次检查已注册的扩展...")
let checkTask = Process()
checkTask.executableURL = URL(fileURLWithPath: "/usr/bin/env")
checkTask.arguments = ["pluginkit", "-m", "-p", "com.apple.FileProvider-nonUI"]

let checkPipe = Pipe()
checkTask.standardOutput = checkPipe

do {
    try checkTask.run()
    let data = checkPipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    if output.isEmpty {
        print("   仍然没有找到FileProvider扩展")
        print("\n❌ 可能的问题:")
        print("   1. 扩展签名问题")
        print("   2. 授权配置问题")
        print("   3. 系统限制")
    } else {
        print(output)
    }
    checkTask.waitUntilExit()
} catch {
    print("   检查命令失败: \(error)")
}

exit(0)
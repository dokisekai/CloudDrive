import Foundation

let userDefaults = UserDefaults.standard
let vaultsKey = "savedVaults"

print("🔍 检查已保存的保险库...")

if let data = userDefaults.data(forKey: vaultsKey) {
    print("✅ 找到保险库数据，大小: \(data.count) 字节")
    
    do {
        // 尝试解码数据
        let vaults = try JSONDecoder().decode([VaultInfo].self, from: data)
        print("✅ 解码成功，共 \(vaults.count) 个保险库:")
        
        for vault in vaults {
            print("   - \(vault.name) (ID: \(vault.id))")
            print("     类型: \(vault.storageType)")
            print("     路径: \(vault.storagePath)")
            print("     创建时间: \(vault.createdAt)")
        }
    } catch {
        print("❌ 解码失败: \(error)")
        
        // 尝试打印原始数据
        if let jsonString = String(data: data, encoding: .utf8) {
            print("原始JSON数据: \(jsonString)")
        }
    }
} else {
    print("❌ 没有找到保存的保险库")
}

// 定义 VaultInfo 结构体用于解码
struct VaultInfo: Codable {
    let id: String
    let name: String
    let storageType: String
    let storagePath: String
    let createdAt: Date
    var webdavURL: String?
    var webdavUsername: String?
}
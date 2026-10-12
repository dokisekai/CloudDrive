import Foundation
import CloudDriveSupport

func runItemAliasStoreRegressionTests() async throws {
    print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("🧪 Running ItemAliasStore & ID Redirection Regressions")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    
    let store = ItemAliasStore.shared
    store.clear()
    
    // 1. 基本映射与直接解析
    print("\n--- 1. Testing Basic Mapping & Resolution ---")
    store.recordAlias(from: "file_old_1", to: "file_new_1")
    assert(store.resolve("file_old_1") == "file_new_1", "Direct alias must resolve to new ID")
    assert(store.resolve("file_new_1") == "file_new_1", "Unmapped target resolves to itself")
    assert(store.resolve("non_existent") == "non_existent", "Unknown ID resolves to itself")
    assert(store.hasAlias(for: "file_old_1"), "hasAlias must return true for mapped source")
    assert(!store.hasAlias(for: "file_new_1"), "hasAlias must return false for target")
    print("  ✅ PASS: Basic mapping and direct resolution verified")
    
    // 2. 链式映射与压平 (A -> B -> C -> D)
    print("\n--- 2. Testing Chained Resolution Flattening ---")
    store.recordAlias(from: "doc_v1", to: "doc_v2")
    store.recordAlias(from: "doc_v2", to: "doc_v3")
    store.recordAlias(from: "doc_v3", to: "doc_v4")
    assert(store.resolve("doc_v1") == "doc_v4", "Chained alias v1 must resolve directly to v4")
    assert(store.resolve("doc_v2") == "doc_v4", "Chained alias v2 must resolve directly to v4")
    assert(store.resolve("doc_v3") == "doc_v4", "Chained alias v3 must resolve directly to v4")
    print("  ✅ PASS: Multi-hop chain flattened to latest target ID")
    
    // 3. 循环依赖安全防环测试 (A -> B -> A)
    print("\n--- 3. Testing Cyclic Reference Protection ---")
    store.recordAlias(from: "cycle_a", to: "cycle_b")
    store.recordAlias(from: "cycle_b", to: "cycle_a") // Attempt circular mapping
    let resolvedA = store.resolve("cycle_a")
    let resolvedB = store.resolve("cycle_b")
    assert(!resolvedA.isEmpty && !resolvedB.isEmpty, "Resolution must terminate gracefully without infinite recursion")
    print("  ✅ PASS: Cyclic mapping safely defended without infinite loop")
    
    // 4. 删除与清理测试
    print("\n--- 4. Testing Alias Invalidation & Removal ---")
    store.recordAlias(from: "temp_del_src", to: "temp_del_dst")
    assert(store.resolve("temp_del_src") == "temp_del_dst")
    store.removeAlias(for: "temp_del_src")
    assert(store.resolve("temp_del_src") == "temp_del_src", "Removed source alias must resolve to itself")
    
    store.recordAlias(from: "src_clean", to: "dst_clean")
    store.removeAlias(for: "dst_clean") // Removing target should also decouple source
    assert(store.resolve("src_clean") == "src_clean", "Decoupled source alias must resolve to itself")
    print("  ✅ PASS: Invalidation and bidirectional cleanup verified")
    
    // 5. 并发压力测试
    print("\n--- 5. Testing Concurrent Thread Safety ---")
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<50 {
            group.addTask {
                for j in 0..<20 {
                    let from = "concur_\(i)_\(j)"
                    let to = "concur_\(i)_\(j + 1)"
                    store.recordAlias(from: from, to: to)
                    _ = store.resolve(from)
                }
            }
        }
    }
    print("  ✅ PASS: Concurrent multi-threaded reads/writes safely completed")
    
    store.clear()
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    print("🎉 All ItemAliasStore Regressions PASSED (5/5 passed)")
    print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
}

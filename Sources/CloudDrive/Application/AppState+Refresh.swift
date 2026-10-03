import SwiftUI
import CloudDriveCore
import CloudDriveStorage
import FileProvider
import Network

extension AppState {
    func startAutoRefreshEngine() {
        refreshScheduler.start(
            mountedVaults: { [weak self] in self?.vaults.filter(\.isMounted) ?? [] },
            refreshVault: { [weak self] id in await self?.signalFileProviderRefresh(for: id) },
            refreshAll: { [weak self] in await self?.refreshAllMountedVaults() }
        )
    }

    func stopAutoRefreshEngine() {
        refreshScheduler.stop()
    }

    func signalFileProviderRefresh(for vaultId: String) async {
        let domainIdentifier = NSFileProviderDomainIdentifier(rawValue: "vault-\(vaultId)")
        guard let targetVault = vaults.first(where: { $0.id == vaultId }) else { return }
        let domain = NSFileProviderDomain(identifier: domainIdentifier, displayName: targetVault.name)
        await EnumeratorSignaler.shared.signal(for: domain, containerItemIdentifiers: [.rootContainer, .workingSet])
    }

    func refreshAllMountedVaults() async {
        for vault in vaults where vault.isMounted {
            await signalFileProviderRefresh(for: vault.id)
        }
    }

    func syncFilesToFileProvider(vaultId: String) async {
        print("📡 AppState: Signaling File Provider to refresh vault file list: \(vaultId)")
        await signalFileProviderRefresh(for: vaultId)
        print("✅ AppState: File Provider refresh signal sent")
    }

    func registerFileProviderDomain(for vault: VaultInfo) async throws {
        try await FileProviderDomainService.shared.registerDomain(for: vault)
    }

    func refreshMountedDomains() {
        NSFileProviderManager.getDomainsWithCompletionHandler { [weak self] domains, error in
            guard let self = self, error == nil else { return }
            guard !domains.isEmpty else { return }
            Task { @MainActor in
                let activeDomainVaultIds = Set(domains.compactMap { d -> String? in
                    let raw = d.identifier.rawValue
                    if raw.hasPrefix("vault-") {
                        return String(raw.dropFirst(6))
                    }
                    return nil
                })
                
                var changed = false
                for i in 0..<self.vaults.count {
                    let isRegistered = activeDomainVaultIds.contains(self.vaults[i].id)
                    if self.vaults[i].isMounted != isRegistered {
                        self.vaults[i].isMounted = isRegistered
                        changed = true
                    }
                }
                if changed {
                    self.saveVaults()
                }
            }
        }
    }
}

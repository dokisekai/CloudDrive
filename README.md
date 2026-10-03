# CloudDrive

[English](README.md) | [简体中文](README_CN.md)

Native macOS cloud storage client built on Apple's modern File Provider framework (`NSFileProviderReplicatedExtension`). Seamlessly mounts remote cloud storage and Cryptomator-compatible vaults into macOS Finder as native virtual drives without kernel extensions (No KEXT) or third-party FUSE.

---

## ⭐️ Production Readiness & Supported Capabilities

> [!NOTE]
> **Current Capability Status**:
> - **Verified & Production-Ready**: **WebDAV** protocol storage, **Cryptomator format end-to-end encrypted vaults**, **native Finder on-demand hydration (dataless files)**, and **transactional two-way sync engine**.
> - **In Active Evolution**: Amazon S3, SMB/CIFS, and FTP protocols are currently undergoing modular driver evolution. **WebDAV** is the primary, production-ready protocol recommended for evaluation.

### Key Features

- 🛡️ **Zero-Knowledge Client-Side Encryption**: Implements the industry-standard Cryptomator vault format (AES-256-GCM data encryption, Scrypt key derivation, encrypted filenames, and dispersed directory IDs). Seamlessly interoperable with official Cryptomator desktop and mobile clients.
- ☁️ **Native On-Demand Hydration (Dataless Files)**: Vaults mount instantly by fetching only directory tree metadata, consuming near-zero local disk space. Files stream on-demand when opened or read, and can be evicted anytime via right-click "Remove Download" to reclaim disk space.
- 🔒 **Ironclad Data Integrity & Conflict Prevention**:
  - **Immutable Generations**: All edits are staged to isolated payloads before committing to the SQLite WAL transaction log, eliminating in-flight race conditions.
  - **Conditional Writes**: Remote writes enforce `If-Match` / `If-None-Match`. In the event of remote modification (HTTP 412), CloudDrive forks conflict copies rather than silently overwriting data.
  - **Tombstones & Non-Destructive Delete**: Deletions create recoverable tombstone records, retaining local restore copies for up to 30 days.
- ⚡️ **Pure Native macOS Experience**: 100% Swift & SwiftUI. Lives quietly in your menu bar, supports offline edits, and synchronizes changes automatically upon reconnection.

---

## 🧪 For Cryptomator Maintainers: How to Build & Test

This project addresses [cryptomator/cryptomator#1590](https://github.com/cryptomator/cryptomator/issues/1590) by providing a pure Swift, native Apple File Provider extension for Cryptomator vaults.

### System Requirements
- **macOS**: **macOS 15.0 (Sequoia) or later** (uses modern File Provider replicated extension APIs).
- **Architecture**: Apple Silicon (M1/M2/M3/M4) or Intel (x86_64).
- **Xcode**: Xcode 16+ with Command Line Tools.

### 1. One-Click Build & Install (Automatic Code Signing)

**No paid Apple Developer account is required!** 

In the repository root, run:

```bash
./scripts/install.sh
```

**How code signing and installation are handled automatically:**
1. **Resolves & Patches Dependencies**: Resolves Swift Package Manager dependencies and applies the `cryptolib-swift` fix.
2. **Builds Binaries**: Compiles `CloudDrive.app` and the File Provider extension `CloudDriveFileProvider.appex`.
3. **Smart Code Signing**:
   - Checks Keychain for a local `Apple Development` certificate.
   - If no paid/personal certificate is found, it falls back to **ad-hoc self-signing (`-`)**.
   - Strictly signs from inside-out: Frameworks $\to$ Extension with `CloudDriveFileProvider.entitlements` $\to$ Main App with `CloudDrive.entitlements` (injecting App Sandbox and App Group `group.net.aabg.CloudDrive`).
4. **System Registration**: Installs to `/Applications/CloudDrive.app`, registers the extension via `pluginkit`, restarts `fileproviderd`, and launches the application.

> **Building via Xcode GUI instead?**  
> If opening `CloudDrive.xcodeproj` in Xcode, select the `CloudDrive` target and `CloudDriveFileProvider` target under **Signing & Capabilities**, select your **Personal Team** (free Apple ID), and build with scheme `CloudDrive`.

### 2. Run the Automated Test Suite

Run the automated test suite covering crypto pipelines, sync state machine, and database transactions:

```bash
./scripts/test.sh
```

### 3. Verify with a Cryptomator Vault

1. Open `/Applications/CloudDrive.app` or click the menu bar status icon;
2. Click **"+"** (New Vault) -> **"Create Encrypted Vault"** (or **"Open Existing Vault"**);
3. Enter your WebDAV server endpoint (e.g. Nextcloud, Apache, Nginx, or Alist), username, password, and master passphrase;
4. Click **"Create & Unlock"**;
5. **Observe native Finder integration**:
   - The virtual drive mounts under Finder's sidebar **"Locations"**;
   - All files appear as **☁️ dataless placeholders** (0-byte local disk usage);
   - Double-clicking streams and materializes the file on-demand with native progress rings;
   - Right-clicking any file and choosing **"Remove Download"** immediately evicts local cache and reclaims disk space.

---

## Project Structure

```text
Sources/
  CloudDrive/              SwiftUI main application & menu bar interface
  CloudDriveCore/          Core domain facade & vault lifecycle service
  CloudDriveFileProvider/  macOS File Provider extension (Finder integration)
  CloudDriveStorage/       Multi-protocol storage drivers (WebDAV ready / S3, SMB, FTP)
  CloudDriveCrypto/        Cryptomator-compatible E2E encryption (AES-GCM + Scrypt)
  CloudDrivePersistence/   SQLite WAL database, schema migrations & repositories
  CloudDriveCache/         Two-tier cache engine, immutable payloads & lease eviction
  CloudDriveSync/          Authoritative sync engine, conditional writes & conflict forking
  CloudDriveRecovery/      Recycle bin & soft-delete tombstone lifecycle manager
  CloudDriveVFS/           Virtual file system routing (direct & encrypted mappings)
  CloudDriveContracts/     Domain protocols, data contracts & constants
  CloudDriveSupport/       Logging, paths layout & global preferences
Tests/
  CloudDriveCoreTests/     Reliability regressions & unit test suites
scripts/
  install.sh              Automated build, sign, and install script
  test.sh                 Test execution script
  patches/                Upstream package patches
docs/
  usage-guide.md          📖 Usage & Verification Guide (English)
  usage-guide_CN.md       📖 Usage Guide (中文)
  architecture.md         System Architecture & Process Topology
  sync-specification.md   Sync Engine & State Machine Specification (DDL/WAL)
  data-safety-review.md   Data Safety Review & Risk Register
  storage-matrix.md       Storage Capabilities & Protocol Matrix
  modularization-plan.md  Modular Architecture Evolution Design
CloudDrive.xcodeproj/      Xcode project configuration
Package.swift              Swift Package configuration
LICENSE                    MIT License
```

---

## Technical Documentation

- 📖 **[Usage & Verification Guide](docs/usage-guide.md)** | **[使用指南 (中文)](docs/usage-guide_CN.md)**
- 📐 **[System Architecture](docs/architecture.md)**: Process topology, module boundaries, and data flows.
- ⚙️ **[Sync Specification](docs/sync-specification.md)**: State machine, immutable generations, conditional headers, and conflict resolution.
- 🛡️ **[Data Safety Review](docs/data-safety-review.md)**: Risk register (S01~S26) and data integrity verification matrix.
- 📊 **[Storage Protocol Matrix](docs/storage-matrix.md)**: Detailed comparison across WebDAV, S3, SMB, and FTP capabilities.

---

## License

This project is open-source under the [MIT License](LICENSE).

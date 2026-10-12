# CloudDrive

> **Native macOS File Provider for Cryptomator + WebDAV — encrypted files appear directly in Finder and download only when opened. Free and open source.**  
> 🔗 **GitHub**: [https://github.com/dokisekai/CloudDrive](https://github.com/dokisekai/CloudDrive)

[English](README.md) | [简体中文](README_CN.md)

Built on Apple's modern File Provider framework (`NSFileProviderReplicatedExtension`). Seamlessly mounts remote WebDAV storage and official Cryptomator end-to-end encrypted vaults into macOS Finder as native virtual drives — without kernel extensions (No KEXT) or third-party FUSE.

---

## ⭐️ Production Readiness & Supported Capabilities

> [!NOTE]
> **Current Capability Status**:
> - **Verified & Production-Ready**: **WebDAV** protocol storage, **Cryptomator format end-to-end encrypted vaults**, **native Finder on-demand hydration (dataless files)**, and **transactional two-way sync engine**.
> - **WebDAV only**: S3, SMB/CIFS, FTP, 123 Pan and local-folder connections are disabled. Historical configurations are retained but are not automatically mounted.

### Key Features

- 🛡️ **100% Compatible with Official Cryptomator Standards**:
  - **Two-Way Seamless Interoperability**: Open existing vaults created by official Cryptomator desktop (macOS / Windows / Linux) or mobile (iOS / Android) apps directly; vaults created within CloudDrive can be opened and modified by official Cryptomator apps without friction.
  - **Strict Adherence to Cryptomator Specification**: Implements Vault Format 7/8/9 specifications (AES-256-GCM authenticated chunk encryption, Scrypt key derivation, RFC 4648 Base32 filename encryption, long name hashing, and two-level `d/` directory flattening with `dir.c9r` pointer mapping).
  - **Modern Pure Swift Architecture**: Directly uses the official `cryptolib-swift` cryptographic foundation, bypassing JVM/Java runtime overhead and memory leaks.
- 🌐 **The Ultimate Combo: Alist + Cryptomator + CloudDrive**:
  - **Universal Cloud Aggregation**: Pair with [Alist](https://github.com/alist-org/alist) to bridge 30+ storage providers (OneDrive, Google Drive, Baidu, Quark, 115, PikPak, Aliyun Drive, S3, etc.) into unified WebDAV endpoints.
  - **Zero-Knowledge Security on Any Cloud**: Deploy Cryptomator vaults on top of any storage backend through Alist. Cloud providers only store encrypted, obfuscated chunks, rendering files inaccessible to cloud surveillance or leaks.
  - **Native Streaming without Local Footprint**: Multi-terabyte remote vaults appear instantaneously in macOS Finder, streaming on-demand and evicting local cache at will.
- ☁️ **Native On-Demand Hydration (Dataless Files)**: Vaults mount instantly by fetching only directory tree metadata, consuming near-zero local disk space. Files stream on-demand when opened or read, and can be evicted anytime via right-click "Remove Download" to reclaim disk space. Directly solves [cryptomator/cryptomator#1590](https://github.com/cryptomator/cryptomator/issues/1590) with Apple's modern File Provider framework.
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
- **Architecture**: **Universal 2 Architecture** (native support for both Apple Silicon `arm64` and Intel `x86_64`).
- **Xcode**: Xcode 16+ (only required if building from source).

### 1. Installation & Local Activation

**No paid Apple Developer account is required!**

#### Option A: Pre-built Package (No Xcode Required, Recommended for End Users)
> Official release packages are pre-compiled as **Universal Binaries** containing native slices for both `arm64` and `x86_64`.

1. Download `CloudDrive-macOS-Release.zip` from Releases, unzip, and move `CloudDrive.app` into `/Applications`;
2. Run the bundled activation script in Terminal:
   ```bash
   bash activate.sh
   # Or from the cloned repo: ./scripts/activate.sh
   ```

#### Option B: Build from Source (For Developers with Xcode 16+)
In the repository root, run:
```bash
./scripts/install.sh
# To build a Universal (arm64 + x86_64) binary from source:
# ./scripts/install.sh --universal
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

### 4. Complete Uninstall & Cache Cleanup (Reset & Uninstall)

To completely uninstall CloudDrive and wipe all caches, databases, credentials, and virtual drives:

```bash
./scripts/uninstall.sh
```

**Common options:**
- `./scripts/uninstall.sh --dry-run`: Preview all files and items that will be cleared without deleting anything;
- `./scripts/uninstall.sh --keep-app`: **One-click reset mode** — keeps `/Applications/CloudDrive.app` but wipes all local caches, databases, settings, and keychain items to reset the app to factory default;
- `./scripts/uninstall.sh --dev`: Also purges Xcode DerivedData and local SPM build caches;
- `./scripts/uninstall.sh -y`: Non-interactive mode (skips confirmation prompts).

**What gets cleaned:**
1. Terminates running CloudDrive and FileProvider extension processes;
2. Unregisters PlugInKit system extension and LaunchServices database associations;
3. Clears App Group (`group.net.aabg.CloudDrive`) cache chunks, VFS database, thumbnails, and trash;
4. Cleans Sandbox Containers (`~/Library/Containers`), Application Scripts, and Application Support;
5. Resets UserDefaults domains, HTTPStorages, and WebKit cache;
6. Purges saved vault passwords from macOS Keychain;
7. Resets TCC privacy permissions and restarts `fileproviderd` & Finder to remove sidebar mounts.

---

## Project Structure

```text
Sources/
  CloudDrive/              SwiftUI main application & menu bar interface
  CloudDriveCore/          Core domain facade & vault lifecycle service
  CloudDriveFileProvider/  macOS File Provider extension (Finder integration)
  CloudDriveStorage/       Storage drivers (WebDAV enabled; historical types retained)
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
  activate.sh             Local activation & re-signing script (no Xcode needed)
  install.sh              Automated build, sign, and install script (from source)
  uninstall.sh            Complete uninstall, cache wipe, and keychain cleanup
  package.sh              Release packaging script (Universal arm64+x86_64 zip)
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

# CloudDrive Usage & Verification Guide

[English](usage-guide.md) | [简体中文](usage-guide_CN.md)

This document provides a comprehensive guide on building, installing, configuring, and verifying **CloudDrive** on macOS, specifically tailored for testing Apple File Provider integration with Cryptomator-compatible vaults.

---

## 1. Supported Capabilities & Architecture

> [!IMPORTANT]
> **Production Readiness Statement**:
> - **Fully Tested & Verified**: **WebDAV** storage backend, **Cryptomator format end-to-end encryption** (AES-256-GCM + Scrypt via `cryptolib-swift`), **macOS File Provider native on-demand hydration (dataless placeholders)**, and **SQLite WAL two-way sync engine**.
> - **In Active Evolution**: Amazon S3, SMB/CIFS, and FTP backends are currently undergoing modular driver evolution. **WebDAV** is the primary, production-ready protocol recommended for evaluation.

### Core Capability Matrix

| Feature / Subsystem | Status | Technical Details |
| :--- | :---: | :--- |
| **Cryptomator Vault Format** | ✅ Ready | Compliant with Cryptomator specification (AES-256-GCM, Scrypt key derivation, encrypted filenames, `d/` dispersed directory IDs). 100% interoperable with official Cryptomator desktop and mobile clients. |
| **WebDAV Storage Backend** | ✅ Ready | Conforms strictly to RFC 4918. Tested with Nextcloud, Apache, Nginx, Alist, and Synology WebDAV. |
| **Dataless Placeholders (☁️)** | ✅ Ready | Leverages Apple's modern `NSFileProviderReplicatedExtension`. Vault mounts display the entire folder tree with zero initial local disk usage. |
| **On-Demand Hydration** | ✅ Ready | Streaming file materialization via `fetchContents` upon opening or reading. |
| **Cache Eviction & Space Reclamation** | ✅ Ready | Native Finder support for "Remove Download" (`allowsEvicting` / `NSFileProviderContentPolicy`). Local files safely revert to dataless placeholders. |
| **Conflict & Crash Resilience** | ✅ Ready | SQLite WAL journal, immutable generation IDs for staged writes, conditional updates (`If-Match`), and automatic conflict forking upon HTTP 412. |

---

## 2. Prerequisites & Environment

- **Operating System**: **macOS 15.0 (Sequoia) or later**.
- **Architecture**: Apple Silicon (M1/M2/M3/M4) or Intel (x86_64).
- **Tools**: Xcode 16+ (with Command Line Tools installed).
- **Code Signing**: **No paid Apple Developer account is required**. The automated build script handles local code signing and sandboxed App Group entitlements automatically (using ad-hoc signing `-` as fallback).

---

## 3. One-Click Build & Installation

You can build, sign, and install the complete app and its File Provider system extension with a single script:

```bash
./scripts/install.sh
```

### What `install.sh` does automatically:
1. Detects `xcodebuild` and developer toolchain;
2. Resolves Swift Package Manager dependencies;
3. Applies upstream patches if necessary (e.g. `cryptolib-swift` crypto loop patch);
4. Compiles `CloudDrive.app` and `CloudDriveFileProvider.appex`;
5. Signs binaries with your local Apple Development certificate or local ad-hoc (`-`) with required sandboxing and App Group entitlements (`group.net.aabg.CloudDrive`);
6. Copies the bundle to `/Applications/CloudDrive.app`;
7. Registers the extension via `pluginkit` and refreshes `fileproviderd` and Finder;
8. Launches `/Applications/CloudDrive.app`.

---

## 4. Running the Automated Test Suite

To verify the sync engine, crypto layer, and regression safety:

```bash
./scripts/test.sh
```

This runs `CloudDriveTestsRunner` containing tests for:
- Cryptographic vault creation and decryption pipelines;
- WebDAV HTTP methods, retries, and ETag conditional writes;
- Concurrent operations and database transaction safety;
- Cache lease eviction and recycle bin safety.

---

## 5. Walkthrough: Testing with a Cryptomator Vault

### Scenario A: Creating a New Encrypted Vault

1. Open `/Applications/CloudDrive.app` (or click the menu bar status icon);
2. Click **"+"** or **"New Vault"**;
3. Choose **"Create Encrypted Vault"**;
4. Enter your WebDAV server details:
   - **Server URL**: e.g., `https://dav.example.com/remote.php/webdav/`
   - **Username & Password**: Your credentials
   - **Remote Directory**: Target directory path on the server (e.g., `/MyCryptomatorVault`)
5. Configure vault parameters:
   - **Vault Name**: Name shown in the Finder sidebar (e.g., `SecureFiles`)
   - **Master Passphrase**: Encryption password
6. Click **"Create & Unlock"**.
   - CloudDrive initializes the Cryptomator vault structure (`masterkey.cryptomator`, `vault.cryptomator`, `d/` directories) on WebDAV;
   - The virtual drive mounts immediately in the Finder sidebar under **"Locations"**.

### Scenario B: Opening an Existing Cryptomator Vault

If you already have a vault created by Cryptomator official desktop or mobile apps:
1. Click **"New Vault"** -> **"Open Existing Vault"**;
2. Provide your WebDAV server URL and point to the folder containing `vault.cryptomator`;
3. Enter the existing master passphrase;
4. Click **"Unlock & Mount"**. The files will be instantly browsable in Finder.

---

## 6. Verifying Finder File Provider Capabilities

Once mounted, verify the native macOS experience:

1. **Verify Dataless Placeholders (☁️)**:
   - Browse into the mounted vault in Finder.
   - Files initially display with the cloud icon (☁️) and report their full file size, while consuming 0 bytes of actual disk space.
2. **Verify On-Demand Hydration**:
   - Double-click any file (e.g., image, PDF, video).
   - Finder shows the circular downloading progress indicator.
   - The file opens seamlessly once hydrated.
3. **Verify Space Eviction (Free up space)**:
   - Right-click any hydrated file or folder in Finder.
   - Select **"Remove Download"** (移除下载内容).
   - The file instantly returns to a ☁️ dataless placeholder, releasing physical disk space.
4. **Verify Offline Editing & Auto-Sync**:
   - Disconnect Wi-Fi.
   - Modify a previously downloaded file and save it.
   - The change is safely committed to local SQLite WAL.
   - Reconnect Wi-Fi: CloudDrive automatically uploads the new version with conditional `If-Match` headers.

---

## 7. Troubleshooting & FAQ

### Q1: The vault doesn't show up in Finder sidebar?
1. Open Finder -> Preferences/Settings -> **Sidebar**, and ensure **"Cloud Storage"** (云端宗卷) is checked.
2. Verify extension registration:
   ```bash
   pluginkit -m -v -i net.aabg.CloudDrive.FileProvider
   ```
3. Restart system FileProvider and Finder services:
   ```bash
   killall -9 fileproviderd Finder
   ```

### Q2: Clean Uninstall & Reset
To completely remove the app, local cache, and SQLite databases:
```bash
killall -9 CloudDrive CloudDriveFileProvider 2>/dev/null || true
sudo rm -rf /Applications/CloudDrive.app
rm -rf ~/Library/Group\ Containers/group.net.aabg.CloudDrive
```

# CloudDrive - WebDAV Cloud Storage Mount System

A WebDAV cloud storage mounting solution designed specifically for Apple devices, enabling direct mounting of WebDAV servers to the macOS sidebar for a seamless file access experience similar to iCloud.

## 📋 Project Overview

CloudDrive is a native macOS application that leverages Apple's File Provider framework to mount remote WebDAV servers as a local file system. Users can access cloud files as if they were local files, with the system automatically handling file downloads, caching, and synchronization.

### 🎯 Design Goals

- **Native macOS Integration**: Mount to Finder sidebar with deep system integration
- **Transparent File Access**: Direct WebDAV path mapping without complex encryption layers
- **Intelligent Cache Management**: Automatic caching of frequently used files to save bandwidth and storage
- **Future iOS Support**: Architecture designed with future iOS expansion in mind

### ⚠️ Current Status

**In Development** - Core features implemented, but still being refined:

✅ **Implemented Features**:
- WebDAV server connection and authentication
- Browse, create, upload, download, and delete files/directories
- Local file caching (LRU strategy, max 10GB)
- macOS Finder sidebar mounting
- Direct path mapping (WebDAV path ↔ Local path)
- Basic sync status management

🚧 **Features in Progress**:
- Cloud-to-local automatic sync logic
- File change monitoring and incremental sync
- Conflict resolution mechanism
- Offline mode optimization
- iOS client support

## 🏗️ System Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    macOS Finder                         │
│         (Users access files via sidebar)                │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│           File Provider Extension                       │
│  • Handle Finder file operation requests                │
│  • Manage file enumeration and metadata                 │
│  • Coordinate caching and downloads                     │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│              Virtual File System (VFS)                  │
│  • Direct WebDAV path mapping                           │
│  • Manage file metadata                                 │
│  • Coordinate storage client                            │
└────────────────────┬────────────────────────────────────┘
                     │
        ┌────────────┴────────────┐
        ▼                         ▼
┌──────────────────┐    ┌──────────────────┐
│  Cache Manager   │    │  WebDAV Client   │
│  • LRU strategy  │    │  • HTTP requests │
│  • Local storage │    │  • Auth mgmt     │
│  • Cache cleanup │    │  • File transfer │
└──────────────────┘    └────────┬─────────┘
                                 │
                                 ▼
                        ┌──────────────────┐
                        │  WebDAV Server   │
                        │  (Remote Storage)│
                        └──────────────────┘
```

## 📦 Project Structure

```
CloudDrive/
├── CloudDrive/                      # Main application
│   ├── CloudDriveApp.swift         # App entry point
│   ├── ContentView.swift           # Main interface
│   ├── CreateVaultView.swift       # Create vault interface
│   ├── SettingsView.swift          # Settings interface
│   └── AppState.swift              # App state management
│
├── CloudDriveCore/                  # Core framework (shared code)
│   ├── VirtualFileSystem.swift     # Virtual file system core
│   ├── WebDAVClient.swift          # WebDAV client
│   ├── StorageClient.swift         # Storage abstraction layer
│   ├── CacheManager.swift          # Cache manager
│   ├── SyncManager.swift           # Sync manager
│   ├── VFSDatabase.swift           # Local database
│   ├── Logger.swift                # Logging system
│   └── KeychainService.swift       # Keychain service
│
├── CloudDriveFileProvider/          # File Provider extension
│   ├── FileProviderExtension.swift # Extension main class
│   ├── FileProviderItem.swift      # File item model
│   └── Info.plist                  # Extension configuration
│
└── CloudDrive.xcodeproj/            # Xcode project files
```

## 🚀 Quick Start

### System Requirements

- **macOS**: 14.0 (Sonoma) or later
- **Xcode**: 15.0 or later
- **Swift**: 5.9 or later
- **WebDAV Server**: Any server supporting standard WebDAV protocol

### Installation Steps

#### 1. Clone the Project

```bash
git clone <repository-url>
cd CloudDrive
```

#### 2. Configure Project

```bash
# Configure App Group and code signing
./configure_project.sh
```

#### 3. Build Project

Open `CloudDrive.xcodeproj` in Xcode:

```bash
open CloudDrive.xcodeproj
```

Or build via command line:

```bash
xcodebuild clean build -project CloudDrive.xcodeproj -scheme CloudDrive
```

#### 4. Run Application

1. Select `CloudDrive` scheme in Xcode
2. Click Run button (Cmd+R)
3. Application will launch and display main interface

### Configure WebDAV Server

#### Using Existing WebDAV Server

If you already have a WebDAV server (like Nextcloud, ownCloud, Synology NAS, etc.), simply use its WebDAV address.

#### Local Test Server (Optional)

The project includes a simple Node.js WebDAV test server:

```bash
cd WebServer
npm install
npm start
```

Default configuration:
- Address: `http://localhost:3000`
- Username: `admin`
- Password: `password`

### Create and Mount Vault

1. **Launch Application**: Run CloudDrive app

2. **Create Vault**:
   - Click "Create New Vault" button
   - Enter vault name (e.g., "My Cloud Drive")
   - Enter WebDAV server information:
     - Server address: `http://your-server:port/webdav`
     - Username: Your WebDAV username
     - Password: Your WebDAV password
   - Click "Create"

3. **Mount to Finder**:
   - After successful creation, vault will auto-mount
   - Open Finder, find "CloudDrive" in sidebar
   - Now you can access cloud files like local folders!

## 💡 Usage Guide

### Basic Operations

#### Browse Files
- Click "CloudDrive" in Finder sidebar
- Browse cloud files like local folders
- Folders and files load in real-time from WebDAV server

#### Upload Files
- Drag and drop files to CloudDrive folder
- Or use copy-paste (Cmd+C / Cmd+V)
- Files automatically upload to WebDAV server

#### Download Files
- Double-click file to open (auto-download)
- Files cache locally for faster next access
- Cache stored at: `~/Library/Caches/com.clouddrive.app/`

#### Create Folders
- Right-click in CloudDrive → "New Folder"
- Folder immediately created on WebDAV server

#### Delete Files
- Select file → Right-click → "Move to Trash"
- Or press Cmd+Delete
- File deleted from WebDAV server

### Cache Management

#### Cache Strategy
- **Auto Cache**: Opened files automatically cached
- **LRU Eviction**: Automatically removes least recently used files when cache full
- **Max Capacity**: Default 10GB (adjustable in settings)

#### View Cache Status
```bash
# View cache directory
open ~/Library/Caches/com.clouddrive.app/

# Check cache size
du -sh ~/Library/Caches/com.clouddrive.app/
```

#### Clear Cache
```bash
# Clear all cache
rm -rf ~/Library/Caches/com.clouddrive.app/
```

### Sync Status

File sync status icons:
- ☁️ **Cloud Only**: File not downloaded locally
- ✅ **Synced**: File downloaded and synced with cloud
- 🔄 **Syncing**: Currently uploading or downloading
- ⚠️ **Pending Sync**: Waiting for network recovery to sync

## 🔧 Technical Details

### File Provider Framework

CloudDrive uses Apple's File Provider framework for system-level integration:

- **NSFileProviderReplicatedExtension**: Handles file operation requests
- **NSFileProviderEnumerator**: Enumerates directory contents
- **NSFileProviderItem**: Represents files and folders

### Direct Path Mapping

For simplicity, CloudDrive uses direct path mapping strategy:

```
WebDAV Path          →  Local Identifier
/folder/file.txt    →  /folder/file.txt
/documents/         →  /documents/
```

Benefits of this design:
- Simple implementation, easy to understand and maintain
- Transparent paths, convenient for debugging
- No complex ID mapping tables needed

### Cache Mechanism

```swift
// LRU cache strategy
class CacheManager {
    // Max cache size: 10GB
    private let maxCacheSize: Int64 = 10 * 1024 * 1024 * 1024
    
    // Cache policies
    enum CachePolicy {
        case automatic  // Auto-managed
        case pinned     // Pinned (won't be cleaned)
        case temporary  // Temporary (priority cleanup)
    }
}
```

### WebDAV Client

Supports standard WebDAV operations:

- **PROPFIND**: List directory contents
- **GET**: Download files
- **PUT**: Upload files
- **MKCOL**: Create directories
- **DELETE**: Delete files/directories
- **MOVE**: Move/rename

### Data Storage

#### Local Database
```
~/Library/Application Support/CloudDrive/
└── vaults/
    └── [vault-id]/
        └── vault.db  # SQLite database
```

Stored content:
- File and directory metadata
- Sync status
- Cache index

#### Cache Files
```
~/Library/Caches/com.clouddrive.app/
└── cache/
    └── [file-id]  # Actual file content
```

## 🐛 Troubleshooting

### File Provider Not Showing

If CloudDrive doesn't appear in Finder sidebar:

```bash
# 1. Check File Provider status
pluginkit -m -p com.apple.FileProvider-nonUI

# 2. Enable extension
pluginkit -e use -i net.aabg.CloudDrive.FileProvider

# 3. Restart Finder
killall Finder
```

### WebDAV Connection Failed

Checklist:
1. ✅ Is WebDAV server address correct?
2. ✅ Are username and password correct?
3. ✅ Is server accessible? (ping test)
4. ✅ Does firewall allow connection?
5. ✅ Is WebDAV service enabled?

Test connection:
```bash
# Test with curl
curl -u username:password -X PROPFIND http://your-server/webdav/
```

### File Upload Failed

Possible causes:
- Network connection interrupted
- Server out of space
- Insufficient permissions
- Filename contains illegal characters

View logs:
```bash
# View system logs
log stream --predicate 'subsystem == "net.aabg.CloudDrive"' --level debug

# View application logs
open ~/.CloudDrive/Logs/
```

### Cache Issues

If encountering cache-related problems:

```bash
# Clear cache
rm -rf ~/Library/Caches/com.clouddrive.app/

# Reset database
rm -rf ~/Library/Application\ Support/CloudDrive/

# Restart application
```

## 📊 Performance Optimization

### Cache Optimization Tips

1. **Adjust cache size**: Based on available disk space
2. **Pin frequently used files**: Mark as `pinned`
3. **Regular cleanup**: Manually clean unnecessary cache

### Network Optimization

1. **Use wired connection**: More stable than Wi-Fi
2. **Choose nearby server**: Reduce latency
3. **Avoid peak hours**: Sync large files during off-peak times

## 🔐 Security

### Data Transmission

- **HTTPS Support**: Recommended to use HTTPS for WebDAV connections
- **Basic Authentication**: Uses HTTP Basic Authentication
- **Password Storage**: Passwords securely stored in macOS Keychain

### Local Data

- **Cache Encryption**: Cache files stored in plaintext (encryption support in future versions)
- **Permission Control**: Protected using macOS file system permissions
- **Sandbox Isolation**: Application runs in sandboxed environment

### Security Recommendations

1. ✅ Use HTTPS instead of HTTP
2. ✅ Use strong passwords
3. ✅ Change passwords regularly
4. ✅ Don't use on public networks
5. ✅ Enable server-side encryption (if supported)

## 🛣️ Roadmap

### Near-term Plans (v1.0)

- [ ] Complete cloud-to-local auto sync
- [ ] Implement file change monitoring
- [ ] Add conflict resolution mechanism
- [ ] Optimize cache strategy
- [ ] Improve error handling and user prompts

### Mid-term Plans (v1.5)

- [ ] Support file encryption (end-to-end)
- [ ] Multiple vault management
- [ ] Selective sync (like iCloud)
- [ ] Enhanced offline mode
- [ ] Performance monitoring and statistics

### Long-term Plans (v2.0)

- [ ] iOS client support
- [ ] iPadOS optimization
- [ ] File sharing features
- [ ] Version history
- [ ] Collaboration features

## 📝 Development Guide

### Build Requirements

- macOS 14.0+
- Xcode 15.0+
- Swift 5.9+
- CocoaPods or Swift Package Manager

### Project Configuration

```bash
# 1. Configure App Group
# Set App Group in Xcode: group.net.aabg.CloudDrive

# 2. Configure code signing
# Use your Apple Developer account

# 3. Configure File Provider Extension
# Ensure Extension Bundle ID is correct
```

### Debugging Tips

#### View Logs
```bash
# Real-time log viewing
log stream --predicate 'subsystem == "net.aabg.CloudDrive"' --level debug

# View File Provider logs
log show --predicate 'subsystem == "com.apple.FileProvider"' --last 1h
```

#### Debug File Provider
```bash
# Attach debugger to File Provider Extension
lldb -p $(pgrep -f CloudDriveFileProvider)
```

### Contribution Guidelines

Contributions welcome! Please follow these steps:

1. Fork the project
2. Create feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to branch (`git push origin feature/AmazingFeature`)
5. Open Pull Request

### Code Standards

- Use official Swift code style
- Add necessary comments
- Write unit tests
- Update documentation

## 📄 License

This project is licensed under the MIT License - see [LICENSE](LICENSE) file for details

## 🙏 Acknowledgments

- Apple File Provider framework documentation
- WebDAV protocol specification
- Open source community support

## 📧 Contact

- **Bug Reports**: Submit via GitHub Issues
- **Feature Requests**: Welcome to discuss in Issues
- **Security Issues**: Please contact privately

## ⚠️ Disclaimer

This project is currently in development and is for learning and testing purposes only. Before using in production:

1. Conduct thorough testing
2. Backup important data
3. Assess security risks
4. Consider using mature commercial solutions

---

**Note**: This is an educational and demonstration project showing how to build a cloud storage mounting system using Apple's File Provider framework. While core features are implemented, further refinement is needed for production use.

**Last Updated**: 2026-01-12
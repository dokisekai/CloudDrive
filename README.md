<!-- CloudDrive, WebDAV, Cloud Storage, macOS, File Provider, Cloud Drive Mount, Swift, Apple, Sync Tool, File Management, Cloud Storage, Cloud Services -->
# CloudDrive - WebDAV Cloud Drive Mount System

![CloudDrive Logo](assets/logo.png) <!-- Placeholder for actual logo -->
![macOS](https://img.shields.io/badge/macOS-14.0+-blue.svg)
![Xcode](https://img.shields.io/badge/Xcode-15.0+-blue.svg)
![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)
![License](https://img.shields.io/badge/License-MIT-green.svg)

A WebDAV cloud drive mounting solution designed specifically for Apple devices that mounts WebDAV servers directly to the macOS sidebar, providing a seamless file access experience similar to iCloud.

## Description

CloudDrive is a cloud storage mounting tool developed based on the Apple File Provider framework, providing native WebDAV cloud disk access experience for macOS users. It allows users to mount any WebDAV server to the system sidebar, accessing cloud resources just like local files, featuring intelligent caching, secure authentication, and cross-platform compatibility.

## 🔑 Keywords

WebDAV, Cloud Storage, macOS, File Provider, Cloud Drive Mount, Swift, Apple, Sync Tool, File Management, Cloud Storage, Cloud Services, Personal Cloud Storage, File Sync, Network Disk, Cloud Drive Client

## 💡 Project Background and Pain Points

Before developing this project, I hoped to find an open-source project that could be used directly and mounted to the sidebar with on-demand caching functionality, but did not find a project that met my needs, so I decided to develop it myself. This is my first time learning the Swift language, and this project started from zero foundation, so please bear with me for any shortcomings.

Currently, mainstream network disk solutions have many pain points:
- Users need to download complete client software
- Need to watch ads or pay to get full functionality
- Network disk providers may read users' personal information
- Lack of flexible support for arbitrary network disks

Therefore, my ultimate goal is to create a completely serverless client that supports arbitrary network disk integration (such as through Alist-to-WebDAV solutions), ensures that all network disks cannot read users' personal information, eliminates the need to download clients or watch ads, and achieves an iCloud-like functional experience.

## 🚀 Project Introduction

CloudDrive is an innovative cloud storage solution that seamlessly integrates remote WebDAV servers into macOS systems through Apple's File Provider framework. Users can access cloud files just like local files, enjoying native file management experiences.

## ✨ Core Features

- **System-Level Integration**: Directly mount to Finder sidebar via File Provider extension
- **Transparent Access**: No need to perceive file storage location, system automatically handles caching and synchronization
- **Smart Cache**: Use LRU strategy to manage local cache, saving bandwidth and storage space
- **Secure & Reliable**: Use Keychain to securely store credentials, ensuring data security
- **Cross-Platform Extension**: Architecture design supports future iOS and iPadOS platforms

## 🎯 Main Advantages

- **Native Experience**: Perfectly integrated with macOS file system, no additional client needed
- **Efficient Sync**: Smart sync mechanism, only downloads required file content
- **Low Resource Usage**: Lightweight design, won't slow down system performance
- **Wide Compatibility**: Supports all cloud storage services using standard WebDAV protocol
- **Open Source**: Completely open source, community-driven, continuously improving

## 🏷️ Technical Tags

`WebDAV` `File Provider` `macOS Development` `Swift Programming` `Cloud Storage` `File Sync` `Apple Ecosystem` `Network Protocols` `File Management` `Distributed Systems` `Cache Strategy` `Security Authentication` `Cross-Platform` `Open Source Software`

## 🧩 Core Functionality Details

### File System Integration
CloudDrive deeply integrates into macOS systems through Apple's File Provider framework, providing users with seamless file access experience. The mounted WebDAV server appears in the Finder sidebar like a local disk, supporting all standard file operations.

### Smart Cache Mechanism
Using advanced LRU (Least Recently Used) cache algorithm, the system automatically manages local cache, ensuring frequently accessed files remain local to improve access speed while releasing infrequently used files to save storage space.

### Security Assurance
- Use macOS Keychain security service to store WebDAV server login credentials
- Support HTTPS encrypted transmission to ensure data security during network transfer
- Implemented comprehensive error handling and exception recovery mechanisms

## 💡 Usage Scenarios

### Individual Users
- Personal file backup and sync
- Self-hosted private cloud storage solution
- Multi-device file synchronization

### Developers & Professional Users
- Remote file access and editing
- Team collaboration file sharing
- Enterprise internal file management

### Enterprise Environment
- Secure enterprise cloud storage solution
- File access control compliant with enterprise security policies
- Seamless integration with existing IT infrastructure

## 📸 Interface Preview

![CloudDrive Screenshot](assets/screenshot.png) <!-- Placeholder for actual screenshot -->

*CloudDrive integration effect in Finder, providing native file access experience*

## 🚀 Quick Start

### System Requirements

- macOS 14.0 (Sonoma) or higher
- Xcode 15.0 or higher
- Swift 5.9 or higher
- At least 2GB available storage space for cache

### Installation Steps

#### Method 1: Compile from Source

1. Clone the project repository:
   ```bash
   git clone https://github.com/your-username/CloudDrive.git
   cd CloudDrive
   ```

2. Open the project in Xcode:
   ```bash
   open CloudDrive.xcodeproj
   ```

3. Configure project settings:
   - Set correct Bundle Identifier
   - Enable App Groups feature (`group.net.aabg.CloudDrive`)
   - Configure necessary permissions and entitlements

4. Build and run the project:
   ```bash
   xcodebuild clean build -project CloudDrive.xcodeproj -scheme CloudDrive
   ```

#### Method 2: Download Pre-built Version

Go to the [Releases](https://github.com/your-username/CloudDrive/releases) page to download the latest pre-built version.

## User Guide

1. Launch the CloudDrive application
2. Click "+" to add a new WebDAV server
3. Enter server address, username and password
4. Select local mount point (optional)
5. Click "Connect" to complete configuration
6. You will see the new cloud drive in the Finder sidebar

## 🤝 Contribution Guidelines

I warmly welcome community members to contribute to the CloudDrive project! Whether it's code improvements, documentation completion, or issue reports, all are important driving forces for project development.

### Development Environment Setup

1. **Clone the Project**
   ```bash
   git clone https://github.com/your-username/CloudDrive.git
   cd CloudDrive
   ```

2. **Configure the Project**
   ```bash
   # Configure App Group and code signing
   # In Xcode, set App Group: group.net.aabg.CloudDrive
   # Enable File Provider Extension permissions
   ```

3. **Build the Project**
   ```bash
   # Open project in Xcode
   open CloudDrive.xcodeproj
   
   # Or compile using command line
   xcodebuild clean build -project CloudDrive.xcodeproj -scheme CloudDrive
   ```

### Code Contributions

#### Code Style

- Follow [Swift Official Style Guide](https://swift.org/documentation/api-design-guidelines/)
- Use clear, descriptive variable and function names
- Add appropriate comments for public interfaces and complex logic
- Add documentation strings for functions and classes
- Use appropriate error handling mechanisms

#### Submission Process

1. Fork the project repository
2. Create a feature branch:
   ```bash
   git checkout -b feature/awesome-feature
   ```
3. Implement functionality and add tests
4. Commit changes:
   ```bash
   git commit -m 'feat: Add awesome feature'
   ```
5. Push the branch:
   ```bash
   git push origin feature/awesome-feature
   ```
6. Submit a Pull Request

### Documentation Contributions

- Improve existing documentation
- Add usage examples
- Enhance API documentation
- Translate internationalization content

### Code of Conduct

To create a friendly and inclusive community environment, please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## 📊 Project Status

### Implemented Features

✅ **WebDAV Server Connection and Authentication**: Supports connection and authentication with standard WebDAV protocol servers

✅ **File Operation Support**: Supports basic operations such as browsing, creating, uploading, downloading, and deleting files/directories

✅ **Local File Cache**: Implements LRU strategy local cache management with maximum 10GB cache support

✅ **Finder Deep Integration**: Mount cloud drives to macOS Finder sidebar through File Provider extension

✅ **Direct Path Mapping**: Implements direct mapping from WebDAV paths to local identifiers, simplifying implementation complexity

✅ **Sync Status Management**: Basic sync status tracking and management

✅ **Secure Credential Management**: Uses macOS Keychain to securely store WebDAV server login credentials

✅ **Application State Management**: Complete vault management and application state management

### Technical Architecture

- **Modular Design**: Adopt three main modules: CloudDrive, CloudDriveCore, CloudDriveFileProvider
- **File Provider Framework**: Fully utilize Apple's File Provider framework for system-level integration
- **Virtual File System**: Implement virtual file system (VFS) abstraction layer to unify local and remote file operations
- **Asynchronous Processing**: Extensively use Swift concurrency model to handle asynchronous operations
- **Cache Strategy**: Intelligent cache management balancing performance and storage space

### Development Roadmap

#### Short-term Goals (v1.0)

- [ ] **Improve Auto Sync**: Implement automatic sync logic from cloud to local, including bidirectional sync
- [ ] **File Change Monitoring**: Implement file change monitoring and incremental sync mechanisms
- [ ] **Conflict Resolution**: Handle conflict situations when multiple devices modify the same file simultaneously
- [ ] **Cache Strategy Optimization**: Improve cache eviction algorithms to increase cache hit rate
- [ ] **Enhanced Error Handling**: Improve error handling and user notification mechanisms

#### Mid-term Goals (v1.5)

- [ ] **End-to-End Encryption**: Support file encryption functionality to ensure data transmission and storage security
- [ ] **Multi-Vault Management**: Support simultaneous connections to multiple different WebDAV servers
- [ ] **Selective Sync**: Implement selective sync functionality similar to iCloud
- [ ] **Enhanced Offline Mode**: Improve offline mode user experience
- [ ] **Performance Monitoring**: Add performance monitoring and statistics functionality

#### Long-term Goals (v2.0)

- [ ] **iOS Client Support**: Develop iOS version to achieve cross-platform consistent experience
- [ ] **iPadOS Optimization**: Optimize for iPadOS large-screen interaction
- [ ] **File Sharing Functionality**: Support file sharing and collaboration functionality
- [ ] **Version History**: Provide file version control and history functionality
- [ ] **Collaboration Features**: Implement real-time collaborative editing functionality for multiple users

## 🔗 Related Resources

### Technical Documentation
- [Apple File Provider Framework Official Documentation](https://developer.apple.com/documentation/fileprovider)
- [WebDAV Protocol Specification](https://tools.ietf.org/html/rfc4918)
- [Swift Official Programming Language Guide](https://docs.swift.org/swift-book/)
- [macOS Application Development Guide](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/ProgrammingWithObjectiveC/Introduction/Introduction.html)

### Learning Resources
- [CloudDrive Development Tutorial](https://github.com/your-username/CloudDrive/wiki)
- [File Provider Extension Best Practices](https://developer.apple.com/videos/play/wwdc2017/701/)
- [WebDAV Client Implementation Guide](https://github.com/related-code/WebSocket)

### Community Support

Join our community to get help or participate in discussions:

- **GitHub Issues**: [Issue Reports & Feature Requests](https://github.com/your-username/CloudDrive/issues)
- **Discussions**: [Community Discussion Board](https://github.com/your-username/CloudDrive/discussions)
- **Mailing List**: cloud-drive-dev@example.com
- **Contributor Chat Room**: [Gitter](https://gitter.im/CloudDrive/community) or [Discord](https://discord.gg/cloud-drive)

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details

## 💝 Sponsorship Support

If you find CloudDrive helpful, please support project development through the following methods:

- Star this project ⭐
- Submit Issues or Pull Requests 🔄
- [Sponsor the project](https://github.com/sponsors/your-username) 💰

---

**Note**: This is an open-source project designed to demonstrate how to build cloud storage mounting systems using Apple's File Provider framework. Community contributions are welcome to jointly create a powerful, reliable, and easy-to-use cloud storage solution.
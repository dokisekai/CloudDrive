// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CloudDrive",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // Libraries
        .library(name: "CloudDriveCore", targets: ["CloudDriveCore"]),
        .library(name: "CloudDriveStorage", targets: ["CloudDriveStorage"]),
        .library(name: "CloudDriveFileProvider", targets: ["CloudDriveFileProvider"]),
        
        // Executables
        .executable(name: "CloudDriveApp", targets: ["CloudDriveApp"]),
        .executable(name: "CloudDriveTestsRunner", targets: ["CloudDriveTestsRunner"])
    ],
    dependencies: [
        .package(url: "https://github.com/cryptomator/cryptolib-swift.git", .upToNextMinor(from: "1.1.0"))
    ],
    targets: [
        // Layer 0: Contracts & Support
        .target(
            name: "CloudDriveContracts",
            dependencies: []
        ),
        .target(
            name: "CloudDriveSupport",
            dependencies: []
        ),
        
        // Layer 1: Persistence, Security, Crypto & Vault Format
        .target(
            name: "CloudDrivePersistence",
            dependencies: [
                "CloudDriveContracts",
                "CloudDriveSupport"
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "CloudDriveSecurity",
            dependencies: [
                "CloudDriveContracts",
                "CloudDriveSupport",
                .product(name: "CryptomatorCryptoLib", package: "cryptolib-swift")
            ]
        ),
        .target(
            name: "CloudDriveCrypto",
            dependencies: [
                "CloudDriveContracts",
                "CloudDriveSupport",
                .product(name: "CryptomatorCryptoLib", package: "cryptolib-swift")
            ]
        ),
        .target(
            name: "CloudDriveVaultFormat",
            dependencies: [
                "CloudDriveContracts",
                "CloudDriveSupport",
                "CloudDriveCrypto",
                .product(name: "CryptomatorCryptoLib", package: "cryptolib-swift")
            ]
        ),
        
        // Layer 2: System, Sync Engine & Cache Management
        .target(
            name: "CloudDriveSystem",
            dependencies: [
                "CloudDriveContracts",
                "CloudDriveSupport",
                "CloudDriveSecurity",
                "CloudDriveStorage"
            ]
        ),
        .target(
            name: "CloudDriveSync",
            dependencies: [
                "CloudDriveContracts",
                "CloudDriveSupport",
                "CloudDrivePersistence",
                "CloudDriveSystem"
            ]
        ),
        .target(
            name: "CloudDriveCache",
            dependencies: [
                "CloudDriveContracts",
                "CloudDriveSupport",
                "CloudDrivePersistence",
                "CloudDriveSync"
            ]
        ),
        
        // Layer 3: Preview, Recovery & VFS
        .target(
            name: "CloudDrivePreview",
            dependencies: [
                "CloudDriveContracts",
                "CloudDriveSupport"
            ]
        ),
        .target(
            name: "CloudDriveRecovery",
            dependencies: [
                "CloudDriveContracts",
                "CloudDriveSupport",
                "CloudDrivePersistence",
                "CloudDriveSystem",
                "CloudDriveCache",
                "CloudDriveSync",
                "CloudDrivePreview"
            ]
        ),
        .target(
            name: "CloudDriveVFS",
            dependencies: [
                "CloudDriveContracts",
                "CloudDriveSupport",
                "CloudDrivePersistence",
                "CloudDriveCrypto",
                "CloudDriveVaultFormat",
                "CloudDriveSync",
                "CloudDriveCache",
                "CloudDriveSystem",
                "CloudDrivePreview"
            ]
        ),

        // Layer 4: Storage Module (All backends in subdirectories, unified factory interface)
        .target(
            name: "CloudDriveStorage",
            dependencies: [
                "CloudDriveContracts",
                "CloudDriveSupport",
                "CloudDrivePersistence",
                "CloudDriveSecurity"
            ]
        ),

        // Layer 5: Core Domain & Vault Lifecycle Facade
        .target(
            name: "CloudDriveCore",
            dependencies: [
                "CloudDriveContracts",
                "CloudDriveSupport",
                "CloudDrivePersistence",
                "CloudDriveSecurity",
                "CloudDriveCrypto",
                "CloudDriveVaultFormat",
                "CloudDriveSystem",
                "CloudDriveSync",
                "CloudDriveCache",
                "CloudDriveVFS",
                "CloudDriveRecovery",
                "CloudDrivePreview",
                "CloudDriveStorage",
                .product(name: "CryptomatorCryptoLib", package: "cryptolib-swift")
            ],
            exclude: ["CloudDriveCore.h"]
        ),
        
        // System Extension & Apps
        .target(
            name: "CloudDriveFileProvider",
            dependencies: [
                "CloudDriveCore",
                "CloudDriveStorage"
            ],
            exclude: [
                "Info.plist",
                "CloudDriveFileProvider.entitlements"
            ]
        ),
        .executableTarget(
            name: "CloudDriveApp",
            dependencies: [
                "CloudDriveCore",
                "CloudDriveStorage",
                "CloudDriveSystem"
            ],
            path: "Sources/CloudDrive",
            exclude: [
                "Info.plist",
                "CloudDrive.entitlements",
                "Assets.xcassets"
            ]
        ),
        .executableTarget(
            name: "CloudDriveTestsRunner",
            dependencies: [
                "CloudDriveFileProvider",
                "CloudDriveCore",
                "CloudDriveStorage",
                "CloudDriveSystem",
                .product(name: "CryptomatorCryptoLib", package: "cryptolib-swift")
            ],
            path: "Tests/CloudDriveCoreTests"
        )
    ]
)

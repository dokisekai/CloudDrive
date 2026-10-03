//
//  EditVaultSheet.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  编辑保险库信息与配置弹窗 (名称、自动挂载、服务器连接与凭据)
//

import SwiftUI
import CloudDriveCore

struct EditVaultSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    
    let vault: VaultInfo
    
    @State private var vaultName: String
    @State private var isAutoMount: Bool
    
    // Local
    @State private var localPath: String
    @State private var localBookmarkData: Data?
    
    // WebDAV
    @State private var webdavURL: String
    @State private var webdavUsername: String
    @State private var webdavPassword: String = ""
    
    // S3
    @State private var s3Endpoint: String
    @State private var s3Region: String
    @State private var s3Bucket: String
    @State private var s3AccessKey: String
    @State private var s3SecretKey: String = ""
    @State private var s3Path: String
    
    // SMB
    @State private var smbHost: String
    @State private var smbShare: String
    @State private var smbSubpath: String
    @State private var smbUsername: String
    @State private var smbPassword: String = ""
    
    // FTP
    @State private var ftpHost: String
    @State private var ftpPort: String
    @State private var ftpUsername: String
    @State private var ftpPassword: String = ""
    
    // Pan123
    @State private var pan123ClientID: String
    @State private var pan123ClientSecret: String = ""
    @State private var pan123AccessToken: String
    @State private var pan123RootFolderID: Int64
    @State private var pan123RootPath: String
    
    // 加密主密码
    @State private var vaultPassword: String = ""
    @State private var showingChangePasswordSheet: Bool = false
    
    // 回收站设置（针对此加密库，存入库内 vfs.db）
    @State private var recycleBinEnabled: Bool
    @State private var recycleBinItemCount: Int = 0
    @State private var recycleBinTotalBytes: Int64 = 0
    @State private var showingEmptyVaultTrashAlert: Bool = false
    
    @State private var showingSaveAlert = false
    @State private var saveErrorMessage: String?
    @State private var showingRemountAlert = false
    
    init(vault: VaultInfo) {
        self.vault = vault
        _vaultName = State(initialValue: vault.name)
        _isAutoMount = State(initialValue: vault.isAutoMount)
        _localPath = State(initialValue: vault.storagePath)
        _localBookmarkData = State(initialValue: vault.bookmarkData)
        
        _recycleBinEnabled = State(initialValue: RecycleBinConfig.isEnabled(for: vault.id))
        _recycleBinItemCount = State(initialValue: RecycleBinManager.shared.count(vaultId: vault.id))
        _recycleBinTotalBytes = State(initialValue: RecycleBinManager.shared.totalSize(vaultId: vault.id))
        
        // 初始化 WebDAV
        _webdavURL = State(initialValue: vault.webdavURL ?? "")
        _webdavUsername = State(initialValue: vault.webdavUsername ?? "")
        
        // 初始化 S3
        if let config = vault.storageConfig, case .s3(let s3) = config {
            _s3Endpoint = State(initialValue: s3.endpoint)
            _s3Region = State(initialValue: s3.region)
            _s3Bucket = State(initialValue: s3.bucket)
            _s3AccessKey = State(initialValue: s3.accessKey)
            _s3Path = State(initialValue: s3.rootPrefix)
        } else {
            _s3Endpoint = State(initialValue: "")
            _s3Region = State(initialValue: "us-east-1")
            _s3Bucket = State(initialValue: "")
            _s3AccessKey = State(initialValue: "")
            _s3Path = State(initialValue: "/")
        }
        
        // 初始化 SMB
        if let config = vault.storageConfig, case .smb(let smb) = config {
            _smbHost = State(initialValue: smb.host)
            _smbShare = State(initialValue: smb.share)
            _smbSubpath = State(initialValue: smb.path)
            _smbUsername = State(initialValue: smb.username)
        } else {
            _smbHost = State(initialValue: "")
            _smbShare = State(initialValue: "")
            _smbSubpath = State(initialValue: "")
            _smbUsername = State(initialValue: "")
        }
        
        // 初始化 FTP
        if let config = vault.storageConfig, case .ftp(let ftp) = config {
            _ftpHost = State(initialValue: ftp.host)
            _ftpPort = State(initialValue: String(ftp.port))
            _ftpUsername = State(initialValue: ftp.username)
        } else {
            _ftpHost = State(initialValue: "")
            _ftpPort = State(initialValue: "21")
            _ftpUsername = State(initialValue: "")
        }
        
        // 初始化 Pan123
        if let config = vault.storageConfig, case .pan123(let pan) = config {
            _pan123ClientID = State(initialValue: pan.clientID)
            _pan123AccessToken = State(initialValue: pan.accessToken ?? "")
            _pan123RootFolderID = State(initialValue: pan.rootFolderID)
            _pan123RootPath = State(initialValue: pan.rootPath)
        } else {
            _pan123ClientID = State(initialValue: "")
            _pan123AccessToken = State(initialValue: "")
            _pan123RootFolderID = State(initialValue: 0)
            _pan123RootPath = State(initialValue: "/")
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶栏
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("vault_edit_title"))
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(vault.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            
            Divider()
            
            // 内容表单
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 基本配置
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L("section_basic_info"))
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("field_vault_name"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField(L("field_vault_name"), text: $vaultName)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        if vault.isLocal {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L("field_local_path"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                HStack(spacing: 8) {
                                    Text(localPath)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .padding(8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color(NSColor.textBackgroundColor))
                                        .cornerRadius(6)
                                    
                                    Button(L("field_local_reselect")) {
                                        selectLocalFolder()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                        
                        Divider().padding(.vertical, 4)
                        
                        Toggle(isOn: $isAutoMount) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("vault_edit_auto_mount"))
                                    .font(.body)
                                Text(L("vault_edit_auto_mount_desc"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                    .padding(16)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(10)
                    
                    // 存储连接配置
                    if !vault.isLocal {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L("section_storage_config"))
                                .font(.headline)
                            
                            switch vault.storageType {
                            case .webdav:
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("field_webdav_url"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("https://example.com/dav/", text: $webdavURL)
                                        .textFieldStyle(.roundedBorder)
                                }
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("field_username"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("Username", text: $webdavUsername)
                                        .textFieldStyle(.roundedBorder)
                                }
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("field_password_new_hint"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    SecureField(L("field_password_keep_placeholder"), text: $webdavPassword)
                                        .textFieldStyle(.roundedBorder)
                                }
                                
                            case .s3:
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Endpoint")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("s3.amazonaws.com", text: $s3Endpoint)
                                        .textFieldStyle(.roundedBorder)
                                }
                                
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Region")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        TextField("us-east-1", text: $s3Region)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Bucket")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        TextField("my-bucket", text: $s3Bucket)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Access Key")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("Access Key ID", text: $s3AccessKey)
                                        .textFieldStyle(.roundedBorder)
                                }
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Secret Key")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    SecureField(L("field_password_keep_placeholder"), text: $s3SecretKey)
                                        .textFieldStyle(.roundedBorder)
                                }
                                
                            case .smb:
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(L("field_smb_host"))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        TextField("192.168.1.100", text: $smbHost)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(L("field_smb_share"))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        TextField("ShareName", text: $smbShare)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("field_username"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("Username", text: $smbUsername)
                                        .textFieldStyle(.roundedBorder)
                                }
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("field_password_new_hint"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    SecureField(L("field_password_keep_placeholder"), text: $smbPassword)
                                        .textFieldStyle(.roundedBorder)
                                }
                                
                            case .ftp:
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(L("field_ftp_host"))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        TextField("ftp.example.com", text: $ftpHost)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Port")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        TextField("21", text: $ftpPort)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("field_username"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("anonymous", text: $ftpUsername)
                                        .textFieldStyle(.roundedBorder)
                                }
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("field_password_new_hint"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    SecureField(L("field_password_keep_placeholder"), text: $ftpPassword)
                                        .textFieldStyle(.roundedBorder)
                                }
                                
                            case .pan123:
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("field_pan123_client_id"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("App Client ID", text: $pan123ClientID)
                                        .textFieldStyle(.roundedBorder)
                                }
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("field_pan123_client_secret"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    SecureField(L("field_password_keep_placeholder"), text: $pan123ClientSecret)
                                        .textFieldStyle(.roundedBorder)
                                }
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("field_pan123_token"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("Access Token", text: $pan123AccessToken)
                                        .textFieldStyle(.roundedBorder)
                                }
                                
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(L("field_pan123_root_id"))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        TextField("0", value: $pan123RootFolderID, formatter: NumberFormatter())
                                            .textFieldStyle(.roundedBorder)
                                    }
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(L("field_pan123_root_path"))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        TextField("/", text: $pan123RootPath)
                                            .textFieldStyle(.roundedBorder)
                                    }
                                }
                                
                            default:
                                EmptyView()
                            }
                        }
                        .padding(16)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(10)
                    }
                    
                    // 加密安全设置 (如果是加密库)
                    if vault.isEncrypted {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(L("section_encryption_security"))
                                .font(.headline)
                            
                            // 选项 B: 真正修改云端加密库密码 (推荐)
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .center) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(L("section_cloud_password"))
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        Text(L("section_cloud_password_desc"))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Button {
                                        showingChangePasswordSheet = true
                                    } label: {
                                        Label(L("btn_open_change_pwd"), systemImage: "key.horizontal")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(12)
                            .background(Color.accentColor.opacity(0.08))
                            .cornerRadius(8)
                            
                            Divider()
                            
                            // 选项 A: 仅同步更新本地保存的凭据
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L("section_local_credential"))
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text(L("section_local_credential_desc"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                SecureField(L("field_password_keep_placeholder"), text: $vaultPassword)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        .padding(16)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(10)
                    }
                    
                    // 回收站设置
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L("vault_recycle_bin_section"))
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: $recycleBinEnabled) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(L("vault_recycle_bin_enable_toggle"))
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text(L("vault_recycle_bin_desc"))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .toggleStyle(.switch)
                        }
                        
                        Divider()
                        
                        HStack {
                            let sizeStr = ByteCountFormatter.string(fromByteCount: recycleBinTotalBytes, countStyle: .file)
                            Text(L("vault_recycle_bin_current_usage", recycleBinItemCount, sizeStr))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            Spacer()
                            
                            if recycleBinItemCount > 0 {
                                Button(role: .destructive) {
                                    showingEmptyVaultTrashAlert = true
                                } label: {
                                    Label(L("vault_recycle_bin_empty_now"), systemImage: "trash")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(16)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(10)
                    
                    // 挂载提示信息
                    if vault.isMounted {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.blue)
                                .font(.title3)
                            Text(L("vault_edit_remount_notice"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(12)
                        .background(Color.blue.opacity(0.08))
                        .cornerRadius(8)
                    }
                    
                    if let err = saveErrorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(24)
            }
            
            Divider()
            
            // 底部操作按钮
            HStack {
                Button(L("cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button(L("vault_edit_save")) {
                    saveChanges()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(vaultName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 500, maxWidth: 580, minHeight: 460, maxHeight: 620)
        .sheet(isPresented: $showingChangePasswordSheet) {
            ChangeVaultPasswordSheet(vault: vault)
                .environmentObject(appState)
        }
        .alert(L("recycle_bin_empty_confirm_title"), isPresented: $showingEmptyVaultTrashAlert) {
            Button(L("cancel"), role: .cancel) { }
            Button(L("recycle_bin_confirm_empty"), role: .destructive) {
                Task {
                    _ = try? await RecycleBinManager.shared.emptyTrash(vaultId: vault.id)
                    await MainActor.run {
                        recycleBinItemCount = RecycleBinManager.shared.count(vaultId: vault.id)
                        recycleBinTotalBytes = RecycleBinManager.shared.totalSize(vaultId: vault.id)
                    }
                }
            }
        } message: {
            Text(L("recycle_bin_empty_confirm_msg"))
        }
        .alert(L("vault_edit_remount_title"), isPresented: $showingRemountAlert) {
            Button(L("vault_edit_remount_now")) {
                Task {
                    try? await appState.remountVault(vault)
                }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            Button(L("vault_edit_remount_later"), role: .cancel) {
                dismiss()
            }
        } message: {
            Text(L("vault_edit_remount_msg"))
        }
    }
    
    private func saveChanges() {
        let trimmedName = vaultName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        
        // 保存回收站策略（存入该加密库专属 vfs.db 数据库）
        RecycleBinConfig.setEnabled(recycleBinEnabled, for: vault.id)
        
        var updated = vault
        // 更新名称与自动挂载
        // (VaultInfo 的 name 是 let，重建新实例或通过构造方法)
        var newStorageConfig: StorageConfiguration? = vault.storageConfig
        var newStoragePassword: String? = nil
        
        switch vault.storageType {
        case .webdav:
            let cleanURL = webdavURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanUser = webdavUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            newStorageConfig = .webdav(WebDAVStorageConfig(
                baseURL: cleanURL,
                username: cleanUser,
                password: webdavPassword
            ))
            updated.webdavURL = cleanURL
            updated.webdavUsername = cleanUser
            if !webdavPassword.isEmpty {
                newStoragePassword = webdavPassword
            }
        case .s3:
            let cleanEndpoint = s3Endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanRegion = s3Region.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanBucket = s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanAccess = s3AccessKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanPath = s3Path.trimmingCharacters(in: .whitespacesAndNewlines)
            newStorageConfig = .s3(S3StorageConfig(
                endpoint: cleanEndpoint,
                region: cleanRegion,
                bucket: cleanBucket,
                accessKey: cleanAccess,
                secretKey: s3SecretKey,
                rootPrefix: cleanPath
            ))
            if !s3SecretKey.isEmpty {
                newStoragePassword = s3SecretKey
            }
        case .smb:
            let cleanHost = smbHost.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanShare = smbShare.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanSubpath = smbSubpath.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanUser = smbUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            newStorageConfig = .smb(SMBStorageConfig(
                host: cleanHost,
                share: cleanShare,
                path: cleanSubpath,
                username: cleanUser,
                password: smbPassword
            ))
            if !smbPassword.isEmpty {
                newStoragePassword = smbPassword
            }
        case .ftp:
            let cleanHost = ftpHost.trimmingCharacters(in: .whitespacesAndNewlines)
            let portInt = Int(ftpPort.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 21
            let cleanUser = ftpUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            newStorageConfig = .ftp(FTPStorageConfig(
                host: cleanHost,
                port: portInt,
                username: cleanUser,
                password: ftpPassword
            ))
            if !ftpPassword.isEmpty {
                newStoragePassword = ftpPassword
            }
        case .pan123:
            let cleanID = pan123ClientID.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanToken = pan123AccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanPath = pan123RootPath.trimmingCharacters(in: .whitespacesAndNewlines)
            newStorageConfig = .pan123(Pan123StorageConfig(
                clientID: cleanID,
                clientSecret: pan123ClientSecret,
                accessToken: cleanToken.isEmpty ? nil : cleanToken,
                rootFolderID: pan123RootFolderID,
                rootPath: cleanPath
            ))
            if !pan123ClientSecret.isEmpty {
                newStoragePassword = pan123ClientSecret
            }
        default:
            break
        }
        
        let newVaultPassword = vaultPassword.isEmpty ? nil : vaultPassword
        
        let newVault = VaultInfo(
            id: vault.id,
            name: trimmedName,
            storagePath: vault.isLocal ? localPath : vault.storagePath,
            createdAt: vault.createdAt,
            storageType: vault.storageType,
            storageConfig: newStorageConfig,
            webdavURL: updated.webdavURL,
            webdavUsername: updated.webdavUsername,
            isMounted: vault.isMounted,
            isEncrypted: vault.isEncrypted,
            bookmarkData: vault.isLocal ? localBookmarkData : vault.bookmarkData,
            isAutoMount: isAutoMount
        )
        
        appState.updateVault(newVault, newStoragePassword: newStoragePassword, newVaultPassword: newVaultPassword)
        if vault.isMounted {
            showingRemountAlert = true
        } else {
            dismiss()
        }
    }
    
    private func selectLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L("open")
        panel.message = L("local_folder_picker_prompt")
        
        if panel.runModal() == .OK, let selectedURL = panel.url {
            self.localPath = selectedURL.path
            do {
                self.localBookmarkData = try selectedURL.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                logError(.system, "Failed to create security bookmark for reselected local URL: \(error)")
            }
        }
    }
}

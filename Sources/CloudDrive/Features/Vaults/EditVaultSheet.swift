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

    // 百度网盘
    @State private var baiduAppID: String = ""
    @State private var baiduAppKey: String = ""
    @State private var baiduClientSecret: String = ""
    @State private var baiduRefreshToken: String = ""
    @State private var baiduAppFolderName: String = "CloudDrive"
    @State private var baiduRootPath: String = "/"

    // 加密主密码
    @State private var vaultPassword: String = ""
    @State private var showingChangePasswordSheet: Bool = false
    

    // 库专属忽略规则 (.clouddriveignore)
    @State private var vaultIgnoreText: String
    
    @State private var showingSaveAlert = false
    @State private var saveErrorMessage: String?
    @State private var showingRemountAlert = false
    
    init(vault: VaultInfo) {
        self.vault = vault
        _vaultName = State(initialValue: vault.name)
        _isAutoMount = State(initialValue: vault.isAutoMount)

        _vaultIgnoreText = State(initialValue: VFSDatabase(vaultId: vault.id).getIgnoreRules() ?? VaultIgnoreManager.defaultContent)
        
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
        
        // 初始化百度网盘
        if let config = vault.storageConfig, case .baidupan(let pan) = config {
            _baiduAppID = State(initialValue: pan.appID)
            _baiduAppKey = State(initialValue: pan.appKey)
            _baiduRefreshToken = State(initialValue: pan.refreshToken)
            _baiduAppFolderName = State(initialValue: pan.appFolderName)
            _baiduRootPath = State(initialValue: pan.rootPath)
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
                    if vault.isStorageEnabled {
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
                                
                            case .baidupan:
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("field_baidupan_app_id"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("App ID", text: $baiduAppID)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("field_baidupan_app_key"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("App Key", text: $baiduAppKey)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("field_baidupan_app_folder"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("CloudDrive", text: $baiduAppFolderName)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("field_baidupan_client_secret"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    SecureField(L("field_password_keep_placeholder"), text: $baiduClientSecret)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("field_baidupan_refresh_token"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    SecureField(L("field_password_keep_placeholder"), text: $baiduRefreshToken)
                                        .textFieldStyle(.roundedBorder)
                                }

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L("field_baidupan_root_path"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    TextField("/", text: $baiduRootPath)
                                        .textFieldStyle(.roundedBorder)
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
                    

                    // 专属忽略规则 (.clouddriveignore)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "line.3.crossed.swirl")
                                .font(.headline)
                                .foregroundColor(.accentColor)
                            Text(L("ignore_tab_vault") + " (.clouddriveignore)")
                                .font(.headline)
                        }
                        
                        Text(L("ignore_vault_desc"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        TextEditor(text: $vaultIgnoreText)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 120)
                            .padding(4)
                            .background(Color(NSColor.textBackgroundColor))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                        
                        HStack {
                            Button(L("ignore_preset_title")) {
                                vaultIgnoreText = VaultIgnoreManager.defaultContent
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            
                            Spacer()
                            
                            Text(L("ignore_unified_tip"))
                                .font(.caption2)
                                .foregroundColor(.secondary)
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
        

        // 保存加密库专属忽略规则
        let db = VFSDatabase(vaultId: vault.id)
        try? db.setIgnoreRules(vaultIgnoreText)
        IgnoreRuleEngine.shared.setVaultRules(vaultId: vault.id, content: vaultIgnoreText)
        
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
        case .baidupan:
            // clientSecret / refreshToken 均为敏感值：留空表示沿用 Keychain 中的现值，
            // 非空则作为新凭证覆盖。切勿把旧值回显到表单里。
            let cleanAppID = baiduAppID.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanAppKey = baiduAppKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanFolder = baiduAppFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanRoot = baiduRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanSecret = baiduClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanRefresh = baiduRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines)

            var merged = (vault.storageConfig.flatMap { cfg -> BaiduPanStorageConfig? in
                if case .baidupan(let c) = cfg { return c }
                return nil
            }) ?? BaiduPanStorageConfig()

            merged.appID = cleanAppID
            merged.appKey = cleanAppKey
            merged.appFolderName = cleanFolder
            merged.rootPath = cleanRoot
            if !cleanSecret.isEmpty { merged.clientSecret = cleanSecret }
            merged.refreshToken = cleanRefresh.isEmpty ? merged.refreshToken : cleanRefresh
            if merged.accessToken.isEmpty {
                if let rec = (try? BaiduPanTokenStore().readRecordPublic(vault.id)) ?? (try? BaiduPanTokenStore().readRecordPublic("default")) {
                    merged.accessToken = rec.accessToken
                    merged.expiresAt = rec.expiresAt
                }
            }
            newStorageConfig = .baidupan(merged)

            if !cleanSecret.isEmpty {
                newStoragePassword = cleanSecret
            } else if !cleanRefresh.isEmpty {
                newStoragePassword = cleanRefresh
            }
        default:
            break
        }
        
        let newVaultPassword = vaultPassword.isEmpty ? nil : vaultPassword
        
        let newVault = VaultInfo(
            id: vault.id,
            name: trimmedName,
            storagePath: vault.storagePath,
            createdAt: vault.createdAt,
            storageType: vault.storageType,
            storageConfig: newStorageConfig,
            webdavURL: updated.webdavURL,
            webdavUsername: updated.webdavUsername,
            isMounted: vault.isMounted,
            isEncrypted: vault.isEncrypted,
            bookmarkData: vault.bookmarkData,
            isAutoMount: isAutoMount
        )
        
        appState.updateVault(newVault, newStoragePassword: newStoragePassword, newVaultPassword: newVaultPassword)
        if vault.isMounted {
            showingRemountAlert = true
        } else {
            dismiss()
        }
    }
}

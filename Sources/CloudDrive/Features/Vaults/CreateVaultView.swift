//
//  CreateVaultView.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  创建与挂载多协议存储保险库向导视图 (支持 WebDAV, S3, SMB, FTP, Local 本地存储)
//

import SwiftUI
import CloudDriveCore

enum VaultCreationMode: String, CaseIterable, Identifiable {
    case createEncrypted = "createEncrypted"
    case openExisting = "openExisting"
    case directWebDAV = "directWebDAV"
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .createEncrypted: return L("vault_mode_new")
        case .openExisting: return L("vault_mode_open")
        case .directWebDAV: return L("vault_mode_direct")
        }
    }
    
    var description: String {
        switch self {
        case .createEncrypted: return L("vault_mode_new_desc")
        case .openExisting: return L("vault_mode_open_desc")
        case .directWebDAV: return L("vault_mode_direct_desc")
        }
    }
    
    var icon: String {
        switch self {
        case .createEncrypted:
            return "lock.shield.fill"
        case .openExisting:
            return "lock.open.trianglebadge.exclamationmark.fill"
        case .directWebDAV:
            return "arrow.triangle.2.circlepath"
        }
    }
}

struct CreateVaultView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    @ObservedObject private var localization = LocalizationManager.shared
    
    // 模式选择
    let initialMode: VaultCreationMode
    @State private var mode: VaultCreationMode
    
    // 协议类型选择
    @State private var selectedProtocol: StorageType = .webdav
    
    // 基本配置
    @State private var vaultName = ""
    
    // WebDAV 配置
    @State private var webdavURL = ""
    @State private var webdavUsername = ""
    @State private var webdavPassword = ""
    
    // S3 配置
    @State private var s3Preset: S3ProviderPreset = .custom
    @State private var s3Endpoint = "http://127.0.0.1:9000"
    @State private var s3Region = "us-east-1"
    @State private var s3Bucket = ""
    @State private var s3AccessKey = ""
    @State private var s3SecretKey = ""
    @State private var s3RootPrefix = ""
    @State private var s3UsePathStyle = true
    
    // SMB 配置
    @State private var smbHost = ""
    @State private var smbShare = ""
    @State private var smbPath = "/"
    @State private var smbPort = 445
    @State private var smbUsername = ""
    @State private var smbPassword = ""
    @State private var smbDomain = ""
    
    // FTP 配置
    @State private var ftpHost = ""
    @State private var ftpPort = 21
    @State private var ftpUsername = ""
    @State private var ftpPassword = ""
    @State private var ftpPath = "/"
    @State private var ftpUseTLS = false
    
    // 123云盘配置
    @State private var pan123ClientID = ""
    @State private var pan123ClientSecret = ""
    @State private var pan123AccessToken = ""
    @State private var pan123RootFolderID: Int64 = 0
    @State private var pan123RootPath = "/"
    
    // 百度网盘配置
    @State private var baiduAppID = ""
    @State private var baiduAppKey = ""
    @State private var baiduClientSecret = ""
    @State private var baiduAppFolderName = "CloudDrive"
    @State private var baiduRootPath = "/"
    @State private var baiduRefreshToken = ""
    @State private var baiduAccessToken = ""
    
    // Local 本地存储配置
    @State private var localPath = ""
    @State private var localBookmarkData: Data? = nil
    
    // 打开已有保险库时的远程路径
    @State private var remoteVaultPath = "/"
    @State private var showingRemoteFolderPicker = false
    
    // 选项配置
    @State private var isAutoMount = true
    
    // 加密保险库密码与显示控制
    @State private var vaultPassword = ""
    @State private var confirmVaultPassword = ""
    @State private var showPasswordPlaintext = false
    @State private var showConfirmPlaintext = false
    
    // 状态控制
    @State private var isConnecting = false
    @State private var isTesting = false
    @State private var testSuccess = false
    @State private var errorMessage: String?
    @State private var testMessage: String?
    
    init(initialMode: VaultCreationMode = .createEncrypted) {
        self.initialMode = initialMode
        _mode = State(initialValue: initialMode)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack(spacing: 12) {
                Image(systemName: mode.icon)
                    .font(.title2)
                    .foregroundColor(mode == .directWebDAV ? .blue : .orange)
                
                Text(titleText)
                    .font(.title3)
                    .fontWeight(.bold)
                
                Spacer()
                
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(isConnecting)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
            
            Divider()
            
            // 表单内容
            Form {
                // 1. 存储模式选择
                Section(L("section_operation_mode")) {
                    HStack(spacing: 8) {
                        ForEach(VaultCreationMode.allCases) { m in
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    mode = m
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: m.icon)
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(m.title)
                                        .font(.system(size: 12, weight: mode == m ? .semibold : .regular))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(mode == m ? (m == .directWebDAV ? Color.blue.opacity(0.14) : Color.orange.opacity(0.14)) : Color(NSColor.controlBackgroundColor))
                                )
                                .foregroundColor(mode == m ? (m == .directWebDAV ? .blue : .orange) : .primary)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(mode == m ? (m == .directWebDAV ? Color.blue : Color.orange) : Color(NSColor.separatorColor).opacity(0.3), lineWidth: mode == m ? 1.5 : 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: mode.icon)
                            .foregroundColor(mode == .directWebDAV ? .blue : .orange)
                            .font(.system(size: 13))
                        Text(mode.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                
                // 2. 云存储协议选择 (支持 WebDAV, S3, SMB, FTP, Local)
                Section(L("section_protocol_select")) {
                    HStack(spacing: 8) {
                        ForEach(StorageType.allCases, id: \.self) { type in
                            ProtocolSelectionCard(
                                type: type,
                                isSelected: selectedProtocol == type,
                                action: {
                                    withAnimation(.easeInOut(duration: 0.12)) {
                                        selectedProtocol = type
                                        testSuccess = false
                                        testMessage = nil
                                        errorMessage = nil
                                    }
                                }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                
                // 3. 保险库基本信息
                Section(L("section_vault_info")) {
                    TextField(L("vault_name_placeholder"), text: $vaultName)
                        .disabled(isConnecting)
                        .help(L("vault_name_help"))
                }
                
                // 4. 协议专用配置表单
                Section(protocolSectionTitle) {
                    switch selectedProtocol {
                    case .webdav:
                        WebDAVFormView(url: $webdavURL, username: $webdavUsername, password: $webdavPassword, isConnecting: isConnecting)
                    case .s3:
                        S3FormView(preset: $s3Preset, endpoint: $s3Endpoint, region: $s3Region, bucket: $s3Bucket, accessKey: $s3AccessKey, secretKey: $s3SecretKey, rootPrefix: $s3RootPrefix, usePathStyle: $s3UsePathStyle, isConnecting: isConnecting)
                    case .baidupan:
                        BaiduPanFormView(
                            appID: $baiduAppID,
                            appKey: $baiduAppKey,
                            clientSecret: $baiduClientSecret,
                            appFolderName: $baiduAppFolderName,
                            rootPath: $baiduRootPath,
                            refreshToken: $baiduRefreshToken,
                            accessToken: $baiduAccessToken,
                            isConnecting: isConnecting
                        )
                    case .smb:
                        SMBFormView(host: $smbHost, port: $smbPort, share: $smbShare, path: $smbPath, username: $smbUsername, password: $smbPassword, domain: $smbDomain, isConnecting: isConnecting)
                    case .ftp:
                        FTPFormView(host: $ftpHost, port: $ftpPort, username: $ftpUsername, password: $ftpPassword, path: $ftpPath, useTLS: $ftpUseTLS, isConnecting: isConnecting)
                    case .pan123:
                        Pan123FormView(
                            clientID: $pan123ClientID,
                            clientSecret: $pan123ClientSecret,
                            accessToken: $pan123AccessToken,
                            rootFolderID: $pan123RootFolderID,
                            rootPath: $pan123RootPath,
                            isConnecting: isConnecting
                        )
                    case .local:
                        LocalFormView(
                            path: $localPath,
                            bookmarkData: $localBookmarkData,
                            isConnecting: isConnecting,
                            onPathSelected: { path in
                                if vaultName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    vaultName = URL(fileURLWithPath: path).lastPathComponent
                                }
                            }
                        )
                    }
                    
                    // 测试连接按钮 (非本地文件夹模式显示)
                    if selectedProtocol != .local {
                        testConnectionButtonRow
                    }
                }
                
                // 5. 远端保险库文件夹选择（打开已有云端保险库时显示）
                if mode == .openExisting && selectedProtocol != .local {
                    Section(L("section_remote_path")) {
                        HStack {
                            TextField(L("remote_path_placeholder"), text: $remoteVaultPath)
                                .disabled(isConnecting)
                            
                            if selectedProtocol == .webdav {
                                Button(action: {
                                    showingRemoteFolderPicker = true
                                }) {
                                    Label(L("remote_path_browse"), systemImage: "folder.badge.gearshape")
                                }
                                .buttonStyle(.bordered)
                                .disabled(!isProtocolConfigValid)
                                .help(isProtocolConfigValid ? L("remote_path_browse") : "")
                            }
                        }
                        
                        Text(L("remote_path_tip"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                // 6. 加密设置与强度反馈
                if mode == .createEncrypted {
                    Section(L("section_encryption_pwd")) {
                        // 主密码输入行
                        HStack {
                            if showPasswordPlaintext {
                                TextField(L("vault_password_placeholder"), text: $vaultPassword)
                                    .disabled(isConnecting)
                            } else {
                                SecureField(L("vault_password_placeholder"), text: $vaultPassword)
                                    .disabled(isConnecting)
                            }
                            
                            Button {
                                showPasswordPlaintext.toggle()
                            } label: {
                                Image(systemName: showPasswordPlaintext ? "eye.slash" : "eye")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(showPasswordPlaintext ? L("pwd_toggle_hide") : L("pwd_toggle_show"))
                        }
                        
                        // 确认密码输入行
                        HStack {
                            if showConfirmPlaintext {
                                TextField(L("vault_password_confirm_placeholder"), text: $confirmVaultPassword)
                                    .disabled(isConnecting)
                            } else {
                                SecureField(L("vault_password_confirm_placeholder"), text: $confirmVaultPassword)
                                    .disabled(isConnecting)
                            }
                            
                            Button {
                                showConfirmPlaintext.toggle()
                            } label: {
                                Image(systemName: showConfirmPlaintext ? "eye.slash" : "eye")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(showConfirmPlaintext ? L("pwd_toggle_hide") : L("pwd_toggle_show"))
                        }
                        
                        // 密码强度检测指示条
                        if !vaultPassword.isEmpty {
                            passwordStrengthView
                        }
                        
                        if !vaultPassword.isEmpty && vaultPassword.count < 8 {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.circle")
                                    .font(.caption2)
                                Text(L("create_vault_pwd_min_hint"))
                                    .font(.caption)
                            }
                            .foregroundColor(.orange)
                        }
                        
                        if !vaultPassword.isEmpty && !confirmVaultPassword.isEmpty && vaultPassword != confirmVaultPassword {
                            Text(L("vault_password_mismatch"))
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                            Text(L("vault_password_warning"))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 2)
                    }
                } else if mode == .openExisting {
                    Section(L("section_encryption_pwd")) {
                        HStack {
                            if showPasswordPlaintext {
                                TextField(L("vault_password_placeholder"), text: $vaultPassword)
                                    .disabled(isConnecting)
                            } else {
                                SecureField(L("vault_password_placeholder"), text: $vaultPassword)
                                    .disabled(isConnecting)
                            }
                            
                            Button {
                                showPasswordPlaintext.toggle()
                            } label: {
                                Image(systemName: showPasswordPlaintext ? "eye.slash" : "eye")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(showPasswordPlaintext ? L("pwd_toggle_hide") : L("pwd_toggle_show"))
                        }
                        
                        Text(L("remote_path_tip"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                // 7. 挂载与启动选项
                Section {
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
                    .disabled(isConnecting)
                }
                
                // 8. 错误信息展示
                if let error = errorMessage {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L("error"))
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.red)
                                Text(error)
                                    .font(.caption2)
                                    .foregroundColor(.red)
                            }
                        }
                        .padding(8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
            }
            .formStyle(.grouped)
            
            Divider()
            
            // 底部操作按钮
            HStack {
                Spacer()
                
                Button(L("cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isConnecting)
                
                Button(submitButtonTitle) {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isFormValid || isConnecting)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(minWidth: 640, idealWidth: 680, minHeight: 640, idealHeight: 740)
        .onAppear {
            self.mode = initialMode
        }
        .sheet(isPresented: $showingRemoteFolderPicker) {
            WebDAVFolderPickerSheet(
                url: webdavURL,
                username: webdavUsername,
                password: webdavPassword,
                selectedPath: $remoteVaultPath,
                onSelect: { selectedPath in
                    remoteVaultPath = selectedPath
                    if vaultName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let name = selectedPath == "/" ? L("vault_default_name_encrypted") : URL(fileURLWithPath: selectedPath).lastPathComponent
                        vaultName = name
                    }
                }
            )
            .environmentObject(appState)
        }
    }
    
    // MARK: - Password Strength Helper
    
    private var passwordScore: Int {
        var score = 0
        if vaultPassword.count >= 8 { score += 1 }
        if vaultPassword.count >= 12 { score += 1 }
        let hasLetters = vaultPassword.rangeOfCharacter(from: .letters) != nil
        let hasNumbers = vaultPassword.rangeOfCharacter(from: .decimalDigits) != nil
        let hasPunctuation = vaultPassword.rangeOfCharacter(from: .punctuationCharacters) != nil || vaultPassword.rangeOfCharacter(from: .symbols) != nil
        if hasLetters && hasNumbers { score += 1 }
        if hasLetters && hasNumbers && hasPunctuation { score += 1 }
        return score
    }
    
    private var passwordStrengthView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ForEach(0..<4) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(strengthBarColor(for: index))
                        .frame(height: 4)
                }
            }
            
            HStack {
                Text(L("pwd_strength_label"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                Text(strengthText)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(strengthLabelColor)
            }
        }
        .padding(.vertical, 2)
    }
    
    private func strengthBarColor(for index: Int) -> Color {
        if index < passwordScore {
            if passwordScore <= 1 { return .red }
            if passwordScore <= 3 { return .orange }
            return .green
        }
        return Color.secondary.opacity(0.2)
    }
    
    private var strengthText: String {
        if passwordScore <= 1 { return L("pwd_strength_weak") }
        if passwordScore <= 3 { return L("pwd_strength_medium") }
        return L("pwd_strength_strong")
    }
    
    private var strengthLabelColor: Color {
        if passwordScore <= 1 { return .red }
        if passwordScore <= 3 { return .orange }
        return .green
    }
    
    // MARK: - Subform Views
    
    private var protocolSectionTitle: String {
        switch selectedProtocol {
        case .webdav: return L("protocol_webdav_title")
        case .s3: return L("protocol_s3_title")
        case .baidupan: return L("protocol_baidupan_title")
        case .smb: return L("protocol_smb_title")
        case .ftp: return L("protocol_ftp_title")
        case .pan123: return L("protocol_pan123_title")
        case .local: return L("protocol_local_title")
        }
    }
    
    private var testConnectionButtonRow: some View {
        HStack {
            Button(action: testConnection) {
                HStack(spacing: 6) {
                    if isTesting {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    } else if testSuccess {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Image(systemName: "network")
                    }
                    Text(isTesting ? L("btn_testing_connection") : (testSuccess ? L("success") : "\(L("btn_test_connection")) (\(selectedProtocol.localizedName))"))
                }
            }
            .disabled(isTesting || !isProtocolConfigValid)
            .buttonStyle(.bordered)
            
            if let message = testMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(testSuccess ? .green : .secondary)
            }
        }
    }
    
    // MARK: - Validation
    
    private var isProtocolConfigValid: Bool {
        switch selectedProtocol {
        case .webdav:
            return !webdavURL.isEmpty && !webdavUsername.isEmpty && !webdavPassword.isEmpty
        case .s3:
            return !s3Endpoint.isEmpty && !s3Bucket.isEmpty && !s3AccessKey.isEmpty && !s3SecretKey.isEmpty
        case .baidupan:
            return !baiduAppKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                   !baiduClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                   !baiduRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .smb:
            return !smbHost.isEmpty && !smbShare.isEmpty
        case .ftp:
            return !ftpHost.isEmpty && ftpPort > 0
        case .pan123:
            return (!pan123ClientID.isEmpty && !pan123ClientSecret.isEmpty) || !pan123AccessToken.isEmpty
        case .local:
            return !localPath.isEmpty
        }
    }
    
    private var isFormValid: Bool {
        guard isProtocolConfigValid else { return false }
        switch mode {
        case .createEncrypted:
            return vaultPassword.count >= 8 && vaultPassword == confirmVaultPassword
        case .openExisting:
            return !vaultPassword.isEmpty
        case .directWebDAV:
            return true
        }
    }
    
    private var titleText: String {
        switch mode {
        case .createEncrypted:
            return L("vault_mode_new")
        case .openExisting:
            return L("vault_mode_open")
        case .directWebDAV:
            return L("vault_mode_direct")
        }
    }
    
    private var submitButtonTitle: String {
        if isConnecting {
            switch mode {
            case .createEncrypted: return L("btn_creating")
            case .openExisting: return L("btn_connecting")
            case .directWebDAV: return L("btn_connecting")
            }
        }
        switch mode {
        case .createEncrypted: return L("btn_create_and_mount")
        case .openExisting: return L("btn_open_and_mount")
        case .directWebDAV: return L("btn_connect_and_mount")
        }
    }
    
    // MARK: - Actions
    
    private func buildStorageConfiguration() -> StorageConfiguration {
        switch selectedProtocol {
        case .webdav:
            return .webdav(WebDAVStorageConfig(
                baseURL: webdavURL.trimmingCharacters(in: .whitespacesAndNewlines),
                username: webdavUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                password: webdavPassword
            ))
        case .s3:
            return .s3(S3StorageConfig(
                endpoint: s3Endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
                region: s3Region.trimmingCharacters(in: .whitespacesAndNewlines),
                bucket: s3Bucket.trimmingCharacters(in: .whitespacesAndNewlines),
                accessKey: s3AccessKey.trimmingCharacters(in: .whitespacesAndNewlines),
                secretKey: s3SecretKey.trimmingCharacters(in: .whitespacesAndNewlines),
                usePathStyle: s3UsePathStyle,
                rootPrefix: s3RootPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        case .baidupan:
            return .baidupan(BaiduPanStorageConfig(
                appID: baiduAppID.trimmingCharacters(in: .whitespacesAndNewlines),
                appKey: baiduAppKey.trimmingCharacters(in: .whitespacesAndNewlines),
                clientSecret: baiduClientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
                appFolderName: baiduAppFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "CloudDrive" : baiduAppFolderName.trimmingCharacters(in: .whitespacesAndNewlines),
                rootPath: baiduRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/" : baiduRootPath.trimmingCharacters(in: .whitespacesAndNewlines),
                refreshToken: baiduRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines),
                accessToken: baiduAccessToken.trimmingCharacters(in: .whitespacesAndNewlines),
                expiresAt: Date().addingTimeInterval(25 * 86400)
            ))
        case .smb:
            return .smb(SMBStorageConfig(
                host: smbHost.trimmingCharacters(in: .whitespacesAndNewlines),
                share: smbShare.trimmingCharacters(in: .whitespacesAndNewlines),
                path: smbPath.trimmingCharacters(in: .whitespacesAndNewlines),
                username: smbUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                password: smbPassword,
                domain: smbDomain.isEmpty ? nil : smbDomain,
                port: smbPort
            ))
        case .ftp:
            return .ftp(FTPStorageConfig(
                host: ftpHost.trimmingCharacters(in: .whitespacesAndNewlines),
                port: ftpPort,
                username: ftpUsername.trimmingCharacters(in: .whitespacesAndNewlines),
                password: ftpPassword,
                path: ftpPath.trimmingCharacters(in: .whitespacesAndNewlines),
                useTLS: ftpUseTLS
            ))
        case .pan123:
            return .pan123(Pan123StorageConfig(
                clientID: pan123ClientID.trimmingCharacters(in: .whitespacesAndNewlines),
                clientSecret: pan123ClientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
                accessToken: pan123AccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : pan123AccessToken.trimmingCharacters(in: .whitespacesAndNewlines),
                rootFolderID: pan123RootFolderID,
                rootPath: pan123RootPath.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        case .local:
            return .local(LocalStorageConfig(path: localPath, bookmarkData: localBookmarkData))
        }
    }
    
    private func testConnection() {
        isTesting = true
        testSuccess = false
        testMessage = nil
        errorMessage = nil
        
        let config = buildStorageConfiguration()
        let start = DispatchTime.now()
        
        Task {
            do {
                let success = try await appState.testStorageConnection(configuration: config)
                let end = DispatchTime.now()
                let elapsedMs = Int((end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                
                await MainActor.run {
                    testSuccess = success
                    testMessage = success ? L("test_latency_ms", elapsedMs) : L("test_conn_failed_check")
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testSuccess = false
                    let desc = error.localizedDescription
                    testMessage = "\(L("test_conn_failed")): \(desc)"
                    errorMessage = desc
                    isTesting = false
                }
            }
        }
    }
    
    private func submit() {
        isConnecting = true
        errorMessage = nil
        
        let trimmedName = vaultName.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultName: String = {
            if selectedProtocol == .local && !localPath.isEmpty {
                return URL(fileURLWithPath: localPath).lastPathComponent
            }
            switch mode {
            case .createEncrypted: return "\(selectedProtocol.localizedName) \(L("vault_default_suffix_encrypted"))"
            case .openExisting:
                let clean = remoteVaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean == "/" || clean.isEmpty {
                    return "\(selectedProtocol.localizedName) \(L("vault_default_suffix_vault"))"
                }
                return URL(fileURLWithPath: clean).lastPathComponent
            case .directWebDAV: return "\(selectedProtocol.localizedName) \(L("vault_default_suffix_storage"))"
            }
        }()
        let targetName = trimmedName.isEmpty ? defaultName : trimmedName
        let config = buildStorageConfiguration()
        let targetRemotePath = (selectedProtocol == .local) ? "/" : remoteVaultPath
        
        Task {
            do {
                try await appState.connectUnifiedStorage(
                    name: targetName,
                    mode: mode,
                    configuration: config,
                    remotePath: targetRemotePath,
                    vaultPassword: mode == .directWebDAV ? nil : vaultPassword,
                    isAutoMount: isAutoMount,
                    bookmarkData: selectedProtocol == .local ? localBookmarkData : nil
                )
                await MainActor.run {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isConnecting = false
                }
            }
        }
    }
}

// MARK: - 协议选择卡片组件

struct ProtocolSelectionCard: View {
    let type: StorageType
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: type.iconName)
                    .font(.system(size: 15, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? type.themeColor : (isHovered ? type.themeColor : .secondary))
                
                Text(type.localizedName)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? type.themeColor.opacity(0.12) : (isHovered ? Color.secondary.opacity(0.06) : Color(NSColor.controlBackgroundColor)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? type.themeColor : Color(NSColor.separatorColor).opacity(0.3),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
//
//  LocalizationManager.swift
//  CloudDrive
//
//  Copyright (c) 2026 李彦军 liyanjun@aabg.net
//  https://github.com/dokisekai/CloudDrive
//
//  多语言国际化管理 (支持运行时中文与英文动态切换)
//

import SwiftUI
import Combine
import CloudDriveCore

public enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case chinese = "zh-Hans"
    case english = "en"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .system:
            return LocalizationManager.shared.currentEffectiveLanguage == .chinese ? "跟随系统 (System)" : "System Default"
        case .chinese:
            return "简体中文 (Chinese)"
        case .english:
            return "English"
        }
    }
}

public class LocalizationManager: ObservableObject {
    public static let shared = LocalizationManager()
    
    public static let languageDidChangeNotification = Notification.Name("CloudDriveLanguageDidChangeNotification")
    private let userDefaultsKey = "CloudDrive_AppLanguage"
    
    @Published public private(set) var selectedLanguage: AppLanguage
    
    private init() {
        if let saved = UserDefaults.standard.string(forKey: userDefaultsKey),
           let lang = AppLanguage(rawValue: saved) {
            self.selectedLanguage = lang
        } else {
            self.selectedLanguage = .system
        }
    }
    
    public var currentEffectiveLanguage: AppLanguage {
        if selectedLanguage == .system {
            let preferred = Locale.preferredLanguages.first ?? "en"
            if preferred.hasPrefix("zh") {
                return .chinese
            } else {
                return .english
            }
        }
        return selectedLanguage
    }
    
    public func setLanguage(_ language: AppLanguage) {
        objectWillChange.send()
        selectedLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: userDefaultsKey)
        NotificationCenter.default.post(name: LocalizationManager.languageDidChangeNotification, object: language)
    }
    
    public func tr(_ key: String, _ args: CVarArg...) -> String {
        let lang = currentEffectiveLanguage
        let table = lang == .chinese ? stringsZh : stringsEn
        let format = table[key] ?? stringsZh[key] ?? key
        if args.isEmpty {
            return format
        } else {
            return String(format: format, arguments: args)
        }
    }
}

/// 全局便捷国际化函数
public func L(_ key: String, _ args: CVarArg...) -> String {
    let lm = LocalizationManager.shared
    let lang = lm.currentEffectiveLanguage
    let table = lang == .chinese ? stringsZh : stringsEn
    let format = table[key] ?? stringsZh[key] ?? key
    if args.isEmpty {
        return format
    } else {
        return String(format: format, arguments: args)
    }
}

// MARK: - 简体中文语言表 (Simplified Chinese)
private let stringsZh: [String: String] = [
    // 通用
    "app_name": "CloudDrive",
    "cancel": "取消",
    "confirm": "确定",
    "done": "完成",
    "ok": "好",
    "remove": "移除",
    "delete": "删除",
    "close": "关闭",
    "open": "打开",
    "copy": "复制",
    "copied": "已复制",
    "refresh": "刷新",
    "success": "成功",
    "error": "错误",
    "warning": "警告",
    "tip": "提示",
    
    // 菜单栏与状态栏
    "menu_open_main_window": "打开主窗口",
    "menu_browse_in_finder": "在访达中浏览云存储",
    "menu_quit_app": "退出 CloudDrive",
    "menu_open_log_directory": "打开日志目录",
    "menu_open_system_log": "打开系统日志",
    "menu_open_file_ops_log": "打开文件操作日志",
    
    // 主界面与工具栏
    "nav_subtitle_default": "端到端加密云盘与多协议挂载",
    "nav_subtitle_counts": "%d 个保险库 · %d 个已挂载",
    "toolbar_add_vault": "添加保险库",
    "toolbar_new_encrypted_vault": "新建加密保险库",
    "toolbar_open_existing_vault": "打开已有加密库",
    "toolbar_direct_storage": "直连存储映射",
    "toolbar_refresh_tooltip": "立即刷新文件与挂载状态",
    "toolbar_settings_tooltip": "偏好设置",
    
    // 保险库卡片与弹窗
    "alert_vault_mounted_cannot_delete": "保险库 “%@” 当前正在挂载中，请先卸载后再移除。",
    "alert_confirm_remove_vault": "确认移除保险库",
    "alert_confirm_remove_vault_msg": "确定要从列表中移除保险库 “%@” 吗？\n\n此操作仅移除本地配置，不会删除云端或本地实际存储的数据。",
    "alert_confirm_unmount": "确认卸载",
    "alert_confirm_unmount_msg": "确定要卸载保险库 “%@” 吗？卸载后可随时重新挂载。",
    "vault_status_mounted": "已挂载",
    "vault_status_unmounted": "未挂载",
    "vault_status_encrypted": "AES-256 加密",
    "vault_status_direct": "直连存储",
    "vault_status_local": "本地",
    "vault_card_open_in_finder": "在访达中打开",
    "vault_card_unmount": "卸载",
    "vault_card_unmount_menu": "卸载保险库",
    "vault_card_mount": "挂载",
    "vault_card_mount_menu": "挂载保险库",
    "vault_card_mounting": "挂载中...",
    "vault_card_remove_tooltip": "从列表中移除",
    "vault_card_copy_path_tooltip": "复制存储地址",
    "vault_card_added_on": "添加于 %@",
    "vault_card_edit": "编辑",
    "vault_card_edit_menu": "编辑保险库信息",
    "vault_edit_title": "编辑保险库信息",
    "vault_edit_auto_mount": "启动应用时自动挂载",
    "vault_edit_auto_mount_desc": "开启后，启动 CloudDrive 时将自动解锁并挂载此保险库至访达",
    "vault_edit_save": "保存更改",
    "vault_edit_remount_notice": "保险库正在挂载中。修改名称或连接配置将在下次重新挂载后生效。",
    "vault_status_automount": "自动挂载",
    "vault_status_manual": "手动挂载",
    "section_basic_info": "基本信息",
    "section_storage_config": "存储连接配置",
    "section_encryption_security": "加密安全设置",
    "field_vault_name": "保险库名称",
    "field_password_new_hint": "新连接密码 (留空保持不变)",
    "field_password_keep_placeholder": "留空保持原密码不变",
    "field_vault_password_update_hint": "新主解锁密码 (留空保持不变)",
    "menu_change_vault_password": "修改保险库密码...",
    "change_pwd_title": "修改保险库主密码",
    "change_pwd_subtitle": "验证原密码后，将使用新密码重新加密云端 masterkey 文件并更新本地钥匙串。所有已有文件无需重新加密，秒级生效。",
    "change_pwd_current": "当前原密码",
    "change_pwd_current_placeholder": "输入当前保险库密码",
    "change_pwd_new": "新保险库密码",
    "change_pwd_new_placeholder": "输入新密码（至少 8 位）",
    "change_pwd_confirm": "确认新密码",
    "change_pwd_confirm_placeholder": "再次输入新密码",
    "change_pwd_submit": "立即修改密码",
    "change_pwd_submitting": "正在更新云端主密钥...",
    "change_pwd_success": "密码修改成功！云端主密钥已更新，本地钥匙串已同步。",
    "change_pwd_err_length": "新密码长度至少需要 8 个字符",
    "change_pwd_err_mismatch": "两次输入的新密码不一致",
    "change_pwd_err_same": "新密码不能与原密码相同",
    "change_pwd_err_wrong_old": "原密码不正确，请重新输入",
    "change_pwd_notice": "💡 提示：修改完成后，官方 Cryptomator 客户端及其他设备后续均需使用此新密码解锁。系统已自动在云端保存了 masterkey.cryptomator.bkup 备份。",
    "section_cloud_password": "选项 B：真正修改云端加密库密码",
    "section_cloud_password_desc": "直接重加密云端的 masterkey 密钥文件，全平台生效，无需重新加密文件。",
    "btn_open_change_pwd": "修改云端主密码...",
    "section_local_credential": "选项 A：仅更新本地保存的解锁密码",
    "section_local_credential_desc": "仅在其他设备（如手机版或 Cryptomator 官方软件）已修改密码时填写，用于同步本地自动挂载凭据。此项不会修改云端保险库密码。",
    
    // 空状态卡片
    "empty_welcome_title": "欢迎使用 CloudDrive",
    "empty_welcome_subtitle": "安全便捷地将云端加密库及 WebDAV / S3 / SMB / FTP 目录挂载为本地磁盘",
    "empty_card_new_title": "新建加密库",
    "empty_card_new_desc": "在云端创建 AES-256-GCM 端到端加密保险库",
    "empty_card_new_btn": "立即创建",
    "empty_card_open_title": "打开已有加密库",
    "empty_card_open_desc": "打开云端或本地已存在的 Cryptomator 保险库",
    "empty_card_open_btn": "打开已有库",
    "empty_card_direct_title": "直连存储映射",
    "empty_card_direct_desc": "无加密直接映射远端存储目录，零开销快速访问",
    "empty_card_direct_btn": "直连存储",
    
    // 创建 / 打开保险库
    "vault_mode_new": "新建加密库",
    "vault_mode_new_desc": "在云端创建全新的客户端端到端加密保险库（AES-256-GCM / Format 8），保障数据绝对私密。",
    "vault_mode_open": "打开已有加密库",
    "vault_mode_open_desc": "打开已存在于云端的 Cryptomator 或 CloudDrive 加密保险库。",
    "vault_mode_direct": "直连存储映射",
    "vault_mode_direct_desc": "直接映射远端存储目录 (WebDAV / S3 / SMB / FTP)，按需同步，保持远端文件原貌，零加密开销。",
    "section_operation_mode": "操作模式",
    "section_protocol_select": "云存储协议选择",
    "section_vault_info": "保险库基本信息",
    "vault_name_placeholder": "保险库显示名称",
    "vault_name_help": "显示在应用列表及访达侧边栏中的名称",
    "section_encryption_pwd": "设置保险库安全密码 (AES-256)",
    "vault_password_placeholder": "保险库加密密码",
    "vault_password_confirm_placeholder": "确认加密密码",
    "create_vault_pwd_min_hint": "密码长度至少 8 个字符",
    "vault_password_mismatch": "两次输入的保险库密码不一致",
    "vault_password_warning": "请务必牢记此密码！该密码用于加密解密所有文件，如果遗失将无法从云端恢复数据。",
    "section_remote_path": "云端保险库文件夹路径",
    "remote_path_placeholder": "远程路径 (例如 / 或 /MyVault)",
    "remote_path_browse": "浏览云端目录...",
    "remote_path_tip": "指定已存在的加密保险库目录路径（通常包含 masterkey.cryptomator 与 d 文件夹）。",
    "btn_test_connection": "测试连接",
    "btn_testing_connection": "测试连接中...",
    "btn_create_and_mount": "创建并挂载",
    "btn_open_and_mount": "打开并挂载",
    "btn_connect_and_mount": "连接并挂载",
    "btn_creating": "正在创建...",
    "btn_connecting": "正在连接...",
    
    // 协议表单
    "protocol_webdav_title": "WebDAV 服务器连接配置",
    "protocol_s3_title": "Amazon S3 / 对象存储连接配置",
    "protocol_smb_title": "SMB / Windows 共享文件夹连接配置",
    "protocol_ftp_title": "FTP / FTPS 服务器连接配置",
    "protocol_pan123_title": "123云盘开放平台连接配置",
    "field_pan123_client_id": "Client ID (开发者 AppID)",
    "field_pan123_client_secret": "Client Secret (应用密钥)",
    "field_pan123_token": "Access Token (可选，已获取时直接填入)",
    "field_pan123_root_id": "根文件夹 ID (0 为根目录)",
    "field_pan123_tip": "支持 123云盘开放平台 API v1/v2，支持分片上传与秒传",
    "field_pan123_root_path": "根路径",
    "vault_edit_remount_title": "配置已更新",
    "vault_edit_remount_msg": "保险库当前处于挂载状态，是否立即重新挂载以应用新配置？",
    "vault_edit_remount_now": "立即重挂载",
    "vault_edit_remount_later": "稍后手动",
    "field_local_reselect": "重新选择文件夹...",
    "field_webdav_url": "WebDAV 服务器 URL",
    "field_username": "用户名",
    "field_password": "密码",
    "field_s3_preset": "服务商预设",
    "field_s3_endpoint": "Endpoint 终端节点",
    "field_s3_region": "区域 (Region)",
    "field_s3_bucket": "存储桶名称 (Bucket)",
    "field_s3_access_key": "Access Key ID",
    "field_s3_secret_key": "Secret Access Key",
    "field_s3_prefix": "根目录前缀 (可选)",
    "field_s3_path_style": "使用 Path-Style 寻址",
    "field_smb_host": "服务器主机 / IP",
    "field_smb_share": "共享文件夹名 (Share Name)",
    "field_smb_subpath": "挂载子路径",
    "field_smb_domain": "工作组 / 域名 (可选)",
    "field_smb_port": "端口 (默认 445)",
    "field_ftp_host": "FTP 服务器主机 / IP",
    "field_ftp_port": "端口 (默认 21)",
    "field_ftp_path": "远程工作目录",
    "field_ftp_tls": "启用 FTPS (TLS 安全传输)",
    
    // 解锁弹窗
    "unlock_title": "解锁加密保险库",
    "unlock_desc": "请输入保险库 “%@” 的主密码以解锁并挂载至访达",
    "unlock_password_placeholder": "保险库密码",
    "unlock_btn_unlock": "解锁并挂载",
    "unlock_btn_unlocking": "解锁中...",
    "unlock_storage_password_label": "%@ 存储密码",
    "unlock_storage_password_placeholder": "存储连接密码",
    "unlock_vault_password_label": "保险库加密密码",
    
    // 设置
    "settings_title": "偏好设置",
    "tab_general": "通用",
    "tab_cache": "缓存",
    "tab_recycle_bin": "回收站",
    "tab_logs": "日志",
    "tab_about": "关于",
    "recycle_bin_enable_title": "启用软删除回收站",
    "recycle_bin_enable_desc": "删除文件时暂存至回收站，可随时还原，防止误删",
    "recycle_bin_filter_vault": "存储库筛选:",
    "recycle_bin_all_vaults": "全部存储库",
    "recycle_bin_search_placeholder": "搜索已删除的文件...",
    "recycle_bin_summary": "共 %d 项，占用空间 %@",
    "recycle_bin_restore_all": "全部还原",
    "recycle_bin_empty": "清空回收站",
    "recycle_bin_restore": "还原",
    "recycle_bin_delete_forever": "彻底删除",
    "recycle_bin_empty_state_title": "回收站为空",
    "recycle_bin_empty_state_desc": "删除的文件将安全暂存在这里，支持随时还原",
    "recycle_bin_deleted_at": "删除于: %@",
    "recycle_bin_empty_confirm_title": "确认清空回收站？",
    "recycle_bin_empty_confirm_msg": "清空后这些文件将从云端彻底删除，此操作不可撤销。",
    "recycle_bin_confirm_empty": "清空",
    "recycle_bin_delete_confirm_title": "确认彻底删除？",
    "recycle_bin_delete_confirm_msg": "将永久删除 \"%@\"，此操作不可恢复。",
    "recycle_bin_confirm_delete": "彻底删除",
    "vault_recycle_bin_section": "回收站设置",
    "vault_recycle_bin_enable_toggle": "开启回收站 (默认关闭)",
    "vault_recycle_bin_mode": "回收站策略",
    "vault_recycle_bin_inherit": "遵循全局设置 (当前: %@)",
    "vault_recycle_bin_force_on": "针对此库强制启用",
    "vault_recycle_bin_force_off": "针对此库彻底禁用 (直接物理删除)",
    "vault_recycle_bin_desc": "开启后，在此库访达中删除文件将移至该库的「回收站」目录，并在云端执行真实移动，本地立即物理清理释放磁盘空间；关闭时删除操作将直接调用永久删除 API。",
    "vault_recycle_bin_snapshot": "保留本地缓存快照",
    "vault_recycle_bin_snapshot_desc": "将已下载的本地缓存备份至回收站，还原时免网络流量秒级恢复",
    "vault_recycle_bin_retention": "自动清理过期文件",
    "vault_recycle_bin_retention_days": "%d 天后自动清空",
    "vault_recycle_bin_retention_forever": "永久保留",
    "vault_recycle_bin_current_usage": "当前已回收: %d 项 (%@)",
    "vault_recycle_bin_empty_now": "立即清空此库回收站",
    "enabled": "开启",
    "disabled": "关闭",
    "settings_language": "应用界面语言",
    "settings_language_desc": "更改后立即生效，菜单与所有界面将动态切换。",
    "settings_security": "安全偏好",
    "settings_auto_lock": "空闲时自动锁定保险库",
    "settings_lock_timeout": "锁定超时时间:",
    "settings_lock_timeout_minutes": "%d 分钟",
    "settings_auto_lock_desc": "当系统长时间无操作时自动卸载并锁定加密保险库，防止未授权访问。",
    "settings_cache_storage": "本地存储与缓存",
    "settings_current_cache": "当前缓存占用:",
    "settings_calculating": "计算中...",
    "settings_clear_cache": "清理本地缓存",
    "settings_clear_cache_desc": "清除已缓存的临时文件，不会影响云端数据与未保存的更改",
    "settings_btn_clear_now": "立即清理",
    "settings_alert_cache_cleared": "缓存已清理",
    "about_app_desc": "端到端加密云盘与 macOS 原生 FileProvider 挂载方案",
    "about_version": "版本 1.0.0 (Build 2026.10)",
    "about_feature_crypto": "AES-256-GCM",
    "about_feature_protocol": "多协议存储 (WebDAV/S3/SMB/FTP)",
    "about_feature_fileprovider": "FileProvider 原生",
    "about_feature_cache": "智能本地缓存",
    
    // 日志管理
    "log_mgmt_title": "模块独立日志监控",
    "log_mgmt_subtitle": "支持单独打开各系统模块的实时运行日志及排错窗口",
    "log_btn_browse_dir": "浏览日志目录",
    "log_btn_close_all": "全部关闭",
    "log_status_running": "运行中",
    "log_btn_open": "打开",
    "log_btn_close": "关闭",
    "log_search_placeholder": "搜索日志",
    "log_records_count": "%d 条记录",
    "log_not_found": "没有找到日志",
    "log_level_filter": "日志级别",
    "log_level_all": "全部",
    "log_menu_copy": "复制",
    "log_menu_copy_full": "复制完整日志",
    "log_export": "导出日志",
    "log_export_format": "导出格式",
    "log_export_count_desc": "将导出 %d 条日志记录",
    "log_export_btn": "导出",
    "log_file_ops_panel_title": "文件操作",
    "log_file_ops_filter": "筛选",
    "log_file_ops_empty": "没有文件操作",
    "log_file_ops_clear_all": "清除所有操作",
    
    // 日志分类
    "cat_system": "系统",
    "cat_system_desc": "系统生命周期与核心事件",
    "cat_file_ops": "文件操作",
    "cat_file_ops_desc": "访达读写、创建与移动操作",
    "cat_webdav": "云端通信",
    "cat_webdav_desc": "远端请求通信与网络状态",
    "cat_cache": "缓存",
    "cat_cache_desc": "本地分块缓存命中与淘汰",
    "cat_database": "数据库",
    "cat_database_desc": "虚拟文件系统 SQLite 元数据",
    "cat_sync": "同步",
    "cat_sync_desc": "后台排队与云端文件同步",
    
    // 存储协议名称
    "protocol_name_webdav": "WebDAV",
    "protocol_name_s3": "Amazon S3 / 对象存储",
    "protocol_name_smb": "SMB / Windows 共享",
    "protocol_name_ftp": "FTP / FTPS",
    "protocol_name_pan123": "123云盘",
    "protocol_name_local": "本地文件夹",
    
    // 保险库默认命名
    "vault_default_suffix_encrypted": "加密保险库",
    "vault_default_suffix_vault": "保险库",
    "vault_default_suffix_storage": "存储",
    "vault_default_name_encrypted": "加密保险库",
    
    // S3 服务商预设
    "s3_preset_custom": "自定义 / MinIO",
    "s3_preset_aliyun": "阿里云 OSS",
    "s3_preset_tencent": "腾讯云 COS",
    
    // 连接测试与结果
    "test_conn_success": "连接成功！",
    "test_conn_failed_check": "连接失败，请检查配置",
    "test_conn_failed": "连接失败",
    "test_conn_success_cryptomator": "连接成功，检测到标准 Cryptomator 保险库！",
    "test_conn_success_clouddrive": "连接成功，检测到 CloudDrive 加密保险库！",
    "test_conn_success_vault_dir": "连接成功，检测到加密保险库目录！",
    "test_conn_no_config_found": "连接成功，但路径 '%@' 未发现保险库配置文件",
    
    // 远程目录选择器
    "picker_title": "选择云端文件夹",
    "picker_home_tooltip": "回到根目录",
    "picker_up_tooltip": "返回上一级目录",
    "picker_vault_detected": "当前目录已检测到加密保险库！",
    "picker_vault_detected_desc": "包含 masterkey.cryptomator 配置文件",
    "picker_select_current_dir": "选择当前目录",
    "picker_loading": "正在读取云端目录...",
    "picker_load_failed": "读取失败: %@",
    "picker_retry": "重试",
    "picker_no_subfolders": "当前目录下无子文件夹",
    "picker_encrypted_vault_badge": "加密保险库",
    "picker_enter": "进入",
    "picker_select_this_vault": "选择此保险库",
    "picker_select": "选择",
    "picker_selected_path": "所选路径: %@",
    "picker_select_current_dir_with_path": "选择当前目录 (%@)",
    
    // 日志与文件操作增强
    "log_auto_scroll": "自动滚动",
    "log_export_failed": "导出失败",
    "log_export_type_text": "纯文本",
    "file_op_status_pending": "等待中",
    "file_op_status_progress": "进行中 %d%%",
    "file_op_status_completed_duration": "已完成 (%@s)",
    "file_op_status_completed": "已完成",
    "file_op_status_failed": "失败",
    "file_op_status_cancelled": "已取消",
    "file_op_filter_in_progress": "进行中",
    "file_op_filter_pending": "等待中",
    "file_op_filter_failed": "失败",
    "file_op_type_create": "创建",
    "file_op_type_delete": "删除",
    "file_op_type_move": "移动",
    "file_op_type_copy": "复制",
    "file_op_type_upload": "上传",
    "file_op_type_download": "下载",
    "file_op_type_modify": "修改",
    "file_op_type_rename": "重命名",
    
    // AppState 授权与错误提示
    "appstate_panel_prompt": "授权访问",
    "appstate_panel_message": "请确认授权 CloudDrive 访问此加密库文件夹以挂载到访达",
    "err_cannot_get_password": "无法获取保险库加密密码",
    "err_invalid_webdav_url": "无效的 WebDAV URL",
    "err_set_vault_password": "请设置保险库加密密码",
    "err_enter_vault_password": "请输入保险库加密密码",
    "err_cannot_connect_webdav": "无法连接到 WebDAV 服务器，请检查网络或配置",
    "err_conn_failed_webdav": "连接失败，无法连接到 WebDAV 服务器",
    "err_vault_not_found": "保险库不存在",
    "err_no_local_folder_auth": "未获得本地文件夹访问授权，无法挂载",
    "err_incomplete_vault_config": "保险库配置不完整",
    "err_cannot_get_webdav_password": "无法获取 WebDAV 密码，可能需要重新配置",
    
    // 忽略规则
    "tab_ignore_rules": "忽略规则",
    "ignore_section_builtin": "系统内置规则 (自动保护)",
    "ignore_toggle_builtin": "启用系统元数据忽略 (如 .DS_Store, Thumbs.db 等)",
    "ignore_builtin_list_title": "查看内置忽略列表 (%d 项)",
    "ignore_section_global": "全局规则 (对所有挂载库生效)",
    "ignore_global_desc": "规则语法完全兼容 .gitignore 标准 (如 target/, node_modules/, *.log, !keep.log)",
    "ignore_empty_custom": "暂无自定义规则",
    "ignore_placeholder": "添加忽略模式 (例如 node_modules/ 或 *.tmp)",
    "ignore_btn_add": "添加",
    "ignore_section_preset": "开发者一键预设",
    "ignore_preset_title": "一键添加工程编译与依赖忽略预设",
    "ignore_preset_desc": "包含 Node.js, Rust, Python, Java, Swift, Git 等常用构建与缓存规则",
    "ignore_btn_select_preset": "选择预设模板...",
    "preset_sheet_title": "选择常用开发预设规则",
    "preset_sheet_already_added": "已添加",
    "preset_select_all": "全选",
    "preset_deselect_all": "全部取消",
    "preset_import_selected": "导入所选规则",
    
    // 缓存高级设置
    "cache_quota_title": "最大缓存配额",
    "cache_quota_default": "%d GB (默认)",
    "cache_thumbnail_section": "缩略图缓存",
    "cache_thumbnail_size": "缩略图占用空间",
    "cache_thumbnail_clear_title": "清理缩略图缓存",
    "cache_thumbnail_clear_desc": "清理所有本地生成的图片、PDF 及视频缩略图缓存（不影响正文文件）",
    "cache_thumbnail_clear_btn": "立即清理",
    "cache_pinned_section": "固定保留文件 (始终保留在此 Mac)",
    "cache_pinned_count": "当前固定保护数量",
    "cache_pinned_items_unit": "%d 个项目",
    "cache_pinned_unpin_all_title": "解除所有固定保护",
    "cache_pinned_unpin_all_desc": "解除后，文件将恢复自动管理并可在空间不足时正常参与清理",
    "cache_pinned_unpin_all_btn": "全部解除",
    
    // 菜单栏托盘设置
    "menu_bar_settings_header": "菜单栏与系统托盘",
    "settings_menubar_toggle": "在 macOS 菜单栏显示图标",
    "settings_menubar_toggle_desc": "开启后，可在屏幕顶部菜单栏随时查看保险库状态并快速挂载/卸载。",
    
    // 主界面搜索与筛选
    "search_vaults_placeholder": "搜索保险库名称或存储路径...",
    "filter_all": "全部",
    "filter_mounted": "已挂载",
    "filter_unmounted": "未挂载",
    "filter_encrypted": "加密库",
    "filter_direct": "直连存储",
    "search_no_results": "没有找到匹配的保险库",
    "search_no_results_desc": "请尝试更换搜索关键字或清除筛选条件",
    "summary_total_vaults": "保险库总数",
    "summary_mounted": "已挂载",
    "summary_encrypted": "加密保护",
    "summary_direct": "直连映射",
    
    // 本地存储
    "protocol_local_title": "本地文件夹存储配置",
    "field_local_path": "本地文件夹路径",
    "field_local_browse": "浏览本地文件夹...",
    "field_local_browse_help": "选择本地磁盘、外接硬盘或 U 盘上的文件夹",
    "local_folder_picker_prompt": "选择要作为保险库的文件夹",
    
    // 密码强度与显示控制
    "pwd_strength_label": "密码强度:",
    "pwd_strength_weak": "弱 (建议至少 8 位并包含字母与数字)",
    "pwd_strength_medium": "中等",
    "pwd_strength_strong": "强",
    "pwd_toggle_show": "显示密码",
    "pwd_toggle_hide": "隐藏密码",
    
    // 状态栏 Popover
    "popover_header_title": "CloudDrive 控制台",
    "popover_vaults_count": "%d 个已挂载 · 共 %d 个",
    "popover_no_vaults": "暂无配置的保险库",
    "popover_quick_mount": "挂载",
    "popover_quick_unmount": "卸载",
    "popover_open_main": "打开主窗口",
    "popover_open_finder": "打开云盘目录",
    "popover_preferences": "偏好设置...",
    "popover_quit": "退出",
    "test_latency_ms": "连接成功 (%d ms)",
    
    // 启动行为设置
    "settings_startup_behavior": "启动行为",
    "settings_startup_behavior_desc": "控制 CloudDrive 的启动偏好，包括自动挂载、窗口显示与通知推送行为。",
    "settings_show_main_on_launch": "启动时显示主窗口",
    "settings_auto_mount_on_launch": "启动时自动挂载已标记的保险库",
    "settings_confirm_before_unmount": "卸载前显示确认对话框",
    "settings_show_notifications": "显示挂载 / 卸载通知",
    
    // 表单字段辅助文字（补充）
    "webdav_url_hint": "WebDAV 地址应以 http:// 或 https:// 开头",
    "field_ftp_tls_on_hint": "已启用 FTPS 加密传输",
    
    // 侧边栏与现代布局
    "sidebar_all_vaults": "全部保险库",
    "sidebar_mounted": "已挂载",
    "sidebar_unmounted": "未挂载",
    "sidebar_encrypted": "加密保护",
    "sidebar_direct": "直连映射",
    "sidebar_protocols": "存储协议",
    "sidebar_vaults": "保险库清单",
    "sidebar_quick_add": "新建保险库",
    "sidebar_preferences": "偏好设置",
    "view_mode_grid": "网格卡片",
    "view_mode_list": "紧凑列表",
    "card_auto_mount_on": "自启动挂载",
    "card_auto_mount_off": "手动挂载",
    "card_reveal_finder": "打开访达",
    "badge_secure_aes": "AES-256 加密",
    "badge_direct_mode": "直接映射"
]

// MARK: - 英文语言表 (English)
private let stringsEn: [String: String] = [
    // General
    "app_name": "CloudDrive",
    "cancel": "Cancel",
    "confirm": "Confirm",
    "done": "Done",
    "ok": "OK",
    "remove": "Remove",
    "delete": "Delete",
    "close": "Close",
    "open": "Open",
    "copy": "Copy",
    "copied": "Copied",
    "refresh": "Refresh",
    "success": "Success",
    "error": "Error",
    "warning": "Warning",
    "tip": "Notice",
    
    // Menu bar & status bar
    "menu_open_main_window": "Open Main Window",
    "menu_browse_in_finder": "Browse Cloud Storage in Finder",
    "menu_quit_app": "Quit CloudDrive",
    "menu_open_log_directory": "Open Log Directory",
    "menu_open_system_log": "Open System Log",
    "menu_open_file_ops_log": "Open File Operations Log",
    
    // Main UI & Toolbar
    "nav_subtitle_default": "End-to-End Encrypted Cloud Drive & Multi-Protocol Mount",
    "nav_subtitle_counts": "%d Vaults · %d Mounted",
    "toolbar_add_vault": "Add Vault",
    "toolbar_new_encrypted_vault": "New Encrypted Vault",
    "toolbar_open_existing_vault": "Open Existing Vault",
    "toolbar_direct_storage": "Direct Storage Mapping",
    "toolbar_refresh_tooltip": "Refresh files and mount status",
    "toolbar_settings_tooltip": "Preferences",
    
    // Vault cards & alerts
    "alert_vault_mounted_cannot_delete": "Vault \"%@\" is currently mounted. Please unmount it before removing.",
    "alert_confirm_remove_vault": "Remove Vault",
    "alert_confirm_remove_vault_msg": "Are you sure you want to remove vault \"%@\" from the list?\n\nThis operation only removes local configuration; your remote and local stored data will not be deleted.",
    "alert_confirm_unmount": "Confirm Unmount",
    "alert_confirm_unmount_msg": "Are you sure you want to unmount \"%@\"? You can remount it at any time.",
    "vault_status_mounted": "Mounted",
    "vault_status_unmounted": "Unmounted",
    "vault_status_encrypted": "AES-256 Encrypted",
    "vault_status_direct": "Direct Storage",
    "vault_status_local": "Local",
    "vault_card_open_in_finder": "Open in Finder",
    "vault_card_unmount": "Unmount",
    "vault_card_unmount_menu": "Unmount Vault",
    "vault_card_mount": "Mount",
    "vault_card_mount_menu": "Mount Vault",
    "vault_card_mounting": "Mounting...",
    "vault_card_remove_tooltip": "Remove from list",
    "vault_card_copy_path_tooltip": "Copy storage address",
    "vault_card_added_on": "Added on %@",
    "vault_card_edit": "Edit",
    "vault_card_edit_menu": "Edit Vault Info",
    "vault_edit_title": "Edit Vault Information",
    "vault_edit_auto_mount": "Auto-mount on app launch",
    "vault_edit_auto_mount_desc": "When enabled, CloudDrive will automatically unlock and mount this vault to Finder on launch",
    "vault_edit_save": "Save Changes",
    "vault_edit_remount_notice": "Vault is currently mounted. Changes to name or connection will take effect upon remount.",
    "vault_status_automount": "Auto-mount",
    "vault_status_manual": "Manual",
    "section_basic_info": "Basic Information",
    "section_storage_config": "Storage Connection",
    "section_encryption_security": "Encryption & Security",
    "field_vault_name": "Vault Name",
    "field_password_new_hint": "New connection password (leave empty to keep)",
    "field_password_keep_placeholder": "Leave empty to keep unchanged",
    "field_vault_password_update_hint": "New master password (leave empty to keep)",
    "menu_change_vault_password": "Change Vault Password...",
    "change_pwd_title": "Change Vault Master Password",
    "change_pwd_subtitle": "After verifying your current password, the masterkey file on the cloud will be re-encrypted and your Keychain updated. Existing files will not need to be re-encrypted.",
    "change_pwd_current": "Current Password",
    "change_pwd_current_placeholder": "Enter current vault password",
    "change_pwd_new": "New Password",
    "change_pwd_new_placeholder": "Enter new password (at least 8 chars)",
    "change_pwd_confirm": "Confirm New Password",
    "change_pwd_confirm_placeholder": "Re-enter new password",
    "change_pwd_submit": "Change Password",
    "change_pwd_submitting": "Updating cloud masterkey...",
    "change_pwd_success": "Password changed successfully! Cloud masterkey updated and local Keychain synchronized.",
    "change_pwd_err_length": "New password must be at least 8 characters long",
    "change_pwd_err_mismatch": "New passwords do not match",
    "change_pwd_err_same": "New password cannot be the same as the current password",
    "change_pwd_err_wrong_old": "Incorrect current password, please try again",
    "change_pwd_notice": "💡 Note: Official Cryptomator apps and other devices will require this new password to unlock. A masterkey.cryptomator.bkup backup has been created on the cloud.",
    "section_cloud_password": "Option B: Change Cloud Vault Password",
    "section_cloud_password_desc": "Re-encrypt the cloud masterkey file directly. Effective globally without re-encrypting files.",
    "btn_open_change_pwd": "Change Cloud Password...",
    "section_local_credential": "Option A: Update Locally Saved Credential",
    "section_local_credential_desc": "Fill in only if you modified the password on another device, to synchronize local auto-mount credentials. This will NOT modify the password on the cloud.",
    
    // Empty state cards
    "empty_welcome_title": "Welcome to CloudDrive",
    "empty_welcome_subtitle": "Securely mount encrypted cloud vaults & WebDAV / S3 / SMB / FTP folders as local drives",
    "empty_card_new_title": "New Encrypted Vault",
    "empty_card_new_desc": "Create an AES-256-GCM end-to-end encrypted vault in the cloud",
    "empty_card_new_btn": "Create Now",
    "empty_card_open_title": "Open Existing Vault",
    "empty_card_open_desc": "Open an existing Cryptomator or CloudDrive vault",
    "empty_card_open_btn": "Open Vault",
    "empty_card_direct_title": "Direct Storage Mapping",
    "empty_card_direct_desc": "Directly map remote folders without encryption for maximum speed",
    "empty_card_direct_btn": "Direct Connect",
    
    // Create / Open Vault
    "vault_mode_new": "New Encrypted Vault",
    "vault_mode_new_desc": "Create a brand new client-side encrypted vault (AES-256-GCM / Format 8) ensuring absolute privacy.",
    "vault_mode_open": "Open Existing Vault",
    "vault_mode_open_desc": "Open an existing Cryptomator or CloudDrive vault on remote storage.",
    "vault_mode_direct": "Direct Storage Mapping",
    "vault_mode_direct_desc": "Directly map remote storage (WebDAV / S3 / SMB / FTP) with on-demand sync and zero encryption overhead.",
    "section_operation_mode": "Operation Mode",
    "section_protocol_select": "Storage Protocol",
    "section_vault_info": "Vault Information",
    "vault_name_placeholder": "Vault Display Name",
    "vault_name_help": "Name displayed in application list and Finder sidebar",
    "section_encryption_pwd": "Set Vault Password (AES-256)",
    "vault_password_placeholder": "Vault Password",
    "vault_password_confirm_placeholder": "Confirm Password",
    "create_vault_pwd_min_hint": "Password must be at least 8 characters",
    "vault_password_mismatch": "Entered passwords do not match",
    "vault_password_warning": "Please remember this password! It is used to encrypt and decrypt all files. If lost, your data cannot be recovered.",
    "section_remote_path": "Remote Vault Folder Path",
    "remote_path_placeholder": "Remote path (e.g. / or /MyVault)",
    "remote_path_browse": "Browse Remote Folders...",
    "remote_path_tip": "Specify the path to the existing vault folder (typically contains masterkey.cryptomator and d folder).",
    "btn_test_connection": "Test Connection",
    "btn_testing_connection": "Testing Connection...",
    "btn_create_and_mount": "Create & Mount",
    "btn_open_and_mount": "Open & Mount",
    "btn_connect_and_mount": "Connect & Mount",
    "btn_creating": "Creating...",
    "btn_connecting": "Connecting...",
    
    // Protocol form
    "protocol_webdav_title": "WebDAV Server Configuration",
    "protocol_s3_title": "Amazon S3 / Object Storage Configuration",
    "protocol_smb_title": "SMB / Windows Network Share Configuration",
    "protocol_ftp_title": "FTP / FTPS Server Configuration",
    "protocol_pan123_title": "123 Cloud Drive Open Platform Configuration",
    "field_pan123_client_id": "Client ID (App ID)",
    "field_pan123_client_secret": "Client Secret",
    "field_pan123_token": "Access Token (Optional)",
    "field_pan123_root_id": "Root Folder ID (0 for root)",
    "field_pan123_tip": "Supports 123 Cloud Drive Open Platform API with chunked upload and deduplication",
    "field_pan123_root_path": "Root Path",
    "vault_edit_remount_title": "Configuration Updated",
    "vault_edit_remount_msg": "The vault is currently mounted. Remount now to apply the new configuration?",
    "vault_edit_remount_now": "Remount Now",
    "vault_edit_remount_later": "Later",
    "field_local_reselect": "Reselect Folder...",
    "field_webdav_url": "WebDAV Server URL",
    "field_username": "Username",
    "field_password": "Password",
    "field_s3_preset": "Provider Preset",
    "field_s3_endpoint": "Endpoint URL",
    "field_s3_region": "Region",
    "field_s3_bucket": "Bucket Name",
    "field_s3_access_key": "Access Key ID",
    "field_s3_secret_key": "Secret Access Key",
    "field_s3_prefix": "Root Prefix (Optional)",
    "field_s3_path_style": "Use Path-Style Addressing",
    "field_smb_host": "Host / IP Address",
    "field_smb_share": "Share Name",
    "field_smb_subpath": "Subpath",
    "field_smb_domain": "Workgroup / Domain (Optional)",
    "field_smb_port": "Port (Default 445)",
    "field_ftp_host": "FTP Host / IP Address",
    "field_ftp_port": "Port (Default 21)",
    "field_ftp_path": "Remote Working Directory",
    "field_ftp_tls": "Enable FTPS (TLS Secure Transfer)",
    
    // Unlock Dialog
    "unlock_title": "Unlock Encrypted Vault",
    "unlock_desc": "Please enter the master password for vault \"%@\" to unlock and mount to Finder",
    "unlock_password_placeholder": "Vault Password",
    "unlock_btn_unlock": "Unlock & Mount",
    "unlock_btn_unlocking": "Unlocking...",
    "unlock_storage_password_label": "%@ Storage Password",
    "unlock_storage_password_placeholder": "Storage connection password",
    "unlock_vault_password_label": "Vault Encryption Password",
    
    // Settings
    "settings_title": "Preferences",
    "tab_general": "General",
    "tab_cache": "Cache",
    "tab_recycle_bin": "Recycle Bin",
    "tab_logs": "Logs",
    "tab_about": "About",
    "recycle_bin_enable_title": "Enable Soft-Delete Recycle Bin",
    "recycle_bin_enable_desc": "Deleted files are moved to the Recycle Bin and can be restored at any time",
    "recycle_bin_filter_vault": "Vault Filter:",
    "recycle_bin_all_vaults": "All Vaults",
    "recycle_bin_search_placeholder": "Search deleted files...",
    "recycle_bin_summary": "%d items, %@ total",
    "recycle_bin_restore_all": "Restore All",
    "recycle_bin_empty": "Empty Trash",
    "recycle_bin_restore": "Restore",
    "recycle_bin_delete_forever": "Delete Permanently",
    "recycle_bin_empty_state_title": "Recycle Bin is Empty",
    "recycle_bin_empty_state_desc": "Files deleted from your vaults will be safely preserved here until permanently removed",
    "recycle_bin_deleted_at": "Deleted: %@",
    "recycle_bin_empty_confirm_title": "Empty Recycle Bin?",
    "recycle_bin_empty_confirm_msg": "All items in the Recycle Bin will be permanently deleted from the cloud. This action cannot be undone.",
    "recycle_bin_confirm_empty": "Empty",
    "recycle_bin_delete_confirm_title": "Permanently Delete Item?",
    "recycle_bin_delete_confirm_msg": "\"%@\" will be permanently deleted from the cloud. This action cannot be undone.",
    "recycle_bin_confirm_delete": "Delete Permanently",
    "vault_recycle_bin_section": "Recycle Bin Settings",
    "vault_recycle_bin_enable_toggle": "Enable Recycle Bin (Disabled by default)",
    "vault_recycle_bin_mode": "Recycle Bin Policy",
    "vault_recycle_bin_inherit": "Inherit Global Setting (Currently: %@)",
    "vault_recycle_bin_force_on": "Force Enabled for this Vault",
    "vault_recycle_bin_force_off": "Force Disabled (Delete Permanently)",
    "vault_recycle_bin_desc": "When enabled, trashing files moves them to the vault's Recycle Bin folder via zero-bandwidth cloud move and instantly frees local disk cache. When disabled, files are permanently deleted immediately.",
    "vault_recycle_bin_snapshot": "Preserve Local Cache Snapshots",
    "vault_recycle_bin_snapshot_desc": "Keep cached copies of deleted files for instantaneous, zero-bandwidth restoration",
    "vault_recycle_bin_retention": "Auto-Purge Expired Items",
    "vault_recycle_bin_retention_days": "Auto-purge after %d days",
    "vault_recycle_bin_retention_forever": "Keep Forever",
    "vault_recycle_bin_current_usage": "Currently recycled: %d items (%@)",
    "vault_recycle_bin_empty_now": "Empty This Vault's Trash Now",
    "enabled": "Enabled",
    "disabled": "Disabled",
    "settings_language": "App Language",
    "settings_language_desc": "Changes take effect immediately. Menus and views will update dynamically.",
    "settings_security": "Security",
    "settings_auto_lock": "Auto-lock vault when idle",
    "settings_lock_timeout": "Lock timeout:",
    "settings_lock_timeout_minutes": "%d minutes",
    "settings_auto_lock_desc": "Automatically unmount and lock encrypted vaults when system is idle to prevent unauthorized access.",
    "settings_cache_storage": "Local Storage & Cache",
    "settings_current_cache": "Current cache usage:",
    "settings_calculating": "Calculating...",
    "settings_clear_cache": "Clear Local Cache",
    "settings_clear_cache_desc": "Remove temporary cached files without affecting cloud files or unsaved changes",
    "settings_btn_clear_now": "Clear Now",
    "settings_alert_cache_cleared": "Cache Cleared",
    "about_app_desc": "End-to-End Encrypted Cloud Drive & Native macOS FileProvider Mount",
    "about_version": "Version 1.0.0 (Build 2026.10)",
    "about_feature_crypto": "AES-256-GCM",
    "about_feature_protocol": "Multi-Protocol (WebDAV/S3/SMB/FTP)",
    "about_feature_fileprovider": "Native FileProvider",
    "about_feature_cache": "Smart Local Cache",
    
    // Log Management
    "log_mgmt_title": "Module Log Monitoring",
    "log_mgmt_subtitle": "Open real-time log viewers and diagnostics for system modules",
    "log_btn_browse_dir": "Browse Log Directory",
    "log_btn_close_all": "Close All",
    "log_status_running": "Running",
    "log_btn_open": "Open",
    "log_btn_close": "Close",
    "log_search_placeholder": "Search logs",
    "log_records_count": "%d records",
    "log_not_found": "No logs found",
    "log_level_filter": "Log Level",
    "log_level_all": "All",
    "log_menu_copy": "Copy",
    "log_menu_copy_full": "Copy Full Log",
    "log_export": "Export Logs",
    "log_export_format": "Export Format",
    "log_export_count_desc": "Will export %d log records",
    "log_export_btn": "Export",
    "log_file_ops_panel_title": "File Operations",
    "log_file_ops_filter": "Filter",
    "log_file_ops_empty": "No file operations",
    "log_file_ops_clear_all": "Clear all operations",
    
    // Log Categories
    "cat_system": "System",
    "cat_system_desc": "System lifecycle & core events",
    "cat_file_ops": "File Operations",
    "cat_file_ops_desc": "Finder I/O, file creation & move operations",
    "cat_webdav": "Cloud Protocol",
    "cat_webdav_desc": "Remote requests, socket & network status",
    "cat_cache": "Cache",
    "cat_cache_desc": "Local chunk cache hits & eviction",
    "cat_database": "Database",
    "cat_database_desc": "Virtual file system SQLite metadata",
    "cat_sync": "Sync",
    "cat_sync_desc": "Background queue & cloud file synchronization",
    
    // Storage Protocol Names
    "protocol_name_webdav": "WebDAV",
    "protocol_name_s3": "Amazon S3 / Object Storage",
    "protocol_name_smb": "SMB / Windows Share",
    "protocol_name_ftp": "FTP / FTPS",
    "protocol_name_pan123": "123 Cloud Drive",
    "protocol_name_local": "Local Folder",
    
    // Vault Default Naming
    "vault_default_suffix_encrypted": "Encrypted Vault",
    "vault_default_suffix_vault": "Vault",
    "vault_default_suffix_storage": "Storage",
    "vault_default_name_encrypted": "Encrypted Vault",
    
    // S3 Provider Presets
    "s3_preset_custom": "Custom / MinIO",
    "s3_preset_aliyun": "Alibaba Cloud OSS",
    "s3_preset_tencent": "Tencent Cloud COS",
    
    // Connection Testing & Results
    "test_conn_success": "Connection successful!",
    "test_conn_failed_check": "Connection failed, please check configuration",
    "test_conn_failed": "Connection failed",
    "test_conn_success_cryptomator": "Connected successfully, detected standard Cryptomator vault!",
    "test_conn_success_clouddrive": "Connected successfully, detected CloudDrive encrypted vault!",
    "test_conn_success_vault_dir": "Connected successfully, detected encrypted vault directory!",
    "test_conn_no_config_found": "Connected successfully, but no vault configuration found in '%@'",
    
    // Remote Folder Picker
    "picker_title": "Select Cloud Folder",
    "picker_home_tooltip": "Go to Root Directory",
    "picker_up_tooltip": "Go to Parent Directory",
    "picker_vault_detected": "Encrypted vault detected in current directory!",
    "picker_vault_detected_desc": "Contains masterkey.cryptomator configuration file",
    "picker_select_current_dir": "Select Current Folder",
    "picker_loading": "Reading cloud directory...",
    "picker_load_failed": "Failed to read: %@",
    "picker_retry": "Retry",
    "picker_no_subfolders": "No subfolders in current directory",
    "picker_encrypted_vault_badge": "Encrypted Vault",
    "picker_enter": "Enter",
    "picker_select_this_vault": "Select This Vault",
    "picker_select": "Select",
    "picker_selected_path": "Selected Path: %@",
    "picker_select_current_dir_with_path": "Select Current Directory (%@)",
    
    // Log & File Operations Enhancements
    "log_auto_scroll": "Auto Scroll",
    "log_export_failed": "Export Failed",
    "log_export_type_text": "Plain Text",
    "file_op_status_pending": "Pending",
    "file_op_status_progress": "In Progress %d%%",
    "file_op_status_completed_duration": "Completed (%@s)",
    "file_op_status_completed": "Completed",
    "file_op_status_failed": "Failed",
    "file_op_status_cancelled": "Cancelled",
    "file_op_filter_in_progress": "In Progress",
    "file_op_filter_pending": "Pending",
    "file_op_filter_failed": "Failed",
    "file_op_type_create": "Create",
    "file_op_type_delete": "Delete",
    "file_op_type_move": "Move",
    "file_op_type_copy": "Copy",
    "file_op_type_upload": "Upload",
    "file_op_type_download": "Download",
    "file_op_type_modify": "Modify",
    "file_op_type_rename": "Rename",
    
    // AppState Authorization & Errors
    "appstate_panel_prompt": "Authorize Access",
    "appstate_panel_message": "Please grant CloudDrive access to this vault folder to mount it to Finder",
    "err_cannot_get_password": "Unable to obtain vault encryption password",
    "err_invalid_webdav_url": "Invalid WebDAV URL",
    "err_set_vault_password": "Please set vault encryption password",
    "err_enter_vault_password": "Please enter vault encryption password",
    "err_cannot_connect_webdav": "Unable to connect to WebDAV server, please check network or configuration",
    "err_conn_failed_webdav": "Connection failed: Unable to connect to WebDAV server",
    "err_vault_not_found": "Vault does not exist",
    "err_no_local_folder_auth": "Local folder access authorization not granted, cannot mount",
    "err_incomplete_vault_config": "Incomplete vault configuration",
    "err_cannot_get_webdav_password": "Unable to obtain WebDAV password, reconfiguration may be required",
    
    // Ignore Rules
    "tab_ignore_rules": "Ignore Rules",
    "ignore_section_builtin": "System Built-in Rules (Auto Protection)",
    "ignore_toggle_builtin": "Enable system metadata ignoring (e.g. .DS_Store, Thumbs.db)",
    "ignore_builtin_list_title": "View built-in ignore list (%d items)",
    "ignore_section_global": "Global Rules (Effective for all vaults)",
    "ignore_global_desc": "Rule syntax fully complies with .gitignore standard (e.g. target/, node_modules/, *.log, !keep.log)",
    "ignore_empty_custom": "No custom rules yet",
    "ignore_placeholder": "Add ignore pattern (e.g. node_modules/ or *.tmp)",
    "ignore_btn_add": "Add",
    "ignore_section_preset": "Developer Presets",
    "ignore_preset_title": "One-click add compilation & dependency ignore presets",
    "ignore_preset_desc": "Includes Node.js, Rust, Python, Java, Swift, Git build & cache rules",
    "ignore_btn_select_preset": "Select Preset Templates...",
    "preset_sheet_title": "Select Developer Ignore Presets",
    "preset_sheet_already_added": "Added",
    "preset_select_all": "Select All",
    "preset_deselect_all": "Deselect All",
    "preset_import_selected": "Import Selected Rules",
    
    // Cache Advanced Settings
    "cache_quota_title": "Maximum Cache Quota",
    "cache_quota_default": "%d GB (Default)",
    "cache_thumbnail_section": "Thumbnail Cache",
    "cache_thumbnail_size": "Thumbnail Cache Size",
    "cache_thumbnail_clear_title": "Clear Thumbnail Cache",
    "cache_thumbnail_clear_desc": "Clear all locally generated image, PDF and video thumbnail caches (does not affect file contents)",
    "cache_thumbnail_clear_btn": "Clear Now",
    "cache_pinned_section": "Pinned Files (Always Keep on This Mac)",
    "cache_pinned_count": "Currently Protected Items",
    "cache_pinned_items_unit": "%d items",
    "cache_pinned_unpin_all_title": "Unpin All Protected Files",
    "cache_pinned_unpin_all_desc": "Once unpinned, files will return to automatic management and participate in eviction during storage pressure",
    "cache_pinned_unpin_all_btn": "Unpin All",
    
    // Menu Bar Settings
    "menu_bar_settings_header": "Menu Bar & System Tray",
    "settings_menubar_toggle": "Show icon in macOS menu bar",
    "settings_menubar_toggle_desc": "When enabled, you can check vault statuses and mount/unmount anytime from the menu bar.",
    
    // Main UI Search & Filters
    "search_vaults_placeholder": "Search vault name or path...",
    "filter_all": "All",
    "filter_mounted": "Mounted",
    "filter_unmounted": "Unmounted",
    "filter_encrypted": "Encrypted",
    "filter_direct": "Direct Storage",
    "search_no_results": "No matching vaults found",
    "search_no_results_desc": "Try changing search keywords or resetting filters",
    "summary_total_vaults": "Total Vaults",
    "summary_mounted": "Mounted",
    "summary_encrypted": "Encrypted",
    "summary_direct": "Direct",
    
    // Local Storage
    "protocol_local_title": "Local Folder Configuration",
    "field_local_path": "Local Folder Path",
    "field_local_browse": "Browse Local Folder...",
    "field_local_browse_help": "Select a folder on your local drive, external disk, or USB",
    "local_folder_picker_prompt": "Select folder to use as vault",
    
    // Password Strength & Display
    "pwd_strength_label": "Password Strength:",
    "pwd_strength_weak": "Weak (At least 8 chars recommended)",
    "pwd_strength_medium": "Medium",
    "pwd_strength_strong": "Strong",
    "pwd_toggle_show": "Show password",
    "pwd_toggle_hide": "Hide password",
    
    // Status Bar Popover
    "popover_header_title": "CloudDrive Console",
    "popover_vaults_count": "%d Mounted · %d Total",
    "popover_no_vaults": "No configured vaults",
    "popover_quick_mount": "Mount",
    "popover_quick_unmount": "Unmount",
    "popover_open_main": "Open Main Window",
    "popover_open_finder": "Open in Finder",
    "popover_preferences": "Preferences...",
    "popover_quit": "Quit",
    "test_latency_ms": "Connected successfully (%d ms)",
    
    // Startup behavior settings
    "settings_startup_behavior": "Startup Behavior",
    "settings_startup_behavior_desc": "Configure CloudDrive launch preferences, including auto-mount, window display, and notification behavior.",
    "settings_show_main_on_launch": "Show main window on launch",
    "settings_auto_mount_on_launch": "Auto-mount tagged vaults on launch",
    "settings_confirm_before_unmount": "Show confirmation before unmounting",
    "settings_show_notifications": "Show mount / unmount notifications",
    
    // Form field hints (additions)
    "webdav_url_hint": "WebDAV URL must start with http:// or https://",
    "field_ftp_tls_on_hint": "FTPS encrypted transport enabled",
    
    // Sidebar & Modern Layout
    "sidebar_all_vaults": "All Vaults",
    "sidebar_mounted": "Mounted",
    "sidebar_unmounted": "Unmounted",
    "sidebar_encrypted": "Encrypted",
    "sidebar_direct": "Direct Storage",
    "sidebar_protocols": "Protocols",
    "sidebar_vaults": "Vaults",
    "sidebar_quick_add": "New Vault",
    "sidebar_preferences": "Preferences",
    "view_mode_grid": "Grid View",
    "view_mode_list": "List View",
    "card_auto_mount_on": "Auto-mount",
    "card_auto_mount_off": "Manual",
    "card_reveal_finder": "Open in Finder",
    "badge_secure_aes": "AES-256 Encrypted",
    "badge_direct_mode": "Direct Mode"
]

// MARK: - 存储类型国际化扩展
extension StorageType {
    public var localizedName: String {
        switch self {
        case .webdav: return L("protocol_name_webdav")
        case .s3: return L("protocol_name_s3")
        case .smb: return L("protocol_name_smb")
        case .ftp: return L("protocol_name_ftp")
        case .pan123: return L("protocol_name_pan123")
        case .local: return L("protocol_name_local")
        }
    }
}

// MARK: - 文件操作类型国际化扩展
extension FileOperationType {
    public var localizedDisplayName: String {
        switch self {
        case .create: return L("file_op_type_create")
        case .delete: return L("file_op_type_delete")
        case .move: return L("file_op_type_move")
        case .copy: return L("file_op_type_copy")
        case .upload: return L("file_op_type_upload")
        case .download: return L("file_op_type_download")
        case .modify: return L("file_op_type_modify")
        case .rename: return L("file_op_type_rename")
        }
    }
}


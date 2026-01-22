#!/bin/bash

# 移动调试相关文档
mv docs/CLOUDDRIVE_DEBUG_GUIDE.md docs/debug/debug-guide.md 2>/dev/null || echo "File not found: CLOUDDRIVE_DEBUG_GUIDE.md"
mv docs/CLOUDDRIVE_SYNC_DEBUG_MANUAL.md docs/debug/sync-debug-manual.md 2>/dev/null || echo "File not found: CLOUDDRIVE_SYNC_DEBUG_MANUAL.md"
mv docs/VIEW_LOGS.md docs/debug/view-logs.md 2>/dev/null || echo "File not found: VIEW_LOGS.md"

# 移动同步相关文档
mv docs/ADVANCED_SYNC_IMPLEMENTATION_SUMMARY.md docs/sync/advanced-sync-implementation-summary.md 2>/dev/null || echo "File not found: ADVANCED_SYNC_IMPLEMENTATION_SUMMARY.md"
mv docs/ADVANCED_SYNC_MECHANISMS.md docs/sync/advanced-sync-mechanisms.md 2>/dev/null || echo "File not found: ADVANCED_SYNC_MECHANISMS.md"
mv docs/SYNC_STATUS_IMPLEMENTATION.md docs/sync/sync-status-implementation.md 2>/dev/null || echo "File not found: SYNC_STATUS_IMPLEMENTATION.md"
mv docs/SYNC_OPERATIONS_FIX.md docs/sync/sync-operations-fix.md 2>/dev/null || echo "File not found: SYNC_OPERATIONS_FIX.md"
mv docs/SYNC_ISSUE_DIAGNOSIS_REPORT.md docs/sync/sync-issue-diagnosis-report.md 2>/dev/null || echo "File not found: SYNC_ISSUE_DIAGNOSIS_REPORT.md"
mv docs/FILE_SYNC_RULES_DOCUMENT.md docs/sync/file-sync-rules-document.md 2>/dev/null || echo "File not found: FILE_SYNC_RULES_DOCUMENT.md"
mv docs/DIRECT_MAPPING_IMPLEMENTATION.md docs/sync/direct-mapping-implementation.md 2>/dev/null || echo "File not found: DIRECT_MAPPING_IMPLEMENTATION.md"
mv docs/DIRECT_WEBDAV_MAPPING_DESIGN.md docs/sync/direct-webdav-mapping-design.md 2>/dev/null || echo "File not found: DIRECT_WEBDAV_MAPPING_DESIGN.md"

# 移动日志相关文档
mv docs/LOGGING_FIX.md docs/logging/logging-fix.md 2>/dev/null || echo "File not found: LOGGING_FIX.md"
mv docs/LOGGING_IMPROVEMENT_GUIDE.md docs/logging/logging-improvement-guide.md 2>/dev/null || echo "File not found: LOGGING_IMPROVEMENT_GUIDE.md"
mv docs/LOGGING_SYSTEM.md docs/logging/logging-system.md 2>/dev/null || echo "File not found: LOGGING_SYSTEM.md"
mv docs/LOGGING_VERIFICATION_REPORT.md docs/logging/logging-verification-report.md 2>/dev/null || echo "File not found: LOGGING_VERIFICATION_REPORT.md"
mv docs/CLOUD_ICON_AND_LOGGING_FIX.md docs/logging/cloud-icon-and-logging-fix.md 2>/dev/null || echo "File not found: CLOUD_ICON_AND_LOGGING_FIX.md"

# 移动错误处理相关文档
mv docs/FILEPROVIDER_ERROR_FIX.md docs/error_handling/fileprovider-error-fix.md 2>/dev/null || echo "File not found: FILEPROVIDER_ERROR_FIX.md"
mv docs/FILEPROVIDER_ERROR_DOMAIN_FIX.md docs/error_handling/fileprovider-error-domain-fix.md 2>/dev/null || echo "File not found: FILEPROVIDER_ERROR_DOMAIN_FIX.md"
mv docs/CONFLICT_RESOLUTION_ERROR_HANDLING.md docs/error_handling/conflict-resolution-error-handling.md 2>/dev/null || echo "File not found: CONFLICT_RESOLUTION_ERROR_HANDLING.md"
mv docs/SYSTEM_ISSUES_AND_FIXES.md docs/error_handling/system-issues-and-fixes.md 2>/dev/null || echo "File not found: SYSTEM_ISSUES_AND_FIXES.md"
mv docs/COMPILE_ERRORS_FIX.md docs/error_handling/compile-errors-fix.md 2>/dev/null || echo "File not found: COMPILE_ERRORS_FIX.md"

# 移动文件上传下载相关文档
mv docs/FILE_UPLOAD_FIX.md docs/sync/file-upload-fix.md 2>/dev/null || echo "File not found: FILE_UPLOAD_FIX.md"
mv docs/FILE_DOWNLOAD_404_FIX.md docs/sync/file-download-404-fix.md 2>/dev/null || echo "File not found: FILE_DOWNLOAD_404_FIX.md"
mv docs/LOCAL_FILE_UPLOAD_FIX.md docs/sync/local-file-upload-fix.md 2>/dev/null || echo "File not found: LOCAL_FILE_UPLOAD_FIX.md"
mv docs/LOCAL_FILE_UPLOAD_COMPLETE_FIX.md docs/sync/local-file-upload-complete-fix.md 2>/dev/null || echo "File not found: LOCAL_FILE_UPLOAD_COMPLETE_FIX.md"
mv docs/LOCAL_FILE_UPLOAD_DIAGNOSIS.md docs/sync/local-file-upload-diagnosis.md 2>/dev/null || echo "File not found: LOCAL_FILE_UPLOAD_DIAGNOSIS.md"

# 移动FileProvider相关文档
mv docs/FILE_PROVIDER_COMMUNICATION_FIX.md docs/sync/fileprovider-communication-fix.md 2>/dev/null || echo "File not found: FILE_PROVIDER_COMMUNICATION_FIX.md"
mv docs/FIX_FILE_PROVIDER_COMMUNICATION.md docs/sync/fileprovider-communication-fix.md 2>/dev/null || echo "File not found: FIX_FILE_PROVIDER_COMMUNICATION.md"
mv docs/TEST_FILE_PROVIDER_SYNC.md docs/testing/test-fileprovider-sync.md 2>/dev/null || echo "File not found: TEST_FILE_PROVIDER_SYNC.md"
mv docs/VAULT_MOUNT_STATUS_FIX.md docs/sync/vault-mount-status-fix.md 2>/dev/null || echo "File not found: VAULT_MOUNT_STATUS_FIX.md"

# 移动数据库相关文档
mv docs/DATABASE_INTEGRITY_FIX.md docs/sync/database-integrity-fix.md 2>/dev/null || echo "File not found: DATABASE_INTEGRITY_FIX.md"
mv docs/DELETE_OPERATION_FIX.md docs/sync/delete-operation-fix.md 2>/dev/null || echo "File not found: DELETE_OPERATION_FIX.md"
mv docs/DELETE_TIMEOUT_FIX.md docs/sync/delete-timeout-fix.md 2>/dev/null || echo "File not found: DELETE_TIMEOUT_FIX.md"

# 移动设置和启动相关文档
mv docs/QUICK_SETUP.md docs/setup/quick-setup.md 2>/dev/null || echo "File not found: QUICK_SETUP.md"
mv docs/READY_TO_BUILD.md docs/setup/ready-to-build.md 2>/dev/null || echo "File not found: READY_TO_BUILD.md"
mv docs/BUILD_STATUS.md docs/setup/build-status.md 2>/dev/null || echo "File not found: BUILD_STATUS.md"

# 移动测试相关文档
mv docs/SUCCESS_VERIFICATION.md docs/testing/success-verification.md 2>/dev/null || echo "File not found: SUCCESS_VERIFICATION.md"
mv docs/COMPLETE_FLOW_VERIFICATION.md docs/testing/complete-flow-verification.md 2>/dev/null || echo "File not found: COMPLETE_FLOW_VERIFICATION.md"
mv docs/WEBDAV_CONNECTION_TEST.md docs/testing/webdav-connection-test.md 2>/dev/null || echo "File not found: WEBDAV_CONNECTION_TEST.md"

# 移动最终版本相关文档
mv docs/FINAL_FIX_SUMMARY.md docs/sync/final-fix-summary.md 2>/dev/null || echo "File not found: FINAL_FIX_SUMMARY.md"
mv docs/FINAL_IMPLEMENTATION_SUMMARY.md docs/sync/final-implementation-summary.md 2>/dev/null || echo "File not found: FINAL_IMPLEMENTATION_SUMMARY.md"
mv docs/FINAL_SUCCESS_CONFIRMATION.md docs/sync/final-success-confirmation.md 2>/dev/null || echo "File not found: FINAL_SUCCESS_CONFIRMATION.md"
mv docs/COMPLETE_FIX_SUMMARY.md docs/sync/complete-fix-summary.md 2>/dev/null || echo "File not found: COMPLETE_FIX_SUMMARY.md"
mv docs/FIXES.md docs/sync/fixes.md 2>/dev/null || echo "File not found: FIXES.md"
mv docs/LOGIC_ERRORS_FIXED_SUMMARY.md docs/sync/logic-errors-fixed-summary.md 2>/dev/null || echo "File not found: LOGIC_ERRORS_FIXED_SUMMARY.md"

# 移动其他功能相关文档
mv docs/ICLOUD_LIKE_FEATURES.md docs/sync/icloud-like-features.md 2>/dev/null || echo "File not found: ICLOUD_LIKE_FEATURES.md"
mv docs/README.md docs/setup/readme.md 2>/dev/null || echo "File not found: README.md"
mv docs/README_EN.md docs/setup/readme-en.md 2>/dev/null || echo "File not found: README_EN.md"

echo "Document organization completed."

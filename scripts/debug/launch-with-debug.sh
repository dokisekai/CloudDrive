#!/bin/bash

# CloudDrive 调试启动脚本

APP_PATH="$HOME/Library/Developer/Xcode/DerivedData/CloudDrive-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX/Build/Products/Debug/CloudDrive.app"
LOG_FILE="$HOME/Desktop/CloudDrive_debug.log"

echo "=== CloudDrive Debug Launch ===" | tee "$LOG_FILE"
echo "Time: $(date)" | tee -a "$LOG_FILE"
echo "App Path: $APP_PATH" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"

# 在后台启动日志监控
echo "Starting log stream..." | tee -a "$LOG_FILE"
log stream --predicate 'processImagePath contains "CloudDrive"' --level debug >> "$LOG_FILE" 2>&1 &
LOG_PID=$!

# 等待一秒
sleep 1

# 启动应用
echo "Launching CloudDrive..." | tee -a "$LOG_FILE"
open "$APP_PATH"

echo "" | tee -a "$LOG_FILE"
echo "✅ CloudDrive launched!" | tee -a "$LOG_FILE"
echo "📝 Logs are being written to: $LOG_FILE" | tee -a "$LOG_FILE"
echo "📁 App logs also in: ~/Documents/CloudDrive.log" | tee -a "$LOG_FILE"
echo "" | tee -a "$LOG_FILE"
echo "Press Ctrl+C to stop log monitoring..." | tee -a "$LOG_FILE"

# 等待用户中断
wait $LOG_PID
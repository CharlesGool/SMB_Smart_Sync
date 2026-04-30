#!/system/bin/sh
MODDIR=${0%/*}

# 定义基础目录
PHOTOS_DIR="/storage/emulated/0/DCIM/GBackup/"
LOG_FILE="/storage/emulated/0/,A Files/sync.log"
CONF_DIR="/storage/emulated/0/SMB_Sync"
CONF_FILE="$CONF_DIR/config.conf"

# 创建日志文件夹(如果不存在)
mkdir -p "/storage/emulated/0/,A Files"

# 日志函数
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "$LOG_FILE"
}
# 错误日志函数
log_err() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> "$LOG_FILE"
}

# --- 核心安全防线：捕捉进程终止信号，防止唤醒锁泄漏 ---
trap 'echo "Magisk_SMB_Sync_Lock" > /sys/power/wake_unlock; log_info "服务被系统或用户终止，已安全释放唤醒锁。"; exit 0' TERM INT HUP QUIT

# 硬件限制函数(限制CPU最高2.0Ghz,锁定最低亮度)
apply_hardware_limits() {
    MSM_PERF_PATH="/sys/module/msm_performance/parameters/cpu_max_freq"
    if [ -f "$MSM_PERF_PATH" ]; then
        chmod 644 "$MSM_PERF_PATH" 2>/dev/null
        echo "0:2000000 1:2000000 2:2000000 3:2000000 4:2000000 5:2000000 6:2000000 7:2000000" > "$MSM_PERF_PATH" 2>/dev/null
    fi
    settings put system screen_brightness 1
}

# 开始相册同步函数(唤醒屏幕+发送媒体扫描广播+重启GoolePhotos)
wake_and_show_photos() {
    log_info "唤醒屏幕中"
    input keyevent KEYCODE_WAKEUP
    wm dismiss-keyguard 2>/dev/null || input keyevent 82
    log_info "发送媒体扫描广播中,休眠2s"
    am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://$1" >/dev/null 2>&1	
    sleep 2
    log_info "重启GoolePhotos中"
    am force-stop com.google.android.apps.photos
    monkey -p com.google.android.apps.photos -c android.intent.category.LAUNCHER 1 > /dev/null 2>&1
}

# 检测屏幕文字函数
check_ui_backup_status() {
    local xml_file="/data/local/tmp/view.xml"
    
    uiautomator dump "$xml_file" >/dev/null 2>&1
    
    if [ ! -f "$xml_file" ]; then
        log_err "UI Dump 失败，路径无法访问"
        return 1
    fi

    # 使用配置文件中的变量匹配文字
    if grep -q "$BACKUP_SUCCESS_TEXT" "$xml_file"; then
        log_info "UI 界面显示「$BACKUP_SUCCESS_TEXT」"
        return 0
    fi
	
    return 1
}

# 智能检测同步进程函数
wait_for_sync_and_sleep() {
    log_info "进入 UI 监控模式，等待 Google Photos 响应..."
    sleep 5

    while true; do
        sleep 5
        log_info "开始扫描屏幕"
        if check_ui_backup_status; then
            am force-stop com.google.android.apps.photos
            log_info "同步完成,退出相册"
            break
        fi
    done
    
    local screen_state=$(dumpsys power | grep 'mWakefulness=' | grep -o 'Awake')
    if [ "$screen_state" = "Awake" ]; then
        input keyevent 26
        log_info "已自动锁屏"
    else
        log_info "已自动锁屏"
    fi
}

# 配置文件检查与加载函数
check_and_load_config() {
    if [ ! -f "$CONF_FILE" ]; then
        log_info "未检测到配置文件，正在生成模板..."
        mkdir -p "$CONF_DIR"
        cat <<EOF > "$CONF_FILE"
# ==========================================
# Magisk SMB Sync 配置文件
# ==========================================

# SMB 服务器 IP 地址
SMB_HOST="192.168.0.2"

# SMB 用户名 (请务必修改此项以启动脚本)
SMB_USER="your_username"

# SMB 密码
SMB_PASS="your_password"

# SMB 服务器端的照片基础目录 (无需开头斜杠，无需包含年份/月份)
# 例如：Data/Photos/Camera
SMB_REMOTE_DIR="Data/Photos/Camera"

# 轮询扫描间隔时间 (秒)
# 默认 3 秒。如果不需要极高实时性，建议改大(如 60)以节省性能
SCAN_INTERVAL=3

# Google Photos 备份完成时的 UI 提示文字
# 繁体中文: 備份完成 | 简体中文: 备份完成 | 英文: Backup complete
BACKUP_SUCCESS_TEXT="備份完成"
EOF
        log_info "配置文件已生成至 $CONF_FILE"
    fi

    # 循环等待用户修改配置文件（检测 your_username 是否被替换）
    while grep -q 'SMB_USER="your_username"' "$CONF_FILE"; do
        log_info "等待用户填写配置文件: $CONF_FILE ，脚本暂停执行..."
        sleep 30
    done

    # 读取配置文件
    . "$CONF_FILE"
    
    log_info "配置加载成功 -> 目标: $SMB_HOST, 目录: $SMB_REMOTE_DIR, 间隔: ${SCAN_INTERVAL}s, 匹配文本: $BACKUP_SUCCESS_TEXT"
}

# 程序正式启动
log_info "SMB Sync 已启动"

# 等待系统底层就绪
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    log_info "安卓系统已启动,等待系统初始化"
    sleep 10
done

# 等待内部存储挂载，确保配置目录可以被写入
while [ ! -d "/storage/emulated/0" ]; do
    log_info "等待 /storage/emulated/0 挂载..."
    sleep 5
done

# 加载配置文件
check_and_load_config

# 创建照片文件夹
mkdir -p "$PHOTOS_DIR" 2>>"$LOG_FILE"

# 申请 CPU 永久唤醒锁
echo "Magisk_SMB_Sync_Lock" > /sys/power/wake_lock
log_info "CPU 唤醒锁已激活,SMB文件扫描将无视息屏"

# 禁用自动息屏
settings put system screen_off_timeout 2147483647

# 执行硬件限制
apply_hardware_limits

# 部署rclone
cp "$MODDIR/rclone" /data/local/tmp/rclone_worker 2>>"$LOG_FILE"
chmod 777 /data/local/tmp/rclone_worker
RCLONE="/data/local/tmp/rclone_worker"

# 配置 SMB (使用配置文件中读取的变量)
RCLONE_CONF="/data/local/tmp/rclone.conf"
touch "$RCLONE_CONF" 2>>"$LOG_FILE"
export RCLONE_CONFIG_MYSMB_TYPE=smb
export RCLONE_CONFIG_MYSMB_HOST=$SMB_HOST
export RCLONE_CONFIG_MYSMB_USER=$SMB_USER
OBSCURED_PASS=$($RCLONE --config "$RCLONE_CONF" obscure "$SMB_PASS" 2>>"$LOG_FILE")

# 执行密码混淆
if [ $? -eq 0 ]; then
    export RCLONE_CONFIG_MYSMB_PASS=$OBSCURED_PASS
else
    log_err "密码混淆失败，强制退出！"
    exit 1
fi

log_info ">>> 一切正常,系统初始化完成 <<<"

# 核心业务
while true; do
    CUR_Y=$(date +%Y)
    CUR_M=$(date +%m | sed 's/^0*//')
    
    # 清理当月之前的所有文件夹
    for yr_dir in "$PHOTOS_DIR"/*; do
        [ ! -d "$yr_dir" ] && continue
        yr=$(basename "$yr_dir")
        for mo_dir in "$yr_dir"/*; do
            [ ! -d "$mo_dir" ] && continue
            mo=$(basename "$mo_dir")
            cur_m_no_zero=$(echo $CUR_M | sed 's/^0*//')
            mo_no_zero=$(echo $mo | sed 's/^0*//')
            if [ "$yr" -lt "$CUR_Y" ] || { [ "$yr" -eq "$CUR_Y" ] && [ "$mo_no_zero" -lt "$cur_m_no_zero" ]; }; then
                rm -rf "$mo_dir" 2>>"$LOG_FILE"
                log_info "发现过时数据，已清理: $yr/$mo"
            fi
        done
        rmdir "$yr_dir" 2>/dev/null
    done

    # 执行Rclone同步
    if ping -c 1 -W 3 $SMB_HOST > /dev/null 2>&1; then
        # 拼接动态 SMB 目录
        REMOTE_PATH="mysmb:${SMB_REMOTE_DIR}/$CUR_Y/$CUR_M"
        LOCAL_PATH="$PHOTOS_DIR/$CUR_Y/$CUR_M"
        mkdir -p "$LOCAL_PATH" 2>/dev/null
        
        RCLONE_TMP_LOG="/data/local/tmp/rclone_run.log"
        
        $RCLONE --config "$RCLONE_CONF" copy "$REMOTE_PATH" "$LOCAL_PATH" \
            --ignore-existing \
            --size-only \
            --multi-thread-streams 4 \
            --buffer-size 16M \
            --contimeout 5s \
            --timeout 30s \
            --verbose > "$RCLONE_TMP_LOG" 2>&1
            
        RCLONE_EXIT_CODE=$?
        COPY_COUNT=$(grep -c "Copied" "$RCLONE_TMP_LOG")

        if [ $RCLONE_EXIT_CODE -eq 0 ]; then
            if [ "$COPY_COUNT" -gt 0 ]; then
                log_info "同步完成! | 同步了 $COPY_COUNT 个新文件"
                grep "Copied" "$RCLONE_TMP_LOG" >> "$LOG_FILE"
                chown -R media_rw:media_rw "$LOCAL_PATH" 2>/dev/null
                chmod -R 775 "$LOCAL_PATH" 2>/dev/null
                
                wake_and_show_photos "$LOCAL_PATH"
                wait_for_sync_and_sleep
            fi
        else
            log_err "rclone 异常退出 (Exit Code: $RCLONE_EXIT_CODE)！"
            grep -i "error" "$RCLONE_TMP_LOG" >> "$LOG_FILE"
        fi
    fi
	
    apply_hardware_limits
    
    # LOG大小限制
    LOG_SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt 1048576 ]; then
        tail -n 10000 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv -f "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
    
    # 使用配置文件中的自定义轮询间隔
    sleep "$SCAN_INTERVAL"
	
done
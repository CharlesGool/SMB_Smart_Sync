#!/system/bin/sh
MODDIR=${0%/*}

# 唯一需要硬编码的基础配置目录 (用于寻找配置文件)
CONF_DIR="/storage/emulated/0/SMB_Smart_Sync"
CONF_FILE="$CONF_DIR/config.conf"

# ==========================================
# 日志系统 (根据 RUN_MODE 动态分级)
# ==========================================
log_debug() {
    # 只有在 debug 模式下才输出的高频日志
    if [ "$RUN_MODE" = "debug" ]; then
        local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1"
        [ -n "$LOCAL_LOG_FILE" ] && echo "$msg" >> "$LOCAL_LOG_FILE" || echo "$msg"
    fi
}

log_info() {
    # 关键业务日志 (Release和Debug都会输出)
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"
    [ -n "$LOCAL_LOG_FILE" ] && echo "$msg" >> "$LOCAL_LOG_FILE" || echo "$msg"
}

log_err() {
    # 错误日志
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1"
    [ -n "$LOCAL_LOG_FILE" ] && echo "$msg" >> "$LOCAL_LOG_FILE" || echo "$msg"
}

# --- 核心安全防线：捕捉进程终止信号，防止唤醒锁泄漏 ---
trap 'echo "Magisk_SMB_Sync_Lock" > /sys/power/wake_unlock; log_info "服务被系统终止，已安全释放唤醒锁。"; exit 0' TERM INT HUP QUIT

# ==========================================
# 核心功能函数
# ==========================================

# 硬件限制函数(由配置文件动态控制频率和亮度)
apply_hardware_limits() {
    MSM_PERF_PATH="/sys/module/msm_performance/parameters/cpu_max_freq"
    if [ -f "$MSM_PERF_PATH" ]; then
        chmod 644 "$MSM_PERF_PATH" 2>/dev/null
        # 动态生成8个核心的限频指令
        echo "0:${CPU_MAX_FREQ} 1:${CPU_MAX_FREQ} 2:${CPU_MAX_FREQ} 3:${CPU_MAX_FREQ} 4:${CPU_MAX_FREQ} 5:${CPU_MAX_FREQ} 6:${CPU_MAX_FREQ} 7:${CPU_MAX_FREQ}" > "$MSM_PERF_PATH" 2>/dev/null
    fi
    settings put system screen_brightness "$SCREEN_BRIGHTNESS"
}

# 开始相册同步函数
wake_and_show_photos() {
    log_info "唤醒屏幕并拉起 Google Photos..."
    input keyevent KEYCODE_WAKEUP
    wm dismiss-keyguard 2>/dev/null || input keyevent 82
    
    log_debug "发送媒体扫描广播中, 休眠2s..."
    am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://$1" >/dev/null 2>&1	
    sleep 2
    
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

    if grep -q "$BACKUP_SUCCESS_TEXT" "$xml_file"; then
        log_info "已检测到「$BACKUP_SUCCESS_TEXT」，云端备份完毕"
        return 0
    fi
    return 1
}

# 智能检测同步进程函数
wait_for_sync_and_sleep() {
    log_debug "进入 UI 监控模式，等待 Google Photos 响应..."
    sleep 5

    while true; do
        sleep 5
        log_debug "扫描屏幕状态中..."
        if check_ui_backup_status; then
            am force-stop com.google.android.apps.photos
            log_info "任务闭环完成，退出相册"
            break
        fi
    done
    
    local screen_state=$(dumpsys power | grep 'mWakefulness=' | grep -o 'Awake')
    if [ "$screen_state" = "Awake" ]; then
        input keyevent 26
        log_info "已自动锁屏休眠"
    else
        log_debug "屏幕已处于休眠状态，无需操作"
    fi
}

# 配置文件检查与加载函数
check_and_load_config() {
    if [ ! -f "$CONF_FILE" ]; then
        mkdir -p "$CONF_DIR"
        cat <<EOF > "$CONF_FILE"
# ==========================================
# Magisk SMB Sync 全局配置文件
# ==========================================

# -----------------
# 0. 运行模式设置
# -----------------
# release: 纯净模式，仅输出关键结果和错误 (日常使用推荐)
# debug:   调试模式，输出所有轮询、比对、等待的详细日志 (排障时使用) 请确保服务正常运行再切换到release模式
RUN_MODE="debug"

# -----------------
# 1. SMB 服务器设置
# -----------------
SMB_HOST="192.168.0.1"
# SMB 用户名 (请务必修改此项以启动脚本)
SMB_USER="your_username"
SMB_PASS="your_password"
# SMB 服务器端的照片基础目录 (无需开头斜杠)
SMB_REMOTE_DIR="Data/Photos/Camera"

# -----------------
# 2. 本地路径与日志设置
# -----------------
# 落盘到手机的目录路径
LOCAL_PHOTOS_DIR="/storage/emulated/0/DCIM/GBackup/"
# 日志文件路径
LOCAL_LOG_FILE="/storage/emulated/0/SMB_Smart_Sync/sync.log"
# 日志文件大小上限 (字节，默认 1048576 = 1MB)
MAX_LOG_SIZE=1048576

# -----------------
# 3. 运行逻辑与 UI 匹配
# -----------------
# 轮询扫描间隔时间 (秒)
SCAN_INTERVAL=3
# Google Photos 备份完成时的 UI 提示文字 EN: Backup complete | ZH-TW: 備份完成 | ZH-CN: 备份完成
BACKUP_SUCCESS_TEXT="備份完成"

# -----------------
# 4. 硬件与性能控制
# -----------------
# 息屏运行时的 CPU 最高频率限制 (单位 KHz，2000000 = 2.0GHz)
CPU_MAX_FREQ="2000000"
# 息屏运行时的屏幕亮度限制 (范围通常 1~255，1最暗)
SCREEN_BRIGHTNESS="1"

# -----------------
# 5. Rclone 传输微调
# -----------------
# 多线程并发数量 (默认 4，局域网NAS可适当调大)
RCLONE_STREAMS="4"
# 单文件内存缓存大小 (默认 16M，提升碎片文件读取性能)
RCLONE_BUFFER="16M"

# -----------------
# 6. 数据清理设置
# -----------------
# 是否自动清理上个月及更早的本地历史照片数据 (true: 开启 | false: 关闭)
# 开启后，脚本会每月自动删除旧文件夹，释放手机空间
ENABLE_AUTO_CLEANUP="false"
EOF
        echo "[INFO] 配置文件已生成至 $CONF_FILE"
    fi

    # 循环等待用户修改配置文件
    while grep -q 'SMB_USER="your_username"' "$CONF_FILE"; do
        echo "[INFO] 挂起: 等待用户填写配置文件 $CONF_FILE ..."
        sleep 30
    done

    # 读取配置文件
    . "$CONF_FILE"
    
    # 兼容旧版本配置文件：如果用户使用的是未包含清理开关的旧配置，默认赋予 true
    [ -z "$ENABLE_AUTO_CLEANUP" ] && ENABLE_AUTO_CLEANUP="true"
    
    # 根据配置文件的路径创建基础目录
    mkdir -p "$(dirname "$LOCAL_LOG_FILE")"
    mkdir -p "$LOCAL_PHOTOS_DIR"
    
    log_info "=== 模块配置加载成功 ==="
    log_info "模式: [$RUN_MODE] | 目标: $SMB_HOST | 间隔: ${SCAN_INTERVAL}s | 自动清理: $ENABLE_AUTO_CLEANUP"
}

# ==========================================
# 主程序启动逻辑
# ==========================================

# 等待系统底层就绪
until [ "$(getprop sys.boot_completed)" = "1" ]; do
    sleep 10
done

# 等待内部存储挂载，确保配置目录可以被写入
while [ ! -d "/storage/emulated/0" ]; do
    sleep 5
done

# 核心初始化
check_and_load_config

# 申请 CPU 永久唤醒锁
echo "Magisk_SMB_Sync_Lock" > /sys/power/wake_lock
log_info "CPU 唤醒锁已激活, 守护进程就绪"

# 禁用自动息屏
settings put system screen_off_timeout 2147483647

# 部署 rclone
cp "$MODDIR/rclone" /data/local/tmp/rclone_worker 2>>"$LOCAL_LOG_FILE"
chmod 777 /data/local/tmp/rclone_worker
RCLONE="/data/local/tmp/rclone_worker"

# 配置 SMB 环境
RCLONE_CONF="/data/local/tmp/rclone.conf"
touch "$RCLONE_CONF" 2>>"$LOCAL_LOG_FILE"
export RCLONE_CONFIG_MYSMB_TYPE=smb
export RCLONE_CONFIG_MYSMB_HOST=$SMB_HOST
export RCLONE_CONFIG_MYSMB_USER=$SMB_USER
OBSCURED_PASS=$($RCLONE --config "$RCLONE_CONF" obscure "$SMB_PASS" 2>>"$LOCAL_LOG_FILE")

if [ $? -eq 0 ]; then
    export RCLONE_CONFIG_MYSMB_PASS=$OBSCURED_PASS
else
    log_err "SMB 密码混淆失败，请检查配置文件密码格式！"
    exit 1
fi

apply_hardware_limits
log_info ">>> 系统初始化完成，进入轮询守护状态 <<<"

# ==========================================
# 核心业务循环
# ==========================================
while true; do
    log_debug "--- 唤醒轮询周期 ---"
    CUR_Y=$(date +%Y)
    CUR_M=$(date +%m | sed 's/^0*//')
    
    # 1. 历史数据清理逻辑 (由开关控制)
    if [ "$ENABLE_AUTO_CLEANUP" = "true" ]; then
        for yr_dir in "$LOCAL_PHOTOS_DIR"/*; do
            [ ! -d "$yr_dir" ] && continue
            yr=$(basename "$yr_dir")
            for mo_dir in "$yr_dir"/*; do
                [ ! -d "$mo_dir" ] && continue
                mo=$(basename "$mo_dir")
                cur_m_no_zero=$(echo $CUR_M | sed 's/^0*//')
                mo_no_zero=$(echo $mo | sed 's/^0*//')
                if [ "$yr" -lt "$CUR_Y" ] || { [ "$yr" -eq "$CUR_Y" ] && [ "$mo_no_zero" -lt "$cur_m_no_zero" ]; }; then
                    rm -rf "$mo_dir" 2>>"$LOCAL_LOG_FILE"
                    log_info "已清理过时数据: $yr/$mo"
                fi
            done
            rmdir "$yr_dir" 2>/dev/null
        done
    else
        log_debug "历史数据自动清理已关闭，跳过。"
    fi

    # 2. Rclone 同步逻辑
    log_debug "探测网络连通性..."
    if ping -c 1 -W 3 $SMB_HOST > /dev/null 2>&1; then
        log_debug "网络 OK，执行远端目录比对..."
        
        REMOTE_PATH="mysmb:${SMB_REMOTE_DIR}/$CUR_Y/$CUR_M"
        LOCAL_PATH="$LOCAL_PHOTOS_DIR/$CUR_Y/$CUR_M"
        mkdir -p "$LOCAL_PATH" 2>/dev/null
        
        RCLONE_TMP_LOG="/data/local/tmp/rclone_run.log"
        
        # 动态应用 Rclone 参数配置
        $RCLONE --config "$RCLONE_CONF" copy "$REMOTE_PATH" "$LOCAL_PATH" \
            --ignore-existing \
            --size-only \
            --multi-thread-streams "$RCLONE_STREAMS" \
            --buffer-size "$RCLONE_BUFFER" \
            --contimeout 5s \
            --timeout 30s \
            --verbose > "$RCLONE_TMP_LOG" 2>&1
            
        RCLONE_EXIT_CODE=$?
        COPY_COUNT=$(grep -c "Copied" "$RCLONE_TMP_LOG")

        if [ $RCLONE_EXIT_CODE -eq 0 ]; then
            if [ "$COPY_COUNT" -gt 0 ]; then
                log_info "★★ 同步完成 | 抓取了 $COPY_COUNT 个新文件 ★★"
                
                # 仅在 Debug 模式下将具体哪些文件被拉取写入主日志
                if [ "$RUN_MODE" = "debug" ]; then
                    grep "Copied" "$RCLONE_TMP_LOG" >> "$LOCAL_LOG_FILE"
                fi
                
                chown -R media_rw:media_rw "$LOCAL_PATH" 2>/dev/null
                chmod -R 775 "$LOCAL_PATH" 2>/dev/null
                
                wake_and_show_photos "$LOCAL_PATH"
                wait_for_sync_and_sleep
            else
                log_debug "目录结构完全一致，无新照片。"
            fi
        else
            log_err "Rclone 进程异常退出 (Code: $RCLONE_EXIT_CODE)！"
            grep -i "error" "$RCLONE_TMP_LOG" >> "$LOCAL_LOG_FILE"
        fi
    else
        log_debug "无法连接至 SMB 服务器，跳过本次同步。"
    fi
	
    # 3. 硬件恢复与休眠
    log_debug "重置底层硬件限制..."
    apply_hardware_limits
    
    # 动态日志大小限制
    LOG_SIZE=$(wc -c < "$LOCAL_LOG_FILE" 2>/dev/null || echo 0)
    if [ "$LOG_SIZE" -gt "$MAX_LOG_SIZE" ]; then
        log_info "日志触发容量上限，自动裁剪历史记录..."
        tail -n 10000 "$LOCAL_LOG_FILE" > "${LOCAL_LOG_FILE}.tmp" 2>/dev/null && mv -f "${LOCAL_LOG_FILE}.tmp" "$LOCAL_LOG_FILE"
    fi
    
    log_debug "挂起 $SCAN_INTERVAL 秒..."
    sleep "$SCAN_INTERVAL"
	
done
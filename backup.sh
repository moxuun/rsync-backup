#!/bin/bash

# =================================================================
# VPS -> NAS 自动备份脚本 (v5)
# =================================================================

# --- 1. 基础配置 ---
# 如果设为 "true"，则只在本地打包，不连接 NAS，不执行同步和远程清理
MIGRATION_ONLY="false"
# NAS 登录用户名、IP、目标备份目录
NAS_USER="admin"
NAS_HOST="192.168.1.2"
NAS_TARGET_DIR="/mnt/Storage1/vps"
# 本地临时备份保存目录
LOCAL_TEMP_ROOT="/tmp/vps_backups"

# 备份保留天数
RETENTION_DAYS=30

# --- 2. 备份对象 ---
CONTAINERS_TO_STOP="nginx"
VOLUMES_TO_BACKUP=""
DIRS_TO_BACKUP="/opt/nginx"

# --- 3. Telegram 配置 ---
TG_BOT_TOKEN="你的_BOT_TOKEN"
TG_CHAT_ID="你的_CHAT_ID"

# -----------------------------------------------------------------

export TZ='Asia/Shanghai'
DATE=$(date +%Y%m%d_%H%M%S)
HOSTNAME=$(hostname)
LOCAL_BACKUP_DIR="${LOCAL_TEMP_ROOT}/${DATE}"
REPORT_DETAILS="" # 用于收集备份过程中的详细信息

# --- 核心通知函数 ---
# 使用 --data-urlencode 解决复杂字符和换行问题
send_notification() {
    local status_icon="$1"
    local title="$2"
    local content="$3"
    
    # 构造 HTML 文本，使用 <b> 替代 * 避免下划线解析错误
    local full_message="${status_icon} <b>${title}</b> (${HOSTNAME})
---------------------------
${content}"

    if [ -n "${TG_BOT_TOKEN}" ] && [ -n "${TG_CHAT_ID}" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TG_CHAT_ID}" \
            -d "parse_mode=HTML" \
            --data-urlencode "text=${full_message}" > /dev/null
    fi
}

echo "--- 任务启动: ${DATE} ---"

# 0. 环境预检查
if [ "$MIGRATION_ONLY" != "true" ]; then
    if ! ssh -q -o BatchMode=yes -o ConnectTimeout=5 "${NAS_USER}@${NAS_HOST}" exit; then
        send_notification "❌" "备份中止" "原因: 无法通过 SSH 连接到 NAS (${NAS_HOST})"
        exit 1
    fi
fi

# 1. 目录准备
mkdir -p "${LOCAL_BACKUP_DIR}"

# 2. 停止容器 (冷备份)
if [ -n "${CONTAINERS_TO_STOP}" ]; then
    echo ">> 正在停止容器: ${CONTAINERS_TO_STOP}"
    docker stop ${CONTAINERS_TO_STOP} > /dev/null
fi

# 3. 打包 Docker 卷
for VOLUME in ${VOLUMES_TO_BACKUP}; do
    if docker volume inspect "${VOLUME}" > /dev/null 2>&1; then
        docker run --rm -v "${VOLUME}:/source_data:ro" -v "${LOCAL_BACKUP_DIR}:/target" \
            alpine tar -czf "/target/vol_${VOLUME}.tar.gz" -C /source_data .
        # 使用换行符替代 \n 确保在 TG 中正确换行
        REPORT_DETAILS="${REPORT_DETAILS}✅ 卷: ${VOLUME}
"
    else
        REPORT_DETAILS="${REPORT_DETAILS}⚠️ 卷不存在: ${VOLUME}
"
    fi
done

# 4. 打包物理文件夹
for DIR in ${DIRS_TO_BACKUP}; do
    if [ -d "${DIR}" ]; then
        D_NAME=$(basename "${DIR}")
        cd "$(dirname "${DIR}")" && tar -czf "${LOCAL_BACKUP_DIR}/dir_${D_NAME}.tar.gz" --exclude='logs' "${D_NAME}"
        REPORT_DETAILS="${REPORT_DETAILS}✅ 目录: ${DIR}
"
    else
        REPORT_DETAILS="${REPORT_DETAILS}⚠️ 目录不存在: ${DIR}
"
    fi
done

# 5. 立即恢复容器 
if [ -n "${CONTAINERS_TO_STOP}" ]; then
    echo ">> 正在恢复容器"
    docker start ${CONTAINERS_TO_STOP} > /dev/null
fi

# 6. 计算备份统计信息
BACKUP_SIZE=$(du -sh "${LOCAL_BACKUP_DIR}" | awk '{print $1}')

# 7. 传输与远程清理
if [ "$MIGRATION_ONLY" = "true" ]; then
    send_notification "📦" "迁移包就绪" "大小: ${BACKUP_SIZE}
路径: ${LOCAL_BACKUP_DIR}

<b>请手动处理后续迁移</b>"
else
    echo ">> 同步至 NAS..."
    rsync -av --timeout=600 "${LOCAL_BACKUP_DIR}" "${NAS_USER}@${NAS_HOST}:${NAS_TARGET_DIR}/"
    
    if [ $? -eq 0 ]; then
        # 成功后的后续操作
        rm -rf "${LOCAL_BACKUP_DIR}"
        ssh "${NAS_USER}@${NAS_HOST}" "find ${NAS_TARGET_DIR} -maxdepth 1 -type d -name '20*' -mtime +${RETENTION_DAYS} -exec rm -rf {} \;"
        
        # 汇总最终报告并发送
        SUCCESS_MSG="<b>时间:</b> ${DATE}
<b>大小:</b> ${BACKUP_SIZE}
<b>保留:</b> ${RETENTION_DAYS} 天
<b>明细:</b>
${REPORT_DETAILS}"
        send_notification "✅" "备份成功" "${SUCCESS_MSG}"
    else
        send_notification "❌" "备份失败" "原因: Rsync 同步过程中出错"
        exit 1
    fi
fi

echo "--- 任务结束 ---"

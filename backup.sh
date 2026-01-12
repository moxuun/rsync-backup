#!/bin/bash

# =================================================================
# VPS ->  NAS 自动备份脚本 (Rsync 版)
# =================================================================

# --- 1. NAS 配置 ---
NAS_USER="admin"
NAS_HOST="192.168.1.2"
# !!! 注意: 请修改为你 Armbian 上实际的大硬盘挂载路径 !!!
NAS_TARGET_DIR="/mnt/Storage1/vps"

# --- 2. 本地配置 ---
# 临时打包目录 (建议放在剩余空间足够的路径)
LOCAL_TEMP_ROOT="/tmp/vps_backups"

# --- 3. 容器配置 (备份期间需要暂停的容器) ---
# 确保包含数据库容器，以保证数据一致性
CONTAINERS_TO_STOP="nginx "

# --- 4. 需要备份的内容 ---
# A. Docker 数据卷 (空格分隔)
VOLUMES_TO_BACKUP=""

# B. 普通文件夹 (空格分隔，绝对路径)
DIRS_TO_BACKUP="/opt/nginx"

# --- 5. 远程保留策略 ---
# 在 NAS 上保留最近多少天的备份
RETENTION_DAYS=30

# -----------------------------------------------------------------

# 设置环境变量
export TZ='Asia/Shanghai'
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="${DATE}"
LOCAL_BACKUP_DIR="${LOCAL_TEMP_ROOT}/${BACKUP_NAME}"

echo "====================================="
echo "[开始] 任务启动: $(date)"
echo "[模式] Rsync over SSH (Target: ${NAS_HOST})"

# 0. 预检查: 测试 SSH 连接是否通畅
ssh -q -o BatchMode=yes -o ConnectTimeout=5 "${NAS_USER}@${NAS_HOST}" exit
if [ $? -ne 0 ]; then
    echo "[致命错误] 无法连接到 NAS (${NAS_HOST})。请检查网络或密钥设置。"
    exit 1
fi

# 1. 准备本地临时目录
mkdir -p "${LOCAL_BACKUP_DIR}"

# 2. 停止关键容器 (冷备份模式)
if [ -n "${CONTAINERS_TO_STOP}" ]; then
    echo ">> [Step 1] 暂停关键容器..."
    docker stop ${CONTAINERS_TO_STOP}
fi

# 3. 打包 Docker 卷
if [ -n "${VOLUMES_TO_BACKUP}" ]; then
    echo ">> [Step 2] 打包 Docker 数据卷..."
    for VOLUME in ${VOLUMES_TO_BACKUP}; do
        # 检查卷是否存在
        if docker volume inspect "${VOLUME}" > /dev/null 2>&1; then
            docker run --rm \
                -v "${VOLUME}:/source_data:ro" \
                -v "${LOCAL_BACKUP_DIR}:/backup_target" \
                alpine tar -czf "/backup_target/${VOLUME}.tar.gz" -C /source_data .
            echo "   - 卷 ${VOLUME} 已打包"
        else
            echo "   ! 警告: 卷 ${VOLUME} 不存在，跳过"
        fi
    done
fi

# 4. 打包普通文件夹
if [ -n "${DIRS_TO_BACKUP}" ]; then
    echo ">> [Step 3] 打包指定文件夹..."
    for DIR_PATH in ${DIRS_TO_BACKUP}; do
        if [ -d "${DIR_PATH}" ]; then
            DIR_NAME=$(basename "${DIR_PATH}")
            # 进入父目录打包，避免包含绝对路径
            cd "$(dirname "${DIR_PATH}")" && \
            tar -czf "${LOCAL_BACKUP_DIR}/${DIR_NAME}_folder.tar.gz" --exclude='logs' "${DIR_NAME}"
            echo "   - 目录 ${DIR_PATH} 已打包"
        else
            echo "   ! 警告: 目录 ${DIR_PATH} 不存在，跳过"
        fi
    done
fi

# 5. 立即恢复容器 (减少业务中断时间)
if [ -n "${CONTAINERS_TO_STOP}" ]; then
    echo ">> [Step 4] 恢复业务容器..."
    docker start ${CONTAINERS_TO_STOP}
fi

# 6. Rsync 推送到 NAS
echo ">> [Step 5] 同步文件到 NAS..."
# -a: 归档模式
# -v: 显示详情
# --timeout: 防止网络卡死
# --rsync-path: 如果 NAS 的 rsync 不在标准路径，可能需要指定，通常不需要
rsync -av --timeout=600 -e ssh \
    "${LOCAL_BACKUP_DIR}" \
    "${NAS_USER}@${NAS_HOST}:${NAS_TARGET_DIR}/"

if [ $? -eq 0 ]; then
    echo "   [成功] 数据已传输至 NAS。"
    
    # 7. 清理本地临时文件
    echo ">> [Step 6] 清理本地临时缓存..."
    rm -rf "${LOCAL_TEMP_ROOT}"
    
    # 8. 远程清理过期备份 (Armbian 标准 Linux 方式)
    echo ">> [Step 7] 清理 NAS 上的旧备份 (保留 ${RETENTION_DAYS} 天)..."
    # 使用 ssh 远程执行 find 命令
    ssh "${NAS_USER}@${NAS_HOST}" "find ${NAS_TARGET_DIR} -maxdepth 1 -type d -name '20*' -mtime +${RETENTION_DAYS} -exec rm -rf {} \;"
    
    echo "====================================="
    echo "[完成] 备份任务圆满结束: $(date)"
else
    echo "====================================="
    echo "[失败] Rsync 传输过程中发生错误！"
    echo "本地备份文件仍保留在: ${LOCAL_BACKUP_DIR} 以防万一。"
    exit 1
fi

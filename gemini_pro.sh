#!/bin/bash
# ------------------------------------------------------------------------------
# High-Performance Gemini API Key Batch Management Tool v2.0 (Extreme Edition)
# Author: ddddd (https://github.com/dddddd1)
#
# Optimization Focus: Extreme speed and stability through a three-stage 
# asynchronous pipeline for project creation and key extraction.
#
# WARNING: Aggressive use of this script may lead to GCP account restrictions.
#          Use responsibly and be mindful of your quotas.
# ------------------------------------------------------------------------------

# ===== Global Configuration =====
VERSION="2.0-Extreme"
# 动态调整并行任务数。建议范围: 20-50。请根据您的机器性能和网络状况调整。
: "${MAX_PARALLEL_JOBS:=30}" 
# 临时文件和输出目录
TEMP_DIR=$(mktemp -d)
OUTPUT_DIR="${PWD}/gemini_keys_$(date +%Y%m%d_%H%M%S)"
DETAILED_LOG_FILE="${OUTPUT_DIR}/detailed_run.log"

# Shell退出时自动清理临时文件
trap 'rm -rf "${TEMP_DIR}"' EXIT

# ===== Styling and Logging =====
# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Logging function with timestamps and color
log() {
    local type="$1"
    local message="$2"
    local color="${NC}"
    case "$type" in
        INFO) color="${CYAN}" ;;
        SUCCESS) color="${GREEN}" ;;
        WARN) color="${YELLOW}" ;;
        ERROR) color="${RED}" ;;
    esac
    # 同步写入日志文件，避免并行输出混乱
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') [${type}] ${message}" | tee -a "${DETAILED_LOG_FILE}"
    # 在控制台输出带颜色的信息
    echo -e "${color}$(date '+%Y-%m-%d %H:%M:%S') [${type}] ${message}${NC}" >&2
}

# Yes/No prompt function
ask_yes_no() {
    while true; do
        read -r -p "$1 [y/N]: " response
        case "$response" in
            [yY][eE][sS]|[yY]) return 0 ;;
            [nN][oO]|[nN]|"") return 1 ;;
            *) echo "Please answer yes or no." >&2 ;;
        esac
    done
}

# ===== Core Utility Functions =====

# 检查gcloud环境和alpha组件
setup_environment() {
    mkdir -p "$OUTPUT_DIR"
    touch "${TEMP_DIR}/log.lock" # 用于文件写入锁
    log "INFO" "临时目录: ${TEMP_DIR}"
    log "INFO" "输出目录: ${OUTPUT_DIR}"

    log "INFO" "正在检查 gcloud 工具..."
    if ! command -v gcloud &> /dev/null; then
        log "ERROR" "gcloud command not found. 请安装 Google Cloud SDK."
        exit 1
    fi

    log "INFO" "正在检查 gcloud alpha 组件..."
    if ! gcloud alpha --version >/dev/null 2>&1; then
        log "WARN" "gcloud alpha 组件未安装或未配置。"
        log "INFO" "正在尝试自动安装 gcloud alpha 组件..."
        if ! gcloud components install alpha -q; then
           log "ERROR" "自动安装 alpha 组件失败。请手动运行 'gcloud components install alpha'."
           exit 1
        fi
        log "SUCCESS" "gcloud alpha 组件安装成功。"
    fi
}

check_gcp_env() {
    log "INFO" "正在检查 GCP 认证和计费状态..."
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "."; then
        log "ERROR" "GCP 账户未登录。请先运行 'gcloud auth login' 和 'gcloud config set project'。"
        exit 1
    fi
    if ! gcloud billing projects list --billing-account="$(gcloud billing accounts list --filter=open=true --format='value(name)' | head -n 1)" --format="value(projectId)" | grep -q "."; then
        log "WARN" "当前账户可能没有有效的结算账户或项目与之关联。大规模创建项目可能会失败。"
        if ! ask_yes_no "是否仍要继续?"; then
            exit 0
        fi
    fi
    log "SUCCESS" "GCP 环境检查通过。"
}

# 生成唯一的项目ID
new_project_id() {
    local prefix="$1"
    # 使用纳秒+4位随机数确保高并发下的唯一性
    echo "${prefix}-$(date +%s%N | rev | cut -c 1-10)-${RANDOM:0:4}"
}

# 带重试逻辑的gcloud命令执行器
smart_retry_gcloud() {
    local retries=3
    local delay=5
    for ((i=1; i<=retries; i++)); do
        if "$@"; then
            return 0
        fi
        log "WARN" "命令执行失败: '$*'. 第 ${i}/${retries} 次重试..."
        sleep $((delay * i))
    done
    return 1
}

# 原子化地写入密钥到文件，防止并行写入冲突
write_key_atomic() {
    local api_key="$1"
    local pure_key_file="$2"
    local comma_key_file="$3"
    local lock_file="${TEMP_DIR}/log.lock"

    (
        flock -x 200 # 使用文件锁，确保原子性
        echo "$api_key" >> "$pure_key_file"
        # 读取现有文件，添加新key，然后写回
        local current_keys
        current_keys=$(cat "$comma_key_file")
        if [ -z "$current_keys" ]; then
            echo -n "$api_key" > "$comma_key_file"
        else
            echo -n "${current_keys},${api_key}" > "$comma_key_file"
        fi
    ) 200>"$lock_file"
}

# ===== EXTREME MODE: 3-Stage Asynchronous Workflow =====

# --- STAGE 1: 异步派发项目创建任务 ---
dispatch_project_creation_tasks() {
    local projects_to_create=("$@")
    local total_tasks=${#projects_to_create[@]}
    local log_prefix="[Stage 1: Dispatch]"
    
    log "INFO" "${log_prefix} 开始异步派发 ${total_tasks} 个项目创建任务..."
    local operations_log="${TEMP_DIR}/creation_operations.log"
    > "$operations_log"

    for i in "${!projects_to_create[@]}"; do
        local project_id="${projects_to_create[i]}"
        # 使用 --async 标志，让gcloud立即返回operation ID，而不是等待项目创建完成
        gcloud projects create "$project_id" --name="$project_id" --quiet --async \
          --format='value(name)' >> "$operations_log" 2>> "${DETAILED_LOG_FILE}" &
        
        # 控制派发速率，防止瞬间请求过多被API拒绝
        if (( (i + 1) % MAX_PARALLEL_JOBS == 0 )); then
            wait
        fi
    done
    wait
    log "SUCCESS" "${log_prefix} 所有 ${total_tasks} 个项目创建任务已派发至 GCP 后端。"
}

# --- STAGE 2: 等待并验证项目创建结果 ---
wait_for_creation_operations() {
    local operations_log="$1"
    local successfully_created_log="$2"
    local log_prefix="[Stage 2: Verify]"
    
    mapfile -t operations < "$operations_log"
    if [ ${#operations[@]} -eq 0 ]; then
        log "WARN" "${log_prefix} 没有找到任何需要等待的创建操作。"
        return
    fi

    log "INFO" "${log_prefix} 正在并行等待 ${#operations[@]} 个项目创建操作完成... (这可能需要几分钟)"
    
    local job_count=0
    for op in "${operations[@]}"; do
        {
            # 等待操作完成，设置600秒超时
            if gcloud alpha services operations wait "$op" --timeout=600 >/dev/null 2>&1; then
                # 操作成功后，从中提取项目ID
                project_id=$(gcloud alpha services operations describe "$op" --format='value(metadata.resourceNames)' 2>/dev/null | sed 's/projects\///')
                if [ -n "$project_id" ]; then
                    log "SUCCESS" "${log_prefix} 项目 [${project_id}] 创建成功。"
                    echo "$project_id" >> "$successfully_created_log"
                else
                    log "ERROR" "${log_prefix} 操作 '${op}' 成功，但无法解析项目ID。"
                    echo "$op" >> "${TEMP_DIR}/failed_parse.log"
                fi
            else
                log "ERROR" "${log_prefix} 操作 '${op}' 失败或超时。"
                echo "$op" >> "${TEMP_DIR}/failed_operations.log"
            fi
        } &
        job_count=$((job_count + 1))
        if [ "$job_count" -ge "$MAX_PARALLEL_JOBS" ]; then
            wait -n || true
            job_count=$((job_count - 1))
        fi
    done
    wait
    log "SUCCESS" "${log_prefix} 所有项目创建操作已检查完毕。"
}

# --- STAGE 3: 为成功创建的项目启用API并提取密钥 ---
process_successful_projects() {
    local projects_file="$1"
    local pure_key_file="$2"
    local comma_key_file="$3"

    mapfile -t projects_to_process < "$projects_file"
    local total_tasks=${#projects_to_process[@]}
    if [ "$total_tasks" -eq 0 ]; then
        log "WARN" "[Stage 3: Process] 没有成功创建的项目可供处理。"
        return
    fi
    
    log "INFO" "[Stage 3: Process] 开始为 ${total_tasks} 个项目启用API并创建密钥..."
    
    # 初始化成功和失败日志
    > "${TEMP_DIR}/success.log"
    > "${TEMP_DIR}/failed.log"

    local job_count=0
    for i in "${!projects_to_process[@]}"; do
        local project_id="${projects_to_process[i]}"
        {
            local log_prefix="[${i+1}/${total_tasks}] [${project_id}]"
            
            # 启用API
            if ! smart_retry_gcloud gcloud services enable generativelanguage.googleapis.com --project="$project_id" --quiet >/dev/null 2>&1; then
                log "ERROR" "${log_prefix} 启用API失败。"
                echo "$project_id" >> "${TEMP_DIR}/failed.log"
            else
                log "INFO" "${log_prefix} API启用成功。正在创建密钥..."
                # 创建密钥
                api_key=$(gcloud alpha services api-keys create --project="$project_id" --display-name="Gemini-Key-Auto" --format="value(keyString)" 2>> "${DETAILED_LOG_FILE}")
                
                if [ -n "$api_key" ]; then
                    write_key_atomic "$api_key" "$pure_key_file" "$comma_key_file"
                    log "SUCCESS" "${log_prefix} 成功获取密钥并已保存！"
                    echo "$project_id" >> "${TEMP_DIR}/success.log"
                else
                    log "WARN" "${log_prefix} 获取密钥失败。将尝试删除此项目。"
                    smart_retry_gcloud gcloud projects delete "$project_id" --quiet >/dev/null 2>&1 || true
                    echo "$project_id" >> "${TEMP_DIR}/failed.log"
                fi
            fi
        } &

        job_count=$((job_count + 1))
        if [ "$job_count" -ge "$MAX_PARALLEL_JOBS" ]; then
            wait -n || true # 等待任何一个后台任务结束
            job_count=$((job_count - 1))
        fi
    done
    wait
    log "INFO" "[Stage 3: Process] 所有项目处理完毕。"
}

# ===== Orchestration Functions =====

gemini_batch_create_keys() {
    log "INFO" "====== 高性能批量创建 Gemini API 密钥 (极限模式) ======"
    local num_projects
    read -r -p "请输入要创建的项目数量 (例如: 50): " num_projects
    if ! [[ "$num_projects" =~ ^[1-9][0-9]*$ ]]; then
        log "ERROR" "无效的数字。请输入一个大于0的整数。"
        return
    fi
    local project_prefix
    read -r -p "请输入项目前缀 (默认: gemini-pro): " project_prefix
    project_prefix=${project_prefix:-gemini-pro}
    
    echo -e "\n${YELLOW}${BOLD}=== 操作确认 ===${NC}" >&2
    echo -e "  计划创建项目数: ${BOLD}${num_projects}${NC}" >&2
    echo -e "  项目前缀:       ${BOLD}${project_prefix}${NC}" >&2
    echo -e "  并行任务数:     ${BOLD}${MAX_PARALLEL_JOBS}${NC}" >&2
    echo -e "  输出目录:       ${BOLD}${OUTPUT_DIR}${NC}" >&2
    echo -e "${RED}警告: 大规模创建项目可能违反GCP服务条款或超出配额。${NC}" >&2
    if ! ask_yes_no "确认要继续吗?"; then
        log "INFO" "操作已取消。"
        return
    fi

    local projects_to_create=()
    for ((i=1; i<=num_projects; i++)); do
        projects_to_create+=("$(new_project_id "$project_prefix")")
    done
    
    # 执行三阶段工作流
    local successfully_created_log="${TEMP_DIR}/creation_success.log"
    > "$successfully_created_log"
    
    dispatch_project_creation_tasks "${projects_to_create[@]}"
    wait_for_creation_operations "${TEMP_DIR}/creation_operations.log" "$successfully_created_log"
    
    local pure_key_file="${OUTPUT_DIR}/all_keys.txt"
    local comma_key_file="${OUTPUT_DIR}/all_keys_comma_separated.txt"
    > "$pure_key_file"
    > "$comma_key_file"
    process_successful_projects "$successfully_created_log" "$pure_key_file" "$comma_key_file"

    report_and_download_results "$comma_key_file" "$pure_key_file"
}

gemini_extract_from_existing() {
    log "INFO" "====== 从现有项目提取 Gemini API 密钥 ======"
    log "INFO" "正在获取您账户下的所有活跃项目列表..."
    mapfile -t all_projects < <(gcloud projects list --filter='lifecycleState:ACTIVE' --format='value(projectId)' 2>/dev/null)

    if [ ${#all_projects[@]} -eq 0 ]; then
        log "ERROR" "未找到任何活跃项目。"
        return
    fi
    
    log "INFO" "找到 ${#all_projects[@]} 个活跃项目。请选择要处理的项目:"
    for i in "${!all_projects[@]}"; do
        printf "  %3d. %s\n" "$((i+1))" "${all_projects[i]}" >&2
    done

    read -r -p "请输入项目编号 (多个用空格隔开，或输入 'all' 处理全部): " -a selections
    
    local projects_to_process=()
    if [[ " ${selections[*],,} " =~ " all " ]]; then
        projects_to_process=("${all_projects[@]}")
    else
        for num in "${selections[@]}"; do
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#all_projects[@]}" ]; then
                projects_to_process+=("${all_projects[$((num-1))]}")
            else
                log "WARN" "无效的编号: $num，已忽略。"
            fi
        done
    fi

    if [ ${#projects_to_process[@]} -eq 0 ]; then
        log "ERROR" "未选择任何有效项目。"
        return
    fi

    echo -e "\n${YELLOW}${BOLD}=== 操作确认 ===${NC}" >&2
    echo -e "  将为 ${#projects_to_process[@]} 个现有项目提取新密钥。" >&2
    echo -e "  并行任务数:     ${BOLD}${MAX_PARALLEL_JOBS}${NC}" >&2
    echo -e "  输出目录:       ${BOLD}${OUTPUT_DIR}${NC}" >&2
    if ! ask_yes_no "确认要继续吗?"; then
        log "INFO" "操作已取消。"
        return
    fi
    
    # 复用Stage 3的处理逻辑
    local projects_file="${TEMP_DIR}/existing_projects_to_process.txt"
    printf "%s\n" "${projects_to_process[@]}" > "$projects_file"

    local pure_key_file="${OUTPUT_DIR}/all_keys.txt"
    local comma_key_file="${OUTPUT_DIR}/all_keys_comma_separated.txt"
    > "$pure_key_file"
    > "$comma_key_file"
    process_successful_projects "$projects_file" "$pure_key_file" "$comma_key_file"
    
    report_and_download_results "$comma_key_file" "$pure_key_file"
}

gemini_batch_delete_projects() {
    log "INFO" "====== 批量删除项目 ======"
    mapfile -t projects < <(gcloud projects list --filter='lifecycleState:ACTIVE' --format='value(projectId)' 2>/dev/null)
    if [ ${#projects[@]} -eq 0 ]; then
        log "ERROR" "未找到任何活跃项目。"
        return
    fi
    
    read -r -p "请输入要删除的项目前缀 (留空则匹配所有): " prefix

    local projects_to_delete=()
    for proj in "${projects[@]}"; do
        if [[ "$proj" == "${prefix}"* ]]; then
            projects_to_delete+=("$proj")
        fi
    done

    if [ ${#projects_to_delete[@]} -eq 0 ]; then
        log "WARN" "没有找到任何项目匹配前缀: '${prefix}'"
        return
    fi

    echo -e "\n${YELLOW}将要删除以下 ${#projects_to_delete[@]} 个项目:${NC}" >&2
    printf ' - %s\n' "${projects_to_delete[@]}" | head -n 20 >&2
    if [ ${#projects_to_delete[@]} -gt 20 ]; then
        echo "   ... 等等" >&2
    fi

    echo -e "\n${RED}${BOLD}!!! 警告：此操作不可逆 !!!${NC}" >&2
    read -r -p "请输入 'DELETE' 来确认删除: " confirmation
    if [ "$confirmation" != "DELETE" ]; then
        log "INFO" "删除操作已取消。"
        return
    fi

    local delete_success_log="${TEMP_DIR}/delete_success.log"
    local delete_failed_log="${TEMP_DIR}/delete_failed.log"
    >"$delete_success_log" >"$delete_failed_log"

    log "INFO" "开始批量删除任务..."
    
    local job_count=0
    for project_id in "${projects_to_delete[@]}"; do
        {
            if smart_retry_gcloud gcloud projects delete "$project_id" --quiet; then
                log "SUCCESS" "项目 [${project_id}] 删除成功。"
                echo "$project_id" >> "$delete_success_log"
            else
                log "ERROR" "项目 [${project_id}] 删除失败。"
                echo "$project_id" >> "$delete_failed_log"
            fi
        } &
        job_count=$((job_count + 1))
        if [ "$job_count" -ge "$MAX_PARALLEL_JOBS" ]; then
            wait -n || true
            job_count=$((job_count - 1))
        fi
    done
    
    wait
    local success_count=$(wc -l < "$delete_success_log" | tr -d ' ')
    local failed_count=$(wc -l < "$delete_failed_log" | tr -d ' ')

    echo -e "\n${GREEN}${BOLD}====== 批量删除完成 ======${NC}" >&2
    log "SUCCESS" "成功删除: ${success_count}"
    log "ERROR" "删除失败: ${failed_count}"
}

report_and_download_results() {
    local comma_key_file="$1"
    local pure_key_file="$2"
    local success_count
    local failed_count
    
    # 确保日志文件存在
    touch "${TEMP_DIR}/success.log" "${TEMP_DIR}/failed.log"

    success_count=$(wc -l < "${TEMP_DIR}/success.log" | tr -d ' ')
    failed_count=$(wc -l < "${TEMP_DIR}/failed.log" | tr -d ' ')

    echo -e "\n${GREEN}${BOLD}====== 操作完成：统计结果 ======${NC}" >&2
    log "SUCCESS" "成功获取密钥的项目数: ${success_count}"
    log "ERROR" "失败的项目数: ${failed_count}"
    
    if [ "$success_count" -gt 0 ]; then
        echo -e "\n${PURPLE}======================================================" >&2
        echo -e "      ✨ 最终API密钥 (逗号分隔，可直接复制) ✨" >&2
        echo -e "======================================================${NC}" >&2
        echo -e "${GREEN}${BOLD}" >&2
        cat "$comma_key_file" >&2
        echo -e "\n${NC}${PURPLE}======================================================${NC}\n" >&2

        log "INFO" "以上密钥已完整保存至目录: ${BOLD}${OUTPUT_DIR}${NC}"
        log "INFO" "逗号分隔密钥文件: ${BOLD}${comma_key_file}${NC}"
        log "INFO" "每行一个密钥文件: ${BOLD}${pure_key_file}${NC}"
        
        if [ -n "${DEVSHELL_PROJECT_ID-}" ] && command -v cloudshell &>/dev/null; then
            log "INFO" "检测到 Cloud Shell 环境，将自动触发下载..."
            cloudshell download "$comma_key_file"
            cloudshell download "$pure_key_file"
            log "SUCCESS" "下载提示已发送。"
        fi
    fi
    if [ "$failed_count" -gt 0 ];
    then
        log "WARN" "失败的项目ID列表保存在详细日志中: ${DETAILED_LOG_FILE}"
    fi
}

show_main_menu() {
    clear
    echo -e "${PURPLE}${BOLD}" >&2
    cat >&2 << "EOF"
  ____ ____ ____ ____ ____ ____ _________ ____ ____ ____ 
 ||G |||e |||m |||i |||n |||i |||       |||K |||e |||y ||
 ||__|||__|||__|||__|||__|||__|||_______|||__|||__|||__||
 |/__\|/__\|/__\|/__\|/__\|/__\|/_______\|/__\|/__\|/__\|
EOF
    echo -e "      高性能 Gemini API 密钥批量管理工具 ${BOLD}v${VERSION}${NC}" >&2
    echo -e "-----------------------------------------------------" >&2
    echo -e "${YELLOW}  作者: ddddd (脚本完全免费分享，请勿倒卖)${NC}" >&2
    echo -e "-----------------------------------------------------" >&2
    local account
    account=$(gcloud config get-value account 2>/dev/null || echo "未登录")
    echo -e "  当前账户: ${CYAN}${account}${NC}" >&2
    echo -e "  并行任务: ${CYAN}${MAX_PARALLEL_JOBS}${NC}" >&2
    echo -e "-----------------------------------------------------" >&2
    echo -e "\n${RED}${BOLD}请注意：滥用此脚本可能导致您的GCP账户受限。${NC}\n" >&2
    echo "  1. 批量创建新项目并提取密钥 (极限模式)" >&2
    echo "  2. 从现有项目中提取 API 密钥" >&2
    echo "  3. 批量删除指定前缀的项目" >&2
    echo "  0. 退出脚本" >&2
    echo "" >&2
}

main_app() {
    while true;
    do
        show_main_menu
        read -r -p "请选择操作 [0-3]: " choice
        case "$choice" in
            1) gemini_batch_create_keys ;;
            2) gemini_extract_from_existing ;;
            3) gemini_batch_delete_projects ;;
            0) 
               log "INFO" "脚本退出。"
               exit 0 
               ;;
            *) log "ERROR" "无效输入，请输入 0, 1, 2, 或 3。" ;;
        esac
        echo -e "\n${GREEN}按任意键返回主菜单...${NC}" >&2
        read -n 1 -s -r || true
    done
}

# ===== Main Execution =====
setup_environment
check_gcp_env
main_app

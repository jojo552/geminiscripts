#!/bin/bash

# ==============================================================================
#
# 高性能 Gemini API 密钥批量管理工具
#
# 功能:
#   1. 批量创建 GCP 项目并生成 Gemini API 密钥。
#   2. 从现有 GCP 项目中提取 Gemini API 密钥。
#   3. 按前缀批量删除 GCP 项目。
#
# 使用说明:
#   - 确保已安装并登录 gcloud CLI。
#   - 确保当前账户有权限创建项目并已关联结算账户。
#   - 直接运行脚本: ./gemini_key_manager.sh
#
# ==============================================================================

# --- 配置 ---
VERSION="2.0-Optimized"
# 【优化】调高默认并行任务数以极致加速。
# 注意：过高的值会因超出GCP配额而导致大量失败。请根据您的账户配额酌情调整。50是一个非常激进的数值。
MAX_PARALLEL_JOBS=${MAX_PARALLEL_JOBS:-50}

# --- 全局变量 ---
TEMP_DIR=$(mktemp -d)
OUTPUT_DIR="${PWD}/gemini_keys_$(date +%Y%m%d_%H%M%S)"
DETAILED_LOG_FILE="${TEMP_DIR}/detailed_run.log"

# --- 颜色定义 ---
NC='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'

# ===== 核心函数 =====

# 日志记录函数，带时间戳和锁机制
log() {
    local type="$1"
    local message="$2"
    local color="$NC"
    case "$type" in
        INFO) color="$CYAN";;
        SUCCESS) color="$GREEN";;
        WARN) color="$YELLOW";;
        ERROR) color="$RED";;
    esac
    (
        flock 200
        echo -e "${color}[$(date +'%Y-%m-%d %H:%M:%S')] [$type]${NC} $message" | tee -a "$DETAILED_LOG_FILE" >&2
    ) 200>"${TEMP_DIR}/log.lock"
}

# 带有重试逻辑的 gcloud 命令执行器
smart_retry_gcloud() {
    local cmd=("$@")
    local tries=${TRIES:-5}
    local delay=${DELAY:-5}
    local attempt=1
    while [ "$attempt" -le "$tries" ]; do
        if "${cmd[@]}"; then
            return 0
        fi
        log "WARN" "命令执行失败: '${cmd[*]}'. ${attempt}/${tries} 次尝试后将在 ${delay}s 后重试..."
        sleep "$delay"
        attempt=$((attempt + 1))
    done
    return 1
}

# 检查GCP环境是否就绪
check_gcp_env() {
    log "INFO" "正在检查 GCP 环境配置..."
    if ! command -v gcloud &> /dev/null; then
        log "ERROR" "gcloud CLI 未找到。请访问 https://cloud.google.com/sdk/docs/install 安装。"
        exit 1
    fi
    local current_user
    current_user=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null)
    if [ -z "$current_user" ]; then
        log "ERROR" "未登录 GCP 账户。请运行 'gcloud auth login' 并 'gcloud auth application-default login'。"
        exit 1
    fi
    log "INFO" "账户 [${current_user}] 已登录。"
    
    local billing_accounts
    billing_accounts=$(gcloud beta billing accounts list --format='value(ACCOUNT_ID)' --filter='OPEN=true' 2>/dev/null)
    if [ -z "$billing_accounts" ]; then
        log "ERROR" "未找到有效的结算账户。创建项目需要一个有效的结算账户。"
        exit 1
    fi
    
    local linked_billing
    linked_billing=$(gcloud beta billing projects list --billing-account="$(echo "$billing_accounts" | head -n1)" --format="value(projectId)" --filter="projectId:$(gcloud config get-value project)" 2>/dev/null)
    if [ -z "$linked_billing" ]; then
        log "WARN" "当前项目未链接结算账户，将尝试自动链接。这可能需要更高权限。"
    fi
    log "SUCCESS" "GCP 环境检查通过。"
}

# 生成唯一的项目ID
new_project_id() {
    local prefix="$1"
    echo "${prefix}-$(date +%s)-${RANDOM}"
}

# 确认提示
ask_yes_no() {
    local question="$1"
    while true; do
        read -r -p "$question [y/N]: " answer
        case "$answer" in
            [Yy]* ) return 0;;
            [Nn]*|"" ) return 1;;
            * ) echo "请输入 y 或 n.";;
        esac
    done
}

# 原子化地写入密钥文件
write_key_atomic() {
    local key="$1"
    local pure_file="$2"
    local comma_file="$3"
    local temp_pure
    local temp_comma
    temp_pure=$(mktemp)
    temp_comma=$(mktemp)
    
    # 追加到临时文件
    echo "$key" >> "$temp_pure"
    
    # 创建新的逗号分隔内容
    if [ -s "$comma_file" ]; then
        echo "$(cat "$comma_file"),$key" > "$temp_comma"
    else
        echo "$key" > "$temp_comma"
    fi
    
    # 原子性地移动/追加
    (
        flock 300
        cat "$temp_pure" >> "$pure_file"
        mv "$temp_comma" "$comma_file"
    ) 300>"${pure_file}.lock"
    
    rm "$temp_pure"
}

# 启用API并创建密钥的核心逻辑
enable_api_and_create_key() {
    local project_id="$1"
    local log_prefix="$2"

    log "INFO" "${log_prefix} 正在启用 generativelanguage.googleapis.com API..."
    if ! smart_retry_gcloud gcloud services enable generativelanguage.googleapis.com --project="$project_id" --quiet >/dev/null 2>&1; then
        log "ERROR" "${log_prefix} 启用 generativelanguage.googleapis.com API 失败。"
        return 1
    fi
    log "INFO" "${log_prefix} API 启用成功。"
    
    # 【优化】移除固定的 sleep 5。后续的 smart_retry_gcloud 会在首次失败后（例如因API传播延迟）进行带延迟的重试，这更高效。
    log "INFO" "${log_prefix} 正在创建 API 密钥..."
    
    local api_key
    api_key=$(smart_retry_gcloud gcloud alpha services api-keys create \
        --project="$project_id" \
        --display-name="Gemini API Key" \
        --api-target="service=generativelanguage.googleapis.com" \
        --format="value(keyString)" 2>/dev/null)
    
    if [ -z "$api_key" ]; then
        log "ERROR" "${log_prefix} 多次尝试后，创建或获取 API 密钥仍然失败。"
        return 1
    fi
    
    echo "$api_key"
}

# ===== 任务处理器 =====

process_new_project_creation() {
    local project_id="$1"
    local task_num="$2"
    local total_tasks="$3"
    local pure_key_file="$4"
    local comma_key_file="$5"
    local log_prefix="[${task_num}/${total_tasks}] [${project_id}]"

    log "INFO" "${log_prefix} 开始创建项目..."
    if ! smart_retry_gcloud gcloud projects create "$project_id" --name="$project_id" --quiet >&2; then
        log "ERROR" "${log_prefix} 项目创建失败。"
        echo "$project_id" >> "${TEMP_DIR}/failed.log"
        return
    fi
    log "INFO" "${log_prefix} 项目创建成功。"

    local api_key
    api_key=$(enable_api_and_create_key "$project_id" "$log_prefix")
    if [ -z "$api_key" ]; then
        log "WARN" "${log_prefix} 获取密钥失败，将尝试删除此空项目以进行清理。"
        smart_retry_gcloud gcloud projects delete "$project_id" --quiet >/dev/null 2>&1 || true
        echo "$project_id" >> "${TEMP_DIR}/failed.log"
        return
    fi
    
    write_key_atomic "$api_key" "$pure_key_file" "$comma_key_file"
    log "SUCCESS" "${log_prefix} 成功获取密钥并已保存！"
    echo "$project_id" >> "${TEMP_DIR}/success.log"
}

process_existing_project_extraction() {
    local project_id="$1"
    local task_num="$2"
    local total_tasks="$3"
    local pure_key_file="$4"
    local comma_key_file="$5"
    local log_prefix="[${task_num}/${total_tasks}] [${project_id}]"

    log "INFO" "${log_prefix} 开始处理现有项目..."
    
    local api_key
    api_key=$(enable_api_and_create_key "$project_id" "$log_prefix")
    if [ -z "$api_key" ]; then
        echo "$project_id" >> "${TEMP_DIR}/failed.log"
        return
    fi
    
    write_key_atomic "$api_key" "$pure_key_file" "$comma_key_file"
    log "SUCCESS" "${log_prefix} 成功获取密钥并已保存！"
    echo "$project_id" >> "${TEMP_DIR}/success.log"
}

# ===== 编排函数 =====
run_parallel_processor() {
    local processor_func="$1"
    shift
    local projects_to_process=("$@")
    
    local pure_key_file="${OUTPUT_DIR}/all_keys.txt"
    local comma_key_file="${OUTPUT_DIR}/all_keys_comma_separated.txt"

    > "$pure_key_file"
    > "$comma_key_file"

    rm -f "${TEMP_DIR}/success.log" "${TEMP_DIR}/failed.log"
    touch "${TEMP_DIR}/success.log" "${TEMP_DIR}/failed.log"

    local job_count=0
    local total_tasks=${#projects_to_process[@]}
    for i in "${!projects_to_process[@]}"; do
        local project_id="${projects_to_process[i]}"
        "$processor_func" "$project_id" "$((i+1))" "$total_tasks" "$pure_key_file" "$comma_key_file" &
        job_count=$((job_count + 1))
        if [ "$job_count" -ge "$MAX_PARALLEL_JOBS" ]; then
            wait -n || true
            job_count=$((job_count - 1))
        fi
    done

    log "INFO" "所有任务已派发，正在等待剩余任务完成..."
    wait

    report_and_download_results "$comma_key_file" "$pure_key_file"
}

gemini_batch_create_keys() {
    log "INFO" "====== 高性能批量创建 Gemini API 密钥 ======"
    local num_projects
    read -r -p "请输入要创建的项目数量 (例如: 50): " num_projects
    if ! [[ "$num_projects" =~ ^[1-9][0-9]*$ ]]; then
        log "ERROR" "无效的数字。请输入一个大于0的整数。"
        return
    fi
    local project_prefix
    read -r -p "请输入项目前缀 (默认: gemini-pro): " project_prefix
    project_prefix=${project_prefix:-gemini-pro}
    
    mkdir -p "$OUTPUT_DIR"
    
    echo -e "\n${YELLOW}${BOLD}=== 操作确认 ===${NC}" >&2
    echo -e "  计划创建项目数: ${BOLD}${num_projects}${NC}" >&2
    echo -e "  项目前缀:       ${BOLD}${project_prefix}${NC}" >&2
    echo -e "  并行任务数:     ${BOLD}${MAX_PARALLEL_JOBS}${NC} ${RED}(警告: 高并行可能导致配额问题)${NC}" >&2
    echo -e "  输出目录:       ${BOLD}${OUTPUT_DIR}${NC}" >&2
    if ! ask_yes_no "确认要继续吗?"; then
        log "INFO" "操作已取消。"
        return
    fi

    local projects_to_create=()
    for ((i=1; i<=num_projects; i++)); do
        projects_to_create+=("$(new_project_id "$project_prefix")")
    done
    
    run_parallel_processor "process_new_project_creation" "${projects_to_create[@]}"
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

    mkdir -p "$OUTPUT_DIR"

    echo -e "\n${YELLOW}${BOLD}=== 操作确认 ===${NC}" >&2
    echo -e "  将为 ${#projects_to_process[@]} 个现有项目提取新密钥。" >&2
    echo -e "  并行任务数:     ${BOLD}${MAX_PARALLEL_JOBS}${NC}" >&2
    echo -e "  输出目录:       ${BOLD}${OUTPUT_DIR}${NC}" >&2
    if ! ask_yes_no "确认要继续吗?"; then
        log "INFO" "操作已取消。"
        return
    fi
    
    run_parallel_processor "process_existing_project_extraction" "${projects_to_process[@]}"
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

    rm -f "${TEMP_DIR}/delete_success.log" "${TEMP_DIR}/delete_failed.log"
    touch "${TEMP_DIR}/delete_success.log" "${TEMP_DIR}/delete_failed.log"
    log "INFO" "开始批量提交删除任务..."
    
    local job_count=0
    for project_id in "${projects_to_delete[@]}"; do
        {
            # 【优化】添加 --async 标志以“即发即忘”模式加速删除，脚本不会等待每个项目删除完成。
            if gcloud projects delete "$project_id" --quiet --async >/dev/null 2>&1; then
                log "SUCCESS" "项目 [${project_id}] 删除请求已成功提交。"
                echo "$project_id" >> "${TEMP_DIR}/delete_success.log"
            else
                log "ERROR" "项目 [${project_id}] 删除请求提交失败。"
                echo "$project_id" >> "${TEMP_DIR}/delete_failed.log"
            fi
        } &
        job_count=$((job_count + 1))
        if [ "$job_count" -ge "$MAX_PARALLEL_JOBS" ]; then
            wait -n || true
            job_count=$((job_count - 1))
        fi
    done
    
    wait
    local success_count=$(wc -l < "${TEMP_DIR}/delete_success.log" | tr -d ' ')
    local failed_count=$(wc -l < "${TEMP_DIR}/delete_failed.log" | tr -d ' ')

    echo -e "\n${GREEN}${BOLD}====== 批量删除请求提交完成 ======${NC}" >&2
    log "SUCCESS" "成功提交删除请求: ${success_count}"
    log "ERROR" "提交删除请求失败: ${failed_count}"
}

# ===== 报告与清理 =====

report_and_download_results() {
    local comma_key_file="$1"
    local pure_key_file="$2"
    local success_count
    local failed_count
    success_count=$(wc -l < "${TEMP_DIR}/success.log" | tr -d ' ')
    failed_count=$(wc -l < "${TEMP_DIR}/failed.log" | tr -d ' ')

    echo -e "\n${GREEN}${BOLD}====== 操作完成：统计结果 ======${NC}" >&2
    log "SUCCESS" "成功: ${success_count}"
    log "ERROR" "失败: ${failed_count}"
    
    if [ "$success_count" -gt 0 ]; then
        echo -e "\n${PURPLE}======================================================" >&2
        echo -e "      ✨ 最终API密钥 (可直接复制) ✨" >&2
        echo -e "======================================================${NC}" >&2
        echo -e "${GREEN}${BOLD}" >&2
        cat "$comma_key_file" >&2
        echo >&2
        echo -e "${NC}" >&2
        echo -e "${PURPLE}======================================================${NC}\n" >&2

        log "INFO" "以上密钥已完整保存至目录: ${BOLD}${OUTPUT_DIR}${NC}"
        log "INFO" "逗号分隔密钥文件: ${BOLD}${comma_key_file}${NC}"
        log "INFO" "每行一个密钥文件: ${BOLD}${pure_key_file}${NC}"
        
        if [ -n "${DEVSHELL_PROJECT_ID-}" ] && command -v cloudshell &>/dev/null; then
            log "INFO" "检测到 Cloud Shell 环境，将自动触发下载..."
            cloudshell download "$comma_key_file"
            log "SUCCESS" "下载提示已发送。文件: ${comma_key_file##*/}"
        fi
    fi
    if [ "$failed_count" -gt 0 ]; then
        log "WARN" "失败的项目ID列表保存在详细日志中: ${DETAILED_LOG_FILE}"
    fi
}

setup_environment() {
    trap 'rm -rf "$TEMP_DIR"; exit' INT TERM EXIT
    mkdir -p "$TEMP_DIR"
    touch "${TEMP_DIR}/log.lock"
}

# ===== 主菜单与应用入口 =====

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
    echo "  1. 批量创建新项目并提取密钥" >&2
    echo "  2. 从现有项目中提取 API 密钥" >&2
    echo "  3. 批量删除指定前缀的项目" >&2
    echo "  0. 退出脚本" >&2
    echo "" >&2
}

main_app() {
    check_gcp_env

    while true;
    do
        show_main_menu
        read -r -p "请选择操作 [0-3]: " choice
        case "$choice" in
            1) gemini_batch_create_keys ;;
            2) gemini_extract_from_existing ;;
            3) gemini_batch_delete_projects ;;
            0) exit 0 ;;
            *) log "ERROR" "无效输入，请输入 0, 1, 2, 或 3。" ;;
        esac
        echo -e "\n${GREEN}按任意键返回主菜单...${NC}" >&2
        read -n 1 -s -r || true
    done
}

# ===== Main Execution =====
setup_environment
main_app

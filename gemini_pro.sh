#!/bin/bash
# ------------------------------------------------------------------------------
# High-Performance Gemini API Key Batch Management Tool v2.2 (Robust Setup)
# Author: ddddd (https://github.com/dddddd1)
#
# Changelog v2.2:
# - Rewrote setup function to be self-healing and more user-friendly.
# - Instead of failing on component installation errors, it now provides
#   clear, copy-pasteable instructions for the user to manually fix their
#   environment and then re-run the script.
# - Centralized failure logic for cleaner code.
#
# WARNING: Aggressive use of this script may lead to GCP account restrictions.
# ------------------------------------------------------------------------------

# ===== Global Configuration =====
VERSION="2.2-Robust-Setup"
: "${MAX_PARALLEL_JOBS:=30}"
TEMP_DIR=$(mktemp -d)
OUTPUT_DIR="${PWD}/gemini_keys_$(date +%Y%m%d_%H%M%S)"
DETAILED_LOG_FILE="${OUTPUT_DIR}/detailed_run.log"

trap 'rm -rf "${TEMP_DIR}"' EXIT

# ===== Styling and Logging =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

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
    # Log to file without color codes
    echo "$(date '+%Y-%m-%d %H:%M:%S') [${type}] ${message}" >> "${DETAILED_LOG_FILE}"
    # Log to stderr with color codes
    echo -e "${color}$(date '+%Y-%m-%d %H:%M:%S') [${type}] ${message}${NC}" >&2
}

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

# ===== Core Utility and Setup Functions =====

# [REBUILT] Smart setup function that handles different gcloud installation types
setup_environment() {
    mkdir -p "$OUTPUT_DIR"
    log "INFO" "临时目录: ${TEMP_DIR}"
    log "INFO" "输出目录: ${OUTPUT_DIR}"

    log "INFO" "正在检查 gcloud 工具..."
    if ! command -v gcloud &> /dev/null; then
        log "ERROR" "gcloud 命令未找到。请安装 Google Cloud SDK。"
        exit 1
    fi

    log "INFO" "正在检查 gcloud alpha 组件..."
    if gcloud alpha --version >/dev/null 2>&1; then
        log "SUCCESS" "gcloud alpha 组件已安装。"
    else
        log "WARN" "gcloud alpha 组件缺失，正在尝试智能安装..."
        local install_failed=0
        local manual_command=""

        # Check if component manager is disabled (the Cloud Shell case)
        if gcloud components list --quiet 2>&1 | grep -q "component manager is disabled"; then
            log "INFO" "检测到 apt 管理的环境 (如 Cloud Shell)。将使用 'sudo apt-get' 安装。"
            manual_command="sudo apt-get update && sudo apt-get install -y google-cloud-cli-alpha-components"
            
            if ! command -v sudo &> /dev/null; then
                log "ERROR" "sudo 命令不可用，无法自动安装 alpha 组件。"
                install_failed=1
            else
                log "INFO" "正在运行 'sudo apt-get update' (这可能需要一些时间)..."
                sudo apt-get update -q || log "WARN" "运行 'sudo apt-get update' 失败，但这可能不影响继续。"
                
                log "INFO" "正在运行 'sudo apt-get install -y google-cloud-cli-alpha-components'..."
                if ! sudo apt-get install -y -q google-cloud-cli-alpha-components; then
                    log "ERROR" "使用 apt 自动安装 alpha 组件失败。"
                    install_failed=1
                fi
            fi
        else
            log "INFO" "检测到标准 gcloud 环境。将使用 'gcloud components install'。"
            manual_command="gcloud components install alpha"
            if ! gcloud components install alpha -q; then
               log "ERROR" "自动安装 alpha 组件失败。"
               install_failed=1
            fi
        fi
        
        # Centralized check for success or failure
        if [ "$install_failed" -eq 1 ]; then
            echo -e "\n${RED}${BOLD}========================= 操作需要您介入 =========================${NC}" >&2
            echo -e "${YELLOW}脚本无法自动安装所需的 gcloud alpha 组件。${NC}" >&2
            echo -e "这通常是由于权限问题或网络环境造成的。" >&2
            echo -e "\n${BOLD}请您手动在终端中运行以下命令：${NC}" >&2
            echo -e "\n    ${CYAN}${manual_command}${NC}\n" >&2
            echo -e "${BOLD}成功运行该命令后，请重新启动此脚本。${NC}" >&2
            echo -e "${RED}${BOLD}===================================================================${NC}\n" >&2
            exit 1
        elif gcloud alpha --version >/dev/null 2>&1; then
             log "SUCCESS" "gcloud alpha 组件已成功安装！"
        else
            log "ERROR" "安装后 alpha 组件仍然不可用。脚本无法继续。"
            log "ERROR" "请尝试手动运行 '${manual_command}' 并重新启动脚本。"
            exit 1
        fi
    fi

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
    log "SUCCESS" "GCP 环境检查通过。脚本准备就绪！"
}

new_project_id() {
    local prefix="$1"
    echo "${prefix}-$(date +%s%N | rev | cut -c 1-10)-${RANDOM:0:4}"
}

smart_retry_gcloud() {
    local retries=3
    local delay=5
    for ((i=1; i<=retries; i++)); do
        if "$@"; then return 0; fi
        log "WARN" "命令执行失败: '$*'. 第 ${i}/${retries} 次重试..."
        sleep $((delay * i))
    done
    return 1
}

write_key_atomic() {
    local api_key="$1"
    local pure_key_file="$2"
    local comma_key_file="$3"
    (
        flock -x 200
        echo "$api_key" >> "$pure_key_file"
        local current_keys; current_keys=$(cat "$comma_key_file")
        if [ -z "$current_keys" ]; then
            echo -n "$api_key" > "$comma_key_file"
        else
            echo -n "${current_keys},${api_key}" > "$comma_key_file"
        fi
    ) 200>"${TEMP_DIR}/keys.lock"
}

# ===== EXTREME MODE: 3-Stage Asynchronous Workflow (Functions remain the same) =====

dispatch_project_creation_tasks() {
    local projects_to_create=("$@"); local total_tasks=${#projects_to_create[@]}
    log "INFO" "[Stage 1: Dispatch] 开始异步派发 ${total_tasks} 个项目创建任务..."
    local operations_log="${TEMP_DIR}/creation_operations.log"; > "$operations_log"
    for i in "${!projects_to_create[@]}"; do
        local project_id="${projects_to_create[i]}"
        gcloud projects create "$project_id" --name="$project_id" --quiet --async --format='value(name)' >> "$operations_log" 2>> "${DETAILED_LOG_FILE}" &
        if (( (i + 1) % MAX_PARALLEL_JOBS == 0 )); then wait; fi
    done
    wait
    log "SUCCESS" "[Stage 1: Dispatch] 所有 ${total_tasks} 个项目创建任务已派发。"
}

wait_for_creation_operations() {
    local operations_log="$1"; local successfully_created_log="$2"
    mapfile -t operations < "$operations_log"
    if [ ${#operations[@]} -eq 0 ]; then log "WARN" "[Stage 2: Verify] 没有找到等待的创建操作。"; return; fi
    log "INFO" "[Stage 2: Verify] 并行等待 ${#operations[@]} 个项目创建操作完成..."
    local job_count=0
    for op in "${operations[@]}"; do
        {
            if gcloud alpha services operations wait "$op" --timeout=600 >/dev/null 2>&1; then
                project_id=$(gcloud alpha services operations describe "$op" --format='value(metadata.resourceNames)' 2>/dev/null | sed 's/projects\///')
                if [ -n "$project_id" ]; then
                    log "SUCCESS" "[Stage 2: Verify] 项目 [${project_id}] 创建成功。"
                    echo "$project_id" >> "$successfully_created_log"
                fi
            else
                log "ERROR" "[Stage 2: Verify] 操作 '${op}' 失败或超时。"
                echo "$op" >> "${TEMP_DIR}/failed_operations.log"
            fi
        } &
        job_count=$((job_count + 1))
        if [ "$job_count" -ge "$MAX_PARALLEL_JOBS" ]; then wait -n || true; job_count=$((job_count - 1)); fi
    done
    wait
    log "SUCCESS" "[Stage 2: Verify] 所有项目创建操作检查完毕。"
}

process_successful_projects() {
    local projects_file="$1"; local pure_key_file="$2"; local comma_key_file="$3"
    mapfile -t projects_to_process < "$projects_file"
    local total_tasks=${#projects_to_process[@]}
    if [ "$total_tasks" -eq 0 ]; then log "WARN" "[Stage 3: Process] 没有成功创建的项目可供处理。"; return; fi
    log "INFO" "[Stage 3: Process] 为 ${total_tasks} 个项目启用API并创建密钥..."
    >"${TEMP_DIR}/success.log"; >"${TEMP_DIR}/failed.log"
    local job_count=0
    for i in "${!projects_to_process[@]}"; do
        local project_id="${projects_to_process[i]}"
        {
            local log_prefix="[${i+1}/${total_tasks}] [${project_id}]"
            if ! smart_retry_gcloud gcloud services enable generativelanguage.googleapis.com --project="$project_id" --quiet >/dev/null 2>&1; then
                log "ERROR" "${log_prefix} 启用API失败。"
                echo "$project_id" >> "${TEMP_DIR}/failed.log"
            else
                log "INFO" "${log_prefix} API启用成功，正在创建密钥..."
                api_key=$(gcloud alpha services api-keys create --project="$project_id" --display-name="Gemini-Key-Auto" --format="value(keyString)" 2>> "${DETAILED_LOG_FILE}")
                if [ -n "$api_key" ]; then
                    write_key_atomic "$api_key" "$pure_key_file" "$comma_key_file"
                    log "SUCCESS" "${log_prefix} 成功获取密钥！"
                    echo "$project_id" >> "${TEMP_DIR}/success.log"
                else
                    log "WARN" "${log_prefix} 获取密钥失败。将尝试删除项目。"
                    smart_retry_gcloud gcloud projects delete "$project_id" --quiet >/dev/null 2>&1 || true
                    echo "$project_id" >> "${TEMP_DIR}/failed.log"
                fi
            fi
        } &
        job_count=$((job_count + 1))
        if [ "$job_count" -ge "$MAX_PARALLEL_JOBS" ]; then wait -n || true; job_count=$((job_count - 1)); fi
    done
    wait
    log "INFO" "[Stage 3: Process] 所有项目处理完毕。"
}

# ===== Orchestration and Menu Functions (remain the same) =====

gemini_batch_create_keys() {
    log "INFO" "====== 高性能批量创建 Gemini API 密钥 ======"
    read -r -p "请输入要创建的项目数量 (例如: 50): " num_projects
    if ! [[ "$num_projects" =~ ^[1-9][0-9]*$ ]]; then log "ERROR" "无效数字。"; return; fi
    read -r -p "请输入项目前缀 (默认: gemini-pro): " project_prefix; project_prefix=${project_prefix:-gemini-pro}
    echo -e "\n${YELLOW}${BOLD}=== 操作确认 ===${NC}" >&2
    echo -e "  计划创建项目数: ${BOLD}${num_projects}${NC}" >&2
    echo -e "  项目前缀:       ${BOLD}${project_prefix}${NC}" >&2
    echo -e "  并行任务数:     ${BOLD}${MAX_PARALLEL_JOBS}${NC}" >&2
    echo -e "${RED}警告: 大规模创建项目可能违反GCP服务条款或超出配额。${NC}" >&2
    if ! ask_yes_no "确认要继续吗?"; then log "INFO" "操作已取消。"; return; fi
    local projects_to_create=()
    for ((i=1; i<=num_projects; i++)); do projects_to_create+=("$(new_project_id "$project_prefix")"); done
    local successfully_created_log="${TEMP_DIR}/creation_success.log"; > "$successfully_created_log"
    dispatch_project_creation_tasks "${projects_to_create[@]}"
    wait_for_creation_operations "${TEMP_DIR}/creation_operations.log" "$successfully_created_log"
    local pure_key_file="${OUTPUT_DIR}/all_keys.txt"; local comma_key_file="${OUTPUT_DIR}/all_keys_comma_separated.txt"
    > "$pure_key_file"; > "$comma_key_file"
    process_successful_projects "$successfully_created_log" "$pure_key_file" "$comma_key_file"
    report_and_download_results "$comma_key_file" "$pure_key_file"
}

gemini_extract_from_existing() {
    log "INFO" "====== 从现有项目提取 Gemini API 密钥 ======"
    mapfile -t all_projects < <(gcloud projects list --filter='lifecycleState:ACTIVE' --format='value(projectId)' 2>/dev/null)
    if [ ${#all_projects[@]} -eq 0 ]; then log "ERROR" "未找到任何活跃项目。"; return; fi
    log "INFO" "找到 ${#all_projects[@]} 个活跃项目。请选择:"
    for i in "${!all_projects[@]}"; do printf "  %3d. %s\n" "$((i+1))" "${all_projects[i]}" >&2; done
    read -r -p "请输入项目编号 (多个用空格隔开, 或 'all'): " -a selections
    local projects_to_process=()
    if [[ " ${selections[*],,} " =~ " all " ]]; then
        projects_to_process=("${all_projects[@]}")
    else
        for num in "${selections[@]}"; do
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#all_projects[@]}" ]; then
                projects_to_process+=("${all_projects[$((num-1))]}")
            else
                log "WARN" "无效编号: $num，已忽略。"
            fi
        done
    fi
    if [ ${#projects_to_process[@]} -eq 0 ]; then log "ERROR" "未选择任何有效项目。"; return; fi
    echo -e "\n${YELLOW}${BOLD}=== 操作确认 ===${NC}" >&2
    echo -e "  将为 ${#projects_to_process[@]} 个现有项目提取新密钥。" >&2
    if ! ask_yes_no "确认要继续吗?"; then log "INFO" "操作已取消。"; return; fi
    local projects_file="${TEMP_DIR}/existing_projects_to_process.txt"; printf "%s\n" "${projects_to_process[@]}" > "$projects_file"
    local pure_key_file="${OUTPUT_DIR}/all_keys.txt"; local comma_key_file="${OUTPUT_DIR}/all_keys_comma_separated.txt"
    > "$pure_key_file"; > "$comma_key_file"
    process_successful_projects "$projects_file" "$pure_key_file" "$comma_key_file"
    report_and_download_results "$comma_key_file" "$pure_key_file"
}

gemini_batch_delete_projects() {
    log "INFO" "====== 批量删除项目 ======"
    mapfile -t projects < <(gcloud projects list --filter='lifecycleState:ACTIVE' --format='value(projectId)' 2>/dev/null)
    if [ ${#projects[@]} -eq 0 ]; then log "ERROR" "未找到任何活跃项目。"; return; fi
    read -r -p "请输入要删除的项目前缀 (留空则匹配所有): " prefix
    local projects_to_delete=()
    for proj in "${projects[@]}"; do if [[ "$proj" == "${prefix}"* ]]; then projects_to_delete+=("$proj"); fi; done
    if [ ${#projects_to_delete[@]} -eq 0 ]; then log "WARN" "没有找到任何项目匹配前缀: '${prefix}'"; return; fi
    echo -e "\n${YELLOW}将要删除以下 ${#projects_to_delete[@]} 个项目:${NC}" >&2
    printf ' - %s\n' "${projects_to_delete[@]}" | head -n 20 >&2
    if [ ${#projects_to_delete[@]} -gt 20 ]; then echo "   ... 等等" >&2; fi
    echo -e "\n${RED}${BOLD}!!! 警告：此操作不可逆 !!!${NC}" >&2
    read -r -p "请输入 'DELETE' 来确认删除: " confirmation
    if [ "$confirmation" != "DELETE" ]; then log "INFO" "删除操作已取消。"; return; fi
    local delete_success_log="${TEMP_DIR}/delete_success.log"; local delete_failed_log="${TEMP_DIR}/delete_failed.log"
    >"$delete_success_log"; >"$delete_failed_log"
    log "INFO" "开始批量删除任务..."
    local job_count=0
    for project_id in "${projects_to_delete[@]}"; do
        {
            if smart_retry_gcloud gcloud projects delete "$project_id" --quiet; then
                echo "$project_id" >> "$delete_success_log"
            else
                echo "$project_id" >> "$delete_failed_log"
            fi
        } &
        job_count=$((job_count + 1))
        if [ "$job_count" -ge "$MAX_PARALLEL_JOBS" ]; then wait -n || true; job_count=$((job_count - 1)); fi
    done
    wait
    local success_count=$(wc -l < "$delete_success_log" | tr -d ' '); local failed_count=$(wc -l < "$delete_failed_log" | tr -d ' ')
    log "SUCCESS" "成功删除: ${success_count}"; log "ERROR" "删除失败: ${failed_count}"
}

report_and_download_results() {
    local comma_key_file="$1"; local pure_key_file="$2"
    touch "${TEMP_DIR}/success.log" "${TEMP_DIR}/failed.log"
    local success_count=$(wc -l < "${TEMP_DIR}/success.log" | tr -d ' ')
    local failed_count=$(wc -l < "${TEMP_DIR}/failed.log" | tr -d ' ')
    echo -e "\n${GREEN}${BOLD}====== 操作完成：统计结果 ======${NC}" >&2
    log "SUCCESS" "成功获取密钥的项目数: ${success_count}"
    log "ERROR" "失败的项目数: ${failed_count}"
    if [ "$success_count" -gt 0 ]; then
        echo -e "\n${PURPLE}================== ✨ 最终API密钥 ✨ ==================${NC}" >&2
        echo -e "${GREEN}${BOLD}" >&2; cat "$comma_key_file" >&2; echo -e "\n${NC}" >&2
        log "INFO" "密钥已保存至: ${BOLD}${OUTPUT_DIR}${NC}"
        if [ -n "${DEVSHELL_PROJECT_ID-}" ] && command -v cloudshell &>/dev/null; then
            log "INFO" "检测到 Cloud Shell 环境，将自动触发下载..."
            cloudshell download "$comma_key_file"; cloudshell download "$pure_key_file"
        fi
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
    local account; account=$(gcloud config get-value account 2>/dev/null || echo "未登录")
    echo -e "  当前账户: ${CYAN}${account}${NC}" >&2
    echo -e "  并行任务: ${CYAN}${MAX_PARALLEL_JOBS}${NC}" >&2
    echo -e "-----------------------------------------------------" >&2
    echo -e "\n${RED}${BOLD}请注意：滥用此脚本可能导致您的GCP账户受限。${NC}\n" >&2
    echo "  1. 批量创建新项目并提取密钥 (极限模式)" >&2
    echo "  2. 从现有项目中提取 API 密钥" >&2
    echo "  3. 批量删除指定前缀的项目" >&2
    echo "  0. 退出脚本" >&2; echo "" >&2
}

main_app() {
    setup_environment
    while true; do
        show_main_menu
        read -r -p "请选择操作 [0-3]: " choice
        case "$choice" in
            1) gemini_batch_create_keys ;;
            2) gemini_extract_from_existing ;;
            3) gemini_batch_delete_projects ;;
            0) log "INFO" "脚本退出。"; exit 0 ;;
            *) log "ERROR" "无效输入。" ;;
        esac
        echo -e "\n${GREEN}按任意键返回主菜单...${NC}" >&2
        read -n 1 -s -r || true
    done
}

# ===== Main Execution =====
main_app

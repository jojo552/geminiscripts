#!/bin/bash
# ------------------------------------------------------------------------------
# High-Performance Gemini API Key Batch Management Tool v3.0 (No-Alpha Edition)
# Author: ddddd (https://github.com/dddddd1)
#
# Changelog v3.0:
# - COMPLETE REMOVAL of all 'gcloud alpha' dependencies.
# - The setup function no longer checks for or installs any alpha components.
# - Replaced the complex 3-stage async workflow with a simpler, more robust
#   parallel processing model. Each project is created and processed in a
#   single, linear background job.
# - Replaced 'gcloud alpha services api-keys create' with the stable GA command
#   'gcloud services api-keys create'.
#
# WARNING: Aggressive use of this script may lead to GCP account restrictions.
# ------------------------------------------------------------------------------

# ===== Global Configuration =====
VERSION="3.0-No-Alpha"
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

# [REBUILT v3.0] Simplified setup without any alpha component checks.
setup_environment() {
    mkdir -p "$OUTPUT_DIR"
    log "INFO" "临时目录: ${TEMP_DIR}"
    log "INFO" "输出目录: ${OUTPUT_DIR}"

    log "INFO" "正在检查 gcloud 工具..."
    if ! command -v gcloud &> /dev/null; then
        log "ERROR" "gcloud 命令未找到。请安装 Google Cloud SDK。"
        exit 1
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

# ===== NEW v3.0: Simplified Parallel Workflow =====

# Helper function for the new simplified workflow. Processes one project from start to finish.
process_single_project() {
    local project_id="$1"
    local project_prefix_log="[${project_id}]"
    local pure_key_file="$2"
    local comma_key_file="$3"
    local success_log="$4"
    local failed_log="$5"

    log "INFO" "${project_prefix_log} 开始创建..."
    # Step 1: Create the project and wait for it to complete.
    if ! smart_retry_gcloud gcloud projects create "$project_id" --name="$project_id" --quiet; then
        log "ERROR" "${project_prefix_log} 项目创建失败。"
        echo "$project_id" >> "$failed_log"
        return 1
    fi
    log "INFO" "${project_prefix_log} 项目创建成功。"

    # Step 2: Enable the Generative Language API.
    if ! smart_retry_gcloud gcloud services enable generativelanguage.googleapis.com --project="$project_id" --quiet; then
        log "ERROR" "${project_prefix_log} 启用API失败，正在删除项目。"
        smart_retry_gcloud gcloud projects delete "$project_id" --quiet >/dev/null 2>&1 || true
        echo "$project_id" >> "$failed_log"
        return 1
    fi
    log "INFO" "${project_prefix_log} API启用成功。"

    # Step 3: Create the API Key using the stable command.
    log "INFO" "${project_prefix_log} 正在创建API密钥..."
    local api_key
    api_key=$(gcloud services api-keys create --project="$project_id" --display-name="Gemini-Key-Auto" --format="value(keyString)" 2>> "${DETAILED_LOG_FILE}")

    if [ -n "$api_key" ]; then
        write_key_atomic "$api_key" "$pure_key_file" "$comma_key_file"
        log "SUCCESS" "${project_prefix_log} 成功创建并保存API密钥！"
        echo "$project_id" >> "$success_log"
    else
        log "ERROR" "${project_prefix_log} API密钥创建失败，正在删除项目。"
        smart_retry_gcloud gcloud projects delete "$project_id" --quiet >/dev/null 2>&1 || true
        echo "$project_id" >> "$failed_log"
        return 1
    fi
}

# [REBUILT v3.0] Main function for batch creation using the new simplified workflow.
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

    # Export functions and variables needed by the background processes
    export -f log smart_retry_gcloud write_key_atomic
    export RED GREEN YELLOW PURPLE CYAN NC BOLD DETAILED_LOG_FILE TEMP_DIR

    local pure_key_file="${OUTPUT_DIR}/all_keys.txt"
    local comma_key_file="${OUTPUT_DIR}/all_keys_comma_separated.txt"
    local success_log="${TEMP_DIR}/success.log"
    local failed_log="${TEMP_DIR}/failed.log"
    > "$pure_key_file"; > "$comma_key_file"; > "$success_log"; > "$failed_log"

    log "INFO" "开始并行创建 ${num_projects} 个项目..."
    local job_count=0
    for ((i=1; i<=num_projects; i++)); do
        local project_id
        project_id=$(new_project_id "$project_prefix")
        
        # Run the entire process for one project in the background
        process_single_project "$project_id" "$pure_key_file" "$comma_key_file" "$success_log" "$failed_log" &

        job_count=$((job_count + 1))
        if [ "$job_count" -ge "$MAX_PARALLEL_JOBS" ]; then
            wait -n || true # Wait for any job to finish
            job_count=$((job_count - 1))
        fi
    done

    # Wait for all remaining background jobs to complete
    wait
    log "INFO" "所有创建任务已完成。"
    report_and_download_results "$comma_key_file" "$pure_key_file"
}

# ===== MODIFIED v3.0: Functions for existing projects =====

# This function is now only used by gemini_extract_from_existing
process_existing_projects() {
    local projects_file="$1"; local pure_key_file="$2"; local comma_key_file="$3"
    mapfile -t projects_to_process < "$projects_file"
    local total_tasks=${#projects_to_process[@]}
    if [ "$total_tasks" -eq 0 ]; then log "WARN" "[Process] 没有选择任何项目。"; return; fi
    log "INFO" "[Process] 为 ${total_tasks} 个现有项目启用API并创建密钥..."
    local success_log="${TEMP_DIR}/success.log"; local failed_log="${TEMP_DIR}/failed.log"
    >"$success_log"; >"$failed_log"
    
    local job_count=0
    for i in "${!projects_to_process[@]}"; do
        local project_id="${projects_to_process[i]}"
        {
            local log_prefix="[${i+1}/${total_tasks}] [${project_id}]"
            if ! smart_retry_gcloud gcloud services enable generativelanguage.googleapis.com --project="$project_id" --quiet >/dev/null 2>&1; then
                log "ERROR" "${log_prefix} 启用API失败。"
                echo "$project_id" >> "$failed_log"
            else
                log "INFO" "${log_prefix} API启用成功，正在创建密钥..."
                # [REPLACEMENT] Use stable command
                api_key=$(gcloud services api-keys create --project="$project_id" --display-name="Gemini-Key-Auto" --format="value(keyString)" 2>> "${DETAILED_LOG_FILE}")
                if [ -n "$api_key" ]; then
                    write_key_atomic "$api_key" "$pure_key_file" "$comma_key_file"
                    log "SUCCESS" "${log_prefix} 成功获取密钥！"
                    echo "$project_id" >> "$success_log"
                else
                    log "WARN" "${log_prefix} 获取密钥失败。"
                    echo "$project_id" >> "$failed_log"
                fi
            fi
        } &
        job_count=$((job_count + 1))
        if [ "$job_count" -ge "$MAX_PARALLEL_JOBS" ]; then wait -n || true; job_count=$((job_count - 1)); fi
    done
    wait
    log "INFO" "[Process] 所有项目处理完毕。"
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
    process_existing_projects "$projects_file" "$pure_key_file" "$comma_key_file"
    report_and_download_results "$comma_key_file" "$pure_key_file"
}

# ===== Other functions remain largely the same =====

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
    echo "  1. 批量创建新项目并提取密钥 (稳定模式)" >&2
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

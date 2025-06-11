#gemini专用自动化脚本1.0promax版本
#请勿倒卖出售
#完全免费分享






#!/bin/bash
set -Euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

setup_environment() {
    echo -e "${CYAN}--- 环境自检与设置 ---${NC}"
    if command -v bc &>/dev/null; then
        echo -e "${GREEN}[✓] 核心依赖 'bc' 已安装。${NC}"
    else
        echo -e "${YELLOW}[!] 核心依赖 'bc' 未找到，正在尝试自动安装...${NC}"
        echo "    (这可能需要您输入 sudo 密码)"
        if command -v apt-get &>/dev/null; then
            if sudo apt-get update >/dev/null && sudo apt-get install -y bc >/dev/null; then
                echo -e "${GREEN}[✓] 依赖 'bc' 安装成功！${NC}"
            else
                echo -e "${RED}[✗] 自动安装 'bc' 失败。${NC}"
                echo -e "${YELLOW}请尝试手动运行: 'sudo apt-get update && sudo apt-get install -y bc'${NC}"
                exit 1
            fi
        else
            echo -e "${RED}[✗] 无法找到 apt-get 包管理器。请手动安装 'bc'。${NC}"
            exit 1
        fi
    fi
    echo -e "${CYAN}--- 环境检查完毕 ---\n${NC}"
    sleep 1
}

VERSION="3.2.0"
MAX_PARALLEL_JOBS="${CONCURRENCY:-25}"
MAX_RETRY_ATTEMPTS="${MAX_RETRY:-3}"
RANDOM_DELAY_MAX="1.5"

SESSION_ID=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="gemini_session_${SESSION_ID}"
DETAILED_LOG_FILE="${OUTPUT_DIR}/detailed_run.log"
DELETION_LOG_FILE="${OUTPUT_DIR}/project_deletion.log"

TEMP_DIR=$(mktemp -d -t gcp_gemini_XXXXXX)
SECONDS=0

cleanup_resources() {
    local exit_code=$?
    log "INFO" "正在执行清理程序..."
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
        log "INFO" "已清理临时文件目录: $TEMP_DIR"
    fi
    if [ $exit_code -eq 0 ]; then
        log "SUCCESS" "所有操作已成功完成。"
    else
        log "WARN" "脚本因错误退出 (退出码: $exit_code)。"
    fi
    duration=$SECONDS
    echo -e "\n${PURPLE}本次运行总耗时: ${BOLD}$((duration / 60)) 分 $((duration % 60)) 秒${NC}"
    echo -e "${CYAN}感谢使用！${NC}"
}
trap cleanup_resources EXIT

handle_error() {
    local exit_code=$?
    local line_no=$1
    if [ $exit_code -ne 0 ]; then
        log "ERROR" "在第 ${line_no} 行发生致命错误 (退出码 ${exit_code})。脚本将终止。"
    fi
}
trap 'handle_error $LINENO' ERR

log() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_line
    case "$level" in
        "INFO")    log_line="${CYAN}[${timestamp}] [INFO] ${msg}${NC}" ;;
        "SUCCESS") log_line="${GREEN}[${timestamp}] [SUCCESS] ${msg}${NC}" ;;
        "WARN")    log_line="${YELLOW}[${timestamp}] [WARN] ${msg}${NC}" ;;
        "ERROR")   log_line="${RED}[${timestamp}] [ERROR] ${msg}${NC}" ;;
        *)         log_line="[${timestamp}] [${level}] ${msg}" ;;
    esac
    echo -e "$log_line" | tee -a "$DETAILED_LOG_FILE"
}

require_cmd() {
    if ! command -v "$1" &>/dev/null; then
        log "ERROR" "核心依赖缺失: '$1'。请在运行脚本前确保它已安装并位于您的 PATH 中。"
        exit 1
    fi
}

retry() {
    local n=1
    while true; do
        if "$@"; then
            return 0
        elif [ $n -lt "$MAX_RETRY_ATTEMPTS" ]; then
            local delay=$((n * 2 + RANDOM % 3))
            log "WARN" "命令失败: '$*'. 第 ${n}/${MAX_RETRY_ATTEMPTS} 次重试 (等待 ${delay}s)..."
            sleep "$delay"
            ((n++))
        else
            log "ERROR" "命令在 ${MAX_RETRY_ATTEMPTS} 次尝试后仍然失败: '$*'"
            return 1
        fi
    done
}

ask_yes_no() {
    local prompt="$1"
    local resp
    while true; do
        read -r -p "${prompt} [y/n]: " resp
        case "$resp" in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "请输入 y 或 n.";;
        esac
    done
}

new_project_id() {
    local prefix="$1"
    local random_part
    random_part=$(openssl rand -hex 4)
    echo "${prefix}-$(date +%s)-${random_part}" | cut -c1-30
}

write_key_atomic() {
    local api_key="$1"
    local pure_key_file="$2"
    local comma_key_file="$3"
    (
        flock -x 200
        echo "$api_key" >> "$pure_key_file"
        if [ -s "$comma_key_file" ]; then
            echo -n "," >> "$comma_key_file"
        fi
        echo -n "$api_key" >> "$comma_key_file"
    ) 200>"${TEMP_DIR}/keys.lock"
}

random_sleep() {
    sleep "$(bc <<< "scale=2; $RANDOM/32767 * $RANDOM_DELAY_MAX")"
}

check_gcp_env() {
    log "INFO" "检查 GCP 环境配置..."
    require_cmd gcloud
    require_cmd openssl
    require_cmd bc

    if ! gcloud config get-value account >/dev/null 2>&1; then
        log "ERROR" "GCP 账户未配置。请先运行 'gcloud auth login' 和 'gcloud config set project [YOUR_PROJECT_ID]'."
        exit 1
    fi
    local account
    account=$(gcloud config get-value account)
    log "SUCCESS" "GCP 环境检查通过。当前活动账户: ${BOLD}${account}${NC}"
}

process_single_project() {
    local project_id="$1"
    local task_num="$2"
    local total_tasks="$3"
    local pure_key_file="$4"
    local comma_key_file="$5"
    local log_prefix="[${task_num}/${total_tasks}] [${project_id}]"

    log "INFO" "${log_prefix} 开始处理..."
    random_sleep
    if ! retry gcloud projects create "$project_id" --name="$project_id" --quiet >/dev/null 2>&1; then
        log "ERROR" "${log_prefix} 项目创建失败。"
        echo "$project_id" >> "${TEMP_DIR}/failed.log"
        return 1
    fi
    log "INFO" "${log_prefix} 项目创建成功。"

    random_sleep
    if ! retry gcloud services enable generativelanguage.googleapis.com --project="$project_id" --quiet >/dev/null 2>&1; then
        log "ERROR" "${log_prefix} 启用 Generative Language API 失败。"
        gcloud projects delete "$project_id" --quiet >/dev/null 2>&1 || true
        echo "$project_id" >> "${TEMP_DIR}/failed.log"
        return 1
    fi
    log "INFO" "${log_prefix} API 启用成功。"

    random_sleep
    local key_json
    local display_name="gemini-key-$(openssl rand -hex 2)"
    if ! key_json=$(retry gcloud services api-keys create --project="$project_id" --display-name="$display_name" --format="json(keyString)" --quiet); then
        log "ERROR" "${log_prefix} 创建 API 密钥失败。"
        gcloud projects delete "$project_id" --quiet >/dev/null 2>&1 || true
        echo "$project_id" >> "${TEMP_DIR}/failed.log"
        return 1
    fi

    local api_key
    api_key=$(echo "$key_json" | grep -o '"keyString": "[^"]*' | cut -d'"' -f4)

    if [ -z "$api_key" ]; then
        log "ERROR" "${log_prefix} 无法从API响应中提取密钥。"
        gcloud projects delete "$project_id" --quiet >/dev/null 2>&1 || true
        echo "$project_id" >> "${TEMP_DIR}/failed.log"
        return 1
    fi

    write_key_atomic "$api_key" "$pure_key_file" "$comma_key_file"
    log "SUCCESS" "${log_prefix} 成功获取密钥并已保存！"
    echo "$project_id" >> "${TEMP_DIR}/success.log"
    return 0
}

gemini_batch_create_keys() {
    log "INFO" "====== 高性能批量创建 Gemini API 密钥 ======"
    local num_projects
    read -r -p "请输入要创建的项目数量 (例如: 50): " num_projects
    if ! [[ "$num_projects" =~ ^[1-9][0-9]*$ ]]; then
        log "ERROR" "无效的数字。请输入一个大于0的整数。"
        return 1
    fi
    local project_prefix
    read -r -p "请输入项目前缀 (默认: gemini-pro): " project_prefix
    project_prefix=${project_prefix:-gemini-pro}

    mkdir -p "$OUTPUT_DIR"
    local pure_key_file="${OUTPUT_DIR}/keys.txt"
    local comma_key_file="${OUTPUT_DIR}/keys_comma_separated.txt"

    echo -e "\n${YELLOW}${BOLD}=== 操作确认 ===${NC}"
    echo -e "  计划创建项目数: ${BOLD}${num_projects}${NC}"
    echo -e "  项目前缀:       ${BOLD}${project_prefix}${NC}"
    echo -e "  并行任务数:     ${BOLD}${MAX_PARALLEL_JOBS}${NC}"
    echo -e "  输出目录:       ${BOLD}${OUTPUT_DIR}${NC}"
    echo -e "${RED}警告: 大规模创建项目可能违反GCP服务条款，请自行承担风险。${NC}"
    if ! ask_yes_no "确认要继续吗?"; then
        log "INFO" "操作已取消。"
        return 1
    fi
    
    rm -f "${TEMP_DIR}/success.log" "${TEMP_DIR}/failed.log"
    touch "${TEMP_DIR}/success.log" "${TEMP_DIR}/failed.log"

    log "INFO" "开始批量创建任务，请稍候..."
    
    local job_count=0
    for i in $(seq 1 "$num_projects"); do
        local project_id
        project_id=$(new_project_id "$project_prefix")
        process_single_project "$project_id" "$i" "$num_projects" "$pure_key_file" "$comma_key_file" &
        job_count=$((job_count + 1))
        if [ "$job_count" -ge "$MAX_PARALLEL_JOBS" ]; then
            wait -n
            job_count=$((job_count - 1))
        fi
    done

    log "INFO" "所有任务已派发，正在等待剩余任务完成..."
    wait
    
    local success_count
    local failed_count
    success_count=$(wc -l < "${TEMP_DIR}/success.log")
    failed_count=$(wc -l < "${TEMP_DIR}/failed.log")

    echo -e "\n${GREEN}${BOLD}====== 批量创建完成 ======${NC}"
    log "SUCCESS" "成功: ${success_count}"
    log "ERROR" "失败: ${failed_count}"
    if [ "$success_count" -gt 0 ]; then
        log "INFO" "所有密钥已保存至目录: ${BOLD}${OUTPUT_DIR}${NC}"
        
        if [ -n "${DEVSHELL_PROJECT_ID-}" ] && command -v cloudshell &>/dev/null; then
            log "INFO" "检测到 Cloud Shell 环境，将自动触发下载逗号分隔的密钥文件..."
            cloudshell download "$comma_key_file"
            log "SUCCESS" "下载提示已发送。请在浏览器中确认下载文件: ${comma_key_file}"
        else
            log "INFO" "纯密钥文件 (每行一个): ${BOLD}${pure_key_file}${NC}"
            log "INFO" "逗号分隔密钥文件: ${BOLD}${comma_key_file}${NC}"
            echo -e "\n${CYAN}--- 逗号分隔密钥预览 ---${NC}"
            cat "$comma_key_file"
            echo ""
        fi
    fi
    if [ "$failed_count" -gt 0 ]; then
        log "WARN" "失败的项目ID列表保存在详细日志中: ${DETAILED_LOG_FILE}"
    fi
}

process_single_deletion() {
    local project_id="$1"
    if retry gcloud projects delete "$project_id" --quiet >/dev/null 2>&1; then
        log "SUCCESS" "项目 ${project_id} 已成功删除。"
        echo "$project_id" >> "${TEMP_DIR}/delete_success.log"
    else
        log "ERROR" "项目 ${project_id} 删除失败。"
        echo "$project_id" >> "${TEMP_DIR}/delete_failed.log"
    fi
}

gemini_batch_delete_projects() {
    log "INFO" "====== 批量删除项目 ======"
    log "INFO" "正在获取您账户下的所有活跃项目列表..."
    mapfile -t projects < <(gcloud projects list --filter='lifecycleState:ACTIVE' --format='value(projectId)' 2>/dev/null)

    if [ ${#projects[@]} -eq 0 ]; then
        log "ERROR" "未找到任何活跃项目。"
        return 1
    fi
    
    log "INFO" "找到 ${#projects[@]} 个活跃项目。"
    read -r -p "请输入要删除的项目前缀 (例如: 'gemini-pro'，留空则匹配所有): " prefix

    local projects_to_delete=()
    for proj in "${projects[@]}"; do
        if [[ "$proj" == "${prefix}"* ]]; then
            projects_to_delete+=("$proj")
        fi
    done

    if [ ${#projects_to_delete[@]} -eq 0 ]; then
        log "WARN" "没有找到任何项目匹配前缀: '${prefix}'"
        return 1
    fi

    echo -e "\n${YELLOW}将要删除以下 ${#projects_to_delete[@]} 个项目:${NC}"
    printf ' - %s\n' "${projects_to_delete[@]}" | head -n 20
    if [ ${#projects_to_delete[@]} -gt 20 ]; then
        echo "   ... 等等"
    fi

    echo -e "\n${RED}${BOLD}!!! 警告：此操作不可逆，将永久删除项目及其所有资源 !!!${NC}"
    read -r -p "请输入 'DELETE' 来确认删除: " confirmation
    if [ "$confirmation" != "DELETE" ]; then
        log "INFO" "删除操作已取消。"
        return 1
    fi

    rm -f "${TEMP_DIR}/delete_success.log" "${TEMP_DIR}/delete_failed.log"
    touch "${TEMP_DIR}/delete_success.log" "${TEMP_DIR}/delete_failed.log"
    log "INFO" "开始批量删除任务..."
    
    local job_count=0
    for project_id in "${projects_to_delete[@]}"; do
        process_single_deletion "$project_id" &
        job_count=$((job_count + 1))
        if [ "$job_count" -ge "$MAX_PARALLEL_JOBS" ]; then
            wait -n
            job_count=$((job_count - 1))
        fi
    done
    
    log "INFO" "正在等待所有删除任务完成..."
    wait

    local success_count
    local failed_count
    success_count=$(wc -l < "${TEMP_DIR}/delete_success.log")
    failed_count=$(wc -l < "${TEMP_DIR}/delete_failed.log")

    echo -e "\n${GREEN}${BOLD}====== 批量删除完成 ======${NC}"
    log "SUCCESS" "成功删除: ${success_count}"
    log "ERROR" "删除失败: ${failed_count}"
    echo "详细信息已记录到: ${DELETION_LOG_FILE}"
}

show_main_menu() {
    clear
    echo -e "${PURPLE}${BOLD}"
    cat << "EOF"
  ____ ____ ____ ____ ____ ____ _________ ____ ____ ____ 
 ||G |||e |||m |||i |||n |||i |||       |||K |||e |||y ||
 ||__|||__|||__|||__|||__|||__|||_______|||__|||__|||__||
 |/__\|/__\|/__\|/__\|/__\|/__\|/_______\|/__\|/__\|/__\|
EOF
    echo -e "      高性能 Gemini API 密钥批量管理工具  版本1.0promax 此后不再更新 ${BOLD}v${VERSION}${NC}"
    echo -e "-----------------------------------------------------"
    echo -e "${YELLOW}  作者: ddddd (脚本完全免费分享，请勿倒卖)${NC}"
    echo -e "-----------------------------------------------------"
    local account
    account=$(gcloud config get-value account 2>/dev/null || echo "未登录")
    echo -e "  当前账户: ${CYAN}${account}${NC}"
    echo -e "  并行任务: ${CYAN}${MAX_PARALLEL_JOBS}${NC}"
    echo -e "-----------------------------------------------------"
    echo -e "\n${RED}${BOLD}请注意：滥用此脚本可能导致您的GCP账户受限。${NC}\n"
    echo "  1. 批量创建 Gemini API 密钥"
    echo "  2. 批量删除指定前缀的项目"
    echo "  0. 退出脚本"
    echo ""
}

main_app() {
    check_gcp_env
    mkdir -p "$OUTPUT_DIR"
    while true; do
        show_main_menu
        read -r -p "请选择操作 [0-2]: " choice
        case "$choice" in
            1) gemini_batch_create_keys ;;
            2) gemini_batch_delete_projects ;;
            0) exit 0 ;;
            *) log "ERROR" "无效输入，请输入 0, 1, 或 2。" ;;
        esac
        echo -e "\n${GREEN}按任意键返回主菜单...${NC}"
        read -n 1 -s -r
    done
}

setup_environment
main_app

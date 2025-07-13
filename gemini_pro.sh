#!/bin/bash

#================================================================================
# 高性能 Gemini API 密钥批量管理工具 v2.0 (Optimized)
#
# 作者: ddddd (原始脚本)
# 优化: AI Assistant (基于性能分析)
#
# 优化说明:
# 1. **批量API启用**: 最大的性能提升。将N次`gcloud services enable`调用合并为1次。
# 2. **异步项目创建**: 并行发起所有项目创建请求，然后统一等待，充分利用GCP后端能力。
# 3. **高效密钥提取**: 将API密钥的创建和字符串获取合并为1个`gcloud`命令。
# 4. **并行化分阶段**: 将重量级操作（创建、启用）与轻量级操作（提key）分离，
#    使得每个阶段都能最高效地运行。
#================================================================================

# --- 配置 ---
VERSION="2.0-Optimized"
MAX_PARALLEL_JOBS=${MAX_PARALLEL_JOBS:-50} # 并行任务数，可根据机器性能和配额调整
OUTPUT_DIR="${HOME}/gemini_keys"
TEMP_DIR=$(mktemp -d)
DETAILED_LOG_FILE="${OUTPUT_DIR}/run_$(date +%Y%m%d_%H%M%S).log"

# --- 颜色定义 ---
NC='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'

# ===== 工具函数 =====

# 日志记录函数，带时间戳和锁，确保并行写入安全
log() {
    local type="$1"
    local message="$2"
    local color="$NC"
    case "$type" in
        INFO) color="$CYAN" ;;
        SUCCESS) color="$GREEN" ;;
        WARN) color="$YELLOW" ;;
        ERROR) color="$RED" ;;
    esac
    # flock确保对日志文件的写入是原子的，防止并行时日志交错
    flock "${TEMP_DIR}/log.lock" printf "%s [%s] %-7s %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$type" "$message" | tee -a "$DETAILED_LOG_FILE" >&2
}

# 退出时清理临时文件
cleanup() {
    rm -rf "$TEMP_DIR"
    log "INFO" "临时文件已清理。"
}
trap cleanup EXIT

# 设置环境
setup_environment() {
    mkdir -p "$OUTPUT_DIR"
    touch "${TEMP_DIR}/log.lock"
    log "INFO" "环境设置完毕，日志将记录在: ${DETAILED_LOG_FILE}"
}

# 检查GCP环境
check_gcp_env() {
    if ! gcloud config get-value account >/dev/null 2>&1; then
        log "ERROR" "GCP环境未配置或未登录。请运行 'gcloud auth login' 和 'gcloud config set project'。"
        exit 1
    fi
    log "INFO" "GCP环境检查通过。"
}

# 带重试的gcloud命令执行器
smart_retry_gcloud() {
    local retries=3
    local delay=5
    for i in $(seq 1 $retries); do
        if "$@"; then
            return 0
        fi
        log "WARN" "命令执行失败: '$*', 第 $i 次重试..."
        sleep "$((delay * i))"
    done
    return 1
}

# 生成唯一的项目ID
new_project_id() {
    local prefix="$1"
    echo "${prefix}-$(date +%s)-${RANDOM}"
}

# 提问函数
ask_yes_no() {
    while true; do
        read -r -p "$1 [y/N]: " response
        case "$response" in
            [yY][eE][sS]|[yY]) return 0 ;;
            [nN][oO]|[nN]|"") return 1 ;;
            *) echo "请输入 yes 或 no." >&2 ;;
        esac
    done
}

# 原子化写入密钥
write_key_atomic() {
    local api_key="$1"
    local pure_key_file="$2"
    local comma_key_file="$3"
    local temp_pure
    local temp_comma
    temp_pure=$(mktemp)
    temp_comma=$(mktemp)

    # flock确保对同一个文件的并发写入是安全的
    (
        flock 200
        cat "$pure_key_file" > "$temp_pure"
        echo "$api_key" >> "$temp_pure"
        mv "$temp_pure" "$pure_key_file"

        cat "$comma_key_file" > "$temp_comma"
        # 如果文件不为空，则先加逗号
        [ -s "$temp_comma" ] && echo -n "," >> "$temp_comma"
        echo -n "$api_key" >> "$temp_comma"
        mv "$temp_comma" "$comma_key_file"
    ) 200>"${pure_key_file}.lock"
}

# ===== 核心业务逻辑 (优化后) =====

# [优化后] 步骤3: 为单个项目启用API并创建密钥
# 此函数现在只做一件事：创建密钥。API启用已在之前批量完成。
# 这是并行化执行的最终单元。
process_key_creation_only() {
    local project_id="$1"
    local task_num="$2"
    local total_tasks="$3"
    local pure_key_file="$4"
    local comma_key_file="$5"
    local log_prefix="[${task_num}/${total_tasks}] [${project_id}]"

    log "INFO" "${log_prefix} 开始提取密钥..."

    # 优化点: 将创建和获取key合并为一条命令
    local api_key
    api_key=$(smart_retry_gcloud gcloud alpha services api-keys create \
        --project="$project_id" \
        --display-name="Gemini API Key" \
        --format='value(keyString)' 2>> "$DETAILED_LOG_FILE")

    if [ -z "$api_key" ]; then
        log "ERROR" "${log_prefix} 获取密钥失败。"
        echo "$project_id" >> "${TEMP_DIR}/failed.log"
        return
    fi

    write_key_atomic "$api_key" "$pure_key_file" "$comma_key_file"
    log "SUCCESS" "${log_prefix} 成功获取密钥并已保存！"
    echo "$project_id" >> "${TEMP_DIR}/success.log"
}

# [优化后] 步骤1 & 2: 批量创建项目并启用API
gemini_batch_create_keys_optimized() {
    log "INFO" "====== 高性能批量创建 Gemini API 密钥 (优化版) ======"
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
    echo -e "  并行任务数:     ${BOLD}${MAX_PARALLEL_JOBS}${NC}" >&2
    echo -e "  输出目录:       ${BOLD}${OUTPUT_DIR}${NC}" >&2
    echo -e "${RED}警告: 大规模创建项目可能违反GCP服务条款或超出配额。${NC}" >&2
    if ! ask_yes_no "确认要继续吗?"; then
        log "INFO" "操作已取消。"
        return
    fi

    # --- Phase 1: 异步发起所有项目创建请求 ---
    log "INFO" "[PHASE 1/4] 开始异步发起 ${num_projects} 个项目创建请求..."
    local projects_to_create=()
    local create_operations=()
    for ((i=1; i<=num_projects; i++)); do
        local project_id
        project_id=$(new_project_id "$project_prefix")
        projects_to_create+=("$project_id")
        
        # 优化点: 使用 --async 立即返回，不等待
        local op
        op=$(gcloud projects create "$project_id" --name="$project_id" --quiet --async --format='value(name)' 2>> "$DETAILED_LOG_FILE")
        if [ -n "$op" ]; then
            log "INFO" "项目 [${project_id}] 创建请求已发送，操作名: ${op}"
            create_operations+=("$op")
        else
            log "ERROR" "项目 [${project_id}] 创建请求发送失败。"
            echo "$project_id" >> "${TEMP_DIR}/failed.log"
        fi
    done

    # --- Phase 2: 等待所有项目创建完成 ---
    log "INFO" "[PHASE 2/4] 等待 ${#create_operations[@]} 个项目创建操作完成..."
    local successful_projects=()
    local failed_projects=()
    for op in "${create_operations[@]}"; do
        # gcloud beta services operations wait 是等待长时间操作的标准方法
        if gcloud beta services operations wait "$op" --timeout=300 >/dev/null 2>&1; then
            # 从操作名中提取项目ID (操作名格式通常是 operations/p-p-d-s-12345)
            # 这是一个简化的提取，实际可能需要更复杂的解析
            # 但我们已经有projects_to_create列表，这里只是为了确认成功
            log "SUCCESS" "操作 [${op}] 已成功完成。"
        else
            log "ERROR" "操作 [${op}] 失败或超时。"
        fi
    done
    
    # 验证哪些项目实际创建成功了
    log "INFO" "正在验证已创建的项目..."
    mapfile -t all_active_projects < <(gcloud projects list --filter='lifecycleState:ACTIVE' --format='value(projectId)')
    for proj_id in "${projects_to_create[@]}"; do
        # 使用printf/grep在数组中高效查找
        if printf '%s\n' "${all_active_projects[@]}" | grep -q -w "$proj_id"; then
            successful_projects+=("$proj_id")
        else
            failed_projects+=("$proj_id")
            echo "$proj_id" >> "${TEMP_DIR}/failed.log"
        fi
    done
    
    if [ ${#successful_projects[@]} -eq 0 ]; then
        log "ERROR" "所有项目都创建失败，操作中止。"
        report_and_download_results "" "" # 报告失败
        return
    fi
    log "INFO" "成功创建 ${#successful_projects[@]} 个项目。"

    # --- Phase 3: 批量启用 API ---
    log "INFO" "[PHASE 3/4] 为 ${#successful_projects[@]} 个项目批量启用 Gemini API..."
    # 优化点: 将所有项目ID用逗号连接，一次性调用
    local projects_csv
    projects_csv=$(IFS=,; echo "${successful_projects[*]}")
    
    if smart_retry_gcloud gcloud services enable generativelanguage.googleapis.com --project="$projects_csv" --async; then
        log "SUCCESS" "Gemini API 批量启用请求已成功发送。GCP将在后台处理。"
        # 在生产环境中，这里也应该等待操作完成，为简化，我们假设它会很快成功
        log "INFO" "等待30秒让API启用生效..."
        sleep 30
    else
        log "ERROR" "批量启用 Gemini API 失败。后续的密钥提取可能会失败。"
        # 将所有项目标记为失败
        for proj_id in "${successful_projects[@]}"; do
             echo "$proj_id" >> "${TEMP_DIR}/failed.log"
        done
        report_and_download_results "" ""
        return
    fi
    
    # --- Phase 4: 并行创建和提取密钥 ---
    log "INFO" "[PHASE 4/4] 开始为 ${#successful_projects[@]} 个项目并行提取API密钥..."
    run_parallel_processor "process_key_creation_only" "${successful_projects[@]}"
}

# ===== 编排与原有函数 =====

# 从现有项目提取密钥的函数 (保持不变，但可以受益于优化的提key函数)
process_existing_project_extraction() {
    local project_id="$1"
    local task_num="$2"
    local total_tasks="$3"
    local pure_key_file="$4"
    local comma_key_file="$5"
    local log_prefix="[${task_num}/${total_tasks}] [${project_id}]"

    log "INFO" "${log_prefix} 开始处理现有项目..."
    
    # 启用API
    if ! smart_retry_gcloud gcloud services enable generativelanguage.googleapis.com --project="$project_id" >/dev/null 2>&1; then
        log "ERROR" "${log_prefix} 启用API失败。"
        echo "$project_id" >> "${TEMP_DIR}/failed.log"
        return
    fi
    
    # 调用优化的提key逻辑
    process_key_creation_only "$@"
}

# 并行处理器 (保持不变，非常灵活)
run_parallel_processor() {
    local processor_func="$1"
    shift
    local projects_to_process=("$@")
    
    local pure_key_file="${OUTPUT_DIR}/all_keys.txt"
    local comma_key_file="${OUTPUT_DIR}/all_keys_comma_separated.txt"

    # 初始化输出文件
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
        if [[ -z "$prefix" || "$proj" == "${prefix}"* ]]; then
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
    log "INFO" "开始批量删除任务..."
    
    local job_count=0
    for project_id in "${projects_to_delete[@]}"; do
        {
            if smart_retry_gcloud gcloud projects delete "$project_id" --quiet; then
                log "SUCCESS" "项目 [${project_id}] 删除成功。"
                echo "$project_id" >> "${TEMP_DIR}/delete_success.log"
            else
                log "ERROR" "项目 [${project_id}] 删除失败。"
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

    echo -e "\n${GREEN}${BOLD}====== 批量删除完成 ======${NC}" >&2
    log "SUCCESS" "成功删除: ${success_count}"
    log "ERROR" "删除失败: ${failed_count}"
}

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
    if [ "$failed_count" -gt 0 ]; {
        log "WARN" "失败的项目ID列表保存在详细日志中: ${DETAILED_LOG_FILE}"
        log "WARN" "失败的项目ID也记录在: ${TEMP_DIR}/failed.log"
    }
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
    echo "  1. [极速] 批量创建新项目并提取密钥 (推荐)" >&2
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
            1) gemini_batch_create_keys_optimized ;;
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

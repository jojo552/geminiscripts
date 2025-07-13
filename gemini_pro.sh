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

    # 初始化输出文件，确保每次运行都是干净的
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
    if [ "$failed_count" -gt 0 ]; then
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
    echo "  1. 批量创建新项目并提取密钥" >&2
    echo "  2. 从现有项目中提取 API 密钥" >&2
    echo "  3. 批量删除指定前缀的项目" >&2
    echo "  0. 退出脚本" >&2
    echo "" >&2
}

main_app() {
    mkdir -p "$OUTPUT_DIR"
    touch "${TEMP_DIR}/log.lock"
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

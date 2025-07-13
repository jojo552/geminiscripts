#!/bin/bash

#================================================================================
选择
#
案例
本地成功_计数本地失败_计数
#
$(wc -l <
${TEMP_DIR}
| tr -d
' '
$(wc -l <
${TEMP_DIR}
#================================================================================

| tr -d
' '="2.0-Optimized"
MAX_PARALLEL_JOBSecho -e${绿色}
OUTPUT_DIR=${粗体}
TEMP_DIR====== 操作完成：统计结果 ======
DETAILED_LOG_FILE=${NC}

日志
"成功:
${success_count}='\033[0;31m'
日志='\033[0;32m'
"失败:='\033[0;33m'
${failed_count}='\033[0;35m'
如果='\033[0;36m'
$success_count='\033[1m'

-gt 0]；然后

echo -e
${紫}
echo -e“最终 API like you（you）”="echo -e"
${NC}echo -e="${绿色}"
${粗体}猫="$逗号_key_file"
echo >&2"echo -e" ${NC}
        INFO) echo -e="${紫}" ;;
        SUCCESS) ${NC}="日志" ;;
        WARN) "以上密钥已完整保存至目录:="${粗体}" ;;
        ERROR) ${OUTPUT_DIR}="${NC}日志
逗号分隔密钥文件:
    "${粗体}
${逗号_key_file}"${NC}/log.lock"日志为""做每行一个密钥文件:)${粗体}${pure_key_file}${NC}如果${DEVSHELL_PROJECT_ID-}-a "" >&2"" "" "
}

日志
“检测到云壳，你看我……”
下载-rf "$逗"
日志"="" "
}
${逗号_key_file##*/}

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
    埃罗夫 project_id 回声-e您可以bioto may API${com}${NC}>&2 "回声-e"---------------------">&2"; 回声-e"${Blu}：dddd（you you，you）${NC}">&2
        {
            回声-e"--------------------">&2当地帐户"帐户=$（gcloud config get-value account 2>/dev/null|echo“you you”）" --quiet; 回声-e[you mayoto:${}${NC}]>&2
回声-E[mayoto mayoto:${Mao}${MAX_PARALLEL_JOBS}${NC}]>&2"SUCCESS" 回声-e"---------------------">&2回声-e"\N${mayoto{######****************************************${NC}\N">&2回声[1.[you you you.]]>&2
回声。你你你喜欢]>&2"echo“3.批量删除指定前缀的项目”" >> "echo“0.退出脚本”/delete_success.log"
            “echo”>和2
main_app() {"ERROR" 虽然是真的；做阅读-r-p“请选择操作[0-3]：”choice
案例“$choice”"1) gemini_batch_create_keys_optimized ;;" >> "2) gemini_extract_from_existing ;;/delete_failed.log"
            3) gemini_batch_delete_projects ;;
0）出口0；；
        job_count*）日志“ERROR”“无效输入，无效输入，0、1、2、3”；
        esac [ "echo-E"\N${GREEN}按任意键返回主菜单……${NC}">&2" -ge "日志警告" 0）出口0；；
${DETAILED_LOG_FILE}
            job_count=日志警告
" "
失败的项目 ID
    
${TEMP_DIR}
show_main_menu() {清晰的/delete_success.log失败的项目身份证在你吗：埃罗夫3. 批量删除指定前缀的项目0. 退出脚本
" 信息 job_count*）you will you“ERROR”[you mayoto you，0、1、2、3]；${NC}/delete_failed.log====== 批量删除完成 ======${NC}

出口[回声*）日志
回声"
"main_app() {而真正的
}

做
阅读""
[请选择操作[0-3]：]
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
返回"菲======================================================#--第四阶段：并行创建和提取密钥--\n" >&2

日志"INFO" [第 4/4]${#successful_projects[@]}个项目并行提取 API。${successful_projects[@]}
# ===== 编排与原有函数 =====""#从现有项目提取密钥的函数（你看，你看，你看钥匙）process_existing_project_extraction() { ""当地的$1当地的"
$2当地的$3当地的$4"
        
当地的$5当地的
" ""${task_num}" ${total_tasks}
] [${project_id}"
日志"SUCCESS" ${log_prefix}开始处理现有项目...""
"个活跃项目。请选择要处理的项目:"
"$((i+1))
为i in{TEMP_DIR}${!all_projects[@]}
"; do
printf ""
    }
}

其他的
日志
警告
" "
无效的编号:
$num
 ||__|||__|||__|||__|||__|||__|||_______|||__|||__|||__||
 |/__\|/__\|/__\|/__\|/__\|/__\|/_______\|/__\|/__\|/__\|
，已忽略。
"菲"
"完成"
"菲"
如果
${#projects_to_process[@]}
" >&2"
-eq 0]；然后
" -ge "
"日志""
为 I在{TEMP_DIR}
"" "
${!all_projects[@]}
""; do'
其他的
为
}

${selections[@]}
    check_gcp_env

"做
如果
        show_main_menu
$num
" =~ ^[0-9]+
$
]] && [ "
$num
" -ge 1 ] && [ "
$num
" -le "
${#all_projects[@]}
然后]
${all_projects[
}

$（（编号-1））
setup_environment
main_app

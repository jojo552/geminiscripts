#!/bin/bash

# ===== 配置 =====
# 自动生成随机用户名
TIMESTAMP=$(date +%s)
RANDOM_CHARS=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 4 | head -n 1)
EMAIL_USERNAME="momo${RANDOM_CHARS}${TIMESTAMP:(-4)}"
PROJECT_PREFIX="gemini-key"
TOTAL_PROJECTS=175  # 默认项目数 (可能会根据配额检查结果自动调整)
### MODIFICATION ###: Increased default parallel jobs for maximum speed.
MAX_PARALLEL_JOBS=40  # 默认设置为40 (可根据机器性能和网络调整)
### MODIFICATION ###: New setting for the single wait period after project creation.
GLOBAL_WAIT_SECONDS=75 # 创建项目和启用API之间的全局等待时间 (秒)
MAX_RETRY_ATTEMPTS=3  # 重试次数
# 只保留纯密钥和逗号分隔密钥文件
PURE_KEY_FILE="key.txt"
COMMA_SEPARATED_KEY_FILE="comma_separated_keys_${EMAIL_USERNAME}.txt"
SECONDS=0
DELETION_LOG="project_deletion_$(date +%Y%m%d_%H%M%S).log"
CLEANUP_LOG="api_keys_cleanup_$(date +%Y%m%d_%H%M%S).log"
TEMP_DIR="/tmp/gcp_script_${TIMESTAMP}"
# ===== 配置结束 =====

# ===== 初始化 =====
# 创建临时目录
mkdir -p "$TEMP_DIR"

# 统一日志函数 (脚本内部使用)
_log_internal() {
  local level=$1
  local msg=$2
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] [$level] $msg"
}

_log_internal "INFO" "JSON 解析将仅使用备用方法 (sed/grep)。"
sleep 1
# ===== 初始化结束 =====

# ===== 工具函数 =====
# 统一日志函数 (对外暴露)
log() {
  local level=$1
  local msg=$2
  _log_internal "$level" "$msg"
}

# 解析JSON并提取字段（仅使用备用方法）
parse_json() {
  local json="$1"
  local field="$2"
  local value=""

  if [ -z "$json" ]; then return 1; fi

  case "$field" in
    ".keyString")
      value=$(echo "$json" | sed -n 's/.*"keyString": *"\([^"]*\)".*/\1/p')
      ;;
    ".[0].name")
      value=$(echo "$json" | sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' | head -n 1)
      ;;
    *)
      local field_name=$(echo "$field" | tr -d '.["]')
      value=$(echo "$json" | grep -oP "(?<=\"$field_name\":\s*\")[^\"]*" 2>/dev/null)
      if [ -z "$value" ]; then
           value=$(echo "$json" | grep -oP "(?<=\"$field_name\":\s*)[^,\s\}]+" 2>/dev/null | head -n 1)
      fi
      ;;
  esac

  if [ -n "$value" ]; then
    echo "$value"
    return 0
  else
    log "ERROR" "parse_json: 备用方法未能提取有效值 '$field'"
    return 1
  fi
}

# 仅在成功时写入纯密钥文件的函数
write_keys_to_files() {
    local api_key="$1"

    if [ -z "$api_key" ]; then
        log "ERROR" "write_keys_to_files called with empty API key!"
        return
    fi

    # 使用文件锁确保写入原子性
    (
        flock 200
        # 写入纯密钥文件 (只有密钥，每行一个)
        echo "$api_key" >> "$PURE_KEY_FILE"
        # 写入逗号分隔文件 (只有密钥，用逗号分隔)
        if [[ -s "$COMMA_SEPARATED_KEY_FILE" ]]; then
            echo -n "," >> "$COMMA_SEPARATED_KEY_FILE"
        fi
        echo -n "$api_key" >> "$COMMA_SEPARATED_KEY_FILE"
    ) 200>"${TEMP_DIR}/key_files.lock"
}


# 改进的指数退避重试函数
retry_with_backoff() {
  local max_attempts=$1
  local cmd=$2
  local attempt=1
  local timeout=5
  local error_log="${TEMP_DIR}/error_$(date +%s)_$RANDOM.log"

  while [ $attempt -le $max_attempts ]; do
    if bash -c "$cmd" 2>"$error_log"; then
      rm -f "$error_log"; return 0
    else
      local error_code=$?; local error_msg=$(cat "$error_log")
      log "INFO" "命令尝试 $attempt/$max_attempts 失败 (退出码: $error_code)，错误: ${error_msg:-'未知错误'}"
      if [[ "$error_msg" == *"Permission denied"* ]] || [[ "$error_msg" == *"Authentication failed"* ]]; then
          log "ERROR" "检测到权限或认证错误，停止重试。"; rm -f "$error_log"; return $error_code
      elif [[ "$error_msg" == *"Quota exceeded"* ]]; then
         log "WARN" "检测到配额错误，重试可能无效。"
      fi
      if [ $attempt -lt $max_attempts ]; then
          log "INFO" "等待 $timeout 秒后重试..."; sleep $timeout
          timeout=$((timeout * 2)); if [ $timeout -gt 60 ]; then timeout=60; fi
      fi; attempt=$((attempt + 1))
    fi
  done
  log "ERROR" "命令在 $max_attempts 次尝试后最终失败。"
  if [ -f "$error_log" ]; then local final_error=$(cat "$error_log"); log "ERROR" "最后一次错误信息: ${final_error:-'未知错误'}"; rm -f "$error_log"; fi
  return 1
}

# 进度条显示（优化版）
show_progress() {
    local completed=$1
    local total=$2
    if [ $total -le 0 ]; then printf "\r%-80s" " "; printf "\r[总数无效: %d]" "$total"; return; fi
    if [ $completed -gt $total ]; then completed=$total; fi

    local percent=$((completed * 100 / total))
    local completed_chars=$((percent * 50 / 100))
    if [ $completed_chars -lt 0 ]; then completed_chars=0; fi
    if [ $completed_chars -gt 50 ]; then completed_chars=50; fi
    local remaining_chars=$((50 - completed_chars))
    local progress_bar=$(printf "%${completed_chars}s" "" | tr ' ' '#')
    local remaining_bar=$(printf "%${remaining_chars}s" "")
    printf "\r%-80s" " "; printf "\r[%s%s] %d%% (%d/%d)" "$progress_bar" "$remaining_bar" "$percent" "$completed" "$total"
}


# 配额检查及调整（改进版）
check_quota() {
  log "INFO" "检查GCP项目创建配额..."
  local current_project=$(gcloud config get-value project 2>/dev/null)
  if [ -z "$current_project" ]; then log "WARN" "无法获取当前GCP项目ID，无法准确检查配额。将跳过配额检查。"; return 0; fi

  local projects_quota; local quota_cmd; local quota_output; local error_msg;
  quota_cmd="gcloud services quota list --service=cloudresourcemanager.googleapis.com --consumer=projects/$current_project --filter='metric=cloudresourcemanager.googleapis.com/project_create_requests' --format=json 2>${TEMP_DIR}/quota_error.log"
  if quota_output=$(retry_with_backoff 2 "$quota_cmd"); then
      projects_quota=$(echo "$quota_output" | grep -oP '(?<="effectiveLimit": ")[^"]+' | head -n 1)
  else
    log "INFO" "GA services quota list 命令失败，尝试 alpha services quota list..."
    quota_cmd="gcloud alpha services quota list --service=cloudresourcemanager.googleapis.com --consumer=projects/$current_project --filter='metric(cloudresourcemanager.googleapis.com/project_create_requests)' --format=json 2>${TEMP_DIR}/quota_error.log"
    if quota_output=$(retry_with_backoff 2 "$quota_cmd"); then
        projects_quota=$(echo "$quota_output" | grep -oP '(?<="INT64": ")[^"]+' | head -n 1)
    else
        error_msg=$(cat "${TEMP_DIR}/quota_error.log" 2>/dev/null); rm -f "${TEMP_DIR}/quota_error.log"
        log "WARN" "无法获取配额信息 (尝试GA和alpha命令均失败): ${error_msg:-'命令执行失败'}"; log "WARN" "将使用默认设置继续，但强烈建议手动检查配额，避免失败。"
        read -p "无法检查配额，是否继续执行? [y/N]: " continue_no_quota
        if [[ "$continue_no_quota" =~ ^[Yy]$ ]]; then return 0; else log "INFO" "操作已取消。"; return 1; fi
    fi
  fi; rm -f "${TEMP_DIR}/quota_error.log"

  if [ -z "$projects_quota" ] || ! [[ "$projects_quota" =~ ^[0-9]+$ ]]; then
    log "WARN" "无法从输出中准确提取项目创建配额值。将使用默认设置 ($TOTAL_PROJECTS) 继续。"; return 0;
  fi

  local quota_limit=$projects_quota; log "INFO" "检测到项目创建配额限制大约为: $quota_limit"
  if [ "$TOTAL_PROJECTS" -gt "$quota_limit" ]; then
    log "WARN" "计划创建的项目数($TOTAL_PROJECTS) 大于检测到的配额限制($quota_limit)"
    echo "选项:"; echo "1. 继续尝试创建 $TOTAL_PROJECTS 个项目 (很可能部分失败)"; echo "2. 调整为创建 $quota_limit 个项目 (更符合配额限制)"; echo "3. 取消操作"
    read -p "请选择 [1/2/3]: " quota_option
    case $quota_option in
      1) log "INFO" "将尝试创建 $TOTAL_PROJECTS 个项目，请注意配额限制。" ;;
      2) TOTAL_PROJECTS=$quota_limit; log "INFO" "已调整计划，将创建 $TOTAL_PROJECTS 个项目" ;;
      3|*) log "INFO" "操作已取消"; return 1 ;;
    esac
  else log "SUCCESS" "计划创建的项目数($TOTAL_PROJECTS) 在检测到的配额限制($quota_limit)之内。"; fi
  return 0
}

# 生成报告
generate_report() {
  local success=$1
  local attempted=$2
  local success_rate=0
  if [ "$attempted" -gt 0 ]; then success_rate=$(echo "scale=2; $success * 100 / $attempted" | bc); fi
  local failed=$((attempted - success))
  local duration=$SECONDS
  local minutes=$((duration / 60))
  local seconds_rem=$((duration % 60))
  echo ""; echo "========== 执行报告 =========="
  echo "计划目标: $attempted 个项目"
  echo "成功获取密钥: $success 个"
  echo "失败: $failed 个"
  echo "成功率: $success_rate%"
  if [ $success -gt 0 ]; then local avg_time=$((duration / success)); echo "平均处理时间 (成功项目): $avg_time 秒/项目"; fi
  echo "总执行时间: $minutes 分 $seconds_rem 秒"
  echo "API密钥已保存至:"
  echo "- 纯API密钥 (每行一个): $PURE_KEY_FILE"
  echo "- 逗号分隔密钥 (单行): $COMMA_SEPARATED_KEY_FILE"
  echo "=========================="
}

### MODIFICATION ###: New task functions for phased execution
# 任务1: 创建项目
task_create_project() {
    local project_id="$1"
    local project_num="$2"
    local total="$3"
    local success_file="$4"
    local error_log="${TEMP_DIR}/create_${project_id}_error.log"

    log "INFO" "[$project_num/$total] 1. 发送创建请求: $project_id"
    if gcloud projects create "$project_id" --name="$project_id" --no-set-as-default --quiet >/dev/null 2>"$error_log"; then
        # Success, record project ID for the next phase
        (flock 200; echo "$project_id" >> "$success_file";) 200>"${success_file}.lock"
        rm -f "$error_log"
        return 0
    else
        local creation_error=$(cat "$error_log" 2>/dev/null)
        log "ERROR" "[$project_num/$total] 创建项目失败: $project_id: ${creation_error:-未知错误}"
        rm -f "$error_log"
        return 1
    fi
}

# 任务2: 启用API
task_enable_api() {
    local project_id="$1"
    local project_num="$2"
    local total="$3"
    local success_file="$4"
    local error_log="${TEMP_DIR}/enable_${project_id}_error.log"

    log "INFO" "[$project_num/$total] 2. 启用API: $project_id"
    if retry_with_backoff $MAX_RETRY_ATTEMPTS "gcloud services enable generativelanguage.googleapis.com --project=\"$project_id\" --quiet 2>\"$error_log\""; then
        # Success, record project ID for the final phase
        (flock 200; echo "$project_id" >> "$success_file";) 200>"${success_file}.lock"
        rm -f "$error_log"
        return 0
    else
        local enable_error=$(cat "$error_log" 2>/dev/null)
        log "ERROR" "[$project_num/$total] 启用API失败: $project_id: ${enable_error:-未知错误}"
        rm -f "$error_log"
        return 1
    fi
}

# 任务3: 创建并提取密钥
task_create_key() {
    local project_id="$1"
    local project_num="$2"
    local total="$3"
    local error_log="${TEMP_DIR}/key_${project_id}_error.log"
    local create_output

    log "INFO" "[$project_num/$total] 3. 创建密钥: $project_id"
    if ! create_output=$(retry_with_backoff $MAX_RETRY_ATTEMPTS "gcloud services api-keys create --project=\"$project_id\" --display-name=\"Gemini API Key for $project_id\" --format=\"json\" --quiet 2>\"$error_log\""); then
        local key_create_error=$(cat "$error_log" 2>/dev/null)
        log "ERROR" "[$project_num/$total] 创建密钥失败: $project_id: ${key_create_error:-未知错误}"
        rm -f "$error_log"
        return 1
    fi

    local api_key
    api_key=$(parse_json "$create_output" ".keyString")
    if [ -n "$api_key" ]; then
        log "SUCCESS" "[$project_num/$total] 成功提取密钥: $project_id"
        write_keys_to_files "$api_key"
        rm -f "$error_log"
        return 0
    else
        log "ERROR" "[$project_num/$total] 提取密钥失败: $project_id (无法从gcloud输出解析keyString)"
        rm -f "$error_log"
        return 1
    fi
}

# 删除单个项目函数
delete_project() {
  local project_id="$1"
  local project_num="$2"
  local total="$3"
  local error_log="${TEMP_DIR}/delete_${project_id}_error.log"; rm -f "$error_log"

  log "INFO" ">>> [$project_num/$total] 删除项目: $project_id"
  if gcloud projects delete "$project_id" --quiet 2>"$error_log"; then
    log "SUCCESS" "<<< [$project_num/$total] 成功删除项目: $project_id"
    ( flock 201; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$project_num/$total] 已删除: $project_id" >> "$DELETION_LOG"; ) 201>"${TEMP_DIR}/${DELETION_LOG}.lock"
    rm -f "$error_log"; return 0
  else
    local error_msg=$(cat "$error_log" 2>/dev/null); rm -f "$error_log"
    log "ERROR" "<<< [$project_num/$total] 删除项目失败: $project_id: ${error_msg:-'未知错误'}"
    ( flock 201; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$project_num/$total] 删除失败: $project_id - ${error_msg:-'未知错误'}" >> "$DELETION_LOG"; ) 201>"${TEMP_DIR}/${DELETION_LOG}.lock"
    return 1
  fi
}

# 资源清理函数
cleanup_resources() {
  log "INFO" "执行退出清理..."
  if [ -d "$TEMP_DIR" ]; then log "INFO" "删除临时目录: $TEMP_DIR"; rm -rf "$TEMP_DIR"; fi
  log "INFO" "资源清理完成"
}
# ===== 工具函数结束 =====

# ===== 功能模块 =====
# 并行执行框架
run_parallel() {
    local task_func="$1"
    local description="$2"
    local success_file="$3"
    shift 3
    local items=("$@")
    local total_items=${#items[@]}

    if [ $total_items -eq 0 ]; then
        log "INFO" "在 '$description' 阶段没有需要处理的项目。"
        return 0
    fi

    local active_jobs=0
    local completed_count=0
    local success_count=0
    local fail_count=0
    local pids=()

    log "INFO" "开始并行执行 '$description' (最多 $MAX_PARALLEL_JOBS 个并行)..."

    for i in "${!items[@]}"; do
        local item="${items[i]}"
        local item_num=$((i + 1))

        "$task_func" "$item" "$item_num" "$total_items" "$success_file" &
        pids+=($!)
        ((active_jobs++))

        if [[ "$active_jobs" -ge "$MAX_PARALLEL_JOBS" ]]; then
            wait -n
            ((active_jobs--))
        fi
    done

    # 等待所有剩余任务完成
    log "INFO" "所有 $total_items 个 '$description' 任务已启动, 等待剩余任务完成..."
    for pid in "${pids[@]}"; do
        wait "$pid"
        local exit_status=$?
        ((completed_count++))
        if [ $exit_status -eq 0 ]; then
            ((success_count++))
        else
            ((fail_count++))
        fi
        show_progress $completed_count $total_items
        echo -n " $description 中 (S:$success_count F:$fail_count)..."
    done

    echo # Newline after progress bar
    log "INFO" "阶段 '$description' 完成。成功: $success_count, 失败: $fail_count"
    log "INFO" "======================================================"

    if [ $fail_count -gt 0 ]; then return 1; else return 0; fi
}

### MODIFICATION ###: Rewritten function to use the high-speed phased approach.
create_projects_and_get_keys_fast() {
    SECONDS=0
    log "INFO" "======================================================"
    log "INFO" "高速模式: 新建项目并获取API密钥"
    log "INFO" "======================================================"

    if ! check_quota; then return 1; fi
    if [ $TOTAL_PROJECTS -le 0 ]; then log "WARN" "计划创建项目数为 0 或无效，操作结束。"; return 0; fi

    log "INFO" "将使用随机生成的用户名: ${EMAIL_USERNAME}"
    log "INFO" "项目前缀: ${PROJECT_PREFIX}"
    log "INFO" "即将开始为 $TOTAL_PROJECTS 个新项目获取密钥..."
    log "INFO" "脚本将在 5 秒后开始执行..."; sleep 5

    # 初始化输出文件
    > "$PURE_KEY_FILE"
    > "$COMMA_SEPARATED_KEY_FILE"

    # 生成需要创建的项目ID列表
    local projects_to_create=()
    for i in $(seq 1 $TOTAL_PROJECTS); do
        local project_num=$(printf "%03d" $i)
        local base_id="${PROJECT_PREFIX}-${EMAIL_USERNAME}-${project_num}"
        # Ensure project ID is valid
        local project_id=$(echo "$base_id" | tr -cd 'a-z0-9-' | cut -c 1-30 | sed 's/-$//')
        if ! [[ "$project_id" =~ ^[a-z] ]]; then
            project_id="g${project_id:1}"
            project_id=$(echo "$project_id" | cut -c 1-30 | sed 's/-$//')
        fi
        projects_to_create+=("$project_id")
    done

    # --- PHASE 1: Create Projects ---
    local CREATED_PROJECTS_FILE="${TEMP_DIR}/created_projects.txt"
    > "$CREATED_PROJECTS_FILE"
    export -f task_create_project log retry_with_backoff
    export TEMP_DIR MAX_RETRY_ATTEMPTS
    run_parallel task_create_project "阶段1: 创建项目" "$CREATED_PROJECTS_FILE" "${projects_to_create[@]}"

    local created_project_ids=()
    if [ -f "$CREATED_PROJECTS_FILE" ]; then
        mapfile -t created_project_ids < "$CREATED_PROJECTS_FILE"
    fi
    if [ ${#created_project_ids[@]} -eq 0 ]; then
        log "ERROR" "项目创建阶段失败，没有任何项目成功创建。中止操作。"
        return 1
    fi

    # --- PHASE 2: Global Wait ---
    log "INFO" "阶段2: 全局等待 ${GLOBAL_WAIT_SECONDS} 秒，以便GCP后端同步项目状态..."
    show_progress 0 ${GLOBAL_WAIT_SECONDS}
    for ((i=1; i<=${GLOBAL_WAIT_SECONDS}; i++)); do
        sleep 1
        show_progress $i ${GLOBAL_WAIT_SECONDS}
        echo -n " 等待中..."
    done
    echo # Newline after progress bar
    log "INFO" "等待完成。"
    log "INFO" "======================================================"

    # --- PHASE 3: Enable APIs ---
    local ENABLED_PROJECTS_FILE="${TEMP_DIR}/enabled_projects.txt"
    > "$ENABLED_PROJECTS_FILE"
    export -f task_enable_api log retry_with_backoff
    export TEMP_DIR MAX_RETRY_ATTEMPTS
    run_parallel task_enable_api "阶段3: 启用API" "$ENABLED_PROJECTS_FILE" "${created_project_ids[@]}"

    local enabled_project_ids=()
    if [ -f "$ENABLED_PROJECTS_FILE" ]; then
        mapfile -t enabled_project_ids < "$ENABLED_PROJECTS_FILE"
    fi
    if [ ${#enabled_project_ids[@]} -eq 0 ]; then
        log "ERROR" "API启用阶段失败，没有任何项目成功启用API。中止操作。"
        generate_report 0 $TOTAL_PROJECTS
        return 1
    fi

    # --- PHASE 4: Create Keys ---
    export -f task_create_key log retry_with_backoff parse_json write_keys_to_files
    export TEMP_DIR MAX_RETRY_ATTEMPTS PURE_KEY_FILE COMMA_SEPARATED_KEY_FILE
    # For key creation, the success file is not needed as it writes directly to final files
    run_parallel task_create_key "阶段4: 创建密钥" "/dev/null" "${enabled_project_ids[@]}"

    # --- FINAL REPORT ---
    local successful_keys=$(wc -l < "$PURE_KEY_FILE" | xargs)
    generate_report "$successful_keys" "$TOTAL_PROJECTS"
    log "INFO" "======================================================"
    log "INFO" "请检查文件 '$PURE_KEY_FILE' 和 '$COMMA_SEPARATED_KEY_FILE' 中的内容"
    if [ "$successful_keys" -lt "$TOTAL_PROJECTS" ]; then
        local failed_count=$((TOTAL_PROJECTS - successful_keys))
        log "WARN" "有 $failed_count 个项目未能成功获取密钥，请检查上方日志了解详情。"
    fi
    log "INFO" "提醒：项目需要关联有效的结算账号才能实际使用 API 密钥"
    log "INFO" "======================================================"
}


# 功能4：删除所有现有项目
delete_all_existing_projects() {
  SECONDS=0
  log "INFO" "======================================================"; log "INFO" "功能4: 删除所有现有项目"; log "INFO" "======================================================"
  log "INFO" "正在获取项目列表..."; local list_error="${TEMP_DIR}/list_projects_error.log"; local ALL_PROJECTS=($(gcloud projects list --format="value(projectId)" --filter="projectId!~^sys-" --quiet 2>"$list_error")); local list_ec=$?; rm -f "$list_error"
  if [ $list_ec -ne 0 ]; then local error_msg=$(cat "$list_error" 2>/dev/null); log "ERROR" "无法获取项目列表: ${error_msg:-'gcloud命令失败'}"; return 1; fi
  if [ ${#ALL_PROJECTS[@]} -eq 0 ]; then log "INFO" "未找到任何用户项目，无需删除"; return 0; fi
  local total_to_delete=${#ALL_PROJECTS[@]}
  log "INFO" "找到 $total_to_delete 个用户项目需要删除"; echo "前5个项目示例："; for ((i=0; i<5 && i<${#ALL_PROJECTS[@]}; i++)); do printf " - %s\n" "${ALL_PROJECTS[i]}"; done; if [ ${#ALL_PROJECTS[@]} -gt 5 ]; then echo " - ... 以及其他 $((${#ALL_PROJECTS[@]} - 5)) 个项目"; fi
  read -p "!!! 危险操作 !!! 确认要删除所有 $total_to_delete 个项目吗？此操作不可撤销！(输入 'DELETE-ALL' 确认): " confirm; if [ "$confirm" != "DELETE-ALL" ]; then log "INFO" "删除操作已取消，返回主菜单"; return 1; fi
  echo "项目删除日志 ($(date +%Y-%m-%d_%H:%M:%S))" > "$DELETION_LOG"; echo "------------------------------------" >> "$DELETION_LOG"
  export -f delete_project log retry_with_backoff show_progress
  export DELETION_LOG TEMP_DIR MAX_PARALLEL_JOBS MAX_RETRY_ATTEMPTS

  run_parallel delete_project "删除项目" "/dev/null" "${ALL_PROJECTS[@]}"
  local delete_status=$?

  local successful_deletions=$(grep -c "已删除:" "$DELETION_LOG")
  local failed_deletions=$(grep -c "删除失败:" "$DELETION_LOG")
  local duration=$SECONDS; local minutes=$((duration / 60)); local seconds_rem=$((duration % 60))
  echo ""; echo "========== 删除报告 =========="; echo "总计尝试删除: $total_to_delete 个项目"; echo "成功删除: $successful_deletions 个项目"; echo "删除失败: $failed_deletions 个项目"; echo "总执行时间: $minutes 分 $seconds_rem 秒"; echo "详细日志已保存至: $DELETION_LOG"; echo "=========================="
  return $delete_status
}

# 显示主菜单
show_menu() {
  clear
  echo "======================================================"
  echo "     GCP Gemini API 密钥懒人管理工具 v3.0 (高速版)"
  echo "======================================================"
  local current_account; current_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -n 1); if [ -z "$current_account" ]; then current_account="无法获取"; fi
  local current_project; current_project=$(gcloud config get-value project 2>/dev/null); if [ -z "$current_project" ]; then current_project="未设置"; fi
  echo "当前账号: $current_account"; echo "当前项目: $current_project"
  echo "并行任务数: $MAX_PARALLEL_JOBS"; echo "全局等待: ${GLOBAL_WAIT_SECONDS}s"; echo "重试次数: $MAX_RETRY_ATTEMPTS"
  echo ""; echo "请选择功能:";
  echo "1. [高速] 一键新建项目并获取API密钥"
  echo "2. 一键删除所有现有项目"
  echo "3. 修改配置参数"
  echo "0. 退出"
  echo "======================================================"
  read -p "请输入选项 [0-3]: " choice

  case $choice in
    1) create_projects_and_get_keys_fast ;;
    2) delete_all_existing_projects ;;
    3) configure_settings ;;
    0) log "INFO" "正在退出..."; exit 0 ;;
    *) echo "无效选项 '$choice'，请重新选择。"; sleep 2 ;;
  esac
  if [[ "$choice" =~ ^[1-3]$ ]]; then echo ""; read -p "按回车键返回主菜单..."; fi
}

# 配置设置
configure_settings() {
  local setting_changed=false
  while true; do
      clear; echo "======================================================"; echo "配置参数"; echo "======================================================"
      echo "当前设置:";
      echo "1. 项目前缀 (用于新建项目): $PROJECT_PREFIX"
      echo "2. 计划创建的项目数量: $TOTAL_PROJECTS"
      echo "3. 最大并行任务数: $MAX_PARALLEL_JOBS"
      echo "4. 最大重试次数 (用于API调用): $MAX_RETRY_ATTEMPTS"
      echo "5. 全局等待时间 (秒): $GLOBAL_WAIT_SECONDS"
      echo "0. 返回主菜单"
      echo "======================================================"
      read -p "请选择要修改的设置 [0-5]: " setting_choice
      case $setting_choice in
        1) read -p "请输入新的项目前缀 (留空取消): " new_prefix; if [ -n "$new_prefix" ]; then if [[ "$new_prefix" =~ ^[a-z][a-z0-9-]{0,19}$ ]]; then PROJECT_PREFIX="$new_prefix"; log "INFO" "项目前缀已更新为: $PROJECT_PREFIX"; setting_changed=true; else echo "错误：前缀必须以小写字母开头，只能包含小写字母、数字和连字符，长度1-20。"; sleep 2; fi; fi ;;
        2) read -p "请输入计划创建的项目数量 (留空取消): " new_total; if [[ "$new_total" =~ ^[1-9][0-9]*$ ]]; then TOTAL_PROJECTS=$new_total; log "INFO" "计划创建的项目数量已更新为: $TOTAL_PROJECTS"; setting_changed=true; elif [ -n "$new_total" ]; then echo "错误：请输入一个大于0的整数。"; sleep 2; fi ;;
        3) read -p "请输入最大并行任务数 (建议 20-80，留空取消): " new_parallel; if [[ "$new_parallel" =~ ^[1-9][0-9]*$ ]]; then MAX_PARALLEL_JOBS=$new_parallel; log "INFO" "最大并行任务数已更新为: $MAX_PARALLEL_JOBS"; setting_changed=true; elif [ -n "$new_parallel" ]; then echo "错误：请输入一个大于0的整数。"; sleep 2; fi ;;
        4) read -p "请输入最大重试次数 (建议 1-5，留空取消): " new_retries; if [[ "$new_retries" =~ ^[1-9][0-9]*$ ]]; then MAX_RETRY_ATTEMPTS=$new_retries; log "INFO" "最大重试次数已更新为: $MAX_RETRY_ATTEMPTS"; setting_changed=true; elif [ -n "$new_retries" ]; then echo "错误：请输入一个大于等于1的整数。"; sleep 2; fi ;;
        5) read -p "请输入新的全局等待时间 (秒, 建议 60-120, 留空取消): " new_wait; if [[ "$new_wait" =~ ^[1-9][0-9]*$ ]]; then GLOBAL_WAIT_SECONDS=$new_wait; log "INFO" "全局等待时间已更新为: $GLOBAL_WAIT_SECONDS"; setting_changed=true; elif [ -n "$new_wait" ]; then echo "错误：请输入一个大于0的整数。"; sleep 2; fi ;;
        0) return ;;
        *) echo "无效选项 '$setting_choice'，请重新选择。"; sleep 2 ;;
      esac; if $setting_changed; then sleep 1; setting_changed=false; fi
  done
}

# ===== 主程序 =====
# 设置退出处理函数
trap cleanup_resources EXIT SIGINT SIGTERM

# --- 登录和项目检查 ---
log "INFO" "检查 GCP 登录状态..."; if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" >/dev/null; then log "WARN" "无法获取活动账号信息，或者尚未登录。请尝试登录:"; if ! gcloud auth login; then log "ERROR" "登录失败。请确保您可以通过 'gcloud auth login' 成功登录后再运行脚本。"; exit 1; fi; log "INFO" "再次检查 GCP 登录状态..."; if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" >/dev/null; then log "ERROR" "登录后仍无法获取账号信息，脚本无法继续。请检查 'gcloud auth list' 的输出。"; exit 1; fi; fi; log "INFO" "GCP 账号检查通过。"
log "INFO" "检查 GCP 项目配置..."; if ! gcloud config get-value project >/dev/null; then log "WARN" "尚未设置默认GCP项目。某些操作（如配额检查）可能无法正常工作。"; log "WARN" "建议使用 'gcloud config set project YOUR_PROJECT_ID' 设置一个默认项目。"; sleep 3; else log "INFO" "GCP 项目配置检查完成 (当前项目: $(gcloud config get-value project))。"; fi

# --- 主菜单循环 ---
while true; do show_menu; done

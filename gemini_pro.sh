#!/bin/bash
# 全自动 Gemini API 密钥管家 - 交互式菜单版
# 版本: 4.0 (Interactive & Automated)

# 严格模式
set -Eeuo pipefail

# ===== 全局配置 (可通过环境变量覆盖) =====
CONCURRENCY="${CONCURRENCY:-40}"
PROJECT_PREFIX="${PROJECT_PREFIX:-cloud-project}"
MAX_RETRY="${MAX_RETRY:-3}"
STATE_FILE="LAST_RUN_PROJECTS.log" # 自动记录上次运行的项目列表

# ===== 颜色定义 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ===== 日志与工具函数 =====
log() { echo -e "${CYAN}[$(date '+%H:%M:%S')] [INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[$(date '+%H:%M:%S')] [SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[$(date '+%H:%M:%S')] [ERROR]${NC} $1" >&2; }

check_environment() {
    log "正在检查环境..."
    if ! command -v gcloud &>/dev/null; then
        log_error "gcloud CLI 未找到。请先安装 Google Cloud SDK。"; exit 1;
    fi
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q '.'; then
        log_error "未登录 gcloud。请运行 'gcloud auth login'。"; exit 1;
    fi
    if ! command -v bc &>/dev/null; then
        log_error "未找到 'bc' 命令，无法计算速度。请安装 (e.g., sudo apt-get install bc)";
    fi
    log_success "环境检查通过。活动账号: $(gcloud config get-value account)"
}

retry() {
    local n=1; local max=$MAX_RETRY; local delay=5
    while true; do
        "$@" && break || {
            if [[ $n -lt $max ]]; then
                ((n++)); log_error "命令失败。将在 ${delay}s 后重试 ($n/$max): $*"; sleep $delay;
            else
                log_error "命令在 ${max} 次尝试后仍然失败: $*"; return 1;
            fi
        }
    done
}

generate_suffix() {
    if command -v uuidgen &>/dev/null; then uuidgen | tr -d '-' | cut -c1-6; else date +%s%N | sha256sum | cut -c1-6; fi
}

increment_counter() {
    ( flock 200; local val=$(cat "$1"); echo $((val + 1)) > "$1"; ) 200>"$1.lock"
}

# ===== 核心并行处理逻辑 =====
process_single_project() {
    local project_id="$1"
    local temp_dir="$2"
    local success_counter_file="${temp_dir}/success.count"
    local fail_counter_file="${temp_dir}/fail.count"
    local key_file="${temp_dir}/keys.txt"
    local failed_log="${temp_dir}/failed.log"

    sleep 0.$(($RANDOM % 5))

    if ! retry gcloud projects create "$project_id" --quiet >/dev/null 2>&1; then
        echo "$project_id - Create failed" >> "$failed_log"; increment_counter "$fail_counter_file"; return 1;
    fi

    if ! retry gcloud services enable generativelanguage.googleapis.com --project="$project_id" --quiet >/dev/null 2>&1; then
        echo "$project_id - API enable failed" >> "$failed_log"; gcloud projects delete "$project_id" --quiet >/dev/null 2>&1 &; increment_counter "$fail_counter_file"; return 1;
    fi

    local key_output
    if ! key_output=$(retry gcloud services api-keys create --project="$project_id" --display-name="gemini-key" --format=json --quiet 2>&1); then
        echo "$project_id - Key create failed: $key_output" >> "$failed_log"; increment_counter "$fail_counter_file"; return 1;
    fi

    local api_key=$(echo "$key_output" | grep -o '"keyString":"[^"]*"' | cut -d'"' -f4)

    if [[ -z "$api_key" ]]; then
        echo "$project_id - Key extract failed" >> "$failed_log"; increment_counter "$fail_counter_file"; return 1;
    fi

    ( flock 200; echo "$api_key" >> "$key_file"; ) 200>"${key_file}.lock"
    increment_counter "$success_counter_file"
    return 0
}

# ===== 交互式功能 =====

main_create() {
    local total_to_create
    read -p "请输入要创建的项目数量: " total_to_create
    if ! [[ "$total_to_create" =~ ^[1-9][0-9]*$ ]]; then
        log_error "无效的数量。请输入一个正整数。"; sleep 2; return;
    fi
    
    echo -e "${YELLOW}即将创建 ${total_to_create} 个项目，并行数: ${CONCURRENCY}。${NC}"
    read -p "确认开始吗? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[yY](es)?$ ]]; then
        log "操作已取消。"; sleep 2; return;
    fi

    log "===== 开始批量创建 Gemini API 密钥 ====="
    
    local temp_dir=$(mktemp -d); trap 'rm -rf -- "$temp_dir"' RETURN
    local success_counter_file="${temp_dir}/success.count"
    local fail_counter_file="${temp_dir}/fail.count"
    local key_file="${temp_dir}/keys.txt"
    local failed_log="${temp_dir}/failed.log"
    local project_list_file="${temp_dir}/projects.list"
    echo 0 > "$success_counter_file"; echo 0 > "$fail_counter_file"

    local start_time=$SECONDS; local active_jobs=0

    # 先生成所有项目ID，并写入状态文件和临时文件
    rm -f "$STATE_FILE"
    for ((i=0; i<total_to_create; i++)); do
        local project_id="${PROJECT_PREFIX}-$(generate_suffix)"
        echo "$project_id" | tee -a "$STATE_FILE" >> "$project_list_file"
    done
    log_success "所有项目ID已生成并保存到 ${STATE_FILE}"

    while IFS= read -r project_id; do
        process_single_project "$project_id" "$temp_dir" &
        ((active_jobs++))
        if [[ $active_jobs -ge $CONCURRENCY ]]; then
            wait -n; ((active_jobs--));
        fi

        # 实时进度
        local success_count=$(cat "$success_counter_file"); local fail_count=$(cat "$fail_counter_file")
        local completed=$((success_count + fail_count)); local elapsed=$((SECONDS - start_time)); local speed=0
        if [[ $elapsed -gt 0 ]] && command -v bc &>/dev/null; then
            speed=$(echo "scale=2; $success_count * 60 / $elapsed" | bc);
        fi
        printf "\r进度: %d/%d | ${GREEN}成功: %d${NC} | ${RED}失败: %d${NC} | 耗时: %ds | 速度: %.2f Keys/min" \
            "$completed" "$total_to_create" "$success_count" "$fail_count" "$elapsed" "$speed"
    done < "$project_list_file"
    wait
    
    local duration=$((SECONDS - start_time))
    local final_success_count=$(cat "$success_counter_file")
    local final_fail_count=$(cat "$fail_counter_file")
    local final_key_file="gemini_keys_$(date +%Y%m%d_%H%M%S).txt"

    echo
    log_success "===== 创建操作完成 ====="
    log "总耗时: ${duration} 秒"
    if [[ $final_success_count -gt 0 ]]; then
        mv "$key_file" "$final_key_file"
        log_success "成功获取 ${final_success_count} 个密钥，已保存到 ./${final_key_file}"
    fi
    if [[ $final_fail_count -gt 0 ]]; then
        local final_fail_log="failed_projects_$(date +%Y%m%d_%H%M%S).log"
        mv "$failed_log" "$final_fail_log"
        log_error "有 ${final_fail_count} 个项目处理失败，详情请查看: ./${final_fail_log}"
    fi
    log "所有创建的项目列表已保存在 ${STATE_FILE} 中，可用于下次删除操作。"
    read -p "按回车键返回主菜单..."
}

execute_delete() {
    local file_to_delete=$1
    if [[ ! -f "$file_to_delete" ]]; then
        log_error "项目列表文件不存在: $file_to_delete"; sleep 2; return;
    fi
    
    local project_count=$(wc -l < "$file_to_delete")
    
    echo -e "${YELLOW}警告: 即将从文件 '${file_to_delete}' 中删除 ${project_count} 个项目。${NC}"
    echo -e "${RED}此操作不可逆！将永久删除项目及其所有资源！${NC}"
    read -p "请输入 'DELETE' 以确认: " confirm
    if [[ "$confirm" != "DELETE" ]]; then
        log "操作已取消。"; sleep 2; return;
    fi

    log "===== 开始批量删除项目 ====="
    local start_time=$SECONDS; local active_jobs=0; local deleted_count=0
    local deletion_log="project_deletion_$(date +%Y%m%d_%H%M%S).log"

    while IFS= read -r project_id; do
        if [[ -z "$project_id" ]]; then continue; fi
        (
            if gcloud projects delete "$project_id" --quiet >/dev/null 2>&1; then
                echo "[SUCCESS] $project_id"; else echo "[FAIL] $project_id";
            fi
        ) >> "$deletion_log" &
        
        ((active_jobs++))
        if [[ $active_jobs -ge $CONCURRENCY ]]; then
            wait -n; ((active_jobs--)); ((deleted_count++));
            printf "\r已处理: %d/%d" "$deleted_count" "$project_count"
        fi
    done < "$file_to_delete"
    wait
    
    echo
    log_success "===== 删除操作完成 ====="
    log "详情请查看日志文件: ./${deletion_log}"

    # 询问是否删除状态文件
    if [[ "$file_to_delete" == "$STATE_FILE" ]]; then
        read -p "是否删除已处理的项目列表文件 ${STATE_FILE}? [y/N]: " del_state
        if [[ "$del_state" =~ ^[yY](es)?$ ]]; then
            rm -f "$STATE_FILE"
            log "状态文件 ${STATE_FILE} 已删除。"
        fi
    fi
    read -p "按回车键返回主菜单..."
}

main_delete_menu() {
    while true; do
        clear
        echo -e "${CYAN}--- 批量删除项目 ---${NC}"
        echo
        echo "请选择删除模式:"
        
        local state_file_exists=false
        if [[ -f "$STATE_FILE" ]]; then
            local count=$(wc -l < "$STATE_FILE")
            echo -e "  [1] 删除上次创建的 ${GREEN}${count}${NC} 个项目 (来自文件: ${STATE_FILE})"
            state_file_exists=true
        else
            echo -e "  [1] ${YELLOW}(未找到上次运行的记录文件 '${STATE_FILE}')${NC}"
        fi
        
        echo "  [2] 从其他指定文件中删除项目"
        echo "  [3] 返回主菜单"
        echo
        read -p "请输入选项 [1-3]: " choice

        case $choice in
            1)
                if $state_file_exists; then
                    execute_delete "$STATE_FILE"
                else
                    log_error "未找到状态文件，无法执行此操作。"; sleep 2;
                fi
                ;;
            2)
                local custom_file
                read -p "请输入包含项目ID列表的文件路径: " custom_file
                execute_delete "$custom_file"
                ;;
            3)
                return
                ;;
            *)
                log_error "无效选项，请重新输入。"; sleep 1;
                ;;
        esac
    done
}

show_main_menu() {
    clear
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║          全自动 Gemini API 密钥管家 v4.0              ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "请选择要执行的操作:"
    echo "  [1] 批量创建 Gemini API 密钥"
    echo "  [2] 批量删除项目"
    echo "  [3] 退出"
    echo
    read -p "请输入选项 [1-3]: " main_choice
    
    case $main_choice in
        1) main_create ;;
        2) main_delete_menu ;;
        3) echo "感谢使用，再见！"; exit 0 ;;
        *) log_error "无效选项，请重新输入。"; sleep 1 ;;
    esac
}

# ===== 主程序入口 =====
main() {
    check_environment
    while true; do
        show_main_menu
    done
}

main

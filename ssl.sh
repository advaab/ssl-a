RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
PLAIN='\033[0m'
BOLD='\033[1m'
RECORD_FILE="$HOME/.custom_cert_records.log"
ACME_SH="$HOME/.acme.sh/acme.sh"

if [ "$1" == "cron-pre" ]; then
    occ_pid=""
    comm_name=""
    if command -v ss >/dev/null 2>&1; then
        ss_line=$(ss -tlnp | grep -E ':80\s' | head -n 1)
        if [ -n "$ss_line" ]; then
            occ_pid=$(echo "$ss_line" | grep -o 'pid=[0-9]*' | cut -d= -f2 | head -n 1)
            comm_name=$(echo "$ss_line" | awk -F'"' '{print $2}' | head -n 1)
        fi
    fi
    if [ -z "$occ_pid" ] && command -v lsof >/dev/null 2>&1; then
        if lsof -i:80 -sTCP:LISTEN >/dev/null 2>&1; then
            occ_pid=$(lsof -i:80 -sTCP:LISTEN -t | head -n 1)
        fi
    fi
    if [ -n "$occ_pid" ] || [ -n "$comm_name" ]; then
        if [ -z "$comm_name" ] && [ -n "$occ_pid" ]; then
            comm_name=$(ps -p $occ_pid -o comm= 2>/dev/null | xargs)
        fi
        restore_svc=""
        if [[ "$comm_name" == "nginx" || "$comm_name" == "httpd" || "$comm_name" == "apache2" || "$comm_name" == "caddy" ]]; then
            restore_svc="$comm_name"
        elif [ -n "$comm_name" ] && systemctl is-active --quiet "$comm_name" 2>/dev/null; then
            restore_svc="$comm_name"
        fi

        if [ -n "$restore_svc" ]; then
            echo "type=service" > /tmp/.acme_80_bak.env
            echo "target=$restore_svc" >> /tmp/.acme_80_bak.env
            systemctl stop "$restore_svc"
        else
            restore_cmd=$(ps -p $occ_pid -o args= 2>/dev/null)
            echo "type=cmd" > /tmp/.acme_80_bak.env
            echo "target=$restore_cmd" >> /tmp/.acme_80_bak.env
        fi
        if command -v fuser >/dev/null 2>&1; then
            fuser -k 80/tcp >/dev/null 2>&1
        else
            [ -n "$occ_pid" ] && kill -9 $occ_pid >/dev/null 2>&1
            command -v lsof >/dev/null 2>&1 && lsof -i:80 -t | xargs -r kill -9 >/dev/null 2>&1
        fi
        sleep 3
    fi
    exit 0
elif [ "$1" == "cron-post" ]; then
    if [ -f /tmp/.acme_80_bak.env ]; then
        type=$(grep "type=" /tmp/.acme_80_bak.env | cut -d= -f2)
        target=$(grep "target=" /tmp/.acme_80_bak.env | cut -d= -f2-)
        rm -f /tmp/.acme_80_bak.env
        if [ "$type" == "service" ]; then
            systemctl start "$target"
        elif [ "$type" == "cmd" ]; then
            nohup $target >/dev/null 2>&1 &
        fi
    fi
    exit 0
fi

msg_info() { echo -e "${CYAN}[信息]${PLAIN} $1"; }
msg_ok() { echo -e "${GREEN}[成功]${PLAIN} $1"; }
msg_err() { echo -e "${RED}[错误]${PLAIN} $1"; }
msg_warn() { echo -e "${YELLOW}[警告]${PLAIN} $1"; }
msg_title() { echo -e "${MAGENTA}${BOLD}◆ $1 ◆${PLAIN}"; }
separator() {
    local width
    width=$(tput cols 2>/dev/null || echo 80)

    line=""
    for ((i=0;i<width;i++)); do
        line+="─"
    done

    echo -e "${BLUE}${line}${PLAIN}"
}
check_root() {
    if [[ $EUID -ne 0 ]]; then
        msg_err "此脚本需要 root 权限运行，请使用 sudo su 或 root 账户登录。"
        exit 1
    fi
}

install_deps() {
    msg_info "检查并安装基础依赖环境 (curl, wget, socat, cron, psmisc, lsof)..."
    if [ -x "$(command -v apt-get)" ]; then
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl wget socat cron psmisc lsof >/dev/null 2>&1
    elif [ -x "$(command -v yum)" ]; then
        yum install -y epel-release >/dev/null 2>&1
        yum install -y curl wget socat cronie psmisc lsof >/dev/null 2>&1
        systemctl start crond >/dev/null 2>&1
        systemctl enable crond >/dev/null 2>&1
    else
        msg_warn "未识别的包管理器，尝试跳过依赖安装，如后续报错请手动安装 curl, wget, socat, psmisc, lsof."
    fi

    if [ ! -f "$ACME_SH" ]; then
        msg_info "正在安装 acme.sh 核心组件..."
        curl -s https://get.acme.sh | sh
        if [ ! -f "$ACME_SH" ]; then
            msg_err "acme.sh 安装失败，请检查网络连通性。"
            exit 1
        fi
        $ACME_SH --upgrade --auto-upgrade
        msg_ok "acme.sh 安装成功！"
    fi

    if [ ! -f "/usr/local/bin/ssl" ]; then
        msg_info "正在创建快捷命令 ssl（首次安装脚本后，任意目录输入 ssl 即可进入脚本）..."
        ln -sf "$(realpath "$0")" /usr/local/bin/ssl
        chmod +x /usr/local/bin/ssl
        msg_ok "快捷命令 ssl 创建成功！以后任意目录输入 ssl 即可运行。"
    fi
}

install_cert_files() {
    local domain=$1
    clear
    msg_title "证书申请成功，进入自定义安装环节"
    separator

    local cert_dir
    while true; do
        read -p "请输入证书存放的绝对路径 (例如 /etc/nginx/ssl，留空默认保存至 /root/certs): " cert_dir
        cert_dir=${cert_dir:-"/root/certs"}
        if [[ "$cert_dir" != /* ]]; then
            msg_warn "路径必须以 '/' 开头！请重新输入。"
        else
            break
        fi
    done

    if [ ! -d "$cert_dir" ]; then
        msg_info "检测到目录 $cert_dir 不存在，正在自动创建..."
        mkdir -p "$cert_dir"
        msg_ok "目录已创建。"
    fi

    local cert_name key_name
    while true; do
        read -p "请输入证书公钥的名称 (无需填写 .crt，直接回车默认用域名命名): " cert_name
        cert_name=${cert_name:-$domain}
        if [[ -z "${cert_name// /}" ]]; then
            msg_warn "名称不能为空，请重新输入。"
        else
            break
        fi
    done

    while true; do
        read -p "请输入证书私钥的名称 (无需填写 .key，直接回车默认用域名命名): " key_name
        key_name=${key_name:-$domain}
        if [[ -z "${key_name// /}" ]]; then
            msg_warn "名称不能为空，请重新输入。"
        else
            break
        fi
    done

    echo ""
    msg_info "若已安装 Nginx 等 Web 服务，证书自动续期后通常需要重启服务才能生效。您可在此配置“重启命令”，脚本会在每次续期成功后自动执行重启；例如：systemctl restart nginx"
    read -p "请输入证书续期后的“服务重载或重启”命令（留空则不配置）： " reload_cmd

    msg_info "正在将证书提取到指定目录..."
    local full_cert_path="${cert_dir}/${cert_name}.crt"
    local full_key_path="${cert_dir}/${key_name}.key"

    if [ -n "$reload_cmd" ]; then
        $ACME_SH --install-cert -d "$domain" --ecc \
            --fullchain-file "$full_cert_path" \
            --key-file "$full_key_path" \
            --reloadcmd "$reload_cmd"
    else
        $ACME_SH --install-cert -d "$domain" --ecc \
            --fullchain-file "$full_cert_path" \
            --key-file "$full_key_path"
    fi

    if [ -f "$full_cert_path" ]; then
        msg_ok "证书已成功部署！"
        echo -e "公钥路径: ${GREEN}$full_cert_path${PLAIN}"
        echo -e "私钥路径: ${GREEN}$full_key_path${PLAIN}"
        
        local current_date=$(date "+%Y-%m-%d %H:%M:%S")
        if [ -f "$RECORD_FILE" ]; then
            sed -i "/^${domain} |/d" "$RECORD_FILE"
        fi
        echo "$domain | $full_cert_path | $full_key_path | $current_date | $reload_cmd" >> "$RECORD_FILE"
    else
        msg_err "证书部署似乎失败了，请检查目录权限。"
    fi
    echo ""
    read -p "按回车键继续..."
}

apply_cert() {
    local domain
    while true; do
        read -p "请输入你需要申请证书的域名 (泛域名请使用 DNS API 验证模式): " domain
        if [[ -z "$domain" ]]; then
            msg_warn "域名不能为空！"
        elif [[ "$domain" == *" "* ]]; then
            msg_warn "域名不能包含空格！"
        else
            break
        fi
    done

    clear
    msg_title "选择证书申请模式"
    separator
    echo -e " ${GREEN}1${PLAIN}) HTTP-01 验证模式 
    (请确保域名已解析到本机IP，且 80 未被占用，若使用 Cloudflare 解析，请确保“小云朵”保持关闭，否则可能导致申请和自动续期失败。)"
    echo -e " ${GREEN}2${PLAIN}) DNS API 验证模式 
    (需准备Cloudflare账号和Global API key，获取API Key可登陆Cloudflare账号后点击绑定的域名 → 下滑找到右下角的 “获取您的API令牌” → “Global API Key” 点击查看。支持泛域名解析，无需关注80端口和 “小云朵” 状态。)"
    echo -e " ${GREEN}0${PLAIN}) 返回主菜单"
    separator
    read -p "请选择 [0-2]: " mode_select

    case $mode_select in
        1)
            local restore_svc=""
            local restore_cmd=""
            local occ_pid=""
            local comm_name=""
            
            if command -v ss >/dev/null 2>&1; then
                local ss_line=$(ss -tlnp | grep -E ':80\s' | head -n 1)
                if [ -n "$ss_line" ]; then
                    occ_pid=$(echo "$ss_line" | grep -o 'pid=[0-9]*' | cut -d= -f2 | head -n 1)
                    comm_name=$(echo "$ss_line" | awk -F'"' '{print $2}' | head -n 1)
                fi
            fi

            if [ -z "$occ_pid" ] && command -v lsof >/dev/null 2>&1; then
                if lsof -i:80 -sTCP:LISTEN >/dev/null 2>&1; then
                    occ_pid=$(lsof -i:80 -sTCP:LISTEN -t | head -n 1)
                fi
            fi

            if [ -n "$occ_pid" ] || [ -n "$comm_name" ]; then
                if [ -z "$comm_name" ] && [ -n "$occ_pid" ]; then
                    comm_name=$(ps -p $occ_pid -o comm= 2>/dev/null | xargs)
                fi

                if [[ "$comm_name" == "nginx" || "$comm_name" == "httpd" || "$comm_name" == "apache2" || "$comm_name" == "caddy" ]]; then
                    restore_svc="$comm_name"
                elif [ -n "$comm_name" ] && systemctl is-active --quiet "$comm_name" 2>/dev/null; then
                    restore_svc="$comm_name"
                fi

                if [ -n "$restore_svc" ]; then
                    msg_info "检测到 80 端口被 $restore_svc 服务占用，正在自动停止..."
                    systemctl stop "$restore_svc"
                else
                    restore_cmd=$(ps -p $occ_pid -o args= 2>/dev/null)
                    msg_info "检测到 80 端口被独立进程占用，正在强制清理进程..."
                fi
                
                if command -v fuser >/dev/null 2>&1; then
                    fuser -k 80/tcp >/dev/null 2>&1
                else
                    [ -n "$occ_pid" ] && kill -9 $occ_pid >/dev/null 2>&1
                    command -v lsof >/dev/null 2>&1 && lsof -i:80 -t | xargs -r kill -9 >/dev/null 2>&1
                fi
                sleep 3 
            fi
            
            msg_info "正在申请证书，请稍候..."
            $ACME_SH --issue -d "$domain" --standalone -k ec-256 --server letsencrypt --pre-hook "/usr/local/bin/zs cron-pre" --post-hook "/usr/local/bin/zs cron-post"
            local issue_status=$?
            
            if [ $issue_status -ne 0 ]; then
                msg_warn "申请未成功，正在自动添加 --force 参数强制重新申请..."
                $ACME_SH --issue -d "$domain" --standalone -k ec-256 --server letsencrypt --pre-hook "/usr/local/bin/zs cron-pre" --post-hook "/usr/local/bin/zs cron-post" --force
                issue_status=$?
            fi
            
            if [ -n "$restore_svc" ]; then
                msg_info "操作结束，正在恢复启动服务: $restore_svc ..."
                systemctl start "$restore_svc"
            elif [ -n "$restore_cmd" ]; then
                msg_info "操作结束，正在恢复启动进程 ..."
                nohup $restore_cmd >/dev/null 2>&1 &
            fi

            if [ $issue_status -eq 0 ]; then
                install_cert_files "$domain"
            else
                echo ""
                msg_warn "提示：如果上方日志显示 Add '\033[31m--force\033[0m' ······ 等内容或已经显示了证书有效期，说明本地已存在该域名的有效的证书，acme.sh 自动跳过了申请；可返回主菜单选择 2)查看证书 或 选择 3)强制申请证书。"
                separator
                msg_err "证书申请失败！若出现验证超时、Connection refused 等错误，请检查：1. 域名解析是否正确指向本机 IP；2. 80 端口是否被占用；3. 若使用 Cloudflare 解析，请确保“小云朵”处于关闭状态。如需保持开启，请改用 DNS API 模式申请。"          
            fi
            ;;
        2)
            local cf_email cf_key
            while true; do
                read -p "请输入 Cloudflare 注册邮箱: " cf_email
                if [[ -z "$cf_email" ]]; then msg_warn "邮箱不能为空！"; else break; fi
            done
            while true; do
                read -p "请输入 Cloudflare Global API Key: " cf_key
                if [[ -z "$cf_key" ]]; then msg_warn "API Key 不能为空！"; else break; fi
            done
            
            export CF_Email="$cf_email"
            export CF_Key="$cf_key"
            
            msg_info "正在通过 DNS API 验证并申请证书，请耐心等待..."
            $ACME_SH --issue --dns dns_cf -d "$domain" -k ec-256 --server letsencrypt
            local dns_status=$?
            
            if [ $dns_status -ne 0 ]; then
                msg_warn "申请未成功，正在自动添加 --force 参数强制重新申请..."
                $ACME_SH --issue --dns dns_cf -d "$domain" -k ec-256 --server letsencrypt --force
                dns_status=$?
            fi
            
            if [ $dns_status -eq 0 ]; then
                install_cert_files "$domain"
            else
                msg_err "申请失败，请检查 CF 账号信息或网络。"
            fi
            ;;
        0) return ;;
        *) msg_warn "无效选项。" ;;
    esac
    echo ""
    read -p "按回车键返回主菜单..."
}

view_certs() {
    clear
    msg_title "已申请证书记录"
    separator
 
    echo -e "${WHITE}域名部署记录：${PLAIN}"
    echo ""
 
    if [ -f "$RECORD_FILE" ] && [ -s "$RECORD_FILE" ]; then
        local is_first=1
        while IFS='|' read -r c_domain c_cert c_key c_date c_reload; do
            if [ $is_first -eq 0 ]; then
                echo -e "${MAGENTA}${BOLD}============================================================${PLAIN}"
            fi
            is_first=0

            c_domain=$(echo "$c_domain" | xargs)
            c_cert=$(echo "$c_cert" | xargs)
            c_key=$(echo "$c_key" | xargs)
            c_date=$(echo "$c_date" | xargs)
            c_reload=$(echo "$c_reload" | xargs)
            
            local start_date="未知"
            local end_date="未知"
            local remain_days="未知"
            local auto_renew="未知"
            local next_renew="未知"

            if [ -f "$c_cert" ]; then
                local s_date=$(openssl x509 -in "$c_cert" -noout -startdate 2>/dev/null | cut -d= -f2)
                local e_date=$(openssl x509 -in "$c_cert" -noout -enddate 2>/dev/null | cut -d= -f2)
                if [ -n "$s_date" ] && [ -n "$e_date" ]; then
                    start_date=$(date -d "$s_date" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$s_date")
                    end_date=$(date -d "$e_date" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$e_date")
                    local end_ts=$(date -d "$e_date" +%s 2>/dev/null)
                    local now_ts=$(date +%s)
                    if [ -n "$end_ts" ]; then
                        remain_days=$(( (end_ts - now_ts) / 86400 ))
                        if [ $remain_days -lt 0 ]; then
                            remain_days="${RED}已过期${PLAIN}"
                        else
                            remain_days="${YELLOW}${remain_days} 天${PLAIN}"
                        fi
                    fi
                fi
            fi

            if [ "$end_date" = "未知" ]; then
                local expire_info=$($ACME_SH --info -d "$c_domain" 2>/dev/null)
                local e_date_str=$(echo "$expire_info" | grep -oE '(Expires on|Not After):[^)]+' | sed 's/.*: //' | xargs)
                if [ -n "$e_date_str" ]; then
                    end_date=$(date -d "$e_date_str" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$e_date_str")
                    local end_ts=$(date -d "$e_date_str" +%s 2>/dev/null)
                    local now_ts=$(date +%s)
                    if [ -n "$end_ts" ]; then
                        remain_days=$(( (end_ts - now_ts) / 86400 ))
                        if [ $remain_days -lt 0 ]; then
                            remain_days="${RED}已过期${PLAIN}"
                        else
                            remain_days="${YELLOW}${remain_days} 天${PLAIN}"
                        fi
                    fi
                fi
            fi

            local list_output=$($ACME_SH --list 2>/dev/null)
            if echo "$list_output" | grep -q -w "$c_domain"; then
                local renew_str=$(echo "$list_output" | grep -w "$c_domain" | awk '{print $6}' | xargs)
                if [ -n "$renew_str" ] && [ "$renew_str" != "Renew" ] && [ "$renew_str" != "" ]; then
                    next_renew=$(date -d "$renew_str" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$renew_str")
                fi
            fi

            if crontab -l 2>/dev/null | grep -q "acme.sh"; then
                auto_renew="${GREEN}是 (已开启计划任务)${PLAIN}"
                local conf_file="$HOME/.acme.sh/${c_domain}_ecc/${c_domain}.conf"
                if [ -f "$conf_file" ] && grep -q "Le_DisableRenew='1'" "$conf_file"; then
                    auto_renew="${RED}否 (已在此域名禁用)${PLAIN}"
                    next_renew="无 (未开启自动续期)"
                fi
            else
                auto_renew="${RED}否 (未检测到计划任务)${PLAIN}"
            fi
            
            echo -e "域名: ${GREEN}$c_domain${PLAIN}"
            echo -e "当前有效期: ${start_date} 至 ${end_date}"
            echo -e "剩余天数: $remain_days"
            echo -e "是否已开启自动续期: $auto_renew"
            echo -e "下一次续期时间: ${CYAN}$next_renew${PLAIN}"
            
            echo -e "CA机构: Let’s Encrypt"
            echo -e "公钥绝对路径: ${GREEN}$c_cert${PLAIN}"
            echo -e "私钥绝对路径: ${GREEN}$c_key${PLAIN}"
            echo -e "部署时间: $c_date"
            if [ -n "$c_reload" ] && [ "$c_reload" != "" ]; then
                echo -e "重启命令: $c_reload"
            fi
            echo ""
        done < "$RECORD_FILE"
    else
        echo "暂无部署记录。"
    fi
    separator
    read -p "按回车键返回主菜单..."
}

force_renew() {
    clear
    msg_title "强制续期证书"
    separator
 
    echo -e "${WHITE}当前部署记录：${PLAIN}"
    echo ""
 
    if [ -f "$RECORD_FILE" ] && [ -s "$RECORD_FILE" ]; then
        local is_first=1
        while IFS='|' read -r c_domain c_cert c_key c_date c_reload; do
            if [ $is_first -eq 0 ]; then
                echo -e "${MAGENTA}${BOLD}============================================================${PLAIN}"
            fi
            is_first=0

            c_domain=$(echo "$c_domain" | xargs)
            c_cert=$(echo "$c_cert" | xargs)
            c_date=$(echo "$c_date" | xargs)
            
            local start_date="未知"
            local end_date="未知"
            local remain_days="未知"
            local auto_renew="未知"
            local next_renew="未知"

            if [ -f "$c_cert" ]; then
                local s_date=$(openssl x509 -in "$c_cert" -noout -startdate 2>/dev/null | cut -d= -f2)
                local e_date=$(openssl x509 -in "$c_cert" -noout -enddate 2>/dev/null | cut -d= -f2)
                if [ -n "$s_date" ] && [ -n "$e_date" ]; then
                    start_date=$(date -d "$s_date" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$s_date")
                    end_date=$(date -d "$e_date" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$e_date")
                    local end_ts=$(date -d "$e_date" +%s 2>/dev/null)
                    local now_ts=$(date +%s)
                    if [ -n "$end_ts" ]; then
                        remain_days=$(( (end_ts - now_ts) / 86400 ))
                        if [ $remain_days -lt 0 ]; then
                            remain_days="${RED}已过期${PLAIN}"
                        else
                            remain_days="${YELLOW}${remain_days} 天${PLAIN}"
                        fi
                    fi
                fi
            fi

            if [ "$end_date" = "未知" ]; then
                local expire_info=$($ACME_SH --info -d "$c_domain" 2>/dev/null)
                local e_date_str=$(echo "$expire_info" | grep -oE '(Expires on|Not After):[^)]+' | sed 's/.*: //' | xargs)
                if [ -n "$e_date_str" ]; then
                    end_date=$(date -d "$e_date_str" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$e_date_str")
                    local end_ts=$(date -d "$e_date_str" +%s 2>/dev/null)
                    local now_ts=$(date +%s)
                    if [ -n "$end_ts" ]; then
                        remain_days=$(( (end_ts - now_ts) / 86400 ))
                        if [ $remain_days -lt 0 ]; then
                            remain_days="${RED}已过期${PLAIN}"
                        else
                            remain_days="${YELLOW}${remain_days} 天${PLAIN}"
                        fi
                    fi
                fi
            fi

            local list_output=$($ACME_SH --list 2>/dev/null)
            if echo "$list_output" | grep -q -w "$c_domain"; then
                local renew_str=$(echo "$list_output" | grep -w "$c_domain" | awk '{print $6}' | xargs)
                if [ -n "$renew_str" ] && [ "$renew_str" != "Renew" ] && [ "$renew_str" != "" ]; then
                    next_renew=$(date -d "$renew_str" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$renew_str")
                fi
            fi

            if crontab -l 2>/dev/null | grep -q "acme.sh"; then
                auto_renew="${GREEN}是 (已开启计划任务)${PLAIN}"
                local conf_file="$HOME/.acme.sh/${c_domain}_ecc/${c_domain}.conf"
                if [ -f "$conf_file" ] && grep -q "Le_DisableRenew='1'" "$conf_file"; then
                    auto_renew="${RED}否 (已在此域名禁用)${PLAIN}"
                    next_renew="无 (未开启自动续期)"
                fi
            else
                auto_renew="${RED}否 (未检测到计划任务)${PLAIN}"
            fi

            echo -e "域名: ${GREEN}$c_domain${PLAIN}"
            echo -e "当前有效期: ${start_date} 至 ${end_date}"
            echo -e "剩余天数: $remain_days"
            echo -e "是否已开启自动续期: $auto_renew"
            echo -e "下一次续期时间: ${CYAN}$next_renew${PLAIN}"
            
            echo -e "部署时间: $c_date"
            echo ""
        done < "$RECORD_FILE"
    else
        echo "暂无部署记录。"
    fi
    separator
 
    read -p "请输入需要强制续期的域名 (参考上面列表，留空取消): " r_domain
    if [ -z "$r_domain" ]; then return; fi
    
    local restore_svc=""
    local restore_cmd=""
    local occ_pid=""
    local comm_name=""

    if command -v ss >/dev/null 2>&1; then
        local ss_line=$(ss -tlnp | grep -E ':80\s' | head -n 1)
        if [ -n "$ss_line" ]; then
            occ_pid=$(echo "$ss_line" | grep -o 'pid=[0-9]*' | cut -d= -f2 | head -n 1)
            comm_name=$(echo "$ss_line" | awk -F'"' '{print $2}' | head -n 1)
        fi
    fi

    if [ -z "$occ_pid" ] && command -v lsof >/dev/null 2>&1; then
        if lsof -i:80 -sTCP:LISTEN >/dev/null 2>&1; then
            occ_pid=$(lsof -i:80 -sTCP:LISTEN -t | head -n 1)
        fi
    fi

    if [ -n "$occ_pid" ] || [ -n "$comm_name" ]; then
        if [ -z "$comm_name" ] && [ -n "$occ_pid" ]; then
            comm_name=$(ps -p $occ_pid -o comm= 2>/dev/null | xargs)
        fi

        if [[ "$comm_name" == "nginx" || "$comm_name" == "httpd" || "$comm_name" == "apache2" || "$comm_name" == "caddy" ]]; then
            restore_svc="$comm_name"
        elif [ -n "$comm_name" ] && systemctl is-active --quiet "$comm_name" 2>/dev/null; then
            restore_svc="$comm_name"
        fi

        if [ -n "$restore_svc" ]; then
            msg_info "检测到 80 端口被 $restore_svc 服务占用，正在自动停止以供续期..."
            systemctl stop "$restore_svc"
        else
            restore_cmd=$(ps -p $occ_pid -o args= 2>/dev/null)
            msg_info "检测到 80 端口被独立进程占用，自动清理占用进程以供续期..."
        fi
        
        if command -v fuser >/dev/null 2>&1; then
            fuser -k 80/tcp >/dev/null 2>&1
        else
            [ -n "$occ_pid" ] && kill -9 $occ_pid >/dev/null 2>&1
            command -v lsof >/dev/null 2>&1 && lsof -i:80 -t | xargs -r kill -9 >/dev/null 2>&1
        fi
        sleep 3
    fi

    msg_info "开始强制续期 $r_domain ..."
    $ACME_SH --renew -d "$r_domain" --force --ecc
    local renew_status=$?

    if [ -n "$restore_svc" ]; then
        msg_info "操作结束，正在恢复启动服务: $restore_svc ..."
        systemctl start "$restore_svc"
    elif [ -n "$restore_cmd" ]; then
        msg_info "操作结束，正在恢复启动进程 ..."
        nohup $restore_cmd >/dev/null 2>&1 &
    fi

    if [ $renew_status -eq 0 ]; then
        msg_ok "续期成功！"
        
        if [ -f "$RECORD_FILE" ]; then
            local record_line=$(grep "^${r_domain} |" "$RECORD_FILE")
            if [ -n "$record_line" ]; then
                msg_info "检测到自定义部署记录，正在重新应用证书路径和重启命令..."
                local full_cert_path=$(echo "$record_line" | cut -d'|' -f2 | xargs)
                local full_key_path=$(echo "$record_line" | cut -d'|' -f3 | xargs)
                local reload_cmd=$(echo "$record_line" | cut -d'|' -f5 | xargs)
                
                if [ -n "$reload_cmd" ]; then
                    $ACME_SH --install-cert -d "$r_domain" --ecc \
                        --fullchain-file "$full_cert_path" \
                        --key-file "$full_key_path" \
                        --reloadcmd "$reload_cmd"
                else
                    $ACME_SH --install-cert -d "$r_domain" --ecc \
                        --fullchain-file "$full_cert_path" \
                        --key-file "$full_key_path"
                fi
                msg_ok "证书已重新部署完成。"
            fi
        fi
    else
        msg_err "续期失败，请查看日志。"
    fi
    echo ""
    read -p "按回车键返回主菜单..."
}

revoke_cert() {
    clear
    msg_title "移除域名证书"
    separator
 
    echo -e "${WHITE}当前部署记录：${PLAIN}"
    echo ""
 
    if [ -f "$RECORD_FILE" ] && [ -s "$RECORD_FILE" ]; then
        local is_first=1
        while IFS='|' read -r c_domain c_cert c_key c_date c_reload; do
            if [ $is_first -eq 0 ]; then
                echo -e "${MAGENTA}${BOLD}============================================================${PLAIN}"
            fi
            is_first=0

            c_domain=$(echo "$c_domain" | xargs)
            c_cert=$(echo "$c_cert" | xargs)
            c_date=$(echo "$c_date" | xargs)
            
            local start_date="未知"
            local end_date="未知"
            local remain_days="未知"
            local auto_renew="未知"
            local next_renew="未知"

            if [ -f "$c_cert" ]; then
                local s_date=$(openssl x509 -in "$c_cert" -noout -startdate 2>/dev/null | cut -d= -f2)
                local e_date=$(openssl x509 -in "$c_cert" -noout -enddate 2>/dev/null | cut -d= -f2)
                if [ -n "$s_date" ] && [ -n "$e_date" ]; then
                    start_date=$(date -d "$s_date" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$s_date")
                    end_date=$(date -d "$e_date" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$e_date")
                    local end_ts=$(date -d "$e_date" +%s 2>/dev/null)
                    local now_ts=$(date +%s)
                    if [ -n "$end_ts" ]; then
                        remain_days=$(( (end_ts - now_ts) / 86400 ))
                        if [ $remain_days -lt 0 ]; then
                            remain_days="${RED}已过期${PLAIN}"
                        else
                            remain_days="${YELLOW}${remain_days} 天${PLAIN}"
                        fi
                    fi
                fi
            fi

            if [ "$end_date" = "未知" ]; then
                local expire_info=$($ACME_SH --info -d "$c_domain" 2>/dev/null)
                local e_date_str=$(echo "$expire_info" | grep -oE '(Expires on|Not After):[^)]+' | sed 's/.*: //' | xargs)
                if [ -n "$e_date_str" ]; then
                    end_date=$(date -d "$e_date_str" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$e_date_str")
                    local end_ts=$(date -d "$e_date_str" +%s 2>/dev/null)
                    local now_ts=$(date +%s)
                    if [ -n "$end_ts" ]; then
                        remain_days=$(( (end_ts - now_ts) / 86400 ))
                        if [ $remain_days -lt 0 ]; then
                            remain_days="${RED}已过期${PLAIN}"
                        else
                            remain_days="${YELLOW}${remain_days} 天${PLAIN}"
                        fi
                    fi
                fi
            fi

            local list_output=$($ACME_SH --list 2>/dev/null)
            if echo "$list_output" | grep -q -w "$c_domain"; then
                local renew_str=$(echo "$list_output" | grep -w "$c_domain" | awk '{print $6}' | xargs)
                if [ -n "$renew_str" ] && [ "$renew_str" != "Renew" ] && [ "$renew_str" != "" ]; then
                    next_renew=$(date -d "$renew_str" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$renew_str")
                fi
            fi

            if crontab -l 2>/dev/null | grep -q "acme.sh"; then
                auto_renew="${GREEN}是 (已开启计划任务)${PLAIN}"
                local conf_file="$HOME/.acme.sh/${c_domain}_ecc/${c_domain}.conf"
                if [ -f "$conf_file" ] && grep -q "Le_DisableRenew='1'" "$conf_file"; then
                    auto_renew="${RED}否 (已在此域名禁用)${PLAIN}"
                    next_renew="无 (未开启自动续期)"
                fi
            else
                auto_renew="${RED}否 (未检测到计划任务)${PLAIN}"
            fi

            echo -e "域名: ${GREEN}$c_domain${PLAIN}"
            echo -e "当前有效期: ${start_date} 至 ${end_date}"
            echo -e "剩余天数: $remain_days"
            echo -e "是否已开启自动续期: $auto_renew"
            echo -e "下一次续期时间: ${CYAN}$next_renew${PLAIN}"
            
            echo -e "部署时间: $c_date"
            echo ""
        done < "$RECORD_FILE"
    else
        echo "暂无部署记录。"
    fi
    separator
    read -p "请输入需要移除证书的域名 (留空取消): " rev_domain
    if [ -z "$rev_domain" ]; then return; fi

    # [新增修改逻辑] 在清理记录前，先获取自定义保存路径并把公钥、私钥文件从本地删除
    if [ -f "$RECORD_FILE" ]; then
        local record_line=$(grep "^${rev_domain} |" "$RECORD_FILE")
        if [ -n "$record_line" ]; then
            local del_cert=$(echo "$record_line" | cut -d'|' -f2 | xargs)
            local del_key=$(echo "$record_line" | cut -d'|' -f3 | xargs)
            
            if [ -f "$del_cert" ]; then
                rm -f "$del_cert"
                msg_info "已删除本地公钥文件: $del_cert"
            fi
            if [ -f "$del_key" ]; then
                rm -f "$del_key"
                msg_info "已删除本地私钥文件: $del_key"
            fi
        fi
    fi

    msg_info "正在移除证书 $rev_domain ..."
    $ACME_SH --revoke -d "$rev_domain" --ecc
    msg_info "正在从 acme 列表中移除..."
    $ACME_SH --remove -d "$rev_domain" --ecc
    if [ -f "$RECORD_FILE" ]; then
        sed -i "/^${rev_domain} |/d" "$RECORD_FILE"
    fi
    msg_ok "证书已成功移除，本地自定义路径下的证书与私钥文件已同步清理。"
    echo ""
    read -p "按回车键返回主菜单..."
}

uninstall_all() {
    clear
    msg_title "卸载警告"
    echo -e "${RED}警告：这将会完全卸载 acme.sh 并清除计划任务！${PLAIN}"
    echo -e "${RED}证书将无法自动续期！${PLAIN}"
    separator
    read -p "确认要卸载吗？(y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        $ACME_SH --uninstall
        rm -rf ~/.acme.sh
        rm -f "$RECORD_FILE"
        msg_ok "acme.sh 已完全卸载，本地记录已清理。"
        exit 0
    fi
}

show_menu() {
    clear
    separator
    echo -e "${MAGENTA}${BOLD} SSL 证书一键申请管理工具 (基于 Acme.sh )${PLAIN}"
    separator
    echo -e "${CYAN}【说明】：本脚本是基于 acme.sh 封装的 SSL 证书管理工具，支持HTTP-01和Cloudflare Dns验证方式申请证书。${PLAIN}"
    echo -e "${CYAN}【支持】：证书一键申请与自动部署✔ 证书自定义存储路径与文件名称✔ 支持自动续期与 Web 服务自动重载✔ 支持证书一件删除✔ ${PLAIN}"
    separator
    echo -e "${CYAN}【快捷方式】：ssl（首次安装运行后可在任意目录直接输入ssl调出菜单）；更新脚本请再次运行安装命令；${PLAIN}"
    separator
    echo ""
    echo -e " ${GREEN}1${PLAIN}) 申请全新证书 (支持自定义证书安装路径和证书名称)"
    echo -e " ${GREEN}2${PLAIN}) 查看域名证书"
    echo -e " ${GREEN}3${PLAIN}) 强制续期证书"
    echo -e " ${GREEN}4${PLAIN}) 删除证书"
    echo -e " ${GREEN}5${PLAIN}) 卸载 acme.sh 环境"
    echo -e " ${GREEN}0${PLAIN}) 退出脚本"
    separator
    if crontab -l 2>/dev/null | grep -q "acme.sh"; then
        echo -e "自动续期状态: ${GREEN}正常运行${PLAIN}"
    else
        echo -e "自动续期状态: ${YELLOW}未检测到计划任务${PLAIN}"
    fi
    echo ""
}

check_root
install_deps
while true; do
    show_menu
    read -p "请输入对应数字 [0-5]: " choice
    case $choice in
        1) apply_cert ;;
        2) view_certs ;;
        3) force_renew ;;
        4) revoke_cert ;;
        5) uninstall_all ;;
        0) echo -e "${GREEN}感谢使用，再见！${PLAIN}" && exit 0 ;;
        *) msg_warn "输入错误，请重新选择" && sleep 1 ;;
    esac
done

# ssl-a
SSL 证书一键申请管理工具；这是一个基于 acme.sh 为核心的 Linux脚本。专为简化证书申请、自动部署、智能续期而设计。支持自定义证书路径、证书命名以及全自动的端口占用清理。可查询证书的有效期、剩余天数、是否开启自动续期、下一次计划续期时间以及证书文件的路径。



##  核心特性

*   **双重验证模式**：
    *   **HTTP-01 独立模式**：适合已有单域名解析。在申请和自动续期时能自动检测、停止、并在完成后恢复占用 80 端口的服务（如 Nginx, Apache, Caddy 等独立的进程）。
    *   **DNS API 模式 (Cloudflare)**：支持申请**泛域名证书（Wildcard）**。通过 Cloudflare API 验证申请证书。

*   **高度自定义安装**：证书申请成功后，支持自定义导出的绝对路径、自定义公钥/私钥的文件名称，拒绝死板的默认生成。
   
*   **无感自动续期**：全自动配置系统 `cron` 计划任务，并在每次续期成功后，自动触发配置的 Web 服务重载/重启命令（如 `systemctl restart nginx`）。
   
*   **一站式证书运维**：
    *   **可视化看板**：清晰展示证书有效期、剩余天数、是否开启自动续期、下一次计划续期时间以及证书文件的路径。
    *   **安全同步卸载/删除**：删除证书时不仅从 acme.sh 列表中注销，还会**同步删除**你自定义目录下的证书文件，不留残余垃圾。
    *   
*   **快捷全局指令**：首次运行后，系统会自动注册 `ssl` 全局命令，后续在任何目录下直接输入 `ssl` 即可秒开面板。

---

##  支持的系统环境

脚本会自动检测并安装底层依赖（如 `curl`, `wget`, `socat`, `psmisc`, `lsof` 等），目前支持以下主流 Linux 发行版：

| 操作系统分类 | 具体支持版本 | 包管理器 |
| :--- | :--- | :--- |
| **Debian 系** | Ubuntu 18.04+ / Debian 10+ 等 | `apt-get` |
| **RedHat 系** | CentOS 7+ / Rocky Linux / AlmaLinux 等 | `yum` (自动配置 EPEL 源并启动 `crond`) |

>  **注意**：脚本必须以 `root` 用户权限运行。

---

##  VPS 一键安装与运行命令

请根据你的操作系统，在 SSH 终端中复制并执行对应命令：

### 1. Ubuntu / Debian 系统
```bash
wget -N --no-check-certificate https://raw.githubusercontent.com/advaab/ssl-a/main/ssl.sh && chmod +x ssl.sh && ./ssl.sh

```

### 2. CentOS / Rocky Linux / AlmaLinux 系统

```bash
yum install -y wget && wget -N --no-check-certificate https://raw.githubusercontent.com/advaab/ssl-a/main/ssl.sh && chmod +x ssl.sh && ./ssl.sh

```

>  **温馨提示**：首次安装并成功运行一次面板后，以后无论在哪个目录，直接输入以下命令即可唤醒面板：
> 
> 
> ```bash
> ssl
> 
> ```
> 
> 

---

##  功能菜单概览

1. **申请全新证书**：输入域名，选择 HTTP 独立验证或 CF DNS 验证，随后自定义存放路径及重启服务指令。


2. **查看域名证书**：可视化读取部署档案，结合 `openssl` 实时解析证书剩余天数、自动续期状态及绝对路径。


3. **强制续期证书**：对列表中未到期的证书执行强制刷新，并重新触发自定义部署和 Web 服务重启。


4. **删除证书**：撤销证书、注销续期任务并删除对应的 `.crt` 和 `.key` 文件。


5. **卸载 acme.sh 环境**：彻底格式化清除 `acme.sh` 核心组件及所有的自动化续期定时任务。



---

##  其他

* 本项目证书签发由 [Let's Encrypt](https://letsencrypt.org/) 提供 CA 机构信任，默认生成更安全、更高性能的 **ECC 256位（EC-256）** 证书。



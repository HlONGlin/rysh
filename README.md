# rysh · 一键部署 Xray Reality 多节点

## 一键脚本

直接使用项目提供的一键脚本完成 rysh 的安装与管理：

```sh
bash <(curl -fsSL https://github.com/HlONGlin/rysh/raw/main/one-click.sh)
```

脚本提供数字菜单：

1. 安装或更新 rysh（含 Xray 核心与依赖）
2. 启动 rysh / Xray 服务
3. 停止 rysh / Xray 服务
4. 彻底卸载并清除全部数据
5. 重置节点凭据（保留节点数据）
6. 进入 rysh 节点管理菜单
0. 退出

如果想完全清除后重新开始，在一键管理工具中选择 `4`，并输入 `DELETE` 确认。该操作会删除 rysh、Xray、全部节点配置、流量记录、限速与防火墙规则；清除后重新选择 `1` 安装即可。

脚本会从本项目 `main` 分支下载 `rysh.sh`，安装到 `/usr/local/bin/rysh`，并自动完成依赖安装、Xray 核心安装、OpenRC 服务注册和 cron 监控任务创建。安装完成后选择 `6` 进入节点管理菜单，即可创建第一个 Reality 节点。

部署完成后，在任意目录输入 **`ry`** 即可直接唤出面板（脚本会自动创建 `/usr/local/bin/ry` 快捷命令，等价于 `rysh`）：

```sh
ry
```

rysh 没有 Web 面板，也没有管理员账号。菜单 `5` 对应的是**重置全部节点的 UUID、ShortID 与 Reality 密钥**：节点记录、端口、限额、到期时间和流量统计都会保留，但旧客户端链接会立即失效，需要重新导入。只重置单个节点，可以进入菜单 `6` 后使用「修改节点」。

Alpine 最小系统默认没有 `bash`，而 `bash <(...)` 需要 bash 才能执行，请先安装：

```sh
apk add bash curl ca-certificates
```

也可以不使用 bash：

```sh
curl -fsSL https://github.com/HlONGlin/rysh/raw/main/one-click.sh -o /tmp/rysh-oneclick.sh && sh /tmp/rysh-oneclick.sh
```

如果提示没有 `curl` 或 `wget`，请先安装：

```sh
# Alpine
apk add curl wget

# Ubuntu / Debian
apt-get install -y curl wget

# Fedora
dnf install -y curl wget

# CentOS / Rocky / AlmaLinux / Oracle Linux / Amazon Linux
yum install -y curl wget
```

## 特性

- **一键部署**：自动安装依赖、Xray 核心、OpenRC 服务与监控任务。
- **多节点**：单机创建任意数量的 VLESS Reality 节点，每个节点独立端口、UUID、Reality 密钥、ShortID、SNI 和目标地址。
- **批量创建**：一次生成多个节点，自动分配空闲端口，统一设置 SNI、限额、到期和限速。
- **流量统计**：通过 Xray Stats API 按节点统计上下行流量，重启不丢量，支持本月与历史月份。
- **月流量限额**：按 GB 设置每月额度，超限自动封禁对应端口，次月自动恢复。
- **到期时间**：按剩余天数或指定日期限制节点有效期，到期自动封禁。
- **端口限速**：使用 tc `clsact` police 规则按节点端口限制上传和下载，不接管 root qdisc。
- **自动封禁**：使用 nftables 独立表阻断超限端口，失败时回退 iptables。
- **实时监控**：终端内查看每个节点的实时上下行速率。
- **链接管理**：查看 VLESS 分享链接、终端二维码，导出全部链接和 Base64 订阅。
- **轻量**：POSIX `sh` 编写，无 Docker、无外部数据库、无 Web 面板。

## 系统要求

- **Alpine Linux v3.21**（其他使用 OpenRC + apk 的 Alpine 版本通常也可以）
- root 权限
- 能访问 GitHub（用于下载 Xray）；网络受限时可在 rysh「全局设置」中配置下载代理
- 建议使用官方 Alpine 内核，确保支持 `nftables`、tc `clsact`、`flower` 和 police action

脚本会自动安装：

```text
curl unzip jq nftables iptables iproute2 ca-certificates
```

按需补装：

```text
iproute2-tc iproute2-ss qrencode
```

## 快速开始

1. 执行一键脚本，选择 `1` 完成安装。
2. 选择 `6` 进入节点管理菜单，再选择 `2` 创建节点。
3. 按提示填写名称、端口、SNI、目标地址；端口留空会自动选择空闲端口。
4. 创建完成后终端会输出 VLESS 分享链接，导入客户端即可使用。
5. 需要二维码时，在节点管理菜单选择 `5`；需要导出全部链接时选择 `6`。

创建节点的默认参数：

| 项目 | 默认值 |
|------|--------|
| 流控 | `xtls-rprx-vision` |
| 客户端指纹 | `chrome` |
| SNI | `www.amazon.com` |
| 目标地址 | `www.amazon.com:443` |
| 限速 | 不限 |
| 月限额 | 不限 |
| 到期时间 | 永久 |

Reality 的目标站点需要支持 TLS 1.3 和 HTTP/2，并且能从你的服务器正常访问。默认使用 `www.amazon.com`，其他常见可用目标包括 `www.microsoft.com`、`www.apple.com`、`www.cloudflare.com` 等。

## 节点管理菜单

```text
 1. 安装/更新 Xray 核心          2. 创建 Reality 节点
 3. 批量创建 Reality 节点        4. 查看节点列表
 5. 查看节点链接/二维码          6. 导出全部节点链接
 7. 修改节点                     8. 删除节点
 9. 启用/禁用节点               10. 重置节点流量
11. 设置月流量限额             12. 设置节点到期时间
13. 设置节点限速               14. 实时流量监控
15. 流量统计/月报              16. 应用所有规则
17. 启动/停止/重启 Xray        18. 查看 Xray 状态/日志
19. 安装/更新监控定时任务      20. 全局设置
21. 备份/恢复                  22. 系统信息/依赖检查
23. 卸载                       24. 编辑 Xray 配置
25. 测试节点连通性              0. 退出
```

「修改节点」支持修改名称、端口、SNI / 目标地址、流控、指纹、UUID、Reality 密钥和备注。重置 UUID 或密钥后旧链接立即失效；修改端口、SNI、流控、UUID 或密钥后，脚本会自动重新生成配置并重启 Xray。

## 流量统计

脚本在 Xray 配置中启用了 `StatsService` API（仅监听 `127.0.0.1:10085`），每个节点对应一个用户邮箱 `n<节点ID>`。

cron 任务默认每分钟执行一次：

```text
* * * * * /usr/local/bin/rysh monitor --quiet
```

每次执行读取 Xray 的累计用户计数，并与状态文件保存的上次计数作差后累加。状态文件同时保存 Xray 进程代次；检测到进程重启时，以新进程计数作为新增流量，不再通过 `-reset` 清空 Xray 计数器。若一次监控在保存状态前异常退出，下次轮询仍可从未清零的累计值恢复。

查看方式：

- 节点管理菜单 `4`：节点列表，显示本月 / 总计 / 限额 / 到期 / 限速
- 节点管理菜单 `14`：实时上下行速率
- 节点管理菜单 `15`：本月统计和历史月份统计
- 节点管理菜单 `10`：重置某个节点的本月或全部流量

## 月流量限额

菜单 `11` 设置节点每月允许的流量，单位 GB，支持小数，`0` 表示不限。

- 达到限额后，脚本会把该节点端口加入封禁规则，阻断新连接和已有连接
- 每月 1 日第一次监控运行时自动清零本月用量
- 新月份用量归零后，如果节点未到期且未禁用，会自动解封
- 提高限额或重置流量后会立即重新检查

限额统计的是上行 + 下行总流量，Xray 重启不会丢失已累计的用量。

## 到期时间

菜单 `12` 支持三种方式：

1. 设置剩余天数
2. 设置具体到期日期 `YYYY-MM-DD`
3. 取消到期限制

到期后脚本会把节点端口加入防火墙封禁列表；延长到期时间或取消限制后，下一次监控运行会自动解封。

## 端口限速

菜单 `13` 设置节点限速，单位 Mbps，`0` 表示不限。限速作用于该节点的监听端口，使用 tc `clsact` 上的 police 规则：

- 下载方向（服务器 → 客户端）：按 TCP 源端口匹配
- 上传方向（客户端 → 服务器）：按 TCP 目标端口匹配
- 优先使用 `flower` 匹配 IPv4 / IPv6；内核不支持时回退到 IPv4 `u32`

注意：

- 脚本只添加和删除自己记录的 `clsact` 过滤规则，不删除网卡原有 root qdisc，也不重定向全网卡流量。
- police 是超速丢包式限速，不是平滑排队；TCP 通常会因重传降低吞吐。实际速率受内核、线路和短时突发影响。
- 需要内核支持 `clsact`、`flower`（建议）和 police action；规则不支持时会报错，不会改动 root qdisc。
- 限速规则由 OpenRC 服务 `rysh` 在开机时自动恢复，也可以在菜单 `16` 手动重新应用。

## 自动封禁

自动封禁使用独立的 nftables 表 `inet rysh`，同时阻断：

- 入站 `tcp dport <节点端口>`
- 出站 `tcp sport <节点端口>`

如果系统没有 nftables，会尝试使用 iptables 自定义链 `RYSH_IN` / `RYSH_OUT`。

被禁用的节点不会出现在 Xray 配置中，端口可以留给其他服务使用。到期或超流量的节点仍保留在配置中，但会被防火墙阻断，便于续费后立即恢复。

## 常用命令

一键脚本本身支持子命令，便于自动化：

```sh
one-click.sh install        安装或更新 rysh
one-click.sh start          启动 rysh / Xray
one-click.sh stop           停止 rysh / Xray
one-click.sh purge          彻底卸载并清除全部数据
one-click.sh reset          重置节点凭据
one-click.sh menu           进入交互菜单
```

安装后的 `rysh` 支持（`ry` 是 `rysh` 的快捷命令，两者等价）：

```sh
ry                          进入节点管理菜单
rysh                        进入节点管理菜单
rysh install [--yes]        安装/更新 Xray 与依赖
rysh monitor [--quiet]      统计流量并执行限额/到期策略
rysh apply                  应用限速和防火墙规则
rysh clear                  清除限速和防火墙规则
rysh gen                    输出生成的 Xray 配置
rysh list                   列出节点
rysh start|stop|restart     启动/停止/重启服务
rysh status                 查看服务状态与日志
rysh reset-credentials      重置全部节点凭据（保留节点数据）
rysh uninstall [--purge]    卸载 rysh；--purge 同时删除 Xray 与全部数据
rysh version                显示脚本版本
```

## 文件位置

```text
/usr/local/bin/rysh                    主脚本
/usr/local/bin/ry                      rysh 快捷命令（指向 rysh 的软链接）
/etc/init.d/rysh                       OpenRC 策略服务（开机应用限速/防火墙）
/etc/init.d/xray                       OpenRC Xray 服务
/usr/local/bin/xray                    Xray 可执行文件
/usr/local/etc/xray/config.json        Xray 配置（由脚本生成）
/usr/local/share/xray/                 geoip.dat / geosite.dat
/var/log/xray/error.log                Xray 错误日志
/etc/rysh/nodes/<节点ID>.conf          节点配置（含私钥，权限 600）
/etc/rysh/state/<节点ID>.state         节点流量状态
/etc/rysh/history/                     月度历史
/etc/rysh/settings.conf                全局设置
/etc/rysh/events.log                   封禁/解封事件
/etc/rysh/blocked.ports                当前被封禁的端口
/etc/crontabs/root                     cron 监控任务
```

备份菜单 `21` 会把上述关键文件打包到 `/root/rysh-backup-<时间>.tar.gz`，恢复时从同一菜单选择备份文件即可。

## 常见问题

**Q: 执行一键脚本提示 `bash: command not found`？**

A: Alpine 最小系统默认没有 bash，执行 `apk add bash curl` 后重试，或改用 `sh /tmp/rysh-oneclick.sh` 的方式。

**Q: 输入 `ry` 提示 `command not found`？**

A: 确认 `/usr/local/bin` 在 `PATH` 中，并检查快捷命令是否存在：

```sh
ls -l /usr/local/bin/ry /usr/local/bin/rysh
echo $PATH
```

如果 `ry` 被其他程序占用，脚本会跳过创建，此时直接使用 `rysh` 即可；也可以手动重建：

```sh
ln -sf /usr/local/bin/rysh /usr/local/bin/ry
```

**Q: 安装时下载 Xray 失败？**

A: 多为 GitHub 访问受限。进入节点管理菜单 `20` 全局设置，填写下载代理（例如 `https://ghproxy.com`），再执行菜单 `1`。

**Q: 创建节点时提示「Xray 配置校验失败」？**

A: 1.0.1 之前的版本把临时配置写成 `config.json.tmp.<pid>`，新版 Xray 无法识别这种扩展名，会直接判定校验失败。请重新执行一键脚本并选择 `1` 更新到 1.0.1 或更高版本；更新后脚本会直接输出 Xray 的具体报错，便于定位其他配置问题。

**Q: Xray 启动失败？**

A: 查看日志：

```sh
tail -n 100 /var/log/xray/error.log
rysh status
```

常见原因是端口被占用、SNI / 目标地址不可用、配置被手动改坏，或下载的二进制架构不匹配。

**Q: 流量不更新？**

A: 依次检查：

```sh
rc-service xray status
rc-service crond status
grep rysh /etc/crontabs/root
rysh monitor
```

确认 Xray 配置中存在 `StatsService` API，并且 `127.0.0.1:10085` 可访问。手动执行 `rysh monitor` 可以立即刷新。

**Q: 限速没有生效？**

A: 检查 `tc` 与内核模块：

```sh
command -v tc
tc qdisc show dev <网卡>
tc filter show dev <网卡> egress chain 1381589832
```

容器或精简内核可能缺少 `clsact`、`flower` 或 police action 支持。脚本会保留现有 qdisc，并提示无法创建的规则；确认内核支持后可重新执行菜单 `16`。

**Q: 到期或超流量没有封禁？**

A: 检查封禁规则和监控任务：

```sh
nft list table inet rysh
cat /etc/rysh/blocked.ports
grep rysh /etc/crontabs/root
rysh monitor
```

如果使用 iptables 回退，检查 `iptables -L RYSH_IN -n -v` 和 `iptables -L RYSH_OUT -n -v`。

**Q: 忘记节点链接或更换了公网 IP？**

A: 菜单 `5` 可重新查看任意节点的链接和二维码；菜单 `6` 可导出全部链接。如果服务器位于 NAT 后面，请在菜单 `20` 中手动设置公网 IP / 域名。

## 安全建议

- 脚本必须以 root 运行，请只在可信服务器上使用。
- 节点配置文件包含 Reality 私钥，权限为 `600`，不要随意分享或提交到仓库。
- Xray Stats API 只监听 `127.0.0.1:10085`，不要把它暴露到公网。
- 建议使用防火墙限制管理入口，并定期备份 `/etc/rysh`。
- 请遵守当地法律法规和服务器提供商的使用条款。

## License

MIT

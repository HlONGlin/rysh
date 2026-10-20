# rysh

`rysh` 是一个面向 **Alpine Linux v3.21** 的 Xray Reality 多节点管理脚本。参考常见 Reality 一键脚本的交互方式，提供更多菜单项、多节点管理、单节点流量统计、月流量限额、到期时间限制和按端口限速。

脚本使用 POSIX `sh` 编写，适配 Alpine 的 busybox ash / OpenRC，不依赖 bash。

## 功能

- 一键安装或更新 Xray-core，自动识别 x86_64 / aarch64 / armv7 / armv6 / x86 / s390x
- 创建单个或批量创建多个 VLESS Reality 节点
- 每个节点独立端口、UUID、Reality 密钥、ShortID、SNI、目标地址
- 查看节点列表、详细信息、VLESS 分享链接、终端二维码
- 导出全部节点链接和 Base64 订阅文件
- 通过 Xray Stats API 统计每个节点的上下行流量
- 实时流量监控（每秒速率 + 本月 / 总计）
- 每月流量限额，超限自动封禁对应端口，次月自动恢复
- 节点到期时间限制（按剩余天数或指定日期），到期自动封禁
- 按端口限速（Mbps），同时限制上传和下载方向
- 启用 / 禁用节点、重置流量、修改节点参数
- 自动安装 cron 监控任务（默认每分钟检查一次）
- 防火墙封禁使用 nftables，失败时回退 iptables
- 备份 / 恢复配置、系统信息、依赖检查、卸载

## 环境要求

- Alpine Linux v3.21（其他使用 OpenRC + apk 的 Alpine 版本通常也可以）
- root 权限
- 可访问 GitHub（用于下载 Xray）；如果网络受限，可在脚本“全局设置”中配置下载代理
- 建议使用官方 Alpine 内核，确保支持 `nftables`、`tc`、`htb`、`ifb`、`cls_flower`

脚本会自动安装以下依赖：

```text
curl unzip jq nftables iproute2 ca-certificates
```

按需补装：

```text
iproute2-tc iproute2-ss qrencode
```

## 安装脚本

把 `rysh.sh` 放到 `/usr/local/bin/rysh`：

```sh
install -m 755 rysh.sh /usr/local/bin/rysh
rysh
```

也可以先从仓库下载再安装。首次进入菜单时，脚本也会尝试把自身复制到 `/usr/local/bin/rysh`，以便 cron 定时任务调用。

> 不要用 `curl ... | sh` 的方式直接运行，否则脚本无法把自己安装到 `/usr/local/bin/rysh`，定时任务也会失效。请先保存为文件再运行。

## 快速开始

1. 运行 `rysh`，输入 `1` 安装 / 更新 Xray。
2. 输入 `2` 创建单个节点，或输入 `3` 批量创建节点。
3. 按提示设置名称、端口、SNI、目标地址；端口留空会自动选择空闲端口。
4. 创建完成后会输出 VLESS 分享链接。
5. 在菜单 `5` 查看链接和二维码，或菜单 `6` 导出全部链接。
6. 菜单 `19` 可重新安装监控定时任务；正常情况下安装 Xray 时会自动安装。

## 菜单说明

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

### 创建节点

默认参数：

- 流控：`xtls-rprx-vision`
- 指纹：`chrome`
- SNI / 目标：`www.microsoft.com` / `www.microsoft.com:443`
- 限速：不限
- 月限额：不限
- 到期：永久

创建时可以只填写名称和 SNI，其他参数使用默认值。也可以在创建时选择设置限速、月限额和有效期。

Reality 的 `dest` / `serverNames` 需要使用支持 TLS 1.3 和 HTTP/2 的真实站点。常见可用目标包括 `www.microsoft.com`、`www.apple.com`、`www.cloudflare.com` 等。请确保目标站点在你服务器的网络中可访问。

### 修改节点

菜单 `7` 支持修改：

- 名称
- 端口
- SNI / 目标地址
- 流控（`xtls-rprx-vision` 或留空）
- 客户端指纹
- 重置 UUID
- 重置 Reality 密钥
- 备注

重置 UUID 或 Reality 密钥后，旧客户端链接立即失效，需要重新导入。修改端口、SNI、流控、UUID、密钥后脚本会重新生成配置并重启 Xray。

## 流量统计

脚本在 Xray 配置中启用了：

- `StatsService` API（仅监听 `127.0.0.1:10085`）
- 用户级上下行统计
- 每个节点对应一个用户邮箱：`n<节点ID>`

cron 任务默认每分钟执行一次：

```text
* * * * * /usr/local/bin/rysh monitor --quiet
```

每次执行时通过 `xray api statsquery -reset` 取得自上次检查以来的流量增量，累加到节点状态文件中。这样即使 Xray 重启，累计流量也不会重复计算。

查看方式：

- 菜单 `4`：节点列表，显示本月 / 总计 / 限额 / 到期 / 限速
- 菜单 `14`：实时上下行速率
- 菜单 `15`：本月统计和历史月份统计
- 菜单 `10`：重置某节点的本月或全部流量

状态文件位于：

```text
/etc/rysh/state/<节点ID>.state
/etc/rysh/history/<年-月>.log
```

## 每月流量限额

菜单 `11` 设置节点每月允许的流量（单位 GB，支持小数，`0` 表示不限）。

- 达到限额后，脚本会把该节点端口加入 nftables 封禁规则，阻断新连接和已有连接
- 每月 1 日（按服务器本地时间）第一次监控运行时自动清零本月用量
- 新月份用量归零后，如果节点未到期且未禁用，会自动解封
- 提高限额后会立即重新检查并解封
- 重置流量后也会立即重新检查

> 限额统计的是上行 + 下行总流量。Xray 重启不会丢失已累计的用量。

## 到期时间限制

菜单 `12` 支持：

- 设置剩余天数
- 设置具体到期日期 `YYYY-MM-DD`
- 取消到期限制

到期后脚本会把节点端口加入防火墙封禁列表。延长到期时间或取消限制后，下一次监控运行会自动解封。

## 按端口限速

菜单 `13` 设置节点限速，单位为 Mbps，`0` 表示不限。限速作用于该节点的监听端口：

- 下载方向（服务器 -> 客户端）：按源端口匹配，使用 egress HTB
- 上传方向（客户端 -> 服务器）：通过 ifb 重定向后按目标端口匹配，使用 ingress HTB
- 优先使用 `flower` 过滤器，同时匹配 IPv4 / IPv6；如果内核不支持则回退到 IPv4 的 `u32`

注意：

- 脚本会重建默认网卡的 root qdisc。**如果服务器上还有其他 tc 限速规则，请先备份或不要使用本功能。**
- 上传方向限速需要内核支持 `ifb` 模块；没有该模块时只对下载方向生效。
- 限速规则在重启后会由 OpenRC 服务 `rysh` 自动恢复，也可以在菜单 `16` 手动重新应用。

## 自动封禁说明

自动封禁使用独立的 nftables 表：

```text
inet rysh
```

规则同时阻断：

- 入站 `tcp dport <节点端口>`
- 出站 `tcp sport <节点端口>`

如果系统没有 nftables，会尝试使用 iptables 自定义链 `RYSH_IN` / `RYSH_OUT`。

被禁用的节点不会出现在 Xray 配置中，因此不会被防火墙封禁，端口可以留给其他服务使用。到期或超流量的节点仍保留在配置中，但会被防火墙阻断，便于续费后立即恢复。

## 全局设置

菜单 `20` 支持：

- 公网 IP / 域名：生成分享链接时使用，留空自动检测
- 默认 SNI
- 默认流控
- 默认客户端指纹
- 监控间隔（1-59 分钟）
- 限速网卡（留空自动检测默认路由网卡）
- 下载代理（例如 `https://ghproxy.com`）

如果服务器位于 NAT 后面，自动检测到的公网 IP 可能不正确，请手动设置。

## 文件位置

```text
/usr/local/bin/rysh                    主脚本
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
/etc/rysh/blocked.nft                  生成的 nftables 规则
/etc/crontabs/root                     cron 监控任务
```

## 备份与恢复

菜单 `21`：

- 备份到 `/root/rysh-backup-<时间>.tar.gz`
- 从备份恢复
- 查看备份列表

备份包含 `/etc/rysh`、Xray 配置、OpenRC 服务脚本和 root crontab。

## 卸载

菜单 `23` 提供两种方式：

1. 卸载 rysh，保留 Xray 和 `/etc/rysh` 配置
2. 完全卸载，删除 Xray、rysh、节点配置、日志和防火墙 / 限速规则

完全卸载需要输入 `DELETE` 二次确认。

## 命令行用法

除了交互菜单，也支持以下命令，便于 cron 或自动化：

```sh
rysh install                 安装/更新 Xray
rysh monitor                 统计流量并执行限额/到期策略
rysh monitor --quiet         静默模式（cron 使用）
rysh apply                   应用限速和防火墙规则
rysh clear                   清除限速和防火墙规则
rysh gen                     输出生成的 Xray 配置
rysh list                    列出节点
rysh start|stop|restart      控制 Xray
rysh status                  查看 Xray 状态和日志
rysh version                 显示脚本版本
```

## 常见问题

### Xray 启动失败

查看日志：

```sh
tail -n 100 /var/log/xray/error.log
rysh status
```

常见原因：

- 端口被其他程序占用
- SNI / 目标地址不可用
- 配置被手动修改后 JSON 不合法
- 架构与下载的 Xray 二进制不匹配

菜单 `24` 可以手动编辑配置，保存后脚本会执行 `xray run -test` 校验并重启。注意节点管理操作会重新生成配置，手动修改会被覆盖。

### 流量不更新

依次检查：

```sh
rc-service xray status
rc-service crond status
grep rysh /etc/crontabs/root
rysh monitor
```

确认 Xray 配置中存在 `StatsService` API，并且 `127.0.0.1:10085` 可访问。手动执行 `rysh monitor` 可以立即刷新。

### 限速没有生效

检查：

```sh
command -v tc
tc qdisc show
tc class show dev <网卡>
lsmod | grep -E 'ifb|htb|cls_flower'
```

如果缺少模块，可尝试：

```sh
modprobe ifb
modprobe sch_htb
modprobe cls_flower
```

在容器或精简内核中可能无法使用 ingress 限速，此时只有下载方向会生效。

### 到期/超流量没有封禁

检查 nftables：

```sh
nft list table inet rysh
cat /etc/rysh/blocked.ports
```

如果没有 nftables，检查 iptables：

```sh
iptables -L RYSH_IN -n -v
iptables -L RYSH_OUT -n -v
```

确认监控任务正在运行，并且执行过 `rysh monitor`。

### GitHub 下载失败

在菜单 `20` 的“下载代理”中填写可用的 GitHub 代理，例如：

```text
https://ghproxy.com
```

然后重新执行菜单 `1`。也可以手动下载对应架构的 `Xray-linux-*.zip`，解压后把 `xray` 放到 `/usr/local/bin/xray`。

## 安全提示

- 脚本必须以 root 运行，请只在可信服务器上使用。
- 节点配置文件包含 Reality 私钥，权限为 `600`，不要随意分享。
- Xray Stats API 只监听 `127.0.0.1:10085`，不要把它暴露到公网。
- 请遵守当地法律法规和服务器提供商的使用条款。

## 免责声明

本脚本仅用于服务器运维和网络技术学习。使用本脚本产生的任何后果由使用者自行承担。

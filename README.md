# my-gw-script

自用的网关快速部署脚本。

## 环境要求

- Debian 12+ (x86_64 / aarch64)，root 或 sudo 权限
- 可正常访问外网（下载二进制与分流数据需要；GitHub 受限时配置 `GH_PROXY`）

## 快速开始

```bash
git clone <本仓库> && cd gateway-setup
cp config.env.example config.env
vim config.env          # 必填 SUB_URL; 可选 Tailscale/节点选择
sudo bash install.sh    # 幂等, 可重复执行
```

## 架构

```
LAN ──→ MosDNS:53 ──CN 域名──→ 国内 DNS (直连)
             └────境外域名──→ Mihomo DNS (redir-host, 无 FakeIP)

LAN ──→ Mihomo TUN (auto-redirect)
          ├─ VoWiFi 域名        → 英国-UZ (经 香港-AKiX 前置)
          ├─ 中国大陆 域名/IP   → 直连 (Bypass TUN)
          ├─ 直连白名单域名     → 直连
          ├─ Tailnet (100.64/10)→ Bypass TUN, 内核转发 tailscale0 + SNAT
          └─ 其余               → 默认出口 香港-AKiX
```

要点：

- VoWiFi 落地用 **SS/VMess** 节点（REALITY 等 TLS 伪装协议经前置链会认证失败）。
- auto-redirect 会劫持 LAN DNS 到 Mihomo，CN 域名直连解析由 `nameserver-policy: geosite:cn` 实现。
- auto-redirect 仅重定向 TCP，LAN 客户端 UDP 直连。
- Tailnet 流量 TUN 排除 `100.64.0.0/10`，需广播 LAN 子网并手动 MASQUERADE（install.sh 已配置）。

## 配置 (config.env)

| 变量 | 说明 |
|---|---|
| `SUB_URL` | 机场订阅 (ClashMeta)，**必填** |
| `GH_PROXY` | GitHub 下载代理，留空直连 |
| `NODE_DEFAULT` | 海外默认出口节点名后缀 |
| `NODE_VOWIFI` / `NODE_VOWIFI_FRONT` | VoWiFi 落地 / 前置节点名后缀 |
| `DIRECT_DOMAINS` | 直连白名单域名，逗号分隔 |
| `MIHOMO_VERSION` / `MOSDNS_VERSION` | 版本锁定 |
| `TAILSCALE_*` | Tailscale 登录服务器 / authkey / 子网 (可选) |

敏感字段（订阅 token / authkey）仅存于 `/etc/gateway/config.env`（600），不入库。

## 运维

- 手动刷新订阅: `sudo systemctl start mihomo-refresh.service`
- WebUI: `http://<网关IP>:9090/ui/`，密钥在 `/etc/mihomo/secret`
- 验证:
  ```bash
  dig @127.0.0.1 baidu.com      # 国内 IP
  dig @127.0.0.1 google.com     # 境外 IP
  curl -s https://ifconfig.me   # 默认出口 IP
  ssh root@100.64.x.x           # Tailnet 连通
  ```

## 已知问题

1. Docker 会把 FORWARD 策略设为 DROP，已由 `gateway-forward.service` + docker drop-in 兜底。
2. Tailscale 需 `--netfilter-mode=off`（默认 netfilter 会丢弃 lo 回环应答导致 Tailnet 连接失败）。
3. LAN→Tailnet 必须广播 LAN 子网 + 手动 MASQUERADE，否则超时（见架构要点）。
4. 卸载: `systemctl disable --now mosdns mihomo gateway-forward mihomo-refresh.timer tailscaled`，删除 `/etc/{mihomo,mosdns,gateway}` 及对应 systemd 单元。

## 数据源

- 分流: [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat)、[Loyalsoldier/geoip](https://github.com/Loyalsoldier/geoip)、[cira.moedove.com](https://cira.moedove.com)
- WebUI: [MetaCubeX/metacubexd](https://github.com/MetaCubeX/metacubexd)
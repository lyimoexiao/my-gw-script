#!/usr/bin/env python3
"""透明代理网关配置转换器。

从机场订阅生成 /etc/mihomo/config.yaml，并更新分流数据:
  - 订阅节点 (米哈莫规则)
  - cira China IP 列表 (route-exclude-address-set, TUN Bypass)
  - Loyalsoldier geosite.dat / geoip.dat / Country.mmdb
  - mosdns 使用的 geosite_cn.txt 与 direct_domains.txt

所有可配置项通过环境变量传入 (见 config.env, 由 install.sh/systemd 加载)。
用法: sudo python3 /etc/gateway/convert.py
"""
import os
import pathlib
import secrets
import struct
import sys
import urllib.request

import yaml

SUB_URL = os.environ.get("SUB_URL", "")
GH_PROXY = os.environ.get("GH_PROXY", "").rstrip("/")
CIRA_URL = os.environ.get("CIRA_URL", "https://cira.moedove.com/china_all_v4.txt")
HKG = os.environ.get("NODE_DEFAULT", "香港-AKiX")          # 海外默认出口
UK = os.environ.get("NODE_VOWIFI", "英国-UZ")             # VoWiFi 落地
VOWIFI_FRONT = os.environ.get("NODE_VOWIFI_FRONT", "香港-AKiX")  # 前置代理
DIRECT_DOMAINS = [d.strip() for d in
                  os.environ.get("DIRECT_DOMAINS", "").split(",") if d.strip()]
GEOSITE_CN_CATEGORY = os.environ.get("GEOSITE_CN_CATEGORY", "CN")


def gh_url(path: str) -> str:
    """GitHub 资源 URL; GH_PROXY 设置时经代理 (proxy/github.com/path), 否则直连。"""
    if GH_PROXY:
        return f"{GH_PROXY}/github.com/{path}"
    return f"https://github.com/{path}"


DAT_URL = gh_url("Loyalsoldier/v2ray-rules-dat/releases/latest/download/{name}")
MMDB_URL = gh_url("Loyalsoldier/geoip/releases/latest/download/Country.mmdb")

HOME = pathlib.Path("/etc/mihomo")
RULESET = HOME / "ruleset"
SUB_FILE = HOME / "subscription.yaml"
CONFIG = HOME / "config.yaml"
GEOSITE_DAT = HOME / "geosite.dat"

PROXY = "Proxy"
VOICE = "VoWiFi"


def fetch(url: str, dest: pathlib.Path, retries: int = 3) -> None:
    req = urllib.request.Request(url, headers={"User-Agent": "clash-verge/v2.0.0"})
    for i in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                dest.write_bytes(r.read())
            return
        except Exception as e:
            print(f"  retry {i + 1}/{retries}: {e}", file=sys.stderr)
    sys.exit(f"failed: {url}")


def _load_secret() -> str:
    """WebUI API 访问密钥, 不存在则生成。"""
    f = HOME / "secret"
    if not f.exists():
        f.write_text(secrets.token_urlsafe(16))
    return f.read_text().strip()


def _rd_varint(b, o):
    r = 0
    s = 0
    while True:
        x = b[o]
        o += 1
        r |= (x & 0x7F) << s
        if not x & 0x80:
            return r, o
        s += 7


def _fields(b, o, end):
    while o < end:
        tag, o = _rd_varint(b, o)
        f, wt = tag >> 3, tag & 7
        if wt == 0:
            _, o = _rd_varint(b, o)
        elif wt == 1:
            o += 8
        elif wt == 2:
            ln, o = _rd_varint(b, o)
            yield f, b[o:o + ln], o + ln
            o += ln
        elif wt == 5:
            o += 4
        else:
            raise ValueError(f"bad wire type {wt}")


def geosite_category(dat: pathlib.Path, wanted: str) -> list[str]:
    """从 v2ray geosite.dat (protobuf) 提取分类域名列表。"""
    data = dat.read_bytes()
    for _, geo_site, _ in _fields(data, 0, len(data)):
        cc = None
        doms = []
        for f, v, _ in _fields(geo_site, 0, len(geo_site)):
            if f == 1:
                cc = v.decode()
            elif f == 2:
                typ = 0
                val = None
                for f2, v2, _ in _fields(v, 0, len(v)):
                    if f2 == 1:
                        typ = v2
                    elif f2 == 2:
                        val = v2.decode()
                doms.append((typ, val))
        if cc == wanted:
            return [val.lstrip(".") for typ, val in doms if typ in (0, 2)]
    sys.exit(f"geosite category {wanted} not found in {dat}")


def main() -> None:
    if not SUB_URL:
        sys.exit("SUB_URL 未配置 (见 /etc/gateway/config.env)")

    print("fetching subscription")
    fetch(SUB_URL, SUB_FILE)
    sub = yaml.safe_load(SUB_FILE.read_text())
    proxies = sub["proxies"]
    names = [p["name"] for p in proxies]

    hkg = next(n for n in names if n.endswith(HKG))
    uk = next(n for n in names if n.endswith(UK))
    front = next(n for n in names if n.endswith(VOWIFI_FRONT))
    for p in proxies:
        if p["name"] == uk:
            p["dialer-proxy"] = front  # VoWiFi 经前置代理

    others = [n for n in names if n != uk]
    groups = [
        {"name": PROXY, "type": "select",
         "proxies": [hkg, "自动选择", "故障转移", *others]},
        {"name": "自动选择", "type": "url-test", "proxies": others,
         "url": "http://www.gstatic.com/generate_204", "interval": 300},
        {"name": "故障转移", "type": "fallback", "proxies": others,
         "url": "http://www.gstatic.com/generate_204", "interval": 300},
        {"name": VOICE, "type": "select",
         "proxies": [uk, "DIRECT"]},
    ]

    rules = [
        "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
        "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
        "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve",
        "DOMAIN-SUFFIX,pub.3gppnetwork.org,VoWiFi",
    ] + [f"DOMAIN-SUFFIX,{d},DIRECT" for d in DIRECT_DOMAINS] + [
        "GEOSITE,CN,DIRECT",
        "GEOIP,CN,DIRECT",
        "MATCH,Proxy",
    ]

    config = {
        "mixed-port": 7890,
        "mode": "rule",
        "log-level": "info",
        "ipv6": False,
        "external-controller": "0.0.0.0:9090",
        "external-ui": "./ui",
        "secret": _load_secret(),
        "tun": {
            "enable": True,
            "stack": "mixed",
            "auto-route": True,
            "auto-redirect": True,
            "auto-detect-interface": True,
            "route-exclude-address": [
                # Tailnet 全部走内核转发 + tailscaled SNAT (需 --advertise-routes 广播
                # LAN 子网): 不进入 mihomo。mihomo 的 DIRECT 拨号 socket 绑定 eth0,
                # 表 52 路由因源地址不匹配不可用, 拨号会从 eth0 发给路由器而失败;
                # 内核转发 + SNAT 走 WireGuard 主会话, 实测可靠
                "100.64.0.0/10",
            ],
            "route-exclude-address-set": ["ChinaIP"],  # 中国大陆 IP Bypass TUN
        },
        "sniffer": {"enable": True},
        "dns": {
            "enable": True,
            "listen": "127.0.0.1:1053",
            "ipv6": False,
            "enhanced-mode": "redir-host",  # 不使用 FakeIP
            "default-nameserver": ["223.5.5.5", "119.29.29.29"],
            "proxy-server-nameserver": ["223.5.5.5", "119.29.29.29"],
            "nameserver": ["223.5.5.5", "119.29.29.29"],
            "nameserver-policy": {
                # auto-redirect 会把 LAN DNS 劫持到 mihomo DNS，在此复现 CN 域名直连解析
                "geosite:cn": ["223.5.5.5", "119.29.29.29"],
            },
            "fallback": ["1.1.1.1", "8.8.8.8"],
            "fallback-filter": {"geoip": True, "geoip-code": "CN", "geosite": ["gfw"]},
            "respect-rules": True,
        },
        "proxies": proxies,
        "proxy-groups": groups,
        "rule-providers": {
            "ChinaIP": {
                "type": "file",
                "behavior": "ipcidr",
                "format": "text",
                "path": "./ruleset/china_all_v4.txt",
            }
        },
        "rules": rules,
    }

    print("fetching China IP list (cira)")
    RULESET.mkdir(exist_ok=True)
    fetch(CIRA_URL, RULESET / "china_all_v4.txt.raw")
    clean = "\n".join(l for l in (RULESET / "china_all_v4.txt.raw").read_text().splitlines()
                      if l and not l.startswith("#"))
    (RULESET / "china_all_v4.txt").write_text(clean + "\n")

    print("fetching geosite.dat / geoip.dat / Country.mmdb")
    fetch(DAT_URL.format(name="geosite.dat"), GEOSITE_DAT)
    fetch(DAT_URL.format(name="geoip.dat"), HOME / "geoip.dat")
    fetch(MMDB_URL, HOME / "Country.mmdb")

    print(f"extracting geosite category {GEOSITE_CN_CATEGORY} for mosdns")
    mosdns_dir = pathlib.Path("/etc/mosdns")
    mosdns_dir.mkdir(exist_ok=True)
    domains = geosite_category(GEOSITE_DAT, GEOSITE_CN_CATEGORY)
    (mosdns_dir / "geosite_cn.txt").write_text("\n".join(domains) + "\n")
    (mosdns_dir / "direct_domains.txt").write_text("\n".join(DIRECT_DOMAINS) + "\n")

    CONFIG.write_text(yaml.safe_dump(config, allow_unicode=True, sort_keys=False))
    print(f"wrote {CONFIG} ({len(domains)} domains -> geosite_cn.txt)")


if __name__ == "__main__":
    main()
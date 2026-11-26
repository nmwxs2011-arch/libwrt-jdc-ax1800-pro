#!/bin/bash
set -e

# ============================================================
# JDC AX1800 Pro (RE-SS-01) 云编译 DIY 脚本 —— 完整合并版
# 用法：整段替换 fork 仓库根目录的 libwrt.sh
#       工作流已通过 diy_script: libwrt.sh 调用，无需改 yml
# 执行时机：源码 clone 且 feeds 安装之后，make defconfig / make 之前
# 包含：
#   1) dnsmasq DNS 劫持端口补丁（上游仓库原有功能，保留）
#   2) PassWall2 官方源
#   3) 首次启动配置 99-custom（打印 / 扫描 / 定时 / 服务自启）
#   4) 只更新新增的 PassWall2 源（不 clean、不全量 update，保护 nss feed）
# ============================================================

# ---------- 1) dnsmasq DNSMASQ HIJACK 端口补丁 ----------
# DNS listener disabled (port=0) 时，劫持规则应跳到实际 DNS 服务端口
# （AdGuard Home / Pi-hole），而不是 dnsmasq 自己已关闭的端口。
DNSMASQ_INIT=$(find . -path "*/dnsmasq/files/dnsmasq.init" -o -path "*/dnsmasq*/dnsmasq.init" 2>/dev/null | head -n1)
if [ -n "$DNSMASQ_INIT" ] && grep -q 'redirect to :\$dns_port' "$DNSMASQ_INIT"; then
  echo ">>> Patching DNSMASQ HIJACK rule in $DNSMASQ_INIT"
  sed -i \
    -e 's/config_get dns_port "\$cfg" port 53/config_get dns_port "$cfg" port 53\n\tconfig_get dns_redirect_port "$cfg" dns_redirect_port "$dns_port"/' \
    -e 's/redirect to :\$dns_port/redirect to :$dns_redirect_port/' \
    "$DNSMASQ_INIT"
else
  echo ">>> WARNING: dnsmasq.init not found or pattern has changed, manual check required" >&2
fi

# ---------- 2) 加入 PassWall2 官方源（新组织 Openwrt-Passwall） ----------
# 幂等：重复执行不会重复追加
grep -q 'openwrt-passwall2' feeds.conf.default || cat >> feeds.conf.default <<'EOF'
src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main
src-git passwall2 https://github.com/Openwrt-Passwall/openwrt-passwall2.git;main
EOF

# ---------- 3) 首次启动配置：files/etc/uci-defaults/99-custom ----------
# 工作流会把仓库 files/ 目录复制进源码根目录；这里生成的文件会被打包进 rootfs。
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-custom <<'CUSTOM'
#!/bin/sh
# 首次启动自动配置：打印 / 扫描 / 定时重启 / 服务自启
# 只在首次启动（或升级后首次）执行，之后可自由在 LuCI 修改。

# --- 打印：p910nd 守护进程实际读取 /etc/config/p910nd ---
# 这是新机避坑关键：LuCI 页面写 usb_printer，守护进程读 p910nd，
# 直接生成正确配置可绕过“页面勾了启用但 9100 不监听”的问题。
mkdir -p /etc/config
if [ ! -s /etc/config/p910nd ]; then
  cat > /etc/config/p910nd <<'EOF_P910'
config p910nd
    option device '/dev/usb/lp0'
    option port '0'
    option enabled '1'
    option bidirectional '1'
EOF_P910
fi
/etc/init.d/p910nd enable 2>/dev/null
/etc/init.d/p910nd restart 2>/dev/null

# --- 扫描：xinetd 托管 saned，监听 6566 ---
mkdir -p /etc/xinetd.d /etc/sane.d
cat > /etc/xinetd.d/sane-port <<'EOF_XINETD'
service sane-port
{
        port        = 6566
        socket_type = stream
        wait        = no
        user        = saned
        group       = saned
        server      = /usr/sbin/saned
        disable     = no
}
EOF_XINETD
# 允许本网段访问扫描（默认管理地址 192.168.1.1；若改成 192.168.2.1 请同步改）
grep -q '192.168.1.0/24' /etc/sane.d/saned.conf 2>/dev/null || echo '192.168.1.0/24' >> /etc/sane.d/saned.conf
/etc/init.d/xinetd enable 2>/dev/null
/etc/init.d/xinetd restart 2>/dev/null

# --- 定时重启：每隔两天 01:00，带防循环保护 ---
# sleep 70 等待时间同步完成；touch /etc/banner 防止升级配置回退时反复重启
mkdir -p /etc/crontabs
cat > /etc/crontabs/root <<'EOF_CRON'
0 1 */2 * * sleep 70 && touch /etc/banner && reboot
EOF_CRON
/etc/init.d/cron enable 2>/dev/null
/etc/init.d/cron restart 2>/dev/null

exit 0
CUSTOM
chmod +x files/etc/uci-defaults/99-custom

# ---------- 4) 只更新新增的 PassWall2 源，让其在 defconfig 时可见 ----------
# 【关键修复】绝不要执行 `./scripts/feeds clean` 或 `./scripts/feeds update -a`：
# 工作流在本脚本之前已装好全部 feed（含 nss_packages，提供 NSS 固件 choice）。
# clean/update -a 会清掉或重建这些 feed，导致 nss-firmware 的选项在 defconfig 时
# 不可用，CONFIG_NSS_FIRMWARE_VERSION_12_1 变成 <unset>，严格校验随即失败。
# 这里只针对新加的两个源做 update，再 install 到 package/feeds 下即可。
./scripts/feeds update passwall_packages
./scripts/feeds update passwall2
./scripts/feeds install -p passwall_packages -a
./scripts/feeds install -p passwall2 -a

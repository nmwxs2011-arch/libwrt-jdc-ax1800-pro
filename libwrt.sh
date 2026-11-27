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
# 【根因修复】工作流在 "Install Feeds" 步骤已先跑过 `feeds update -a`，
# 它生成了 feeds.conf；而 make defconfig 读的是 feeds.conf，不是 feeds.conf.default。
# 旧的幂等判断只写 feeds.conf.default，导致 defconfig 看不到 passwall2 源
# （build.config 里表现为 "CONFIG_FEED_passwall2 is not set"），界面包被丢弃。
# 因此这里必须同时写入两个文件，并按 feed 名精确判断（不用 URL 子串）。
add_pw2_feeds() {
  local conf="$1"
  grep -qE '^[[:space:]]*src-git[[:space:]]+passwall2[[:space:]]' "$conf" 2>/dev/null && return 0
  cat >> "$conf" <<'EOF'
src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main
src-git passwall2 https://github.com/Openwrt-Passwall/openwrt-passwall2.git;main
EOF
  echo ">>> appended passwall feeds to $conf"
}
add_pw2_feeds feeds.conf.default
# feeds.conf 由工作流生成，务必同步追加，否则 defconfig 不认
if [ -f feeds.conf ]; then
  add_pw2_feeds feeds.conf
else
  cp feeds.conf.default feeds.conf
fi

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
# 【v5.1 修复】固件已自带非空 /etc/config/p910nd（enabled=0），原来的
# `[ ! -s ... ]` 判断因此永远不成立、跳过写入，导致 9100 不监听。
# 改为：无论文件是否已存在，都用 uci 强制把关键项写成启用值。
if ! uci show p910nd >/dev/null 2>&1; then
  cat > /etc/config/p910nd <<'EOF_P910'
config p910nd
    option device '/dev/usb/lp0'
    option port '0'
    option enabled '1'
    option bidirectional '1'
EOF_P910
fi
# 强制覆盖关键项（即使厂商/固件预置了 enabled=0 也会被纠正）
uci set p910nd.@p910nd[0].device='/dev/usb/lp0' 2>/dev/null
uci set p910nd.@p910nd[0].port='0' 2>/dev/null
uci set p910nd.@p910nd[0].enabled='1' 2>/dev/null
uci set p910nd.@p910nd[0].bidirectional='1' 2>/dev/null
uci commit p910nd 2>/dev/null
/etc/init.d/p910nd enable 2>/dev/null
/etc/init.d/p910nd restart 2>/dev/null

# --- 扫描：xinetd 托管 saned，监听 6566 ---
# 25.12 的 sane-daemon 包会自带 /etc/xinetd.d/sane-port（user=saned, group=scanner,
# disable=yes）。这里覆盖为启用版，group 必须与包内 USERID:=saned:scanner 一致。
mkdir -p /etc/xinetd.d /etc/sane.d
cat > /etc/xinetd.d/sane-port <<'EOF_XINETD'
service sane-port
{
        port        = 6566
        socket_type = stream
        wait        = no
        user        = saned
        group       = scanner
        server      = /usr/sbin/saned
        disable     = no
}
EOF_XINETD
# 允许本网段访问扫描（默认管理地址 192.168.1.1；若改成 192.168.2.1 请同步改）
grep -q '192.168.1.0/24' /etc/sane.d/saned.conf 2>/dev/null || echo '192.168.1.0/24' >> /etc/sane.d/saned.conf
# 确保 epson2 后端被 dll.conf 加载（L850 走 epson2；每个后端包自带 dll.d 片段，
# 这里再补一道保险，避免 @noauto 导致后端未启用）。
mkdir -p /etc/sane.d/dll.d
grep -q '^epson2' /etc/sane.d/dll.conf 2>/dev/null || echo 'epson2' >> /etc/sane.d/dll.conf
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

# --- 界面语言：固定为简体中文（v5.2）---
# 固件已内置 luci-i18n-base-zh-cn 等中文包；这里把默认语言从 auto 改成 zh-cn，
# 无论浏览器语言是什么都显示中文（编译进固件，无需浏览器 auto 匹配）。
uci set luci.main.lang='zh-cn' 2>/dev/null
uci commit luci 2>/dev/null

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

# 【关键修复 v5】显式把 .config 里的 FEED 标记置 y。
# 根因：workflow 在 clone 后立即跑过一次 make defconfig（Generate Variables 步骤），
# 那时 passwall2 还没注册，于是 .config 里被写入 "# CONFIG_FEED_passwall2 is not set"。
# 后续 libwrt.sh 即使装好了 feed，最后一次 make defconfig 也会沿用这个显式的 not set，
# 导致 CONFIG_PACKAGE_luci-app-passwall2 被丢弃（manifest 里看不到界面包）。
# 这里直接改写 .config 的两行标记，确保最终 defconfig 承认这两个 feed。
if [ -f .config ]; then
  sed -i 's/^# *CONFIG_FEED_passwall2 is not set$/CONFIG_FEED_passwall2=y/' .config
  grep -q '^CONFIG_FEED_passwall2=' .config || echo 'CONFIG_FEED_passwall2=y' >> .config
  sed -i 's/^# *CONFIG_FEED_passwall_packages is not set$/CONFIG_FEED_passwall_packages=y/' .config
  grep -q '^CONFIG_FEED_passwall_packages=' .config || echo 'CONFIG_FEED_passwall_packages=y' >> .config
  echo ">>> forced CONFIG_FEED_passwall2=y / CONFIG_FEED_passwall_packages=y in .config"
fi

# 【自检】确认两个包在 defconfig 阶段可见，避免再次产出缺包固件。
# 若缺失就直接 fail，让编译停在这里，而不是浪费 1.5 小时后才发现缺包。
check_pkg() {
  local name="$1"
  # feeds install 按「源目录名」建软链；一个 Makefile 常产出多个子包，
  # 例如 sane-backends 产出 libsane / sane-daemon / sane-epson2 / sane-frontends，
  # 磁盘上并没有叫 sane-daemon 的目录。所以先找同名目录（如 luci-app-passwall2），
  # 再回退到 feed 源码里的 "define Package/<name>"，并确认其源包已被 install。
  if find package/feeds -maxdepth 2 -name "$name" 2>/dev/null | grep -q .; then
    echo ">>> OK: package '$name' visible to defconfig (source dir)"
    return 0
  fi
  local mk src feed
  mk=$(grep -rl --include=Makefile "define Package/$name" feeds 2>/dev/null | head -n1)
  if [ -n "$mk" ]; then
    src=$(basename "$(dirname "$mk")")
    feed=$(echo "$mk" | cut -d/ -f2)
    if [ -e "package/feeds/$feed/$src" ]; then
      echo ">>> OK: package '$name' visible to defconfig (in $feed/$src)"
      return 0
    fi
  fi
  echo ">>> FATAL: package '$name' not installed by feeds; defconfig will drop it." >&2
  return 1
}
check_pkg luci-app-passwall2 || exit 1
check_pkg sane-daemon || exit 1

# 【自检 v5】确认 .config 里 FEED 标记已置 y——这才是界面包能否进固件的决定因素。
# 只查软链不够：上次软链自检 OK，但 FEED 标记仍为 not set，界面包最终被丢弃。
if grep -q '^# CONFIG_FEED_passwall2 is not set' .config 2>/dev/null; then
  echo ">>> FATAL: CONFIG_FEED_passwall2 still not set; luci-app-passwall2 will be dropped." >&2
  exit 1
fi
echo ">>> OK: CONFIG_FEED_passwall2=y in .config"

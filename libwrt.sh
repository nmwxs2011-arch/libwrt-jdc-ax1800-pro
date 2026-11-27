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
#   3) 首次启动配置 99-custom（管理地址 / 打印 / 扫描 / 定时 / 服务自启）
#   4) 只更新新增的 PassWall2 源（不 clean、不全量 update，保护 nss feed）
#   5) 默认管理地址改为 192.168.123.1（config_generate + uci-defaults 双保险）
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
# 首次启动自动配置：管理地址 / 打印 / 扫描 / 定时重启 / 服务自启
# 只在首次启动（或升级后首次）执行，之后可自由在 LuCI 修改。

# --- 管理地址：固定为 192.168.123.1（官方 image config 已改，这里再保一道）---
# 即使刷机时保留了旧配置，首启也会把 LAN 口改到新地址；电脑设 192.168.123.x/24 即可进。
# 新版 config_generate 用 list ipaddr='IP/前缀'，所以先删旧值再 add_list，避免 option/list 混用。
uci -q delete network.lan.ipaddr 2>/dev/null
uci add_list network.lan.ipaddr='192.168.123.1/24' 2>/dev/null
uci set network.lan.netmask='255.255.255.0' 2>/dev/null
uci commit network 2>/dev/null

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
# 允许本网段访问扫描（管理地址已改为 192.168.123.1，网段同步为 192.168.123.0/24）
grep -q '192.168.123.0/24' /etc/sane.d/saned.conf 2>/dev/null || echo '192.168.123.0/24' >> /etc/sane.d/saned.conf
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

# 【关键修复 v5.4 — 本次根因】清掉 workflow 早期 defconfig 留下的 tmp 扫描缓存并重建。
# 根因：workflow 在 Generate Variables 步骤（feeds.conf 还没有 passwall 源时）跑过
#   `make defconfig`，生成了 tmp/.config-package.in、tmp/.packageinfo、tmp/info/*。
#   随后本脚本才 feeds install 新源。但后续 `make defconfig` 的 prepare-tmpinfo 阶段
#   依赖时间戳判断（tmp/.config-package.in -nt tmp/.packageinfo 时跳过重建），于是
#   passwall_packages / passwall2 的包符号从未进入 Kconfig。表现为：FEED 标记=y、
#   软链存在、seed 里 =y，但 build.config 里包符号根本不存在 → defconfig 丢弃。
# 处理：删掉这些缓存文件强制 make defconfig 重新扫描全部 package（含新装的两个源）。
#   注意只删 tmp 下的扫描缓存，不动 feeds/、package/feeds/，因此不会影响 nss feed。
echo ">>> v5.4: clearing stale tmp scan cache so new feeds are visible to defconfig"
rm -f tmp/.config-package.in tmp/.packageinfo tmp/.packagedeps \
      tmp/.packageauxvars tmp/.packageusergroup tmp/.config-feeds.in tmp/.build
rm -rf tmp/info
# 立即重建，让后面的自检能在新鲜的 tmp/.config-package.in 上判断
make prepare-tmpinfo >/dev/null 2>&1 || {
  echo ">>> WARNING: prepare-tmpinfo failed; will retry via defconfig later" >&2
}

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

# 【自检 v5.3】确认语言开关与 PassWall2 依赖齐全，避免再次产出缺包固件。
# 语言：LuCI 翻译包 HIDDEN，真正开关是 LUCI_LANG_*；vi=y 会导致 zh-cn 包不生成。
if grep -q '^CONFIG_LUCI_LANG_vi=y' .config 2>/dev/null; then
  echo ">>> FATAL: CONFIG_LUCI_LANG_vi=y still set; Chinese (zh-cn) packages will NOT be built." >&2
  exit 1
fi
grep -q '^CONFIG_LUCI_LANG_zh_Hans=y' .config 2>/dev/null || {
  echo ">>> FATAL: CONFIG_LUCI_LANG_zh_Hans not set; Chinese (zh-cn) packages will NOT be built." >&2
  exit 1
}
echo ">>> OK: CONFIG_LUCI_LANG_zh_Hans=y in .config"
# PassWall2 的 7 个显式依赖：缺任意一个，defconfig 都会丢弃 luci-app-passwall2。
for dep in coreutils coreutils-base64 coreutils-nohup coreutils-timeout ip-full libuci-lua unzip; do
  grep -q "^CONFIG_PACKAGE_${dep}=y" .config 2>/dev/null || {
    echo ">>> FATAL: CONFIG_PACKAGE_${dep} not set; luci-app-passwall2 will be dropped." >&2
    exit 1
  }
done
echo ">>> OK: all 7 PassWall2 deps enabled in .config"

# 【自检 v5.4 — 决定性检查】前面所有自检都是间接条件（软链/FEED/依赖），
# 上一版这些全 OK，界面包却仍被 defconfig 丢弃。这里直接跑一次 defconfig，
# 然后检查最终 .config 里 luci-app-passwall2 到底是不是 =y。
# 这样任何"包被丢弃"的问题都会在编译开始前几分钟就 FATAL，不再空等 1.5 小时。
echo ">>> v5.4: running make defconfig to verify final package selection..."
make defconfig >/tmp/v54_defconfig.log 2>&1 || {
  echo ">>> FATAL: make defconfig failed (v5.4 decisive check)." >&2
  tail -40 /tmp/v54_defconfig.log >&2
  exit 1
}
if grep -q '^CONFIG_PACKAGE_luci-app-passwall2=y' .config 2>/dev/null; then
  echo ">>> OK: luci-app-passwall2=y present in final .config (v5.4 decisive check)"
else
  echo ">>> FATAL: luci-app-passwall2 is NOT selected in final .config after defconfig." >&2
  echo ">>> DIAG: grep config-package.in:" >&2
  grep -n 'luci-app-passwall2' tmp/.config-package.in 2>/dev/null | head -5 >&2 || true
  echo ">>> DIAG: .config passwall lines:" >&2
  grep -n 'passwall' .config 2>/dev/null | head -20 >&2 || true
  echo ">>> DIAG: feed symlink:" >&2
  ls -ld package/feeds/passwall2/luci-app-passwall2 2>/dev/null >&2 || true
  exit 1
fi
# 扫描缓存重建后，passwall_packages 独有包（xray-core 等）也应可见；仅提示不致命
if grep -q '^config PACKAGE_xray-core$' tmp/.config-package.in 2>/dev/null; then
  echo ">>> OK: passwall_packages feed packages visible in Kconfig (xray-core found)"
else
  echo ">>> WARNING: passwall_packages packages still not in Kconfig; core set may be limited" >&2
fi

# ---------- 5) 默认管理地址改为 192.168.123.1 ----------
# 主路径：seed 已开 CONFIG_TARGET_DEFAULT_LAN_IP_FROM_PREINIT=y，
# 并覆盖 CONFIG_TARGET_PREINIT_IP="192.168.123.1"；base-files 会生成
# /etc/board.d/99-lan-ip，把该地址写进 board.json，config_generate 据此生成网络配置。
# 这里再改 config_generate 里的兜底字面量作为第二道保险。
# 99-custom 里的 uci 写入是第三道保险（保留配置升级时也能纠正）。
CFG_GEN="package/base-files/files/bin/config_generate"
if [ -f "$CFG_GEN" ]; then
  before=$(grep -c '192\.168\.1\.1' "$CFG_GEN" 2>/dev/null || true)
  sed -i 's/192\.168\.1\.1/192.168.123.1/g' "$CFG_GEN"
  after=$(grep -c '192\.168\.123\.1' "$CFG_GEN" 2>/dev/null || true)
  echo ">>> OK: config_generate LAN IP patched (found $before occurrence(s), now $after)"
else
  echo ">>> WARNING: $CFG_GEN not found; relying on 99-custom uci-defaults for LAN IP" >&2
fi

# 【自检】确认新管理地址确实写进了固件（image config + 编译期兜底 + 首启脚本三保险）
if grep -q '^CONFIG_TARGET_PREINIT_IP="192.168.123.1"$' .config 2>/dev/null && \
   grep -q '^CONFIG_TARGET_DEFAULT_LAN_IP_FROM_PREINIT=y$' .config 2>/dev/null && \
   grep -q '192\.168\.123\.1' "$CFG_GEN" 2>/dev/null && \
   grep -q "network.lan.ipaddr='192.168.123.1/24'" files/etc/uci-defaults/99-custom 2>/dev/null && \
   grep -q '192.168.123.0/24' files/etc/uci-defaults/99-custom 2>/dev/null; then
  echo ">>> OK: firmware LAN IP = 192.168.123.1 and scan subnet = 192.168.123.0/24"
else
  echo ">>> FATAL: LAN IP patch incomplete; firmware would boot at old address." >&2
  echo ">>> DIAG: .config LAN lines:" >&2
  grep -n 'PREINIT_IP\|DEFAULT_LAN_IP_FROM_PREINIT' .config 2>/dev/null | head -10 >&2 || true
  echo ">>> DIAG: config_generate IP lines:" >&2
  grep -n '192.168' "$CFG_GEN" 2>/dev/null | head -10 >&2 || true
  exit 1
fi

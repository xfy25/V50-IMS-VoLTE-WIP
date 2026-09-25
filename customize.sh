#!/system/bin/sh
# ============================================================================
# customize.sh —— 安装期校验（v0.61 新增）
#
#   为什么要有这个文件：
#     本模块会覆盖 /system/framework/telephony-common.jar 并往 system_ext 塞一堆
#     LG 专有库。装到非 V50 的机器上不会"装不上"，而是会把对方的 telephony 栈换掉，
#     后果从拨号失灵到开不了机都有。这个坑真实发生过 —— 曾经被装到一台一加 8T 上。
#     所以这里做硬校验：设备不对直接 abort，宁可不装。
#
#   注意：本文件只在【安装时】执行，不进 runtime。它不动 post-fs-data.sh /
#         service.sh 的任何逻辑，因此加它不改变模块的运行行为，不可能导致 bootloop。
# ============================================================================

SKIPUNZIP=0

# ---------------------------------------------------------------- 输出工具
# Magisk / APatch 的 installer 环境提供 ui_print；缺失时退化为 echo
if ! command -v ui_print >/dev/null 2>&1; then
  ui_print() { echo "$1"; }
fi

say()  { ui_print "$1"; }
fail() { ui_print " "; ui_print "!! $1"; ui_print " "; abort "$1"; }

# ---------------------------------------------------------------- 读取设备代号
# getprop 在从 App 安装时一定有；recovery 里可能没有，所以再兜两个文件源。
read_prop() {
  v=$(getprop "$1" 2>/dev/null)
  [ -n "$v" ] && { echo "$v"; return; }
  for f in /system/build.prop /system/system_ext/etc/build.prop /vendor/build.prop; do
    [ -f "$f" ] || continue
    v=$(grep -m1 "^$1=" "$f" 2>/dev/null | cut -d= -f2)
    [ -n "$v" ] && { echo "$v"; return; }
  done
  echo ""
}

DEV=$(read_prop ro.product.device)
[ -z "$DEV" ] && DEV=$(read_prop ro.product.vendor.device)
[ -z "$DEV" ] && DEV=$(read_prop ro.product.system.device)
MODEL=$(read_prop ro.product.model)
[ -z "$MODEL" ] && MODEL=$(read_prop ro.product.vendor.model)
[ -z "$MODEL" ] && MODEL=$(read_prop ro.product.system.model)
BRAND=$(read_prop ro.product.brand)
[ -z "$BRAND" ] && BRAND=$(read_prop ro.product.vendor.brand)

say " "
say "*****************************************"
say " V50 IMS + VoLTE —— 安装前校验"
say "*****************************************"
say " 设备代号 : ${DEV:-（读不到）}"
say " 型号     : ${MODEL:-（读不到）}"
say " 品牌     : ${BRAND:-（读不到）}"
say " 架构     : $ARCH"
say " "

# ---------------------------------------------------------------- 1. 架构
# 模块的 LG 库全在 lib64 下，只做 arm64。装到 32 位机上会得到一个半残的系统。
case "$ARCH" in
  arm64) : ;;
  *)
    fail "本模块只有 arm64 版 LG 库（lib64/），不支持 ARCH=$ARCH。已中止安装。
      This module ships arm64-only LG libraries; ARCH=$ARCH is not supported."
    ;;
esac

# ---------------------------------------------------------------- 2. 设备（硬校验）
# 接受 flashlm* 前缀，覆盖 flashlmdd（V50 ThinQ 5G）及其同系变体。
case "$DEV" in
  flashlm*)
    say " [OK] 设备匹配：$DEV"
    ;;
  "")
    say " [!!] 读不到设备代号（可能在 recovery 环境下安装）。"
    say "      无法校验，继续安装 —— 但请自行确认这是 LG V50 (flashlmdd)。"
    say "      建议改从 APatch / Magisk App 里安装，那样能读到属性。"
    ;;
  *)
    say " "
    fail "设备不匹配！本模块只适用于 LG V50 (flashlmdd)，当前设备是 '$DEV'。
      This module is ONLY for the LG V50 (codename flashlmdd); this device is '$DEV'.
      继续安装会把 LG 的 telephony 栈覆盖到这台机器上，可能导致无法开机。
      Refusing to install. Nothing has been written."
    ;;
esac

# ---------------------------------------------------------------- 3. 安卓版本（软校验）
API=$(read_prop ro.build.version.sdk)
case "$API" in
  34) say " [OK] Android 14 (API 34)" ;;
  "") say " [--] 读不到 API 等级，跳过版本检查" ;;
  *)  say " [!!] 本模块是针对 Pixel Experience 14 / API 34 开发的，当前 API $API。"
      say "      版本不同可能导致 telephony-common.jar 的桩方法对不上 —— 不会开不了机"
      say "      （有开机失败自动回退），但 IMS 很可能是坏的。自行决定是否继续。" ;;
esac

# ---------------------------------------------------------------- 4. Root 方案
# 脚本里写死了 /data/adb/ap/bin/{magiskpolicy,resetprop,busybox}（APatch 布局）。
# Magisk 下这些工具在 /data/adb/magisk/，工作不完全等价 —— 先提醒，不阻断。
if [ -x /data/adb/ap/bin/magiskpolicy ]; then
  say " [OK] 检测到 APatch"
elif [ -x /data/adb/magisk/magiskpolicy ]; then
  say " [!!] 检测到 Magisk 而非 APatch。"
  say "      本模块的 SELinux 规则依赖 APatch 的 /data/adb/ap/bin/magiskpolicy 与"
  say "      resetprop。Magisk 下这些路径不存在，SELinux 规则和 ro.* 属性强制写入"
  say "      会失败，IMS 大概率起不来。模块能装，但预期不可用。"
else
  say " [!!] 既没找到 /data/adb/ap/ 也没找到 /data/adb/magisk/ —— 没有 root？"
  say "      本模块必须配合 APatch 使用。"
fi

say " "
say "*****************************************"
say " 校验通过，开始安装"
say "*****************************************"
say " "

# ---------------------------------------------------------------- 5. 权限
#
#   v0.60 那个 zip 是【在 Windows 上打的包，没有存 unix 权限位】—— 实测 41 个条目
#   的外部属性高 16 位全是 0。于是文件权限完全取决于安装器的兜底默认值，而默认
#   文件模式通常是 0644。问题在于 service.sh 是这样判断的：
#       [ -x "$IS" ] || { log "  !! imsipsecstarter 不存在"; return 1; }
#   一旦它是 0644，这个 -x 就失败，IPSec 通道静默不启动，日志里只会显示"不存在"，
#   很难查。所以这里显式把该可执行的设成 0755 —— 不是冗余，是修一个潜伏 bug。
#
set_perm_recursive "$MODPATH" 0 0 0755 0644

# 模块脚本必须可执行
for f in post-fs-data.sh service.sh uninstall.sh; do
  [ -f "$MODPATH/$f" ] && set_perm "$MODPATH/$f" 0 0 0755
done

# LG 的两个常驻二进制必须可执行（service.sh 用 [ -x ] 判活）
for f in imsipsecstarter imsipsecclient; do
  p="$MODPATH/system/system_ext/bin/$f"
  if [ -f "$p" ]; then
    set_perm "$p" 0 0 0755
    say " [OK] $f -> 0755"
  else
    say " [!!] 缺少 system/system_ext/bin/$f —— 模块包不完整"
  fi
done

# ---------------------------------------------------------------- 6. 安全网状态复位
# .bootfail/.bootcur/.bootok 是 runtime 状态。全新安装必须清零，否则如果模块目录里
# 残带一个 .bootfail=2，装完第一次开机就会立刻把补丁 jar 回退掉，看起来像"没生效"。
rm -f "$MODPATH/.bootfail" "$MODPATH/.bootcur" "$MODPATH/.bootok" 2>/dev/null
say " [OK] 开机失败计数已清零（安全网重新计数）"
say " "

#!/system/bin/sh
# ============================================================================
# v50_soi_hal v0.3 — 安装期校验
#
# 这个模块只给 LG V50 (flashlmdd) + APatch + Pixel Experience 14 用。
# 装错机器不会立刻坏，但会往 /vendor 上叠 overlay；先在安装期拦住。
# 同时在安装时显式设置权限位（zip 权限位丢失是 v0.60 的真实坑）。
# ============================================================================

SKIPUNZIP=0

if ! command -v ui_print >/dev/null 2>&1; then
  ui_print() { echo "$1"; }
fi
say()  { ui_print "$1"; }
fail() { ui_print " "; ui_print "!! $1"; ui_print " "; abort "$1"; }

DEV=$(getprop ro.product.device 2>/dev/null)
[ -z "$DEV" ] && DEV=$(getprop ro.product.vendor.device 2>/dev/null)
MODEL=$(getprop ro.product.model 2>/dev/null)
[ -z "$MODEL" ] && MODEL=$(getprop ro.product.vendor.model 2>/dev/null)
[ -z "$ARCH" ] && ARCH=$(getprop ro.product.cpu.abi 2>/dev/null)

say "*****************************************"
say " V50 SOI HAL —— 安装前校验"
say "*****************************************"
say " 设备代号 : ${DEV:-（读不到）}"
say " 型号     : ${MODEL:-（读不到）}"
say " 架构     : ${ARCH:-（读不到）}"
say " "

case "$ARCH" in
  arm64|arm64-v8a) say " [OK] arm64" ;;
  "") say " [--] 读不到架构，跳过检查" ;;
  *) fail "本模块只有 arm64 HAL/库，不支持 ARCH=$ARCH。" ;;
esac

case "$DEV" in
  flashlm*) say " [OK] 设备匹配：$DEV" ;;
  "") say " [!!] 读不到设备代号（可能在 recovery 里安装）；请自行确认是 LG V50 (flashlmdd)。" ;;
  *) fail "设备不匹配！本模块只适用于 LG V50 (flashlmdd)，当前设备是 '$DEV'。已中止，未写入任何文件。" ;;
esac

if [ -x /data/adb/ap/bin/magiskpolicy ]; then
  say " [OK] 检测到 APatch"
elif [ -x /data/adb/magisk/magiskpolicy ]; then
  say " [!!] 检测到 Magisk。本模块按 APatch 的 /data/adb/ap/bin 布局编写，预期不可用。"
else
  say " [!!] 未找到 magiskpolicy —— 本模块必须配合 APatch 使用。"
fi

# ---------------------------------------------------------------- 权限
# 脚本 0755；HAL 二进制 0755；so/xml 0644。
set_perm_recursive "$MODPATH" 0 0 0755 0644
for f in post-fs-data.sh service.sh uninstall.sh; do
  [ -f "$MODPATH/$f" ] && set_perm "$MODPATH/$f" 0 0 0755
done
set_perm "$MODPATH/files/bin/vendor.lge.hardware.soi@1.0-service" 0 0 0755
say " [OK] 权限已设置（注册器 0755）"

# ---------------------------------------------------------------- 状态复位
# 全新安装时清掉旧的失败计数与 disable 标记，避免上一份模块留下的状态
# 让新装完的模块立刻被自动禁用。
mkdir -p /data/adb/v50_soi
echo 0 > /data/adb/v50_soi/fails
rm -f "$MODPATH/disable"
say " [OK] 失败计数已清零"
say " "

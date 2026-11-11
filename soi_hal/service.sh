#!/system/bin/sh
# v50_soi_hal v0.3
# 目标：把开机早期开销从 boot_completed 窗口里拿掉。
#  1) 23 条 SELinux 规则改成一次 `magiskpolicy --live --apply`（1 个进程，~0.1s）
#  2) 在 late_start 就把 SoI registrar 拉起来（早于 com.lge.ims 启动），
#     让 IMS 第一次启动就能拿到 ISoi，不再需要 `am force-stop` + `am start-service`
#  3) 完全不再等待 sys.boot_completed
#  4) watchdog：registrar 死亡后先等 ISoi 重新注册成功，再重启 IMS；
#     注册失败则不动 IMS，避免打断已经建立的 IPSec（测试 G 的坑）。
# 失败回退：cp service.sh.v02 service.sh && 重启
MODDIR=${0%/*}
D=/data/adb/v50_soi
LOG=/data/local/tmp/v50_soi.log
RLOG=/data/local/tmp/v50_soi_registrar.log
BIN="$MODDIR/files/bin/vendor.lge.hardware.soi@1.0-service"
mkdir -p $D
exec >> $LOG 2>&1
echo "=== service v0.3 $(date) uptime=$(cut -d' ' -f1 /proc/uptime) ==="

BOOTMODE=$(getprop ro.boot.mode)
case "$BOOTMODE" in
  pif_*|qem_*)
    echo "factory boot mode '$BOOTMODE' (cable detection): skip policy/registrar"
    exit 0 ;;
esac

# hwservicemanager 必须先在，才能注册 HAL（getprop 不产生进程，开销可忽略）
i=0
while [ "$(getprop init.svc.hwservicemanager)" != "running" ] && [ $i -lt 60 ]; do
  sleep 1; i=$((i + 1))
done
echo "hwservicemanager=$(getprop init.svc.hwservicemanager) after ${i}s"

MP=
for p in /data/adb/ap/bin/magiskpolicy /data/adb/magisk/magiskpolicy; do
  [ -x "$p" ] && { MP="$p"; break; }
done
[ -z "$MP" ] && MP=$(command -v magiskpolicy 2>/dev/null)
echo "magiskpolicy=$MP"

if [ -n "$MP" ] && [ -f "$MODDIR/soipolicy.txt" ]; then
  # --apply 按行解析，去掉注释和空行，避免解析器把 "#' 当语句
  CLEAN=$D/soipolicy.clean
  sed -e 's/\r$//' -e 's/#.*$//' -e 's/^[[:space:]]*$//' "$MODDIR/soipolicy.txt" \
    | grep -v '^$' > "$CLEAN"
  NS=$(date +%s%N)
  "$MP" --live --apply "$CLEAN"
  RC=$?
  NE=$(date +%s%N)
  if [ $RC -ne 0 ]; then
    echo "policy: --apply rc=$RC, falling back to per-line"
    OK=0; BAD=0
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      if "$MP" --live "$line"; then OK=$((OK + 1)); else BAD=$((BAD + 1)); echo "policy reject: $line"; fi
    done < "$CLEAN"
    echo "policy: per-line ok=$OK rejected=$BAD"
  else
    echo "policy: one-shot rc=$RC elapsed_ms=$(( (NE - NS) / 1000000 )) lines=$(wc -l < "$CLEAN")"
  fi
else
  echo "policy: skipped"
fi

echo "hooks:"
ls -lZ /vendor/lib64/vendor.lge.hardware.soi@1.0.so \
       /vendor/lib64/hw/vendor.lge.hardware.soi@1.0-impl.so \
       /vendor/etc/vintf/manifest/vendor.lge.hardware.soi.xml 2>&1

BB=/data/adb/ap/bin/busybox

start_registrar() {
  echo "starting $BIN at $(date)"
  : > $RLOG
  if [ -x "$BB" ]; then
    $BB setsid "$BIN" > $RLOG 2>&1 &
  else
    setsid "$BIN" > $RLOG 2>&1 &
  fi
}

# lshal 单次约 1s（实测），所以最多 12 次、每次间隔 1s ≈ 24s。
wait_soi() {
  n=0
  while [ "$n" -lt 12 ]; do
    if lshal 2>/dev/null | grep -qi 'vendor.lge.hardware.soi.*ISoi'; then
      echo "ISoi registered after ${n} extra polls"
      return 0
    fi
    sleep 1
    n=$((n + 1))
  done
  echo "ISoi NOT registered after ${n} polls"
  return 1
}

start_registrar
if wait_soi; then REGOK=1; else REGOK=0; fi
echo "registrar alive: $(ps -A 2>/dev/null | grep -v grep | grep -c 'vendor.lge.hardware.soi@1.0-service')"
echo "registrar domain: $(ps -Z 2>/dev/null | grep '[v]endor.lge.hardware.soi@1.0-service' | awk '{print $1}' | head -1)"
echo "lshal at $(date): $(lshal 2>/dev/null | grep -i 'vendor.lge.hardware.soi' | tr '\n' '|')"
echo "ims pid at registrar-ready: '$(pidof com.lge.ims)'"
echo "registrar ok: $REGOK"
echo "--- registrar log ---"; cat $RLOG

echo 0 > $D/fails
echo "service done at $(date); no boot_completed wait, no am calls"

restart_ims() {
  n=0
  while [ $n -lt 30 ]; do
    if grep -q '^com.lge.ims ' /data/system/packages.list 2>/dev/null; then break; fi
    sleep 2; n=$((n + 1))
  done
  if ! grep -q '^com.lge.ims ' /data/system/packages.list 2>/dev/null; then
    echo "com.lge.ims not in packages.list; skipping IMS restart"
    return
  fi
  am force-stop com.lge.ims
  sleep 2
  am start-service -n com.lge.ims/.server.ims.LGImsService
  sleep 3
  echo "IMS restarted at $(date) pid=$(pidof com.lge.ims)"
}

(
  LAST=0
  while true; do
    sleep 120
    if ! ps -A 2>/dev/null | grep -v grep | grep -q 'vendor.lge.hardware.soi@1.0-service'; then
      echo "watchdog: registrar dead at $(date)"
      start_registrar
      if wait_soi; then
        restart_ims
      else
        echo "watchdog: registrar failed to register ISoi; skip IMS restart to avoid breaking IPSec"
      fi
      LAST=$(date +%s)
      continue
    fi
    N=$(logcat -d -t 500 2>/dev/null | grep -c "Prev SMS_DELIVER is not processed yet")
    N=${N:-0}
    if [ "$N" -ge 3 ]; then
      NOW=$(date +%s)
      if [ $((NOW - LAST)) -gt 900 ]; then
        LAST=$NOW
        echo "watchdog: wedged SMS queue (n=$N) at $(date); restarting IMS"
        restart_ims
        sleep 60
      fi
    fi
  done
) &
echo "watchdog started"
exit 0

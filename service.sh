#!/system/bin/sh
# ============================================================================
# v0.27 service.sh
#   * 跑到 boot_completed 之后立刻给 post-fs-data 的"开机失败自动回退"打卡：
#     把本次 boot_id 写进 .bootok、把 .bootfail 清零。没跑到这里 = 上一次开机失败。
#   * 保留 v0.19 的 set-ims-service 重试循环（判定标准是 get-ims-service 能否读回
#     com.lge.ims，而不是命令返回值）。
#   * 保留 v0.20 从 post-fs-data 起的持续过滤抓取（v50ims_lg.txt）。
#   * 快照重点看 4 件事：
#       1. com.lge.ims.phone 这次注册了吗        （service list）
#       2. LGIMS_IPS 有没有 "LGImsPhoneService::create"（补丁有没有真的跑）
#       3. LGIMS_IPPM 的 bindService :: 拿到对象没有（proxy 通没通）
#       4. ApnImsGlobal 的 vops 还是不是 off      （VoLTE 条件）
# ============================================================================
MODDIR=${0%/*}
LOG=/data/local/tmp/v50ims.log
LG=/data/local/tmp/v50ims_lg.txt
PIDF=/data/local/tmp/v50ims_lg.pid
TMP=/data/local/tmp

log() { echo "$(date +%H:%M:%S) $*" >> $LOG; }

log "==================== service.sh 启动 (v0.57) ===================="
log "MODDIR=$MODDIR  SELinux=$(getenforce)  脚本域=$(id -Z 2>&1)"

i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 120 ]; do
    sleep 2; i=$((i+1))
done
log "boot_completed 等待 $i 轮"

# ---------------------------------------------------------------- v0.36 LG IPSec starter
BB=/data/adb/ap/bin/busybox
IS=/system/system_ext/bin/imsipsecstarter
ISLOG=/data/local/tmp/v50ims_ipsec.txt
ipsec_up() {
  [ -x "$IS" ] || { log "  !! imsipsecstarter 不存在: $IS"; return 1; }
  : > "$ISLOG" 2>/dev/null
  if [ -x "$BB" ]; then $BB setsid "$IS" >>"$ISLOG" 2>&1 & else "$IS" >>"$ISLOG" 2>&1 & fi
  return 0
}
ipsec_alive() { ps -A 2>/dev/null | grep -q '[i]msipsecstarter'; }

# v0.38: starter 用 ctl.start product.imsipsecclient 拉不起来它（rc 没被 init 解析），
# 所以这里直接执行那个二进制。stock rc 里 client 本就是 disabled、由 starter 拉起，
# 无 user 行（默认 root），本脚本同样以 root 起，身份匹配。
IC=/system/system_ext/bin/imsipsecclient
ICLOG=/data/local/tmp/v50ims_ipsec_c.txt
ipsec_client_up() {
  [ -x "$IC" ] || { log "  !! imsipsecclient 不存在: $IC"; return 1; }
  : > "$ICLOG" 2>/dev/null
  if [ -x "$BB" ]; then $BB setsid "$IC" >>"$ICLOG" 2>&1 & else "$IC" >>"$ICLOG" 2>&1 & fi
  return 0
}
ipsec_client_alive() { ps -A 2>/dev/null | grep -q '[i]msipsecclient'; }

ipsec_diag() {
  {
    echo "  ---- $1 ----"
    echo "    id            : $(id 2>&1)"
    echo "    本 ns         : $(readlink /proc/self/ns/mnt 2>&1)"
    echo "    init ns       : $(readlink /proc/1/ns/mnt 2>&1)"
    for d in /tmp /tmp/ims /tmp/ims/socket; do
      echo "    $d = $(ls -ld "$d" 2>&1)"
    done
    echo "    socket 内容   : $(ls -l /tmp/ims/socket/ 2>&1 | head -5)"
    echo "    进程          : $(ps -A 2>/dev/null | grep '[i]msipsec' | head -3)"
  } >> $LOG 2>&1
}

log "-- v0.36 LG IPSec starter --"
mkdir -p /tmp/ims/socket 2>/dev/null
ipsec_diag "启动前"
if ipsec_alive; then
  log "  imsipsecstarter 已在运行（post-fs-data 拉起的）"
else
  ipsec_up; sleep 3
  if ipsec_alive; then log "  imsipsecstarter 已拉起"; else log "  !! 拉起失败"; fi
fi
ipsec_diag "启动后"

# v0.38: 拉起 client（starter 已经在跑并 bind 了 ipsec_controller）
if ipsec_client_alive; then
  log "  imsipsecclient 已在运行"
else
  ipsec_client_up; sleep 3
  if ipsec_client_alive; then log "  imsipsecclient 已拉起"
  else log "  !! imsipsecclient 拉起失败"; fi
fi
log "  client stdout(前 12 行):"
head -12 "$ICLOG" 2>/dev/null | while read -r l; do log "    C| $l"; done

# DAC 路线：EACCES 无 avc 记录 => 大概率是 socket 文件权限
# com.lge.ims 是 uid 1001(radio)，写不进 magisk 域创建的这个 socket
# v0.36 这里是空操作（目录根本不存在）。现在 /tmp 由模块挂出来，先判断再放权限。
if [ -d /tmp/ims/socket ]; then
  chmod 777 /tmp/ims /tmp/ims/socket 2>/dev/null
  chmod 777 /tmp/ims/socket/* 2>/dev/null
  log "  chmod: $(ls -ld /tmp/ims/socket 2>&1)"
else
  log "  !! /tmp/ims/socket 仍不存在（模块的 system/tmp 没挂上？）"
fi
ipsec_diag "chmod 777 后"

log "  --- starter 自己的输出（最多 30 行，全量在 $ISLOG）---"
head -30 "$ISLOG" 2>/dev/null | while read -r l; do log "    | $l"; done

# keeper：掉了补拉，并持续把 socket 放开
(
  n=0
  while [ "$n" -lt 40 ]; do
    sleep 30; n=$((n+1))
    if ! ipsec_alive; then ipsec_up; sleep 3; log "  [keeper#$n] 重新拉起 starter"; fi
    [ -d /tmp/ims/socket ] && chmod 777 /tmp/ims/socket/* 2>/dev/null
  done
) &
log "  keeper 已启动 (每 30s，共 40 次)"

# ---------------------------------------------------------------- v0.44 日志自动搬运
# 把本次日志覆盖到 /sdcard，方便直接取（MTP / 文件管理器）。
# 优先 /sdcard，失败则退回 /data/media/0（/sdcard 的真身）。每 60s 同步一次，
# 这样拨号等后续操作产生的内容也会被带出去。
copy_logs() {
  for D in /sdcard /storage/emulated/0 /data/media/0; do
    [ -d "$D" ] || continue
    cp -f /data/local/tmp/v50ims.log            "$D/v50ims.log"            2>/dev/null
    cp -f /data/local/tmp/v50ims_lg.txt         "$D/v50ims_lg.txt"         2>/dev/null
    cp -f /data/local/tmp/v50ims_ipsec.txt      "$D/v50ims_ipsec.txt"      2>/dev/null
    cp -f /data/local/tmp/v50ims_ipsec_c.txt    "$D/v50ims_ipsec_c.txt"    2>/dev/null
    cp -f /data/local/tmp/v50ims_client_launch.txt "$D/v50ims_client_launch.txt" 2>/dev/null
    cp -f /data/local/tmp/v50ims_boot.txt       "$D/v50ims_boot.txt"       2>/dev/null
    chmod 666 "$D"/v50ims* 2>/dev/null
    chown media_rw:media_rw "$D"/v50ims* 2>/dev/null
    return 0
  done
  return 1
}
if copy_logs; then
  log "  日志已搬运到 /sdcard（v50ims*）"
else
  log "  !! 日志搬运失败（/sdcard 与 /data/media/0 都不可写）"
fi
(
  n=0
  while [ "$n" -lt 240 ]; do
    sleep 60; n=$((n+1))
    copy_logs
  done
) &
log "  日志同步循环已启动（每 60s，共 240 次）"

# ---------------------------------------------------------------- v0.40 client 拉起（方案 A）
# client 只有在 libims 已经 bind 了 ipsec_user 的窄窗口里才能握手成功；它失败即退出、不重试。
# starter 的 "Controller(Read) :: read bytes (4)" 正是 libims 发出 SPADD 的那一刻 —— 窗口开启信号。
# 所以两条通道并用：事件驱动（盯 logcat）+ 2 秒高频兜底（300 次约 10 分钟）。
CLILOG=/data/local/tmp/v50ims_client_launch.txt
: > $CLILOG 2>/dev/null
log "-- v0.40 client 拉起：事件驱动 + 2s 兜底 --"

# 通道 1：事件驱动
(
  logcat -b main -s IMSIPSECS 2>/dev/null | while read -r l; do
    case "$l" in
      *"Controller(Read)"*)
        ipsec_client_up
        echo "evt  $(date +%H:%M:%S)  starter 收到命令，已拉 client" >> $CLILOG 2>/dev/null
        ;;
    esac
  done
) &
log "  通道1（事件驱动，盯 IMSIPSECS 的 Controller(Read)）已启动"

# 通道 2：2 秒高频兜底
(
  n=0
  while [ "$n" -lt 300 ]; do
    if ! ipsec_client_alive; then
      ipsec_client_up
      n=$((n+1))
      echo "poll #$n  $(date +%H:%M:%S)" >> $CLILOG 2>/dev/null
    fi
    sleep 2
  done
  echo "poll 循环结束（300 次），此后由 30s keeper 看护" >> $CLILOG 2>/dev/null
) &
# ---------------------------------------------------------------- v0.48 sleep 自检
# v0.47 日志：标注"每 2s 兜底，共 300 次"的通道，300 次循环在 35 秒内跑完
# （poll #290..#299 落在同一秒内）。若 sleep 2 真的睡了，300 次应耗时 >=600 秒。
# 这里把根因钉死，不靠猜：报 PATH、sleep 的真实路径、以及一次 sleep 2 的实测耗时。
{
  echo "-- v0.48 sleep 自检 --"
  echo "  PATH=$PATH"
  echo "  command -v sleep -> $(command -v sleep 2>&1)"
  echo "  command -v date  -> $(command -v date 2>&1)"
  _t0=$(date +%s)
  sleep 2
  _t1=$(date +%s)
  echo "  sleep 2 实测耗时: $(( _t1 - _t0 )) 秒（期望 2；为 0 则 sleep 无效）"
} >> $LOG 2>&1

# ---------------------------------------------------------------- v0.49 最小闭包验证
# 判据：LGImsNetworkFeature 是否还在抛 NoClassDefFoundError，以及 vops 位是否变化。
{
  echo "-- v0.49 最小闭包验证 --"
  echo "  LGImsNetworkFeature 相关日志行数: $(grep -ac 'LGImsNetworkFeature' /data/local/tmp/v50ims_lg.txt 2>/dev/null)"
  echo "  NoClassDefFoundError 行数: $(grep -ac 'NoClassDefFoundError' /data/local/tmp/v50ims_lg.txt 2>/dev/null)"
  echo "  --- 最近 6 条 printCondition（看 vops 位）---"
  grep -a 'printCondition' /data/local/tmp/v50ims_lg.txt 2>/dev/null | tail -6 | sed 's/^/      | /'
  echo "  --- 有无 LGImsNetworkFeature 的 NoClassDefFoundError ---"
  grep -a 'LGImsNetworkFeature' /data/local/tmp/v50ims_lg.txt 2>/dev/null | grep -a 'NoClassDefFound\|ClassNotFound' | tail -4 | sed 's/^/      | /'
  echo "  --- jar 里这两个类在不在 ---"
  unzip -l /system/framework/telephony-common.jar 2>/dev/null | head -3 | sed 's/^/      | /'
} >> $LOG 2>&1

# ---------------------------------------------------------------- v0.51 运营商目标验证
{
  echo "-- v0.51 运营商目标验证 --"
  for k in ro.vendor.lge.build.target_operator ro.vendor.lge.build.target_country \
           ro.vendor.lge.build.target_region ro.vendor.lge.build.target_operator \
           ro.vendor.lge.opid ro.boot.vendor.lge.opid; do
    printf '     %-42s = [%s]\n' "$k" "$(getprop $k)"
  done
  echo "  --- LG 运营商判定输出（最近 10 条）---"
  grep -a 'SIMOperatorDetector\|OperatorInfo\|ImsPolicy' /data/local/tmp/v50ims_lg.txt 2>/dev/null | tail -10 | sed 's/^/      | /'
  echo "  --- isOperatorBasedOn / unknown / target 相关 ---"
  grep -a 'updateOperatorBasedOn\|setUnknownPolicy\|setOperatorInfo\|No Changed Operator' /data/local/tmp/v50ims_lg.txt 2>/dev/null | tail -8 | sed 's/^/      | /'
} >> $LOG 2>&1

# ---------------------------------------------------------------- v0.52 服务端实现验证
{
  echo "-- v0.52 服务端实现验证 --"
  echo "  bindService 相关:"
  grep -a 'LGIMS_IPPM\|LGImsPhoneService\|bindService' /data/local/tmp/v50ims_lg.txt 2>/dev/null | tail -6 | sed 's/^/      | /'
  echo "  printCondition 最近 4 条（看 vops 位）:"
  grep -a 'printCondition' /data/local/tmp/v50ims_lg.txt 2>/dev/null | tail -4 | sed 's/^/      | /'
  echo "  类解析异常:"
  for k in NoClassDefFound ClassNotFound NoSuchMethod AbstractMethod; do
    printf '      %-22s %s\n' "$k" "$(grep -ac "$k" /data/local/tmp/v50ims_lg.txt 2>/dev/null)"
  done
  echo "  jar 里有没有这两个实现类:"
  unzip -p /system/framework/telephony-common.jar classes.dex 2>/dev/null | strings -a | grep -c 'LGImsPhoneService\|LGImsPhoneProxy' | sed 's/^/      | 命中 /'
} >> $LOG 2>&1

# ---------------------------------------------------------------- v0.54 socket 路径验证
{
  echo "-- v0.54 socket 路径验证 --"
  echo "  socket 文件: $(ls -la /data/local/tmp/ipsec_* 2>&1 | head -6)"
  echo "  starter 进程: $(pgrep -f imsipsecstarter 2>/dev/null | tr '\n' ' ')"
  echo "  client  进程: $(pgrep -f imsipsecclient 2>/dev/null | tr '\n' ' ')"
  echo "  Connection refused 次数: $(grep -ac 'Connection refused' /data/local/tmp/v50ims_lg.txt 2>/dev/null)"
  echo "  --- IMSIPSEC/IMSIPSECC 最近 12 条 ---"
  grep -a 'IMSIPSEC' /data/local/tmp/v50ims_lg.txt 2>/dev/null | tail -12 | sed 's/^/      | /'
  echo "  --- IPsec 建立标志 ---"
  grep -a 'SA is established\|command succeeded\|SetPcscfPort\|AoSIPSec' /data/local/tmp/v50ims_lg.txt 2>/dev/null | tail -8 | sed 's/^/      | /'
  echo "  --- 注册状态 ---"
  grep -a 'ImsRegistration is null\|mRegistrationState\|getImsRegistrationTechnology' /data/local/tmp/v50ims_lg.txt 2>/dev/null | tail -6 | sed 's/^/      | /'
} >> $LOG 2>&1

log "  通道2（每 2s 兜底，共 300 次）已启动"

# ---------------------------------------------------------------- v0.39 CarrierConfig
# 症状：拨出请求发不出去、挂断卡住。v0.38 日志定位到 AOSP 侧 isVolteEnabled=false，
# 而 LG 侧 VoLTE 可用、provisioning 也不需要 —— 卡在 CarrierConfig 的
# carrier_volte_available_bool。手法照抄参考 repo（from-xml 优先，失败则逐条 set-value，
# 均带 -p 持久化），并把用户层的 volte_vt_enabled 一起打开。
CCXML=$MODDIR/carrier_volte_override.xml
{
  echo "-- v0.60 CarrierConfig --"
  echo "  XML: $(ls -l "$CCXML" 2>&1)"
  # PE14 用户版把 cmd phone cc 的权限收紧，root/radio/system 全报 Permission denied。
  # 这里三种身份都试一遍，失败也继续；VoLTE 主要靠 persist.dbg.volte_avail_ovr / LG IMS 配置激活。
  _cc_ok=0
  if [ -f "$CCXML" ]; then
    for _u in root radio system; do
      _ctx=$(su -s /system/bin/sh -c 'id' "$_u" 2>&1)
      _out=$(su -s /system/bin/sh -c 'cmd phone cc set-values-from-xml -p' "$_u" < "$CCXML" 2>&1)
      _rc=$?
      echo "  [$_u] $(_ctx) -> rc=$_rc : $_out"
      if [ "$_rc" -eq 0 ] && ! echo "$_out" | grep -qi 'permission\|denied\|fail'; then
        _cc_ok=1; echo "  set-values-from-xml : OK ($_u)"; break
      fi
    done
  fi
  if [ "$_cc_ok" -ne 1 ]; then
    echo "  set-values-from-xml 仍失败，逐条 set-value（预期同样受限）"
    for _k in carrier_volte_available_bool carrier_vt_available_bool carrier_wfc_ims_available_bool \
              carrier_supports_sms_over_ims_bool carrier_use_ims_first_for_sms_bool; do
      _v=true
      case "$_k" in carrier_supports_sms_over_ims_bool|carrier_use_ims_first_for_sms_bool) _v=false ;; esac
      _out=$(su -s /system/bin/sh -c "cmd phone cc set-value -p $_k $_v" radio 2>&1)
      echo "    $_k=$_v : $_out"
    done
  fi
  echo "  volte_vt_enabled(前) = $(settings get global volte_vt_enabled 2>&1)"
  if [ "$(settings get global volte_vt_enabled)" = "null" ]; then
    settings put global volte_vt_enabled 1
  fi
  echo "  volte_vt_enabled(后) = $(settings get global volte_vt_enabled 2>&1)"
} >> $LOG 2>&1
log "  CarrierConfig 已施加"

# ---------------------------------------------------------------- 打卡
BID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
LEDGER=/data/local/tmp/v50ims_boot.txt
CURJAR=$MODDIR/system/framework/telephony-common.jar
SYSJAR=/system/framework/telephony-common.jar
MSZ=$(ls -l "$CURJAR" 2>/dev/null | awk '{print $5}')
SSZ=$(ls -l "$SYSJAR" 2>/dev/null | awk '{print $5}')
if [ -n "$MSZ" ] && [ "$MSZ" = "$SSZ" ]; then
  MNT="覆盖生效（模块内=$MSZ，/system 下=$SSZ）"
elif [ -n "$MSZ" ]; then
  MNT="!! 覆盖【未】生效：模块内=$MSZ，/system 下=$SSZ —— 补丁不会起作用"
else
  MNT="模块内无 jar（已回退）；/system 下=$SSZ（原版）"
fi

if [ -n "$BID" ]; then
  echo "$BID" > "$MODDIR/.bootok" 2>/dev/null
  echo 0 > "$MODDIR/.bootfail" 2>/dev/null
  log "已标记本次开机成功 (boot_id=$BID)，失败计数清零"
  echo "$(date '+%m-%d %H:%M:%S') boot=$BID 开机成功，失败计数清零 | $MNT" >> "$LEDGER" 2>/dev/null
else
  log "!! 读不到 boot_id，自动回退的打卡没能完成"
  echo "$(date '+%m-%d %H:%M:%S') boot=(读不到) 开机成功但打卡失败 | $MNT" >> "$LEDGER" 2>/dev/null
fi
log "telephony-common.jar：$MNT"
log "开机台账: $LEDGER（只追加不轮转，最后 12 行）"
tail -12 "$LEDGER" 2>/dev/null | while read -r l; do log "    $l"; done

for p in ACCESS_COARSE_LOCATION ACCESS_FINE_LOCATION ACCESS_BACKGROUND_LOCATION; do
    pm grant --user 0 com.lge.ims android.permission.$p >> $LOG 2>&1
done
pm enable product.lge.data.server >> $LOG 2>&1
pm enable com.lge.ims >> $LOG 2>&1
log "权限与启用已完成"

# ---------------------------------------------------------------- 持续抓取守卫
FILTER='LGIMS|IMS\.|ImsWms|ImsResolver|ImsService|ImsFeature|ImsManager|ImsRegistration|ImsPhone|ImsProvisioning|ImsState|ImsConfig|FeatureConnector|FeatureConnection|TelephonyShellCommand|LGDataRuntimeFeature|LgData|LGData|Iwlan|Epdg|Mapcon|WifiQuality|avc:.*denied|FATAL EXCEPTION|AndroidRuntime|AbstractMethodError|NoSuchMethodError|NoClassDefFoundError|IncompatibleClassChange|service_manager_slow|GII-IMPL|Phone   : (getImsRegistrationTechnology|isImsCapabilityAvailable|isImsRegistered)|SST     : .*setImsRegistrationState'

alive=0
if [ -f "$PIDF" ]; then
  p=$(cat "$PIDF" 2>/dev/null)
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && alive=1
fi
if [ "$alive" -eq 1 ]; then
  log "持续抓取仍在运行 (pid=$(cat $PIDF))，已抓 $(wc -l < $LG 2>/dev/null) 行"
else
  log "!! post-fs-data 起的抓取没活下来，这里重新起一个（会丢掉之前那段！）"
  rm -f "$LG" "$PIDF" 2>/dev/null
  logcat -b all -v threadtime < /dev/null 2>/dev/null | grep -E "$FILTER" > "$LG" 2>&1 &
  echo $! > "$PIDF" 2>/dev/null
  log "   重启后 pid=$(cat $PIDF 2>/dev/null)"
fi

# ---------------------------------------------------------------- ImsService 覆盖
{
  echo
  echo "########## ImsService 覆盖（重试直到读回成功）  $(date +%H:%M:%S) ##########"
} >> $LOG 2>&1

ok=0
n=0
while [ "$n" -lt 24 ]; do
  s1=$(cmd phone ims set-ims-service -s 0 -c -f 1 com.lge.ims 2>&1)
  s2=$(cmd phone ims set-ims-service -s 0 -d -f 1 com.lge.ims 2>&1)
  s3=$(cmd phone ims set-ims-service -s 0 -c -f 0 com.lge.ims 2>&1)
  sleep 2
  g1=$(cmd phone ims get-ims-service -s 0 -c -f 1 2>&1)
  g2=$(cmd phone ims get-ims-service -s 0 -d -f 1 2>&1)
  {
    echo "  --- 第 $n 轮 ---"
    echo "    set -c -f 1 -> $s1"
    echo "    set -d -f 1 -> $s2"
    echo "    set -c -f 0 -> $s3"
    echo "    get -c -f 1 -> $g1"
    echo "    get -d -f 1 -> $g2"
  } >> $LOG 2>&1
  case "$g1" in
    *com.lge.ims*)
      log "  >>> 第 $n 轮读到 com.lge.ims，覆盖设置成功"
      ok=1
      break
      ;;
  esac
  n=$((n+1))
  sleep 2
done

if [ "$ok" -eq 0 ]; then
  log "  !! 24 轮重试后仍未读回 com.lge.ims，继续后面的诊断"
fi

# ---------------------------------------------------------------- 等引擎反应
log "覆盖设置结束，等待 130 秒让框架绑定、让 LG 引擎走完条件判定…"
sleep 130

# ---------------------------------------------------------------- 关键快照
{
  echo
  echo "########## 最终快照  $(date +%H:%M:%S) ##########"
  echo "-- 进程与域 --"
  ps -AZ 2>/dev/null | grep -E "lge|ims|phone"
  echo
  echo "== ★1：LG 的 binder 服务注册了吗 =="
  service list 2>&1 | grep -iE "lge|lgdata|ims"
  echo "   [service list 行数: $(service list 2>/dev/null | wc -l)]"
  echo
  echo "== ★2：补丁有没有真的跑（LGIMS_IPS = LGImsPhoneService）=="
  echo "   LGIMS_IPS 行数: $(grep -ac 'LGIMS_IPS' "$LG" 2>/dev/null)"
  grep -a 'LGIMS_IPS' "$LG" 2>/dev/null | head -20
  echo
  echo "== ★3：ImsPhoneProxyManager / ImsPhoneProxyApi =="
  echo "   LGIMS_IPPM 行数: $(grep -ac 'LGIMS_IPPM' "$LG" 2>/dev/null)"
  grep -a 'LGIMS_IPPM' "$LG" 2>/dev/null | head -25
  echo
  echo "== ★4：VoLTE 条件（vops 还在不在 off）=="
  grep -a 'printCondition' "$LG" 2>/dev/null | tail -6
  echo "   printCondition 总行数: $(grep -ac 'printCondition' "$LG" 2>/dev/null)"
  echo
  echo "== ★4b：v0.26 补丁生效了吗（LGIMS_VOPS = 从 ServiceState 读到的真值）=="
  echo "   LGIMS_VOPS 行数: $(grep -ac 'LGIMS_VOPS' "$LG" 2>/dev/null)"
  grep -a 'LGIMS_VOPS' "$LG" 2>/dev/null | tail -10
  echo "   --- modem 的原始 VoPS 上报（LteVopsSupportInfo：1=NOT_AVAILABLE 2=SUPPORTED 3=NOT_SUPPORTED）---"
  grep -ao 'mVopsSupport = [0-9]' "$LG" 2>/dev/null | sort | uniq -c
  echo "   --- WWAN PS 域注册状态 ---"
  echo "   --- ★4c：v27 诊断（com.lge.ims 实际看到的网络）---"
  echo "   LGIMS_V27 行数: $(grep -ac 'LGIMS_V27' "$LG" 2>/dev/null)"
  grep -a 'LGIMS_V27' "$LG" 2>/dev/null | tail -12
  echo "   --- IMS 网络的下发信息（lgdataservice 视角，含 P-CSCF）---"
  echo "   --- ★4d：v28 P-CSCF 真实现 ---"
  echo "   LGIMS_PCSCF 行数: $(grep -ac 'LGIMS_PCSCF' "$LG" 2>/dev/null)"
  grep -a 'LGIMS_PCSCF' "$LG" 2>/dev/null | tail -8
  echo "   Addresses is null = $(grep -ac 'Addresses is null' "$LG" 2>/dev/null)"
  echo "   No valid addresses = $(grep -ac 'No valid addresses' "$LG" 2>/dev/null)"
  echo "   Count of valid addresses:"
  grep -a 'Count of valid addresses' "$LG" 2>/dev/null | tail -3
  echo "   p-cscf is not configured = $(grep -ac 'p-cscf is not configured' "$LG" 2>/dev/null)"
  echo "   --- ★4e：v29 事件驱动 VoPS ---"
  echo "   VoPSRefresher 行数: $(grep -ac 'VoPSRefresher' "$LG" 2>/dev/null)"
  echo "   --- ★4f：v30 P-CSCF 失败分支（一次看出卡在哪步）---"
  for K in "mContext null" "getSystemService(ConnectivityManager) null" \
           "getAllNetworks() null" "no IMS-capable network" \
           "getLinkProperties() null" "getPcscfServers() null or empty" \
           "OK apnType=" ; do
    echo "      $K = $(grep -ac "FAIL: $K\|$K" "$LG" 2>/dev/null)"
  done
  grep -a 'LGIMS_PCSCF' "$LG" 2>/dev/null | tail -12
  echo "      nets total 行: $(grep -ac 'nets total=' "$LG" 2>/dev/null)"
  echo "      SKIP lp==null      = $(grep -ac 'SKIP lp==null' "$LG" 2>/dev/null)"
  echo "      SKIP pcscf-empty   = $(grep -ac 'SKIP pcscf-empty' "$LG" 2>/dev/null)"
  echo "      every skipped      = $(grep -ac 'every IMS-capable net skipped' "$LG" 2>/dev/null)"
  echo "      OK apnType         = $(grep -ac 'OK apnType=' "$LG" 2>/dev/null)"
  echo "   --- ★4g：v34 本进程直取 P-CSCF ---"
  grep -a 'LOCAL ' "$LG" 2>/dev/null | tail -18
  echo "      LOCAL OK nw=        = $(grep -ac 'LOCAL OK nw=' "$LG" 2>/dev/null)"
  echo "      LOCAL none          = $(grep -ac 'LOCAL none, fallback' "$LG" 2>/dev/null)"
  echo "   --- ★4h：v36 IPSec starter ---"
  echo "      进程数: $(ps -A 2>/dev/null | grep -c '[i]msipsec')"
  ps -A 2>/dev/null | grep '[i]msipsec' | head -4
  echo "      socket: $(ls -l /tmp/ims/socket/ 2>&1 | head -4)"
  echo "      SA failed     = $(grep -ac 'Creating SA failed' "$LG" 2>/dev/null)"
  echo "      ECONNREFUSED  = $(grep -ac 'Connection refused' "$LG" 2>/dev/null)"
  echo "      EACCES        = $(grep -ac 'Permission denied' "$LG" 2>/dev/null)"
  echo "      AuthChallenged= $(grep -ac 'ProcessAuthChallenged' "$LG" 2>/dev/null)"
  echo "      /tmp 结构      = $(ls -ld /tmp /tmp/ims /tmp/ims/socket 2>&1 | tr '\n' '|')"
  echo "      starter 域     = $(ps -Z 2>/dev/null | grep '[i]msipsecstarter' | awk '{print $1}')"
  echo "      com.lge.ims 域 = $(ps -Z 2>/dev/null | grep 'com.lge.ims$' | awk '{print $1}')"
  echo "      IMSIPSEC 日志  = $(grep -ac 'IMSIPSEC' "$LG" 2>/dev/null)"
  echo "      --- client(v0.57) ---"
  echo "      client 进程数  = $(ps -A 2>/dev/null | grep -c '[i]msipsecclient')"
  echo "      IMSIPSECC 日志 = $(grep -ac 'IMSIPSECC' "$LG" 2>/dev/null)"
  grep -a 'IMSIPSECC' "$LG" 2>/dev/null | tail -10 | sed 's/^/      | /'
  echo "      Proxy - start failed = $(grep -ac 'Proxy - start failed' "$LG" 2>/dev/null)"
  echo "      client stdout:"
  head -12 /data/local/tmp/v50ims_ipsec_c.txt 2>/dev/null | sed 's/^/      C| /'
  echo "   --- ★4i：v39 VolTE 判定（拨号能否走 IMS 就看这里）---"
  echo "      volte_vt_enabled = $(settings get global volte_vt_enabled 2>&1)"
  echo "      isVolteEnabled 最新值:"
  grep -a 'handleFeatureCapabilityChanged: isVolteEnabled' "$LG" 2>/dev/null | tail -3 | sed 's/^/      | /'
  echo "      getImsRegistrationTechnology:"
  grep -a 'getImsRegistrationTechnology' "$LG" 2>/dev/null | tail -3 | sed 's/^/      | /'
  echo "      carrier_config 里的 volte（dumpsys）:"
  dumpsys carrier_config 2>/dev/null | grep -i 'volte_available\|vt_available' | head -4 | sed 's/^/      | /'
  echo "      --- v0.41 VoLTE 平台判定 ---"
  echo "      persist.dbg.volte_avail_ovr = $(getprop persist.dbg.volte_avail_ovr)"
  echo "      persist.dbg.vt_avail_ovr    = $(getprop persist.dbg.vt_avail_ovr)"
  echo "      isVolteEnabled 最新 3 条:"
  grep -a 'handleFeatureCapabilityChanged: isVolteEnabled' "$LG" 2>/dev/null | tail -3 | sed 's/^/      | /'
  echo "      MmTel Capabilities 最新 2 条:"
  grep -a 'onCapabilitiesStatusChanged: MmTel Capabilities' "$LG" 2>/dev/null | tail -2 | sed 's/^/      | /'
  echo "      --- client 拉起统计(v0.57) ---"
  echo "      client 拉起次数 = $(grep -ac '^poll #\|^evt ' /data/local/tmp/v50ims_client_launch.txt 2>/dev/null)"
  echo "      其中事件驱动   = $(grep -ac '^evt ' /data/local/tmp/v50ims_client_launch.txt 2>/dev/null)"
  echo "      command succeeded = $(grep -ac 'command succeeded' "$LG" 2>/dev/null)"
  echo "      Sa is established = $(grep -ac 'Sa is established' "$LG" 2>/dev/null)"
  echo "      拉起记录（后 12 条）:"
  tail -12 /data/local/tmp/v50ims_client_launch.txt 2>/dev/null | sed 's/^/      | /'
  echo "      cc 应用日志:"
  sed -n '/v0.39 CarrierConfig/,/CarrierConfig 已施加/p' $LOG 2>/dev/null | tail -12 | sed 's/^/      | /'
  grep -a 'IMSIPSEC' "$LG" 2>/dev/null | tail -8 | sed 's/^/      | /'
  echo "      --- starter 自述 ---"
  head -20 /data/local/tmp/v50ims_ipsec.txt 2>/dev/null | sed 's/^/      | /'

  echo "      SKIP one IMS-capable net = $(grep -ac 'SKIP one IMS-capable net' "$LG" 2>/dev/null)"
  echo "      every IMS-capable net skipped = $(grep -ac 'every IMS-capable net skipped' "$LG" 2>/dev/null)"
  grep -a 'VoPSRefresher' "$LG" 2>/dev/null | tail -6
  grep -ao 'network=1[0-9][0-9] networkCapabilities=\[[^]]*\]' "$LG" 2>/dev/null | tail -3
  grep -ao 'PcscfAddresses: \[[^]]*\]' "$LG" 2>/dev/null | tail -2
  grep -ao 'transportType=WWAN registrationState=[A-Z_]*' "$LG" 2>/dev/null | sort | uniq -c
  echo
  echo "== ★5：注册相关 ==
   --- ★5d：v44 电话栈存活（补安全网盲区：开机成功但电话栈死它看不见）---
   echo "      IN_SERVICE       = $(grep -ac 'IN_SERVICE' "$LG" 2>/dev/null)"
   echo "      OUT_OF_SERVICE   = $(grep -ac 'OUT_OF_SERVICE' "$LG" 2>/dev/null)"
   echo "      RILJ 行数        = $(grep -ac 'RILJ' "$LG" 2>/dev/null)"
   echo "      IllegalAccess    = $(grep -ac 'IllegalAccessError' "$LG" 2>/dev/null)"
   echo "      LgeRIL 相关      = $(grep -ac 'LgeRIL\|LGRADIOFALCON\|LgeRadio' "$LG" 2>/dev/null)"
   echo "      --- 有无新的 IllegalAccessError / 崩溃 ---"
   grep -a 'IllegalAccessError\|FATAL EXCEPTION\|AndroidRuntime' "$LG" 2>/dev/null | tail -8 | sed 's/^/      | /'
   echo "      --- RILJ_EX / LgeRIL 尾部 ---"
   grep -a 'RILJ_EX\|LgeRIL\|LGRADIOFALCON' "$LG" 2>/dev/null | tail -10 | sed 's/^/      | /'

   --- ★5c：v43 LgeRIL 是否被实例化（本次改动唯一变量）---
   echo "      LgeRIL 相关日志:" > /dev/null
   grep -a 'LgeRIL\|LGRADIOFALCON\|LgeRadioIndication\|LgeRadioResponse' "$LG" 2>/dev/null | tail -15 | sed 's/^/      | /'
   echo "      RILJ 行数        = $(grep -ac 'RILJ' "$LG" 2>/dev/null)"
   echo "      RIL_IMS_EX 行数  = $(grep -ac 'RIL_IMS_EX' "$LG" 2>/dev/null)"
   echo "      RILC_EX 行数     = $(grep -ac 'RILC_EX' "$LG" 2>/dev/null)"
   echo "      --- 数据/语音基本功能是否正常 ---"
   echo "      IN_SERVICE 行数  = $(grep -ac 'IN_SERVICE' "$LG" 2>/dev/null)"
   echo "      OUT_OF_SERVICE   = $(grep -ac 'OUT_OF_SERVICE' "$LG" 2>/dev/null)"
   echo "      数据连接         = $(grep -ac 'onSetupDataNetwork\|DataConnection' "$LG" 2>/dev/null)"

   --- ★5b：v42 通话路径（拨号死在哪一层就看这里）---
   echo "      Telecom 行数   = $(grep -ac 'Telecom' "$LG" 2>/dev/null)"
   echo "      ImsCall 行数   = $(grep -ac 'ImsCall' "$LG" 2>/dev/null)"
   echo "      CallTracker 行 = $(grep -ac 'CallTracker' "$LG" 2>/dev/null)"
   echo "      RILJ 行数      = $(grep -ac 'RILJ' "$LG" 2>/dev/null)"
   echo "      --- Telecom 尾部 ---"
   grep -a 'Telecom\|CallsManager\|InCallController' "$LG" 2>/dev/null | tail -12 | sed 's/^/      | /'
   echo "      --- CallTracker 尾部 ---"
   grep -a 'CallTracker' "$LG" 2>/dev/null | tail -12 | sed 's/^/      | /'
"
  for k in "ImsRegistration" "getImsRegistrationTechnology" "registerMmTelCapability" "REGISTER"; do
    echo "   $k = $(grep -ac "$k" "$LG" 2>/dev/null)"
  done
  grep -aE 'getImsRegistrationTechnology|registerMmTelCapability|ImsRegistration is' "$LG" 2>/dev/null | tail -12
  echo
  echo "== ★6：致命异常 / 新增 avc =="
  grep -aE 'FATAL EXCEPTION|AbstractMethodError|NoSuchMethodError|NoClassDefFoundError|IncompatibleClassChange|verify error|VerifyError' "$LG" 2>/dev/null | head -15
  grep -a 'avc:.*denied' "$LG" 2>/dev/null | grep 'service_manager' | sed 's/.*denied *//' | sort | uniq -c | sort -rn | head -10
  echo
  echo "== ★7：LG 原生引擎跑到哪一步 =="
  grep -a 'LGIMS' "$LG" 2>/dev/null | grep -o 'IMS\.[A-Za-z.]*' | sort | uniq -c | sort -rn | head -20
  grep -a 'LGIMS   :' "$LG" 2>/dev/null | grep -avE "SoIClient|AndroidTimer|PlatformInterface.cpp:358" | tail -25
  echo
  echo "== 相关属性 =="
  getprop 2>/dev/null | grep -iE "ims|volte|vonr|iwlan|vops|log.tag" | head -30
  echo
  echo "== ★8：安全网状态（jar 覆盖是否生效 / 回退有没有发生）=="
  echo "   模块内 jar: $(ls -l "$CURJAR" 2>/dev/null | awk '{print $5}') 字节"
  echo "   /system 下 : $(ls -l "$SYSJAR" 2>/dev/null | awk '{print $5}') 字节"
  echo "   $MNT"
  echo "   计数文件 .bootfail = $(cat "$MODDIR/.bootfail" 2>/dev/null)"
  echo "   .bootcur = $(cat "$MODDIR/.bootcur" 2>/dev/null)"
  echo "   .bootok  = $(cat "$MODDIR/.bootok" 2>/dev/null)"
  echo "   $(ls -l "$MODDIR"/telephony-common.jar.disabled 2>/dev/null || echo '（没有 .disabled，说明没回退过）')"
  echo
  echo "== ★9：开机台账全文（跨开机保留，bootloop 复盘就靠它）=="
  cat "$LEDGER" 2>/dev/null || echo "   （台账不存在）"
  echo
  echo "== v50ims_lg.txt 行数 / 大小 =="
  wc -l < "$LG" 2>/dev/null
  ls -l "$LG" 2>/dev/null
} >> $LOG 2>&1

# ---------------------------------------------------------------- 停止抓取
if [ -f "$PIDF" ]; then
  kill "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null
  rm -f "$PIDF" 2>/dev/null
fi
sleep 1

{
  echo
  echo "==================== 诊断结束 ===================="
  echo "覆盖设置结果: $([ "$ok" -eq 1 ] && echo 成功 || echo 失败)"
  echo "★ 需要回传的文件（两个都要）:"
  echo "    /data/local/tmp/v50ims.log     本次脚本日志（本文件，已含 7 项关键摘要）"
  echo "    /data/local/tmp/v50ims_lg.txt  本次开机过滤后的完整 logcat（原始证据）"
  echo "  上一次开机: /data/local/tmp/v50ims_prev.log"
  echo "--- /data/local/tmp 里本项目相关文件 ---"
  ls -l $TMP/v50ims*.log $TMP/v50ims*.txt $TMP/v50ims*.pid 2>/dev/null
  echo "--- 模块目录状态（看 jar 还在不在 system/ 下）---"
  ls -l $MODDIR/system/framework/ 2>/dev/null
  ls -l $MODDIR/.bootcur $MODDIR/.bootok $MODDIR/.bootfail 2>/dev/null
} >> $LOG 2>&1

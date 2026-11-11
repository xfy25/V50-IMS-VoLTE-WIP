#!/system/bin/sh
# ============================================================================
# v0.27 —— 修 v0.26 的 post-fs-data 回归 + 给 Ims6 加网络可见性诊断
#
#   v0.24 只补了 CommandsInterface 的 65 个，结果 LGImsPhoneProxy.start() 从 301 行
#   往前走到 312 行，撞上 ServiceStateTracker.addImsNetworkInfoListener 又停了。
#   根因是我的分类标准错了：我按【目标类】猜"像不像 IMS 相关"，
#   而正确的标准是【调用方】—— LGImsPhoneProxy.start() 调它，它就在路径上。
#
#   这次不猜了：凡是【目标类在 telephony-common 里】的缺失方法，全部补空实现。
#     - telephony-common 内: 16 个类 / 125 个方法  -> 本版补
#     - 其他框架 jar 内:     17 个类 /  34 个方法  -> 不补（见 LATENT_DRIFT.txt，
#       调用方都是 LG 自己的 RIL/UICC/systemservice，PE 的框架不会调用到）
#
#   返回类型按类型给安全默认值（void/0/null），PE 自己从不调用这些名字，
#   所以对 PE 是惰性的；只有 classes2.dex 里的 LG 代码会走到。
#
#
#   v0.23 日志：com.lge.ims.phone 注册成功（service list 里有了），
#   LGImsPhoneService.create -> init -> new LGImsPhoneProxy -> start 之后抛
#       NoSuchMethodError: No interface method registerSsacState(...)
#       in class Lcom/android/internal/telephony/CommandsInterface;
#
#   这不是一个孤立的坑 —— 离线把 1546 个 LG 桥接类对 PE 框架的调用全扫了一遍
#   （真值 = 我们自己从 PE 的 telephony-common.jar / framework.jar / services.jar /
#     libcore(apex) 反编译出来的 54239 个类，先过 5 项阳性对照）：
#       确定缺失 159 个方法，分布在 33 个目标类
#       其中 65 个在 CommandsInterface 上，调用方正是
#       LGImsPhoneProxy / LGImsPhoneProxy$PhoneProxyBinder / LGImsPhoneProxy$ImsVoNR
#     这 65 个全是 void，所以本版给 PE 的 CommandsInterface 补 65 个空实现
#     （default method）—— 一个地方解决，LG 侧一行都不用改。
#
#   机制可行性已证：PE 自己的 CommandsInterface 里本来就有 default method
#   （AOSP 13+ 的 addAllowedSatelliteContacts），不是我们在赌。
#
#   不在 IMS 注册路径上的其余 94 个（Phone 16 / GsmCdmaPhone 10 /
#   SubscriptionController 8 / GsmAlphabet 6 / RIL 6 / SignalStrength 5 / …
#   以及 android/telephony、android/os、android/app 下的十来个）本版【不补】，
#   完整清单在模块根目录的 LATENT_DRIFT.txt 里，写明调用方。
#
#
#   v0.23 只加了一条规则：allow radio default_android_service service_manager { add }
#     v0.22 日志：LGImsPhoneService::create 已经跑起来了（classes2.dex 上 boot classpath 成功，
#     NoClassDefFoundError 消失），调用链走到
#       PhoneGlobals.onCreate -> PhoneFactory.makeDefaultPhones -> LGImsPhoneService.create
#       -> getInstance -> ServiceManager.addService
#     之后抛 SecurityException: SELinux denied。全开机唯一一条 service_manager 拒绝就是它：
#       { add } for name=com.lge.ims.phone scontext=u:r:radio:s0
#       tcontext=u:object_r:default_android_service:s0
#     因为 PE 的 service_contexts 没有 com.lge.ims.phone 条目 -> 落到通配符
#     default_android_service，而 radio 域只有 (allow radio radio_service (service_manager (add find)))。
#
#   同域 binder（com.android.phone 与 com.lge.ims 都是 radio）【不用】加规则：
#     PE 自带 (allow appdomain appdomain (binder (call transfer)))，而 radio 是 appdomain 成员。
#   同理 appdomain 层面没有任何 service_manager 规则，所以 default_android_service 的
#   add/find 只能自己加 —— 这次是先枚举完整权限矩阵再动手，不是看到 AVC 才补。
#
# 【为什么必须打这一刀】两端都有实证，不是推测：
#
#   原厂 A12 的 PhoneFactory.makeDefaultPhone() 末尾有：
#       if (com.android.ims.ImsFeatureProvider.hasLgeFeatureIms()) {
#           LGImsPhoneService.create(context, PhoneFactory.sPhones,
#                                    PhoneFactory.sCommandsInterfaces);
#       }
#   PE14 完全没有：
#     - telephony-common.jar / framework.jar / services.jar 里
#       LGImsPhoneService、ImsFeatureProvider、hasLgeFeatureIms、ImsSmsService 全部 = 0
#     - PE 的 makeDefaultPhones 只是一行 invoke-static makeDefaultPhone
#     - 全盘只有 LGImsPhoneService 自己含字符串 "com.lge.ims.phone"
#     => 我们注入了 1592 个类，却没把调用点注进去，com.lge.ims.phone 从来没注册过。
#
#   v0.20 设备实测（持续抓取 + log.tag.LGIMS=D）：
#       LGIMS_IPPM: bindService :: null          ImsPhoneProxyManager 拿到 null
#       [LGIMS_IPS 总行数: 0]                     create() 从没被调用
#       service list 里没有 com.lge.ims.phone
#       [ApnImsGlobal::printCondition] vops=off   VoLTE 条件 2/7 不满足
#
#   完整因果链：
#       PhoneFactory 缺钩子
#         -> LGImsPhoneService.create() 不执行
#         -> binder 服务 com.lge.ims.phone 不注册
#         -> ImsPhoneProxyManager.getPhoneProxy(0) = null
#         -> 29 个类静默降级（ImsPhoneProxyApi 每个调用点都是 if-eqz -> return null）
#             其中 IIMSPhoneGov$IImsPhone.mPhoneProxy = null
#               -> registerForLteVoPSChanged 永远收不到通知
#               -> DCNetWatcher.mIMSVoPS = false
#               -> ApnImsGlobal 条件位 VOLTE_VoPS_ON(0x4) 恒不置位
#               -> printCondition 打出 vops=off
#         -> 不发 SIP REGISTER
#
# 【插入点是怎么选定的】
#   PE 的 makeDefaultPhones(Context) 只有一行委托调用，是理想插入点。
#   调用方在 priv-app/TeleService/TeleService.apk（不是 framework jar，所以先在
#   framework jar 里搜不到是正常的，别被误导）：
#       com/android/phone/PhoneGlobals.smali:1984
#       invoke-static {p0}, Lcom/android/internal/telephony/PhoneFactory;->makeDefaultPhones(...)V
#   补丁插在 makeDefaultPhone() 之后，此时 sPhones / sCommandsInterfaces 已填好。
#
# 【时序前提（已核对 v0.20 日志时间线）】
#   补丁在 makeDefaultPhone() 里跑，约 21:15:16（ImsResolver 初始化同期）；
#   LG IMS 应用 21:15:15.7 第一次拿 proxy 会失败，但 LGImsPhoneService.init() 会发
#   com.lge.ims.action.IMS_PHONE_STARTED 广播，ImsPhoneProxyManager 注册了这个广播，
#   收到后重连；而 IIMSPhoneGov$IImsPhone 要到 21:15:19 之后（VoLTE service 起来时）
#   才构造，所以它构造时 proxy 已经有效。
#   注意 IImsPhone.mPhoneProxy 是 final、只在构造时取一次，之后不刷新 —— 这个先后顺序
#   是本方案成立的前提。
#
# 【安全网】telephony-common.jar 在 boot classpath 上，由 system_server 自己加载，
#   改坏了会 bootloop。所以：
#     - 补丁只动 makeDefaultPhones 这一个 6 行方法，带 sPhones 非空判断 + catchall 兜底，
#       任何异常只记一条 Log.w，绝不影响电话初始化；
#     - 连续 2 次判定"上次开机没走完"，就把这个 jar 从模块的 system/ 下移走 ——
#       magic mount 不再覆盖，下一轮开机自动回到原版。
#     - 救急也可以直接用 APatch 安全模式（音量键）禁用全部模块。
# ============================================================================
MODDIR=${0%/*}
LOG=/data/local/tmp/v50ims.log
PREV=/data/local/tmp/v50ims_prev.log
LG=/data/local/tmp/v50ims_lg.txt
PIDF=/data/local/tmp/v50ims_lg.pid
MP=/data/adb/ap/bin/magiskpolicy
RP=/data/adb/ap/bin/resetprop
TMP=/data/local/tmp
CURJAR=$MODDIR/system/framework/telephony-common.jar
DISJAR=$MODDIR/telephony-common.jar.disabled

# ---------------------------------------------------------------- 日志清理
rm -f "$PREV" 2>/dev/null
[ -f "$LOG" ] && mv -f "$LOG" "$PREV" 2>/dev/null

rm -f "$TMP"/v50ims_lc.txt "$TMP"/v50ims_lc_prev.txt \
      "$TMP"/v50ims_lcA.txt "$TMP"/v50ims_lcB.txt \
      "$TMP"/v50ims_cmd.txt "$TMP"/lc_*.txt "$TMP"/v50ims_lc_last.txt 2>/dev/null

# ---------------------------------------------------------------- 开机失败自动回退
# 判据：post-fs-data 把本次 boot_id 记到 .bootcur；service.sh 只有在 sys.boot_completed=1
# 之后才把同一个 boot_id 写进 .bootok。于是 .bootcur != .bootok 就说明"上一次开机没走完"。
# 连续 2 次判定失败 -> 把补丁 jar 移出 system/（下一次开机的 magic mount 就不再覆盖它）。
BID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
[ -z "$BID" ] && BID="(读不到)"
PREVID=$(cat "$MODDIR/.bootcur" 2>/dev/null)
OKID=$(cat "$MODDIR/.bootok" 2>/dev/null)
CNT=$(cat "$MODDIR/.bootfail" 2>/dev/null)
case "$CNT" in ''|*[!0-9]*) CNT=0 ;; esac

if [ -n "$PREVID" ] && [ "$PREVID" != "$OKID" ]; then
  CNT=$((CNT+1)); FAILNOTE="上一次开机 boot_id=${PREVID} 没走完（service.sh 没到 boot_completed）"
else
  CNT=0; FAILNOTE="上一次开机正常"
fi
echo "$CNT" > "$MODDIR/.bootfail" 2>/dev/null
echo "$BID" > "$MODDIR/.bootcur" 2>/dev/null

# 回退动作 —— 成功/失败/不需要 三种结果都要明确写出来，失败时带上 mv 的原话
REVERT="未触发（计数 $CNT < 阈值 2）"
if [ "$CNT" -ge 2 ]; then
  if [ ! -f "$CURJAR" ]; then
    REVERT="不需要回退（system/ 下已经没有补丁 jar 了）"
  else
    ERR=$(mv -f "$CURJAR" "$DISJAR" 2>&1); RC=$?
    if [ "$RC" -eq 0 ]; then
      REVERT="已回退：补丁 jar 已移到 $DISJAR（下一次开机 magic mount 不再覆盖，恢复原版）"
    else
      REVERT="!! 回退失败 rc=$RC：$ERR"
    fi
  fi
fi

if [ -f "$CURJAR" ]; then JARSTATE="模块内有补丁 jar"
else JARSTATE="模块内没有补丁 jar（已回退或未安装）"; fi

# 验证 magic mount 到底有没有把 /system/framework/telephony-common.jar 换成模块里这份。
# 如果没换成，补丁是静默不工作的 —— 这种情况必须一眼看出来。
SYSJAR=/system/framework/telephony-common.jar
MSZ=$(ls -l "$CURJAR" 2>/dev/null | awk '{print $5}')
SSZ=$(ls -l "$SYSJAR" 2>/dev/null | awk '{print $5}')
if [ -n "$MSZ" ] && [ "$MSZ" = "$SSZ" ]; then
  MOUNTSTATE="覆盖生效（模块内=$MSZ，/system 下=$SSZ）"
elif [ -n "$MSZ" ]; then
  MOUNTSTATE="!! 覆盖【未】生效：模块内=$MSZ，/system 下=$SSZ —— 补丁不会起作用"
else
  MOUNTSTATE="模块内无 jar；/system 下=$SSZ（原版）"
fi

# 只追加、不轮转的开机台账 —— v50ims.log 每次开机只留一代，bootloop 时最该看的那几轮
# 会被冲掉；这份台账每行一次开机，专门用来事后复盘安全网干过什么。
LEDGER=/data/local/tmp/v50ims_boot.txt
echo "$(date '+%m-%d %H:%M:%S') boot=$BID cnt=$CNT prev=$PREVID ok=$OKID | $REVERT | $MOUNTSTATE | $FAILNOTE" >> "$LEDGER" 2>/dev/null

# ---------------------------------------------------------------- 放开 LG Java 日志
# com.lge.ims.log.Log 的 d/w/i/e 是无条件写 logcat 的，dc/vc 走
# Log.isLoggable("LGIMS", 3) —— 设 log.tag.LGIMS=D 就能把 ImsPhoneProxyManager 的
# "bindService :: <值>" 打出来。只影响日志详细度。
[ -x "$RP" ] && "$RP" log.tag.LGIMS D 2>&1
LOGTAG=$([ -x "$RP" ] && "$RP" log.tag.LGIMS 2>/dev/null)

{
  echo "==================== post-fs-data $(date +%H:%M:%S) ===================="
  echo "模块版本: $(grep '^version=' $MODDIR/module.prop 2>/dev/null | cut -d= -f2)  (versionCode=$(grep '^versionCode=' $MODDIR/module.prop 2>/dev/null | cut -d= -f2))"
  echo "本次开机的日志起点。上一次开机的日志在 ${PREV}（只保留一代）。"
  echo "SELinux: $(getenforce)"
  echo "-- telephony-common.jar / 安全网 --"
  echo "   $JARSTATE"
  echo "   $MOUNTSTATE"
  echo "   回退动作: $REVERT"
  echo "-- 开机失败计数 --"
  echo "   boot_id(本次)=$BID"
  echo "   boot_id(上次记录)=$PREVID   boot_id(上次成功)=$OKID"
  echo "   $FAILNOTE"
  echo "   连续失败计数=$CNT / 阈值 2"
  echo "-- 开机台账（只追加不轮转，最后 12 行）--"
  tail -12 "$LEDGER" 2>/dev/null
  echo "log.tag.LGIMS = ${LOGTAG}"
  echo "-- PE 的 system_ext_service_contexts 里有没有 LG 的服务（预期：没有）--"
  grep -nE "ims|lgdata|lge" /system/system_ext/etc/selinux/system_ext_service_contexts 2>&1 | head -5
  echo "-- PE 的 plat_service_contexts 通配符 --"
  grep -n 'default_android_service' /system/etc/selinux/plat_service_contexts 2>&1 | head -3
  echo "-- 关键属性在 PE 里的类型 --"
  grep -nE "^(net\.|persist\.net)" /system/etc/selinux/plat_property_contexts 2>&1 | head -8
} >> $LOG 2>&1

# 0.7 的 seapp 覆盖遗留的错误标签清理（0.8 起已移除覆盖文件，这行只为兼容旧数据）
D=/data/user_de/0/product.lge.data.server
{
  if [ -e "$D" ]; then
    cur=$(ls -Zd "$D" 2>/dev/null | awk '{print $1}')
    echo "-- 数据目录标签: $cur"
    case "$cur" in
      *app_data_file*) echo "   正常，保留" ;;
      *) rm -rf "$D" 2>>$LOG && echo "   已删除旧目录，将按 app_data_file 重建" \
                             || echo "   !! rm 失败" ;;
    esac
  else
    echo "-- 数据目录不存在（正常）"
  fi
} >> $LOG 2>&1

# ---------------------------------------------------------------- v0.41 VoLTE 平台判定开关
# ims-common.jar 里 com.android.ims.ImsManager.isVolteEnabledByPlatform() 的第一条就是：
#     SystemProperties.getInt("persist.dbg.volte_avail_ovr" + mPhoneId, -1) == 1 -> true
#     SystemProperties.getInt("persist.dbg.volte_avail_ovr", -1) == 1 -> true
# 默认 -1（不生效），显式设 1 才短路后面三道门（框架资源 / carrier_volte_available_bool / isGbaValid）。
# 本机症状：video=true 而 voice=false —— 正是框架资源 0x111011f(volte)=false、0x1110120(vt)=true。
RP=/data/adb/ap/bin/resetprop
{
  echo "-- v0.41 VoLTE 平台判定开关 --"
  if [ -x "$RP" ]; then
    echo "  resetprop 前: volte_ovr=$(getprop persist.dbg.volte_avail_ovr) vt_ovr=$(getprop persist.dbg.vt_avail_ovr)"
    $RP persist.dbg.volte_avail_ovr 1
    $RP persist.dbg.vt_avail_ovr 1
    # 参考 repo 是在 post-fs-data 里用 resetprop 设这一条（不在 system.prop）；
    # 本模块 system.prop 里也有同一条，但通道不同，这里按参考的做法再设一遍（幂等）。
    $RP persist.product.lge.ims.volte_open 1
    echo "  resetprop 后: volte_ovr=$(getprop persist.dbg.volte_avail_ovr) vt_ovr=$(getprop persist.dbg.vt_avail_ovr) volte_open=$(getprop persist.product.lge.ims.volte_open)"
  else
    echo "  !! $RP 不存在，改用 setprop"
    setprop persist.dbg.volte_avail_ovr 1
    setprop persist.dbg.vt_avail_ovr 1
    setprop persist.product.lge.ims.volte_open 1
    echo "  setprop 后: volte_ovr=$(getprop persist.dbg.volte_avail_ovr) vt_ovr=$(getprop persist.dbg.vt_avail_ovr)"
  fi
} >> $LOG 2>&1

# ---------------------------------------------------------------- v0.51 IMS 运营商目标
# ImsProperties 读这三个属性决定 target operator/country/region。
# 原厂这三个值由 product/op 分区提供，PE 不带那两个分区，所以设备上它们是空的
# （ro.vendor.lge.build.target_region 还出现在 libc 的 Access denied 名单里）。
# 实机日志显示 LG 的运营商判定因此落到 setUnknownPolicy(0/OPEN/CN/target/operator)。
# 用户确认 OPEN/CN 是其本人在 stock 上配置过、且 stock 下 VoLTE 可用的参数。
# system.prop 通道之外再 resetprop 一遍：ro.* 是只读属性，靠 resetprop 强写才生效。
RP2=/data/adb/ap/bin/resetprop
{
  echo "-- v0.51 IMS target operator/country/region --"
  if [ -x "$RP2" ]; then
    for kv in ro.vendor.lge.build.target_operator=OPEN \
              ro.vendor.lge.build.target_country=CN \
              ro.vendor.lge.build.target_region=CN; do
      k=${kv%%=*}; v=${kv#*=}
      $RP2 "$k" "$v"
      echo "  set $k=$v -> 读回: $(getprop $k)"
    done
  else
    echo "  !! resetprop 不存在，改用 setprop（ro.* 可能失败）"
    for kv in ro.vendor.lge.build.target_operator=OPEN \
              ro.vendor.lge.build.target_country=CN \
              ro.vendor.lge.build.target_region=CN; do
      k=${kv%%=*}; v=${kv#*=}
      setprop "$k" "$v" 2>/dev/null
      echo "  set $k=$v -> 读回: $(getprop $k)"
    done
  fi
} >> $LOG 2>&1

# ---------------------------------------------------------------- v0.54 IPSec socket 路径
# 三方硬编码的 socket 路径已在本版一起等长改为 /data/local/tmp/...：
#   imsipsecstarter              bind  /data/local/tmp/ipsec_controller
#   imsipsecclient               bind  /data/local/tmp/ipsec_proxy
#                                send→ /data/local/tmp/ipsec_user
#   libims.lge.so (com.lge.ims)  bind  /data/local/tmp/ipsec_user
# 原因：/ 是只读 ext4、/tmp 不存在，且原厂与 PE 的 rc 里没有任何一条创建 /tmp/ims/socket，
# 两个二进制自身也没有 mkdir —— 所以那个目录在本机永远不存在。
# （v0.53 只改了前两个、漏了 libims.lge.so，已作废。）
{
  echo "-- v0.54 IPSec socket 路径 --"
  echo "  /tmp: $(ls -ld /tmp 2>&1 | head -1)"
  echo "  /data/local/tmp: $(ls -ld /data/local/tmp 2>&1 | head -1)"
  rm -f /data/local/tmp/ipsec_controller /data/local/tmp/ipsec_proxy /data/local/tmp/ipsec_user 2>/dev/null
  echo "  三方二进制里的路径:"
  for f in /system/system_ext/bin/imsipsecstarter /system/system_ext/bin/imsipsecclient            /system/system_ext/lib64/libims.lge.so; do
    printf '    %-40s %s\n' "$(basename $f)" \
      "$(strings -a $f 2>/dev/null | grep -a 'ipsec_controller\|ipsec_proxy\|ipsec_user' | tr '\n' ' ')"
  done
} >> $LOG 2>&1

# ---------------------------------------------------------------- SELinux 规则
if [ -x "$MP" ]; then
  echo "-- SELinux 规则 --" >> $LOG
  # v0.62: 一次 --apply（实测 64 条逐条 1695 ms -> 一次 113 ms）。
  # 同时删掉 live policy 里不存在的类型的规则：APatch magiskpolicy 对未知类型
  # 静默丢弃（rc=0 但规则不生效），留着只会制造假阳性。
  POL=$TMP/v50ims_policy.txt
  : > "$POL"
  for r in \
    "allow radio vendor_lge_misc_prop file { read open getattr map }" \
    "allow radio system_data_file dir { getattr search }" \
    "allow radio default_prop property_service { set }" \
    "allow radio system_prop property_service { set }" \
    "allow radio op_file dir { search read open getattr }" \
    "allow radio op_file file { read open getattr map }" \
    "allow radio default_android_hwservice hwservice_manager { find }" \
    "allow radio hal_vss_ims_hwservice hwservice_manager { find }" \
    "allow radio hal_vss_ims_default binder { call transfer }" \
    "allow hal_vss_ims_default radio binder { call transfer }" \
    "allow radio hal_vss_ims_default fd { use }" \
    "allow vendor_dataservice_app vendor_lge_misc_prop file { read open getattr map }" \
    "allow vendor_dataservice_app default_prop property_service { set }" \
    "allow vendor_dataservice_app system_prop property_service { set }" \
    "allow vendor_dataservice_app app_data_file dir { getattr search read open write add_name remove_name create }" \
    "allow vendor_dataservice_app app_data_file file { getattr read write open create unlink rename }" \
    "allow vendor_dataservice_app hal_lgdata_hwservice hwservice_manager { find }" \
    "allow vendor_dataservice_app hal_lgdata_default binder { call transfer }" \
    "allow hal_lgdata_default vendor_dataservice_app binder { call transfer }" \
    "allow vendor_dataservice_app hal_lgdata_default fd { use }" \
    "allow hal_lgdata_default vendor_dataservice_app fd { use }" \
  "allow hal_lgdata_default hal_lgdata_default qipcrtr_socket { getattr read write setopt }" \
    "allow radio magisk unix_dgram_socket { sendto }" \
    "allow magisk radio unix_dgram_socket { sendto }" \
    "allow radio magisk unix_stream_socket { connectto }" \
    "allow magisk radio unix_stream_socket { connectto }" \
    "typeattribute magisk mlstrustedsubject" \
    "allow platform_app vendor_lge_misc_prop file { read open getattr map }" \
    "allow platform_app default_prop property_service { set }" \
    "allow platform_app system_prop property_service { set }" \
    "allow platform_app op_file dir { search read open getattr }" \
    "allow platform_app op_file file { read open getattr map }" \
    "allow platform_app app_data_file dir { getattr search read open write add_name remove_name create }" \
    "allow platform_app app_data_file file { getattr read write open create unlink rename }" \
    "allow platform_app radio_data_file dir { getattr search read open write add_name remove_name create }" \
    "allow platform_app radio_data_file file { getattr read write open create unlink rename }" \
    "allow platform_app hal_lgdata_hwservice hwservice_manager { find }" \
    "allow platform_app hal_lgdata_default binder { call transfer }" \
    "allow radio default_android_service service_manager { find }" \
    "allow platform_app default_android_service service_manager { find }" \
    "allow system_server default_android_service service_manager { find }" \
    "allow radio default_android_service binder { call transfer }" \
    "allow platform_app default_android_service binder { call transfer }" \
    "allow system_server default_android_service binder { call transfer }" \
    "allow radio default_android_service service_manager { add }" \
    "allow magisk service_manager_type service_manager { find }" \
    "allow magisk service_manager_type service_manager { list }" \
    "allow magisk system_file file { read open getattr map execute execute_no_trans }" \
    "allow magisk tmpfs file { read write open create getattr unlink }" \
    "allow magisk tmpfs dir { read write open getattr add_name remove_name search }" \
    "allow magisk shell_data_file dir { read write open getattr add_name remove_name search }" \
    "allow magisk shell_data_file file { read write open create getattr unlink }" \
    ; do
    echo "$r" >> "$POL"
  done
  T0=$(date +%s%N)
  "$MP" --live --apply "$POL"
  RC=$?
  T1=$(date +%s%N)
  if [ "$RC" -eq 0 ]; then
    echo "  policy: one-shot rc=0 elapsed_ms=$(( (T1 - T0) / 1000000 )) lines=$(wc -l < "$POL")" >> $LOG
  else
    echo "  policy: one-shot rc=$RC, falling back to per-line" >> $LOG
    OK=0; BAD=0
    while IFS= read -r r; do
      [ -z "$r" ] && continue
      out=$($MP --live "$r" 2>&1); rc=$?
      if [ "$rc" -eq 0 ]; then OK=$((OK + 1)); else BAD=$((BAD + 1)); fi
      echo "  [$rc] $r ${out}" >> $LOG
    done < "$POL"
    echo "  policy: per-line ok=$OK rejected=$BAD" >> $LOG
  fi
else
  echo "  magiskpolicy 不存在" >> $LOG
fi

# ---------------------------------------------------------------- v0.36 LG IPSec starter
BB=/data/adb/ap/bin/busybox
IS=/system/system_ext/bin/imsipsecstarter
ISLOG=/data/local/tmp/v50ims_ipsec.txt
{
  echo "-- v0.36 LG IPSec starter (post-fs-data) --"
  echo "  id     : $(id 2>&1)"
  echo "  本 ns  : $(readlink /proc/self/ns/mnt 2>&1)"
  echo "  init ns: $(readlink /proc/1/ns/mnt 2>&1)"
  for d in /tmp /tmp/ims /tmp/ims/socket; do
    echo "  $d = $(ls -ld "$d" 2>&1)"
  done
  echo "  二进制 : $(ls -l "$IS" 2>&1)"
  # v0.54: / 只读、/tmp 不存在，此行必然失败；socket 路径已在三方二进制/库里等长改到 /data/local/tmp
  echo "  mkdir 后 /tmp/ims/socket = $(ls -ld /tmp/ims/socket 2>&1)"
  if [ -x "$IS" ]; then
    : > "$ISLOG" 2>/dev/null
    if [ -x "$BB" ]; then $BB setsid "$IS" >>"$ISLOG" 2>&1 & else "$IS" >>"$ISLOG" 2>&1 & fi
    sleep 2
    echo "  进程   : $(ps -A 2>/dev/null | grep '[i]msipsec' | head -3)"
    echo "  socket : $(ls -l /tmp/ims/socket/ 2>&1 | head -5)"
    echo "  --- starter 自己的输出 ---"
    head -20 "$ISLOG" 2>/dev/null | sed 's/^/    | /'
  fi
  IC=/system/system_ext/bin/imsipsecclient
  ICLOG=/data/local/tmp/v50ims_ipsec_c.txt
  echo "  client 二进制: $(ls -l "$IC" 2>&1)"
  if [ -x "$IC" ] && ! ps -A 2>/dev/null | grep -q '[i]msipsecclient'; then
    : > "$ICLOG" 2>/dev/null
    if [ -x "$BB" ]; then $BB setsid "$IC" >>"$ICLOG" 2>&1 & else "$IC" >>"$ICLOG" 2>&1 & fi
    sleep 2
    echo "  client 进程  : $(ps -A 2>/dev/null | grep '[i]msipsecclient' | head -2)"
    echo "  client stdout: $(head -10 "$ICLOG" 2>/dev/null | tr '\n' '|')"
  fi
} >> $LOG 2>&1

# ---------------------------------------------------------------- 持续抓取
FILTER='LGIMS|IMS\.|ImsWms|ImsResolver|ImsService|ImsFeature|ImsManager|ImsRegistration|ImsPhone|ImsProvisioning|ImsState|ImsConfig|FeatureConnector|FeatureConnection|TelephonyShellCommand|LgeRIL|LGRADIOFALCON|LgeRadio|RadioIndication|Telecom|telecom|ImsCall|GsmCdmaCallTracker|GsmCdmaPhone|CallsManager|InCallController|Telephony |RILJ|Dialer|InCallService|LGDataRuntimeFeature|LgData|LGData|Iwlan|Epdg|Mapcon|WifiQuality|IMSIPSEC|ipsec_api|avc:.*denied|FATAL EXCEPTION|AndroidRuntime|AbstractMethodError|NoSuchMethodError|NoClassDefFoundError|IncompatibleClassChange|service_manager_slow|GII-IMPL|Phone   : (getImsRegistrationTechnology|isImsCapabilityAvailable|isImsRegistered)|SST     : .*setImsRegistrationState'

if [ -f "$PIDF" ]; then
  kill "$(cat "$PIDF" 2>/dev/null)" 2>/dev/null
  rm -f "$PIDF" 2>/dev/null
fi
rm -f "$LG" 2>/dev/null
logcat -b all -v threadtime < /dev/null 2>/dev/null | grep -E "$FILTER" > "$LG" 2>&1 &
echo $! > "$PIDF" 2>/dev/null
{
  echo "-- 持续抓取已启动 (pid=$(cat "$PIDF" 2>/dev/null), 文件 $LG)"
} >> $LOG 2>&1

# ---------------------------------------------------------------- v0.55 音频修复
# PE 的 SELinux 策略只给了 hal_vss_ims_default 对【自己】的 qipcrtr_socket
# { create }，缺 getattr。缺这一个权限 → QMI 客户端初始化失败
# （qmi_client_get_service_list 走不下去、vss_ims_init return (-1)、
#   之后每次 send_cmd 报 "ims handle is NULL"）→ modem↔AP 的 VoLTE 语音桥
# 建不起来 → 电话能接通但一个字都听不见。
# 补上之后实测：ims_client 建立、IMS init Complete!!!、vss_ims_init return (0)、
# 通话有声音。stock 上这个 HAL 正常工作，说明 stock 策略本就有这条，属移植遗漏。
# ★ 目标域必须写全，不能用 self —— APatch 的 magiskpolicy 不认 self 简写，
#   会返回 rc=0 但策略不变（实测踩过）。
[ -x "$MP" ] && "$MP" --live "allow hal_vss_ims_default hal_vss_ims_default qipcrtr_socket { read write create getattr bind connect setopt recvfrom sendto }"


# ---------------------------------------------------------------- v0.57 运营商配置修复
# 根因：ConfigXMLLoader.setXmlResource() 按
#   Configuration/<configType>.<OP>.<COUNTRY>.xml   （folder = Configuration/OP/COUNTRY）
# 查找运营商配置。本机 ro.vendor.lge.build.target_operator=OPEN、target_country=CN，
# 于是找的是 Configuration/OPEN/CN/configuration.OPEN.CN.xml —— Ims6.apk 里没有这个文件
# （实测日志 existInAssets FileNotFoundException: Configuration/OPEN/CN/
# configuration.OPEN.CN.xml），加载器于是回退到顶层通用 Configuration/configuration.xml
# （一份欧洲默认档）。
# 后果：nUETIMER_QOS_WAIT 取默认 2 秒。实测 StartQoSTimer -> OnWaitTimerExpired 只有
# 2.06 秒（两通电话分别 2.07/2.06），随即 NotifyReserveFailedByQoSTimerExpired；
# 我方 SDP 声明 a=curr:qos local none + a=des:qos mandatory local sendrecv，对端 183
# 里带 a=conf:qos remote sendrecv 即要求我方在本地承载就绪后回 UPDATE 确认，而该确认
# 发不出去，被叫侧因此永不 180 Ringing —— 常规号码全部打不通。服务号 10086/10010 由
# IMS 核心终结、不走端到端预条件，所以照常能通，这就是"只有服务号能打通"的原因。
#
# 修法：ConfigXMLLoader.openXmlResource() 有两条外部覆盖通道，
# existInExternal() 拼的都是 ext_folder + "/" + filename（【不带子目录】）：
#   ext  : ImsConstants.PATH_XML = /data/user_de/0/com.lge.ims/xml/
#   cota : /data/shared/cust/config/
# 文件存在且 modifiedTime 高于 asset 即胜出（asset 侧根本没有此文件，modifiedInAsset=-1）。
# ★ 两条都写：ext 在 app 数据目录里，实测会被 installd 在包扫描时重建目录而抹掉
#   （装/卸模块后第一次开机发生过）；cota 目录是我们自己建的，不受影响，是主落点。
# 实测日志：ConfigXML(configuration.OPEN.CN.xml) :: modifiedTime(asset|cota|ext)=[-1|101|101]
#           ConfigXML(ParseNMerge) :: modifiedTime(config|media|rcs)=[101|14|3]
#
# 这里放的是以通用配置为基线、只改 4 个 QoS 参数的最小改动版；
# config_xml_modified_time=101 用于触发 lgims.db 重建（代码只比对 modified_time）。
# ★ 不可改成整份 CMCC 原厂配置 —— 实测会让 IMS 完全注册不上：
#   aos_condition_1_isim_index_for_impu 1->0 导致 "NO valid IMPU" -> ConfigureAsEmergency，
#   REGISTER 一次都不发；其 tCustomizedSessionConfig 也缺 bNeedToAddSIPInstanceParam。
#   同理不可用 resetprop 把 target_operator 改成 CMCC 去命中 APK 里那份 CMCC 配置。
# ★ OPEN/CN 是设备级判定（来自 ro.vendor.* 而非 SIM），故该配置对移动/联通/电信通用。
V50CFG="$MODDIR/v50ims/configuration.OPEN.CN.xml"
V50EXT=/data/user_de/0/com.lge.ims/xml
V50COTA=/data/shared/cust/config
if [ -f "$V50CFG" ]; then
  mkdir -p "$V50COTA" 2>/dev/null
  cp -f "$V50CFG" "$V50COTA/configuration.OPEN.CN.xml" 2>/dev/null
  chmod 0644 "$V50COTA/configuration.OPEN.CN.xml" 2>/dev/null
  chcon u:object_r:radio_data_file:s0 "$V50COTA/configuration.OPEN.CN.xml" 2>/dev/null
  mkdir -p "$V50EXT" 2>/dev/null
  cp -f "$V50CFG" "$V50EXT/configuration.OPEN.CN.xml" 2>/dev/null
  chown radio:radio "$V50EXT/configuration.OPEN.CN.xml" 2>/dev/null
  chmod 0660 "$V50EXT/configuration.OPEN.CN.xml" 2>/dev/null
  chcon u:object_r:radio_data_file:s0 "$V50EXT/configuration.OPEN.CN.xml" 2>/dev/null
  { echo "-- v0.57 运营商配置已放置(cota+ext)"
    ls -laZ "$V50COTA/configuration.OPEN.CN.xml" "$V50EXT/configuration.OPEN.CN.xml"; } >> $LOG 2>&1
else
  echo "-- v0.57 !! 找不到 $V50CFG" >> $LOG 2>&1
fi

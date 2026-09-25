#!/system/bin/sh
# ============================================================================
# uninstall.sh —— 卸载清理（v0.61 新增）
#
#   模块目录本身由安装器删除，但脚本在运行期往模块【外面】写过几样东西，
#   不清理就会留在机器上。这份文件把它们收干净。
#
#   卸载时 SELinux 规则不用管：magiskpolicy 的规则是 per-boot 的，重启即失效。
#   system/ 的覆盖也不用管：magisk mount 随模块目录消失而消失。
# ============================================================================

TMP=/data/local/tmp

# ---------------------------------------------------------------- 1. 停掉常驻进程
# 这两个二进制是从 system_ext 直接执行的，模块卸载后它们会变成"没有源文件的进程"，
# 必须显式杀掉，否则会一直占着 IPSec 通道。
for p in imsipsecstarter imsipsecclient; do
  pid=$(pidof $p 2>/dev/null)
  if [ -n "$pid" ]; then
    kill -9 $pid 2>/dev/null
    echo "  已停止 $p (pid=$pid)"
  fi
done

# ---------------------------------------------------------------- 2. 模块写到模块外的两份配置
# post-fs-data.sh 会把 v50ims/configuration.OPEN.CN.xml 复制到这两个位置。
# 目录只在空的时候删，避免误伤。
for f in /data/shared/cust/config/configuration.OPEN.CN.xml \
         /data/user_de/0/com.lge.ims/xml/configuration.OPEN.CN.xml; do
  if [ -f "$f" ]; then
    rm -f "$f" 2>/dev/null && echo "  已删除 $f"
  fi
done
rmdir /data/shared/cust/config 2>/dev/null && echo "  已删除空目录 /data/shared/cust/config"
rmdir /data/shared/cust       2>/dev/null
rmdir /data/user_de/0/com.lge.ims/xml 2>/dev/null && echo "  已删除空目录 /data/user_de/0/com.lge.ims/xml"
rmdir /data/user_de/0/com.lge.ims     2>/dev/null

# ---------------------------------------------------------------- 3. 临时文件与 IPSec socket
rm -f  $TMP/v50ims*.log $TMP/v50ims*.txt $TMP/v50ims*.pid $TMP/v50ims_prev.log 2>/dev/null
rm -f  $TMP/ipsec_controller $TMP/ipsec_proxy $TMP/ipsec_user 2>/dev/null
echo "  已清理 $TMP/v50ims* 与 ipsec_* socket"

# ---------------------------------------------------------------- 4. 保留的东西（有意为之）
#   /data/user_de/0/product.lge.data.server
#       LG 数据服务的 app 状态目录，属于应用数据而非模块产物，
#       且 post-fs-data.sh 专门写了一段逻辑维护它的 SELinux 标签。
#       卸载时删除用户数据不合适，故保留。
#
#   /sdcard 下的诊断日志副本
#       由 service.sh 复制出来供你查看，属于用户可见文件，请自行决定是否删除。

echo "  卸载清理完成，建议重启一次让 system_ext 覆盖彻底退出"

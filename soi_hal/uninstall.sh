#!/system/bin/sh
# v50_soi_hal 卸载清理：停掉 registrar 与 watchdog，删掉持久状态和日志。
# 只处理本模块自己的进程；不要碰 v50_ims_volte 的 imsipsec* 进程。

for p in $(ps -A -o PID,ARGS 2>/dev/null \
           | grep -E 'vendor\.lge\.hardware\.soi@1\.0-service|/v50_soi_hal/service\.sh' \
           | grep -v grep | awk '{print $1}'); do
  kill "$p" 2>/dev/null
done

rm -rf /data/adb/v50_soi
rm -f /data/local/tmp/v50_soi.log \
      /data/local/tmp/v50_soi_registrar.log \
      /data/local/tmp/v50_soi_boot.log

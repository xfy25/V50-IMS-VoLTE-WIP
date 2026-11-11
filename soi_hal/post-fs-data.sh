#!/system/bin/sh
# v50_soi_hal v0.2: no system/vendor overlay. Build three overlayfs merges so
# every original file under /vendor stays visible; only our files are added.
# Runs before hwservicemanager starts, so the VINTF fragment is parsed at boot.
MODDIR=${0%/*}
D=/data/adb/v50_soi
OVL=$D/ovl
LOG=/data/local/tmp/v50_soi_boot.log
mkdir -p $D
exec >> $LOG 2>&1
echo "=== post-fs-data $(date) ==="

# LG factory/PIF boot modes (non-compliant LT_130K cable latched by bootloader)
# already break USB and clamp backlight; do not add mounts on top of that.
BOOTMODE=$(getprop ro.boot.mode)
case "$BOOTMODE" in
  pif_*|qem_*)
    echo "factory boot mode '$BOOTMODE' (cable detection): skip mounts"
    exit 0 ;;
esac

FAILS=$(cat $D/fails 2>/dev/null || echo 0)
case "$FAILS" in ''|*[!0-9]*) FAILS=0 ;; esac
echo "fails=$FAILS"
if [ "$FAILS" -ge 3 ]; then echo "fails>=3: disabling module"; touch "$MODDIR/disable"; fi
echo $((FAILS + 1)) > $D/fails
( sleep 240; if [ "$(getprop sys.boot_completed)" = "1" ]; then echo 0 > $D/fails; fi ) &

rm -rf "$OVL"
mkdir -p "$OVL/lib/upper" "$OVL/lib/work" \
         "$OVL/hw/upper"  "$OVL/hw/work" \
         "$OVL/mf/upper"  "$OVL/mf/work"

cp -f "$MODDIR/files/lib64/"*.so        "$OVL/lib/upper/"
cp -f "$MODDIR/files/lib64/hw/"*.so     "$OVL/hw/upper/"
cp -f "$MODDIR/files/etc/vintf/manifest/"*.xml "$OVL/mf/upper/"
chmod 0644 "$OVL/lib/upper/"*.so "$OVL/hw/upper/"*.so "$OVL/mf/upper/"*.xml

# The overlay root directory takes the upperdir's label, so it must match the
# original directory or unrelated vendor processes get avc denials. Files too.
chcon u:object_r:vendor_file:s0        "$OVL/lib/upper" "$OVL/lib/upper/"*.so
chcon u:object_r:vendor_hal_file:s0    "$OVL/hw/upper"  "$OVL/hw/upper/"*.so
chcon u:object_r:vendor_configs_file:s0 "$OVL/mf/upper" "$OVL/mf/upper/"*.xml
echo "labels: $(ls -dZ $OVL/lib/upper $OVL/hw/upper $OVL/mf/upper | tr '\n' '|')"

BEFORE="lib64=$(ls /vendor/lib64 | wc -l) hw=$(ls /vendor/lib64/hw | wc -l) mf=$(ls /vendor/etc/vintf/manifest | wc -l)"
echo "before: $BEFORE"

# Parent first, child second: mounting /vendor/lib64 after /vendor/lib64/hw
# hides the hw overlay (proven in live tests).
mount -t overlay overlay -o lowerdir=/vendor/lib64,upperdir=$OVL/lib/upper,workdir=$OVL/lib/work /vendor/lib64
R1=$?
mount -t overlay overlay -o lowerdir=/vendor/lib64/hw,upperdir=$OVL/hw/upper,workdir=$OVL/hw/work /vendor/lib64/hw
R2=$?
mount -t overlay overlay -o lowerdir=/vendor/etc/vintf/manifest,upperdir=$OVL/mf/upper,workdir=$OVL/mf/work /vendor/etc/vintf/manifest
R3=$?
echo "mount rc: lib=$R1 hw=$R2 manifest=$R3"
echo "after : lib64=$(ls /vendor/lib64 | wc -l) hw=$(ls /vendor/lib64/hw | wc -l) mf=$(ls /vendor/etc/vintf/manifest | wc -l)"
ls -lZ /vendor/lib64/vendor.lge.hardware.soi@1.0.so \
       /vendor/lib64/hw/vendor.lge.hardware.soi@1.0-impl.so \
       /vendor/etc/vintf/manifest/vendor.lge.hardware.soi.xml 2>&1
exit 0

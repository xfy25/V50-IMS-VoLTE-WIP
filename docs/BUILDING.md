# 构建说明

## 仓库根目录就是模块根目录

`module.prop` 在仓库根，`system/` 与它平级。这是 Magisk/APatch 模块的标准布局，也是 `zip` 之后必须保持的形状 —— **压缩包里不能有顶层目录**，否则安装器认不出。

## 打包

### 本地（Windows）

```powershell
powershell -ExecutionPolicy Bypass -File tools\build.ps1
```

产物落在 `dist\v50_ims_volte_v0.61.zip`，脚本会自己校验并打印 sha256。

**不要用 `Compress-Archive`。** 它不写 unix 权限位，会复现下面这个 bug。

### 在 WSL / Linux 上（等价做法）

```bash
chmod 0755 customize.sh post-fs-data.sh service.sh uninstall.sh
chmod 0755 system/system_ext/bin/imsipsecstarter system/system_ext/bin/imsipsecclient
zip -r -X v50_ims_volte_v0.61.zip \
    module.prop customize.sh post-fs-data.sh service.sh uninstall.sh \
    system.prop carrier_volte_override.xml LATENT_DRIFT.txt \
    v50ims system
```

`zip` 会保留文件系统上的权限位。前提是文件本身已经是 0755 —— 从 `/mnt/` 或 U 盘复制过来的文件权限往往是错的，复制后记得重新 `chmod`。

> 本项目**不设自动发布流程**。Release 附件由人工构建后手动上传。

---

## ⚠ 权限位：一个真实踩过的坑

**v0.60 的包是在 Windows 上打的，41 个条目的 unix 权限位全为 0。**

后果不是"看起来不整齐"，而是功能性的：`imsipsecstarter` / `imsipsecclient` 以安装器默认的 `0644` 落地，而 `service.sh` 是这样判活的：

```sh
[ -x "$IS" ] || { log "  !! imsipsecstarter 不存在: $IS"; return 1; }
```

`-x` 失败 → IPSec 通道**静默不启动** → 日志里只显示"不存在"，指不到真正的原因。

现在有两道防线：

1. `tools/build.ps1` 与 CI 都显式写入权限位（实测 v0.61：`post-fs-data.sh`/`service.sh`/`customize.sh`/`uninstall.sh` 与两个二进制 = `0100755`，其余 = `0100644`）
2. `customize.sh` 在安装时再显式 `set_perm` 一遍兜底

### Windows 上 git 还要额外做一步

Windows 的 git 默认 `core.filemode=false`，**不会记录可执行位**。于是 `git archive` / GitHub 打包出来的 zip 又会丢权限。要修：

```bash
git update-index --chmod=+x post-fs-data.sh service.sh customize.sh uninstall.sh
git update-index --chmod=+x system/system_ext/bin/imsipsecstarter
git update-index --chmod=+x system/system_ext/bin/imsipsecclient
```

确认：

```bash
git ls-files -s system/system_ext/bin/
# 期望看到 100755，而不是 100644
```

即便漏了这一步，CI 里的 `chmod` 和 `customize.sh` 的 `set_perm` 也会把它补回来 —— 但三处都对才叫稳。

---

## 发布检查清单

打包后确认：

- [ ] `module.prop` 在 zip 根目录（不是 `v50_ims_volte/module.prop`）
- [ ] `post-fs-data.sh` / `service.sh` / `customize.sh` / `uninstall.sh` 是 `0100755`
- [ ] `system/system_ext/bin/imsipsecstarter` / `imsipsecclient` 是 `0100755`
- [ ] zip 里**没有** `.bootfail` / `.bootcur` / `.bootok`（带上会让模块一装就自动回退）
- [ ] zip 里**没有** `README.md` / `docs/` / `.github/` / `tools/`
- [ ] `module.prop` 的 `versionCode` 比上一版大

`tools/build.ps1` 会自动检查前两项和倒数第二项。

---

## 测试安装

```sh
# 推到设备
adb push dist/v50_ims_volte_v0.61.zip /sdcard/

# APatch 里安装，或者命令行：
adb shell su -c "apd module install /sdcard/v50_ims_volte_v0.61.zip"
adb reboot
```

开机后先看安装期校验有没有拦住：

```sh
adb shell su -c "cat /data/adb/modules/v50_ims_volte/module.prop"
adb shell su -c "cat /data/local/tmp/v50ims.log"
```

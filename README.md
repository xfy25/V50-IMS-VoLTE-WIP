# V50 IMS + VoLTE

把 **LG V50 ThinQ 5G（`flashlmdd` / LM-V500N）** 原厂的 IMS/VoLTE 通话栈，移植到 **Pixel Experience 14** 这类 AOSP 系 ROM 上。

> Porting the LG V50's stock IMS/VoLTE stack onto AOSP-based Android 14 ROMs (developed against Pixel Experience 14).
> An English summary is at the bottom.

```
设备      LG V50 ThinQ 5G (LM-V500N, codename flashlmdd)
原厂底座  Android 12 (SKQ1.211103.001)
目标 ROM  Pixel Experience 14 (API 34)
Root      APatch  ← 必需，见下方"要求"
```

---

## 当前状态

| 功能 | 状态 | 说明 |
|---|---|---|
| **VoLTE 语音** | ✅ 可用 | IMS 注册成功，走 `com.lge.ims` |
| 视频通话 (VT) | ✅ 判定已放开 | `persist.dbg.vt_avail_ovr=1` |
| IPSec（IMS 安全通道） | ✅ 已打通 | 三方 socket 路径已统一改写 |
| **短信** | ⚠️ 走 CS/CSFB | v0.60 强制回落到 CS。**不走 IMS** |
| VoWiFi | ❌ 不支持 | 未做 |
| 5G NR 上的语音 (VoNR) | ❌ 未验证 | |

---

## English summary

This module brings the LG V50's proprietary IMS/VoLTE stack to AOSP-based Android 14 ROMs.

**What it does:** overlays LG's `com.lge.ims` service (Ims6.apk, `libims.lge.so`, `lgdataservice`, IMSIPSec binaries and their LG framework jars) plus a **patched `telephony-common.jar`** onto the ROM's `/system`, injects ~62 SELinux `allow` rules, starts the IPSec channel, and forces the VoLTE platform gates open.

**The hard part** was not copying binaries — it was that PE14's framework is missing both the *call site* that instantiates the LG IMS service and **159 methods across 33 classes** that LG's code calls. 125 of those (16 classes) live in `telephony-common.jar` and are stubbed there; the remaining 34 are documented but intentionally left alone. See `LATENT_DRIFT.txt`.

**Requirements:** LG V50 (`flashlmdd`) only — enforced at install time; **APatch** (not Magisk); Pixel Experience 14 / API 34.

**Status:** VoLTE voice works. SMS stays on CS/CSFB. No VoWiFi.

**Safety net:** if two consecutive boots fail to reach `sys.boot_completed`, the module automatically moves the patched jar aside so the stock one comes back.

---

## 要求

- **设备**：LG V50 ThinQ 5G，`ro.product.device` 为 `flashlm*`。安装脚本会硬校验，不匹配直接拒绝安装。
- **Root**：**APatch**。脚本写死了 `/data/adb/ap/bin/{magiskpolicy,resetprop,busybox}`；Magisk 下这三个路径不存在，SELinux 规则和 `ro.*` 强制写入都会失败，IMS 起不来。安装时会检测并警告。
- **ROM**：Pixel Experience 14（API 34）。其他 A14 ROM 未验证 —— 版本不同会导致 `telephony-common.jar` 的桩方法与调用方对不上。
- **原厂底座**：设备需已刷入 Android 12 之上基带/固件（`flashlmdd` 的 vendor 分区）。

---

## 安装

1. 从 Releases 下载 `v50_ims_volte_v0.61.zip`
2. APatch App → 模块 → 从本地安装
3. 重启
4. 重启后**等 2～3 分钟**再判断效果（IMS 注册是异步的）

装完可以看一眼日志确认：

```sh
su -c "cat /data/local/tmp/v50ims.log"
```

重点看四件事：

| 看什么 | 期望 |
|---|---|
| `service list` 里的 `com.lge.ims.phone` | 出现了 |
| `LGIMS_IPS` 有没有 `LGImsPhoneService::create` | 有 → 调用点注入成功 |
| `LGIMS_IPPM` 的 `bindService ::` | 不是 `null` |
| `ApnImsGlobal` 的 `vops` | 不是 `off` |

---

## 卸载

直接在 APatch 里卸载并重启即可。`uninstall.sh` 会自动清掉模块写在模块外的残留（两份 `configuration.OPEN.CN.xml`、`/data/local/tmp/v50ims*`、`ipsec_*` socket、两个常驻进程）。

SELinux 规则和 `system/` 覆盖都是 per-boot 的，重启即消失。

---

## 它是怎么工作的

移植 LG 的 IMS 栈，真正的难点是四个，逐个说。

### 1. 缺的不是类，是调用点

最初以为把 LG 的类注入进去就行。实际注入 1592 个类之后，`com.lge.ims.phone` **从来没注册过**。

因为在原厂 A12 里，`PhoneFactory.makeDefaultPhone()` 末尾有这么一段：

```java
if (com.android.ims.ImsFeatureProvider.hasLgeFeatureIms()) {
    LGImsPhoneService.create(context, PhoneFactory.sPhones, PhoneFactory.sCommandsInterfaces);
}
```

而 PE14 里 `LGImsPhoneService`、`ImsFeatureProvider`、`hasLgeFeatureIms`、`ImsSmsService` 这四个符号**全部为 0** —— 整个调用点不存在。全盘只有 `LGImsPhoneService` 自己含字符串 `com.lge.ims.phone`。

所以光搬类没用，必须**连调用点一起注进去**，让 `LGImsPhoneService.create()` 真的被执行。

### 2. API 漂移：159 个方法，33 个类

LG 那些桥接类是按 LG 自己改过的 AOSP 写的，调用的方法在 PE 的框架里很多不存在。不补桩，`NoSuchMethodError` 会让 `LGImsPhoneProxy.start()` 直接挂掉，IMS 代理链根本起不来。

离线全扫了一遍 —— 把 1546 个 LG 桥接类对 PE 框架的调用全部比对（真值取自 PE 的 `telephony-common.jar` + `framework.jar` + `services.jar` + `libcore`(apex)，共 54239 个反编译类，先过 5 项阳性对照）：

```
确定缺失 159 个方法，分布在 33 个目标类
  ├─ 目标类在 telephony-common 内：16 个类 / 125 个方法  → 全部补空实现
  └─ 目标类在其他框架 jar 内：    17 个类 /  34 个方法  → 不补
```

**为什么不补那 34 个**：它们的调用方全是 LG 自己的 RIL/UICC/systemservice 代码，PE 的框架永远不会调到；而目标类在 `framework.jar` 里，动它就等于改整个框架，风险远大于收益。

**一个必须知道的取舍**：125 个桩里有 **33 个返回非 void**，空实现只能返回 `0`/`null`。其中 8 个位于 IMS 代理链上，返回值理论上会影响注册逻辑：

```
Phone.getPcscfAddress(String)[]String              ← LGImsPhoneProxy$PhoneProxyBinder  (P-CSCF!)
Phone.getActiveApnHost(String)String               ← LGImsPhoneProxy$PhoneProxyBinder
Phone.getIMSNetworkInfo()[]String                  ← LGImsPhoneProxy$PhoneProxyHandler
Phone.isUnsolResponseEnabled()Z                    ← LGImsPhoneProxy$PhoneProxyBinder
Phone.getDataEnabledSettings()DataEnabledSettings  ← LGImsPhoneProxy
SubscriptionController.getDefaultSubId()I          ← LGImsIsimHandler
SubscriptionController.getPhoneId(I)I              ← LGImsIsimHandler
IsimUiccRecords.getLGWFCInfo()LGWFCInfo            ← LGImsIsimHandler$LGImsIsim
```

为什么不写成真实现：PE 上**没有对应的 AOSP 等价物**（A14 已删掉 `TelephonyManager.getPcscfAddress` 等），硬写要拉进 `ConnectivityManager` / `LinkProperties` 一整套，风险更大。而不打桩的后果更糟 —— `NoSuchMethodError` 会让 proxy 直接起不来。

完整清单（含每个方法的调用方）在 [`LATENT_DRIFT.txt`](LATENT_DRIFT.txt)。

### 3. SELinux：62 条规则

PE 的 `system_ext_service_contexts` 里没有 `com.lge.ims.phone` 条目，于是落到通配符 `default_android_service`，而 `radio` 域原本只有 `(allow radio radio_service (service_manager (add find)))`，注册被拒：

```
avc: denied { add } for name=com.lge.ims.phone
     scontext=u:r:radio:s0  tcontext=u:object_r:default_android_service:s0
```

模块在 `post-fs-data` 阶段用 `magiskpolicy` 注入 **62 条** `allow` 规则（按域：radio 18 / magisk 15 / platform_app 13 / vendor_dataservice_app 10 / hal_lgdata_default 3 / system_server 2 / hal_vss_ims_default 1），覆盖属性读取、binder 调用、hwservice 查找、service_manager 注册、socket 创建等。

这些规则是 per-boot 的，不落盘，重启即恢复。

### 4. IPSec socket 路径：三方都要改

LG 的 IMS 安全通道靠三个组件通过 UNIX socket 通信，而**它们的路径是硬编码的**：

```
imsipsecstarter              bind  /tmp/ims/socket/...
imsipsecclient               bind  /tmp/ims/socket/...
libims.lge.so (com.lge.ims)  bind  /tmp/ims/socket/...
```

问题在于：这台机器上 `/tmp/ims/socket` **永远不存在** —— `/` 是只读 ext4，`/tmp` 根本没有，原厂和 PE 的 rc 里都没有任何一条创建它的指令，两个二进制自身也没有 `mkdir`。

处理办法是把三方的路径**等长改写**成 `/data/local/tmp/`：

```
imsipsecstarter              bind  /data/local/tmp/ipsec_controller
imsipsecclient               bind  /data/local/tmp/ipsec_proxy
                             send→ /data/local/tmp/ipsec_user
libims.lge.so                bind  /data/local/tmp/ipsec_user
```

（v0.53 只改了前两个、漏了 `libims.lge.so`，已作废；v0.54 起三方一致。）

### 5. 开机失败自动回退

这个模块会覆盖 `/system/framework/telephony-common.jar` —— 改错了就是开不了机。所以内置了安全网：

```
post-fs-data  把本次 boot_id 写入 .bootcur
service.sh    只有在 sys.boot_completed=1 之后，才把同一个 boot_id 写入 .bootok

于是 .bootcur != .bootok  ⇒  上一次开机没走完
```

连续 **2 次**判定失败，就把补丁 jar 移到 `telephony-common.jar.disabled`，下一次开机的 magic mount 就不再覆盖它，原版 jar 自动回来。

状态记在模块目录的 `.bootfail` / `.bootcur` / `.bootok`，每行一次开机的台账在 `/data/local/tmp/v50ims_boot.txt`。

> 全新安装时 `customize.sh` 会清零这三个文件 —— 否则模块目录里若残带一个 `.bootfail=2`，装完第一次开机就会立刻回退，看起来像"没生效"。

---

## 故障排查

**先看日志**

```sh
su -c "cat /data/local/tmp/v50ims.log"       # 本次开机（只留一代）
su -c "cat /data/local/tmp/v50ims_lg.txt"    # LG 侧持续抓取
su -c "cat /data/local/tmp/v50ims_boot.txt"  # 每次开机的台账
```

`service.sh` 会把上面这些复制一份到 `/sdcard`，方便不接 adb 时查看。

**常见症状**

| 症状 | 先查 |
|---|---|
| IMS 完全不起 | `service list` 里有没有 `com.lge.ims.phone`；`.bootfail` 是不是 ≥2（说明被安全网回退了） |
| 开机自动回退了 | `v50ims_boot.txt` 最后几行会写明 `REVERT` 和原因 |
| 拨号不走 IMS | `ApnImsGlobal` 的 `vops`；`getprop persist.dbg.volte_avail_ovr` 是否为 1 |
| IPSec 拉不起来 | `v50ims_ipsec.txt`；确认 `imsipsecstarter` 是 0755 可执行的 |
| 补丁静默失效 | 看日志里的 `MOUNTSTATE` —— 如果不是"覆盖生效"，说明 magic mount 没换上 |

**重放一次完整调参/修复**（开机后手动重设）

模块每次开机都会自动应用，正常不需要手动。调试时可看 `service.sh` 的 keeper 循环（每 30 秒检查一次，跑 40 轮，另有 240 轮的 60 秒循环）。

---

## 已知限制

1. **短信不走 IMS**。v0.60 是主动把短信强制回落到 CS/CSFB 的（`sms_over_ip_networks_indication=''→0`），这是当前版本的既定行为，不是 bug。
2. **VoWiFi 未实现**。
3. **33 个非 void 桩返回 0/null**，其中 8 个在 IMS 代理链上（见上文第 2 节），属于已知的理论风险点。
4. **只支持 APatch**。Magisk 下能装但预期不可用。
5. **只验证了 Pixel Experience 14**。
6. `LATENT_DRIFT.txt` 是**中文**技术附录。

---

## 仓库结构

```
.
├── module.prop                    模块声明
├── system.prop                    随模块挂载的属性
├── customize.sh                   安装期校验（设备/架构/版本/root 方案）+ 权限修正
├── post-fs-data.sh                开机早期：安全网、SELinux 规则、属性、配置注入
├── service.sh                     boot_completed 后：IPSec 拉起与 keeper、诊断快照
├── uninstall.sh                   卸载清理
├── carrier_volte_override.xml     CarrierConfig 覆盖
├── LATENT_DRIFT.txt               ★ 159 个缺失方法 / 33 个类的完整清单
├── v50ims/
│   └── configuration.OPEN.CN.xml  LG IMS 配置（注入到两个运行期位置）
└── system/                        覆盖到 /system 的 payload
    ├── etc/                       ike_conf / mapcon_conf
    ├── framework/
    │   └── telephony-common.jar   ← 打了 125 个兼容桩的 PE jar
    └── system_ext/
        ├── bin/                   imsipsecstarter / imsipsecclient
        ├── etc/                   init.lge.ims.rc、权限 XML、SELinux 上下文
        ├── framework/             com.lge.ims.httpTxn.jar 等
        ├── lib64/                 libims.lge.so 等 14 个 LG 库
        └── priv-app/              Ims6.apk、lgdataservice.apk
```

---

## 法律声明

**本仓库不包含、也不主张任何 LG 的代码或知识产权。**

`system/` 下的 LG 专有文件（`libims.lge.so`、`Ims6.apk`、`lgdataservice.apk`、各 LG 库与框架 jar）**版权归 LG Electronics 所有**，此处仅出于互操作性目的、为让该设备在自定义 ROM 上恢复通话功能而收录。模块本身的脚本与文档由本仓库作者编写。详见 [`NOTICE.md`](NOTICE.md)。

如果你是在用自定义 ROM 的 V50 用户，下载安装即可，不需要关心这些。

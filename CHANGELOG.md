# 更新日志

> 完整的逐版记录（含每一版的推理过程、证伪的假设、离线验证方法）在
> **[`docs/VERSION_NOTES.md`](docs/VERSION_NOTES.md)**，由各版 `module.prop` 描述汇总而成。
> 本文件只列里程碑。

版本号对应关系：`module.prop` 的 `version` 是语义化的（`0.60_cs_sms`），`versionCode` 是递增的构建号。

---

## 里程碑总表

| 版本 | code | 这一版解决了什么 |
|---|---|---|
| 0.1 | 1 | 首版：注入 LG `com.lge.ims` ImsService + `product.lge.data.server` |
| 0.8 | 8 | 补上 LG 留在 `system_ext/lib64` 的 HAL 接口库，修 `libims.lge.so` dlopen 失败 |
| 0.10 | 10 | 消灭最后一个 `NoSuchMethodError`，`com.lge.ims` 起能常驻并输出日志 |
| **0.12** | 12 | **补 `android.hardware.telephony.ims` feature 声明 —— 这才是此前一直卡住的真正原因** |
| 0.14 | 14 | Ims6 的 `LGImsService.onBind` 改回 `super.onBind()`，绕开 A12/A14 AIDL 签名不兼容 |
| 0.19 | 19 | `set-ims-service` 改成重试循环（判定标准是能否读回，而非命令返回值） |
| 0.23 | 23 | 补 `CommandsInterface` 的 65 个桩；加 `service_manager { add }` 规则让 `com.lge.ims.phone` 能注册 |
| 0.25 | 25 | 凡是目标类在 `telephony-common` 内的缺失方法**全部**补桩：16 个类 / 125 个方法 |
| 0.29 | 29 | VoPS 刷新从被动拉取改为事件驱动，`vops=on` 稳定复现 |
| 0.35 | 35 | 移植 LG IPSec starter（PE 的 `system_ext/bin` 被清空，只剩 1 个文件，stock 有 62 个） |
| 0.36 | 36 | 让 starter 自己说话（日志落盘 + 双 mount namespace 对照诊断） |
| 0.37 | 37 | `/tmp` 用 magic mount 挂出来（`libims.lge.so` 把路径写死在二进制里） |
| 0.38 | 38 | 不依赖 init，自己执行 `imsipsecclient`，IPSec 通道打通 |
| **0.39** | **39** | **CarrierConfig 的 `carrier_volte_available_bool` 置 true —— 拨号真正可用的关键** |
| 0.41 | 41 | 一行属性 `persist.dbg.volte_avail_ovr` 短路 VoLTE 平台判定 |
| 0.51 | 51 | 补 LG IMS 的运营商目标属性（`target_operator` / `country` / `region`） |
| 0.54 | 54 | IPSec socket 路径**三方一起**等长改写（v0.53 只改了两方，已作废） |
| 0.57 | 57 | 修运营商配置回落：`configuration.OPEN.CN.xml` 注入到两个运行期位置 |
| 0.58 | 58 | `bPreconditionSupportWithoutQoS` 0→1：收不到 modem QoS 预留通知也认本地承载就绪 |
| 0.59 | 59 | `nUETIMER_QOS_FORCE_FAKE` 0→1：1 秒未收到通知即强制就绪 |
| **0.60** | **61** | 主动把短信强制回落 CS/CSFB（`voice_domain_preference_*`、`sms_over_ip_networks_indication=0`） |
| **0.61** | **62** | **首个公开发布版**：安装期设备校验、卸载清理、修 zip 权限位缺失 |

---

## 关键转折点

### v0.12 —— 真正的卡点是一个 feature 声明

此前一直以为问题是类没注入全、SELinux 没放行。实际上 A14 的 `PhoneFactory` 会检查 `android.hardware.telephony.ims` 这个 system feature —— 设备（V50 的 vendor 是原厂 A12 的）没有这个声明，PE 就打印 `IMS is not supported on this device, skipping ImsResolver.` 并**永不绑定任何 ImsService**。

补上这一条声明之后，框架才第一次去绑 `com.lge.ims`。

### v0.14 —— AIDL 签名不兼容

框架确实已经绑上了 `com.lge.ims`，但立刻 `AbstractMethodError` 崩溃。原因是 LG 用自己的 `LGImsServiceBinder extends IImsServiceController$Stub` 包了一层，实现的是 **Android 12 的一参数 AIDL**，而 A14 用两参数调用。

修法是把 Ims6 的 `LGImsService.onBind` 改为直接返回 `super.onBind()` —— AOSP 14 的 `ImsService` 保留了 LG 覆盖的那些方法并自带版本适配，用基类 Stub 即可。

### v0.25 —— 分类标准从"目标类"改成"调用方"

v0.24 只补了 `CommandsInterface` 的 65 个，结果 `LGImsPhoneProxy.start()` 从 301 行走到 312 行又停。根因是分类标准错了：原来按【目标类】猜"像不像 IMS 相关"，而正确的标准是【调用方】—— `LGImsPhoneProxy.start()` 调它，它就在路径上。

于是不再猜：**凡是目标类在 `telephony-common` 内的缺失方法，全部补空实现**。16 个类 / 125 个方法。目标类在其他框架 jar 里的 34 个不补（调用方都是 LG 自己的 RIL/UICC/systemservice）。

### v0.39 —— IMS 注册成功 ≠ 能打电话

v0.38 已让 IMS 在 LTE 上注册成功（`state=active`、`registered=true`、`IN_SERVICE`），但拨出请求发不出去、挂断卡住。

两个症状同源，日志定位到 `ImsPhoneCallTracker` 的 `isVolteEnabled=false`（同一行 `isVideoCallEnabled=true`），而 LG 侧报 `VoLteEnabled=true`。阻塞点在 AOSP 的 `ImsManager.isVolteEnabledByPlatform()` 第二道门 —— CarrierConfig 的 `carrier_volte_available_bool`。

### v0.54 —— 三方硬编码同一组路径

IPSec 通道的三个组件都把 socket 路径写死在二进制里，指向 `/tmp/ims/socket/*`；而这台机器上那个目录**永远不存在**（`/` 是只读 ext4，`/tmp` 根本没有，两边 rc 都没创建指令，二进制自身也没有 `mkdir`）。

v0.53 只改了 starter 和 client，漏了 `libims.lge.so`，作废。v0.54 起三方一致等长改写为 `/data/local/tmp/*`。

### v0.60 —— 短信主动回落到 CS

这不是修 bug，是**主动的取舍**：强制 `voice_domain_preference_eutran=-1→2`、`utran=-1→1`、`sms_over_ip_networks_indication=''→0`，并把 `config_xml_modified_time` 从 103 提到 104 触发 DB 重建。

结果是短信走 CS/CSFB 而非 IMS —— 能收能发，但不算真正的 IMS 短信。

### v0.61 —— 公开发布

相对 v0.60 的改动**只涉及安装与卸载，不改变任何开机运行逻辑**：

- **新增 `customize.sh`**：安装期校验设备代号 / 架构 / API / root 方案。此前模块可以被装到非 V50 设备上 —— 这个坑真实发生过。
- **新增 `uninstall.sh`**：清理模块写在模块外的残留。
- **修复 zip 未存 unix 权限位**：v0.60 的包是在 Windows 上打的，41 个条目的外部属性高 16 位**全为 0**，于是 `imsipsecstarter` / `imsipsecclient` 会按安装器默认的 0644 落地；而 `service.sh` 用 `[ -x ]` 判活，会**静默不启动 IPSec 通道**，日志里只显示"不存在"。现由 `customize.sh` 显式设为 0755。
- 补 `README.md` / `CHANGELOG.md` / `NOTICE.md` / `LICENSE` / `docs/VERSION_NOTES.md`。

# 声明 / NOTICE

## 一句话

**本仓库的脚本与文档由本项目作者编写，以 MIT 授权（见 `LICENSE`）。`system/` 目录下的 LG 专有文件版权归 LG Electronics 所有，不在 MIT 授权范围内，此处仅出于互操作性目的收录。**

---

## LG 专有文件清单

以下文件提取自 **LG V50 ThinQ 5G（`flashlmdd` / LM-V500N）原厂 Android 12 固件**，版权归 LG Electronics 所有：

| 文件 | 大小 | 说明 |
|---|---|---|
| `system/system_ext/lib64/libims.lge.so` | 18,107,192 | LG IMS 核心库 |
| `system/system_ext/priv-app/Ims6/Ims6.apk` | 6,784,081 | LG ImsService 实现 |
| `system/system_ext/priv-app/lgdataservice/lgdataservice.apk` | 315,795 | LG 数据服务 |
| `system/system_ext/framework/lgdataservice-manager.jar` | 1,225,024 | |
| `system/system_ext/framework/lgsvcitems.jar` | 58,449 | |
| `system/system_ext/framework/com.lge.ims.httpTxn.jar` | 41,569 | |
| `system/system_ext/lib64/*.so`（其余 13 个） | ~1.44 MB | LG HAL 接口库（vss_ims / lgdata / soi 等） |
| `system/system_ext/bin/imsipsecstarter` | 11,288 | LG IMSIPSec 守护 |
| `system/system_ext/bin/imsipsecclient` | 32,616 | LG IMSIPSec 客户端 |
| `system/etc/ike_conf.xml`、`mapcon_conf.xml` 及 `system_ext/etc/` 下的同名文件 | ~0.54 MB | LG IMS 网络配置 |
| `system/system_ext/etc/permissions/*` | ~30 KB | LG 权限声明 |
| `system/system_ext/etc/init/init.lge.ims.rc` | 493 | LG IMS 服务定义 |

### 收录理由

LG 未授权再分发这些文件。本项目收录它们的唯一理由是**互操作性**：让一台已经刷入第三方 ROM 的 LG V50，恢复使用它自己硬件所需的通话功能。这些文件本来就是该设备出厂固件的一部分，本项目既不修改其授权状态，也不从中获利。

如果你是权利人或代理人，认为此处收录不当，请开 issue 联系，我们会移除。

---

## 被修改过的文件

以下文件在上表基础上做了**字节级修改**，修改内容与理由见 README 与 `docs/VERSION_NOTES.md`：

| 文件 | 改动 |
|---|---|
| `system/framework/telephony-common.jar` | **源自 Pixel Experience 14**（非 LG 文件）。补入 125 个兼容桩方法；v0.60 起做 zipalign |
| `system/system_ext/priv-app/Ims6/Ims6.apk` | 字节码修补：`LGImsService.onBind` 改为 `super.onBind()`；替换 A14 已删除的 LG 扩展 API |
| `system/system_ext/priv-app/lgdataservice/lgdataservice.apk` | 同上，替换 A14 已删除的 LG 扩展 API |
| `system/system_ext/bin/imsipsecstarter` | socket 路径等长改写 `/tmp/ims/socket/*` → `/data/local/tmp/ipsec_controller` |
| `system/system_ext/bin/imsipsecclient` | socket 路径等长改写 → `/data/local/tmp/ipsec_proxy`、`/data/local/tmp/ipsec_user` |
| `system/system_ext/lib64/libims.lge.so` | socket 路径等长改写 → `/data/local/tmp/ipsec_user` |

### 关于 `telephony-common.jar`

它源自 **Pixel Experience 14**，不是 LG 的文件。AOSP 与 Pixel Experience 均以 **Apache License 2.0** 授权，本项目对其的修改继续适用 Apache 2.0。

### 关于 APK 的字节码修补

对 `Ims6.apk` 与 `lgdataservice.apk` 的改动是**为在 Android 14 上运行所做的兼容性适配**，不涉及绕过授权、许可校验或任何形式的保护措施规避。

---

## 无关联声明

本项目与 **LG Electronics**、**Google LLC**、**Pixel Experience** 项目组均无隶属、赞助或背书关系。

"LG"、"V50" 是 LG Electronics 的商标。"Android" 是 Google LLC 的商标。此处使用仅出于指称与兼容性说明目的。

---

## 如果不想再分发 LG 文件

若你打算 fork 本仓库但希望规避再分发问题，删掉 `system/` 目录即可 —— 剩下的脚本、文档与 SELinux 规则是纯粹的本项目成果。代价是模块无法直接安装，需要使用者自备对应固件并自行提取这些文件。

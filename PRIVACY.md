# 隐私政策 · DroidBerth

**最后更新：2026-10-13** ｜ **适用版本：DroidBerth 1.0.0 及之后**

## 一句话

DroidBerth 不收集、不上传、不分享你的任何个人信息。

## 1. 这个应用做什么

DroidBerth 在你的 Mac 与你自己的 Android 手机之间传输文件。所有传输都通过 USB 数据线
（或你主动开启的局域网调试连接）在**你自己的两台设备之间**直接进行 —— 不经过任何服务器，
我们没有服务器。

## 2. 我们处理什么，以及为什么

| 数据 | 什么时候 | 用来做什么 | 会不会离开你的设备 |
| --- | --- | --- | --- |
| **你选择的文件与文件夹** | 你主动选择要传输的目录之后 | 在这些目录内读取 / 写入，完成传输 | ❌ 不会。只在你的 Mac 与你自己的手机之间流动 |
| **Android 设备信息**（型号、可用空间、文件列表） | 你连接手机之后 | 在界面上显示，让你选择目标位置 | ❌ 不会 |
| **照片图库内容** | 你授权「照片图库」来源之后 | 读取你选中的照片 / 视频的原始文件并推送 | ❌ 不会 |
| **诊断报告** | **只在你主动执行「导出诊断报告」时** | 出问题时报给开发者排查 | ⚠️ 由**你**决定是否发送。报告写入磁盘**之前**已抹去用户名与家目录路径 |
| **应用偏好**（视图模式、窗口状态等） | 日常使用 | 记住你的设置 | ❌ 不会。只存在本机 |

## 3. 我们不做什么

- 不联网上传你的任何文件
- 不含任何分析、追踪、广告或用户画像 SDK
- 不收集设备标识符、位置、通讯录、浏览记录
- 不在后台收集数据
- 不向第三方出售或分享任何数据（我们根本没有这些数据）

## 4. 权限说明（macOS）

| 系统权限 | 为什么需要 | 什么时候请求 |
| --- | --- | --- |
| **文件与文件夹访问** | 读取要传输的素材、写入下载的文件 | **只在你亲手选择目录时**。应用只在你选过的范围内工作，**不会扫描其他位置** |
| **USB 设备访问** | 通过数据线与你自己的 Android 手机通信 | 连接手机时 |
| **网络访问** | 仅用于「无线调试」模式 —— 你主动开启后，经局域网连接你自己的手机 | 你开启该模式时 |
| **照片图库** | 让你直接从「照片」里选素材推送，不必先导出到文件夹 | 你切换到「照片图库」来源时 |

## 5. 第三方组件

本应用内嵌了 **Google 发布的 Android Platform Tools（ADB）**，以
[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0) 分发。

- 它只用于通过 USB 与你**自己的设备**通信，不具备任何联网或上传能力
- 完整许可声明随应用分发（见应用包内 `NOTICE.txt`）
- 除此之外，本应用**不含任何第三方 SDK**

## 6. 你的控制权

- **撤销文件访问**：系统设置 → 隐私与安全性 → 文件与文件夹；或直接在应用内「位置」弹窗里
  点「清除」移除已授权的目录
- **撤销照片访问**：系统设置 → 隐私与安全性 → 照片
- **删除本机数据**：应用不保存任何云端数据，删除应用即删除全部本地数据
  （`~/Library/Containers/<bundle-id>/` 与 `~/Library/Application Support/DroidBerth/`）

## 7. 儿童

本应用不面向 13 岁以下儿童，也不会有意收集其任何信息。

## 8. 政策变更

本政策如有变更，会更新本文档顶部的日期，变更过程在仓库提交记录中可见。

## 9. 联系方式

- 问题与反馈：<https://github.com/tangzzz-fan/DroidBerth/issues>
- 安全问题请通过同一入口报告

---

# Privacy Policy · DroidBerth

**Last updated: 2026-10-13** ｜ **Applies to: DroidBerth 1.0.0 and later**

## The short version

DroidBerth does not collect, upload, or share any of your personal information.

## What it processes, and why

| Data | When | Why | Leaves your devices? |
| --- | --- | --- | --- |
| **Files and folders you pick** | After you choose a folder to transfer | Read/write within those folders to complete the transfer | No — only between your Mac and your own phone |
| **Android device info** (model, free space, file listing) | After you connect a phone | Show it in the UI so you can pick a destination | No |
| **Photo library items** | After you grant access to the Photos source | Read the originals of the items you select and push them | No |
| **Diagnostics** | **Only when you explicitly run "Export diagnostics"** | Debugging, if you choose to send it | Only if you decide to. Usernames and home paths are scrubbed **before** the file is written |
| **App preferences** | Normal use | Remember your settings | No — stored locally only |

## What it does not do

No uploads of your files. No analytics, tracking, or advertising SDKs. No collection of device
identifiers, location, contacts, or browsing history. No background data collection. No sale or
sharing of data with third parties.

## Permissions

File access is requested **only when you pick a folder yourself**, and the app works only within
what you picked — it does not scan other locations. USB access is used to talk to **your own**
phone. Network access is used only for the "wireless debugging" mode you enable yourself.

## Third-party components

The app bundles Google's **Android Platform Tools (ADB)** under the
[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0). It is used solely to talk to
**your own** phone over USB and has no networking or upload capability. Full notices ship with the
app (`NOTICE.txt`). There are no other third-party SDKs.

## Your control

Revoke file access in System Settings → Privacy & Security → Files and Folders (or use "Clear" in
the app's Places popover). Revoke Photos access in Privacy & Security → Photos. Nothing is stored
in any cloud; deleting the app removes all local data.

## Contact

<https://github.com/tangzzz-fan/DroidBerth/issues>

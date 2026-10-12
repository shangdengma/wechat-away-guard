# 微信离开保护 · WeChat Away Guard

用 Codex 辅助开发的桌面工具：检测随身 iPhone 的蓝牙连接或实时信号，在持续失联后尝试调用微信原生锁定功能，其他软件保持可用。

这是第三方体验项目，与微信官方无关。程序界面使用「🌏 离开保护」名称。

## 下载与版本状态

| 平台 | 版本 | 当前交付 |
| --- | --- | --- |
| Windows | 0.3.1 | 可运行 EXE，已编译、界面预览；31 项逻辑测试通过 |
| macOS | 0.2 | 本机构建源码包；19 项共享状态机测试通过，尚未完成 Mac 原生编译和实机验证 |

**[前往 Releases 下载](https://github.com/shangdengma/wechat-away-guard/releases/tag/v0.3.1)**

Windows 下载 `GlobeGuard-Windows-v0.3.1.zip`，解压后打开 `WeChatGuard.exe`。
Mac 下载 `GlobeGuard-Mac-v0.2-source.zip`，按包内说明在 Mac 上构建。

新版本的手机关开、离开锁定和返回全过程仍需现场验证。逻辑测试通过不等于已完成商业产品验收。

## 实现了什么

- 只尝试锁定微信，不锁整台电脑。
- iPhone 无需额外安装 App。
- 可设置离开延时；蓝牙信号不等于精确距离。
- 首次引导识别手机并验证锁定，记住设置，之后一键开启。
- 主界面明确显示尚未保护、保护已开启、锁定未确认等状态。
- 关闭窗口后仍驻留托盘／菜单栏；可暂停或完全退出。
- 返回后由用户在手机微信上确认解锁，不自动解锁。

## 第一次使用

1. Windows 先将 iPhone 与电脑蓝牙配对。Mac 按程序提示选择扫描到的设备。
2. 点击「开始设置」，选择自己的 iPhone。
3. 按提示保持手机蓝牙开启，然后在 iPhone「设置 → 蓝牙」中关闭开关。
4. **关闭后先不要重新打开。等页面提示「重新打开手机蓝牙」后再开启。电脑蓝牙始终保持开启。**
5. 完成一次原生锁定验证；Mac 还需由用户授予蓝牙和辅助功能权限。
6. 看到「保护已开启」后，带手机实际离开工位，确认触发符合使用环境。

当前实现保存连接验证 7 天；到期或更换手机需要重新验证。微信路径／版本变化会要求重测锁定。取消引导、无法建立新连接或锁定结果未确认时，不能视为已保护。

## 工作方式

Windows 通过实际建立、随即关闭的蓝牙 RFCOMM 连接判定本次响应；设备列表、缓存或服务查询成功本身不算在线。连续失联达到默认 20 秒后触发，探测自身耗时会增加实际等待。

Mac 使用 CoreBluetooth 新广播或 `readRSSI` 成功回调更新信号时间。默认信号过期 10 秒后，再等待设定的 20 秒，通常约 30 秒或更久才触发。可选弱信号阈值需要现场校准。

两版均需连续两个有效响应／信号后才开始离开判断。Windows 使用已验证目标窗口的原生快捷键并检查锁定提示；Mac 查找可访问的原生锁定菜单。自动锁定结果无法确认时暂停并提示。

## 从源码构建

### Windows

需要 Windows 上的 .NET Framework C# 编译器与相应 Windows WinMetadata，使用 PowerShell：

```powershell
./windows/source/build.ps1
./windows/WeChatGuard.exe --self-test
Get-Content ./windows/self-test.txt
```

构建脚本使用系统编译器，生成 x64 程序。自测不会执行蓝牙探测或锁定微信。

### Mac

目标 macOS 12+。安装 Apple Command Line Tools 后：

```bash
bash macos/build-and-run.command
```

脚本按当前 Mac 架构构建 `macos/build/WeChatGuard.app` 并做本地临时签名。它不是 Developer ID 签名或公证安装包。Apple Silicon／Intel 兼容性尚待实机验证。

可选的共享状态机测试需要 Node.js：

```bash
node macos/tests/core.test.cjs
```

## 隐私与限制

没有服务器，不上传数据、不读取微信数据库、不保存聊天记录或密码。Windows 仅在锁定操作后尝试在内存中识别目标窗口的锁定提示，不保存该图像和识别文本。Mac 通过辅助功能检查菜单和锁定结果，亦不记录聊天文字。

设置保存在本机，包含所选设备标识、名称（Windows）、验证时间、阈值和应用版本。运行日志在内存显示。

蓝牙兼容性、遮挡、系统权限、设备标识变化和微信版本均可能影响结果。目前不支持微信多开；不保证独立图片窗口、通知预览、剪贴板或导出文件受到原生锁定保护。同一电脑账户的使用者能够退出工具。

尚未提供安装器、商业授权收费、自动更新、开机自启、防退出或自动解锁。仓库暂未指定开源许可证，公开源码不表示授予任意再分发或商业使用许可。

## 项目结构

```text
windows/source/       Windows 原生界面、连接检测与锁定逻辑
macos/source/         Mac 原生界面与共享状态机
macos/tests/          共享状态机测试
docs/推文.txt          项目介绍文案
```

使用问题可以通过 [Issues](https://github.com/shangdengma/wechat-away-guard/issues) 反馈。请不要上传聊天截图、账号凭据或其他个人隐私信息。

# Vivi Player（薇薇播放器）

一款使用 SwiftUI 构建的本地 iPhone 音乐与视频播放器。媒体保存在 App 自有的 Documents 目录；不提供在线媒体服务。

## 功能

- 通过系统文件选择器导入本地音频、视频和同名 `.lrc` 歌词；浏览、搜索及确认后删除媒体。
- 音乐：播放列表、收藏、最近播放、随机播放、完成方式、睡眠定时、同步歌词、后台响度平衡缓存、锁屏与系统遥控。
- 视频：KSPlayer 播放、进度恢复、自动连播、速度调节和系统遥控。
- 音乐页及播放详情队列打开时定位当前歌曲。蓝牙 A2DP 且有有效同步歌词时，可能通过系统“正在播放”的标题字段向车机显示歌词；具体效果依车型而异。

## 源码构建

1. 使用 Xcode 27.0（本次实际验证版本，build 27A266a）打开 `DrivePlayer.xcodeproj`，让 Swift Package Manager 按已锁定的 `Package.resolved` 解析固定依赖；部署目标为 iOS 17 或更高版本。KSPlayer 的依赖使用上游预编译 XCFrameworks，本项目不从源码构建这些框架。
2. 选择 `DrivePlayer` scheme 和 iPhone 模拟器；可使用 `xcodebuild -project DrivePlayer.xcodeproj -scheme DrivePlayer -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` 验证编译。
3. 真机安装前，在你自己的 Xcode 签名设置中选择开发团队，并将 App 与测试目标的示例 Bundle ID 改成你拥有的唯一标识。仓库中的 `com.example.*` 仅用于公开源码演示，不对应既有 App，也不能作为保留既有手机数据的同身份更新包。
4. `DrivePlayer` scheme 运行单元测试；`DrivePlayerMusicMenuUI` scheme 运行真实菜单 UI 测试。UI 测试需要独立模拟器、有效合成歌曲素材及测试运行环境变量，参见 `DrivePlayerUITests/README.md`。

## 测试素材

`DrivePlayer/Resources/phase0-test.mp4` 与 `DrivePlayerTests/Resources/metadata-fixture.m4a` 完全由仓库内 Swift 脚本生成，未使用外部媒体或下载。生成命令、工具版本、SHA-256、授权和验证限制见 [tools/README.md](tools/README.md)。

## 授权与分发

本项目原创 App、测试、脚本及文档采用 GPL-3.0-only（见 LICENSE、COPYING）；上述合成素材亦明确以 GPL-3.0-only 授权。第三方代码与框架保留其原有权利和许可，本项目授权不重新许可第三方组件。

项目锁定 KSPlayer 与 kingslay/FFmpegKit 的版本。依赖边界见 THIRD_PARTY_NOTICES.md；实际二进制分发仍需核查所链接的预编译框架、对应源码及上游声明。这不是完整的组件清单或一揽子再分发合规认证。

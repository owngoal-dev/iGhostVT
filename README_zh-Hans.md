<p align="center">
  <a href="README.md">English</a> |
  <a href="README_zh-Hans.md">简体中文</a>
</p>

# iGhostVT

在 iPhone、iPad 和 Mac 上使用真正的终端，绘制引擎与桌面版 [Ghostty](https://ghostty.org) 相同。启动一条命令，离开应用再回来，shell 仍在运行。

![应用预览](./Documents/screenshots.png)

## 安装

在运行自定义固件的设备上，用你常用的包管理器添加 OwnGoal Studio 软件源：

**[apt.owngoal.dev](https://apt.owngoal.dev/)**

也可从 [GitHub Releases](https://github.com/owngoal-dev/iGhostVT/releases) 下载。请选择与设备匹配的文件。

| 设备 | 软件包 |
| --- | --- |
| 运行自定义固件的 iPhone 或 iPad，[roothide](https://github.com/roothide) | `iphoneos-arm64e` |
| 运行自定义固件的 iPhone 或 iPad，rootless（`/var/jb`） | `iphoneos-arm64` |
| Mac | `iGhostVT-<version>-macos.zip` |
| 未运行自定义固件的 iPhone 或 iPad，用来连接上面这些设备 | `GhostRemote-<version>.ipa`（见 [Ghost Remote](#ghost-remote)） |

需要 iOS 15 或更高版本，或 macOS 13 或更高版本。

### Mac

解压后将 `iGhostVT.app` 拖入**应用程序**，再从该位置打开。应用通过后台辅助程序运行终端会话。如需授权，请按应用提示在系统设置中启用。

发布包为 ad-hoc 签名。如果 macOS 拒绝打开应用：

```sh
xattr -dr com.apple.quarantine /Applications/iGhostVT.app
```

### Ghost Remote

Ghost Remote 是单独拿出来的 iGhostVT 远程访问，给未运行自定义固件的 iPhone 或 iPad 用：它只打开你那些运行 iGhostVT 的设备上的终端，自己不运行任何终端。在 AltStore 或 SideStore 中添加这个源：

**`https://owngoal-dev.github.io/iGhostVT/altstore.json`**

也可以从 [GitHub Releases](https://github.com/owngoal-dev/iGhostVT/releases) 下载 `GhostRemote-<version>.ipa`，用 Sideloadly 或你自己的证书安装。在另一台设备上打开远程访问，然后在 Ghost Remote 中轻点 **+**，输入它显示的配对码。两边需要同一个发布线：版本号的前两位相同。

## 功能

- **Ghostty 引擎**：GPU 绘制终端、Ghostty 主题目录，以及带额外按键的软件键盘。
- **持久会话**：启用**保持会话运行**后，程序会在退出应用后继续执行，下次启动时恢复对应会话。空闲的 shell 会随应用退出而关闭。可在**设置 → 高级 → 会话**中调整。
- **标签页与窗口**：同时打开多个会话，使用标签页切换器，锁定标签页以防止误输入，并在 iPad 和 Mac 上打开多个窗口。
- **拷贝与分享**：拷贝文本、拷贝为图片或导出文本。
- **查找**：按 ⌘F 或在标签页菜单中选择**查找…**，搜索终端的屏幕和回滚内容。输入时即高亮所有匹配项，⌘G 和 ⇧⌘G 从最新的匹配项开始逐个跳转。
- **快捷指令**：通过「快捷指令」运行命令、打开标签页或读取终端输出。使用 `ighostvt://session/<id>` 可从其他应用打开指定会话。
- **实时活动**：在支持此功能且运行 iOS 16.2 或更高版本的设备上，于锁定屏幕查看会话状态；支持灵动岛的 iPhone 机型也可在灵动岛中显示。
- **命令行**：`ighostvt-cli` 操作应用正在显示的同一批会话，不会接管它们。
- **远程访问**：用 6 位配对码把设备配对，互相打开对方的终端。同一网络内直接连接，不在同一网络时可经过你自己部署的中继（`docker compose up -d`，再导入它生成的 `.vtrpsc` 文件，详见 [Relay](Relay/README.md)）。两台设备需要运行相同版本的 iGhostVT。

## 命令行

列出会话、读取终端输出、发送输入，或创建和关闭会话。每条命令执行一次后即断开。先运行 `ighostvt-cli list` 查看会话 ID，再替换下方示例中的 `1`。`kill` 命令会关闭指定会话。

```sh
ighostvt-cli list
ighostvt-cli capture 1
ighostvt-cli capture 1 --full
ighostvt-cli send 1 text "ls -la" key Enter
ighostvt-cli send 1 key C-c
ighostvt-cli new
ighostvt-cli new -- /bin/sh -l
ighostvt-cli kill 1
```

在 Mac 上，该工具位于 `/Applications/iGhostVT.app/Contents/MacOS/ighostvt-cli`。

## 从源码构建

```sh
make deb              # iOS，roothide
make deb-rootless     # iOS，rootless
make mac-zip          # Mac
make test
```

贡献说明见 [AGENTS.md](AGENTS.md)。架构说明见 [Documents/ARCHITECTURE.md](Documents/ARCHITECTURE.md)。

## 许可证

iGhostVT 使用 [MIT 许可证](LICENSE)。

iOS 应用需要自定义固件，不适用于 App Store。Mac 应用不需要自定义固件。

欢迎加入 [Discord](https://discord.gg/vqhDEep2mN) 社区。

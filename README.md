# FCP 插件管理（FCP Plugin Manager）

**中文** | [English](README.en.md)

一个 macOS 原生小工具，用来管理 Final Cut Pro 的插件：扫描、暂停使用（禁用）、恢复、备份、删除、改名。全部在本机完成，不联网、不上传任何数据。

> **这不是可以自由商用的开源项目。**
> 源码公开可见，采用 [PolyForm Noncommercial 1.0.0](LICENSE)：允许个人学习、研究、非商业使用与修改，**不允许任何商业用途**。
> 你可以在 App Store 上买到的版本由版权人（黄宗敬）商业发行。商业授权请先联系版权人。

---

## 它能做什么

Final Cut Pro 的插件散落在六七个不同目录里，系统级和用户级混在一起，想临时关掉几个、或者清理掉不用的，手动翻文件夹很麻烦。这个工具把这些目录汇总成一张表：

- **扫描**：系统级与用户级的「效果 / 发生器 / 转场 / 标题」目录，外加 `/Library/Plug-ins/FxPlug` 与 `~/Library/Plug-ins/FxPlug`，一次全部列出
- **按工程停用**：拖入 `.fcpxml` 或整个 `.fcpbundle` 资源库，读出每个工程实际用到的效果，只停用没用到的那些；库按只读副本解析，不碰原库
- **停用 / 启用**：用户级插件直接移出原目录，FCP 立刻看不到；随时可以按原路径放回
- **备份与恢复**：删除前自动备份，之后可从「已备份」一键恢复，恢复时遇到同名插件不会覆盖
- **删除**：危险操作，永远放在最后，必须二次确认，且默认先备份
- **改名**：改真实文件夹名，FCP 菜单里显示的名字跟着变；带改名台账，随时能改回原名
- **导入译名表**：CSV / JSON 两列「原标识 → 新名字」，先出预览（原名 / 新名 / 会失败的原因），确认后才落盘
- **批量能力**：全部或按类别禁用 / 启用 / 恢复 / 恢复原名，带进度条和「停止」
- **操作日志与撤销**：每步操作都有记录，删除和禁用可以撤销
- **中英文界面**：默认中文，可在设置里切换
- **来源判定**：按包标识与代码签名区分「Apple 自带 / 第三方 / 来源未知」，不再凭安装位置猜
- **命令行工具 `fcpplugin`**：给脚本和 AI agent 用，一行命令完成查询、批量改名、禁用启用、恢复备份

## 按工程停用未使用的插件

插件装多了会拖慢 FCP 启动、也让菜单变得很长。这个功能用来回答一个问题：**我现在的工程到底用到了哪些插件？**

1. 点「扫描工程」，把 `.fcpxml` 工程文件或整个 `.fcpbundle` 资源库拖进面板
2. 面板列出事件与工程，可以选「整库」，也可以只勾某个工程
3. 实时显示「用到 N 个 / 未使用 M 个」，确认后点「停用未使用的 M 个…」
4. 停用会记成一批，随时「恢复这一批」，回到停用前的状态

关于直接读 `.fcpbundle`：

- 先把库的索引文件（`CurrentVersion.flexolibrary`、各事件与工程的 `CurrentVersion.fcpevent`、`CurrentVersion.plist`、`Settings.plist`、`Effects.map`）用 `ditto` 复制到临时目录，跳过 `Render Files` 与媒体；解析在副本上做，原库不写入、不加锁、不改修改时间
- SQLite 以只读方式打开，效果引用从其归档对象图里读，FCP 内置效果（调色、色彩符合等）不算插件
- 库正在 FCP 里使用时只做只读分析并提示；临时副本用完即删
- 格式不认识（版本过新、字段缺失、文件损坏）时会明说「这个库的格式本工具还读不懂」，并提供「选择 XML 文件…」兜底，**不会输出猜测清单**

如果某个库读不出来，可以在 FCP 里用「文件 → 导出 XML」导出 `.fcpxml` 再拖进来，效果一样。

## 系统要求

- macOS 14（Sonoma）或更高
- 构建需要 Xcode 15 及以上（或对应版本的 Command Line Tools）
- Swift 5.9+，无任何第三方依赖

## 安装

### 用现成的 app

从 [Releases](../../releases) 下载 `FCP-Plugin-Manager-<版本>.zip`，解压后把其中的 `FCP 插件管理.app` 拖进「应用程序」。首次打开如果被系统拦截，右键 →「打开」。

> 这个 zip 未经 Apple 公证（non-notarized）。如果系统提示「无法验证开发者」，到「系统设置 → 隐私与安全性」里点「仍要打开」，或右键 app →「打开」。

### 自己构建

```bash
git clone https://github.com/huangzongjingziliu-png/fcp-plugin-manager.git
cd fcp-plugin-manager
swift build
swift run FCPXPluginManager
```

打一个可双击的 app（会同时安装到 `~/Applications`，并在 `dist/` 生成 zip）：

```bash
./Scripts/build_app.sh
```

> 在 exFAT 外置盘上构建时，建议加 `--scratch-path /tmp/fcp-build`，否则签名可能因为 `._*` 元数据文件失败。

跑测试（全部使用系统临时目录，不碰真实插件）：

```bash
swift test --scratch-path /tmp/fcp-test-build
```

## 界面用法

1. 打开后自动扫描，左侧按「全部 / 效果 / 发生器 / 转场 / 标题」分类，底部显示总数
2. 勾选插件，右键或底部按钮操作；常用的是「停用」和「启用」
3. 「已禁用」页能看到每条记录的真实状态：
   - **已停用（已生效）**：原位置确实没有这个插件了
   - **待执行管理员命令（未生效）**：系统级插件还没授权，FCP 仍会加载
   - **记录信息缺失**：老版本留下的记录，原始位置未知
4. 「已备份」页可以单个或批量恢复；恢复前会预检冲突，不会覆盖正在使用的插件
5. 顶部「⋯」菜单里有：导入译名表、恢复原名、语言切换

插件来源按包标识与代码签名判定：`com.apple.*` 或 Apple 签名的算「Apple 自带」，其余算「第三方」，两者都读不到的标「来源未知」，不猜。批量停用默认跳过 Apple 自带，第三方不论装在所有用户目录还是当前用户目录都会参与，其中装在所有用户目录的会统一走一次管理员授权。

## 命令行工具

`fcpplugin` 与 GUI 是同一份二进制，加 `--cli` 进入命令行模式。安装：

```bash
./Scripts/build_app.sh     # 先打好 app
./Scripts/install_cli.sh   # 默认装到 ~/bin/fcpplugin
```

如果 `~/bin` 不在 PATH 里，把 `export PATH="$HOME/bin:$PATH"` 加到 `~/.zshrc`。

常用例子（默认只预演，加 `--yes` 才真改文件）：

```bash
# 列出所有插件，输出 JSON 方便程序解析
fcpplugin list --json

# 只看某一类
fcpplugin list --category effects

# 只看已禁用的
fcpplugin list --disabled --json

# 按名字停用（会先打印将要做什么）
fcpplugin disable --path "3D Camera Rig" --yes

# 整类停用
fcpplugin disable --category transitions --yes

# 全部启用回来
fcpplugin enable --all --yes

# 恢复某个备份
fcpplugin restore --backup "3D Camera Rig_20261106-101500-123" --yes

# 单个改名
fcpplugin rename --path "3D Camera Rig" --name "3D Camera Rig EN" --yes

# 按映射表批量改名（先出结果，确认后加 --yes）
fcpplugin rename --map names.json
fcpplugin rename --map names.json --yes

# 查看改名台账 / 操作日志
fcpplugin ledger --json
fcpplugin log --json

# 按台账恢复原名
fcpplugin restore-name --category effects --yes
fcpplugin restore-name --all --yes
```

安全约定：

- 所有会改文件的命令**默认 dry-run**，必须加 `--yes`
- 系统级插件只打印可复制的 `sudo mv` 命令，CLI 自己不提权
- CLI 不提供批量删除
- 恢复遇到同名插件会跳过，不覆盖

### 配合 AI agent 做批量译名

CLI 不做翻译，翻译交给 agent：

1. `fcpplugin list --json > plugins.json`
2. 让 agent 按清单生成映射：`{"原路径": "英文名"}`
3. `fcpplugin rename --map map.json` 先看预览，确认后加 `--yes`

映射里的名字会先经过校验：空名字、含 `/` 等非法字符、同目录重名、路径不存在，都会在预览阶段标出，不会执行到一半才失败。

## 数据安全设计

这个工具会移动真实的插件文件，所以几条原则写死在代码里：

- **先备份，再删除**：备份失败就中止，绝不出现「没备份就删了」
- **不覆盖**：恢复或改名时目标位置已有同名插件，一律拒绝并说明，让你自己决定
- **删除走系统废纸篓**：`NSWorkspace.recycle`，随时能「放回原处」
- **系统级插件不静默改**：需要管理员密码，取消授权就只给命令和「待执行」标记，不伪造成功
- **拒绝猜**：改名台账损坏或记录缺元数据时，明确说「原名无从得知 / 原始位置未知」，不给一个猜的答案
- **改名有台账**：每次改名记录原名、新名、目录、时间、状态，存在应用自己的目录里，不依赖备份记录

## 数据存放位置

```
~/Library/Application Support/FCPPluginManager/
  Backups/     删除前的备份（每个插件一个目录，含 .metadata）
  Disabled/    停用的插件与记录
  Renames/     改名台账 ledger.json
  Operations/  操作日志 log.json
```

卸载 app 不会自动删除这些数据；确认不再需要后，手动删除整个 `FCPPluginManager` 目录即可。

## 目录结构

```
Package.swift                          SwiftPM 清单
FCPXPluginManager/
  FCPXPluginManager.swift              入口；检测 --cli 时进入命令行模式
  PluginCategory.swift                 分类、来源、侧边栏枚举（纯数据层）
  PluginViewModel.swift                扫描、备份、恢复、禁用、日志
  ContentView.swift                    界面与交互
  ProjectScan.swift                    工程扫描、与已安装插件匹配、按批次停用
  FCPBundleReader.swift                只读解析 .fcpbundle（SQLite + NSKeyedArchiver）
  ProjectBatches.swift                 工程停用批次记录与精确恢复
  HoverEffects.swift                   悬停动效
  RenameMap.swift                      译名表解析、改名预览、执行
  RenameLedger.swift                   改名台账与恢复原名
  Localization.swift                   中英文文案
  CLIRunner.swift                      命令行实现
Tests/FCPXPluginManagerTests/          单元测试（临时目录）
Scripts/
  build_app.sh                         构建、安装、打包 zip
  install_cli.sh                       安装 fcpplugin
  make_icon.swift                      用 AppKit 生成图标
```

更细的架构说明见 [DEVELOPMENT.md](DEVELOPMENT.md)。

## 隐私

完全离线，不联网、不统计、不上传。详见 [PRIVACY.md](PRIVACY.md)。

## 许可

源码可见，但**不是** OSI 定义的开源许可。允许非商业使用，禁止商业使用。完整条款见 [LICENSE](LICENSE)。

如果你用这个工具做出了作品，欢迎告诉我；发现 bug 或有功能建议，开 issue 就行。

## 免责

这是一个第三方工具，与 Apple Inc. 无关联。它会移动、备份、删除插件文件，使用前请确认你清楚自己在做什么；重要的插件建议自己再单独留一份。

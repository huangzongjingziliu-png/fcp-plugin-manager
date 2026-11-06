# 开发说明

给接手代码的人（或 AI agent）看的。用户向的说明在 [README.md](README.md)。

## 技术栈与约束

- Swift 5.9+ / SwiftUI + AppKit，Swift Package Manager 工程，无第三方依赖
- 最低 macOS 14；只在 Apple Silicon 上验证过
- 单进程、离线；没有任何网络代码
- 界面文案用 `T("中文原文")` 取当前语言，中文原文就是 key
- 测试一律在系统临时目录造数据，**不许碰真实插件目录**

## 代码结构

```
Package.swift                        SPM 清单，executable target: FCPXPluginManager
FCPXPluginManager/
  FCPXPluginManager.swift            @main；main() 检测 --cli 后转交 CLIRunner
  PluginCategory.swift               PluginCategory / SidebarItem / PluginSource 枚举
  PluginViewModel.swift              扫描、备份、恢复、禁用、日志、批量进度
  ContentView.swift                  全部界面与交互
  RenameMap.swift                    CSV/JSON 译名表解析 + 改名预览 + 执行
  RenameLedger.swift                 改名台账、恢复原名
  Localization.swift                 中英文文案表与 T()
  CLIRunner.swift                    命令行实现
Tests/FCPXPluginManagerTests/        P0 数据安全、P1 功能、改名台账
Scripts/
  build_app.sh                       构建 → 安装到 ~/Applications → 打 zip
  install_cli.sh                     安装 fcpplugin 到 ~/bin
  make_icon.swift                    AppKit 画 AppIcon.icns
```

数据层（`PluginViewModel`）只依赖 Foundation / Combine / AppKit，不 import SwiftUI。视图通过 `@Published` 驱动。

## 扫描

`PluginSource` 定义 10 个来源，系统级 6 个、用户级 4 个：

| 来源 | 路径 |
| --- | --- |
| 系统模板 | `/Library/Application Support/Final Cut Pro/Templates.localized/{Effects,Generators,Titles,Transitions}.localized` |
| 系统模板（旧命名） | `/Library/Application Support/Final Cut Pro/Templates/{Effects,Generators,Titles,Transitions}` |
| 系统 FxPlug | `/Library/Plug-ins/FxPlug` |
| 用户模板 | `~/Movies/Motion Templates.localized/{Effects,Generators,Titles,Transitions}.localized` |
| 用户模板（旧命名） | `~/Movies/Motion Templates/{Effects,Generators,Titles,Transitions}` |
| 用户 FxPlug | `~/Library/Plug-ins/FxPlug` |

只取目标目录下的一级子项，跳过隐藏项、`.localized` 目录本身和图片文件；`.plugin` / `.fxplug` / `.app` / `.component` / `.pluginkit` 等包和单文件都收。能从包内 `Info.plist` 读到版本、厂商、包标识就带上。

`PluginItem.id` 用绝对路径，不用名字——重名插件不会串号。

## 数据存放

```
~/Library/Application Support/FCPPluginManager/
  Backups/<名字>_<毫秒时间戳>[-2]/   备份的插件 + .metadata
  Disabled/<名字>_<时间戳>/          停用的插件 + .metadata
  Renames/ledger.json                改名台账
  Operations/log.json                操作日志（最多 100 条）
```

`.metadata` 是 JSON，记录 `originalPath` / `category` / `isSystemLevel` / 时间等。读取时任何一项坏了都要当成「信息缺失」处理，不能猜。

## 不可破坏的规则

1. **先备份成功，再删除**。备份失败必须中止，并明确告知哪几个没删。
2. **不覆盖**。恢复、改名、恢复原名，目标位置已有同名项时返回「已存在」，由用户决定，不静默覆盖。
3. **删除走 `NSWorkspace.shared.recycle`**，不用 `moveItem` 拼 `~/.Trash`，也不直接 `rm`。
4. **系统级不静默改**。对 `/Library` 下的路径，只有真正的权限错误才返回「需要授权」；授权用 `osascript ... with administrator privileges` 触发一次，取消则给可复制的 `sudo` 命令并标记「待执行」。
5. **状态必须如实**。`DisabledItem.isEffective` 判据是「原路径不存在」；只有它算真正停用。缺元数据的记录单独归为「信息缺失」。
6. **改名独立记账**。`Renames/ledger.json` 记录 `oldName / newName / directory / date / status`，不依赖备份记录；台账损坏时明确提示「原名无从得知」。

## 禁用 / 启用的语义

- 用户级：`moveItem` 把插件移进 `Disabled/<记录目录>/`，原位置消失，立即生效；启用时移回原路径
- 系统级：先建记录并复制一份，再走管理员授权移走原件；未授权时记录仍是「待执行」
- 启用时若原位置已有同名插件：只把禁用目录里的副本移入废纸篓，绝不覆盖正在使用的那个
- 旧版本留下的「只复制、没移走」的记录：`isEffective == false`，不计入停用数；「一键全部恢复」会把多余副本移入废纸篓

## 改名与台账

- 单个改名：`renamePlugin`
- 批量：`RenameMapParser` 解析 CSV/JSON → `buildRenamePlan` 生成逐条状态 → `applyRenamePlan` 落盘。GUI 和 CLI 共用这一套，不要复制第二份实现
- 预览状态：可执行 / 需管理员命令 / 失败（空名、非法字符 `/`、同目录重名、路径不存在、重复映射）
- 台账状态：`applied` / `renamePending` / `restored` / `restorePending`，每次扫描后按磁盘实际状态刷新
- 改名前后的台账与操作日志要能对应上

## 命令行

`main()` 里检测 `--cli` 后调用 `CLIRunner.run()`，与 GUI 共用 `PluginViewModel` 和文件操作。新增命令时不要另写一套移动逻辑。

安全约定：

- 所有改文件的命令默认 dry-run，`--yes` 才执行
- `--json` 输出给程序解析
- 系统级只打印 `sudo` 命令，CLI 不提权
- 不提供批量删除

## 本地化

- 语言存 `UserDefaults` 的 `FCPPluginManager.language`，值 `zh-Hans` / `en`
- 界面用 `T("中文")` / `T("模板 %@", 参数)`；英文表缺条目时回退中文，不会空白
- 视图根部 `.id(localization.language)`，切语言整棵树重建
- 切换语言不得影响数据、备份、禁用状态

## 构建、测试、打包

```bash
swift build
swift test --scratch-path /tmp/fcp-test-build
./Scripts/build_app.sh        # 安装到 ~/Applications，并在 dist/ 生成 zip
./Scripts/install_cli.sh      # 安装 fcpplugin
```

注意：

- 项目可能放在 exFAT 外置盘上，构建请加 `--scratch-path` 到 APFS 临时目录，否则 `._*` 元数据会让 `codesign` 失败
- exFAT 不保留权限位，仓库里先执行 `git config core.filemode false`
- `dist/` 只放 zip，不放 `.app`——外置盘上的 `.app` 会被 Launchpad 收录，导致出现重复图标
- 打包脚本在覆盖 `~/Applications` 前会检测程序是否在运行，运行中先退出再覆盖

## 测试

`Tests/FCPXPluginManagerTests` 覆盖：

- P0 数据安全：备份失败中止、备份重名不丢旧备份、恢复不覆盖、删除走回收站语义、权限错误识别
- P1 功能：扫描多根路径、详情读取、启用禁用、日志与撤销
- 改名：CSV/JSON 解析与行号报错、预览四态、执行落盘、台账持久化与恢复原名、台账损坏提示

测试全部用 `FileManager.temporaryDirectory` 下的一次性目录。

## 已知限制

- 插件预览图不做：解码插件包内容会明显拖慢扫描
- 系统级批量操作需要用户为每一批输入一次管理员密码（受 `osascript` 限制）
- 改名会让旧备份里的 `originalPath` 指向旧名字，恢复前请先恢复原名
- 界面只支持中文和英文

## 下一步可以做的

- 备份清单导出 / 按厂商分组
- 对插件目录做完整性校验（记录文件列表与大小，恢复后比对）
- 更细的批量进度（当前按条推进，没有分阶段）

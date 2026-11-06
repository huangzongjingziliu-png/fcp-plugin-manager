# 隐私说明

一句话：**这个工具完全离线，不联网，不收集任何数据。**

## 采集什么

什么都不采集。没有账号、没有登录、没有统计、没有崩溃上报、没有广告 SDK。

## 联网吗

不联网。程序里没有任何网络请求代码，不连接任何服务器（包括开发者自己的服务器）。你可以断网使用，功能不受影响。

## 数据存在哪

所有数据都在你自己的 Mac 上：

```
~/Library/Application Support/FCPPluginManager/
  Backups/     删除前的插件备份
  Disabled/    停用的插件与记录
  Renames/     改名台账
  Operations/  操作日志
```

以及程序为了工作必须读写的地方：

- Final Cut Pro 的插件目录（`/Library/Application Support/Final Cut Pro/Templates.localized`、`~/Movies/Motion Templates.localized` 等）
- `/Library/Plug-ins/FxPlug` 与 `~/Library/Plug-ins/FxPlug`
- 系统废纸篓（删除时通过系统 API 移入，可还原）

这些内容不会离开你的电脑，也不会被上传、同步或分享。

## 会用管理员密码做什么

只有在你主动对**系统级插件**执行停用、启用或改名时，程序才会通过系统弹窗请求一次管理员授权，用来移动 `/Library` 下的文件。取消授权不会有任何副作用；程序也绝不会自己提权或保存你的密码。

## 第三方

没有第三方库，也没有第三方服务。构建只依赖 Apple 官方的 Swift 工具链和系统框架。

## 删掉数据

退出程序后删除 `~/Library/Application Support/FCPPluginManager/` 即可；卸载 app 不会自动删这个目录。

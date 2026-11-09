# Pasta

<img src="Assets/PastaIcon.png" width="128" alt="Pasta 图标">

一个面向 Apple Silicon Mac 的 **NTFS 文件导入工具**。选择来源文件或文件夹及外置 NTFS 分区，Pasta 完成预检、卸载、导入和逐文件 SHA-256 读回校验。

当前版本 **0.2.1**，构建目标 macOS 15.0，已在 macOS 15.8.2 上验证。这是个人工具，不是系统级 NTFS 驱动，也不依赖 macFUSE。

## 工作方式

- 校验目标分区 UUID、外置设备属性、文件系统和可写介质，拒绝内部磁盘及整盘设备。
- 来源保留原样；同名且内容不同的目标文件会被拒绝，不自动覆盖。
- 写入前执行 NTFS 安全预检；导入后逐文件进行 SHA-256 读回校验。
- 管理员辅助程序只在用户批准的操作中运行，不安装持久服务。

写入真实磁盘仍应以已有重要数据备份为前提。请勿把此工具当作文件系统修复或格式化程序。

## 构建

需要 Apple Silicon Mac、macOS 15 或更高版本、Apple Command Line Tools 及 Python 3：

```sh
xcode-select --install
python3 build.py --clean
```

输出：`dist/Pasta.app`。应用、管理员辅助程序、NTFS 库和预检程序均从仓库内源码构建。
没有外部驱动依赖，不复用其他 macOS 版本的旧二进制。

应用下载见本仓库 **Releases**。构建使用本机临时代码签名，没有 Developer ID 公证，macOS 可能阻止直接打开下载的应用；可从源码自行构建。

## 验证

```sh
python3 Tests/compatibility_checks.py
```

检查 macOS 最低版本、架构、依赖、签名、辅助程序参数拒绝，以及磁盘选择和路径规则。

完整导入测试可另外运行：

```sh
python3 Tests/import_checks.py
```

它只访问新建的普通 NTFS 镜像文件，不访问实体磁盘；包含中文、emoji、嵌套目录、空文件、冲突拒绝及超过 4 GiB 文件的读回校验。大文件测试会临时占用较多存储空间，测试输出会给出临时目录位置。

公开仓库只包含应用所需实现与通用测试。绑定旧电脑路径、特定磁盘 UUID 的历史诊断/恢复脚本没有纳入。

## 依赖和许可

NTFS-3G 的完整依赖源码、作者信息及许可证保留在 `vendor/ntfs-3g-2026.9.28`。
本项目导入引擎 `Sources/import_engine.c` 已声明 **GPL-2.0-or-later**；依赖及预检工具遵循各文件的原有许可。
参见 [COPYING.NTFS-3G](COPYING.NTFS-3G) 和 [THIRD_PARTY.md](THIRD_PARTY.md)。

# 依赖与来源

## NTFS-3G

- 源码目录：`vendor/ntfs-3g-2026.9.28`
- 源码中保留原有版权声明、`COPYING`、`COPYING.LIB` 和 `AUTHORS`。
- 导入引擎使用 NTFS-3G 库，不使用 FUSE 驱动。`ntfs-3g.probe` 从原有源码构建。
- `Sources/import_engine.c` 按文件头声明采用 GPL-2.0-or-later。
- 应用包包含 NTFS-3G 的许可和作者文件；仓库及每次发布对应标签提供完整引擎源码和构建脚本。

Swift 界面、授权胶水代码与图标沿用个人项目内容，本次上传未另行新增许可授权。Pasta 与 Apple、NTFS-3G 的维护者没有官方关联。

# Blender 插件加密工具

当前版本：**v26.6.24**

Windows 桌面工具：将 Blender 插件的 Python 脚本编译为 `.pyd` 核心，生成包含壳层 `__init__.py` 和核心模块的插件 ZIP。

## 下载与运行

1. 在此仓库的 **Releases** 中下载 `Blender-Plugin-Encryption-Tool-v26.6.24-Windows-x64.zip` 完整便携包。
2. 将压缩包完整解压到本机可写目录，建议使用简短的英文路径，例如 `D:\BlenderEncryptTool`。
3. 双击 `Start Tool.bat` 启动，也可以把一个 `.py` 文件拖到该 BAT 上。
4. 选择源脚本、目标 Python 版本和输出目录，点击“开始加密”。

便携包面向 Windows 64 位，内置 Python 3.10～3.14、Cython、setuptools 和 MinGW GCC。通常无需另外安装 Python 或编译器；仍需在目标电脑上验证实际加密和 Blender 安装结果。

请根据目标 Blender 使用的 Python 版本选择编译版本。生成的 `.pyd` 面向对应的 Windows / Python 环境，不能直接用于 macOS 或 Linux。

> GitHub 自动生成的 “Source code” ZIP 只包含本项目源码，不包含 Python 和编译器，不能直接作为便携包运行。

## 源码目录

```text
assets/                  窗口图标
config/versions.json     目标 Python 版本和相对路径配置
scripts/gui_launcher.ps1 Windows Forms 界面
scripts/builder_backend.py 编译和打包后台
scripts/package_release.py 完整便携包打包脚本
Start Tool.bat           启动入口
README.txt              随便携包附带的简要说明
```

`compiler/`、`python_envs/` 通过完整便携包分发，不纳入 Git 历史。`work/`、`output/`、`dist/` 分别用于临时构建、加密输出和发行压缩包，均不上传源码仓库。

## 从源码使用

克隆源码后，从同版本完整便携包中复制 `compiler/` 和 `python_envs/` 到项目根目录，保持原有目录结构，再运行 `Start Tool.bat`。

## 制作完整便携包

在包含完整运行环境的项目根目录中运行：

```powershell
.\python_envs\py314\python.exe -B scripts\package_release.py
```

脚本从 GUI 的 `$ToolVersion` 读取版本号，在 `dist/` 生成完整 ZIP 及 SHA-256 校验文件。压缩包包含项目代码、图标、配置、Python 和编译器（保留各自附带的许可证文件），排除已有加密结果、临时日志、缓存及 Git 元数据。

## 使用边界

- 源脚本需要包含顶层 `bl_info`，具体支持范围以编译后台处理逻辑为准。
- 编译保护不等同于保证源码无法被逆向分析。
- 当前工作目录和日志用于本机构建，请避免同时发起多个编译任务。
- 窗口标题显示版本号；界面内部主标题保持不带版本号。

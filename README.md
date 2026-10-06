# Yokogawa OSA 光谱仪控制界面

用于 Yokogawa AQ6370D 光谱仪的以太网远程控制，提供 MATLAB 与 Python 两个可分别下载的版本。

## 选择下载版本

| 版本 | 下载 | 使用环境 |
| --- | --- | --- |
| MATLAB 版 | [下载 MATLAB 版 ZIP](https://github.com/Jerry-behappy/Yokogawa-OSA-GUI/releases/latest/download/Yokogawa-OSA-MATLAB.zip) | MATLAB R2023a 或更新版本 |
| Python 版 | [下载 Python 版 ZIP](https://github.com/Jerry-behappy/Yokogawa-OSA-GUI/releases/latest/download/Yokogawa-OSA-Python.zip) | Python 3.10 或更新版本 |

也可查看 [全部发布版本](https://github.com/Jerry-behappy/Yokogawa-OSA-GUI/releases)，或通过仓库 `Code → Download ZIP` 下载两个版本的完整源码。私有仓库及下载附件需要登录具有访问权限的 GitHub 账号。

## 功能

- Net(Socket) 以太网连接、匿名认证与仪器识别。
- 中心波长、跨度、分辨率、灵敏度、自动/手动点数配置。
- 单次采集与连续采集；每轮完成数据读取和绘图后启动下一轮。
- TRA/TRB/TRC 显示、WRITE/FIX 属性与仪器端 `A-B(LOG)` 数学 Trace。
- 三条 Trace 在窗口内独立标签页显示，支持自动或手动坐标范围。
- 保存指定 Trace 为 MAT、CSV，包含采集配置和时间等元数据，重名自动编号。
- 保存连接、采集、绘图和导出设置。

## 快速开始

仪器选择 `SYSTEM → Remote Interface → Net(Socket)`，使电脑与仪器处于可通信的网络。默认连接参数为 `192.168.3.63:10001`，超时 5 秒；请按仪器实际配置修改。

**MATLAB：** 解压 MATLAB 下载包，进入其中的 `matlab` 文件夹，在 MATLAB 命令窗口运行：

```matlab
yokogawa_OSA_GUI
```

**Python：** 解压 Python 下载包，进入其中的 `python` 文件夹，先运行 `安装依赖.bat`，再运行 `启动Python版.bat`。也可执行：

```powershell
python -m pip install -r requirements.txt
python yokogawa_OSA_GUI.py
```

## 采集行为

两版均以 SINGLE 扫描完成一轮采集；单次采集结束，或停止软件连续采集并完成最后一轮后，恢复仪器 REPEAT 扫描。因此，停止软件采集后，仪器仍会自行扫描。

TRA/TRB 等普通曲线显示功率 `Power (dBm)`；启用 `TRC = TRA − TRB (LOG)` 时，TRC 显示 `Loss (dB)`。数学表达式保持 A−B，不对符号做额外变换。

MATLAB 目录保留提供的原始程序。Python 版使用后台通信线程和 GUI 主线程绘图，按 Trace 自身点数校验 FIX 曲线，保存请求配置与读回配置。两版 MAT 字段 `AcquiredAt` 分别使用 MATLAB datetime 和文本时间戳。

## 目录

```text
matlab/  MATLAB 原始程序与使用说明
python/  Python 程序、依赖、Windows 启动脚本、使用说明与离线测试
tools/   两个独立 ZIP 下载包的生成脚本
```

详细操作见 [MATLAB 使用说明](matlab/使用说明.md) 和 [Python 使用说明](python/使用说明.md)。

## 验证状态

已在 Windows 上完成 MATLAB R2023a 静态检查和无仪器界面启动/关闭检查，以及 Python 3.12 的离线通信、数据解析、MAT/CSV 导出和五轮 GUI 串行采集测试。MATLAB 静态检查仅有数组扩容、通过 `save` 使用的变量等提示。离线测试使用模拟数据，不代表已经完成实物仪器联调。

通信命令参考 [Yokogawa 官方远程控制手册 IM AQ6370C-17EN](https://cdn.tmi.yokogawa.com/1/6057/files/IMAQ6370C-17EN.pdf)。

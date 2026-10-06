"""Yokogawa AQ6370D 光谱仪：Socket 通信、采集、绘图和 MAT/CSV 导出。"""
from __future__ import annotations

import argparse
import csv
import json
import math
import os
from pathlib import Path
import queue
import re
import socket
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime
from typing import Callable

import numpy as np
from scipy.io import savemat

TRACES = ("TRA", "TRB", "TRC")
RBWS = ("0.02 nm", "0.05 nm", "0.1 nm", "0.2 nm", "0.5 nm", "1 nm", "2 nm")
SENSITIVITIES = {"NORMAL": 6, "MID": 2, "HIGH1": 3, "HIGH2": 4}
POINTS = ("Auto", "101", "201", "501", "1001", "2001", "5001", "10001", "20001", "50001")
ATTRIBUTES = {"0": "WRITE", "1": "FIX", "2": "MAX", "3": "MIN", "4": "RAVG", "5": "CALC"}
COLORS = {"TRA": "#0072bd", "TRB": "#d95319", "TRC": "#77ac30"}


def numeric_list(response: str, label: str = "数据") -> np.ndarray:
    text = response.strip()
    if not text:
        raise ValueError(f"{label}返回为空")
    if re.search(r"[,;]\s*[,;]|^[,;]|[,;]$", text):
        raise ValueError(f"{label}存在缺失数值")
    tokens = re.split(r"[,;\s]+", text)
    # 首尾分隔符和缺失元素也属于损坏响应，不能静默丢弃。
    try:
        values = np.array([float(token) for token in tokens], dtype=float)
    except ValueError as exc:
        raise ValueError(f"{label}含无法解析的数值") from exc
    if not np.all(np.isfinite(values)):
        raise ValueError(f"{label}含非有限数值")
    return values


def scalar(response: str, label: str) -> float:
    values = numeric_list(response, label)
    if values.size != 1:
        raise ValueError(f"{label}应为单个数值")
    return float(values[0])


def point_count(response: str) -> int:
    value = scalar(response, "点数")
    if not value.is_integer() or not 1 <= value <= 50001:
        raise ValueError(f"仪器返回的点数无效：{response}")
    return int(value)


@dataclass(frozen=True)
class ScanConfig:
    center_nm: float = 1310.0
    span_nm: float = 100.0
    rbw: str = "0.02 nm"
    sensitivity: str = "NORMAL"
    points: str = "Auto"
    traces: tuple[str, ...] = ("TRA",)
    attributes: tuple[str, ...] = ("WRITE", "WRITE", "WRITE")
    math_enabled: bool = False

    def validate(self) -> None:
        if not all(math.isfinite(v) for v in (self.center_nm, self.span_nm)):
            raise ValueError("波长和跨度必须为有限数值")
        if self.span_nm < 0.01 or self.center_nm - self.span_nm / 2 < 600 or self.center_nm + self.span_nm / 2 > 1700:
            raise ValueError("AQ6370D 扫描起止波长须在 600–1700 nm 内，跨度至少 0.01 nm")
        if self.rbw not in RBWS or self.sensitivity not in SENSITIVITIES or self.points not in POINTS:
            raise ValueError("分辨率、灵敏度或点数设置无效")
        if not self.traces or len(set(self.traces)) != len(self.traces) or any(t not in TRACES for t in self.traces):
            raise ValueError("请至少选择一条有效 Trace")
        if len(self.attributes) != 3 or any(a not in ("WRITE", "FIX") for a in self.attributes):
            raise ValueError("Trace 属性须为 WRITE 或 FIX")


class OSAClient:
    """仅由单个工作线程发命令；close 可从 GUI 线程取消阻塞读写。"""

    def __init__(self) -> None:
        self.sock: socket.socket | None = None
        self.buffer = bytearray()
        self.timeout = 5.0
        self.instrument_id = ""
        self._lock = threading.Lock()
        self._closed = threading.Event()

    def connect(self, host: str, port: int, timeout: float) -> str:
        if self._closed.is_set():
            raise ConnectionError("连接已取消")
        if not host.strip() or not 1 <= port <= 65535 or not 1 <= timeout <= 120:
            raise ValueError("请检查 IP、端口和超时（1–120 秒）")
        self.timeout = timeout
        connection = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        with self._lock:
            if self._closed.is_set():
                connection.close()
                raise ConnectionError("连接已取消")
            self.sock = connection
        try:
            connection.settimeout(timeout)
            connection.connect((host.strip(), port))
            reply = self.query('open "anonymous"')
            if "ready" not in reply.lower():
                if "authenticate" not in reply.lower():
                    raise ConnectionError(f"仪器未返回认证提示：{reply}")
                reply = self.query(" ")  # 官方匿名认证示例发送空格密码。
            if "ready" not in reply.lower():
                raise ConnectionError(f"匿名认证失败：{reply}")
            self.instrument_id = self.query("*IDN?").strip()
            if not self.instrument_id:
                raise ConnectionError("仪器未返回 *IDN? 信息")
            return self.instrument_id
        except Exception:
            self.close()
            raise

    def close(self) -> None:
        self._closed.set()
        with self._lock:
            connection, self.sock = self.sock, None
        if connection is not None:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()

    def write(self, command: str) -> None:
        if "\n" in command or "\r" in command:
            raise ValueError("命令不能含换行")
        connection = self.sock
        if connection is None or self._closed.is_set():
            raise ConnectionError("仪器连接已关闭")
        try:
            connection.sendall((command + "\r\n").encode("ascii"))
        except OSError:
            self.close()
            raise

    def readline(self) -> str:
        deadline = time.monotonic() + self.timeout
        try:
            while True:
                newline = self.buffer.find(b"\n")
                if newline >= 0:
                    line = bytes(self.buffer[:newline]).rstrip(b"\r")
                    del self.buffer[:newline + 1]
                    return line.decode("ascii")
                connection = self.sock
                if connection is None or self._closed.is_set():
                    raise ConnectionError("仪器连接已关闭")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("接收仪器响应超时")
                connection.settimeout(remaining)
                chunk = connection.recv(65536)
                if not chunk:
                    raise ConnectionError("仪器已断开连接")
                self.buffer.extend(chunk)
                if len(self.buffer) > 16 * 1024 * 1024:
                    raise ValueError("响应超过允许长度")
        except (OSError, ValueError):
            # 超时后旧响应可能迟到；关闭连接避免错配后续查询。
            self.close()
            raise
        finally:
            connection = self.sock
            if connection is not None:
                try:
                    connection.settimeout(self.timeout)
                except OSError:
                    pass

    def query(self, command: str) -> str:
        self.write(command)
        return self.readline()

    def configure(self, config: ScanConfig) -> None:
        config.validate()
        commands = [
            f":SENS:WAV:CENT {config.center_nm * 1e-9:.12g}",
            f":SENS:WAV:SPAN {config.span_nm * 1e-9:.12g}",
            f":SENS:BANDWIDTH {float(config.rbw.split()[0]) * 1e-9:.3g}",
            f":SENS:SENS {SENSITIVITIES[config.sensitivity]}",
            f":SENSE:SWEEP:POINTS:AUTO {'ON' if config.points == 'Auto' else 'OFF'}",
        ]
        if config.points != "Auto":
            commands.append(f":SENSE:SWEEP:POINTS {int(config.points)}")
        for name, attribute in zip(TRACES, config.attributes):
            commands.append(f":TRACE:STATE:{name} {'ON' if name in config.traces else 'OFF'}")
            commands.append(f":TRACE:ATTRIBUTE:{name} {attribute}")
        if config.math_enabled:
            commands.append(":CALCULATE:MATH:TRC A-B(LOG)")
        for command in commands:
            self.write(command)

    def restore_repeat(self) -> None:
        self.write(":INITIATE:SMODE REPEAT;:INITIATE")

    def read_trace(self, name: str, expected: int, progress: Callable[[str], None]) -> tuple[np.ndarray, np.ndarray]:
        last_error = "无数据"
        for attempt in range(3):
            # 每次均收完 X/Y 两条响应再校验，重试时不存在未读的查询响应。
            x_response = self.query(f":TRACE:X? {name}")
            y_response = self.query(f":TRACE:Y? {name}")
            try:
                x = numeric_list(x_response, f"{name} X")
                y = numeric_list(y_response, f"{name} Y")
                if x.size != expected or y.size != expected:
                    raise ValueError(f"期望 {expected} 点，收到 X={x.size}、Y={y.size}")
                if np.any(x <= 0) or (x.size > 1 and np.any(np.diff(x) <= 0)):
                    raise ValueError("波长数组须为正数且严格递增")
                return x, y
            except ValueError as exc:
                last_error = str(exc)
                if attempt < 2:
                    progress(f"{name} 响应无效，重试 {attempt + 2}/3")
        raise ValueError(f"{name} 数据接收失败：{last_error}")

    def acquire(self, config: ScanConfig, progress: Callable[[str], None] = lambda _: None) -> list[dict]:
        self.configure(config)
        self.write(":FORMAT:DATA ASCII")
        progress("正在执行 SINGLE 扫描，等待 *OPC?…")
        self.write(":INITIATE:SMODE SINGLE;:INITIATE")
        if self.query("*OPC?").strip() != "1":
            raise ValueError("*OPC? 未返回 1，扫描未正常完成")
        rbw_raw = self.query(":SENSE:BANDWIDTH?").strip()
        rbw_m = scalar(rbw_raw, "分辨率")
        if rbw_m <= 0:
            raise ValueError("仪器返回的分辨率无效")
        sensitivity_raw = self.query(":SENSE:SENSE?").strip()
        sensitivity_mode = scalar(sensitivity_raw, "灵敏度")
        sensitivity_text = next((k for k, v in SENSITIVITIES.items() if v == sensitivity_mode), sensitivity_raw)
        sweep_points = point_count(self.query(":SENSE:SWEEP:POINTS?"))
        center_m = scalar(self.query(":SENSE:WAVELENGTH:CENTER?"), "实际中心波长")
        span_m = scalar(self.query(":SENSE:WAVELENGTH:SPAN?"), "实际跨度")
        acquired_at = datetime.now().isoformat(sep=" ", timespec="milliseconds")
        frame = []
        for name in config.traces:
            progress(f"正在读取 {name}…")
            # FIX Trace 可能来自旧扫描，使用该 Trace 自身的实际点数。
            expected = point_count(self.query(f":TRACE:SNUMBER? {name}"))
            x_m, y = self.read_trace(name, expected, progress)
            attribute_raw = self.query(f":TRACE:ATTRIBUTE:{name}?").strip().upper()
            attribute = ATTRIBUTES.get(attribute_raw, attribute_raw)
            expression = self.query(":CALCULATE:MATH:TRC?").strip().upper() if name == "TRC" else ""
            is_loss = name == "TRC" and expression == "A-B(LOG)"
            if name == "TRC" and config.math_enabled and not is_loss:
                raise ValueError(f"TRC 数学表达式未生效：{expression}")
            frame.append(dict(
                XDataMeters=x_m, XDataNm=x_m * 1e9, YData=y, Trace=name,
                TraceAttribute=attribute, RequestedTraceAttribute=config.attributes[TRACES.index(name)],
                InstrumentID=self.instrument_id, AcquiredAt=acquired_at,
                CenterWavelengthNm=center_m * 1e9, SpanNm=span_m * 1e9,
                RequestedCenterWavelengthNm=config.center_nm, RequestedSpanNm=config.span_nm,
                RBW=rbw_raw, RBWMeters=rbw_m, ResolutionNm=rbw_m * 1e9,
                SENS=sensitivity_raw, SensitivityMode=sensitivity_mode, SensitivityText=sensitivity_text,
                SamplePointsSetting=config.points, SweepPoints=sweep_points,
                ExpectedPoints=expected, ActualPoints=int(y.size), MathEnabled=config.math_enabled,
                MathExpression=expression if is_loss else "", IsLossTrace=is_loss,
                YUnit="Loss_dB" if is_loss else "Power_dBm",
            ))
        return frame


def save_frame(frame: list[dict], folder: Path, base: str, selected: tuple[str, ...],
               mat: bool = True, csv_format: bool = True, rbw: bool = True, sens: bool = True) -> list[Path]:
    chosen = [td for td in frame if td["Trace"] in selected]
    if not chosen or not (mat or csv_format):
        raise ValueError("请选择已有数据的 Trace 和至少一种保存格式")
    for td in chosen:
        expected = td["ActualPoints"]
        if any(np.size(td[key]) != expected for key in ("XDataMeters", "XDataNm", "YData")):
            raise ValueError("保存数据长度不一致")
    folder.mkdir(parents=True, exist_ok=True)
    base = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", base.strip()).rstrip(". ") or "OSA_trace"
    paths = []
    for td in chosen:
        stem = folder / f"{base}_{td['Trace']}"
        suffix = 0
        while Path(str(stem) + ".mat").exists() or Path(str(stem) + ".csv").exists():
            suffix += 1
            stem = folder / f"{base}_{td['Trace']}_{suffix}"
        # 不用 with_suffix 替换用户基础名称中的点号。
        target_base = str(stem)
        payload = dict(td)
        if not rbw:
            for key in ("RBW", "RBWMeters", "ResolutionNm"):
                payload.pop(key, None)
        if not sens:
            for key in ("SENS", "SensitivityMode", "SensitivityText"):
                payload.pop(key, None)
        if mat:
            path = Path(target_base + ".mat")
            with path.open("xb") as handle:
                savemat(handle, payload, do_compression=True, oned_as="column")
            paths.append(path)
        if csv_format:
            path = Path(target_base + ".csv")
            with path.open("x", newline="", encoding="utf-8-sig") as handle:
                writer = csv.writer(handle)
                for key, value in payload.items():
                    if key not in ("XDataMeters", "XDataNm", "YData"):
                        writer.writerow([f"# {key}", str(value).replace("\r", " ").replace("\n", " ")])
                writer.writerow([])
                writer.writerow(["Wavelength_nm", td["YUnit"]])
                writer.writerows(zip((f"{v:.15g}" for v in td["XDataNm"]), (f"{v:.15g}" for v in td["YData"])))
            paths.append(path)
    return paths


def settings_defaults() -> dict:
    return dict(ip="192.168.3.63", port=10001, timeout=5, center=1310, span=100,
                rbw="0.02 nm", sensitivity="NORMAL", points="Auto", math=False,
                trace_TRA=True, trace_TRB=False, trace_TRC=False,
                attr_TRA="WRITE", attr_TRB="WRITE", attr_TRC="WRITE",
                folder=str(Path.home() / "OSA_data"), base="OSA_trace",
                save_TRA=True, save_TRB=False, save_TRC=False, mat=True, csv=True, res=True, sens=True,
                x_auto=True, x_min=1260, x_max=1360, y_auto=True, y_min=-100, y_max=0,
                geometry="1280x860+70+40")


def load_settings(path: Path) -> dict:
    defaults = settings_defaults()
    try:
        saved = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(saved, dict):
            return defaults
    except (OSError, ValueError):
        return defaults
    bounds = {"port": (1, 65535), "timeout": (1, 120), "center": (600, 1700),
              "span": (0.01, 1100), **{k: (-1e9, 1e9) for k in ("x_min", "x_max", "y_min", "y_max")}}
    choices = {"rbw": RBWS, "sensitivity": tuple(SENSITIVITIES), "points": POINTS,
               **{f"attr_{t}": ("WRITE", "FIX") for t in TRACES}}
    for key, default in list(defaults.items()):
        value = saved.get(key, default)
        if isinstance(default, bool):
            valid = isinstance(value, bool)
        elif key in bounds:
            valid = isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and bounds[key][0] <= value <= bounds[key][1]
            if key == "port":
                valid = valid and float(value).is_integer()
        elif key in choices:
            valid = value in choices[key]
        else:
            valid = isinstance(value, str) and bool(value.strip())
            if key == "geometry":
                valid = valid and bool(re.fullmatch(r"\d{3,5}x\d{3,5}[+-]\d+[+-]\d+", value))
        if valid:
            defaults[key] = value
    for axis in ("x", "y"):
        if defaults[f"{axis}_min"] >= defaults[f"{axis}_max"]:
            fallback = settings_defaults()
            defaults[f"{axis}_min"] = fallback[f"{axis}_min"]
            defaults[f"{axis}_max"] = fallback[f"{axis}_max"]
    return defaults


class OSAGUI:
    def __init__(self, root, *, settings_path: Path | None = None, client_factory=OSAClient) -> None:
        import tkinter as tk
        from tkinter import ttk
        from matplotlib import rcParams
        from matplotlib.figure import Figure
        from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg, NavigationToolbar2Tk

        self.root = root
        self.tk, self.ttk = tk, ttk
        self.settings_path = settings_path or Path(os.environ.get("LOCALAPPDATA", str(Path.home() / ".config"))) / "YokogawaOSAGUI" / "settings.json"
        settings = load_settings(self.settings_path)
        self.vars = {k: (tk.BooleanVar(value=v) if isinstance(v, bool) else tk.StringVar(value=str(v))) for k, v in settings.items() if k != "geometry"}
        self.client_factory = client_factory
        self.client = None
        self.connected = self.busy = self.continuous = self.closing = False
        self.epoch = 0
        self.completed = 0
        self.latest: list[dict] = []
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="OSA")
        self.events: queue.Queue = queue.Queue()
        self.next_round = None
        self.settings_after = None
        self.poll_after = None
        self.repeat_error = None
        self.axis_limits = {axis: (settings[f"{axis}_auto"], settings[f"{axis}_min"], settings[f"{axis}_max"]) for axis in ("x", "y")}
        self.connection_widgets = []
        self.instrument_widgets = []
        self.save_checks = {}
        self.lines, self.axes, self.canvases = {}, {}, {}
        root.title("Yokogawa OSA 远程控制 · Python")
        root.geometry(settings["geometry"])
        root.minsize(1120, 810)
        root.protocol("WM_DELETE_WINDOW", self.close)
        ttk.Style(root).configure("TLabel", font=("Microsoft YaHei UI", 10))
        rcParams["font.family"] = ["Microsoft YaHei", "DejaVu Sans"]
        rcParams["axes.unicode_minus"] = False
        outer = ttk.Frame(root, padding=10)
        outer.pack(fill="both", expand=True)
        outer.columnconfigure(0, weight=1)
        outer.rowconfigure(1, weight=1)
        connection = ttk.LabelFrame(outer, text="以太网连接", padding=8)
        connection.grid(row=0, column=0, sticky="ew", pady=(0, 8))
        for col, (label, key, width) in enumerate((("IP", "ip", 18), ("端口", "port", 8), ("超时(s)", "timeout", 6))):
            ttk.Label(connection, text=label).grid(row=0, column=col * 2, padx=4)
            entry = self.entry(connection, key, width=width)
            entry.grid(row=0, column=col * 2 + 1, padx=4)
            self.connection_widgets.append(entry)
        self.connection_state = ttk.Label(connection, text="● 未连接")
        self.connection_state.grid(row=0, column=6, padx=12)
        self.connect_button = ttk.Button(connection, text="连接", command=self.toggle_connection)
        self.connect_button.grid(row=0, column=7, sticky="e")
        self.identity = ttk.Label(connection, text="仪器：尚未连接", wraplength=950)
        self.identity.grid(row=1, column=0, columnspan=8, sticky="w", pady=(8, 0))
        connection.columnconfigure(7, weight=1)
        content = ttk.Frame(outer)
        content.grid(row=1, column=0, sticky="nsew")
        content.columnconfigure(1, weight=1)
        content.rowconfigure(0, weight=1)
        controls = ttk.Frame(content, width=395)
        controls.grid(row=0, column=0, sticky="nsw", padx=(0, 8))
        scan = ttk.LabelFrame(controls, text="扫描与采集", padding=8)
        scan.pack(fill="x", pady=(0, 8))
        for row, (label, key, choices) in enumerate((("中心波长 (nm)", "center", None), ("跨度 (nm)", "span", None),
                ("分辨率", "rbw", RBWS), ("灵敏度模式", "sensitivity", tuple(SENSITIVITIES)), ("点数", "points", POINTS))):
            ttk.Label(scan, text=label).grid(row=row, column=0, sticky="w", padx=4, pady=3)
            widget = self.combo(scan, key, choices) if choices else self.entry(scan, key)
            widget.grid(row=row, column=1, sticky="ew", pady=3)
            self.instrument_widgets.append(widget)
        scan.columnconfigure(1, weight=1)
        self.single_button = ttk.Button(scan, text="单次采集", command=lambda: self.start(False))
        self.single_button.grid(row=5, column=0, columnspan=2, sticky="ew", pady=5)
        self.start_button = ttk.Button(scan, text="开始连续采集", command=lambda: self.start(True))
        self.start_button.grid(row=6, column=0, sticky="ew", padx=(0, 4))
        self.stop_button = ttk.Button(scan, text="停止连续采集", command=self.stop)
        self.stop_button.grid(row=6, column=1, sticky="ew")
        self.acquisition_info = ttk.Label(scan, text="等待采集", wraplength=350)
        self.acquisition_info.grid(row=7, column=0, columnspan=2, sticky="w", pady=6)
        trace = ttk.LabelFrame(controls, text="Trace 配置", padding=8)
        trace.pack(fill="x", pady=(0, 8))
        for row, name in enumerate(TRACES):
            check = ttk.Checkbutton(trace, text=f"显示 {name}", variable=self.vars[f"trace_{name}"], command=self.setting_changed)
            check.grid(row=row, column=0, sticky="w", pady=4)
            combo = self.combo(trace, f"attr_{name}", ("WRITE", "FIX"))
            combo.grid(row=row, column=1, sticky="ew", padx=8)
            self.instrument_widgets.extend((check, combo))
        math_check = ttk.Checkbutton(trace, text="TRC = TRA − TRB (LOG)", variable=self.vars["math"], command=self.setting_changed)
        math_check.grid(row=3, column=0, columnspan=2, sticky="w", pady=4)
        self.instrument_widgets.append(math_check)
        ttk.Label(trace, text="连接后修改自动下发；采集中锁定参数。", wraplength=350).grid(row=4, column=0, columnspan=2, sticky="w")
        trace.columnconfigure(1, weight=1)
        save = ttk.LabelFrame(controls, text="保存当前采集", padding=8)
        save.pack(fill="x")
        ttk.Label(save, text="目录").grid(row=0, column=0, sticky="w")
        self.entry(save, "folder", instrument=False, width=24).grid(row=0, column=1, columnspan=2, sticky="ew", padx=4)
        ttk.Button(save, text="选择…", width=7, command=self.browse).grid(row=0, column=3)
        ttk.Label(save, text="名称").grid(row=1, column=0, sticky="w", pady=5)
        self.entry(save, "base", instrument=False, width=24).grid(row=1, column=1, columnspan=3, sticky="ew", padx=4)
        for col, name in enumerate(TRACES, 1):
            widget = ttk.Checkbutton(save, text=name, variable=self.vars[f"save_{name}"])
            widget.grid(row=2, column=col, sticky="w", pady=4)
            self.save_checks[name] = widget
        for row, title, options in ((3, "格式", (("MAT", "mat"), ("CSV", "csv"))), (4, "元数据", (("Res", "res"), ("SENS", "sens")))):
            ttk.Label(save, text=title).grid(row=row, column=0, sticky="w")
            for col, (label, key) in enumerate(options, 1):
                ttk.Checkbutton(save, text=label, variable=self.vars[key]).grid(row=row, column=col, sticky="w", pady=3)
        self.save_button = ttk.Button(save, text="保存", command=self.save)
        self.save_button.grid(row=5, column=0, columnspan=4, sticky="ew", pady=5)
        ttk.Label(save, text="重名自动追加 _1、_2…；保存已采集参数。", wraplength=350).grid(row=6, column=0, columnspan=4, sticky="w")
        save.columnconfigure(1, weight=1)
        plots = ttk.Frame(content)
        plots.grid(row=0, column=1, sticky="nsew")
        plots.columnconfigure(0, weight=1)
        plots.rowconfigure(1, weight=1)
        self.plot_info = ttk.Label(plots, text="尚无采集数据", anchor="center")
        self.plot_info.grid(row=0, column=0, sticky="ew", pady=4)
        self.tabs = ttk.Notebook(plots)
        self.tabs.grid(row=1, column=0, sticky="nsew")
        for name in TRACES:
            tab = ttk.Frame(self.tabs)
            self.tabs.add(tab, text=name)
            figure = Figure(figsize=(7, 5), dpi=100)
            figure.subplots_adjust(left=0.14, bottom=0.14, right=0.96, top=0.91)
            axes = figure.add_subplot(111)
            axes.set(xlabel="Wavelength (nm)", ylabel="Power (dBm)", title=f"{name} - 未采集")
            axes.grid(True, alpha=0.3)
            line, = axes.plot([], [], color=COLORS[name], linewidth=1.2)
            canvas = FigureCanvasTkAgg(figure, master=tab)
            canvas.get_tk_widget().pack(fill="both", expand=True)
            NavigationToolbar2Tk(canvas, tab).update()
            self.axes[name], self.lines[name], self.canvases[name] = axes, line, canvas
        limits = ttk.Frame(plots)
        limits.grid(row=2, column=0, sticky="ew", pady=6)
        for row, axis in enumerate(("x", "y")):
            ttk.Checkbutton(limits, text=f"{axis.upper()} 自动", variable=self.vars[f"{axis}_auto"], command=self.axis_changed).grid(row=row, column=0, padx=5)
            for col, edge in enumerate(("min", "max"), 1):
                ttk.Label(limits, text="Min" if edge == "min" else "Max").grid(row=row, column=col * 2 - 1, padx=3)
                widget = self.entry(limits, f"{axis}_{edge}", instrument=False, width=10, callback=self.axis_changed)
                widget.grid(row=row, column=col * 2, sticky="ew", pady=2)
                limits.columnconfigure(col * 2, weight=1)
        self.status = ttk.Label(outer, text="就绪：请连接光谱仪", wraplength=1180)
        self.status.grid(row=2, column=0, sticky="ew", pady=(8, 0))
        self.update_states()
        self.axis_changed()
        self.poll_after = root.after(40, self.poll)

    def entry(self, parent, key, *, instrument=True, width=14, callback=None):
        widget = self.ttk.Entry(parent, textvariable=self.vars[key], width=width)
        action = callback or (self.setting_changed if instrument and key not in ("ip", "port", "timeout") else self.persist)
        widget.bind("<FocusOut>", lambda _: action())
        widget.bind("<Return>", lambda _: action())
        return widget

    def combo(self, parent, key, choices):
        widget = self.ttk.Combobox(parent, textvariable=self.vars[key], values=choices, state="readonly", width=14)
        widget.bind("<<ComboboxSelected>>", lambda _: self.setting_changed())
        return widget

    def set_status(self, text: str, error=False) -> None:
        if not self.closing:
            self.status.configure(text=text, foreground="#b91c1c" if error else "#1f2937")

    def config(self) -> ScanConfig:
        v = self.vars
        config = ScanConfig(float(v["center"].get()), float(v["span"].get()), v["rbw"].get(),
                            v["sensitivity"].get(), v["points"].get(),
                            tuple(t for t in TRACES if v[f"trace_{t}"].get()),
                            tuple(v[f"attr_{t}"].get() for t in TRACES), v["math"].get())
        config.validate()
        return config

    def persist(self) -> None:
        if self.closing:
            return
        values = {k: v.get() for k, v in self.vars.items()}
        for key in ("port", "timeout", "center", "span", "x_min", "x_max", "y_min", "y_max"):
            try:
                values[key] = float(values[key])
            except ValueError:
                values[key] = settings_defaults()[key]
        values["geometry"] = self.root.geometry()
        try:
            self.settings_path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.settings_path.with_suffix(".tmp")
            temporary.write_text(json.dumps(values, ensure_ascii=False, indent=2), encoding="utf-8")
            temporary.replace(self.settings_path)
        except OSError as exc:
            self.set_status(f"设置保存失败：{exc}", True)

    def submit(self, kind: str, action) -> None:
        if self.busy or self.closing:
            return
        self.busy = True
        self.update_states()
        epoch = self.epoch
        future = self.executor.submit(action)
        def finished(result):
            try:
                self.events.put((epoch, kind, result.result(), None))
            except Exception as exc:
                self.events.put((epoch, kind, None, exc))
        future.add_done_callback(finished)

    def toggle_connection(self) -> None:
        if self.client is not None:
            self.disconnect()
            return
        try:
            port_value = float(self.vars["port"].get())
            if not port_value.is_integer():
                raise ValueError("端口须为整数")
            host, port, timeout = self.vars["ip"].get(), int(port_value), float(self.vars["timeout"].get())
            self.client = self.client_factory()
            client = self.client
            self.set_status("正在连接光谱仪…")
            self.submit("connect", lambda: client.connect(host, port, timeout))
        except Exception as exc:
            self.disconnect(announce=False)
            self.set_status(f"连接失败：{exc}", True)

    def disconnect(self, announce=True) -> None:
        self.epoch += 1
        self.continuous = False
        self.cancel_next()
        if self.settings_after is not None:
            self.root.after_cancel(self.settings_after)
            self.settings_after = None
        client, self.client = self.client, None
        if client is not None:
            client.close()
        self.connected = self.busy = False
        self.identity.configure(text="仪器：尚未连接")
        self.acquisition_info.configure(text="采集已停止")
        self.update_states()
        if announce:
            self.set_status("已断开连接")

    def setting_changed(self) -> None:
        self.persist()
        if self.connected and not self.busy and not self.continuous:
            if self.settings_after is not None:
                self.root.after_cancel(self.settings_after)
            self.settings_after = self.root.after(150, self.apply_settings)

    def apply_settings(self) -> None:
        self.settings_after = None
        if not self.connected or self.busy or self.continuous:
            return
        try:
            config, client = self.config(), self.client
            self.submit("settings", lambda: client.configure(config))
        except ValueError as exc:
            self.set_status(str(exc), True)

    def start(self, continuous: bool) -> None:
        if not self.connected or self.busy or self.continuous:
            return
        try:
            self.config()
        except ValueError as exc:
            self.set_status(str(exc), True)
            return
        self.continuous = continuous
        self.repeat_error = None
        self.round()

    def round(self) -> None:
        self.next_round = None
        if self.closing or not self.connected or self.busy:
            return
        try:
            config, client, epoch = self.config(), self.client, self.epoch
        except ValueError as exc:
            self.continuous = False
            self.update_states()
            self.set_status(str(exc), True)
            return
        def progress(text):
            self.events.put((epoch, "progress", text, None))
        self.acquisition_info.configure(text="采集中…")
        self.submit("frame", lambda: client.acquire(config, progress))

    def stop(self) -> None:
        if not self.continuous:
            return
        self.continuous = False
        self.cancel_next()
        self.update_states()
        if self.busy:
            self.set_status("已请求停止：当前轮完成后恢复仪器 REPEAT 扫描")
        elif self.connected:
            self.finish_sweep()

    def finish_sweep(self) -> None:
        client = self.client
        self.submit("repeat", client.restore_repeat)

    def cancel_next(self) -> None:
        if self.next_round is not None:
            self.root.after_cancel(self.next_round)
            self.next_round = None

    def poll(self) -> None:
        if self.closing:
            return
        try:
            while True:
                epoch, kind, value, error = self.events.get_nowait()
                if epoch != self.epoch:
                    continue
                if kind == "progress":
                    self.acquisition_info.configure(text=value)
                    continue
                self.busy = False
                if error is not None:
                    self.continuous = False
                    self.cancel_next()
                    if isinstance(error, (OSError, ConnectionError)) or kind == "connect":
                        self.disconnect(announce=False)
                    elif kind == "frame" and self.connected:
                        self.repeat_error = f"采集失败：{error}；保留上一轮有效数据"
                        self.finish_sweep()
                    self.set_status(f"{kind} 失败：{error}；保留上一轮有效数据", True)
                    self.acquisition_info.configure(text="操作失败")
                elif kind == "connect":
                    self.connected = True
                    self.identity.configure(text=f"仪器：{value}")
                    self.set_status(f"连接成功：{value}")
                    self.persist()
                elif kind == "settings":
                    self.set_status("参数已下发")
                elif kind == "frame":
                    self.latest = value
                    self.render_frame(value)
                    self.completed += 1
                    if self.continuous:
                        # 完成三个嵌入画布的实际 draw 后才调度下一轮。
                        self.next_round = self.root.after(50, self.round)
                    elif self.connected:
                        self.finish_sweep()
                elif kind == "repeat":
                    self.acquisition_info.configure(text=f"已完成 {self.completed} 轮；仪器已恢复 REPEAT")
                    if self.repeat_error:
                        self.set_status(self.repeat_error + "；仪器已恢复 REPEAT", True)
                    else:
                        self.set_status("软件采集已结束，仪器已恢复 REPEAT 连续扫描")
                self.update_states()
        except queue.Empty:
            pass
        self.poll_after = self.root.after(40, self.poll)

    def render_frame(self, frame: list[dict]) -> None:
        by_trace = {td["Trace"]: td for td in frame}
        for name in TRACES:
            axes, line = self.axes[name], self.lines[name]
            td = by_trace.get(name)
            if td:
                line.set_data(td["XDataNm"], td["YData"])
                axes.set_title(f"{name} · {td['ActualPoints']} 点")
                axes.set_ylabel("Loss (dB)" if td["IsLossTrace"] else "Power (dBm)")
                self.vars[f"save_{name}"].set(True)
            else:
                line.set_data([], [])
                axes.set_title(f"{name} - 未采集")
                axes.set_ylabel("Power (dBm)")
                self.vars[f"save_{name}"].set(False)
            axes.relim()
            axes.autoscale(enable=True, axis="both")
        self.apply_limits()
        selected_name = TRACES[self.tabs.index(self.tabs.select())]
        if selected_name not in by_trace:
            self.tabs.select(TRACES.index(frame[0]["Trace"]))
        td = frame[0]
        counts = "、".join(f"{data['Trace']} {data['ActualPoints']} 点" for data in frame)
        self.plot_info.configure(text=f"{counts} | Res {td['ResolutionNm']:.6g} nm | {td['SensitivityText']}\n{td['AcquiredAt']}")
        self.acquisition_info.configure(text=f"已读取 {counts}")
        self.set_status(f"采集和绘图完成：{counts}")

    def apply_limits(self) -> None:
        for axis in ("x", "y"):
            auto, low, high = self.axis_limits[axis]
            if auto:
                for axes in self.axes.values():
                    axes.autoscale(enable=True, axis=axis)
            else:
                for axes in self.axes.values():
                    (axes.set_xlim if axis == "x" else axes.set_ylim)(low, high)
        for canvas in self.canvases.values():
            canvas.draw()

    def axis_changed(self) -> None:
        try:
            proposed = {}
            for axis in ("x", "y"):
                auto = self.vars[f"{axis}_auto"].get()
                low, high = float(self.vars[f"{axis}_min"].get()), float(self.vars[f"{axis}_max"].get())
                if not math.isfinite(low) or not math.isfinite(high) or low >= high:
                    raise ValueError(f"{axis.upper()} 轴范围须为有限数值，且 Min < Max")
                proposed[axis] = (auto, low, high)
            self.axis_limits = proposed
            self.apply_limits()
            self.persist()
        except ValueError as exc:
            for axis, (auto, low, high) in self.axis_limits.items():
                self.vars[f"{axis}_auto"].set(auto)
                self.vars[f"{axis}_min"].set(str(low))
                self.vars[f"{axis}_max"].set(str(high))
            self.set_status(str(exc), True)

    def update_states(self) -> None:
        available = {td["Trace"] for td in self.latest}
        for widget in self.connection_widgets:
            widget.configure(state="disabled" if self.client is not None else "normal")
        self.connect_button.configure(text="取消连接" if self.client is not None and not self.connected else "断开" if self.connected else "连接")
        self.connection_state.configure(text="● 已连接" if self.connected else "● 未连接", foreground="#17833b" if self.connected else "#a32424")
        for widget in self.instrument_widgets:
            disabled = self.busy or self.continuous
            widget.configure(state="disabled" if disabled else "readonly" if isinstance(widget, self.ttk.Combobox) else "normal")
        idle = self.connected and not self.busy and not self.continuous
        self.single_button.configure(state="normal" if idle else "disabled", text="采集中…" if self.busy else "单次采集")
        self.start_button.configure(state="normal" if idle else "disabled")
        self.stop_button.configure(state="normal" if self.connected and self.continuous else "disabled")
        self.save_button.configure(state="normal" if self.latest else "disabled")
        for name, widget in self.save_checks.items():
            widget.configure(state="normal" if name in available else "disabled")

    def browse(self) -> None:
        from tkinter import filedialog
        folder = filedialog.askdirectory(parent=self.root, title="选择 OSA 数据保存目录")
        if folder:
            self.vars["folder"].set(folder)
            self.persist()

    def save(self) -> None:
        try:
            folder = self.vars["folder"].get().strip()
            if not folder:
                raise ValueError("保存目录不能为空")
            paths = save_frame(self.latest, Path(folder), self.vars["base"].get(),
                               tuple(t for t in TRACES if self.vars[f"save_{t}"].get()),
                               self.vars["mat"].get(), self.vars["csv"].get(), self.vars["res"].get(), self.vars["sens"].get())
            self.persist()
            self.set_status(f"已保存 {len(paths)} 个文件：{folder}")
        except Exception as exc:
            self.set_status(f"保存失败：{exc}", True)

    def close(self) -> None:
        if self.closing:
            return
        self.persist()
        self.closing = True
        self.epoch += 1
        self.continuous = False
        for handle in (self.next_round, self.settings_after, self.poll_after):
            if handle is not None:
                self.root.after_cancel(handle)
        if self.client is not None:
            self.client.close()
        self.executor.shutdown(wait=False, cancel_futures=True)
        self.root.destroy()


def main() -> int:
    parser = argparse.ArgumentParser(description="Yokogawa AQ6370D 光谱仪控制界面")
    parser.add_argument("--self-test", action="store_true", help="运行离线通信、解析和导出测试")
    parser.add_argument("--gui-smoke-test", action="store_true", help="使用模拟仪器验证 GUI 采集和关闭")
    args = parser.parse_args()
    if args.self_test or args.gui_smoke_test:
        from tests.test_osa import run_tests, gui_smoke_test
        return gui_smoke_test() if args.gui_smoke_test else run_tests()
    import tkinter as tk
    root = tk.Tk()
    app = OSAGUI(root)
    try:
        root.mainloop()
    finally:
        if not app.closing:
            app.close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        import traceback
        error_text = traceback.format_exc()
        log_folder = Path(os.environ.get("LOCALAPPDATA", str(Path.home() / ".config"))) / "YokogawaOSAGUI"
        try:
            log_folder.mkdir(parents=True, exist_ok=True)
            (log_folder / "startup_error.log").write_text(error_text, encoding="utf-8")
        except OSError:
            pass
        print(error_text, file=sys.stderr)
        raise SystemExit(1)

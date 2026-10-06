"""验证通信边界、采集快照、导出以及 GUI 串行采集。"""
import csv
import json
from pathlib import Path
import socket
import tempfile
import threading
import time
import unittest

import numpy as np
from scipy.io import loadmat

from yokogawa_OSA_GUI import OSAClient, OSAGUI, ScanConfig, load_settings, numeric_list, point_count, save_frame


class FakeClient(OSAClient):
    def __init__(self):
        super().__init__()
        self.commands = []
        self.instrument_id = "YOKOGAWA,AQ6370D,OFFLINE,1.0"
        self.config_snapshot = ScanConfig()
        self.fail_trace = None
        self.truncated_remaining = 0
        self.active = 0
        self.max_active = 0
        self.repeat_count = 0
        self.scan_count = 0

    def connect(self, host, port, timeout):
        self.timeout = timeout
        return self.instrument_id

    def write(self, command):
        self.commands.append(command)
        if "SMODE REPEAT" in command:
            self.repeat_count += 1

    def configure(self, config):
        self.config_snapshot = config
        super().configure(config)

    def query(self, command):
        self.write(command)
        if command == "*OPC?":
            return "1"
        scalars = {":SENSE:BANDWIDTH?": "2e-11", ":SENSE:SENSE?": "6",
                   ":SENSE:SWEEP:POINTS?": "5", ":SENSE:WAVELENGTH:CENTER?": "1.31e-6",
                   ":SENSE:WAVELENGTH:SPAN?": "1e-7"}
        if command in scalars:
            return scalars[command]
        if command.startswith(":TRACE:SNUMBER?"):
            return "3" if command.endswith("TRB") else "5"
        if command.startswith(":TRACE:ATTRIBUTE:"):
            if "TRC" in command and self.config_snapshot.math_enabled:
                return "5"
            return "1" if "TRB" in command else "0"
        if command == ":CALCULATE:MATH:TRC?":
            return "A-B(LOG)" if self.config_snapshot.math_enabled else "NONE"
        if command.startswith(":TRACE:X?"):
            count = 3 if command.endswith("TRB") else 5
            return ",".join(str(v) for v in np.linspace(1.26e-6, 1.36e-6, count))
        if command.startswith(":TRACE:Y?"):
            if self.fail_trace and command.endswith(self.fail_trace):
                return "bad"
            if self.truncated_remaining:
                self.truncated_remaining -= 1
                return "-20,-21"
            count = 3 if command.endswith("TRB") else 5
            return ",".join(str(-20 - v) for v in range(count))
        raise AssertionError(f"模拟器未定义查询：{command}")

    def acquire(self, config, progress=lambda _: None):
        self.active += 1
        self.max_active = max(self.max_active, self.active)
        try:
            time.sleep(0.015)
            self.scan_count += 1
            return super().acquire(config, progress)
        finally:
            self.active -= 1


class OSATests(unittest.TestCase):
    def test_parser_rejects_invalid_responses(self):
        np.testing.assert_array_equal(numeric_list("1, 2;3e-2"), [1, 2, 0.03])
        for invalid in ("", "1,,2", "1,", "nan", "inf", "1,bad", "__import__('os')"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                numeric_list(invalid)
        for invalid in ("0", "50002", "1.5", "nan", "1,2"):
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                point_count(invalid)

    def test_fragmented_socket_auth_and_cancellation(self):
        # 使用回环地址，不访问任何外部设备。
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        received = []
        errors = []
        waiting = threading.Event()
        def server():
            try:
                connection, _ = listener.accept()
                with connection, connection.makefile("rb") as handle:
                    for expected, response in ((b'open "anonymous"\r\n', b"AUTHENTICATE CRAM-MD5.\r\n"),
                            (b" \r\n", b"ready\r\n"), (b"*IDN?\r\n", b"YOKOGAWA,AQ6370D,OFFLINE,1.0\r\n"),
                            (b"ARRAY?\r\n", b"1,2,3\r\n")):
                        line = handle.readline()
                        received.append(line)
                        if line != expected:
                            raise AssertionError((line, expected))
                        for byte in response:
                            connection.sendall(bytes([byte]))
                    received.append(handle.readline())
                    waiting.set()
                    handle.readline()  # GUI 主动关闭 socket 后结束。
            except Exception as exc:
                errors.append(exc)
        thread = threading.Thread(target=server, daemon=True)
        thread.start()
        client = OSAClient()
        try:
            self.assertIn("AQ6370D", client.connect("127.0.0.1", listener.getsockname()[1], 2))
            self.assertEqual(client.query("ARRAY?"), "1,2,3")
            reader_errors = []
            def blocked_read():
                try:
                    client.query("WAIT?")
                except OSError as exc:
                    reader_errors.append(exc)
            reader = threading.Thread(target=blocked_read, daemon=True)
            reader.start()
            self.assertTrue(waiting.wait(2))
            client.close()
            reader.join(2)
            self.assertFalse(reader.is_alive())
            self.assertTrue(reader_errors)
        finally:
            client.close()
            listener.close()
            thread.join(2)
        self.assertFalse(errors, errors)
        self.assertEqual(received[-1], b"WAIT?\r\n")

    def test_complete_frame_math_fixed_points_and_retry(self):
        client = FakeClient()
        client.truncated_remaining = 1
        config = ScanConfig(traces=("TRA", "TRB", "TRC"), attributes=("WRITE", "FIX", "WRITE"), math_enabled=True)
        frame = client.acquire(config)
        self.assertEqual([td["ActualPoints"] for td in frame], [5, 3, 5])
        self.assertEqual(frame[1]["TraceAttribute"], "FIX")
        self.assertEqual(frame[2]["TraceAttribute"], "CALC")
        self.assertEqual(frame[2]["YUnit"], "Loss_dB")
        self.assertEqual(frame[2]["MathExpression"], "A-B(LOG)")
        np.testing.assert_allclose(frame[0]["XDataNm"], [1260, 1285, 1310, 1335, 1360])
        self.assertEqual(client.commands.count(":TRACE:X? TRA"), 2)
        self.assertIn(":SENS:WAV:CENT 1.31e-06", client.commands)
        self.assertIn(":SENS:BANDWIDTH 2e-11", client.commands)
        self.assertIn(":CALCULATE:MATH:TRC A-B(LOG)", client.commands)
        self.assertLess(client.commands.index(":INITIATE:SMODE SINGLE;:INITIATE"), client.commands.index("*OPC?"))
        client.fail_trace = "TRC"
        with self.assertRaises(ValueError):
            client.acquire(config)
        self.assertEqual(client.commands.count(":TRACE:Y? TRC"), 4)

    def test_export_preserves_snapshot_and_avoids_collision(self):
        frame = FakeClient().acquire(ScanConfig())
        frame[0]["InstrumentID"] = 'YOKOGAWA,"quoted",AQ6370D\nOFFLINE'
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            first = save_frame(frame, folder, "sample.v1", ("TRA",))
            second = save_frame(frame, folder, "sample.v1", ("TRA",))
            self.assertEqual([p.name for p in first], ["sample.v1_TRA.mat", "sample.v1_TRA.csv"])
            self.assertEqual([p.name for p in second], ["sample.v1_TRA_1.mat", "sample.v1_TRA_1.csv"])
            data = loadmat(first[0])
            self.assertEqual(data["XDataNm"].shape, (5, 1))
            self.assertEqual(data["ExpectedPoints"][0, 0], 5)
            np.testing.assert_array_equal(data["YData"].ravel(), frame[0]["YData"])
            with first[1].open(encoding="utf-8-sig", newline="") as handle:
                rows = list(csv.reader(handle))
            header = next(i for i, row in enumerate(rows) if row and row[0] == "Wavelength_nm")
            self.assertEqual(len(rows[header + 1:]), 5)
            metadata = {row[0]: row[1] for row in rows[:header] if row}
            self.assertEqual(metadata["# InstrumentID"], 'YOKOGAWA,"quoted",AQ6370D OFFLINE')
            minimal = save_frame(frame, folder, "minimal", ("TRA",), rbw=False, sens=False)
            self.assertNotIn("RBWMeters", loadmat(minimal[0]))
            self.assertNotIn("SensitivityMode", loadmat(minimal[0]))

    def test_settings_validation(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "settings.json"
            path.write_text(json.dumps(dict(port=1.5, center="bad", rbw="bad", x_min=10, x_max=5, math="false")))
            settings = load_settings(path)
            self.assertEqual(settings["port"], 10001)
            self.assertEqual(settings["center"], 1310)
            self.assertFalse(settings["math"])
            self.assertLess(settings["x_min"], settings["x_max"])
        for config in (ScanConfig(traces=()), ScanConfig(center_nm=1690, span_nm=100), ScanConfig(span_nm=float("nan"))):
            with self.assertRaises(ValueError):
                config.validate()


def run_tests():
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(OSATests)
    return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1


def gui_smoke_test():
    import tkinter as tk
    with tempfile.TemporaryDirectory() as temporary:
        root = tk.Tk()
        app = OSAGUI(root, settings_path=Path(temporary) / "settings.json", client_factory=FakeClient)
        def pump(condition, limit=20):
            deadline = time.monotonic() + limit
            while not condition():
                if time.monotonic() >= deadline:
                    raise AssertionError("GUI 模拟采集超时")
                root.update()
                time.sleep(0.01)
        try:
            app.toggle_connection()
            pump(lambda: app.connected and not app.busy)
            client = app.client
            for name in ("TRB", "TRC"):
                app.vars[f"trace_{name}"].set(True)
            app.vars["attr_TRB"].set("FIX")
            app.vars["math"].set(True)
            render_count = [0]
            original_render = app.render_frame
            def render(frame):
                original_render(frame)
                render_count[0] += 1
                assert client.scan_count == render_count[0], "前一帧绘图结束前启动了下一轮"
                if render_count[0] == 5:
                    app.stop()
            app.render_frame = render
            app.start(True)
            pump(lambda: app.completed == 5 and not app.busy and not app.continuous)
            assert client.max_active == 1
            assert client.repeat_count == 1
            assert app.axes["TRC"].get_ylabel() == "Loss (dB)"
            assert len(app.lines["TRB"].get_ydata()) == 3
            previous = app.latest
            client.fail_trace = "TRC"
            app.start(False)
            pump(lambda: not app.busy)
            assert app.latest is previous, "失败采集覆盖了有效帧"
            assert app.completed == 5
            app.vars["x_auto"].set(False)
            app.vars["x_min"].set("1300")
            app.vars["x_max"].set("1320")
            app.axis_changed()
            assert app.axes["TRA"].get_xlim() == (1300, 1320)
            app.vars["x_min"].set("bad")
            app.axis_changed()
            assert app.vars["x_min"].get() == "1300.0"
            app.disconnect()
            assert not app.connected and client._closed.is_set()
            app.close()
            app.close()
            pump(lambda: not any(t.name.startswith("OSA") and t.is_alive() for t in threading.enumerate()), limit=2)
        finally:
            if not app.closing:
                app.close()
    print("GUI 离线测试通过：5 轮串行采集、绘图、停止恢复 REPEAT、失败保留帧、坐标范围、断开及关闭。")
    return 0

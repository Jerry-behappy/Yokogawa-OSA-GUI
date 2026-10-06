"""生成 MATLAB 和 Python 的独立下载包，不包含用户设置或采集数据。"""
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "dist"


def build():
    DESTINATION.mkdir(exist_ok=True)
    for language, label in (("matlab", "MATLAB"), ("python", "Python")):
        path = DESTINATION / f"Yokogawa-OSA-{label}.zip"
        files = sorted(p for p in (ROOT / language).rglob("*") if p.is_file()
                       and not any(part in ("__pycache__", ".venv") for part in p.parts)
                       and p.suffix not in (".pyc", ".log", ".asv"))
        with ZipFile(path, "w", ZIP_DEFLATED) as archive:
            for file in files:
                archive.write(file, str(Path(language) / file.relative_to(ROOT / language)))
        print(f"{path.name}: {len(files)} 个文件")


if __name__ == "__main__":
    build()

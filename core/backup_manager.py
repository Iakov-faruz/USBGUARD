from __future__ import annotations
import os
import tarfile
import time
from pathlib import Path
from typing import List, Optional


def create_backup(rules_dir: str, backup_dir: str, keep: int = 20) -> Optional[str]:
    rules_p = Path(rules_dir)
    backup_p = Path(backup_dir)
    if not rules_p.is_dir():
        return None
    backup_p.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y%m%d_%H%M%S")
    backup_file = backup_p / f"rules_{ts}.tar.gz"
    tmp = backup_p / f".tmp_{ts}.tar.gz"
    try:
        with tarfile.open(tmp, "w:gz") as tar:
            tar.add(rules_p, arcname=rules_p.name)
        tmp.replace(backup_file)
        backup_file.chmod(0o600)
        rotate_backups(backup_dir, keep)
        return str(backup_file)
    except Exception:
        if tmp.exists():
            tmp.unlink(missing_ok=True)
        return None


def rotate_backups(backup_dir: str, keep: int = 20) -> None:
    p = Path(backup_dir)
    if not p.is_dir():
        return
    backups = sorted(p.glob("rules_*.tar.gz"), key=lambda f: f.stat().st_mtime, reverse=True)
    for old in backups[keep:]:
        try:
            old.unlink()
        except Exception:
            pass


def list_backups(backup_dir: str) -> List[str]:
    p = Path(backup_dir)
    if not p.is_dir():
        return []
    backups = sorted(p.glob("rules_*.tar.gz"), key=lambda f: f.stat().st_mtime, reverse=True)
    return [str(b.name) for b in backups]


def restore_backup(backup_file: str, rules_dir: str) -> bool:
    import tempfile
    bpath = Path(backup_file)
    if not bpath.is_file():
        return False
    tmp = Path(tempfile.mkdtemp(prefix="usbguard_restore_"))
    try:
        with tarfile.open(bpath, "r:gz") as tar:
            tar.extractall(tmp)
        extracted = tmp / Path(rules_dir).name
        if not extracted.is_dir():
            return False
        rdir = Path(rules_dir)
        rdir.mkdir(parents=True, exist_ok=True)
        for f in extracted.glob("*.rules"):
            dest = rdir / f.name
            f.replace(dest)
            dest.chmod(0o600)
            try:
                os.chown(str(dest), 0, 0)
            except (AttributeError, PermissionError, OSError):
                pass
        return True
    except Exception:
        return False
    finally:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)

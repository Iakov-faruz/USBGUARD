from __future__ import annotations

import fcntl
import json
import logging
import os
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Generator, TextIO

from .models import now_iso

# יצירת לוגר פנימי למודול לצורך דיווח על שגיאות מערכת
logger = logging.getLogger(__name__)


@contextmanager
def file_lock(file: TextIO) -> Generator[None, None, None]:
    """
    קונטקסט מנג'ר המבצע נעילה בלעדית (Exclusive Lock) על קובץ.
    הנעילה משוחררת תמיד בסיום, גם אם נזרקת שגיאה בתוך הבלוק.
    """
    fcntl.flock(file.fileno(), fcntl.LOCK_EX)
    try:
        yield
    finally:
        fcntl.flock(file.fileno(), fcntl.LOCK_UN)


class AuditLogger:
    """
    מנהל רישום לוגים (Audit Trail) בפורמט JSON Lines.

    תכונות מרכזיות:
    - נעילת קבצים בלעדית למניעת התנגשויות כתיבה
    - הוספה אטומית של שורות
    - קידוד UTF-8 מלא
    - סנכרון פיזי לדיסק (fsync) לאחר כל כתיבה
    """

    def __init__(self, path: str):
        """אתחול נתיב הלוג ויצירת תיקיות/קובץ בסיס במידת הצורך."""
        self.path = Path(path)
        # יצירת תיקיות האב אם אינן קיימות
        self.path.parent.mkdir(parents=True, exist_ok=True)

        # יצירת קובץ הלוג ריק עם הרשאות אבטחה מחמירות אם אינו קיים
        if not self.path.exists():
            self.path.touch(mode=0o640)

    def log(
        self,
        event: str,
        actor: str = "system",
        **details: Any,
    ) -> None:
        """
        הוספת אירוע ביקורת חדש לקובץ הלוג.

        פרמטרים
        ----------
        event:
            שם האירוע המבוקר.
        actor:
            הגורם או המשתמש שהפעיל את האירוע.
        details:
            שדות ונתונים נוספים בפורמט JSON.
        """

        # הרכבת מבנה הנתונים של הלוג כולל חותמת זמן ומזהים
        record = {
            "ts": now_iso(),
            "event": event,
            "actor": actor,
            **details,
        }

        # המרת המילון למחרוזת JSON עם תמיכה בעברית ומיון מפתחות לסדר אחיד
        line = json.dumps(
            record,
            ensure_ascii=False,
            sort_keys=True,
        ) + "\n"

        try:
            # פתיחת הקובץ במצב הוספה (Append) עם קידוד תווים תקין
            with open(self.path, "a", encoding="utf-8") as file:
                # שימוש בנעילה בלעדית בזמן הכתיבה והסנכרון לדיסק
                with file_lock(file):
                    file.write(line)
                    file.flush()
                    os.fsync(file.fileno())

        except OSError:
            # תפיסת שגיאות מערכת (כגון דיסק מלא או בעיות הרשאה) ותיעודן בלוג המערכת
            logger.exception(
                "Failed writing audit log: %s",
                self.path,
            )
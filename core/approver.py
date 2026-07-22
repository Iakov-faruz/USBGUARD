from __future__ import annotations
import copy, time
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

# ייבוא רכיבי ה-Core הנדרשים לניהול המדיניות והרכיבים
from .audit import AuditLogger
from .config import Config
from .models import DeviceRecord, now_iso
from .policy_store import PolicyStore
from .rules_renderer import composite_reject_rules, render_allow, render_reject
from .usbguard_client import USBGuardClient, UsbguardError


class Approver:
    """
    מחלקת הליבה המנהלת את המדיניות, האישורים, החסימות והסנכרון של התקני USB.
    מתממשקת מול ה-PolicyStore המקומי ומול שירות ה-USBGuard של ה-Kernel.
    """

    def __init__(self, config: Config, store: PolicyStore, client: USBGuardClient, audit: AuditLogger):
        """אתחול מחלקת ההחלטות עם התלות ברכיבי המערכת השונים."""
        self.config = config
        self.store = store
        self.client = client
        self.audit = audit

    @property
    def lockdown_enabled(self) -> bool:
        """מאפיין המחזיר האם המערכת נמצאת כעת במצב סגר חירום (Lockdown)."""
        return bool(self.store.meta_get("lockdown", False))

    # ==========================================================================
    # סנכרון וניהול זמנים
    # ==========================================================================

    def sync_devices(self) -> int:
        """
        מסנכרנת את ההתקנים המזוהים בזמן אמת מול ה-USBGuard ומעדכנת את מסד הנתונים.
        מחזירה את כמות ההתקנים שסונכרנו.
        """
        observed = self.client.list_devices()
        count = 0

        for device in observed:
            existing = self.store.get_device(device.fingerprint)
            
            if existing:
                # אם ההתקן כבר מוכר, נשמור על המידע וההיסטוריה הקיימת שלו
                device.first_seen = existing.first_seen
                device.state = existing.state
                device.approved_by = existing.approved_by
                device.approved_at = existing.approved_at
                device.expires_at = existing.expires_at
                device.risk_score = existing.risk_score
                device.flags = sorted(set(existing.flags + device.flags))
            else:
                # התקן חדש שלא נראה בעבר
                device.first_seen = now_iso()
                if device.observed_target == "allow":
                    device.state = "approved-permanent"
                    device.add_flag("PRE_EXISTING_ALLOW")
                else:
                    device.state = "pending"

            device.last_seen = now_iso()
            self.store.upsert_device(device)
            count += 1

        self.audit.log("sync_devices", count=count)
        return count

    def expire_temporary(self) -> int:
        """
        סורקת התקנים שקיבלו אישור זמני (Temporary Approval) וחוסמת אותם אם פג תוקפם.
        """
        expired = 0
        now = datetime.now(timezone.utc)

        for device in self.store.list_devices(state="approved-temporary"):
            if not device.expires_at:
                continue

            try:
                expires = datetime.fromisoformat(device.expires_at)
                if expires.tzinfo is None:
                    expires = expires.replace(tzinfo=timezone.utc)
            except Exception:
                continue

            # אם זמן התוקף עבר - ביטול האישור והעברה ל-Deny
            if now >= expires:
                self.deny(device.fingerprint, actor="system", reason="temporary approval expired")
                expired += 1

        return expired

    # ==========================================================================
    # בדיקות אימות וזהות (Identity & Validation)
    # ==========================================================================

    def validate_identity(self, device: DeviceRecord) -> List[str]:
        """
        בודקת האם ההתקן עומד בדרישות האבטחה והזהות שהוגדרו בקונפיגורציה.
        מחזירה רשימת שגיאות (אם נמצאו).
        """
        errors: List[str] = []

        # בדיקת שדות חובה שהוגדרו במערכת (Interfaces, Hash וכו')
        for required in self.config.identity.required:
            if required == "interfaces":
                if not device.interfaces:
                    errors.append("missing_interfaces")
            elif required == "hash":
                if not device.hash and not device.fingerprint.startswith("sha256:"):
                    if not self.config.identity.allow_no_hw_hash:
                        errors.append("missing_hash")
                    else:
                        if "NO_HW_HASH" not in device.flags:
                            device.add_flag("NO_HW_HASH")
            else:
                if not getattr(device, required, ""):
                    errors.append(f"missing_{required}")

        # בדיקת הגנה מצירופים חשודים (כמו HID + Mass Storage)
        if self.is_composite_unexpected(device):
            errors.append("composite_unexpected")

        return errors

    def is_composite_unexpected(self, device: DeviceRecord) -> bool:
        """
        בודקת האם ההתקן הוא התקן משולב חשוד (BadUSB Attack Vectors).
        למשל: התקן שהוא גם מקלדת/עכבר (03) וגם דיסק און קי (08) או תקשורת (02).
        """
        interfaces = device.interfaces or []
        hid = any(i.lower().startswith("03:") for i in interfaces)
        mass_storage = any(i.lower().startswith("08:") for i in interfaces)
        cdc = any(i.lower().startswith("02:") for i in interfaces)

        # חסימת רכיב משולב לפי ההגדרות בקובץ הקונפיגורציה
        if self.config.composite.reject_hid_mass_storage and hid and mass_storage:
            return True
        if self.config.composite.reject_hid_cdc and hid and cdc:
            return True

        return False

    # ==========================================================================
    # פעולות שינוי מדיניות (Approve, Deny, Quarantine)
    # ==========================================================================

    def remove_rules_for_device(self, device: DeviceRecord, targets: List[str]) -> int:
        """מסירה חוקים קיימים של ההתקן מ-USBGuard לפי סוג Target (למשל allow/reject)."""
        removed = 0
        try:
            rules = self.client.list_rules()
        except UsbguardError as e:
            self.audit.log("list_rules_failed", error=str(e))
            return 0

        for rule in rules:
            if rule.observed_target not in targets:
                continue
            if not self._rule_matches(rule, device):
                continue
            if rule.observed_rule_id is None:
                continue

            try:
                self.client.remove_rule(rule.observed_rule_id)
                removed += 1
                self.audit.log("rule_removed", rule_id=rule.observed_rule_id, target=rule.observed_target, fingerprint=device.fingerprint)
            except UsbguardError as e:
                self.audit.log("rule_remove_failed", rule_id=rule.observed_rule_id, error=str(e))

        return removed

    def approve(self, fingerprint: str, permanent: bool = False, ttl: int = 300, actor: str = "cli", port_bind: bool = False) -> DeviceRecord:
        """
        מאשרת התקן לשימוש במערכת (אישור קבוע או זמני עם TTL).
        מזריקה חוק Allow ל-USBGuard ומעדכנת את מסד הנתונים.
        """
        if self.lockdown_enabled:
            raise RuntimeError("Lockdown is enabled. Approve is blocked.")

        device = self._require_device(fingerprint)
        errors = self.validate_identity(device)
        
        # אם יש חריגת אבטחה בזהות ההתקן – האישור נדחה
        if errors:
            self.audit.log("approve_rejected", actor=actor, fingerprint=device.fingerprint, errors=errors)
            raise RuntimeError(f"Approval rejected: {', '.join(errors)}")

        # ניקוי חוקים קודמים של ההתקן
        self.remove_rules_for_device(device, ["allow", "reject"])

        # יצירת חוק Allow והזרקתו ל-USBGuard
        rule_device = copy.deepcopy(device)
        if not port_bind:
            rule_device.via_port = ""  # אם לא הוגדר Port Binding, נבטל הצמדה לפורט ספציפי
            
        rule = render_allow(rule_device)
        self.client.append_rule(rule)

        # עדכון מצב ההתקן במסד הנתונים
        device.state = "approved-permanent" if permanent else "approved-temporary"
        device.approved_by = actor
        device.approved_at = now_iso()
        device.expires_at = "" if permanent else (datetime.now(timezone.utc) + timedelta(seconds=ttl)).isoformat()

        if port_bind and not device.via_port:
            device.add_flag("PORT_BIND_MISSING_PORT")

        self.store.upsert_device(device)
        self.audit.log("device_approved", actor=actor, fingerprint=device.fingerprint, permanent=permanent, ttl=ttl, port_bind=port_bind, rule=rule)

        return device

    def deny(self, fingerprint: str, actor: str = "cli", reason: str = "") -> DeviceRecord:
        """חוסמת התקן (מסירה חוקי Allow קיימים ומעדכנת את המצב ל-Denied)."""
        device = self._require_device(fingerprint)
        self.remove_rules_for_device(device, ["allow"])

        device.state = "denied"
        if reason:
            device.add_flag(reason)

        self.store.upsert_device(device)
        self.audit.log("device_denied", actor=actor, fingerprint=device.fingerprint, reason=reason)

        return device

    def quarantine(self, fingerprint: str, actor: str = "cli", reason: str = "") -> DeviceRecord:
        """מעבירה התקן חשוד להסגר (Quarantine), מזריקה חוק Reject ומעלה את ציון הסיכון."""
        device = self._require_device(fingerprint)
        self.remove_rules_for_device(device, ["allow"])

        try:
            rule = render_reject(device)
            self.client.append_rule(rule)
        except Exception as e:
            self.audit.log("quarantine_rule_failed", fingerprint=device.fingerprint, error=str(e))

        device.state = "quarantined"
        device.risk_score += 50
        device.add_flag("QUARANTINED")
        if reason:
            device.add_flag(reason)

        self.store.upsert_device(device)
        self.audit.log("device_quarantined", actor=actor, fingerprint=device.fingerprint, reason=reason, risk_score=device.risk_score)

        return device

    # ==========================================================================
    # ניהול מצבי חירום ולמידה (Lockdown & Learning Mode)
    # ==========================================================================

    def lockdown_enable(self, actor: str = "cli") -> None:
        """מפעילה מצב סגר חירום במערכת – משנה את מדיניות ה-USBGuard ל-Block."""
        prev = self.client.get_parameter("ImplicitPolicyTarget")
        self.store.meta_set("prev_implicit_policy", prev)
        self.store.meta_set("lockdown", True)

        try:
            self.client.set_parameter("ImplicitPolicyTarget", "block")
        except UsbguardError as e:
            self.audit.log("lockdown_set_parameter_failed", error=str(e))

        self.audit.log("lockdown_enabled", actor=actor, prev_policy=prev)

    def lockdown_disable(self, actor: str = "cli") -> None:
        """מבטלת את מצב הסגר במערכת."""
        prev = self.store.meta_get("prev_implicit_policy", "block")
        self.store.meta_set("lockdown", False)
        self.audit.log("lockdown_disabled", actor=actor, prev_policy=prev)

    def init_policy(self) -> int:
        """
        מאתחלת את קובץ החוקים של USBGuard: 
        מזריקה את חוקי ה-Composite Reject (הגנה מ-BadUSB) בראש הקובץ (First Match),
        ולאחר מכן מחזירה את חוקי ה-Allow הקיימים.
        
        הערה: פעולה זו אינה אטומית לחלוטין (USBGuard לא תומך ב-transaction),
        אך אנו מבצעים גיבוי של החוקים הקיימים לפני המחיקה ומנסים לשחזר במקרה כשל.
        """
        try:
            existing_rules = self.client.list_rules()
        except UsbguardError as e:
            self.audit.log("init_policy_list_failed", error=str(e))
            return 0

        existing_allows = [r for r in existing_rules if r.observed_target == "allow"]
        existing_rejects = [r for r in existing_rules if r.observed_target == "reject"]
        
        # גיבוי כל החוקים לפי סדר - למקרה שנסתנכרן בחזרה
        # שומרים את החוקים לפי סדר-hash למניעת מצבי Race Condition
        rule_backup = [(r.raw_spec, r.observed_target) for r in existing_rules if r.raw_spec]

        # מחיקת כל החוקים הקיימים כדי לבנות את הסדר מחדש
        remove_success = True
        for r in sorted(existing_rules, key=lambda x: x.observed_rule_id or 0, reverse=True):
            if r.observed_rule_id is None:
                continue
            try:
                self.client.remove_rule(r.observed_rule_id)
            except Exception:
                remove_success = False

        added = 0
        try:
            # 1. הזרקת חוקי החסימה המשולבים (Composite Reject) ראשונים
            for rule in composite_reject_rules(self.config):
                try:
                    self.client.append_rule(rule)
                    added += 1
                    self.audit.log("composite_reject_added", rule=rule)
                except UsbguardError as e:
                    self.audit.log("composite_reject_failed", rule=rule, error=str(e))

            # 2. הזרקת חוקי ה-Allow המורשים מחדש
            for dev in existing_allows:
                try:
                    rule = render_allow(dev)
                    self.client.append_rule(rule)
                    added += 1
                except Exception:
                    pass

            # 3. החזרת חוקי Reject קיימים (לא-קומפוזיט) בסוף
            for dev in existing_rejects:
                try:
                    # Skip if this is a composite reject already covered
                    rule = render_reject(dev)
                    if any(cr in rule for cr in ["with-interface { 03:01:01 08:06:50 }", "with-interface { 03:01:02 08:06:50 }", "with-interface { 03:00:00 08:06:50 }", "with-interface { 03:01:01 02:02:01 }", "with-interface { 03:01:02 02:02:01 }"]):
                        continue
                    self.client.append_rule(rule)
                    added += 1
                except Exception:
                    pass

            self.audit.log("init_policy_reordered", rules_added=added, composite_first=True)
            return added
        except Exception as e:
            # במקרה של כשל, ננסה לשחזר את המצב הקודם
            self.audit.log("init_policy_failed_rollback", error=str(e))
            for spec, target in rule_backup:
                try:
                    self.client.append_rule(spec)
                    added += 1
                except Exception:
                    pass
            self.audit.log("init_policy_rollback_complete", restored=len(rule_backup))
            return added

    def learn(self, duration: int, actor: str = "cli"):
        """
        מפעילה מצב למידה (Learning Mode) למשך זמן מוגדר.
        עוקבת אחר התקנים חדשים שהתחברו ומציעה המלצות אבטחה ללא אכיפה בפועל.
        """
        duration = max(0, int(duration))
        before = {d.fingerprint: d for d in self.client.list_devices()}
        
        time.sleep(duration)
        
        after = {d.fingerprint: d for d in self.client.list_devices()}
        proposals = []

        for fp, device in after.items():
            flags = []
            if fp not in before:
                flags.append("APPEARED_DURING_LEARNING")
            if self.is_composite_unexpected(device):
                flags.append("COMPOSITE_UNEXPECTED")

            # קביעת המלצת האבטחה
            recommendation = "REVIEW_REQUIRED"
            if "COMPOSITE_UNEXPECTED" in flags:
                recommendation = "DO_NOT_APPROVE"
            elif "APPEARED_DURING_LEARNING" in flags:
                recommendation = "REVIEW_PHYSICAL_VERIFICATION"

            proposals.append({
                "fingerprint": fp,
                "device": device.to_dict(),
                "flags": flags,
                "recommendation": recommendation
            })

        self.audit.log("learn_completed", actor=actor, duration=duration, proposals=len(proposals))
        return proposals

    # ==========================================================================
    # פונקציות עזר פנימיות (Private Helpers)
    # ==========================================================================

    def _require_device(self, fingerprint: str) -> DeviceRecord:
        """שולפת התקן מפינגרפרינט/מזהה, ומעלה שגיאה אם אינו קיים במסד הנתונים."""
        device = self.store.get_device_by_any(fingerprint)
        if not device:
            raise RuntimeError(f"Device not found: {fingerprint}")
        return device

    def _rule_matches(self, rule: DeviceRecord, device: DeviceRecord) -> bool:
        """בודקת התאמה בין חוק קיים ב-USBGuard לבין אובייקט התקן במערכת."""
        if rule.hash and device.hash and rule.hash == device.hash:
            return True

        if rule.vid_pid and device.vid_pid and rule.vid_pid == device.vid_pid:
            # בדיקת התאמת מספר סידורי
            if rule.serial and device.serial:
                if rule.serial != device.serial:
                    return False
            elif rule.serial or device.serial:
                return False

            # בדיקת התאמת ממשקים (Interfaces)
            if rule.interfaces and device.interfaces:
                if set(rule.interfaces) != set(device.interfaces):
                    return False

            return True

        return False
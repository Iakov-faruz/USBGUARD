from __future__ import annotations
import statistics
from collections import deque
from typing import Dict, Tuple
from core.config import Config, Thresholds

class KeystrokeStats:
    def __init__(self, thresholds: Thresholds):
        self.thresholds = thresholds
        self.events: deque[float] = deque()
        self.intervals: deque[float] = deque()
        self.last_ts: float | None = None
        self.last_trigger: float = 0.0
    def add(self, ts: float) -> None:
        if self.last_ts is not None:
            interval_ms = (ts - self.last_ts) * 1000.0
            self.intervals.append(interval_ms)
        self.events.append(ts); self.last_ts=ts; self._prune(ts)
        while len(self.intervals)>300: self.intervals.popleft()
    def reset(self) -> None:
        self.events.clear(); self.intervals.clear(); self.last_ts=None
    def _prune(self, ts: float) -> None:
        max_window = max(self.thresholds.window_seconds, self.thresholds.burst_window_seconds, 2.0)
        while self.events and ts - self.events[0] > max_window: self.events.popleft()
    def metrics(self, ts: float) -> Dict[str, float]:
        window_count = sum(1 for t in self.events if ts - t <= self.thresholds.window_seconds)
        burst_count = sum(1 for t in self.events if ts - t <= self.thresholds.burst_window_seconds)
        intervals = list(self.intervals)
        recent = intervals[-max(2,self.thresholds.min_events_for_decision):]
        stddev_ms=9999.0
        if len(recent)>=2: stddev_ms=statistics.pstdev(recent)
        eps = window_count / max(0.001, self.thresholds.window_seconds)
        return {"window_count":float(window_count),"burst_count":float(burst_count),"eps":float(eps),"stddev_ms":float(stddev_ms),"interval_samples":float(len(recent))}
    def should_trigger(self, ts: float) -> Tuple[bool, str, Dict[str, float]]:
        if ts - self.last_trigger < self.thresholds.cooldown_seconds: return False,"",{}
        m=self.metrics(ts)
        if m["window_count"] < self.thresholds.min_events_for_decision: return False,"",m
        reasons=[]
        if m["eps"] > self.thresholds.eps_threshold: reasons.append("HIGH_EPS")
        if m["burst_count"] >= self.thresholds.burst_chars: reasons.append("BURST")
        if m["interval_samples"] >= self.thresholds.min_events_for_decision and m["stddev_ms"] < self.thresholds.low_variance_ms:
            reasons.append("LOW_VARIANCE")
        if not reasons: return False,"",m
        if "BURST" in reasons or "HIGH_EPS" in reasons:
            self.last_trigger=ts; return True,",".join(reasons),m
        return False,"",m

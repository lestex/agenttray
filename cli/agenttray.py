#!/usr/bin/env python3
"""AgentTray in the terminal: usage limits and token history for Claude and Codex.

Reads the logins the two CLIs already wrote and calls their own usage
endpoints, then adds up tokens from their local session logs. Standard library
only, Python 3.13+.

    agenttray.py                  # every agent
    agenttray.py claude           # one agent
    agenttray.py --json           # machine-readable
    agenttray.py --no-history     # limits only
"""
import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from typing import Optional

HOME = Path.home()
DAYS = 7
AGENTS = ("claude", "codex")


class UsageError(Exception):
    """Something the user can act on; the message says what."""


# MARK: - Model


@dataclass
class Limit:
    title: str
    percent: float
    resets_at: Optional[datetime]
    order: int = 0


@dataclass
class Extra:
    percent: float
    used: str
    limit: str


@dataclass
class Report:
    agent: str
    plan: Optional[str] = None
    limits: list = field(default_factory=list)
    extra: Optional[Extra] = None
    error: Optional[str] = None
    days: list = field(default_factory=list)    # [(date, tokens)], oldest first
    models: list = field(default_factory=list)  # [(name, tokens)], busiest first


# MARK: - Transport


def get_json(url, headers):
    request = urllib.request.Request(url, headers={
        "Accept": "application/json", "User-Agent": "AgentTray-cli/1.0", **headers})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return json.load(response)
    except urllib.error.HTTPError as err:
        if err.code in (401, 403):
            raise UsageError("Token rejected.") from None
        if err.code == 429:
            raise UsageError("Rate limited by the API (HTTP 429). Try again in a few minutes.") from None
        raise UsageError(f"API returned HTTP {err.code}.") from None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as err:
        raise UsageError(f"Could not reach the usage API: {getattr(err, 'reason', err)}") from None


def read_text(path):
    try:
        return Path(path).read_text()
    except OSError:
        return None


# MARK: - Parsing helpers


def parse_time(value):
    """RFC 3339 with any number of fractional digits, or epoch seconds/millis."""
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(value / 1000 if value > 1e11 else value, tz=timezone.utc)
    if not isinstance(value, str):
        return None
    text = re.sub(r"\.(\d+)", lambda m: "." + m.group(1)[:6].ljust(6, "0"), value.strip())
    text = text[:-1] + "+00:00" if text.endswith("Z") else text
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def clamp(value):
    return min(max(float(value), 0.0), 100.0)


# MARK: - Claude

CLAUDE_URL = "https://api.anthropic.com/api/oauth/usage"

# Display names for the windows we know. Anything else still shows, humanised.
# The weekly top-model window ships under a rotating codename.
CLAUDE_WINDOWS = {
    "five_hour": ("5-hour window", 0),
    "seven_day": ("Weekly", 1),
    "iguana_necktie": ("Weekly Fable", 2),
    "nimbus_quill": ("Weekly Fable", 2),
    "seven_day_fable": ("Weekly Fable", 2),
    "seven_day_opus": ("Weekly Opus", 2),
    "seven_day_sonnet": ("Weekly Sonnet", 3),
    "seven_day_oauth_apps": ("Weekly (apps)", 4),
}
NOT_A_LIMIT = {"extra_usage", "spend"}


def claude_login():
    """(token, plan). Only claudeAiOauth is read: the same blob also holds a
    token per MCP server, which must never be sent to the usage endpoint."""
    blobs = []
    try:
        out = subprocess.run(["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
                             capture_output=True, text=True, timeout=10)
        if out.returncode == 0:
            blobs.append(out.stdout)
    except (OSError, subprocess.SubprocessError):
        pass  # not macOS, or no Keychain item
    blobs.append(read_text(HOME / ".claude/.credentials.json"))
    for blob in blobs:
        try:
            root = json.loads(blob or "")
        except json.JSONDecodeError:
            continue
        oauth = root.get("claudeAiOauth") or root
        if isinstance(oauth, dict) and oauth.get("accessToken"):
            return oauth["accessToken"], oauth.get("subscriptionType")
    raise UsageError("No Claude credentials found. Log in with `claude` first.")


def claude_report():
    token, plan = claude_login()
    try:
        payload = get_json(CLAUDE_URL, {"Authorization": f"Bearer {token}",
                                        "anthropic-beta": "oauth-2025-04-20"})
    except UsageError as err:
        if str(err) == "Token rejected.":
            raise UsageError("Token rejected. Run `claude` in a terminal to refresh the login.") from None
        raise
    report = Report("claude", plan=plan)
    for key, window in payload.items():
        if key in NOT_A_LIMIT or not isinstance(window, dict):
            continue
        used = next((window[f] for f in ("utilization", "used_percentage")
                     if isinstance(window.get(f), (int, float))), None)
        if used is None:
            continue
        title, order = CLAUDE_WINDOWS.get(key, (key.replace("_", " ").capitalize(), 3))
        resets = next((parse_time(window[f]) for f in ("resets_at", "reset_at", "resetsAt")
                       if window.get(f) is not None), None)
        report.limits.append(Limit(title, clamp(used), resets, order))
    report.limits.sort(key=lambda l: (l.order, l.title))
    if not report.limits:
        raise UsageError("Could not read the usage payload.")
    report.extra = claude_extra(payload.get("extra_usage"))
    return report


def claude_extra(block):
    if not isinstance(block, dict) or block.get("is_enabled") is not True:
        return None
    used, cap = block.get("used_credits"), block.get("monthly_limit")
    if not isinstance(used, (int, float)) or not isinstance(cap, (int, float)):
        return None
    scale = 10 ** int(block.get("decimal_places", 2))
    percent = block.get("utilization")
    if not isinstance(percent, (int, float)):
        percent = used / cap * 100 if cap else 0
    currency = block.get("currency", "USD")
    return Extra(clamp(percent), money(used / scale, currency), money(cap / scale, currency))


def money(value, currency):
    return f"${value:,.2f}" if currency == "USD" else f"{value:,.2f} {currency}"


# MARK: - Codex


def codex_home():
    return Path(os.environ.get("CODEX_HOME") or HOME / ".codex")


def codex_report():
    text = read_text(codex_home() / "auth.json")
    try:
        tokens = json.loads(text or "")["tokens"]
        token = tokens["access_token"]
    except (json.JSONDecodeError, KeyError, TypeError):
        raise UsageError("No Codex credentials found in ~/.codex/auth.json. Log in with `codex` first.") from None
    headers = {"Authorization": f"Bearer {token}"}
    if tokens.get("account_id"):
        headers["chatgpt-account-id"] = tokens["account_id"]
    try:
        payload = get_json("https://chatgpt.com/backend-api/wham/usage", headers)
    except UsageError as err:
        if str(err) == "Token rejected.":
            raise UsageError("Token rejected. Run `codex` in a terminal to refresh the login.") from None
        raise
    report = Report("codex", plan=payload.get("plan_type"))
    block = payload.get("rate_limit") or {}
    for order, key in enumerate(("primary_window", "secondary_window")):
        window = block.get(key)
        if not isinstance(window, dict) or not isinstance(window.get("used_percent"), (int, float)):
            continue
        resets = parse_time(window["reset_at"]) if window.get("reset_at") else None
        if resets is None and isinstance(window.get("reset_after_seconds"), (int, float)):
            resets = datetime.now(timezone.utc) + timedelta(seconds=window["reset_after_seconds"])
        report.limits.append(Limit(codex_window_name(window.get("limit_window_seconds")),
                                   clamp(window["used_percent"]), resets, order))
    if not report.limits:
        raise UsageError("Could not read the usage payload.")
    return report


def codex_window_name(seconds):
    """Two fixed slots, so the title comes from how long the window is."""
    if not isinstance(seconds, (int, float)) or seconds < 3600:
        return "Window"
    hours = round(seconds / 3600)
    if hours % 168 == 0:
        weeks = hours // 168
        return "Weekly" if weeks == 1 else f"{weeks}-week window"
    if hours % 24 == 0:
        return f"{hours // 24}-day window"
    return f"{hours}-hour window"


# MARK: - Token history, from the CLIs' own session logs


class Tally:
    def __init__(self, today):
        self.since = today - timedelta(days=DAYS - 1)
        self.today = today
        self.by_day = {}
        self.by_model = {}

    def add(self, tokens, model, when):
        day = when.astimezone().date()
        if tokens > 0 and day >= self.since:
            self.by_day[day] = self.by_day.get(day, 0) + tokens
            self.by_model[model] = self.by_model.get(model, 0) + tokens

    def days(self):
        return [(self.since + timedelta(days=i), self.by_day.get(self.since + timedelta(days=i), 0))
                for i in range(DAYS)]

    def models(self):
        return sorted(self.by_model.items(), key=lambda kv: (-kv[1], kv[0]))


def log_records(root, since, *markers):
    """Parsed lines mentioning a marker, from logs touched since `since`. The
    substring test skips the JSON parse for most of a log, which is message text."""
    cutoff = datetime.combine(since, time.min).timestamp()
    for path in sorted(Path(root).rglob("*.jsonl")):
        try:
            if path.stat().st_mtime < cutoff:
                continue
            lines = path.read_text(errors="replace").splitlines()
        except OSError:
            continue
        records = []
        for line in lines:
            if any(m in line for m in markers):
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
        yield path, records


def claude_history(tally):
    seen = set()
    for _, records in log_records(HOME / ".claude/projects", tally.since, '"usage"'):
        for record in records:
            message = record.get("message")
            if not isinstance(message, dict) or not isinstance(message.get("usage"), dict):
                continue
            model, when = message.get("model"), parse_time(record.get("timestamp"))
            if not model or model == "<synthetic>" or when is None:
                continue
            # A message can be written more than once: streamed in parts, or
            # copied into a resumed session.
            if message.get("id"):
                key = (message["id"], record.get("requestId"))
                if key in seen:
                    continue
                seen.add(key)
            usage = message["usage"]
            total = sum(int(usage.get(k) or 0) for k in (
                "input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
            tally.add(total, claude_model_name(model), when)


def claude_model_name(model_id):
    """claude-opus-5-5 -> Opus 5.5; claude-3-5-sonnet-20241022 -> Sonnet 3.5."""
    parts = [p for p in model_id.split("[")[0].split("-") if p != "claude"]
    words = [p for p in parts if p[:1].isalpha()]
    version = [p for p in parts if p.isdigit() and len(p) < 8]  # 8 digits is a snapshot date
    if not words:
        return model_id
    name = " ".join(w.capitalize() for w in words)
    return f"{name} {'.'.join(version)}" if version else name


def codex_history(tally):
    """Each token_count event carries a running total, so a turn's tokens are
    the step from the previous total, credited to the latest turn_context model."""
    for _, records in log_records(codex_home() / "sessions", tally.since, '"turn_context"', '"token_count"'):
        model, total = "Codex", 0
        for record in records:
            payload = record.get("payload") or {}
            if record.get("type") == "turn_context" and payload.get("model"):
                model = codex_model_name(payload["model"])
            info = payload.get("info") if payload.get("type") == "token_count" else None
            when = parse_time(record.get("timestamp"))
            if not isinstance(info, dict) or when is None:
                continue
            running = int((info.get("total_token_usage") or {}).get("total_tokens") or 0)
            step = running - total if running >= total else running  # a lower total means a restart
            total = running
            tally.add(step, model, when)


def codex_model_name(model_id):
    """gpt-5.6-luna -> GPT-5.6 Luna."""
    parts = model_id.split("-")
    if len(parts) < 2 or parts[0].lower() != "gpt":
        return model_id
    return " ".join([f"GPT-{parts[1]}"] + [p.capitalize() for p in parts[2:]])


def add_history(report):
    tally = Tally(date.today())
    {"claude": claude_history, "codex": codex_history}[report.agent](tally)
    report.days, report.models = tally.days(), tally.models()


# MARK: - Formatting


class Style:
    def __init__(self, enabled):
        self.enabled = enabled

    def paint(self, code, text):
        return f"\033[{code}m{text}\033[0m" if self.enabled else text

    def level(self, percent, text):
        """Calm until it starts to matter, like the menu bar pills."""
        return self.paint("31" if percent >= 85 else "33" if percent >= 60 else "0", text)

    def dim(self, text): return self.paint("2", text)
    def bold(self, text): return self.paint("1", text)


def fmt_percent(value):
    rounded = round(value * 10) / 10
    return f"{rounded:.1f}%" if 0 < rounded < 10 and rounded != int(rounded) else f"{rounded:.0f}%"


def fmt_tokens(count):
    for limit, suffix in ((1e9, "B"), (1e6, "M"), (1e3, "K")):
        if count >= limit:
            scaled = count / limit
            return (f"{scaled:.0f}" if scaled >= 100 else f"{scaled:.1f}") + suffix
    return str(count)


def fmt_countdown(when, now):
    total = round((when - now).total_seconds())
    if total <= 0:
        return "resetting now"
    days, rest = divmod(total, 86400)
    hours, rest = divmod(rest, 3600)
    minutes = rest // 60
    if days:
        return f"resets in {days} d {hours} h {minutes} min"
    if hours:
        return f"resets in {hours} h {minutes} min"
    return f"resets in {max(minutes, 1)} min"


def fmt_plan(raw):
    return raw.replace("_", " ").capitalize() + " plan"


def bar(fraction, width=20):
    filled = round(min(max(fraction, 0), 1) * width)
    if fraction > 0:
        filled = max(filled, 1)
    return "█" * filled + "░" * (width - filled)


def render(report, style, with_history):
    now = datetime.now(timezone.utc)
    title = report.agent.capitalize() + (f" · {fmt_plan(report.plan)}" if report.plan else "")
    out = [style.bold(title)]
    if report.error:
        return out + [f"  {report.error}"]

    rows = [(l.title, l.percent, fmt_countdown(l.resets_at, now) if l.resets_at else "reset not reported")
            for l in report.limits]
    if report.extra:
        rows.append(("Extra usage", report.extra.percent, f"{report.extra.used} of {report.extra.limit}"))
    width = max(len(r[0]) for r in rows)
    out.append("")
    out.append(style.dim("LIMITS"))
    for name, percent, detail in rows:
        out.append(f"  {name:<{width}}  {style.level(percent, bar(percent / 100))}  "
                   f"{fmt_percent(percent):>5}  {style.dim(detail)}")

    if with_history:
        out += ["", style.dim("TOKENS BY DAY")]
        busiest = max((t for _, t in report.days), default=0)
        labels = ["Today" if d == date.today() else d.strftime("%a") for d, _ in report.days]
        for label, (_, tokens) in zip(labels, report.days):
            line = f"  {label:<5}  {bar(tokens / busiest if busiest else 0)}  {fmt_tokens(tokens):>6}"
            out.append(style.bold(line) if label == "Today" else line)

        out += ["", style.dim(f"TOKENS BY MODEL · {DAYS} DAYS")]
        if not report.models:
            out.append(f"  Nothing in the last {DAYS} days")
        busiest = report.models[0][1] if report.models else 0
        name_width = max((len(n) for n, _ in report.models), default=0)
        for name, tokens in report.models:
            out.append(f"  {name:<{name_width}}  {bar(tokens / busiest)}  {fmt_tokens(tokens):>6}")
    return out


def as_json(report):
    return {
        "plan": report.plan,
        "error": report.error,
        "limits": [{"title": l.title, "percent": l.percent,
                    "resets_at": l.resets_at.isoformat() if l.resets_at else None} for l in report.limits],
        "extra": report.extra and {"percent": report.extra.percent, "used": report.extra.used,
                                   "limit": report.extra.limit},
        "tokens": {"days": [{"date": d.isoformat(), "tokens": t} for d, t in report.days],
                   "models": [{"model": n, "tokens": t} for n, t in report.models]},
    }


# MARK: - Main


def main(argv=None):
    parser = argparse.ArgumentParser(description="Usage limits and token history for Claude and Codex.")
    parser.add_argument("agents", nargs="*", metavar="agent", help="claude, codex (default: both)")
    parser.add_argument("--json", action="store_true", help="print JSON instead of text")
    parser.add_argument("--no-history", action="store_true", help="skip the token sections")
    args = parser.parse_args(argv)

    chosen = args.agents or list(AGENTS)
    unknown = [a for a in chosen if a not in AGENTS]
    if unknown:
        parser.error(f"unknown agent {unknown[0]!r}; try one of: {', '.join(AGENTS)}")

    reports = []
    for agent in chosen:
        try:
            report = {"claude": claude_report, "codex": codex_report}[agent]()
        except UsageError as err:
            report = Report(agent, error=str(err))
        if not args.no_history:
            add_history(report)
        reports.append(report)

    if args.json:
        print(json.dumps({r.agent: as_json(r) for r in reports}, indent=2))
    else:
        style = Style(sys.stdout.isatty() and "NO_COLOR" not in os.environ)
        blocks = ["\n".join(render(r, style, not args.no_history)) for r in reports]
        print("\n\n".join(blocks))
    return 1 if any(r.error for r in reports) else 0


if __name__ == "__main__":
    sys.exit(main())

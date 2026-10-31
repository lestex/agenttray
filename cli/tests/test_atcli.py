import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
import urllib.error
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import atcli as at  # noqa: E402

NOW = datetime(2026, 10, 31, 12, 0, tzinfo=timezone.utc)
TODAY = date(2026, 10, 31)


def local_noon(day):
    """Noon in the local zone, so the day a record lands on doesn't depend on it."""
    return datetime(day.year, day.month, day.day, 12, 0).astimezone()


def write_jsonl(path, records):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(json.dumps(r) if not isinstance(r, str) else r for r in records) + "\n")


class ParseTime(unittest.TestCase):
    def test_fraction_of_any_length(self):
        for text in ("2026-09-02T04:10:00.464945+00:00", "2026-09-02T04:10:00.464945123Z",
                     "2026-09-02T04:10:00.4Z", "2026-09-02T04:10:00Z"):
            parsed = at.parse_time(text)
            self.assertEqual(parsed.replace(microsecond=0),
                             datetime(2026, 9, 2, 4, 10, tzinfo=timezone.utc), text)

    def test_epoch_seconds_and_millis_agree(self):
        self.assertEqual(at.parse_time(1776360365), at.parse_time(1776360365000))

    def test_garbage_is_none(self):
        self.assertIsNone(at.parse_time("not a date"))
        self.assertIsNone(at.parse_time(None))


class Formatting(unittest.TestCase):
    def test_percent(self):
        self.assertEqual(at.fmt_percent(0), "0%")
        self.assertEqual(at.fmt_percent(4), "4%")
        self.assertEqual(at.fmt_percent(4.26), "4.3%")
        self.assertEqual(at.fmt_percent(9.96), "10%")
        self.assertEqual(at.fmt_percent(100), "100%")

    def test_tokens(self):
        self.assertEqual(at.fmt_tokens(0), "0")
        self.assertEqual(at.fmt_tokens(950), "950")
        self.assertEqual(at.fmt_tokens(12_300), "12.3K")
        self.assertEqual(at.fmt_tokens(1_400_000), "1.4M")
        self.assertEqual(at.fmt_tokens(152_600_000), "153M")
        self.assertEqual(at.fmt_tokens(2_100_000_000), "2.1B")

    def test_countdown(self):
        def left(**delta):
            return at.fmt_countdown(NOW + timedelta(**delta), NOW)
        self.assertEqual(left(days=4, hours=18, minutes=45), "resets in 4 d 18 h 45 min")
        self.assertEqual(left(hours=3, minutes=5, seconds=40), "resets in 3 h 5 min")
        self.assertEqual(left(seconds=30), "resets in 1 min")
        self.assertEqual(left(seconds=-5), "resetting now")

    def test_plan(self):
        self.assertEqual(at.fmt_plan("pro"), "Pro plan")
        self.assertEqual(at.fmt_plan("max_5x"), "Max 5x plan")

    def test_bar_keeps_a_sliver_for_small_values(self):
        self.assertEqual(at.bar(0, 10), "░" * 10)
        self.assertEqual(at.bar(0.001, 10), "█" + "░" * 9)
        self.assertEqual(at.bar(1, 10), "█" * 10)
        self.assertEqual(at.bar(5, 10), "█" * 10)


class Names(unittest.TestCase):
    def test_claude_models(self):
        self.assertEqual(at.claude_model_name("claude-opus-5-5"), "Opus 5.5")
        self.assertEqual(at.claude_model_name("claude-3-5-sonnet-20241022"), "Sonnet 3.5")
        self.assertEqual(at.claude_model_name("claude-sonnet-5-5[1m]"), "Sonnet 5.5")

    def test_codex_models(self):
        self.assertEqual(at.codex_model_name("gpt-5.6-luna"), "GPT-5.6 Luna")
        self.assertEqual(at.codex_model_name("gpt-6-astra"), "GPT-6 Astra")
        self.assertEqual(at.codex_model_name("o3"), "o3")

    def test_codex_windows_are_named_by_length(self):
        self.assertEqual(at.codex_window_name(18000), "5-hour window")
        self.assertEqual(at.codex_window_name(604800), "Weekly")
        self.assertEqual(at.codex_window_name(1209600), "2-week window")
        self.assertEqual(at.codex_window_name(2592000), "30-day window")
        self.assertEqual(at.codex_window_name(60), "Window")
        self.assertEqual(at.codex_window_name(None), "Window")


class Transport(unittest.TestCase):
    def fail_with(self, code):
        error = urllib.error.HTTPError("https://x", code, "msg", {}, None)
        return mock.patch("urllib.request.urlopen", side_effect=error)

    def test_status_codes_become_messages(self):
        for code, text in ((401, "Token rejected"), (403, "Token rejected"),
                           (429, "Rate limited"), (500, "HTTP 500")):
            with self.fail_with(code), self.assertRaises(at.UsageError) as caught:
                at.get_json("https://x", {})
            self.assertIn(text, str(caught.exception))

    def test_unreachable(self):
        with mock.patch("urllib.request.urlopen", side_effect=urllib.error.URLError("offline")):
            with self.assertRaises(at.UsageError) as caught:
                at.get_json("https://x", {})
        self.assertIn("offline", str(caught.exception))


class ClaudeLogin(unittest.TestCase):
    def login_from(self, blob, home):
        done = mock.Mock(returncode=0, stdout=blob)
        with mock.patch.object(at, "HOME", Path(home)), mock.patch("subprocess.run", return_value=done):
            return at.claude_login()

    def test_reads_the_account_token_not_an_mcp_servers(self):
        blob = json.dumps({"mcpOAuth": {"server": {"accessToken": "mcp-token"}},
                           "claudeAiOauth": {"accessToken": "mine", "subscriptionType": "pro"}})
        with tempfile.TemporaryDirectory() as home:
            self.assertEqual(self.login_from(blob, home), ("mine", "pro"))

    def test_falls_back_to_the_credentials_file(self):
        with tempfile.TemporaryDirectory() as home:
            (Path(home) / ".claude").mkdir()
            (Path(home) / ".claude/.credentials.json").write_text(
                json.dumps({"claudeAiOauth": {"accessToken": "from-file"}}))
            done = mock.Mock(returncode=44, stdout="")
            with mock.patch.object(at, "HOME", Path(home)), mock.patch("subprocess.run", return_value=done):
                self.assertEqual(at.claude_login(), ("from-file", None))

    def test_nothing_found(self):
        with tempfile.TemporaryDirectory() as home:
            done = mock.Mock(returncode=44, stdout="")
            with mock.patch.object(at, "HOME", Path(home)), mock.patch("subprocess.run", return_value=done):
                with self.assertRaises(at.UsageError):
                    at.claude_login()


CLAUDE_PAYLOAD = {
    "amber_cistern": None,
    "extra_usage": {"is_enabled": True, "used_credits": 832, "monthly_limit": 4000,
                    "decimal_places": 2, "currency": "USD", "utilization": 20.8},
    "five_hour": {"utilization": 4, "resets_at": "2026-10-31T23:19:59.731855+00:00"},
    "iguana_necktie": {"utilization": 0, "resets_at": "2026-11-05T07:59:00+00:00"},
    "seven_day": {"utilization": 4, "resets_at": "2026-11-05T14:59:59.731880+00:00"},
    "seven_day_breakdown": {"rows": [{"key": "chat", "percent": 72}]},
    "limits": [{"kind": "session", "percent": 4}],
    "spend": {"percent": 21, "enabled": True},
    "some_new_window": {"utilization": 12.5},
}


class ClaudeReport(unittest.TestCase):
    def report(self, payload=CLAUDE_PAYLOAD):
        with mock.patch.object(at, "claude_login", return_value=("tok", "pro")), \
                mock.patch.object(at, "get_json", return_value=payload):
            return at.claude_report()

    def test_windows_are_named_and_ordered(self):
        titles = [l.title for l in self.report().limits]
        self.assertEqual(titles, ["5-hour window", "Weekly", "Weekly Fable", "Some new window"])

    def test_things_that_are_not_limits_are_skipped(self):
        titles = " ".join(l.title for l in self.report().limits).lower()
        for word in ("spend", "breakdown", "cistern", "extra"):
            self.assertNotIn(word, titles)

    def test_extra_usage(self):
        extra = self.report().extra
        self.assertEqual((extra.used, extra.limit), ("$8.32", "$40.00"))
        self.assertAlmostEqual(extra.percent, 20.8)

    def test_extra_usage_off_or_malformed(self):
        self.assertIsNone(at.claude_extra({"is_enabled": False, "used_credits": 1, "monthly_limit": 2}))
        self.assertIsNone(at.claude_extra({"is_enabled": True}))
        self.assertIsNone(at.claude_extra(None))

    def test_percent_is_clamped(self):
        report = self.report({"five_hour": {"utilization": 140}, "seven_day": {"utilization": -3}})
        self.assertEqual([l.percent for l in report.limits], [100.0, 0.0])

    def test_an_empty_payload_is_an_error(self):
        with self.assertRaises(at.UsageError):
            self.report({"limits": []})

    def test_a_rejected_token_says_how_to_refresh(self):
        with mock.patch.object(at, "claude_login", return_value=("tok", None)), \
                mock.patch.object(at, "get_json", side_effect=at.UsageError("Token rejected.")):
            with self.assertRaises(at.UsageError) as caught:
                at.claude_report()
        self.assertIn("`claude`", str(caught.exception))


class CodexReport(unittest.TestCase):
    PAYLOAD = {"plan_type": "plus", "rate_limit": {
        "primary_window": {"used_percent": 7, "limit_window_seconds": 18000, "reset_at": 1776360365},
        "secondary_window": {"used_percent": 8, "limit_window_seconds": 604800, "reset_after_seconds": 3600},
    }}

    def report(self, payload=PAYLOAD):
        with tempfile.TemporaryDirectory() as home:
            (Path(home) / "auth.json").write_text(
                json.dumps({"tokens": {"access_token": "tok", "account_id": "acct"}}))
            with mock.patch.dict(os.environ, {"CODEX_HOME": home}), \
                    mock.patch.object(at, "get_json", return_value=payload) as get:
                report = at.codex_report()
            return report, get

    def test_windows_and_plan(self):
        report, _ = self.report()
        self.assertEqual(report.plan, "plus")
        self.assertEqual([(l.title, l.percent) for l in report.limits], [("5-hour window", 7.0), ("Weekly", 8.0)])

    def test_reset_falls_back_to_the_offset(self):
        report, _ = self.report()
        self.assertEqual(report.limits[0].resets_at, datetime.fromtimestamp(1776360365, tz=timezone.utc))
        remaining = (report.limits[1].resets_at - datetime.now(timezone.utc)).total_seconds()
        self.assertTrue(3500 < remaining <= 3600)

    def test_sends_the_account_id(self):
        _, get = self.report()
        headers = get.call_args[0][1]
        self.assertEqual(headers["chatgpt-account-id"], "acct")
        self.assertEqual(headers["Authorization"], "Bearer tok")

    def test_no_login(self):
        with tempfile.TemporaryDirectory() as home, mock.patch.dict(os.environ, {"CODEX_HOME": home}):
            with self.assertRaises(at.UsageError) as caught:
                at.codex_report()
        self.assertIn("`codex`", str(caught.exception))


class Tokens(unittest.TestCase):
    def test_tally_covers_seven_days_ending_today(self):
        tally = at.Tally(TODAY)
        tally.add(10, "A", local_noon(TODAY))
        tally.add(5, "A", local_noon(TODAY - timedelta(days=6)))
        tally.add(99, "A", local_noon(TODAY - timedelta(days=7)))   # outside the range
        tally.add(0, "B", local_noon(TODAY))                         # nothing to count
        days = tally.days()
        self.assertEqual(len(days), 7)
        self.assertEqual((days[0][0], days[-1][0]), (TODAY - timedelta(days=6), TODAY))
        self.assertEqual((days[0][1], days[-1][1]), (5, 10))
        self.assertEqual(tally.models(), [("A", 15)])

    def test_models_busiest_first(self):
        tally = at.Tally(TODAY)
        tally.add(1, "small", local_noon(TODAY))
        tally.add(9, "big", local_noon(TODAY))
        self.assertEqual([m for m, _ in tally.models()], ["big", "small"])

    def test_claude_history(self):
        def message(msg_id, model, tokens, day, request="r1", **extra):
            usage = {"input_tokens": tokens, "output_tokens": 0,
                     "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
            return {"timestamp": local_noon(day).isoformat(), "requestId": request,
                    "message": {"id": msg_id, "model": model, "usage": usage}, **extra}

        with tempfile.TemporaryDirectory() as home:
            write_jsonl(Path(home) / ".claude/projects/proj/a.jsonl", [
                message("m1", "claude-opus-5-5", 100, TODAY),
                message("m1", "claude-opus-5-5", 100, TODAY),               # streamed twice
                message("m2", "claude-sonnet-5-5", 40, TODAY - timedelta(days=1)),
                message("m3", "<synthetic>", 500, TODAY),                  # not a real request
                message("m4", "claude-opus-5-5", 700, TODAY - timedelta(days=30)),
                {"timestamp": local_noon(TODAY).isoformat(), "type": "user", "note": '"usage" in text'},
                "not json but mentions \"usage\"",
            ])
            tally = at.Tally(TODAY)
            with mock.patch.object(at, "HOME", Path(home)):
                at.claude_history(tally)
        self.assertEqual(tally.models(), [("Opus 5.5", 100), ("Sonnet 5.5", 40)])
        self.assertEqual([t for _, t in tally.days()][-2:], [40, 100])

    def test_cache_and_output_tokens_count(self):
        usage = {"input_tokens": 2, "output_tokens": 3,
                 "cache_creation_input_tokens": 10, "cache_read_input_tokens": 100}
        with tempfile.TemporaryDirectory() as home:
            write_jsonl(Path(home) / ".claude/projects/p/a.jsonl", [
                {"timestamp": local_noon(TODAY).isoformat(),
                 "message": {"model": "claude-opus-5-5", "usage": usage}}])
            tally = at.Tally(TODAY)
            with mock.patch.object(at, "HOME", Path(home)):
                at.claude_history(tally)
        self.assertEqual(tally.models(), [("Opus 5.5", 115)])

    def test_codex_history_steps_between_running_totals(self):
        def stamp(hour):
            return local_noon(TODAY).replace(hour=hour).astimezone(timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%S.123456789Z")

        def count(hour, total):
            return {"timestamp": stamp(hour), "type": "event_msg", "payload": {
                "type": "token_count", "info": {"total_token_usage": {"total_tokens": total}}}}

        with tempfile.TemporaryDirectory() as home:
            write_jsonl(Path(home) / "sessions/2026/10/31/rollout.jsonl", [
                {"timestamp": stamp(9), "type": "turn_context", "payload": {"model": "gpt-5.6-luna"}},
                {"timestamp": stamp(9), "type": "event_msg", "payload": {"type": "token_count", "info": None}},
                count(10, 100),
                count(11, 100),    # a repeated event steps by zero
                count(12, 250),
                count(13, 40),     # a lower total means the counter restarted
            ])
            tally = at.Tally(TODAY)
            with mock.patch.dict(os.environ, {"CODEX_HOME": home}):
                at.codex_history(tally)
        self.assertEqual(tally.models(), [("GPT-5.6 Luna", 290)])


class Output(unittest.TestCase):
    REPORT = at.Report("claude", plan="pro",
                       limits=[at.Limit("5-hour window", 14.0, NOW + timedelta(hours=2)),
                               at.Limit("Weekly", 6.0, None)],
                       extra=at.Extra(21.0, "$8.32", "$40.00"))

    def test_render(self):
        text = "\n".join(at.render(self.REPORT, at.Style(False), with_history=False))
        for expected in ("Claude · Pro plan", "5-hour window", "14%", "Weekly", "reset not reported",
                         "$8.32 of $40.00"):
            self.assertIn(expected, text)
        self.assertNotIn("TOKENS", text)
        self.assertNotIn("\033", text)

    def test_render_an_error(self):
        lines = at.render(at.Report("codex", error="No login."), at.Style(False), with_history=True)
        self.assertEqual(lines[-1].strip(), "No login.")

    def test_colour_only_when_it_matters(self):
        style = at.Style(True)
        self.assertNotIn("\033[31m", style.level(10, "x"))
        self.assertIn("\033[33m", style.level(70, "x"))
        self.assertIn("\033[31m", style.level(90, "x"))

    def run_main(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = at.main(list(argv))
        return code, out.getvalue()

    def test_main_json(self):
        with mock.patch.object(at, "claude_report", return_value=self.REPORT):
            code, out = self.run_main("claude", "--json", "--no-history")
        self.assertEqual(code, 0)
        data = json.loads(out)["claude"]
        self.assertEqual(data["plan"], "pro")
        self.assertEqual([l["title"] for l in data["limits"]], ["5-hour window", "Weekly"])
        self.assertIsNone(data["limits"][1]["resets_at"])

    def test_main_exits_1_when_an_agent_cannot_be_read(self):
        with mock.patch.object(at, "codex_report", side_effect=at.UsageError("No login.")):
            code, out = self.run_main("codex", "--no-history")
        self.assertEqual(code, 1)
        self.assertIn("No login.", out)

    def test_main_rejects_an_unknown_agent(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
            at.main(["bogus"])
        self.assertEqual(caught.exception.code, 2)


if __name__ == "__main__":
    unittest.main()

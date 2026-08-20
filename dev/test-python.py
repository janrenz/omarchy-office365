#!/usr/bin/env python3
"""Unit tests for the Python helpers.

    python3 dev/test-python.py

These cover the parts where being wrong is quiet rather than loud: picking the
wrong widget entry to save into, or letting two aliases share one mailbox's
tokens. Both would look like the plugin working.
"""

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from datetime import datetime, timedelta

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src"))

import config  # noqa: E402
import graph  # noqa: E402

PLUGIN = "caseonline.omarchy.office365"


def layout(*entries):
    return {"bar": {"layout": {"right": [dict(e) for e in entries]}}}


def widget(**settings):
    return dict({"id": PLUGIN}, **settings)


class FindEntry(unittest.TestCase):
    def test_instance_id_wins_over_a_shared_alias(self):
        """The case that made this necessary: a merged widget and a per-mailbox
        one both holding `work`. Saving either must not touch the other."""
        cfg = layout(
            widget(instance="aaa", accounts=[{"account": "work"}, {"account": "personal"}]),
            widget(instance="bbb", accounts=[{"account": "work"}], label="W"),
        )
        match = {"instance": "bbb", "accounts": [{"account": "work"}], "label": "W"}
        self.assertEqual(config.find_entry(cfg, PLUGIN, match, "bbb"), ("right", 1))
        self.assertEqual(config.find_entry(cfg, PLUGIN, match, "aaa"), ("right", 0))

    def test_an_unknown_instance_id_is_not_found(self):
        cfg = layout(widget(instance="aaa", account="work"))
        self.assertIsNone(config.find_entry(cfg, PLUGIN, {"account": "work"}, "zzz"))

    def test_exact_settings_beat_a_shared_alias(self):
        cfg = layout(
            widget(accounts=[{"account": "work"}, {"account": "personal"}]),
            widget(accounts=[{"account": "work"}], label="W"),
        )
        match = {"accounts": [{"account": "work"}], "label": "W"}
        self.assertEqual(config.find_entry(cfg, PLUGIN, match), ("right", 1))

    def test_a_shared_alias_alone_is_ambiguous(self):
        """Two widgets on `work`, neither stamped and neither matching exactly.
        Refusing is the point: writing into either could be the wrong one."""
        cfg = layout(
            widget(account="work", label="one"),
            widget(account="work", label="two"),
        )
        self.assertEqual(
            config.find_entry(cfg, PLUGIN, {"account": "work", "label": "three"}),
            "ambiguous",
        )

    def test_a_unique_alias_still_matches(self):
        cfg = layout(widget(account="personal"), widget(account="work", label="stale"))
        self.assertEqual(
            config.find_entry(cfg, PLUGIN, {"account": "work", "label": "fresh"}),
            ("right", 1),
        )

    def test_a_fresh_widget_has_no_mailbox_yet(self):
        cfg = layout(widget(account="work"), widget())
        self.assertEqual(config.find_entry(cfg, PLUGIN, {}), ("right", 1))

    def test_two_fresh_widgets_are_ambiguous(self):
        cfg = layout(widget(), widget())
        self.assertEqual(config.find_entry(cfg, PLUGIN, {}), "ambiguous")

    def test_other_plugins_are_never_candidates(self):
        cfg = layout(widget(account="work"), {"id": "omarchy.clock"})
        self.assertIsNone(config.find_entry(cfg, "someone.else", {"account": "work"}))


class Saving(unittest.TestCase):
    def save(self, cfg, match, updates, instance=""):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            json.dump(cfg, handle)
            path = handle.name
        argv = [
            "config.py", "--plugin-id", PLUGIN, "--shell-json", path,
            "--match", json.dumps(match), "--set", json.dumps(updates),
            "--instance", instance,
        ]
        old_argv, sys.argv = sys.argv, argv
        try:
            # main() reports on stdout and exits; neither belongs in the run.
            with contextlib.redirect_stdout(io.StringIO()) as reported:
                with self.assertRaises(SystemExit):
                    config.main()
            self.report = json.loads(reported.getvalue())
        finally:
            sys.argv = old_argv
        with open(path, encoding="utf-8") as handle:
            written = json.load(handle)
        os.unlink(path)
        return written["bar"]["layout"]["right"]

    def test_the_first_save_stamps_an_instance_id(self):
        entries = self.save(layout(widget(account="work")), {"account": "work"}, {"label": "W"})
        self.assertEqual(entries[0]["label"], "W")
        self.assertTrue(entries[0]["instance"])

    def test_saving_one_widget_leaves_the_other_alone(self):
        cfg = layout(
            widget(instance="aaa", account="work", label="one"),
            widget(instance="bbb", account="work", label="two"),
        )
        entries = self.save(cfg, {"account": "work", "label": "two"}, {"label": "edited"}, "bbb")
        self.assertEqual([e["label"] for e in entries], ["one", "edited"])

    def test_an_empty_value_restores_the_default(self):
        cfg = layout(widget(instance="aaa", account="work", label="W"))
        entries = self.save(cfg, {}, {"label": ""}, "aaa")
        self.assertNotIn("label", entries[0])

    def test_an_ambiguous_save_is_refused_rather_than_guessed(self):
        cfg = layout(widget(account="work"), widget(account="work"))
        entries = self.save(cfg, {"account": "work", "label": "x"}, {"label": "x"})
        self.assertEqual(self.report["error"]["code"], "ambiguous")
        self.assertNotIn("label", entries[0])
        self.assertNotIn("label", entries[1])


class Aliases(unittest.TestCase):
    def test_punctuation_cannot_collapse_two_aliases_onto_one_file(self):
        for alias in ("work/a", "work!a", "work a", "../work", "work\\a"):
            self.assertTrue(graph.alias_problem(alias), alias)

    def test_ordinary_aliases_are_accepted(self):
        for alias in ("work", "work-2", "work_2", "work.2", "Work2"):
            self.assertEqual(graph.alias_problem(alias), "", alias)

    def test_an_alias_needs_something_to_name_it(self):
        for alias in ("", "   ", "...", "-_-", None):
            self.assertTrue(graph.alias_problem(alias), repr(alias))

    def test_distinct_aliases_get_distinct_files(self):
        paths = {graph.state_path(a) for a in ("work", "work-a", "work_a", "work.a")}
        self.assertEqual(len(paths), 4)

    def test_a_rejected_alias_fails_that_mailbox_only(self):
        with self.assertRaises(graph.AccountError) as caught:
            graph.state_path("work/a")
        self.assertEqual(caught.exception.code, "bad_alias")


class Pagination(unittest.TestCase):
    """Graph hands back one page and a link to the next. A busy week is more
    meetings than one page holds, and stopping there looks like a quiet week."""

    def pages(self, *responses):
        """Stand in for the network: each call answers the next response."""
        remaining = list(responses)

        def answer(*args, **kwargs):
            return remaining.pop(0)

        return answer

    def collect(self, *responses):
        original_get, original_get_url = graph.graph_get, graph.graph_get_url
        answer = self.pages(*responses)
        graph.graph_get = lambda *a, **k: answer()
        graph.graph_get_url = lambda *a, **k: answer()
        try:
            return graph.graph_collect("token", "/me/calendarView", {})
        finally:
            graph.graph_get, graph.graph_get_url = original_get, original_get_url

    def test_one_page_is_the_whole_thing(self):
        status, items, _, complete = self.collect((200, {"value": [1, 2]}))
        self.assertEqual((status, items, complete), (200, [1, 2], True))

    def test_the_walk_follows_nextlink_to_the_end(self):
        status, items, _, complete = self.collect(
            (200, {"value": [1, 2], "@odata.nextLink": "next"}),
            (200, {"value": [3, 4], "@odata.nextLink": "next"}),
            (200, {"value": [5]}),
        )
        self.assertEqual((status, items, complete), (200, [1, 2, 3, 4, 5], True))

    def test_a_page_that_fails_keeps_what_arrived(self):
        status, items, payload, _ = self.collect(
            (200, {"value": [1, 2], "@odata.nextLink": "next"}),
            (403, {"error": {"message": "Access is denied"}}),
        )
        self.assertEqual((status, items), (403, [1, 2]))
        self.assertEqual(graph.graph_error(payload, "fallback"), "Access is denied")

    def test_a_walk_the_caps_cut_short_says_so(self):
        pages = [(200, {"value": [n], "@odata.nextLink": "next"}) for n in range(graph.MAX_PAGES + 2)]
        status, items, _, complete = self.collect(*pages)
        self.assertEqual(status, 200)
        self.assertEqual(len(items), graph.MAX_PAGES)
        self.assertFalse(complete)


class Args:
    """The pieces of the parsed command line that fetch_account reads."""

    mails = 5
    days = 3
    from_now = False


class FetchAccount(unittest.TestCase):
    """The real fetch_account, with the network answering to order.

    Each mail query backs one of the panel's filter combinations, and they
    cannot stand in for each other: nothing in the unread list need be Focused,
    nor anything in the Focused list unread. One that fails leaves its own view
    short while the others look full, so "did anything come back at all" is not
    the test.
    """

    def fetch(self, failing_queries=(), inbox_ok=True, timezone_name="UTC"):
        failing = set(failing_queries)
        self.calendar_params = {}

        def collect(token, path, params, *a, **k):
            self.calendar_params = params
            return 200, [], {}, True

        patched = {
            "read_json": lambda *a, **k: {"username": "you@example.com"},
            "access_token": lambda alias, account: ("token", account),
            "graph_get": lambda *a, **k: (
                (200, {"unreadItemCount": 9}) if inbox_ok
                else (403, {"error": {"message": "Access is denied"}})
            ),
            "fetch_messages": self.messages(failing),
            "graph_collect": collect,
        }
        original = {name: getattr(graph, name) for name in patched}
        for name, stub in patched.items():
            setattr(graph, name, stub)
        try:
            return graph.fetch_account("work", Args(), timezone_name)
        finally:
            for name, value in original.items():
                setattr(graph, name, value)

    def messages(self, failing):
        def answer(token, top, tz, unread_only=False, focused_only=False):
            for label, unread, focused in graph.MAIL_QUERIES:
                if (unread, focused) != (unread_only, focused_only):
                    continue
                if label in failing:
                    return 400, {"error": {"message": "InefficientFilter"}}
                return 200, {"value": [{"id": label, "isRead": False,
                                        "receivedDateTime": "2026-08-20T10:00:00Z"}]}
            raise AssertionError("unexpected query")
        return answer

    def test_nothing_wrong_says_nothing(self):
        result = self.fetch()
        self.assertEqual(result["warnings"], [])
        self.assertEqual(result["unreadCount"], 9)
        self.assertTrue(result["unreadKnown"])

    def test_one_refused_query_is_reported_even_though_mail_arrived(self):
        result = self.fetch(failing_queries=["focused unread"])
        self.assertTrue(result["mail"], "the other queries still filled the list")
        self.assertEqual(len(result["warnings"]), 1)
        self.assertIn("focused unread", result["warnings"][0]["message"])

    def test_every_query_failing_reports_the_failure_itself(self):
        result = self.fetch(failing_queries=[label for label, _, _ in graph.MAIL_QUERIES])
        self.assertEqual(result["mail"], [])
        self.assertEqual(result["warnings"][0]["message"], "InefficientFilter")

    def test_an_unreadable_count_is_never_reported_as_none(self):
        result = self.fetch(inbox_ok=False)
        self.assertFalse(result["unreadKnown"])
        # A floor from the rows that did arrive, so the bar still highlights.
        self.assertEqual(result["unreadCount"], len(result["mail"]))
        self.assertGreater(result["unreadCount"], 0)
        self.assertIn("Access is denied", [w["message"] for w in result["warnings"]])

    def test_the_calendar_window_is_built_in_the_mailbox_timezone(self):
        """Asked for in Auckland, the window has to be Auckland's midnights -
        not the offset the machine running this happens to be at. A zone read
        as a fixed offset gets this wrong wherever the two differ, which is the
        same mistake that costs an hour on the days the clocks change."""
        self.fetch(timezone_name="Pacific/Auckland")
        start = self.calendar_params["startDateTime"]
        end = self.calendar_params["endDateTime"]
        for boundary in (start, end):
            self.assertIn("T00:00:00", boundary)
            self.assertRegex(boundary, r"\+1[23]:00$")
        self.assertEqual(
            (datetime.fromisoformat(end) - datetime.fromisoformat(start)).days, Args.days
        )


class CalendarWindow(unittest.TestCase):
    """The window is midnight to midnight, and on two days a year those are not
    24 hours apart. A fixed offset taken from today gets the far end wrong."""

    def window(self, name, year, month, day, days):
        zone = graph.local_zone(name)
        now = datetime(year, month, day, 12, 0, tzinfo=zone)
        midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
        return midnight.isoformat(), (midnight + timedelta(days=days)).isoformat()

    def test_a_window_over_the_autumn_change_ends_at_local_midnight(self):
        # Europe/Amsterdam goes back to +01:00 on 2026-10-25. Three days from
        # the 24th must end at midnight on the 27th in the offset then in
        # force, not in the +02:00 that is in force on the 24th.
        start, end = self.window("Europe/Amsterdam", 2026, 10, 24, 3)
        self.assertEqual(start, "2026-10-24T00:00:00+02:00")
        self.assertEqual(end, "2026-10-27T00:00:00+01:00")

    def test_a_window_over_the_spring_change(self):
        start, end = self.window("Europe/Amsterdam", 2026, 3, 28, 3)
        self.assertEqual(start, "2026-03-28T00:00:00+01:00")
        self.assertEqual(end, "2026-03-31T00:00:00+02:00")

    def test_an_ordinary_window_is_unchanged(self):
        start, end = self.window("Europe/Amsterdam", 2026, 8, 20, 3)
        self.assertEqual(start, "2026-08-20T00:00:00+02:00")
        self.assertEqual(end, "2026-08-23T00:00:00+02:00")

    def test_an_unusable_zone_name_still_gives_a_zone(self):
        self.assertIsNotNone(graph.local_zone("Not/AZone"))


class OnlineMeetings(unittest.TestCase):
    def test_the_modern_join_url(self):
        self.assertEqual(graph.join_url({"onlineMeeting": {"joinUrl": " x "}}), "x")

    def test_the_legacy_join_url(self):
        self.assertEqual(graph.join_url({"onlineMeetingUrl": "x"}), "x")

    def test_an_online_meeting_with_no_link_has_nothing_to_join(self):
        self.assertEqual(graph.join_url({"isOnlineMeeting": True}), "")

    def test_providers(self):
        self.assertEqual(graph.online_provider({"onlineMeetingProvider": "teamsForBusiness"}), "teams")
        self.assertEqual(graph.online_provider({"onlineMeetingProvider": "skypeForConsumer"}), "skype")
        self.assertEqual(graph.online_provider({"onlineMeetingProvider": "unknown", "isOnlineMeeting": True}), "teams")
        self.assertEqual(graph.online_provider({}), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)

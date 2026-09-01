#!/usr/bin/env python3
"""Unit tests for the Python helpers.

    python3 dev/test-python.py

These cover the parts where being wrong is quiet rather than loud: picking the
wrong widget entry to save into, or letting two aliases share one mailbox's
tokens. Both would look like the plugin working.
"""

import contextlib
import re
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
    folder = []


class FetchAccount(unittest.TestCase):
    """The real fetch_account, with the network answering to order.

    Each mail query backs one of the panel's filter combinations, and they
    cannot stand in for each other: nothing in the unread list need be Focused,
    nor anything in the Focused list unread. One that fails leaves its own view
    short while the others look full, so "did anything come back at all" is not
    the test.
    """

    def fetch(self, failing_queries=(), inbox_ok=True, timezone_name="UTC",
              folder=(), folders=None, folders_error=""):
        failing = set(failing_queries)
        self.calendar_params = {}
        # Every folder the mail queries were pointed at, in order.
        self.folders_read = []

        def collect(token, path, params, *a, **k):
            self.calendar_params = params
            return 200, [], {}, True

        args = Args()
        args.folder = list(folder)

        patched = {
            "read_json": lambda *a, **k: {"username": "you@example.com"},
            "access_token": lambda alias, account: ("token", account),
            "graph_get": lambda *a, **k: (
                (200, {"id": "INBOX-ID", "unreadItemCount": 9}) if inbox_ok
                else (403, {"error": {"message": "Access is denied"}})
            ),
            "fetch_messages": self.messages(failing),
            "fetch_folders": lambda token, inbox_id="": (
                [] if folders_error else (list(folders) if folders is not None else []),
                folders_error,
                True,
            ),
            "graph_collect": collect,
        }
        original = {name: getattr(graph, name) for name in patched}
        for name, stub in patched.items():
            setattr(graph, name, stub)
        try:
            return graph.fetch_account("work", args, timezone_name)
        finally:
            for name, value in original.items():
                setattr(graph, name, value)

    def messages(self, failing):
        def answer(token, top, tz, unread_only=False, focused_only=False, folder_id="inbox"):
            self.folders_read.append(folder_id)
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


ARCHIVE = {"id": "ARCHIVE-ID", "name": "Archive", "unread": 0, "total": 12,
           "childCount": 0, "parentId": "", "depth": 0, "isInbox": False}
INBOX_ROW = {"id": "INBOX-ID", "name": "Inbox", "unread": 9, "total": 40,
             "childCount": 0, "parentId": "", "depth": 0, "isInbox": True}


class Folders(FetchAccount):
    """Reading a folder other than the inbox."""

    def test_no_choice_reads_the_inbox(self):
        result = self.fetch(folders=[INBOX_ROW, ARCHIVE])
        self.assertEqual(result["folderId"], "inbox")
        self.assertEqual(result["folderName"], "Inbox")
        self.assertEqual(set(self.folders_read), {"inbox"})

    def test_a_chosen_folder_is_the_one_read(self):
        result = self.fetch(folder=["work=ARCHIVE-ID"], folders=[INBOX_ROW, ARCHIVE])
        self.assertEqual(result["folderId"], "ARCHIVE-ID")
        self.assertEqual(result["folderName"], "Archive")
        self.assertEqual(set(self.folders_read), {"ARCHIVE-ID"})

    def test_another_mailboxs_choice_is_not_this_ones(self):
        # Folder ids belong to one mailbox. A choice made for "personal" must
        # leave "work" on its inbox rather than sending work's id somewhere.
        result = self.fetch(folder=["personal=ARCHIVE-ID"], folders=[INBOX_ROW, ARCHIVE])
        self.assertEqual(result["folderId"], "inbox")
        self.assertEqual(set(self.folders_read), {"inbox"})

    def test_outside_the_inbox_focused_is_not_asked_for(self):
        # Focused/Other is an inbox split, so those two queries would spend two
        # round trips on a question the folder cannot answer.
        self.fetch(folder=["work=ARCHIVE-ID"], folders=[INBOX_ROW, ARCHIVE])
        self.assertEqual(len(self.folders_read), 2)
        self.fetch(folders=[INBOX_ROW, ARCHIVE])
        self.assertEqual(len(self.folders_read), 4)

    def test_a_folder_that_is_gone_falls_back_to_the_inbox(self):
        result = self.fetch(folder=["work=DELETED-ID"], folders=[INBOX_ROW, ARCHIVE])
        self.assertEqual(result["folderId"], "inbox")
        self.assertEqual(set(self.folders_read), {"inbox"})
        self.assertTrue(any(w["scope"] == "folders" for w in result["warnings"]))

    def test_the_badge_still_counts_the_inbox(self):
        # Browsing Sent must not stop the bar counting new mail.
        result = self.fetch(folder=["work=ARCHIVE-ID"], folders=[INBOX_ROW, ARCHIVE])
        self.assertEqual(result["unreadCount"], 9)
        self.assertTrue(result["unreadKnown"])

    def test_an_unreadable_folder_list_is_a_warning_not_a_failure(self):
        # No sidebar is a degraded window, not a broken mailbox: the inbox is
        # still readable, so the mail must still arrive.
        result = self.fetch(folders_error="Access is denied")
        self.assertTrue(result["ok"])
        self.assertEqual(len(result["mail"]), 4)
        self.assertEqual(result["folders"], [])
        self.assertIn("Access is denied", [w["message"] for w in result["warnings"]])


class FolderChoices(unittest.TestCase):
    def test_pairs_are_read_per_mailbox(self):
        self.assertEqual(
            graph.folder_choices(["work=A", "personal=B"]),
            {"work": "A", "personal": "B"},
        )

    def test_junk_is_dropped_rather_than_guessed_at(self):
        self.assertEqual(graph.folder_choices(["no-equals-sign", "=B", "work=", ""]), {})

    def test_an_id_may_contain_an_equals_sign(self):
        # Graph ids are base64url-ish and routinely end in padding.
        self.assertEqual(graph.folder_choices(["work=AAA=="]), {"work": "AAA=="})


class FolderPaths(unittest.TestCase):
    def test_an_id_is_escaped_into_the_path(self):
        self.assertEqual(graph.messages_path("inbox"), "/me/mailFolders/inbox/messages")
        self.assertEqual(
            graph.messages_path("AA/BB+CC=="),
            "/me/mailFolders/AA%2FBB%2BCC%3D%3D/messages",
        )

    def test_no_folder_means_the_inbox(self):
        self.assertEqual(graph.messages_path(""), "/me/mailFolders/inbox/messages")


SAFELINK = ("https://eur03.safelinks.protection.outlook.com/?url="
            "https%3A%2F%2Fcontoso.sharepoint.com%2Fsites%2Fteam%2FReport.docx"
            "&data=05%7C02%7Cjan%40example.com&sdata=Zm9v%3D&reserved=0")


class Linkify(unittest.TestCase):
    """Plain-text mail, with its links put back.

    Graph's HTML-to-text conversion keeps every link in a form nothing can use:
    two hundred characters of safelink behind the words, or run straight into
    them. These are the shapes it actually writes.
    """

    def render(self, text):
        return graph.linkify(graph.tidy_body(text))

    def test_a_labelled_link_keeps_its_words_and_gains_its_address(self):
        out = self.render("Here: [Open the report]<%s>" % SAFELINK)
        self.assertIn(">Open the report</a>", out)
        # The safelink is what gets followed, so the tenant's own checking
        # still runs. Only the display is unwrapped.
        self.assertIn('href="https://eur03.safelinks', out)

    def test_a_link_run_into_the_words_before_it_is_set_off(self):
        """The bug this fixes: `Unsubscribe<url>` came out as one word."""
        out = self.render("Unsubscribe<https://short.example/u>")
        self.assertIn("Unsubscribe (", out)
        self.assertNotIn("Unsubscribehttps", out)

    def test_one_that_was_already_spaced_is_left_alone(self):
        out = self.render("Raw link: <https://short.example/u>")
        self.assertNotIn("(", out)

    def test_a_safelink_is_shown_as_where_it_really_goes(self):
        out = self.render("See %s for it." % SAFELINK)
        self.assertIn(">https://contoso.sharepoint.com/sites/team/Report.docx<", out)
        self.assertIn('href="https://eur03.safelinks', out)

    def test_a_long_address_is_shortened_to_host_and_tail(self):
        long_url = "https://contoso.sharepoint.com/sites/team/docs/2026/q1/Report.docx?web=1&x=" + "y" * 80
        out = self.render("Raw: <%s>" % long_url)
        self.assertIn(">contoso.sharepoint.com/\u2026/Report.docx<", out)
        # Shortened for reading only - the whole thing is still what opens.
        self.assertIn(long_url.replace("&", "&amp;"), out)

    def test_a_short_address_is_left_whole(self):
        out = self.render("Go to https://example.com/a/b")
        self.assertIn(">https://example.com/a/b<", out)

    def test_a_full_stop_ends_the_sentence_not_the_address(self):
        out = self.render("Go to https://example.com/a.")
        self.assertIn('href="https://example.com/a"', out)
        self.assertTrue(out.endswith("</a>."), out)

    def test_brackets_that_are_not_a_link_are_left_as_prose(self):
        out = self.render("Re: [EXTERNAL] the [1] footnote")
        self.assertEqual(out, "Re: [EXTERNAL] the [1] footnote")

    def test_an_address_is_not_mistaken_for_a_link(self):
        out = self.render("Write to jan@example.com")
        self.assertNotIn("<a ", out)

    def test_what_the_sender_wrote_can_never_become_markup(self):
        """The whole reason this needs no sanitiser: every character out of the
        message is escaped, so the only tags present are the ones built here."""
        out = self.render("Beware <script>alert(1)</script> and 5 < 6 & 7 > 2")
        self.assertNotIn("<script", out)
        self.assertIn("&lt;script&gt;", out)
        self.assertIn("5 &lt; 6 &amp; 7 &gt; 2", out)

    def test_a_javascript_target_inside_a_safelink_is_not_offered(self):
        """The url parameter is text an attacker can choose. Unwrapping it to
        something that is not an address must show the safelink instead."""
        bad = ("https://eur03.safelinks.protection.outlook.com/"
               "?url=javascript%3Aalert(1)&data=x")
        self.assertEqual(graph.unwrap_safelink(bad), bad)

    def test_line_breaks_survive_the_crossing(self):
        self.assertEqual(self.render("One\n\nTwo"), "One<br>\n<br>\nTwo")

    def test_an_ordinary_host_is_not_treated_as_a_safelink(self):
        plain = "https://example.com/?url=https%3A%2F%2Felsewhere.example"
        self.assertEqual(graph.unwrap_safelink(plain), plain)


class Emitted(Exception):
    """graph.out() reached, carrying what it was about to print."""

    def __init__(self, payload):
        super().__init__("emitted")
        self.payload = payload


class MoveArgs:
    account = "work"
    id = "MSG-1"
    folder = "FOLDER-ARCHIVE"


class Move(unittest.TestCase):
    """Filing a message in another folder.

    The move is a write, so a read-only mailbox has to be turned away before
    the request rather than after a 403 - and Graph hands back a *new* id for
    the message in its new home, which the window needs to be told about.
    """

    def run_move(self, write=True, response=(201, {"id": "MSG-1-IN-ARCHIVE"}), **overrides):
        self.calls = []

        def http(url, method="GET", data=None, json_body=None, headers=None, timeout=20):
            self.calls.append({"url": url, "method": method, "body": json_body})
            return response

        args = MoveArgs()
        for key, value in overrides.items():
            setattr(args, key, value)

        patched = {
            "read_json": lambda *a, **k: {"write": write, "scopes": "Mail.ReadWrite"},
            "access_token": lambda alias, account: ("token", account),
            "http": http,
            "out": lambda payload: (_ for _ in ()).throw(Emitted(payload)),
        }
        original = {name: getattr(graph, name) for name in patched}
        for name, stub in patched.items():
            setattr(graph, name, stub)
        try:
            graph.cmd_move(args)
        except Emitted as emitted:
            return emitted.payload
        finally:
            for name, value in original.items():
                setattr(graph, name, value)
        raise AssertionError("cmd_move emitted nothing")

    def test_the_destination_goes_to_the_move_endpoint(self):
        result = self.run_move()
        self.assertTrue(result["ok"])
        self.assertTrue(self.calls[0]["url"].endswith("/messages/MSG-1/move"))
        self.assertEqual(self.calls[0]["method"], "POST")
        self.assertEqual(self.calls[0]["body"], {"destinationId": "FOLDER-ARCHIVE"})

    def test_the_new_id_comes_back_with_the_old_one(self):
        """An id names a message in a folder, so the move changes it. A caller
        that wants to follow the message needs both."""
        result = self.run_move()
        self.assertEqual(result["id"], "MSG-1")
        self.assertEqual(result["newId"], "MSG-1-IN-ARCHIVE")
        self.assertEqual(result["folder"], "FOLDER-ARCHIVE")

    def test_an_id_with_punctuation_is_escaped_into_the_path(self):
        self.run_move(id="AA/BB+CC==")
        self.assertTrue(self.calls[0]["url"].endswith("/messages/AA%2FBB%2BCC%3D%3D/move"))

    def test_a_read_only_mailbox_is_refused_before_the_request(self):
        result = self.run_move(write=False)
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "write_required")
        self.assertEqual(self.calls, [])

    def test_no_destination_is_refused_rather_than_sent(self):
        result = self.run_move(folder="   ")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "no_folder")
        self.assertEqual(self.calls, [])

    def test_a_refused_move_is_reported_as_itself(self):
        result = self.run_move(
            response=(403, {"error": {"message": "Access is denied"}}))
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "move_failed")
        self.assertIn("Access is denied", result["error"]["message"])

    def test_a_no_content_answer_is_still_a_move(self):
        """Graph normally returns the moved message; 204 with nothing in it is
        not a failure, only a move with no new id to report."""
        result = self.run_move(response=(204, None))
        self.assertTrue(result["ok"])
        self.assertEqual(result["newId"], "")


class ComposeArgs:
    account = "work"
    id = "MSG-1"
    mode = "reply"
    comment = "Thanks - will do."
    to = ""
    draft = False


class Compose(unittest.TestCase):
    """Replying, replying to everyone, and forwarding.

    Sending needs Mail.Send; drafting needs only the Mail.ReadWrite a
    write-enabled mailbox already has. The split is the whole point of these
    tests: a mailbox that cannot send must be told so before the request, not
    after a 403, or the window has nothing useful to offer in its place.
    """

    def run_compose(self, scopes="Mail.ReadWrite Mail.Send", write=True, responses=None, **overrides):
        self.calls = []
        queue = list(responses or [(202, {})])

        def http(url, method="GET", data=None, json_body=None, headers=None, timeout=20):
            self.calls.append({"url": url, "method": method, "body": json_body})
            return queue.pop(0) if queue else (202, {})

        args = ComposeArgs()
        for key, value in overrides.items():
            setattr(args, key, value)

        patched = {
            "read_json": lambda *a, **k: {"write": write, "scopes": scopes},
            "access_token": lambda alias, account: ("token", account),
            "http": http,
            "out": lambda payload: (_ for _ in ()).throw(Emitted(payload)),
        }
        original = {name: getattr(graph, name) for name in patched}
        for name, stub in patched.items():
            setattr(graph, name, stub)
        try:
            graph.cmd_compose(args)
        except Emitted as emitted:
            return emitted.payload
        finally:
            for name, value in original.items():
                setattr(graph, name, value)
        raise AssertionError("cmd_compose emitted nothing")

    def test_a_reply_is_sent_to_the_reply_endpoint(self):
        result = self.run_compose()
        self.assertTrue(result["ok"])
        self.assertFalse(result["drafted"])
        self.assertTrue(self.calls[0]["url"].endswith("/reply"))
        self.assertEqual(self.calls[0]["body"], {"comment": "Thanks - will do."})

    def test_reply_all_and_forward_use_their_own_endpoints(self):
        self.run_compose(mode="reply-all")
        self.assertTrue(self.calls[0]["url"].endswith("/replyAll"))
        self.run_compose(mode="forward", to="her@example.com")
        self.assertTrue(self.calls[0]["url"].endswith("/forward"))
        self.assertEqual(
            self.calls[0]["body"]["toRecipients"],
            [{"emailAddress": {"address": "her@example.com"}}],
        )

    def test_a_forward_with_nobody_to_forward_to_is_refused(self):
        result = self.run_compose(mode="forward")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "no_recipient")
        self.assertEqual(self.calls, [])

    def test_an_address_that_is_not_one_is_refused_before_sending(self):
        result = self.run_compose(mode="forward", to="her@example.com, notanaddress")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "bad_recipient")
        self.assertIn("notanaddress", result["error"]["message"])
        self.assertEqual(self.calls, [])

    def test_a_mailbox_without_send_is_told_before_the_request(self):
        result = self.run_compose(scopes="Mail.ReadWrite")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "send_permission_required")
        # Nothing was attempted: the point is to offer the draft instead.
        self.assertEqual(self.calls, [])

    def test_a_read_only_mailbox_cannot_compose_at_all(self):
        result = self.run_compose(write=False)
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "write_required")

    def test_a_draft_needs_no_send_permission(self):
        result = self.run_compose(
            scopes="Mail.ReadWrite", draft=True,
            responses=[(201, {"id": "DRAFT-1", "webLink": "https://outlook/draft"})])
        self.assertTrue(result["ok"])
        self.assertTrue(result["drafted"])
        self.assertEqual(result["webLink"], "https://outlook/draft")
        self.assertTrue(self.calls[0]["url"].endswith("/createReply"))

    def test_a_forwarded_draft_is_addressed_afterwards(self):
        # createForward takes no recipients, so they go on with a PATCH.
        result = self.run_compose(
            mode="forward", to="her@example.com", draft=True, scopes="Mail.ReadWrite",
            responses=[(201, {"id": "DRAFT-2", "webLink": "https://outlook/d2"}), (200, {})])
        self.assertTrue(result["ok"])
        self.assertEqual(self.calls[1]["method"], "PATCH")
        self.assertEqual(
            self.calls[1]["body"]["toRecipients"],
            [{"emailAddress": {"address": "her@example.com"}}],
        )
        self.assertEqual(result["warning"], "")

    def test_a_draft_that_could_not_be_addressed_still_opens(self):
        # Half a draft in Outlook beats an error and no draft.
        result = self.run_compose(
            mode="forward", to="her@example.com", draft=True, scopes="Mail.ReadWrite",
            responses=[(201, {"id": "D", "webLink": "https://outlook/d"}),
                       (403, {"error": {"message": "Access is denied"}})])
        self.assertTrue(result["ok"])
        self.assertTrue(result["drafted"])
        self.assertEqual(result["warning"], "Access is denied")

    def test_a_refused_send_names_the_permission(self):
        # The tenant withheld Mail.Send even though the token claims it.
        result = self.run_compose(responses=[(403, {"error": {"message": "Access denied"}})])
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "send_permission_required")

    def test_any_other_failure_is_reported_as_itself(self):
        result = self.run_compose(responses=[(400, {"error": {"message": "Message too large"}})])
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "send_failed")
        self.assertEqual(result["error"]["message"], "Message too large")


class Recipients(unittest.TestCase):
    def test_the_separators_people_type_all_work(self):
        good, bad = graph.recipient_list("a@b.com, c@d.org; e@f.net\ng@h.io")
        self.assertEqual([r["emailAddress"]["address"] for r in good],
                         ["a@b.com", "c@d.org", "e@f.net", "g@h.io"])
        self.assertEqual(bad, [])

    def test_angle_brackets_are_stripped(self):
        good, _ = graph.recipient_list("<a@b.com>")
        self.assertEqual(good[0]["emailAddress"]["address"], "a@b.com")

    def test_what_is_not_an_address_is_named(self):
        good, bad = graph.recipient_list("fine@example.com, nope, @host, tail@")
        self.assertEqual(len(good), 1)
        self.assertEqual(bad, ["nope", "@host", "tail@"])


class SendPermission(unittest.TestCase):
    def test_the_granted_scopes_decide(self):
        self.assertTrue(graph.can_send({"scopes": "openid Mail.ReadWrite Mail.Send"}))
        self.assertFalse(graph.can_send({"scopes": "openid Mail.ReadWrite"}))

    def test_a_mailbox_from_before_scopes_were_recorded_may_not_send(self):
        # Unknown has to mean no: offering Send and failing is worse than
        # offering the draft, which works either way.
        self.assertFalse(graph.can_send({}))
        self.assertFalse(graph.can_send(None))


class SanitizeHtml(unittest.TestCase):
    """What a mail body may keep when it is rendered as markup.

    Qt's rich text fetches what it is told to fetch, from the shell process and
    the user's IP. A remote image in a message is a tracking pixel that fires
    on render whether or not anyone meant to open it, so the remote references
    come out here rather than being trusted to the renderer.
    """

    def test_text_and_structure_survive(self):
        kept = graph.sanitize_html("<p>Hi <b>there</b></p><ul><li>one</li></ul>")
        self.assertEqual(kept, "<p>Hi <b>there</b></p><ul><li>one</li></ul>")

    def test_a_tracking_pixel_does_not(self):
        self.assertNotIn("tracker", graph.sanitize_html('<img src="https://tracker/x.gif">'))
        self.assertNotIn("<img", graph.sanitize_html('text <img src="https://tracker/x.gif"> more'))

    def test_script_goes_with_its_contents(self):
        cleaned = graph.sanitize_html("before<script>steal()</script>after")
        self.assertEqual(cleaned, "beforeafter")

    def test_style_and_frames_go_the_same_way(self):
        self.assertEqual(graph.sanitize_html("a<style>p{color:red}</style>b"), "ab")
        self.assertEqual(graph.sanitize_html('a<iframe src="https://evil"></iframe>b'), "ab")

    def test_event_handlers_are_stripped(self):
        cleaned = graph.sanitize_html('<div onclick="bad()">body</div>')
        self.assertNotIn("onclick", cleaned)
        self.assertIn("body", cleaned)

    def test_css_cannot_fetch_either(self):
        cleaned = graph.sanitize_html('<div style="background:url(https://tracker/y.png)">x</div>')
        self.assertNotIn("tracker", cleaned)

    def test_a_link_that_runs_something_loses_its_href(self):
        cleaned = graph.sanitize_html('<a href="javascript:bad()">x</a>')
        self.assertNotIn("javascript", cleaned)
        self.assertIn(">x</a>", cleaned)

    def test_an_ordinary_link_is_left_alone(self):
        # The whole point of rendering markup is that the links still work.
        cleaned = graph.sanitize_html('<a href="https://ok.example">ok</a>')
        self.assertIn('href="https://ok.example"', cleaned)

    def test_comments_are_removed(self):
        self.assertEqual(graph.sanitize_html("a<!-- hidden -->b"), "ab")

    def test_nothing_in_nothing_out(self):
        self.assertEqual(graph.sanitize_html(None), "")
        self.assertEqual(graph.sanitize_html(""), "")


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


class QmlText(unittest.TestCase):
    """Every Text and TextEdit item must pin textFormat, exactly once.

    Pinning matters because Qt's AutoText would otherwise let mailbox content
    turn itself into rich text and fetch remote resources. Exactly once matters
    because QML refuses a property assigned twice and drops the whole component
    - which is how a blanket edit that duplicated one line silently killed the
    reading pane, in a file no screenshot happened to cover.
    """

    def text_blocks(self):
        """(file, line, textFormat count) for every Text/TextEdit item in src/.

        TextEdit is in here because selectable text is a TextEdit - a Text item
        cannot be selected at all - and it has the same AutoText default and so
        the same problem. SelectableText does not match: it is this plugin's own
        component, and it pins the format once in its own file.
        """
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src")
        opener = re.compile(r"^\s*(?:[A-Za-z_][\w.]*\s*:\s*)?(?:TextEdit|Text)\s*\{\s*$")
        for name in sorted(os.listdir(root)):
            if not name.endswith(".qml"):
                continue
            with open(os.path.join(root, name), encoding="utf-8") as handle:
                lines = handle.read().split("\n")
            for i, line in enumerate(lines):
                if not opener.match(line):
                    continue
                indent = len(line) - len(line.lstrip())
                count, j = 0, i + 1
                while j < len(lines):
                    cur = lines[j]
                    if cur.strip() and (len(cur) - len(cur.lstrip())) <= indent:
                        break
                    if re.match(r"^\s*textFormat\s*:", cur):
                        count += 1
                    j += 1
                yield name, i + 1, count

    def test_every_text_item_pins_its_format_exactly_once(self):
        blocks = list(self.text_blocks())
        self.assertGreater(len(blocks), 50, "the scanner found almost nothing - has the syntax changed?")
        wrong = ["%s:%d has %d" % b for b in blocks if b[2] != 1]
        self.assertEqual(wrong, [], "Text items not pinned exactly once: " + ", ".join(wrong))


if __name__ == "__main__":
    unittest.main(verbosity=2)

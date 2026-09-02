#!/usr/bin/env python3
"""Unit tests for the Python helpers.

    python3 dev/test-python.py

These cover the parts where being wrong is quiet rather than loud: picking the
wrong widget entry to save into, or letting two aliases share one mailbox's
tokens. Both would look like the plugin working.
"""

import base64
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


class FakeIMAP:
    """Just enough of an imaplib client to record what it was told to do."""

    capabilities = ("IMAP4REV1",)

    def __init__(self):
        self.calls = []

    def _ok(self, name, *args):
        self.calls.append((name,) + args)
        return "OK", [b"done"]

    def create(self, name):
        return self._ok("CREATE", name)

    def rename(self, old, new):
        return self._ok("RENAME", old, new)

    def delete(self, name):
        return self._ok("DELETE", name)

    def subscribe(self, name):
        return self._ok("SUBSCRIBE", name)

    def unsubscribe(self, name):
        return self._ok("UNSUBSCRIBE", name)


class FolderActions(unittest.TestCase):
    """Making and unmaking IMAP folders, which is all path arithmetic.

    A folder id on IMAP is its whole path, so creating one inside another,
    renaming it and moving it under a different parent are the same two
    commands with different strings - and getting the string wrong makes a
    folder at the top level called "Archive/2024".
    """

    TREE = [
        ("INBOX", "/", []),
        ("Archive", "/", ["\\HasChildren"]),
        ("Archive/2024", "/", []),
        ("Backup", "/", []),
    ]

    def setUp(self):
        import imapmail
        self.imapmail = imapmail
        self.client = FakeIMAP()
        self.original = (imapmail.connect, imapmail.close, imapmail.list_folders)
        imapmail.connect = lambda *a, **k: self.client
        imapmail.close = lambda *a, **k: None
        imapmail.list_folders = lambda client: list(self.TREE)

    def tearDown(self):
        (self.imapmail.connect, self.imapmail.close,
         self.imapmail.list_folders) = self.original

    def commands(self, name):
        return [call for call in self.client.calls if call[0] == name]

    def test_a_new_folder_at_the_top_level_is_its_own_path(self):
        result = self.imapmail.create_folder({}, "token", "Receipts", "")
        self.assertEqual(result["id"], "Receipts")
        self.assertEqual(self.commands("CREATE"), [("CREATE", '"Receipts"')])

    def test_a_new_folder_inside_another_carries_its_parent(self):
        result = self.imapmail.create_folder({}, "token", "2025", "Archive")
        self.assertEqual(result["id"], "Archive/2025")
        self.assertEqual(self.commands("CREATE"), [("CREATE", '"Archive/2025"')])
        # Servers list what is subscribed; one nobody subscribed to is a folder
        # this plugin would make and then fail to find.
        self.assertEqual(self.commands("SUBSCRIBE"), [("SUBSCRIBE", '"Archive/2025"')])

    def test_a_name_with_the_delimiter_in_it_is_refused(self):
        with self.assertRaises(self.imapmail.TransportError) as caught:
            self.imapmail.create_folder({}, "token", "2025/Q1", "Archive")
        self.assertEqual(caught.exception.code, "bad_name")
        self.assertEqual(self.commands("CREATE"), [])

    def test_renaming_keeps_the_folder_where_it_is(self):
        result = self.imapmail.rename_folder({}, "token", "Archive/2024", "2023")
        self.assertEqual(result["id"], "Archive/2023")
        self.assertEqual(self.commands("RENAME"),
                         [("RENAME", '"Archive/2024"', '"Archive/2023"')])

    def test_moving_keeps_the_name_and_changes_the_parent(self):
        result = self.imapmail.move_folder({}, "token", "Archive/2024", "Backup")
        self.assertEqual(result["id"], "Backup/2024")
        self.assertEqual(self.commands("RENAME"),
                         [("RENAME", '"Archive/2024"', '"Backup/2024"')])

    def test_moving_to_the_top_level_drops_the_parent(self):
        result = self.imapmail.move_folder({}, "token", "Archive/2024", "")
        self.assertEqual(result["id"], "2024")

    def test_a_folder_cannot_be_moved_inside_itself(self):
        with self.assertRaises(self.imapmail.TransportError) as caught:
            self.imapmail.move_folder({}, "token", "Archive", "Archive/2024")
        self.assertEqual(caught.exception.code, "bad_folder")
        self.assertEqual(self.commands("RENAME"), [])

    def test_the_inbox_is_left_alone(self):
        for call in (lambda: self.imapmail.rename_folder({}, "token", "INBOX", "Post"),
                     lambda: self.imapmail.move_folder({}, "token", "INBOX", "Archive"),
                     lambda: self.imapmail.delete_folder({}, "token", "INBOX")):
            with self.assertRaises(self.imapmail.TransportError) as caught:
                call()
            self.assertEqual(caught.exception.code, "bad_folder")

    def test_a_folder_with_folders_in_it_is_refused_rather_than_guessed_at(self):
        # RFC 3501 lets a server either refuse this or leave a \Noselect husk
        # behind, and neither is something to find out about afterwards.
        with self.assertRaises(self.imapmail.TransportError) as caught:
            self.imapmail.delete_folder({}, "token", "Archive")
        self.assertEqual(caught.exception.code, "has_children")
        self.assertEqual(self.commands("DELETE"), [])

    def test_deleting_a_leaf_unsubscribes_it_first(self):
        result = self.imapmail.delete_folder({}, "token", "Archive/2024")
        self.assertEqual(result["id"], "Archive/2024")
        self.assertEqual(self.commands("DELETE"), [("DELETE", '"Archive/2024"')])
        self.assertEqual(self.commands("UNSUBSCRIBE"), [("UNSUBSCRIBE", '"Archive/2024"')])


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


class StripMarkupLinks(unittest.TestCase):
    """HTML mail crossing to text on the IMAP path, with its addresses intact.

    Graph converts HTML to text itself and keeps the links; over IMAP the
    conversion happens here, and it used to throw every href away. A sign-in
    mail then arrived as the word "Sign in" with nothing behind it.
    """

    def setUp(self):
        import imapmail
        self.imapmail = imapmail

    def strip(self, markup, keep_links=True):
        return self.imapmail.strip_markup(markup, keep_links=keep_links)

    def render(self, markup):
        """All the way to the markup the reading pane is handed."""
        return graph.linkify(graph.tidy_body(self.strip(markup)))

    def test_an_anchor_keeps_its_words_and_its_address(self):
        out = self.strip('<p>Click <a href="https://claude.ai/magic-link?x=1">Sign in</a></p>')
        self.assertIn("[Sign in]<https://claude.ai/magic-link?x=1>", out)

    def test_that_shape_is_the_one_linkify_makes_clickable(self):
        """The bug the user hit: the words were there, the link was not."""
        out = self.render('Click <a href="https://claude.ai/magic-link?x=1">Sign in</a>')
        self.assertIn('href="https://claude.ai/magic-link?x=1"', out)
        self.assertIn(">Sign in</a>", out)

    def test_an_address_survives_the_tag_strip_that_used_to_eat_it(self):
        """`<https://…>` is as angle-bracketed as any tag - hence the parking."""
        out = self.strip('<div><a href="https://example.com/a">Go</a></div>')
        self.assertIn("https://example.com/a", out)

    def test_an_entity_in_the_address_is_decoded(self):
        out = self.strip('<a href="https://example.com/?a=1&amp;b=2">Report</a>')
        self.assertIn("[Report]<https://example.com/?a=1&b=2>", out)

    def test_an_anchor_around_nothing_visible_comes_back_as_a_bare_link(self):
        """A stripped image leaves no words, and linkify shortens the address
        into a label of its own rather than showing an empty one."""
        out = self.strip('<a href="https://example.com/x"><img src="https://t.example/p.gif"></a>')
        self.assertIn("<https://example.com/x>", out)
        self.assertNotIn("[]", out)

    def test_a_scheme_the_pane_will_not_follow_keeps_only_its_words(self):
        out = self.strip('<a href="javascript:alert(1)">Press</a>')
        self.assertNotIn("javascript", out)
        self.assertIn("Press", out)

    def test_a_label_cannot_break_the_shape_it_is_written_into(self):
        """linkify ends a label at a `]`, so one in the words must not reach it."""
        out = self.strip('<a href="https://example.com/a">See [1] here</a>')
        self.assertIn("[See (1) here]<https://example.com/a>", out)
        self.assertIn(">See (1) here</a>", graph.linkify(graph.tidy_body(out)))

    def test_a_very_long_label_is_trimmed_to_what_linkify_accepts(self):
        out = self.render('<a href="https://example.com/a">%s</a>' % ("word " * 60))
        self.assertIn('href="https://example.com/a"', out)

    def test_markup_inside_the_words_does_not_ride_along(self):
        out = self.strip('<a href="https://example.com/a"><span>Open</span> <b>it</b></a>')
        self.assertIn("[Open it]<https://example.com/a>", out)

    def test_a_null_a_sender_planted_cannot_forge_a_link(self):
        """The parking marker is NUL-delimited, so any NUL in the body goes."""
        out = self.strip('\x000\x00 <a href="https://example.com/a">Real</a>')
        self.assertEqual(out.count("https://example.com/a"), 1)

    def test_a_preview_still_gets_the_words_without_the_addresses(self):
        """The other caller: one line has no room for two hundred characters
        of safelink, which is why keeping them is opt-in."""
        out = self.strip('Click <a href="https://example.com/a">Sign in</a>', keep_links=False)
        self.assertNotIn("https://example.com/a", out)
        self.assertIn("Sign in", out)


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


class FlagArgs:
    account = "work"
    id = "MSG-1"
    flagged = True


class Flag(unittest.TestCase):
    """Raising and clearing the follow-up flag.

    Outlook's flag has three states and only two of them are a flag: clearing
    has to send notFlagged, because "complete" is a ticked-off task and would
    leave Outlook drawing a tick where the user asked for nothing.
    """

    def run_flag(self, write=True, response=(200, {}), **overrides):
        self.calls = []

        def http(url, method="GET", data=None, json_body=None, headers=None, timeout=20):
            self.calls.append({"url": url, "method": method, "body": json_body})
            return response

        args = FlagArgs()
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
            graph.cmd_flag(args)
        except Emitted as emitted:
            return emitted.payload
        finally:
            for name, value in original.items():
                setattr(graph, name, value)
        raise AssertionError("cmd_flag emitted nothing")

    def test_flagging_patches_the_message(self):
        result = self.run_flag()
        self.assertTrue(result["ok"])
        self.assertTrue(result["flagged"])
        self.assertTrue(self.calls[0]["url"].endswith("/messages/MSG-1"))
        self.assertEqual(self.calls[0]["method"], "PATCH")
        self.assertEqual(self.calls[0]["body"], {"flag": {"flagStatus": "flagged"}})

    def test_clearing_says_notflagged_rather_than_complete(self):
        result = self.run_flag(flagged=False)
        self.assertFalse(result["flagged"])
        self.assertEqual(self.calls[0]["body"], {"flag": {"flagStatus": "notFlagged"}})

    def test_an_id_with_punctuation_is_escaped_into_the_path(self):
        self.run_flag(id="AA/BB+CC==")
        self.assertTrue(self.calls[0]["url"].endswith("/messages/AA%2FBB%2BCC%3D%3D"))

    def test_a_read_only_mailbox_is_refused_before_the_request(self):
        result = self.run_flag(write=False)
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "write_required")
        self.assertEqual(self.calls, [])

    def test_a_refused_flag_is_reported_as_itself(self):
        result = self.run_flag(response=(403, {"error": {"message": "Access is denied"}}))
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "flag_failed")
        self.assertIn("Access is denied", result["error"]["message"])

    def test_a_no_content_answer_is_still_a_flag(self):
        result = self.run_flag(response=(204, None))
        self.assertTrue(result["ok"])


class MessageRowFlag(unittest.TestCase):
    """What the list rows say about the flag.

    Graph's flagStatus is a string with three values; the row carries a boolean,
    and "complete" is not one of the two that mean a flag is still standing.
    """

    def test_a_flagged_message_says_so(self):
        row = graph.message_row({"id": "1", "flag": {"flagStatus": "flagged"}})
        self.assertTrue(row["flagged"])

    def test_notflagged_and_a_missing_flag_are_both_unflagged(self):
        self.assertFalse(graph.message_row({"id": "1", "flag": {"flagStatus": "notFlagged"}})["flagged"])
        self.assertFalse(graph.message_row({"id": "1"})["flagged"])

    def test_a_completed_follow_up_is_not_a_standing_flag(self):
        row = graph.message_row({"id": "1", "flag": {"flagStatus": "complete"}})
        self.assertFalse(row["flagged"])


class ComposeArgs:
    account = "work"
    id = "MSG-1"
    mode = "reply"
    comment = "Thanks - will do."
    to = ""
    draft = False


class Attachments(unittest.TestCase):
    """Files on a reply, which Graph cannot do in the one request a reply is."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.file = os.path.join(self.dir, "quote.pdf")
        with open(self.file, "wb") as handle:
            handle.write(b"%PDF-1.4 not really")

    def run_compose(self, responses=None, attach=None, draft=False, **overrides):
        self.calls = []
        queue = list(responses or [(201, {"id": "DRAFT-1"}), (201, {}), (202, {})])

        def http(url, method="GET", data=None, json_body=None, headers=None, timeout=20):
            self.calls.append({"url": url, "method": method, "body": json_body})
            return queue.pop(0) if queue else (202, {})

        args = ComposeArgs()
        args.attach = [self.file] if attach is None else attach
        args.draft = draft
        for key, value in overrides.items():
            setattr(args, key, value)

        patched = {
            "read_json": lambda *a, **k: {"write": True, "scopes": "Mail.ReadWrite Mail.Send"},
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

    def test_a_reply_with_a_file_goes_through_a_draft_because_reply_cannot_carry_one(self):
        result = self.run_compose()
        self.assertTrue(result["ok"])
        self.assertEqual(result["attached"], ["quote.pdf"])
        urls = [call["url"] for call in self.calls]
        self.assertTrue(urls[0].endswith("/createReply"))
        self.assertTrue(urls[1].endswith("/attachments"))
        self.assertTrue(urls[2].endswith("/send"))
        # And never the one-shot endpoint, which would drop the attachment.
        self.assertFalse(any(url.endswith("/reply") for url in urls))

    def test_the_file_goes_as_a_base64_fileAttachment_under_its_own_name(self):
        self.run_compose()
        body = self.calls[1]["body"]
        self.assertEqual(body["@odata.type"], "#microsoft.graph.fileAttachment")
        self.assertEqual(body["name"], "quote.pdf")
        self.assertEqual(base64.b64decode(body["contentBytes"]), b"%PDF-1.4 not really")

    def test_a_forward_with_a_file_is_addressed_before_it_is_sent(self):
        self.run_compose(mode="forward", to="her@example.com",
                         responses=[(201, {"id": "D1"}), (200, {}), (201, {}), (202, {})])
        self.assertEqual(self.calls[1]["method"], "PATCH")
        self.assertEqual(self.calls[1]["body"],
                         {"toRecipients": [{"emailAddress": {"address": "her@example.com"}}]})

    def test_a_draft_gets_the_file_too(self):
        result = self.run_compose(draft=True, responses=[(201, {"id": "D1", "webLink": "x"}), (201, {})])
        self.assertTrue(result["drafted"])
        self.assertTrue(self.calls[1]["url"].endswith("/attachments"))

    def test_a_file_that_would_not_attach_says_where_the_message_is(self):
        result = self.run_compose(responses=[(201, {"id": "D1"}),
                                            (413, {"error": {"message": "too big"}})])
        self.assertEqual(result["error"]["code"], "attach_failed")
        self.assertIn("waiting in your drafts", result["error"]["message"])

    def test_a_missing_file_is_refused_before_anything_is_asked_of_outlook(self):
        result = self.run_compose(attach=["/does/not/exist"])
        self.assertEqual(result["error"]["code"], "no_file")
        self.assertEqual(self.calls, [])

    def test_an_empty_file_is_refused(self):
        empty = os.path.join(self.dir, "empty.txt")
        open(empty, "wb").close()
        result = self.run_compose(attach=[empty])
        self.assertEqual(result["error"]["code"], "empty_file")

    def test_the_cap_is_about_what_one_request_can_carry(self):
        big = os.path.join(self.dir, "big.bin")
        with open(big, "wb") as handle:
            handle.truncate(graph.ATTACH_CAP + 1)
        result = self.run_compose(attach=[big])
        self.assertEqual(result["error"]["code"], "too_large")

    def test_several_files_are_capped_together_not_one_by_one(self):
        paths = []
        for index in range(3):
            path = os.path.join(self.dir, "part%d.bin" % index)
            with open(path, "wb") as handle:
                handle.truncate(graph.ATTACH_CAP // 2)
            paths.append(path)
        result = self.run_compose(attach=paths)
        self.assertEqual(result["error"]["code"], "too_large")

    def test_nothing_attached_still_takes_the_one_request_path(self):
        result = self.run_compose(attach=[], responses=[(202, {})])
        self.assertTrue(result["ok"])
        self.assertTrue(self.calls[0]["url"].endswith("/reply"))
        self.assertNotIn("attached", result)


class ImapAttachments(unittest.TestCase):
    """The same files over SMTP, where the MIME has to be assembled here."""

    def build(self, attachments):
        import imapmail
        sent = {}

        def fake_message(account, token, message_id, want_html=False):
            return {"subject": "Rechnung", "fromAddress": "her@example.com",
                    "to": [], "cc": [], "messageId": "<abc@example.com>",
                    "body": "the original", "received": ""}

        class FakeSMTP:
            def __init__(self, *a, **k):
                pass

            def ehlo(self):
                pass

            def starttls(self):
                pass

            def auth(self, *a, **k):
                pass

            def send_message(self, note):
                sent["note"] = note

            def quit(self):
                pass

        original = (imapmail.message, imapmail.smtplib.SMTP, imapmail.connect)
        imapmail.message = fake_message
        imapmail.smtplib.SMTP = FakeSMTP
        # Filing a copy in Sent Items is best effort; refusing the connection
        # here exercises the warning rather than the failure.
        imapmail.connect = lambda *a, **k: (_ for _ in ()).throw(OSError("no imap"))
        try:
            result = imapmail.compose({"username": "me@example.com"}, "token", "1",
                                      "reply", "here you go", [], False, attachments)
        finally:
            imapmail.message, imapmail.smtplib.SMTP, imapmail.connect = original
        return result, sent.get("note")

    def test_a_file_becomes_a_multipart_part_with_its_name_and_type(self):
        result, note = self.build([("quote.pdf", b"%PDF-1.4")])
        self.assertTrue(result["ok"])
        self.assertTrue(note.is_multipart())
        parts = [part for part in note.walk() if part.get_filename()]
        self.assertEqual([part.get_filename() for part in parts], ["quote.pdf"])
        self.assertEqual(parts[0].get_content_type(), "application/pdf")
        self.assertEqual(parts[0].get_payload(decode=True), b"%PDF-1.4")

    def test_an_unguessable_type_falls_back_to_octet_stream(self):
        _result, note = self.build([("thing.zzz", b"xx")])
        parts = [part for part in note.walk() if part.get_filename()]
        self.assertEqual(parts[0].get_content_type(), "application/octet-stream")

    def test_the_reply_is_still_a_reply_with_a_file_on_it(self):
        _result, note = self.build([("quote.pdf", b"%PDF-1.4")])
        self.assertEqual(note["Subject"], "Re: Rechnung")
        self.assertEqual(note["In-Reply-To"], "<abc@example.com>")
        self.assertIn("here you go", note.get_body(("plain",)).get_content())

    def test_no_attachments_leaves_it_a_plain_message(self):
        _result, note = self.build([])
        self.assertFalse(note.is_multipart())

    def test_the_message_id_carries_the_mailbox_domain_not_this_machines_name(self):
        # make_msgid() with no domain calls socket.getfqdn(): five seconds of
        # waiting on a resolver here, and the machine's hostname written into a
        # header the recipient reads. Both were real.
        _result, note = self.build([])
        self.assertTrue(note["Message-ID"].endswith("@example.com>"), note["Message-ID"])


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



def tiny_png(width=20, height=10, rgb=(0, 200, 0)):
    """A real PNG, so the sniffing and the sizing are exercised on real bytes."""
    import zlib, struct
    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b""))


class ImageSniffing(unittest.TestCase):
    """What the bytes are, rather than what a header said they were."""

    def test_a_png_is_recognised_and_measured(self):
        data = tiny_png(20, 10)
        self.assertEqual(graph.image_kind(data), "image/png")
        self.assertEqual(graph.image_size(data, "image/png"), (20, 10))

    def test_a_gif_is_recognised(self):
        self.assertEqual(graph.image_kind(b"GIF89a" + b"\x20\x00\x10\x00" + b"x" * 20), "image/gif")

    def test_html_pretending_to_be_a_picture_is_not_one(self):
        self.assertEqual(graph.image_kind(b"<html>gotcha</html>"), "")

    def test_an_svg_is_refused_though_qt_could_draw_it(self):
        """It is a document that can carry its own references out to the
        network, which is the one thing this path exists to keep out."""
        self.assertEqual(graph.image_kind(b"<svg xmlns='http://www.w3.org/2000/svg'></svg>"), "")

    def test_nothing_is_not_an_image(self):
        self.assertEqual(graph.image_kind(b""), "")
        self.assertEqual(graph.image_kind(None), "")

    def test_a_size_it_cannot_read_is_not_guessed_at(self):
        self.assertIsNone(graph.image_size(b"RIFF0000WEBP", "image/webp"))


class InlineImages(unittest.TestCase):
    """Pictures the message brought with it cost nothing to show."""

    def setUp(self):
        self.png = tiny_png()

    def render(self, markup, policy):
        return graph.sanitized(markup, policy, graph.HTML_BODY_CAP)[0]

    def test_a_cid_image_is_embedded_from_the_message_itself(self):
        policy = graph.ImagePolicy({"logo": self.png})
        out = self.render('<img src="cid:logo">', policy)
        self.assertIn("<img src=\"data:image/png;base64,", out)
        self.assertEqual((policy.shown, policy.blocked), (1, 0))

    def test_the_angle_brackets_of_a_content_id_header_are_not_part_of_the_id(self):
        """A Content-ID is written <logo@host>; the cid: in the markup is not.
        The map is keyed the way the markup writes it."""
        import email.message, imapmail
        outer = email.message.EmailMessage()
        outer.make_related()
        outer.add_alternative('<img src="cid:logo@host">', subtype="html")
        outer.get_payload()[0].add_related(self.png, maintype="image", subtype="png",
                                           cid="<logo@host>")
        found = imapmail.inline_images(outer)
        self.assertIn("logo@host", found)
        self.assertIn("data:image/png",
                      self.render('<img src="cid:logo@host">', graph.ImagePolicy(found)))

    def test_a_part_that_is_not_an_image_is_not_offered_as_one(self):
        import email.message, imapmail
        outer = email.message.EmailMessage()
        outer.make_related()
        outer.add_alternative("hello", subtype="plain")
        outer.get_payload()[0].add_related(b"MZ not a picture", maintype="application",
                                           subtype="octet-stream", cid="<thing>")
        self.assertEqual(imapmail.inline_images(outer), {})

    def test_a_cid_with_no_part_behind_it_leaves_nothing(self):
        policy = graph.ImagePolicy({})
        self.assertEqual(self.render('<img src="cid:missing">', policy), "")
        # Not counted as blocked: nothing was withheld, the message is broken.
        self.assertEqual(policy.blocked, 0)

    def test_a_data_uri_that_is_really_an_image_survives(self):
        encoded = base64.b64encode(self.png).decode()
        policy = graph.ImagePolicy()
        self.assertIn("data:image/png", self.render('<img src="data:image/png;base64,%s">' % encoded, policy))

    def test_a_data_uri_that_is_not_an_image_does_not(self):
        encoded = base64.b64encode(b"<html>nope</html>").decode()
        policy = graph.ImagePolicy()
        self.assertEqual(self.render('<img src="data:image/png;base64,%s">' % encoded, policy), "")

    def test_a_picture_wider_than_the_pane_is_given_a_size_that_fits(self):
        policy = graph.ImagePolicy({"wide": tiny_png(1200, 300)})
        out = self.render('<img src="cid:wide">', policy)
        self.assertIn('width="560" height="140"', out)

    def test_one_that_already_fits_is_left_at_its_own_size(self):
        policy = graph.ImagePolicy({"small": self.png})
        self.assertNotIn("width=", self.render('<img src="cid:small">', policy))

    def test_a_scheme_nobody_asked_for_is_dropped(self):
        policy = graph.ImagePolicy()
        for source in ("file:///etc/passwd", "javascript:alert(1)", "ftp://x/y.png"):
            self.assertEqual(self.render('<img src="%s">' % source, policy), "")

    def test_the_count_stops_at_the_cap(self):
        policy = graph.ImagePolicy({"a": self.png})
        markup = '<img src="cid:a">' * (graph.IMAGE_MAX_COUNT + 5)
        self.render(markup, policy)
        self.assertEqual(policy.shown, graph.IMAGE_MAX_COUNT)

    def test_the_total_budget_stops_it_too(self):
        policy = graph.ImagePolicy({"a": self.png})
        policy.budget = len(self.png)
        self.render('<img src="cid:a"><img src="cid:a">', policy)
        self.assertEqual(policy.shown, 1)


class RemoteImages(unittest.TestCase):
    """A remote image is a request from the reader's own address, so it is a
    decision rather than a default."""

    def render(self, markup, policy):
        return graph.sanitized(markup, policy, graph.HTML_BODY_CAP)[0]

    def test_a_remote_image_is_counted_and_left_out(self):
        policy = graph.ImagePolicy()
        out = self.render('<p>hi</p><img src="https://tracker.example/pixel.gif">', policy)
        self.assertNotIn("tracker.example", out)
        self.assertNotIn("<img", out)
        self.assertEqual(policy.blocked, 1)

    def test_nothing_is_fetched_while_it_is_left_out(self):
        """The property the whole default rests on: not merely that the picture
        is absent from the markup, but that nobody was asked for it."""
        asked = []
        policy = graph.ImagePolicy()
        policy.fetch = lambda url: asked.append(url)
        self.render('<img src="https://tracker.example/p.gif">', policy)
        self.assertEqual(asked, [])

    def test_pressing_the_button_is_what_makes_the_request(self):
        asked = []
        png = tiny_png()
        policy = graph.ImagePolicy(fetch_remote=True)
        policy.fetch = lambda url: (asked.append(url), png)[1]
        out = self.render('<img src="https://cdn.example/a.png">', policy)
        self.assertEqual(asked, ["https://cdn.example/a.png"])
        self.assertIn("data:image/png", out)

    def test_a_fetch_that_fails_is_counted_rather_than_raised(self):
        policy = graph.ImagePolicy(fetch_remote=True)
        policy.fetch = lambda url: None
        self.assertEqual(self.render('<img src="https://cdn.example/a.png">', policy), "")
        self.assertEqual(policy.blocked, 1)

    def test_what_comes_back_is_believed_only_if_it_is_an_image(self):
        policy = graph.ImagePolicy(fetch_remote=True)
        policy.fetch = lambda url: b"<html>not a picture</html>"
        out = self.render('<img src="https://cdn.example/a.png">', policy)
        self.assertNotIn("not a picture", out)
        self.assertEqual(policy.blocked, 1)


class ImagesAndTheRestOfTheSanitiser(unittest.TestCase):
    """The images have to survive the pass that strips every other src."""

    def test_an_embedded_image_is_not_eaten_by_the_attribute_strip(self):
        """_HTML_REMOTE_ATTRS takes src off every tag and cannot know this one
        is bytes - which is why the image is parked and put back afterwards."""
        policy = graph.ImagePolicy({"logo": tiny_png()})
        out = graph.sanitized('<img src="cid:logo">', policy, graph.HTML_BODY_CAP)[0]
        self.assertIn("src=\"data:image/png", out)

    def test_a_marker_a_sender_planted_cannot_forge_an_image(self):
        policy = graph.ImagePolicy({"logo": tiny_png()})
        out = graph.sanitized('\x00i0\x00<img src="cid:logo">', policy, graph.HTML_BODY_CAP)[0]
        self.assertEqual(out.count("data:image/png"), 1)

    def test_the_cap_counts_the_markup_and_not_the_photograph(self):
        """A body of a few hundred characters plus one large picture is not a
        truncated body - the cap is there to bound tags and words."""
        policy = graph.ImagePolicy({"a": tiny_png(400, 400)})
        body, truncated = graph.sanitized("<p>short</p>" + '<img src="cid:a">', policy, 200)
        self.assertFalse(truncated)
        self.assertIn("data:image/png", body)

    def test_without_a_policy_every_image_still_goes(self):
        self.assertNotIn("<img", graph.sanitize_html('<img src="cid:logo">'))
        self.assertNotIn("<img", graph.sanitize_html('<img src="https://tracker/x.gif">'))


class BodyMode(unittest.TestCase):
    """Which body a message is built as, and who decided."""

    def mode(self, body="", html=False):
        import argparse
        return graph.body_mode(argparse.Namespace(body=body, html=html))

    def test_nothing_asked_for_is_auto(self):
        self.assertEqual(self.mode(), "auto")

    def test_the_older_html_flag_still_means_html(self):
        """The skill file and anything an agent wrote against it pass --html."""
        self.assertEqual(self.mode(html=True), "html")

    def test_an_explicit_mode_wins_over_the_older_flag(self):
        self.assertEqual(self.mode(body="text", html=True), "text")

    def test_a_mode_that_is_not_one_falls_back_rather_than_raising(self):
        self.assertEqual(self.mode(body="fancy"), "auto")

    def test_auto_renders_markup_only_where_there_was_no_text_part(self):
        """render_body is handed the decision, not the request - which is how
        an HTML-only message reaches the pane formatted with nobody asking."""
        markup = "<p>Hello</p>"
        self.assertEqual(graph.render_body(markup, True, True)[2], "html")
        self.assertEqual(graph.render_body(markup, True, False)[2], "linked")


class HasHtml(unittest.TestCase):
    """Whether the reading pane has any formatting to offer."""

    def build(self, plain=None, markup=None):
        import email.message
        message = email.message.EmailMessage()
        if plain is not None and markup is not None:
            message.set_content(plain)
            message.add_alternative(markup, subtype="html")
        elif markup is not None:
            message.set_content(markup, subtype="html")
        else:
            message.set_content(plain or "")
        return message

    def test_a_plain_message_offers_nothing(self):
        import imapmail
        self.assertFalse(imapmail.has_html(self.build(plain="Just words")))

    def test_both_parts_means_there_is_something_to_show(self):
        """body_of prefers the plain part, so this is exactly the case the
        button exists for: text on screen, markup available behind it."""
        import imapmail
        message = self.build(plain="Just words", markup="<p>Just words</p>")
        self.assertFalse(imapmail.body_of(message, False)[1])
        self.assertTrue(imapmail.has_html(message))

    def test_an_html_only_message_says_so_both_ways(self):
        import imapmail
        message = self.build(markup="<p>Only markup</p>")
        self.assertTrue(imapmail.body_of(message, False)[1])
        self.assertTrue(imapmail.has_html(message))

    def test_an_attached_page_is_not_the_message_s_own_formatting(self):
        """A .html file on a plain-text message would otherwise light the
        button up on a body that has nothing else to show."""
        import imapmail
        message = self.build(plain="See attached")
        message.add_attachment(b"<p>report</p>", maintype="text", subtype="html",
                               filename="report.html")
        self.assertFalse(imapmail.has_html(message))


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

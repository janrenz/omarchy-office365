#!/usr/bin/env python3
"""Unit tests for the Python helpers.

    python3 dev/test-python.py

These cover the parts where being wrong is quiet rather than loud: picking the
wrong widget entry to save into, or letting two aliases share one mailbox's
tokens. Both would look like the plugin working.
"""

import base64
import contextlib
import email.policy
import re
import io
import json
import os
import sys
import tempfile
import unittest
from email.message import EmailMessage
from datetime import datetime, timedelta

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src"))

import config  # noqa: E402
import graph  # noqa: E402

PLUGIN = "caseonline.omarchy.office365"


# An INTERNALDATE the way imaplib hands one over, so `received_iso` has
# something real to read: the arrival time is what both transports report, and
# the Date: header is the sender's clock.
IMAP_PREFIX = b'1 (UID 7 INTERNALDATE "01-Sep-2026 10:00:00 +0000" BODY[]<0>'


def imap_message(subject="Rechnung", sender="Her Name <her@example.com>",
                 to="Me <me@example.com>", cc='"Renz, Jan" <jan@x.de>',
                 message_id="<abc@example.com>", body="the original body",
                 attachments=(), references="", html=""):
    """One message as it arrives over IMAP, parsed the way a fetch parses it.

    A real source rather than a dict written by hand. The dict was how these
    tests came to assert on a `messageId` key that the shipped code never put
    there - so every reply over this transport went out unthreaded while the
    suite stayed green.
    """
    import imapmail
    note = EmailMessage(policy=email.policy.SMTP)
    note["From"] = sender
    note["To"] = to
    if cc:
        note["Cc"] = cc
    note["Subject"] = subject
    note["Message-ID"] = message_id
    note["Date"] = "Tue, 01 Sep 2026 12:00:00 +0200"
    if references:
        note["References"] = references
    note.set_content(body)
    if html:
        note.add_alternative(html, subtype="html")
    for name, payload, content_type in attachments:
        maintype, _, subtype = content_type.partition("/")
        note.add_attachment(payload, maintype=maintype, subtype=subtype, filename=name)
    return imapmail.parse_headers(note.as_bytes())


def imap_fetch(source, cut=False):
    """A `fetch_parsed` stand-in for one message."""
    return lambda account, token, message_id, cap=None: (source, IMAP_PREFIX, cut)


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


class GraphSearch(unittest.TestCase):
    """Asking Exchange's own index, and what to do when it will not answer.

    $search is the only way to reach mail older than the fetch window, and it
    comes with two rules worth a test each: it will not sort, and a tenant that
    has it turned off says 400 rather than answering empty. Getting the first
    wrong gives a list in relevance order that looks shuffled; getting the
    second wrong turns "your admin disabled search" into "no results".
    """

    def setUp(self):
        self.calls = []
        self.original = graph.graph_get
        graph.graph_get = self.answer

    def tearDown(self):
        graph.graph_get = self.original

    def answer(self, token, path, params, *a, **k):
        self.calls.append((path, dict(params)))
        return self.replies.pop(0)

    @staticmethod
    def message(mid, when, subject="Rechnung", folder="F-INBOX"):
        return {"id": mid, "subject": subject, "receivedDateTime": when,
                "from": {"emailAddress": {"name": "Her", "address": "her@example.com"}},
                "bodyPreview": "text", "isRead": False, "parentFolderId": folder}

    def test_the_query_travels_verbatim_and_unsorted(self):
        self.replies = [(200, {"value": []})]
        graph.graph_search("token", "from:kees rechnung", 50, "UTC")
        path, params = self.calls[0]
        # The whole mailbox, not one folder, and the KQL the user typed - the
        # from: prefix is Exchange's to read, not this file's to parse.
        self.assertEqual(path, "/me/messages")
        self.assertEqual(params["$search"], '"from:kees rechnung"')
        # $orderby with $search is a 400. Asking for it would fail every search.
        self.assertNotIn("$orderby", params)
        self.assertIn("parentFolderId", params["$select"])

    def test_relevance_order_comes_back_as_date_order(self):
        self.replies = [(200, {"value": [
            self.message("old", "2026-01-02T09:00:00Z"),
            self.message("new", "2026-08-02T09:00:00Z"),
        ]})]
        rows, warnings, error = graph.graph_search("token", "rechnung", 50, "UTC")
        self.assertEqual([row["id"] for row in rows], ["new", "old"])
        self.assertEqual((warnings, error), ([], ""))

    def test_a_hit_says_which_folder_it_was_found_in(self):
        self.replies = [(200, {"value": [self.message("a", "2026-08-02T09:00:00Z", folder="F-SENT")]})]
        rows, _warnings, _error = graph.graph_search("token", "rechnung", 50, "UTC")
        self.assertEqual(rows[0]["folderId"], "F-SENT")

    def test_one_folder_when_that_is_what_was_asked_for(self):
        self.replies = [(200, {"value": []})]
        graph.graph_search("token", "rechnung", 50, "UTC", "F-ARCHIVE")
        self.assertEqual(self.calls[0][0], graph.messages_path("F-ARCHIVE"))

    def test_a_tenant_with_search_off_falls_back_to_subjects(self):
        self.replies = [(400, {"error": {"message": "Search is not enabled"}}),
                        (200, {"value": [self.message("a", "2026-08-02T09:00:00Z")]})]
        rows, warnings, error = graph.graph_search("token", "rechnung", 50, "UTC")
        self.assertEqual([row["id"] for row in rows], ["a"])
        self.assertEqual(error, "")
        # Said out loud: a subject-only search that claims to have read bodies
        # is how somebody concludes the message is not there.
        self.assertIn("subjects only", warnings[0]["message"])
        self.assertEqual(self.calls[1][1]["$filter"], "contains(subject,'rechnung')")

    def test_an_apostrophe_is_doubled_rather_than_ending_the_literal(self):
        self.replies = [(400, {}), (200, {"value": []})]
        graph.graph_search("token", "o'brien", 50, "UTC")
        self.assertEqual(self.calls[1][1]["$filter"], "contains(subject,'o''brien')")

    def test_a_quote_cannot_end_the_kql_string_early(self):
        self.replies = [(200, {"value": []})]
        graph.graph_search("token", 'say "hello" now', 50, "UTC")
        self.assertEqual(self.calls[0][1]["$search"], '"say  hello  now"')

    def test_a_refused_sort_is_dropped_before_the_search_is_given_up_on(self):
        self.replies = [(400, {}), (400, {}), (200, {"value": []})]
        graph.graph_search("token", "rechnung", 50, "UTC")
        self.assertEqual(self.calls[1][1].get("$orderby"), "receivedDateTime desc")
        self.assertNotIn("$orderby", self.calls[2][1])

    def test_a_sign_in_failure_is_not_retried_as_a_subject_search(self):
        self.replies = [(401, {"error": {"message": "Access token has expired"}})]
        rows, _warnings, error = graph.graph_search("token", "rechnung", 50, "UTC")
        self.assertEqual((rows, len(self.calls)), ([], 1))
        self.assertIn("expired", error)

    def test_nothing_worth_searching_for_asks_nothing(self):
        self.replies = []
        self.assertEqual(graph.graph_search("token", '  "  ', 50, "UTC"), ([], [], ""))


class SearchCommand(unittest.TestCase):
    """The command around it: where the query comes from, and what a full page means."""

    def test_the_query_comes_off_stdin_so_it_is_not_in_argv(self):
        args = graph.argparse.Namespace(account=["work"], query="", stdin=True,
                                        scope="all", limit=50, demo=True, folder=[])
        was = sys.stdin
        sys.stdin = io.StringIO(json.dumps({"query": "invoice"}) + "\n")
        try:
            with contextlib.redirect_stdout(io.StringIO()) as printed:
                graph.cmd_search(args)
        finally:
            sys.stdin = was
        answer = json.loads(printed.getvalue())
        self.assertEqual(answer["query"], "invoice")
        self.assertEqual([row["subject"] for row in answer["accounts"][0]["rows"]],
                         ["Invoice INV-2026-0418"])

    def test_nothing_to_search_for_is_refused_rather_than_answered_empty(self):
        args = graph.argparse.Namespace(account=["work"], query="   ", stdin=False,
                                        scope="all", limit=50, demo=True, folder=[])
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            with self.assertRaises(SystemExit):
                graph.cmd_search(args)
        self.assertEqual(json.loads(printed.getvalue())["error"]["code"], "no_query")

    def test_a_full_page_is_reported_as_maybe_having_more_behind_it(self):
        # Graph says nothing about what it left out, so a page that came back
        # full is the only signal there is. Claiming completeness from it would
        # be a claim this end cannot make.
        rows = [{"id": str(n), "received": "2026-08-0%dT09:00:00Z" % (n % 9 + 1)} for n in range(3)]
        original = (graph.read_json, graph.access_token, graph.graph_search)
        graph.read_json = lambda *a, **k: {"username": "you@example.com"}
        graph.access_token = lambda alias, account: ("token", account)
        graph.graph_search = lambda *a, **k: (rows, [], "")
        try:
            args = graph.argparse.Namespace(query="x", scope="all", limit=3, folder=[])
            self.assertFalse(graph.search_account("work", args, "UTC")["complete"])
            args.limit = 9
            self.assertTrue(graph.search_account("work", args, "UTC")["complete"])
        finally:
            (graph.read_json, graph.access_token, graph.graph_search) = original


class SearchingIMAP(unittest.TestCase):
    """The walk, and the criteria it walks with.

    IMAP has no search across folders, so "everywhere" is a SELECT and a SEARCH
    per folder. Two things are worth pinning down: that the walk is bounded and
    says when it stopped short, and that the query reaches the server as
    something the server will read - a term that is not ASCII has to travel as
    a literal, and imaplib carries exactly one of those per command.
    """

    TREE = [("INBOX", "/", []), ("Archive", "/", []), ("Sent Items", "/", [])]

    class Client:
        capabilities = ("IMAP4REV1",)

        def __init__(self, hits, unopenable=()):
            self.hits = hits
            self.unopenable = set(unopenable)
            self.selected = None
            self.searches = []
            self.literal = None
            self.untagged_responses = {"UIDVALIDITY": [b"42"]}

        def select(self, mailbox, readonly=True):
            import imaplib
            name = mailbox.strip('"')
            if name in self.unopenable:
                raise imaplib.IMAP4.error("no such mailbox")
            self.selected = name
            return "OK", [b"3"]

        def uid(self, command, *args):
            if command == "SEARCH":
                self.searches.append((self.selected, args, self.literal))
                self.literal = None
                return "OK", [" ".join(self.hits.get(self.selected, [])).encode()]
            # A real header block, so the row is shaped by the shipped code
            # rather than by a dict written here.
            note = imap_message(subject="Rechnung 2026", sender="Her <her@example.com>")
            return "OK", [(b'1 (UID 7 INTERNALDATE "01-Sep-2026 10:00:00 +0000" BODY[]<0>',
                           note.as_bytes()), b")"]

    def run_search(self, hits, query="rechnung", scope="all", unopenable=(), top=50):
        import imapmail
        client = self.Client(hits, unopenable)
        original = (imapmail.connect, imapmail.close, imapmail.list_folders)
        imapmail.connect = lambda *a, **k: client
        imapmail.close = lambda *a, **k: None
        imapmail.list_folders = lambda c: list(self.TREE)
        try:
            return client, imapmail.search({}, "token", query, "", scope, top)
        finally:
            (imapmail.connect, imapmail.close, imapmail.list_folders) = original

    def test_ascii_words_are_anded_as_separate_text_keys(self):
        client, _found = self.run_search({"INBOX": ["7"]}, "rechnung 2026")
        # Two TEXT keys side by side is IMAP's "both of these".
        self.assertEqual(client.searches[0][1], ("TEXT", '"rechnung"', "TEXT", '"2026"'))

    def test_a_term_that_is_not_ascii_travels_as_a_utf8_literal(self):
        client, _found = self.run_search({"INBOX": ["7"]}, "Rechnung über")
        mailbox, args, literal = client.searches[0]
        self.assertEqual(args, ("CHARSET", "UTF-8", "TEXT"))
        self.assertEqual(literal, "Rechnung über".encode("utf-8"))

    def test_the_inbox_is_searched_first(self):
        client, _found = self.run_search({"INBOX": ["7"], "Archive": ["7"]})
        self.assertEqual([call[0] for call in client.searches], ["INBOX", "Archive", "Sent Items"])

    def test_one_folder_when_that_is_the_scope(self):
        client, found = self.run_search({"INBOX": ["7"]}, scope="folder")
        self.assertEqual([call[0] for call in client.searches], ["INBOX"])
        self.assertTrue(found["complete"])

    def test_every_hit_says_which_folder_it_came_from(self):
        _client, found = self.run_search({"Archive": ["7"], "Sent Items": ["7"]})
        self.assertEqual(sorted(row["folderId"] for row in found["rows"]),
                         ["Archive", "Sent Items"])
        # Shaped by the shipped code, not by the test.
        self.assertEqual(found["rows"][0]["subject"], "Rechnung 2026")

    def test_a_folder_that_will_not_open_is_a_warning_not_a_failure(self):
        _client, found = self.run_search({"INBOX": ["7"], "Archive": ["7"]},
                                         unopenable=("Archive",))
        self.assertEqual([row["folderId"] for row in found["rows"]], ["INBOX"])
        self.assertFalse(found["complete"])
        self.assertIn("Archive", found["warnings"][0]["message"])

    def test_the_walk_stops_at_the_cap_and_says_so(self):
        import imapmail
        original = imapmail.SEARCH_FOLDER_CAP
        imapmail.SEARCH_FOLDER_CAP = 2
        try:
            client, found = self.run_search({"INBOX": ["7"]})
            self.assertEqual(len(client.searches), 2)
            self.assertFalse(found["complete"])
        finally:
            imapmail.SEARCH_FOLDER_CAP = original

    def test_nothing_to_search_for_opens_nothing(self):
        client, found = self.run_search({"INBOX": ["7"]}, query="   ")
        self.assertEqual((client.searches, found["rows"]), ([], []))

    def test_a_search_term_is_quoted_but_not_put_through_mutf7(self):
        import imapmail
        # `quoted` is for mailbox names and would turn this into "&APY-", which
        # is a folder-name encoding and matches nothing in a message.
        self.assertEqual(imapmail._search_string("über"), '"über"')
        self.assertEqual(imapmail._search_string('say "hi"'), '"say \\"hi\\""')


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


class SaslXoauth2(unittest.TestCase):
    """The credentials string, in the type the library asking for it wants.

    imaplib base64s what the callable returns and so needs bytes; smtplib
    calls .encode("ascii") on it and so needs str. One helper served both
    with bytes, so every send over SMTP died on an AttributeError inside
    smtplib - before any of compose()'s own except clauses could turn it
    into something the window could report.
    """

    def setUp(self):
        import imapmail
        self.imapmail = imapmail

    def test_imaplib_gets_bytes_it_can_base64(self):
        authobject = self.imapmail._sasl_xoauth2("me@example.com", "tok")
        credentials = authobject(b"")
        # What imaplib.authenticate does with the return value.
        self.assertEqual(base64.b64decode(base64.b64encode(credentials)), credentials)
        self.assertEqual(credentials, b"user=me@example.com\x01auth=Bearer tok\x01\x01")

    def test_smtplib_gets_a_string_it_can_encode(self):
        authobject = self.imapmail._sasl_xoauth2("me@example.com", "tok", binary=False)
        credentials = authobject()
        # What smtplib.auth does with the return value, and what used to raise.
        self.assertEqual(credentials.encode("ascii").decode("ascii"), credentials)
        self.assertEqual(credentials, "user=me@example.com\x01auth=Bearer tok\x01\x01")

    def test_the_second_challenge_is_answered_with_nothing_of_the_same_type(self):
        """A rejected exchange wants an empty line, not the credentials again -
        and smtplib would encode() that empty answer too."""
        binary = self.imapmail._sasl_xoauth2("me@example.com", "tok")
        binary(b"")
        self.assertEqual(binary(b'{"status":"401"}'), b"")

        text = self.imapmail._sasl_xoauth2("me@example.com", "tok", binary=False)
        text()
        self.assertEqual(text(b'{"status":"401"}'), "")

    def test_binary_is_the_default_because_imaplib_is_the_older_caller(self):
        self.assertIsInstance(
            self.imapmail._sasl_xoauth2("me@example.com", "tok")(), bytes)


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
        source = imap_message(body="the original", cc="")

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

        original = (imapmail.fetch_parsed, imapmail.smtplib.SMTP, imapmail.connect)
        imapmail.fetch_parsed = imap_fetch(source)
        imapmail.smtplib.SMTP = FakeSMTP
        # Filing a copy in Sent Items is best effort; refusing the connection
        # here exercises the warning rather than the failure.
        imapmail.connect = lambda *a, **k: (_ for _ in ()).throw(OSError("no imap"))
        try:
            result = imapmail.compose({"username": "me@example.com"}, "token", "1",
                                      "reply", "here you go", [], False, attachments)
        finally:
            imapmail.fetch_parsed, imapmail.smtplib.SMTP, imapmail.connect = original
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


class ImapNewMessage(unittest.TestCase):
    """A message written from nothing, over SMTP.

    Everything Graph would assemble - the subject, the recipients, the
    headers - is assembled here, and for a new message that means leaving out
    the two things a reply is defined by: the quoted original and the
    In-Reply-To that files it under a conversation.
    """

    def build(self, draft=False, **kwargs):
        import imapmail
        sent = {}
        asked = []

        def fake_fetch(account, token, message_id, cap=None):
            asked.append(message_id)
            return imap_message(), IMAP_PREFIX, False

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

        original = (imapmail.fetch_parsed, imapmail.smtplib.SMTP, imapmail.connect)
        imapmail.fetch_parsed = fake_fetch
        imapmail.smtplib.SMTP = FakeSMTP
        # Filing the Sent copy is best effort; refusing the connection here
        # exercises the warning rather than the failure.
        imapmail.connect = lambda *a, **k: (_ for _ in ()).throw(OSError("no imap"))
        try:
            result = imapmail.compose(
                {"username": "me@example.com"}, "token", "", "new",
                kwargs.pop("comment", "here it is"), kwargs.pop("to", ["her@example.com"]),
                draft, None,
                kwargs.pop("subject_line", "Rechnung"), kwargs.pop("cc", None))
        finally:
            imapmail.fetch_parsed, imapmail.smtplib.SMTP, imapmail.connect = original
        return result, sent.get("note"), asked

    def test_nothing_is_fetched_because_there_is_no_original(self):
        _result, _note, asked = self.build()
        self.assertEqual(asked, [])

    def test_the_subject_is_the_one_that_was_typed_with_no_prefix_on_it(self):
        _result, note, _asked = self.build()
        self.assertEqual(note["Subject"], "Rechnung")

    def test_it_starts_a_conversation_rather_than_joining_one(self):
        _result, note, _asked = self.build()
        self.assertIsNone(note["In-Reply-To"])
        self.assertIsNone(note["References"])

    def test_the_body_is_what_was_written_and_nothing_is_quoted_under_it(self):
        _result, note, _asked = self.build(comment="Anbei die Rechnung.")
        self.assertEqual(note.get_body(("plain",)).get_content().strip(),
                         "Anbei die Rechnung.")

    def test_copies_become_a_cc_header_and_are_absent_when_there_are_none(self):
        _result, note, _asked = self.build(cc=["him@example.com"])
        self.assertEqual(note["Cc"], "him@example.com")
        _result, bare, _asked = self.build()
        self.assertIsNone(bare["Cc"])

    def test_nobody_to_send_it_to_is_refused(self):
        import imapmail
        with self.assertRaises(imapmail.TransportError) as caught:
            self.build(to=[])
        self.assertEqual(caught.exception.code, "no_recipient")

    def test_the_answer_carries_no_message_id_because_there_was_none(self):
        result, _note, _asked = self.build()
        self.assertTrue(result["ok"])
        self.assertEqual(result["id"], "")


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


class NewMessage(unittest.TestCase):
    """A message that answers nothing.

    The plugin could only ever reply, reply to everyone or forward: writing a
    fresh mail meant leaving for Outlook. It has no original to hang off, so
    there is no createReply to ask for one - the whole message is assembled
    here and handed over in one request.
    """

    def run_compose(self, scopes="Mail.ReadWrite Mail.Send", write=True, responses=None,
                    attach=None, **overrides):
        self.calls = []
        queue = list(responses or [(202, {})])

        def http(url, method="GET", data=None, json_body=None, headers=None, timeout=20):
            self.calls.append({"url": url, "method": method, "body": json_body})
            return queue.pop(0) if queue else (202, {})

        args = ComposeArgs()
        args.mode = "new"
        args.id = ""
        args.to = "her@example.com"
        args.subject = "Rechnung"
        args.cc = ""
        args.attach = attach or []
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

    def test_it_goes_out_in_one_request_carrying_the_whole_message(self):
        result = self.run_compose()
        self.assertTrue(result["ok"])
        self.assertFalse(result["drafted"])
        self.assertEqual(len(self.calls), 1)
        self.assertTrue(self.calls[0]["url"].endswith("/me/sendMail"))
        body = self.calls[0]["body"]
        self.assertTrue(body["saveToSentItems"])
        self.assertEqual(body["message"]["subject"], "Rechnung")
        self.assertEqual(body["message"]["toRecipients"],
                         [{"emailAddress": {"address": "her@example.com"}}])

    def test_the_body_is_text_because_that_is_what_was_typed(self):
        # contentType HTML would take somebody's angle brackets for markup.
        self.run_compose(comment="1 < 2 & you know it")
        body = self.calls[0]["body"]["message"]["body"]
        self.assertEqual(body["contentType"], "Text")
        self.assertEqual(body["content"], "1 < 2 & you know it")

    def test_copies_go_as_ccRecipients_and_are_left_out_when_there_are_none(self):
        self.run_compose(cc="him@example.com; them@example.org")
        self.assertEqual(
            self.calls[0]["body"]["message"]["ccRecipients"],
            [{"emailAddress": {"address": "him@example.com"}},
             {"emailAddress": {"address": "them@example.org"}}])
        self.run_compose()
        self.assertNotIn("ccRecipients", self.calls[0]["body"]["message"])

    def test_a_copy_that_is_not_an_address_is_refused_before_sending(self):
        result = self.run_compose(cc="notanaddress")
        self.assertEqual(result["error"]["code"], "bad_recipient")
        self.assertIn("notanaddress", result["error"]["message"])
        self.assertEqual(self.calls, [])

    def test_nobody_to_send_it_to_is_refused_before_the_network(self):
        result = self.run_compose(to="")
        self.assertEqual(result["error"]["code"], "no_recipient")
        self.assertEqual(self.calls, [])

    def test_an_attachment_rides_inside_it_rather_than_through_a_draft(self):
        # /sendMail takes the whole message, so the draft-attach-send dance a
        # reply needs is not needed here.
        directory = tempfile.mkdtemp()
        path = os.path.join(directory, "quote.pdf")
        with open(path, "wb") as handle:
            handle.write(b"%PDF-1.4")
        result = self.run_compose(attach=[path])
        self.assertEqual(result["attached"], ["quote.pdf"])
        self.assertEqual(len(self.calls), 1)
        files = self.calls[0]["body"]["message"]["attachments"]
        self.assertEqual(files[0]["@odata.type"], "#microsoft.graph.fileAttachment")
        self.assertEqual(base64.b64decode(files[0]["contentBytes"]), b"%PDF-1.4")

    def test_a_draft_is_a_post_to_the_collection_and_needs_no_send_permission(self):
        result = self.run_compose(
            scopes="Mail.ReadWrite", draft=True,
            responses=[(201, {"id": "D9", "webLink": "https://outlook/d9"})])
        self.assertTrue(result["drafted"])
        self.assertEqual(result["webLink"], "https://outlook/d9")
        self.assertEqual(self.calls[0]["method"], "POST")
        self.assertTrue(self.calls[0]["url"].endswith("/me/messages"))

    def test_a_mailbox_without_send_is_told_before_the_request(self):
        result = self.run_compose(scopes="Mail.ReadWrite")
        self.assertEqual(result["error"]["code"], "send_permission_required")
        self.assertEqual(self.calls, [])

    def test_an_answer_with_no_message_to_answer_is_refused(self):
        # The other way round: --mode reply without --id used to build a URL
        # with an empty id in it and let Outlook explain.
        result = self.run_compose(mode="reply", id="")
        self.assertEqual(result["error"]["code"], "no_id")
        self.assertEqual(self.calls, [])


class ComposeStopsWhenItIsDone(unittest.TestCase):
    """out() does not exit in this helper, and cmd_compose forgot to return.

    Both were real: --draft printed the draft and then went on to send the
    message, and a reply carrying a file was sent twice - once as the addressed
    draft and again through /reply without the attachment. The stub that raises
    on out() hid it from every other test here, so these let out() do what it
    really does and count the requests.
    """

    def run_compose(self, responses, **overrides):
        self.calls = []
        self.printed = []
        queue = list(responses)

        def http(url, method="GET", data=None, json_body=None, headers=None, timeout=20):
            self.calls.append({"url": url, "method": method, "body": json_body})
            return queue.pop(0) if queue else (202, {})

        args = ComposeArgs()
        args.attach = []
        for key, value in overrides.items():
            setattr(args, key, value)

        patched = {
            "read_json": lambda *a, **k: {"write": True,
                                          "scopes": "Mail.ReadWrite Mail.Send"},
            "access_token": lambda alias, account: ("token", account),
            "http": http,
            "out": self.printed.append,
        }
        original = {name: getattr(graph, name) for name in patched}
        for name, stub in patched.items():
            setattr(graph, name, stub)
        try:
            graph.cmd_compose(args)
        finally:
            for name, value in original.items():
                setattr(graph, name, value)

    def test_saving_a_draft_does_not_also_send_it(self):
        self.run_compose([(201, {"id": "D1", "webLink": "https://outlook/d1"})], draft=True)
        self.assertEqual(len(self.printed), 1)
        self.assertTrue(self.printed[0]["drafted"])
        self.assertEqual([call["url"].rsplit("/", 1)[-1] for call in self.calls],
                         ["createReply"])

    def test_a_reply_with_a_file_is_sent_once(self):
        directory = tempfile.mkdtemp()
        path = os.path.join(directory, "quote.pdf")
        with open(path, "wb") as handle:
            handle.write(b"%PDF-1.4")
        self.run_compose([(201, {"id": "D1"}), (201, {}), (202, {})], attach=[path])
        self.assertEqual(len(self.printed), 1)
        self.assertEqual([call["url"].rsplit("/", 1)[-1] for call in self.calls],
                         ["createReply", "attachments", "send"])
        self.assertFalse(any(call["url"].endswith("/reply") for call in self.calls))


class RecipientsWithNames(unittest.TestCase):
    """The bug that made forwarding not work.

    recipient_list used to split the whole field on whitespace as well as on
    commas, so "Jan Renz <jan@example.com>" arrived as three entries, two of
    them without an @ - and the answer was `bad_recipient: Not an email
    address: Jan, Renz`. A name comes with the address nearly every time it is
    copied from anywhere, so forwarding to anybody whose address had not been
    typed out by hand simply failed.
    """

    def addresses(self, value):
        good, bad = graph.recipient_list(value)
        return [entry["emailAddress"] for entry in good], bad

    def test_a_name_and_address_is_one_recipient_with_its_name_kept(self):
        good, bad = self.addresses("Jan Renz <jan@example.com>")
        self.assertEqual(bad, [])
        self.assertEqual(good, [{"address": "jan@example.com", "name": "Jan Renz"}])

    def test_a_bare_address_still_works_and_carries_no_name(self):
        good, bad = self.addresses("jan@example.com")
        self.assertEqual((good, bad), ([{"address": "jan@example.com"}], []))

    def test_a_comma_inside_a_quoted_name_does_not_split_it_in_two(self):
        good, bad = self.addresses('"Renz, Jan" <jan@example.com>')
        self.assertEqual(bad, [])
        self.assertEqual(good, [{"address": "jan@example.com", "name": "Renz, Jan"}])

    def test_outlooks_semicolons_and_everybody_elses_commas_both_work(self):
        good, _bad = self.addresses("a@b.com; Someone Else <c@d.org>, e@f.net")
        self.assertEqual([entry["address"] for entry in good],
                         ["a@b.com", "c@d.org", "e@f.net"])

    def test_a_separator_inside_angle_brackets_does_not_split_the_entry(self):
        # The scan is what must hold this together. Whether an unquoted
        # semicolon in a local part is then a routable address is a different
        # question, and refusing it is right.
        self.assertEqual(graph.split_address_list("<a;b@example.com>, k@example.org"),
                         ["<a;b@example.com>", "k@example.org"])
        self.assertEqual(graph.split_address_list('"Renz, Jan" <j@x.de>, k@example.org'),
                         ['"Renz, Jan" <j@x.de>', "k@example.org"])

    def test_something_that_is_not_an_address_is_still_refused(self):
        good, bad = self.addresses("a@b.com, notanaddress")
        self.assertEqual([entry["address"] for entry in good], ["a@b.com"])
        self.assertEqual(bad, ["notanaddress"])

    def test_what_was_refused_is_named_as_it_was_typed_not_as_fragments(self):
        # "Not an email address: Jan, Renz" told nobody what to fix.
        _good, bad = self.addresses("Jan Renz <not an address>")
        self.assertEqual(bad, ["Jan Renz <not an address>"])

    def test_the_imap_path_gets_a_header_it_can_use_verbatim(self):
        good, _bad = graph.recipient_list('"Renz, Jan" <jan@example.com>, k@example.org')
        self.assertEqual([graph.address_header(entry) for entry in good],
                         ['"Renz, Jan" <jan@example.com>', "k@example.org"])

    def test_a_forward_reaches_the_endpoint_with_the_name_on_it(self):
        args = ComposeArgs()
        args.mode = "forward"
        args.to = "Jan Renz <jan@example.com>"
        args.attach = []
        calls = []

        def http(url, method="GET", data=None, json_body=None, headers=None, timeout=20):
            calls.append({"url": url, "body": json_body})
            return (202, {})

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
            result = emitted.payload
        finally:
            for name, value in original.items():
                setattr(graph, name, value)
        self.assertTrue(result["ok"])
        self.assertTrue(calls[0]["url"].endswith("/forward"))
        self.assertEqual(calls[0]["body"]["toRecipients"],
                         [{"emailAddress": {"address": "jan@example.com", "name": "Jan Renz"}}])


class ImapForward(unittest.TestCase):
    """A forward is not a reply to the message it forwards.

    It goes to somebody who was never in the conversation, so it carries the
    original's headers where a reply carries a quote - and it must not carry
    In-Reply-To, which filed the forward under the original in the recipient's
    client as though they had been copied on it all along.
    """

    def build(self, mode="forward", to=None, attachments=(), cut=False, own=None,
              references=""):
        import imapmail
        sent = {}
        source = imap_message(attachments=attachments, references=references)

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

        saved = (imapmail.fetch_parsed, imapmail.smtplib.SMTP, imapmail.connect)
        imapmail.fetch_parsed = imap_fetch(source, cut=cut)
        imapmail.smtplib.SMTP = FakeSMTP
        imapmail.connect = lambda *a, **k: (_ for _ in ()).throw(OSError("no imap"))
        try:
            self.result = imapmail.compose(
                {"username": "me@example.com"}, "token", "1", mode,
                "FYI", to if to is not None else ["third@example.org"],
                False, own, "", None)
        finally:
            imapmail.fetch_parsed, imapmail.smtplib.SMTP, imapmail.connect = saved
        return sent["note"]

    def body_of(self, note):
        return note.get_body(("plain",)).get_content()

    def test_a_forward_is_not_threaded_into_the_conversation_it_came_from(self):
        note = self.build()
        self.assertIsNone(note["In-Reply-To"])
        self.assertIsNone(note["References"])

    def test_a_reply_still_is(self):
        note = self.build(mode="reply", to=[])
        self.assertEqual(note["In-Reply-To"], "<abc@example.com>")

    def test_it_carries_the_originals_headers_because_nobody_has_seen_them(self):
        body = self.body_of(self.build())
        self.assertIn("---------- Forwarded message ----------", body)
        self.assertIn("From: Her Name <her@example.com>", body)
        self.assertIn("Subject: Rechnung", body)
        self.assertIn("To: Me <me@example.com>", body)
        self.assertIn('Cc: "Renz, Jan" <jan@x.de>', body)

    def test_the_forwarded_body_is_passed_on_rather_than_quoted(self):
        body = self.body_of(self.build())
        self.assertIn("\nthe original body", body)
        self.assertNotIn("> the original body", body)

    def test_a_name_and_address_typed_into_To_survives_into_the_header(self):
        note = self.build(to=['"Renz, Jan" <third@example.org>'])
        self.assertEqual(note["To"], '"Renz, Jan" <third@example.org>')

    def test_the_quote_line_is_a_date_a_person_can_read(self):
        # It used to be "On 2026-09-01T10:00:00+00:00, Her Name wrote:".
        body = self.body_of(self.build(mode="reply", to=[]))
        self.assertNotIn("2026-09-01T10:00:00", body)
        self.assertIn("Sep 2026", body)

    def test_a_reply_is_threaded_by_the_id_on_the_message_itself(self):
        # The id used to be read off a key `message()` did not return, so this
        # went out empty and the reply landed beside the conversation. The list
        # row has one, but a message opened from a notification never went
        # through a list.
        note = self.build(mode="reply", to=[])
        self.assertEqual(note["In-Reply-To"], "<abc@example.com>")

    def test_the_reference_chain_is_the_originals_plus_the_original(self):
        note = self.build(mode="reply", to=[], references="<one@x.de> <two@x.de>")
        self.assertEqual(note["References"],
                         "<one@x.de> <two@x.de> <abc@example.com>")


class ImapForwardCarriesItsAttachments(unittest.TestCase):
    """The files the original was carrying go with the forward.

    Graph's forward is built by Outlook out of attachments already in the
    mailbox, so that path has always carried them. Here the message is
    assembled locally, and it was assembled out of the original's text alone:
    the files were dropped, nothing said so, and the forward looked complete in
    Sent Items. That is the bug these cover.
    """

    PDF = ("quote.pdf", b"%PDF-1.4 the invoice", "application/pdf")

    def build(self, mode="forward", attachments=(PDF,), own=None, cut=False,
              cap=None):
        import imapmail
        sent = {}
        source = imap_message(attachments=attachments)

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

        saved = (imapmail.fetch_parsed, imapmail.smtplib.SMTP, imapmail.connect,
                 imapmail.FORWARD_TOTAL_CAP)
        imapmail.fetch_parsed = imap_fetch(source, cut=cut)
        imapmail.smtplib.SMTP = FakeSMTP
        imapmail.connect = lambda *a, **k: (_ for _ in ()).throw(OSError("no imap"))
        if cap is not None:
            imapmail.FORWARD_TOTAL_CAP = cap
        try:
            result = imapmail.compose({"username": "me@example.com"}, "token", "1",
                                      mode, "FYI", ["third@example.org"], False, own)
        finally:
            (imapmail.fetch_parsed, imapmail.smtplib.SMTP, imapmail.connect,
             imapmail.FORWARD_TOTAL_CAP) = saved
        return result, sent.get("note")

    def files(self, note):
        return [(part.get_filename(), part.get_payload(decode=True))
                for part in note.walk() if part.get_filename()]

    def test_the_forward_carries_the_originals_file(self):
        _result, note = self.build()
        self.assertEqual(self.files(note), [("quote.pdf", b"%PDF-1.4 the invoice")])

    def test_the_type_survives_rather_than_becoming_octet_stream(self):
        _result, note = self.build()
        part = [p for p in note.walk() if p.get_filename() == "quote.pdf"][0]
        self.assertEqual(part.get_content_type(), "application/pdf")

    def test_the_result_names_what_rode_along(self):
        result, _note = self.build()
        self.assertEqual(result["carried"], ["quote.pdf"])

    def test_a_reply_does_not_carry_them(self):
        # A reply goes back to somebody who already has the file.
        result, note = self.build(mode="reply")
        self.assertEqual(self.files(note), [])
        self.assertEqual(result["carried"], [])

    def test_a_file_of_your_own_comes_before_the_ones_being_forwarded(self):
        _result, note = self.build(own=[("cover.txt", b"see attached")])
        self.assertEqual([name for name, _body in self.files(note)],
                         ["cover.txt", "quote.pdf"])

    def test_the_body_is_still_the_forwarded_message(self):
        _result, note = self.build()
        body = note.get_body(("plain",)).get_content()
        self.assertIn("FYI", body)
        self.assertIn("---------- Forwarded message ----------", body)
        self.assertIn("the original body", body)

    def test_a_signature_logo_is_not_forwarded_as_a_document(self):
        # The awkward real case: `Content-Disposition: attachment` on a part
        # the body points at with `cid:`. Plenty of senders do exactly that,
        # so the Content-ID has to be tested first or every forward carries
        # somebody's logo as though it were a file.
        import imapmail
        note = EmailMessage(policy=email.policy.SMTP)
        note["From"] = "her@example.com"
        note.set_content("hello")
        note.add_attachment(b"\x89PNG", maintype="image", subtype="png",
                            filename="logo.png")
        for part in note.walk():
            if part.get_filename() == "logo.png":
                part["Content-ID"] = "<logo@x.de>"
        parsed = imapmail.parse_headers(note.as_bytes())
        self.assertEqual(parsed.get_payload()[1].get_content_disposition(), "attachment")
        self.assertEqual(imapmail.attached_files(parsed), [])
        # And a message with nothing attached has nothing to carry.
        self.assertEqual(imapmail.attached_files(imap_message()), [])

    def test_a_part_named_only_on_its_content_type_still_counts(self):
        # Senders leave Content-Disposition off and name the file on the type.
        # Trusting the disposition alone loses real documents.
        import imapmail
        note = EmailMessage(policy=email.policy.SMTP)
        note["From"] = "her@example.com"
        note.set_content("see attached")
        note.add_attachment(b"data", maintype="application", subtype="pdf",
                            filename="named.pdf")
        for part in note.walk():
            if part.get_filename() == "named.pdf":
                del part["Content-Disposition"]
                part.set_param("name", "named.pdf")
        files = imapmail.attached_files(imapmail.parse_headers(note.as_bytes()))
        self.assertEqual([name for name, _body, _type in files], ["named.pdf"])

    def test_a_message_the_read_cap_cut_is_refused_rather_than_sent_short(self):
        import imapmail
        with self.assertRaises(imapmail.TransportError) as caught:
            self.build(cut=True)
        self.assertEqual(caught.exception.code, "forward_too_large")

    def test_a_forward_the_server_would_refuse_is_refused_here_by_weight(self):
        import imapmail
        with self.assertRaises(imapmail.TransportError) as caught:
            self.build(cap=8)
        self.assertEqual(caught.exception.code, "attachment_too_large")


class UnifiedFolderOverImap(unittest.TestCase):
    """Asking every mailbox for the same folder at once.

    No folder id means the same folder in two mailboxes, let alone across the
    two transports - so what travels is the well-known name. Graph already takes
    those in a folder path; over IMAP they have to be matched against names that
    arrive in the mailbox's own language, which `move` already did and a fetch
    did not, so the merged Archive would have shown the inbox.
    """

    FOLDERS = [{"id": "INBOX", "name": "Inbox", "isInbox": True},
               {"id": "Archiv", "name": "Archiv", "isInbox": False},
               {"id": "Gesendete Elemente", "name": "Gesendete Elemente", "isInbox": False}]

    def open(self, folder_id, folders=None, names=None):
        import imapmail
        listed = names if names is not None else [row["name"] for row in self.FOLDERS]
        saved = imapmail.list_folders
        imapmail.list_folders = lambda client: [(name, "/", ()) for name in listed]
        warnings = []
        try:
            chosen = imapmail.folder_to_open(
                None, {}, self.FOLDERS if folders is None else folders, folder_id, warnings)
        finally:
            imapmail.list_folders = saved
        return chosen, warnings

    def test_nothing_and_inbox_both_mean_the_inbox(self):
        self.assertEqual(self.open("")[0], "INBOX")
        self.assertEqual(self.open("inbox")[0], "INBOX")

    def test_a_path_this_mailbox_lists_is_that_folder(self):
        chosen, warnings = self.open("Archiv")
        self.assertEqual((chosen, warnings), ("Archiv", []))

    def test_a_well_known_name_resolves_to_the_localized_folder(self):
        # The whole point: the window says "archive" to every mailbox, and this
        # one calls it Archiv.
        chosen, warnings = self.open("archive")
        self.assertEqual((chosen, warnings), ("Archiv", []))
        chosen, _warnings = self.open("sentitems")
        self.assertEqual(chosen, "Gesendete Elemente")

    def test_a_path_wins_over_a_well_known_name_of_its_own(self):
        # A mailbox that really has a folder called "archive" means that one.
        folders = [{"id": "INBOX", "name": "Inbox", "isInbox": True},
                   {"id": "archive", "name": "archive", "isInbox": False}]
        chosen, warnings = self.open("archive", folders=folders)
        self.assertEqual((chosen, warnings), ("archive", []))

    def test_a_mailbox_whose_archive_is_named_something_unknown_says_so(self):
        chosen, warnings = self.open("archive", names=["Inbox", "Ablage 2024"])
        self.assertEqual(chosen, "INBOX")
        self.assertEqual(len(warnings), 1)
        self.assertIn("imapFolders.archive", warnings[0]["message"])

    def test_a_folder_that_is_simply_gone_still_says_that(self):
        chosen, warnings = self.open("Projekte")
        self.assertEqual(chosen, "INBOX")
        self.assertEqual(warnings[0]["message"], "That folder is gone - showing the inbox")


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


class RespondPermission(unittest.TestCase):
    """Whether a mailbox may answer a meeting.

    Its own grant, and not the one that deletes mail: accept, tentative and
    decline are writes to the event, so a token carrying Calendars.Read gets
    ErrorAccessDenied from all three.
    """

    def test_reading_the_calendar_is_not_answering_it(self):
        self.assertFalse(graph.can_respond(
            {"scopes": "openid Mail.ReadWrite Mail.Send Calendars.Read"}))
        self.assertTrue(graph.can_respond(
            {"scopes": "openid Mail.ReadWrite Mail.Send Calendars.ReadWrite"}))

    def test_write_access_to_mail_says_nothing_about_it(self):
        self.assertFalse(graph.can_respond({"write": True, "scopes": "Mail.ReadWrite"}))

    def test_a_mailbox_from_before_scopes_were_recorded_may_not_answer(self):
        self.assertFalse(graph.can_respond({}))
        self.assertFalse(graph.can_respond(None))

    def test_over_imap_a_calendar_signed_in_at_all_may_answer(self):
        # EWS has one scope and it is the whole mailbox, so there is no
        # read-only calendar to tell apart here.
        self.assertFalse(graph.can_respond({"transport": "imap"}))
        self.assertTrue(graph.can_respond(
            {"transport": "imap", "calendar": {"refresh_token": "x"}}))


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


class MeetingBody(unittest.TestCase):
    """A meeting's body, whatever the transport claims it handed over."""

    def test_exchange_markup_is_converted_even_though_it_says_text(self):
        """A GetItem asking for BodyType Text still comes back with tags in it,
        which is what put a stylesheet in the pane. What comes out is markup
        again - the "linked" format - but markup this plugin wrote."""
        body, _, body_format = graph.event_body(
            '<div style="color:red">Hallo zusammen,</div><br>\n'
            'der Link: <a href="https://example.com/j">Teilnehmen</a>')
        self.assertEqual(body_format, "linked")
        # Nothing of the sender's own markup survives as markup.
        self.assertNotIn("style=", body)
        self.assertNotIn("<div", body)
        # The join link does survive, as an anchor written here.
        self.assertIn('href="https://example.com/j"', body)
        self.assertIn("Hallo zusammen", body)

    def test_text_that_merely_contains_an_angle_bracket_is_left_alone(self):
        body, _, _ = graph.event_body("if a < b then nothing happens")
        self.assertIn("a &lt; b", body)

    def test_an_empty_body_is_not_a_failure(self):
        self.assertEqual(graph.event_body(None)[0], "")

    def test_markup_is_recognised_by_a_tag_and_not_by_a_bracket(self):
        self.assertTrue(graph.looks_like_markup("one<br>two"))
        self.assertTrue(graph.looks_like_markup("<DIV>shouting</DIV>"))
        self.assertFalse(graph.looks_like_markup("2 < 3 and 4 > 1"))
        self.assertFalse(graph.looks_like_markup(""))


class MeetingAnswers(unittest.TestCase):
    """The three answers, and what each transport calls them."""

    def test_only_the_three_are_accepted(self):
        for reply in ("accept", "tentative", "decline"):
            self.assertIn(reply, graph.EVENT_REPLIES)
        self.assertNotIn("maybe", graph.EVENT_REPLIES)

    def test_graph_verbs_are_the_ones_the_api_documents(self):
        self.assertEqual(graph.EVENT_REPLIES["tentative"], "tentativelyAccept")

    def test_ews_maps_its_own_words_onto_graph_s(self):
        import ewscal
        self.assertEqual(ewscal.RESPONSES["accept"], "accepted")
        self.assertEqual(ewscal.RESPONSES["tentative"], "tentativelyAccepted")
        self.assertEqual(ewscal.RESPONSES["noresponsereceived"], "notResponded")
        # Not an answer at all: it is Exchange saying the meeting is yours.
        self.assertEqual(ewscal.RESPONSES["organizer"], "organizer")

    def test_ews_answers_by_creating_the_response_item(self):
        """Exchange has no respond verb - the answer is an item, and sending it
        is what puts it on the organiser's tally."""
        import ewscal
        self.assertEqual(ewscal.REPLY_ITEMS["accept"], "AcceptItem")
        self.assertEqual(ewscal.REPLY_ITEMS["tentative"], "TentativelyAcceptItem")
        self.assertEqual(ewscal.REPLY_ITEMS["decline"], "DeclineItem")

    def test_a_reply_that_is_not_one_is_refused_before_anything_is_sent(self):
        import ewscal

        def explode(*a, **k):
            raise AssertionError("reached the network")

        original = ewscal._post
        ewscal._post = explode
        try:
            with self.assertRaises(ewscal.CalendarError):
                ewscal.respond("token", "id", "maybe")
        finally:
            ewscal._post = original


class MeetingPeople(unittest.TestCase):
    """Who was invited, and what they said, out of Graph's own shape."""

    def test_a_name_and_a_response_come_through(self):
        people = graph.event_people([
            {"emailAddress": {"name": "Ada", "address": "ada@example.com"},
             "status": {"response": "accepted"}},
        ])
        self.assertEqual(people, [{"name": "Ada", "address": "ada@example.com",
                                   "response": "accepted"}])

    def test_an_attendee_with_only_an_address_is_named_by_it(self):
        people = graph.event_people([{"emailAddress": {"address": "x@example.com"}}])
        self.assertEqual(people[0]["name"], "x@example.com")
        self.assertEqual(people[0]["response"], "none")

    def test_an_empty_entry_is_dropped_rather_than_drawn_as_a_blank_row(self):
        self.assertEqual(graph.event_people([{}, None]), [])


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

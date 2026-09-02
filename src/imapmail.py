#!/usr/bin/env python3
"""IMAP and SMTP transport, for mailboxes whose tenant will not consent to Graph.

Some tenants allow users to consent only to "low impact" delegated
permissions - User.Read, openid, profile, email, offline_access. Mail.Read is
not one of them, so on those tenants the Graph path in graph.py stops at an
admin-approval wall that the user cannot clear themselves. Where the same
tenant has already granted a desktop mail client access to IMAP, this module
reads the mailbox over IMAP instead, with the same OAuth device-code sign-in.

Two things about that are worth stating plainly rather than leaving in the
git log:

  * The client id used for an IMAP sign-in defaults to Mozilla Thunderbird's
    (see IMAP_CLIENT_ID in graph.py). The tenant sees Thunderbird where this
    widget is what actually connects. Set "clientId" per mailbox to use a
    registration of your own where that matters.
  * IMAP has no read-only scope. IMAP.AccessAsUser.All is full mailbox
    access, so a mailbox added for reading holds permission to change and
    delete mail even though nothing here will. On the Graph path, "signed in
    for reading" is enforced by the token; here it is only enforced by this
    code, and account["write"] is a local policy rather than a boundary.

Stdlib only, like the rest of the plugin: imaplib, smtplib and email are all
that this needs.

The module speaks in the same shapes graph.py already builds for the QML side,
so the panel cannot tell which transport answered - except where a protocol
genuinely cannot answer, which is reported as a capability rather than faked:
IMAP has no calendar, and Outlook's Focused/Other split lives in Graph alone.
"""

import base64
import email.policy
import email.utils
import imaplib
import mimetypes
import re
import smtplib
import time
from datetime import datetime, timezone
from email.message import EmailMessage

DEFAULT_IMAP_HOST = "outlook.office365.com"
DEFAULT_SMTP_HOST = "smtp.office365.com"
DEFAULT_SMTP_PORT = 587
TIMEOUT = 30

# A preview is two lines in a list; a couple of kilobytes of the body is more
# than enough to find them, and asking for the whole body of every message in
# the list would turn one fetch into a download.
PREVIEW_BYTES = 3072
PREVIEW_CHARS = 200
# A reading pane cannot show a novel, and some mail carries megabytes of
# attachment that BODY[] would drag over the wire before anything is drawn.
MAX_MESSAGE_BYTES = 2 * 1024 * 1024

FOLDER_CAP = 200
FOLDER_MAX_DEPTH = 3
# One STATUS per folder is one round trip per folder. A mailbox with a hundred
# of them would spend the whole refresh interval counting, so the counts stop
# after this many and the rest list without them.
FOLDER_COUNT_CAP = 60

# Headers worth having for a list row. Content-Type and
# Content-Transfer-Encoding are not for display: they are what makes the
# separately fetched body text parseable as MIME (see preview_text).
HEADER_FIELDS = ("SUBJECT FROM DATE TO CC MESSAGE-ID REFERENCES IN-REPLY-TO "
                 "CONTENT-TYPE CONTENT-TRANSFER-ENCODING MIME-VERSION X-PRIORITY "
                 "IMPORTANCE")
LIST_ITEMS = "(UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (%s)])" % HEADER_FIELDS
PREVIEW_ITEMS = "(UID BODY.PEEK[TEXT]<0.%d>)" % PREVIEW_BYTES

# A Message-ID as RFC 5322 writes one. Deliberately loose about what may sit
# inside the angle brackets - real mailers put spaces, slashes and unicode in
# there - and strict only about the brackets, which is what separates one id
# from the next in a folded References header.
MESSAGE_ID = re.compile(r"<[^<>]+>")

POLICY = email.policy.default

# Exchange advertises neither SPECIAL-USE nor XLIST, so there is no flag on a
# LIST reply saying which folder is the trash - and the names arrive in the
# mailbox's own language. Matching by name is what is left. A mailbox whose
# names are none of these says so and asks for the folder to be set, rather
# than moving mail somewhere unintended.
SPECIAL_FOLDERS = {
    "trash": ("Deleted Items", "Gelöschte Elemente", "Gelöschte Objekte", "Trash", "Papierkorb",
              "Éléments supprimés", "Elementos eliminados", "Verwijderde items", "Cestino",
              "Usunięte", "Kosz", "Slettede elementer", "Borttagna objekt", "Poistetut"),
    "archive": ("Archive", "Archiv", "Archief", "Arkiv", "Arkisto", "Archivio", "Archivo",
                "Archives", "Archiwum"),
    "junk": ("Junk Email", "Junk-E-Mail", "Junk", "Spam", "Ongewenste e-mail", "Courrier indésirable",
             "Correo no deseado", "Posta indesiderata", "Wiadomości-śmieci", "Skräppost", "Roskaposti"),
    "drafts": ("Drafts", "Entwürfe", "Concepten", "Brouillons", "Borradores", "Bozze", "Kladder",
               "Utkast", "Luonnokset", "Wersje robocze", "Kladde"),
    "sent": ("Sent Items", "Gesendete Elemente", "Gesendete Objekte", "Sent", "Verzonden items",
             "Éléments envoyés", "Elementos enviados", "Posta inviata", "Skickat", "Lähetetyt",
             "Elementy wysłane", "Sendte elementer"),
}

# Well-known destinations graph.py's `move` accepts, mapped onto the keys
# above, so the window's Archive and Junk buttons mean the same thing whichever
# transport is behind the mailbox.
GRAPH_WELL_KNOWN = {
    "deleteditems": "trash",
    "trash": "trash",
    "archive": "archive",
    "junkemail": "junk",
    "junk": "junk",
    "drafts": "drafts",
    "sentitems": "sent",
}


class TransportError(Exception):
    """A failure that belongs to one mailbox. graph.py turns it into an
    AccountError, so one unreachable mailbox does not empty the others."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


# --------------------------------------------------------------------------
# modified UTF-7, RFC 3501 section 5.1.3
# --------------------------------------------------------------------------
#
# IMAP mailbox names are ASCII on the wire, with everything else in a base64
# dialect. German mailboxes hit this immediately - "Entwürfe" - and a name that
# survives a round trip unchanged is the difference between selecting a folder
# and creating one.


def _mutf7_chunk(text):
    raw = base64.b64encode(text.encode("utf-16-be")).decode("ascii")
    return raw.rstrip("=").replace("/", ",")


def encode_mutf7(name):
    parts, run = [], []
    for char in str(name):
        if "\x20" <= char <= "\x7e":
            if run:
                parts.append("&" + _mutf7_chunk("".join(run)) + "-")
                run = []
            parts.append("&-" if char == "&" else char)
        else:
            run.append(char)
    if run:
        parts.append("&" + _mutf7_chunk("".join(run)) + "-")
    return "".join(parts)


def decode_mutf7(name):
    text = name.decode("ascii", "replace") if isinstance(name, bytes) else str(name)
    parts, index = [], 0
    while index < len(text):
        char = text[index]
        if char != "&":
            parts.append(char)
            index += 1
            continue
        end = text.find("-", index + 1)
        if end == -1:
            # Unterminated shift: nothing good comes of guessing, so the rest
            # is taken literally and the name stays readable.
            parts.append(text[index:])
            break
        chunk = text[index + 1:end]
        if chunk == "":
            parts.append("&")
        else:
            padded = chunk.replace(",", "/")
            padded += "=" * (-len(padded) % 4)
            try:
                parts.append(base64.b64decode(padded).decode("utf-16-be"))
            except (ValueError, UnicodeDecodeError):
                parts.append(text[index:end + 1])
        index = end + 1
    return "".join(parts)


def quoted(name):
    """A mailbox name as an IMAP quoted string."""
    ascii_name = encode_mutf7(name)
    return '"' + ascii_name.replace("\\", "\\\\").replace('"', '\\"') + '"'


# --------------------------------------------------------------------------
# message ids
# --------------------------------------------------------------------------
#
# Graph hands out an id that names a message wherever it is. An IMAP UID names
# a message *in one mailbox*, and only for as long as that mailbox keeps its
# UIDVALIDITY - so all three go into the id the panel carries around, and a
# stale one is reported rather than resolved against whatever now holds that
# number.

ID_PREFIX = "imap"


def make_id(mailbox, uidvalidity, uid):
    from urllib.parse import quote
    return "%s:%s:%s:%s" % (ID_PREFIX, quote(str(mailbox), safe=""), uidvalidity, uid)


def parse_id(message_id):
    from urllib.parse import unquote
    parts = str(message_id or "").split(":")
    if len(parts) != 4 or parts[0] != ID_PREFIX:
        raise TransportError("bad_id", "That message id is not an IMAP one")
    mailbox = unquote(parts[1])
    if not parts[3].isdigit():
        raise TransportError("bad_id", "That message id has no UID")
    return mailbox, parts[2], parts[3]


# --------------------------------------------------------------------------
# connection
# --------------------------------------------------------------------------


def _sasl_xoauth2(username, token):
    """SASL XOAUTH2, as imaplib and smtplib both want it: a callable that is
    handed the server's challenge and answers with the bytes to base64.

    A failed exchange comes back as a challenge carrying a JSON error blob and
    the protocol expects an empty line before the NO, so the credentials are
    offered once and every later challenge is answered with nothing. Resending
    them would leave the connection waiting on a continuation that never ends.
    """
    state = {"offered": False}

    def authobject(_challenge=None):
        if state["offered"]:
            return b""
        state["offered"] = True
        return ("user=%s\x01auth=Bearer %s\x01\x01" % (username, token)).encode()

    return authobject


def _text(value):
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    if isinstance(value, (list, tuple)):
        return " ".join(_text(item) for item in value)
    return str(value)


def _auth_failure(detail):
    """Turn a rejected AUTHENTICATE into something a user can act on."""
    lowered = detail.lower()
    if "disabled" in lowered or "not enabled" in lowered:
        return TransportError(
            "imap_disabled",
            "IMAP is switched off for this mailbox. The tenant consented to the "
            "permission, but an admin has disabled the protocol.",
        )
    if "authenticationfailed" in lowered.replace(" ", "") or "invalid" in lowered:
        return TransportError("auth_required", "IMAP rejected the sign-in: " + detail)
    return TransportError("imap_error", "IMAP sign-in failed: " + detail)


def username_of(account):
    name = str((account or {}).get("username") or "").strip()
    if not name:
        raise TransportError(
            "no_username",
            "This mailbox has no address recorded, and XOAUTH2 needs one. Sign in again, "
            "or set the mailbox address in the widget's settings.",
        )
    return name


def connect(account, token):
    """An authenticated IMAP connection. The caller closes it."""
    username = username_of(account)
    host = str(account.get("imap_host") or DEFAULT_IMAP_HOST)
    try:
        client = imaplib.IMAP4_SSL(host, 993, timeout=TIMEOUT)
    except (OSError, imaplib.IMAP4.error) as error:
        raise TransportError("network", "Could not reach %s: %s" % (host, error))
    try:
        client.authenticate("XOAUTH2", _sasl_xoauth2(username, token))
    except imaplib.IMAP4.error as error:
        try:
            client.logout()
        except (OSError, imaplib.IMAP4.error):
            pass
        raise _auth_failure(_text(error))
    return client


def close(client):
    """Log out without letting a failing goodbye mask the work that succeeded."""
    if client is None:
        return
    try:
        client.logout()
    except (OSError, imaplib.IMAP4.error):
        pass


def select(client, mailbox, readonly=True):
    """SELECT or EXAMINE, returning (exists, uidvalidity)."""
    try:
        typ, data = client.select(quoted(mailbox), readonly=readonly)
    except imaplib.IMAP4.error as error:
        raise TransportError("select_failed", "Could not open %s: %s" % (mailbox, _text(error)))
    if typ != "OK":
        raise TransportError("select_failed", "Could not open %s: %s" % (mailbox, _text(data)))
    exists = 0
    try:
        exists = int(_text(data[0]).strip() or 0)
    except (ValueError, IndexError):
        pass
    # UIDVALIDITY arrives untagged during SELECT; imaplib keeps the last one.
    validity = _text(client.untagged_responses.get("UIDVALIDITY", [b""])[0]).strip() or "0"
    return exists, validity


# --------------------------------------------------------------------------
# folders
# --------------------------------------------------------------------------

LIST_LINE = re.compile(rb'^\((?P<flags>[^)]*)\)\s+(?:"(?P<delim>[^"]*)"|(?P<nil>NIL))\s+(?P<name>.*)$')


def list_folders(client):
    """[(name, delimiter, flags)] for every folder, names already decoded."""
    try:
        typ, data = client.list('""', '"*"')
    except imaplib.IMAP4.error as error:
        raise TransportError("list_failed", "Could not list folders: " + _text(error))
    if typ != "OK":
        raise TransportError("list_failed", "Could not list folders: " + _text(data))

    folders = []
    for line in data or []:
        raw, literal = (line[0], line[1]) if isinstance(line, tuple) else (line, None)
        if not raw:
            continue
        match = LIST_LINE.match(raw.strip())
        if not match:
            continue
        flags = _text(match.group("flags")).split()
        delimiter = _text(match.group("delim") or "/")
        if literal is not None:
            # A name the server chose to send as a literal; the trailing field
            # of the line is then the length prefix rather than the name.
            name = decode_mutf7(literal)
        else:
            name = _text(match.group("name")).strip()
            if name.startswith('"') and name.endswith('"') and len(name) >= 2:
                name = name[1:-1].replace('\\"', '"').replace("\\\\", "\\")
            name = decode_mutf7(name)
        if name:
            folders.append((name, delimiter or "/", flags))
    return folders


def folder_rows(client, want_counts=True):
    """The folder tree flattened parents-first, in graph.py's row shape.

    Returns (rows, complete). Counts come from one STATUS per folder, which is
    one round trip each - capped, and the cap is what `complete` reports.
    """
    folders = list_folders(client)
    inbox = next((name for name, _, _ in folders if name.upper() == "INBOX"), "INBOX")

    def sort_key(item):
        name, delimiter, _flags = item
        parts = name.split(delimiter) if delimiter else [name]
        # The inbox leads. Below it, alphabetical within each level, with each
        # level's key carrying the parent's so children follow their parent.
        keyed = []
        for index, part in enumerate(parts):
            first = index == 0 and part.upper() == "INBOX"
            keyed.append((0 if first else 1, part.lower()))
        return keyed

    truncated = False
    rows, counted = [], 0
    for name, delimiter, flags in sorted(folders, key=sort_key):
        if len(rows) >= FOLDER_CAP:
            truncated = True
            break
        parts = name.split(delimiter) if delimiter else [name]
        depth = len(parts) - 1
        if depth >= FOLDER_MAX_DEPTH:
            truncated = True
            continue
        selectable = not any(flag.lower() == "\\noselect" for flag in flags)
        unread = total = 0
        if want_counts and selectable and counted < FOLDER_COUNT_CAP:
            unread, total = folder_counts(client, name)
            counted += 1
        elif want_counts and selectable:
            truncated = True
        rows.append(
            {
                "id": name,
                "name": parts[-1] or name,
                "unread": unread,
                "total": total,
                # LIST says whether a folder has children; \HasChildren is
                # advertised by Exchange, and the count itself is not
                # something IMAP offers.
                "childCount": 1 if any(f.lower() == "\\haschildren" for f in flags) else 0,
                "parentId": delimiter.join(parts[:-1]) if depth else "",
                "depth": depth,
                "isInbox": name == inbox,
            }
        )
    return rows, not truncated


STATUS_COUNTS = re.compile(rb"MESSAGES\s+(\d+).*?UNSEEN\s+(\d+)|UNSEEN\s+(\d+).*?MESSAGES\s+(\d+)", re.S)


def folder_counts(client, mailbox):
    """(unread, total) for one folder, or (0, 0) if it will not say."""
    try:
        typ, data = client.status(quoted(mailbox), "(MESSAGES UNSEEN)")
    except imaplib.IMAP4.error:
        return 0, 0
    if typ != "OK":
        return 0, 0
    blob = b" ".join(item for item in data if isinstance(item, bytes))
    total = re.search(rb"MESSAGES\s+(\d+)", blob)
    unread = re.search(rb"UNSEEN\s+(\d+)", blob)
    return (int(unread.group(1)) if unread else 0, int(total.group(1)) if total else 0)


def resolve_special(client, key, account=None):
    """The mailbox behind "trash", "archive", "junk", "drafts" or "sent".

    An explicit choice in the account's own settings wins; otherwise the folder
    names are matched against the localized candidates. Nothing matching is an
    error naming the setting to fix, because the alternative is moving somebody
    else's mail into a folder this code guessed at.
    """
    override = str(((account or {}).get("imap_folders") or {}).get(key) or "").strip()
    if override:
        return override
    names = [name for name, _, _ in list_folders(client)]
    lowered = {name.lower(): name for name in names}
    for candidate in SPECIAL_FOLDERS.get(key, ()):
        found = lowered.get(candidate.lower())
        if found:
            return found
    raise TransportError(
        "no_such_folder",
        "Could not find this mailbox's %s folder. Set it in the widget's settings "
        "(imapFolders.%s) - the names are localized and this one is not among the "
        "ones known here." % (key, key),
    )


# --------------------------------------------------------------------------
# reading
# --------------------------------------------------------------------------


def fetch_items(data):
    """imaplib's FETCH reply as [(prefix, literal)].

    Every item asked for here carries exactly one literal, which keeps the
    reply to a predictable shape: a tuple per message, plus the bare bytes that
    close each one.
    """
    items = []
    for element in data or []:
        if isinstance(element, tuple) and len(element) >= 2 and element[1] is not None:
            items.append((element[0] or b"", element[1]))
    return items


UID_RE = re.compile(rb"UID\s+(\d+)")


def uid_of(prefix):
    found = UID_RE.search(prefix or b"")
    return found.group(1).decode("ascii") if found else ""


def received_iso(prefix):
    """INTERNALDATE as UTC ISO-8601 - the arrival time, which is what the
    Graph path's receivedDateTime is too. The Date: header is the sender's
    clock and is not always honest about it."""
    try:
        stamp = imaplib.Internaldate2tuple(prefix)
    except (ValueError, TypeError):
        stamp = None
    if not stamp:
        return ""
    return datetime.fromtimestamp(time.mktime(stamp), timezone.utc).replace(microsecond=0).isoformat()


def address_pair(header):
    """(display name, address) from a From/To header, decoded."""
    if header is None:
        return "", ""
    try:
        addresses = getattr(header, "addresses", None)
        if addresses:
            first = addresses[0]
            return str(first.display_name or ""), str(first.addr_spec or "")
    except (AttributeError, IndexError, ValueError):
        pass
    name, address = email.utils.parseaddr(str(header))
    return name, address


def address_rows(header):
    people = []
    if header is None:
        return people
    try:
        for address in getattr(header, "addresses", ()) or ():
            people.append({"name": str(address.display_name or ""), "address": str(address.addr_spec or "")})
        if people:
            return people
    except (AttributeError, ValueError):
        pass
    for name, address in email.utils.getaddresses([str(header)]):
        if address:
            people.append({"name": name, "address": address})
    return people


def parse_headers(blob):
    try:
        return email.message_from_bytes(blob, policy=POLICY)
    except (ValueError, TypeError):
        return email.message_from_bytes(b"", policy=POLICY)


def header_str(message, name, default=""):
    try:
        value = message[name]
    except (KeyError, ValueError, IndexError):
        return default
    if value is None:
        return default
    try:
        return str(value)
    except (ValueError, UnicodeDecodeError):
        return default


def reference_ids(message):
    """Every Message-ID this message names, oldest first.

    References carries the chain and In-Reply-To its immediate parent, which is
    usually the last entry of the chain again - but only usually, and a mailer
    that sends one without the other is common enough that both are read. The
    ids are pulled out by pattern rather than split on whitespace: a folded
    References header arrives with newlines in it, and some mailers separate
    the ids with commas.

    Panel-side these become edges in a graph, so order and duplication do not
    matter to the result; they are kept tidy anyway because this is also what a
    person reads when a thread looks wrong.
    """
    blob = " ".join(
        part for part in (header_str(message, "References"),
                          header_str(message, "In-Reply-To")) if part
    )
    seen, found = set(), []
    for candidate in MESSAGE_ID.findall(blob):
        if candidate not in seen:
            seen.add(candidate)
            found.append(candidate)
    return found


def looks_important(message):
    if header_str(message, "Importance").strip().lower() == "high":
        return True
    priority = header_str(message, "X-Priority").strip()[:1]
    return priority in ("1", "2")


def looks_attached(message):
    """Whether the message probably carries an attachment.

    BODYSTRUCTURE would answer properly, at the cost of parsing it; the
    top-level content type is one header away and gets the common case right.
    An inline image in a multipart/related body reads as no attachment here,
    which is the wrong answer in the direction that costs least - a paperclip
    that fails to appear rather than one that appears on mail without one.
    """
    return header_str(message, "Content-Type").strip().lower().startswith("multipart/mixed")


# An anchor whole, so its address can be saved before the tag carrying it is
# thrown away. Non-greedy to the first </a>: nesting anchors is not legal HTML,
# and a greedy match would swallow a whole newsletter as one link.
_ANCHOR = re.compile(
    r"""(?is)<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))[^>]*>(.*?)<\s*/\s*a\s*>"""
)
# Where a parked anchor waits out the tag strip. NUL cannot survive in a mail
# body that is going to be read as text, so nothing else can be wearing one.
_PARKED = re.compile("\x00(\\d+)\x00")


def _anchor_label(inner, html_module):
    """The words inside an anchor, as something linkify will take as a label.

    Its pattern reads a label as `[...]` up to the first `]` or newline, and
    caps it at 160 characters. Both brackets therefore have to go: a `]` ends
    the label early, and a `[` inside it is where the pattern starts reading
    instead, which drops the words before it. Parentheses read the same and
    mean nothing to the pattern.
    """
    text = re.sub(r"(?s)<[^>]+>", " ", inner)
    text = html_module.unescape(text).replace("[", "(").replace("]", ")")
    return re.sub(r"\s+", " ", text).strip()[:160].strip()


def strip_markup(markup, keep_links=False):
    """HTML mail as text. With `keep_links`, the addresses come along.

    A link's address lives in the tag, so the plain strip below drops it and
    leaves the reader words like "Sign in" with nothing behind them - the whole
    point of that message gone. Graph's own HTML-to-text conversion writes
    `[label]<url>`, which `linkify` knows how to turn back into a link, so this
    writes the same shape. Off by default: a one-line preview has no room for
    an address, and that is the other caller.
    """
    import html as html_module

    # Comments first: an Outlook mail is full of conditional ones, and taking
    # tags out from under them leaves their "-->" stranded in the text.
    text = re.sub(r"(?s)<!--.*?-->", " ", markup)
    # Up to the closing tag, or to the end when the fetch cut the block off:
    # a preview is built from a truncated body, where a stylesheet routinely
    # has no </style> to find.
    text = re.sub(r"(?is)<(script|style)\b.*?(?:</\1>|$)", " ", text)

    links = []
    if keep_links:
        # The address has to be taken out before the tags go, and it cannot be
        # written back in yet: `<https://…>` is as angle-bracketed as any tag
        # and the strip would eat it. So each anchor leaves a marker behind and
        # returns as text once there is nothing left to strip.
        text = text.replace("\x00", "")

        def park(match):
            url = match.group(1) or match.group(2) or match.group(3) or ""
            url = url.strip()
            # Only the schemes the reading pane will follow. Anything else -
            # a javascript: href, a cid: image link - keeps its words and
            # loses its address, which is the safe direction.
            if not url.lower().startswith(("http://", "https://")):
                return match.group(4)
            links.append((url, _anchor_label(match.group(4), html_module)))
            return "\x00%d\x00" % (len(links) - 1)

        text = _ANCHOR.sub(park, text)

    text = re.sub(r"(?is)<br\s*/?>|</p>", "\n", text)
    text = re.sub(r"(?s)<[^>]+>", " ", text)
    text = html_module.unescape(text)
    if not links:
        return text

    def restore(match):
        url, label = links[int(match.group(1))]
        # No words to show means the anchor wrapped something that did not
        # survive - an image, most often. The bare form leaves linkify to
        # shorten the address into a label of its own.
        return "[%s]<%s>" % (label, html_module.unescape(url)) if label \
            else "<%s>" % html_module.unescape(url)

    return _PARKED.sub(restore, text)


def _body_for_order(message, order):
    """(text, is_html) for the first part matching `order`, or ("", False)."""
    part = None
    try:
        part = message.get_body(preferencelist=order)
    except (AttributeError, ValueError):
        part = None
    if part is None:
        # A truncated fetch can leave get_body with nothing to choose from;
        # fall back to whatever the top level holds.
        part = message
    is_html = str(part.get_content_type() or "").lower() == "text/html"
    try:
        content = part.get_content()
    except (LookupError, ValueError, TypeError, AssertionError):
        # Base64 cut mid-stream, an unknown charset, a part whose declared
        # encoding does not match its bytes. The raw payload is still better
        # than an empty pane.
        try:
            raw = part.get_payload(decode=True)
            content = raw.decode("utf-8", "replace") if raw else str(part.get_payload())
        except (ValueError, TypeError):
            content = ""
    if not isinstance(content, str):
        content = str(content or "")
    return content, is_html


def inline_images(message):
    """Content-ID -> bytes, for the pictures the message brought with it.

    An HTML mail that shows a logo or a signature image carries it as another
    MIME part and points at it with `cid:`. Those cost nothing to display -
    the bytes are already here, and showing them asks nobody for anything - so
    they are handed up whether or not remote images were asked for.

    The id is stored without its angle brackets, which is how the `cid:` in the
    markup writes it.
    """
    found = {}
    for part in message.walk():
        identifier = str(part.get("Content-ID") or "").strip().strip("<>")
        if identifier == "" or identifier in found:
            continue
        if not str(part.get_content_type() or "").lower().startswith("image/"):
            continue
        try:
            payload = part.get_payload(decode=True)
        except (ValueError, TypeError, AssertionError):
            continue
        if payload:
            found[identifier] = payload
    return found


def has_html(message):
    """Whether the message carries a text/html part at all.

    The reading pane offers "Show formatting" from this rather than from a
    guess. On a message that was only ever plain text there is nothing to
    show, and an offer that changes nothing when it is taken is worse than no
    offer at all.
    """
    for part in message.walk():
        if str(part.get_content_type() or "").lower() != "text/html":
            continue
        if part.get_content_disposition() == "attachment":
            continue
        return True
    return False


def body_of(message, want_html):
    """(text, is_html) for the part worth showing, or ("", False).

    A multipart/alternative can carry an empty text/plain beside a real
    text/html - some senders ship the plain part as a placeholder. Preferring
    plain then finding it blank is not a reason to show an empty pane, so the
    other format gets a turn before giving up.
    """
    order = ("html", "plain") if want_html else ("plain", "html")
    content, is_html = _body_for_order(message, order)
    if content.strip():
        return content, is_html
    alt, alt_is_html = _body_for_order(message, tuple(reversed(order)))
    return (alt, alt_is_html) if alt.strip() else (content, is_html)


def decoded_if_base64(text):
    """The text behind a body the truncated fetch left base64-encoded.

    Cutting the body mid-stream can leave the parser without what it needs to
    decode a part, and it hands back the encoded text instead. Decoding as
    much as arrived beats showing the reader base64.
    """
    # The leading run of encoded lines only: a truncated part is usually
    # followed by the next MIME boundary, so testing the whole string finds
    # one stray "-" or "_" and gives up. Real prose never survives this -
    # a line of it carries a space or a comma within the first 40 characters.
    run = []
    for line in text.strip().splitlines():
        line = line.strip()
        if re.fullmatch(r"[A-Za-z0-9+/=]{40,}", line):
            run.append(line)
        elif run:
            break
        elif line:
            return text
    if not run:
        return text
    packed = "".join(run)
    # A cut stream rarely ends on a four-character group, and a trailing
    # partial one is what b64decode refuses outright - so drop it rather than
    # lose the whole body to it.
    packed = packed.rstrip("=")
    packed = packed[:len(packed) - len(packed) % 4]
    if not packed:
        return text
    try:
        raw = base64.b64decode(packed)
    except (ValueError, base64.binascii.Error):
        return text
    decoded = raw.decode("utf-8", "replace")
    return decoded if decoded.strip() else text


def preview_text(header_blob, text_blob):
    """A one-line preview, built by parsing the headers and body back together.

    The headers carry the boundary and the transfer encoding, so gluing the
    separately fetched body text under them gives the email parser a message it
    can walk - truncated, which it tolerates - rather than a wall of MIME to
    guess at.
    """
    if not text_blob:
        return ""
    glued = header_blob.rstrip(b"\r\n") + b"\r\n\r\n" + text_blob
    message = parse_headers(glued)
    content, is_html = body_of(message, want_html=False)
    content = decoded_if_base64(content)
    if is_html:
        content = strip_markup(content)
    # Quoted replies and signatures are mostly what a preview would otherwise
    # show, so lines that are only quoting are dropped before the first two
    # lines are taken.
    lines = [line.strip() for line in content.splitlines()]
    kept = [line for line in lines if line and not line.startswith(">")]
    return re.sub(r"\s+", " ", " ".join(kept))[:PREVIEW_CHARS].strip()


def row_from(prefix, header_blob, mailbox, validity, previews):
    message = parse_headers(header_blob)
    uid = uid_of(prefix)
    flags = [_text(flag).lower() for flag in imaplib.ParseFlags(prefix) or ()]
    name, address = address_pair(message["From"] if "From" in message else None)
    subject = header_str(message, "Subject").strip()
    return {
        "id": make_id(mailbox, validity, uid),
        "subject": subject or "(no subject)",
        "from": name or address,
        "fromAddress": address,
        "received": received_iso(prefix),
        "preview": preview_text(header_blob, previews.get(uid, b"")),
        # OWA deep links are built from Graph's message id, which IMAP never
        # sees. The window hides the button when there is nothing to open.
        "webLink": "",
        "important": looks_important(message),
        "hasAttachments": looks_attached(message),
        "read": "\\seen" in flags,
        # IMAP's own follow-up flag, and the one Outlook's flag column sets, so
        # this agrees with what Graph reports for the same mailbox.
        "flagged": "\\flagged" in flags,
        # Focused/Other is Outlook's own split, computed server-side and
        # exposed through Graph only. Every row claims Focused because that is
        # the view the panel opens on; capabilities() says the split is absent
        # so the filter can be hidden rather than showing an empty Other.
        "focused": True,
        # Threading, in the shape graph.py's rows carry it. IMAP has no
        # conversation id of its own, so "thread" stays empty and the panel
        # rebuilds the conversation from these two instead - the Message-ID
        # graph that has been how mail threads since RFC 822.
        "thread": "",
        "messageId": header_str(message, "Message-ID").strip(),
        "references": reference_ids(message),
    }


def sequence_window(exists, top):
    """The newest `top` messages as a sequence range, or "" for an empty folder."""
    if exists <= 0:
        return ""
    first = max(1, exists - top + 1)
    return "%d:%d" % (first, exists)


def fetch_previews(client, uid_set):
    if not uid_set:
        return {}
    try:
        typ, data = client.uid("FETCH", uid_set, PREVIEW_ITEMS)
    except imaplib.IMAP4.error:
        return {}
    if typ != "OK":
        return {}
    return {uid_of(prefix): blob for prefix, blob in fetch_items(data) if uid_of(prefix)}


def read_rows(client, mailbox, validity, spec, by_uid):
    """Rows for a sequence range or UID set, newest first."""
    if not spec:
        return []
    try:
        if by_uid:
            typ, data = client.uid("FETCH", spec, LIST_ITEMS)
        else:
            typ, data = client.fetch(spec, LIST_ITEMS)
    except imaplib.IMAP4.error as error:
        raise TransportError("fetch_failed", "Could not read mail: " + _text(error))
    if typ != "OK":
        raise TransportError("fetch_failed", "Could not read mail: " + _text(data))

    items = fetch_items(data)
    uids = [uid_of(prefix) for prefix, _ in items]
    previews = fetch_previews(client, ",".join(uid for uid in uids if uid))
    rows = [row_from(prefix, blob, mailbox, validity, previews) for prefix, blob in items]
    rows.sort(key=lambda row: row["received"], reverse=True)
    return rows


def folder_to_open(client, account, folders, folder_id, warnings):
    """Which mailbox to SELECT for a fetch, from what the panel asked for.

    Four answers, tried in that order because each is more specific than the
    next: nothing or "inbox" is the inbox; a path this mailbox actually lists is
    that folder; a well-known name - "archive", "sentitems" - is resolved
    against the mailbox's own folder names; and anything else has gone.

    The well-known branch is what lets the window ask every mailbox for the
    same folder at once - see Service.selectFolderEverywhere. It cannot ask by
    id, because no folder id means the same folder in two mailboxes, let alone
    across the two transports. So the *name* travels, and each side resolves it:
    Graph already takes these names in a folder path, and here they are matched
    against names that arrive in the mailbox's own language.

    A path is tried before a well-known name deliberately: a mailbox that really
    does contain a folder called "Archive" means that one, and its path is what
    the tree handed out.
    """
    inbox = next((row["id"] for row in folders if row["isInbox"]), "INBOX")
    wanted = str(folder_id or "").strip()
    if wanted in ("", "inbox"):
        return inbox
    if any(row["id"] == wanted for row in folders) or not folders:
        return wanted
    special = GRAPH_WELL_KNOWN.get(wanted.lower())
    if special:
        try:
            return resolve_special(client, special, account)
        except TransportError as error:
            # A mailbox whose Archive is called something nobody here knows is
            # worth saying so about, and worth still showing mail for.
            warnings.append({"scope": "folders", "message": error.message})
            return inbox
    warnings.append({"scope": "folders", "message": "That folder is gone - showing the inbox"})
    return inbox


def snapshot(account, token, top, folder_id="", want_folders=True):
    """One mailbox's unread count, folder tree and newest mail.

    Two lists are read, matching the two the panel can ask for: the newest
    messages in the folder, and the newest unread ones. The newest N need not
    contain the newest N unread, so neither list can be derived from the other.
    """
    client = None
    warnings = []
    try:
        client = connect(account, token)

        folders, complete = ([], True)
        if want_folders:
            try:
                folders, complete = folder_rows(client)
            except TransportError as error:
                warnings.append({"scope": "folders", "message": error.message})
            if not complete:
                warnings.append(
                    {"scope": "folders", "message": "Too many folders to list them all - some are not shown"}
                )

        inbox = next((row["id"] for row in folders if row["isInbox"]), "INBOX")
        mailbox = folder_to_open(client, account, folders, folder_id, warnings)

        unread, _total = folder_counts(client, inbox)
        exists, validity = select(client, mailbox, readonly=True)

        collected = {}
        try:
            for row in read_rows(client, mailbox, validity, sequence_window(exists, top), by_uid=False):
                collected[row["id"]] = row
        except TransportError as error:
            warnings.append({"scope": "mail", "message": error.message})

        try:
            typ, data = client.uid("SEARCH", None, "UNSEEN")
            if typ == "OK":
                unseen = _text(data).split()
                for row in read_rows(client, mailbox, validity, ",".join(unseen[-top:]), by_uid=True):
                    collected.setdefault(row["id"], row)
        except (imaplib.IMAP4.error, TransportError) as error:
            warnings.append({"scope": "mail", "message": "Could not list unread mail: " + _text(error)})

        name = next((row["name"] for row in folders if row["id"] == mailbox), mailbox)
        return {
            "unreadCount": unread,
            "unreadKnown": True,
            "folders": folders,
            "folderId": mailbox,
            "folderName": name,
            "mail": sorted(collected.values(), key=lambda row: row["received"], reverse=True),
            "warnings": warnings,
        }
    finally:
        close(client)


def message(account, token, message_id, want_html):
    """One message's headers and body, raw. graph.py renders it, the same way
    it renders a Graph body, so both transports look identical in the pane."""
    mailbox, validity, uid = parse_id(message_id)
    client = None
    try:
        client = connect(account, token)
        _exists, current = select(client, mailbox, readonly=True)
        if validity not in ("0", current):
            raise TransportError(
                "stale_id",
                "This message's folder was rebuilt since the list was fetched. Refresh and try again.",
            )
        try:
            typ, data = client.uid("FETCH", uid, "(BODY.PEEK[]<0.%d>)" % MAX_MESSAGE_BYTES)
        except imaplib.IMAP4.error as error:
            raise TransportError("message_failed", "Could not open this message: " + _text(error))
        items = fetch_items(data)
        if typ != "OK" or not items:
            raise TransportError("message_failed", "This message is no longer in %s" % mailbox)

        parsed = parse_headers(items[0][1])
        name, address = address_pair(parsed["From"] if "From" in parsed else None)
        raw, is_html = body_of(parsed, want_html)
        return {
            "id": message_id,
            "subject": header_str(parsed, "Subject").strip() or "(no subject)",
            "from": name or address,
            "fromAddress": address,
            "to": address_rows(parsed["To"] if "To" in parsed else None),
            "cc": address_rows(parsed["Cc"] if "Cc" in parsed else None),
            "received": received_iso(items[0][0]) or header_str(parsed, "Date"),
            "webLink": "",
            "hasAttachments": any(
                part.get_content_disposition() == "attachment" for part in parsed.walk()
            ),
            "raw": raw,
            "isHtml": is_html,
            # Whether markup exists, as opposed to whether it is what came
            # back above: `body_of` prefers plain text, so a message with both
            # parts answers is_html False and hasHtml True.
            "hasHtml": has_html(parsed),
            "inlineImages": inline_images(parsed),
        }
    finally:
        close(client)


# --------------------------------------------------------------------------
# writing
# --------------------------------------------------------------------------


def mark(account, token, message_id, read):
    mailbox, validity, uid = parse_id(message_id)
    client = None
    try:
        client = connect(account, token)
        _exists, current = select(client, mailbox, readonly=False)
        if validity not in ("0", current):
            raise TransportError("stale_id", "This message's folder was rebuilt. Refresh and try again.")
        try:
            typ, data = client.uid("STORE", uid, "+FLAGS" if read else "-FLAGS", "(\\Seen)")
        except imaplib.IMAP4.error as error:
            raise TransportError("mark_failed", "Could not change this message: " + _text(error))
        if typ != "OK":
            raise TransportError("mark_failed", "Could not change this message: " + _text(data))
        return {"ok": True, "id": message_id, "read": bool(read)}
    finally:
        close(client)


def flag(account, token, message_id, flagged):
    mailbox, validity, uid = parse_id(message_id)
    client = None
    try:
        client = connect(account, token)
        _exists, current = select(client, mailbox, readonly=False)
        if validity not in ("0", current):
            raise TransportError("stale_id", "This message's folder was rebuilt. Refresh and try again.")
        try:
            typ, data = client.uid("STORE", uid, "+FLAGS" if flagged else "-FLAGS", "(\\Flagged)")
        except imaplib.IMAP4.error as error:
            raise TransportError("flag_failed", "Could not flag this message: " + _text(error))
        if typ != "OK":
            raise TransportError("flag_failed", "Could not flag this message: " + _text(data))
        return {"ok": True, "id": message_id, "flagged": bool(flagged)}
    finally:
        close(client)


COPYUID = re.compile(rb"\[COPYUID\s+(\d+)\s+([\d,:]+)\s+([\d,:]+)\]", re.I)


def move(account, token, message_id, destination):
    """Move one message into another folder of the same mailbox.

    MOVE is advertised by Exchange, so the copy-then-delete-then-expunge dance
    is only a fallback - and it matters that it is: an EXPUNGE on a mailbox
    someone else is also changing removes by sequence number, and getting that
    wrong deletes the wrong mail. UIDPLUS gives back the new UID, which is what
    lets the panel follow the message it just moved.
    """
    mailbox, validity, uid = parse_id(message_id)
    wanted = str(destination or "").strip()
    if not wanted:
        raise TransportError("no_folder", "No folder to move this message to")
    client = None
    try:
        client = connect(account, token)
        key = GRAPH_WELL_KNOWN.get(wanted.lower())
        target = resolve_special(client, key, account) if key else wanted
        _exists, current = select(client, mailbox, readonly=False)
        if validity not in ("0", current):
            raise TransportError("stale_id", "This message's folder was rebuilt. Refresh and try again.")

        new_uid = ""
        if "MOVE" in (client.capabilities or ()):
            try:
                typ, data = client.uid("MOVE", uid, quoted(target))
            except imaplib.IMAP4.error as error:
                raise TransportError("move_failed", "Could not move this message: " + _text(error))
            if typ != "OK":
                raise TransportError("move_failed", "Could not move this message: " + _text(data))
            found = COPYUID.search(b" ".join(item for item in (data or []) if isinstance(item, bytes)))
            new_uid = found.group(3).decode("ascii") if found else ""
        else:
            try:
                typ, data = client.uid("COPY", uid, quoted(target))
                if typ != "OK":
                    raise TransportError("move_failed", "Could not copy this message: " + _text(data))
                found = COPYUID.search(b" ".join(i for i in (data or []) if isinstance(i, bytes)))
                new_uid = found.group(3).decode("ascii") if found else ""
                client.uid("STORE", uid, "+FLAGS", "(\\Deleted)")
                # UID EXPUNGE removes only the message named here; a bare
                # EXPUNGE would take every \Deleted message in the folder,
                # including ones another client flagged.
                if "UIDPLUS" in (client.capabilities or ()):
                    client.uid("EXPUNGE", uid)
            except imaplib.IMAP4.error as error:
                raise TransportError("move_failed", "Could not move this message: " + _text(error))

        return {
            "ok": True,
            "id": message_id,
            "newId": make_id(target, "0", new_uid) if new_uid else "",
            "folder": target,
        }
    finally:
        close(client)


def delete(account, token, message_id):
    """Move to the trash folder rather than erase, so the button stays undoable
    from Outlook - the same thing Graph's DELETE on a message does."""
    result = move(account, token, message_id, "deleteditems")
    return {"ok": True, "id": message_id, "deleted": True, "newId": result.get("newId", "")}


def readable_date(value):
    """A timestamp somebody can read, out of the ISO one a fetch returns.

    The quote line said "On 2026-09-01T10:00:00+00:00, X wrote:" - a machine
    timestamp in the one line of a reply the recipient actually reads. Falls
    back to whatever it was given: a date that cannot be parsed is still better
    printed than dropped.
    """
    text = str(value or "")
    if not text:
        return ""
    try:
        # received_iso writes UTC; shown in the local zone, because the line is
        # read by a person and not by a parser.
        parsed = datetime.fromisoformat(text).astimezone()
    except (TypeError, ValueError):
        return text
    return parsed.strftime("%a, %d %b %Y at %H:%M")


def original_text(original):
    """The original's body as text, whatever it arrived as."""
    body = str(original.get("raw") or "")
    return strip_markup(body) if original.get("isHtml") else body


def quote_original(original):
    """The original message, quoted the way mail clients quote a reply."""
    who = original.get("from") or original.get("fromAddress") or "somebody"
    quoted_lines = "\n".join("> " + line for line in original_text(original).splitlines())
    return "On %s, %s wrote:\n%s" % (readable_date(original.get("received")), who, quoted_lines)


def forwarded_original(original):
    """The original as a forwarded message: its headers, then its body.

    A reply is quoted with "On <date>, X wrote:" because whoever gets it was
    already in the conversation. A forward goes to somebody who has never seen
    the message, so who it was from, who it was addressed to, when it arrived
    and what it was called are part of what is being forwarded - and the body
    is passed on as it was written rather than marked up as a quotation.
    """
    who = original.get("from") or ""
    address = str(original.get("fromAddress") or "")
    sender = email.utils.formataddr((str(who), address)) if address else str(who or "somebody")
    lines = ["---------- Forwarded message ----------",
             "From: %s" % sender,
             "Date: %s" % readable_date(original.get("received")),
             "Subject: %s" % str(original.get("subject") or "")]
    for label, key in (("To", "to"), ("Cc", "cc")):
        people = [email.utils.formataddr((str(person.get("name") or ""),
                                          str(person.get("address") or "")))
                  for person in (original.get(key) or []) if person.get("address")]
        if people:
            lines.append("%s: %s" % (label, ", ".join(people)))
    return "\n".join(lines) + "\n\n" + original_text(original)


def compose(account, token, message_id, mode, comment, to_addresses, draft, attachments=None,
            subject_line="", cc_addresses=None):
    """Reply, reply all, forward, or write a message of your own.

    Graph builds the quoting, the recipients and the threading headers itself
    (createReply and friends); over SMTP all of that has to be assembled here.
    A draft is an APPEND to the Drafts folder, which needs no SMTP permission
    at all - so a mailbox that consented to IMAP but not SMTP.Send can still
    write, and finish the message in Outlook.

    `mode == "new"` is the message that answers nothing: nothing is fetched,
    nothing is quoted, there is no In-Reply-To to thread it by, and the subject
    is `subject_line` rather than the original's with a prefix on it.

    `attachments` is [(name, bytes)], already read and size-checked by the
    caller so that both transports refuse the same files for the same reasons.
    """
    new = mode == "new"
    # Not fetched for a new message: there is no original, and asking the
    # server for message id "" is a round trip that can only fail.
    original = {} if new else message(account, token, message_id, want_html=False)
    me = username_of(account)

    copies = [address for address in (cc_addresses or []) if address]

    if new:
        subject = str(subject_line or "")
        recipients = list(to_addresses or [])
    else:
        subject = original.get("subject") or ""
        if mode == "forward":
            prefix = "Fwd: "
            recipients = list(to_addresses or [])
        else:
            prefix = "Re: "
            sender = original.get("fromAddress") or ""
            recipients = list(to_addresses or ([sender] if sender else []))
            if mode == "reply-all":
                for person in (original.get("to") or []) + (original.get("cc") or []):
                    address = person.get("address") or ""
                    # Replying to everybody should not mean replying to yourself.
                    if address and address.lower() != me.lower() and address not in recipients:
                        recipients.append(address)
        if not subject.lower().startswith(prefix.lower().strip()):
            subject = prefix + subject
    if not recipients:
        raise TransportError("no_recipient", "There is nobody to send this to")

    note = EmailMessage(policy=email.policy.SMTP)
    note["From"] = me
    note["To"] = ", ".join(recipients)
    if copies:
        note["Cc"] = ", ".join(copies)
    note["Subject"] = subject
    note["Date"] = email.utils.formatdate(localtime=True)
    # domain= is not decoration. make_msgid() without it calls socket.getfqdn(),
    # which on a machine whose hostname does not resolve blocks until the
    # resolver gives up - five seconds, measured here, on every single reply -
    # and then writes that hostname into a header the recipient can read. The
    # mailbox's own domain is instant and is what a Message-ID should say
    # anyway; the SMTP host is the fallback for an address without one.
    note["Message-ID"] = email.utils.make_msgid(
        domain=(me.rpartition("@")[2] or str(account.get("smtp_host") or DEFAULT_SMTP_HOST)))
    # Threading, so the reply lands in the conversation rather than beside it.
    #
    # Only a reply. A new message starts a conversation instead of joining one,
    # and a forward is a different message about the same thing sent to somebody
    # who was never in the conversation - threading it in filed the forward
    # under the original in the recipient's client, as though they had been
    # copied on it all along. Inventing a reference to nothing does the same to
    # a new message.
    original_id = "" if (new or mode == "forward") else str(original.get("messageId") or "").strip()
    if original_id:
        note["In-Reply-To"] = original_id
        note["References"] = original_id
    if new:
        body_text = str(comment or "")
    elif mode == "forward":
        body_text = "%s\n\n%s" % (str(comment or ""), forwarded_original(original))
    else:
        body_text = "%s\n\n%s" % (str(comment or ""), quote_original(original))
    note.set_content(body_text)

    # add_attachment turns this into multipart/mixed, which is why set_content
    # has to have run first. The type is guessed from the name and falls back to
    # octet-stream: a wrong guess is a file the recipient has to open by hand, a
    # missing one is a mail some servers refuse.
    for name, body in (attachments or []):
        guessed, _ = mimetypes.guess_type(name)
        maintype, _, subtype = (guessed or "application/octet-stream").partition("/")
        note.add_attachment(body, maintype=maintype, subtype=subtype or "octet-stream",
                            filename=name)

    if draft:
        client = None
        try:
            client = connect(account, token)
            folder = resolve_special(client, "drafts", account)
            try:
                typ, data = client.append(quoted(folder), "(\\Draft)", None, note.as_bytes())
            except imaplib.IMAP4.error as error:
                raise TransportError("draft_failed", "Could not save the draft: " + _text(error))
            if typ != "OK":
                raise TransportError("draft_failed", "Could not save the draft: " + _text(data))
            return {"ok": True, "mode": mode, "drafted": True, "id": "", "webLink": "", "warning": ""}
        finally:
            close(client)

    host = str(account.get("smtp_host") or DEFAULT_SMTP_HOST)
    port = int(account.get("smtp_port") or DEFAULT_SMTP_PORT)
    try:
        server = smtplib.SMTP(host, port, timeout=TIMEOUT)
        try:
            server.ehlo()
            server.starttls()
            server.ehlo()
            server.auth("XOAUTH2", _sasl_xoauth2(me, token), initial_response_ok=True)
            server.send_message(note)
        finally:
            try:
                server.quit()
            except (OSError, smtplib.SMTPException):
                pass
    except smtplib.SMTPAuthenticationError as error:
        raise TransportError(
            "send_permission_required",
            "SMTP would not accept the sign-in - this mailbox may not have consented to "
            "SMTP.Send. Save it as a draft instead. (%s)" % _text(error.smtp_error or error),
        )
    except (OSError, smtplib.SMTPException) as error:
        raise TransportError("send_failed", "Could not send this message: " + _text(error))

    # Client SMTP submission does not put a copy in Sent Items, so this does.
    # Best effort: a message that went out and was not filed is worth a warning,
    # not a failure report on a mail the recipient already has.
    warning = ""
    client = None
    try:
        client = connect(account, token)
        folder = resolve_special(client, "sent", account)
        typ, _data = client.append(quoted(folder), "(\\Seen)", None, note.as_bytes())
        if typ != "OK":
            warning = "Sent, but could not file a copy in %s" % folder
    except (TransportError, imaplib.IMAP4.error, OSError) as error:
        warning = "Sent, but could not file a copy in Sent Items: " + _text(error)
    finally:
        close(client)

    return {"ok": True, "mode": mode, "drafted": False,
            "id": "" if new else message_id, "warning": warning}


# --------------------------------------------------------------------------
# folders, as things that can be made and unmade
# --------------------------------------------------------------------------
#
# An IMAP folder is a path: "Archive", "Archive/2024", with a delimiter the
# server chooses and announces in LIST. That is why a folder id here is the
# whole path and not a name - and why moving a folder under another parent is
# the same command as renaming it. Both are RENAME with a different path.


def delimiter_for(client):
    """The character this server puts between a folder and its parent."""
    for _name, delim, _flags in list_folders(client):
        if delim:
            return delim
    return "/"


def leaf_of(path, delim):
    return path.split(delim)[-1] if delim else path


def _check_leaf(leaf, delim):
    if leaf == "":
        raise TransportError("bad_name", "A folder needs a name")
    if delim and delim in leaf:
        raise TransportError(
            "bad_name",
            "A folder name cannot contain %s on this server - that is how it "
            "separates a folder from its parent" % delim,
        )


def _refuse_inbox(path):
    if path.upper() == "INBOX":
        raise TransportError("bad_folder", "The inbox cannot be renamed, moved or deleted")


def _joined(parent, leaf, delim):
    return (parent + delim + leaf) if parent else leaf


def create_folder(account, token, name, parent):
    """A new folder, under `parent` (a folder id) or at the top level."""
    leaf = str(name or "").strip()
    where = str(parent or "").strip()
    client = None
    try:
        client = connect(account, token)
        delim = delimiter_for(client)
        _check_leaf(leaf, delim)
        path = _joined(where, leaf, delim)
        try:
            typ, data = client.create(quoted(path))
        except imaplib.IMAP4.error as error:
            raise TransportError("create_failed", "Could not create that folder: " + _text(error))
        if typ != "OK":
            raise TransportError("create_failed", "Could not create that folder: " + _text(data))
        # Servers list what is subscribed; one nobody is subscribed to is a
        # folder this plugin would make and then not be able to find.
        try:
            client.subscribe(quoted(path))
        except imaplib.IMAP4.error:
            pass
        return {"ok": True, "id": path, "name": leaf, "parentId": where}
    finally:
        close(client)


def rename_folder(account, token, folder_id, name):
    """Give a folder another name, where it already is."""
    path = str(folder_id or "").strip()
    leaf = str(name or "").strip()
    if path == "":
        raise TransportError("bad_folder", "No folder to rename")
    _refuse_inbox(path)
    client = None
    try:
        client = connect(account, token)
        delim = delimiter_for(client)
        _check_leaf(leaf, delim)
        parts = path.split(delim) if delim else [path]
        target = _joined(delim.join(parts[:-1]) if len(parts) > 1 else "", leaf, delim)
        if target == path:
            return {"ok": True, "id": path, "name": leaf}
        return _rename(client, path, target, "rename")
    finally:
        close(client)


def move_folder(account, token, folder_id, parent):
    """Put a folder under another one, or back at the top level.

    The same RENAME as above with the leaf kept and the parent changed, which
    is all "move" means to IMAP. Children come along: the server renames the
    whole hierarchy under a folder that is renamed.
    """
    path = str(folder_id or "").strip()
    where = str(parent or "").strip()
    if path == "":
        raise TransportError("bad_folder", "No folder to move")
    _refuse_inbox(path)
    client = None
    try:
        client = connect(account, token)
        delim = delimiter_for(client)
        # Into itself, or into one of its own children, is a folder that would
        # have to contain itself. The server may or may not say so; this does.
        if where == path or (delim and where.startswith(path + delim)):
            raise TransportError("bad_folder", "A folder cannot be moved inside itself")
        target = _joined(where, leaf_of(path, delim), delim)
        if target == path:
            return {"ok": True, "id": path, "name": leaf_of(path, delim)}
        return _rename(client, path, target, "move")
    finally:
        close(client)


def _rename(client, path, target, what):
    try:
        typ, data = client.rename(quoted(path), quoted(target))
    except imaplib.IMAP4.error as error:
        raise TransportError(what + "_failed", "Could not %s that folder: %s" % (what, _text(error)))
    if typ != "OK":
        raise TransportError(what + "_failed", "Could not %s that folder: %s" % (what, _text(data)))
    try:
        client.subscribe(quoted(target))
        client.unsubscribe(quoted(path))
    except imaplib.IMAP4.error:
        pass
    delim = delimiter_for(client)
    return {"ok": True, "id": target, "name": leaf_of(target, delim)}


def delete_folder(account, token, folder_id):
    """Delete a folder and the mail in it.

    IMAP has no wastebasket for folders: DELETE takes the messages with it.
    A folder with children is refused rather than guessed at - RFC 3501 lets a
    server either refuse it or leave a \\Noselect husk behind, and neither is
    something to find out about after the fact.
    """
    path = str(folder_id or "").strip()
    if path == "":
        raise TransportError("bad_folder", "No folder to delete")
    _refuse_inbox(path)
    client = None
    try:
        client = connect(account, token)
        delim = delimiter_for(client)
        for name, _delim, _flags in list_folders(client):
            if delim and name.startswith(path + delim):
                raise TransportError(
                    "has_children",
                    "This folder has folders inside it. Delete or move those first.",
                )
        try:
            client.unsubscribe(quoted(path))
        except imaplib.IMAP4.error:
            pass
        try:
            typ, data = client.delete(quoted(path))
        except imaplib.IMAP4.error as error:
            raise TransportError("delete_failed", "Could not delete that folder: " + _text(error))
        if typ != "OK":
            raise TransportError("delete_failed", "Could not delete that folder: " + _text(data))
        return {"ok": True, "id": path, "name": leaf_of(path, delim)}
    finally:
        close(client)


def capabilities():
    """What this transport cannot do, so the panel can hide it rather than
    show a filter that never matches or an agenda that is always empty."""
    return {"calendar": False, "focused": False, "webLinks": False}

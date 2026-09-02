"""Exchange Web Services, for the calendar of a mailbox read over IMAP.

IMAP carries no calendar. A tenant that withholds Graph's Mail.Read will
usually still consent to EWS, because that is what a desktop mail client asks
for - the same reasoning that put the mail on IMAP in the first place. So a
mailbox on the IMAP transport gets its agenda from here, shaped exactly like
the one the Graph path builds so that nothing downstream can tell which
transport drew it.

Two things are worth stating plainly:

  * EWS is a separate resource from IMAP, and Entra issues one token per
    resource - the two cannot be asked for together. A mailbox therefore
    holds a second set of tokens for the calendar, obtained by its own
    consent, and having mail is no guarantee of having a calendar.
  * EWS answers in UTC whatever it is asked, while the panel reads a
    zone-less timestamp as local wall clock (parseDate in Model.js). Every
    time is converted here. Passing one through unconverted would land every
    meeting an hour or two from where it belongs, which is the kind of wrong
    that looks right.
"""

import re
import urllib.error
import urllib.request
import xml.etree.ElementTree as ElementTree
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

ENDPOINT = "https://outlook.office365.com/EWS/Exchange.asmx"
TIMEOUT = 30
# A CalendarView expands recurrences into instances, so a wide window on a busy
# calendar is a lot of items. The panel shows a few days; this is the ceiling
# that keeps one fetch from turning into a download.
MAX_EVENTS = 250

SOAP_NS = "http://schemas.xmlsoap.org/soap/envelope/"
MSG_NS = "http://schemas.microsoft.com/exchange/services/2006/messages"
TYPE_NS = "http://schemas.microsoft.com/exchange/services/2006/types"
NS = {"s": SOAP_NS, "m": MSG_NS, "t": TYPE_NS}

# Exchange2013 is the oldest version that every Microsoft 365 mailbox still
# answers, and nothing here needs anything newer.
REQUEST_VERSION = "Exchange2013"

FIELDS = (
    "item:Subject",
    "calendar:Start",
    "calendar:End",
    "calendar:IsAllDayEvent",
    "calendar:Location",
    "calendar:Organizer",
    "calendar:LegacyFreeBusyStatus",
    "calendar:IsCancelled",
    "calendar:AppointmentState",
    "calendar:UID",
)

# AppointmentState is a bitmask; this is the only bit worth reading. Exchange
# omits IsCancelled from an attendee's copy of a cancelled meeting - the copy
# that keeps sitting in the calendar - so that property alone would let every
# "Canceled:" and "Abgesagt:" through. Matching the subject prefix instead
# would work in exactly the two languages someone thought to test.
APPOINTMENT_CANCELED = 4


class CalendarError(Exception):
    """A failure that belongs to one mailbox's calendar. graph.py turns this
    into a warning rather than an empty pane: mail arriving without an agenda
    is worth showing, and saying why beats a blank column."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def _zone(timezone_name):
    try:
        return ZoneInfo(timezone_name)
    except (ZoneInfoNotFoundError, ValueError, TypeError):
        return timezone.utc


def _utc_stamp(value):
    """An EWS timestamp as an aware UTC datetime, or None."""
    text = str(value or "").strip()
    if not text:
        return None
    # EWS emits "2026-09-01T09:00:00Z"; tolerate an explicit offset too, and
    # trim fractional seconds Python's parser would refuse at odd lengths.
    text = re.sub(r"(\.\d{1,6})\d*", r"\1", text)
    text = text.replace("Z", "+00:00")
    try:
        stamp = datetime.fromisoformat(text)
    except ValueError:
        return None
    if stamp.tzinfo is None:
        stamp = stamp.replace(tzinfo=timezone.utc)
    return stamp.astimezone(timezone.utc)


def _local_iso(stamp, zone):
    """Local wall clock without a zone suffix - what Model.js expects."""
    if stamp is None:
        return ""
    return stamp.astimezone(zone).strftime("%Y-%m-%dT%H:%M:%S")


def _escape(text):
    return (
        str(text)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def _envelope(body):
    fields = "".join('<t:FieldURI FieldURI="%s"/>' % name for name in FIELDS)
    return (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="%s" xmlns:t="%s" xmlns:m="%s">'
        "<s:Header><t:RequestServerVersion Version=\"%s\"/></s:Header>"
        "<s:Body>%s</s:Body>"
        "</s:Envelope>"
    ) % (SOAP_NS, TYPE_NS, MSG_NS, REQUEST_VERSION, body % {"fields": fields})


def _find_item(start_utc, end_utc):
    return _envelope(
        '<m:FindItem Traversal="Shallow">'
        "<m:ItemShape>"
        "<t:BaseShape>IdOnly</t:BaseShape>"
        "<t:AdditionalProperties>%(fields)s</t:AdditionalProperties>"
        "</m:ItemShape>"
        '<m:CalendarView StartDate="' + start_utc + '" EndDate="' + end_utc + '" '
        'MaxEntriesReturned="' + str(MAX_EVENTS) + '"/>'
        "<m:ParentFolderIds>"
        '<t:DistinguishedFolderId Id="calendar"/>'
        "</m:ParentFolderIds>"
        "</m:FindItem>"
    )


def _post(token, payload):
    request = urllib.request.Request(
        ENDPOINT,
        data=payload.encode("utf-8"),
        method="POST",
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": 'text/xml; charset="utf-8"',
            "Accept": "text/xml",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        body = ""
        try:
            body = error.read().decode("utf-8", "replace")
        except (OSError, ValueError):
            body = ""
        if error.code in (401, 403):
            # The mail token is not an EWS token, and consent to one is not
            # consent to the other - so say which one is missing.
            raise CalendarError(
                "calendar_auth_required",
                "The calendar needs its own permission for this mailbox",
            )
        raise CalendarError(
            "calendar_failed",
            "Could not read the calendar: " + (_fault_text(body) or "HTTP %d" % error.code),
        )
    except (urllib.error.URLError, OSError) as error:
        raise CalendarError("calendar_failed", "Could not reach the calendar: %s" % error)


def _fault_text(body):
    """The human half of a SOAP fault, if that is what came back."""
    try:
        root = ElementTree.fromstring(body)
    except ElementTree.ParseError:
        return ""
    for path in ("s:Body/s:Fault/faultstring", ".//{%s}MessageText" % MSG_NS):
        found = root.find(path, NS) if path.startswith("s:") else root.find(path)
        if found is not None and (found.text or "").strip():
            return found.text.strip()
    return ""


def _is_cancelled(item):
    """Whether this is the leftover copy of a meeting that was called off."""
    if _text_of(item, "t:IsCancelled").lower() == "true":
        return True
    try:
        return bool(int(_text_of(item, "t:AppointmentState") or 0) & APPOINTMENT_CANCELED)
    except ValueError:
        return False


def _text_of(item, path):
    found = item.find(path, NS)
    return (found.text or "").strip() if found is not None else ""


def events(token, days, timezone_name, from_now=False):
    """The next `days` days of a mailbox's calendar, in the Graph event shape.

    Raises CalendarError, which the caller turns into a warning: an agenda
    that failed should not take the mail down with it.
    """
    zone = _zone(timezone_name)
    now = datetime.now(zone)
    start = now if from_now else now.replace(hour=0, minute=0, second=0, microsecond=0)
    end = (start + timedelta(days=max(1, int(days or 1)))).replace(
        hour=0, minute=0, second=0, microsecond=0
    )

    payload = _find_item(
        start.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        end.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    )
    body = _post(token, payload)

    try:
        root = ElementTree.fromstring(body)
    except ElementTree.ParseError:
        raise CalendarError("calendar_failed", "The calendar answered with something unreadable")

    message = root.find(".//m:FindItemResponseMessage", NS)
    if message is None:
        raise CalendarError("calendar_failed", _fault_text(body) or "The calendar did not answer")
    if (message.get("ResponseClass") or "") == "Error":
        raise CalendarError(
            "calendar_failed",
            "Could not read the calendar: " + (_text_of(message, "m:MessageText") or "unknown"),
        )

    collected = []
    for item in message.findall(".//t:CalendarItem", NS):
        if _is_cancelled(item):
            continue
        start_stamp = _utc_stamp(_text_of(item, "t:Start"))
        end_stamp = _utc_stamp(_text_of(item, "t:End"))
        if start_stamp is None:
            continue
        identifier = item.find("t:ItemId", NS)
        organizer = item.find("t:Organizer/t:Mailbox/t:Name", NS)
        collected.append(
            {
                "id": (identifier.get("Id") if identifier is not None else "") or "",
                "uid": _text_of(item, "t:UID"),
                "subject": _text_of(item, "t:Subject") or "(no subject)",
                "start": _local_iso(start_stamp, zone),
                "end": _local_iso(end_stamp or start_stamp, zone),
                "isAllDay": _text_of(item, "t:IsAllDayEvent").lower() == "true",
                "location": _text_of(item, "t:Location"),
                "organizer": (organizer.text or "").strip() if organizer is not None else "",
                # Deep links into OWA are built from Graph's own id, which EWS
                # never sees. The window hides the button when there is
                # nothing to open, the same as on the IMAP mail path.
                "webLink": "",
                "free": _text_of(item, "t:LegacyFreeBusyStatus").lower() == "free",
                # A join link lives in the body, which a CalendarView does not
                # fetch. Asking for every body to find a few links would cost
                # more than the button is worth.
                "joinUrl": "",
                "onlineProvider": "",
            }
        )

    collected.sort(key=lambda event: event["start"])
    truncated = len(collected) >= MAX_EVENTS
    return collected, truncated


# --------------------------------------------------------------------------
# one meeting, and answering it
#
# A CalendarView carries what a grid needs and nothing else. Who else was
# invited, what they said, what the organiser wrote and what you yourself
# answered are another request, made when somebody asks for one meeting -
# which is the only time any of it is worth fetching.
# --------------------------------------------------------------------------

DETAIL_FIELDS = (
    "item:Subject",
    "item:Body",
    "calendar:Start",
    "calendar:End",
    "calendar:IsAllDayEvent",
    "calendar:Location",
    "calendar:Organizer",
    "calendar:RequiredAttendees",
    "calendar:OptionalAttendees",
    "calendar:MyResponseType",
    "calendar:IsMeeting",
    "calendar:IsResponseRequested",
    "calendar:LegacyFreeBusyStatus",
    "calendar:IsCancelled",
    "calendar:AppointmentState",
    "calendar:UID",
)

# What EWS calls a response, in the words the rest of the plugin uses. EWS
# says "Accept" where Graph says "accepted", and one of its values is not a
# response at all: "Organizer" is how it tells you the meeting is yours.
RESPONSES = {
    "accept": "accepted",
    "tentative": "tentativelyAccepted",
    "decline": "declined",
    "noresponsereceived": "notResponded",
    "organizer": "organizer",
    "unknown": "none",
}

# The reply, as the element that carries it. Exchange has no "respond" verb:
# answering a meeting means creating the response item and sending it, which
# is also what puts it on the organiser's tally.
REPLY_ITEMS = {
    "accept": "AcceptItem",
    "tentative": "TentativelyAcceptItem",
    "decline": "DeclineItem",
}


def _bare_envelope(body):
    """An envelope for a request that names its own fields.

    `_envelope` substitutes the CalendarView field list into its body, which
    means a body containing a literal `%` - or one that wants a different set
    of fields - cannot go through it.
    """
    return (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="%s" xmlns:t="%s" xmlns:m="%s">'
        '<s:Header><t:RequestServerVersion Version="%s"/></s:Header>'
        "<s:Body>%s</s:Body>"
        "</s:Envelope>"
    ) % (SOAP_NS, TYPE_NS, MSG_NS, REQUEST_VERSION, body)


def _response_message(body, name):
    """One response message out of a SOAP body, or a CalendarError saying why
    there is none. Every EWS call answers in this shape."""
    try:
        root = ElementTree.fromstring(body)
    except ElementTree.ParseError:
        raise CalendarError("calendar_failed", "The calendar answered with something unreadable")
    message = root.find(".//m:%s" % name, NS)
    if message is None:
        raise CalendarError("calendar_failed", _fault_text(body) or "The calendar did not answer")
    if (message.get("ResponseClass") or "") == "Error":
        raise CalendarError(
            "calendar_failed",
            _text_of(message, "m:MessageText") or "The calendar refused that",
        )
    return message


def _attendees(item, path):
    """[{name, address, response}] for one of the two attendee lists."""
    found = []
    for attendee in item.findall("%s/t:Attendee" % path, NS):
        name = _text_of(attendee, "t:Mailbox/t:Name")
        address = _text_of(attendee, "t:Mailbox/t:EmailAddress")
        if not name and not address:
            continue
        response = _text_of(attendee, "t:ResponseType").lower()
        found.append({
            "name": name or address,
            "address": address,
            "response": RESPONSES.get(response, "none"),
        })
    return found


def details(token, item_id, timezone_name):
    """One meeting, in the shape graph.py's own `event` command answers with."""
    zone = _zone(timezone_name)
    fields = "".join('<t:FieldURI FieldURI="%s"/>' % name for name in DETAIL_FIELDS)
    body = _post(token, _bare_envelope(
        "<m:GetItem>"
        "<m:ItemShape>"
        "<t:BaseShape>IdOnly</t:BaseShape>"
        "<t:BodyType>Text</t:BodyType>"
        "<t:AdditionalProperties>" + fields + "</t:AdditionalProperties>"
        "</m:ItemShape>"
        "<m:ItemIds>"
        '<t:ItemId Id="' + _escape(item_id) + '"/>'
        "</m:ItemIds>"
        "</m:GetItem>"
    ))
    message = _response_message(body, "GetItemResponseMessage")
    item = message.find(".//t:CalendarItem", NS)
    if item is None:
        raise CalendarError("calendar_failed", "That meeting is no longer in the calendar")

    start_stamp = _utc_stamp(_text_of(item, "t:Start"))
    end_stamp = _utc_stamp(_text_of(item, "t:End"))
    mine = _text_of(item, "t:MyResponseType").lower()
    organizer_name = _text_of(item, "t:Organizer/t:Mailbox/t:Name")
    identifier = item.find("t:ItemId", NS)
    return {
        "id": (identifier.get("Id") if identifier is not None else "") or item_id,
        "changeKey": (identifier.get("ChangeKey") if identifier is not None else "") or "",
        "uid": _text_of(item, "t:UID"),
        "subject": _text_of(item, "t:Subject") or "(no subject)",
        "start": _local_iso(start_stamp, zone) if start_stamp else "",
        "end": _local_iso(end_stamp or start_stamp, zone) if start_stamp else "",
        "isAllDay": _text_of(item, "t:IsAllDayEvent").lower() == "true",
        "location": _text_of(item, "t:Location"),
        "organizer": organizer_name,
        "organizerAddress": _text_of(item, "t:Organizer/t:Mailbox/t:EmailAddress"),
        "body": _text_of(item, "t:Body"),
        "required": _attendees(item, "t:RequiredAttendees"),
        "optional": _attendees(item, "t:OptionalAttendees"),
        # "Organizer" is EWS saying the meeting is yours, which is why this is
        # read for both questions rather than guessed from the organiser's
        # name - two people can share a display name, and a mailbox does not
        # always know its own.
        "myResponse": RESPONSES.get(mine, "none"),
        "isOrganizer": mine == "organizer",
        "isMeeting": _text_of(item, "t:IsMeeting").lower() == "true",
        "responseRequested": _text_of(item, "t:IsResponseRequested").lower() != "false",
        "cancelled": _is_cancelled(item),
        "free": _text_of(item, "t:LegacyFreeBusyStatus").lower() == "free",
        # Both of these are Graph's, and EWS never sees either. The pane hides
        # what it has no address for, the same way it does on the agenda.
        "webLink": "",
        "joinUrl": "",
        "onlineProvider": "",
    }


def respond(token, item_id, reply, comment=""):
    """Answer a meeting request: accept, tentative or decline.

    The response is created and sent in one call - "SendAndSaveCopy" - because
    an answer nobody was told about is not an answer. Exchange updates the
    calendar item itself as a consequence of sending it, so there is nothing
    else to write.
    """
    element = REPLY_ITEMS.get(str(reply or "").lower())
    if not element:
        raise CalendarError("bad_reply", "That is not an answer a meeting takes")

    # The change key with it where we have one: it is what tells Exchange the
    # answer is to the meeting as it stands rather than to a version that has
    # since been rescheduled.
    current = details(token, item_id, "UTC")
    change_key = str(current.get("changeKey") or "")
    reference = '<t:ReferenceItemId Id="%s"%s/>' % (
        _escape(item_id),
        ' ChangeKey="%s"' % _escape(change_key) if change_key else "",
    )
    note = ('<t:Body BodyType="Text">%s</t:Body>' % _escape(comment)) if comment else ""

    body = _post(token, _bare_envelope(
        '<m:CreateItem MessageDisposition="SendAndSaveCopy">'
        "<m:Items>"
        "<t:" + element + ">" + note + reference + "</t:" + element + ">"
        "</m:Items>"
        "</m:CreateItem>"
    ))
    _response_message(body, "CreateItemResponseMessage")
    return {"response": RESPONSES[str(reply).lower()]}


def capabilities():
    """What a mailbox gains once its calendar is signed in. Focused/Other and
    OWA deep links stay absent: both are Graph's, not the mailbox's."""
    return {"calendar": True, "focused": False, "webLinks": False}

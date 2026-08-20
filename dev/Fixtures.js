.pragma library
.import "Model.js" as Model

// Synthetic calendars for the dev harness: a deliberately awkward few days
// with overlapping meetings, back-to-back blocks, all-day events and one that
// runs past midnight - the cases a timeline has to get right and that a real
// mailbox only offers on a bad week.

function at(dayOffset, hour, minute) {
  var d = new Date()
  d.setDate(d.getDate() + dayOffset)
  d.setHours(hour, minute || 0, 0, 0)
  // The helper hands out local ISO strings without a zone, which is what the
  // Graph query asks for, so the fixture matches.
  return isoLocal(d)
}

function isoLocal(d) {
  function pad(n) { return (n < 10 ? "0" : "") + n }
  return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
    + "T" + pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":00"
}

function event(id, subject, dayOffset, from, to, extra) {
  var e = {
    id: id,
    subject: subject,
    start: at(dayOffset, from[0], from[1]),
    end: at(dayOffset, to[0], to[1]),
    isAllDay: false,
    location: "",
    organizer: "",
    webLink: "https://example.invalid/" + id,
    free: false
  }
  for (var key in (extra || {})) e[key] = extra[key]
  return e
}

function workEvents() {
  return [
    event("w1", "Sprint refinement", 0, [9, 0], [10, 0],
          { location: "Microsoft Teams Meeting",
            joinUrl: "https://teams.microsoft.com/l/meetup-join/demo2",
            onlineProvider: "teams" }),
    // Three overlapping, to exercise column packing.
    event("w2", "Northwind - quarterly check-in", 0, [11, 0], [12, 0],
          { location: "Room 6.18", uid: "shared-invite" }),
    event("w3", "Supplier review", 0, [11, 30], [12, 30]),
    event("w4", "Partner sync", 0, [11, 45], [12, 15]),
    // Half of a pair: two people's lunch, at the same time, called the same
    // thing. Both belong on the grid, so the identity has to be the uid rather
    // than the subject.
    event("w5", "Lunch", 0, [12, 30], [13, 0], { free: true, uid: "work-lunch" }),
    event("w6", "Team weekly", 0, [16, 0], [17, 0],
          { location: "Microsoft Teams Meeting",
            joinUrl: "https://teams.microsoft.com/l/meetup-join/demo",
            onlineProvider: "teams" }),
    // Runs past the default 22:00 end of day.
    event("w7", "Quarterly review", 0, [20, 30], [23, 30]),
    // Starts before the default 07:00 start of day.
    event("w8", "Early standup", 1, [6, 30], [7, 0]),
    event("w9", "Admin and invoicing", 1, [15, 0], [16, 0],
          { joinUrl: "https://teams.microsoft.com/l/meetup-join/demo3", onlineProvider: "teams" }),
    event("w10", "Security compliance review", 2, [13, 0], [14, 30], { location: "Teams" }),
    { id: "w11", subject: "Offsite", start: at(2, 0, 0), end: at(3, 0, 0), isAllDay: true,
      location: "", organizer: "", webLink: "", free: false }
  ]
}

function personalEvents() {
  return [
    event("p1", "Partner working", 0, [8, 30], [14, 0]),
    event("p2", "Birthday - Robin", 0, [15, 15], [21, 30], { free: true }),
    event("p3", "Swimming lesson - Sam", 1, [18, 30], [18, 45]),
    // One invitation, two mailboxes: same iCalUId, so this merges with w2 and
    // the block gets a rail in both colours.
    event("p4", "Northwind - quarterly check-in", 0, [11, 0], [12, 0], { uid: "shared-invite" }),
    // The other half of the pair: identical to w5 in every way a person could
    // see, and a different meeting.
    event("p6", "Lunch", 0, [12, 30], [13, 0], { free: true, uid: "personal-lunch" }),
    { id: "p5", subject: "Birthday - Alex", start: at(1, 0, 0), end: at(2, 0, 0), isAllDay: true,
      location: "", organizer: "", webLink: "", free: false }
  ]
}

// Views shaped the way Service builds them, so the harness runs the real
// merge rather than a hand-written result.
function views() {
  return [
    { alias: "work", short: "WRK", color: "#7aa2f7", ok: true, loaded: true, busy: false,
      write: true, username: "you@example.com", displayName: "Example User", errorCode: "", errorMessage: "",
      mail: [], unreadCount: 0, events: workEvents(), warnings: [], config: {} },
    { alias: "personal", short: "PRS", color: "#bb9af7", ok: true, loaded: true, busy: false,
      write: false, username: "you@example.net", displayName: "Example User", errorCode: "", errorMessage: "",
      mail: [], unreadCount: 0, events: personalEvents(), warnings: [], config: {} }
  ]
}

function agenda() {
  return Model.mergeEvents(views(), new Date(), 40, true)
}

// One of every way a mailbox can go wrong, which a real account will not do to
// order: one that answered without its calendar, one that failed outright, one
// still waiting to be signed in (which is not a problem and must not be listed
// as one), and one that is fine.
function brokenViews() {
  var broken = views()
  broken[0].warnings = [{ scope: "calendar", message: "Access is denied. Check credentials and try again." }]
  return broken.concat([
    { alias: "family", short: "FAM", color: "#7dcfff", ok: false, loaded: true, busy: false,
      write: false, username: "", displayName: "", errorCode: "throttled",
      errorMessage: "Too many requests. Try again in a moment.",
      mail: [], unreadCount: 0, events: [], warnings: [], config: {} },
    { alias: "new", short: "NEW", color: "#e0af68", ok: false, loaded: true, busy: false,
      write: false, username: "", displayName: "", errorCode: "auth_required",
      errorMessage: "Not signed in",
      mail: [], unreadCount: 0, events: [], warnings: [], config: {} }
  ])
}

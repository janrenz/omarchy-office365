#!/usr/bin/env node
// Unit tests for the pure parts of Model.js - the timeline packing in
// particular, where getting the columns wrong is easy to do and hard to see.
//
//   node dev/test-model.js
//
// Model.js is a QML library, so it is loaded by evaluating it here. A handful
// of its functions reach for Qt.locale(); those are stubbed rather than
// exercised, since date formatting is the shell's job, not this file's.

// Pinned before the first Date exists. The grid is laid out in local time
// throughout, so these tests need a zone of their own rather than whichever one
// the machine running them happens to be in - and one whose clocks change twice
// a year, because that is where the arithmetic gets interesting.
process.env.TZ = "Europe/Amsterdam"

const fs = require("fs")
const path = require("path")
const vm = require("vm")

const source = fs.readFileSync(path.join(__dirname, "..", "src", "Model.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "")

const Model = vm.createContext({
  Qt: { locale: () => "en_GB" },
  Date, Math, String, Number, JSON, isNaN, isFinite, parseInt, parseFloat, console
})
vm.runInContext(source, Model)

let failures = 0
let checks = 0

function check(name, actual, expected) {
  checks += 1
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) {
    failures += 1
    console.log(`  FAIL  ${name}\n        expected ${e}\n        got      ${a}`)
  }
}

function group(name, body) {
  console.log(name)
  body()
}

// A fixed "today" so nothing depends on when the tests are run.
const TODAY = new Date(2026, 7, 20, 12, 0, 0)

function iso(dayOffset, hour, minute) {
  const d = new Date(TODAY.getFullYear(), TODAY.getMonth(), TODAY.getDate() + dayOffset, hour, minute || 0)
  const p = (n) => (n < 10 ? "0" : "") + n
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}:00`
}

function ev(id, dayOffset, from, to, extra) {
  return Object.assign({
    id, subject: id, start: iso(dayOffset, from[0], from[1]), end: iso(dayOffset, to[0], to[1]),
    isAllDay: false, location: "", organizer: "", webLink: "", free: false
  }, extra || {})
}

function view(alias, short, color, events) {
  return { alias, short, color, events }
}

function grid(views, options) {
  return Model.dayGrid(views, TODAY, Object.assign({ days: 1 }, options || {}))
}

function placement(day) {
  return day.timed.map((e) => `${e.id}:${e.column}/${e.columns}x${e.span}`)
}

group("packDay - columns", () => {
  // Nothing overlapping: everyone gets the full width.
  let g = grid([view("w", "W", "#fff", [
    ev("a", 0, [9, 0], [10, 0]),
    ev("b", 0, [10, 0], [11, 0])
  ])])
  check("back to back share column 0", placement(g.days[0]), ["a:0/1x1", "b:0/1x1"])

  // Two overlapping: side by side.
  g = grid([view("w", "W", "#fff", [
    ev("a", 0, [9, 0], [10, 30]),
    ev("b", 0, [10, 0], [11, 0])
  ])])
  check("overlap splits in two", placement(g.days[0]), ["a:0/2x1", "b:1/2x1"])

  // Three overlapping at once - the 11:00 pile-up from the fixtures.
  g = grid([view("w", "W", "#fff", [
    ev("a", 0, [11, 0], [12, 0]),
    ev("b", 0, [11, 30], [12, 30]),
    ev("c", 0, [11, 45], [12, 15])
  ])])
  check("three-way overlap", placement(g.days[0]), ["a:0/3x1", "b:1/3x1", "c:2/3x1"])

  // A long meeting with two short ones inside it, one after the other. The
  // shorts share a column because they do not overlap each other.
  g = grid([view("w", "W", "#fff", [
    ev("long", 0, [9, 0], [12, 0]),
    ev("s1", 0, [9, 30], [10, 0]),
    ev("s2", 0, [10, 30], [11, 0])
  ])])
  check("shorts reuse the freed column", placement(g.days[0]), ["long:0/2x1", "s1:1/2x1", "s2:1/2x1"])

  // Expand-right: b ends before c starts, so b can take c's column too.
  g = grid([view("w", "W", "#fff", [
    ev("a", 0, [9, 0], [12, 0]),
    ev("b", 0, [9, 30], [10, 0]),
    ev("c", 0, [10, 30], [11, 0]),
    ev("d", 0, [10, 30], [11, 0])
  ])])
  check("a block grows into free columns", placement(g.days[0]), ["a:0/3x1", "b:1/3x2", "c:1/3x1", "d:2/3x1"])

  // Separate clusters are packed independently, so a morning pile-up does not
  // narrow the afternoon.
  g = grid([view("w", "W", "#fff", [
    ev("a", 0, [9, 0], [10, 0]),
    ev("b", 0, [9, 30], [10, 30]),
    ev("c", 0, [14, 0], [15, 0])
  ])])
  check("clusters are independent", placement(g.days[0]), ["a:0/2x1", "b:1/2x1", "c:0/1x1"])
})

group("dayGrid - days", () => {
  const g = grid([view("w", "W", "#fff", [
    ev("today", 0, [9, 0], [10, 0]),
    ev("tomorrow", 1, [9, 0], [10, 0]),
    ev("later", 5, [9, 0], [10, 0])
  ])], { days: 3 })
  check("one slot per day, empty or not", g.days.length, 3)
  check("today is flagged", g.days.map((d) => d.isToday), [true, false, false])
  check("events land in their own day", g.days.map((d) => d.timed.map((e) => e.id)), [["today"], ["tomorrow"], []])
})

group("dayGrid - the visible window", () => {
  const g = grid([view("w", "W", "#fff", [
    ev("early", 0, [6, 0], [6, 30]),
    ev("inside", 0, [9, 0], [10, 0]),
    ev("late", 0, [23, 0], [23, 30])
  ])], { startMinutes: 7 * 60, endMinutes: 22 * 60 })
  check("out-of-window events are counted, not drawn", placement(g.days[0]), ["inside:0/1x1"])
  check("earlier count", g.days[0].earlier, 1)
  check("later count", g.days[0].later, 1)
  // What the window would have to be to hide nothing - the hidden ones are
  // exactly what this has to account for.
  check("the window that would fit everything", [g.fits.startMinutes, g.fits.endMinutes],
    [6 * 60, 23 * 60 + 30])

  // A meeting straddling the edge is drawn, and widens what would fit.
  const straddle = grid([view("w", "W", "#fff", [ev("dawn", 0, [6, 0], [8, 0])])])
  check("straddling the edge still draws", placement(straddle.days[0]), ["dawn:0/1x1"])
  check("fits opens up to include it", straddle.fits.startMinutes, 6 * 60)
})

group("dayGrid - all day", () => {
  const g = grid([view("w", "W", "#fff", [
    { id: "offsite", subject: "Offsite", start: iso(0, 0, 0), end: iso(2, 0, 0), isAllDay: true,
      location: "", organizer: "", webLink: "", free: false },
    ev("meeting", 0, [9, 0], [10, 0])
  ])], { days: 3 })
  check("all-day spans every day it touches", g.days.map((d) => d.allDay.map((e) => e.id)),
    [["offsite"], ["offsite"], []])
  check("and stays out of the grid", g.days.map((d) => d.timed.map((e) => e.id)), [["meeting"], [], []])

  // Two overlapping all-day events stack; the second gets its own row.
  const stacked = grid([view("w", "W", "#fff", [
    { id: "one", subject: "One", start: iso(0, 0, 0), end: iso(1, 0, 0), isAllDay: true, location: "", organizer: "", webLink: "", free: false },
    { id: "two", subject: "Two", start: iso(0, 0, 0), end: iso(1, 0, 0), isAllDay: true, location: "", organizer: "", webLink: "", free: false }
  ])])
  check("overlapping all-day bars stack", stacked.days[0].allDay.map((e) => e.row), [0, 1])
})

group("dayGrid - across midnight", () => {
  const g = Model.dayGrid([view("w", "W", "#fff", [
    { id: "night", subject: "Night", start: iso(0, 22, 0), end: iso(1, 1, 0), isAllDay: false,
      location: "", organizer: "", webLink: "", free: false }
  ])], TODAY, { days: 2, startMinutes: 0, endMinutes: 24 * 60 })
  check("appears on both days", g.days.map((d) => d.timed.map((e) => e.id)), [["night"], ["night"]])
  check("clipped to each day", g.days.map((d) => [d.timed[0].startMinutes, d.timed[0].endMinutes]),
    [[22 * 60, 24 * 60], [0, 60]])
  check("and knows it is cut", g.days.map((d) => [d.timed[0].continuesBefore, d.timed[0].continuesAfter]),
    [[false, true], [true, false]])
})

group("dayGrid - past and present", () => {
  const g = grid([view("w", "W", "#fff", [
    ev("done", 0, [9, 0], [10, 0]),
    ev("now", 0, [11, 30], [12, 30]),
    ev("soon", 0, [14, 0], [15, 0])
  ])])
  check("finished meetings are kept, flagged past", g.days[0].timed.map((e) => e.past), [true, false, false])
  check("the one happening now is flagged", g.days[0].timed.map((e) => e.current), [false, true, false])
})

group("dayGrid - two mailboxes", () => {
  // The same invitation in two mailboxes: different message ids, one iCalUId.
  const invite = (id) => ev(id, 0, [11, 0], [12, 0], { uid: "shared-uid", subject: "Sprint review" })
  const g = grid([
    view("work", "WRK", "#blue", [invite("work-copy")]),
    view("personal", "P", "#magenta", [invite("personal-copy")])
  ])
  check("the same meeting merges", g.days[0].timed.map((e) => e.id), ["work-copy"])
  check("keeping both colours", g.days[0].timed[0].colors, ["#blue", "#magenta"])

  const apart = Model.dayGrid([
    view("work", "WRK", "#blue", [invite("a")]),
    view("personal", "P", "#magenta", [invite("b")])
  ], TODAY, { days: 1, dedupe: false })
  check("unless dedupe is off", placement(apart.days[0]), ["a:0/2x1", "b:1/2x1"])

  // Two people's lunch, at the same time, called the same thing. Matching on
  // subject and start alone would hide one of them.
  const lunch = grid([
    view("work", "WRK", "#blue", [ev("lunch-work", 0, [12, 0], [13, 0], { uid: "one" })]),
    view("personal", "P", "#magenta", [ev("lunch-work", 0, [12, 0], [13, 0], { uid: "two" })])
  ])
  check("different meetings that look alike both stay",
        lunch.days[0].timed.map((e) => e.uid), ["one", "two"])

  // A mailbox that answered without an iCalUId has nothing to match on, and a
  // duplicate drawn twice beats a meeting quietly removed.
  const noUid = grid([
    view("work", "WRK", "#blue", [ev("m", 0, [11, 0], [12, 0])]),
    view("personal", "P", "#magenta", [ev("m", 0, [11, 0], [12, 0])])
  ])
  check("no identity means no merging", noUid.days[0].timed.length, 2)

  // Every occurrence of a series carries the series' uid, so the uid alone
  // would fold a daily standup into Monday.
  const series = Model.dayGrid([view("work", "WRK", "#blue", [
    ev("mon", 0, [9, 0], [9, 15], { uid: "standup" }),
    ev("tue", 1, [9, 0], [9, 15], { uid: "standup" })
  ])], TODAY, { days: 2 })
  check("a recurring series keeps every occurrence",
        series.days.map((d) => d.timed.length), [1, 1])
})

// A grid is labelled with wall-clock hours, so a block's position has to be
// read off the same clock. Elapsed milliseconds since midnight stop agreeing
// with it on the two days a year the clocks change.
group("daylight saving", () => {
  const at = (y, m, d, h, min) => {
    const p = (n) => (n < 10 ? "0" : "") + n
    return `${y}-${p(m)}-${p(d)}T${p(h)}:${p(min)}:00`
  }
  const dayOf = (y, m, d, events) =>
    Model.dayGrid([{ alias: "w", short: "W", color: "#fff", events }],
                  new Date(y, m - 1, d, 12, 0, 0), { days: 1, startMinutes: 0, endMinutes: 1440 })

  // Europe/Amsterdam springs forward at 02:00 on 2026-03-29: a 23-hour day.
  const spring = dayOf(2026, 3, 29, [{
    id: "s", subject: "Standup", start: at(2026, 3, 29, 9, 0), end: at(2026, 3, 29, 10, 0),
    isAllDay: false, location: "", organizer: "", webLink: "", free: false
  }])
  check("09:00 on the short day is drawn at 09:00",
        [spring.days[0].timed[0].startMinutes, spring.days[0].timed[0].endMinutes], [540, 600])

  // And falls back at 03:00 on 2026-10-25: a 25-hour day.
  const autumn = dayOf(2026, 10, 25, [{
    id: "a", subject: "Brunch", start: at(2026, 10, 25, 11, 0), end: at(2026, 10, 25, 12, 30),
    isAllDay: false, location: "", organizer: "", webLink: "", free: false
  }])
  check("11:00 on the long day is drawn at 11:00",
        [autumn.days[0].timed[0].startMinutes, autumn.days[0].timed[0].endMinutes], [660, 750])

  // The day boundary is the next midnight, not 24 hours on, so the day after a
  // change still holds its own events rather than borrowing the neighbour's.
  const across = Model.dayGrid([{ alias: "w", short: "W", color: "#fff", events: [
    { id: "sat", subject: "Sat", start: at(2026, 10, 24, 23, 30), end: at(2026, 10, 25, 0, 30),
      isAllDay: false, location: "", organizer: "", webLink: "", free: false }
  ] }], new Date(2026, 9, 24, 12, 0, 0), { days: 2, startMinutes: 0, endMinutes: 1440 })
  check("a meeting over midnight splits at midnight",
        across.days.map((d) => d.timed.map((e) => [e.startMinutes, e.endMinutes])),
        [[[1410, 1440]], [[0, 30]]])
})

group("clock settings", () => {
  check("07:00", Model.minutesFromClock("07:00", -1), 420)
  check("7:00", Model.minutesFromClock("7:00", -1), 420)
  check("bare hour", Model.minutesFromClock("7", -1), 420)
  check("midnight end", Model.minutesFromClock("24:00", -1), 1440)
  check("nonsense falls back", Model.minutesFromClock("elevenish", -1), -1)
  check("out of range falls back", Model.minutesFromClock("99:99", -1), -1)
  check("empty falls back", Model.minutesFromClock("", -1), -1)
  check("round trip", Model.clockFromMinutes(Model.minutesFromClock("21:45", 0)), "21:45")
})

// omarchy-launch-or-focus evaluates its command as shell text, so what goes in
// has to survive being taken apart again.
group("launch commands", () => {
  const cmd = (openCommand, url) => Model.shellCommand(Model.openArgv(openCommand, url))

  check("the default browser", cmd("", "https://x/y"), "xdg-open https://x/y")
  check("an argument with a space keeps its boundary",
        cmd(["microsoft-edge", "--profile-directory=Profile 1", "{url}"], "https://x/y"),
        "microsoft-edge '--profile-directory=Profile 1' https://x/y")
  check("a URL with shell characters is not reinterpreted",
        cmd(["firefox"], "https://x/y?a=1&b=2;rm"),
        "firefox 'https://x/y?a=1&b=2;rm'")
  check("a quote in a value closes and reopens",
        cmd(["app", "it's"], "https://x"),
        "app 'it'\\''s' https://x")
  check("plain words are left alone",
        cmd(["chromium", "--new-window"], "https://x"),
        "chromium --new-window https://x")

  // The v1 string form, which the settings form has to round-trip rather than
  // normalise away.
  check("a string command still runs",
        cmd("firefox --new-tab {url}", "https://x"),
        "firefox --new-tab https://x")
  check("a string command survives being read back",
        Model.commandArgv("firefox --new-tab {url}"),
        ["firefox", "--new-tab", "{url}"])
  check("an array command survives being read back",
        Model.commandArgv(["firefox", "{url}"]), ["firefox", "{url}"])
  check("nothing configured stays nothing", Model.commandArgv(""), [])
})

// A mailbox that answered without its calendar is not a mailbox with an empty
// calendar, and the panel has to be able to tell the difference.
group("partial failures", () => {
  const views = [
    { alias: "work", short: "WRK", color: "#blue", ok: true,
      warnings: [{ scope: "calendar", message: "Access is denied" }] },
    { alias: "personal", short: "P", color: "#magenta", ok: true, warnings: [] },
    { alias: "dead", short: "D", color: "#red", ok: false,
      warnings: [{ scope: "mail", message: "never shown, the account failed outright" }] }
  ]
  const found = Model.collectWarnings(views)
  check("only mailboxes that answered", found.map((w) => w.short), ["WRK"])
  check("carrying what failed and why", [found[0].scope, found[0].message],
        ["calendar", "Access is denied"])
  check("nothing wrong means nothing shown", Model.collectWarnings([views[1]]), [])
})

// "no unread mail" is a claim, and it must never rest on a request that failed.
group("how many are unread", () => {
  const known = { unreadCount: 3, unreadKnown: true }
  const floored = { unreadCount: 3, unreadKnown: false }
  const blind = { unreadCount: 0, unreadKnown: false }
  const empty = { unreadCount: 0, unreadKnown: true }

  check("the inbox's own number", Model.unreadLabel(known), "3")
  check("a floor is marked as one", Model.unreadLabel(floored), "3+")
  check("nothing to go on", Model.unreadLabel(blind), "?")
  check("an empty inbox still says so", Model.unreadSummary(empty), "no unread mail")
  check("and never on a failed count", Model.unreadSummary(blind), "unread count unavailable")
  check("phrased for a tooltip", Model.unreadSummary(floored), "3+ unread")

  // A mailbox from before this existed, or one that answered normally.
  check("a view with no flag is trusted",
        Model.unreadLabel({ unreadCount: 2 }), "2")
})

// A bar that lights up for an unread message from three weeks ago is a bar
// that is always lit, and one that is always lit says nothing when mail
// actually arrives. So "new" is what the list shows, and the backlog behind it
// is counted separately.
group("new mail against the backlog", () => {
  // Newest first, and dated so the cut falls where the test wants it.
  const msg = (id, day, read) => ({
    id: id, subject: "re: " + id, from: "someone", fromAddress: "a@b.c",
    received: `2026-08-${String(day).padStart(2, "0")}T09:00:00Z`,
    preview: "", webLink: "", important: false, hasAttachments: false,
    read: read, focused: true
  })
  const box = (alias, mail, unread, known) => ({
    alias: alias, short: alias.toUpperCase(), color: "#fff", ok: true,
    mail: mail, unreadCount: unread, unreadKnown: known !== false, write: true,
    events: [], folders: [], warnings: []
  })

  // Three newer messages sit on top of the unread one from the 1st, so with a
  // list of three it is out of view: backlog, not news.
  const buried = [box("work", [
    msg("d4", 4, true), msg("d3", 3, true), msg("d2", 2, true), msg("old", 1, false)
  ], 1)]
  check("an unread message the list cannot reach is not new",
        Model.freshUnread(buried, 3, {}).total, 0)
  check("and the bar phrase says only that it is unread",
        Model.unreadSummary(buried[0], Model.freshUnread(buried, 3, {})), "1 unread")

  // The same mailbox, one message having just landed unread.
  const arrived = [box("work", [
    msg("new", 5, false), msg("d4", 4, true), msg("d3", 3, true), msg("old", 1, false)
  ], 2)]
  const fresh = Model.freshUnread(arrived, 3, {})
  check("what is in the list is", fresh.total, 1)
  check("with the backlog kept apart from it",
        Model.unreadSummary(arrived[0], fresh), "1 new · 2 unread")

  // Nothing behind them: two numbers where one is the whole story.
  const allNew = [box("work", [msg("a", 5, false), msg("b", 4, false)], 2)]
  check("no backlog, so no second number",
        Model.unreadSummary(allNew[0], Model.freshUnread(allNew, 3, {})), "2 new")

  // A floor is still a floor, and the new count does not make it a count.
  const floored = [box("work", [msg("a", 5, false)], 1, false)]
  check("a floor stays marked as one",
        Model.unreadSummary(floored[0], Model.freshUnread(floored, 3, {})), "1 new · 1+ unread")

  // Marking it read is the point of marking it read: the tint has to go out
  // before the server agrees, or the bar argues with the panel for a round.
  check("an optimistic read drops it at once",
        Model.freshUnread(arrived, 3, { read: { "new": true } }).total, 0)
  check("as does deleting it",
        Model.freshUnread(allNew, 3, { deleted: { "a": true } }).total, 1)
  // Taking a row out makes room, and the backlog message that slides up into
  // the list is new by this definition. That is the definition working rather
  // than failing: it is in the list now, so opening the panel shows what the
  // lit icon is about.
  check("and the backlog slides up into the room it left",
        Model.freshUnread(arrived, 3, { deleted: { "new": true } }).total, 1)

  // Each mailbox on its own, because the tooltip names them one per line.
  const both = [
    box("work", [msg("w1", 5, false)], 4),
    box("home", [msg("h1", 4, true), msg("h2", 3, true)], 0)
  ]
  const split = Model.freshUnread(both, 5, {})
  check("counted per mailbox", [split.total, split.byAlias.work, split.byAlias.home || 0], [1, 1, 0])
  check("and one mailbox's news is not the other's",
        [Model.unreadSummary(both[0], split), Model.unreadSummary(both[1], split)],
        ["1 new · 4 unread", "no unread mail"])

  // The panel's own filters must not be able to redefine what arrived.
  // Filtering to unread pulls the backlog into view; the bar must not read
  // that as four things landing at once.
  const filtered = Model.mergeMail(buried, true, 3, {}, false)
  check("the unread filter does show the backlog", filtered.map((r) => r.id), ["old"])
  check("but it is still not new", Model.freshUnread(buried, 3, {}).total, 0)

  // Without a fresh count there is no claim to make about it, and the phrase
  // falls back to what it always said.
  check("no list, no claim", Model.unreadSummary(box("work", [], 7)), "7 unread")
})

group("the list view still works", () => {
  const merged = Model.mergeEvents([view("w", "W", "#fff", [
    ev("done", 0, [9, 0], [10, 0]),
    ev("soon", 0, [14, 0], [15, 0])
  ])], TODAY, 20, true)
  check("finished meetings stay dropped there", merged.groups[0].events.map((e) => e.id), ["soon"])
})

// Anything the shell draws for us cannot be pinned to Text.PlainText from here,
// so it has to arrive already unable to look like markup. Qt switches a string
// to rich text as soon as it finds a `<` that could open a tag, and rich text
// fetches what it is told to.
group("text handed to the shell", () => {
  const attack = '<img src="http://tracker.example/pixel.png">Invoice'
  check("a tag cannot survive", Model.plainText(attack).indexOf("<"), -1)
  check("the words do", Model.plainText(attack).indexOf("Invoice") >= 0, true)
  check("a closing tag cannot either",
        Model.plainText("</b><a href='http://x'>x</a>").indexOf("<"), -1)
  check("nor an html document",
        Model.plainText("<!DOCTYPE html><html><body>hi").indexOf("<"), -1)
  check("ordinary text is untouched",
        Model.plainText("Re: sprint 24 scope"), "Re: sprint 24 scope")
  check("an address keeps its name",
        Model.plainText("Priya Raman kees@example.com>"), "Priya Raman kees@example.com>")
  check("nothing is empty, not undefined", Model.plainText(undefined), "")
})

// The optimistic overlay is shared by every host now, and retired one
// mailbox at a time - because one mailbox at a time is what a fetch answers.
// Judging another mailbox's override against a fetch that could never have
// carried its message would retire the lot on the first answer to arrive.
group("retiring the optimistic overlay", () => {
  const fetched = (alias, mail) => ({ ok: true, alias, mail })
  const msg = (id, read) => ({ id, read })

  check("an override the server has caught up with goes",
        Model.pruneOwnedOverrides(
          fetched("work", [msg("a", true)]),
          { read: { a: true }, deleted: {} }, { a: "work" }),
        { overrides: { read: {}, flagged: {}, deleted: {} }, owner: {} })

  check("one it has not stays",
        Model.pruneOwnedOverrides(
          fetched("work", [msg("a", false)]),
          { read: { a: true }, deleted: {} }, { a: "work" }),
        null)

  // The message just marked read fell out of the unread query. Dropping its
  // flag here would let the pinned row read as unread again.
  check("a message the fetch no longer carries keeps its flag",
        Model.pruneOwnedOverrides(
          fetched("work", [msg("b", false)]),
          { read: { a: true }, deleted: {} }, { a: "work" }),
        null)

  check("another mailbox's override is not this fetch's business",
        Model.pruneOwnedOverrides(
          fetched("work", [msg("b", false)]),
          { read: { a: true }, deleted: {} }, { a: "personal" }),
        null)

  // A deleted row is confirmed by the server no longer returning it, which is
  // the opposite way round from a read flag.
  check("a deletion the server has taken up goes",
        Model.pruneOwnedOverrides(
          fetched("work", [msg("b", false)]),
          { read: {}, deleted: { a: true } }, { a: "work" }),
        { overrides: { read: {}, flagged: {}, deleted: {} }, owner: {} })

  check("one still being returned stays",
        Model.pruneOwnedOverrides(
          fetched("work", [msg("a", false)]),
          { read: {}, deleted: { a: true } }, { a: "work" }),
        null)

  check("a mailbox that failed prunes nothing",
        Model.pruneOwnedOverrides(
          { ok: false, alias: "work", mail: [] },
          { read: { a: true }, deleted: {} }, { a: "work" }),
        null)

  check("what is kept keeps its owner",
        Model.pruneOwnedOverrides(
          fetched("work", [msg("a", true), msg("b", false)]),
          { read: { a: true, b: true }, deleted: {} }, { a: "work", b: "work" }),
        { overrides: { read: { b: true }, flagged: {}, deleted: {} }, owner: { b: "work" } })
})

// The follow-up flag rides the same optimistic overlay the read mark does, so
// flagging a row in the window flags it in the bar before the helper has
// answered - and puts it back if the helper refuses.
group("the follow-up flag", () => {
  const view = (alias, mail) => ({ alias, short: alias[0].toUpperCase(), color: "#fff",
                                   write: true, mail })
  const msg = (id, flagged) => ({ id, subject: id, from: "A", fromAddress: "a@example.com",
                                  received: "2026-09-01T09:00:00Z", preview: "", read: true,
                                  flagged })
  const flagsOf = (rows) => rows.map((r) => [r.id, r.flagged])

  const rows = [view("work", [msg("a", true), msg("b", false)])]

  check("what the server says, with no overlay",
        flagsOf(Model.mergeMail(rows, false, 0, {}, false)),
        [["a", true], ["b", false]])

  check("an overlay wins over the server",
        flagsOf(Model.mergeMail(rows, false, 0, { flagged: { b: true } }, false)),
        [["a", true], ["b", true]])

  check("and can clear one the server still calls flagged",
        flagsOf(Model.mergeMail(rows, false, 0, { flagged: { a: false } }, false)),
        [["a", false], ["b", false]])

  // Retiring works the way the read mark's does: only once the fetch agrees.
  check("an override the fetch has caught up with goes",
        Model.pruneOwnedOverrides(
          { ok: true, alias: "work", mail: [msg("a", true)] },
          { read: {}, flagged: { a: true }, deleted: {} }, { a: "work" }),
        { overrides: { read: {}, flagged: {}, deleted: {} }, owner: {} })

  check("one it still disagrees with stays",
        Model.pruneOwnedOverrides(
          { ok: true, alias: "work", mail: [msg("a", false)] },
          { read: {}, flagged: { a: true }, deleted: {} }, { a: "work" }),
        null)

  // A collapsed conversation stands for every message in it, so one flag in
  // there is a flag on the row.
  const thread = [view("work", [
    { ...msg("a", false), thread: "t1" },
    { ...msg("b", true), thread: "t1" }
  ])]
  check("a thread wears any flag inside it",
        Model.groupThreads(Model.mergeMailAll(thread, false, {}, false), 0, {})
             .map((g) => g.flagged),
        [true])
})

group("where a message can be filed", () => {
  // Two mailboxes, because the answer has to come from one of them: a folder
  // id names a folder in a single mailbox, and Graph cannot move a message
  // across mailboxes at all.
  const views = [
    { alias: "work", color: "#7aa2f7", short: "W", folders: [
      { id: "F-INBOX", name: "Inbox", depth: 0, unread: 3, total: 9, isInbox: true },
      { id: "F-ARCHIVE", name: "Archive", depth: 0, unread: 0, total: 40 },
      { id: "F-2024", name: "2024", depth: 1, unread: 0, total: 12 }
    ] },
    { alias: "home", color: "#9ece6a", short: "H", folders: [
      { id: "H-INBOX", name: "Inbox", depth: 0, unread: 1, total: 4, isInbox: true },
      { id: "H-BILLS", name: "Bills", depth: 0, unread: 0, total: 7 }
    ] }
  ]

  const names = (alias, current) =>
    Model.moveTargets(views, alias, current).map(row => row.name)

  check("only the mailbox being filed out of",
        names("work", "F-ARCHIVE"), ["Inbox", "2024"])

  // "inbox" is the well-known name the fetch defaults to; the tree knows the
  // same folder as F-INBOX, and offering it would be a row that does nothing.
  check("the inbox is dropped under either of its names",
        names("work", "inbox"), ["Archive", "2024"])

  check("and under its real id too",
        names("work", "F-INBOX"), ["Archive", "2024"])

  check("the other mailbox has its own answer",
        names("home", "inbox"), ["Bills"])

  check("a mailbox nobody knows has nowhere to put anything",
        names("nobody", "inbox"), [])

  check("a mailbox whose folders have not arrived yet has nothing to offer",
        Model.moveTargets([{ alias: "work", folders: [] }], "work", "inbox"), [])

  // The tree draws these, so they have to arrive shaped the way it reads them.
  check("rows carry what the tree draws",
        Model.moveTargets(views, "work", "inbox")[1],
        { kind: "folder", key: "work:F-2024", alias: "work", id: "F-2024",
          name: "2024", unread: 0, total: 12, depth: 1, color: "#7aa2f7",
          short: "W", isInbox: false, selected: false, placeholder: false })
})

group("folderRows - one highlight at a time", () => {
  const box = (alias, folders) => ({
    alias, short: alias.substring(0, 3).toUpperCase(), color: "#fff", username: alias + "@x",
    unreadCount: 0, folderName: "", folders
  })
  const tree = (alias) => [
    { id: alias + "-inbox", name: "Inbox", isInbox: true, unread: 2, total: 9, depth: 0 },
    { id: alias + "-archive", name: "Archive", isInbox: false, unread: 0, total: 4, depth: 0 }
  ]
  const views = [box("work", tree("work")), box("fwu", tree("fwu"))]
  const lit = (rows) => rows.filter((r) => r.selected).map((r) => r.alias + ":" + r.name)

  // Both mailboxes are on their inbox at all times; only one of them is where
  // you are, and two lit rows read as two things open at once.
  check("only the mailbox being read is lit",
        lit(Model.folderRows(views, {}, "work")), ["work:Inbox"])

  check("and it follows what was picked, folder and mailbox alike",
        lit(Model.folderRows(views, { fwu: "fwu-archive" }, "fwu")), ["fwu:Archive"])

  // folderNameFor asks what each mailbox is on, which is a different question.
  check("without one named, each mailbox shows its own",
        lit(Model.folderRows(views, { fwu: "fwu-archive" })), ["work:Inbox", "fwu:Archive"])

  check("a mailbox whose folders have not arrived is lit the same way",
        lit(Model.folderRows([box("work", []), box("fwu", [])], {}, "fwu")), ["fwu:Inbox"])
})

group("folderMoveTargets - where a folder can go", () => {
  const view = {
    alias: "work", short: "WRK", color: "#fff", username: "you@x", unreadCount: 0,
    folderName: "", folders: [
      { id: "inbox-id", name: "Inbox", isInbox: true, parentId: "", depth: 0, unread: 0, total: 0 },
      { id: "arch", name: "Archive", isInbox: false, parentId: "", depth: 0, unread: 0, total: 0 },
      { id: "arch-24", name: "2024", isInbox: false, parentId: "arch", depth: 1, unread: 0, total: 0 },
      { id: "arch-24-q1", name: "Q1", isInbox: false, parentId: "arch-24", depth: 2, unread: 0, total: 0 },
      { id: "back", name: "Backup", isInbox: false, parentId: "", depth: 0, unread: 0, total: 0 }
    ]
  }
  const names = (folderId) =>
    Model.folderMoveTargets([view], "work", folderId).map((r) => r.name)

  // A folder cannot be its own parent, and a server asked to put one inside
  // its own child either refuses or loses the subtree.
  check("itself and everything under it are not destinations",
        names("arch"), ["Inbox", "Backup"])

  check("the top level is offered to anything that is not already there",
        names("arch-24"), ["Top level", "Inbox", "Backup"])

  check("and not to a folder that is already at the top level",
        names("back").indexOf("Top level"), -1)

  // Offering the parent it already has is a row that does nothing.
  check("its own parent is left out", names("arch-24").indexOf("Archive"), -1)

  check("a grandchild may go anywhere above it",
        names("arch-24-q1"), ["Top level", "Inbox", "Archive", "Backup"])

  check("another mailbox's folders are never destinations",
        Model.folderMoveTargets([view], "other", "arch"), [])
})

group("accountViews - last folder's answer, standing in", () => {
  // Switching folder makes a new fetch key, and a new key has no data until
  // the server answers. The mailbox used to drop out of the snapshot for those
  // seconds, and its folder tree collapsed to a single Inbox row - the tree
  // being the thing that had just been clicked in. Its last answer stands in
  // now, marked `stale`, and this is what may be taken from it and what may
  // not.
  const answer = {
    alias: "uds", ok: true, username: "jan@example.de", write: true, send: true,
    folders: [{ id: "inbox", name: "Inbox", isInbox: true },
              { id: "archive", name: "Archive", isInbox: false },
              { id: "history", name: "Conversation History", isInbox: false }],
    folderId: "archive", folderName: "Archive",
    mail: [{ id: "1", subject: "in the folder we just left", read: false }],
    unreadCount: 6038, unreadKnown: true,
    events: [{ id: "e1", subject: "standup" }],
    capabilities: { focused: true }
  }
  const build = (data) =>
    Model.accountViews([{ account: "uds" }], { accounts: [data] }, {}, "#fff", {}, true)[0]

  const fresh = build(answer)
  const standIn = build(Object.assign({}, answer, { stale: true }))

  check("the tree is kept, which is the whole point",
        standIn.folders.map((f) => f.id), ["inbox", "archive", "history"])
  check("and so is who the mailbox is",
        [standIn.username, standIn.write, standIn.send], ["jan@example.de", true, true])
  check("and its agenda, which no folder switch changes",
        standIn.events.length, 1)

  // The rows are the folder that was open a moment ago. Drawing them under the
  // new folder's name says "this is what is in Archive" about somebody's inbox.
  check("the mail is not kept", standIn.mail, [])
  check("nor is the folder it came from",
        [standIn.folderId, standIn.folderName], ["inbox", ""])
  check("the fresh answer keeps both",
        [fresh.mail.length, fresh.folderId], [1, "archive"])

  // The count is the inbox's own on the Graph path, so it is no more stale
  // than the tree - and a merged total that dips by six thousand and comes
  // back reads as a glitch.
  check("the unread count stays put", standIn.unreadCount, 6038)

  check("a mailbox standing in reads as busy, because it is",
        [standIn.busy, fresh.busy], [true, false])
  check("and says which of the two it is",
        [standIn.stale, fresh.stale], [true, false])
})

group("accountViews - the Focused/Other split", () => {
  // Outlook computes Focused/Other server-side and hands it over through Graph
  // alone. An IMAP mailbox says every row is focused because there is nothing
  // else it could truthfully say, so a filter on it would do nothing at all -
  // the window asks first, and this is what it asks.
  const build = (config, account) =>
    Model.accountViews([config], { accounts: account ? [account] : [] }, {}, "#fff", {}, false)[0]

  check("a Graph mailbox has the split",
        build({ account: "work" },
              { alias: "work", ok: true, capabilities: { focused: true } }).canFocus, true)

  check("an IMAP mailbox does not",
        build({ account: "fwu", transport: "imap" },
              { alias: "fwu", ok: true, capabilities: { focused: false } }).canFocus, false)

  // Before the first fetch answers there is no payload to read it from, and a
  // pill that appears for a moment and then leaves is worse than one that was
  // right from the start.
  check("the configured transport answers until the fetch does",
        build({ account: "fwu", transport: "imap" }, null).canFocus, false)

  check("and anything else is assumed to have it",
        build({ account: "work" }, null).canFocus, true)

  // A helper that stops reporting capabilities must not silently switch the
  // filter back on over a mailbox that cannot honour it.
  check("a mailbox that answered without saying is taken at the transport's word",
        build({ account: "fwu", transport: "imap" }, { alias: "fwu", ok: true }).canFocus, false)
})

group("legibleBody - a colour the pane cannot draw", () => {
  // #140000 is a real Omarchy theme's background, and black on it comes out at
  // a contrast ratio of 1.03 - the bug this exists for: the reader could see
  // the message only by selecting it.
  const DARK = "#140000"
  const LIGHT = "#ffffff"

  check("black on a near-black background is unreadable", Model.readableOn("black", DARK), false)
  check("and readable on a white one", Model.readableOn("black", LIGHT), true)
  check("the theme's own foreground is readable, which is what dropping falls back to",
        Model.readableOn("#F9D78E", DARK), true)

  // What Outlook and Word actually write, in every notation they write it in.
  check("rgb() black is caught too",
        Model.legibleBody('<span style="color: rgb(0, 0, 0); font-size: 12pt">hi</span>', "html", DARK),
        '<span style="font-size: 12pt">hi</span>')

  check("windowtext is Word for black",
        Model.legibleBody("<span style='color:windowtext'>hi</span>", "html", DARK),
        "<span>hi</span>")

  check("a style attribute left with nothing in it goes as well",
        Model.legibleBody('<p style="color:#000000">hi</p>', "html", DARK), "<p>hi</p>")

  // The point of the contrast test rather than stripping every colour: a
  // sender's readable choice is theirs.
  check("a colour that can be read is the sender's to choose",
        Model.legibleBody('<b style="color: rgb(254, 114, 53)">warning</b>', "html", DARK),
        '<b style="color: rgb(254, 114, 53)">warning</b>')

  check("and the same colour is dropped where it cannot be read",
        Model.legibleBody('<b style="color: #fab326">warning</b>', "html", LIGHT),
        "<b>warning</b>")

  // Backgrounds go whatever they are: with none of them left there is exactly
  // one background every colour is judged against.
  check("a painted background is dropped even when it is readable",
        Model.legibleBody('<td style="background-color: #ffffff; color: #000">x</td>', "html", DARK),
        "<td>x</td>")

  check("the background shorthand goes with it",
        Model.legibleBody('<td style="background: #fff url(x)">x</td>', "html", DARK),
        "<td>x</td>")

  check("and so does the legacy attribute",
        Model.legibleBody('<table bgcolor="#ffffff"><tr><td>x</td></tr></table>', "html", DARK),
        "<table><tr><td>x</td></tr></table>")

  check("<font color> is judged the same way",
        Model.legibleBody('<font color="black" size="2">hi</font>', "html", DARK),
        '<font size="2">hi</font>')

  check("a readable <font color> is kept",
        Model.legibleBody('<font color="#fab326">hi</font>', "html", DARK),
        '<font color="#fab326">hi</font>')

  // Only the sender's own markup. "linked" is markup Model.js wrote out of
  // escaped plain text, so there is no sender colour in it to argue with.
  check("a linked body is not touched",
        Model.legibleBody('<span style="color:#000">hi</span>', "linked", DARK),
        '<span style="color:#000">hi</span>')

  check("neither is plain text",
        Model.legibleBody("color: black", "text", DARK), "color: black")

  check("an empty body stays empty", Model.legibleBody("", "html", DARK), "")

  // A colour neither side can read is left as the sender wrote it: unreadable
  // is the only verdict that changes anything.
  check("a colour this cannot parse is left alone",
        Model.legibleBody('<b style="color: var(--x)">hi</b>', "html", DARK),
        '<b style="color: var(--x)">hi</b>')

  check("a background this cannot parse means no judging at all",
        Model.legibleBody('<b style="color:#000">hi</b>', "html", "not a colour"),
        '<b style="color:#000">hi</b>')

  // Qt hands a non-opaque colour over as #aarrggbb, and the alpha leads.
  check("Qt's #aarrggbb is read from the right end",
        Model.parseColor("#ff140000").join(","), "20,0,0")

  check("#rgb shorthand doubles each digit", Model.parseColor("#f00").join(","), "255,0,0")

  check("percentage channels are legal CSS",
        Model.parseColor("rgb(100%, 0%, 0%)").join(","), "255,0,0")

  check("rgba() alpha is ignored rather than refusing the colour",
        Model.parseColor("rgba(0, 0, 0, 0.5)").join(","), "0,0,0")

  check("a name this does not know is not guessed at",
        Model.parseColor("rebeccapurple"), null)
})

group("bodyMarkup - both passes, in the order that works", () => {
  // The link colour arrives as a style block in front of the body, and the
  // legibility pass runs on the body first - a link whose own blue is dropped
  // then falls back to that block, which is the whole point of doing it in
  // this order.
  const body = '<a href="https://e.com" style="color: blue">Sign in</a>'
  const out = Model.bodyMarkup(body, "html", "#4b74d6", "#140000")
  check("the theme's link colour leads", out.startsWith("<style>a { color: #4b74d6; }</style>"), true)
  check("and the sender's unreadable blue is gone", out.indexOf("color: blue"), -1)
  check("the anchor itself survives", out.indexOf('href="https://e.com"') > 0, true)
})

group("withLinkColor - links in the theme's colour", () => {
  // A TextEdit's rich text ignores palette.link and bakes Qt's #0000ff into
  // every anchor, so the colour has to arrive as markup in front of the body.
  const body = '<a href="https://e.com">Sign in</a>'

  check("a rich-text body is given the theme's link colour",
        Model.withLinkColor(body, "linked", "#7aa2f7"),
        '<style>a { color: #7aa2f7; }</style>' + body)

  check("a sender's own markup gets it too",
        Model.withLinkColor(body, "html", "#7aa2f7").startsWith("<style>"), true)

  // Plain text is rendered as plain text: a style block would be shown as
  // words rather than read as CSS.
  check("plain text is left exactly as it is",
        Model.withLinkColor("Sign in at https://e.com", "text", "#7aa2f7"),
        "Sign in at https://e.com")

  check("an empty body stays empty", Model.withLinkColor("", "linked", "#7aa2f7"), "")

  // The value comes from qs.Commons, but it is going into a style block.
  check("anything that is not plainly a colour is refused rather than escaped",
        Model.withLinkColor(body, "linked", "red; } body { display: none"), body)

  check("and so is a colour by name, which Qt would take but this will not",
        Model.withLinkColor(body, "linked", "rebeccapurple"), body)

  // Qt stringifies a non-opaque colour as #aarrggbb, which CSS reads as a
  // different colour entirely.
  check("an alpha channel is dropped rather than read as part of the colour",
        Model.cssColor("#ff7aa2f7"), "#7aa2f7")

  check("a short form is passed through", Model.cssColor("#abc"), "#abc")
})

group("a meeting - who is coming, and what they said", () => {
  const detail = {
    required: [
      { name: "You", response: "notResponded" },
      { name: "Ana", response: "organizer" },
      { name: "Tomás", response: "accepted" },
      { name: "Priya", response: "tentativelyAccepted" }
    ],
    optional: [{ name: "Yuki", response: "declined" }]
  }

  // The count is the answer to "is this happening at all", which is why it is
  // above the list rather than left to be worked out from it.
  check("the counts read as a sentence",
        Model.attendeeSummary(detail),
        "2 of 5 going  ·  1 maybe  ·  1 declined  ·  1 not answered")

  check("an appointment nobody was invited to has nothing to summarise",
        Model.attendeeSummary({ required: [], optional: [] }), "")

  check("and neither does a missing meeting", Model.attendeeSummary(null), "")

  // One list to draw, required first, each row knowing which it was.
  const rows = Model.attendeeRows(detail)
  check("required come before optional", rows.length, 5)
  check("and the optional ones say so", rows[4].optional, true)
  check("required ones do not", rows[0].optional, false)

  // Told apart by shape, not by hue alone: one of these people is going to be
  // colour-blind, and a list of names in two greens is no list at all.
  check("accepted is a tick", Model.responseGlyph("accepted"), "✓")
  check("maybe is a question", Model.responseGlyph("tentativelyAccepted"), "?")
  check("declined is a cross", Model.responseGlyph("declined"), "✕")
  check("the organiser is starred", Model.responseGlyph("organizer"), "★")
  check("no answer is a dot", Model.responseGlyph("nonsense"), "·")

  // The same value describes what somebody else said and what you said, and
  // "Accepted" reads oddly about yourself.
  check("your own answer is in the first person",
        Model.responseLabel("accepted", true), "You are going")
  check("not answering is worth saying out loud",
        Model.responseLabel("notResponded", true), "You have not answered")
  check("your own meeting has no answer to give",
        Model.responseLabel("organizer", true), "")
  check("somebody else's answer is a word",
        Model.responseLabel("tentativelyAccepted", false), "maybe")

  // A pane is where somebody checks whether they can be somewhere, and an
  // hour on its own has caught people out by a day.
  const now = new Date(2026, 8, 2, 9, 0, 0)
  check("today says today",
        Model.meetingWhen("2026-09-02T14:00:00", "2026-09-02T14:30:00", false, now),
        "Today  14:00–14:30")
  check("an all-day meeting says so instead of showing midnight",
        Model.meetingWhen("2026-09-02T00:00:00", "2026-09-03T00:00:00", true, now),
        "Today  ·  all day")
  check("nothing to place is nothing to say", Model.meetingWhen("", "", false, now), "")
})

group("recipient completion - the entry being typed, and what it matches", () => {
  // A To field holds a list, and only the last entry is being completed.
  check("nothing typed yet is nothing to complete",
        Model.lastAddressFragment(""), { head: "", fragment: "" })
  check("the whole field is the fragment while it is the only entry",
        Model.lastAddressFragment("jan"), { head: "", fragment: "jan" })
  check("only what follows the last separator is being typed",
        Model.lastAddressFragment("a@b.com, jan"), { head: "a@b.com,", fragment: "jan" })
  check("a semicolon separates too, because Outlook taught people it does",
        Model.lastAddressFragment("a@b.com; jan"), { head: "a@b.com;", fragment: "jan" })

  // The two that a plain split on commas gets wrong, and that would cut a
  // finished recipient in half every time the next one was typed.
  check("a comma inside a quoted name is not a separator",
        Model.lastAddressFragment('"Renz, Jan" <j@x.de>, ma'),
        { head: '"Renz, Jan" <j@x.de>,', fragment: "ma" })
  check("a separator inside angle brackets is not one either",
        Model.lastAddressFragment("<a,b@x.de>"), { head: "", fragment: "<a,b@x.de>" })

  // What accepting a suggestion writes. graph.py parses this form apart again.
  check("a name is kept, because that is what the field is read back for",
        Model.formatRecipient({ name: "Jan Renz", address: "j@x.de" }), "Jan Renz <j@x.de>")
  check("an address with no name stays an address",
        Model.formatRecipient({ name: "", address: "j@x.de" }), "j@x.de")
  check("a name that is also the address is not written twice",
        Model.formatRecipient({ name: "j@x.de", address: "j@x.de" }), "j@x.de")
  check("a name carrying a comma is quoted, or it would be two recipients",
        Model.formatRecipient({ name: "Renz, Jan", address: "j@x.de" }), '"Renz, Jan" <j@x.de>')
  check("nothing to format is nothing", Model.formatRecipient(null), "")

  const book = {
    "j@x.de": { address: "j@x.de", name: "Jan Renz", count: 5, at: 2 },
    "marijana@y.de": { address: "marijana@y.de", name: "Marijana Kern", count: 40, at: 9 },
    "k@z.de": { address: "k@z.de", name: "Klaus Renz", count: 1, at: 1 }
  }
  const addresses = (fragment, limit) =>
    Model.matchAddresses(book, fragment, limit).map((entry) => entry.address)

  check("an empty fragment matches nobody - a list of everyone is not a suggestion",
        addresses(""), [])
  // The ranking that matters: "jan" should offer Jan before Marijana, even
  // though Marijana is written to eight times as often.
  check("a name that starts with it beats a name that merely contains it",
        addresses("jan"), ["j@x.de", "marijana@y.de"])
  check("any word of a name counts, not just the first",
        addresses("renz"), ["j@x.de", "k@z.de"])
  check("the address matches as well as the name", addresses("marijana@"), ["marijana@y.de"])
  check("case is not something anybody should have to get right",
        addresses("REnZ"), ["j@x.de", "k@z.de"])
  check("nobody reads past the limit", addresses("renz", 1), ["j@x.de"])
  check("no match is an empty list, not everything", addresses("zzz"), [])
})

group("the merged view - one folder, every mailbox", () => {
  const views = [
    { alias: "work", username: "me@work", short: "W", color: "blue", unreadCount: 3,
      folders: [{ id: "INBOX", name: "Inbox", isInbox: true, unread: 3, depth: 0 },
                { id: "Archiv", name: "Archiv", unread: 0, depth: 0 }] },
    { alias: "home", username: "me@home", short: "H", color: "magenta", unreadCount: 2,
      folders: [{ id: "inbox", name: "Inbox", isInbox: true, unread: 2, depth: 0 }] }
  ]

  // The state a window opens in: nothing has picked a folder, so every mailbox
  // is on its inbox and the list is all of them merged. That was true all
  // along and the window said "Inbox — me@work" about it.
  check("nothing picked is every mailbox on its inbox",
        Model.unifiedFolder(["work", "home"], {}), "inbox")
  check("one mailbox moved off breaks it",
        Model.unifiedFolder(["work", "home"], { work: "Archiv" }), "")
  check("both on the same folder is merged again",
        Model.unifiedFolder(["work", "home"], { work: "archive", home: "archive" }), "archive")
  check("no mailboxes is nothing to merge", Model.unifiedFolder([], {}), "")
  check("one mailbox agrees with itself, which the caller has to ignore",
        Model.unifiedFolder(["work"], {}), "inbox")

  const rows = (unified) => Model.folderRows(views, {}, "", unified)
  const merged = (unified) => rows(unified).filter((r) => r.alias === "*")

  check("the merged group is a header and the folders every mailbox has",
        merged("inbox").map((r) => r.name),
        ["All mailboxes", "Inbox", "Archive", "Sent", "Drafts", "Junk", "Deleted"])
  // What travels is the well-known name, because no folder id means the same
  // folder in two mailboxes - let alone across the two transports.
  check("the merged rows carry well-known names rather than folder ids",
        merged("inbox").filter((r) => r.kind === "folder").map((r) => r.id),
        ["inbox", "archive", "sentitems", "drafts", "junkemail", "deleteditems"])
  check("the merged inbox counts every mailbox's unread",
        merged("inbox").filter((r) => r.id === "inbox")[0].unread, 5)
  check("only the merged inbox has a count - nothing reports the other folders",
        merged("inbox").filter((r) => r.id === "archive")[0].unread, 0)

  check("the merged folder that is open is the one lit",
        merged("archive").filter((r) => r.selected).map((r) => r.id), ["archive"])
  // One folder lighting up two rows would say the window is in two places.
  check("no mailbox's own row is lit while the merged view is open",
        rows("inbox").filter((r) => r.alias !== "*" && r.selected).length, 0)
  check("and they are lit again once the merged view is not what is open",
        rows("").filter((r) => r.alias !== "*" && r.selected).map((r) => r.id),
        ["INBOX", "inbox"])

  // With one mailbox the merged group is that mailbox's tree drawn twice.
  check("a single mailbox gets no merged group",
        Model.folderRows([views[0]], {}, "", "").filter((r) => r.alias === "*").length, 0)

  check("the merged folder has a name for the window's title",
        Model.unifiedFolderName("sentitems"), "Sent")
  check("something that is not a merged folder has none",
        Model.unifiedFolderName("Archiv"), "")
})

// ---------------------------------------------------------------- file sizes
//
// What the reading pane writes beside an attachment's name. The question it
// answers is whether this is a page or a presentation, which is why the units
// change rather than the number growing.
group("a file size a person can read", () => {
  check("bytes, while there are few enough to matter", Model.fileSize(512), "512 B")
  check("kilobytes for a page of PDF", Model.fileSize(176433), "172 KB")
  check("one decimal below ten, so 1.4 MB is not rounded to 1", Model.fileSize(1468006), "1.4 MB")
  check("and none above it, because nobody needs 12.3", Model.fileSize(12.7 * 1024 * 1024), "13 MB")
  check("nothing at all for a size that is not one", Model.fileSize(0), "")
  check("the folder a saved file went into", Model.folderOf("~/Downloads/scan.pdf"), "~/Downloads")
  check("and a bare name has none", Model.folderOf("scan.pdf"), "scan.pdf")
  check("or for one that is not a number", Model.fileSize("what"), "")
})

console.log(`\n${checks - failures}/${checks} passed`)
process.exit(failures ? 1 : 0)

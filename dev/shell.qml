import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

import "Fixtures.js" as Fixtures
import "Model.js" as Model

// Development harness. Renders the panel's own components in a plain window
// against fixture data, so laying out the agenda does not mean restarting the
// bar and reopening a popup for every change.
//
//   dev/link.sh && qs -p dev/shell.qml
//
// Quickshell reloads on save, so this window redraws as the files above it are
// edited. Commons and Ui are symlinks to the shell's own, so what renders here
// uses the same Style, Color and controls as the real panel.
ShellRoot {
  FloatingWindow {
    id: window
    title: "office365 dev"
    implicitWidth: 1400
    implicitHeight: 900
    color: Color.background

    // The settings the timeline would take from a widget, as controls, so a
    // range or a working day can be tried without editing anything.
    property int days: 3
    property int startMinutes: 7 * 60
    property int endMinutes: 22 * 60
    property bool showWeekends: true
    property var selected: null
    // "timeline" or "settings" - the settings form is worth looking at here
    // too, since reaching it in the real panel means clicking a gear.
    property string page: "timeline"

    // Enough of a Service for the settings form to render against. Saving
    // prints rather than writing, so the harness can never touch shell.json.
    // An Item rather than a QtObject only so it can hold the Timer that makes
    // saving asynchronous, the way the real one is.
    Item {
      id: fakeService
      visible: false
      property var settings: ({
        label: "MAIL", icon: "", mails: 15, calendar: "3day", agendaView: "timeline",
        dayStart: "07:00", dayEnd: "22:00", showWeekends: true,
        accounts: [
          { account: "work", short: "WRK", color: "blue" },
          { account: "personal", short: "PRS", color: "magenta" }
        ]
      })
      property var accountConfigs: settings.accounts
      // A few named colours, so the mailbox page's swatches are not all grey
      // the way they are before a real palette has been read.
      property var themePalette: ({
        blue: "#7aa2f7", green: "#9ece6a", magenta: "#bb9af7", yellow: "#e0af68",
        cyan: "#7dcfff", orange: "#ff9e64", red: "#f7768e", brown: "#cfa07a"
      })
      property bool configured: true
      property bool saving: false
      property string saveError: ""
      // No settingsChanged signal here: `property var settings` already
      // generates one, which is what the form listens to.
      //
      // settingsSaved is declared, because the form waits for it before
      // closing. Set failNextSave to watch what happens when the write fails:
      // the form has to stay open with the error on it rather than closing and
      // taking the edits with it.
      signal settingsSaved()
      property bool failNextSave: false
      function viewFor(alias) {
        return { alias: alias, ok: true, loaded: true, busy: false, write: alias === "work",
                 username: alias + "@example.com", errorCode: "", errorMessage: "" }
      }
      function canWrite(alias) { return alias === "work" }
      function startLogin(alias, write) { console.log("login", alias, write) }
      function signOut(alias) { console.log("signOut", alias) }
      // Answers the way the real one does: starts, then reports later.
      function saveSettings(patch) {
        console.log("save", JSON.stringify(patch))
        saving = true
        saveError = ""
        saveTimer.restart()
        return true
      }

      Timer {
        id: saveTimer
        interval: 400
        onTriggered: {
          fakeService.saving = false
          if (fakeService.failNextSave) {
            fakeService.saveError = "Could not find this widget in the bar layout"
            return
          }
          fakeService.settingsSaved()
        }
      }
    }

    readonly property var grid: Model.dayGrid(Fixtures.views(), new Date(), {
      days: window.days,
      startMinutes: window.startMinutes,
      endMinutes: window.endMinutes,
      showWeekends: window.showWeekends,
      dedupe: true
    })

    // The harness draws its own screenshots rather than being photographed off
    // the screen: a tiling compositor will put this window behind another one,
    // and a region grab then captures whatever is in front of it. This also
    // means the loop works while the window is on another workspace.
    //
    //   qs -p dev/shell.qml ipc call dev shot /tmp/x.png
    //   qs -p dev/shell.qml ipc call dev range 7         (days across)
    IpcHandler {
      target: "dev"

      function shot(path: string): void {
        var started = content.grabToImage(function(result) {
          console.log("shot", path, result ? result.saveToFile(path) : "no result")
        })
        if (!started) console.log("shot", path, "grab refused - is the window mapped?")
      }

      // Just the stage, without the harness's own controls above it - for
      // figures where the dev chrome would be noise.
      function stageShot(path: string): void {
        var started = stage.grabToImage(function(result) {
          console.log("shot", path, result ? result.saveToFile(path) : "no result")
        })
        if (!started) console.log("shot", path, "grab refused - is the window mapped?")
      }

      function range(days: int): void {
        window.days = days
      }

      function page(name: string): void {
        window.page = name
      }

      // Which page of the settings form: -1 the list, -2 the calendar,
      // 0 upwards a mailbox.
      function settingsPage(index: int): void {
        window.page = "settings"
        if (settingsLoader.item) settingsLoader.item.editing = index
      }

      // Press Save. Pass "fail" to have the write come back refused, which is
      // the case worth looking at: the form must still be there, with the
      // error on it and the edits intact.
      function save(mode: string): void {
        window.page = "settings"
        fakeService.failNextSave = mode === "fail"
        if (settingsLoader.item) settingsLoader.item.save()
      }

      function hours(from: string, to: string): void {
        window.startMinutes = Model.minutesFromClock(from, 7 * 60)
        window.endMinutes = Model.minutesFromClock(to, 22 * 60)
      }

      function select(subject: string): void {
        window.selected = null
        for (var d = 0; d < window.grid.days.length; d++) {
          var day = window.grid.days[d]
          var pools = [day.timed, day.allDay]
          for (var p = 0; p < pools.length; p++)
            for (var i = 0; i < pools[p].length; i++)
              if (String(pools[p][i].subject).toLowerCase().indexOf(subject.toLowerCase()) >= 0) {
                window.selected = pools[p][i]
                return
              }
        }
      }
    }

    Rectangle {
      id: content
      anchors.fill: parent
      color: Color.background

      Row {
        id: controls
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: Style.spacing.lg
        spacing: Style.spacing.lg

        Repeater {
          model: [
            { label: "1 day", days: 1 },
            { label: "3 day", days: 3 },
            { label: "week", days: 7 }
          ]

          Rectangle {
            id: pill
            required property var modelData
            width: pillLabel.implicitWidth + Style.spacing.xxl
            height: Style.space(20)
            radius: height / 2
            color: window.days === pill.modelData.days
              ? Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.16)
              : "transparent"
            border.width: Style.space(1)
            border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.2)

            Text {
              id: pillLabel
              anchors.centerIn: parent
              text: pill.modelData.label
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: window.days = pill.modelData.days
            }
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: Model.clockFromMinutes(window.startMinutes) + "–" + Model.clockFromMinutes(window.endMinutes)
                + "   ·   " + (window.selected ? window.selected.subject : "nothing selected")
          color: Qt.darker(Color.foreground, 1.5)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      // A stage the size the timeline actually gets in the panel, rather than
      // whatever the window happens to be: laying this out against a
      // full-screen window would tune it for a size it never has.
      Rectangle {
        id: stage
        anchors.left: parent.left
        anchors.top: controls.bottom
        anchors.margins: Style.spacing.lg
        width: window.page === "timeline"
          ? Style.space(window.days === 1 ? 300 : (window.days === 3 ? 500 : 1100))
          : Style.space(380)
        height: window.page === "settings" ? settingsLoader.implicitHeight + Style.spacing.md * 2
                                           : Style.space(560)
        color: "transparent"
        border.width: Style.space(1)
        border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.15)

        AgendaList {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.spacing.md
          visible: window.page === "list"
          agenda: Fixtures.agenda()
          showAccount: true
          onOpenRequested: function(url, alias) { console.log("open", url, alias) }
          onJoinRequested: function(url, alias) { console.log("join", url, alias) }
        }

        Loader {
          id: settingsLoader
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.spacing.md
          active: window.page === "settings"
          // done() is what the panel closes the form on, so the harness has to
          // act on it too - otherwise a save that closes and one that does not
          // look identical here.
          sourceComponent: SettingsForm {
            service: fakeService
            onDone: {
              console.log("settings form closed")
              window.page = "timeline"
            }
          }
        }

        // What the panel says when a mailbox only half worked. Easy to get
        // wrong and impossible to provoke on demand from a real mailbox, so
        // the fixtures carry one of each.
        ProblemList {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.spacing.md
          visible: window.page === "problems"
          views: Fixtures.brokenViews()
          warnings: Model.collectWarnings(Fixtures.brokenViews())
          errorMessage: "The helper could not be run"
        }

        AgendaTimeline {
          anchors.fill: parent
          anchors.margins: Style.spacing.md
          visible: window.page === "timeline"
          availableHeight: stage.height - Style.spacing.md * 2

          grid: window.grid
          showAccount: true
          selectedEvent: window.selected
          onEventClicked: function(event) { window.selected = event }
          onExpandRequested: {
            window.startMinutes = window.grid.fits.startMinutes
            window.endMinutes = window.grid.fits.endMinutes
          }
          onOpenRequested: function(url, alias) { console.log("open", url, alias) }
        }
      }
    }
  }
}

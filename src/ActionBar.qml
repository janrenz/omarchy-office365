import QtQuick
import qs.Commons
import qs.Ui

// A row of buttons that keeps to the width it is given.
//
// The reading pane grew to ten actions - Open, three ways to write a reply,
// the agent, read, flag, move, delete - laid out in a plain Row, which does
// not wrap and does not care that the pane is narrower than its contents. The
// ones past the edge were simply unreachable by pointer, and on the bar's
// popup that was most of them.
//
// So this measures them and shows what fits, with the rest behind a button
// that reveals them on a second line. Revealing rather than floating a menu
// over the pane: a popup would have to escape whatever ancestor is clipping
// it, and it would have to be dismissed, while a second line is just more
// pane and costs nothing to get wrong. The row is the common case and stays
// exactly as it was.
//
// An action is a plain object, not an Item, so the same one can be drawn in
// either line:
//
//   { text, tooltip, enabled, visible, danger, muted, trigger }
//
// `danger` draws it in the accent - Delete, Send, a raised flag - and `muted`
// in the dim foreground, for the ones that are offers rather than actions.
//
// `visible: false` takes an action out entirely - that is how the pane hides
// what a read-only mailbox cannot do - and only what is left is measured.
Item {
  id: root

  property var actions: []
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.caption
  property real spacing: Style.spacing.sm

  // Whether the overflow line is showing. Deliberately not reset when the
  // pane is resized: somebody who opened it to reach Delete should not have
  // it shut under them because a neighbouring column moved.
  property bool expanded: false

  // The actions that want to be on screen at all. Everything below counts and
  // measures this list, never `actions`, so a hidden action takes up no room
  // and cannot push a visible one into the overflow.
  readonly property var live: {
    var out = []
    for (var i = 0; i < actions.length; i++)
      if (actions[i] && actions[i].visible !== false) out.push(actions[i])
    return out
  }

  // Filled by the measuring row below, which is why it is a property and not
  // a function: the widths are only knowable once the buttons exist, and this
  // is what re-runs the fit when they change.
  property var widths: []

  readonly property int fits: {
    if (width <= 0 || widths.length !== live.length) return live.length
    var used = 0
    for (var i = 0; i < live.length; i++) {
      var next = used + (i > 0 ? spacing : 0) + widths[i]
      if (next <= width) { used = next; continue }
      // This one does not fit, so it and everything after it overflow - and
      // the button that reveals them needs room of its own, which may mean
      // giving up one or more that did fit.
      var shown = i
      while (shown > 0 && used + spacing + moreWidth > width) {
        shown -= 1
        used -= widths[shown] + (shown > 0 ? spacing : 0)
      }
      return shown
    }
    return live.length
  }

  readonly property bool overflowing: fits < live.length
  readonly property real moreWidth: moreButton.implicitWidth

  implicitHeight: lines.implicitHeight
  implicitWidth: lines.implicitWidth

  // Every action, drawn once where nobody can see it, purely to be measured.
  //
  // A Button's width comes from its own text metrics and padding, so there is
  // no honest way to know it without building one. Kept out of the layout with
  // a zero-sized parent rather than `visible: false`, because an invisible item
  // is skipped by the Row it is in but is still laid out here, and this way it
  // cannot be clicked, tabbed to or read out either.
  Item {
    id: ruler
    width: 0
    height: 0
    clip: true
    opacity: 0
    enabled: false

    Repeater {
      id: rulerRepeater
      model: root.live
      Button {
        text: String(modelData.text || "")
        bordered: true
        fontFamily: root.fontFamily
        fontSize: root.fontSize
        onImplicitWidthChanged: root.remeasure()
      }
      onCountChanged: root.remeasure()
    }
  }

  function remeasure() {
    var measured = []
    for (var i = 0; i < rulerRepeater.count; i++) {
      var item = rulerRepeater.itemAt(i)
      if (!item) return
      measured.push(item.implicitWidth)
    }
    widths = measured
  }

  Component.onCompleted: remeasure()

  Column {
    id: lines
    width: parent.width
    spacing: root.spacing

    Row {
      id: primary
      spacing: root.spacing

      Repeater {
        model: root.live
        Button {
          visible: index < root.fits
          enabled: modelData.enabled !== false
          text: String(modelData.text || "")
          tooltipText: String(modelData.tooltip || "")
          bordered: true
          foreground: modelData.danger === true ? root.accent
                      : (modelData.muted === true ? root.dim : root.fg)
          fontFamily: root.fontFamily
          fontSize: root.fontSize
          onClicked: if (modelData.trigger) modelData.trigger()
        }
      }

      // Says how many are hidden rather than just that some are: the count is
      // the whole reason to press it, and it is free to know.
      Button {
        id: moreButton
        visible: root.overflowing
        text: root.expanded ? "Fewer" : ("+" + (root.live.length - root.fits) + " more")
        tooltipText: root.expanded
                     ? "Hide the actions that do not fit"
                     : "Show the actions that do not fit on one line"
        bordered: true
        foreground: root.dim
        fontFamily: root.fontFamily
        fontSize: root.fontSize
        onClicked: root.expanded = !root.expanded
      }
    }

    // Wrapped rather than a second Row, because the overflow has no width
    // budget left to respect - whatever did not fit on one line will not fit
    // on another one either.
    Flow {
      width: parent.width
      spacing: root.spacing
      visible: root.expanded && root.overflowing

      Repeater {
        model: root.live
        Button {
          visible: index >= root.fits
          enabled: modelData.enabled !== false
          text: String(modelData.text || "")
          tooltipText: String(modelData.tooltip || "")
          bordered: true
          foreground: modelData.danger === true ? root.accent
                      : (modelData.muted === true ? root.dim : root.fg)
          fontFamily: root.fontFamily
          fontSize: root.fontSize
          onClicked: if (modelData.trigger) modelData.trigger()
        }
      }
    }
  }
}

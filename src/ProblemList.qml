import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Everything that went wrong, under whatever data survived it.
//
// Three kinds, in order of how much they cost you:
//   - a mailbox that failed outright, which is why its rows are missing;
//   - a mailbox that answered without part of itself, which is the one nothing
//     else in the panel would mention - an unreadable calendar looks exactly
//     like a free afternoon;
//   - the helper itself failing, which takes every mailbox with it.
//
// Sign-in is not a problem and is not listed here: a mailbox waiting to be
// signed in has a button of its own further up.
Column {
  id: root

  // Account views, for the ones that failed outright.
  property var views: []
  // Model.collectWarnings output, for the ones that partly failed.
  property var warnings: []
  // A whole-fetch failure, already one line.
  property string errorMessage: ""

  property color accent: Color.accent
  property string fontFamily: Style.font.family

  spacing: Style.spacing.xxs

  Repeater {
    model: root.views

    Text {
      required property var modelData
      width: root.width
      visible: modelData.loaded && !modelData.ok && modelData.errorCode !== "auth_required"
      wrapMode: Text.WordWrap
      text: modelData.short + ": " + Model.oneLine(modelData.errorMessage, 160)
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Repeater {
    model: root.warnings

    Text {
      required property var modelData
      width: root.width
      wrapMode: Text.WordWrap
      text: modelData.short + ": " + modelData.message
      color: root.accent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  Text {
    width: root.width
    visible: root.errorMessage !== ""
    wrapMode: Text.WordWrap
    text: root.errorMessage
    color: root.accent
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}

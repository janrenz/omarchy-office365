import QtQuick
import qs.Commons
import qs.Ui

// A text field that says what it holds. Placeholders disappear the moment a
// value is typed, which left the settings form showing a column of values with
// nothing to say what any of them were.
Column {
  id: root

  property string label: ""
  property string placeholder: ""
  property string value: ""
  property string hint: ""
  property color fg: Color.foreground
  property color dim: Qt.darker(fg, 1.5)
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  // Optional input validator, for fields whose value has to survive being used
  // as something other than text - an alias becomes a filename.
  property var validator: null

  signal edited(string value)

  spacing: Style.spacing.xxs

  Text {
    textFormat: Text.PlainText
    text: root.label
    visible: text !== ""
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  TextField {
    width: parent.width
    text: root.value
    placeholderText: root.placeholder
    validator: root.validator
    foreground: root.fg
    accent: root.accent
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    onTextChanged: if (text !== root.value) root.edited(text)
  }

  Text {
    textFormat: Text.PlainText
    text: root.hint
    visible: text !== ""
    width: parent.width
    wrapMode: Text.WordWrap
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
}

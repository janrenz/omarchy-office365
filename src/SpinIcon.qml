import QtQuick
import qs.Commons

// A glyph that spins about its own ink rather than its line box.
//
// Icon glyphs rarely sit in the middle of the em box the font reserves for
// them, so rotating the text item swings the icon around a point that is not
// its centre and it visibly wobbles. TextMetrics knows where the painted
// pixels actually are; centring on that and turning about the same point
// keeps the icon still while it spins.
Item {
  id: root

  property string text: ""
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.icon
  property color color: Color.foreground
  property bool spinning: false
  property real angle: 0

  implicitWidth: fontSize
  implicitHeight: fontSize

  TextMetrics {
    id: metrics
    font.family: root.fontFamily
    font.pixelSize: Math.max(1, Math.round(root.fontSize))
    text: root.text
  }

  // Middle of the painted glyph, in the text item's own coordinates. The
  // horizontal figure is measured from the item's left edge, but the vertical
  // one is measured from the baseline and reads negative above it - which is
  // why the shell's own OpticalGlyph corrects horizontally only. Adding the
  // baseline offset puts both in the same space.
  readonly property real inkX: metrics.tightBoundingRect.x + metrics.tightBoundingRect.width / 2
  readonly property real inkY: glyph.baselineOffset
                               + metrics.tightBoundingRect.y
                               + metrics.tightBoundingRect.height / 2

  Text {
    textFormat: Text.PlainText
    id: glyph
    text: root.text
    color: root.color
    font: metrics.font
    // Placed so the ink lands in the middle of the box, not the line box.
    x: root.width / 2 - root.inkX
    y: root.height / 2 - root.inkY

    transform: Rotation {
      origin.x: root.inkX
      origin.y: root.inkY
      angle: root.angle
    }
  }

  NumberAnimation on angle {
    from: 0
    to: 360
    duration: 900
    loops: Animation.Infinite
    running: root.spinning
    // Leaving it stopped mid-turn would read as broken rather than idle.
    onStopped: root.angle = 0
  }
}

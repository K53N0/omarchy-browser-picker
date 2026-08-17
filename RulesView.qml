// The list of host → profile rules, with a way to drop one.
//
// Every rule is shown, whether it was written by hand or learned from repeats,
// and each is one click from being removed. A rule that silently sends a domain
// somewhere is only acceptable while it stays this easy to see and undo.

import QtQuick
import QtQuick.Layouts
import qs.Commons

Column {
  id: root

  property var rules: []
  property color foreground: Color.foreground
  property color dim: Color.muted
  property string fontFamily: Style.font.family

  signal removed(string pattern)

  spacing: Style.space(4)

  Text {
    width: parent.width
    visible: root.rules.length === 0
    wrapMode: Text.WordWrap
    text: "No rules yet. Pick a profile for a site a few times and the picker "
      + "will offer to make it permanent."
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  Repeater {
    model: root.rules

    Rectangle {
      required property var modelData

      width: parent.width
      implicitHeight: Math.max(Style.spacing.popupRowHeight, ruleText.implicitHeight + Style.space(10))
      radius: Style.cornerRadius
      color: hover.hovered ? Style.hoverFill : "transparent"

      HoverHandler { id: hover }

      RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Style.space(8)
        anchors.rightMargin: Style.space(8)
        spacing: Style.space(8)

        Column {
          Layout.fillWidth: true
          spacing: Style.space(1)

          Text {
            id: ruleText
            width: parent.width
            text: modelData.pattern
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            // The id is "<bin>:<profile>"; the profile alone is what the user
            // recognises, and the browser is already implied by the rule they
            // just watched themselves make.
            text: String(modelData.entryId).split(":").slice(1).join(":")
              + (modelData.learned ? "  ·  learned" : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Text {
          Layout.alignment: Qt.AlignVCenter
          text: "✕"
          color: hover.hovered ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body

          MouseArea {
            anchors.fill: parent
            anchors.margins: -Style.space(6)
            cursorShape: Qt.PointingHandCursor
            onClicked: root.removed(modelData.pattern)
          }
        }
      }
    }
  }
}

// The list of host → profile rules.
//
// Two modes from one component. The bar popup shows a read-only glance at the
// most recent few; the rules window shows all of them, editable, with a row for
// adding one by hand. A rule that silently sends a domain somewhere is only
// acceptable while it stays this easy to see, change and undo.

import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Column {
  id: root

  property var rules: []
  // Profiles a rule may point at, for the target picker. Manage rows are not
  // destinations, so they never appear here.
  property var entries: []
  property bool editable: false
  // 0 shows everything. The bar popup passes a small number so a long list
  // cannot push the settings above it off the card; the full window passes 0.
  property int limit: 0
  readonly property var shownRules: limit > 0 ? rules.slice(0, limit) : rules
  readonly property int hiddenCount: Math.max(0, rules.length - shownRules.length)

  property color foreground: Color.foreground
  property color dim: Color.muted
  property string fontFamily: Style.font.family

  // oldPattern empty means "this is a new rule". Renaming a pattern arrives as
  // an old and a new one, so the caller can drop the old entry.
  signal changed(string oldPattern, string newPattern, string entryId)
  signal removed(string pattern)
  signal escaped()

  readonly property var targetOptions: {
    var out = []
    for (var i = 0; i < entries.length; i++) {
      if (entries[i].manage) continue
      out.push({ value: entries[i].id, label: entries[i].label })
    }
    return out
  }

  // "<binary>:<profile>" is what a rule stores, but only the profile half means
  // anything to a person reading the list.
  function shortTarget(entryId) {
    var id = String(entryId || "")
    var parts = id.split(":")
    var tail = parts.slice(1).join(":")
    return tail || id
  }

  // A rule can outlive the profile it points at — a profile gets deleted, a
  // browser uninstalled. SearchableDropdown falls back to showing the raw id in
  // that case, which reads like a glitch rather than a stale rule, so the
  // missing target is added as an option of its own and named as missing.
  function optionsFor(entryId) {
    var id = String(entryId || "")
    if (!id) return targetOptions
    for (var i = 0; i < targetOptions.length; i++) {
      if (targetOptions[i].value === id) return targetOptions
    }
    return [{ value: id, label: shortTarget(id) + "  ·  profile not found" }]
      .concat(targetOptions)
  }

  // One column width for the trailing control, shared by the ✕ on a rule row
  // and the Add button below, so every row ends on the same vertical line.
  readonly property int actionWidth: Style.space(52)
  readonly property int rowHeight: Style.spacing.controlHeight

  spacing: Style.space(4)

  Text {
    width: parent.width
    visible: root.rules.length === 0
    wrapMode: Text.WordWrap
    text: root.editable
      ? "No rules yet. Add one below, or let the picker offer you one after you "
        + "pick the same profile for the same site a few times."
      : "No rules yet. Pick a profile for a site a few times and the picker "
        + "will offer to make it permanent."
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // ----------------------------------------------------------- read-only

  Repeater {
    model: root.editable ? [] : root.shownRules

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
            text: root.shortTarget(modelData.entryId)
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

  // ------------------------------------------------------------ editable

  Repeater {
    model: root.editable ? root.shownRules : []

    RowLayout {
      required property var modelData

      width: parent.width
      spacing: Style.space(8)

      TextField {
        id: patternField
        Layout.fillWidth: true
        Layout.preferredHeight: root.rowHeight
        Layout.alignment: Qt.AlignVCenter
        text: modelData.pattern
        foreground: root.foreground
        font.family: root.fontFamily
        // Committed on Enter or on leaving the field, never per keystroke:
        // rewriting the rules file on every character would fight the watcher
        // that reloads it and make the field jump under the cursor.
        onAccepted: root.commitPattern(modelData, text)
        onActiveFocusChanged: if (!activeFocus) root.commitPattern(modelData, text)
        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Escape) { root.escaped(); event.accepted = true }
        }
      }

      SearchableDropdown {
        Layout.preferredWidth: Style.spacing.searchableDropdownWidth
        Layout.preferredHeight: root.rowHeight
        Layout.alignment: Qt.AlignVCenter
        rowHeight: root.rowHeight
        showLabel: false
        value: modelData.entryId
        options: root.optionsFor(modelData.entryId)
        placeholderText: "Search profiles…"
        triggerLabel: root.shortTarget(modelData.entryId)
        fontFamily: root.fontFamily
        onChanged: function (value) {
          if (value && value !== modelData.entryId)
            root.changed(modelData.pattern, modelData.pattern, value)
        }
      }

      Item {
        Layout.preferredWidth: root.actionWidth
        Layout.preferredHeight: root.rowHeight
        Layout.alignment: Qt.AlignVCenter

        Text {
          anchors.centerIn: parent
          text: "✕"
          color: removeHover.hovered ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        HoverHandler { id: removeHover }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.removed(modelData.pattern)
        }
      }
    }
  }

  function commitPattern(rule, text) {
    // Rewriting the file rebuilds these delegates, and the one losing focus can
    // arrive here already detached from its data.
    if (!rule || !rule.pattern) return
    var next = String(text || "").trim().toLowerCase()
    if (!next || next === rule.pattern) return
    root.changed(rule.pattern, next, rule.entryId)
  }

  // ----------------------------------------------------------------- add

  Item {
    width: parent.width
    height: Style.space(6)
    visible: root.editable
  }

  RowLayout {
    width: parent.width
    spacing: Style.space(8)
    visible: root.editable

    TextField {
      id: newPattern
      Layout.fillWidth: true
      Layout.preferredHeight: root.rowHeight
      Layout.alignment: Qt.AlignVCenter
      placeholderText: "example.com"
      foreground: root.foreground
      font.family: root.fontFamily
      onAccepted: addButton.commit()
      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) { root.escaped(); event.accepted = true }
      }
    }

    SearchableDropdown {
      id: newTarget
      Layout.preferredWidth: Style.spacing.searchableDropdownWidth
      Layout.preferredHeight: root.rowHeight
      Layout.alignment: Qt.AlignVCenter
      rowHeight: root.rowHeight
      showLabel: false
      options: root.targetOptions
      placeholderText: "Search profiles…"
      triggerLabel: newTarget.value ? root.shortTarget(newTarget.value) : "Pick a profile"
      fontFamily: root.fontFamily
      onChanged: function (value) { newTarget.value = value }
    }

    Button {
      id: addButton
      Layout.preferredWidth: root.actionWidth
      Layout.preferredHeight: root.rowHeight
      Layout.alignment: Qt.AlignVCenter
      text: "Add"
      bordered: true
      foreground: root.foreground
      fontFamily: root.fontFamily
      enabled: newPattern.text.trim() !== "" && newTarget.value !== ""
      opacity: enabled ? 1 : 0.5
      onClicked: commit()

      function commit() {
        if (!enabled) return
        root.changed("", newPattern.text.trim().toLowerCase(), newTarget.value)
        newPattern.text = ""
        newTarget.value = ""
      }
    }
  }
}

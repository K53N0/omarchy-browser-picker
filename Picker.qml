// The picker overlay for k53n0.browser-picker.
//
// Summoned by bin/browser-picker over shell IPC, one summon per link. Every
// decision lives here — routing rules, ranking, learning — so the shim can stay
// a shim and there is one implementation of each rule rather than two.
//
// The reply is a ready-to-run argv written NUL-separated into the caller's
// selection file, then the done file is touched to release it. Handing back
// argv rather than a name means no quoting question survives the boundary: a
// profile called `He said "hi"` crosses it unharmed.

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "Model.js" as Model

Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/omarchy/browser-picker.json"
  readonly property string statePath: home + "/.local/state/omarchy/browser-picker.json"
  readonly property string legacyRulesPath: home + "/.config/browser-chooser/rules"
  readonly property string scanPath: Qt.resolvedUrl("bin/browser-picker-scan").toString().replace(/^file:\/\//, "")

  property bool opened: false
  property var entries: []
  property var config: Model.parseConfig("")
  property var pickerState: Model.parseState("")
  property bool stateLoaded: false
  property bool legacyChecked: false

  // The live request. Empty selectionFile means nothing is waiting on us.
  property string selectionFile: ""
  property string doneFile: ""
  property var urls: []
  property var flags: []
  property string host: ""

  property string filter: ""
  property int cursor: 0

  // The output to open on, resolved once per summon rather than bound live: a
  // picker that hops to another screen because focus moved while you were
  // reading it would be worse than one that stays where it appeared.
  property var targetScreen: null

  // Without this the window lands on whichever output Quickshell picked first,
  // which is routinely not the one the link was clicked on — the picker then
  // appears on a screen the user is not looking at. Bar.qml resolves summoned
  // panels the same way.
  function focusedScreen() {
    var monitor = Hyprland.focusedMonitor
    var wanted = monitor ? String(monitor.name || "") : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].name === wanted) return screens[i]
    }
    return screens.length > 0 ? screens[0] : null
  }

  readonly property var rows: Model.rankEntries(
    entries, pickerState, config, host, filter, Date.now() / 1000)
  readonly property var currentEntry:
    rows.length && cursor >= 0 && cursor < rows.length ? rows[cursor] : null

  // Offering to make a habit permanent only makes sense for the row the user is
  // actually about to choose.
  readonly property bool offersRule: !!currentEntry && Model.shouldOfferRule(
    pickerState, config, host, currentEntry, config.settings.promptAfter)

  readonly property string heading: host || (urls.length ? urls[0] : "Open with")

  // ------------------------------------------------------------------ IPC

  // Called by omarchy-shell with the summon payload (shell.qml:541).
  function open(payload) {
    var request = {}
    try { request = JSON.parse(String(payload || "")) || {} } catch (e) { request = {} }

    // The bar asks for the rules window through the same summon entry point.
    // Handled before anything else touches the pending request: a shim waiting
    // on a link must not be released because someone opened a settings screen.
    if (request.view === "rules") { openRules(); return }

    // A second summon while one is pending would strand the first caller's
    // shim polling a done file nobody will ever touch. Release it first.
    if (doneFile) releaseDoneFile(doneFile)

    selectionFile = String(request.selectionFile || "")
    doneFile = String(request.doneFile || "")
    urls = Array.isArray(request.urls) ? request.urls.map(String) : []
    flags = Array.isArray(request.flags) ? request.flags.map(String) : []
    host = urls.length ? Model.hostOf(urls[0]) : ""
    filter = ""
    cursor = 0
    pointerGate.reset()

    // Profiles are added and renamed while the shell runs, so the list is
    // refreshed every time. When we already have one, it is shown immediately
    // and replaced when the rescan lands: a picker that stalls for 80ms on
    // every link reads as broken even when it is merely thorough.
    if (entries.length === 0) scan()
    else { scan(); resolve() }
  }

  function scan() {
    if (scanProcess.running) return
    scanProcess.running = true
  }

  // Decide whether this request needs a human at all.
  function resolve() {
    var rule = host ? Model.matchRule(config.rules, host) : null
    if (rule && config.settings.autoOpenRules) {
      var target = Model.entryById(entries, rule.entryId)
      if (target) { finish(target, false); return }
      // A rule pointing at a profile that no longer exists is stale, not fatal:
      // fall through to the picker rather than refusing to open the link.
    }
    targetScreen = focusedScreen()
    opened = true
    Qt.callLater(function () { filterField.forceActiveFocus() })
  }

  // ------------------------------------------------------------- selection

  function choose(alsoMakeRule) {
    var entry = currentEntry
    if (!entry) { cancel(); return }
    finish(entry, alsoMakeRule === true)
  }

  function finish(entry, alsoMakeRule) {
    var now = Date.now() / 1000
    // Only a choice someone is waiting on counts. Without this guard a stray
    // choose() — a double IPC call, a click landing twice — would inflate the
    // ranking for a launch that never happened, and ranking is only worth
    // anything while it reflects real use.
    var wasPending = doneFile !== ""

    if (entry && !entry.manage && wasPending) {
      pickerState = Model.recordChoice(pickerState, entry.id, host, now)
      stateFile.setText(Model.serializeState(pickerState))

      if (alsoMakeRule && host) {
        var nextRules = Model.upsertRule(config.rules, host, entry.id, true)
        config = Model.parseConfig(JSON.stringify({
          settings: config.settings, rules: nextRules
        }))
        configFile.setText(Model.serializeConfig(config))
      }
    }

    var argv = entry ? [entry.bin].concat(Model.launchArgs(entry, urls, flags)) : []
    deliver(argv)
    opened = false
  }

  function cancel() {
    deliver([])
    opened = false
  }

  // The shell calls close() on `omarchy-shell shell hide <id>` (shell.qml:489).
  // Without it the window would stay up and, worse, the shim that summoned us
  // would poll a done file nobody is ever going to touch. Closing for any
  // reason has to release the caller.
  function close() { if (rulesOpen) closeRules(); else cancel() }

  // ---------------------------------------------------------- rules window

  property bool rulesOpen: false
  property string rulesFilter: ""
  readonly property var visibleRules: Model.filterRules(config.rules, rulesFilter)

  function openRules() {
    rulesFilter = ""
    // The target picker lists profiles, and this entry point skips the link
    // path that normally fills them in — without this the dropdowns open on
    // an empty list and every rule shows a raw id instead of a profile name.
    if (entries.length === 0) scan()
    targetScreen = focusedScreen()
    rulesOpen = true
    Qt.callLater(function () { rulesFilterField.forceActiveFocus() })
  }

  function closeRules() {
    rulesOpen = false
    rulesFilter = ""
  }

  // A rule the user typed is no longer a learned one, so the flag is dropped:
  // "learned" means the picker offered it, and after a hand edit that is no
  // longer the story the list should tell.
  function applyRule(oldPattern, newPattern, entryId) {
    var next = config.rules
    if (oldPattern && oldPattern !== newPattern) next = Model.removeRule(next, oldPattern)
    next = Model.upsertRule(next, newPattern, entryId, false)
    config = Model.parseConfig(JSON.stringify({ settings: config.settings, rules: next }))
    configFile.setText(Model.serializeConfig(config))
  }

  function removeRule(pattern) {
    config = Model.parseConfig(JSON.stringify({
      settings: config.settings,
      rules: Model.removeRule(config.rules, pattern)
    }))
    configFile.setText(Model.serializeConfig(config))
  }

  // One bash call writes the argv and releases the caller, in that order, so
  // the shim can never observe a done file next to a half-written selection.
  function deliver(argv) {
    var activeSelection = selectionFile
    var activeDone = doneFile
    selectionFile = ""
    doneFile = ""
    if (!activeDone) return

    var script = ""
    if (argv.length > 0 && activeSelection) {
      var quoted = []
      for (var i = 0; i < argv.length; i++) quoted.push(Util.shellQuote(String(argv[i])))
      script += "printf '%s\\0' " + quoted.join(" ") + " > " + Util.shellQuote(activeSelection) + "; "
    }
    script += ": > " + Util.shellQuote(activeDone)
    writeProcess.command = ["bash", "-c", script]
    writeProcess.running = true
  }

  function releaseDoneFile(path) {
    if (!path) return
    releaseProcess.command = ["bash", "-c", ": > " + Util.shellQuote(path)]
    releaseProcess.running = true
  }

  // Reachable as `omarchy-shell shell call <id> setFilter <text>`. Exists so the
  // list can be driven without a keyboard — useful for a scripted jump to one
  // profile, and the only way to exercise the narrow-list layout in a test.
  function setFilter(text) {
    filterField.text = String(text || "")
    return String(rows.length)
  }

  function moveCursor(delta) {
    if (!rows.length) { cursor = 0; return }
    pointerGate.reset()
    cursor = Math.max(0, Math.min(rows.length - 1, cursor + delta))
  }

  // Rows sliding under a stationary pointer are not a hover: without the reset
  // the row that happens to land under the cursor while filtering would steal
  // the selection mid-keystroke.
  onRowsChanged: {
    pointerGate.reset()
    if (cursor >= rows.length) cursor = Math.max(0, rows.length - 1)
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: list
  }

  // -------------------------------------------------------------- backing

  Process {
    id: scanProcess
    command: [root.scanPath]
    stdout: StdioCollector {
      id: scanOut
      waitForEnd: true
      onStreamFinished: {
        var parsed = null
        try { parsed = JSON.parse(String(scanOut.text || "")) } catch (e) { parsed = null }
        root.entries = parsed && Array.isArray(parsed.entries) ? parsed.entries : []
        root.importLegacyRules()
        // A request that arrived before the first scan finished is waiting on
        // this: only now is there a list to rank or a rule target to resolve.
        if (root.doneFile && !root.opened) root.resolve()
      }
    }
  }

  // One-time import of the v2 bash chooser's rules file. Runs after the first
  // scan because its targets were label substrings, which only mean something
  // once the labels exist.
  function importLegacyRules() {
    if (legacyChecked || entries.length === 0) return
    legacyChecked = true
    if (config.rules.length > 0) return
    legacyFile.reload()
  }

  FileView {
    id: legacyFile
    path: root.legacyRulesPath
    printErrors: false
    onLoaded: {
      var imported = Model.migrateLegacyRules(text(), root.entries)
      if (imported.length === 0) return
      root.config = Model.parseConfig(JSON.stringify({
        settings: root.config.settings, rules: imported
      }))
      configFile.setText(Model.serializeConfig(root.config))
    }
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.config = Model.parseConfig(text())
    onLoadFailed: root.config = Model.parseConfig("")
  }

  FileView {
    id: stateFile
    path: root.statePath
    atomicWrites: true
    printErrors: false
    onLoaded: { root.pickerState = Model.parseState(text()); root.stateLoaded = true }
    onLoadFailed: { root.pickerState = Model.parseState(""); root.stateLoaded = true }
  }

  Process { id: writeProcess }
  Process { id: releaseProcess }

  // ----------------------------------------------------------------- view

  PanelWindow {
    id: window

    screen: root.targetScreen
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "browser-picker"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
      MouseArea { anchors.fill: parent; onClicked: root.cancel() }
    }

    Rectangle {
      id: card
      anchors.centerIn: parent

      // A definite height, with the list taking whatever is left over. Deriving
      // it from the content's implicit height instead left the last row sliced
      // in half under the footer, because the list and the card were each
      // waiting on the other to settle.
      //
      // Every gap is summed as the same Style.space() call that draws it rather
      // than as one rounded total: space() scales and rounds per call, so a
      // hand-totalled constant is short by a few pixels at some scales — which
      // is exactly enough to slice the last row when the list is short.
      readonly property int chrome:
        header.height + filterField.height + legend.height
        + Style.space(12)   // header top
        + Style.space(8)    // header → filter
        + Style.space(8)    // filter → list
        + Style.space(8)    // list → legend
        + Style.space(12)   // legend bottom
      readonly property int listHeight:
        Math.max(Style.spacing.popupRowHeight, list.contentHeight)
      // No fixed cap on the list: with thirty-odd profiles, every row that fits
      // on screen is one the user does not have to scroll to. The card still
      // shrinks to its content when there are only a few, so a short list never
      // becomes a tall empty box.
      width: Math.min(parent.width - Style.space(80), Style.space(560))
      height: Math.min(parent.height - Style.space(120), listHeight + chrome)
      radius: Style.cornerRadius
      color: Color.menu.background
      border.width: Style.spacing.hairline
      border.color: Color.menu.border

      // Clicks inside the card must not reach the scrim behind it.
      MouseArea { anchors.fill: parent }

      // The host being opened is the single most useful thing on screen:
      // it is what the choice is about.
      Text {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Style.space(12)
        text: root.heading
        color: Color.menu.text
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        elide: Text.ElideMiddle
      }

      TextField {
        id: filterField
        anchors.top: header.bottom
        anchors.topMargin: Style.space(8)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(12)
        placeholderText: "Type to filter"
        foreground: Color.menu.text
        font.family: Style.font.family
        onTextChanged: { root.filter = text; root.cursor = 0 }

        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Escape) {
            root.cancel(); event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.moveCursor(1); event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.moveCursor(-1); event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            // Ctrl+Enter takes the same choice and makes it the rule for this
            // host, so the offer is one keystroke away from the action it
            // describes rather than a separate screen.
            root.choose((event.modifiers & Qt.ControlModifier) !== 0)
            event.accepted = true
          }
        }
      }

      ListView {
        id: list
        anchors.top: filterField.bottom
        anchors.topMargin: Style.space(8)
        anchors.bottom: legend.top
        anchors.bottomMargin: Style.space(8)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(12)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.rows
        currentIndex: root.cursor
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

        // A filter that matches nothing would otherwise leave a blank card and
        // no clue why, which reads as a broken picker rather than a typo.
        Text {
          anchors.centerIn: parent
          visible: root.rows.length === 0
          text: "No profile matches " + '"' + root.filter + '"'
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
        }

        delegate: Rectangle {
          required property var modelData
          required property int index

          width: ListView.view.width
          // Omarchy's own popup row height, with no padding added on top: a
          // shorter row is another profile visible without scrolling, and with
          // this many profiles that trade is worth making.
          height: Style.spacing.popupRowHeight
          radius: Style.cornerRadius
          color: index === root.cursor ? Color.menu.selectedBackground : "transparent"
          border.width: index === root.cursor ? Style.spacing.hairline : 0
          border.color: Color.menu.selectedBorder

          // The selected row carries an accent bar down its left edge. A tinted
          // background alone is easy to lose against a busy wallpaper behind a
          // translucent theme; a hard vertical edge is not.
          Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Style.space(3)
            radius: parent.radius
            color: Color.accent
            visible: index === root.cursor
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: Style.spacing.rowPaddingX
            anchors.rightMargin: Style.spacing.rowPaddingX
            text: modelData.label
            color: index === root.cursor ? Color.menu.selectedText : Color.menu.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            // Deliberately not onEntered. The overlay appears wherever the
            // pointer happens to be resting, and a plain hover handler hands
            // the selection to whatever row lands under it — so Enter opens a
            // profile the user never looked at. The gate yields the cursor
            // only once the pointer has actually moved.
            onPositionChanged: function (mouse) {
              if (pointerGate.moved(this, mouse)) root.cursor = index
            }
            onClicked: { root.cursor = index; root.choose(false) }
          }
        }
        }

      Text {
        id: legend
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Style.space(12)
        text: root.offersRule
          ? "↵ open   ·   Ctrl+↵ always open " + root.host + " here"
          : "↵ open   ·   ↑↓ move   ·   esc cancel"
        color: root.offersRule ? Color.accent : Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }

  // The full rules list, opened from the bar entry. A separate window rather
  // than a taller popup: once there are more rules than fit at a glance, the
  // popup would have to scroll a list that sits under the settings it belongs
  // to, and neither would be comfortable.
  PanelWindow {
    id: rulesWindow

    screen: root.targetScreen
    visible: root.rulesOpen
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "browser-picker-rules"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.rulesOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
      MouseArea { anchors.fill: parent; onClicked: root.closeRules() }
    }

    Rectangle {
      anchors.centerIn: parent
      width: Math.min(parent.width - Style.space(80), Style.space(620))
      height: Math.min(parent.height - Style.space(120),
                       rulesList.contentHeight + rulesHeader.height
                       + rulesFilterField.height + rulesLegend.height + Style.space(60))
      radius: Style.cornerRadius
      color: Color.menu.background
      border.width: Style.spacing.hairline
      border.color: Color.menu.border

      MouseArea { anchors.fill: parent }

      Text {
        id: rulesHeader
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Style.space(14)
        text: root.config.rules.length === 1
          ? "1 browser routing rule"
          : root.config.rules.length + " browser routing rules"
        color: Color.menu.text
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        elide: Text.ElideRight
      }

      TextField {
        id: rulesFilterField
        anchors.top: rulesHeader.bottom
        anchors.topMargin: Style.space(8)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(14)
        anchors.rightMargin: Style.space(14)
        placeholderText: "Filter by site or profile"
        foreground: Color.menu.text
        font.family: Style.font.family
        onTextChanged: root.rulesFilter = text
        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Escape) { root.closeRules(); event.accepted = true }
        }
      }

      Flickable {
        id: rulesList
        anchors.top: rulesFilterField.bottom
        anchors.topMargin: Style.space(8)
        anchors.bottom: rulesLegend.top
        anchors.bottomMargin: Style.space(8)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(14)
        anchors.rightMargin: Style.space(14)
        clip: true
        contentWidth: width
        contentHeight: rulesColumn.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        RulesView {
          id: rulesColumn
          width: rulesList.width
          editable: true
          entries: root.entries
          rules: root.visibleRules
          foreground: Color.menu.text
          dim: Color.muted
          fontFamily: Style.font.family
          onRemoved: function (pattern) { root.removeRule(pattern) }
          onChanged: function (oldPattern, newPattern, entryId) {
            root.applyRule(oldPattern, newPattern, entryId)
          }
          onEscaped: root.closeRules()
        }
      }

      Text {
        id: rulesLegend
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: Style.space(14)
        text: "edit a site or profile in place   ·   ✕ removes   ·   esc closes"
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }
}

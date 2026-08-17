// Bar entry for k53n0.browser-picker.
//
// The picker itself never needs this: it is summoned by the shim for every
// link. What the bar adds is the housekeeping that has to live somewhere —
// which host goes where, whether rules apply themselves, and the one-time
// business of becoming the default browser.

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "k53n0.browser-picker"

  readonly property string home: Quickshell.env("HOME")
  readonly property string configPath: home + "/.config/omarchy/browser-picker.json"
  readonly property string shimPath:
    Qt.resolvedUrl("bin/browser-picker").toString().replace(/^file:\/\//, "")

  property var config: Model.parseConfig("")
  property string defaultBrowser: ""
  readonly property bool isDefault: defaultBrowser === "browser-picker.desktop"

  // Panel lifecycle contract the shell uses for summon/hide/toggle routing.
  readonly property bool opened: card.open
  readonly property bool popoutSwitchClosing: false

  function open() { root.refresh(); card.open = true }
  function close() { card.open = false }
  function toggle() { if (card.open) card.open = false; else root.open() }
  function closeForPopoutSwitch() { card.open = false }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() { defaultProcess.running = true }

  function saveSettings(patch) {
    var settings = {}
    for (var key in config.settings) settings[key] = config.settings[key]
    for (var field in patch) settings[field] = patch[field]
    config = Model.parseConfig(JSON.stringify({ settings: settings, rules: config.rules }))
    configFile.setText(Model.serializeConfig(config))
  }

  function removeRule(pattern) {
    config = Model.parseConfig(JSON.stringify({
      settings: config.settings,
      rules: Model.removeRule(config.rules, pattern)
    }))
    configFile.setText(Model.serializeConfig(config))
  }

  function launchPicker() {
    Quickshell.execDetached([root.shimPath])
    card.open = false
  }

  function makeDefault() {
    // --set-default copies the .desktop into ~/.local/share/applications and
    // calls xdg-settings. It is not done at install time because
    // `omarchy plugin add` never runs plugin code, by design.
    setDefaultProcess.running = true
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

  Process {
    id: defaultProcess
    command: ["xdg-settings", "get", "default-web-browser"]
    stdout: StdioCollector {
      id: defaultOut
      waitForEnd: true
      onStreamFinished: root.defaultBrowser = String(defaultOut.text || "").trim()
    }
  }

  Process {
    id: setDefaultProcess
    command: [root.shimPath, "--set-default"]
    onExited: root.refresh()
  }

  Component.onCompleted: root.refresh()

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰖟"
    tooltipText: root.isDefault
      ? "Browser picker — " + root.config.rules.length
        + (root.config.rules.length === 1 ? " rule" : " rules")
      : "Browser picker — not the default browser"
    onPressed: function (code) {
      // Middle click skips the housekeeping and just opens a browser, which is
      // the same thing the keybind does.
      if (code === Qt.MiddleButton) root.launchPicker()
      else root.toggle()
    }
  }

  IpcHandler {
    target: "k53n0.browser-picker-settings"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function rules(): string { return JSON.stringify(root.config.rules) }
  }

  PopupCard {
    id: card
    anchorItem: button
    bar: root.bar
    owner: root
    contentWidth: Style.space(380)
    // Sized to its content rather than a fixed height: the rules list grows,
    // and a fixed card simply clipped it — the rules were unreachable. The cap
    // stops a long list from filling the screen, and the flick below scrolls it.
    contentHeight: card.fittedContentHeight(column.implicitHeight, Style.space(620))

    readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
    readonly property color dim: Color.muted

    Flickable {
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        Text {
          width: parent.width
          text: "Browser picker"
          color: card.fg
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.title
          elide: Text.ElideRight
        }

        // Until this is the default browser the plugin does nothing for clicked
        // links, which is most of what it is for — so it leads, and disappears
        // once it is done.
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: !root.isDefault

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Links still open in " + (root.defaultBrowser || "another browser")
              + ". Make this the default to route them through the picker."
            color: card.dim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Button {
            text: "Set as default browser"
            bordered: true
            foreground: card.fg
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onClicked: root.makeDefault()
          }
        }

        Button {
          text: "Open a browser"
          bordered: true
          foreground: card.fg
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: root.launchPicker()
        }

        PanelSeparator { foreground: card.fg }

        PanelSectionHeader {
          text: "List"
          foreground: card.fg
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        Toggle {
          width: parent.width
          label: "Manage rows first"
          description: "Keep the profile-management rows at the top"
          checked: root.config.settings.manageFirst
          foreground: card.fg
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: root.saveSettings({ manageFirst: !checked })
        }

        Toggle {
          width: parent.width
          label: "Plain browsers first"
          description: "Keep browsers without separate profiles above the named ones"
          checked: root.config.settings.genericFirst
          foreground: card.fg
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: root.saveSettings({ genericFirst: !checked })
        }

        PanelSeparator { foreground: card.fg }

        PanelSectionHeader {
          text: "Rules"
          foreground: card.fg
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        Toggle {
          width: parent.width
          label: "Apply rules automatically"
          description: "Open a matching host without showing the picker"
          checked: root.config.settings.autoOpenRules
          foreground: card.fg
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: root.saveSettings({ autoOpenRules: !checked })
        }

        Toggle {
          width: parent.width
          label: "Learn from repeats"
          description: "Offer a permanent rule after " + root.config.settings.promptAfter
            + " identical choices"
          checked: root.config.settings.learnRules
          foreground: card.fg
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: root.saveSettings({ learnRules: !checked })
        }

        RulesView {
          width: parent.width
          rules: root.config.rules
          foreground: card.fg
          dim: card.dim
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onRemoved: function (pattern) { root.removeRule(pattern) }
        }
      }
    }
  }
}

import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Widgets

Item {
  id: root

  property var pluginApi: null
  property var mainInstance: pluginApi?.mainInstance

  readonly property var geometryPlaceholder: panelContainer
  readonly property bool allowAttach: true

  property real contentPreferredWidth: 400 * Style.uiScaleRatio
  property real contentPreferredHeight: 300 * Style.uiScaleRatio

  property var monitorModel: []
  property string selectedSource: ""
  property string selectedDestination: ""
  property string discoveryError: ""
  property string detectedBackend: ""
  readonly property bool sameSelection: selectedSource !== "" && selectedSource === selectedDestination
  readonly property var sourceModel: monitorModel.filter(item => item.key !== selectedDestination)
  readonly property var destinationModel: monitorModel.filter(item => item.key !== selectedSource)

  readonly property bool hasEnoughMonitors: monitorModel.length >= 2
  readonly property bool controlsLocked: !hasEnoughMonitors || discoveryError !== ""

  anchors.fill: parent

  Component.onCompleted: refreshOutputs()
  onVisibleChanged: {
    if (visible) refreshOutputs();
  }

  function refreshOutputs() {
    root.discoveryError = "";
    loadOutputsProc.running = false;
    loadOutputsProc.running = true;
  }

  function startMirror() {
    if (selectedSource === selectedDestination) {
      return;
    }
    mainInstance?.startMirror(selectedSource, selectedDestination);
  }

  function stopMirror() {
    mainInstance?.stopMirror();
  }

  function ensureDifferentSelection() {
    if (!sameSelection || monitorModel.length < 2) {
      return;
    }

    for (let i = 0; i < monitorModel.length; i++) {
      const key = monitorModel[i].key;
      if (key !== selectedSource) {
        selectedDestination = key;
        return;
      }
    }
  }

  onSelectedSourceChanged: ensureDifferentSelection()
  onSelectedDestinationChanged: ensureDifferentSelection()

  function extractNames(value) {
    let names = [];

    if (Array.isArray(value)) {
      for (let i = 0; i < value.length; i++) {
        names = names.concat(extractNames(value[i]));
      }
      return names;
    }

    if (value && typeof value === "object") {
      const keys = ["name", "output", "output_name"];
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i];
        if (typeof value[key] === "string" && value[key].length > 0) {
          names.push(value[key]);
        }
      }

      const objectKeys = Object.keys(value);
      for (let i = 0; i < objectKeys.length; i++) {
        const child = value[objectKeys[i]];
        if (child && typeof child === "object") {
          names = names.concat(extractNames(child));
        }
      }
    }

    return names;
  }

  Process {
    id: loadOutputsProc
    command: ["sh", "-c", "if command -v wlr-randr >/dev/null 2>&1; then echo '__BACKEND__:wlr-randr'; wlr-randr --json 2>/dev/null; elif command -v hyprctl >/dev/null 2>&1; then echo '__BACKEND__:hyprctl'; hyprctl -j monitors 2>/dev/null; elif command -v swaymsg >/dev/null 2>&1; then echo '__BACKEND__:swaymsg'; swaymsg -t get_outputs -r 2>/dev/null; elif command -v niri >/dev/null 2>&1; then echo '__BACKEND__:niri'; niri msg -j outputs 2>/dev/null; else echo '__BACKEND__:none'; fi"]
    running: false

    stdout: StdioCollector {
      onStreamFinished: {
        const lines = text.split("\n");
        let backend = "";
        let jsonLines = [];

        for (let i = 0; i < lines.length; i++) {
          const line = lines[i].trim();
          if (line.startsWith("__BACKEND__:")) {
            backend = line.replace("__BACKEND__:", "").trim();
          } else if (line.length > 0) {
            jsonLines.push(lines[i]);
          }
        }

        root.detectedBackend = backend;

        if (backend === "none") {
          root.monitorModel = [];
          root.discoveryError = pluginApi?.tr("panel.discoveryError.noBackendFound");
          return;
        }

        const jsonText = jsonLines.join("\n").trim();
        if (jsonText.length === 0) {
          root.monitorModel = [];
          root.discoveryError = pluginApi?.tr("panel.discoveryError.noDataFromBackend", { backend: backend });
          return;
        }

        let names = [];
        try {
          const parsed = JSON.parse(jsonText);
          names = extractNames(parsed);
        } catch (e) {
          root.monitorModel = [];
          root.discoveryError = pluginApi?.tr("panel.discoveryError.parseFailed", { backend: backend });
          return;
        }

        const unique = [];
        const seen = {};
        for (let i = 0; i < names.length; i++) {
          const name = String(names[i]).trim();
          if (name.length === 0 || seen[name]) {
            continue;
          }
          seen[name] = true;
          unique.push(name);
        }

        if (unique.length === 0) {
          root.discoveryError = pluginApi?.tr("panel.discoveryError.noMonitorsDetected", { backend: backend });
        }

        root.monitorModel = unique.map(name => ({
          key: name,
          name: name
        }));

        if (unique.length > 0) {
          if (!root.selectedSource || unique.indexOf(root.selectedSource) === -1) {
            root.selectedSource = unique[0];
          }

          let preferredDest = unique.length > 1 ? unique[1] : unique[0];
          if (!root.selectedDestination || unique.indexOf(root.selectedDestination) === -1 || root.selectedDestination === root.selectedSource) {
            root.selectedDestination = preferredDest;
          }

          if (root.selectedDestination === root.selectedSource && unique.length > 1) {
            for (let i = 0; i < unique.length; i++) {
              if (unique[i] !== root.selectedSource) {
                root.selectedDestination = unique[i];
                break;
              }
            }
          }
        }
      }
    }

    stderr: StdioCollector {
      onStreamFinished: {
        const msg = text.trim();
        if (msg.length > 0 && root.monitorModel.length === 0) {
          root.discoveryError = msg;
        }
      }
    }
  }

  Rectangle {
    id: panelContainer
    anchors.fill: parent
    color: "transparent"

    ColumnLayout {
      anchors {
        fill: parent
        margins: Style.marginL
      }
      spacing: Style.marginM


      NText {
        Layout.fillWidth: true
        text: pluginApi?.tr("panel.title")
        pointSize: Style.fontSizeL
        font.weight: Font.DemiBold
        color: Color.mOnSurface
      }

      NText {
        Layout.fillWidth: true
        text: pluginApi?.tr("panel.subtitle")
        pointSize: Style.fontSizeS
        color: Color.mOnSurfaceVariant
        wrapMode: Text.WordWrap
      }

      NComboBox {
        Layout.fillWidth: true
        label: pluginApi?.tr("panel.source.label")
        description: pluginApi?.tr("panel.source.description")
        model: root.sourceModel
        currentKey: root.selectedSource
        enabled: !(mainInstance?.mirroringActive ?? false) && !root.controlsLocked
        onSelected: key => root.selectedSource = key
      }

      NComboBox {
        Layout.fillWidth: true
        label: pluginApi?.tr("panel.destination.label")
        description: pluginApi?.tr("panel.destination.description")
        model: root.destinationModel
        currentKey: root.selectedDestination
        enabled: !(mainInstance?.mirroringActive ?? false) && !root.controlsLocked
        onSelected: key => root.selectedDestination = key
      }

      NText {
        Layout.fillWidth: true
        visible: root.sameSelection
        text: pluginApi?.tr("panel.validation.sameSelection")
        pointSize: Style.fontSizeS
        color: Color.mError
      }

      NText {
        Layout.fillWidth: true
        visible: !root.hasEnoughMonitors
        text: pluginApi?.tr("panel.validation.needTwoMonitors")
        pointSize: Style.fontSizeS
        color: Color.mError
      }

      NText {
        Layout.fillWidth: true
        visible: root.discoveryError !== ""
        text: root.discoveryError
        pointSize: Style.fontSizeS
        color: Color.mError
        wrapMode: Text.WordWrap
      }

      NText {
        Layout.fillWidth: true
        visible: (mainInstance?.lastError ?? "") !== ""
        text: mainInstance?.lastError ?? ""
        pointSize: Style.fontSizeS
        color: Color.mError
        wrapMode: Text.WordWrap
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.marginS


        NButton {
          Layout.fillWidth: true
          text: pluginApi?.tr("panel.actions.refresh")
          icon: "refresh"
          enabled: !(mainInstance?.mirroringActive ?? false)
          onClicked: root.refreshOutputs()
        }

        NButton {
          Layout.fillWidth: true
          text: pluginApi?.tr("panel.actions.start")
          icon: "media-play"
          backgroundColor: Color.mPrimary
          textColor: Color.mOnPrimary
          enabled: !(mainInstance?.mirroringActive ?? false)
              && !root.controlsLocked
              && root.selectedSource !== ""
              && root.selectedDestination !== ""
              && !root.sameSelection
          onClicked: root.startMirror()
        }
      }

      NButton {
        Layout.fillWidth: true
        visible: mainInstance?.mirroringActive ?? false
        text: pluginApi?.tr("panel.actions.stop")
        icon: "stop"
        backgroundColor: Color.mError
        textColor: Color.mOnError
        enabled: true
        onClicked: root.stopMirror()
      }
    }
  }
}

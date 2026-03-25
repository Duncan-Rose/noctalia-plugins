import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Widgets

ColumnLayout {
  id: root

  property var pluginApi: null

  spacing: Style.marginL

  NText {
    Layout.fillWidth: true
    text: pluginApi?.tr("settings.description")
    pointSize: Style.fontSizeM
    color: Color.mOnSurface
    wrapMode: Text.WordWrap
  }

  NText {
    Layout.fillWidth: true
    text: pluginApi?.tr("settings.dependency")
    pointSize: Style.fontSizeS
    color: Color.mOnSurfaceVariant
  }

  function saveSettings() {
    pluginApi?.saveSettings();
  }
}

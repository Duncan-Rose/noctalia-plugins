import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Services.UI

Item {
  id: root

  property var pluginApi: null

  // Reactive state consumed by BarWidget and Panel
  property var profiles: []
  property var profileMeta: ({})
  property string lastAppliedProfile: pluginApi?.pluginSettings?.lastAppliedProfile || ""
  property bool isBusy: false

  // ─── Helpers ────────────────────────────────────────────────────────────────

  function _pluginIcon() {
    return pluginApi?.pluginSettings?.icon ||
           pluginApi?.manifest?.metadata?.defaultSettings?.icon ||
           "bookmark"
  }

  function _profilesDir() {
    var dir = pluginApi?.pluginSettings?.profilesDir || ""
    if (!dir || dir.trim() === "")
      dir = Settings.configDir + "profiles/"
    return dir.endsWith("/") ? dir : dir + "/"
  }

  function _backupsDir() {
    return _profilesDir() + "_backups/"
  }

  function _profilePath(name) {
    return _profilesDir() + name.trim()
  }

  function _timestamp() {
    var now = new Date()
    var pad = function(n) { return String(n).padStart(2, '0') }
    return now.getFullYear() + '-' + pad(now.getMonth() + 1) + '-' + pad(now.getDate()) +
           '_' + pad(now.getHours()) + '-' + pad(now.getMinutes()) + '-' + pad(now.getSeconds())
  }

  function profileExists(name) {
    return root.profiles.indexOf(name ? name.trim() : "") !== -1
  }

  function validateName(name) {
    if (!name || name.trim() === "")
      return pluginApi?.tr("error.name-empty") || "Name cannot be empty"
    var t = name.trim()
    if (t.length > 64)
      return pluginApi?.tr("error.name-too-long") || "Name is too long"
    if (/[\/\\.:<>"|?*\x00-\x1f]/.test(t))
      return pluginApi?.tr("error.name-invalid") || "Name contains invalid characters"
    return ""
  }

  // ─── Process: directory listing ─────────────────────────────────────────────

  Process {
    id: listProc
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    onExited: function(exitCode, exitStatus) {
      var names = []
      var meta = {}
      if (exitCode === 0) {
        var lines = listProc.stdout.text.split('\n')
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i]
          if (line.trim() === "") continue
          var parts = line.split('\t')
          var name = parts[0].trim()
          var savedAt = parts.length > 1 ? parts[1].trim() : ""
          if (name && !name.startsWith('.') && !name.startsWith('_')) {
            names.push(name)
            meta[name] = { savedAt: savedAt }
          }
        }
      }
      Logger.i("ShellProfiles", "Profiles found:", names.length)
      root.profiles = names
      root.profileMeta = meta
    }
  }

  // ─── Process: general commands ──────────────────────────────────

  Process {
    id: cmdProc
    stdout: StdioCollector {}
    stderr: StdioCollector {}
    property var pendingCallback: null
    onExited: function(exitCode, exitStatus) {
      var cb = pendingCallback
      pendingCallback = null
      if (cb) cb(exitCode, cmdProc.stdout.text, cmdProc.stderr.text)
    }
  }

  function _runCommand(cmd, callback) {
    cmdProc.pendingCallback = callback
    cmdProc.command = cmd
    cmdProc.running = true
  }

  // ─── Backup helpers ──────────────────────────────────────────────────────────

  function _createBackup(beforeProfileName, callback) {
    var backupsDir = _backupsDir()
    var ts = _timestamp()
    var backupDir = backupsDir + ts
    var cfg = Settings.configDir
    var metaJson = JSON.stringify({
      "savedAt": new Date().toISOString(),
      "description": "auto-backup before applying: " + beforeProfileName
    })

    // Build wallpapers JSON from current state
    var screens = []
    try {
      var wmap = WallpaperService.currentWallpapers
      for (var wkey in wmap) {
        var we = wmap[wkey]
        if (!we) continue
        var wl = (typeof we === "string") ? we : (we.light || "")
        var wd = (typeof we === "string") ? we : (we.dark  || "")
        screens.push({ "name": wkey, "light": wl, "dark": wd })
      }
    } catch (e) {}
    var wallJson = JSON.stringify({ "screens": screens }, null, 2)

    var copyCmd = [
      "sh", "-c",
      'mkdir -p "' + backupDir + '" && ' +
      'cp -f "' + cfg + 'settings.json" "' + backupDir + '/settings.json" 2>/dev/null || true; ' +
      'cp -f "' + cfg + 'colors.json" "' + backupDir + '/colors.json" 2>/dev/null || true; ' +
      '{ [ -f "' + cfg + 'plugins.json" ] && cp -f "' + cfg + 'plugins.json" "' + backupDir + '/plugins.json" || true; }; ' +
      'exit 0'
    ]
    _runCommand(copyCmd, function(code) {
      if (code !== 0) { if (callback) callback(); return }
      // Write wallpapers
      _runCommand(["python3", "-c", "import sys; open(sys.argv[1],'w').write(sys.argv[2])",
                   backupDir + "/wallpapers.json", wallJson], function() {
        // Write meta
        _runCommand(["python3", "-c", "import sys; open(sys.argv[1],'w').write(sys.argv[2])",
                     backupDir + "/meta.json", metaJson], function() {
          Logger.i("ShellProfiles", "Backup created:", ts)
          _pruneBackups(backupsDir, callback)
        })
      })
    })
  }

  function _pruneBackups(backupsDir, callback) {
    var maxCount = Math.max(1, Math.min(20, pluginApi?.pluginSettings?.backupCount ?? 5))
    var listCmd = [
      "sh", "-c",
      'find "' + backupsDir + '" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -n -' + maxCount
    ]
    _runCommand(listCmd, function(code, stdout) {
      var toDelete = (stdout || "").trim().split('\n').filter(function(s) { return s.trim() !== "" })
      if (toDelete.length > 0) {
        _runCommand(["rm", "-rf"].concat(toDelete), function() {
          Logger.i("ShellProfiles", "Pruned", toDelete.length, "old backup(s)")
          if (callback) callback()
        })
      } else {
        if (callback) callback()
      }
    })
  }

  // ─── IPC handlers ────────────────────────────────────────────────────────────

  IpcHandler {
    target: "plugin:shell-profiles"

    function toggleProfiles() {
      if (!pluginApi) return
      pluginApi.withCurrentScreen(screen => {
        pluginApi.togglePanel(screen)
      })
    }

    function applyProfile(name: string) {
      if (!pluginApi || !name) return
      var includeWallpapers = pluginApi.pluginSettings?.includeWallpapers ?? true
      root.applyProfile(name, includeWallpapers)
    }
  }

  // ─── Lifecycle ───────────────────────────────────────────────────────────────

  Component.onCompleted: {
    Logger.i("ShellProfiles", "Main loaded")
    Quickshell.execDetached(["mkdir", "-p", _profilesDir()])
    Quickshell.execDetached(["mkdir", "-p", _backupsDir()])
    listProfiles()
  }

  // ─── Public API ──────────────────────────────────────────────────────────────

  function listProfiles() {
    if (listProc.running) return
    // Python reads each profile dir and extracts savedAt from meta.json
    var pyScript =
      "import json,os,sys\n" +
      "d=sys.argv[1]\n" +
      "if not os.path.isdir(d): sys.exit(0)\n" +
      "entries=sorted(e for e in os.listdir(d) if os.path.isdir(os.path.join(d,e)) and not e.startswith('_') and not e.startswith('.'))\n" +
      "for name in entries:\n" +
      "  s=''\n" +
      "  try:\n" +
      "    with open(os.path.join(d,name,'meta.json')) as f: s=json.load(f).get('savedAt','')\n" +
      "  except: pass\n" +
      "  print(name+'\\t'+s)\n"
    listProc.command = ["python3", "-c", pyScript, _profilesDir()]
    listProc.running = true
  }

  function saveProfile(name, callback) {
    var err = validateName(name)
    if (err) { if (callback) callback(false, err); return }

    var trimmed = name.trim()
    var dirPath = _profilePath(trimmed)
    var cfg = Settings.configDir
    var savedAt = new Date().toISOString()

    // Build wallpapers JSON from current WallpaperService state
    var screens = []
    try {
      var map = WallpaperService.currentWallpapers
      for (var key in map) {
        var entry = map[key]
        if (!entry) continue
        var light = (typeof entry === "string") ? entry : (entry.light || "")
        var dark  = (typeof entry === "string") ? entry : (entry.dark  || "")
        screens.push({ "name": key, "light": light, "dark": dark })
      }
    } catch (e) {
      Logger.w("ShellProfiles", "Could not read WallpaperService:", e)
    }
    var wallpapersJson = JSON.stringify({ "screens": screens }, null, 2)
    var metaJson = JSON.stringify({ "savedAt": savedAt })

    var copyCmd = [
      "sh", "-c",
      'mkdir -p "' + dirPath + '" && ' +
      'cp -f "' + cfg + 'settings.json" "' + dirPath + '/settings.json" && ' +
      'cp -f "' + cfg + 'colors.json" "' + dirPath + '/colors.json" && ' +
      '{ [ -f "' + cfg + 'plugins.json" ] && cp -f "' + cfg + 'plugins.json" "' + dirPath + '/plugins.json" || true; }'
    ]

    isBusy = true
    _runCommand(copyCmd, function(code, stdout, stderr) {
      if (code !== 0) {
        root.isBusy = false
        var msg = stderr.trim() || pluginApi?.tr("error.save-failed") || "Failed to save profile"
        Logger.e("ShellProfiles", "Save failed:", msg)
        ToastService.showError(pluginApi?.tr("panel.title") || "Profiles", msg)
        if (callback) callback(false, msg)
        return
      }
      // Write wallpapers.json
      _runCommand(["python3", "-c", "import sys; open(sys.argv[1],'w').write(sys.argv[2])",
                   dirPath + "/wallpapers.json", wallpapersJson], function(wCode, wStdout, wStderr) {
        if (wCode !== 0) {
          root.isBusy = false
          var wmsg = wStderr.trim() || pluginApi?.tr("error.save-failed") || "Failed to save profile"
          Logger.e("ShellProfiles", "Save failed (wallpapers):", wmsg)
          ToastService.showError(pluginApi?.tr("panel.title") || "Profiles", wmsg)
          if (callback) callback(false, wmsg)
          return
        }
        // Write meta.json
        _runCommand(["python3", "-c", "import sys; open(sys.argv[1],'w').write(sys.argv[2])",
                     dirPath + "/meta.json", metaJson], function() {
          root.isBusy = false
          Logger.i("ShellProfiles", "Saved profile:", trimmed)
          root.listProfiles()
          ToastService.showNotice(
            pluginApi?.tr("panel.title") || "Profiles",
            pluginApi?.tr("toast.saved", { "name": trimmed }) || ('Profile "' + trimmed + '" saved'),
            _pluginIcon()
          )
          if (callback) callback(true, "")
        })
      })
    })
  }

  function applyProfile(name, includeWallpapers, callback) {
    var err = validateName(name)
    if (err) { if (callback) callback(false, err); return }

    var trimmed = name.trim()
    var dirPath = _profilePath(trimmed)
    var cfg = Settings.configDir

    var copyConfigFiles = function() {
      var cmd = [
        "sh", "-c",
        '[ -d "' + dirPath + '" ] || { echo "Profile not found: ' + dirPath + '"; exit 1; }; ' +
        '{ [ -f "' + dirPath + '/settings.json" ] && cp "' + dirPath + '/settings.json" "' + cfg + 'settings.json.noctalia-tmp" && mv -f "' + cfg + 'settings.json.noctalia-tmp" "' + cfg + 'settings.json" || true; }; ' +
        '{ [ -f "' + dirPath + '/colors.json" ] && cp "' + dirPath + '/colors.json" "' + cfg + 'colors.json.noctalia-tmp" && mv -f "' + cfg + 'colors.json.noctalia-tmp" "' + cfg + 'colors.json" || true; }; ' +
        '{ [ -f "' + dirPath + '/plugins.json" ] && cp "' + dirPath + '/plugins.json" "' + cfg + 'plugins.json.noctalia-tmp" && mv -f "' + cfg + 'plugins.json.noctalia-tmp" "' + cfg + 'plugins.json" || true; }; ' +
        'exit 0'
      ]
      _runCommand(cmd, function(code, stdout, stderr) {
        root.isBusy = false
        if (code === 0) {
          // Persist the last applied profile name
          root.lastAppliedProfile = trimmed
          if (pluginApi) {
            pluginApi.pluginSettings.lastAppliedProfile = trimmed
            pluginApi.saveSettings()
          }
          Logger.i("ShellProfiles", "Applied profile:", trimmed)
          ToastService.showNotice(
            pluginApi?.tr("panel.title") || "Profiles",
            pluginApi?.tr("toast.applied", { "name": trimmed }) || ('Profile "' + trimmed + '" applied'),
            _pluginIcon()
          )
          if (callback) callback(true, "")
        } else {
          var msg = stderr.trim() || pluginApi?.tr("error.apply-failed") || "Failed to apply profile"
          Logger.e("ShellProfiles", "Apply failed:", msg)
          ToastService.showError(pluginApi?.tr("panel.title") || "Profiles", msg)
          if (callback) callback(false, msg)
        }
      })
    }

    var doApply = function() {
      if (includeWallpapers) {
        _runCommand(["cat", dirPath + "/wallpapers.json"], function(wCode, wStdout) {
          if (wCode === 0) {
            try {
              var data = JSON.parse(wStdout)
              if (data && data.screens && Array.isArray(data.screens)) {
                for (var i = 0; i < data.screens.length; i++) {
                  var entry = data.screens[i]
                  if (!entry || !entry.name) continue
                  if (entry.light)
                    WallpaperService.changeWallpaper(entry.light, entry.name, "light")
                  if (entry.dark && entry.dark !== entry.light)
                    WallpaperService.changeWallpaper(entry.dark, entry.name, "dark")
                }
              }
            } catch (e) {
              Logger.w("ShellProfiles", "Could not parse wallpapers.json:", e)
            }
          }
          copyConfigFiles()
        })
      } else {
        copyConfigFiles()
      }
    }

    isBusy = true

    // Create auto-backup before applying, if enabled
    var backupEnabled = pluginApi?.pluginSettings?.backupEnabled ?? true
    if (backupEnabled) {
      _createBackup(trimmed, doApply)
    } else {
      doApply()
    }
  }

  function deleteProfile(name, callback) {
    var err = validateName(name)
    if (err) { if (callback) callback(false, err); return }

    var trimmed = name.trim()
    isBusy = true
    _runCommand(["rm", "-rf", _profilePath(trimmed)], function(code, stdout, stderr) {
      root.isBusy = false
      if (code === 0) {
        // Clear active profile indicator if we deleted the active one
        if (root.lastAppliedProfile === trimmed) {
          root.lastAppliedProfile = ""
          if (pluginApi) {
            pluginApi.pluginSettings.lastAppliedProfile = ""
            pluginApi.saveSettings()
          }
        }
        Logger.i("ShellProfiles", "Deleted profile:", trimmed)
        root.listProfiles()
        ToastService.showNotice(
          pluginApi?.tr("panel.title") || "Profiles",
          pluginApi?.tr("toast.deleted", { "name": trimmed }) || ('Profile "' + trimmed + '" deleted'),
          _pluginIcon()
        )
        if (callback) callback(true, "")
      } else {
        var msg = stderr.trim() || pluginApi?.tr("error.delete-failed") || "Failed to delete profile"
        Logger.e("ShellProfiles", "Delete failed:", msg)
        ToastService.showError(pluginApi?.tr("panel.title") || "Profiles", msg)
        if (callback) callback(false, msg)
      }
    })
  }

  function renameProfile(oldName, newName, callback) {
    var err = validateName(oldName) || validateName(newName)
    if (err) { if (callback) callback(false, err); return }

    var oldT = oldName.trim()
    var newT = newName.trim()
    if (oldT === newT) { if (callback) callback(true, ""); return }

    isBusy = true
    _runCommand(["mv", _profilePath(oldT), _profilePath(newT)], function(code, stdout, stderr) {
      root.isBusy = false
      if (code === 0) {
        // Keep active profile in sync after rename
        if (root.lastAppliedProfile === oldT) {
          root.lastAppliedProfile = newT
          if (pluginApi) {
            pluginApi.pluginSettings.lastAppliedProfile = newT
            pluginApi.saveSettings()
          }
        }
        Logger.i("ShellProfiles", "Renamed:", oldT, "->", newT)
        root.listProfiles()
        if (callback) callback(true, "")
      } else {
        var msg = stderr.trim() || pluginApi?.tr("error.rename-failed") || "Failed to rename profile"
        Logger.e("ShellProfiles", "Rename failed:", msg)
        ToastService.showError(pluginApi?.tr("panel.title") || "Profiles", msg)
        if (callback) callback(false, msg)
      }
    })
  }

}

import QtQuick
import Quickshell.Io

// Serial busctl call queue + persistent JSON bus monitor, adapted from
// seb-krz/omarchy-connect (MIT). Extended for DeskPhone: monitors
// conversations, telephony, and notifications interfaces.

Item {
  id: root

  signal monitorLine(string line)

  readonly property bool monitorActive: monitorProc.running
  property int callTimeoutMs: 6000
  property string lastErrText: ""

  property var _queue: []
  property var _current: null

  function call(argv, cb) {
    _queue.push({ argv: argv, cb: cb })
    _next()
  }

  function startMonitor() {
    restartTimer.stop()
    monitorProc.running = true
  }

  function stopMonitor() {
    monitorProc.running = false
  }

  function _next() {
    if (_current || _queue.length === 0) return
    _current = _queue.shift()
    lastErrText = ""
    callProc.command = _current.argv
    callTimer.restart()
    callWatchdog.restart()
    callProc.running = true
  }

  function _finish(text) {
    if (!_current) return
    callTimer.stop()
    callWatchdog.stop()
    var cb = _current.cb
    _current = null
    if (cb) cb(text)
    _next()
  }

  Process {
    id: callProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._finish(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.length > 0) root.lastErrText = text.trim()
      }
    }
  }

  Timer {
    id: callTimer
    interval: root.callTimeoutMs
    onTriggered: callProc.running = false
  }

  Timer {
    id: callWatchdog
    interval: 20000
    onTriggered: root._finish("")
  }

  property int _backoffIndex: 0
  readonly property var _backoffs: [1000, 2000, 5000, 10000]

  // Monitor conversations + telephony + notifications in one busctl session.
  Process {
    id: monitorProc
    command: [
      "busctl", "--user", "--json=short", "monitor",
      "--match=interface='org.kde.kdeconnect.device.conversations'",
      "--match=interface='org.kde.kdeconnect.device.telephony'",
      "--match=interface='org.kde.kdeconnect.device.notifications'"
    ]
    stdout: SplitParser {
      onRead: function (segment) { root.monitorLine(segment) }
    }
    onExited: {
      if (!root.monitorActive) return
      restartTimer.interval = root._backoffs[Math.min(root._backoffIndex, root._backoffs.length - 1)]
      root._backoffIndex = root._backoffIndex + 1
      restartTimer.start()
    }
  }

  Timer {
    id: restartTimer
    onTriggered: monitorProc.running = true
  }

  Timer {
    interval: 30000
    running: monitorProc.running
    onTriggered: root._backoffIndex = 0
  }
}

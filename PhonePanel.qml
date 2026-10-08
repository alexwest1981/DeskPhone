import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  // --- device state
  property bool closingFromHost: false
  property string deviceId: ""
  property string deviceName: ""

  // --- tab: 0=SMS, 1=Samtal, 2=Notiser
  property int tab: 0

  // --- SMS state
  property int smsPage: 0          // 0=lista, 1=tråd, 2=nytt
  property var conversations: []
  property int selectedThreadId: -1
  property var threadMessages: []
  property string draftReply: ""
  property string draftNumber: ""
  property string draftBody: ""
  property var pendingSent: []

  // --- Call state
  property bool incomingCall: false
  property string callerNumber: ""
  property string callerName: ""
  property string callState: ""    // "ringing" | "missed" | ""
  property var callLog: []         // { number, name, state, ts }
  property real savedVolume: 1.0
  property bool volumeLowered: false

  // --- Notification state
  property var phoneNotifs: []     // { id, appName, ticker, title, text, ts }

  // --- shared
  property string errorText: ""
  property string hintText: ""
  property bool loading: false
  property bool sending: false

  readonly property bool hasDevice: deviceId !== ""
  readonly property bool smsOk: hasDevice && errorText === ""

  // ------------------------------------------------------------------ IPC
  function open(payloadJson) {
    root.closingFromHost = false
    phoneWindow.visible = true
    bridge.startMonitor()
    pollTimer.restart()
    Qt.callLater(function() {
      if (phoneWindow.visible) root.refreshAll()
    })
    return "ok"
  }

  function close() {
    root.closingFromHost = true
    phoneWindow.visible = false
    bridge.stopMonitor()
    root.closingFromHost = false
    return "ok"
  }

  function toggle() {
    return phoneWindow.visible ? root.close() : root.open("{}")
  }

  function requestClose() {
    if (root.shell && typeof root.shell.hide === "function") {
      root.shell.hide("io.github.alexwest1981.deskphone")
    } else {
      root.close()
    }
    return "ok"
  }

  function ping() { return "ok" }

  function refresh() {
    root.refreshAll()
    return "ok"
  }

  IpcHandler {
    target: "io.github.alexwest1981.deskphone"
    function open(): string  { return root.open("{}") }
    function close(): string { return root.close() }
    function toggle(): string { return root.toggle() }
    function refresh(): string { return root.refresh() }
    function ping(): string  { return "ok" }
  }

  // ------------------------------------------------------------------ Bridge
  PhoneBridge {
    id: bridge
  }

  Connections {
    target: bridge
    function onMonitorLine(line) { root.onMonitorLine(line) }
  }

  // ------------------------------------------------------------------ Device scan
  function refreshAll() {
    if (!hasDevice) {
      scanDevices()
    } else {
      smsConvRefresh()
      notifRefresh()
    }
  }

  function scanDevices() {
    if (scanProc.running) return
    loading = true
    scanProc.running = true
  }

  function onDevices(text) {
    loading = false
    var devs = Model.parseDeviceCliLines(text)
    var wantId = ""
    var wantName = ""
    for (var i = 0; i < devs.length; i++) {
      if (devs[i].id && devs[i].id !== deviceId) {
        wantId = devs[i].id
        wantName = devs[i].name
        break
      }
      if (devs[i].id === deviceId) {
        wantId = devs[i].id
        wantName = devs[i].name
      }
    }
    if (wantId === "") {
      deviceId = ""
      deviceName = ""
      conversations = []
      threadMessages = []
      selectedThreadId = -1
      phoneNotifs = []
      hintText = "Ingen enhet tillgänglig. Öppna KDE Connect på telefonen och se till att den är parad och ansluten."
      return
    }
    var changed = deviceId !== wantId
    deviceId = wantId
    deviceName = wantName
    errorText = ""
    if (changed) {
      conversations = []
      threadMessages = []
      selectedThreadId = -1
      phoneNotifs = []
    }
    smsConvRefresh()
    notifRefresh()
  }

  // ------------------------------------------------------------------ Monitor
  function onMonitorLine(line) {
    var ev = Model.parseMonitor(line)
    if (!ev) return

    // SMS
    if (ev.member === "conversationCreated" || ev.member === "conversationUpdated") {
      var m = Model.msgFromEntry(ev.value)
      if (!m) return
      if (tab === 0 && smsPage === 1 && m.threadId === selectedThreadId) {
        appendThreadMsg(m)
      } else if (tab === 0 && smsPage === 0) {
        smsConvRefresh()
      }
      return
    }
    if (ev.member === "conversationRemoved") {
      if (tab === 0 && smsPage === 0) smsConvRefresh()
      return
    }

    // Telephony: callReceived(sss) → [number, contactName, state]
    if (ev.member === "callReceived") {
      var args = ev.value
      var num   = Array.isArray(args) ? String(args[0] || "") : ""
      var cname = Array.isArray(args) ? String(args[1] || "") : ""
      var state = Array.isArray(args) ? String(args[2] || "") : ""
      root.callerNumber = num
      root.callerName   = cname
      root.callState    = state
      if (state === "ringing") {
        root.incomingCall = true
        root.lowerVolume()
      } else {
        // missed / talking / idle — dismiss popup, log it
        if (root.incomingCall || state === "missed") {
          var entry = { number: num, name: cname, state: state, ts: Date.now() }
          var log = root.callLog.slice()
          log.unshift(entry)
          root.callLog = log.slice(0, 50)
        }
        root.incomingCall = false
        root.restoreVolume()
      }
      return
    }

    // Notifications
    if (ev.member === "notificationPosted" || ev.member === "notificationUpdated") {
      var nid = Model.parseNotifId(ev.value)
      if (nid) fetchNotif(nid)
      return
    }
    if (ev.member === "notificationRemoved") {
      var rid = Model.parseNotifId(ev.value)
      if (rid) {
        root.phoneNotifs = root.phoneNotifs.filter(function(n) { return n.id !== rid })
      }
      return
    }
    if (ev.member === "allNotificationsRemoved") {
      root.phoneNotifs = []
      return
    }
  }

  // ------------------------------------------------------------------ SMS helpers
  function smsConvRefresh() {
    if (!hasDevice) return
    if (loading) return
    loading = true
    var base = smsArgs()
    bridge.call(base.concat(["requestAllConversationThreads"]), function() {
      bridge.call(base.concat(["activeConversations"]), function(text) {
        loading = false
        var entries = Model.decodeList(text)
        if (entries === null) {
          var err = bridge.lastErrText
          if (err) hintText = "DBus-fel: " + err
          return
        }
        hintText = ""
        var list = []
        var seenNums = []
        for (var i = 0; i < entries.length; i++) {
          if (!Model.isMessageEntry(entries[i])) continue
          var m = Model.msgFromEntry(entries[i])
          if (!m) continue
          if (m.addresses) {
            for (var a = 0; a < m.addresses.length; a++) {
              var d = Model.normNum(m.addresses[a])
              if (d) seenNums.push(d)
            }
          }
          list.push({
            threadId: m.threadId,
            title:  Model.titleFor(m),
            body:   Model.stripNewlines(m.body),
            when:   Model.fmtWhen(m.date),
            ts:     m.date
          })
        }
        var now = Date.now()
        var kept = []
        for (var p = 0; p < root.pendingSent.length; p++) {
          var pend = root.pendingSent[p]
          if (now - pend.ts > 30 * 60000) continue
          var matched = false
          for (var s = 0; s < seenNums.length; s++) {
            if (Model.sameNum(pend.num, seenNums[s])) { matched = true; break }
          }
          if (matched) continue
          kept.push(pend)
          list.push({
            threadId: -1,
            title: pend.num,
            body:  pend.body,
            when:  Model.fmtWhen(pend.ts),
            ts:    pend.ts,
            pending: true
          })
        }
        root.pendingSent = kept
        list.sort(function(x, y) { return y.ts - x.ts })
        conversations = list
      })
    })
  }

  function smsArgs() {
    return ["busctl", "--user", "--timeout=6", "--json=short", "call",
            "org.kde.kdeconnect",
            "/modules/kdeconnect/devices/" + deviceId,
            "org.kde.kdeconnect.device.conversations"]
  }

  function openThread(threadId) {
    if (threadId < 0) return
    selectedThreadId = threadId
    threadMessages = []
    smsPage = 1
    var base = smsArgs()
    bridge.call(base.concat(["requestConversation", "xii", String(threadId), "0", "100"]), function() {})
  }

  function backToList() {
    smsPage = 0
    selectedThreadId = -1
    smsConvRefresh()
  }

  function appendThreadMsg(m) {
    var body = String(m.body || "")
    if (!body && (!m.attachments || m.attachments.length === 0)) return
    var arr = threadMessages
    for (var i = 0; i < arr.length; i++) {
      if (arr[i].uid !== 0 && arr[i].uid === m.uid && arr[i].date === m.date) return
    }
    arr.push({ body: body, me: !Model.isIncoming(m), date: m.date, uid: m.uid })
    arr.sort(function(a, b) { return a.date - b.date })
    threadMessages = arr.slice(-500)
    threadList.positionViewAtEnd()
  }

  function sendReply() {
    var msg = draftReply.trim()
    if (msg === "" || selectedThreadId < 0 || sending) return
    sending = true
    errorText = ""
    var base = smsArgs()
    bridge.call(base.concat(["replyToConversation", "xsav", String(selectedThreadId), msg, "0"]), function() {
      sending = false
      draftReply = ""
      appendThreadMsg({ body: msg, me: true, date: Date.now(), uid: 0 })
      var base2 = smsArgs()
      bridge.call(base2.concat(["requestConversation", "xii", String(selectedThreadId), "0", "100"]), function() {})
    })
  }

  function openNew() { smsPage = 2; draftNumber = ""; draftBody = "" }

  function sendNew() {
    var num = draftNumber.trim()
    var msg = draftBody.trim()
    if (num === "" || msg === "" || !hasDevice || sendProc.running) {
      errorText = "Fyll i mottagarnummer och meddelande."
      return
    }
    errorText = ""
    sendProc.command = ["kdeconnect-cli", "--device", deviceId,
                        "--send-sms", msg, "--destination", num]
    sendProc.running = true
  }

  // ------------------------------------------------------------------ Call helpers
  function dismissCall() {
    // Log as missed if we dismiss manually
    if (root.incomingCall) {
      var entry = { number: root.callerNumber, name: root.callerName, state: "avvisad", ts: Date.now() }
      var log = root.callLog.slice()
      log.unshift(entry)
      root.callLog = log.slice(0, 50)
    }
    root.incomingCall = false
    restoreVolume()
  }

  function callFriendlyState(state) {
    if (state === "ringing")  return "Ringde"
    if (state === "missed")   return "Missat"
    if (state === "talking")  return "Besvarad"
    if (state === "avvisad") return "Avvisad"
    return state || "Okänt"
  }

  // ------------------------------------------------------------------ Volume control
  function lowerVolume() {
    if (volumeLowered) return
    volumeLowered = true
    // Spara nuvarande volym
    volGetProc.running = true
  }

  function restoreVolume() {
    if (!volumeLowered) return
    volRestoreProc.command = ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@",
                             String(root.savedVolume)]
    volRestoreProc.running = true
    volumeLowered = false
  }

  Process {
    id: volGetProc
    command: ["wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // "Volume: 0.75" → parseFloat
        var match = text.match(/Volume:\s*([\d.]+)/)
        if (match) {
          root.savedVolume = parseFloat(match[1])
        }
        // Sänk till 15%
        volSetProc.running = true
      }
    }
  }

  Process {
    id: volSetProc
    command: ["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "0.15"]
  }

  Process {
    id: volRestoreProc
  }

  // ------------------------------------------------------------------ Notification helpers
  function notifRefresh() {
    if (!hasDevice) return
    bridge.call([
      "busctl", "--user", "--timeout=6", "--json=short", "call",
      "org.kde.kdeconnect",
      "/modules/kdeconnect/devices/" + deviceId + "/notifications",
      "org.kde.kdeconnect.device.notifications",
      "activeNotifications"
    ], function(text) {
      try {
        var o = JSON.parse(text)
        var ids = Model.unwrap(o)
        if (!Array.isArray(ids)) return
        for (var i = 0; i < ids.length; i++) fetchNotif(String(ids[i]))
      } catch(e) {}
    })
  }

  function fetchNotif(nid) {
    // Get all properties of /notifications/<id>
    bridge.call([
      "busctl", "--user", "--timeout=6", "--json=short", "call",
      "org.kde.kdeconnect",
      "/modules/kdeconnect/devices/" + deviceId + "/notifications/" + nid,
      "org.freedesktop.DBus.Properties", "GetAll", "s",
      "org.kde.kdeconnect.device.notifications.notification"
    ], function(text) {
      try {
        var o = JSON.parse(text)
        o = Model.unwrap(o)
        if (!o || typeof o !== "object") return
        // GetAll returns a{sv} — unwrap gives us a plain object
        var props = Array.isArray(o) ? o[0] : o
        if (!props || typeof props !== "object") return
        var notif = {
          id:       nid,
          appName:  String(props.appName  || props.app_name   || ""),
          ticker:   String(props.ticker   || ""),
          title:    String(props.title    || ""),
          text:     String(props.text     || props.body        || ""),
          isCancelable: Boolean(props.isCancelable),
          ts: Date.now()
        }
        // Deduplicate by id
        var arr = root.phoneNotifs.filter(function(n) { return n.id !== nid })
        arr.unshift(notif)
        root.phoneNotifs = arr.slice(0, 100)
      } catch(e) {}
    })
  }

  function dismissNotif(nid) {
    bridge.call([
      "busctl", "--user", "--timeout=6", "call",
      "org.kde.kdeconnect",
      "/modules/kdeconnect/devices/" + deviceId + "/notifications/" + nid,
      "org.kde.kdeconnect.device.notifications.notification", "dismiss"
    ], function() {
      root.phoneNotifs = root.phoneNotifs.filter(function(n) { return n.id !== nid })
    })
  }

  // ------------------------------------------------------------------ Processes
  Process {
    id: scanProc
    command: ["kdeconnect-cli", "-a", "--id-name-only"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onDevices(text)
    }
  }

  Process {
    id: sendProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.pendingSent = root.pendingSent.concat([{
          num:  root.draftNumber.trim(),
          body: root.draftBody.trim(),
          ts:   Date.now()
        }]).slice(-25)
        errorText = ""
        draftBody = ""
        draftNumber = ""
        smsPage = 0
        smsConvRefresh()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (text && text.trim() !== "") root.errorText = "Kunde inte skicka: " + text.trim()
      }
    }
  }

  Timer {
    id: pollTimer
    interval: 6000
    repeat: true
    running: phoneWindow.visible
    onTriggered: {
      if (!hasDevice) scanDevices()
      else {
        if (tab === 0 && smsPage !== 1) smsConvRefresh()
        if (tab === 2) notifRefresh()
      }
    }
  }

  // ================================================================== Window
  FloatingWindow {
    id: phoneWindow
    title: "DeskPhone"
    color: Color.background
    implicitWidth: 900
    implicitHeight: 640
    minimumSize: Qt.size(620, 480)
    visible: false

    Column {
      anchors.fill: parent
      spacing: 0

      // ---- title bar
      Rectangle {
        width: parent.width
        height: 40
        color: Color.bar.background

        MouseArea { anchors.fill: parent; onPressed: phoneWindow.startSystemMove() }

        Text {
          id: winTitle
          anchors.left: parent.left
          anchors.leftMargin: 14
          anchors.verticalCenter: parent.verticalCenter
          text: "DeskPhone"
          color: Color.bar.text
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Row {
          anchors.left: winTitle.right
          anchors.leftMargin: 12
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          Rectangle {
            width: 7; height: 7; radius: 4
            anchors.verticalCenter: parent.verticalCenter
            color: hasDevice ? "#4f9d69" : Color.urgent
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: hasDevice ? deviceName : "Ingen enhet"
            color: Qt.darker(Color.bar.text, 1.35)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          anchors.right: parent.right
          anchors.rightMargin: 10
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: loading ? "läser…" : ""
            color: Qt.darker(Color.bar.text, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Button {
            text: "↻"
            tooltipText: "Uppdatera enheter/konversationer"
            onClicked: root.refreshAll()
          }
          Button {
            text: "—"
            tooltipText: "Minimera"
            onClicked: phoneWindow.minimized = true
          }
          Button {
            text: "x"
            tooltipText: "Stäng"
            onClicked: root.requestClose()
          }
        }
      }

      // ---- loading bar
      Rectangle {
        width: parent.width
        height: 3
        visible: root.loading
        color: Util.alpha(Color.accent, 0.15)
        clip: true
        Rectangle {
          width: 180; height: parent.height
          color: Color.accent
          NumberAnimation on x {
            from: -parent.parent.width; to: parent.parent.width
            duration: 900; loops: Animation.Infinite
            running: root.loading
          }
        }
      }

      // ---- error bar
      Rectangle {
        width: parent.width
        height: root.errorText ? 28 : 0
        visible: root.errorText !== ""
        color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.12)
        clip: true
        Text {
          anchors { left: parent.left; leftMargin: 14; right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
          text: root.errorText
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }

      // ---- incoming call popup
      Rectangle {
        width: parent.width
        height: root.incomingCall ? 64 : 0
        visible: root.incomingCall
        color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.18)
        clip: true

        Behavior on height { NumberAnimation { duration: 180 } }

        Text {
          anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
          text: "📞"
          font.pixelSize: 24
        }

        Column {
          anchors { left: parent.left; leftMargin: 46; verticalCenter: parent.verticalCenter }
          spacing: 2
          Text {
            text: "Inkommande samtal"
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
          Text {
            text: root.callerName !== "" ? root.callerName + " (" + root.callerNumber + ")" : root.callerNumber
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }

        Button {
          anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
          text: "Avvisa"
          bordered: true
          onClicked: root.dismissCall()
        }
      }

      // ---- tab bar
      Rectangle {
        width: parent.width
        height: 38
        color: Qt.darker(Color.background, 1.05)

        Row {
          anchors.centerIn: parent
          spacing: 0

          Repeater {
            model: [
              { label: "󰍦  SMS",     idx: 0 },
              { label: "󰏲  Samtal",  idx: 1 },
              { label: "󰂚  Notiser", idx: 2 }
            ]
            delegate: Rectangle {
              width: 140; height: 38
              color: root.tab === modelData.idx
                ? Color.background
                : "transparent"

              Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 2
                color: root.tab === modelData.idx ? Color.accent : "transparent"
              }

              Text {
                anchors.centerIn: parent
                text: modelData.label
                color: root.tab === modelData.idx ? Color.foreground : Qt.darker(Color.foreground, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                font.bold: root.tab === modelData.idx
              }

              MouseArea {
                anchors.fill: parent
                onClicked: root.tab = modelData.idx
              }
            }
          }
        }
      }

      // ---- content area
      Item {
        id: contentArea
        width: parent.width
        height: parent.height - 40 - (root.errorText ? 28 : 0) - 38
                - (root.incomingCall ? 64 : 0)

        // ========== TAB 0: SMS ==========
        Item {
          anchors.fill: parent
          visible: root.tab === 0

          // page 0: conversation list
          Rectangle {
            anchors.fill: parent
            visible: root.smsPage === 0
            color: "transparent"

            Column {
              anchors.fill: parent
              spacing: 0

              Rectangle {
                width: parent.width; height: 44
                color: Qt.darker(Color.background, 1.03)

                Text {
                  anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                  text: hasDevice ? "Konversationer" : "Ingen enhet ansluten"
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                Button {
                  anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                  text: "Nytt meddelande"
                  visible: hasDevice
                  onClicked: root.openNew()
                }
              }

              Item {
                width: parent.width
                height: parent.height - 44
                clip: true

                Text {
                  anchors { centerIn: parent; }
                  width: parent.width - 60
                  visible: conversations.length === 0
                  horizontalAlignment: Text.AlignHCenter
                  wrapMode: Text.WordWrap
                  text: root.hintText !== "" ? root.hintText
                      : (loading ? "Läser konversationer…" : "Inga konversationer än.")
                  color: Qt.darker(Color.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }

                ListView {
                  id: convList
                  anchors.fill: parent
                  clip: true
                  model: root.conversations

                  delegate: Rectangle {
                    width: convList.width; height: 62
                    color: index % 2 === 0 ? Qt.darker(Color.background, 1.02) : Qt.darker(Color.background, 1.05)

                    Rectangle {
                      anchors.bottom: parent.bottom
                      width: parent.width; height: 1
                      color: Util.alpha(Color.foreground, 0.07)
                    }

                    Text {
                      anchors { top: parent.top; topMargin: 8; left: parent.left; leftMargin: 14; right: parent.right; rightMargin: 14 }
                      text: modelData.title
                      color: Color.foreground
                      font { family: Style.font.family; pixelSize: Style.font.bodySmall; bold: true }
                      elide: Text.ElideRight
                    }
                    Text {
                      anchors { top: parent.top; topMargin: 28; left: parent.left; leftMargin: 14; right: parent.right; rightMargin: 60 }
                      text: modelData.body
                      // PlainText, never Qt's default AutoText: the body comes from
                      // whoever sent the SMS, and markup in it would make the shell
                      // fetch a URL of their choosing (marketplace review of the
                      // DeskSMS submission, 2026-10-01).
                      textFormat: Text.PlainText
                      color: Qt.darker(Color.foreground, 1.4)
                      font { family: Style.font.family; pixelSize: Style.font.caption; italic: modelData.pending === true }
                      elide: Text.ElideRight
                    }
                    Text {
                      anchors { top: parent.top; topMargin: 8; right: parent.right; rightMargin: 14 }
                      text: modelData.pending ? "skickat" : modelData.when
                      color: modelData.pending ? Color.accent : Qt.darker(Color.foreground, 1.5)
                      font { family: Style.font.family; pixelSize: Style.font.caption; italic: modelData.pending === true }
                    }

                    MouseArea { anchors.fill: parent; onClicked: root.openThread(modelData.threadId) }
                  }
                }
              }
            }
          }

          // page 1: thread view
          Rectangle {
            anchors.fill: parent
            visible: root.smsPage === 1
            color: "transparent"

            Column {
              anchors.fill: parent
              spacing: 0

              Rectangle {
                width: parent.width; height: 40
                color: Qt.darker(Color.background, 1.03)

                Button {
                  anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
                  text: "←"; tooltipText: "Tillbaka till konversationer"
                  onClicked: root.backToList()
                }

                Text {
                  anchors.centerIn: parent
                  text: {
                    for (var i = 0; i < root.conversations.length; i++) {
                      if (root.conversations[i].threadId === root.selectedThreadId)
                        return root.conversations[i].title
                    }
                    return ""
                  }
                  color: Color.foreground
                  font { family: Style.font.family; pixelSize: Style.font.title; bold: true }
                }
              }

              ListView {
                id: threadList
                width: parent.width
                height: parent.height - 40 - 58
                clip: true
                spacing: 8
                model: root.threadMessages
                boundsBehavior: Flickable.StopAtBounds
                onCountChanged: positionViewAtEnd()

                delegate: Item {
                  width: threadList.width
                  height: bubble.height + 8

                  Rectangle {
                    id: bubble
                    anchors { top: parent.top; topMargin: 4 }
                    anchors.right: modelData.me ? parent.right : undefined
                    anchors.rightMargin: 12
                    anchors.left: modelData.me ? undefined : parent.left
                    anchors.leftMargin: 12
                    width: msgCol.width + 22
                    height: msgCol.height + 16
                    radius: 12
                    color: modelData.me ? Qt.darker(Color.accent, 1.05) : Qt.darker(Color.background, 1.35)

                    Column {
                      id: msgCol
                      anchors { top: parent.top; topMargin: 9; left: parent.left; leftMargin: 11 }
                      width: Math.max(Math.min(bodyTxt.implicitWidth, threadList.width * 0.6 - 10), timeText.implicitWidth)
                      spacing: 6

                      Text {
                        id: bodyTxt
                        width: parent.width
                        text: modelData.body
                        // See the thread preview above: an SMS body is untrusted
                        // text and must never be parsed as markup.
                        textFormat: Text.PlainText
                        wrapMode: Text.WordWrap
                        color: modelData.me ? "#ffffff" : Color.foreground
                        font { family: Style.font.family; pixelSize: Style.font.body }
                      }

                      Item {
                        width: parent.width
                        height: timeText.implicitHeight
                        Text {
                          id: timeText
                          anchors.right: parent.right
                          text: Model.fmtWhen(modelData.date)
                          color: modelData.me ? Util.alpha("#ffffff", 0.7) : Qt.darker(Color.foreground, 1.5)
                          font { family: Style.font.family; pixelSize: 10 }
                        }
                      }
                    }
                  }
                }
              }

              Rectangle {
                width: parent.width; height: 58
                color: Qt.darker(Color.background, 1.06)
                border { color: Util.alpha(Color.foreground, 0.06); width: 1 }

                Row {
                  anchors { fill: parent; margins: 8 }
                  spacing: Style.space(8)

                  TextField {
                    id: replyField
                    height: 42
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 90 - Style.space(8)
                    placeholderText: "Skriv ett svar…"
                    text: root.draftReply
                    onTextChanged: root.draftReply = text
                    Keys.onReturnPressed: root.sendReply()
                    Keys.onEnterPressed:  root.sendReply()
                  }

                  Button {
                    text: "Skicka"; bordered: true
                    width: 82; height: 42
                    anchors.verticalCenter: parent.verticalCenter
                    enabled: !root.sending
                    onClicked: root.sendReply()
                  }
                }
              }
            }
          }

          // page 2: new message
          Rectangle {
            anchors.fill: parent
            visible: root.smsPage === 2
            color: "transparent"

            Column {
              anchors { fill: parent; margins: 16 }
              spacing: Style.space(10)

              Row {
                width: parent.width; spacing: Style.space(8)
                Button { text: "←"; tooltipText: "Tillbaka"; onClicked: root.smsPage = 0 }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Nytt SMS"
                  color: Color.foreground
                  font { family: Style.font.family; pixelSize: Style.font.title; bold: true }
                }
              }

              Text { text: "Mottagarens telefonnummer"; color: Qt.darker(Color.foreground, 1.4); font { family: Style.font.family; pixelSize: Style.font.caption } }
              TextField {
                width: parent.width
                placeholderText: "t.ex. 0701234567"
                text: root.draftNumber
                onTextChanged: root.draftNumber = text
              }
              Text { text: "Meddelande"; color: Qt.darker(Color.foreground, 1.4); font { family: Style.font.family; pixelSize: Style.font.caption } }
              TextField {
                width: parent.width; height: 110
                placeholderText: "Skriv här…"
                text: root.draftBody
                onTextChanged: root.draftBody = text
              }

              Row {
                width: parent.width; spacing: Style.space(8)
                Button { text: "Skicka SMS"; bordered: true; onClicked: root.sendNew() }
                Button { text: "Avbryt"; onClicked: root.smsPage = 0 }
              }
            }
          }
        }

        // ========== TAB 1: Samtal ==========
        Item {
          anchors.fill: parent
          visible: root.tab === 1

          Column {
            anchors.fill: parent
            spacing: 0

            Rectangle {
              width: parent.width; height: 44
              color: Qt.darker(Color.background, 1.03)
              Text {
                anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                text: "Samtalslogg"
                color: Color.foreground
                font { family: Style.font.family; pixelSize: Style.font.title; bold: true }
              }
            }

            Item {
              width: parent.width
              height: parent.height - 44
              clip: true

              Text {
                anchors.centerIn: parent
                width: parent.width - 60
                visible: root.callLog.length === 0
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: hasDevice ? "Inga samtal registrerade ännu.\nSamtal visas här när KDE Connect rapporterar dem." : "Ingen enhet ansluten."
                color: Qt.darker(Color.foreground, 1.4)
                font { family: Style.font.family; pixelSize: Style.font.body }
              }

              ListView {
                id: callLogList
                anchors.fill: parent
                clip: true
                model: root.callLog

                delegate: Rectangle {
                  width: callLogList.width; height: 56
                  color: index % 2 === 0 ? Qt.darker(Color.background, 1.02) : Qt.darker(Color.background, 1.05)

                  Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width; height: 1
                    color: Util.alpha(Color.foreground, 0.07)
                  }

                  Text {
                    anchors { top: parent.top; topMargin: 8; left: parent.left; leftMargin: 46; right: parent.right; rightMargin: 90 }
                    text: modelData.name !== "" ? modelData.name : modelData.number
                    color: Color.foreground
                    font { family: Style.font.family; pixelSize: Style.font.bodySmall; bold: true }
                    elide: Text.ElideRight
                  }
                  Text {
                    anchors { top: parent.top; topMargin: 28; left: parent.left; leftMargin: 46; right: parent.right; rightMargin: 90 }
                    text: modelData.name !== "" ? modelData.number : ""
                    color: Qt.darker(Color.foreground, 1.5)
                    font { family: Style.font.family; pixelSize: Style.font.caption }
                    elide: Text.ElideRight
                  }

                  Text {
                    anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                    text: modelData.state === "missed" || modelData.state === "avvisad" ? "📵" : "📞"
                    font.pixelSize: 18
                  }

                  Text {
                    anchors { top: parent.top; topMargin: 8; right: parent.right; rightMargin: 14 }
                    text: Model.fmtWhen(modelData.ts)
                    color: Qt.darker(Color.foreground, 1.5)
                    font { family: Style.font.family; pixelSize: Style.font.caption }
                  }
                  Text {
                    anchors { top: parent.top; topMargin: 28; right: parent.right; rightMargin: 14 }
                    text: root.callFriendlyState(modelData.state)
                    color: (modelData.state === "missed" || modelData.state === "avvisad") ? Color.urgent : Qt.darker(Color.foreground, 1.4)
                    font { family: Style.font.family; pixelSize: Style.font.caption }
                  }
                }
              }
            }
          }
        }

        // ========== TAB 2: Notiser ==========
        Item {
          anchors.fill: parent
          visible: root.tab === 2

          Column {
            anchors.fill: parent
            spacing: 0

            Rectangle {
              width: parent.width; height: 44
              color: Qt.darker(Color.background, 1.03)

              Text {
                anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                text: "Notifikationer"
                color: Color.foreground
                font { family: Style.font.family; pixelSize: Style.font.title; bold: true }
              }

              Button {
                anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                text: "Rensa alla"
                visible: root.phoneNotifs.length > 0
                onClicked: {
                  for (var i = 0; i < root.phoneNotifs.length; i++) {
                    root.dismissNotif(root.phoneNotifs[i].id)
                  }
                }
              }
            }

            Item {
              width: parent.width
              height: parent.height - 44
              clip: true

              Text {
                anchors.centerIn: parent
                width: parent.width - 60
                visible: root.phoneNotifs.length === 0
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: hasDevice ? "Inga aktiva notifikationer." : "Ingen enhet ansluten."
                color: Qt.darker(Color.foreground, 1.4)
                font { family: Style.font.family; pixelSize: Style.font.body }
              }

              ListView {
                id: notifList
                anchors.fill: parent
                clip: true
                model: root.phoneNotifs

                delegate: Rectangle {
                  width: notifList.width
                  height: notifCol.height + 20
                  color: index % 2 === 0 ? Qt.darker(Color.background, 1.02) : Qt.darker(Color.background, 1.05)

                  Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width; height: 1
                    color: Util.alpha(Color.foreground, 0.07)
                  }

                  Column {
                    id: notifCol
                    anchors { top: parent.top; topMargin: 10; left: parent.left; leftMargin: 14; right: parent.right; rightMargin: 44 }
                    spacing: 3

                    Text {
                      width: parent.width
                      text: modelData.appName
                      color: Color.accent
                      font { family: Style.font.family; pixelSize: Style.font.caption; bold: true }
                      elide: Text.ElideRight
                    }
                    Text {
                      width: parent.width
                      text: modelData.title !== "" ? modelData.title : modelData.ticker
                      color: Color.foreground
                      font { family: Style.font.family; pixelSize: Style.font.bodySmall; bold: true }
                      wrapMode: Text.WordWrap
                      visible: text !== ""
                    }
                    Text {
                      width: parent.width
                      text: modelData.text
                      color: Qt.darker(Color.foreground, 1.3)
                      font { family: Style.font.family; pixelSize: Style.font.caption }
                      wrapMode: Text.WordWrap
                      visible: text !== "" && text !== modelData.title
                    }
                  }

                  Text {
                    anchors { top: parent.top; topMargin: 10; right: parent.right; rightMargin: 44 }
                    text: Model.fmtWhen(modelData.ts)
                    color: Qt.darker(Color.foreground, 1.5)
                    font { family: Style.font.family; pixelSize: 10 }
                  }

                  Button {
                    anchors { right: parent.right; rightMargin: 6; verticalCenter: parent.verticalCenter }
                    text: "×"
                    tooltipText: "Avfärda"
                    onClicked: root.dismissNotif(modelData.id)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

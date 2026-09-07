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

  property bool closingFromHost: false
  property int page: 0
  property string deviceId: ""
  property string deviceName: ""
  property var conversations: []
  property int selectedThreadId: -1
  property var threadMessages: []
  property string errorText: ""
  property string hintText: ""
  property bool loading: false
  property bool sending: false
  property string draftReply: ""
  property string draftNumber: ""
  property string draftBody: ""
  property int booted: 0
  property var pendingSent: []

  readonly property bool hasDevice: deviceId !== ""
  readonly property bool smsOk: hasDevice && errorText === ""

  function open(payloadJson) {
    root.closingFromHost = false
    smsWindow.visible = true
    bridge.startMonitor()
    pollTimer.restart()
    Qt.callLater(function() {
      if (smsWindow.visible) root.refreshAll()
    })
    return "ok"
  }

  function close() {
    root.closingFromHost = true
    smsWindow.visible = false
    bridge.stopMonitor()
    root.closingFromHost = false
    return "ok"
  }

  function toggle() {
    return smsWindow.visible ? root.close() : root.open("{}")
  }

  function requestClose() {
    if (root.shell && typeof root.shell.hide === "function") {
      root.shell.hide("alex.sms")
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
    target: "alex.sms"
    function open(): string { return root.open("{}") }
    function close(): string { return root.close() }
    function toggle(): string { return root.toggle() }
    function refresh(): string { return root.refresh() }
    function ping(): string { return "ok" }
  }

  SmsBridge {
    id: bridge
  }

  Connections {
    target: bridge
    function onMonitorLine(line) { root.onMonitorLine(line) }
  }

  function refreshAll() {
    if (!hasDevice) {
      scanDevices()
    } else {
      convRefresh()
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
    }
    convRefresh()
  }

  function onMonitorLine(line) {
    var ev = Model.parseMonitor(line)
    if (!ev) return
    if (ev.member === "conversationCreated" || ev.member === "conversationUpdated") {
      var m = Model.msgFromEntry(ev.value)
      if (!m) return
      if (page === 1 && m.threadId === selectedThreadId) {
        appendThreadMsg(m)
      } else if (page === 0) {
        convRefresh()
      }
    } else if (ev.member === "conversationRemoved") {
      if (page === 0) convRefresh()
    }
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

  function convRefresh() {
    if (!hasDevice) return
    if (loading) return
    loading = true
    var base = busctlArgs()
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
            title: Model.titleFor(m),
            body: Model.stripNewlines(m.body),
            when: Model.fmtWhen(m.date),
            ts: m.date
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
            body: pend.body,
            when: Model.fmtWhen(pend.ts),
            ts: pend.ts,
            pending: true
          })
        }
        root.pendingSent = kept
        list.sort(function(x, y) { return y.ts - x.ts })
        conversations = list
      })
    })
  }

  function busctlArgs() {
    return ["busctl", "--user", "--timeout=6", "--json=short", "call",
            "org.kde.kdeconnect",
            "/modules/kdeconnect/devices/" + deviceId,
            "org.kde.kdeconnect.device.conversations"]
  }

  function openThread(threadId) {
    if (threadId < 0) return
    selectedThreadId = threadId
    threadMessages = []
    page = 1
    var base = busctlArgs()
    bridge.call(base.concat(["requestConversation", "xii", String(threadId), "0", "100"]), function() {
      // Messages arrive asynchronously through conversationUpdated signals.
    })
  }

  function backToList() {
    page = 0
    selectedThreadId = -1
    convRefresh()
  }

  function sendReply() {
    var msg = draftReply.trim()
    if (msg === "" || selectedThreadId < 0 || sending) return
    sending = true
    errorText = ""
    var base = busctlArgs()
    bridge.call(base.concat(["replyToConversation", "xsav", String(selectedThreadId), msg, "0"]), function() {
      sending = false
      draftReply = ""
      appendThreadMsg({ body: msg, me: true, date: Date.now(), uid: 0 })
      var base2 = busctlArgs()
      bridge.call(base2.concat(["requestConversation", "xii", String(selectedThreadId), "0", "100"]), function() {})
    })
  }

  function openNew() {
    page = 2
    draftNumber = ""
    draftBody = ""
  }

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
          num: root.draftNumber.trim(),
          body: root.draftBody.trim(),
          ts: Date.now()
        }]).slice(-25)
        errorText = ""
        draftBody = ""
        draftNumber = ""
        page = 0
        convRefresh()
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
    running: smsWindow.visible
    onTriggered: {
      if (!hasDevice) scanDevices()
      else if (page !== 1) convRefresh()
    }
  }

  // ------------------------------------------------------------- chrome
  FloatingWindow {
    id: smsWindow
    title: "DeskSMS"
    color: Color.background
    implicitWidth: 900
    implicitHeight: 640
    minimumSize: Qt.size(620, 480)
    visible: false

    Column {
      anchors.fill: parent
      spacing: 0

      Rectangle {
        width: parent.width
        height: 40
        color: Color.bar.background

        MouseArea {
          anchors.fill: parent
          onPressed: smsWindow.startSystemMove()
        }

        Text {
          id: winTitle
          anchors.left: parent.left
          anchors.leftMargin: 14
          anchors.verticalCenter: parent.verticalCenter
          text: "DeskSMS"
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
            onClicked: smsWindow.minimized = true
          }
          Button {
            text: "x"
            tooltipText: "Stäng"
            onClicked: root.requestClose()
          }
        }
      }

      Rectangle {
        id: loadTrack
        width: parent.width
        height: 3
        visible: root.loading
        color: Util.alpha(Color.accent, 0.15)
        clip: true

        Rectangle {
          id: loadFill
          width: 180
          height: parent.height
          color: Color.accent

          NumberAnimation on x {
            from: -loadTrack.width
            to: loadTrack.width
            duration: 900
            loops: Animation.Infinite
            running: root.loading
          }
        }
      }

      Rectangle {
        width: parent.width
        height: root.errorText ? 28 : 0
        visible: root.errorText !== ""
        color: Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, 0.12)
        clip: true

        Text {
          anchors.left: parent.left
          anchors.leftMargin: 14
          anchors.right: parent.right
          anchors.rightMargin: 14
          anchors.verticalCenter: parent.verticalCenter
          text: root.errorText
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }

      Item {
        width: parent.width
        height: parent.height - 40 - (root.errorText ? 28 : 0)

        // ---- page 0: conversation list
        Rectangle {
          anchors.fill: parent
          visible: root.page === 0
          color: "transparent"

          Column {
            anchors.fill: parent
            spacing: 0

            Rectangle {
              width: parent.width
              height: 44
              color: Qt.darker(Color.background, 1.03)

              Text {
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                text: hasDevice ? "Konversationer" : "Ingen enhet ansluten"
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Button {
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: "Nytt meddelande"
                visible: hasDevice
                onClicked: root.openNew()
              }
            }

            Rectangle {
              width: parent.width
              height: root.hintText && !hasDevice ? 0 : 0
              visible: false
            }

            Item {
              width: parent.width
              height: parent.height - 44
              clip: true

              Text {
                anchors.centerIn: parent
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
                  width: convList.width
                  height: 62
                  color: modelData === undefined ? "transparent" : (index % 2 === 0 ? Qt.darker(Color.background, 1.02) : Qt.darker(Color.background, 1.05))

                  Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: 1
                    color: Util.alpha(Color.foreground, 0.07)
                  }

                  Text {
                    anchors.top: parent.top
                    anchors.topMargin: 8
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    text: modelData.title
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    elide: Text.ElideRight
                  }
                  Text {
                    anchors.top: parent.top
                    anchors.topMargin: 28
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    anchors.right: parent.right
                    anchors.rightMargin: 60
                    text: modelData.body
                    color: Qt.darker(Color.foreground, 1.4)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.italic: modelData.pending === true
                    elide: Text.ElideRight
                  }
                  Text {
                    anchors.top: parent.top
                    anchors.topMargin: 8
                    anchors.right: parent.right
                    anchors.rightMargin: 14
                    text: modelData.pending ? "skickat" : modelData.when
                    color: modelData.pending ? Color.accent : Qt.darker(Color.foreground, 1.5)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.italic: modelData.pending === true
                  }

                  MouseArea {
                    anchors.fill: parent
                    onClicked: root.openThread(modelData.threadId)
                  }
                }
              }
            }
          }
        }

        // ---- page 1: thread
        Rectangle {
          anchors.fill: parent
          visible: root.page === 1
          color: "transparent"

          Column {
            anchors.fill: parent
            spacing: 0

            Rectangle {
              width: parent.width
              height: 40
              color: Qt.darker(Color.background, 1.03)

              Button {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: "←"
                tooltipText: "Tillbaka till konversationer"
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
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
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
                    anchors.top: parent.top
                    anchors.topMargin: 4
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
                      anchors.top: parent.top
                      anchors.topMargin: 9
                      anchors.left: parent.left
                      anchors.leftMargin: 11
                      width: Math.max(Math.min(bodyTxt.implicitWidth, threadList.width * 0.6 - 10), timeText.implicitWidth)
                      spacing: 6

                      Text {
                        id: bodyTxt
                        width: parent.width
                        text: modelData.body
                        wrapMode: Text.WordWrap
                        color: modelData.me ? "#ffffff" : Color.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                      }

                      Item {
                        width: parent.width
                        height: timeText.implicitHeight

                        Text {
                          id: timeText
                          anchors.right: parent.right
                          text: Model.fmtWhen(modelData.date)
                          color: modelData.me ? Util.alpha("#ffffff", 0.7) : Qt.darker(Color.foreground, 1.5)
                          font.family: Style.font.family
                          font.pixelSize: 10
                        }
                      }
                    }
                  }
              }
            }

            Rectangle {
              width: parent.width
              height: 58
              color: Qt.darker(Color.background, 1.06)
              border.color: Util.alpha(Color.foreground, 0.06)
              border.width: 1

              Row {
                anchors.fill: parent
                anchors.margins: 8
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
                  Keys.onEnterPressed: root.sendReply()
                }

                Button {
                  text: "Skicka"
                  bordered: true
                  width: 82
                  height: 42
                  anchors.verticalCenter: parent.verticalCenter
                  enabled: !root.sending
                  onClicked: root.sendReply()
                }
              }
            }
          }
        }

        // ---- page 2: new message
        Rectangle {
          anchors.fill: parent
          visible: root.page === 2
          color: "transparent"

          Column {
            anchors.fill: parent
            anchors.margins: 16
            spacing: Style.space(10)

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                text: "←"
                tooltipText: "Tillbaka"
                onClicked: root.page = 0
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Nytt SMS"
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.title
                font.bold: true
              }
            }

            Text {
              text: "Mottagarens telefonnummer"
              color: Qt.darker(Color.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            TextField {
              width: parent.width
              placeholderText: "t.ex. 0701234567"
              text: root.draftNumber
              onTextChanged: root.draftNumber = text
            }
            Text {
              text: "Meddelande"
              color: Qt.darker(Color.foreground, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            TextField {
              width: parent.width
              height: 110
              placeholderText: "Skriv här…"
              text: root.draftBody
              onTextChanged: root.draftBody = text
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                text: "Skicka SMS"
                bordered: true
                onClicked: root.sendNew()
              }
              Button {
                text: "Avbryt"
                onClicked: root.page = 0
              }
            }
          }
        }
      }
    }
  }
}

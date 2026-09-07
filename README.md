# DeskSMS

Read and reply to your phone's SMS right from your Omarchy desktop, through
[KDE Connect](https://kdeconnect.kde.org/). No cloud, no forwarding service and
no credentials: the plugin talks directly to the local KDE Connect daemon over
D-Bus.

## Features

- **Conversations** – thread list straight from the phone, with sender number,
  unread state and the last message preview.
- **Thread view** – per-conversation history, incoming and outgoing bubbles,
  time-relative timestamps.
- **Reply** – send a reply from the thread. **"Ny"** composes a message to a
  number that isn't in a thread yet.
- **Live updates** – a persistent D-Bus monitor keeps the open conversation
  current when a message arrives (with a bounded reconnect backoff if the bus
  monitor drops).
- **Works from the bar** – one click opens DeskSMS; right-click forces a
  refresh of the already-open window.

## Requirements

- KDE Connect installed and running on this machine (`kdeconnect` / the
  `kdeconnectd` daemon), with `kdeconnect-cli` and `busctl` on `PATH`.
- Your phone paired **and trusted** in KDE Connect, on the same network.
- The **SMS** plugin enabled on the phone (KDE Connect → *Plugins* → *SMS*).
- The phone must expose the conversations interface (recent KDE Connect
  versions do; development targets 26.08.0).

DeskSMS only ever sends to, and reads from, that local daemon – nothing leaves
the machine except the reply you deliberately send.

## Usage

Open the window from the bar widget (DeskSMS) or with:

```
omarchy-shell shell toggle alex.sms '{}'
```

If the plugin can't find the phone it shows the reason (no paired device, SMS
plugin not available, …). Right-click the bar widget or run
`omarchy-shell shell call alex.sms refresh '{}'` to rescan.

## Files

```
alex.sms/
├── manifest.json        plugin manifest (panel + bar widget)
├── BarWidget.qml        bar launcher
├── SmsPanel.qml         root: device scan, conversations, thread UI, send
├── SmsBridge.qml        serial busctl call queue + persistent bus monitor
├── Model.js             decoding of busctl --json=short structs
└── README.md
```

No network, no keys: the panel shells out to `busctl`/`kdeconnect-cli` and reads
their JSON, using the local KDE Connect service as the only data source.

## How it works

The plugin uses two paths to KDE Connect:

- **Request/response** – `busctl --user call` against the
  `org.kde.kdeconnect.device.conversations` interface to list conversations and
  fetch a thread, and `kdeconnect-cli --device … --send-sms` to reply. Calls are
  queued and time-guarded so a hung D-Bus answer can't wedge the UI.
- **Monitor** – `busctl --user monitor` streams signals on that interface, so a
  newly arrived message appears live instead of on a fixed poll.

`busctl --json=short` renders D-Bus structs as JSON arrays; `Model.js` unwraps
variants and maps the positional `ConversationMessage` fields onto readable
objects.

## Development notes

- After editing QML, restart the shell so the running engine picks the files
  up: `omarchy-restart-shell`, then reopen the window.
- Lint plugin QML against the shell UI types:

```
qmllint -I /usr/share/omarchy/shell -I /usr/lib/qt6/qml SmsPanel.qml SmsBridge.qml BarWidget.qml
```

- Runtime errors land in `journalctl --user -t omarchy-shell`.
- The D-Bus surface is that of KDE Connect 26.08.0 (`ConversationMessage` as a
  positional struct). Newer daemons may change field order – update
  `msgFromEntry` in `Model.js` if decoding starts to drift.

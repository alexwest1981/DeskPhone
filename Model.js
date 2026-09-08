// Decoding helpers for busctl --json=short output against the KDE Connect
// conversations D-Bus surface (kdeconnect 26.08.0). busctl renders DBus
// structs as ordered arrays, so ConversationMessage maps positionally:
//   [event, body, addresses, date, type, read, threadID, uID, subID, attachments]
// where addresses = [ [addr], ... ] and attachments = [ [partID, mime, file, uid], ... ]

function unwrap(v) {
  if (v === null || v === undefined) return v
  if (Array.isArray(v)) {
    for (var i = 0; i < v.length; i++) v[i] = unwrap(v[i])
    return v
  }
  if (typeof v === "object") {
    if (typeof v.type === "string" && "data" in v) {
      var t = v.type
      if (t === "v") return unwrap(v.data)
      if (t.charAt(0) === "a") return unwrap(v.data)
      if (t === "s" || t === "x" || t === "t" || t === "u" || t === "i" || t === "d" ||
          t === "b" || t === "o" || t === "g" || t === "y" || t === "q" || t === "n" ||
          t === "h" || t === "ay" || t === "sv") return v.data
      return unwrap(v.data)
    }
    for (var k in v) v[k] = unwrap(v[k])
    return v
  }
  return v
}

function num(x) {
  var n = Number(x)
  return isNaN(n) ? 0 : n
}

function msgFromEntry(x) {
  x = unwrap(x)
  if (x && typeof x === "object" && !Array.isArray(x) && typeof x.thread_id !== "undefined") {
    return {
      event: num(x.event),
      body: String(x.body || ""),
      addresses: rawAddresses(x.addresses),
      date: num(x.date),
      type: num(x.type),
      read: num(x.read),
      threadId: num(x.thread_id),
      uid: num(x.uid !== undefined ? x.uid : x._id),
      subId: num(x.sub_id)
    }
  }
  if (!Array.isArray(x)) return null
  return {
    event: num(x[0]),
    body: String(x[1] !== undefined ? x[1] : ""),
    addresses: rawAddresses(x[2]),
    date: num(x[3]),
    type: num(x[4]),
    read: num(x[5]),
    threadId: num(x[6]),
    uid: num(x[7]),
    subId: num(x[8])
  }
}

function rawAddresses(a) {
  if (!Array.isArray(a)) return []
  var out = []
  for (var i = 0; i < a.length; i++) {
    var e = unwrap(a[i])
    if (Array.isArray(e)) {
      if (typeof e[0] === "string") out.push(e[0])
      else if (e[0] && typeof e[0].address === "string") out.push(e[0].address)
    } else if (e && typeof e.address === "string") {
      out.push(e.address)
    }
  }
  return out
}

function isMessageEntry(x) {
  var v = unwrap(x)
  if (Array.isArray(v) && v.length >= 4 && typeof v[1] === "string") return true
  return false
}

function decodeList(jsonText) {
  try {
    var o = JSON.parse(jsonText)
    o = unwrap(o)
    if (o && Array.isArray(o)) {
      if (o.length > 0 && Array.isArray(o[0]) && o[0].length > 0 &&
          Array.isArray(o[0][0]) && typeof o[0][0][1] === "string") {
        return o[0]
      }
      return o
    }
  } catch (e) {}
  return null
}

function firstOther(m) {
  if (!m) return ""
  if (m.addresses && m.addresses.length > 0) return m.addresses[0]
  return ""
}

function titleFor(m) {
  if (!m) return ""
  if (m.addresses && m.addresses.length > 1) return m.addresses.length + " deltagare"
  return firstOther(m)
}

function isIncoming(m) {
  if (!m) return true
  return m.type === 1
}

function stripNewlines(s) {
  return String(s || "").replace(/\s+/g, " ").trim()
}

function normNum(s) {
  return String(s || "").replace(/[^0-9]/g, "")
}

function sameNum(a, b) {
  var A = normNum(a)
  var B = normNum(b)
  if (!A || !B) return false
  if (A === B) return true
  var k = Math.min(A.length, B.length)
  if (k < 8) return A === B
  return A.slice(-k) === B.slice(-k)
}

function fmtWhen(ms) {
  if (!ms) return ""
  var d = new Date(ms)
  if (isNaN(d.getTime())) return ""
  var now = new Date()
  var sameDay = d.getFullYear() === now.getFullYear() &&
                d.getMonth() === now.getMonth() &&
                d.getDate() === now.getDate()
  function two(n) { return (n < 10 ? "0" : "") + n }
  var hhmm = two(d.getHours()) + ":" + two(d.getMinutes())
  if (sameDay) return hhmm
  return two(d.getDate()) + "/" + two(d.getMonth() + 1) + (d.getFullYear() === now.getFullYear() ? "" : " " + d.getFullYear())
}

function parseMonitor(line) {
  try {
    var o = JSON.parse(line)
    if (!o || o.type !== "signal" || typeof o.member !== "string") return null
    var p = o.payload !== undefined ? o.payload : (o.args !== undefined ? o.args : null)
    var val = p === null ? null : unwrap(p)
    if (Array.isArray(val) && val.length > 0 && Array.isArray(val[0]) &&
        typeof val[0][1] === "string") {
      val = val[0]
    }
    return { member: o.member, path: String(o.path || ""), value: val }
  } catch (e) {
    return null
  }
}

function parseDeviceCliLines(text) {
  var devices = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    if (/^[\d]+ devices? found/.test(line)) continue
    var ws = line.search(/\s/)
    var id = ws < 0 ? line : line.slice(0, ws)
    var name = ws < 0 ? "" : line.slice(ws + 1).trim()
    if (!id || id.length < 8) continue
    devices.push({ id: id, name: name })
  }
  return devices
}

// Parse a notificationPosted/Updated signal value.
// KDE Connect sends the notification ID as a plain string.
function parseNotifId(val) {
  if (typeof val === "string") return val
  if (Array.isArray(val) && val.length > 0) return String(val[0])
  return null
}

// Decode a notification object fetched via busctl get-property / introspect.
// Properties: appName (s), id (s), ticker (s), isCancelable (b), hasReplyId (s)
function decodeNotifProps(jsonText) {
  try {
    var o = JSON.parse(jsonText)
    o = unwrap(o)
    if (!o || typeof o !== "object" || Array.isArray(o)) return null
    return {
      appName:  String(o.appName  || o.app_name   || ""),
      id:       String(o.id       || ""),
      ticker:   String(o.ticker   || ""),
      title:    String(o.title    || ""),
      text:     String(o.text     || o.body        || ""),
      isCancelable: Boolean(o.isCancelable),
      hasReplyId:   String(o.hasReplyId || ""),
      ts: Date.now()
    }
  } catch(e) { return null }
}

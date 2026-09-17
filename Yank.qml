import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "YankHistory.js" as YankHistory

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property bool opened: false
  property string filterText: ""
  property string filterKind: "all" // all | text | links | images | colors
  property int selectedIndex: 0
  property bool cursorActive: false
  // Timestamp of the last keyboard move. Hover must not steal the cursor for a
  // moment afterwards: scrolling slides new rows under a stationary pointer, the
  // dwell timer fires, and the selection jumps back to wherever the mouse sits.
  property double lastKeyboardMove: 0
  property var history: []

  // Actions overlay state
  property bool actionsOpen: false
  property string actionFilter: ""
  property int actionIndex: 0

  // Same directory capture.sh writes images to.
  property string stateDir: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/yank"
  property string historyPath: stateDir + "/history.json"
  property string captureScript: Qt.resolvedUrl("capture.sh").toString().replace("file://", "")
  property string pasteScript: Qt.resolvedUrl("paste.sh").toString().replace("file://", "")
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  // The card frame is a 1px hairline at 40% — not the 2px, full-alpha rule the
  // theme authors for the shell's own popups. At this card size that reads as a
  // heavy near-black box around an otherwise airy surface. Colour still comes
  // from the theme's menu border token, so it follows the theme.
  readonly property var borderSpec: Border.flat(Util.alpha(border, 0.4), 1)
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  // ---- help popup ----
  // Keycaps are a soft white inset rather than a tinted fill: on a light card a
  // white chip reads as a physical key, while a grey chip reads as another
  // button competing with the row text.
  readonly property color keycapFill: Util.alpha("#ffffff", 0.55)
  readonly property color keycapBorder: Util.alpha(foreground, 0.20)
  readonly property color keycapText: Util.alpha(foreground, 0.9)
  // The single primary hint (Enter) takes the theme accent, so the most-used
  // action is the one the eye lands on.
  readonly property color keycapAccentFill: Util.alpha(selectedText, 0.15)
  readonly property color keycapAccentBorder: Util.alpha(selectedText, 0.45)
  readonly property color hintLabel: Util.alpha(foreground, 0.68)
  readonly property color chevron: Util.alpha(foreground, 0.45)
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.space(7)
  property int headerHeight: Style.space(34)
  property int chipsHeight: Style.space(26)
  readonly property int metaFont: Math.max(9, Math.round(Style.font.caption * 0.82))
  readonly property int capHeight: metaFont + Style.space(7)
  // The help popup sizes itself to this stack: divider + three title/row
  // columns + the trailing actions line.
  readonly property int referenceRowHeight: Style.space(15)
  // Sized to the reference, measured from the rendered popup: three columns of
  // title + four rows plus the trailing actions line come to ~150 logical px.
  // Undersizing clipped the right-hand labels; oversizing left dead space.
  readonly property int helpPopupWidth: Style.space(700)
  readonly property int helpPopupHeight: Style.space(180)
  // Help popup over the card, opened by the ? in the header.
  property bool helpOpen: false
  // "shortcuts" or "settings". Ctrl+, opens straight to settings, the way most
  // apps use that chord.
  property string helpTab: "settings"
  function openHelp(tab) {
    if (root.helpOpen && root.helpTab === tab) { root.helpOpen = false; return }
    root.helpTab = tab
    root.helpOpen = true
  }
  property int contentSpacing: Style.space(6)
  property int cardWidth: Math.min(Style.space(720), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(600), panel.height - Style.gapsOut * 2)
  property int rowHeight: Style.space(42)
  property int historyLimit: 200   // max entries; oldest deleted beyond this
  // Delete unpinned entries older than this many days. 0 turns automatic cleanup
  // off. Pinned entries are never removed. Editable in the settings page (Ctrl+,)
  // and persisted next to the history.
  property int maxAgeDays: 30
  property string settingsPath: stateDir + "/settings.json"
  // Kept as text so a half-typed number is not clamped mid-keystroke.
  property string retentionDraft: "30"

  property bool previewOpen: false // explicit: Ctrl+O or the row chevron
  property bool previewAuto: false // true when opened for an image automatically
  readonly property int previewPadding: Style.space(11)
  property color rowHover: Util.alpha(root.foreground, 0.045)
  property color accentSoft: Util.alpha(Color.accent, 0.14)

  readonly property var kinds: [
    { id: "all", label: "All", glyph: "󰌨" },
    { id: "text", label: "Text", glyph: "󰏫" },
    { id: "links", label: "Links", glyph: "󰌹" },
    { id: "images", label: "Images", glyph: "󰋩" },
    { id: "colors", label: "Colors", glyph: "󰏘" }
  ]

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.filterKind = "all"
    root.selectedIndex = 0
    root.cursorActive = false
    root.previewOpen = false
    root.previewAuto = false
    root.helpOpen = false
    root.closeActions()
    root.rebuildDisplay()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  function applyRetention(text) {
    var n = parseInt(String(text || "").trim(), 10)
    if (!isFinite(n) || n < 0) n = 0
    root.maxAgeDays = n
    root.retentionDraft = String(n)
    settingsWriter.setText(JSON.stringify({ maxAgeDays: n }, null, 2) + "\n")
    // Reflect the number at once, and write the pruned result: saveHistory
    // prunes on write, so the file on disk is filtered too.
    root.history = YankHistory.pruneHistory(root.history, root.historyLimit, n)
    root.saveHistory()
    root.rebuildDisplay()
  }

  function loadSettings(raw) {
    var n = 30
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      var v = Number(parsed && parsed.maxAgeDays)
      if (isFinite(v) && v >= 0) n = Math.floor(v)
    } catch (e) {}
    root.maxAgeDays = n
    root.retentionDraft = String(n)
  }

  function loadHistory(raw) {
    var parsed = YankHistory.parseHistory(raw)
    var kept = YankHistory.pruneHistory(parsed, root.historyLimit, root.maxAgeDays)
    root.history = kept
    // Expired entries would otherwise linger in the file: prune on read, then
    // write the result back once, so the retention you configured is actually
    // reflected on disk instead of only in the list.
    // The file itself is filtered by saveHistory (see below); this read only
    // keeps the list honest between writes.
    if (root.opened) root.rebuildDisplay()
  }

  // Retention is enforced here rather than on read. Saving is what every
  // mutation already does, so the file on disk is always filtered — and nothing
  // writes back on load, which would only re-trigger the file watcher and
  // reload the unpruned file over the top of it.
  function saveHistory() {
    root.history = YankHistory.pruneHistory(root.history, root.historyLimit, root.maxAgeDays)
    historyFile.setText(JSON.stringify(root.history, null, 2) + "\n")
  }

  function addClipboardEntry(entry) {
    var normalized = YankHistory.normalizeEntry(entry)
    if (!normalized) return

    root.history = YankHistory.pruneHistory(
      YankHistory.addEntry(root.history, normalized, root.historyLimit),
      root.historyLimit, root.maxAgeDays)
    root.saveHistory()
    if (root.opened) root.rebuildDisplay()
  }

  function addClipboardJson(line) {
    var raw = String(line || "").trim()
    if (!raw) return
    try { root.addClipboardEntry(JSON.parse(raw)) } catch (e) {}
  }

  function sectionRow(label) {
    return {
      entryType: "separator", pinned: false, fullText: "", previewText: "",
      caption: "", isLink: false, isColor: false, isEmail: false, isPath: false,
      isCode: false, previewImage: "", path: "", mime: "",
      sepLabel: label, historyIndex: -1
    }
  }

  readonly property int combinedCount: pinnedModel.count + displayModel.count

  // "Nothing to show" means no rows at all. Testing the recent model alone made
  // an all-pinned list (or a filter whose only matches are pinned) draw the
  // empty state on top of live rows, and locked the actions menu out of it.
  readonly property bool nothingToShow: combinedCount === 0
  // True when the pointer has been still and the keyboard quiet long enough that
  // hover-to-select is welcome again.
  readonly property bool hoverAllowed: Date.now() - lastKeyboardMove > 700
  // "3 / 28" for the focused row, empty when nothing is focused.
  readonly property string positionLabel: cursorActive && combinedCount > 0
                                          ? (selectedIndex + 1) + " / " + combinedCount
                                          : ""

  function rowAt(idx) {
    if (idx < 0) return null
    if (idx < pinnedModel.count) return pinnedModel.get(idx)
    var r = idx - pinnedModel.count
    if (r < displayModel.count) return displayModel.get(r)
    return null
  }

  // Full, uncapped entry text for the preview. Display rows are deliberately
  // capped for list performance; the preview must show the real value.
  function fullTextOf(row) {
    if (!row) return ""
    var entry = root.history[row.historyIndex]
    if (!entry) return row.fullText
    if (entry.type === "image") return ""
    return String(entry.text || "")
  }

  function ensureVisible(idx) {
    if (idx >= pinnedModel.count && resultList.count > 0)
      resultList.positionViewAtIndex(idx - pinnedModel.count, ListView.Contain)
  }

  function canPreview(row) {
    if (!row) return false
    if (row.entryType === "image") return true
    return String(row.previewText || "").length > 0
  }

  // The preview is never shown on its own: it opens on Ctrl+O or by
  // clicking a row's chevron, so long entries cannot ambush the user.
  function togglePreview() {
    root.previewAuto = false
    if (!canPreview(rowAt(root.selectedIndex))) { root.previewOpen = false; return }
    root.previewOpen = !root.previewOpen
  }

  // Images are worth seeing the moment they are selected; text stays opt-in.
  // An auto-opened preview closes again when the selection leaves images, but
  // a preview the user opened deliberately is left alone.
  function syncPreviewToSelection() {
    var row = root.cursorActive ? rowAt(root.selectedIndex) : null
    if (row && row.entryType === "image") {
      root.previewOpen = true
      root.previewAuto = true
    } else if (root.previewAuto) {
      root.previewOpen = false
      root.previewAuto = false
    }
  }

  function rebuildDisplay() {
    var rows = YankHistory.displayRows(root.history, root.filterText, root.filterKind, 100)
    pinnedModel.clear()
    displayModel.clear()
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      appendEntryRow(row.pinned ? pinnedModel : displayModel, row)
    }

    var combined = pinnedModel.count + displayModel.count
    if (combined === 0) selectedIndex = 0
    else if (selectedIndex >= combined) selectedIndex = combined - 1
    else if (selectedIndex < 0) selectedIndex = 0

    Qt.callLater(function() {
      // models are populated now, so the selection can be inspected safely
      syncPreviewToSelection()
      if (root.selectedIndex >= pinnedModel.count && resultList.count > 0)
        resultList.positionViewAtIndex(root.selectedIndex - pinnedModel.count, ListView.Beginning)
    })
  }

  function appendEntryRow(model, row) {
    model.append({
      entryType: row.entryType,
      pinned: row.pinned,
      fullText: row.fullText,
      previewText: row.previewText,
      caption: row.caption,
      isLink: row.isLink,
      isColor: row.isColor,
      isEmail: row.isEmail,
      isPath: row.isPath,
      isCode: row.isCode,
      previewImage: row.previewImage ? Util.fileUrl(row.previewImage) : "",
      path: row.path,
      mime: row.mime,
      historyIndex: row.index
    })
  }

  function select(delta) {
    if (combinedCount === 0) return
    root.lastKeyboardMove = Date.now()
    var wasActive = root.cursorActive
    root.cursorActive = true
    var idx = root.selectedIndex
    if (!wasActive) {
      idx = delta < 0 ? combinedCount - 1 : 0
    } else {
      idx = (idx + delta + combinedCount) % combinedCount
    }
    root.selectedIndex = idx
    ensureVisible(idx)
  }

  // Reorder the selected entry up/down. Only pinned entries are manually
  // orderable — unpinned ones stay recency-sorted, so this is a no-op there.
  function moveSelected(delta) {
    var row = rowAt(selectedIndex)
    if (!row || !row.pinned) return
    var next = YankHistory.moveEntryAt(root.history, row.historyIndex, delta)
    if (!next || next.length === 0) return
    root.history = next
    root.saveHistory()
    root.rebuildDisplay()
    ensureVisible(root.selectedIndex)
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    root.selectedIndex = 0
    // Arm the cursor on the top result. Without this the first Enter after
    // typing only arms it and appears to do nothing, which reads as "paste is
    // broken" when the list is plainly right there.
    root.cursorActive = nextFilter.length > 0
    root.rebuildDisplay()
  }

  function setFilterKind(kind) {
    root.filterKind = kind
    root.selectedIndex = 0
    root.cursorActive = root.filterText.length > 0
    root.previewOpen = false
    root.rebuildDisplay()
  }

  function removeSelected() {
    var row = rowAt(selectedIndex)
    if (!row) return
    root.history = YankHistory.removeEntryAt(root.history, row.historyIndex)
    root.saveHistory()
    root.rebuildDisplay()
  }

  function togglePinSelected() {
    var row = rowAt(selectedIndex)
    if (!row) return
    root.history = YankHistory.togglePinAt(root.history, row.historyIndex)
    root.saveHistory()
    root.rebuildDisplay()
    // Keep the same entry under the cursor even though pinned entries resort.
    for (var i = 0; i < combinedCount; i++) {
      var r = rowAt(i)
      if (r && r.historyIndex === row.historyIndex) {
        root.selectedIndex = i
        ensureVisible(i)
        break
      }
    }
  }

  function clearUnpinned() {
    root.history = YankHistory.clearUnpinned(root.history)
    root.saveHistory()
    root.selectedIndex = 0
    root.cursorActive = false
    root.rebuildDisplay()
  }

  function activeRow() {
    if (!root.cursorActive) return null
    return rowAt(selectedIndex)
  }

  function activateSelected(copyOnly) {
    var row = rowAt(selectedIndex)
    if (!row) return
    root.opened = false
    if (row.entryType === "image") {
      var args = [root.omarchyPath + "/bin/omarchy-clipboard-paste-file"]
      if (copyOnly) args.push("--copy-only")
      args.push(row.mime)
      args.push(row.path)
      Quickshell.execDetached(args)
      return
    }
    // Copy via wl-copy. We deliberately avoid `wtype "$text"`
    // (omarchy-clipboard-paste-text's argument mode): typing arbitrary text
    // through keysyms mangles emoji and other unmapped characters.
    root.deliverText(row.fullText, copyOnly)
  }

  // Pasting. Two routes, because synthesising a keystroke is only reliable for
  // one of them:
  //
  //  * A terminal is pasted into directly, by writing the text to its tty with
  //    bracketed-paste markers. No keystroke, no focus race, and it sidesteps
  //    the fact that Ctrl+V is quoted-insert in a terminal rather than paste.
  //  * Everything else gets a synthesised Ctrl+V, which is what those apps
  //    expect.
  //
  // The window's pid comes from the compositor; walking up its parents finds the
  // tty of the terminal that owns it, if any.
  //
  // The text travels over stdin, never argv: a single argument is capped at
  // 128 KiB by the kernel, and a long entry would silently fail to paste.
  function deliverText(text, copyOnly) {
    if (pasteProc.running) return
    pasteProc.payload = String(text || "")
    pasteProc.command = copyOnly ? ["bash", root.pasteScript, "--copy-only"] : ["bash", root.pasteScript]
    pasteProc.stdinEnabled = true
    pasteProc.running = true
  }


  // ---- Actions overlay ----

  function openActions() {
    if (!root.cursorActive || root.combinedCount === 0) return
    root.actionsOpen = true
    root.actionFilter = ""
    root.actionIndex = 0
    root.rebuildActions()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function closeActions() {
    root.actionsOpen = false
    root.actionFilter = ""
    root.actionIndex = 0
  }

  function rebuildActions() {
    var row = activeRow()
    actionsModel.clear()
    if (!row) return

    var needle = root.actionFilter.toLowerCase()

    function add(id, label, hint) {
      if (needle && label.toLowerCase().indexOf(needle) < 0) return
      actionsModel.append({ actionId: id, label: label, hint: hint })
    }

    if (row.entryType === "image") {
      add("copypath", "Copy image path", "")
      add("openfolder", "Open containing folder", "")
      add("savepic", "Save image to ~/Pictures", "")
    } else {
      if (row.isLink) add("openlink", "Open link", "")
      if (row.isPath) {
        add("openfile", "Open file", "")
        add("openfolder", "Open containing folder", "")
      }
    }
    add("pin", row.pinned ? "Unpin entry" : "Pin entry", "Ctrl+P")
    add("paste", "Paste", "Enter")
    add("copy", "Copy", "Shift+Enter")
    add("remove", "Remove entry", "Del")

    if (root.actionIndex >= actionsModel.count) root.actionIndex = Math.max(0, actionsModel.count - 1)

    Qt.callLater(function() {
      if (actionsList.count > 0) actionsList.positionViewAtIndex(root.actionIndex, ListView.Contain)
    })
  }

  function runActionById(id) {
    var row = activeRow()
    root.closeActions()
    root.opened = false
    if (!row) return

    if (id === "paste") { root.activateSelected(false); return }
    if (id === "copy") { root.activateSelected(true); return }
    if (id === "remove") { root.opened = true; root.removeSelected(); root.opened = false; return }
    if (id === "pin") { root.opened = true; root.togglePinSelected(); root.opened = false; return }

    if (id === "copypath") {
      Quickshell.execDetached(["bash", "-c", "wl-copy --type text/plain < \"$1\"", "bash", row.path])
      return
    }
    // For text entries holding a path, the entry text IS the path.
    var targetPath = row.entryType === "image" ? row.path : String(row.fullText).trim()

    if (id === "openfile") {
      Quickshell.execDetached(["xdg-open", targetPath])
      return
    }
    if (id === "openfolder") {
      var dir = targetPath.substring(0, Math.max(targetPath.lastIndexOf("/"), 0)) || "/"
      Quickshell.execDetached(["xdg-open", dir])
      return
    }
    if (id === "savepic") {
      Quickshell.execDetached(["bash", "-c", "mkdir -p \"$HOME/Pictures\" && cp \"$1\" \"$HOME/Pictures/yank-$(date +%Y%m%d-%H%M%S).png\"", "bash", row.path])
      return
    }
    if (id === "openlink") {
      Quickshell.execDetached(["xdg-open", String(row.fullText).trim()])
      return
    }
  }

  function runActionIndex(index) {
    if (index < 0 || index >= actionsModel.count) return
    root.runActionById(actionsModel.get(index).actionId)
  }

  onSelectedIndexChanged: root.syncPreviewToSelection()

  Component.onCompleted: initProc.running = true

  ListModel { id: displayModel }
  ListModel { id: pinnedModel }
  ListModel { id: actionsModel }

  component KeyCap: Rectangle {
    id: keyCap
    property string label
    property bool primary: false
    width: keyCapLabel.implicitWidth + Style.space(9)
    height: capHeight
    radius: 5
    color: keyCap.primary ? root.keycapAccentFill : root.keycapFill
    border.color: keyCap.primary ? root.keycapAccentBorder : root.keycapBorder
    border.width: 1
    Behavior on color { ColorAnimation { duration: 110 } }
    Behavior on border.color { ColorAnimation { duration: 110 } }

    Text {
      id: keyCapLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: keyCap.label
      color: root.keycapText
      font.family: root.fontFamily
      font.pixelSize: root.metaFont
      font.weight: keyCap.primary ? Font.DemiBold : Font.Normal
    }
  }

  // Aligned shortcut row: a fixed key column plus its description, so every
  // group's labels line up regardless of how many keys a row shows.
  component ShortcutRow: Row {
    id: shortcutRow
    property var keys: []
    property string label
    spacing: Style.space(12)

    Row {
      width: Style.space(96)
      height: root.referenceRowHeight
      spacing: Style.space(3)

      Repeater {
        model: shortcutRow.keys
        delegate: KeyCap { required property string modelData; label: modelData }
      }
    }

    Text {
      textFormat: Text.PlainText
      text: shortcutRow.label
      color: root.hintLabel
      height: root.referenceRowHeight
      verticalAlignment: Text.AlignVCenter
      font.family: root.fontFamily
      font.pixelSize: root.metaFont
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // named group of shortcut rows
  component ShortcutGroup: Column {
    id: shortcutGroup
    property string title
    property var rows: []
    spacing: Style.space(3)

    Text {
      textFormat: Text.PlainText
      text: shortcutGroup.title
      color: root.selectedText
      font.family: root.fontFamily
      font.pixelSize: root.metaFont
      font.letterSpacing: 1.4
      font.weight: Font.DemiBold
      bottomPadding: Style.space(4)
    }

    Repeater {
      model: shortcutGroup.rows
      delegate: ShortcutRow {
        required property var modelData
        keys: modelData.keys
        label: modelData.label
      }
    }
  }


  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  FileView {
    id: historyFile
    path: root.historyPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadHistory(text())
    onLoadFailed: root.loadHistory("[]")
    onFileChanged: reload()
  }

  // The retention choice lives in its own small file so the history file stays a
  // plain array; a missing file simply means "use the default".
  FileView {
    id: settingsReader
    path: root.settingsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadSettings(text())
    onLoadFailed: root.loadSettings("{}")
    onFileChanged: reload()
  }

  FileView {
    id: settingsWriter
    path: root.settingsPath
    atomicWrites: true
    printErrors: false
  }

  Process {
    id: pasteProc
    property string payload: ""
    onStarted: {
      write(payload)
      payload = ""
      // Closing stdin is what tells paste.sh the text is complete.
      stdinEnabled = false
    }
  }

  // Reap watchers left behind by a previous shell instance, then start our own.
  // pdeathsig makes the kernel kill them whenever the shell exits.
  Process {
    id: initProc
    command: ["pkill", "-f", "wl-paste .*--watch " + root.captureScript]
    onExited: {
      textWatchProc.running = true
      imageWatchProc.running = true
    }
  }

  Process {
    id: textWatchProc
    command: ["setpriv", "--pdeathsig", "TERM", "wl-paste", "--type", "text", "--watch", root.captureScript, "text"]
    onExited: watchRestartTimer.restart()
    stdout: SplitParser {
      onRead: function(data) { root.addClipboardJson(data) }
    }
  }

  Process {
    id: imageWatchProc
    command: ["setpriv", "--pdeathsig", "TERM", "wl-paste", "--type", "image/png", "--watch", root.captureScript, "image/png"]
    onExited: watchRestartTimer.restart()
    stdout: SplitParser {
      onRead: function(data) { root.addClipboardJson(data) }
    }
  }

  Timer {
    id: watchRestartTimer
    interval: 1000
    repeat: false
    onTriggered: {
      if (!textWatchProc.running) textWatchProc.running = true
      if (!imageWatchProc.running) imageWatchProc.running = true
    }
  }

  // Enforce maxAgeDays for long-running sessions (entries expire over time).
  Timer {
    interval: 3600000
    repeat: true
    running: root.maxAgeDays > 0
    onTriggered: {
      var pruned = YankHistory.pruneHistory(root.history, root.historyLimit, root.maxAgeDays)
      if (pruned.length !== root.history.length) {
        root.history = pruned
        root.saveHistory()
        if (root.opened) root.rebuildDisplay()
      }
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "de.gransoftware.yank"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      // Grow to fit the content so nothing is crushed by a fixed card height;
      // the list is the flexible part and it caps itself.
      height: Math.max(root.cardHeight, column.implicitHeight + contentTopInset + contentBottomInset)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin
      opacity: root.opened ? 1 : 0
      scale: root.opened ? 1 : 0.985
      Behavior on opacity { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
      Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: root.actionsOpen ? 20 : 0
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          // ---- actions overlay keys ----
          if (root.actionsOpen) {
            if (event.key === Qt.Key_Escape) {
              root.closeActions()
              event.accepted = true
            } else if (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier)) {
              if (actionsModel.count > 0) root.actionIndex = (root.actionIndex - 1 + actionsModel.count) % actionsModel.count
              event.accepted = true
            } else if (event.key === Qt.Key_J && (event.modifiers & Qt.ControlModifier)) {
              if (actionsModel.count > 0) root.actionIndex = (root.actionIndex + 1) % actionsModel.count
              event.accepted = true
            } else if (event.key === Qt.Key_Up) {
              if (actionsModel.count > 0) root.actionIndex = (root.actionIndex - 1 + actionsModel.count) % actionsModel.count
              event.accepted = true
            } else if (event.key === Qt.Key_Down) {
              if (actionsModel.count > 0) root.actionIndex = (root.actionIndex + 1) % actionsModel.count
              event.accepted = true
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.runActionIndex(root.actionIndex)
              event.accepted = true
            } else if (event.key === Qt.Key_Backspace) {
              root.actionFilter = root.actionFilter.slice(0, -1)
              root.rebuildActions()
              event.accepted = true
            } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
              root.actionFilter += event.text
              root.actionIndex = 0
              root.rebuildActions()
              event.accepted = true
            }
            Qt.callLater(function() {
              if (actionsList.count > 0) actionsList.positionViewAtIndex(root.actionIndex, ListView.Contain)
            })
            return
          }

          // ---- main keys ----
          if (event.key === Qt.Key_Escape) {
            if (root.helpOpen) root.helpOpen = false
            else if (root.previewOpen) root.previewOpen = false
            else if (root.filterText) root.setFilter("")
            else root.close()
            event.accepted = true
          } else if (event.key === Qt.Key_O && (event.modifiers & Qt.ControlModifier)) {
            root.togglePreview()
            event.accepted = true
          } else if (event.key === Qt.Key_J && (event.modifiers & Qt.ControlModifier) && (event.modifiers & Qt.ShiftModifier)) {
            root.moveSelected(1)
            event.accepted = true
          } else if (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier) && (event.modifiers & Qt.ShiftModifier)) {
            root.moveSelected(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_K && (event.modifiers & Qt.ControlModifier)) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_J && (event.modifiers & Qt.ControlModifier)) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_P && (event.modifiers & Qt.ControlModifier)) {
            root.togglePinSelected()
            event.accepted = true

          } else if (event.key === Qt.Key_Period && (event.modifiers & Qt.ControlModifier)) {
            root.openActions()
            event.accepted = true
          } else if (event.key === Qt.Key_D && (event.modifiers & Qt.ControlModifier)) {
            // Ctrl+D is the same action as Delete, for people whose habit is
            // Ctrl+D. Both work on pinned entries too; Shift+Delete is the one
            // that clears every unpinned entry at once.
            if (event.modifiers & Qt.ShiftModifier) root.clearUnpinned()
            else root.removeSelected()
            event.accepted = true
          } else if (event.key >= Qt.Key_1 && event.key <= Qt.Key_5 && (event.modifiers & Qt.ControlModifier)) {
            root.setFilterKind(root.kinds[event.key - Qt.Key_1].id)
            event.accepted = true
          } else if ((event.key === Qt.Key_H || event.key === Qt.Key_L) && (event.modifiers & Qt.ControlModifier)) {
            // Vim-style: ^H = previous filter, ^L = next filter.
            var hldir = event.key === Qt.Key_H ? -1 : 1
            var hlat = 0
            for (var hl = 0; hl < root.kinds.length; hl++) {
              if (root.kinds[hl].id === root.filterKind) { hlat = hl; break }
            }
            root.setFilterKind(root.kinds[(hlat + hldir + root.kinds.length) % root.kinds.length].id)
            event.accepted = true
          } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            // Shift+Tab arrives as Key_Backtab.
            var dir = (event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier)) ? -1 : 1
            var at = 0
            for (var k = 0; k < root.kinds.length; k++) {
              if (root.kinds[k].id === root.filterKind) { at = k; break }
            }
            root.setFilterKind(root.kinds[(at + dir + root.kinds.length) % root.kinds.length].id)
            event.accepted = true
          } else if (event.key === Qt.Key_Comma && (event.modifiers & Qt.ControlModifier)) {
            root.openHelp("settings")
            event.accepted = true
          } else if (event.key === Qt.Key_Question) {
            // The ? the header advertises. Sits above the generic text branch
            // below, or "?" would be typed into the filter instead. Shift is not
            // required for ?: not every tool reports it.
            root.openHelp("shortcuts")
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Delete) {
            if (event.modifiers & Qt.ShiftModifier) root.clearUnpinned()
            else root.removeSelected()
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.cursorActive) root.activateSelected(event.modifiers & Qt.ShiftModifier)
            else if (root.combinedCount > 0) root.cursorActive = true
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        id: column
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // ---- search + filter panel (matches the shortcut panel language) ----
        Rectangle {
          id: controlPanel
          width: parent.width
          height: controlColumn.implicitHeight + Style.space(22)
          radius: Style.space(9)
          color: root.background
          border.color: Util.alpha(root.border, 0.3)
          border.width: 1

          Column {
            id: controlColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(11)
            spacing: Style.space(8)

            // panel header: label + result count
            Item {
              width: parent.width
              height: root.metaFont + Style.space(3)

              Text {
                textFormat: Text.PlainText
                text: "SEARCH  &  FILTER"
                color: root.foreground
                opacity: 0.45
                font.family: root.fontFamily
                font.pixelSize: root.metaFont
                font.letterSpacing: 1.5
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Row {
                anchors.right: headerSettings.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(7)

                // Where the cursor sits in the visible list. Only meaningful once
                // a cursor exists, so it appears when you start moving rather than
                // adding noise to the resting panel.
                Text {
                  textFormat: Text.PlainText
                  visible: root.cursorActive
                  text: root.positionLabel
                  color: root.selectedText
                  font.family: root.fontFamily
                  font.pixelSize: root.metaFont
                  font.weight: Font.DemiBold
                  anchors.verticalCenter: parent.verticalCenter
                }

                Rectangle {
                  visible: root.cursorActive
                  width: 1
                  height: Style.space(10)
                  color: Util.alpha(root.foreground, 0.18)
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.combinedCount === root.history.length
                        ? root.combinedCount + " items"
                        : root.combinedCount + " of " + root.history.length
                  color: root.foreground
                  opacity: 0.35
                  font.family: root.fontFamily
                  font.pixelSize: root.metaFont
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              // Settings affordance: a gear that opens the settings panel.
              Item {
                id: headerSettings
                width: Style.space(18)
                height: width
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter

                Rectangle {
                  anchors.fill: parent
                  radius: width / 2
                  color: settingsArea.containsMouse || root.helpOpen
                         ? Util.alpha(root.border, 0.16) : "transparent"
                  Behavior on color { ColorAnimation { duration: 110 } }
                }

                Text {
                  anchors.centerIn: parent
                  text: "\u{F0493}"   // nf-md-cog
                  color: root.helpOpen ? root.selectedText : root.chevron
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                MouseArea {
                  id: settingsArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openHelp("settings")
                }
              }
            }

            // search field
            Rectangle {
              id: searchField
              width: parent.width
              height: root.headerHeight
              radius: Style.space(8)
              color: Util.alpha(root.border, 0.06)
              border.width: 1
              border.color: root.filterText.length > 0
                            ? Util.alpha(Color.accent, 0.5)
                            : Util.alpha(root.border, 0.16)
              Behavior on border.color { ColorAnimation { duration: 120 } }

              Row {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(11)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  id: searchIcon
                  text: "󰍉"
                  color: root.filterText.length > 0 ? Color.accent : root.foreground
                  opacity: root.filterText.length > 0 ? 1 : 0.45
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: searchInput
                  textFormat: Text.PlainText
                  width: Math.max(0, parent.width - searchIcon.width - clearButton.width - parent.spacing * 2)
                  text: root.filterText || "Search clipboard…"
                  color: root.foreground
                  opacity: root.filterText.length > 0 ? 1 : 0.42
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                  anchors.verticalCenter: parent.verticalCenter
                }

                Rectangle {
                  id: clearButton
                  visible: root.filterText.length > 0
                  width: visible ? Style.space(17) : 0
                  height: width
                  radius: width / 2
                  color: clearArea.containsMouse ? Util.alpha(root.border, 0.3) : Util.alpha(root.border, 0.13)
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    anchors.centerIn: parent
                    text: "✕"
                    color: root.foreground
                    opacity: 0.7
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  MouseArea {
                    id: clearArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.setFilter("")
                  }
                }
              }
            }

            // filter tabs
            Item {
              width: parent.width
              height: root.chipsHeight

              Row {
                id: tabsRow
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                height: parent.height
                spacing: Style.space(22)

                Repeater {
                  model: root.kinds

                  delegate: Item {
                    id: tab
                    required property var modelData
                    readonly property bool active: root.filterKind === modelData.id
                    readonly property bool hovered: tabArea.containsMouse

                    width: tabRow.implicitWidth
                    height: parent.height

                    Row {
                      id: tabRow
                      anchors.horizontalCenter: parent.horizontalCenter
                      anchors.top: parent.top
                      anchors.topMargin: Style.space(3)
                      spacing: Style.space(6)

                      Text {
                        text: tab.modelData.glyph
                        color: tab.active ? Color.accent : root.foreground
                        opacity: tab.active ? 1 : (tab.hovered ? 0.75 : 0.4)
                        Behavior on opacity { NumberAnimation { duration: 110 } }
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Text {
                        id: tabLabel
                        textFormat: Text.PlainText
                        text: tab.modelData.label.toUpperCase()
                        color: tab.active ? Color.accent : root.foreground
                        opacity: tab.active ? 1 : (tab.hovered ? 0.75 : 0.45)
                        Behavior on opacity { NumberAnimation { duration: 110 } }
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.letterSpacing: 1.6
                        font.weight: tab.active ? Font.DemiBold : Font.Normal
                        anchors.verticalCenter: parent.verticalCenter
                      }
                    }

                    MouseArea {
                      id: tabArea
                      anchors.fill: parent
                      anchors.margins: -Style.space(6)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.setFilterKind(tab.modelData.id)
                    }
                  }
                  }
              }
            }
          }
        }
        // ---- entries card ----
        Rectangle {
          id: entryCard
          width: parent.width
          height: parent.height - controlPanel.height - root.contentSpacing
          radius: Style.space(9)
          color: root.background
          border.color: Util.alpha(root.border, 0.3)
          border.width: 1


          Item {
            id: contentArea
  anchors.fill: parent
  anchors.margins: Style.space(8)
            width: parent.width

            component EntryRow: Rectangle {
              id: entryRow
              required property int index
              required property string entryType
              required property bool pinned
              required property string previewText
              required property string fullText
              required property bool isLink
              required property bool isColor
              required property bool isEmail
              required property bool isPath
              required property bool isCode
              required property string previewImage
              property int base

              readonly property bool hasCursor: root.cursorActive && base + index === root.selectedIndex
              readonly property bool hovered: rowHoverArea.containsMouse

              width: ListView.view.width
              height: root.rowHeight
              radius: Style.space(6)
              color: hasCursor ? root.selectedBackground : (hovered ? root.rowHover : "transparent")
              Behavior on color { ColorAnimation { duration: 90 } }

              // accent marker for the focused row
              Rectangle {
                visible: entryRow.hasCursor
                width: 3
                height: parent.height * 0.5
                radius: 1.5
                color: Color.accent
                anchors.left: parent.left
                anchors.leftMargin: Style.space(5)
                anchors.verticalCenter: parent.verticalCenter
              }

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.space(14)
                anchors.rightMargin: entryRow.pinned ? Style.space(44) : Style.space(32)
                spacing: Style.space(11)

                // fixed-width icon column keeps every title on the same x
                Item {
                  id: iconColumn
                  width: Style.space(26)
                  height: parent.height
                  anchors.verticalCenter: parent.verticalCenter

                  Rectangle {
                    visible: entryRow.entryType === "image"
                    width: Style.space(24)
                    height: width
                    radius: Style.space(5)
                    anchors.centerIn: parent
                    color: Util.alpha(root.border, entryRow.hasCursor ? 0.2 : 0.08)
                    clip: true
                    border.color: Util.alpha(root.border, 0.28)
                    border.width: 1

                    Image {
                      anchors.fill: parent
                      anchors.margins: 2
                      source: entryRow.previewImage
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true
                      smooth: true
                    }
                  }

                  Rectangle {
                    visible: entryRow.isColor === true
                    width: Style.space(15)
                    height: width
                    radius: width / 2
                    anchors.centerIn: parent
                    color: entryRow.isColor === true && !!entryRow.fullText ? entryRow.fullText.trim() : "transparent"
                    border.color: Util.alpha(root.foreground, 0.3)
                    border.width: 1
                  }

                  Text {
                    visible: entryRow.entryType !== "image" && !entryRow.isColor
                    text: {
                      if (entryRow.isLink === true) return "󰌹"
                      if (entryRow.isEmail === true) return "󰇮"
                      if (entryRow.isPath === true) return "󰉋"
                      if (entryRow.isCode === true) return "󰘦"
                      return "󰏫"
                    }
                    color: {
                      if (entryRow.hasCursor) return root.selectedText
                      if (entryRow.pinned || entryRow.isLink === true) return Color.accent
                      return Color.muted
                    }
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.title
                    anchors.centerIn: parent
                  }
                }

                Text {
                  id: titleText
                  textFormat: Text.PlainText
                  width: parent.width - iconColumn.width - parent.spacing
                  text: entryRow.previewText
                  color: {
                    if (entryRow.hasCursor) return root.selectedText
                    if (entryRow.isLink === true) return Color.accent
                    return root.foreground
                  }
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                  anchors.verticalCenter: parent.verticalCenter

                }
              }

              // preview affordance for values that do not fit the row
            Rectangle {
              id: previewChevron
              visible: titleText.truncated || entryRow.entryType === "image"
              width: Style.space(18)
              height: width
              radius: width / 2
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              color: chevronArea.containsMouse ? Util.alpha(root.border, 0.28)
                                               : (entryRow.hasCursor ? Util.alpha(root.border, 0.16) : "transparent")

              Text {
                anchors.centerIn: parent
                text: entryRow.entryType === "image" ? "\uF02E9" : "\u203A"
                color: entryRow.hasCursor ? Color.accent : root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                id: chevronArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  hoverDwell.stop()
                  root.cursorActive = true
                  root.selectedIndex = entryRow.base + entryRow.index
                  root.previewAuto = false
                  root.previewOpen = true
                }
              }
            }

            // trailing pin marker (the caption that used to say "pinned" is gone)
              Text {
                visible: entryRow.pinned && !entryRow.hasCursor
                text: "󰐃"
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                color: Color.accent
                opacity: 0.45
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              // Hovering must not flash the preview pane: selection only follows
              // the pointer after a short dwell, so sweeping across long entries
              // no longer pops a translucent pane in and out.
              Timer {
                id: hoverDwell
                interval: 320
                repeat: false
                onTriggered: {
                  if (!root.hoverAllowed) return
                  root.cursorActive = true
                  root.selectedIndex = entryRow.base + entryRow.index
                }
              }

              MouseArea {
                id: rowHoverArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: {
                  if (!root.hoverAllowed) return
                  hoverDwell.restart()
                }
                onExited: hoverDwell.stop()
                onClicked: {
                  hoverDwell.stop()
                  root.cursorActive = true
                  root.selectedIndex = entryRow.base + entryRow.index
                  root.activateSelected(false)
                }
              }
            }

            // ---- list column: yields width when the preview is open ----
            Item {
              id: listColumn
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: parent.width - (root.previewOpen && root.canPreview(previewPane.activeRow) ? previewPane.width : 0)
              Behavior on width { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

              // ---- sticky pinned block ----
              Column {
                id: pinnedArea
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                visible: pinnedModel.count > 0
                spacing: Style.space(4)

                Text {
                  textFormat: Text.PlainText
                  text: "PINNED  ·  " + pinnedModel.count
                  color: Color.accent
                  opacity: 0.75
                  font.family: root.fontFamily
                  font.pixelSize: root.metaFont
                  font.letterSpacing: 1.6
                  leftPadding: Style.space(14)
                }

                ListView {
                  id: pinnedList
                  width: parent.width
                  height: contentHeight
                  interactive: false
                  model: pinnedModel
                  clip: true
                  spacing: Style.space(4)

                  delegate: EntryRow { base: 0 }
                }
              }

              // ---- recent header ----
              Column {
                id: recentHeader
                anchors.top: pinnedArea.visible ? pinnedArea.bottom : parent.top
                anchors.topMargin: pinnedArea.visible ? Style.space(6) : 0
                anchors.left: parent.left
                anchors.right: parent.right
                visible: displayModel.count > 0

                Rectangle {
                  visible: pinnedArea.visible
                  width: parent.width
                  height: Style.normalBorderWidth
                  color: Util.alpha(root.border, 0.28)
                }

                Text {
                  textFormat: Text.PlainText
                  text: "RECENT  ·  " + displayModel.count
                  color: root.foreground
                  opacity: 0.42
                  font.family: root.fontFamily
                  font.pixelSize: root.metaFont
                  font.letterSpacing: 1.6
                  topPadding: Style.space(4)
                  leftPadding: Style.space(14)
                }
              }

              ListView {
                id: resultList
                anchors.top: recentHeader.visible ? recentHeader.bottom : recentHeader.top
                anchors.topMargin: Style.space(2)
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                model: displayModel
                clip: true
                spacing: Style.space(4)
                boundsBehavior: Flickable.StopAtBounds

                delegate: EntryRow { base: pinnedModel.count }
              }

              // No edge fades: content clips cleanly at the card. The fade
              // gradients read as a smudge across the first and last visible
              // row, and the scroll indicator already says there is more.

              // slim scroll indicator for the recency list
              Item {
                id: scrollIndicator
                visible: resultList.contentHeight > resultList.height + 1
                anchors.top: resultList.top
                anchors.bottom: resultList.bottom
                anchors.right: resultList.right
                anchors.rightMargin: Style.space(2)
                width: Style.space(3)

                Rectangle {
                  width: parent.width
                  radius: width / 2
                  color: Util.alpha(root.foreground, 0.22)
                  height: Math.max(Style.space(20),
                                   parent.height * (resultList.height / Math.max(1, resultList.contentHeight)))
                  y: {
                    var maxScroll = Math.max(1, resultList.contentHeight - resultList.height)
                    var travel = Math.max(0, parent.height - height)
                    return Math.max(0, Math.min(travel, (resultList.contentY / maxScroll) * travel))
                  }
                  Behavior on y { NumberAnimation { duration: 80 } }
                }
              }
            }

            }

            // ---- preview pane ----
            Item {
              id: previewPane
              anchors.right: parent.right
              width: parent.width * 0.62
              height: parent.height
              clip: true
              visible: width > 0 && root.previewOpen && root.canPreview(previewPane.activeRow)

              property var activeRow: root.cursorActive ? root.rowAt(root.selectedIndex) : null

              Rectangle {
                anchors.fill: parent
                color: Util.alpha(root.border, 0.04)
              }

              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Style.normalBorderWidth
                color: Util.alpha(root.border, 0.3)
              }

              Text {
                id: previewHeader
                textFormat: Text.PlainText
                text: "PREVIEW"
                color: root.foreground
                opacity: 0.45
                font.family: root.fontFamily
                font.pixelSize: root.metaFont
                font.letterSpacing: 1.5
                anchors.left: parent.left
                anchors.leftMargin: root.previewPadding
                anchors.top: parent.top
                anchors.topMargin: Style.space(6)
              }

              Flickable {
                visible: previewPane.activeRow && !previewPane.activeRow.previewImage
                anchors.fill: parent
                anchors.leftMargin: root.previewPadding
                anchors.rightMargin: root.previewPadding
                anchors.topMargin: previewHeader.height + Style.space(16)
                anchors.bottomMargin: root.previewPadding
                contentWidth: width
                contentHeight: previewText.implicitHeight
                clip: true
                interactive: true
                boundsBehavior: Flickable.StopAtBounds

                Text {
                  id: previewText
                  width: parent.width
                  textFormat: Text.PlainText
                  text: visible && previewPane.activeRow ? root.fullTextOf(previewPane.activeRow) : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WrapAnywhere
                }
              }

              Image {
                visible: parent.activeRow && parent.activeRow.previewImage
                anchors.fill: parent
                anchors.leftMargin: root.previewPadding
                anchors.rightMargin: root.previewPadding
                anchors.topMargin: previewHeader.height + Style.space(16)
                anchors.bottomMargin: root.previewPadding
                source: parent.activeRow ? parent.activeRow.previewImage : ""
                fillMode: Image.PreserveAspectFit
                verticalAlignment: Image.AlignTop
                asynchronous: true
                smooth: true
              }
            }
        }

      }

        // ---- help popup ----
        // The shortcut reference, opened by the ? in the panel header. It
        // overlays the list rather than taking space in the layout, so opening
        // help never reflows anything under the pointer.
        Rectangle {
          anchors.fill: parent
          radius: root.cornerRadius
          // The theme's menu scrim is the background colour (light) at 50%, which
          // merely veils the list and leaves it legible behind the card. Dim with
          // the foreground instead so the reference reads as the only thing here.
          color: Util.alpha(root.foreground, 0.28)
          visible: opacity > 0.01
          opacity: root.helpOpen ? 1 : 0
          Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

          MouseArea { anchors.fill: parent; onClicked: root.helpOpen = false }
        }

        BorderSurface {
          id: helpCard
          anchors.centerIn: parent
          width: Math.min(root.helpPopupWidth, card.width - Style.space(60))
          height: Math.min(root.helpPopupHeight, card.height - Style.space(60))
          radius: root.cornerRadius
          // The theme's menu background is authored at 0.95 alpha. That is fine
          // for a popup over a scrim, but this card sits on live list rows, so
          // force it fully opaque or the text behind shows through.
          color: Util.alpha(root.background, 1)
          borderSpec: root.borderSpec
          padding: root.contentMargin
          visible: opacity > 0.01
          opacity: root.helpOpen ? 1 : 0
          scale: root.helpOpen ? 1 : 0.99
          Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
          Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

          MouseArea { anchors.fill: parent; onClicked: {} }

          Column {
            anchors.fill: parent
            // A little more air than the shell's default inset: the reference is
            // dense, and flush edges made the columns read as clipped.
            anchors.topMargin: parent.contentTopInset + Style.space(4)
            anchors.rightMargin: parent.contentRightInset + Style.space(2)
            anchors.bottomMargin: parent.contentBottomInset
            anchors.leftMargin: parent.contentLeftInset + Style.space(2)
            spacing: root.contentSpacing

            // ---- page: shortcuts ----
            // Page switcher. Explicit items rather than a Repeater: repeated
            // delegates in this popup did not render.
            Row {
              spacing: Style.space(4)

              Item {
                id: tabShortcuts
                width: tabShortcutsLabel.implicitWidth + Style.space(18)
                height: Style.space(24)
                readonly property bool active: root.helpTab === "shortcuts"

                Rectangle {
                  anchors.fill: parent
                  radius: Style.space(5)
                  color: tabShortcuts.active ? Util.alpha(root.selectedText, 0.16)
                                             : (tabShortcutsArea.containsMouse ? Util.alpha(root.foreground, 0.06) : "transparent")
                  border.width: 1
                  border.color: tabShortcuts.active ? Util.alpha(root.selectedText, 0.45)
                                                    : Util.alpha(root.foreground, 0.16)
                  Behavior on color { ColorAnimation { duration: 110 } }
                }

                Text {
                  id: tabShortcutsLabel
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: "SHORTCUTS"
                  color: tabShortcuts.active ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: root.metaFont
                  font.letterSpacing: 1.0
                  font.weight: tabShortcuts.active ? Font.DemiBold : Font.Normal
                }

                MouseArea {
                  id: tabShortcutsArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.helpTab = "shortcuts"
                }
              }

              Item {
                id: tabSettings
                width: tabSettingsLabel.implicitWidth + Style.space(18)
                height: Style.space(24)
                readonly property bool active: root.helpTab === "settings"

                Rectangle {
                  anchors.fill: parent
                  radius: Style.space(5)
                  color: tabSettings.active ? Util.alpha(root.selectedText, 0.16)
                                            : (tabSettingsArea.containsMouse ? Util.alpha(root.foreground, 0.06) : "transparent")
                  border.width: 1
                  border.color: tabSettings.active ? Util.alpha(root.selectedText, 0.45)
                                                   : Util.alpha(root.foreground, 0.16)
                  Behavior on color { ColorAnimation { duration: 110 } }
                }

                Text {
                  id: tabSettingsLabel
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: "SETTINGS"
                  color: tabSettings.active ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: root.metaFont
                  font.letterSpacing: 1.0
                  font.weight: tabSettings.active ? Font.DemiBold : Font.Normal
                }

                MouseArea {
                  id: tabSettingsArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.helpTab = "settings"
                }
              }
            }

            // ---- page: settings ----
            Column {
              visible: root.helpTab === "settings"
              width: parent.width
              spacing: Style.space(8)

              // The panel owns the keyboard (its key catcher has focus), so the
              // field has to claim focus explicitly when the page opens.
              onVisibleChanged: if (visible) Qt.callLater(retentionInput.forceActiveFocus)

              Text {
                textFormat: Text.PlainText
                text: "AUTO-CLEANUP"
                color: root.hintLabel
                font.family: root.fontFamily
                font.pixelSize: root.metaFont
                font.letterSpacing: 1.0
                font.weight: Font.DemiBold
              }

              Row {
                spacing: Style.space(7)

                Text {
                  textFormat: Text.PlainText
                  text: "Remove unpinned entries after"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: root.metaFont
                  anchors.verticalCenter: parent.verticalCenter
                }

                Rectangle {
                  width: Style.space(64)
                  height: Style.space(26)
                  radius: Style.space(5)
                  color: Util.alpha("#ffffff", 0.55)
                  border.width: retentionInput.activeFocus ? 2 : 1
                  border.color: retentionInput.activeFocus
                                ? Util.alpha(root.selectedText, 0.6)
                                : Util.alpha(root.foreground, 0.20)

                  TextInput {
                    id: retentionInput
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(8)
                    verticalAlignment: TextInput.AlignVCenter
                    horizontalAlignment: TextInput.AlignHCenter
                    text: root.retentionDraft
                    color: root.foreground
                    selectionColor: Util.alpha(root.selectedText, 0.35)
                    selectedTextColor: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: root.metaFont
                    validator: IntValidator { bottom: 0; top: 3650 }
                    inputMethodHints: Qt.ImhDigitsOnly
                    activeFocusOnPress: true

                    // Autosave: the value is persisted as soon as it is a
                    // usable number, so there is nothing to confirm.
                    onTextEdited: {
                      root.retentionDraft = text
                      var n = parseInt(text, 10)
                      // Save only once there is a usable number, so clearing the
                      // field to retype is allowed; 0 means "never clean up".
                      if (text.length === 1 && n === 0) root.applyRetention("0")
                      else if (text.length > 0 && isFinite(n) && n > 0) root.applyRetention(text)
                    }
                    Keys.onEscapePressed: root.helpOpen = false
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.IBeamCursor
                    onClicked: retentionInput.forceActiveFocus()
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  text: "days"
                  color: root.hintLabel
                  font.family: root.fontFamily
                  font.pixelSize: root.metaFont
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  text: "0 = never"
                  color: root.hintLabel
                  font.family: root.fontFamily
                  font.pixelSize: root.metaFont
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "Saved as you type. Pinned entries are never removed."
                color: root.hintLabel
                font.family: root.fontFamily
                font.pixelSize: root.metaFont
                wrapMode: Text.WordWrap
              }
            }

            // ---- page: shortcuts ----
            Row {
              visible: root.helpTab === "shortcuts"
              spacing: Style.space(20)

              ShortcutGroup {
                title: "NAVIGATE"
                rows: [
                  { keys: ["Ctrl+J", "Ctrl+K"], label: "move" },
                  { keys: ["Tab", "Shift+Tab"], label: "switch kind" },
                  { keys: ["Ctrl+H", "Ctrl+L"], label: "cycle kinds" },
                  { keys: ["Ctrl+1\u20135"], label: "pick a kind" }
                ]
              }

              ShortcutGroup {
                title: "CLIPBOARD"
                rows: [
                  { keys: ["Enter"], label: "paste" },
                  { keys: ["Shift+Enter"], label: "copy only" },
                  { keys: ["Ctrl+O"], label: "preview" },
                  { keys: ["Esc"], label: "close" }
                ]
              }

              ShortcutGroup {
                title: "PANEL"
                rows: [
                  { keys: ["?"], label: "this reference" },
                  { keys: ["Ctrl+,"], label: "settings" },
                  { keys: ["Ctrl+O"], label: "preview" },
                  { keys: ["Ctrl+."], label: "actions menu" }
                ]
              }

              ShortcutGroup {
                title: "ORGANIZE"
                rows: [
                  { keys: ["Ctrl+P"], label: "pin / unpin" },
                  { keys: ["Delete", "Ctrl+D"], label: "remove entry" },
                  { keys: ["Shift+Delete"], label: "clear unpinned" },
                  { keys: ["Ctrl+."], label: "actions menu" }
                ]
              }
            }

            Item {
              visible: root.helpTab === "shortcuts"
              width: parent.width
              height: actionsFooterRow.implicitHeight

              Row {
                id: actionsFooterRow
                anchors.right: parent.right
                spacing: Style.space(7)

                Text {
                  textFormat: Text.PlainText
                  text: "Open the actions menu"
                  color: root.hintLabel
                  font.family: root.fontFamily
                  font.pixelSize: root.metaFont
                  anchors.verticalCenter: parent.verticalCenter
                }

                KeyCap { label: "Ctrl+." }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  root.helpOpen = false
                  root.cursorActive = root.combinedCount > 0
                  root.openActions()
                }
              }
            }
          }
        }


      // ---- empty state ----
      Column {
        anchors.centerIn: parent
        spacing: Style.space(8)
        visible: root.nothingToShow && !root.actionsOpen

        Text {
          text: "󰅌"
          color: Color.accent
          opacity: 0.55
          font.family: root.fontFamily
          font.pixelSize: Style.font.displayLarge
          horizontalAlignment: Text.AlignHCenter
          width: parent.width
        }

        Text {
          textFormat: Text.PlainText
          text: root.history.length === 0 ? "Clipboard is empty — copy something" : "No matches for “" + root.filterText + "”"
          color: root.foreground
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          horizontalAlignment: Text.AlignHCenter
          width: parent.width
        }
      }

      // ---- actions overlay ----
      Rectangle {
        anchors.fill: parent
        visible: root.actionsOpen
        radius: root.cornerRadius
        color: Util.alpha(root.background, 0.35)
      }

      BorderSurface {
        visible: root.actionsOpen
        anchors.centerIn: parent
        width: Math.min(Style.space(560), card.width - Style.space(40))
        height: Math.min(Style.space(620), card.height - Style.space(40))
        radius: root.cornerRadius
        color: root.background
        borderSpec: root.borderSpec
        padding: root.contentMargin

        MouseArea { anchors.fill: parent; onClicked: {} }

        Column {
          anchors.fill: parent
          anchors.topMargin: parent.contentTopInset
          anchors.rightMargin: parent.contentRightInset
          anchors.bottomMargin: parent.contentBottomInset
          anchors.leftMargin: parent.contentLeftInset
          spacing: root.contentSpacing

          Text {
            id: actionsHeading
            textFormat: Text.PlainText
            text: "Actions"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }

          Rectangle {
            id: actionSearchBox
            width: parent.width
            height: Style.space(42)
            radius: root.cornerRadius
            color: Util.alpha(root.border, 0.08)

            Text {
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.leftMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              text: root.actionFilter || "Search actions…"
              color: root.foreground
              opacity: root.actionFilter ? 1 : 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }
          }

          ListView {
            id: actionsList
            width: parent.width
            height: parent.height - actionsHeading.height - actionSearchBox.height - root.contentSpacing * 2
            model: actionsModel
            clip: true
            spacing: Style.space(4)
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              id: actionRow
              required property int index
              required property string actionId
              required property string label
              required property string hint

              readonly property bool hasCursor: index === root.actionIndex

              width: ListView.view.width
              height: Style.space(46)
              radius: root.cornerRadius
              color: hasCursor ? root.selectedBackground : "transparent"

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(10)

                Item { width: 1; height: 1 }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width - parent.height - parent.spacing * 3 - actionHint.implicitWidth
                  height: parent.height
                  text: actionRow.label
                  color: actionRow.hasCursor ? root.selectedText : (actionRow.actionId === "remove" ? "#d04860" : root.foreground)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  elide: Text.ElideRight
                  verticalAlignment: Text.AlignVCenter
                }

                Text {
                  id: actionHint
                  textFormat: Text.PlainText
                  text: actionRow.hint
                  height: parent.height
                  color: actionRow.hasCursor ? root.selectedText : root.foreground
                  opacity: 0.5
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  verticalAlignment: Text.AlignVCenter
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPositionChanged: function(mouse) {
                  if (!pointerGate.moved(actionRow, mouse)) return
                  root.actionIndex = actionRow.index
                }
                onClicked: root.runActionIndex(actionRow.index)
              }
            }
        }
      }
    }
  }
}
}

// Workspace OSD — DMS daemon plugin.
// Flashes the id/name of the workspace you just switched to, centered on that screen.
// A new switch replaces the text immediately (no queue); the card fades out after `holdMs`.
//
// Compositors: Hyprland (workspacev2 raw event) and niri (NiriService.allWorkspaces diff).
// Below the label it lists the windows open on that workspace, one per line in a small font
// ("App · Window title", or grouped app names), folding the rest into "+N more".
// IPC (all three arguments are required, pass "" to skip one):
//   dms ipc call wsosd flash "<text>" "<monitor-name or empty for all>" "line one | line two"
//   dms ipc call wsosd hide
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    // ---- settings (see WorkspaceOsdSettings.qml) --------------------------------------
    property int holdMs: pluginData.holdMs ?? 700
    // 0 = follow the DMS animation speed setting
    property int fadeSetting: pluginData.fadeMs ?? 0
    readonly property int fadeMs: fadeSetting > 0 ? fadeSetting : Theme.mediumDuration
    property int fontSize: pluginData.fontSize ?? 44
    property bool showName: pluginData.showName ?? true
    property string labelStyle: pluginData.labelStyle || "prefixed"   // prefixed | compact | nameOnly
    property string position: pluginData.position || "center"        // center | top | bottom
    property bool showApps: pluginData.showApps ?? true
    property bool accentBorder: pluginData.accentBorder ?? true
    property int maxApps: pluginData.maxApps ?? 6
    property string appLineStyle: pluginData.appLineStyle || "title"   // title | name
    property string appLineAlign: pluginData.appLineAlign || "left"    // left | center
    property int appLineMaxChars: pluginData.appLineMaxChars ?? 100    // 0 = no limit

    // ---- flash state --------------------------------------------------------------------
    property string text: ""
    property var apps: []
    property string monitor: ""
    property bool shown: false
    property bool fading: false

    Timer { id: hideTimer; interval: root.holdMs; onTriggered: root.shown = false }
    Timer { id: unmapTimer; interval: root.fadeMs + 80; onTriggered: root.fading = false }
    onShownChanged: {
        if (shown) { unmapTimer.stop(); fading = false; }
        else { fading = true; unmapTimer.restart(); }
    }

    // Show the card (a new call replaces the current text; nothing is queued).
    function showFlash(text, monitor, apps) {
        if (SessionData.suppressOSD) return;
        root.text = text;
        root.apps = root.showApps ? (apps || []) : [];
        root.monitor = monitor || "";
        root.shown = true;
        hideTimer.restart();
    }

    // Build the label from a workspace number and its (optional) name.
    function labelFor(number, name) {
        const num = String(number);
        let n = (name || "").trim();
        if (n === num) n = "";
        // DMS's Hyprland rename dialog stores "<id> <name>"; strip the duplicated id.
        const m = n.match(new RegExp("^" + num + "\\s+(.+)$"));
        if (m) n = m[1];
        if (!root.showName) n = "";
        switch (root.labelStyle) {
        case "nameOnly":
            return n !== "" ? n : num;
        case "compact":
            return n !== "" ? num + "  ·  " + n : num;
        default:
            return n !== "" ? I18n.trFor("workspaceOsdFlash", "Workspace %1: %2").arg(num).arg(n)
                            : I18n.trFor("workspaceOsdFlash", "Workspace %1").arg(num);
        }
    }

    // ---- apps open on a workspace ----------------------------------------------------------
    function appName(appId) {
        if (!appId) return "";
        const modded = Paths.moddedAppId(appId);
        return Paths.getAppName(modded, DesktopEntries.heuristicLookup(modded));
    }

    // entries: [{ name, title }] per window -> array of lines for the card.
    function summarize(entries) {
        const lines = [];
        if (root.appLineStyle === "name") {
            const counts = {}; const order = [];
            for (const e of entries) {
                if (!e.name) continue;
                if (counts[e.name] === undefined) { counts[e.name] = 0; order.push(e.name); }
                counts[e.name]++;
            }
            for (const n of order) lines.push(counts[n] > 1 ? n + " \u00d7" + counts[n] : n);
        } else {
            for (const e of entries) {
                const title = (e.title || "").trim();
                if (title === "") { if (e.name) lines.push(e.name); continue; }
                // Titles like "Inbox - Google Chrome" already carry the app name; otherwise prefix it.
                const hasName = e.name && title.toLowerCase().includes(e.name.toLowerCase());
                lines.push(hasName || !e.name ? title : e.name + "  \u00b7  " + title);
            }
        }
        const shown = lines.slice(0, root.maxApps).map(l => root.truncate(l));
        if (lines.length > root.maxApps) shown.push(I18n.trFor("workspaceOsdFlash", "+%1 more").arg(lines.length - root.maxApps));
        return shown;
    }

    function truncate(line) {
        const max = root.appLineMaxChars;
        if (max <= 0 || line.length <= max) return line;
        return line.slice(0, Math.max(1, max - 1)).replace(/\s+$/, "") + "\u2026";
    }

    function hyprlandApps(wsId) {
        const entries = [];
        for (const t of Hyprland.toplevels.values) {
            if (!t.workspace || t.workspace.id !== wsId) continue;
            entries.push({ name: appName(t.wayland?.appId || t.lastIpcObject?.class || ""), title: t.title || "" });
        }
        return summarize(entries);
    }

    function niriApps(wsId) {
        const entries = [];
        for (const w of (NiriService.windows || []))
            if (w.workspace_id === wsId) entries.push({ name: appName(w.app_id), title: w.title || "" });
        return summarize(entries);
    }

    // ---- Hyprland -----------------------------------------------------------------------
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (!CompositorService.isHyprland || event.name !== "workspacev2") return;
            const parts = event.parse(2);            // "ID,NAME"
            const id = parseInt(parts[0]);
            if (isNaN(id) || id < 0) return;         // special workspaces have negative ids
            let mon = "";
            const ws = Array.from(Hyprland.workspaces?.values || []).find(w => w.id === id);
            if (ws && ws.monitor) mon = ws.monitor.name;
            else if (Hyprland.focusedMonitor) mon = Hyprland.focusedMonitor.name;
            root.showFlash(root.labelFor(id, parts[1]), mon, root.hyprlandApps(id));
        }
    }

    // ---- niri (best effort, diff of the active workspace per output) --------------------
    property var _niriActive: ({})
    property bool _niriPrimed: false
    Connections {
        target: NiriService
        function onAllWorkspacesChanged() {
            if (!CompositorService.isNiri) return;
            const list = NiriService.allWorkspaces || [];
            const next = {};
            for (const ws of list)
                if (ws.is_active && ws.output) next[ws.output] = ws;
            if (root._niriPrimed) {
                for (const out in next) {
                    const ws = next[out];
                    const prev = root._niriActive[out];
                    // Only a change on an output we already knew about; a newly appearing output is not a switch.
                    // niri's idx is the 1-based number DMS shows in its bar.
                    if (prev && prev.id !== ws.id)
                        root.showFlash(root.labelFor(ws.idx, ws.name), out, root.niriApps(ws.id));
                }
            }
            const snapshot = {};
            for (const out in next) snapshot[out] = { id: next[out].id };
            root._niriActive = snapshot;
            root._niriPrimed = true;
        }
    }

    // ---- IPC ----------------------------------------------------------------------------
    IpcHandler {
        target: "wsosd"
        // apps: list of lines separated by "|" (or newlines); pass "" for none. Quickshell IPC needs all arguments.
        function flash(text: string, monitor: string, apps: string): void {
            const lines = (apps || "").split(/\s*\|\s*|\n/).map(a => a.trim()).filter(a => a !== "");
            root.showFlash(text, monitor, root.summarize(lines.map(l => ({ name: "", title: l }))));
        }
        function hide(): void { root.shown = false; }
    }

    // ---- overlay window, one per screen --------------------------------------------------
    Variants {
        model: Quickshell.screens
        PanelWindow {
            id: win
            required property var modelData
            screen: modelData
            readonly property bool forThisScreen: root.monitor === "" || root.monitor === modelData.name
            readonly property bool active: root.shown && forThisScreen

            // Same layer selection as DMS's own OSDs (DMS_OSD_LAYER env override, overlay default).
            WlrLayershell.layer: LayerShell.fromEnv("DMS_OSD_LAYER", WlrLayer.Overlay, { "allow": ["top", "overlay"], "invalidLayer": WlrLayer.Overlay, "label": "Workspace OSD" })
            WlrLayershell.namespace: "dms:osd"
            WlrLayershell.exclusiveZone: -1
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            mask: Region {}                                   // click-through
            visible: forThisScreen && (root.shown || root.fading)
            anchors.top: root.position === "top"
            anchors.bottom: root.position === "bottom"
            margins.top: root.position === "top" ? 96 : 0
            margins.bottom: root.position === "bottom" ? 96 : 0

            readonly property real dpr: CompositorService.getScreenScale(modelData)
            readonly property real shadowBuffer: 15
            readonly property real cardWidth: Theme.px(content.implicitWidth + Math.round(root.fontSize * 1.6), dpr)
            readonly property real cardHeight: Theme.px(content.implicitHeight + Math.round(root.fontSize * 0.9), dpr)
            implicitWidth: cardWidth + shadowBuffer * 2
            implicitHeight: cardHeight + shadowBuffer * 2

            // Background blur behind the card (only when the user enabled blur in DMS).
            WindowBlur {
                targetWindow: win
                blurX: win.shadowBuffer
                blurY: win.shadowBuffer
                blurWidth: win.active ? win.cardWidth : 0
                blurHeight: win.active ? win.cardHeight : 0
                blurRadius: Theme.cornerRadius
            }

            Item {
                id: card
                x: win.shadowBuffer
                y: win.shadowBuffer
                width: win.cardWidth
                height: win.cardHeight
                opacity: 1
                scale: 1
                // Appear instantly (animations do not run reliably on a window that is being mapped);
                // fade + shrink out explicitly when deactivated, using the DMS easing.
                ParallelAnimation {
                    id: fadeOut
                    NumberAnimation {
                        target: card
                        property: "opacity"
                        to: 0
                        duration: root.fadeMs
                        easing.type: Theme.emphasizedEasing
                    }
                    NumberAnimation {
                        target: card
                        property: "scale"
                        to: 0.9
                        duration: root.fadeMs
                        easing.type: Theme.emphasizedEasing
                    }
                }
                Connections {
                    target: win
                    function onActiveChanged() {
                        if (win.active) { fadeOut.stop(); card.opacity = 1; card.scale = 1; }
                        else if (win.visible) { fadeOut.restart(); }
                    }
                }

                // Surface: theme corner radius, popup transparency, outline, M3 elevation shadow.
                ElevationShadow {
                    anchors.fill: parent
                    level: Theme.elevationLevel3
                    fallbackOffset: 6
                    targetRadius: Theme.cornerRadius
                    targetColor: Theme.withAlpha(Theme.surfaceContainer, Theme.popupTransparency)
                    borderColor: Theme.outlineMedium
                    borderWidth: 1
                    shadowEnabled: Theme.elevationEnabled && SettingsData.popoutElevationEnabled
                }
                // Blur border (follows the DMS "blur border" colour/enabled settings).
                Rectangle {
                    anchors.fill: parent
                    radius: Theme.cornerRadius
                    color: "transparent"
                    border.color: BlurService.borderColor
                    border.width: BlurService.borderWidth
                }
                // Accent: thin primary-coloured ring so the flash reads as a highlight, not a popup.
                Rectangle {
                    anchors.fill: parent
                    radius: Theme.cornerRadius
                    color: "transparent"
                    border.color: Theme.withAlpha(Theme.primary, 0.6)
                    border.width: root.accentBorder ? 1 : 0
                }

                Column {
                    id: content
                    anchors.centerIn: parent
                    spacing: Math.round(root.fontSize * 0.18)
                    Text {
                        id: label
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.text
                        color: Theme.surfaceText
                        font.family: Theme.fontFamily
                        font.pixelSize: root.fontSize
                        font.weight: Font.DemiBold
                    }
                    Column {
                        id: appsList
                        // Block of lines centered under the label; lines are left-aligned inside it (or centered, per setting).
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: contentWidth
                        visible: root.apps.length > 0
                        spacing: Math.round(root.fontSize * 0.08)
                        topPadding: Math.round(root.fontSize * 0.1)
                        readonly property real maxLineWidth: Math.round(win.screen.width * 0.5)
                        property real contentWidth: 0
                        function recompute() {
                            let w = 0;
                            for (let i = 0; i < appsRepeater.count; i++) {
                                const it = appsRepeater.itemAt(i);
                                if (it) w = Math.max(w, Math.min(it.implicitWidth, maxLineWidth));
                            }
                            contentWidth = w;
                        }
                        Repeater {
                            id: appsRepeater
                            model: root.apps
                            onItemAdded: Qt.callLater(appsList.recompute)
                            onItemRemoved: Qt.callLater(appsList.recompute)
                            Text {
                                required property string modelData
                                text: modelData
                                color: Theme.surfaceVariantText
                                font.family: Theme.fontFamily
                                font.pixelSize: Math.max(Theme.fontSizeSmall, Math.round(root.fontSize * 0.38))
                                font.weight: Font.Medium
                                elide: Text.ElideRight
                                maximumLineCount: 1
                                width: appsList.contentWidth > 0 ? appsList.contentWidth : Math.min(implicitWidth, appsList.maxLineWidth)
                                horizontalAlignment: root.appLineAlign === "center" ? Text.AlignHCenter : Text.AlignLeft
                                onImplicitWidthChanged: Qt.callLater(appsList.recompute)
                            }
                        }
                    }
                }
            }
        }
    }
}

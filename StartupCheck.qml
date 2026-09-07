// Startup gate: the plugin only listens to Hyprland and niri workspace events,
// so refuse to enable on other compositors (DMS shows the error as a toast).
import QtQuick
import qs.Common
import qs.Services

QtObject {
    function check() {
        if (CompositorService.isHyprland || CompositorService.isNiri)
            return null;
        return {
            title: I18n.trFor("workspaceOsdFlash", "Hyprland or niri is required"),
            details: I18n.trFor("workspaceOsdFlash", "Workspace OSD Flash listens to Hyprland and niri workspace events and does not work on other compositors.")
        };
    }
}

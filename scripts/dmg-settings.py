from pathlib import Path

root = Path.cwd()  # build-dmg.sh runs from the repository root.
app = root / "dist" / "Input Selector.app"

format = "UDZO"
files = [str(app)]
symlinks = {"Applications": "/Applications"}
icon = str(app / "Contents/Resources/AppIcon.icns")
background = str(root / "macos/Resources/dmg-background.png")
icon_locations = {app.name: (160, 180), "Applications": (440, 180)}
window_rect = ((200, 160), (600, 360))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
icon_size = 96
text_size = 13
label_pos = "bottom"
include_icon_view_settings = True
include_list_view_settings = False


def create_hook(mount_point, settings):
    import subprocess

    subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(Path(mount_point) / app.name)],
        check=True,
    )

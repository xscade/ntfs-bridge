# dmgbuild settings for the NTFS Bridge disk image. tools/make-dmg.sh passes
# the paths with -D app=... -D licenses=...
import os

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
licenses = defines["licenses"]  # noqa: F821
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"

files = [app, licenses]
symlinks = {"Applications": "/Applications"}

background = "builtin-arrow"
window_rect = ((200, 120), (600, 420))
default_view = "icon-view"
show_toolbar = False
show_status_bar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {
    app_name: (150, 170),
    "Applications": (450, 170),
    os.path.basename(licenses): (300, 330),
}

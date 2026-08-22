# Godot Itch Uploader

[![Test](https://github.com/Red-Teapot/GodotItchUploader/actions/workflows/test.yml/badge.svg)](https://github.com/Red-Teapot/GodotItchUploader/actions/workflows/test.yml)

**Supported Godot versions:** 4.4 - 4.7 (inclusive)

This addon allows automatically exporting and uploading your project to [Itch.io](https://itch.io/) using [Butler](https://itch.io/docs/butler/). This is mainly intended to save time and prevent publishing mistakes during game jams, but the addon can be used outside of jams too.

Made by humans, for humans.

# How to Use

1. [Install Butler](https://itch.io/docs/butler/installing.html).
2. [Authenticate Butler](https://itch.io/docs/butler/login.html).
3. Install and enable this addon.
4. Open `Project Settings`, navigate to the `Itch Uploader` section in the left panel, and fill the `Itch Page URL` field. It should contain the link to the project page on Itch, e.g.: `https://redteapot.itch.io/test`.
5. Configure your export presets. Make sure each export preset uses a separate empty folder to avoid packaging unnecessary files with your project. For example, you could use these paths:

   - For Web, `.export/web/index.html`
   - For Windows, `.export/windows/game-name.exe`
   - For Linux, `.export/linux/game-name.x86_64`
   - For MacOS, `.export/macos/game-name.app`

   Don't forget to add the `.export` folder to the `.gitignore` file. Also, make sure the presets you want to export are marked as runnable (which they are by default).

   Also, you might want to exclude this addon from the exports (by adding the `addons/itch_uploader` folder to the exluded files field in the Resources tab of an export preset settings).

6. Open the Project menu, then go to `Tools` -> `Export and Upload to Itch...`
8. If you have Butler in your `PATH`, skip this step. Otherwise, specify the path to the Butler executable in the `Butler path` field. It will be saved, so you won't have to do it again.
9. Select the export presets you want to export and click `Export and Upload`.

# Version Control Notes

By default, the saved Butler path is not committed to Git, because it's assumed to be specific to every machine. If you want to change this, remove the corresponding entry in `addons/itch_uploader/.gitignore`.

The Itch.io page URL, on the contrary, is saved to project settings (`project.godot`) and commited to version control, because it's assumed to be specific to the entire project and this shareable. Currently there is no easy way to change this behavior.

# License

This addon is licensed under the terms of the [MIT License](LICENSE). The icons used by this addon are part of the [Godot Engine](https://godotengine.org/) and are licensed under the [MIT License](https://godotengine.org/license/).

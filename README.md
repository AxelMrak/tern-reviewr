# Tern Reviewr

Review staged, unstaged and non-ignored untracked Git changes in a focused Tern picture-in-picture. The IBM-terminal layout puts the unified diff on the left and the file list on the right, uses the active Tern theme colors, and marks `+`/`-` plus old/new line numbers. It never edits, stages or commits files.

## Install

```sh
tern plugin install github.com/AxelMrak/tern-reviewr
```

## Open

- Open **Review uncommitted changes** from the command palette or press the plugin default `Ctrl+Alt+Shift+R`.
- To use Tern's tmux-style prefix, add these optional entries to `settings.json`:

```json
{
  "keybinds": {
    "ctrl+b>r": "plugin.tern-reviewr.open",
    "ctrl+b>f": "plugin.tern-reviewr.focus_float"
  }
}
```

- Tern's window-plugin API does not expose PiP expansion; run `tern ctl pip expand` from a Tern pane to fill the frame.

## Review and comment

- `Tab`: switch focus between the **FILES** sidebar and the **DIFF** panel.
- Under 64 columns or 24 rows, Reviewr uses one focused panel and a compact summary of file counts, names, and the latest comment preview when space permits. In the wide layout, the latest two comments appear above the diff. The footer is hidden in compact mode; the header's `C#` badge keeps the saved-comment count visible. Tern may keep reported block size fixed during a visual PiP resize, so compact mode can begin before the float looks tiny.
- `j` / `k`: move through files when the sidebar has focus; move through diff lines when the diff has focus.
- `v`: start or clear a line range. Move with `j` / `k` to extend it; the selected lines and `path:start–end` are shown.
- `c`: open the centered comment dialog for the selected line or range. Type the comment, `Enter` saves, `Esc` cancels.
- `m`: show or hide saved comments.
- `x`: mark the selected file reviewed or unreviewed. This is reviewer-local progress; it does not modify Git files or send anything to the agent.
- `[` / `]`: choose a Tern agent in this repository; the focused agent is selected by default when it is in this repo.
- `s`, then `Enter`: confirm sending comments directly to that agent; `Esc` cancels.
- In wide layouts, the footer shows the saved-comment count beside `s send`. Compact mode hides the footer and keeps the count in the header badge.
- `Ctrl+R`: refresh the diff.

The focused panel uses the active theme's accent border; line numbers and `+`/`-` marks keep diff meaning visible without relying on color. Comments stay visible after sending.

Direct sending uses Tern's `cx.agents:ask` API and requires a matching agent with ready input. Failures appear in the reviewer; files remain unchanged.

The agent receives plain text: an instruction followed by one Markdown bullet per comment, formatted as `path:start[-end] — comment`. The message includes no full diff and does not apply changes.

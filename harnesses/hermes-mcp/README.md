# Hermes MCP Harness

This bridge lets Hermes call the local TipTour macOS engine without embedding Hermes inside TipTour.

TipTour must be running. It exposes a localhost harness at:

```text
http://127.0.0.1:19474
```

## Install

```bash
cd /Users/milindsoni/Documents/mywork/tiptour-macos/harnesses/hermes-mcp
python3 -m venv .venv
.venv/bin/python -m pip install -U mcp
```

## Hermes Config

Add this to `~/.hermes/config.yaml`:

```yaml
mcp_servers:
  tiptour:
    command: "/Users/milindsoni/Documents/mywork/tiptour-macos/harnesses/hermes-mcp/.venv/bin/python"
    args:
      - "/Users/milindsoni/Documents/mywork/tiptour-macos/harnesses/hermes-mcp/server.py"
```

Hermes will discover:

- `tiptour_observe`
- `tiptour_targets`
- `tiptour_action_history`
- `tiptour_resolve_highlight_source`
- `tiptour_image_edit`
- `tiptour_plan_next_action`
- `tiptour_submit_workflow_plan`

Prefer `tiptour_plan_next_action` for UI clicks because it refreshes TipTour's local YOLO/OCR targets, matches a real on-screen label, executes one action through TipTour's pointer workflow, validates that the local target set changed, and tries one local repair before failing. This is safer than asking Hermes to guess `box_2d` coordinates.

Use `tiptour_resolve_highlight_source` when the user refers to "this image",
"this file", selected text, a highlighted region, or the current browser page.
The response tells Hermes whether to use the image edit tool, its normal
text/file editing tools, selected-text action editing, or visual context.

Use `tiptour_image_edit` for image sources. Call it with `execute=False` first
to resolve the highlighted source and create artifacts. Call it with
`execute=True` only after the source is an image and the user wants the image
model called. TipTour saves a copy of the result and never overwrites the
original file.

TipTour still clamps every submitted workflow to one action. Hermes should call `tiptour_observe` or `tiptour_targets`, take one action, then observe again. Use `validate_state_change=False` for clicks where no visible UI change is expected, such as focusing a text field.

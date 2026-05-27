# TipTour Agent Contract

TipTour is the local macOS visual context broker, perception target grounder, pointer/action executor, and post-action validator. External agents do long-horizon reasoning, web/files/tool orchestration, and asset handling. TipTour executes one desktop action at a time.

Base URL:

```text
http://127.0.0.1:19474
```

Machine-readable contract:

```bash
curl http://127.0.0.1:19474/v1/agent-contract
```

## Canonical Loop

1. `GET /v1/observe` to confirm active app, toggles, and current state.
2. Preserve one `trace_id` across the whole user task and include it in every harness request body.
3. Use the agent's own web, browser, terminal, file, memory, and skill tools for research, downloads, file staging, and planning; call TipTour only when the local Mac needs observation, grounding, GUI action, or visual verification.
4. When the user refers to a highlighted file, image, text, URL, or "this thing", `POST /v1/resolve-highlight-source` first so TipTour can return the source and valid tool suggestions.
5. `POST /v1/visual-context` with `visual_context:"auto"` before uncertain, canvas, task-start, failed, or visually rich steps. Include `query` or `target_label` when asking about one specific target so TipTour can prefer `target_crop`.
6. For visible UI controls, `POST /v1/ground-target` for the next target only.
7. `POST /v1/act` with the returned `targetID` or `targetMark`.
8. For targetless keyboard, typing, app, URL, or coordinate-bearing canvas steps, `POST /v1/workflow-plan` with exactly one step.
9. When you already know a deterministic mini-sequence, such as Blender modal transform `S`, `Z`, type value, `Return`, use `POST /v1/tasks` instead of multiple steps in `/v1/workflow-plan`.
10. Read the compact response. If unclear, `GET /v1/action-history` and filter logs by `trace_id`.
11. Repeat from observe or visual-context. Do not ask TipTour to plan the whole task.

## Agent Responsibilities

Hermes or another outer agent should use its own tools for non-desktop work:

- web search and page extraction
- browser automation for websites and downloads
- local file staging, inspection, conversion, and command-line work
- memory, skills, and long-horizon task planning

TipTour should be called for local Mac observation/action:

- deciding whether a fresh screenshot, crop, or compact state is needed
- grounding a visible local UI target
- clicking, typing, pressing keys, opening apps/URLs, and validating visible state

For a task like "find a nice house model online and load it in Blender", the outer agent should search/download/validate the asset first, then either import it through Blender scripting/terminal tools or ask TipTour to drive the visible `File > Import/Open/Append` UI one action at a time. Use TipTour visual context after import to verify the model is visible.

## Normal Endpoints

- `GET /v1/observe`
- `POST /v1/visual-context`
- `POST /v1/resolve-highlight-source`
- `POST /v1/ground-target`
- `POST /v1/image-edit`
- `POST /v1/act`
- `POST /v1/workflow-plan`
- `POST /v1/tasks`
- `GET /v1/tasks/{task_id}`
- `GET /v1/tasks/{task_id}/events`
- `GET /v1/action-history`
- `GET /v1/skills/active`

## Debug Endpoints

- `GET /v1/targets`
- `GET /v1/screenshots`

## Rules

- One action per request. Wait for completion, pause, failure, or validation before deciding the next action.
- Never send multiple steps to `/v1/workflow-plan`. Use `/v1/tasks` only for a concrete deterministic mini-sequence, not for open-ended planning.
- Use `/v1/visual-context` instead of `/v1/screenshots` in normal loops. Raw screenshots are for explicit debugging.
- Use `/v1/ground-target` instead of full `/v1/targets` in normal loops.
- Use exact `targetID` or `targetMark` once TipTour returns one.
- For Blender/canvas viewport objects, include `point_2d` or `box_2d`; bare labels can match outliner/menu/property text instead of the object.
- Do not ask TipTour to browse the web, choose downloads, inspect licenses, or transform local files. Use the outer agent's tools for those parts, then hand TipTour the local UI/action step if needed.
- For Blender asset import, prefer reliable local file import through Blender scripting/terminal tools when available; use TipTour to drive File/Open/Import UI when the user specifically wants visible UI interaction or scripting is unavailable.
- For highlighted files, URLs, or text, call `/v1/resolve-highlight-source` first. It returns the resolved source and suggested tools such as `image_edit`, `text_edit`, `selected_text_edit`, `open_source`, or `visual_context`.
- For image edits, call `/v1/image-edit` after the user has painted a focus highlight or after `/v1/resolve-highlight-source` reports `content_category:"image"`. TipTour resolves the source image file when possible, creates highlighted screenshot artifacts, and optionally calls the configured image model. Use `output_mode:"copy"`; do not overwrite originals automatically.
- Do not click password, 2FA, payment, consent, or credential-finalization controls automatically.
- Every action response/log path should carry `trace_id` so one request can be followed through grounding, execution, and validation.

## Image Edit

Resolve the latest highlighted source and available tools:

```bash
curl -X POST http://127.0.0.1:19474/v1/resolve-highlight-source \
  -H 'content-type: application/json' \
  -d '{
    "trace_id": "same task trace"
  }'
```

Prepare a file-aware highlighted image edit job:

```bash
curl -X POST http://127.0.0.1:19474/v1/image-edit \
  -H 'content-type: application/json' \
  -d '{
    "trace_id": "same task trace",
    "prompt": "remove the object inside the highlighted area",
    "source": "current_highlight",
    "execute": false
  }'
```

Execute through the configured Gemini/Nano Banana provider:

```bash
curl -X POST http://127.0.0.1:19474/v1/image-edit \
  -H 'content-type: application/json' \
  -d '{
    "trace_id": "same task trace",
    "prompt": "make the highlighted area brighter",
    "source": "current_highlight",
    "provider": "gemini",
    "model": "gemini-2.5-flash-image",
    "execute": true,
    "output_mode": "copy"
  }'
```

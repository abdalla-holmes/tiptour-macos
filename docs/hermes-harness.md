# TipTour Hermes Harness

TipTour should stay the native macOS perception/action engine. Hermes should stay an external orchestrator.

Hermes should use its own agent toolset for non-desktop work: web search,
page extraction, browser automation, downloads, file operations, terminal
commands, memory, skills, and subtasks. TipTour should enter the loop only
when Hermes needs the local Mac's visual context, a grounded GUI action, or
post-action verification.

The integration boundary is the local TipTour harness server:

```text
Hermes Agent
  -> MCP bridge or local HTTP client
  -> TipTour Harness Server
  -> TipTourEngine
  -> macOS AX / OCR / local detection / CUA actions
```

TipTour listens only on localhost:

```text
http://127.0.0.1:19474
```

Hermes and other agents should follow the canonical contract in
[`docs/tiptour-agent-contract.md`](tiptour-agent-contract.md). The same
contract is available from the running app:

```bash
curl http://127.0.0.1:19474/v1/agent-contract
```

## Endpoints

### Health

```bash
curl http://127.0.0.1:19474/v1/health
```

### Observe

Returns TipTour's current local state without sending screenshots anywhere.

```bash
curl http://127.0.0.1:19474/v1/observe
```

### Visual Context Broker

Asks TipTour to decide whether the agent needs compact state, a target crop,
or a full screenshot. This is the normal visual API for long-running agents.
Use `/v1/screenshots` only for explicit raw screenshot debugging.

```bash
curl -X POST http://127.0.0.1:19474/v1/visual-context \
  -H 'content-type: application/json' \
  -d '{
    "intent": "make a house in Blender",
    "app": "Blender",
    "visual_context": "auto",
    "reason": "task_start"
  }'
```

### Local Grounding Targets

Refreshes TipTour's on-device YOLO/OCR perception pass and returns real on-screen targets. This endpoint is for debugging or full-graph inspection. In normal agent loops, prefer `/v1/ground-target` so TipTour returns one compact best match.

```bash
curl http://127.0.0.1:19474/v1/targets
```

### Plan And Execute One Grounded Action

Asks TipTour to choose one local target from the refreshed perception cache. If `execute` is true, TipTour runs the resulting single action through the same workflow/pointer path as voice mode, waits for WorkflowRunner to complete/pause/fail, refreshes local perception again, and reports whether the visible target set changed.

If validation fails, TipTour refreshes local perception and tries one alternate matching local target before returning failure. This is the preferred self-repair path for external harnesses.

```bash
curl -X POST http://127.0.0.1:19474/v1/plan-next-action \
  -H 'content-type: application/json' \
  -d '{
    "goal": "choose Mesh from the Blender Add menu",
    "app": "Blender",
    "target_label": "Mesh",
    "action": "click",
    "execute": true,
    "validate_state_change": true
  }'
```

Prefer this endpoint for harness-driven UI demos. It refuses to guess a raw coordinate when the local target does not exist, which is safer than clicking a stale or approximate `box_2d`.

Set `validate_state_change` to `false` for actions where a visible UI change is not expected, such as clicking into a text field before typing.

### Action History

Returns recent grounded-action attempts, including the chosen target, WorkflowRunner outcome, validation result, and whether a repair retry happened.

```bash
curl http://127.0.0.1:19474/v1/action-history
```

### Highlighted Image Edit

Use `/v1/resolve-highlight-source` when the user has highlighted something and
the agent needs to decide what tools are valid. The response includes the
source file/URL/text context plus suggested tools such as `image_edit`,
`text_edit`, `selected_text_edit`, `open_source`, or `visual_context`.

```bash
curl -X POST http://127.0.0.1:19474/v1/resolve-highlight-source \
  -H 'content-type: application/json' \
  -d '{"trace_id":"same task trace"}'
```

Prepares or executes a file-aware image edit based on the user's latest
TipTour focus highlight. TipTour tries to resolve the original image file via
AX document attributes, app-specific AppleScript such as Preview/Finder, and
browser URLs before falling back to screenshot-only artifacts.

Preparation mode creates local artifacts only:

```bash
curl -X POST http://127.0.0.1:19474/v1/image-edit \
  -H 'content-type: application/json' \
  -d '{
    "prompt": "remove the object inside the highlighted area",
    "source": "current_highlight",
    "execute": false
  }'
```

Execution mode uses the local Gemini key and saves a copy:

```bash
curl -X POST http://127.0.0.1:19474/v1/image-edit \
  -H 'content-type: application/json' \
  -d '{
    "prompt": "make the highlighted area brighter",
    "source": "current_highlight",
    "provider": "gemini",
    "model": "gemini-2.5-flash-image",
    "execute": true,
    "output_mode": "copy"
  }'
```

The endpoint never overwrites the original file. It writes artifacts under
`~/Library/Application Support/TipTour/image-edits/<trace_id>/`.

### Submit One Action

External harnesses submit the same single-action workflow shape Gemini uses internally.

```bash
curl -X POST http://127.0.0.1:19474/v1/workflow-plan \
  -H 'content-type: application/json' \
  -d '{
    "goal": "open the Add menu",
    "app": "Blender",
    "steps": [
      {
        "type": "click",
        "label": "Add",
        "hint": "Click the Add menu"
      }
    ]
  }'
```

TipTour clamps every external request to one step. Hermes should observe after each action and decide the next step. Prefer `/v1/plan-next-action` when Hermes has a semantic target label; use `/v1/workflow-plan` only when the caller already has a reliable TipTour workflow step.

External action requests also respect the menu bar connection toggles. If the CUA Driver toggle is off, TipTour rejects action plans instead of silently trying to click/type through the disabled driver.

## Why This Shape

Hermes is good at long-running reasoning, memory, skills, messaging, and tool orchestration.
For example, when the user asks Blender to fetch a nice model from the web,
Hermes should search, inspect the license/source, download the asset, validate
the file, and import it through Blender scripting or a local terminal path when
possible. TipTour should be used to drive `File > Import/Open/Append` only when
visible UI interaction is requested or scripting is unavailable, and to verify
the viewport after the import.

TipTour is good at:

- local screen perception
- macOS accessibility grounding
- browser DOM fallback
- local OCR/detection grounding
- cursor overlay and user-visible guidance
- safe desktop action execution

Keeping the boundary local and small avoids embedding Hermes inside the macOS app while still letting Hermes use TipTour as a real computer-use harness.

Implementation note: transports such as HTTP and MCP should call `TipTourEngine`, not `CompanionManager`, so the engine can grow without tying plugin/harness code to menu bar UI state.

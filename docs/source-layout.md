# TipTour Source Layout

The root `AGENTS.md` is the source of truth for coding agents. This file is outside the Xcode app target so it will not be bundled as an app resource.

## Folders

- `TipTour/App/` owns app lifecycle and the central `CompanionManager` state machine.
- `TipTour/Core/` exposes the small `TipTourEngine` facade used by harnesses and future plugins.
- `TipTour/Actions/` owns desktop action execution. Keep workflow code dependent on `ActionExecutor` / `TipTourActionDriver`, not CUA directly.
- `TipTour/Actions/Drivers/` is reserved for concrete action backends when they grow large enough to stand alone.
- `TipTour/Workflow/` owns action schemas, grounding, and single-action workflow execution.
- `TipTour/Perception/` owns screen capture, AX, DOM/CDP, local detection, OCR, and target caches.
- `TipTour/Harnesses/` owns local transports that let external orchestrators call TipTour.
- `TipTour/Plugins/` owns lightweight connection/plugin models and future plugin registry code.
- `TipTour/Plugins/Orchestrators/` is reserved for small built-in orchestrator adapters.
- `TipTour/UI/` owns the menu bar panel, overlay, detection visuals, and design system.
- `TipTour/Voice/` owns Gemini Live realtime audio, WebSocket, session orchestration, and lightweight clients for optional voice sidecar harnesses such as Pipecat.
- `TipTour/Recording/` owns ScreenCaptureKit walkthrough recording.
- `TipTour/Utilities/` owns cross-cutting helpers such as hotkeys, keychain, analytics, and permissions.

## Boundary Rules

- New external orchestrators should call `TipTour/Core/TipTourEngine.swift` through a harness instead of reaching into `CompanionManager`.
- New desktop action backends should implement `TipTourActionDriver` and be wired through `ActionExecutor`.
- New grounding or screen-understanding logic belongs in `TipTour/Perception/` and should be called by `TipTour/Workflow/ElementResolver.swift`.
- Menu bar toggles should stay simple: user-facing connection state in `CompanionManager`, display in `TipTour/UI/CompanionPanelView.swift`, and enforcement in the engine/action facade.
- TipTour does not have a dynamic plugin marketplace yet. Keep the model explicit and boring: built-in connections such as CUA, Hermes, and Pipecat Voice are represented by small models, toggled from the menu bar, and enforced by the engine/action facade.

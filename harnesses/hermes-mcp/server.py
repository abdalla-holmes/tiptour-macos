#!/usr/bin/env python3
"""MCP bridge from Hermes to TipTour's local macOS harness."""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Any

from mcp.server.fastmcp import FastMCP


TIPTOUR_BASE_URL = "http://127.0.0.1:19474"

mcp = FastMCP("tiptour")


def _request_json(
    path: str,
    payload: dict[str, Any] | None = None,
    timeout_seconds: int = 10,
) -> dict[str, Any]:
    url = f"{TIPTOUR_BASE_URL}{path}"
    data = None
    headers = {"Accept": "application/json"}

    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    request = urllib.request.Request(url, data=data, headers=headers)

    try:
        with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
            response_body = response.read().decode("utf-8")
    except urllib.error.URLError as error:
        return {
            "ok": False,
            "reason": "tiptour_unavailable",
            "message": str(error),
        }

    try:
        parsed = json.loads(response_body)
    except json.JSONDecodeError:
        return {
            "ok": False,
            "reason": "invalid_tiptour_response",
            "message": response_body,
        }

    if isinstance(parsed, dict):
        return parsed

    return {"ok": True, "value": parsed}


@mcp.tool()
def tiptour_observe() -> dict[str, Any]:
    """Observe TipTour's current local state without requesting screenshots."""
    return _request_json("/v1/observe")


@mcp.tool()
def tiptour_targets() -> dict[str, Any]:
    """Refresh and return TipTour's current local YOLO/OCR grounding targets."""
    return _request_json("/v1/targets")


@mcp.tool()
def tiptour_action_history() -> dict[str, Any]:
    """Return recent TipTour grounded-action attempts and validation outcomes."""
    return _request_json("/v1/action-history")


@mcp.tool()
def tiptour_resolve_highlight_source(
    source_file_path: str | None = None,
    trace_id: str | None = None,
) -> dict[str, Any]:
    """Resolve the user's current TipTour highlight into a file, URL, text, or visual source.

    Call this when the user says "this image", "this file", "the highlighted
    area", or similar. TipTour returns the resolved source plus suggested
    tools such as image_edit, text_edit, selected_text_edit, open_source, or
    visual_context.
    """
    return _request_json(
        "/v1/resolve-highlight-source",
        {
            "source_file_path": source_file_path,
            "trace_id": trace_id,
        },
    )


@mcp.tool()
def tiptour_image_edit(
    prompt: str,
    source_file_path: str | None = None,
    execute: bool = False,
    provider: str = "gemini",
    model: str = "gemini-2.5-flash-image",
    output_mode: str = "copy",
    open_result: bool = True,
    trace_id: str | None = None,
) -> dict[str, Any]:
    """Prepare or execute a file-aware edit for the highlighted image.

    Use execute=False first to resolve the source and create local artifacts.
    Use execute=True only when the source is an image, TipTour screenshots are
    enabled, and the user wants the configured image model called. TipTour
    saves a copy of the result and never overwrites the original image.
    """
    return _request_json(
        "/v1/image-edit",
        {
            "prompt": prompt,
            "source": "current_highlight",
            "source_file_path": source_file_path,
            "execute": execute,
            "provider": provider,
            "model": model,
            "output_mode": output_mode,
            "open_result": open_result,
            "trace_id": trace_id,
        },
        timeout_seconds=180 if execute else 30,
    )


@mcp.tool()
def tiptour_plan_next_action(
    goal: str,
    app: str | None = None,
    target_label: str | None = None,
    action: str = "click",
    execute: bool = True,
    allow_screenshot_planning: bool = False,
    validate_state_change: bool = True,
) -> dict[str, Any]:
    """Ask TipTour to choose one grounded local target and optionally execute it.

    Prefer this over hand-written box_2d coordinates. TipTour refreshes its
    local YOLO/OCR perception cache, matches target_label or goal against real
    on-screen targets, executes one action, refreshes perception, and reports
    whether the visible target set changed. If validation fails, TipTour tries
    one local perception repair before giving up. It refuses to guess raw
    coordinates when no target matches.
    """
    return _request_json(
        "/v1/plan-next-action",
        {
            "goal": goal,
            "app": app,
            "target_label": target_label,
            "action": action,
            "execute": execute,
            "allow_screenshot_planning": allow_screenshot_planning,
            "validate_state_change": validate_state_change,
        },
    )


@mcp.tool()
def tiptour_submit_workflow_plan(
    goal: str,
    app: str | None,
    steps: list[dict[str, Any]],
) -> dict[str, Any]:
    """Submit one desktop action to TipTour.

    Steps use TipTour's workflow shape. Example:
    [{"type": "click", "label": "Add", "hint": "Click the Add menu"}]

    TipTour clamps every request to the first step, executes through its
    existing local grounding/action stack, and returns how many steps were
    accepted or ignored.
    """
    return _request_json(
        "/v1/workflow-plan",
        {
            "goal": goal,
            "app": app,
            "steps": steps,
        },
    )


if __name__ == "__main__":
    mcp.run()

# OmniParser Harness

OmniParser is an optional local parser sidecar for experiments. It should not replace TipTour's native YOLO/OCR path until we benchmark it.

TipTour keeps ownership of:

- screen capture permission and capture timing
- native AX/CDP/YOLO/OCR perception
- target IDs and global coordinate conversion
- cursor animation and CUA action execution
- one-action validation and safety rails

OmniParser owns:

- richer screenshot parsing
- interactable region detection
- icon/function captions
- additional semantic labels for unlabeled controls

## Local Service

| Service | URL | Role |
| --- | --- | --- |
| TipTour harness | `http://127.0.0.1:19474` | Final local perception/action engine |
| OmniParser sidecar | `http://127.0.0.1:8765` | Optional richer screen parser |

The first OmniParser sidecar contract is:

- `GET /v1/health`
- `POST /v1/parse`

TipTour also supports the current local legacy server in `/Users/milindsoni/Documents/mywork/OmniParser/server.py`:

- `GET /models`
- `POST /parse` with `{ "image": "...jpeg base64..." }`

TipTour also tolerates the official OmniParser FastAPI shape:

- `GET /probe/`
- `POST /parse/` with `{ "base64_image": "...jpeg base64..." }`

`POST /v1/parse` receives:

```json
{
  "imageBase64": "...jpeg...",
  "imageWidth": 1512,
  "imageHeight": 982
}
```

and returns:

```json
{
  "ok": true,
  "elements": [
    {
      "bbox": [252, 98, 276, 109],
      "label": "Add",
      "source": "icon_caption",
      "confidence": 0.91
    }
  ]
}
```

Coordinates are screenshot pixels in `[x1, y1, x2, y2]` order with origin at the top-left of the captured image.

## Merge Policy

When the OmniParser toggle is enabled, TipTour still runs native YOLO/OCR and appends OmniParser results into the same `LocalPerceptionTargetCache`.

Sources are normalized to:

- `ocr`
- `yolo`
- `omniparser`
- `omniparser-*`

Hermes and other orchestrators should keep using `/v1/targets` and choose `target_id` or `target_mark`. They should not call OmniParser directly.

## Experiment Goal

Use OmniParser to improve target quality for:

- unlabeled toolbar icons
- visually grouped controls
- ambiguous duplicate text labels
- controls where OCR knows the text but not the interactable region

Do not use it for semantic app regions like `blender.viewport.center`. Those should be deterministic TipTour semantic targets, not parsed text.

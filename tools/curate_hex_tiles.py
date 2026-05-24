"""Curation tool for the carved world-map hex tiles.

Launches a tiny local HTTP server + opens a browser. Per scene/biome, shows every
carved hex as a thumbnail; click to toggle inclusion. Selections persist to
`data/hex_tile_curation.json` and are honored by `tools/build_hex_tiles_json.py`
when it next builds `data/hex_tiles.json`.

Usage:
    python tools/curate_hex_tiles.py            # open at http://localhost:8765/
    python tools/curate_hex_tiles.py --port 9000
"""
from __future__ import annotations

import argparse
import json
import os
import threading
import time
import webbrowser
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent
GAME_ROOT = ROOT / "tfa-simultaneous-gemini-1"
HEX_DIR = GAME_ROOT / "Assets" / "HexTiles"
CURATION_PATH = GAME_ROOT / "data" / "hex_tile_curation.json"

SKIP_SCENE_NAMES = {"_v1", "_v2", "sources", "icons"}


def list_scenes() -> list[dict]:
    """Return [{name, count}, ...] for every scene folder containing carved hexes."""
    scenes = []
    for entry in sorted(HEX_DIR.iterdir()):
        if not entry.is_dir() or entry.name in SKIP_SCENE_NAMES:
            continue
        hexes = sorted(p.name for p in entry.glob(f"{entry.name}_c*_r*.png"))
        if hexes:
            scenes.append({"name": entry.name, "count": len(hexes)})
    return scenes


def list_hexes(scene: str) -> list[str]:
    d = HEX_DIR / scene
    if not d.is_dir():
        return []
    return sorted(p.name for p in d.glob(f"{scene}_c*_r*.png"))


def load_curation() -> dict:
    if not CURATION_PATH.exists():
        return {}
    try:
        return json.loads(CURATION_PATH.read_text())
    except Exception as e:  # noqa: BLE001
        print(f"WARN: failed to parse {CURATION_PATH}: {e}")
        return {}


def save_curation(data: dict) -> None:
    CURATION_PATH.parent.mkdir(parents=True, exist_ok=True)
    CURATION_PATH.write_text(json.dumps(data, indent=2, sort_keys=True))


INDEX_HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>Hex Tile Curation</title>
<style>
:root {
  --bg: #1c1c1f;
  --panel: #25262b;
  --fg: #e9e9ee;
  --muted: #8c8c93;
  --accent: #4ade80;
  --reject: #444751;
}
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; background: var(--bg); color: var(--fg); font: 14px/1.4 system-ui, sans-serif; }
header { display: flex; align-items: center; gap: 16px; padding: 12px 16px; background: var(--panel); position: sticky; top: 0; z-index: 10; border-bottom: 1px solid #000; }
header h1 { margin: 0; font-size: 16px; font-weight: 600; }
header .spacer { flex: 1; }
button { background: #34353c; color: var(--fg); border: 1px solid #44464d; border-radius: 4px; padding: 6px 12px; font: inherit; cursor: pointer; }
button:hover { background: #3e4047; }
button.primary { background: var(--accent); color: #0a1a10; border-color: var(--accent); font-weight: 600; }
button.primary:disabled { opacity: 0.6; cursor: not-allowed; }
.layout { display: flex; min-height: calc(100vh - 49px); }
nav { width: 240px; border-right: 1px solid #000; padding: 8px 0; background: var(--panel); overflow-y: auto; max-height: calc(100vh - 49px); position: sticky; top: 49px; }
nav .scene { padding: 8px 14px; cursor: pointer; border-left: 3px solid transparent; display: flex; justify-content: space-between; gap: 8px; align-items: center; }
nav .scene:hover { background: #2c2d33; }
nav .scene.active { background: #2c2d33; border-left-color: var(--accent); }
nav .scene .count { color: var(--muted); font-size: 12px; }
nav .scene .selected { color: var(--accent); font-size: 12px; font-variant-numeric: tabular-nums; }
main { flex: 1; padding: 16px; }
.toolbar { display: flex; gap: 8px; align-items: center; margin-bottom: 12px; }
.toolbar .name { font-size: 18px; font-weight: 600; margin-right: auto; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 10px; }
.tile { position: relative; background: #15161a; border: 2px solid #44464d; border-radius: 4px; overflow: hidden; cursor: pointer; aspect-ratio: 1.155 / 1; }
.tile img { width: 100%; height: 100%; object-fit: contain; display: block; }
.tile.selected { border-color: var(--accent); }
.tile.selected::after { content: "✓"; position: absolute; top: 4px; right: 4px; background: var(--accent); color: #0a1a10; width: 22px; height: 22px; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-weight: 700; }
.tile:not(.selected) { opacity: 0.5; }
.tile:not(.selected):hover { opacity: 0.8; }
.tile .label { position: absolute; bottom: 0; left: 0; right: 0; background: rgba(0,0,0,0.6); color: var(--fg); font-size: 11px; padding: 2px 4px; font-variant-numeric: tabular-nums; }
.status { color: var(--muted); font-size: 12px; }
.status.saved { color: var(--accent); }
</style>
</head>
<body>
<header>
  <h1>Hex Tile Curation</h1>
  <span class="status" id="status">loading…</span>
  <span class="spacer"></span>
  <button id="save" class="primary" disabled>Save curation</button>
</header>
<div class="layout">
  <nav id="scene-list"></nav>
  <main>
    <div class="toolbar">
      <span class="name" id="scene-name">—</span>
      <button id="select-all">Select all</button>
      <button id="select-none">Select none</button>
    </div>
    <div class="grid" id="grid"></div>
  </main>
</div>
<script>
let scenes = [];
let activeScene = null;
let curation = {};      // {scene: Set<filename>}
let dirty = false;

const $ = (s) => document.querySelector(s);

async function api(path, init) {
  const r = await fetch(path, init);
  if (!r.ok) throw new Error(`${r.status} ${r.statusText}`);
  return r.json();
}

function setStatus(msg, saved=false) {
  $("#status").textContent = msg;
  $("#status").className = "status" + (saved ? " saved" : "");
}

function setDirty(d) {
  dirty = d;
  $("#save").disabled = !d;
}

function selectedCount(scene) {
  const set = curation[scene];
  if (!set) return 0;
  return set.size;
}

function renderSceneList() {
  const el = $("#scene-list");
  el.innerHTML = "";
  for (const s of scenes) {
    const div = document.createElement("div");
    div.className = "scene" + (s.name === activeScene ? " active" : "");
    div.dataset.scene = s.name;
    const sel = selectedCount(s.name);
    div.innerHTML = `<span>${s.name}</span><span><span class="selected">${sel}</span> <span class="count">/${s.count}</span></span>`;
    div.addEventListener("click", () => loadScene(s.name));
    el.appendChild(div);
  }
}

async function loadScene(name) {
  activeScene = name;
  renderSceneList();
  $("#scene-name").textContent = name;
  const data = await api(`/api/scene/${encodeURIComponent(name)}`);
  // data: {hexes: [filename, ...], selected: [filename, ...]}
  if (!curation[name]) {
    curation[name] = new Set(data.selected);
  }
  const grid = $("#grid");
  grid.innerHTML = "";
  for (const h of data.hexes) {
    const tile = document.createElement("div");
    tile.className = "tile" + (curation[name].has(h) ? " selected" : "");
    tile.dataset.filename = h;
    const m = h.match(/_c(\d+)_r(\d+)/);
    const label = m ? `c${m[1]} r${m[2]}` : h;
    tile.innerHTML = `<img loading="lazy" src="/img/${name}/${h}" alt="${h}"><div class="label">${label}</div>`;
    tile.addEventListener("click", () => toggleTile(name, h, tile));
    grid.appendChild(tile);
  }
}

function toggleTile(scene, filename, tile) {
  if (curation[scene].has(filename)) {
    curation[scene].delete(filename);
    tile.classList.remove("selected");
  } else {
    curation[scene].add(filename);
    tile.classList.add("selected");
  }
  setDirty(true);
  renderSceneList();
}

$("#select-all").addEventListener("click", () => {
  if (!activeScene) return;
  document.querySelectorAll(".tile").forEach(t => {
    curation[activeScene].add(t.dataset.filename);
    t.classList.add("selected");
  });
  setDirty(true);
  renderSceneList();
});

$("#select-none").addEventListener("click", () => {
  if (!activeScene) return;
  curation[activeScene].clear();
  document.querySelectorAll(".tile").forEach(t => t.classList.remove("selected"));
  setDirty(true);
  renderSceneList();
});

$("#save").addEventListener("click", async () => {
  const payload = {};
  for (const [k, v] of Object.entries(curation)) {
    payload[k] = Array.from(v).sort();
  }
  setStatus("saving…");
  try {
    await api("/api/curation", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    setDirty(false);
    setStatus("saved.", true);
  } catch (e) {
    setStatus("save failed: " + e.message);
  }
});

async function init() {
  scenes = (await api("/api/scenes")).scenes;
  curation = {};
  const existing = (await api("/api/curation")).curation;
  for (const [k, v] of Object.entries(existing)) {
    curation[k] = new Set(v);
  }
  renderSceneList();
  if (scenes.length > 0) await loadScene(scenes[0].name);
  setStatus(`${scenes.length} scenes loaded.`);
}
init().catch(e => setStatus("init failed: " + e.message));
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "HexCuration/0.1"

    def _send_json(self, code: int, payload) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_bytes(self, code: int, content_type: str, body: bytes) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args) -> None:
        # Quieter than default — only show errors.
        if args and isinstance(args[1], str) and not args[1].startswith(("2", "3")):
            super().log_message(fmt, *args)

    def do_GET(self) -> None:  # noqa: N802
        path = unquote(self.path.split("?", 1)[0])
        if path == "/" or path == "/index.html":
            body = INDEX_HTML.encode("utf-8")
            self._send_bytes(200, "text/html; charset=utf-8", body)
            return
        if path == "/api/scenes":
            self._send_json(200, {"scenes": list_scenes()})
            return
        if path.startswith("/api/scene/"):
            scene = path[len("/api/scene/"):]
            hexes = list_hexes(scene)
            cur = load_curation()
            selected = cur.get(scene, hexes)  # default to all
            self._send_json(200, {"hexes": hexes, "selected": selected})
            return
        if path == "/api/curation":
            self._send_json(200, {"curation": load_curation()})
            return
        if path.startswith("/img/"):
            rel = path[len("/img/"):]
            scene, _, fname = rel.partition("/")
            if not scene or not fname or scene in SKIP_SCENE_NAMES or "/" in fname or "\\" in fname:
                self._send_json(404, {"error": "bad image path"})
                return
            fp = HEX_DIR / scene / fname
            if not fp.is_file():
                self._send_json(404, {"error": "not found"})
                return
            self._send_bytes(200, "image/png", fp.read_bytes())
            return
        self._send_json(404, {"error": "not found", "path": path})

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/api/curation":
            self._send_json(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        try:
            payload = json.loads(body)
        except Exception as e:  # noqa: BLE001
            self._send_json(400, {"error": f"bad json: {e}"})
            return
        if not isinstance(payload, dict):
            self._send_json(400, {"error": "expected object"})
            return
        save_curation(payload)
        n = sum(len(v) for v in payload.values())
        print(f"  saved curation: {len(payload)} scenes, {n} total hexes selected -> {CURATION_PATH}")
        self._send_json(200, {"ok": True, "scenes": len(payload), "total_selected": n})


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--no-browser", action="store_true", help="don't auto-open browser")
    args = ap.parse_args()

    if not HEX_DIR.is_dir():
        print(f"ERROR: hex tiles directory missing: {HEX_DIR}")
        return 2

    server = HTTPServer((args.host, args.port), Handler)
    url = f"http://{args.host}:{args.port}/"
    print(f"Curation tool listening on {url}")
    print(f"Curation file: {CURATION_PATH}")
    print("Press Ctrl+C to stop.")

    if not args.no_browser:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

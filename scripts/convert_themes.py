#!/usr/bin/env python3
"""Convert Windows Terminal color schemes from the MIT-licensed
mbadolato/iTerm2-Color-Schemes corpus into Tecolot theme JSON.

Usage: convert_themes.py <path-to-iTerm2-Color-Schemes>/windowsterminal <output-dir>

The curated list below picks ~100 well-known themes with a mix of dark,
light and novelty palettes. Re-run after editing the list; output files
are named by slug and are checked into Resources/Themes.
"""
import json
import re
import sys
from pathlib import Path

CURATED = [
    # Terminal.app equivalents
    "Apple Classic", "Apple System Colors", "Apple System Colors Light",
    "Pro", "Pro Light", "Man Page", "Ocean", "Homebrew", "Novel", "Red Sands",
    "Terminal Basic", "Terminal Basic Dark",
    # The classics
    "Dracula", "Nord", "Nord Light", "Zenburn", "Molokai", "IR Black",
    "Jellybeans", "Wombat", "Twilight", "Obsidian", "Cobalt2", "Espresso",
    "Tomorrow", "Tomorrow Night", "Tomorrow Night Eighties", "Tomorrow Night Blue",
    "iTerm2 Solarized Dark", "iTerm2 Solarized Light",
    "Solarized Dark Higher Contrast", "Selenized Dark", "Selenized Light",
    # Modern favorites
    "Catppuccin Mocha", "Catppuccin Macchiato", "Catppuccin Frappe", "Catppuccin Latte",
    "TokyoNight", "TokyoNight Storm", "TokyoNight Moon", "TokyoNight Day",
    "Gruvbox Dark", "Gruvbox Dark Hard", "Gruvbox Light",
    "Everforest Dark Med", "Everforest Light Med",
    "Rose Pine", "Rose Pine Moon", "Rose Pine Dawn",
    "Kanagawa Wave", "Kanagawa Dragon", "Kanagawa Lotus",
    "One Half Dark", "One Half Light", "Atom One Dark", "Atom One Light",
    "Ayu", "Ayu Mirage", "Ayu Light",
    "Night Owl", "Nightfox", "Duskfox", "Carbonfox", "Terafox", "Nordfox", "Dayfox",
    "Monokai Pro", "Monokai Remastered", "Monokai Soda",
    "Material", "Material Darker", "Material Ocean",
    "Snazzy", "Challenger Deep", "Horizon", "Andromeda", "Argonaut",
    "Oceanic Next", "Sonokai", "Srcery", "Moonfly", "Oxocarbon", "Poimandres",
    "Vesper", "Mellow", "Miasma", "Hybrid", "Afterglow", "Hardcore",
    "Flexoki Dark", "Flexoki Light", "Melange Dark", "Melange Light",
    "Modus Operandi", "Modus Vivendi", "Zenbones", "Zenbones Dark", "Zenbones Light",
    # Vendor looks
    "GitHub Dark Default", "GitHub Dark Dimmed", "GitHub Light Default",
    "Dark Modern", "Dark+", "JetBrains Darcula",
    "Xcode Dark", "Xcode Light", "Ubuntu", "Adwaita", "Adwaita Dark",
    "Raycast Dark", "Raycast Light", "Vercel", "Claude",
    "Nvim Dark", "Nvim Light",
    # Retro / fun
    "C64", "Borland", "Matrix", "Blue Matrix", "Green Phosphor CRT",
    "Amber CRT Retro", "Terminal Green 1999", "Retro",
    "Synthwave Alpha", "Synthwave Everything", "Cyberpunk", "Outrun Electric",
    "Fairyfloss", "Shades Of Purple", "Rebecca", "Spiderman", "The Hulk",
    "Batman", "Toy Chest", "Under The Sea", "Wild Cherry", "Earthsong",
    "Alabaster", "Chalkboard", "Sea Shells",
]

ANSI_KEYS = [
    "black", "red", "green", "yellow", "blue", "purple", "cyan", "white",
    "brightBlack", "brightRed", "brightGreen", "brightYellow",
    "brightBlue", "brightPurple", "brightCyan", "brightWhite",
]

HEX_RE = re.compile(r"^#[0-9a-fA-F]{6}$")


def slug(name: str) -> str:
    out = []
    last_dash = False
    for ch in name.lower():
        if ch.isalnum():
            out.append(ch)
            last_dash = False
        elif not last_dash:
            out.append("-")
            last_dash = True
    return "".join(out).strip("-")


def convert(source: dict) -> dict:
    for key in ANSI_KEYS + ["background", "foreground"]:
        value = source.get(key)
        if not value or not HEX_RE.match(value):
            raise ValueError(f"missing or invalid {key}")
    theme = {
        "name": source["name"],
        "ansi": [source[k].lower() for k in ANSI_KEYS],
        "foreground": source["foreground"].lower(),
        "background": source["background"].lower(),
    }
    if source.get("cursorColor") and HEX_RE.match(source["cursorColor"]):
        theme["cursor"] = source["cursorColor"].lower()
    if source.get("selectionBackground") and HEX_RE.match(source["selectionBackground"]):
        theme["selectionBackground"] = source["selectionBackground"].lower()
    return theme


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    source_dir = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])
    output_dir.mkdir(parents=True, exist_ok=True)

    missing, converted = [], 0
    for name in CURATED:
        source_file = source_dir / f"{name}.json"
        if not source_file.exists():
            missing.append(name)
            continue
        theme = convert(json.loads(source_file.read_text()))
        out = output_dir / f"{slug(name)}.json"
        out.write_text(json.dumps(theme, indent=2) + "\n")
        converted += 1

    print(f"converted {converted} themes to {output_dir}")
    if missing:
        print("MISSING from corpus:")
        for name in missing:
            print(f"  {name}")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())

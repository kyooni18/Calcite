#!/usr/bin/env python3
"""Generate deterministic EditorVim compatibility fixtures with system Vim.

The generated cases intentionally use an ASCII, non-interactive subset so Vim's
byte columns and EditorVim's UTF-16 offsets are directly comparable.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Tests" / "EditorVimTests" / "Fixtures" / "vim-differential.json"

BASE = "one two three\n    four-five six\nseven eight nine\nlast line\n"
CASES = [
    ("word-forward", BASE, 0, "w"),
    ("counted-word-forward", BASE, 0, "2w"),
    ("word-end", BASE, 0, "e"),
    ("counted-word-end", BASE, 0, "2e"),
    ("word-backward", BASE, 8, "b"),
    ("counted-word-backward", BASE, 14, "2b"),
    ("line-start", BASE, 8, "0"),
    ("first-nonblank", BASE, 14, "^"),
    ("line-end", BASE, 0, "$"),
    ("document-start", BASE, 42, "gg"),
    ("document-end", BASE, 0, "G"),
    ("line-by-count", BASE, 0, "3G"),
    ("line-down", BASE, 8, "j"),
    ("counted-line-down", BASE, 8, "2j"),
    ("line-up", BASE, 42, "k"),
    ("next-line-first-nonblank", BASE, 0, "+"),
    ("previous-line-first-nonblank", BASE, 42, "-"),
    ("current-line-first-nonblank", BASE, 18, "_"),
    ("counted-underscore", BASE, 0, "2_"),
    ("column", BASE, 0, "7|"),
    ("delete-character", BASE, 0, "x"),
    ("delete-counted-characters", BASE, 0, "3x"),
    ("delete-line", BASE, 0, "dd"),
    ("delete-counted-lines", BASE, 0, "2dd"),
    ("delete-word", BASE, 0, "dw"),
    ("delete-counted-words", BASE, 0, "2dw"),
    ("delete-word-end", BASE, 0, "de"),
    ("delete-backward-word", BASE, 8, "db"),
    ("delete-to-line-end", BASE, 4, "d$"),
    ("delete-to-line-start", BASE, 8, "d0"),
    ("delete-to-first-nonblank", BASE, 18, "d^"),
    ("delete-to-document-end", BASE, 27, "dG"),
    ("delete-to-document-start", BASE, 42, "dgg"),
    ("yank-word-no-text-change", BASE, 0, "yw"),
    ("yank-line-no-text-change", BASE, 0, "yy"),
    ("indent-line", BASE, 0, ">>"),
    ("indent-counted-lines", BASE, 0, "2>>"),
    ("outdent-line", BASE, 18, "<<"),
    ("join-lines", BASE, 0, "J"),
    ("join-three-lines", BASE, 0, "2J"),
    ("swap-case", BASE, 0, "~"),
    ("swap-case-count", BASE, 0, "3~"),
    ("find-forward", BASE, 14, "f-"),
    ("till-forward", BASE, 14, "t-"),
    ("find-backward", BASE, 27, "F-"),
    ("till-backward", BASE, 27, "T-"),
    ("repeat-find", "a-b-c-d\n", 0, "f-;"),
    ("reverse-find", "a-b-c-d\n", 0, "f-;,"),
    ("visual-delete", BASE, 0, "vwx"),
    ("visual-line-delete", BASE, 0, "Vjd"),
]


def offset_to_line_col(text: str, offset: int) -> tuple[int, int]:
    before = text[:offset]
    line = before.count("\n") + 1
    col = len(before.rsplit("\n", 1)[-1]) + 1
    return line, col


def line_col_to_offset(text: str, line: int, col_zero_based: int) -> int:
    lines = text.splitlines(keepends=True)
    if not lines:
        return 0
    line_index = max(0, min(len(lines) - 1, line - 1))
    return sum(len(part) for part in lines[:line_index]) + min(col_zero_based, len(lines[line_index].rstrip("\r\n")))


def vim_quote(value: str) -> str:
    return value.replace("'", "''")


def run_case(vim: str, name: str, initial: str, cursor: int, keys: str) -> dict[str, object]:
    with tempfile.TemporaryDirectory(prefix="editorvim-diff-") as raw:
        directory = Path(raw)
        source = directory / "input.txt"
        result = directory / "result.txt"
        metadata = directory / "cursor.txt"
        script = directory / "case.vim"
        source.write_bytes(initial.encode("utf-8"))
        line, column = offset_to_line_col(initial, cursor)
        script.write_text(
            "\n".join(
                [
                    "set nomore shortmess+=I",
                    "set binary nofixeol noswapfile undolevels=-1",
                    "set expandtab shiftwidth=2 tabstop=2 softtabstop=2",
                    f"silent edit {source}",
                    f"call cursor({line}, {column})",
                    f"execute 'normal! {vim_quote(keys)}'",
                    f"call writefile(getline(1, '$'), '{result}', &endofline ? '' : 'b')",
                    f"call writefile([string(line('.')), string(col('.') - 1)], '{metadata}')",
                    "qa!",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        completed = subprocess.run(
            [vim, "-Nu", "NONE", "-n", "-es", "-S", str(script)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if completed.returncode != 0:
            raise RuntimeError(f"Vim failed for {name}: {completed.stderr}")
        final = result.read_bytes().decode("utf-8")
        meta = metadata.read_text(encoding="utf-8").splitlines()
        final_cursor = line_col_to_offset(final, int(meta[0]), int(meta[1]))
        return {
            "name": name,
            "initialText": initial,
            "initialCursor": cursor,
            "notation": keys,
            "expectedText": final,
            "expectedCursor": final_cursor,
        }


def main() -> None:
    vim = shutil.which(os.environ.get("VIM", "vim"))
    if not vim:
        raise SystemExit("vim is required to regenerate fixtures")
    fixtures = [run_case(vim, *case) for case in CASES]
    OUTPUT.write_text(json.dumps(fixtures, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {len(fixtures)} fixtures to {OUTPUT}")


if __name__ == "__main__":
    main()

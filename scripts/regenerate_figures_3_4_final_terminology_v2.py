#!/usr/bin/env python3
"""Regenerate manuscript Figures 3 and 4 with the final terminology.

This is a deterministic terminology-only update: it preserves all numerical
curves, axes, markers, and dimensions in the archived canonical PDFs, while
replacing the legacy labels

  * "Capacity-filled Lagrangian" with "Threshold-based Lagrangian"; and
  * "Mean gap to conditional threshold-dual benchmark (%)" with
    "Mean relative difference from threshold-based Lagrangian benchmark (%)".

Repository usage (from the repository root):

    python scripts/regenerate_figures_3_4_final_terminology.py

The script reads and overwrites the two canonical manuscript PDFs under
``reproducibility/figures/manuscript``.  Copies are also written under
``reproducibility/figures/notebook_outputs`` when that directory exists.
Use ``--input-dir`` and ``--output-dir`` to work elsewhere.
"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path
from typing import Iterable

import fitz  # PyMuPDF

FIGURE3 = "policy_relative_performance_by_capacity.pdf"
FIGURE4 = "mp_conditional_benchmark_gap_by_size.pdf"
FONT_FILE = Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")


def _span_matches(page: fitz.Page, target: str) -> list[dict]:
    matches: list[dict] = []
    for block in page.get_text("dict").get("blocks", []):
        for line in block.get("lines", []):
            for span in line.get("spans", []):
                if span.get("text") == target:
                    matches.append({**span, "direction": tuple(line.get("dir", (1.0, 0.0)))})
    return matches


def _require_count(items: Iterable[object], expected: int, description: str) -> list[object]:
    result = list(items)
    if len(result) != expected:
        raise RuntimeError(
            f"Expected {expected} occurrence(s) of {description}, found {len(result)}."
        )
    return result


def _font_kwargs() -> dict[str, str]:
    """Return a portable PyMuPDF font specification."""
    if FONT_FILE.is_file():
        return {"fontname": "DejaVuSansFinal", "fontfile": str(FONT_FILE)}
    return {"fontname": "helv"}


def _patch_figure3(source: Path, destination: Path) -> None:
    document = fitz.open(source)
    if document.page_count != 1:
        raise RuntimeError(f"{source} must contain exactly one page.")
    page = document[0]

    old = "Capacity-filled Lagrangian"
    new = "Threshold-based Lagrangian"
    spans = _require_count(_span_matches(page, old), 2, repr(old))
    lwz_spans = _require_count(_span_matches(page, "LWZ4"), 2, repr("LWZ4"))

    # Remove only the old legend text; the legend line/marker samples lie to
    # the left and are intentionally untouched.  Because the font bounding
    # boxes of adjacent legend rows overlap slightly, LWZ4 is restored below.
    for span in spans:
        rect = fitz.Rect(span["bbox"])
        rect.x0 -= 0.2
        rect.x1 += 0.3
        page.add_redact_annot(rect, fill=(1, 1, 1))
    page.apply_redactions(images=fitz.PDF_REDACT_IMAGE_NONE,
                          graphics=fitz.PDF_REDACT_LINE_ART_NONE,
                          text=fitz.PDF_REDACT_TEXT_REMOVE)

    font_kwargs = _font_kwargs()
    for span in spans:
        origin = fitz.Point(*span["origin"])
        # The new wording is longer, so use a minimally smaller legend font
        # while preserving the original baseline and alignment.
        page.insert_text(
            origin,
            new,
            **font_kwargs,
            fontsize=5.3,
            color=(0, 0, 0),
            overlay=True,
        )

    for span in lwz_spans:
        page.insert_text(
            fitz.Point(*span["origin"]),
            "LWZ4",
            **font_kwargs,
            fontsize=float(span["size"]),
            color=(0, 0, 0),
            overlay=True,
        )

    destination.parent.mkdir(parents=True, exist_ok=True)
    document.save(destination, garbage=4, deflate=True)
    document.close()


def _patch_figure4(source: Path, destination: Path) -> None:
    document = fitz.open(source)
    if document.page_count != 1:
        raise RuntimeError(f"{source} must contain exactly one page.")
    page = document[0]

    old_first = "Mean gap to conditional"
    old_second = "threshold-dual benchmark (%)"
    first = _require_count(_span_matches(page, old_first), 1, repr(old_first))[0]
    second = _require_count(_span_matches(page, old_second), 1, repr(old_second))[0]

    union = fitz.Rect(first["bbox"]) | fitz.Rect(second["bbox"])
    union.x0 = max(0.0, union.x0 - 1.0)
    union.y0 -= 1.0
    union.x1 += 1.0
    union.y1 += 1.0
    page.add_redact_annot(union, fill=(1, 1, 1))
    page.apply_redactions(images=fitz.PDF_REDACT_IMAGE_NONE,
                          graphics=fitz.PDF_REDACT_LINE_ART_NONE,
                          text=fitz.PDF_REDACT_TEXT_REMOVE)

    font_kwargs = _font_kwargs()
    font = (
        fitz.Font(fontfile=font_kwargs["fontfile"])
        if "fontfile" in font_kwargs
        else fitz.Font("helv")
    )
    labels = (
        "Mean relative difference from",
        "threshold-based Lagrangian benchmark (%)",
    )

    # Standard bottom-to-top y-axis orientation, matching the archived plot.
    # Use two lines rather than three to avoid crowding the rightmost label
    # against the y-axis tick labels.
    x_origins = (10.0, 18.7)
    vertical_center = 111.0
    fontsize = 6.4
    for x_origin, label in zip(x_origins, labels):
        length = font.text_length(label, fontsize=fontsize)
        origin = fitz.Point(x_origin, vertical_center + length / 2.0)
        page.insert_text(
            origin,
            label,
            **font_kwargs,
            fontsize=fontsize,
            rotate=90,
            color=(0, 0, 0),
            overlay=True,
        )

    destination.parent.mkdir(parents=True, exist_ok=True)
    document.save(destination, garbage=4, deflate=True)
    document.close()


def _copy_to_notebook_outputs(paths: list[Path], repository_root: Path) -> None:
    target = repository_root / "reproducibility" / "figures" / "notebook_outputs"
    if not target.is_dir():
        return
    for path in paths:
        shutil.copy2(path, target / path.name)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repository-root",
        type=Path,
        default=Path.cwd(),
        help="Root of paperPCLsensingErrors (default: current directory).",
    )
    parser.add_argument(
        "--input-dir",
        type=Path,
        default=None,
        help="Directory containing the two source PDFs. Defaults to the canonical manuscript-figure directory.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=None,
        help="Output directory. Defaults to the input directory (canonical files are replaced).",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    root = args.repository_root.resolve()
    input_dir = (
        args.input_dir.resolve()
        if args.input_dir is not None
        else root / "reproducibility" / "figures" / "manuscript"
    )
    output_dir = args.output_dir.resolve() if args.output_dir is not None else input_dir

    source3 = input_dir / FIGURE3
    source4 = input_dir / FIGURE4
    for source in (source3, source4):
        if not source.is_file():
            raise FileNotFoundError(source)

    # Save through temporary files when input and output directories coincide.
    temp_dir = output_dir / ".terminology_update_tmp"
    temp_dir.mkdir(parents=True, exist_ok=True)
    temp3 = temp_dir / FIGURE3
    temp4 = temp_dir / FIGURE4

    _patch_figure3(source3, temp3)
    _patch_figure4(source4, temp4)

    final3 = output_dir / FIGURE3
    final4 = output_dir / FIGURE4
    final3.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(temp3), str(final3))
    shutil.move(str(temp4), str(final4))
    temp_dir.rmdir()

    _copy_to_notebook_outputs([final3, final4], root)

    print(final3)
    print(final4)


if __name__ == "__main__":
    main()

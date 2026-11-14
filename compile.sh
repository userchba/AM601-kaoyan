#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# compile.sh – Build 601.pdf from the AM601-kaoyan project.
#
# Behaviour:
#   1. Resolve and work from the script's own directory (repo root).
#   2. Require xelatex; create a task-owned mktemp build directory
#      with cleanup via trap.
#   3. Compile three times.  Auxiliary files stay inside the temp build
#      directory; only the finished PDF lands at repo-root 601.pdf.
#   4. First attempt uses the exact project (fontset=windows).  If
#      that fails (e.g. missing SimSun), automatically retry with
#      temporary copies where fontset=windows → fontset=fandol.
#      Set PORTABLE_FONTS=1 to select Fandol directly (for Linux/CI).
#      No tracked .tex / .cls / .sty files are ever modified.
#   5. Ensure \include{1/…} works by creating the temp 1/ directory
#      and copying the source .tex files there.  Resource directories
#      (picture/, svg-inkscape/) are symlinked into the temp dir.
#      TEXINPUTS preserves the default search path while making the
#      project root (style.cls, ascolorbox.sty, …) findable.
#   6. Prints whether the normal or portable-fallback build succeeded.
# -------------------------------------------------------------------

# -- resolve script directory --------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# -- require xelatex -----------------------------------------------------------
if ! command -v xelatex &>/dev/null; then
    echo "ERROR: xelatex not found in PATH" >&2
    exit 1
fi

# -- task-owned temporary build directory --------------------------------------
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT
echo "Build directory: $BUILD_DIR"

# -- populate the temp build tree ----------------------------------------------
# 1. Main .tex source (copy so that \include-aux files land here)
cp "$SCRIPT_DIR/601.tex" "$BUILD_DIR/601.tex"

# 2. Sub-directory 1/ with all .tex files (must be real copies for aux output)
mkdir -p "$BUILD_DIR/1"
cp "$SCRIPT_DIR/1/"*.tex "$BUILD_DIR/1/"

# 3. Resource directories – try symlink first (fast), fall back to copy
for dir in picture svg-inkscape; do
    if [ -d "$SCRIPT_DIR/$dir" ]; then
        if ! ln -s "$SCRIPT_DIR/$dir" "$BUILD_DIR/$dir" 2>/dev/null; then
            cp -r "$SCRIPT_DIR/$dir" "$BUILD_DIR/$dir"
        fi
    fi
done

# 4. TeX search path: look in the build dir first, then the project root,
#    then the system default (the trailing colon preserves the system default).
export TEXINPUTS=".:$SCRIPT_DIR:"

# -- helper: compile a .tex file three times inside the build directory --------------
# Arguments:   $1 – main tex filename (relative to BUILD_DIR)
# Returns 0 on success, 1 if any xelatex pass fails.
compile_xelatex() {
    local main_tex="$1"
    local xelatex_opts=(
        -interaction=nonstopmode
        -halt-on-error
        -no-shell-escape
        -file-line-error
    )

    # First pass
    if ! ( cd "$BUILD_DIR" && xelatex "${xelatex_opts[@]}" "$main_tex" > /dev/null 2>&1 ); then
        return 1
    fi
    # Repeat to settle per-paper totals and PDF bookmarks.
    for pass in 2 3; do
        if ! ( cd "$BUILD_DIR" && xelatex "${xelatex_opts[@]}" "$main_tex" > /dev/null 2>&1 ); then
            return 1
        fi
    done
    return 0
}

# ======== Attempt 1: normal build – fontset=windows (original files) ==========
echo "=== Attempt 1: Building with fontset=windows ==="
if [ "${PORTABLE_FONTS:-0}" != "1" ] && compile_xelatex "601.tex"; then
    echo "Normal build (fontset=windows) succeeded."
    cp "$BUILD_DIR/601.pdf" "$SCRIPT_DIR/601.pdf"
    exit 0
fi
echo "Normal build failed (likely missing Windows fonts such as SimSun)."

# ======== Attempt 2: portable fallback – fontset=fandol =======================
echo "=== Attempt 2: Building with fontset=fandol ==="

# Generate temporary copies – never modify tracked sources
sed 's/fontset=windows/fontset=fandol/' "$SCRIPT_DIR/style.cls" \
    > "$BUILD_DIR/style-fandol.cls"
sed 's/\\documentclass{style}/\\documentclass{style-fandol}/' "$SCRIPT_DIR/601.tex" \
    > "$BUILD_DIR/601-fandol.tex"

# Remove auxiliary files from the failed first attempt (keep tex sources and resources)
find "$BUILD_DIR" \( -name '*.aux' -o -name '*.log' -o -name '*.out' -o -name '*.toc' \) -delete 2>/dev/null || true

if compile_xelatex "601-fandol.tex"; then
    echo "Portable fallback build (fontset=fandol) succeeded."
    cp "$BUILD_DIR/601-fandol.pdf" "$SCRIPT_DIR/601.pdf"
    exit 0
fi

echo "ERROR: Both normal and fallback builds failed." >&2
exit 1

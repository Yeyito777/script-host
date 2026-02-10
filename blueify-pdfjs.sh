#!/bin/bash
# Appends dark mode CSS tweaks to the PDF.js viewer stylesheet.
# Must be run with sudo.
#
# Usage:
#   sudo ./blueify-pdfjs.sh           # Apply the dark mode patch
#   sudo ./blueify-pdfjs.sh --remove  # Remove the dark mode patch

# === CONFIGURATION ===
# Background color (Deep Blue)
PDF_BG_COLOR="#00050f"

# Text Color (Hex).
# Note: Since this uses filters, this primarily controls the brightness/greyscale
# of the text. #ffffff is pure white, #dddddd is light grey, #888888 is dark grey.
TEXT_COLOR="#eeeeee"
# =====================

TARGET="/usr/share/pdf.js/web/viewer.css"
BACKUP="/usr/share/pdf.js/web/viewer.css.bak"

MARKER_START="/* === Custom Dark Mode Patch === */"
MARKER_END="/* === End Dark Mode Patch === */"

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run with sudo."
  exit 1
fi

# Check if target file exists
if [ ! -f "$TARGET" ]; then
  echo "Error: $TARGET not found. Please check the path."
  exit 1
fi

# --- Remove mode ---
if [ "$1" = "--remove" ]; then
  if ! grep -Fq "$MARKER_START" "$TARGET"; then
    echo "Patch not found in $TARGET. Nothing to remove."
    exit 0
  fi

  echo "Creating backup at $BACKUP..."
  cp "$TARGET" "$BACKUP"

  echo "Removing dark mode patch from $TARGET..."
  # Delete from the start marker through the end marker (inclusive)
  sed -i "/$(printf '%s' "$MARKER_START" | sed 's/[*/.[\\]/\\&/g')/,/$(printf '%s' "$MARKER_END" | sed 's/[*/.[\\]/\\&/g')/d" "$TARGET"
  # Remove any trailing blank lines left behind
  sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$TARGET"

  echo "Done. Patch removed."
  exit 0
fi

# --- Apply mode ---
if grep -Fq "$MARKER_START" "$TARGET"; then
  echo "Patch already applied to $TARGET. Nothing to do."
  echo "Use --remove to remove it first."
  exit 0
fi

# Calculate Brightness Ratio from Hex
# 1. Extract Red channel (first 2 chars after #) as an approximation for greyscale brightness
HEX_VAL=${TEXT_COLOR:1:2}
# 2. Convert Hex to Decimal
DEC_VAL=$(printf "%d" "0x${HEX_VAL}")
# 3. Calculate percentage (Decimal / 255) using awk for floating point precision
BRIGHTNESS=$(awk "BEGIN {print ${DEC_VAL}/255}")

echo "Configuration:"
echo "  Background: $PDF_BG_COLOR"
echo "  Text Hex:   $TEXT_COLOR"
echo "  Brightness: $BRIGHTNESS"

echo "Creating backup at $BACKUP..."
cp "$TARGET" "$BACKUP"

echo "Appending custom dark mode CSS to $TARGET..."
cat << EOF >> "$TARGET"

${MARKER_START}

/* 1. Set the physical background of the page container. */
.page, .page .canvasWrapper {
  background-color: ${PDF_BG_COLOR} !important;
  border-color: transparent !important;
}

/* 2. Manipulate the PDF Canvas.
   - invert(100%): Swaps White BG -> Black, Black Text -> White.
   - hue-rotate(180deg): Rotates colors back (so red stays red-ish).
   - brightness(${BRIGHTNESS}): Dims the text to match the requested hex value.
   - mix-blend-mode: screen: Makes the Black background transparent
     so the ${PDF_BG_COLOR} shows through. */
.page canvas {
  filter: invert(100%) hue-rotate(180deg) brightness(${BRIGHTNESS});
  mix-blend-mode: screen;
}

/* 3. Ensure the selection layer doesn't obscure the view */
.textLayer {
  opacity: 1;
  mix-blend-mode: normal;
}
${MARKER_END}

EOF

echo "Done."

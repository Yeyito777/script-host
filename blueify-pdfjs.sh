#!/bin/bash
# Appends dark mode CSS tweaks to the PDF.js viewer stylesheet.
# Must be run with sudo.

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

# Check if target file exists
if [ ! -f "$TARGET" ]; then
  echo "Error: $TARGET not found. Please check the path."
  exit 1
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

/* === Custom Dark Mode Patch === */

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
/* === End Dark Mode Patch === */

EOF

echo "Done."

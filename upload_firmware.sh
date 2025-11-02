#!/bin/bash
#
# Upload Firmware to Lolin S2 Mini
# Compiles and uploads the soundprojector firmware
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ARDUINO_CLI="/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli"
BOARD_FQBN="esp32:esp32:lolin_s2_mini"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo -e "${BLUE}=== Soundprojector Firmware Upload ===${NC}"
echo ""

# Find serial port
SERIAL_PORT="${1:-auto}"
if [ "$SERIAL_PORT" = "auto" ]; then
    echo -e "${YELLOW}Searching for Lolin S2 Mini...${NC}"

    # Look for usbmodem (ESP32-S2 native USB)
    if [ -e /dev/cu.usbmodem* ]; then
        SERIAL_PORT=$(ls /dev/cu.usbmodem* 2>/dev/null | head -n1)
    fi

    if [ -z "$SERIAL_PORT" ] || [ ! -e "$SERIAL_PORT" ]; then
        echo -e "${RED}ERROR: No ESP32-S2 found!${NC}"
        echo ""
        echo "Available ports:"
        ls -1 /dev/cu.* 2>/dev/null | grep -v Bluetooth | grep -v debug || echo "  (none)"
        echo ""
        echo "Make sure:"
        echo "  1. ESP32-S2 is connected via USB"
        echo "  2. No other programs (Arduino IDE, serial monitor) have the port open"
        echo ""
        echo "Usage: $0 [serial_port]"
        echo "Example: $0 /dev/cu.usbmodem01"
        exit 1
    fi
fi

echo -e "${GREEN}Using serial port: $SERIAL_PORT${NC}"
echo ""

# Compile
echo -e "${YELLOW}Compiling firmware...${NC}"
cd "$SCRIPT_DIR"
"$ARDUINO_CLI" compile -b "$BOARD_FQBN" \
  --board-options "CDCOnBoot=default" \
  soundprojector.ino

echo ""
echo -e "${GREEN}✓ Compilation successful${NC}"
echo ""

# Upload
echo -e "${YELLOW}Uploading to ESP32-S2...${NC}"
"$ARDUINO_CLI" upload -b "$BOARD_FQBN" \
  soundprojector.ino \
  --port "$SERIAL_PORT"

if [ $? -eq 0 ]; then
    echo ""
    echo -e "${GREEN}=== SUCCESS ===${NC}"
    echo -e "${GREEN}✓ Firmware uploaded successfully!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Open serial monitor (115200 baud) to see boot messages"
    echo "  2. Upload audio file: ./convert_upload.sh your_audio.mp3"
    echo "  3. Test trigger: Connect GPIO18 to GND"
else
    echo ""
    echo -e "${RED}=== FAILED ===${NC}"
    echo "Upload failed. Check error messages above."
    echo ""
    echo "Common issues:"
    echo "  - Port busy: Close Arduino IDE or serial monitor"
    echo "  - Wrong port: Try specifying port manually"
    echo "  - Device not in bootloader: Press RESET on board"
    exit 1
fi

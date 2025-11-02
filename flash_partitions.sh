#!/bin/bash
#
# Flash Custom Partition Table to ESP32-S2
# Board: Lolin (Wemos) S2 Mini
# This script generates and flashes partitions.csv to the ESP32
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARTITION_CSV="$SCRIPT_DIR/partitions.csv"
PARTITION_BIN="/tmp/partitions.bin"
GEN_ESP32PART="$HOME/Library/Arduino15/packages/esp32/hardware/esp32/3.3.0/tools/gen_esp32part.py"
ESPTOOL="$HOME/Library/Arduino15/packages/esp32/tools/esptool_py/5.0.0/esptool"

echo -e "${BLUE}=== ESP32 Custom Partition Table Flasher ===${NC}"
echo ""

# Check if partitions.csv exists
if [ ! -f "$PARTITION_CSV" ]; then
    echo -e "${RED}ERROR: partitions.csv not found at $PARTITION_CSV${NC}"
    exit 1
fi

# Check if gen_esp32part.py exists
if [ ! -f "$GEN_ESP32PART" ]; then
    echo -e "${RED}ERROR: gen_esp32part.py not found${NC}"
    echo "Expected at: $GEN_ESP32PART"
    echo "Please install ESP32 Arduino core"
    exit 1
fi

# Check if esptool exists
if [ ! -f "$ESPTOOL" ]; then
    echo -e "${RED}ERROR: esptool not found${NC}"
    echo "Expected at: $ESPTOOL"
    echo "Please install ESP32 Arduino core"
    exit 1
fi

# Find serial port
SERIAL_PORT="${1:-auto}"
if [ "$SERIAL_PORT" = "auto" ]; then
    echo -e "${YELLOW}Searching for ESP32...${NC}"

    # Try different port patterns
    if [ -e /dev/cu.usbmodem* ]; then
        SERIAL_PORT=$(ls /dev/cu.usbmodem* 2>/dev/null | head -n1)
    elif [ -e /dev/cu.usbserial-* ]; then
        SERIAL_PORT=$(ls /dev/cu.usbserial-* 2>/dev/null | head -n1)
    elif [ -e /dev/cu.SLAB_USBtoUART ]; then
        SERIAL_PORT="/dev/cu.SLAB_USBtoUART"
    elif [ -e /dev/cu.wchusbserial* ]; then
        SERIAL_PORT=$(ls /dev/cu.wchusbserial* 2>/dev/null | head -n1)
    fi

    if [ -z "$SERIAL_PORT" ] || [ ! -e "$SERIAL_PORT" ]; then
        echo -e "${RED}ERROR: No ESP32 found!${NC}"
        echo ""
        echo "Available ports:"
        ls -1 /dev/cu.* 2>/dev/null | grep -v Bluetooth | grep -v debug || echo "  (none)"
        echo ""
        echo "Usage: $0 [serial_port]"
        echo "Example: $0 /dev/cu.usbmodem01"
        exit 1
    fi
fi

echo -e "${GREEN}Using serial port: $SERIAL_PORT${NC}"
echo ""

# Display partitions.csv
echo -e "${BLUE}=== Partition Layout (from partitions.csv) ===${NC}"
echo ""
printf "%-12s %-8s %-10s %-12s %-12s\n" "NAME" "TYPE" "SUBTYPE" "OFFSET" "SIZE"
echo "----------------------------------------------------------------"

while IFS=',' read -r name ptype subtype offset size flags; do
    # Skip comments and header
    if [[ "$name" =~ ^# ]] || [[ "$name" =~ ^Name ]]; then
        continue
    fi

    # Clean whitespace
    name=$(echo "$name" | xargs)
    ptype=$(echo "$ptype" | xargs)
    subtype=$(echo "$subtype" | xargs)
    offset=$(echo "$offset" | xargs)
    size=$(echo "$size" | xargs)

    if [ -n "$name" ]; then
        # Calculate size in MB
        if [[ "$size" =~ ^0x ]]; then
            size_bytes=$((size))
        else
            size_bytes=$size
        fi
        size_mb=$(echo "scale=2; $size_bytes / 1048576" | bc)

        printf "%-12s %-8s %-10s %-12s %-12s (%.1fMB)\n" "$name" "$ptype" "$subtype" "$offset" "$size" "$size_mb"
    fi
done < "$PARTITION_CSV"

echo ""

# Generate partition binary
echo -e "${YELLOW}Generating partition table binary...${NC}"
python3 "$GEN_ESP32PART" "$PARTITION_CSV" "$PARTITION_BIN"

if [ ! -f "$PARTITION_BIN" ]; then
    echo -e "${RED}ERROR: Failed to generate partition binary${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Partition binary generated: $PARTITION_BIN${NC}"
echo ""

# Flash partition table
echo -e "${YELLOW}Flashing partition table to ESP32...${NC}"
echo "Port: $SERIAL_PORT"
echo "Offset: 0x8000 (partition table location)"
echo ""

"$ESPTOOL" --port "$SERIAL_PORT" write_flash 0x8000 "$PARTITION_BIN"

if [ $? -eq 0 ]; then
    echo ""
    echo -e "${GREEN}=== SUCCESS ===${NC}"
    echo -e "${GREEN}✓ Custom partition table flashed successfully!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Upload your firmware with arduino-cli"
    echo "  2. Upload audio files with ./convert_upload.sh"
    echo ""
    echo "To verify the partition table was flashed:"
    echo "  ./check_partitions.sh $SERIAL_PORT"
else
    echo ""
    echo -e "${RED}=== FAILED ===${NC}"
    echo "Flash operation failed. Check the error messages above."
    exit 1
fi

#!/bin/bash
#
# Ultrasonic Sound Projector - Audio Conversion & Upload Script
# Converts any audio format to 8-bit raw PCM and uploads to ESP32-S2
#

set -e  # Exit on error

# Configuration
ARDUINO_CLI="/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli"
BOARD_FQBN="esp32:esp32:lolin_s2_mini"
SAMPLE_RATE=40000
DATA_DIR="$(dirname "$0")/data"
OUTPUT_FILE="$DATA_DIR/audio.raw"
PARTITION_FILE="$(dirname "$0")/partitions.csv"

# Read SPIFFS size from partitions.csv
get_spiffs_size() {
    if [ -f "$PARTITION_FILE" ]; then
        while IFS=',' read -r name ptype subtype offset size flags; do
            # Remove whitespace
            subtype=$(echo "$subtype" | xargs)
            size=$(echo "$size" | xargs)

            if [ "$subtype" = "spiffs" ]; then
                # Convert hex to decimal
                if [[ "$size" =~ ^0x ]]; then
                    echo $((size))
                else
                    echo "$size"
                fi
                return
            fi
        done < "$PARTITION_FILE"
    fi
    # Default fallback
    echo "2500000"
}

SPIFFS_SIZE=$(get_spiffs_size)
MAX_SIZE_BYTES=$((SPIFFS_SIZE * 95 / 100))  # 95% of SPIFFS (leaving overhead)
MAX_DURATION_SEC=$((MAX_SIZE_BYTES / SAMPLE_RATE))

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check dependencies
check_dependencies() {
    if ! command -v ffmpeg &> /dev/null; then
        echo -e "${RED}ERROR: ffmpeg not found!${NC}"
        echo "Install with: brew install ffmpeg"
        exit 1
    fi

    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}ERROR: python3 not found!${NC}"
        exit 1
    fi
}

# Show usage
usage() {
    echo "Usage: $0 <input_audio_file> [serial_port]"
    echo ""
    echo "Examples:"
    echo "  $0 alarm.mp3"
    echo "  $0 doorbell.wav /dev/cu.usbserial-0001"
    echo ""
    echo "Supported formats: .wav, .mp3, .ogg, .flac, .aac, etc."
    echo "Maximum length: ~60 seconds"
    exit 1
}

# Parse arguments
if [ $# -lt 1 ]; then
    usage
fi

INPUT_FILE="$1"
SERIAL_PORT="${2:-auto}"

# Check if input file exists
if [ ! -f "$INPUT_FILE" ]; then
    echo -e "${RED}ERROR: Input file not found: $INPUT_FILE${NC}"
    exit 1
fi

echo -e "${BLUE}=== Ultrasonic Sound Projector - Audio Converter ===${NC}"
echo ""
echo "SPIFFS Partition: $((SPIFFS_SIZE / 1024 / 1024))MB (max file: ~${MAX_DURATION_SEC}s)"
echo "Input file: $INPUT_FILE"

# Get input file duration
echo -e "${YELLOW}Checking audio duration...${NC}"
DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$INPUT_FILE" 2>/dev/null)
DURATION_INT=${DURATION%.*}

if (( DURATION_INT > MAX_DURATION_SEC )); then
    echo -e "${RED}ERROR: Audio is ${DURATION_INT}s long, maximum is ${MAX_DURATION_SEC}s${NC}"
    echo "Please trim your audio file before converting."
    exit 1
fi

echo -e "${GREEN}✓ Duration: ${DURATION_INT}s (within ${MAX_DURATION_SEC}s limit)${NC}"

# Create data directory if it doesn't exist
mkdir -p "$DATA_DIR"

# Convert audio
echo -e "${YELLOW}Converting to 8-bit raw PCM at 40kHz...${NC}"
ffmpeg -i "$INPUT_FILE" -f u8 -ar $SAMPLE_RATE -ac 1 "$OUTPUT_FILE" -y 2>&1 | grep -v "^Input\|^Output\|^Stream\|^Press\|Duration\|encoder\|^$" || true

# Check output file size
FILE_SIZE=$(stat -f%z "$OUTPUT_FILE" 2>/dev/null || stat -c%s "$OUTPUT_FILE" 2>/dev/null)
FILE_SIZE_KB=$((FILE_SIZE / 1024))
FILE_SIZE_MB=$(echo "scale=2; $FILE_SIZE / 1048576" | bc)

echo -e "${GREEN}✓ Conversion complete${NC}"
echo "  Output: $OUTPUT_FILE"
echo "  Size: ${FILE_SIZE_KB}KB (${FILE_SIZE_MB}MB)"

if [ $FILE_SIZE -gt $MAX_SIZE_BYTES ]; then
    echo -e "${RED}ERROR: File size (${FILE_SIZE_MB}MB) exceeds SPIFFS limit (2.4MB)${NC}"
    echo "Please use a shorter audio file."
    exit 1
fi

# Calculate actual duration from file size
ACTUAL_DURATION=$(echo "scale=1; $FILE_SIZE / $SAMPLE_RATE" | bc)
echo "  Duration: ${ACTUAL_DURATION}s @ 40kHz"
echo ""

# Upload to ESP32
echo -e "${BLUE}=== Upload to ESP32 ===${NC}"

# Find serial port if auto
if [ "$SERIAL_PORT" = "auto" ]; then
    echo -e "${YELLOW}Searching for ESP32...${NC}"
    # Look for common ESP32 serial ports
    if [ -e /dev/cu.usbserial-* ]; then
        SERIAL_PORT=$(ls /dev/cu.usbserial-* 2>/dev/null | head -n1)
    elif [ -e /dev/cu.SLAB_USBtoUART ]; then
        SERIAL_PORT="/dev/cu.SLAB_USBtoUART"
    elif [ -e /dev/cu.wchusbserial* ]; then
        SERIAL_PORT=$(ls /dev/cu.wchusbserial* 2>/dev/null | head -n1)
    fi

    if [ -z "$SERIAL_PORT" ] || [ ! -e "$SERIAL_PORT" ]; then
        echo -e "${YELLOW}No ESP32 found automatically.${NC}"
        echo "Please specify serial port manually, or use Arduino IDE:"
        echo "  Tools → ESP32 Sketch Data Upload"
        exit 0
    fi
fi

echo "Serial port: $SERIAL_PORT"
echo ""

# Check if esp32fs plugin is available
echo -e "${YELLOW}Attempting upload using arduino-cli...${NC}"

# Create a simple Python script to upload via SPIFFS
cat > /tmp/esp32_upload_spiffs.py << 'PYEOF'
#!/usr/bin/env python3
import sys
import os
import subprocess
import tempfile
import struct

def read_partition_table_from_device(serial_port):
    """Read partition table directly from ESP32 using esptool"""
    try:
        print("Reading partition table from ESP32...")

        # Partition table is typically at 0x8000 (default) or 0x9000
        partition_offsets = [0x8000, 0x9000]

        for pt_offset in partition_offsets:
            # Read partition table from device
            temp_bin = tempfile.mktemp(suffix='.bin')
            cmd = ['python3', '-m', 'esptool', '--port', serial_port,
                   'read_flash', hex(pt_offset), '0x1000', temp_bin]

            result = subprocess.run(cmd, capture_output=True, text=True)

            if result.returncode != 0:
                continue

            # Parse partition table binary format
            with open(temp_bin, 'rb') as f:
                data = f.read()

            os.remove(temp_bin)

            # Check magic bytes (0xAA50) at start
            if len(data) < 32:
                continue

            magic = struct.unpack('<H', data[0:2])[0]
            if magic != 0x50AA:
                continue

            print(f"Found partition table at {hex(pt_offset)}")

            # Parse partition entries (each 32 bytes)
            # Format: Each entry starts with magic(2) + type(1) + subtype(1) + offset(4) + size(4) + name(16) + flags(4)
            offset = 0
            while offset + 32 <= len(data):
                entry = data[offset:offset+32]

                # Check for end marker or invalid magic
                entry_magic = struct.unpack('<H', entry[0:2])[0]
                if entry_magic == 0xFFFF or entry_magic == 0xEBEB:
                    break

                if entry_magic != 0x50AA:
                    # Try next entry
                    offset += 32
                    continue

                # Parse entry (skip magic bytes at start)
                ptype = entry[2]
                subtype = entry[3]
                part_offset = struct.unpack('<I', entry[4:8])[0]
                part_size = struct.unpack('<I', entry[8:12])[0]
                name = entry[12:28].rstrip(b'\x00').decode('utf-8', errors='ignore')

                # Type 1 = data, Subtype 0x82 = SPIFFS
                if ptype == 0x01 and subtype == 0x82:
                    print(f"Found SPIFFS partition on device:")
                    print(f"  Name: {name}")
                    print(f"  Offset: {hex(part_offset)} ({part_offset} bytes)")
                    print(f"  Size: {hex(part_size)} ({part_size} bytes / {part_size/1024/1024:.1f}MB)")
                    return part_offset, part_size

                offset += 32

        print("ERROR: No SPIFFS partition found on device")
        return None, None

    except Exception as e:
        print(f"ERROR reading partition table from device: {e}")
        print("Will try reading from partitions.csv file instead...")
        return None, None

def parse_partition_csv(partition_file):
    """Parse partitions.csv as fallback"""
    try:
        with open(partition_file, 'r') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue

                parts = [p.strip() for p in line.split(',')]
                if len(parts) >= 5:
                    name, ptype, subtype, offset, size = parts[:5]

                    if subtype.lower() == 'spiffs':
                        offset_int = int(offset, 16) if offset.startswith('0x') else int(offset)
                        size_int = int(size, 16) if size.startswith('0x') else int(size)

                        print(f"Found SPIFFS partition in partitions.csv:")
                        print(f"  Offset: {hex(offset_int)} ({offset_int} bytes)")
                        print(f"  Size: {hex(size_int)} ({size_int} bytes / {size_int/1024/1024:.1f}MB)")
                        return offset_int, size_int

        return None, None
    except:
        return None, None

def upload_spiffs(data_dir, serial_port, board_fqbn, partition_file):
    """Upload SPIFFS data to ESP32"""

    try:
        # Try reading partition table from device first
        spiffs_offset, spiffs_size = read_partition_table_from_device(serial_port)

        # Fallback to partitions.csv if device read failed
        if spiffs_offset is None or spiffs_size is None:
            print("Falling back to partitions.csv...")
            spiffs_offset, spiffs_size = parse_partition_csv(partition_file)

        if spiffs_offset is None or spiffs_size is None:
            print("ERROR: Could not determine partition information")
            print("Please use Arduino IDE: Tools → ESP32 Sketch Data Upload")
            return False

        # Try to find mkspiffs
        mkspiffs_paths = [
            os.path.expanduser("~/.arduino15/packages/esp32/tools/mkspiffs/*/mkspiffs"),
            os.path.expanduser("~/Library/Arduino15/packages/esp32/tools/mkspiffs/*/mkspiffs"),
        ]

        mkspiffs = None
        for path_pattern in mkspiffs_paths:
            import glob
            matches = glob.glob(path_pattern)
            if matches:
                mkspiffs = matches[0]
                break

        if not mkspiffs:
            print("ERROR: mkspiffs tool not found")
            print("Please use Arduino IDE: Tools → ESP32 Sketch Data Upload")
            return False

        # Create SPIFFS image
        spiffs_image = tempfile.mktemp(suffix='.bin')

        print(f"Creating SPIFFS image with mkspiffs...")
        cmd = [mkspiffs, '-c', data_dir, '-p', '256', '-b', '4096', '-s', str(spiffs_size), spiffs_image]
        subprocess.run(cmd, check=True, capture_output=True)

        # Upload with esptool (with retry logic for port busy issues)
        print(f"Uploading to {serial_port} at offset {hex(spiffs_offset)}...")

        max_retries = 3
        for attempt in range(max_retries):
            try:
                esptool_cmd = ['python3', '-m', 'esptool', '--port', serial_port, '--baud', '921600',
                               'write_flash', hex(spiffs_offset), spiffs_image]
                subprocess.run(esptool_cmd, check=True)
                break  # Success!
            except subprocess.CalledProcessError as e:
                if attempt < max_retries - 1:
                    print(f"Port busy or unavailable, waiting 3 seconds (attempt {attempt + 1}/{max_retries})...")
                    import time
                    time.sleep(3)
                else:
                    raise  # Give up after max retries

        # Clean up
        os.remove(spiffs_image)
        print("✓ Upload complete!")
        return True

    except Exception as e:
        print(f"ERROR: {e}")
        return False

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: upload_spiffs.py <data_dir> <serial_port> <board_fqbn> <partition_file>")
        sys.exit(1)

    success = upload_spiffs(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
    sys.exit(0 if success else 1)
PYEOF

python3 /tmp/esp32_upload_spiffs.py "$DATA_DIR" "$SERIAL_PORT" "$BOARD_FQBN" "$PARTITION_FILE"
UPLOAD_STATUS=$?

rm -f /tmp/esp32_upload_spiffs.py

if [ $UPLOAD_STATUS -eq 0 ]; then
    echo ""
    echo -e "${GREEN}=== SUCCESS ===${NC}"
    echo -e "${GREEN}Audio file converted and uploaded successfully!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Connect GPIO18 to GND (trigger pin)"
    echo "  2. Watch serial monitor for playback confirmation"
    echo "  3. Audio will play through ultrasonic transducer"
else
    echo ""
    echo -e "${YELLOW}=== Manual Upload Required ===${NC}"
    echo "The audio file is ready in: $OUTPUT_FILE"
    echo ""
    echo "To upload manually:"
    echo "  1. Open Arduino IDE"
    echo "  2. Open soundprojector.ino"
    echo "  3. Tools → ESP32 Sketch Data Upload"
    echo "  4. Wait for upload to complete"
fi

echo ""
echo -e "${BLUE}Audio file details:${NC}"
echo "  Location: $OUTPUT_FILE"
echo "  Size: ${FILE_SIZE_KB}KB"
echo "  Duration: ${ACTUAL_DURATION}s"
echo "  Format: 8-bit unsigned raw PCM @ 40kHz mono"

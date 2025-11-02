#!/bin/bash
#
# Simple serial monitor for ESP32-S2
#

PORT="${1:-/dev/cu.usbmodem01}"
BAUD="${2:-115200}"

if [ ! -e "$PORT" ]; then
    echo "ERROR: Port $PORT not found"
    echo "Available ports:"
    ls -1 /dev/cu.* 2>/dev/null | grep -v Bluetooth | grep -v debug
    exit 1
fi

echo "=== Serial Monitor ==="
echo "Port: $PORT"
echo "Baud: $BAUD"
echo "Press Ctrl+C to exit"
echo "Press RESET on board to see boot messages"
echo "========================"
echo ""

# Use python for cross-platform serial monitoring
python3 - "$PORT" "$BAUD" << 'PYEOF'
import serial
import sys

port = sys.argv[1]
baud = int(sys.argv[2])

try:
    ser = serial.Serial(port, baud, timeout=0.1)
    print(f"Connected to {port}")
    print()

    while True:
        if ser.in_waiting:
            line = ser.readline().decode('utf-8', errors='ignore')
            print(line, end='')

except KeyboardInterrupt:
    print("\n\nDisconnected.")
except Exception as e:
    print(f"Error: {e}")
PYEOF

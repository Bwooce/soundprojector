# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Quick Reference
- **User documentation:** See [README.md](README.md) for quick start and wiring guide
- **Conversion script:** `./convert_upload.sh <audio_file>` - automated audio conversion and upload
- **Build command:** See "Build and Upload" section below

## Project Overview
This is an Arduino sketch for an ESP32-S2 Mini based ultrasonic sound projector. It uses PWM modulation at 40kHz carrier frequency to create a directional audio beam. Features dual-mode operation: live analog audio input OR triggered playback of stored audio files.

## Hardware Setup
- **Board:** Lolin (Wemos) S2 Mini - ESP32-S2FNR2
- **Board Profile:** `esp32:esp32:lolin_s2_mini`
- **Amplifier:** TPA3116 (connected to GPIO16 PWM output)
- **Transducer:** 60W 40kHz ultrasonic cleaning transducer

### ESP32-S2 USB Serial Notes
- ESP32-S2 uses native USB-OTG (not UART via USB-serial chip)
- **USB CDC (Communications Device Class)** must be enabled for Serial.print() to work
- Default for Lolin S2 Mini: CDC enabled on boot
- Serial port appears as `/dev/cu.usbmodem*` (macOS) or `/dev/ttyACM*` (Linux)
- Port disappears when device resets (normal behavior)

**Port Busy / Connection Issues:**
- ESP32-S2 port can be temperamental after operations
- If port shows as "busy": Wait 3-5 seconds and retry
- If port disappeared: Unplug/replug USB cable
- Close Arduino IDE, serial monitors, or other tools using the port
- On macOS: The port may briefly disappear after esptool operations (normal)

**Serial Debugging:**
- Baud rate: 115200
- Code includes `while(!Serial)` wait (up to 3 seconds) for serial connection
- Open serial monitor BEFORE or immediately after reset to see boot messages
- Use included tool: `./serial_monitor.sh`
- Or use: `screen /dev/cu.usbmodem01 115200` (Ctrl+A, K to exit)

## GPIO Configuration (ESP32-S2 Safe Pins)
- **Audio Input (optional):** GPIO5 (ADC) - live analog audio signal (0-3.3V) - only used if `ENABLE_LIVE_INPUT` is defined
- **PWM Output:** GPIO16 - outputs modulated 40kHz carrier to TPA3116 amplifier
- **Trigger Input:** GPIO18 - active LOW with internal pullup, triggers audio playback (debounced)
- **Status LED (optional):** NOT included by default (Lolin S2 Mini has no built-in LED)
  - Connect external LED to any safe GPIO (e.g., GPIO2, GPIO7, GPIO12) with current-limiting resistor
  - Enable by uncommenting `ENABLE_STATUS_LED` and setting `LED_PIN` in code

## Operating Modes (Compile-Time Option)

**Default Mode: Playback-only (ENABLE_LIVE_INPUT undefined)**
- Outputs silence (carrier off) when idle
- Trigger GPIO18 to GND → plays stored audio file
- After playback → returns to silence
- Clean, simple operation for triggered playback use case

**Optional Mode: Live Input + Playback (ENABLE_LIVE_INPUT defined)**
- Continuously reads analog audio from GPIO5 ADC
- Modulates carrier with live audio signal in real-time
- Trigger GPIO18 to GND → overrides with stored audio file
- After playback → returns to live ADC input
- Requires audio source connected to GPIO5 (0-3.3V max)

**To enable live input:** Uncomment `#define ENABLE_LIVE_INPUT` in soundprojector.ino line 22

## Status LED (Optional - External Only)

**Lolin S2 Mini has NO built-in LED** - but you can add an external one for status indication.

**To add external LED:**
1. Connect LED + current-limiting resistor (220Ω-1kΩ) to a safe GPIO pin
2. Recommended pins: GPIO2, GPIO7, GPIO12, GPIO13, GPIO14 (avoid strapping pins)
3. In soundprojector.ino (lines 24-31), uncomment:
   - `#define ENABLE_STATUS_LED`
   - `#define LED_PIN X` (replace X with your GPIO number)
   - `#define LED_BRIGHTNESS_READY 30`
   - `#define LED_BRIGHTNESS_PLAY 200`

**LED behavior when enabled:**
- **Dim (30/255):** Ready/idle state
- **Bright (200/255):** Playing audio
- Uses PWM for brightness control

**Circuit:**
```
GPIO Pin ---[ 330Ω Resistor ]---|>|--- GND
                                LED
```

## Build and Upload

**CRITICAL: Flash partition table first** (one-time setup):
```bash
# Step 1: Flash the custom partition table to ESP32
./flash_partitions.sh

# Step 2: Upload firmware (RECOMMENDED - uses helper script)
./upload_firmware.sh

# OR manually:
"/Applications/Arduino IDE.app/Contents/Resources/app/lib/backend/resources/arduino-cli" \
  compile --upload -b esp32:esp32:lolin_s2_mini \
  --board-options "CDCOnBoot=default" \
  soundprojector.ino
```

**Note:** `CDCOnBoot=default` enables USB CDC serial (already default for Lolin S2 Mini, but specified explicitly for clarity). This is required for `Serial.print()` to work on ESP32-S2.

**Why two steps?**
- Arduino-cli's `--board-options "PartitionScheme=custom"` option does NOT work reliably
- The Lolin S2 Mini board profile doesn't include a "Custom" partition scheme option
- Must manually flash partition table using `gen_esp32part.py` + `esptool`
- Only needs to be done once (partition table persists across firmware uploads)

## Partition Management

### Custom Partition Layout (partitions.csv)
```
nvs:     0x9000,  size 0x5000   (20KB)   - Non-volatile storage
otadata: 0xe000,  size 0x2000   (8KB)    - OTA data
app0:    0x10000, size 0x180000 (1.5MB)  - Firmware
spiffs:  0x190000,size 0x270000 (2.5MB)  - Audio files
```

### Partition Table Scripts

**Flash partition table (one-time setup):**
```bash
./flash_partitions.sh              # Auto-detect ESP32
./flash_partitions.sh /dev/cu.usbmodem01  # Specify port
```

**Verify partition table:**
```bash
./check_partitions.sh              # Compare file vs device
```

**How it works:**
1. `gen_esp32part.py` converts partitions.csv → binary format
2. `esptool` flashes binary to 0x8000 (partition table location)
3. ESP32 bootloader reads partition table on every boot
4. `convert_upload.sh` reads actual partition table from device for data uploads

**Smart upload:** The `convert_upload.sh` script reads the partition table directly from the ESP32 using esptool, ensuring it always uploads to the correct offset with the correct size, even if you modify `partitions.csv`.

## Audio File Format and Workflow

### Input Files
**Start with standard audio files** in any common format:
- `.wav` (recommended - uncompressed)
- `.mp3` (will be converted)
- `.ogg`, `.flac`, `.aac`, etc.

### File Length Limitations
- **Maximum duration: ~60 seconds**
- SPIFFS partition: 2.5MB available
- Sample rate: 40kHz × 8-bit × mono = 40KB/second
- Calculation: 2,500,000 bytes / 40,000 bytes/sec ≈ 60 seconds
- Leave overhead for filesystem: practical limit ~55-60 seconds

### Why Pre-Conversion is REQUIRED

**Files MUST be pre-converted** - the ESP32 cannot decode MP3/WAV/OGG in real-time. Here's why:

**Timing Constraint:**
- The `modulate()` interrupt fires every **25 microseconds** (40kHz rate)
- It must read one sample and update PWM - this takes < 25μs
- MP3/OGG decoding takes milliseconds per frame - **1000x too slow**
- Even WAV files have headers, wrong bit depth (16-bit), wrong sample rate (44.1/48kHz)

**Why Raw 8-bit PCM:**
1. **Speed:** Reading one byte from flash takes ~1-2μs (fits in 25μs window)
2. **Sample Rate:** Must be exactly 40kHz to match carrier frequency
3. **Bit Depth:** Must be 8-bit to match PWM resolution (0-255)
4. **No Overhead:** No headers, no decoding, no resampling needed
5. **Deterministic:** Same timing every cycle - critical for clean AM modulation

**In short:** Real-time decoding would miss timing deadlines and create audio glitches. Pre-conversion ensures one simple byte-read per interrupt cycle.

### Conversion Workflow

**RECOMMENDED: Use the automated script**
```bash
# Automatic conversion + upload (detects ESP32 automatically)
./convert_upload.sh alarm.mp3

# Specify serial port manually
./convert_upload.sh doorbell.wav /dev/cu.usbserial-0001

# Supports any format: .mp3, .wav, .ogg, .flac, .aac, etc.
```

The script automatically:
- ✓ Reads partition table **directly from ESP32** using esptool (no hardcoded values!)
- ✓ Converts to required format (8-bit raw PCM @ 40kHz)
- ✓ Validates file size (must fit in SPIFFS partition)
- ✓ Checks duration (calculated from partition size)
- ✓ Copies to data/ folder
- ✓ Uploads to ESP32 SPIFFS at correct offset (if tools available)
- ✓ Falls back to `partitions.csv` if device can't be read
- ✓ Provides clear error messages and instructions

**Intelligent design:** The script reads the partition table directly from the connected ESP32 device, so it always uses the actual partition layout - no sync issues between files and device. Falls back to `partitions.csv` if device reading fails.

**MANUAL: Convert and upload yourself**
```bash
# Step 1: Convert any audio file to the required raw format
ffmpeg -i yoursound.wav -f u8 -ar 40000 -ac 1 data/audio.raw

# Examples:
ffmpeg -i alarm.mp3 -f u8 -ar 40000 -ac 1 data/audio.raw
ffmpeg -i voice.ogg -f u8 -ar 40000 -ac 1 data/audio.raw

# Step 2: Upload to ESP32 SPIFFS
# Arduino IDE: Tools → ESP32 Sketch Data Upload
```

**ffmpeg parameters explained:**
- `-f u8` = 8-bit unsigned format (0-255 values) - matches PWM range
- `-ar 40000` = 40kHz sample rate - matches modulation frequency exactly
- `-ac 1` = Mono (single channel) - stereo not needed for parametric array
- No header/metadata = Raw PCM data only - one byte per sample

### Output Format
The raw file contains pure 8-bit unsigned PCM samples:
- Each byte represents one audio sample (0-255)
- No header, no compression, no metadata
- Direct sample values used for PWM duty cycle modulation

## Key Dependencies
- **Ticker library:** Timer-based modulation (built-in to ESP32 core)
- **SPIFFS:** File system for audio storage (built-in to ESP32 core)

## How It Works: Amplitude Modulation for Parametric Audio

This system creates **directional audio** using amplitude modulation of an ultrasonic carrier:

1. **40kHz PWM Carrier:** ESP32 generates a 40kHz PWM signal (ultrasonic frequency, above human hearing)
2. **Audio Modulation:** Audio signal (8-bit, 0-255) modulates the PWM duty cycle in real-time
3. **Amplitude Modulation (AM):** The audio becomes the modulation envelope of the 40kHz carrier
4. **Amplification:** TPA3116 amplifies the AM-modulated ultrasonic signal to drive the transducer
5. **Ultrasonic Beam:** 60W 40kHz transducer creates a highly directional ultrasonic beam
6. **Nonlinear Demodulation:** Air's nonlinear properties demodulate the audio from the carrier
7. **Result:** Audible sound that propagates in a narrow beam like a spotlight

**Key Principle:** Standard audio (20Hz-20kHz) is converted to AM modulation of a 40kHz ultrasonic carrier, creating a parametric array effect.

## Architecture Notes
- **Dual-mode operation:**
  - Normal mode: Reads analog audio from GPIO5 ADC continuously
  - Playback mode: Triggered by GPIO18 going LOW, plays stored audio.raw from SPIFFS
- **Interrupt-driven:** All audio processing in `modulate()` function called by Ticker at 40kHz (25μs intervals)
- **Debouncing:** 50ms debounce on trigger input prevents false triggers
- **Auto-return:** After playback completes, automatically returns to ADC input mode
- **Signal chain:** Audio (8-bit) → PWM duty cycle → 40kHz carrier → TPA3116 → Ultrasonic transducer
- **Watchdog Timer:** Uses ESP32 FreeRTOS `vTaskDelay()` in main loop to properly feed watchdog timer
  - NEVER use standard `delay()` in production ESP32 code - always use `vTaskDelay(pdMS_TO_TICKS(ms))`
  - Prevents watchdog timer resets during long operations
  - Do NOT call delay/yield/vTaskDelay in interrupt handlers (like `modulate()`)

## Interrupt Management and Timing Critical Operations

### WiFi Disabled
**WiFi is explicitly disabled** in setup() to prevent interrupt conflicts:
- WiFi interrupts can interfere with the 40kHz Ticker timing
- Disabled via `WiFi.mode(WIFI_OFF)`
- This ensures deterministic 25μs timing for the `modulate()` interrupt
- **Note:** ESP32-S2 has no Bluetooth hardware (unlike ESP32 classic)

### Interrupt Priority
- **Ticker interrupt (40kHz):** Highest priority - cannot be delayed
- **Main loop:** Low priority - handles debouncing and file operations
- **No other interrupts enabled:** Clean interrupt environment for timing-critical AM modulation

## Critical ESP32 Coding Requirements
- **Always use `vTaskDelay(pdMS_TO_TICKS(ms))` instead of `delay(ms)` to feed watchdog**
- Interrupt handlers must be IRAM_ATTR and non-blocking (no delays, no Serial, minimal operations)
- The `modulate()` function runs at 40kHz - keep it extremely fast (just read/write operations)
- **WiFi must remain disabled** - enabling it will cause timing jitter and audio artifacts
- Serial output in interrupt context (like in `modulate()`) can cause crashes - avoid it
- ESP32-S2 has no Bluetooth hardware (only WiFi)

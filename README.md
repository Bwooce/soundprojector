# Ultrasonic Sound Projector

An ESP32-S2 based **parametric audio array** that creates highly directional audio beams using ultrasonic transducers. Point sound like a flashlight beam!

## What is a Parametric Array?

This project uses **amplitude modulation** of a 40kHz ultrasonic carrier to create audible sound that propagates in a narrow, directional beam. The ultrasonic waves interact nonlinearly in the air itself, demodulating the audio signal and creating a "sound spotlight" effect.

**Note:** The term "parametric array" refers to the **acoustic phenomenon** described by the Westervelt parametric array equations, not the number of transducers. A single high-intensity ultrasonic transducer is sufficient to create the effect - the "array" is the parametric interaction of sound waves in air, not a physical array of speakers.

**How it works:**
1. Audio signal modulates a 40kHz PWM carrier
2. TPA3116 amplifier drives a 60W ultrasonic transducer
3. Ultrasonic beam propagates in a tight cone (~10-20°)
4. Air's nonlinear properties demodulate the audio **in mid-air**
5. Result: Directional audible sound from the ultrasonic beam

**Applications:** Museums, installations, targeted advertising, privacy-focused audio, immersive experiences

## Features

- 🎯 **Highly directional audio** - sound goes where you point it
- 🔊 **Triggered playback** - store audio files, play on button press
- 🎤 **Optional live input** - real-time modulation from analog audio source
- 📦 **2.5MB SPIFFS storage** - up to ~60 seconds of audio
- ⚡ **40kHz interrupt-driven modulation** - precise timing
- 🧪 **Built-in test modes** - DC voltage and 1kHz sine wave tests
- 📊 **Serial monitoring** - verbose debug output via USB CDC
- 🔧 **Easy audio conversion** - automated script handles any audio format

## Hardware Requirements

| Component | Specification | Notes |
|-----------|--------------|-------|
| **Microcontroller** | Lolin (Wemos) S2 Mini | ESP32-S2FNR2 |
| **Amplifier** | TPA3116 Class-D | 60W, 12-24V power supply |
| **Transducer** | 60W 40kHz ultrasonic | Cleaning transducer works well |
| **Power Supply** | 12-24V DC | Higher voltage = more power |
| **Trigger Button** | Momentary switch | Optional - connect GPIO18 to GND |
| **Status LED** | Any LED + resistor | Optional external LED |

**Board Profile:** `esp32:esp32:lolin_s2_mini`

## Hookup Diagram

```
                    ┌─────────────────────┐
    USB Power ──────┤ ESP32-S2 Mini       │
                    │  (Lolin S2 Mini)    │
                    │                     │
                    │ GPIO16 ──────────┐  │
                    │ GPIO18 ─────┐    │  │
                    │ GND ────┐   │    │  │
                    │         │   │    │  │
                    └─────────┼───┼────┼──┘
                              │   │    │
                              │   │    │  PWM Signal (3.3V, 40kHz)
                   Common GND │   │    └──────────────┐
                              │   │                   │
                    ┌─────────┘   │              ┌────▼─────────────┐
                    │             │              │   TPA3116        │
    ┌───────────┐   │             │              │   Amplifier      │
    │  Trigger  │   │             │              │                  │
    │  Button   ├───┴─────────────┘   Input ────┤                  │
    │           │                                │                  │
    └───────────┘                                │  OUT+ ──┐        │
                                                 │         │        │
                         12-24V DC Power ────────┤  OUT- ──┼───┐    │
                         (Higher V = More Power) │         │   │    │
                                                 └─────────┼───┼────┘
                                                           │   │
                                                      ┌────▼───▼────┐
                                                      │  Ultrasonic │
                                                      │  Transducer │
                                                      │   (60W)     │
                                                      │   40kHz     │
                                                      └─────────────┘

Optional connections (if enabled in code):
  - GPIO5: Analog audio input (0-3.3V max) for ENABLE_LIVE_INPUT mode
  - Any GPIO: External LED + resistor (330Ω) for ENABLE_STATUS_LED

IMPORTANT:
  - Connect all grounds together (ESP32, TPA3116, power supply)
  - TPA3116 needs separate 12-24V power (NOT from ESP32)
  - ESP32-S2 Mini powered via USB (5V)
```

**Pin Summary:**

| Component | ESP32-S2 Pin | Notes |
|-----------|--------------|-------|
| PWM to TPA3116 input | GPIO16 | 40kHz carrier output |
| Trigger button | GPIO18 | Active LOW (connect to GND) |
| Analog audio (optional) | GPIO5 | Only if ENABLE_LIVE_INPUT defined |
| Status LED (optional) | Any safe GPIO | Requires external LED + resistor |
| Common ground | GND | **Must connect all grounds together** |

## Quick Start

### 1. Flash Partition Table (one-time setup)

```bash
# Connect ESP32-S2 via USB
./flash_partitions.sh

# This creates a 2.5MB SPIFFS partition for audio storage
```

### 2. Upload Firmware

```bash
# Recommended: Use helper script
./upload_firmware.sh

# OR manually with arduino-cli:
arduino-cli compile --upload -b esp32:esp32:lolin_s2_mini \
  --board-options "CDCOnBoot=default" soundprojector.ino
```

**Note:** USB CDC must be enabled for serial output. Lolin S2 Mini has this enabled by default.

### 3. Prepare and Upload Audio

```bash
# Automatic conversion and upload (recommended)
./convert_upload.sh your_audio.mp3

# Supports: .mp3, .wav, .ogg, .flac, .aac, and more
# Maximum length: ~60 seconds
# Automatically converts to 8-bit raw PCM @ 40kHz
```

**Manual conversion (if needed):**
```bash
ffmpeg -i input.mp3 -f u8 -ar 40000 -ac 1 data/audio.raw
# Then upload via Arduino IDE: Tools → ESP32 Sketch Data Upload
```

### 4. Use It!

- Connect GPIO18 to GND (or press button) → plays stored audio file
- Optional: `./serial_monitor.sh` to see debug output (press RESET to see boot messages)

## Test Modes

Built-in test modes for debugging (edit `soundprojector.ino` to enable):

**TEST_MODE_DC** - Voltage verification:
- Constant 50% duty cycle on GPIO16
- Measure ~1.65V DC with multimeter
- Verifies PWM hardware is working

**TEST_MODE_SINE** - Audio verification:
- Generates 1kHz sine wave modulating 40kHz carrier
- **You'll hear a 1kHz tone** from the parametric array
- Verifies entire signal chain including acoustic output
- Use oscilloscope to see 40kHz carrier with 1kHz envelope

**Note:** File playback has priority - triggering GPIO18 will play the stored audio file even when test modes are enabled, then return to test mode after playback finishes.

## Configuration Options

Edit compile-time options at the top of `soundprojector.ino`:

**Live Input Mode** (optional):
```cpp
#define ENABLE_LIVE_INPUT  // Uncomment to enable
```
Continuously modulate from GPIO5 analog input instead of silence when idle.

**Status LED** (optional):
```cpp
#define ENABLE_STATUS_LED
#define LED_PIN 15  // Your GPIO pin
```
External LED shows ready (dim) / playing (bright) status.

## Audio Format

Files must be **8-bit raw PCM @ 40kHz** (no header, mono). The interrupt fires every 25μs, leaving no time for decoding MP3/WAV in real-time.

**Required format:**
- 8-bit unsigned (0-255 values)
- 40kHz sample rate (matches carrier frequency)
- Mono (single channel)
- Raw PCM (no header, no compression)
- Max duration: ~60 seconds (2.5MB SPIFFS ÷ 40KB/sec)

**Why pre-conversion is required:**
The `modulate()` interrupt fires every 25 microseconds. MP3/OGG decoding takes milliseconds per frame (1000× too slow), which would cause timing glitches and distorted audio. Files must be pre-converted to simple raw PCM for fast, interrupt-safe reading.

**Automatic conversion (recommended):**
```bash
./convert_upload.sh your_audio.mp3
```

**Manual conversion:**
```bash
# Convert any audio file to required format
ffmpeg -i input.mp3 -f u8 -ar 40000 -ac 1 data/audio.raw

# Then upload via Arduino IDE: Tools → ESP32 Sketch Data Upload
```

The `data/` folder is where your `audio.raw` file lives. The script automatically places converted files there and uploads to the ESP32's SPIFFS filesystem as `/audio.raw`.

## Project Structure

```
soundprojector/
├── soundprojector.ino      # Main firmware
├── partitions.csv          # Custom partition table (2.5MB SPIFFS)
├── LICENSE                 # MIT License
├── README.md              # This file
├── CLAUDE.md              # Detailed technical documentation
├── flash_partitions.sh     # Flash partition table to device
├── upload_firmware.sh      # Compile and upload firmware
├── convert_upload.sh       # Convert audio and upload to SPIFFS
├── serial_monitor.sh       # Serial debugging tool
└── data/
    └── audio.raw          # Your audio file (after conversion, gitignored)
```

## Technical Details

**Signal Chain:**
```
Audio (8-bit) → PWM Duty Cycle → 40kHz Carrier → TPA3116 Amplifier → Ultrasonic Transducer → Directional Beam
```

**Key specifications:**
- Carrier frequency: 40kHz (ultrasonic, above human hearing)
- PWM resolution: 8-bit (0-255)
- Sample rate: 40kHz (matches carrier frequency)
- Interrupt timing: 25μs per sample (critical for clean modulation)
- Modulation type: Amplitude Modulation (AM)

**ESP32-S2 Notes:**
- Uses native USB-OTG for serial (not UART via USB-serial chip)
- No Bluetooth hardware (WiFi-only chip)
- Must use `ledcAttach()` API for LEDC PWM (ESP32-S2/S3 specific)
- Requires FreeRTOS `vTaskDelay()` for watchdog feeding

**Physics:**
- Westervelt parametric array effect
- Nonlinear self-demodulation in air at high SPL
- Directional audible sound from ultrasonic parent waves
- Sound appears to originate from the beam target

For complete technical documentation, see [CLAUDE.md](CLAUDE.md).

## Troubleshooting

**No audio output:**
- Enable `TEST_MODE_SINE` to verify the entire chain with a 1kHz test tone
- Check TPA3116 power supply is connected and enabled (12-24V)
- Verify GPIO16 PWM with oscilloscope (40kHz carrier with modulation envelope)
- Ensure transducer resonates at 40kHz

**No voltage on GPIO16:**
- Try `TEST_MODE_DC` and measure with multimeter (should read ~1.65V)
- ESP32-S2 requires `ledcAttach()` API, not the older `ledcSetup()` functions
- Check serial output for "PWM configured" confirmation message

**Port busy during upload:**
- ESP32-S2 USB port can be temperamental - wait 3-5 seconds and retry
- Port appears as `/dev/cu.usbmodem*` on macOS, `/dev/ttyACM*` on Linux

## Safety Notes

- **Ultrasonic exposure:** 40kHz is above human hearing but can affect pets
- **High power:** 60W transducer gets hot - ensure proper cooling
- **Voltage:** TPA3116 requires 12-24V - observe proper electrical safety
- **Oscilloscope:** Safe to connect in parallel with transducer, but keep transducer connected (amplifier needs load)

## Contributing

Contributions welcome! This project demonstrates:
- ESP32-S2 LEDC PWM configuration
- High-frequency interrupt-driven signal generation
- Custom partition tables for SPIFFS
- Parametric array / directional audio physics
- Audio signal processing on embedded systems

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Resources

- [ESP32-S2 Datasheet](https://www.espressif.com/sites/default/files/documentation/esp32-s2_datasheet_en.pdf)
- [TPA3116 Datasheet](https://www.ti.com/lit/ds/symlink/tpa3116d2.pdf)
- [Parametric Array Wikipedia](https://en.wikipedia.org/wiki/Parametric_array)
- [Lolin S2 Mini Documentation](https://www.wemos.cc/en/latest/s2/s2_mini.html)

## Acknowledgments

Based on the principles of parametric loudspeakers and the Westervelt equation describing nonlinear acoustic wave propagation.

/*
 * Ultrasonic Sound Projector - Amplitude Modulation System
 *
 * This sketch implements a parametric audio array using amplitude modulation:
 * 1. A 40kHz PWM carrier signal is generated (ultrasonic frequency)
 * 2. Audio signal (from ADC or file) modulates the PWM duty cycle
 * 3. This creates AM (amplitude modulation) of the ultrasonic carrier
 * 4. The modulated 40kHz signal drives a TPA3116 amplifier
 * 5. The amplifier drives a 60W 40kHz ultrasonic transducer
 * 6. The transducer creates a directional ultrasonic beam
 * 7. Air acts as a nonlinear medium, demodulating the audio from the ultrasonic carrier
 *
 * Result: Directional audio beam that can be aimed like a spotlight
 *
 * IMPORTANT: Uses ESP32 FreeRTOS delay functions (vTaskDelay) to feed watchdog timer
 */

// ============================================================
// COMPILE-TIME OPTIONS - Configure your build here
// ============================================================

// Uncomment to enable live analog audio input on GPIO5
// If disabled: outputs silence when not playing files (playback-only mode)
// If enabled: reads GPIO5 ADC for live audio input when not playing files
// #define ENABLE_LIVE_INPUT

// LED status indication (OPTIONAL - Lolin S2 Mini has NO built-in LED)
// To use: Connect external LED + resistor to any safe GPIO pin
// Uncomment all 4 lines below and set LED_PIN to your GPIO number
// #define ENABLE_STATUS_LED
// #define LED_PIN 15              // GPIO pin for external LED
// #define LED_BRIGHTNESS_READY 30 // Low brightness when ready (0-255)
// #define LED_BRIGHTNESS_PLAY 200 // Higher brightness when playing (0-255)

// Testing mode - choose ONE test type:
// Option 1: DC test - constant 50% duty for voltage measurement with multimeter
// Option 2: Sine wave test - 1kHz tone for audio output verification
// Uncomment ONE of the following:
// #define TEST_MODE_DC
#define TEST_MODE_SINE  // 1kHz sine wave AM modulation

// Helper macro to check if any test mode is active
#if defined(TEST_MODE_DC) || defined(TEST_MODE_SINE)
  #define TEST_MODE
#endif

// ============================================================
// PIN CONFIGURATION - Hardware connections
// ============================================================

#define PWM_PIN 16           // GPIO16 -> TPA3116 amplifier input
#define TRIGGER_PIN 18       // GPIO18 -> Trigger input (active LOW with pullup)

#ifdef ENABLE_LIVE_INPUT
  #define AUDIO_PIN 5        // GPIO5 -> Analog audio input (0-3.3V max)
#endif

// PWM Configuration
#define PWM_CHANNEL 0        // LEDC channel for audio PWM
#define PWM_FREQ 40000       // 40kHz carrier frequency (actual: ~39kHz due to clock constraints)
#define PWM_RES 8            // 8-bit resolution (0-255)
// Note: ESP32-S2 LEDC cannot generate exactly 40kHz at 8-bit resolution
// Actual frequency will be ~39.06kHz or ~35.16kHz depending on clock divider
// Use 6-bit (PWM_RES 6) for closer to 40kHz (40.32kHz), but reduces audio quality
// 8-bit is recommended for better audio despite frequency error

#ifdef ENABLE_STATUS_LED
  #define LED_CHANNEL 1      // LEDC channel for status LED (separate from audio)
  #define LED_FREQ 5000      // 5kHz PWM for LED (prevents visible flicker)
  #define LED_RES 8          // 8-bit resolution for brightness
#endif

// ============================================================
// LIBRARIES
// ============================================================

#include <Ticker.h>    // For timed modulation (install via Library Manager)
#include <SPIFFS.h>    // For file storage
#include <FS.h>        // File system
#include <WiFi.h>      // To disable WiFi
// Note: ESP32-S2 has no Bluetooth hardware, so no esp_bt.h needed

// ============================================================
// CONSTANTS AND GLOBALS
// ============================================================

// Debounce settings
const unsigned long debounceDelay = 50;  // 50ms debounce
unsigned long lastTriggerTime = 0;
bool lastTriggerState = LOW;
bool triggerState = LOW;

// Playback state
bool isPlaying = false;
File audioFile;
const char* audioFilePath = "/audio.raw";  // 8-bit raw PCM - MUST be pre-converted (see CLAUDE.md)
                                            // Cannot decode MP3/WAV in real-time - too slow for 25μs interrupt timing

Ticker modulator;  // Timer for modulation

#ifdef TEST_MODE_SINE
// Sine wave generation for test mode
const int sineTableSize = 100;  // Samples per cycle (40kHz / 100 = 400Hz sample rate)
unsigned int sinePhase = 0;     // Current phase in sine wave
const float testFreq = 1000.0;  // 1kHz test tone
const float phaseIncrement = (testFreq * sineTableSize) / 40000.0;  // Phase step per sample
#endif

// ============================================================
// SETUP AND MAIN LOOP
// ============================================================

void setup() {
  Serial.begin(115200);

  // ESP32-S2 USB CDC: Wait for serial connection or timeout
  // This ensures serial output is visible when serial monitor opens
  unsigned long start = millis();
  while (!Serial && (millis() - start) < 3000) {
    delay(10);  // Wait up to 3 seconds for serial monitor
  }

  Serial.println("\n\n=== Ultrasonic Sound Projector ===");
  Serial.println("Board: Lolin S2 Mini (ESP32-S2)");

  // Disable WiFi to prevent interrupt conflicts
  // Note: ESP32-S2 has no Bluetooth hardware
  WiFi.mode(WIFI_OFF);
  Serial.println("WiFi disabled");

  // Initialize SPIFFS
  if (!SPIFFS.begin(true)) {
    Serial.println("SPIFFS initialization failed!");
    return;
  }
  Serial.println("SPIFFS initialized");

  // Check if audio file exists
  if (SPIFFS.exists(audioFilePath)) {
    Serial.printf("Audio file found: %s\n", audioFilePath);
    File f = SPIFFS.open(audioFilePath, "r");
    Serial.printf("File size: %d bytes\n", f.size());
    f.close();
  } else {
    Serial.printf("Audio file not found: %s\n", audioFilePath);
    Serial.println("Upload audio.raw to SPIFFS using data upload tool");
  }

  // Setup pins
  pinMode(TRIGGER_PIN, INPUT_PULLUP);  // Active LOW with pullup
  pinMode(PWM_PIN, OUTPUT);             // Set PWM pin as output
  Serial.println("GPIO pins configured");

  // Setup LEDC PWM for audio (ESP32-S2/S3 API)
  // NOTE: Must use ledcAttach(pin, freq, res) for ESP32-S2/S3
  // The older ledcAttachChannel() and ledcSetup()/ledcAttachPin() APIs don't work
  // ESP32-S2/S3 simplified the API: attach directly to pin, write directly to pin
  uint32_t actual_freq = ledcAttach(PWM_PIN, PWM_FREQ, PWM_RES);  // Returns actual frequency
  Serial.printf("PWM configured: GPIO%d, requested %dkHz, actual %.2fkHz, %d-bit resolution\n",
                PWM_PIN, PWM_FREQ/1000, actual_freq/1000.0, PWM_RES);

  if (abs((int)actual_freq - (int)PWM_FREQ) > 1000) {
    Serial.printf("  WARNING: Actual frequency differs by %.1f%% due to clock divider constraints\n",
                  abs((float)actual_freq - PWM_FREQ) / PWM_FREQ * 100);
    Serial.println("  This is normal for ESP32 LEDC. Transducer should still work.");
  }

  // Verify PWM is working by setting initial test value
  #ifdef TEST_MODE_DC
  ledcWrite(PWM_PIN, 127);  // ESP32-S2/S3: write directly to pin, not channel
  Serial.printf("TEST MODE DC: Set GPIO%d to value 127 (50%% duty)\n", PWM_PIN);
  delay(100);  // Give it a moment to settle
  #endif

  #ifdef TEST_MODE_SINE
  Serial.println("TEST MODE SINE: 1kHz tone will start after modulation timer begins");
  #endif

  #ifdef ENABLE_STATUS_LED
  // Setup status LED with PWM for brightness control
  pinMode(LED_PIN, OUTPUT);
  ledcAttach(LED_PIN, LED_FREQ, LED_RES);
  ledcWrite(LED_PIN, LED_BRIGHTNESS_READY);  // Set to dim "ready" state
  Serial.printf("Status LED: GPIO%d (dim=ready, bright=playing)\n", LED_PIN);
  #endif

  // Start modulation every 25us (1/40kHz)
  modulator.attach_ms(0.025, modulate);
  Serial.println("40kHz modulation timer started");

  // Print GPIO pin assignments
  Serial.println("\n=== GPIO Pin Configuration ===");
  Serial.printf("  PWM Output:    GPIO%d -> TPA3116 amplifier (40kHz carrier)\n", PWM_PIN);
  Serial.printf("  Trigger Input: GPIO%d -> Active LOW with internal pullup\n", TRIGGER_PIN);
  #ifdef ENABLE_LIVE_INPUT
    Serial.printf("  ADC Input:     GPIO%d -> Live audio input (0-3.3V)\n", AUDIO_PIN);
  #endif
  #ifdef ENABLE_STATUS_LED
    Serial.printf("  Status LED:    GPIO%d -> PWM brightness control\n", LED_PIN);
  #endif

  Serial.println("\n=== Operating Mode ===");
  #ifdef TEST_MODE_DC
    Serial.println("  *** TEST MODE: DC OUTPUT ***");
    Serial.printf("  Continuous 50%% duty cycle on GPIO%d\n", PWM_PIN);
    Serial.println("  Expected DC voltage: ~1.65V (measure with multimeter)");
    Serial.println("  NOTE: Triggering file playback will override test mode");
  #elif defined(TEST_MODE_SINE)
    Serial.println("  *** TEST MODE: SINE WAVE ***");
    Serial.printf("  1kHz sine wave modulating 40kHz carrier on GPIO%d\n", PWM_PIN);
    Serial.println("  You should hear a 1kHz tone from the ultrasonic beam");
    Serial.println("  Use oscilloscope to see 40kHz carrier with 1kHz AM envelope");
    Serial.println("  NOTE: Triggering file playback will override test mode");
  #elif defined(ENABLE_LIVE_INPUT)
    Serial.println("  - Live ADC input (GPIO5) -> Continuous audio modulation");
    Serial.println("  - Trigger (GPIO18 to GND) -> Override with stored audio playback");
  #else
    Serial.println("  - Playback-only (silence when idle)");
    Serial.println("  - Trigger (GPIO18 to GND) -> Play stored audio file");
  #endif

  Serial.println("\n=== READY ===\n");
}

void loop() {
  checkTrigger();
  vTaskDelay(pdMS_TO_TICKS(10));  // ESP32 delay that feeds watchdog
}

// ============================================================
// INTERRUPT HANDLERS
// ============================================================

void modulate() {
  int audio = 0;

  // File playback ALWAYS has priority (even over test modes)
  if (isPlaying && audioFile) {
    // Read next sample from file
    if (audioFile.available()) {
      audio = audioFile.read();  // Already 8-bit (0-255)
    } else {
      // End of file - close and stop playback
      audioFile.close();
      isPlaying = false;
      #ifdef ENABLE_STATUS_LED
      ledcWrite(LED_PIN, LED_BRIGHTNESS_READY);  // Return to dim "ready" state
      #endif
      Serial.println("\n*** Playback finished - ready for next trigger ***");
      audio = 0;  // Silence after playback
    }
  } else {
    // Not playing file - use test mode or normal mode
    #ifdef TEST_MODE_DC
      // Test mode: Output constant 50% duty cycle (1.65V DC)
      audio = 127;  // 50% of 255 = ~1.65V
    #elif defined(TEST_MODE_SINE)
      // Test mode: Generate 1kHz sine wave for AM modulation
      // Use simple sine approximation: value = 127 + 127 * sin(phase)
      float angle = (sinePhase * 2.0 * PI) / sineTableSize;
      audio = 127 + (int)(127.0 * sin(angle));  // 0-255 range

      // Increment phase for next sample
      sinePhase += (int)phaseIncrement;
      if (sinePhase >= sineTableSize) {
        sinePhase -= sineTableSize;
      }
    #elif defined(ENABLE_LIVE_INPUT)
      // Read from ADC (live audio input)
      audio = analogRead(AUDIO_PIN) / 4;  // Scale 0-4095 to 0-255 (ESP ADC is 12-bit)
    #else
      // Silence (playback-only mode)
      audio = 0;
    #endif
  }

  ledcWrite(PWM_PIN, audio);  // ESP32-S2/S3: write directly to pin
}

// ============================================================
// HELPER FUNCTIONS
// ============================================================

void checkTrigger() {
  // Read trigger pin (active LOW)
  bool reading = !digitalRead(TRIGGER_PIN);  // Invert for active LOW

  // Debounce
  if (reading != lastTriggerState) {
    lastTriggerTime = millis();
  }

  if ((millis() - lastTriggerTime) > debounceDelay) {
    if (reading != triggerState) {
      triggerState = reading;

      // Trigger on rising edge
      if (triggerState == HIGH && !isPlaying) {
        startPlayback();
      }
    }
  }

  lastTriggerState = reading;
}

void startPlayback() {
  if (SPIFFS.exists(audioFilePath)) {
    audioFile = SPIFFS.open(audioFilePath, "r");
    if (audioFile) {
      isPlaying = true;
      #ifdef ENABLE_STATUS_LED
      ledcWrite(LED_PIN, LED_BRIGHTNESS_PLAY);  // Set to bright "playing" state
      #endif

      // Calculate and display playback duration
      size_t fileSize = audioFile.size();
      float durationSeconds = (float)fileSize / 40000.0;  // 40kHz sample rate

      // Format file size in human-readable form
      if (fileSize >= 1048576) {  // >= 1MB
        Serial.printf("Starting playback: %.2f MB, %.1f seconds\n", fileSize / 1048576.0, durationSeconds);
      } else if (fileSize >= 1024) {  // >= 1KB
        Serial.printf("Starting playback: %.1f KB, %.1f seconds\n", fileSize / 1024.0, durationSeconds);
      } else {
        Serial.printf("Starting playback: %d bytes, %.1f seconds\n", fileSize, durationSeconds);
      }
    } else {
      Serial.println("Failed to open audio file");
    }
  } else {
    Serial.println("Audio file not found");
  }
}

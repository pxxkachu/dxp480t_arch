# LED Control: UGREEN DXP480T Plus on Arch Linux

Fix the annoying flashing power LED when running Arch on the DXP480T Plus.

On stock UGOS, the front panel LED indicates power, network, and disk activity. Third-party OS installs do not ship a driver for the LED MCU, so the power LED typically flashes continuously. The DXP480T has **only a single dual-color (red/white) power LED** — there are no per-bay disk LEDs.

The standard [ugreen_leds_controller](https://github.com/miskcoo/ugreen_leds_controller) project supports many UGREEN NAS models but **does not yet support the DXP480T Plus**. Use direct I2C commands instead.

Primary reference: [GitHub issue #6](https://github.com/miskcoo/ugreen_leds_controller/issues/6) (community reverse-engineering of the LED protocol).

---

## How it works

The LED is controlled by an N76E003 MCU on the SMBus (Intel I801 adapter). Linux talks to it through the `i2c-dev` kernel module and the `i2c-tools` userspace package.

| Parameter | Value |
|-----------|-------|
| I2C bus | SMBus I801 adapter (`i2c-0` on most boots; can change — detect dynamically) |
| Chip address | `0x26` |
| Identification | Reading register `0x5a` returns `0xa5`, `0x5b` returns `0xb5` |

Relevant control registers (8-bit byte mode — always use the `b` suffix with `i2cset`):

| Register | Purpose |
|----------|---------|
| `0x50` | Effect: solid on (`0`), fast flash (`1`), breathing (`2`) |
| `0x51` | Effect: slow flash on (`1`), off (`0`) |
| `0xb1` | Color on: red (`1` or `5`), white (`2` or `6`) |
| `0xa0` | Color off: red (`1` or `5`), white (`2` or `6`) |

---

## 1. Install packages

```bash
sudo pacman -S i2c-tools
```

Load the I2C device interface at boot:

```bash
echo i2c-dev | sudo tee /etc/modules-load.d/i2c-dev.conf
sudo modprobe i2c-dev
```

Do not use `ugreen_leds_controller` on the DXP480T:

The AUR packages `ugreen-leds-controller-dkms-git` and `ugreen-leds-controller-utils-git` target HDD-bay NAS models (DXP4800, DX4600 Pro, etc.). They will not detect or control the DXP480T power LED. The DXP480T uses a different I2C protocol at address `0x26`.

---

## 2. Verify hardware access

Confirm the SMBus adapter is present:

```bash
i2cdetect -l
```

Expected output includes a line like:

```
i2c-0   smbus   SMBus I801 adapter at efa0   SMBus adapter
```

Scan the bus (replace `0` with your bus number if different):

```bash
i2cdetect -y 0
```

You should see `26` in the `0x20` row:

```
     0  1  2  3  4  5  6  7  8  9  a  b  c  d  e  f
20:          -- -- -- -- -- 26 -- -- -- -- -- -- -- --
```

Confirm the chip identity:

```bash
i2cget -y 0 0x26 0x5a b   # expect 0xa5
i2cget -y 0 0x26 0x5b b   # expect 0xb5
```

If `i2cdetect -l` returns nothing, the `i2c-dev` module is not loaded:

```bash
sudo modprobe i2c-dev
```

If writes fail with `Error: Write failed`, the bus number is wrong. Some users report bus `1` instead of `0` — re-run `i2cdetect -l` and use whichever bus shows the `0x26` device.

---

## 3. Quick manual test

Stop the flashing and set slow white breathing (replace `-y 0` if your bus differs):

```bash
sudo i2cset -y 0 0x26 0xa0 1 b   # red off
sudo i2cset -y 0 0x26 0xa0 2 b   # white off
sudo i2cset -y 0 0x26 0x51 0 b   # slow flash off
sudo i2cset -y 0 0x26 0xb1 2 b   # white on
sudo i2cset -y 0 0x26 0x50 2 b   # breathing
```

Fast-flashing red (shutdown state):

```bash
sudo i2cset -y 0 0x26 0xa0 1 b   # red off
sudo i2cset -y 0 0x26 0xa0 2 b   # white off
sudo i2cset -y 0 0x26 0x51 0 b   # slow flash off
sudo i2cset -y 0 0x26 0x50 0 b   # clear effects
sudo i2cset -y 0 0x26 0xb1 1 b   # red on
sudo i2cset -y 0 0x26 0x50 1 b   # fast flash
```

---

## 4. LED state reference

All commands use `i2cset -y <BUS> 0x26 <register> <value> b`. Replace `<BUS>` with your detected bus number.

### Colors

| Action | Command |
|--------|---------|
| Red on | `i2cset -y <BUS> 0x26 0xb1 1 b` |
| Red off | `i2cset -y <BUS> 0x26 0xa0 1 b` |
| White on | `i2cset -y <BUS> 0x26 0xb1 2 b` |
| White off | `i2cset -y <BUS> 0x26 0xa0 2 b` |

### Effects (apply after turning a color on)

| Action | Command |
|--------|---------|
| Solid on | `i2cset -y <BUS> 0x26 0x50 0 b` |
| Fast flash | `i2cset -y <BUS> 0x26 0x50 1 b` |
| Breathing | `i2cset -y <BUS> 0x26 0x50 2 b` |
| Slow flash on | `i2cset -y <BUS> 0x26 0x51 1 b` |
| Slow flash off | `i2cset -y <BUS> 0x26 0x51 0 b` |

Typical preset before applying an effect:

```bash
i2cset -y <BUS> 0x26 0xa0 1 b   # red off
i2cset -y <BUS> 0x26 0xa0 2 b   # white off
i2cset -y <BUS> 0x26 0x50 0 b   # clear fast/breathing
```

Brightness control is not documented. Community reports indicate the default white brightness is quite high with no known register to dim it.

---

## 5. Install boot and shutdown scripts

These scripts auto-detect the SMBus I801 bus number (which can change across cold boots):

- **Boot / running**: slow white breathing
- **Shutdown**: fast-flashing red

### Create the control script

```bash
sudo tee /usr/local/bin/ugreen-dxp480t-led > /dev/null << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# Detect SMBus I801 bus (bus number can change after cold boot)
I2C_BUS=$(i2cdetect -l | grep -i "SMBus I801" | awk '{print $1}' | sed 's/i2c-//')
if [[ -z "$I2C_BUS" ]]; then
  echo "Error: No SMBus I801 adapter found" >&2
  exit 1
fi

ADDR=0x26
MODE="${1:-white-breathing}"

i2c() {
  i2cset -y "$I2C_BUS" "$ADDR" "$1" "$2" b
}

red_off()     { i2c 0xa0 1; }
white_off()   { i2c 0xa0 2; }
slow_off()    { i2c 0x51 0; }
solid_on()    { i2c 0x50 0; }
fast_on()     { i2c 0x50 1; }
breath_on()   { i2c 0x50 2; }
red_on()      { i2c 0xb1 1; }
white_on()    { i2c 0xb1 2; }

preset() {
  red_off
  white_off
  slow_off
  solid_on
}

case "$MODE" in
  white-breathing)
    preset
    white_on
    breath_on
    ;;
  white-solid)
    preset
    white_on
    solid_on
    ;;
  red-solid)
    preset
    red_on
    solid_on
    ;;
  red-flash)
    preset
    red_on
    fast_on
    ;;
  off)
    red_off
    white_off
    ;;
  *)
    echo "Usage: $0 {white-breathing|white-solid|red-solid|red-flash|off}" >&2
    exit 1
    ;;
esac
SCRIPT

sudo chmod +x /usr/local/bin/ugreen-dxp480t-led
```

Test it:

```bash
sudo /usr/local/bin/ugreen-dxp480t-led white-breathing
sudo /usr/local/bin/ugreen-dxp480t-led red-flash
```

### Create systemd services

Boot service (runs after multi-user.target):

```bash
sudo tee /etc/systemd/system/ugreen-dxp480t-led-boot.service > /dev/null << 'EOF'
[Unit]
Description=UGREEN DXP480T Plus LED — white breathing while running
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ugreen-dxp480t-led white-breathing
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
```

Shutdown service:

```bash
sudo tee /etc/systemd/system/ugreen-dxp480t-led-shutdown.service > /dev/null << 'EOF'
[Unit]
Description=UGREEN DXP480T Plus LED — red flash on shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ugreen-dxp480t-led red-flash
TimeoutStartSec=10

[Install]
WantedBy=halt.target reboot.target shutdown.target
EOF
```

Enable both:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ugreen-dxp480t-led-boot.service
sudo systemctl enable ugreen-dxp480t-led-shutdown.service
```

To use solid white instead of breathing, change `white-breathing` to `white-solid` in the boot service.

---

## 6. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `i2cdetect -l` returns nothing | `i2c-dev` not loaded | `sudo modprobe i2c-dev`; add to modules-load.d |
| `Error: Write failed` | Wrong bus number | Run `i2cdetect -y <N>` on each bus until `0x26` appears |
| LED still flashes after script | Service not running or bus changed | Check `systemctl status ugreen-dxp480t-led-boot.service`; re-run script manually |

### Bus detection one-liner

```bash
for bus in $(i2cdetect -l | awk '{print $1}' | sed 's/i2c-//'); do
  echo "=== i2c-$bus ==="
  i2cdetect -y "$bus" 2>/dev/null | grep -E "26|UU" && echo "Found 0x26 on bus $bus"
done
```

---

## 7. Network, CPU, and disk activity

### Hardware limits

The DXP480T Plus has **one** front-panel LED (red + white in a single housing). Unlike the DXP4800 or DX4600 Pro, there are:

- No per-bay disk LEDs
- No separate network LED
- No activity LED that blinks with I/O

On UGOS, HDD-bay models drive multiple LEDs from the same MCU family. The DXP480T uses a different I2C chip at `0x26` with a smaller feature set. [ugreen_leds_controller](https://github.com/miskcoo/ugreen_leds_controller) and its disk-I/O monitor (`scripts/ugreen-diskiomon`) target those multi-LED models and **do not work** on the DXP480T.

| Signal | Supported on DXP480T? | Notes |
|--------|----------------------|-------|
| Power / running | Yes | White breathing (default), solid white, or off |
| Shutting down | Yes | Fast-flashing red via shutdown service |
| Disk read/write per bay | No | No physical disk LEDs; no kernel LED trigger hooks |
| Network link / traffic | No | No dedicated LED; would need custom logic on the power LED |
| CPU load | No | Not exposed by UGOS hardware; fully custom if desired |
| SMART / disk fault | Partial | No fault LED — can override power LED color/effect via script |

### What you can do instead

Because there is only one LED, any “activity” indication means **temporarily changing the power LED** away from the normal white-breathing state. Examples:

- **Disk fault**: poll `smartctl` on a timer; on failure call `ugreen-dxp480t-led red-solid` or `red-flash`
- **Network down**: poll `ip link` or Tailscale status; switch to red slow-flash while offline, restore `white-breathing` when back
- **Heavy I/O**: poll `/proc/diskstats` or `iostat`; pulse fast-flash briefly during activity (will interrupt breathing)

None of this is built in. You would add a separate monitor script + systemd timer or service that calls `/usr/local/bin/ugreen-dxp480t-led` with different modes. Patterns from [ugreen-diskiomon](https://github.com/miskcoo/ugreen_leds_controller/blob/master/scripts/ugreen-diskiomon) are useful for **what to monitor**, but the I2C commands must come from this guide, not that repo's CLI.

For a headless NAS, monitoring via Prometheus, Scrutiny (SMART), or service health checks is usually more useful than encoding state in a single LED.

---

## References

- [miskcoo/ugreen_leds_controller — Issue #6 (DXP480T)](https://github.com/miskcoo/ugreen_leds_controller/issues/6)
- [fnOS community guide (Chinese)](https://club.fnnas.com/forum.php?mod=viewthread&tid=27494)
- [Arch package: i2c-tools](https://archlinux.org/packages/extra/x86_64/i2c-tools/)
- [AUR: ugreen-leds-controller (other models only)](https://aur.archlinux.org/packages/ugreen-leds-controller-dkms-git)

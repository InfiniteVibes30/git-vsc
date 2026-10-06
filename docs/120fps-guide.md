# Running the Game at 120 FPS

This guide covers the three layers that decide whether the game actually reaches
and holds 120 frames per second:

| Layer | What it controls | Where it's configured |
|---|---|---|
| **1. Game / engine** | Frame-rate cap, VSync, simulation timing | Game code and config files (section 2) |
| **2. Graphics driver** | Driver-level FPS caps, VSync overrides, power state | NVIDIA / AMD / Intel control panel (section 3) |
| **3. Windows (OS)** | Display refresh rate, GPU scheduling, Game Mode, background capture | Settings app and registry (section 4) |

> **Prerequisite:** you only get a real 120 fps on screen with a display running at
> **120 Hz or higher**. On a 60 Hz monitor the game can *render* 120 fps, but you'll
> only *see* 60 of them. Check the refresh rate first (section 4.1).

---

## 1. Safety first: back up before changing anything

Do these before editing the registry, whether by hand or with the script.

1. **Create a System Restore point.** In an elevated PowerShell:
   ```powershell
   Checkpoint-Computer -Description "Before 120fps tweaks" -RestorePointType MODIFY_SETTINGS
   ```
   If this fails, turn on System Protection first: *Control Panel → System →
   System Protection → Configure → Turn on system protection*.

2. **Export each registry key you plan to change.** Run this in an elevated Command Prompt or PowerShell:
   ```bat
   mkdir %USERPROFILE%\120fps-backup
   reg export "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" "%USERPROFILE%\120fps-backup\GraphicsDrivers.reg" /y
   reg export "HKCU\Software\Microsoft\GameBar" "%USERPROFILE%\120fps-backup\GameBar.reg" /y
   reg export "HKCU\System\GameConfigStore" "%USERPROFILE%\120fps-backup\GameConfigStore.reg" /y
   reg export "HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR" "%USERPROFILE%\120fps-backup\GameDVR.reg" /y
   reg export "HKCU\Software\Microsoft\DirectX\UserGpuPreferences" "%USERPROFILE%\120fps-backup\UserGpuPreferences.reg" /y
   ```
   If a key doesn't exist yet, `reg export` reports an error. That's expected: there's nothing to back up.

3. **To restore** a key, double-click its `.reg` file, or run:
   ```bat
   reg import "%USERPROFILE%\120fps-backup\GraphicsDrivers.reg"
   ```

4. **Change one thing at a time** and test after each change, so you know which
   setting helped and which one to undo if something breaks.

The included script (`tools/windows/Set-120FpsTweaks.ps1`) does steps 1 and 2 for you
automatically and can revert its own changes. See section 5.

---

## 2. Game / engine settings (the part that ships with the game)

The cap that matters most is the game's own. Three rules hold in any engine:

- **Expose a frame-rate setting** in the options menu (for example *30 / 60 / 120 / 144 / Unlimited*),
  and default it to the display's refresh rate.
- **Turn off VSync, or make it optional, when using a fixed cap.** VSync locks the game to the
  refresh rate. With VSync on, 120 fps happens only on a 120 Hz display. With VSync off, the cap does the limiting.
- **Separate simulation from rendering.** Run physics and gameplay on a fixed timestep (for
  example 60 Hz) and render at 120 fps with interpolation. Otherwise the game runs
  faster at higher frame rates, and physics behaves differently.

### Unity (C#)
```csharp
using UnityEngine;

public class FrameRateSettings : MonoBehaviour
{
    [SerializeField] int targetFps = 120;

    void Awake()
    {
        QualitySettings.vSyncCount = 0;          // 0 = off, so targetFrameRate applies
        Application.targetFrameRate = targetFps; // -1 = unlimited
        Time.fixedDeltaTime = 1f / 60f;          // physics stays at 60 Hz
    }
}
```

### Unreal Engine
`Config/DefaultEngine.ini`:
```ini
[/Script/Engine.Engine]
bUseFixedFrameRate=False
bSmoothFrameRate=False
```
`Saved/Config/Windows/GameUserSettings.ini` (per-user):
```ini
[/Script/Engine.GameUserSettings]
FrameRateLimit=120.000000
bUseVSync=False
```
Console / runtime:
```
t.MaxFPS 120
r.VSync 0
```
In C++: `GEngine->GetGameUserSettings()->SetFrameRateLimit(120.f); ->ApplySettings(false);`

### Godot 4
`project.godot`:
```ini
[application]
run/max_fps=120

[display]
window/vsync/vsync_mode=0   ; 0 = Disabled
```
Runtime (GDScript):
```gdscript
DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
Engine.max_fps = 120
Engine.physics_ticks_per_second = 60
```

### Custom engine / framework
- Use a high-resolution timer (`QueryPerformanceCounter` on Windows) and limit to
  `1/120 s ≈ 8.333 ms` per frame. Sleep for most of the remaining time, then spin-wait for the last ~1 ms
  (Windows sleep granularity is coarse).
- Use a DXGI **flip-model** swap chain (`DXGI_SWAP_EFFECT_FLIP_DISCARD`) and
  `Present(0, DXGI_PRESENT_ALLOW_TEARING)` when VSync is off. This gives lower latency in
  windowed and borderless modes.

**Effect:** the game will try to deliver exactly 120 frames per second, no more, so the GPU
doesn't burn power on frames the display can't show. A stable 120 feels smoother than a
number that swings between 90 and 200.

---

## 3. Graphics driver settings

A driver-level cap or VSync override takes precedence over the game's own setting, so check these if the game seems stuck at 60.
These are set in the vendor control panels. There are no supported registry values for them.

| Vendor | Where | Setting |
|---|---|---|
| **NVIDIA** | NVIDIA Control Panel → *Manage 3D settings* → *Program Settings* → (pick the game) | **Max Frame Rate** = 120 (or Off if the game caps itself); **Vertical sync** = *Use the 3D application setting*; **Power management mode** = *Prefer maximum performance*; **Low Latency Mode** = On |
| **AMD** | AMD Software: Adrenalin → *Gaming* → (game) | **Frame Rate Target Control** = 120 (or off); **Wait for Vertical Refresh** = *Off, unless application specifies*; leave **Radeon Chill** off |
| **Intel Arc / Iris** | Intel Graphics Software → *Graphics* → (game) | **Frame Rate Limiter** = 120 (or off); **Vertical Sync** = *Use application settings* |

**Only cap in one place.** Two caps (game + driver) can fight and cause stutter. Prefer
the in-game cap, and use the driver cap only as a fallback.

If the display supports **G-SYNC / FreeSync / VRR**, turn it on in the driver *and* in
Windows (*Settings → System → Display → Graphics → Variable refresh rate*). With VRR on,
a cap a few frames below the refresh rate (for example 117 on a 120 Hz panel) avoids tearing at no extra latency cost.

---

## 4. Windows settings

These apply to **Windows 10 (2004+) and Windows 11**. The paths and values below are
documented or widely used Microsoft settings. Each one can be set through the Settings app (preferred) or the registry.

### 4.1 Display refresh rate (required)
**Settings → System → Display → Advanced display → Choose a refresh rate → 120 Hz (or higher).**

There's no stable registry value for this. It's stored per-monitor in driver-managed keys,
so **always use the Settings app**. If 120 Hz isn't listed, check that the cable supports it
(DisplayPort 1.2+ or HDMI 2.0+) and the monitor's own menu has it enabled.

### 4.2 Hardware-accelerated GPU scheduling (HAGS)
Lets the GPU manage its own memory scheduling, which can lower latency and CPU overhead.

- **UI:** Settings → System → Display → Graphics → *Change default graphics settings* →
  *Hardware-accelerated GPU scheduling* = On
- **Registry** (admin, **reboot required**):
  ```bat
  reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v HwSchMode /t REG_DWORD /d 2 /f
  ```
  `2` = On, `1` = Off.
- **Effect:** usually a small latency/frame-time improvement on modern GPUs (NVIDIA
  GTX 10-series+, AMD RX 5000+). It's required for DLSS Frame Generation. On older GPUs or drivers it can
  cause stutter. If it does, set it back to `1`.

### 4.3 Game Mode
Tells Windows to give priority to the foreground game and hold back Windows Update installs and
notifications.

- **UI:** Settings → Gaming → Game Mode = On
- **Registry** (current user):
  ```bat
  reg add "HKCU\Software\Microsoft\GameBar" /v AutoGameModeEnabled /t REG_DWORD /d 1 /f
  reg add "HKCU\Software\Microsoft\GameBar" /v AllowAutoGameMode   /t REG_DWORD /d 1 /f
  ```
- **Effect:** more consistent frame times when background tasks are running. It's on by
  default in current Windows builds.

### 4.4 Disable background game recording (Game DVR)
Background recording continuously encodes video and takes GPU time away from the game.

- **UI:** Settings → Gaming → Captures → *Record what happened* = Off
- **Registry** (current user):
  ```bat
  reg add "HKCU\System\GameConfigStore" /v GameDVR_Enabled /t REG_DWORD /d 0 /f
  reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v AppCaptureEnabled /t REG_DWORD /d 0 /f
  ```
- **Effect:** frees GPU encoder and memory bandwidth. Downside: Win+Alt+G "record last
  30 seconds" stops working.

### 4.5 Force the high-performance GPU (laptops / hybrid graphics)
On laptops with both integrated and dedicated GPUs, make sure the game runs on the dedicated one.

- **UI:** Settings → System → Display → Graphics → add the game's `.exe` → Options →
  *High performance*
- **Registry** (current user; the value name is the full path to the exe):
  ```bat
  reg add "HKCU\Software\Microsoft\DirectX\UserGpuPreferences" /v "C:\Games\MyGame\MyGame.exe" /t REG_SZ /d "GpuPreference=2;" /f
  ```
  `0` = let Windows decide, `1` = power saving, `2` = high performance.
- **Effect:** on hybrid laptops this is often the difference between ~40 fps and 120+.

### 4.6 Optimizations for windowed games (Windows 11)
Upgrades older DirectX 10/11 games running in windowed or borderless mode to the flip-model presentation path, for lower
latency and support for VRR in windowed mode.

- **UI:** Settings → System → Display → Graphics → *Change default graphics settings* →
  *Optimizations for windowed games* = On
- **Registry** (current user):
  ```bat
  reg add "HKCU\Software\Microsoft\DirectX\UserGpuPreferences" /v DirectXUserGlobalSettings /t REG_SZ /d "SwapEffectUpgradeEnable=1;" /f
  ```
  If `DirectXUserGlobalSettings` already has other entries (for example `VRROptimizeEnable=0;`),
  **add** `SwapEffectUpgradeEnable=1;` to the existing string instead of replacing it.

### 4.7 Power plan
Stops the CPU from clocking down between frames.

```bat
powercfg /list
powercfg /setactive SCHEME_MIN
```
`SCHEME_MIN` is the built-in **High performance** plan (despite the name). Restore with
`powercfg /setactive SCHEME_BALANCED`. On laptops, plug in. Battery mode limits clocks
regardless of the plan.

---

## 5. Using the included script

`tools/windows/Set-120FpsTweaks.ps1` applies sections 4.2–4.7 safely:

- creates a System Restore point (if System Protection is on)
- exports every registry key it touches to a timestamped backup folder
- records the original values so `-Revert` restores exactly what was there
- supports `-WhatIf` to preview changes without applying them

From an **elevated** PowerShell in the repo root:
```powershell
# Preview what would change
powershell -ExecutionPolicy Bypass -File tools\windows\Set-120FpsTweaks.ps1 -WhatIf

# Apply (optionally pin a game exe to the dedicated GPU)
powershell -ExecutionPolicy Bypass -File tools\windows\Set-120FpsTweaks.ps1 -GameExe "C:\Games\MyGame\MyGame.exe"

# Undo using the most recent backup
powershell -ExecutionPolicy Bypass -File tools\windows\Set-120FpsTweaks.ps1 -Revert
```
Reboot after applying or reverting, because the HAGS change only takes effect after a restart.

---

## 6. Tweaks deliberately *not* included

Many "FPS boost" guides online recommend registry edits that do nothing on modern Windows, or
make things worse. Avoid these:

| Tweak | Why to skip |
|---|---|
| `TdrDelay` / `TdrLevel` (GraphicsDrivers) | Disables GPU-hang recovery: a driver hang becomes a full system freeze instead of a recovered black screen. |
| `Win32PrioritySeparation` | Changes scheduler quantum for the whole system. Benefits are unproven and it can hurt audio/input responsiveness. |
| `SystemProfile\Tasks\Games` "GPU Priority" / "Scheduling Category" | Only affects apps that register with MMCSS. Most games don't, so it has no effect. |
| `NetworkThrottlingIndex = ffffffff` | Network-related, not frame-rate related. It can raise DPC latency. |
| Disabling HPET / `bcdedit /set useplatformclock` | Can *increase* timer overhead and break frame pacing. Modern Windows already picks the best timer. |
| Disabling Windows Defender / services wholesale | Security risk for little or no measurable gain. |

---

## 7. Verifying the result

1. Check the display really is at 120 Hz: <https://www.testufo.com> shows the detected refresh rate.
2. Show an FPS counter in-game. Unity: the Stats panel. Unreal: `stat fps` / `stat unit`.
   Godot: `Engine.get_frames_per_second()`. Or use the Xbox Game Bar's Performance widget (Win+G).
3. Watch **frame time**, not just FPS. A steady **8.3 ms** line means smooth 120. Spikes
   mean stutter, even if the average reads 120. Tools: PresentMon / Intel PresentMon, CapFrameX, MSI Afterburner.
4. If you're stuck at 60: VSync is on with a 60 Hz display, a driver cap is set, or the laptop
   is on the integrated GPU (sections 3, 4.1, 4.5).
5. If you're under 120 with the GPU at ~99% load: you're GPU-bound. Lower resolution or graphics quality,
   or enable upscaling (DLSS / FSR / XeSS). OS tweaks won't close a large gap.

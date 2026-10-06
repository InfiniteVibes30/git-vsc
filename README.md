# git-vsc

## Performance: 120 FPS

- [docs/120fps-guide.md](docs/120fps-guide.md): how to reach a steady 120 FPS, covering
  the engine frame cap and VSync, driver settings, and Windows registry and system settings,
  with backup and revert steps.
- [tools/windows/Set-120FpsTweaks.ps1](tools/windows/Set-120FpsTweaks.ps1): applies the
  Windows settings from the guide, backing them up first. Supports `-WhatIf` and `-Revert`.

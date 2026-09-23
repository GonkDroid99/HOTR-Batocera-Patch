HOTR Batocera 43 launch/config fix

Problems fixed:
1) The old hotr-configgen-launch treated %CONTROLLERSCONFIG% as one positional
   argument. In reality it expands to many command-line flags, so both systems
   could fail before configgen ever reached the emulator.
2) The DuckStation generator only swapped the executable when cmd.array[0] was
   exactly 'duckstation-qt'. Batocera may return an absolute executable path.
   The HOTR generator now always swaps to the HOTR executable.
3) PCSX2 HOTR now runs its AppImage with APPIMAGE_EXTRACT_AND_RUN=1 and uses its
   own directory as the execution directory, keeping MameOutputSender/resources
   beside the emulator.
4) The old es_features_hotr.cfg was intentionally minimal, so PCSX2 HOTR only
   showed the HOTR output switch. generate-es-features-hotr.py clones the FULL
   stock Batocera DuckStation/PCSX2 feature definitions and adds the HOTR option.

To test directly on Batocera:
  unzip HOTR-Batocera43-launch-fix.zip
  cd HOTR-Batocera43-launch-fix
  ./apply-fix.sh
  reboot

Then launch a game. If it still fails:
  tail -n 200 /userdata/system/logs/es_launch_stderr.log
  tail -n 200 /userdata/system/logs/es_launch_stdout.log

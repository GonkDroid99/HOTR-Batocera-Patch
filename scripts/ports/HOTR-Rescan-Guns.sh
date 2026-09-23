#!/bin/bash
ROOT=/userdata/system/hotr
/userdata/system/services/hotr stop 2>/dev/null || true
python3 "$ROOT/bin/hotr-autoconfig.py" --force
/userdata/system/services/hotr start

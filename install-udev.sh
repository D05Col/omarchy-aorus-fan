#!/usr/bin/env bash
# Install the udev rule that lets the logged-in user write to the cooler's hidraw node.
# Without it the plugin can read status but not change profiles. Needs sudo.
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/70-waterforce.rules"

sudo install -m 0644 "$src" /etc/udev/rules.d/70-waterforce.rules
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=hidraw --action=change
echo "udev rule installed"

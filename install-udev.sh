#!/usr/bin/env bash
# Install the udev rule that lets the logged-in user write to the cooler's hidraw node.
# Without it the plugin can read status but not change profiles.
# The panel runs this through pkexec; from a terminal it asks for sudo itself.
set -euo pipefail

[[ $EUID -eq 0 ]] || exec sudo "$0" "$@"

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/70-waterforce.rules"

install -m 0644 "$src" /etc/udev/rules.d/70-waterforce.rules
udevadm control --reload-rules
udevadm trigger --subsystem-match=hidraw --action=change
echo "udev rule installed"

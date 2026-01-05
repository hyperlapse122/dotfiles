#!/bin/bash

set -e -o pipefail

ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

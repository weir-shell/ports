#!/bin/bash
pwd > "${RING_PWD_OUT:-/dev/null}"
exec sleep 600

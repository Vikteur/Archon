#!/usr/bin/env bash
# Post comments on a PR without approving or requesting changes. Same arguments as review.sh.
exec bash "$(dirname "${BASH_SOURCE[0]}")/review.sh" --event COMMENT "$@"

#!/usr/bin/env bash
# Submit a "request changes" review on a PR. Same arguments as review.sh; --body is required.
exec bash "$(dirname "${BASH_SOURCE[0]}")/review.sh" --event REQUEST_CHANGES "$@"

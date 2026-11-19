#!/bin/bash -e

# The CPZ graphics packages (cage, foot, Mesa DRI, xauth and Xwayland) are
# installed by ../01-session/00-packages, so the whole stage uses one apt
# transaction. This stage remains as the documented graphics boundary and is
# kept in the pi-gen layout/verification checks.
exit 0

# TokenPilot local verification environment.
# Source this file before build/test/smoke commands to keep all runtime work scoped
# to this project directory. It performs no installs and reads no credentials.
export TOKENPILOT_TOOLCHAIN_LOADED=1
export TOKENPILOT_PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TOKENPILOT_PROJECT_ROOT"

# t_core_ctl_arch.S -- t_core_ctl.S without the timing checks (check 3), for
# runs with bus wait states: there fetch latency dominates and the predictor's
# one-cycle saving disappears, so only architectural equivalence is checked.
#define CTL_ARCH_ONLY
#include "t_core_ctl.S"

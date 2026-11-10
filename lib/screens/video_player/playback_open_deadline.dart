/// How long a started load may go without progress — no `file-loaded`, no
/// demuxer progress, no failure, no death — before the attempt gives up on
/// it. A slow load that keeps moving is not bounded by this (#2635).
///
/// Live TV gets the short budget: a dead channel held the spinner for half a
/// minute (audit finding #2). Ten seconds is long enough for a slow HLS
/// playlist fetch and demux, short enough that a dead channel surfaces
/// promptly — and it matches the app's existing patience for live (the
/// mini-player's 5 s first-frame watchdog only reveals the surface).
/// On-demand opens negotiate and buffer more before the first frame, so they
/// keep the 30 s budget.
const Duration liveOpenDeadline = Duration(seconds: 10);

/// On-demand open deadline: unchanged from the pre-#24 behaviour.
const Duration vodOpenDeadline = Duration(seconds: 30);

/// The open deadline for a screen of the given kind.
Duration openDeadlineFor({required bool isLive}) => isLive ? liveOpenDeadline : vodOpenDeadline;

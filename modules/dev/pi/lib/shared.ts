/**
 * Code shared by the Pi extensions in the folder above. Not an extension itself: Pi loads the
 * .ts files directly in extensions/ and folders with an index file, so lib/ is skipped.
 */

import type { ExtensionAPI, Theme } from "@earendil-works/pi-coding-agent";

export type ThemeColor = Parameters<Theme["fg"]>[0];

// Event bus: extensions talk to status.ts and notify.ts through these channels.

const STATUS_CHANNEL = "status";
const NOTIFY_CHANNEL = "notify";

// A part of the status line (status.ts), ordered by key. Without render, the segment is
// removed; spinner colors the working spinner (the first segment by key that sets one wins).
export interface StatusSegment {
  key: string;
  render?: (theme: Theme) => string;
  spinner?: ThemeColor;
}

// A desktop notification (notify.ts); a final notice stays on the card instead of the run's
// "Done".
export interface Notice {
  message: string;
  final?: boolean;
}

export function sendStatus(pi: ExtensionAPI, segment: StatusSegment) {
  pi.events.emit(STATUS_CHANNEL, segment);
}

export function onStatus(pi: ExtensionAPI, handler: (segment: StatusSegment) => void) {
  pi.events.on(STATUS_CHANNEL, (data) => handler(data as StatusSegment));
}

export function sendNotice(pi: ExtensionAPI, notice: Notice) {
  pi.events.emit(NOTIFY_CHANNEL, notice);
}

export function onNotice(pi: ExtensionAPI, handler: (notice: Notice) => void) {
  pi.events.on(NOTIFY_CHANNEL, (data) => handler(data as Notice));
}

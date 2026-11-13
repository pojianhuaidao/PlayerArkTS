export class PlaybackManager {
  private static pauseCallback: (() => void) | null = null;
  private static resumeCallback: (() => void) | null = null;

  static setCallbacks(pause: (() => void) | null, resume: (() => void) | null): void {
    PlaybackManager.pauseCallback = pause;
    PlaybackManager.resumeCallback = resume;
  }

  static pauseForBackground(): void {
    if (PlaybackManager.pauseCallback) {
      PlaybackManager.pauseCallback();
    }
  }

  static resumeFromBackground(): void {
    if (PlaybackManager.resumeCallback) {
      PlaybackManager.resumeCallback();
    }
  }
}

/**
 * Structured JSON logger for the Enterprise Node.
 *
 * Lightweight structured logging without external dependencies.
 * All output is JSON lines to stdout/stderr for production log aggregation.
 *
 * @module logger
 */

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type LogLevel = "debug" | "info" | "warn" | "error";

interface LogEntry {
  readonly level: LogLevel;
  readonly module: string;
  readonly msg: string;
  readonly ts: string;
  readonly [key: string]: unknown;
}

const LOG_LEVELS: Record<LogLevel, number> = {
  debug: 0,
  info: 1,
  warn: 2,
  error: 3,
};

/** Current minimum log level (configurable via LOG_LEVEL env var). */
function getMinLevel(): number {
  const envLevel = process.env["LOG_LEVEL"]?.toLowerCase();
  if (envLevel && envLevel in LOG_LEVELS) {
    return LOG_LEVELS[envLevel as LogLevel];
  }
  return LOG_LEVELS.info;
}

// ---------------------------------------------------------------------------
// Logger
// ---------------------------------------------------------------------------

export interface Logger {
  debug(msg: string, data?: Record<string, unknown>): void;
  info(msg: string, data?: Record<string, unknown>): void;
  warn(msg: string, data?: Record<string, unknown>): void;
  error(msg: string, data?: Record<string, unknown>): void;
}

/**
 * Create a structured logger scoped to a module.
 *
 * @param module - Module name for log context
 * @returns Logger instance
 */
export function createLogger(module: string): Logger {
  const emit = (level: LogLevel, msg: string, data?: Record<string, unknown>): void => {
    if (LOG_LEVELS[level] < getMinLevel()) return;

    const entry: LogEntry = {
      level,
      module,
      msg,
      ts: new Date().toISOString(),
      ...data,
    };

    const line = JSON.stringify(entry);

    if (level === "error" || level === "warn") {
      process.stderr.write(line + "\n");
    } else {
      process.stdout.write(line + "\n");
    }
  };

  return {
    debug: (msg, data) => emit("debug", msg, data),
    info: (msg, data) => emit("info", msg, data),
    warn: (msg, data) => emit("warn", msg, data),
    error: (msg, data) => emit("error", msg, data),
  };
}

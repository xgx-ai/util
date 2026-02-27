const RESET = "\x1b[0m";
const DIM = "\x1b[2m";
const BOLD = "\x1b[1m";
const GRAY = "\x1b[90m";
const CYAN = "\x1b[36m";
const YELLOW = "\x1b[33m";
const RED = "\x1b[31m";

const levels = ["debug", "info", "warn", "error"] as const;
type LogLevel = (typeof levels)[number];

const minLevel = levels.indexOf((process.env.LOG_LEVEL as LogLevel) || "info");

const levelConfig: Record<LogLevel, { color: string; badge: string }> = {
	debug: { color: GRAY, badge: "DBUG" },
	info: { color: CYAN, badge: "INFO" },
	warn: { color: YELLOW, badge: "WARN" },
	error: { color: RED, badge: "ERRO" },
};

function formatTimestamp(): string {
	const now = new Date();
	const h = now.getHours().toString().padStart(2, "0");
	const m = now.getMinutes().toString().padStart(2, "0");
	const s = now.getSeconds().toString().padStart(2, "0");
	const ms = now.getMilliseconds().toString().padStart(3, "0");
	return `${h}:${m}:${s}.${ms}`;
}

const originalConsole = {
	info: console.info,
	warn: console.warn,
	error: console.error,
	debug: console.debug,
};

function createLogger(level: LogLevel) {
	const levelIndex = levels.indexOf(level);
	if (levelIndex < minLevel) return () => {};

	const config = levelConfig[level];
	return (...args: unknown[]) => {
		const timestamp = `${DIM}${formatTimestamp()}${RESET}`;
		const badge = `${config.color}${BOLD}${config.badge}${RESET}`;

		originalConsole[level](`${timestamp} ${badge}`, ...args);
	};
}

console.debug = createLogger("debug");
console.info = createLogger("info");
console.warn = createLogger("warn");
console.error = createLogger("error");

#!/usr/bin/env node
// Mint through a headless Chrome this skill owns, for every session Orca is not running.
//
// Zero dependencies on purpose. Node has had a global WebSocket since 21, so the DevTools
// Protocol is reachable with nothing installed — which matters because the alternative was
// importing puppeteer out of the browser-tools skill, and a skill reaching into another
// skill's node_modules is the coupling this skill avoids.
//
// The profile lives in ~/.claude/state/github-attachments/, never in the checkout. It holds
// a live GitHub session, so it deliberately does not go in ~/.cache/browser-tools: that
// directory is shared by every Claude session on this machine, and a session cookie parked
// there would let any of them act as the human on GitHub.
//
// Usage: chrome.mjs <image> <owner/repo> <timeout-seconds> [--login]
// Prints: the asset uuid on stdout. Everything else goes to stderr.

import { execFileSync, spawn } from "node:child_process";
import { accessSync, constants, readFileSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { createConnection } from "node:net";
import { homedir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const LIB = join(HERE, "..", "..", "lib", "paste.js");
const PROFILE = join(homedir(), ".claude", "state", "github-attachments", "chrome-profile");
const MAC_CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const PORT = 9375; // Not 9222: that port is browser-tools', shared by every session here.
let chromeChild = null;

const [image, repo, timeoutArg, ...rest] = process.argv.slice(2);
const login = rest.includes("--login");
const timeoutMs = Number(timeoutArg || 60) * 1000;

const die = (code, ...lines) => {
	for (const l of lines) console.error(`chrome: ${l}`);
	process.exit(code);
};

// --- Chrome -----------------------------------------------------------------

function findChrome() {
	const override = process.env.GH_ATTACH_CHROME;
	if (override) {
		try {
			accessSync(override, constants.X_OK);
			return override;
		} catch {
			die(3, `GH_ATTACH_CHROME is not an executable Chrome: ${override}`);
		}
	}

	const names = process.platform === "darwin"
		? [MAC_CHROME, "google-chrome", "google-chrome-stable", "chromium", "chromium-browser"]
		: ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"];
	for (const name of names) {
		const candidates = name.includes("/")
			? [name]
			: (process.env.PATH || "").split(delimiter).filter(Boolean).map((dir) => join(dir, name));
		for (const candidate of candidates) {
			try {
				accessSync(candidate, constants.X_OK);
				return candidate;
			} catch {}
		}
	}

	die(
		3,
		"Chrome executable not found.",
		"Set GH_ATTACH_CHROME to a Chrome executable, or install google-chrome, google-chrome-stable, chromium, or chromium-browser on PATH.",
	);
}

function portInUse() {
	return new Promise((resolve) => {
		const socket = createConnection({ host: "127.0.0.1", port: PORT });
		const done = (used) => {
			socket.destroy();
			resolve(used);
		};
		socket.once("connect", () => done(true));
		socket.once("error", () => done(false));
	});
}

function stopChromeSync() {
	if (!chromeChild?.pid) return;
	try {
		// The child is detached, so its process group contains Chrome and its
		// renderers but not this driver or any pre-existing browser.
		process.kill(-chromeChild.pid, "SIGTERM");
	} catch {}
	chromeChild = null;
}

async function stopChrome() {
	const pid = chromeChild?.pid;
	if (!pid) return;
	stopChromeSync();
	await new Promise((r) => setTimeout(r, 250));
	try {
		process.kill(-pid, "SIGKILL");
	} catch {}
}

process.once("exit", stopChromeSync);

async function startChrome() {
	const chrome = findChrome();
	if (await portInUse())
		die(
			3,
			`DevTools port ${PORT} is already in use; refusing to attach to an existing browser.`,
			`Stop the process using port ${PORT} (for example, close its Chrome window) and retry.`,
		);
	await mkdir(PROFILE, { recursive: true });
	const args = [
		`--remote-debugging-port=${PORT}`,
		`--user-data-dir=${PROFILE}`,
		"--no-first-run",
		"--no-default-browser-check",
		"--disable-background-networking",
	];
	// The login run wants a window; every other run must never steal focus.
	if (!login) args.push("--headless=new", "--disable-gpu");
	// Chrome is a universal binary, and macOS starts it as x86_64 under Rosetta when an
	// Intel shell is anywhere up the chain, even through an arm64-only node. An Intel
	// bash first on PATH (a leftover /usr/local/bin/bash) did exactly that through
	// mint.sh's `env bash`, and GitHub then took 30-40s per step (#6). Ask the hardware,
	// not process.arch: a universal node is itself translated in that chain.
	let appleSilicon = false;
	try {
		appleSilicon = process.platform === "darwin" && execFileSync("/usr/sbin/sysctl", ["-n", "hw.optional.arm64"], { encoding: "utf8" }).trim() === "1";
	} catch {} // Intel Macs have no such key.
	const [cmd, pre] = appleSilicon ? ["/usr/bin/arch", ["-arm64", chrome]] : [chrome, []];
	const child = spawn(cmd, [...pre, ...args], { stdio: "ignore", detached: true });
	chromeChild = child;
	child.unref();
	for (let i = 0; i < 100; i++) {
		try {
			const r = await fetch(`http://127.0.0.1:${PORT}/json/version`);
			if (r.ok) return child;
		} catch {}
		await new Promise((r) => setTimeout(r, 100));
	}
	await stopChrome();
	die(3, "Chrome did not answer on the debugging port within 10s.");
}

async function connect(url) {
	const page = await (await fetch(`http://127.0.0.1:${PORT}/json/new?${encodeURIComponent(url)}`, { method: "PUT" })).json();
	const ws = new WebSocket(page.webSocketDebuggerUrl);
	await new Promise((res, rej) => {
		ws.onopen = res;
		ws.onerror = () => rej(new Error("could not attach to the page"));
	});

	let next = 1;
	const waiting = new Map();
	// A closed socket never answers, and send() on it does not throw, so settle every
	// question still waiting instead of hanging the caller past its deadline.
	ws.onclose = ws.onerror = () => {
		for (const p of waiting.values()) p.reject(new Error("page connection closed"));
		waiting.clear();
	};
	ws.onmessage = (e) => {
		const msg = JSON.parse(e.data);
		const pending = waiting.get(msg.id);
		if (!pending) return;
		waiting.delete(msg.id);
		msg.error ? pending.reject(new Error(msg.error.message)) : pending.resolve(msg.result);
	};

	const send = (method, params) =>
		new Promise((resolve, reject) => {
			const id = next++;
			waiting.set(id, { resolve, reject });
			ws.send(JSON.stringify({ id, method, params }));
		});

	// Returns the expression's value, already JSON-parsed where the caller asked for JSON.
	const evaluate = async (expression) => {
		const r = await send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
		if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || "evaluate threw");
		return r.result.value;
	};

	return { page, evaluate, close: () => ws.close() };
}

// Every mint opens a tab, so every mint closes it. Left open, they piled up in one
// headless Chrome that ran for days, each GitHub page with its own renderer (#6). The
// browser goes too once nothing else is using it; a concurrent mint's tab, even one
// still on about:blank, keeps it alive. chrome://newtab/ is Chrome's own.
async function closeTab(tab) {
	tab.close();
	try {
		await fetch(`http://127.0.0.1:${PORT}/json/close/${tab.page.id}`);
		const others = (await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json()).filter(
			(t) => t.type === "page" && t.id !== tab.page.id && t.url !== "chrome://newtab/",
		);
		if (others.length) return;
		const { webSocketDebuggerUrl } = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json();
		const browser = new WebSocket(webSocketDebuggerUrl);
		await new Promise((res, rej) => {
			browser.onopen = res;
			browser.onerror = rej;
		});
		browser.send(JSON.stringify({ id: 1, method: "Browser.close" }));
		await new Promise((r) => {
			browser.onclose = r;
			setTimeout(r, 2000);
		});
	} catch {} // Cleanup never turns a minted URL into a failure.
}

// --- the one-time login -----------------------------------------------------

if (login) {
	await startChrome();
	const tab = await connect("https://github.com/login");
	console.error("A Chrome window is open on github.com/login.");
	console.error("Sign in there, then close the window. The session stays in:");
	console.error(`  ${PROFILE}`);
	console.error("Waiting for the sign-in to land (Ctrl-C to give up)...");
	for (;;) {
		await new Promise((r) => setTimeout(r, 2000));
		let who = null;
		try {
			who = await tab.evaluate('document.querySelector("meta[name=user-login]")?.content || null');
		} catch {
			continue; // navigation tears the page down mid-question; that is normal here.
		}
		if (who) {
			console.error(`Signed in as ${who}. You can close the window.`);
			await stopChrome();
			process.exit(0);
		}
	}
}

// --- the mint ---------------------------------------------------------------

if (!image || !repo) die(2, "usage: chrome.mjs <image> <owner/repo> <timeout-seconds>");

const target = `https://github.com/${repo}/issues/new`;
const pause = (ms) => new Promise((r) => setTimeout(r, ms));
class Failure extends Error {
	constructor(code, lines) {
		super(lines[0]);
		Object.assign(this, { code, lines });
	}
}
const fail = (code, ...lines) => {
	throw new Failure(code, lines);
};

// Read straight to base64 so the bytes never become a string anyone has to look at.
const b64 = readFileSync(image).toString("base64");
const name = image.split("/").pop();
const mime = name.toLowerCase().endsWith(".png")
	? "image/png"
	: /\.jpe?g$/i.test(name)
		? "image/jpeg"
		: /\.gif$/i.test(name)
			? "image/gif"
			: /\.webp$/i.test(name)
				? "image/webp"
				: /\.pdf$/i.test(name) ? "application/pdf" : "application/octet-stream";

await startChrome();
const tab = await connect(target);
const library = readFileSync(LIB, "utf8");
// Navigation replaces the page's globals and can destroy the context mid-question, so
// every call re-installs the library and a thrown evaluate just means "not yet".
const ask = async (expression) => {
	try {
		return await tab.evaluate(`(() => { if (!globalThis.__ghAttach) { ${library} } return ${expression}; })()`);
	} catch {
		return null;
	}
};

const draftLines = [
	`the editor on ${target} already has text in it; left untouched`,
	"It is a saved draft in this skill's Chrome profile, or the repository's issue template prefills the body.",
];

let code = 0;
let pasted = false;
try {
	const deadline = Date.now() + timeoutMs;

	let where = { state: "loading" };
	while (Date.now() < deadline) {
		where = (await ask(`globalThis.__ghAttach.page(${JSON.stringify(target)})`)) || { state: "loading" };
		if (["ready", "signed-out", "wrong-page", "draft"].includes(where.state)) break;
		await pause(250);
	}
	if (where.state === "loading") fail(3, `${target} did not finish loading within ${timeoutMs / 1000}s`);
	if (where.state === "signed-out")
		fail(
			4,
			"this browser is not signed in to GitHub.",
			"Run `scripts/login.sh` once; the session then persists for every later run.",
		);
	if (where.state === "draft") fail(5, ...draftLines);
	if (where.state !== "ready")
		fail(
			5,
			`no comment editor on ${target}`,
			"Check the repository exists, that this account can see it, and that issues are enabled.",
		);

	// Keep offering until the client-rendered editor takes the file (see offer() in
	// lib/paste.js). The bytes go to the page once, not with every offer.
	const stage = `(globalThis.__ghAttachFile = ${JSON.stringify(b64)}, true)`;
	await ask(stage);
	let offer = null;
	while (Date.now() < deadline) {
		offer = await ask(
			`globalThis.__ghAttach.offer(globalThis.__ghAttachFile,${JSON.stringify(name)},${JSON.stringify(mime)})`,
		);
		if (offer?.ok || offer?.reason === "draft") break;
		if (offer?.reason === "file-not-staged") await ask(stage);
		await pause(250);
	}
	if (offer?.reason === "draft") fail(5, ...draftLines);
	if (!offer?.ok) fail(6, `the editor did not accept the paste (${offer?.reason || "unknown"})`);
	pasted = true;

	for (;;) {
		const got = await ask("globalThis.__ghAttach.harvest()");
		if (got?.state === "done") {
			console.log(got.url);
			break;
		}
		if (got?.state === "refused") fail(8, got.error);
		if (Date.now() > deadline) fail(7, `gave up after ${timeoutMs / 1000}s waiting for GitHub to return an asset URL`);
		await pause(500);
	}
} catch (e) {
	code = e instanceof Failure ? e.code : 3;
	for (const l of e instanceof Failure ? e.lines : [e.message]) console.error(`chrome: ${l}`);
} finally {
	if (pasted) await ask("globalThis.__ghAttach.clear()");
	await ask("(delete globalThis.__ghAttachFile, true)");
	await closeTab(tab);
	await stopChrome();
}
process.exit(code);

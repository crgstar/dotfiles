#!/usr/bin/env node
// reflect-extract CLI: I/O (ファイル読み・argv 解釈・stdout 出力) だけを担う薄い層。
// 判定・整形ロジックは lib.mjs の純粋関数に置く。

import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join, dirname, basename } from "node:path";
import { homedir } from "node:os";

import {
  parseJsonl,
  buildToolUseMap,
  buildToolResultIndex,
  buildDigest,
  resolveUuidPrefix,
  resolveByLine,
  resolveBoundaryIndex,
  sessionHasOrigin,
  clampRadius,
  sliceContext,
  sliceTail,
  renderThin,
  shortUuid,
  DEFAULT_RADIUS,
  DEFAULT_TOP_TURNS,
  DEFAULT_MIN_TURN_MS,
} from "./lib.mjs";

function die(msg, code = 2) {
  process.stderr.write(`${msg}\n`);
  process.exit(code);
}

function parseFlags(argv, spec) {
  // spec: { "--flag": "string"|"number"|"boolean" }
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) {
      out._ = out._ ?? [];
      out._.push(a);
      continue;
    }
    const kind = spec[a];
    if (kind === "boolean") {
      out[a] = true;
    } else if (kind) {
      out[a] = argv[++i];
    } else {
      die(`unknown flag: ${a}`);
    }
  }
  return out;
}

// ---- subagent index の解決 (I/O) ----

function buildSubagentIndex(jsonlPath) {
  const dir = join(dirname(jsonlPath), basename(jsonlPath, ".jsonl"), "subagents");
  const index = new Map();
  if (!existsSync(dir)) return index;
  for (const f of readdirSync(dir)) {
    if (!f.endsWith(".meta.json")) continue;
    try {
      const meta = JSON.parse(readFileSync(join(dir, f), "utf8"));
      const agentFile = f.replace(/\.meta\.json$/, "");
      if (meta.toolUseId) index.set(meta.toolUseId, { agentFile, meta });
    } catch {
      // 壊れた meta.json は無視（why: digest 生成全体を止めたくない）
    }
  }
  return index;
}

// ---- mirugit annotations の解決 (I/O) ----

function resolveAnnotationsFile(mirugitRoot) {
  const sessionPath = join(mirugitRoot, "review-session.json");
  if (!existsSync(sessionPath)) return null;
  let token;
  try {
    token = JSON.parse(readFileSync(sessionPath, "utf8")).token;
  } catch {
    return null;
  }
  if (!token) return null;
  const annotationsDir = join(mirugitRoot, "annotations");
  if (!existsSync(annotationsDir)) return null;
  for (const repoId of readdirSync(annotationsDir)) {
    const candidate = join(annotationsDir, repoId, "sessions", `${token}.json`);
    if (existsSync(candidate)) return candidate;
  }
  return null;
}

// ---- digest ----

function runDigest(argv) {
  const flags = parseFlags(argv, {
    "--processed-until": "string",
    "--processed-until-line": "string",
    "--annotations": "string",
    "--no-annotations": "boolean",
    "--mirugit-root": "string",
    "--top-turns": "string",
    "--min-turn-ms": "string",
  });
  const jsonlArg = flags._?.[0];
  if (!jsonlArg) die("usage: reflect-extract digest <jsonl> [flags]");
  const jsonlPath = jsonlArg;
  if (!existsSync(jsonlPath)) die(`file not found: ${jsonlPath}`);

  if (flags["--processed-until"] != null && flags["--processed-until-line"] != null) {
    die("--processed-until と --processed-until-line は同時指定できません");
  }

  const text = readFileSync(jsonlPath, "utf8");
  const { events, eventLines, skipped } = parseJsonl(text);

  const uuidIndex = new Map();
  events.forEach((e, i) => {
    if (e.uuid) uuidIndex.set(e.uuid, i);
  });

  let boundaryIdx = null;
  let processedUntilLabel = "(none)";
  if (flags["--processed-until"] != null) {
    const prefix = flags["--processed-until"];
    const resolved = resolveUuidPrefix(events, prefix);
    if (resolved.error === "not-found") die(`--processed-until: uuid not found for prefix "${prefix}"`);
    if (resolved.error === "ambiguous") die(`--processed-until: uuid prefix "${prefix}" is ambiguous (${resolved.matches.length} matches)`);
    const r = resolveBoundaryIndex(events, eventLines, { uuid: resolved.event.uuid, uuidIndex });
    boundaryIdx = r.boundaryIdx;
    processedUntilLabel = shortUuid(resolved.event.uuid);
  } else if (flags["--processed-until-line"] != null) {
    const n = Number(flags["--processed-until-line"]);
    if (!Number.isInteger(n) || n < 1) die(`--processed-until-line must be a positive integer, got "${flags["--processed-until-line"]}"`);
    const r = resolveBoundaryIndex(events, eventLines, { line: n });
    boundaryIdx = r.boundaryIdx;
    processedUntilLabel = `line ${n}`;
  }

  const subagentIndex = buildSubagentIndex(jsonlPath);

  let annotationsText = null;
  let annotationsPath = null;
  if (!flags["--no-annotations"]) {
    if (flags["--annotations"]) {
      annotationsPath = flags["--annotations"];
      if (existsSync(annotationsPath)) annotationsText = readFileSync(annotationsPath, "utf8");
    } else {
      const mirugitRoot = flags["--mirugit-root"] ?? join(homedir(), ".mirugit");
      annotationsPath = resolveAnnotationsFile(mirugitRoot);
      if (annotationsPath) annotationsText = readFileSync(annotationsPath, "utf8");
    }
  }

  const topTurns = flags["--top-turns"] != null ? Number(flags["--top-turns"]) : DEFAULT_TOP_TURNS;
  const minTurnMs = flags["--min-turn-ms"] != null ? Number(flags["--min-turn-ms"]) : DEFAULT_MIN_TURN_MS;

  const output = buildDigest(events, {
    jsonlPath,
    skipped,
    boundaryIdx,
    processedUntilLabel,
    subagentIndex,
    annotationsText,
    annotationsPath,
    topTurns,
    minTurnMs,
    eventLines,
  });
  process.stdout.write(output + "\n");
}

// ---- context ----

function runContext(argv) {
  const flags = parseFlags(argv, {
    "--uuid": "string",
    "--line": "string",
    "--radius": "string",
    "--subagent": "string",
  });
  const jsonlArg = flags._?.[0];
  if (!jsonlArg) die("usage: reflect-extract context <jsonl> --uuid <uuid>|--line <N> [--radius N] [--subagent agent-id]");
  let jsonlPath = jsonlArg;

  if (flags["--uuid"] != null && flags["--line"] != null) {
    die("--uuid と --line は同時指定できません");
  }

  let { radius, clamped } = clampRadius(flags["--radius"] != null ? Number(flags["--radius"]) : DEFAULT_RADIUS);
  if (clamped) process.stderr.write(`radius clamped to ${radius}\n`);

  if (flags["--subagent"]) {
    const dir = join(dirname(jsonlPath), basename(jsonlPath, ".jsonl"), "subagents");
    let agentId = flags["--subagent"];
    if (!agentId.startsWith("agent-")) agentId = `agent-${agentId}`;
    jsonlPath = join(dir, `${agentId}.jsonl`);
  }
  if (!existsSync(jsonlPath)) die(`file not found: ${jsonlPath}`);

  const text = readFileSync(jsonlPath, "utf8");
  const { events, eventLines } = parseJsonl(text);
  const hasOrigin = sessionHasOrigin(events);
  const toolUseMap = buildToolUseMap(events);
  const toolResultIndex = buildToolResultIndex(events);

  let startIdx, endIdx, targetIdx = null, targetLabel = "(none)";
  if (flags["--uuid"]) {
    const resolved = resolveUuidPrefix(events, flags["--uuid"]);
    if (resolved.error === "not-found") die(`--uuid: not found for prefix "${flags["--uuid"]}"`);
    if (resolved.error === "ambiguous") die(`--uuid: prefix "${flags["--uuid"]}" is ambiguous (${resolved.matches.length} matches)`);
    targetIdx = events.indexOf(resolved.event);
    targetLabel = resolved.event.uuid;
    [startIdx, endIdx] = sliceContext(events, targetIdx, radius);
  } else if (flags["--line"] != null) {
    const n = Number(flags["--line"]);
    if (!Number.isInteger(n) || n < 1) die(`--line must be a positive integer, got "${flags["--line"]}"`);
    const resolved = resolveByLine(events, eventLines, n);
    if (resolved.error === "not-found") die(`--line: no event found at line ${n} (parse エラー行の可能性があります)`);
    targetIdx = resolved.index;
    targetLabel = `line ${n}`;
    [startIdx, endIdx] = sliceContext(events, targetIdx, radius);
  } else if (flags["--subagent"]) {
    [startIdx, endIdx] = sliceTail(events, radius);
  } else {
    die("--uuid か --line のどちらかが必要です (--subagent 省略時)");
  }

  process.stdout.write("# reflect-extract context\n");
  process.stdout.write(`session: ${jsonlPath}\n`);
  process.stdout.write(`target: ${targetLabel}\n`);
  process.stdout.write(`radius: ${radius}\n\n`);

  for (let i = startIdx; i <= endIdx; i++) {
    const e = events[i];
    const isTarget = targetIdx != null && i === targetIdx;
    const renderedLines = renderThin(e, { toolUseMap, toolResultIndex, isTarget, hasOrigin, line: eventLines[i] });
    for (const l of renderedLines) process.stdout.write(l + "\n");
  }
}

// ---- entry ----

function main() {
  const [, , sub, ...rest] = process.argv;
  if (sub === "digest") return runDigest(rest);
  if (sub === "context") return runContext(rest);
  die("usage: reflect-extract <digest|context> ...");
}

main();

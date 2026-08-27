// reflect-extract の判定・変換・整形ロジック。すべて純粋関数（CQS の Query 側）。
// I/O (ファイル読み・argv 解釈・stdout 出力) は reflect-extract.mjs 側の責務。

export const MAX_TEXT = 2000;
export const HEAD_CHARS = 1400;
export const TAIL_CHARS = 400;
export const DEFAULT_RADIUS = 5;
export const MAX_RADIUS = 10;
export const DEFAULT_TOP_TURNS = 3;
export const DEFAULT_MIN_TURN_MS = 120000;

// ---- 基礎ユーティリティ ----

/**
 * jsonl テキストをパースする。壊れた行は捨てて件数だけ返す（why: 1 行の破損で全体を落としたくない）。
 * eventLines[i] は events[i] の由来する行番号 (1 始まり)。--processed-until-line の境界特定に使う。
 */
export function parseJsonl(text) {
  const rawLines = text.split("\n");
  const events = [];
  const eventLines = [];
  let skipped = 0;
  rawLines.forEach((line, i) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    try {
      events.push(JSON.parse(trimmed));
      eventLines.push(i + 1);
    } catch {
      skipped++;
    }
  });
  return { events, eventLines, skipped };
}

export function shortUuid(uuid) {
  return uuid ? uuid.slice(0, 8) : "(none)";
}

export function oneLine(text) {
  return String(text ?? "").replace(/\s+/g, " ").trim();
}

/** 2000 文字超は先頭 1400 + 末尾 400 を残し中抜きする。ちょうど 2000 は無加工（境界値） */
export function elide(text, opts = {}) {
  const { head = HEAD_CHARS, tail = TAIL_CHARS, max = MAX_TEXT } = opts;
  const s = String(text ?? "");
  if (s.length <= max) return s;
  const elidedCount = s.length - head - tail;
  return `${s.slice(0, head)}\n... [${elidedCount} chars elided] ...\n${s.slice(s.length - tail)}`;
}

/** user/assistant の message.content から本文テキストを取り出す（string か block 配列） */
export function textOfContent(content) {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .filter((b) => b && b.type === "text")
      .map((b) => b.text ?? "")
      .join("\n");
  }
  return "";
}

function toolResultBlocks(content) {
  if (!Array.isArray(content)) return [];
  return content.filter((b) => b && b.type === "tool_result");
}

/** tool_result.content は string または block 配列。テキストとして取り出す */
export function tool_resultText(block) {
  const c = block?.content;
  if (typeof c === "string") return c;
  if (Array.isArray(c)) {
    return c.map((x) => (typeof x === "string" ? x : x?.text ?? JSON.stringify(x))).join("\n");
  }
  return "";
}

// ---- user イベントの分類 ----

/** セッション内に origin.kind 付きの user イベントが 1 件でもあるか（fallback 判定に使う） */
export function sessionHasOrigin(events) {
  return events.some((e) => e.type === "user" && e.origin && e.origin.kind);
}

/**
 * user イベントの種別を判定する。
 * 戻り値: "human" | "human-inferred" | "task-notification" | "meta" | "tool_result" | "other"
 */
export function classifyUserEvent(event, hasOrigin) {
  const content = event?.message?.content;
  const kind = event?.origin?.kind;
  if (kind === "human") return "human";
  if (kind === "task-notification") return "task-notification";
  if (event?.origin) return "other"; // 既知でない origin.kind

  const trBlocks = toolResultBlocks(content);
  if (trBlocks.length > 0) return "tool_result";

  if (event?.isMeta === true) return "meta";

  if (!hasOrigin && typeof content === "string") return "human-inferred";

  return "other";
}

// ---- tool_use / tool_result の突合 ----

/** assistant の tool_use block を id -> {name, input, uuid, ts} で索引化 */
export function buildToolUseMap(events) {
  const map = new Map();
  for (const e of events) {
    if (e.type !== "assistant") continue;
    const content = e.message?.content;
    if (!Array.isArray(content)) continue;
    for (const b of content) {
      if (b?.type === "tool_use" && b.id) {
        map.set(b.id, { name: b.name, input: b.input, uuid: e.uuid, ts: e.timestamp });
      }
    }
  }
  return map;
}

/** tool_use_id -> tool_result を運ぶ {event, block} の索引（最初の 1 件） */
export function buildToolResultIndex(events) {
  const map = new Map();
  for (const e of events) {
    if (e.type !== "user") continue;
    for (const b of toolResultBlocks(e.message?.content)) {
      if (b.tool_use_id && !map.has(b.tool_use_id)) {
        map.set(b.tool_use_id, { event: e, block: b });
      }
    }
  }
  return map;
}

// ---- エラークラスタ ----

const UUID_RE = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi;
const HEX_RE = /\b0x[0-9a-f]+\b/gi;
const PATH_RE = /\/[\w.\-]+(?:\/[\w.\-]+)+/g;
const NUM_RE = /\b\d+\b/g;

/** エラーメッセージをクラスタリング用キーへ正規化する */
export function normalizeErrorKey(msg) {
  let s = String(msg ?? "").toLowerCase();
  s = s.replace(UUID_RE, "⟨uuid⟩");
  s = s.replace(HEX_RE, "⟨hex⟩");
  s = s.replace(PATH_RE, "⟨path⟩");
  s = s.replace(NUM_RE, "⟨n⟩");
  s = s.replace(/\s+/g, " ").trim();
  return s.slice(0, 120);
}

/** denial (拒否) 判定に使う正規表現フォールバック */
const DENIAL_TEXT_RE = /doesn.t want to proceed|tool use was rejected/i;

/** is_error==true な tool_result のうち denial を除いたものを列挙する */
export function collectErrorEntries(events, toolUseMap) {
  const entries = [];
  for (const e of events) {
    if (e.type !== "user") continue;
    for (const b of toolResultBlocks(e.message?.content)) {
      if (b.is_error !== true) continue;
      if (e.toolDenialKind) continue; // 構造化 denial は除外
      const text = tool_resultText(b);
      if (DENIAL_TEXT_RE.test(text)) continue; // 文言 denial も除外
      const toolName = toolUseMap.get(b.tool_use_id)?.name ?? "(unknown)";
      entries.push({ uuid: e.uuid, toolName, message: text });
    }
  }
  return entries;
}

/** count>=2 のクラスタのみ、count 降順で返す */
export function clusterErrors(entries) {
  const clusters = new Map();
  for (const entry of entries) {
    const normKey = normalizeErrorKey(entry.message);
    const key = `${entry.toolName}|${normKey}`;
    if (!clusters.has(key)) {
      clusters.set(key, { key: normKey, toolName: entry.toolName, count: 0, sample: entry.message, uuids: [] });
    }
    const c = clusters.get(key);
    c.count++;
    c.uuids.push(entry.uuid);
  }
  return [...clusters.values()]
    .filter((c) => c.count >= 2)
    .sort((a, b) => b.count - a.count);
}

// ---- denials ----

/** Edit/Write/NotebookEdit は path のみに圧縮し、200 文字で切る */
export function compactToolInput(toolName, input) {
  let obj = input;
  if (toolName === "Edit" || toolName === "Write") {
    obj = { file_path: input?.file_path };
  } else if (toolName === "NotebookEdit") {
    obj = { notebook_path: input?.notebook_path };
  }
  const s = JSON.stringify(obj ?? {});
  return s.length > 200 ? s.slice(0, 200) : s;
}

/**
 * denial を collect する。toolDenialKind (構造化) を第一ソースに、
 * 文言マッチによる後方互換フォールバックを union し uuid で重複排除する。
 * AskUserQuestion の拒否はここに出さない（structured questions 側で扱う）。
 */
export function collectDenials(events, toolUseMap) {
  const seen = new Set();
  const out = [];
  for (const e of events) {
    if (e.type !== "user") continue;
    for (const b of toolResultBlocks(e.message?.content)) {
      const toolName = toolUseMap.get(b.tool_use_id)?.name;
      if (toolName === "AskUserQuestion") continue;
      const text = tool_resultText(b);
      const isStructured = e.toolDenialKind === "user-rejected" || e.toolDenialKind === "permission-rule";
      const isTextMatch = b.is_error === true && DENIAL_TEXT_RE.test(text);
      if (!isStructured && !isTextMatch) continue;
      if (seen.has(e.uuid)) continue;
      seen.add(e.uuid);
      out.push({
        uuid: e.uuid,
        kind: isStructured ? e.toolDenialKind : "user-rejected",
        toolName: toolName ?? "(unknown)",
        input: toolUseMap.get(b.tool_use_id)?.input,
      });
    }
  }
  return out;
}

// ---- structured questions (AskUserQuestion / auq-web) ----

/** AskUserQuestion の tool_use + 対応する回答/拒否をまとめる */
export function collectAskUserQuestion(events, toolUseMap, toolResultIndex) {
  const out = [];
  for (const e of events) {
    if (e.type !== "assistant") continue;
    const content = e.message?.content;
    if (!Array.isArray(content)) continue;
    for (const b of content) {
      if (b?.type !== "tool_use" || b.name !== "AskUserQuestion") continue;
      const result = toolResultIndex.get(b.id);
      const questions = b.input?.questions ?? [];
      const status = result?.block?.is_error === true ? "rejected" : "answered";
      const answerText = result ? oneLine(tool_resultText(result.block)) : "";
      out.push({
        uuid: e.uuid,
        tool: "AskUserQuestion",
        status,
        questions: questions.map((q) => ({
          question: q.question,
          options: (q.options ?? []).map((o) => o.label),
        })),
        answerUuid: result?.event?.uuid,
        answerText,
      });
    }
  }
  return out;
}

/** auq-web: Bash/BashOutput tool_result 内に混ざる `{"event":"answer",...}` 行を抽出する */
export function extractAuqWebAnswers(events) {
  const out = [];
  for (const e of events) {
    if (e.type !== "user") continue;
    for (const b of toolResultBlocks(e.message?.content)) {
      const text = tool_resultText(b);
      for (const line of text.split("\n")) {
        const t = line.trim();
        if (!t.startsWith('{"event":"answer"')) continue;
        if (!t.includes('"answers"')) continue;
        if (t.includes('"timedOut":true')) continue; // 未回答は捨てる
        out.push({ uuid: e.uuid, line: t });
      }
    }
  }
  return out;
}

/** AskUserQuestion + auq-web を統合した「structured questions」一覧 */
export function collectStructuredQA(events, toolUseMap, toolResultIndex) {
  const auq = collectAskUserQuestion(events, toolUseMap, toolResultIndex);
  const web = extractAuqWebAnswers(events).map((w) => ({
    uuid: w.uuid,
    tool: "auq-web",
    answerText: w.line,
  }));
  return { auq, web };
}

// ---- hook events ----

export function collectHookEvents(events) {
  const out = [];
  events.forEach((e, idx) => {
    if (e.type === "system" && e.subtype === "stop_hook_summary") {
      const hasErrors = Array.isArray(e.hookErrors) && e.hookErrors.length > 0;
      if (hasErrors || e.preventedContinuation === true) {
        out.push({
          idx,
          src: "stop_hook_summary",
          uuid: e.uuid,
          preventedContinuation: !!e.preventedContinuation,
          stopReason: e.stopReason ?? "",
          errors: oneLine(JSON.stringify(e.hookErrors ?? [])).slice(0, 200),
        });
      }
    } else if (e.type === "attachment" && e.attachment?.type === "hook_non_blocking_error") {
      const a = e.attachment;
      out.push({
        idx,
        src: "hook_non_blocking_error",
        uuid: e.uuid,
        hookName: a.hookName,
        hookEvent: a.hookEvent,
        exitCode: a.exitCode,
        stderr: oneLine(a.stderr ?? "").slice(0, 160),
      });
    } else if (e.type === "attachment" && e.attachment?.type === "hook_permission_decision") {
      const a = e.attachment;
      if (a.decision !== "allow") {
        out.push({
          idx,
          src: "hook_permission_decision",
          uuid: e.uuid,
          decision: a.decision,
          toolUseID: a.toolUseID,
        });
      }
    }
  });
  return out;
}

// ---- heavy turns ----

export function collectHeavyTurns(events, { topTurns = DEFAULT_TOP_TURNS, minTurnMs = DEFAULT_MIN_TURN_MS } = {}) {
  const turns = events.filter((e) => e.type === "system" && e.subtype === "turn_duration" && e.durationMs >= minTurnMs);
  return turns
    .sort((a, b) => b.durationMs - a.durationMs)
    .slice(0, topTurns)
    .map((e) => ({ uuid: e.uuid, ts: e.timestamp, durationMs: e.durationMs, messages: e.messageCount }));
}

// ---- skills / agent calls ----

export function collectSkillInvocations(events) {
  const counts = new Map();
  for (const e of events) {
    if (e.type !== "assistant") continue;
    for (const b of e.message?.content ?? []) {
      if (b?.type === "tool_use" && b.name === "Skill") {
        const skill = b.input?.skill ?? "(unknown)";
        const args = b.input?.args;
        const key = args ? `${skill} ${args}` : skill;
        counts.set(key, (counts.get(key) ?? 0) + 1);
      }
    }
  }
  return [...counts.entries()]
    .map(([key, n]) => {
      const [skill, args] = key.split(" ");
      return { skill, args, count: n };
    })
    .sort((a, b) => b.count - a.count);
}

export function collectAgentCallSummary(events) {
  const counts = new Map();
  for (const e of events) {
    if (e.type !== "assistant") continue;
    for (const b of e.message?.content ?? []) {
      if (b?.type === "tool_use" && b.name === "Agent") {
        const t = b.input?.subagent_type ?? "(unknown)";
        counts.set(t, (counts.get(t) ?? 0) + 1);
      }
    }
  }
  return [...counts.entries()].map(([type, count]) => ({ type, count })).sort((a, b) => b.count - a.count);
}

export function collectAttribution(events) {
  const counts = new Map();
  for (const e of events) {
    if (e.type !== "assistant" || !e.attributionSkill) continue;
    counts.set(e.attributionSkill, (counts.get(e.attributionSkill) ?? 0) + 1);
  }
  return [...counts.entries()].map(([skill, count]) => ({ skill, count })).sort((a, b) => b.count - a.count);
}

/**
 * Agent tool_use 全件を、subagent index (toolUseId -> {agentFile}) と
 * tool_result index を使って解決する。I/O (ディレクトリ走査) は呼び出し側が subagentIndex として渡す。
 */
export function collectAgentCalls(events, toolResultIndex, subagentIndex = new Map()) {
  const out = [];
  for (const e of events) {
    if (e.type !== "assistant") continue;
    for (const b of e.message?.content ?? []) {
      if (b?.type !== "tool_use" || b.name !== "Agent") continue;
      const result = toolResultIndex.get(b.id);
      const resultText = result ? oneLine(tool_resultText(result.block)).slice(0, 200) : null;
      out.push({
        uuid: e.uuid,
        agentType: b.input?.subagent_type ?? "(unknown)",
        description: b.input?.description ?? "",
        agentFile: subagentIndex.get(b.id)?.agentFile ?? "(not found)",
        result: resultText,
      });
    }
  }
  return out;
}

// ---- uuid prefix 解決 ----

/** uuid prefix からイベントを一意に特定する。0件/複数件はエラーを返す */
export function resolveUuidPrefix(events, prefix) {
  const matches = events.filter((e) => typeof e.uuid === "string" && e.uuid.startsWith(prefix));
  if (matches.length === 0) return { error: "not-found", matches: [] };
  if (matches.length > 1) return { error: "ambiguous", matches };
  return { event: matches[0] };
}

/**
 * jsonl の行番号 (1 始まり) からイベントを特定する。
 * uuid を持たない queue-operation 等も --line なら対象にできるようにするための解決関数。
 */
export function resolveByLine(events, eventLines, line) {
  const idx = eventLines.indexOf(line);
  if (idx === -1) return { error: "not-found" };
  return { event: events[idx], index: idx };
}

// ---- digest 組み立て ----

function formatUuidList(uuids, limit = 5) {
  return uuids.slice(0, limit).map(shortUuid).join(" ");
}

function buildUuidIndex(events) {
  const idx = new Map();
  events.forEach((e, i) => {
    if (e.uuid) idx.set(e.uuid, i);
  });
  return idx;
}

function processedMarker(uuid, boundaryIdx, uuidIndex) {
  if (boundaryIdx == null) return "";
  const i = uuidIndex.get(uuid);
  return i != null && i <= boundaryIdx ? " processed" : "";
}

/**
 * --processed-until (uuid) と --processed-until-line (行番号) の境界を events 配列上の
 * index (inclusive) へ解決する。両方指定は呼び出し側の責務でエラーにするため、ここでは
 * uuid を優先せず単純に "同時指定" を conflict として返す。
 */
export function resolveBoundaryIndex(events, eventLines, { uuid, line, uuidIndex } = {}) {
  if (uuid != null && line != null) return { error: "conflict" };
  if (uuid != null) {
    const idx = uuidIndex ? uuidIndex.get(uuid) : events.findIndex((e) => e.uuid === uuid);
    if (idx == null || idx === -1) return { error: "not-found" };
    return { boundaryIdx: idx };
  }
  if (line != null) {
    // eventLines は昇順なので、line 以下の最後の index を探す（超過なら全件、未満なら該当なし）
    let boundaryIdx = -1;
    for (let i = 0; i < eventLines.length; i++) {
      if (eventLines[i] <= line) boundaryIdx = i;
      else break;
    }
    return { boundaryIdx };
  }
  return { boundaryIdx: null };
}

function fmtDuration(ms) {
  const totalSec = Math.round(ms / 1000);
  const m = Math.floor(totalSec / 60);
  const s = totalSec % 60;
  return `${m}m ${s}s`;
}

/**
 * digest 全文を組み立てる純粋関数。events は既にパース済み。
 * subagentIndex / annotations は I/O 済みのデータとして渡す。
 */
export function buildDigest(events, opts) {
  const {
    jsonlPath,
    skipped,
    processedUntilLabel = "(none)",
    boundaryIdx = null,
    subagentIndex = new Map(),
    annotationsText = null,
    annotationsPath = null,
    topTurns = DEFAULT_TOP_TURNS,
    minTurnMs = DEFAULT_MIN_TURN_MS,
    // eventLines[i] = events[i] の由来する jsonl 行番号。queue-operation は uuid を持たないため
    // 表示・processed 判定に行番号を使う。呼び出し側 (テスト含む) が省略した場合は index+1 で代替する
    eventLines = events.map((_, i) => i + 1),
  } = opts;

  const lastWithUuid = [...events].reverse().find((e) => e.uuid);
  const boundaryUuid = lastWithUuid?.uuid ?? null;
  const uuidIndex = buildUuidIndex(events);

  const hasOrigin = sessionHasOrigin(events);
  const toolUseMap = buildToolUseMap(events);
  const toolResultIndex = buildToolResultIndex(events);

  const lines = [];
  lines.push("# reflect-extract digest");
  lines.push(`session: ${jsonlPath}`);
  lines.push(`events: ${events.length} (skipped: ${skipped})`);
  lines.push(`boundary: ${boundaryUuid ?? "(none)"}`);
  lines.push(`processed-until: ${processedUntilLabel}`);
  lines.push("");

  // session map
  // why custom-title を先に見る: セッション名は transcript に追記される制御行で、
  // CLI の /resume 一覧は customTitle -> aiTitle の順に最後の 1 件を採用する。
  // /rename や rename hook で名前が付いたセッションでは ai-title が生成されないため、
  // ai-title だけを見ると title が (unknown) に落ちる。
  // why jsonl から読む: 名前を取る公式手段 (statusline の session_name / Agent SDK の
  // get_session_info / claude agents --json) はいずれも稼働中セッションか SDK 導入を
  // 要求するが、reflect の対象は終了済みセッションの transcript。このエントリ形式は
  // Claude Code の内部仕様でバージョン間非互換だと公式が明言しているので、読めなければ
  // (unknown) に落として digest 全体は壊さない
  const lastTitle = (type, key) => {
    const hits = events.filter((e) => e.type === type && e[key]);
    return hits.length > 0 ? hits[hits.length - 1][key] : null;
  };
  const title = lastTitle("custom-title", "customTitle")
    ?? lastTitle("ai-title", "aiTitle")
    ?? "(unknown)";
  const timestamped = events.filter((e) => e.timestamp);
  const first = timestamped[0]?.timestamp ?? "(none)";
  const last = timestamped[timestamped.length - 1]?.timestamp ?? "(none)";
  let duration = "(unknown)";
  if (timestamped.length >= 2) {
    const ms = new Date(last).getTime() - new Date(first).getTime();
    if (!Number.isNaN(ms) && ms >= 0) duration = fmtDuration(ms);
  }
  const userEvents = events.filter((e) => e.type === "user");
  const humanCount = userEvents.filter((e) => {
    const k = classifyUserEvent(e, hasOrigin);
    return k === "human" || k === "human-inferred";
  }).length;
  const queuedCount = events.filter((e) => e.type === "queue-operation" && e.operation === "enqueue").length;
  const assistantTextCount = events.filter(
    (e) => e.type === "assistant" && Array.isArray(e.message?.content) && e.message.content.some((b) => b?.type === "text")
  ).length;
  const awaySummaries = events.filter((e) => e.type === "system" && e.subtype === "away_summary");

  lines.push("## session map");
  lines.push(`title: ${title}`);
  lines.push(`first event: ${first}`);
  lines.push(`last event: ${last}`);
  lines.push(`duration: ${duration}`);
  lines.push(`user turns (human): ${humanCount} (+queued: ${queuedCount})`);
  lines.push(`assistant turns (with text): ${assistantTextCount}`);
  if (awaySummaries.length > 0) {
    lines.push("away summaries:");
    for (const a of awaySummaries) lines.push(`- ${a.content}`);
  } else {
    lines.push("away summaries: (none)");
  }
  lines.push("");

  // skills
  const skillInvocations = collectSkillInvocations(events);
  const agentCallSummary = collectAgentCallSummary(events);
  const attribution = collectAttribution(events);
  lines.push("## skills");
  lines.push("skill invocations:");
  if (skillInvocations.length === 0) {
    lines.push("(none)");
  } else {
    for (const s of skillInvocations) {
      lines.push(`  ${s.count}  ${s.skill}${s.args ? ` (args: ${s.args})` : ""}`);
    }
  }
  lines.push("agent calls:");
  if (agentCallSummary.length === 0) {
    lines.push("(none)");
  } else {
    for (const a of agentCallSummary) lines.push(`  ${a.count}  ${a.type}`);
  }
  lines.push("attribution:");
  if (attribution.length === 0) {
    lines.push("(none)");
  } else {
    for (const a of attribution) lines.push(`  ${a.count}  ${a.skill}`);
  }
  lines.push("");

  // user messages (human 発話 + queue-operation の enqueue を時系列でマージする。
  // why: ターン実行中の割り込み発話は user イベントにならず queue-operation として記録されるため、
  // ここに出さないと訂正シグナルの筆頭が digest から漏れる)
  lines.push("## user messages");
  let userNum = 0;
  let taskNotifCount = 0;
  const userBody = [];
  events.forEach((e, i) => {
    if (e.type === "user") {
      const kind = classifyUserEvent(e, hasOrigin);
      if (kind === "task-notification") {
        taskNotifCount++;
        return;
      }
      if (kind !== "human" && kind !== "human-inferred") return;
      userNum++;
      const originLabel = kind === "human-inferred" ? "human=inferred" : "human";
      const processed = processedMarker(e.uuid, boundaryIdx, uuidIndex);
      userBody.push(
        `[U${userNum}] uuid=${shortUuid(e.uuid)} ts=${e.timestamp} origin=${originLabel}${processed}\n${elide(textOfContent(e.message?.content))}`
      );
    } else if (e.type === "queue-operation" && e.operation === "enqueue") {
      userNum++;
      const processed = i <= (boundaryIdx ?? -1) ? " processed" : "";
      userBody.push(
        `[U${userNum}] line=${eventLines[i]} ts=${e.timestamp} origin=queued${processed}\n${elide(e.content ?? "")}`
      );
    }
  });
  if (userBody.length === 0) {
    lines.push("(none)");
  } else {
    lines.push(userBody.join("\n\n"));
  }
  lines.push(`task-notifications: ${taskNotifCount} (excluded)`);
  lines.push("");

  // interruptions
  lines.push("## interruptions");
  let intNum = 0;
  const intBody = [];
  for (const e of userEvents) {
    if (classifyUserEvent(e, hasOrigin) !== "meta") continue;
    intNum++;
    const text = textOfContent(e.message?.content);
    const firstLine = text.split("\n")[0] ?? "";
    intBody.push(`[I${intNum}] uuid=${shortUuid(e.uuid)} ts=${e.timestamp} ${firstLine}`);
  }
  lines.push(intBody.length === 0 ? "(none)" : intBody.join("\n"));
  lines.push("");

  // structured questions
  const { auq, web } = collectStructuredQA(events, toolUseMap, toolResultIndex);
  lines.push("## structured questions");
  const qaBody = [];
  let qNum = 0;
  for (const q of auq) {
    qNum++;
    const head = `[Q${qNum}] uuid=${shortUuid(q.uuid)} tool=AskUserQuestion status=${q.status}`;
    const qLines = q.questions.map(
      (qq) => `  Q: ${qq.question}${qq.options.length ? ` options: ${qq.options.join(" | ")}` : ""}`
    );
    const aLine = `  A: uuid=${shortUuid(q.answerUuid)} ${q.answerText}`;
    qaBody.push([head, ...qLines, aLine].join("\n"));
  }
  for (const w of web) {
    qNum++;
    qaBody.push(`[Q${qNum}] uuid=${shortUuid(w.uuid)} tool=auq-web\n  A: ${w.answerText}`);
  }
  lines.push(qaBody.length === 0 ? "(none)" : qaBody.join("\n"));
  lines.push("");

  // denials
  const denials = collectDenials(events, toolUseMap);
  lines.push("## denials");
  if (denials.length === 0) {
    lines.push("(none)");
  } else {
    denials.forEach((d, i) => {
      const processed = processedMarker(d.uuid, boundaryIdx, uuidIndex);
      const compact = compactToolInput(d.toolName, d.input);
      lines.push(`[D${i + 1}] uuid=${shortUuid(d.uuid)} kind=${d.kind} tool=${d.toolName} input=${compact}${processed}`);
    });
  }
  lines.push("");

  // error clusters
  const errorEntries = collectErrorEntries(events, toolUseMap);
  const clusters = clusterErrors(errorEntries);
  lines.push("## error clusters");
  if (clusters.length === 0) {
    lines.push("(none)");
  } else {
    clusters.forEach((c, i) => {
      const allProcessed = boundaryIdx != null && c.uuids.every((u) => (uuidIndex.get(u) ?? Infinity) <= boundaryIdx);
      lines.push(`[E${i + 1}] count=${c.count} tool=${c.toolName} key="${c.key}"`);
      lines.push(`  sample: ${oneLine(c.sample).slice(0, 160)}`);
      lines.push(`  at: ${formatUuidList(c.uuids)}${allProcessed ? " processed" : ""}`);
    });
  }
  lines.push("");

  // hook events
  const hookEvents = collectHookEvents(events);
  lines.push("## hook events");
  if (hookEvents.length === 0) {
    lines.push("(none)");
  } else {
    hookEvents.forEach((h, i) => {
      if (h.src === "stop_hook_summary") {
        lines.push(
          `[H${i + 1}] uuid=${shortUuid(h.uuid)} src=stop_hook_summary preventedContinuation=${h.preventedContinuation} stopReason="${h.stopReason}" errors=${h.errors}`
        );
      } else if (h.src === "hook_non_blocking_error") {
        lines.push(
          `[H${i + 1}] uuid=${shortUuid(h.uuid)} src=hook_non_blocking_error hook=${h.hookName}@${h.hookEvent} exit=${h.exitCode} stderr="${h.stderr}"`
        );
      } else {
        lines.push(`[H${i + 1}] uuid=${shortUuid(h.uuid)} src=hook_permission_decision decision=${h.decision} tool_use=${h.toolUseID}`);
      }
    });
  }
  lines.push("");

  // heavy turns
  const heavy = collectHeavyTurns(events, { topTurns, minTurnMs });
  lines.push("## heavy turns");
  if (heavy.length === 0) {
    lines.push("(none)");
  } else {
    heavy.forEach((t, i) => {
      lines.push(`[T${i + 1}] uuid=${shortUuid(t.uuid)} ts=${t.ts} durationMs=${t.durationMs} messages=${t.messages}`);
    });
  }
  lines.push("");

  // agent calls
  const agentCalls = collectAgentCalls(events, toolResultIndex, subagentIndex);
  lines.push("## agent calls");
  if (agentCalls.length === 0) {
    lines.push("(none)");
  } else {
    agentCalls.forEach((a, i) => {
      lines.push(`[A${i + 1}] uuid=${shortUuid(a.uuid)} type=${a.agentType} desc="${a.description}" agent-file=${a.agentFile}`);
      lines.push(`  result: ${a.result ?? "(no result)"}`);
    });
  }
  lines.push("");

  // mirugit annotations
  lines.push("## mirugit annotations");
  lines.push(renderAnnotationsSection(annotationsText, annotationsPath));

  return lines.join("\n");
}

/** mirugit annotation json (テキスト) を整形する。パース不能/null なら "(no annotation file)" */
export function renderAnnotationsSection(annotationsText) {
  if (!annotationsText) return "(no annotation file)";
  let data;
  try {
    data = JSON.parse(annotationsText);
  } catch {
    return "(no annotation file)";
  }
  const anns = (data.annotations ?? []).filter((a) => a.author === "user");
  if (anns.length === 0) return "(no annotation file)";
  const byId = new Map((data.annotations ?? []).map((a) => [a.id, a]));
  const out = [];
  for (const a of anns) {
    const target = a.target ?? {};
    let loc = "file";
    if (target.type === "line") loc = String(target.line);
    else if (target.type === "range") loc = `${target.startLine}-${target.endLine}`;
    out.push(`- ${a.file}:${loc} — ${oneLine(a.body).slice(0, 200)}`);
    if (a.replyTo) {
      const parent = byId.get(a.replyTo);
      if (parent) out.push(`    (reply to claude: ${oneLine(parent.body).slice(0, 120)})`);
    }
  }
  return out.join("\n");
}

// ---- context サブコマンド ----

function conversationIndices(events) {
  const idxs = [];
  events.forEach((e, i) => {
    if (e.type === "user" || e.type === "assistant") idxs.push(i);
  });
  return idxs;
}

/** radius を [0, MAX_RADIUS] にクランプする。超過時は clamped フラグを立てる */
export function clampRadius(radius) {
  if (radius > MAX_RADIUS) return { radius: MAX_RADIUS, clamped: true };
  return { radius, clamped: false };
}

/**
 * targetIdx (overall index) を中心に、前後 radius 件の会話イベント範囲を切り出す。
 * 戻り値は [startIdx, endIdx] (overall index, inclusive)。
 */
export function sliceContext(events, targetIdx, radius) {
  const convIdxs = conversationIndices(events);
  if (convIdxs.length === 0) return [0, events.length - 1];
  let pos = convIdxs.indexOf(targetIdx);
  if (pos === -1) {
    pos = convIdxs.findIndex((i) => i > targetIdx);
    if (pos === -1) pos = convIdxs.length; // target は末尾より後
  }
  const lowPos = Math.max(0, pos - radius);
  const highPos = Math.min(convIdxs.length - 1, pos === convIdxs.length ? convIdxs.length - 1 : pos + radius);
  const startOverall = convIdxs[lowPos] ?? 0;
  const endOverall = convIdxs[highPos] ?? events.length - 1;
  return [Math.min(startOverall, targetIdx), Math.max(endOverall, targetIdx)];
}

/** --subagent かつ --uuid 省略時: 末尾 2*radius 件の会話イベント範囲 */
export function sliceTail(events, radius) {
  const convIdxs = conversationIndices(events);
  if (convIdxs.length === 0) return [0, events.length - 1];
  const n = radius * 2;
  const startPos = Math.max(0, convIdxs.length - n);
  return [convIdxs[startPos], events.length - 1];
}

function compactJson(value, limit = 200) {
  const s = JSON.stringify(value ?? {});
  return s.length > limit ? s.slice(0, limit) : s;
}

/**
 * 1 イベントを薄切り表示する行の配列を返す（複数行/複数ブロックのことがある）。
 * thinking block は行自体を出さない。
 */
export function renderThin(event, ctx) {
  const { toolUseMap, toolResultIndex, isTarget } = ctx;
  const mark = isTarget ? " <<< target" : "";
  const out = [];

  if (event.type === "user") {
    const content = event.message?.content;
    const trBlocks = toolResultBlocks(content);
    if (trBlocks.length > 0) {
      for (const b of trBlocks) {
        const toolName = toolUseMap.get(b.tool_use_id)?.name ?? "(unknown)";
        const errSuffix = b.is_error === true ? " (error)" : "";
        out.push(`--- [tool_result ${toolName}] uuid=${shortUuid(event.uuid)}${mark}`);
        out.push(`${oneLine(tool_resultText(b)).slice(0, 200)}${errSuffix}`);
      }
      return out;
    }
    const hasOrigin = ctx.hasOrigin ?? false;
    const kind = classifyUserEvent(event, hasOrigin);
    const label = kind === "human-inferred" ? "human" : kind === "human" ? "human" : kind === "task-notification" ? "task-notification" : "meta";
    out.push(`--- [user ${label}] uuid=${shortUuid(event.uuid)} ts=${event.timestamp}${mark}`);
    out.push(elide(textOfContent(content)));
    return out;
  }

  if (event.type === "assistant") {
    const content = event.message?.content;
    if (!Array.isArray(content)) return out;
    for (const b of content) {
      if (b?.type === "thinking") continue; // why: thinking は行自体を出さない仕様
      if (b?.type === "text") {
        out.push(`--- [assistant] uuid=${shortUuid(event.uuid)} ts=${event.timestamp}${mark}`);
        out.push(elide(b.text ?? ""));
      } else if (b?.type === "tool_use") {
        out.push(`--- [tool_use ${b.name}] uuid=${shortUuid(event.uuid)}${mark}`);
        out.push(compactJson(b.input));
      }
    }
    return out;
  }

  if (event.type === "queue-operation") {
    // why: 割り込み発話は uuid を持たない queue-operation として記録されるため line で表示する
    out.push(`--- [queue-operation ${event.operation}] line=${ctx.line ?? "(unknown)"} ts=${event.timestamp}${mark}`);
    if (event.operation === "enqueue") out.push(elide(event.content ?? ""));
    return out;
  }

  if (event.type === "system") {
    out.push(
      `--- [system ${event.subtype}] uuid=${shortUuid(event.uuid)}${mark} ${compactJson({
        durationMs: event.durationMs,
        messageCount: event.messageCount,
        content: event.content,
        preventedContinuation: event.preventedContinuation,
        stopReason: event.stopReason,
      })}`
    );
    return out;
  }

  if (event.type === "attachment" && event.attachment?.type !== "hook_success") {
    out.push(`--- [attachment ${event.attachment?.type}] uuid=${shortUuid(event.uuid)}${mark} ${compactJson(event.attachment)}`);
    return out;
  }

  return out; // hook_success など、その他は無視
}

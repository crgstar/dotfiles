import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

import {
  parseJsonl,
  classifyUserEvent,
  sessionHasOrigin,
  elide,
  normalizeErrorKey,
  clusterErrors,
  collectErrorEntries,
  collectDenials,
  collectStructuredQA,
  extractAuqWebAnswers,
  buildToolUseMap,
  buildToolResultIndex,
  resolveUuidPrefix,
  resolveByLine,
  resolveBoundaryIndex,
  clampRadius,
  sliceContext,
  buildDigest,
  renderAnnotationsSection,
  renderThin,
  MAX_RADIUS,
} from "./lib.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const fixturePath = join(__dirname, "fixtures", "basic.jsonl");

// ---- parseJsonl ----

test("parseJsonl: 空文字は 0 件・0 スキップ", () => {
  const { events, skipped } = parseJsonl("");
  assert.equal(events.length, 0);
  assert.equal(skipped, 0);
});

test("parseJsonl: パース不能行が混在しても件数だけカウントしてスキップする", () => {
  const text = '{"a":1}\nnot json\n{"a":2}\n';
  const { events, skipped, eventLines } = parseJsonl(text);
  assert.equal(events.length, 2);
  assert.equal(skipped, 1);
  assert.deepEqual(eventLines, [1, 3]); // 由来する行番号 (1 始まり) がずれずに記録される
});

test("parseJsonl: 空行は無視されるが skipped にはカウントしない", () => {
  const text = '{"a":1}\n\n\n{"a":2}\n';
  const { events, skipped } = parseJsonl(text);
  assert.equal(events.length, 2);
  assert.equal(skipped, 0);
});

// ---- classifyUserEvent ----

test("classifyUserEvent: origin.kind human は human", () => {
  const e = { origin: { kind: "human" }, message: { content: "hi" } };
  assert.equal(classifyUserEvent(e, true), "human");
});

test("classifyUserEvent: origin.kind task-notification は区別される", () => {
  const e = { origin: { kind: "task-notification" }, message: { content: "done" } };
  assert.equal(classifyUserEvent(e, true), "task-notification");
});

test("classifyUserEvent: origin 欠落 + tool_result block は tool_result", () => {
  const e = { message: { content: [{ type: "tool_result", tool_use_id: "x", content: "ok" }] } };
  assert.equal(classifyUserEvent(e, true), "tool_result");
});

test("classifyUserEvent: origin 欠落 + isMeta + text は meta (割り込み等)", () => {
  const e = { isMeta: true, message: { content: "[Request interrupted by user for tool use]" } };
  assert.equal(classifyUserEvent(e, true), "meta");
});

test("classifyUserEvent: 旧 transcript (origin 皆無) では string content を human-inferred とみなす", () => {
  const e = { message: { content: "こんにちは" } };
  assert.equal(classifyUserEvent(e, false), "human-inferred");
});

test("classifyUserEvent: セッション内に origin 付きが 1 件でもあれば fallback しない", () => {
  const e = { message: { content: "こんにちは" } };
  assert.equal(classifyUserEvent(e, true), "other");
});

test("sessionHasOrigin: origin.kind を持つ user が 1 件も無ければ false", () => {
  const events = [{ type: "user", message: { content: "a" } }, { type: "assistant" }];
  assert.equal(sessionHasOrigin(events), false);
});

// ---- elide ----

test("elide: ちょうど 2000 文字は無加工", () => {
  const s = "x".repeat(2000);
  assert.equal(elide(s), s);
});

test("elide: 2001 文字は中抜きされ、先頭1400+末尾400+区切りになる", () => {
  const s = "x".repeat(2001);
  const out = elide(s);
  assert.ok(out.includes("[201 chars elided]"));
  assert.equal(out.split("\n")[0].length, 1400);
});

// ---- normalizeErrorKey ----

test("normalizeErrorKey: uuid/path/hex/数値を正規化してキーを揃える", () => {
  const a = normalizeErrorKey("Error at /Users/a/file0.txt (session cafebabe-1234-4abc-8def-0123456789ab, code 0xA, retry 0)");
  const b = normalizeErrorKey("Error at /Users/b/file9.txt (session 11111111-2222-4333-8444-555555555555, code 0xB, retry 9)");
  assert.equal(a, b);
});

test("normalizeErrorKey: 120 文字で切る", () => {
  const long = "e".repeat(300);
  assert.equal(normalizeErrorKey(long).length, 120);
});

// ---- clusterErrors / collectErrorEntries ----

test("clusterErrors: count>=2 のみ、降順で返す", () => {
  const entries = [
    { uuid: "u1", toolName: "Read", message: "not found /a/1" },
    { uuid: "u2", toolName: "Read", message: "not found /b/2" },
    { uuid: "u3", toolName: "Bash", message: "single error only" },
  ];
  const clusters = clusterErrors(entries);
  assert.equal(clusters.length, 1);
  assert.equal(clusters[0].count, 2);
  assert.equal(clusters[0].toolName, "Read");
});

test("collectErrorEntries: denial (toolDenialKind 付き) は除外する", () => {
  const toolUseMap = new Map([["t1", { name: "Bash" }]]);
  const events = [
    {
      type: "user",
      uuid: "u1",
      toolDenialKind: "user-rejected",
      message: { content: [{ type: "tool_result", tool_use_id: "t1", is_error: true, content: "denied" }] },
    },
    {
      type: "user",
      uuid: "u2",
      message: { content: [{ type: "tool_result", tool_use_id: "t1", is_error: true, content: "real error" }] },
    },
  ];
  const entries = collectErrorEntries(events, toolUseMap);
  assert.equal(entries.length, 1);
  assert.equal(entries[0].uuid, "u2");
});

// ---- collectDenials ----

test("collectDenials: 構造化denialと文言denialをunionし、AskUserQuestionは除外・uuid重複排除する", () => {
  const toolUseMap = new Map([
    ["t1", { name: "Bash", input: { command: "rm -rf /" } }],
    ["t2", { name: "AskUserQuestion", input: {} }],
    ["t3", { name: "Edit", input: { file_path: "/a.txt" } }],
  ]);
  const events = [
    { type: "user", uuid: "u1", toolDenialKind: "user-rejected", message: { content: [{ type: "tool_result", tool_use_id: "t1", is_error: true, content: "The user doesn't want to proceed" }] } },
    { type: "user", uuid: "u2", message: { content: [{ type: "tool_result", tool_use_id: "t2", is_error: true, content: "The user doesn't want to proceed with this tool use." }] } },
    { type: "user", uuid: "u3", message: { content: [{ type: "tool_result", tool_use_id: "t3", is_error: true, content: "tool use was rejected" }] } },
  ];
  const denials = collectDenials(events, toolUseMap);
  assert.equal(denials.length, 2); // AskUserQuestion (u2) は除外
  assert.deepEqual(denials.map((d) => d.uuid).sort(), ["u1", "u3"]);
});

test("collectDenials: 同一uuidに構造化+文言両方一致しても1件のみ (重複排除)", () => {
  const toolUseMap = new Map([["t1", { name: "Bash", input: {} }]]);
  const events = [
    { type: "user", uuid: "u1", toolDenialKind: "permission-rule", message: { content: [{ type: "tool_result", tool_use_id: "t1", is_error: true, content: "tool use was rejected" }] } },
  ];
  const denials = collectDenials(events, toolUseMap);
  assert.equal(denials.length, 1);
  assert.equal(denials[0].kind, "permission-rule");
});

// ---- structured QA ----

test("collectStructuredQA: AskUserQuestion 複数質問をまとめて1エントリにする", () => {
  const toolUseMap = new Map();
  const events = [
    {
      type: "assistant",
      uuid: "a1",
      message: {
        content: [
          {
            type: "tool_use",
            id: "t1",
            name: "AskUserQuestion",
            input: { questions: [{ question: "Q1?", options: [{ label: "A" }] }, { question: "Q2?", options: [{ label: "B" }] }] },
          },
        ],
      },
    },
    { type: "user", uuid: "u1", message: { content: [{ type: "tool_result", tool_use_id: "t1", is_error: false, content: '"Q1?"="A","Q2?"="B"' }] } },
  ];
  const toolResultIndex = buildToolResultIndex(events);
  const { auq } = collectStructuredQA(events, toolUseMap, toolResultIndex);
  assert.equal(auq.length, 1);
  assert.equal(auq[0].questions.length, 2);
  assert.equal(auq[0].status, "answered");
});

test("extractAuqWebAnswers: timedOut な行は除外する", () => {
  const events = [
    {
      type: "user",
      uuid: "u1",
      message: {
        content: [
          {
            type: "tool_result",
            tool_use_id: "t1",
            content: 'log noise\n{"event":"answer","answers":{"x":1},"timedOut":false}\n{"event":"answer","answers":{},"timedOut":true}',
          },
        ],
      },
    },
  ];
  const answers = extractAuqWebAnswers(events);
  assert.equal(answers.length, 1);
  assert.ok(answers[0].line.includes('"x":1'));
});

// ---- resolveUuidPrefix ----

test("resolveUuidPrefix: 一意なら event を返す", () => {
  const events = [{ uuid: "abcdef12-0000-0000-0000-000000000000" }, { uuid: "11111111-0000-0000-0000-000000000000" }];
  const r = resolveUuidPrefix(events, "abcdef12");
  assert.equal(r.event.uuid, "abcdef12-0000-0000-0000-000000000000");
});

test("resolveUuidPrefix: 見つからなければ not-found", () => {
  const events = [{ uuid: "abcdef12-0000-0000-0000-000000000000" }];
  const r = resolveUuidPrefix(events, "zzzzzzzz");
  assert.equal(r.error, "not-found");
});

test("resolveUuidPrefix: 複数一致は ambiguous", () => {
  const events = [{ uuid: "abcdef12-0000-0000-0000-000000000000" }, { uuid: "abcdef34-0000-0000-0000-000000000000" }];
  const r = resolveUuidPrefix(events, "abcdef");
  assert.equal(r.error, "ambiguous");
  assert.equal(r.matches.length, 2);
});

// ---- resolveBoundaryIndex (--processed-until / --processed-until-line) ----

test("resolveBoundaryIndex: uuid 指定でその index を返す", () => {
  const events = [{ uuid: "a" }, { uuid: "b" }, { uuid: "c" }];
  const uuidIndex = new Map([["a", 0], ["b", 1], ["c", 2]]);
  const r = resolveBoundaryIndex(events, [1, 2, 3], { uuid: "b", uuidIndex });
  assert.equal(r.boundaryIdx, 1);
});

test("resolveBoundaryIndex: 行番号指定でその行以下の最後の event index を返す", () => {
  const events = [{ uuid: "a" }, { uuid: "b" }, { uuid: "c" }];
  const eventLines = [1, 5, 9]; // 行3などパース不能行がある想定
  const r = resolveBoundaryIndex(events, eventLines, { line: 5 });
  assert.equal(r.boundaryIdx, 1);
});

test("resolveBoundaryIndex: 行番号が総行数を超えていても正常 (全件 processed)", () => {
  const events = [{ uuid: "a" }, { uuid: "b" }];
  const eventLines = [1, 2];
  const r = resolveBoundaryIndex(events, eventLines, { line: 9999 });
  assert.equal(r.boundaryIdx, 1); // 最後の index = 全件 processed
});

test("resolveBoundaryIndex: 行番号が最初のイベントより前なら該当なし (-1)", () => {
  const events = [{ uuid: "a" }, { uuid: "b" }];
  const eventLines = [5, 9];
  const r = resolveBoundaryIndex(events, eventLines, { line: 1 });
  assert.equal(r.boundaryIdx, -1);
});

test("resolveBoundaryIndex: uuid と line の同時指定は conflict", () => {
  const r = resolveBoundaryIndex([], [], { uuid: "a", line: 1 });
  assert.equal(r.error, "conflict");
});

// ---- clampRadius ----

test("clampRadius: 上限以下ならそのまま", () => {
  assert.deepEqual(clampRadius(10), { radius: 10, clamped: false });
  assert.deepEqual(clampRadius(3), { radius: 3, clamped: false });
});

test("clampRadius: 上限超過は 10 に丸めて clamped=true", () => {
  assert.deepEqual(clampRadius(20), { radius: MAX_RADIUS, clamped: true });
});

// ---- sliceContext ----

test("sliceContext: 会話イベントのみを radius 単位で数え前後を切り出す", () => {
  // index: 0=user 1=assistant 2=user 3=assistant(target) 4=user 5=assistant 6=user
  const events = [
    { type: "user" }, { type: "assistant" }, { type: "user" }, { type: "assistant" },
    { type: "user" }, { type: "assistant" }, { type: "user" },
  ];
  const [start, end] = sliceContext(events, 3, 1);
  assert.equal(start, 2);
  assert.equal(end, 4);
});

test("sliceContext: system/attachment イベントも範囲内なら含める", () => {
  const events = [
    { type: "user" }, { type: "system" }, { type: "assistant" }, { type: "user" },
  ];
  const [start, end] = sliceContext(events, 2, 1);
  assert.equal(start, 0); // radius=1 前方は index0 (user)
  assert.equal(end, 3);
});

// ---- renderAnnotationsSection ----

test("renderAnnotationsSection: null/パース不能は (no annotation file)", () => {
  assert.equal(renderAnnotationsSection(null), "(no annotation file)");
  assert.equal(renderAnnotationsSection("not json"), "(no annotation file)");
});

test("renderAnnotationsSection: author=user のみ抽出し replyTo を併記する", () => {
  const json = JSON.stringify({
    annotations: [
      { id: "a1", author: "claude", file: "x.js", target: { type: "line", line: 5 }, body: "claude comment" },
      { id: "a2", author: "user", file: "x.js", target: { type: "line", line: 5 }, body: "user reply", replyTo: "a1" },
      { id: "a3", author: "user", file: "y.js", target: { type: "range", startLine: 1, endLine: 3 }, body: "range comment" },
    ],
  });
  const out = renderAnnotationsSection(json);
  assert.ok(out.includes("x.js:5 — user reply"));
  assert.ok(out.includes("(reply to claude: claude comment)"));
  assert.ok(out.includes("y.js:1-3 — range comment"));
});

// ---- buildDigest 統合テスト (fixture 全種を対象に、各セクションの期待を固定する) ----

test("buildDigest: fixture 全シグナルの主要セクションを検証する", () => {
  const text = readFileSync(fixturePath, "utf8");
  const { events, skipped } = parseJsonl(text);
  assert.equal(skipped, 1); // fixture に混ぜた不正行

  const out = buildDigest(events, { jsonlPath: fixturePath, skipped });

  assert.ok(out.includes("title: reflect-extract fixture session")); // 最後の ai-title が採用される
  assert.ok(out.includes("task-notifications: 1 (excluded)"));
  assert.ok(out.includes("[I1]") && out.includes("[Request interrupted by user for tool use]"));
  assert.ok(out.includes("tool=AskUserQuestion status=answered"));
  assert.ok(out.includes("tool=AskUserQuestion status=rejected"));
  assert.ok(out.includes("tool=auq-web"));
  assert.ok(!out.includes('"timedOut":true')); // 未回答の auq-web 行は出ない
  assert.ok(out.includes("[D1]") && out.includes("[D2]") && !out.includes("[D3]")); // denial は2件 (AUQ拒否は含まない)
  assert.ok(out.includes('count=3 tool=Read')); // 同一エラー3回のクラスタ
  assert.ok(!out.match(/count=1/)); // 単発エラーはクラスタに出ない
  assert.ok(out.includes("src=hook_non_blocking_error"));
  assert.ok(out.includes("src=hook_permission_decision decision=deny"));
  assert.ok(!out.includes("decision=allow")); // allow はノイズなので出ない
  assert.ok(out.includes("src=stop_hook_summary"));
  assert.ok(out.includes("durationMs=237917")); // heavy turn
  assert.ok(!out.includes("durationMs=4000")); // 軽い turn は出ない
  assert.ok(out.includes("type=sanitize-auditor"));
  assert.ok(out.includes("  1  code-review (args: high --fix)"));
  assert.ok(out.includes("  1  sanitize-auditor"));
  assert.ok(out.includes("  1  reflect"));
  assert.ok(out.includes("(no annotation file)"));
});

test("buildDigest: --processed-until-line 相当の boundaryIdx で processed マーカーが付く", () => {
  const text = readFileSync(fixturePath, "utf8");
  const { events, skipped } = parseJsonl(text);
  // 先頭の human 発話 (U1) だけが processed になるよう、そのイベント index を境界にする
  const boundaryIdx = events.findIndex((e) => e.type === "user" && e.origin?.kind === "human");
  const out = buildDigest(events, { jsonlPath: fixturePath, skipped, boundaryIdx, processedUntilLabel: "line 1" });
  assert.ok(out.includes("processed-until: line 1"));
  const u1Line = out.split("\n").find((l) => l.startsWith("[U1]"));
  assert.ok(u1Line.includes("processed"));
  const u2Line = out.split("\n").find((l) => l.startsWith("[U2]"));
  assert.ok(!u2Line.includes("processed"));
});

// ---- queue-operation (割り込み発話は uuid を持たず line 識別になる) ----

test("classifyUserEvent は queue-operation を扱わない (別経路で digest に載せる)", () => {
  // queue-operation は type が "user" ではないため、そもそも classifyUserEvent の対象外であることの確認。
  // 実際のマージは buildDigest 側の events.forEach ループが担う。
  const e = { type: "queue-operation", operation: "enqueue", content: "x" };
  assert.equal(e.type === "user", false);
});

test("buildDigest: queue-operation は enqueue のみ '## user messages' に載り、remove/dequeue は載らない", () => {
  const text = readFileSync(fixturePath, "utf8");
  const { events, skipped, eventLines } = parseJsonl(text);
  const out = buildDigest(events, { jsonlPath: fixturePath, skipped, eventLines });

  assert.ok(out.includes("origin=queued"));
  assert.ok(out.includes("ちゃんとサブエージェント使うように。"));
  // remove イベントの行番号 (enqueue の直後) が [U] エントリの見出しとして出現しないこと
  const enqueueLineNo = eventLines[events.findIndex((e) => e.type === "queue-operation" && e.operation === "enqueue")];
  const removeLineNo = eventLines[events.findIndex((e) => e.type === "queue-operation" && e.operation === "remove")];
  assert.ok(out.includes(`line=${enqueueLineNo} `));
  assert.ok(!out.includes(`line=${removeLineNo} `));
});

test("buildDigest: session map に queued 件数が併記される", () => {
  const text = readFileSync(fixturePath, "utf8");
  const { events, skipped, eventLines } = parseJsonl(text);
  const out = buildDigest(events, { jsonlPath: fixturePath, skipped, eventLines });
  assert.ok(out.includes("(+queued: 1)"));
});

test("buildDigest: queue-operation の enqueue にも processed マーカーが行番号ベースで付く", () => {
  const text = readFileSync(fixturePath, "utf8");
  const { events, skipped, eventLines } = parseJsonl(text);
  const enqueueIdx = events.findIndex((e) => e.type === "queue-operation" && e.operation === "enqueue");
  const out = buildDigest(events, { jsonlPath: fixturePath, skipped, eventLines, boundaryIdx: enqueueIdx });
  const queuedLine = out.split("\n").find((l) => l.includes("origin=queued"));
  assert.ok(queuedLine.includes("processed"));
});

test("resolveByLine: 行番号からイベントを特定する。パース不能行は not-found", () => {
  const events = [{ uuid: "a" }, { uuid: "b" }];
  const eventLines = [1, 3]; // 行2はパース不能で欠番
  assert.equal(resolveByLine(events, eventLines, 3).event.uuid, "b");
  assert.equal(resolveByLine(events, eventLines, 2).error, "not-found");
});

test("context: --line で queue-operation (uuid 無し) をターゲットにでき、renderThin が line 表示する", () => {
  const text = readFileSync(fixturePath, "utf8");
  const { events, eventLines } = parseJsonl(text);
  const enqueueIdx = events.findIndex((e) => e.type === "queue-operation" && e.operation === "enqueue");
  const enqueueLine = eventLines[enqueueIdx];
  const resolved = resolveByLine(events, eventLines, enqueueLine);
  assert.equal(resolved.index, enqueueIdx);

  const toolUseMap = buildToolUseMap(events);
  const toolResultIndex = buildToolResultIndex(events);
  const rendered = renderThin(events[enqueueIdx], { toolUseMap, toolResultIndex, isTarget: true, line: enqueueLine });
  assert.ok(rendered[0].includes(`line=${enqueueLine}`));
  assert.ok(rendered[0].includes("<<< target"));
  assert.ok(rendered[1].includes("ちゃんとサブエージェント使うように。"));
});

test("renderThin: queue-operation の remove/dequeue は本文を出さず見出しのみ", () => {
  const e = { type: "queue-operation", operation: "remove", timestamp: "2026-01-01T00:00:00.000Z", content: "should not print" };
  const out = renderThin(e, { toolUseMap: new Map(), toolResultIndex: new Map(), isTarget: false, line: 5 });
  assert.equal(out.length, 1);
  assert.ok(!out[0].includes("should not print"));
});

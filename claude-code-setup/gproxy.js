#!/usr/bin/env node
// =============================================================================
// gproxy — Gemini → Claude Code Proxy
//
// Flow:
//   You type → Gemini compresses + classifies → Claude Code (haiku/sonnet)
//               executes → output streams back to you via Gemini
//
// Usage:
//   node gproxy.js                  # interactive REPL loop
//   echo "fix the bug" | node gproxy.js   # one-shot from stdin
//   node gproxy.js "explain this codebase" # one-shot from arg
//
// Requirements:
//   - gemini CLI installed: npm install -g @google/gemini-cli
//   - claude CLI installed: npm install -g @anthropic-ai/claude-code
//   - Both authenticated
// =============================================================================

const { execSync, spawnSync, spawn } = require("child_process");
const readline = require("readline");
const fs = require("fs");
const path = require("path");
const os = require("os");

// ── Config ────────────────────────────────────────────────────────────────────
const CONFIG = {
  // Model selection thresholds
  haiku_model:  "claude-haiku-4-5",   // fast/cheap: simple Q&A, explanations
  sonnet_model: "claude-sonnet-4-6",  // powerful: coding, multi-file, complex

  // Context window auto-compact threshold
  compact_threshold: 75,

  // Max tokens Gemini sends to Claude (keeps Claude context lean)
  max_compressed_tokens: 800,

  // Session state
  session_file: path.join(os.homedir(), ".claude/tmp/gproxy-session.json"),
  state_file:   path.join(os.homedir(), ".claude/tmp/context-state.json"),

  // Colors
  colors: {
    gemini:  "\x1b[94m",   // blue
    claude:  "\x1b[95m",   // magenta
    system:  "\x1b[90m",   // dim gray
    warn:    "\x1b[33m",   // yellow
    error:   "\x1b[91m",   // red
    green:   "\x1b[32m",   // green
    reset:   "\x1b[0m",
    bold:    "\x1b[1m",
  },
};

// ── Helpers ───────────────────────────────────────────────────────────────────
const C = CONFIG.colors;
const log  = (msg)        => process.stderr.write(`${C.system}${msg}${C.reset}\n`);
const warn = (msg)        => process.stderr.write(`${C.warn}⚠  ${msg}${C.reset}\n`);
const err  = (msg)        => process.stderr.write(`${C.error}✗  ${msg}${C.reset}\n`);
const ok   = (msg)        => process.stderr.write(`${C.green}✓  ${msg}${C.reset}\n`);
const tag  = (who, msg)   => `${C.bold}${who}${C.reset} ${msg}`;

function readState() {
  try { return JSON.parse(fs.readFileSync(CONFIG.state_file, "utf8")); }
  catch { return {}; }
}

function readSession() {
  try { return JSON.parse(fs.readFileSync(CONFIG.session_file, "utf8")); }
  catch { return { session_id: null, history: [] }; }
}

function saveSession(data) {
  fs.mkdirSync(path.dirname(CONFIG.session_file), { recursive: true });
  fs.writeFileSync(CONFIG.session_file, JSON.stringify(data, null, 2));
}

// ── Check prerequisites ───────────────────────────────────────────────────────
function checkPrereqs() {
  const missing = [];
  try { execSync("which gemini", { stdio: "pipe" }); } catch { missing.push("gemini (npm install -g @google/gemini-cli)"); }
  try { execSync("which claude", { stdio: "pipe" }); } catch { missing.push("claude (npm install -g @anthropic-ai/claude-code)"); }
  if (missing.length) {
    err("Missing required tools:");
    missing.forEach(m => err(`  ${m}`));
    process.exit(1);
  }
}

// ── Step 1: Gemini analyses your input ────────────────────────────────────────
// Returns: { compressed_prompt, model, reasoning, is_simple }
async function geminiAnalyze(userInput, conversationHistory) {
  const historySnippet = conversationHistory.slice(-4)
    .map(h => `[${h.role}]: ${h.content.slice(0, 300)}`)
    .join("\n");

  const metaPrompt = `You are a routing and compression layer between a user and Claude Code CLI.

Your job:
1. CLASSIFY the request complexity
2. COMPRESS the user's input into a lean, precise prompt for Claude Code
3. SELECT the right Claude model

RECENT HISTORY (last 2 exchanges):
${historySnippet || "(none yet)"}

USER INPUT:
${userInput}

CLASSIFICATION RULES:
- Use "haiku" for: simple questions, explanations, quick lookups, "what does X do?", "explain Y", short answers
- Use "sonnet" for: writing/editing code, debugging, multi-file tasks, architecture, "fix", "implement", "refactor", "create"

COMPRESSION RULES:
- Remove filler words, pleasantries, repetition
- Keep all technical specifics (file names, function names, error messages)
- If user references history ("that function", "the bug above"), include the specific reference inline
- Target: under 150 words, but never lose meaning
- If user's input is already short and precise, keep it as-is

Respond ONLY with valid JSON (no markdown, no backticks):
{
  "model": "haiku" or "sonnet",
  "reasoning": "one sentence why",
  "compressed_prompt": "the lean prompt to send to Claude Code",
  "is_simple": true/false
}`;

  process.stderr.write(`${C.gemini}◆ Gemini${C.reset} analyzing... `);

  const result = spawnSync("gemini", ["-p", metaPrompt], {
    encoding: "utf8",
    timeout: 30000,
  });

  if (result.error || result.status !== 0) {
    process.stderr.write("failed\n");
    warn("Gemini analysis failed, using raw input + sonnet");
    return {
      model: "sonnet",
      reasoning: "fallback",
      compressed_prompt: userInput,
      is_simple: false,
    };
  }

  let raw = result.stdout.trim();
  // Strip markdown fences if present
  raw = raw.replace(/^```json\s*/i, "").replace(/```\s*$/, "").trim();

  try {
    const parsed = JSON.parse(raw);
    process.stderr.write(`${C.green}done${C.reset}\n`);
    return parsed;
  } catch {
    process.stderr.write("parse error, using fallback\n");
    return {
      model: userInput.match(/\b(fix|implement|create|refactor|debug|write|edit|build|add|remove|change|update|migrate)\b/i)
        ? "sonnet" : "haiku",
      reasoning: "keyword-based fallback",
      compressed_prompt: userInput,
      is_simple: false,
    };
  }
}

// ── Step 2: Run Claude Code with the compressed prompt ────────────────────────
function runClaudeCode(compressedPrompt, modelChoice, sessionData) {
  const modelName = modelChoice === "haiku"
    ? CONFIG.haiku_model
    : CONFIG.sonnet_model;

  const args = [
    "-p", compressedPrompt,
    "--model", modelName,
    "--output-format", "stream-json",
    "--verbose",
    "--allowedTools", "Read,Write,Edit,Bash,Glob,Grep,LS",
  ];

  // Resume session if we have one
  if (sessionData.session_id) {
    args.push("--resume", sessionData.session_id);
  }

  process.stderr.write(`\n${C.claude}◆ Claude Code${C.reset} ${C.system}[${modelName}]${C.reset}\n`);
  process.stderr.write("─".repeat(50) + "\n");

  let fullText = "";
  let newSessionId = sessionData.session_id;
  let toolCalls = [];
  let finalCost = null;

  return new Promise((resolve) => {
    const proc = spawn("claude", args, {
      stdio: ["pipe", "pipe", "pipe"],
    });

    proc.stdin.end();

    let buffer = "";

    proc.stdout.on("data", (chunk) => {
      buffer += chunk.toString();
      const lines = buffer.split("\n");
      buffer = lines.pop(); // keep incomplete last line

      for (const line of lines) {
        if (!line.trim()) continue;
        try {
          const event = JSON.parse(line);
          handleStreamEvent(event);
        } catch {
          // Not JSON — print raw
          if (line.trim()) process.stdout.write(line + "\n");
        }
      }
    });

    proc.stderr.on("data", (chunk) => {
      const text = chunk.toString();
      // Filter out noise, show real errors
      if (text.includes("Error") || text.includes("error")) {
        process.stderr.write(`${C.warn}${text}${C.reset}`);
      }
    });

    function handleStreamEvent(event) {
      // Extract session ID from first response
      if (event.session_id && !newSessionId) {
        newSessionId = event.session_id;
      }

      // Text output — stream directly to user
      if (event.type === "stream_event") {
        const delta = event.event?.delta;
        if (delta?.type === "text_delta") {
          process.stdout.write(delta.text);
          fullText += delta.text;
        }
      }

      // Tool use — show live
      if (event.type === "stream_event" && event.event?.type === "content_block_start") {
        const block = event.event.content_block;
        if (block?.type === "tool_use") {
          const toolName = block.name || "tool";
          process.stderr.write(`\n${C.system}  ⚙ ${toolName}${C.reset} `);
          toolCalls.push(toolName);
        }
      }

      // Tool input streaming (show file names etc)
      if (event.type === "stream_event" && event.event?.type === "content_block_delta") {
        const delta = event.event.delta;
        if (delta?.type === "input_json_delta" && delta.partial_json) {
          // Try to extract file path from partial JSON
          const match = delta.partial_json.match(/"(file_path|path|command)":\s*"([^"]{3,60})"/);
          if (match) process.stderr.write(`${C.system}${match[2]}${C.reset}`);
        }
      }

      // Cost / usage at end
      if (event.cost_usd !== undefined) finalCost = event.cost_usd;
      if (event.type === "result" && event.cost_usd !== undefined) finalCost = event.cost_usd;
    }

    proc.on("close", (code) => {
      // Flush remaining buffer
      if (buffer.trim()) {
        try {
          const event = JSON.parse(buffer);
          if (event.cost_usd !== undefined) finalCost = event.cost_usd;
        } catch {}
      }

      process.stdout.write("\n");
      process.stderr.write("─".repeat(50) + "\n");

      if (finalCost !== null) {
        
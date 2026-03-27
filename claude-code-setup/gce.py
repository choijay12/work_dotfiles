#!/usr/bin/env python3
# =============================================================================
# gce — Gemini Context Engineer for Claude Code
# 
# Gemini acts as the intake layer:
#   1. Takes your natural-language input
#   2. Reads large files / codebases / PDFs via Gemini's 1M token window
#   3. Compresses context and selects Haiku vs Sonnet for Claude
#   4. Passes a lean, precise prompt to Claude Code
#   5. Prints Claude's response back to you
#
# Usage:
#   gce "add auth to my express app"
#   gce --read src/ "summarize architecture then plan auth"
#   gce --pdf docs/spec.pdf "what endpoints do I need to build?"
#   gce --interactive     (REPL loop: you talk to Gemini, it talks to Claude)
#   gce --gemini-only "summarize the codebase"   (skip Claude entirely)
# =============================================================================

import subprocess
import sys
import os
import json
import argparse
import tempfile
import re
from pathlib import Path

# ── Config ────────────────────────────────────────────────────────────────────
HAIKU_TASKS   = ["explain", "what is", "quick", "rename", "typo", "fix typo",
                 "one line", "single file", "syntax", "comment", "simple",
                 "describe", "list", "show me", "what does", "small", "minor"]
SONNET_TASKS  = ["implement", "build", "create", "refactor", "debug", "fix",
                 "add feature", "write tests", "architect", "design", "migrate",
                 "complex", "multi-file", "integrate", "optimize", "auth"]
DEFAULT_MODEL = "sonnet"

STATE_FILE = Path.home() / ".claude" / "tmp" / "context-state.json"

COLORS = {
    "cyan":    "\033[96m",
    "green":   "\033[92m",
    "yellow":  "\033[93m",
    "red":     "\033[91m",
    "magenta": "\033[95m",
    "dim":     "\033[2m",
    "bold":    "\033[1m",
    "reset":   "\033[0m",
}

def c(color, text):
    return f"{COLORS.get(color,'')}{text}{COLORS['reset']}"

def banner(text):
    print(f"\n{c('dim','─'*55)}")
    print(f"  {c('bold', text)}")
    print(f"{c('dim','─'*55)}")

# ── Model selection ───────────────────────────────────────────────────────────
def pick_model(prompt_text: str) -> str:
    """Gemini decides: haiku for simple tasks, sonnet for complex ones."""
    low = prompt_text.lower()
    for keyword in HAIKU_TASKS:
        if keyword in low:
            return "haiku"
    for keyword in SONNET_TASKS:
        if keyword in low:
            return "sonnet"
    return DEFAULT_MODEL

def explain_model_choice(model: str, prompt: str) -> str:
    low = prompt.lower()
    if model == "haiku":
        matched = [k for k in HAIKU_TASKS if k in low]
        reason = f"simple/quick task (matched: {matched[0]})" if matched else "default fast path"
    else:
        matched = [k for k in SONNET_TASKS if k in low]
        reason = f"complex task (matched: {matched[0]})" if matched else "default development path"
    return reason

# ── Gemini headless call ──────────────────────────────────────────────────────
def call_gemini(prompt: str, stdin_text: str = None) -> str:
    """Call Gemini CLI in headless mode."""
    cmd = ["gemini", "-p", prompt]
    
    try:
        result = subprocess.run(
            cmd,
            input=stdin_text,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if result.returncode != 0:
            err = result.stderr.strip()
            raise RuntimeError(f"Gemini error (exit {result.returncode}): {err}")
        return result.stdout.strip()
    except FileNotFoundError:
        raise RuntimeError(
            "gemini not found. Install: npm install -g @google/gemini-cli && gemini"
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError("Gemini timed out (>120s)")

# ── Claude Code headless call ─────────────────────────────────────────────────
def call_claude(prompt: str, model: str = "sonnet", allowed_tools: str = None) -> str:
    """Call Claude Code in print (-p) mode."""
    cmd = ["claude", "-p", prompt, "--model", model]
    
    if allowed_tools:
        cmd += ["--allowedTools", allowed_tools]
    
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=300,
            cwd=os.getcwd(),
        )
        output = result.stdout.strip()
        if not output and result.stderr:
            output = result.stderr.strip()
        return output
    except FileNotFoundError:
        raise RuntimeError(
            "claude not found. Install: npm install -g @anthropic-ai/claude-code"
        )
    except subprocess.TimeoutExpired:
        raise RuntimeError("Claude timed out (>300s)")

# ── File/codebase reader via Gemini ──────────────────────────────────────────
def read_via_gemini(paths: list[str], user_query: str) -> str:
    """
    Feed large files/dirs to Gemini's 1M context window.
    Returns a compressed, relevant summary for Claude.
    """
    file_contents = []
    
    for path_str in paths:
        path = Path(path_str)
        if not path.exists():
            print(c("yellow", f"  ⚠ Path not found: {path_str}"))
            continue
            
        if path.is_dir():
            print(c("dim", f"  📁 Reading directory: {path_str}"))
            # Walk directory, collect text files
            for fp in sorted(path.rglob("*")):
                if fp.is_file() and fp.suffix in (
                    ".py", ".js", ".ts", ".tsx", ".jsx", ".go", ".rs",
                    ".java", ".cpp", ".c", ".h", ".cs", ".rb", ".php",
                    ".swift", ".kt", ".md", ".txt", ".json", ".yaml",
                    ".yml", ".toml", ".env", ".sh", ".sql", ".html", ".css"
                ):
                    # Skip common noise dirs
                    parts = fp.parts
                    if any(d in parts for d in ("node_modules", ".git", "__pycache__",
                                                ".next", "dist", "build", ".venv", "venv")):
                        continue
                    try:
                        content = fp.read_text(encoding="utf-8", errors="ignore")
                        rel = fp.relative_to(path)
                        file_contents.append(f"=== FILE: {rel} ===\n{content}\n")
                    except Exception:
                        pass
        elif path.is_file():
            print(c("dim", f"  📄 Reading file: {path_str}"))
            try:
                content = path.read_text(encoding="utf-8", errors="ignore")
                file_contents.append(f"=== FILE: {path_str} ===\n{content}\n")
            except Exception as e:
                print(c("yellow", f"  ⚠ Could not read {path_str}: {e}"))

    if not file_contents:
        return ""

    total_chars = sum(len(f) for f in file_contents)
    print(c("dim", f"  📊 Total content: ~{total_chars:,} chars (~{total_chars//4:,} tokens) → Gemini processing..."))

    combined = "\n".join(file_contents)
    
    gemini_prompt = f"""You are a context engineer. Your job is to read the provided files and produce a DENSE, 
structured summary that another AI (Claude) will use to complete a coding task.

The task Claude needs to do: "{user_query}"

Analyze the content and produce:

## Codebase Summary
Brief architecture overview (3-5 sentences max)

## Relevant Files for This Task
List only files directly relevant to "{user_query}" with 1-line descriptions

## Key Patterns & Conventions
Tech stack, naming conventions, architectural patterns Claude must follow

## Current State Related to Task
What already exists that relates to the task? What's missing?

## Precise Context for Claude
The minimum information Claude needs to complete the task correctly, nothing more.
Be surgical — only include what's needed for this specific task.

FILES:
{combined[:800000]}"""  # Stay well under 1M tokens

    return call_gemini(gemini_prompt)

# ── PDF reader ────────────────────────────────────────────────────────────────
def read_pdf_via_gemini(pdf_path: str, user_query: str) -> str:
    """Use Gemini CLI to read a PDF and extract relevant context."""
    # Gemini CLI can read files directly in interactive mode, but for -p mode
    # we extract text first using pdftotext (poppler) or fallback to cat
    path = Path(pdf_path)
    if not path.exists():
        raise FileNotFoundError(f"PDF not found: {pdf_path}")

    print(c("dim", f"  📄 Reading PDF: {pdf_path}"))

    # Try pdftotext first
    pdf_text = None
    try:
        result = subprocess.run(
            ["pdftotext", str(path), "-"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0:
            pdf_text = result.stdout
            print(c("dim", f"  ✓ Extracted via pdftotext ({len(pdf_text):,} chars)"))
    except FileNotFoundError:
        pass

    # Fallback: try python pdfminer
    if not pdf_text:
        try:
            import importlib
            pdfminer = importlib.import_module("pdfminer.high_level")
            pdf_text = pdfminer.extract_text(str(path))
            print(c("dim", f"  ✓ Extracted via pdfminer ({len(pdf_text):,} chars)"))
        except (ImportError, Exception):
            pass

    if not pdf_text:
        raise RuntimeError(
            f"Could not extract PDF text. Install pdftotext:\n"
            f"  macOS: brew install poppler\n"
            f"  Ubuntu: apt install poppler-utils"
        )

    gemini_prompt = f"""You are a context engineer reading a document to extract relevant information for a coding task.

Task: "{user_query}"

Extract and summarize ONLY what's relevant to this task from the document. Be concise and precise.
Format as structured notes Claude can use directly.

DOCUMENT:
{pdf_text[:700000]}"""

    return call_gemini(gemini_prompt)

# ── Context compression prompt builder ───────────────────────────────────────
def build_compressed_prompt(
    user_input: str,
    context_summary: str,
    model: str,
    model_reason: str
) -> str:
    """
    Ask Gemini to engineer the final prompt for Claude.
    Gemini compresses context + refines the task description.
    """
    compression_prompt = f"""You are a context engineer creating an optimal prompt for Claude Code ({model} model).

USER'S ORIGINAL REQUEST: {user_input}

CONTEXT SUMMARY: 
{context_summary if context_summary else "(no extra context provided)"}

Your job: Write the BEST possible prompt for Claude to complete this task.
Rules:
- Be precise and unambiguous  
- Include only context Claude needs — strip everything else
- Reference specific files/functions if the context mentions them
- State the expected output clearly
- For {model} model: {"be concise, this is a simple task" if model == "haiku" else "be thorough, this is a complex task"}
- Do NOT include pleasantries or meta-commentary
- Output ONLY the prompt text, nothing else

Write the Claude prompt now:"""

    return call_gemini(compression_prompt)

# ── Interactive REPL mode ─────────────────────────────────────────────────────
def interactive_mode(read_paths: list[str] = None):
    """
    Interactive loop where you talk to Gemini,
    Gemini manages context, and dispatches to Claude when needed.
    """
    banner("GCE Interactive Mode  — Gemini Context Engineer")
    print(c("dim", "  You → Gemini → Claude Code"))
    print(c("dim", "  Commands: /quit, /gemini-only, /read <path>, /clear"))
    print()

    session_context = []
    extra_context = ""

    # Pre-load any specified paths
    if read_paths:
        print(c("cyan", "📚 Pre-loading paths via Gemini..."))
        extra_context = read_via_gemini(read_paths, "general codebase understanding")
        print(c("green", "✓ Context loaded"))
        print()

    while True:
        try:
            user_input = input(c("cyan", "you › ") + " ").strip()
        except (KeyboardInterrupt, EOFError):
            print(c("dim", "\n  Exiting GCE."))
            break

        if not user_input:
            continue

        # Commands
        if user_input.lower() in ("/quit", "/exit", "exit", "quit"):
            break

        if user_input.lower().startswith("/read "):
            paths = user_input[6:].split()
            print(c("cyan", f"📚 Loading {paths}..."))
            extra_context = read_via_gemini(paths, "general understanding")
            print(c("green", "✓ Loaded"))
            continue

        if user_input.lower() == "/clear":
            session_context = []
            extra_context = ""
            print(c("dim", "  Context cleared."))
            continue

        gemini_only = user_input.lower().startswith("/gemini-only ")
        if gemini_only:
            user_input = user_input[13:]

        # Determine routing
        model = pick_model(user_input)
        reason = explain_model_choice(model, user_input)

        print()
        print(c("dim", f"  🤖 Gemini processing → Claude {model} ({reason})"))

        try:
            # Build compressed prompt for Claude
            if gemini_only:
                # Don't call Claude, just get Gemini's answer
                context_for_gemini = (extra_context + "\n\n" + "\n".join(session_context[-4:]))
                gemini_q = f"""Context:\n{context_for_gemini}\n\nQuestion: {user_input}"""
                response = call_gemini(gemini_q)
                print()
                print(c("magenta", "gemini › "))
                print(response)
            else:
                # Compress with Gemini → execute with Claude
                context_blob = extra_context
                if session_context:
                    context_blob += "\n\nPrevious session context:\n" + "\n".join(session_context[-3:])

                compressed = build_compressed_prompt(user_input, context_blob, model, reason)

                print(c("dim", f"\n  📝 Compressed prompt → claude --model {model}"))
                print(c("dim", f"  {'─'*50}"))
                print(c("dim", f"  {compressed[:200]}{'...' if len(compressed) > 200 else ''}"))
                print(c("dim", f"  {'─'*50}\n"))

                response = call_claude(compressed, model)

                print(c("green", f"claude ({model}) › "))
                print(response)

                # Store exchange summary in session context
                session_context.append(
                    f"[User asked]: {user_input[:150]}\n[Claude replied]: {response[:300]}"
                )
                # Keep context window manageable
                if len(session_context) > 8:
                    session_context = session_context[-6:]

        except RuntimeError as e:
            print(c("red", f"\n  ✗ Error: {e}"))

        print()

# ── Single-shot mode ──────────────────────────────────────────────────────────
def single_shot(args):
    user_input = " ".join(args.prompt)
    
    banner("GCE — Gemini Context Engineer")

    # Step 1: Read files/paths if specified
    extra_context = ""

    if args.read:
        print(c("cyan", f"📚 Step 1/3: Loading content via Gemini 1M context..."))
        extra_context = read_via_gemini(args.read, user_input)
        print(c("green", "  ✓ Content processed by Gemini"))
        print()

    if args.pdf:
        print(c("cyan", f"📄 Step 1/3: Reading PDF via Gemini..."))
        for pdf in args.pdf:
            extra_context += "\n" + read_pdf_via_gemini(pdf, user_input)
        print(c("green", "  ✓ PDF processed by Gemini"))
        print()

    # Step 2: Pick model
    model = args.model if args.model else pick_model(user_input)
    reason = explain_model_choice(model, user_input)
    
    print(c("cyan", f"🧠 Step 2/3: Gemini compressing context → Claude {model}"))
    print(c("dim",  f"  Model choice: {model} ({reason})"))

    if args.gemini_only:
        print(c("dim", "  Mode: Gemini only (no Claude)"))
        prompt = f"""Context:\n{extra_context}\n\nTask: {user_input}"""
        response = call_gemini(prompt)
        print()
        banner("Gemini Response")
        print(response)
        return

    # Step 3: Compress + dispatch to Claude
    compressed = build_compressed_prompt(user_input, extra_context, model, reason)

    print()
    print(c("dim", f"  Compressed prompt preview:"))
    print(c("dim", f"  {compressed[:300]}{'...' if len(compressed) > 300 else ''}"))
    print()

    print(c("cyan", f"⚡ Step 3/3: Claude {model} executing..."))
    print()

    response = call_claude(compressed, model, args.tools)

    banner(f"Claude {model} Response")
    print(response)

# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        prog="gce",
        description="Gemini Context Engineer for Claude Code — Gemini reads, Claude codes.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  gce "add JWT auth to my express app"
  gce --read src/ "what does the auth module do?"
  gce --read src/ --pdf docs/spec.pdf "implement the /users endpoint"
  gce --model haiku "rename variable foo to userCount in utils.js"
  gce --gemini-only "summarize this entire codebase"
  gce --interactive
  gce --interactive --read src/
        """
    )

    parser.add_argument("prompt", nargs="*", help="Your task/question in natural language")
    parser.add_argument("--read",  "-r", nargs="+", metavar="PATH",
                        help="Files or directories for Gemini to read (large context)")
    parser.add_argument("--pdf",   nargs="+", metavar="FILE",
                        help="PDF files for Gemini to read and summarize")
    parser.add_argument("--model", "-m", choices=["haiku", "sonnet", "opus"],
                        help="Force a specific Claude model (default: auto-selected by Gemini)")
    parser.add_argument("--tools", "-t", metavar="TOOLS",
                        help='Allowed Claude tools, e.g. "Read,Write,Bash"')
    parser.add_argument("--gemini-only", "-g", action="store_true",
                        help="Use Gemini only — don't call Claude Code")
    parser.add_argument("--interactive", "-i", action="store_true",
                        help="Interactive REPL: you → Gemini → Claude Code")
    parser.add_argument("--dry-run", action="store_true",
                        help="Show compressed prompt but don't call Claude")

    args = parser.parse_args()

    # Check dependencies
    for tool in ["gemini", "claude"]:
        if not args.gemini_only or tool == "gemini":
            try:
                subprocess.run([tool, "--version"], capture_output=True, timeout=5)
            except FileNotFoundError:
                if tool == "gemini":
                    print(c("red", f"✗ gemini not found. Install:"))
                    print("  npm install -g @google/gemini-cli && gemini")
                else:
                    print(c("red", f"✗ claude not found. Install:"))
                    print("  npm install -g @anthropic-ai/claude-code")
                sys.exit(1)
            except subprocess.TimeoutExpired:
                pass

    if args.interactive:
        interactive_mode(args.read)
        return

    if not args.prompt and not args.read and not args.pdf:
        parser.print_help()
        sys.exit(0)

    single_shot(args)

if __name__ == "__main__":
    main()

#!/usr/bin/env bun
/**
 * Reflex's read-only MCP surface.
 *
 * A thin stdio client of reflexd: it reads ~/.config/reflex/token per call and
 * forwards to the local /api/* endpoints. Routing, ranking and question parsing
 * stay in the daemon; this file only shapes responses for an agent.
 *
 * Registered per harness (Pi: ~/.pi/agent/mcp.json, Claude: `claude mcp add`).
 * Never expose the write endpoints here: an agent that can spawn/send/answer
 * other agents needs its own decision, not a side effect of asking for state.
 */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";

const port = process.env.REFLEX_PORT || "47823";
const base = `http://127.0.0.1:${port}`;
// The installer and reflexd use ~/.config/reflex regardless of
// XDG_CONFIG_HOME; resolve the same file here instead of inventing a second path.
const tokenFile = path.join(os.homedir(), ".config", "reflex", "token");

function token(): string {
  return fs.readFileSync(tokenFile, "utf8").trim();
}

async function api(method: "GET" | "POST", route: string, body?: unknown): Promise<any> {
  const headers: Record<string, string> = { authorization: `Bearer ${token()}` };
  let payload: string | undefined;
  if (body !== undefined) {
    headers["content-type"] = "application/json";
    payload = JSON.stringify(body);
  }
  const res = await fetch(base + route, {
    method,
    headers,
    body: payload,
    signal: AbortSignal.timeout(8000),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`reflexd ${res.status}: ${text.slice(0, 300)}`);
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

function stateSummary(state: any) {
  const agents = Array.isArray(state?.agents) ? state.agents : [];
  const inbox = Array.isArray(state?.inbox) ? state.inbox : [];
  const questions = inbox.filter((item: any) => String(item?.kind || "") === "ask");
  const updates = inbox.filter((item: any) => String(item?.kind || "") !== "ask");
  return {
    now: state?.now,
    herdr: state?.herdr,
    folders: state?.folders,
    pending: state?.pending,
    counts: {
      agents: agents.length,
      working: agents.filter((a: any) => a.status === "working").length,
      blocked: agents.filter((a: any) => a.status === "blocked").length,
      questions: questions.length,
    },
    agents: agents.map((a: any) => ({
      pane: a.pane,
      name: a.name,
      kind: a.kind,
      status: a.status,
      cwd: a.cwd,
      title: a.title,
    })),
    questions,
    updates,
  };
}

const tools = [
  {
    name: "reflex_state",
    description:
      "Read Reflex's live state: every agent herdr reports (pane, name, kind, status, cwd, title), the questions waiting on you with their options, inbox updates and counts. Read-only.",
    inputSchema: { type: "object", properties: {}, additionalProperties: false },
  },
  {
    name: "reflex_candidates",
    description:
      "List where a request could go (live sessions, folders, earlier conversations) with Jev's weights, without sending anything. Read-only.",
    inputSchema: {
      type: "object",
      properties: {
        text: { type: "string", description: "The request, in the user's words." },
        harness: { type: "string", description: "Agent for a new session, e.g. claude or pi." },
        machine: { type: "string", description: "Another Mac's label; omit for this machine." },
      },
      required: ["text"],
      additionalProperties: false,
    },
  },
  {
    name: "reflex_route",
    description:
      "Ask Reflex where a request should go. Always a dry run: returns the decision and its reason, dispatches nothing. Read-only.",
    inputSchema: {
      type: "object",
      properties: {
        text: { type: "string", description: "The request, in the user's words." },
        harness: { type: "string", description: "Agent for a new session, e.g. claude or pi." },
        machine: { type: "string", description: "Another Mac's label; omit for this machine." },
      },
      required: ["text"],
      additionalProperties: false,
    },
  },
  {
    name: "reflex_folders",
    description: "Search the folder index Reflex routes into. Read-only.",
    inputSchema: {
      type: "object",
      properties: {
        q: { type: "string", description: "Filter text; omit for every folder." },
        machine: { type: "string", description: "Another Mac's label; omit for this machine." },
      },
      additionalProperties: false,
    },
  },
  {
    name: "reflex_explain",
    description: "Explain why Reflex would route a request where it does. Read-only.",
    inputSchema: {
      type: "object",
      properties: {
        text: { type: "string", description: "The request, in the user's words." },
        machine: { type: "string", description: "Another Mac's label; omit for this machine." },
      },
      required: ["text"],
      additionalProperties: false,
    },
  },
];

function query(args: Record<string, unknown>) {
  const params = new URLSearchParams();
  for (const key of ["q", "machine"]) {
    const value = args[key];
    if (value === undefined || value === null || value === "") continue;
    if (typeof value !== "string") throw new Error(`${key} must be a string`);
    params.set(key, value);
  }
  const text = params.toString();
  return text === "" ? "" : `?${text}`;
}

function requireText(args: Record<string, unknown>) {
  if (typeof args.text !== "string" || args.text.trim() === "") {
    throw new Error("text is required");
  }
}

async function run(name: string, args: Record<string, unknown>): Promise<any> {
  switch (name) {
    case "reflex_state":
      return stateSummary(await api("GET", "/api/state"));
    case "reflex_candidates":
      requireText(args);
      return api("POST", "/api/candidates", {
        text: args.text,
        harness: args.harness || "",
        machine: args.machine || "",
      });
    case "reflex_route":
      requireText(args);
      return api("POST", "/api/route", {
        text: args.text,
        dry: true,
        harness: args.harness || "",
        machine: args.machine || "",
      });
    case "reflex_folders":
      return api("GET", `/api/folders${query(args)}`);
    case "reflex_explain":
      requireText(args);
      return api("POST", "/api/explain", { text: args.text, machine: args.machine || "" });
    default:
      throw new Error(`unknown tool: ${name}`);
  }
}

function reply(id: unknown, result: unknown) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
}

function fail(id: unknown, code: number, message: string) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } }) + "\n");
}

async function handle(message: any) {
  const id = message?.id;
  const method = String(message?.method || "");
  const params = message?.params || {};

  if (method === "initialize") {
    return reply(id, {
      protocolVersion: typeof params.protocolVersion === "string" ? params.protocolVersion : "2024-11-05",
      capabilities: { tools: {} },
      serverInfo: { name: "reflex", version: "0.1.0" },
    });
  }
  if (method === "ping") return reply(id, {});
  if (method === "tools/list") return reply(id, { tools });
  if (method === "tools/call") {
    const name = String(params?.name || "");
    const args = (params?.arguments || {}) as Record<string, unknown>;
    try {
      const result = await run(name, args);
      return reply(id, {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
        isError: false,
      });
    } catch (error) {
      return reply(id, {
        content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }],
        isError: true,
      });
    }
  }
  // Notifications (initialized, cancelled, ...) carry no id: stay silent.
  if (id === undefined || id === null) return;
  fail(id, -32601, `unknown method: ${method}`);
}

const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
for await (const line of lines) {
  const text = line.trim();
  if (text === "") continue;
  let message: any;
  try {
    message = JSON.parse(text);
  } catch {
    fail(null, -32700, "invalid JSON");
    continue;
  }
  if (message === null || typeof message !== "object" || Array.isArray(message)) {
    fail(null, -32600, "invalid request");
    continue;
  }
  await handle(message);
}

#!/usr/bin/env -S node --experimental-strip-types

import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

/// The workflow that runs one scenario. GitHub dispatches a workflow only when the default branch
/// carries it, so this route works from any branch once the workflow is on main.
const workflowFile = "scenario.yml";

/// How long to look for the run the dispatch made. GitHub takes a few seconds to create it.
const lookLimit = 30;
const lookWaitMs = 2000;

export type CommandResult = {
  status: number;
  output: string;
};

export type Tools = {
  run: (command: string, args: readonly string[]) => CommandResult;
  wait: (ms: number) => Promise<void>;
  print: (line: string) => void;
};

export function countFromLog(log: string): number | null {
  let count: number | null = null;
  for (const line of log.split("\n")) {
    const found = /scenarios: ([0-9]+)/.exec(line);
    if (found !== undefined && found !== null && found[1] !== undefined) {
      count = Number(found[1]);
    }
  }
  return count;
}

export function runIdsFrom(listing: string): number[] {
  const rows: unknown = JSON.parse(listing === "" ? "[]" : listing);
  if (!Array.isArray(rows)) {
    return [];
  }
  const ids: number[] = [];
  for (const row of rows) {
    const id: unknown = (row as { databaseId?: unknown }).databaseId;
    if (typeof id === "number") {
      ids.push(id);
    }
  }
  return ids;
}

/// The reason to refuse, or null when the tree is clean. A run of a tree that carries changes
/// proves nothing about the changes, because the pipeline reads the commit and not the tree.
export function refusalForWorkingTree(tools: Tools): string | null {
  const status = tools.run("git", ["status", "--porcelain"]);
  if (status.status !== 0) {
    return `git status failed: ${status.output.trim()}`;
  }
  if (status.output.trim() !== "") {
    return "the working tree carries changes that no commit holds, so commit them first";
  }
  return null;
}

/// The reason to refuse, or null when origin carries the commit this tree is on.
export function refusalForUnpushedHead(tools: Tools, branch: string): string | null {
  const head = tools.run("git", ["rev-parse", "HEAD"]).output.trim();
  const listing = tools.run("git", ["ls-remote", "origin", `refs/heads/${branch}`]);
  const remote = listing.output.trim().split(/\s+/)[0] ?? "";
  if (remote === "") {
    return `origin carries no branch named ${branch}, so push it first`;
  }
  if (remote !== head) {
    return `origin/${branch} is at ${remote.slice(0, 8)} and this tree is at ${head.slice(0, 8)}, so push it first`;
  }
  return null;
}

async function waitForTheNewRun(tools: Tools, branch: string, known: number[]): Promise<number | null> {
  for (let look = 0; look < lookLimit; look = look + 1) {
    await tools.wait(lookWaitMs);
    const now = runIdsFrom(listRuns(tools, branch).output);
    const fresh = now.filter((id) => !known.includes(id));
    if (fresh.length > 0) {
      return Math.max(...fresh);
    }
  }
  return null;
}

function listRuns(tools: Tools, branch: string): CommandResult {
  return tools.run("gh", [
    "run",
    "list",
    "--workflow",
    workflowFile,
    "--branch",
    branch,
    "--limit",
    "20",
    "--json",
    "databaseId",
  ]);
}

/// Runs one scenario in the pipeline and prints `scenarios: N`. Returns the exit code.
///
/// The count is printed before anything is decided, because the count is the evidence. A count of
/// zero, a count the log does not carry, and a run that went red all exit non zero.
export async function prove(scenario: string, tools: Tools): Promise<number> {
  const branch = tools.run("git", ["rev-parse", "--abbrev-ref", "HEAD"]).output.trim();
  if (branch === "" || branch === "HEAD") {
    return refuse("this tree is on no branch, so there is nothing to run");
  }

  const dirty = refusalForWorkingTree(tools);
  if (dirty !== null) {
    return refuse(dirty);
  }
  const unpushed = refusalForUnpushedHead(tools, branch);
  if (unpushed !== null) {
    return refuse(unpushed);
  }

  const known = runIdsFrom(listRuns(tools, branch).output);
  const dispatch = tools.run("gh", [
    "workflow",
    "run",
    workflowFile,
    "--ref",
    branch,
    "-f",
    `scenario=${scenario}`,
  ]);
  if (dispatch.status !== 0) {
    return refuse(`the dispatch failed: ${dispatch.output.trim()}`);
  }

  const id = await waitForTheNewRun(tools, branch, known);
  if (id === null) {
    return refuse(`no run of ${workflowFile} appeared on ${branch}`);
  }

  const watched = tools.run("gh", ["run", "watch", String(id), "--exit-status"]);
  const log = tools.run("gh", ["run", "view", String(id), "--log"]).output;
  const count = countFromLog(log);

  tools.print(`scenarios: ${count ?? 0}`);

  if (count === null) {
    return refuse(`the run carried no count, so it proves nothing: ${addressOf(id)}`);
  }
  if (count === 0) {
    return refuse(`no scenario named ${scenario} ran: ${addressOf(id)}`);
  }
  if (watched.status !== 0) {
    return refuse(`the scenario ran and the run went red: ${addressOf(id)}`);
  }
  return 0;
}

function addressOf(id: number): string {
  return `gh run view ${id}`;
}

function refuse(reason: string): number {
  process.stderr.write(`prove: ${reason}\n`);
  return 1;
}

const shell: Tools = {
  run: (command, args) => {
    const done = spawnSync(command, [...args], { encoding: "utf8" });
    return {
      status: done.status ?? 1,
      output: `${done.stdout ?? ""}${done.stderr ?? ""}`,
    };
  },
  wait: (ms) => new Promise((done) => setTimeout(done, ms)),
  print: (line) => process.stdout.write(`${line}\n`),
};

const entry = process.argv[1];
if (entry !== undefined && import.meta.url === pathToFileURL(entry).href) {
  const scenario = process.argv[2];
  if (scenario === undefined || scenario === "") {
    process.stderr.write("prove: name the scenario to run, for example prove.ts thePackageBuilds\n");
    process.exit(2);
  }
  process.exit(await prove(scenario, shell));
}
